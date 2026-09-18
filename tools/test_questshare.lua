--[[
    test_questshare.lua - two simulated clients share quest progress.

    Usage (from the repo root):
        lua tools/test_questshare.lua [path/to/addon.lua]

    The first test in here is the important one. Scanning the quest log requires
    SelectQuestLogEntry, which is global state shared with the default quest log
    UI and with SetAbandonQuest(). An addon that leaves the selection moved makes
    the player abandon the WRONG quest - silently, because the UI keeps showing
    the row they clicked. That exact bug was found in another addon on this
    install, so it gets a regression test here rather than a comment and good
    intentions.
--]]

local Stub = dofile("tools/wow_stub.lua")
local ADDON_PATH = arg[1] or "GrayfathersQuestshare.lua"

local failures, checks = 0, 0
local function check(label, got, want)
    checks = checks + 1
    if got ~= want then
        failures = failures + 1
        print("  FAIL " .. label .. ": got " .. tostring(got) .. ", wanted " .. tostring(want))
    end
end

-- A mock quest log. Each entry is a header or a quest with objectives, and the
-- objective text is built exactly as the client formats it.
local function installQuestLog(log, state)
    QUEST_MONSTERS_KILLED = "%s slain: %d/%d"

    GetNumQuestLogEntries = function() return table.getn(log) end
    GetQuestLogTitle = function(i)
        local q = log[i]
        if not q then return nil end
        return q.title, q.level or 1, nil, q.isHeader, nil, q.complete
    end
    GetQuestLogSelection = function() return state.selected end
    SelectQuestLogEntry = function(i) state.selected = i end
    GetNumQuestLeaderBoards = function()
        local q = log[state.selected]
        return (q and q.objectives) and table.getn(q.objectives) or 0
    end
    GetQuestLogLeaderBoard = function(j)
        local q = log[state.selected]
        local o = q and q.objectives and q.objectives[j]
        if not o then return nil end
        local text
        if o.kind == "monster" then
            text = o.name .. " slain: " .. o.have .. "/" .. o.need
        else
            text = o.name .. ": " .. o.have .. "/" .. o.need
        end
        return text, o.kind, (o.have >= o.need) and 1 or nil
    end
end

local function newClient(charName, log, party)
    Stub.Reset()
    Stub.SetRoster({ player = charName, party = party or {} })
    GetRealmName = function() return "N'Zoth" end
    GetNumPartyMembers = function() return table.getn(party or {}) end
    GetNumRaidMembers = function() return 0 end
    time = os.time
    GameTooltip = Stub.CreateFrame("Frame", "GameTooltip")
    GetContainerItemLink = function() return nil end
    GetLootSlotLink = function() return nil end

    local state = { selected = 0 }
    installQuestLog(log, state)

    local sent = {}
    SendAddonMessage = function(prefix, msg, channel)
        table.insert(sent, { prefix = prefix, msg = msg, channel = channel })
    end

    GQ = nil
    dofile(ADDON_PATH)
    GQ.config = {}
    return { GQ = GQ, sent = sent, name = charName, state = state, log = log, party = party or {} }
end

local function activate(client)
    GQ = client.GQ
    UnitName = function(unit)
        if unit == "player" then return client.name end
        local _, _, idx = string.find(unit or "", "^party(%d+)$")
        if idx then return client.party[tonumber(idx)] end
        return nil
    end
    GetNumPartyMembers = function() return table.getn(client.party) end
    GetNumRaidMembers = function() return 0 end
    SendAddonMessage = function(prefix, msg, channel)
        table.insert(client.sent, { prefix = prefix, msg = msg, channel = channel })
    end
    installQuestLog(client.log, client.state)
end

local function deliver(from, to)
    activate(from)
    while table.getn(from.GQ.sendQueue) > 0 do from.GQ.DrainQueue() end
    local messages = from.sent
    from.sent = {}
    for _, m in ipairs(messages) do
        activate(to)
        to.GQ.OnAddonMessage(m.msg, from.name)
    end
    return table.getn(messages)
end

