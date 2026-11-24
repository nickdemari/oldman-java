-- Oldman Java auto quests: while you talk to a quest giver, accepts the quests the route picks up and
-- turns in the ones you've finished. Quests the route leaves out are left for you. When a quest offers
-- a choice of rewards, the window stays open for you to pick. Holding Shift as you start talking leaves
-- that whole conversation to you. If Questie's own auto accept or turn-in is on, that part is left to it.
local _, SP = ...

local Auto = {}
SP.AutoQuest = Auto

local handlers = {}
Auto.handlers = handlers -- Core registers these with its events

local manual = false     -- Shift was held: this conversation is yours
local tried = {}         -- quests already opened in this conversation, so a refusal can't loop
local waiting = nil      -- quest offered before the route had it (a follow-up just after a turn-in)

local function Enabled()
    return SP.ready and SP.db and SP.db.autoQuest ~= false
end

local function Skip()
    if manual then return true end
    if IsShiftKeyDown and IsShiftKeyDown() then
        manual = true
        return true
    end
    return not Enabled()
end

-- Questie's own setting for this part ("accept" or "turnin"), when Questie is loaded.
local function QuestieDoes(part)
    local ok, on = pcall(function()
        local p = Questie.db.profile
        if part == "accept" then return p.autoAccept and p.autoAccept.enabled end
        return p.autocomplete
    end)
    return ok and on and true or false
end

-- The route picks this quest up.
local function Routed(id)
    if not id or id == 0 then return false end
    local route = SP.Planner and SP.Planner.route
    for i = 1, route and #route or 0 do
        local node = route[i]
        if node.kind == "pickup" and node.q == id then return true end
    end
    return false
end

-- Turned in for you: anything finished except repeatable quests (cloth and other hand-ins).
local function Finishable(id, repeatable)
    if repeatable then return false end
    local info = id and id ~= 0 and SP.Data and SP.Data.Info(id)
    return not (info and info.blocked == "repeatable")
end

local function Reset()
    manual, tried = false, {}
end

-- Between one quest window and the next, every window is briefly closed: only start afresh when the
-- conversation is really over.
local function AfterClose()
    C_Timer.After(0.5, function()
        local open = (GossipFrame and GossipFrame:IsShown()) or (QuestFrame and QuestFrame:IsShown())
        if not open then Reset() end
    end)
end

function handlers.GOSSIP_SHOW()
    if Skip() or not C_GossipInfo then return end
    if not QuestieDoes("turnin") then
        for _, q in ipairs(C_GossipInfo.GetActiveQuests() or {}) do
            local id = q.questID
            if q.isComplete and id and not tried[id] and Finishable(id, q.repeatable) then
                tried[id] = true
                C_GossipInfo.SelectActiveQuest(id)
                return
            end
        end
    end
    if not QuestieDoes("accept") then
        for _, q in ipairs(C_GossipInfo.GetAvailableQuests() or {}) do
            local id = q.questID
            if id and not tried[id] and Routed(id) then
                tried[id] = true
                C_GossipInfo.SelectAvailableQuest(id)
                return
            end
        end
    end
end

-- Quest givers with a plain list of quests instead of gossip.
function handlers.QUEST_GREETING()
    if Skip() then return end
    if not QuestieDoes("turnin") and GetNumActiveQuests then
        for i = 1, GetNumActiveQuests() do
            local _, complete = GetActiveTitle(i)
            local id = GetActiveQuestID and GetActiveQuestID(i) or 0
            local key = id ~= 0 and id or ("active" .. i)
            if complete and not tried[key] and Finishable(id) then
                tried[key] = true
                SelectActiveQuest(i)
                return
            end
        end
    end
    if not QuestieDoes("accept") and GetNumAvailableQuests and GetAvailableQuestInfo then
        for i = 1, GetNumAvailableQuests() do
            local id = select(5, GetAvailableQuestInfo(i)) -- Forever adds the quest ID here
            if id and not tried[id] and Routed(id) then
                tried[id] = true
                SelectAvailableQuest(i)
                return
            end
        end
    end
end

function handlers.QUEST_DETAIL()
    if Skip() or QuestieDoes("accept") then return end
    local id = GetQuestID and GetQuestID() or 0
    if id == 0 then return end
    if Routed(id) then
        waiting = nil
        AcceptQuest()
    else
        waiting = id -- checked again when the next route is out
    end
end

-- The "bring me these" page: hand them over when you have everything (and it costs no money).
function handlers.QUEST_PROGRESS()
    if Skip() or QuestieDoes("turnin") then return end
    if not (IsQuestCompletable and IsQuestCompletable()) then return end
    if (GetQuestMoneyToGet and GetQuestMoneyToGet() or 0) > 0 then return end
    if Finishable(GetQuestID and GetQuestID() or 0) then CompleteQuest() end
end

-- The reward page: take it, unless there's a choice to make.
function handlers.QUEST_COMPLETE()
    if Skip() or QuestieDoes("turnin") then return end
    if not Finishable(GetQuestID and GetQuestID() or 0) then return end
    if (GetNumQuestChoices and GetNumQuestChoices() or 0) > 1 then
        local title = GetTitleText and GetTitleText()
        if SP.Print then SP.Print("pick your reward" .. (title and title ~= "" and (" for " .. title) or "") .. ".") end
        return
    end
    GetQuestReward(1) -- the call Questie makes on this client, with one reward or none
end

function handlers.GOSSIP_CLOSED() AfterClose() end
function handlers.QUEST_FINISHED() AfterClose() end

-- A new route is out: accept the quest on screen if the route now picks it up.
function Auto.OnPlan()
    if not waiting or manual or not Enabled() or QuestieDoes("accept") then return end
    if GetQuestID and GetQuestID() == waiting and Routed(waiting) then
        waiting = nil
        AcceptQuest()
    end
end
