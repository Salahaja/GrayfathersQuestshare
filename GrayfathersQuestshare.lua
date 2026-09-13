--[[
    Addon:       GrayfathersQuestshare (folder/.toc/.lua name; shows in-game as
                 "Grayfather's Questshare")
    Description: Puts your party's quest progress on the tooltip. Hover the mob
                 or the item and see who still needs it:

                     Kill Ten Boars
                       you 3/10  -  Bob 7/10  -  Cara done

    Why a separate addon rather than a pfQuest patch: quest progress comes from
    the Blizzard quest log API, not from pfQuest. pfQuest is a display layer over
    the same data, so reading it directly means this works with pfQuest, with
    Questie, or with neither, and survives updates to any of them. (pfQuest is
    MIT, so patching it would have been allowed - it just wouldn't have been
    better.)

    Nothing is saved between sessions. Quest progress goes stale the moment
    someone plays without you, and a party is a different set of people every
    time, so stale numbers would be worse than no numbers. This is live only:
    what you see came from someone currently in your group.

    THE ONE DANGEROUS PART, and the reason GQ.ScanQuestLog is written the way it
    is: reading objectives requires SelectQuestLogEntry, which changes GLOBAL
    selection state - the same selection the default quest log UI, and
    SetAbandonQuest(), act on. An addon that scans the log and leaves the
    selection on the last entry will silently cause the player to abandon the
    WRONG QUEST. That is not hypothetical; it was diagnosed in another addon on
    this very install. So the selection is saved before the scan and restored
    after, always.

    Slash commands: /gq, /questshare
--]]

GQ = {}
GQ.ADDON_NAME = "GrayfathersQuestshare"
GQ.PREFIX     = "GQSHARE"
GQ.VERSION    = "1.3.0"

-- [playerName] = { time = <when heard>, quests = { [questTitle] = { {name, have, need}, ... } } }
GQ.data   = {}
GQ.config = {}

GQ.MAX_PAYLOAD     = 200
GQ.SEND_INTERVAL   = 0.4
GQ.SCAN_DEBOUNCE   = 1.5
GQ.PEER_STALE_AFTER = 300 -- drop someone's progress 5 minutes after their last update

GQ.PRESENCE_INTERVAL = 30 -- seconds between "I'm running this addon" beacons

GQ.sendQueue = {}
GQ.sendTimer = 0
GQ.scanTimer = nil
GQ.presenceTimer = 0
GQ.incoming  = {}

-- [name] = when we last heard from them at all. Separate from GQ.data because
-- "has the addon" and "has shared progress" are different facts, and telling
-- them apart is the whole difference between "they need to install it" and
-- "something is broken".
GQ.present = {}

GQ.stats = { sent = 0, received = 0 }