local ALICE_LOG = {
    { title = "Elwynn", isHeader = true },
    { title = "Kill Ten Boars", objectives = {
        { kind = "monster", name = "Mottled Boar", have = 3, need = 10 },
    } },
    { title = "Gather Hides", objectives = {
        { kind = "item", name = "Boar Hide", have = 2, need = 5 },
        { kind = "item", name = "Tough Leather", have = 0, need = 4 },
    } },
}

-- ---------------------------------------------------------------------------
print("scanning the quest log RESTORES the selection (wrong-quest-abandon guard)")
do
    local a = newClient("Alice", ALICE_LOG)
    activate(a)

    -- The player has quest 2 selected in their log.
    SelectQuestLogEntry(2)
    check("selection starts where the player put it", a.state.selected, 2)

    a.GQ.ScanQuestLog()
    check("selection is exactly where it was after a scan", a.state.selected, 2)

    -- And from "nothing selected", which is its own valid state.
    SelectQuestLogEntry(0)
    a.GQ.ScanQuestLog()
    check("no selection stays no selection", a.state.selected, 0)
end

-- ---------------------------------------------------------------------------
print("objectives are parsed, with the localised kill suffix stripped")
do
    local a = newClient("Alice", ALICE_LOG)
    activate(a)
    local quests = a.GQ.ScanQuestLog()

    check("headers are skipped", quests["Elwynn"], nil)
    check("kill quest found", quests["Kill Ten Boars"] ~= nil, true)
    -- "Mottled Boar slain" would never match a hovered "Mottled Boar".
    check("  mob name has no 'slain' suffix", quests["Kill Ten Boars"][1].name, "Mottled Boar")
    check("  progress", quests["Kill Ten Boars"][1].have, 3)
    check("  needed", quests["Kill Ten Boars"][1].need, 10)
    check("item quest has both objectives", table.getn(quests["Gather Hides"]), 2)
    check("  item name", quests["Gather Hides"][1].name, "Boar Hide")
end

-- ---------------------------------------------------------------------------
print("the wire format round-trips names with spaces and apostrophes")
do
    local a = newClient("Alice", ALICE_LOG)
    activate(a)
    local quests = {
        ["Ma'ruk Wyrmscale's Request"] = {
            { name = "Okna's Tough Hide", have = 1, need = 3 },
            { name = "Silverwing Sentinel", have = 12, need = 12 },
        },
    }
    local round = a.GQ.Deserialize(a.GQ.Serialize(quests))
    check("quest title survives", round["Ma'ruk Wyrmscale's Request"] ~= nil, true)
    check("  objective with apostrophe", round["Ma'ruk Wyrmscale's Request"][1].name, "Okna's Tough Hide")
    check("  its progress", round["Ma'ruk Wyrmscale's Request"][1].have, 1)
    check("  second objective", round["Ma'ruk Wyrmscale's Request"][2].name, "Silverwing Sentinel")
end

-- ---------------------------------------------------------------------------
print("no message exceeds the 255-byte addon message limit")
do
    local big = {}
    for i = 1, 25 do
        table.insert(big, { title = "A Really Quite Long Quest Title Number " .. i, objectives = {
            { kind = "monster", name = "Some Long Creature Name " .. i, have = i, need = 30 },
        } })
    end
    local a = newClient("Alice", big, { "Bob" })
    activate(a)
    a.GQ.UpdateOwnData()
    a.GQ.SendProgress()
    while table.getn(a.GQ.sendQueue) > 0 do a.GQ.DrainQueue() end

    local longest = 0
    for _, m in ipairs(a.sent) do
        if string.len(m.msg) > longest then longest = string.len(m.msg) end
    end
    check("chunked (more than one message)", table.getn(a.sent) > 2, true)
    check("longest is under 255 (" .. longest .. ")", longest < 255, true)
end

