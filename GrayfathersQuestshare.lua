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
GQ.VERSION    = "1.0.0"

-- [playerName] = { time = <when heard>, quests = { [questTitle] = { {name, have, need}, ... } } }
GQ.data   = {}
GQ.config = {}

GQ.MAX_PAYLOAD     = 200
GQ.SEND_INTERVAL   = 0.4
GQ.SCAN_DEBOUNCE   = 1.5
GQ.PEER_STALE_AFTER = 300 -- drop someone's progress 5 minutes after their last update

GQ.sendQueue = {}
GQ.sendTimer = 0
GQ.scanTimer = nil
GQ.incoming  = {}
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
    pcall(SendAddonMessage, GQ.PREFIX, msg, channel)
    GQ.stats.sent = GQ.stats.sent + 1
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

    local _, _, kind, rest = string.find(msg, "^(%a)~(.+)$")
    if not kind then return end

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

local function AddLines(tooltip, target)
    local lines = GQ.LinesFor(target)
    if table.getn(lines) == 0 then return end
    for _, line in ipairs(lines) do
        tooltip:AddLine(line.title, 1, 0.82, 0)
        tooltip:AddLine("  " .. line.detail, 1, 1, 1)
    end
    tooltip:Show()
end

local function ItemNameFromLink(link)
    if not link then return nil end
    local _, _, name = string.find(link, "%[(.-)%]")
    return name
end

function GQ.HookTooltips()
    -- Units: GetUnit() tells us whether this tooltip is actually showing a unit,
    -- which is cleaner than guessing from "mouseover" and works for any unit the
    -- tooltip was pointed at.
    local origOnShow = GameTooltip:GetScript("OnShow")
    GameTooltip:SetScript("OnShow", function()
        if origOnShow then pcall(origOnShow) end
        local name = GameTooltip:GetUnit()
        if name then AddLines(GameTooltip, name) end
    end)

    local origSetBagItem = GameTooltip.SetBagItem
    GameTooltip.SetBagItem = function(self, bag, slot)
        local ret = origSetBagItem(self, bag, slot)
        AddLines(self, ItemNameFromLink(GetContainerItemLink(bag, slot)))
        return ret
    end

    local origSetLootItem = GameTooltip.SetLootItem
    if origSetLootItem then
        GameTooltip.SetLootItem = function(self, slot)
            local ret = origSetLootItem(self, slot)
            AddLines(self, ItemNameFromLink(GetLootSlotLink(slot)))
            return ret
        end
    end

    local origSetHyperlink = GameTooltip.SetHyperlink
    GameTooltip.SetHyperlink = function(self, link, count)
        local ret = origSetHyperlink(self, link, count)
        AddLines(self, ItemNameFromLink(link))
        return ret
    end
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

    elseif cmd == "sync" then
        if not GQ.Channel() then
            GQ.Say("you're not in a party or raid - there's nobody to share with.")
        else
            GQ.UpdateOwnData()
            GQ.SendProgress()
            GQ.Say("sharing your quest progress...")
        end

    elseif cmd == "" then
        local channel = GQ.Channel()
        GQ.Say("group: " .. (channel and ("|cFF00FF7F" .. channel .. "|r") or
            "|cFFFF5179solo|r - nothing is shared until you're in a party"))
        GQ.Say("sent " .. GQ.stats.sent .. ", received " .. GQ.stats.received .. " this session")

        local any = false
        for _, name in ipairs(OrderedNames()) do
            local entry = GQ.data[name]
            local n = 0
            for _ in pairs(entry.quests) do n = n + 1 end
            local age = entry.time and math.floor((time() - entry.time) / 60) or 0
            GQ.Say("  " .. (name == GQ.Me() and ("|cFF00FF7F" .. name .. " (you)|r") or name) ..
                " - " .. n .. " quest(s) with objectives, " .. age .. "m ago")
            any = true
        end
        if not any then
            GQ.Say("nobody's progress yet. Party members need this addon too.")
        end

    else
        GQ.Say("usage: /gq, /gq sync, /gq debug")
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
end)