-- ---------------------------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------------------------
function GQ.Say(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cFF88DD88Grayfather's Questshare|r: " .. msg)
end

function GQ.Debug(msg)
    if GQ.config.debug then
        DEFAULT_CHAT_FRAME:AddMessage("|cFF888888Questshare debug|r: " .. msg)
    end
end

function GQ.Me()
    return UnitName("player")
end

function GQ.Channel()
    if GetNumRaidMembers() > 0 then return "RAID" end
    if GetNumPartyMembers() > 0 then return "PARTY" end
    return nil
end

-- ---------------------------------------------------------------------------------------------
-- Reading our own quest log
-- ---------------------------------------------------------------------------------------------

-- Objective text arrives as "<name>: <have>/<need>" for items and objects, and
-- "<name> slain: <have>/<need>" for monsters. The word between the name and the
-- colon is localised, so rather than hardcoding "slain" it's derived from the
-- client's own QUEST_MONSTERS_KILLED format string. Getting this right matters
-- because the name is what we match a hovered mob against: "Mottled Boar slain"
-- would never match "Mottled Boar".
local monsterSuffix = ""
do
    local fmt = QUEST_MONSTERS_KILLED or "%s slain: %d/%d"
    local _, _, suffix = string.find(fmt, "^%%s(.-):")
    monsterSuffix = suffix or ""
end

function GQ.ParseObjective(text, objType)
    if not text then return nil end
    local _, _, name, have, need = string.find(text, "^(.+): (%d+)/(%d+)$")
    if not name then return nil end

    if objType == "monster" and monsterSuffix ~= "" then
        local cut = string.len(name) - string.len(monsterSuffix)
        if cut > 0 and string.sub(name, cut + 1) == monsterSuffix then
            name = string.sub(name, 1, cut)
        end
    end

    return name, tonumber(have), tonumber(need)
end

-- Returns { [questTitle] = { {name=, have=, need=}, ... } }.
--
-- See the header note: SelectQuestLogEntry is global state shared with the
-- default UI and with SetAbandonQuest(). Save it, restore it, no exceptions.
function GQ.ScanQuestLog()
    local originalSelection = GetQuestLogSelection()
    local quests = {}

    for i = 1, GetNumQuestLogEntries() do
        local title, _, _, isHeader = GetQuestLogTitle(i)
        if not isHeader and title then
            SelectQuestLogEntry(i)
            local objectives = {}
            for j = 1, GetNumQuestLeaderBoards() do
                local text, objType = GetQuestLogLeaderBoard(j)
                local name, have, need = GQ.ParseObjective(text, objType)
                if name then
                    table.insert(objectives, { name = name, have = have, need = need })
                end
            end
            if table.getn(objectives) > 0 then
                quests[title] = objectives
            end
        end
    end

    if originalSelection then
        SelectQuestLogEntry(originalSelection)
    end
    return quests
end

function GQ.UpdateOwnData()
    local me = GQ.Me()
    if not me then return end
    GQ.data[me] = { time = time(), quests = GQ.ScanQuestLog() }
    GQ.dirty = true
end

-- ---------------------------------------------------------------------------------------------
-- Wire format
-- ---------------------------------------------------------------------------------------------
-- "Quest Title=Objective:3/10;Other:1/5!Second Quest=..."
--
-- Separators are '!', '=' and ';' because none of them occur in vanilla quest,
-- mob or item names, which do contain spaces, apostrophes, commas and hyphens.
-- A pipe would have been the obvious choice and is exactly wrong: it's WoW's
-- escape character for |c/|r/|H and the chat pipeline mangles it.
function GQ.Serialize(quests)
    local parts = {}
    for title, objectives in pairs(quests) do
        local objParts = {}
        for _, o in ipairs(objectives) do
            table.insert(objParts, o.name .. ":" .. o.have .. "/" .. o.need)
        end
        table.insert(parts, title .. "=" .. table.concat(objParts, ";"))
    end
    return table.concat(parts, "!")
end

function GQ.Deserialize(str)
    local quests = {}
    for block in string.gfind(str or "", "[^!]+") do
        local _, _, title, rest = string.find(block, "^([^=]+)=(.*)$")
        if title then
            local objectives = {}
            for chunk in string.gfind(rest, "[^;]+") do
                local _, _, name, have, need = string.find(chunk, "^(.+):(%d+)/(%d+)$")
                if name then
                    table.insert(objectives, {
                        name = name, have = tonumber(have), need = tonumber(need),
                    })
                end
            end
            quests[title] = objectives
        end
    end
    return quests
end

function GQ.Queue(msg)
    table.insert(GQ.sendQueue, msg)
end

function GQ.DrainQueue()
    local msg = table.remove(GQ.sendQueue, 1)
    if not msg then return end
    local channel = GQ.Channel()
    if not channel then
        GQ.sendQueue = {}
        return
    end
    local ok, err = pcall(SendAddonMessage, GQ.PREFIX, msg, channel)
    GQ.stats.sent = GQ.stats.sent + 1
    if not ok then
        GQ.Say("|cFFFF5179SendAddonMessage failed:|r " .. tostring(err))
    else
        GQ.Debug("sent [" .. channel .. "] " .. string.sub(msg, 1, 60))
    end
end

-- A few bytes saying "someone here is running this addon". It exists so the
-- group roster can distinguish "they haven't installed it" from "it's installed
-- and something is broken" - without it, both look identical from the outside,
-- which is exactly the hole this addon fell into on first contact.
function GQ.SendPresence()
    if not GQ.Channel() then return end
    GQ.Queue("P~" .. GQ.Me())
end

function GQ.SendProgress()
    local channel = GQ.Channel()
    if not channel then return end

    local me = GQ.Me()
    local own = GQ.data[me]
    if not own then return end

    local payload = GQ.Serialize(own.quests)
    local total = math.ceil(string.len(payload) / GQ.MAX_PAYLOAD)
    if total < 1 then total = 1 end

    local nonce = math.random(100000, 999999)
    GQ.Queue("H~" .. nonce .. "~" .. total)
    for i = 1, total do
        local from = (i - 1) * GQ.MAX_PAYLOAD + 1
        GQ.Queue("D~" .. nonce .. "~" .. i .. "~" ..
            string.sub(payload, from, from + GQ.MAX_PAYLOAD - 1))
    end
    GQ.dirty = false
    GQ.Debug("sending " .. total .. " chunk(s), " .. string.len(payload) .. " chars")
end

-- ---------------------------------------------------------------------------------------------
-- Receiving
-- ---------------------------------------------------------------------------------------------
function GQ.OnAddonMessage(msg, sender)
    if sender == GQ.Me() then return end
    GQ.stats.received = GQ.stats.received + 1
    GQ.Debug("recv from " .. tostring(sender) .. ": " .. string.sub(msg, 1, 60))

    local _, _, kind, rest = string.find(msg, "^(%a)~(.+)$")
    if not kind then
        GQ.Debug("  unparseable - the message was altered in transit")
        return
    end

    -- Anything we hear from them proves they're running this.
    GQ.present[sender] = time()

    if kind == "P" then
        -- Answer a beacon with our progress, so a newcomer gets data at once
        -- instead of waiting for our next quest update. Deliberately NOT another
        -- beacon: two clients answering each other's beacons forever is a loop.
        GQ.Debug("  " .. sender .. " is running Questshare")
        GQ.SendProgress()
        return
    end

    if kind == "H" then
        local _, _, nonce, total = string.find(rest, "^(%d+)~(%d+)$")
        if not nonce then return end
        GQ.incoming[sender] = { nonce = nonce, expected = tonumber(total), chunks = {} }

    elseif kind == "D" then
        local _, _, nonce, index, data = string.find(rest, "^(%d+)~(%d+)~(.*)$")
        if not nonce then return end
        local pending = GQ.incoming[sender]
        if not pending or pending.nonce ~= nonce then return end

        pending.chunks[tonumber(index)] = data or ""

        local have = 0
        for _ in pairs(pending.chunks) do have = have + 1 end
        if have < pending.expected then return end

        local joined = ""
        for i = 1, pending.expected do joined = joined .. (pending.chunks[i] or "") end

        GQ.data[sender] = { time = time(), quests = GQ.Deserialize(joined) }
        GQ.incoming[sender] = nil
        GQ.Debug("got progress from " .. sender)
    end
end

-- ---------------------------------------------------------------------------------------------
-- Tooltips
-- ---------------------------------------------------------------------------------------------

-- Everyone currently in the group, you first, then alphabetically - so the
-- comparison you're actually making reads left to right without hunting.
local function OrderedNames()
    local me = GQ.Me()
    local names = {}
    for name in pairs(GQ.data) do
        if name ~= me then table.insert(names, name) end
    end
    table.sort(names)
    if GQ.data[me] then table.insert(names, 1, me) end
    return names
end

local function IsInMyGroup(name)
    if name == GQ.Me() then return true end
    for i = 1, GetNumRaidMembers() do
        if UnitName("raid" .. i) == name then return true end
    end
    for i = 1, GetNumPartyMembers() do
        if UnitName("party" .. i) == name then return true end
    end
    return false
end

-- Finds every quest where SOMEONE has an objective matching `target`, and
-- returns lines ready to add to a tooltip. Matching is by objective name against
-- the hovered mob or item name, case-insensitively.
function GQ.LinesFor(target)
    if not target or target == "" then return {} end
    local wanted = string.lower(target)

    -- Collect per quest so one line covers everyone, rather than one line each.
    local order, byQuest = {}, {}
    for _, name in ipairs(OrderedNames()) do
        local entry = GQ.data[name]
        if entry and IsInMyGroup(name) then
            for title, objectives in pairs(entry.quests) do
                for _, o in ipairs(objectives) do
                    if string.lower(o.name) == wanted then
                        if not byQuest[title] then
                            byQuest[title] = {}
                            table.insert(order, title)
                        end
                        table.insert(byQuest[title], {
                            who = name, have = o.have, need = o.need,
                        })
                    end
                end
            end
        end
    end

    table.sort(order)
    local lines = {}
    for _, title in ipairs(order) do
        local parts = {}
        for _, p in ipairs(byQuest[title]) do
            local who = (p.who == GQ.Me()) and "you" or p.who
            if p.have >= p.need then
                table.insert(parts, "|cFF66FF66" .. who .. " done|r")
            else
                table.insert(parts, who .. " " .. p.have .. "/" .. p.need)
            end
        end
        table.insert(lines, { title = title, detail = table.concat(parts, "  -  ") })
    end
    return lines
end

-- A one-line summary of somebody's standing on a quest: the raw count when
-- there's a single objective, or how many objectives are finished when there
-- are several, since "2/5" would be ambiguous between the two.
function GQ.SummarizeQuest(objectives)
    local total = table.getn(objectives)
    if total == 0 then return "?" end
    if total == 1 then
        local o = objectives[1]
        if o.have >= o.need then return "done" end
        return o.have .. "/" .. o.need
    end
    local done = 0
    for _, o in ipairs(objectives) do
        if o.have >= o.need then done = done + 1 end
    end
    if done >= total then return "done" end
    return done .. "/" .. total .. " objectives"
end

-- Every quest anyone in the group is on, and where each of them stands. Sorted
-- so the shared ones come first, because "are we on the same quest" is the
-- question this answers and a wall of solo quests buries it.
function GQ.QuestOverview()
    local me = GQ.Me()
    local titles, seen = {}, {}

    for _, name in ipairs(OrderedNames()) do
        if IsInMyGroup(name) then
            for title in pairs(GQ.data[name].quests) do
                if not seen[title] then
                    seen[title] = true
                    table.insert(titles, title)
                end
            end
        end
    end
    table.sort(titles)

    local rows = {}
    for _, title in ipairs(titles) do
        local who, mine = {}, false
        for _, name in ipairs(OrderedNames()) do
            if IsInMyGroup(name) then
                local objectives = GQ.data[name].quests[title]
                if objectives then
                    if name == me then mine = true end
                    table.insert(who, {
                        name = name,
                        summary = GQ.SummarizeQuest(objectives),
                    })
                end
            end
        end
        table.insert(rows, { title = title, who = who, mine = mine, shared = table.getn(who) > 1 })
    end

    table.sort(rows, function(a, b)
        if a.shared ~= b.shared then return a.shared end
        if a.mine ~= b.mine then return a.mine end
        return a.title < b.title
    end)
    return rows
end

local function AddLines(tooltip, target)
    local lines = GQ.LinesFor(target)
    if table.getn(lines) == 0 then return end
    for _, line in ipairs(lines) do
        tooltip:AddLine(line.title, 1, 0.82, 0)
        tooltip:AddLine("  " .. line.detail, 1, 1, 1)
    end
    tooltip:Show()
end


-- The tooltip's first line is the NAME of whatever it's showing - a mob, an
-- item in a bag, a loot slot, a chat link - so reading it covers every case with
-- one hook instead of one hook per Set* method, and can't double up by firing
-- through two paths at once. This is what pfQuest, ItemRack and pfExtend all do
-- on this client.
--
-- The obvious-looking GameTooltip:GetUnit() does NOT exist in 1.12 - it's a
-- later-expansion API, and calling it threw on every single tooltip.
local function TooltipSubject(tooltip)
    local name = tooltip:GetName()
    if not name then return nil end
    local left = getglobal(name .. "TextLeft1")
    return left and left:GetText() or nil
end

local function HookOne(tooltip)
    if not tooltip then return end
    local origOnShow = tooltip:GetScript("OnShow")
    tooltip:SetScript("OnShow", function()
        if origOnShow then pcall(origOnShow) end
        AddLines(this or tooltip, TooltipSubject(this or tooltip))
    end)
end

-- Who else in the group is on `title`, and where they stand. Excludes you: the
-- quest log is already showing your own progress right there.
function GQ.WhoIsOn(title)
    local me, others = GQ.Me(), {}
    for _, name in ipairs(OrderedNames()) do
        if name ~= me and IsInMyGroup(name) then
            local objectives = GQ.data[name].quests[title]
            if objectives then
                table.insert(others, { name = name, summary = GQ.SummarizeQuest(objectives) })
            end
        end
    end
    return others
end

-- Is anyone at all sharing with us right now? Used to stay silent rather than
-- announce "nobody else has this" on every quest when the truth is simply that
-- nobody is sharing.
local function AnyoneSharing()
    local me = GQ.Me()
    for name in pairs(GQ.data) do
        if name ~= me and IsInMyGroup(name) then return true end
    end
    return false
end

-- Hovering a row in the quest log. The button's ID is the quest log index (the
-- default UI sets it in QuestLog_Update), so the title comes from
-- GetQuestLogTitle(index) - which takes an index and therefore does NOT touch
-- the global quest selection. That matters here of all places: mangling the
-- selection while the player is moused over their quest log is precisely how
-- the wrong quest gets abandoned.
function GQ.ShowQuestLogTooltip(button)
    local index = button:GetID()
    if not index or index < 1 then return end

    local title, _, _, isHeader = GetQuestLogTitle(index)
    if not title or isHeader then return end
    if not AnyoneSharing() then return end

    local others = GQ.WhoIsOn(title)

    -- The default handler only shows a tooltip when the title is truncated, so
    -- there may be nothing on screen to append to yet.
    if not GameTooltip:IsShown() then
        GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
        GameTooltip:SetText(title, 1, 0.82, 0)
    end

    if table.getn(others) == 0 then
        GameTooltip:AddLine("nobody else in your group has this", 0.6, 0.6, 0.6)
    else
        GameTooltip:AddLine("also on this quest:", 0.6, 0.6, 0.6)
        for _, o in ipairs(others) do
            if o.summary == "done" then
                GameTooltip:AddLine("  " .. o.name .. " - done", 0.4, 1, 0.4)
            else
                GameTooltip:AddLine("  " .. o.name .. " - " .. o.summary, 1, 1, 1)
            end
        end
    end
    GameTooltip:Show()