-- ---------------------------------------------------------------------------
print("two party members exchange progress")
do
    local BOB_LOG = {
        { title = "Kill Ten Boars", objectives = {
            { kind = "monster", name = "Mottled Boar", have = 10, need = 10 },
        } },
        { title = "Gather Hides", objectives = {
            { kind = "item", name = "Boar Hide", have = 5, need = 5 },
        } },
    }
    local a = newClient("Alice", ALICE_LOG, { "Bob" })
    local b = newClient("Bob", BOB_LOG, { "Alice" })

    activate(a); a.GQ.UpdateOwnData(); a.GQ.SendProgress()
    deliver(a, b)
    activate(b); b.GQ.UpdateOwnData(); b.GQ.SendProgress()
    deliver(b, a)

    activate(a)
    check("Alice has Bob's progress", a.GQ.data["Bob"] ~= nil, true)
    check("  on the kill quest", a.GQ.data["Bob"]["quests"]["Kill Ten Boars"][1].have, 10)
end

-- ---------------------------------------------------------------------------
print("tooltip lines compare everyone on the hovered target")
do
    local a = newClient("Alice", ALICE_LOG, { "Bob" })
    activate(a)
    a.GQ.UpdateOwnData()
    a.GQ.data["Bob"] = { time = os.time(), quests = {
        ["Kill Ten Boars"] = { { name = "Mottled Boar", have = 10, need = 10 } },
    } }

    -- Your own progress is OFF by default: pfQuest already shows it on the same
    -- tooltip, so including it duplicates a number already on screen.
    local lines = a.GQ.LinesFor("Mottled Boar")
    check("one quest matched", table.getn(lines), 1)
    check("  titled", lines[1].title, "Kill Ten Boars")
    check("  only the other person by default", lines[1].detail, "|cFF66FF66Bob done|r")

    a.GQ.config.showSelf = true
    lines = a.GQ.LinesFor("Mottled Boar")
    check("  self on puts you back, first", lines[1].detail,
        "you 3/10  -  |cFF66FF66Bob done|r")
    a.GQ.config.showSelf = nil

    -- Case-insensitive, because tooltip capitalisation isn't guaranteed.
    check("case insensitive", table.getn(a.GQ.LinesFor("mottled boar")), 1)
    check("unrelated target matches nothing", table.getn(a.GQ.LinesFor("Kobold Miner")), 0)

    -- An item objective only you are on shows nothing by default, since your own
    -- line is what is being suppressed.
    check("an objective only you have is silent by default",
        table.getn(a.GQ.LinesFor("Boar Hide")), 0)

    a.GQ.config.showSelf = true
    local itemLines = a.GQ.LinesFor("Boar Hide")
    check("  and appears with self on", table.getn(itemLines), 1)
    check("  reading as yours", itemLines[1].detail, "you 2/5")
    a.GQ.config.showSelf = nil
end

-- ---------------------------------------------------------------------------
print("the tooltip hook actually runs (v1.0.0 shipped broken here)")
do
    -- v1.0.0 called GameTooltip:GetUnit(), which does not exist in 1.12, and
    -- threw on EVERY tooltip. The suite passed anyway because it only ever
    -- called LinesFor() directly and never fired the hook. So this test drives
    -- the real path: install the hooks, then show a tooltip.
    local a = newClient("Alice", ALICE_LOG, { "Bob" })
    activate(a)
    a.GQ.UpdateOwnData()
    a.GQ.data["Bob"] = { time = os.time(), quests = {
        ["Kill Ten Boars"] = { { name = "Mottled Boar", have = 10, need = 10 } },
    } }

    local added = {}
    GameTooltip = Stub.CreateFrame("Frame", "GameTooltip")
    GameTooltip.AddLine = function(self, text) table.insert(added, text) end
    GameTooltip.Show = function() end
    ItemRefTooltip = Stub.CreateFrame("Frame", "ItemRefTooltip")
    ItemRefTooltip.AddLine = function() end
    ItemRefTooltip.Show = function() end

    -- The tooltip's first line is the subject's name - that's what the addon
    -- reads, since 1.12 has no GetUnit().
    local left = Stub.CreateFrame("Frame", "GameTooltipTextLeft1")
    left:SetText("Mottled Boar")

    local ok, err = pcall(a.GQ.HookTooltips)
    check("hooking raises no error", ok, true)
    if not ok then print("      " .. tostring(err)) end

    local fired, fireErr = pcall(function()
        Stub.FireScript(GameTooltip, "OnShow")
    end)
    check("showing a tooltip raises no error", fired, true)
    if not fired then print("      " .. tostring(fireErr)) end

    check("two lines were added", table.getn(added), 2)
    check("  the quest title", added[1], "Kill Ten Boars")
    check("  and everyone else's progress", added[2], "  |cFF66FF66Bob done|r")

    -- A tooltip whose subject matches no objective must add nothing.
    added = {}
    left:SetText("Some Unrelated Critter")
    Stub.FireScript(GameTooltip, "OnShow")
    check("nothing added for an unrelated tooltip", table.getn(added), 0)
