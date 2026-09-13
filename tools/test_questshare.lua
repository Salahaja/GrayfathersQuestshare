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

    local lines = a.GQ.LinesFor("Mottled Boar")
    check("one quest matched", table.getn(lines), 1)
    check("  titled", lines[1].title, "Kill Ten Boars")
    check("  you first, Bob shown as done", lines[1].detail, "you 3/10  -  |cFF66FF66Bob done|r")

    -- Case-insensitive, because tooltip capitalisation isn't guaranteed.
    check("case insensitive", table.getn(a.GQ.LinesFor("mottled boar")), 1)
    check("unrelated target matches nothing", table.getn(a.GQ.LinesFor("Kobold Miner")), 0)

    -- An item objective should match the item name.
    local itemLines = a.GQ.LinesFor("Boar Hide")
    check("item objective matched", table.getn(itemLines), 1)
    check("  and only you have it", itemLines[1].detail, "you 2/5")
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

    -- Cara isn't in the party, so her numbers must not be shown even though
    -- they're still cached this session.
    local lines = a.GQ.LinesFor("Mottled Boar")
    check("only you are listed", lines[1].detail, "you 3/10")
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