end

-- Hooked lazily and idempotently: the buttons exist from the start, but another
-- addon may rebuild the quest log, and re-running this simply skips what's
-- already hooked.
function GQ.HookQuestLog()
    local i = 1
    while true do
        local button = getglobal("QuestLogTitle" .. i)
        if not button then break end
        if not button.gqHooked then
            button.gqHooked = true
            local origEnter = button:GetScript("OnEnter")
            button:SetScript("OnEnter", function()
                if origEnter then pcall(origEnter) end
                pcall(GQ.ShowQuestLogTooltip, this)
            end)
            local origLeave = button:GetScript("OnLeave")
            button:SetScript("OnLeave", function()
                if origLeave then pcall(origLeave) end
                GameTooltip:Hide()
            end)
        end
        i = i + 1
    end
end

function GQ.HookTooltips()
    HookOne(GameTooltip)
    HookOne(ItemRefTooltip) -- links clicked in chat
    GQ.HookQuestLog()
end

-- ---------------------------------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------------------------------
SLASH_GRAYFATHERSQUESTSHARE1 = "/gq"
SLASH_GRAYFATHERSQUESTSHARE2 = "/questshare"
SlashCmdList["GRAYFATHERSQUESTSHARE"] = function(msg)
    local words = {}
    for word in string.gfind(msg or "", "[^%s]+") do table.insert(words, word) end
    local cmd = string.lower(words[1] or "")

    if cmd == "debug" then
        GQ.config.debug = not GQ.config.debug
        GQ_Config = GQ.config
        GQ.Say("debug: " .. (GQ.config.debug and "|cFF00FF7Fon|r" or "|cFFFF5179off|r"))

    elseif cmd == "quests" or cmd == "common" then
        local rows = GQ.QuestOverview()
        if table.getn(rows) == 0 then
            GQ.Say("no quest data yet - see |cFFFFFFFF/gq|r for whether anyone is sharing.")
        else
            local sharedCount = 0
            for _, row in ipairs(rows) do
                if row.shared then sharedCount = sharedCount + 1 end
            end
            GQ.Say(sharedCount .. " quest(s) in common with your group:")

            for _, row in ipairs(rows) do
                local parts = {}
                for _, w in ipairs(row.who) do
                    local label = (w.name == GQ.Me()) and "you" or w.name
                    if w.summary == "done" then
                        table.insert(parts, "|cFF66FF66" .. label .. " done|r")
                    else
                        table.insert(parts, label .. " " .. w.summary)
                    end
                end
                -- Shared quests in gold, everything else dimmed: the point of the
                -- list is what you have in common, not a full inventory of
                -- everyone's log.
                local colour = row.shared and "|cFFFFCC00" or "|cFF888888"
                GQ.Say("  " .. colour .. row.title .. "|r - " .. table.concat(parts, ", "))
            end
        end

    elseif cmd == "sync" then
        if not GQ.Channel() then
            GQ.Say("you're not in a party or raid - there's nobody to share with.")
        else
            GQ.UpdateOwnData()
            GQ.SendPresence()
            GQ.SendProgress()
            GQ.Say("sharing your quest progress...")
        end

    elseif cmd == "" then
        local channel = GQ.Channel()
        GQ.Say("group: " .. (channel and ("|cFF00FF7F" .. channel .. "|r") or
            "|cFFFF5179solo|r - nothing is shared until you're in a party"))
        GQ.Say("sent " .. GQ.stats.sent .. ", received " .. GQ.stats.received .. " this session")

        -- Walk the actual group rather than only what we've received, so
        -- somebody who hasn't answered is visibly present-but-silent rather than
        -- simply missing. That difference is the whole diagnosis.
        local roster = {}
        for i = 1, GetNumRaidMembers() do
            local n = UnitName("raid" .. i)
            if n and n ~= GQ.Me() then table.insert(roster, n) end
        end
        for i = 1, GetNumPartyMembers() do
            local n = UnitName("party" .. i)
            if n and n ~= GQ.Me() then table.insert(roster, n) end
        end

        local me = GQ.Me()
        local own = GQ.data[me]
        local ownCount = 0
        if own then for _ in pairs(own.quests) do ownCount = ownCount + 1 end end
        GQ.Say("  |cFF00FF7F" .. tostring(me) .. " (you)|r - " .. ownCount ..
            " quest(s) with counted objectives")

        local silent = 0
        for _, name in ipairs(roster) do
            local entry = GQ.data[name]
            if entry then
                local n = 0
                for _ in pairs(entry.quests) do n = n + 1 end
                GQ.Say("  " .. name .. " - |cFF00FF7F" .. n .. " quest(s) shared|r")
            elseif GQ.present[name] then
                GQ.Say("  " .. name .. " - |cFFFFCC00has the addon, no progress yet|r")
            else
                GQ.Say("  " .. name .. " - |cFFFF5179silent|r (no addon, or not reaching us)")
                silent = silent + 1
            end
        end

        if table.getn(roster) == 0 then
            GQ.Say("nobody else in the group.")
        elseif silent > 0 and GQ.stats.received == 0 then
            GQ.Say("|cFFFF5179Nothing has been received at all this session.|r If they do have " ..
                "it running, try |cFFFFFFFF/gq debug|r on both and |cFFFFFFFF/gq sync|r on one.")
        end

    else
        GQ.Say("usage: /gq, /gq quests, /gq sync, /gq debug")
    end