end

-- ---------------------------------------------------------------------------
print("the quest overview answers 'are we on the same quest'")
do
    local a = newClient("Alice", ALICE_LOG, { "Bob" })
    activate(a)
    a.GQ.UpdateOwnData()
    a.GQ.data["Bob"] = { time = os.time(), quests = {
        -- Shared with Alice.
        ["Kill Ten Boars"] = { { name = "Mottled Boar", have = 10, need = 10 } },
        -- Bob's alone.
        ["Deliver the Package"] = { { name = "Package", have = 0, need = 1 } },
    } }

    local rows = a.GQ.QuestOverview()
    check("every quest across the group", table.getn(rows), 3)

    -- Shared first: that's the question being answered.
    check("shared quest is listed first", rows[1].title, "Kill Ten Boars")
    check("  and is marked shared", rows[1].shared, true)
    check("  with both people", table.getn(rows[1].who), 2)
    check("  you first", rows[1].who[1].name, "Alice")
    check("  your standing", rows[1].who[1].summary, "3/10")
    check("  and Bob's", rows[1].who[2].summary, "done")

    -- Then yours, then theirs.
    check("your own quest next", rows[2].title, "Gather Hides")
    check("  not marked shared", rows[2].shared, false)
    check("their solo quest last", rows[3].title, "Deliver the Package")
    check("  and is theirs, not yours", rows[3].mine, false)
end

-- ---------------------------------------------------------------------------
print("a multi-objective quest summarises as objectives done, not a raw count")
do
    local a = newClient("Alice", ALICE_LOG, { "Bob" })
    activate(a)
    -- "Gather Hides" has two objectives: 2/5 and 0/4. Reporting "2/5" would
    -- read as though the quest were 40% done.
    check("two objectives, none finished", a.GQ.SummarizeQuest({
        { name = "Boar Hide", have = 2, need = 5 },
        { name = "Tough Leather", have = 0, need = 4 },
    }), "0/2 objectives")
    check("one of two finished", a.GQ.SummarizeQuest({
        { name = "Boar Hide", have = 5, need = 5 },
        { name = "Tough Leather", have = 1, need = 4 },
    }), "1/2 objectives")
    check("all finished reads plainly", a.GQ.SummarizeQuest({
        { name = "Boar Hide", have = 5, need = 5 },
        { name = "Tough Leather", have = 4, need = 4 },
    }), "done")
    check("a single objective keeps its real count", a.GQ.SummarizeQuest({
        { name = "Mottled Boar", have = 3, need = 10 },
    }), "3/10")
end

-- ---------------------------------------------------------------------------
print("hovering a quest log row shows who else is on it")
do
    local a = newClient("Alice", ALICE_LOG, { "Bob" })
    activate(a)
    a.GQ.UpdateOwnData()
    a.GQ.data["Bob"] = { time = os.time(), quests = {
        ["Kill Ten Boars"] = { { name = "Mottled Boar", have = 10, need = 10 } },
    } }

    local added, shown = {}, false
    GameTooltip = Stub.CreateFrame("Frame", "GameTooltip")
    GameTooltip.AddLine = function(self, text) table.insert(added, text) end
    GameTooltip.SetText = function(self, text) table.insert(added, text) end
    GameTooltip.SetOwner = function() end
    GameTooltip.IsShown = function() return false end
    GameTooltip.Show = function() shown = true end
    GameTooltip.Hide = function() end

    -- The quest log rows: the default UI sets each button's ID to the quest
    -- index, which is how we know which quest is being hovered.
    local row = Stub.CreateFrame("Button", "QuestLogTitle1")
    row.GetID = function() return 2 end -- ALICE_LOG[2] = "Kill Ten Boars"
    local header = Stub.CreateFrame("Button", "QuestLogTitle2")
    header.GetID = function() return 1 end -- ALICE_LOG[1] is a header

    local ok, err = pcall(a.GQ.HookQuestLog)
    check("hooking the quest log raises no error", ok, true)
    if not ok then print("      " .. tostring(err)) end

    local fired, ferr = pcall(function() Stub.FireScript(row, "OnEnter") end)
    check("hovering a row raises no error", fired, true)
    if not fired then print("      " .. tostring(ferr)) end
    check("the tooltip was shown", shown, true)
    check("titled with the quest", added[1], "Kill Ten Boars")
    check("  a heading", added[2], "also on this quest:")
    check("  and Bob's standing", added[3], "  Bob - done")

    -- A quest only you are on should say so rather than leave you guessing.
    added, shown = {}, false
    row.GetID = function() return 3 end -- "Gather Hides", Alice only
    Stub.FireScript(row, "OnEnter")
    check("solo quest says nobody else has it", added[2], "nobody else in your group has this")

    -- Headers are not quests.
    added, shown = {}, false
    Stub.FireScript(header, "OnEnter")
    check("headers show nothing", table.getn(added), 0)

    -- And with nobody sharing at all, stay silent rather than announcing
    -- "nobody else has this" on every single quest.
    a.GQ.data["Bob"] = nil
    added, shown = {}, false
    row.GetID = function() return 2 end
    Stub.FireScript(row, "OnEnter")
    check("silent when nobody is sharing", table.getn(added), 0)
end

-- ---------------------------------------------------------------------------
print("someone who left the group stops appearing")
do
    local a = newClient("Alice", ALICE_LOG, { "Bob" })
    activate(a)
    a.GQ.UpdateOwnData()
    a.GQ.data["Cara"] = { time = os.time(), quests = {
        ["Kill Ten Boars"] = { { name = "Mottled Boar", have = 5, need = 10 } },
    } }

    -- Cara is not in the party, so her numbers must not be shown even though
    -- they are still cached this session. With self hidden by default that
    -- leaves nothing at all to show.
    check("nothing from someone out of the group", table.getn(a.GQ.LinesFor("Mottled Boar")), 0)

    -- With self on, YOU appear and she still does not - which is what proves
    -- the group filter is doing the work rather than the self filter.
    a.GQ.config.showSelf = true
    local lines = a.GQ.LinesFor("Mottled Boar")
    check("only you are listed", lines[1].detail, "you 3/10")
    a.GQ.config.showSelf = nil
end

-- ---------------------------------------------------------------------------
print("a single objective tick sends ONE small message, not the whole log")
do
    -- Twenty quests, so a full send would be several chunks. This is the
    -- slowness that was reported: every kill re-sent the lot.
    local big = {}
    for i = 1, 20 do
        table.insert(big, { title = "Quest Number " .. i, objectives = {
            { kind = "monster", name = "Creature " .. i, have = 0, need = 10 },
        } })
    end
    local a = newClient("Alice", big, { "Bob" })
    activate(a)

    a.GQ.UpdateOwnData()
    a.GQ.SendChanges()                      -- first time: no baseline, full sync
    while table.getn(a.GQ.sendQueue) > 0 do a.GQ.DrainQueue() end
    local fullCount = table.getn(a.sent)
    check("the first send is a full sync of several messages", fullCount > 3, true)

    -- One boar dies.
    a.sent = {}
    big[7].objectives[1].have = 1
    a.GQ.UpdateOwnData()
    a.GQ.SendChanges()
    while table.getn(a.GQ.sendQueue) > 0 do a.GQ.DrainQueue() end
    check("one kill is now a single message", table.getn(a.sent), 1)
    check("  and it is a delta", string.sub(a.sent[1].msg, 1, 2), "U~")
    check("  carrying only the quest that moved",
        string.find(a.sent[1].msg, "Quest Number 7", 1, true) ~= nil, true)
    check("  and nothing else", string.find(a.sent[1].msg, "Quest Number 8", 1, true), nil)