end

-- ---------------------------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("QUEST_LOG_UPDATE")
ev:RegisterEvent("PARTY_MEMBERS_CHANGED")
ev:RegisterEvent("RAID_ROSTER_UPDATE")
ev:RegisterEvent("CHAT_MSG_ADDON")

ev:SetScript("OnEvent", function()
    if event == "ADDON_LOADED" then
        if arg1 ~= GQ.ADDON_NAME then return end
        GQ.config = GQ_Config or {}
        GQ.HookTooltips()

    elseif event == "CHAT_MSG_ADDON" then
        if arg1 == GQ.PREFIX then GQ.OnAddonMessage(arg2, arg4) end

    elseif event == "QUEST_LOG_UPDATE" then
        -- Debounced: this fires repeatedly for a single kill.
        GQ.scanTimer = GQ.SCAN_DEBOUNCE
        -- Cheap and idempotent: catches quest log rows built or replaced after
        -- we first hooked, without needing to know which addon did it.
        GQ.HookQuestLog()

    elseif event == "PLAYER_ENTERING_WORLD" then
        GQ.scanTimer = GQ.SCAN_DEBOUNCE

    else -- group changed
        -- Someone joined or left: re-share, and drop anyone no longer with us so
        -- their numbers can't linger on a tooltip.
        for name in pairs(GQ.data) do
            if name ~= GQ.Me() and not IsInMyGroup(name) then GQ.data[name] = nil end
        end
        GQ.dirty = true
        GQ.scanTimer = GQ.SCAN_DEBOUNCE
        GQ.presenceTimer = GQ.PRESENCE_INTERVAL -- beacon on the next tick
    end
end)

ev:SetScript("OnUpdate", function()
    local elapsed = arg1

    if GQ.scanTimer then
        GQ.scanTimer = GQ.scanTimer - elapsed
        if GQ.scanTimer <= 0 then
            GQ.scanTimer = nil
            GQ.UpdateOwnData()
            if GQ.dirty and GQ.Channel() then GQ.SendProgress() end
        end
    end

    GQ.sendTimer = GQ.sendTimer + elapsed
    if GQ.sendTimer >= GQ.SEND_INTERVAL then
        GQ.sendTimer = 0
        GQ.DrainQueue()
    end

    GQ.presenceTimer = GQ.presenceTimer + elapsed
    if GQ.presenceTimer >= GQ.PRESENCE_INTERVAL then
        GQ.presenceTimer = 0
        GQ.SendPresence()
    end
end)