end

-- ---------------------------------------------------------------------------
print("nothing is sent when nothing actually moved")
do
    local a = newClient("Alice", ALICE_LOG, { "Bob" })
    activate(a)
    a.GQ.UpdateOwnData()
    a.GQ.SendChanges()
    while table.getn(a.GQ.sendQueue) > 0 do a.GQ.DrainQueue() end

    -- QUEST_LOG_UPDATE fires plenty of times with no objective change.
    a.sent = {}
    a.GQ.UpdateOwnData()
    a.GQ.SendChanges()
    while table.getn(a.GQ.sendQueue) > 0 do a.GQ.DrainQueue() end
    check("an unchanged log sends nothing at all", table.getn(a.sent), 0)
end

-- ---------------------------------------------------------------------------
print("accepting or finishing a quest falls back to a full sync")
do
    local log = { { title = "First", objectives = {
        { kind = "monster", name = "Thing", have = 0, need = 5 } } } }
    local a = newClient("Alice", log, { "Bob" })
    activate(a)
    a.GQ.UpdateOwnData(); a.GQ.SendChanges()
    while table.getn(a.GQ.sendQueue) > 0 do a.GQ.DrainQueue() end

    -- A delta can say "this quest now reads 4/10" but cannot say "this quest is
    -- gone", so a change in the SET of quests has to go full.
    a.sent = {}
    table.insert(log, { title = "Second", objectives = {
        { kind = "item", name = "Widget", have = 0, need = 2 } } })
    a.GQ.UpdateOwnData(); a.GQ.SendChanges()
    while table.getn(a.GQ.sendQueue) > 0 do a.GQ.DrainQueue() end
    check("a new quest sends something at all", table.getn(a.sent) > 0, true)
    check("  and it is a full sync",
        a.sent[1] and string.sub(a.sent[1].msg, 1, 2) or "nothing sent", "H~")

    a.sent = {}
    table.remove(log, 1)
    a.GQ.UpdateOwnData(); a.GQ.SendChanges()
    while table.getn(a.GQ.sendQueue) > 0 do a.GQ.DrainQueue() end
    check("losing one sends something at all", table.getn(a.sent) > 0, true)
    check("  and it is a full sync",
        a.sent[1] and string.sub(a.sent[1].msg, 1, 2) or "nothing sent", "H~")
end

-- ---------------------------------------------------------------------------
print("a delta merges into what the receiver already has")
do
    local aliceLog = {
        { title = "Alpha", objectives = { { kind = "monster", name = "Aaa", have = 0, need = 5 } } },
        { title = "Beta",  objectives = { { kind = "monster", name = "Bbb", have = 0, need = 5 } } },
    }
    local a = newClient("Alice", aliceLog, { "Bob" })
    local b = newClient("Bob", {}, { "Alice" })

    activate(a); a.GQ.UpdateOwnData(); a.GQ.SendChanges()
    deliver(a, b)
    activate(b)
    check("Bob has both quests", b.GQ.data["Alice"].quests["Beta"] ~= nil, true)

    -- Alice advances only Alpha.
    activate(a)
    aliceLog[1].objectives[1].have = 3
    a.GQ.UpdateOwnData(); a.GQ.SendChanges()
    deliver(a, b)

    activate(b)
    check("Alpha updated", b.GQ.data["Alice"].quests["Alpha"][1].have, 3)
    check("  and Beta survived the merge", b.GQ.data["Alice"].quests["Beta"] ~= nil, true)
end

-- ---------------------------------------------------------------------------
print("a mob shows the quest ITEM it drops (optional pfQuest lookup)")
do
    -- The reported gap: hovering a boar showed "Kill Ten Boars" but never the
    -- "Boar Hide 2/5" objective the same boar drops, because that objective is
    -- named after the item and nothing in the Blizzard API links the two.
    local a = newClient("Alice", ALICE_LOG, { "Bob" })
    activate(a)

    -- A stand-in for pfQuest's database, shaped the way the real one is:
    -- items.data[id].U maps unit id -> drop chance, units.loc maps id -> name.
    pfDB = {
        items = { loc = { [4231] = "Boar Hide" },
                  data = { [4231] = { U = { [113] = 45 }, R = { [900] = 30 } } } },
        units = { loc = { [113] = "Mottled Boar", [114] = "Elder Boar" } },
        refloot = { data = { [900] = { U = { [114] = 30 } } } },
    }
    pfDatabase = {
        GetIDByName = function(self, name, db)
            local out = {}
            for id, loc in pairs(pfDB[db] and pfDB[db].loc or {}) do
                if loc == name then out[id] = loc end
            end
            return out
        end,
    }

    a.GQ.data["Bob"] = { time = os.time(), quests = {
        ["Gather Hides"] = { { name = "Boar Hide", have = 2, need = 5 } },
    } }

    check("the database is detected", a.GQ.HasQuestDB(), true)

    local lines = a.GQ.LinesFor("Mottled Boar")
    check("the boar now shows the hide objective", table.getn(lines), 1)
    check("  named for the quest", lines[1].title, "Gather Hides")
    check("  with the party count", lines[1].detail, "Bob 2/5")

    -- Reference loot tables matter: many mobs point at a shared table rather
    -- than listing the item themselves.
    check("a mob from a shared loot table counts too",
        table.getn(a.GQ.LinesFor("Elder Boar")), 1)

    -- And an unrelated mob still shows nothing.
    check("an unrelated mob is unaffected", table.getn(a.GQ.LinesFor("Kobold Miner")), 0)

    pfDB, pfDatabase = nil, nil
end

-- ---------------------------------------------------------------------------
print("without pfQuest it degrades quietly rather than erroring")
do
    local a = newClient("Alice", ALICE_LOG, { "Bob" })
    activate(a)
    pfDB, pfDatabase = nil, nil

    a.GQ.data["Bob"] = { time = os.time(), quests = {
        ["Gather Hides"] = { { name = "Boar Hide", have = 2, need = 5 } },
    } }

    check("no database detected", a.GQ.HasQuestDB(), false)
    local ok, lines = pcall(a.GQ.LinesFor, "Mottled Boar")
    check("hovering raises no error", ok, true)
    check("  and simply adds no drop line", ok and table.getn(lines) or -1, 0)

    -- Name matching must still work with no database at all.
    check("the item itself still matches by name",
        table.getn(a.GQ.LinesFor("Boar Hide")), 1)
end

-- ---------------------------------------------------------------------------
print("a database that has changed shape is survived, not trusted")
do
    local a = newClient("Alice", ALICE_LOG, { "Bob" })
    activate(a)
    -- Shaped like a future pfQuest that moved things around.
    pfDB = { items = { loc = {}, data = {} }, units = { loc = {} } }
    pfDatabase = { GetIDByName = function() error("restructured") end }

    a.GQ.data["Bob"] = { time = os.time(), quests = {
        ["Gather Hides"] = { { name = "Boar Hide", have = 2, need = 5 } },
    } }

    local ok, lines = pcall(a.GQ.LinesFor, "Mottled Boar")
    check("a broken lookup does not break the tooltip", ok, true)
    check("  it just adds nothing", ok and table.getn(lines) or -1, 0)
    pfDB, pfDatabase = nil, nil
end

-- ---------------------------------------------------------------------------
print("")
if failures == 0 then
    print("all " .. checks .. " checks passed")
    os.exit(0)
else
    print(failures .. " of " .. checks .. " checks FAILED")
    os.exit(1)
end
