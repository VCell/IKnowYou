local ADDON_NAME, ns = ...

--============================================================
-- 数据结构
-- IKnowYouDB = {
--   watchList = {
--     ["角色名-服务器"] = {
--       collected = false,
--       collectedDate = nil,       -- "YYYYMMDD"，本次采集发生的日期（不是成就完成日期）
--       achievements = {},         -- 采集时该角色已完成的成就集合 { [成就ID] = true }
--       matchedGUIDs = {},         -- 已识别出的疑似同账号角色 { [guid] = "角色名-服务器（检测时）" }
--     },
--   },
--   settings = {
--     checkOnTarget = true,        -- 选中当前目标时检测
--     checkOnGroup  = true,        -- 小队/团队每分钟检测
--     similarityThreshold = 0.95,  -- 相似度阈值
--   },
-- }
--============================================================

local DEFAULT_DB = {
    watchList = {},
    settings = {
        checkOnTarget = true,
        checkOnGroup = true,
        similarityThreshold = 0.95,
    },
    suspectedMirrors = {}, -- debug模式下发现的"同名不同ID"疑似镜像成就 { {id1=, id2=, name=}, ... }
}

-- 本次登录内，"检测同账号"已经检查过的 GUID（不落盘，重新登录重置）
local checkedThisSession = {}

-- 异步请求队列：保证同一时刻只有一个 SetAchievementComparisonUnit 请求在处理中
local requestQueue = {}
local activeRequest = nil
local debug = false

local SCAN_TIMEOUT = 8 -- 秒。请求发出后这么久还没等到 INSPECT_ACHIEVEMENT_READY，就当作失败，放弃并处理下一个

--============================================================
-- 工具函数
--============================================================

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[IKnowYou]|r " .. msg)
end

local function Debug(...)
    if debug then
        print(...)
    end
end

local function TableLen(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function GetFullName(unit)
    if not UnitExists(unit) then return nil end
    local name, realm = UnitName(unit)
    if not name then return nil end
    if not realm or realm == "" then
        realm = GetRealmName()
    end
    return name .. "-" .. realm
end

local function TodayDateString()
    local t = date("*t")
    return string.format("%04d%02d%02d", t.year, t.month, t.day)
end

local function FormatDate(dateStr)
    if not dateStr then return "-" end
    local y, m, d = dateStr:match("^(%d%d%d%d)(%d%d)(%d%d)$")
    if not y then return dateStr end
    return string.format("%s-%s-%s", y, m, d)
end

local function EnsureDB()
    IKnowYouDB = IKnowYouDB or {}
    for k, v in pairs(DEFAULT_DB) do
        if IKnowYouDB[k] == nil then
            IKnowYouDB[k] = v
        end
    end
    IKnowYouDB.settings = IKnowYouDB.settings or {}
    for k, v in pairs(DEFAULT_DB.settings) do
        if IKnowYouDB.settings[k] == nil then
            IKnowYouDB.settings[k] = v
        end
    end
    IKnowYouDB.suspectedMirrors = IKnowYouDB.suspectedMirrors or {}
end

--============================================================
-- 关注列表增删（供 Options.lua 调用）
--============================================================

function ns.AddWatch(fullName)
    if not fullName or fullName == "" then return end
    if not IKnowYouDB.watchList[fullName] then
        IKnowYouDB.watchList[fullName] = {
            collected = false,
            collectedDate = nil,
            achievements = {},
            matchedGUIDs = {},
        }
        Print("已添加关注角色：" .. fullName)
        if ns.RefreshOptionsPanel then ns.RefreshOptionsPanel() end
    end
end

function ns.RemoveWatch(fullName)
    IKnowYouDB.watchList[fullName] = nil
    if ns.RefreshOptionsPanel then ns.RefreshOptionsPanel() end
end

--============================================================
-- 请求队列：保证"上一个请求返回后才发起下一个"
--============================================================

local function ProcessQueue()
    Debug("ProcessQueue")
    -- 注意：这里不能无条件调用 ClearAchievementComparisonUnit()。
    -- ProcessQueue 在每次 EnqueueRequest 入队时都会被调用一次，如果这时已经有
    -- activeRequest 在等待服务器返回，无条件清空会把这个还没返回的请求直接取消掉，
    -- 导致它的 INSPECT_ACHIEVEMENT_READY 永远不会触发——这正是队列卡住的根因。
    if activeRequest then return end

    ClearAchievementComparisonUnit()

    local req = table.remove(requestQueue, 1)
    if not req then return end

    if not UnitExists(req.unit) then
        -- 目标已失效（比如玩家已经切换目标/队友已离线），跳过继续处理下一个
        ProcessQueue()
        return
    end

    activeRequest = req
    SetAchievementComparisonUnit(req.unit)

    -- 超时保护：如果一直等不到 INSPECT_ACHIEVEMENT_READY，放弃这次请求，继续处理队列
    C_Timer.After(SCAN_TIMEOUT, function()
        if activeRequest == req then
            Debug("请求超时，放弃", req.fullName, req.mode)
            activeRequest = nil
            ProcessQueue()
        end
    end)
end

local function EnqueueRequest(unit, mode, fullName)
    Debug("EnqueueRequest", unit, mode, fullName)
    if not UnitExists(unit) then return end
    local guid = UnitGUID(unit)
    if not guid then return end

    if activeRequest and activeRequest.guid == guid and activeRequest.mode == mode then
        return
    end
    for _, req in ipairs(requestQueue) do
        if req.guid == guid and req.mode == mode then
            return
        end
    end

    table.insert(requestQueue, { unit = unit, mode = mode, fullName = fullName, guid = guid })
    ProcessQueue()
end

local function GetAchievementName(achID)
    local _, name = GetAchievementInfo(achID)
    return name or ("未知成就#" .. tostring(achID))
end
ns.GetAchievementName = GetAchievementName

-- 阵营镜像成就归一化：把 IKnowYou_FactionAchievementMirror 里配对的两个ID
-- 映射到同一个 canonical ID（取较小的那个），采集/比对时统一走这层映射，
-- 这样"完成A即视为完成B"就不会被计入差异(b)了。
local canonicalMap
local function BuildCanonicalMap()
    canonicalMap = {}
    local mirror = IKnowYou_FactionAchievementMirror or {}
    for a, h in pairs(mirror) do
        local canon = math.min(a, h)
        canonicalMap[a] = canon
        canonicalMap[h] = canon
    end
end

local function CanonicalAchievementID(achID)
    if not canonicalMap then
        BuildCanonicalMap()
    end
    return canonicalMap[achID] or achID
end

-- 把差异成就名字打印出来，方便排查（比如阵营专属成就造成的干扰）
-- 默认只在开了 /iky debug 时打印，避免刷屏；每边最多打印 MAX_PRINT 条
local MAX_DIFF_PRINT = 30

local function PrintDiffList(title, achIDs)
    if #achIDs == 0 then return end
    Print(string.format("  %s（%d项）：", title, #achIDs))
    for i, achID in ipairs(achIDs) do
        if i > MAX_DIFF_PRINT then
            Print(string.format("    ……还有 %d 项未显示", #achIDs - MAX_DIFF_PRINT))
            break
        end
        Print(string.format("    - [%d] %s", achID, GetAchievementName(achID)))
    end
end

-- 在 onlyWatched / onlyTarget 里找"名字相同但ID不同"的成就（疑似阵营镜像对），
-- 记录进 IKnowYouDB.suspectedMirrors，供之后手动核对、填进 FactionMirror.lua。
-- 仅在 debug 模式下执行。
local function AlreadyRecordedMirror(id1, id2)
    for _, rec in ipairs(IKnowYouDB.suspectedMirrors) do
        if (rec.id1 == id1 and rec.id2 == id2) or (rec.id1 == id2 and rec.id2 == id1) then
            return true
        end
    end
    return false
end

-- local function RecordSuspectedMirrors(onlyWatched, onlyTarget)
--     if #onlyWatched == 0 or #onlyTarget == 0 then return end

--     -- 先把 onlyTarget 的名字缓存出来，避免 O(n*m) 次重复调用 GetAchievementInfo
--     local targetNames = {}
--     for _, id2 in ipairs(onlyTarget) do
--         targetNames[id2] = GetAchievementName(id2)
--     end

--     local newCount = 0
--     for _, id1 in ipairs(onlyWatched) do
--         local name1 = GetAchievementName(id1)
--         for id2, name2 in pairs(targetNames) do
--             if name1 == name2 and not AlreadyRecordedMirror(id1, id2) then
--                 table.insert(IKnowYouDB.suspectedMirrors, { id1 = id1, id2 = id2, name = name1 })
--                 newCount = newCount + 1
--             end
--         end
--     end

--     if newCount > 0 then
--         Print(string.format(
--             "发现 %d 个疑似镜像成就（同名不同ID），已记录到 IKnowYouDB.suspectedMirrors，可核对后填入 FactionMirror.lua",
--             newCount))
--     end
-- end

local function CompareAgainstWatchList(targetAchievedWithDate, guid, targetDisplayName)
    local threshold = IKnowYouDB.settings.similarityThreshold or 0.95

    for watchName, entry in pairs(IKnowYouDB.watchList) do
        if watchName ~= targetDisplayName and entry.collected and entry.collectedDate and not entry.matchedGUIDs[guid] then
            -- 只取目标在该关注角色"采集日期"之前完成的成就
            local targetBefore = {}
            for achID, dateStr in pairs(targetAchievedWithDate) do
                if dateStr and dateStr <= entry.collectedDate then
                    targetBefore[achID] = true
                end
            end

            local a, b = 0, 0
            local onlyWatched, onlyTarget = {}, {}
            for achID in pairs(entry.achievements) do
                if targetBefore[achID] then
                    a = a + 1
                else
                    b = b + 1
                    onlyWatched[#onlyWatched + 1] = achID
                end
            end
            for achID in pairs(targetBefore) do
                if not entry.achievements[achID] then
                    b = b + 1
                    onlyTarget[#onlyTarget + 1] = achID
                end
            end

            if a > 0 then
                local similarity = (a - b) / a
                if similarity > threshold then
                    entry.matchedGUIDs[guid] = targetDisplayName
                    Print(string.format(
                        "|cffff8800疑似发现同账号角色|r：%s 与关注角色 %s 相似度 %.1f%%",
                        targetDisplayName, watchName, similarity * 100))
                    if ns.RefreshOptionsPanel then ns.RefreshOptionsPanel() end
                else
                    Debug(string.format(
                        "%s 与关注角色 %s 相似度%.1f%%, 低于阈值", targetDisplayName, watchName, similarity * 100))
                end

                if debug then
                    Print(string.format("[差异明细] %s vs 关注角色 %s（a=%d, b=%d）",
                        targetDisplayName, watchName, a, b))
                    PrintDiffList(watchName .. " 有但 " .. targetDisplayName .. " 没有（采集日期前）", onlyWatched)
                    PrintDiffList(targetDisplayName .. " 有但 " .. watchName .. " 没有", onlyTarget)
                end
            end
        end
    end
end

--============================================================
-- 处理成就比对数据返回
--============================================================

local function HandleScanResult(req)
    Debug("HandleScanResult", req.unit, req.mode)
    local allIDs = ns.GetAllAchievementIDs()

    if req.mode == "collect" then
        local achieved = {}
        for _, achID in ipairs(allIDs) do
            local completed = GetAchievementComparisonInfo(achID)
            if completed then
                achieved[CanonicalAchievementID(achID)] = true
            end
        end
        local entry = IKnowYouDB.watchList[req.fullName]
        if entry then
            entry.achievements = achieved
            entry.collected = true
            entry.collectedDate = TodayDateString()
            Print(string.format("已采集关注角色成就数据：%s（共 %d 项已完成成就，采集日期 %s）",
                req.fullName, TableLen(achieved), FormatDate(entry.collectedDate)))
            if ns.RefreshOptionsPanel then ns.RefreshOptionsPanel() end
            --采集成功时重置checkedThisSession
            checkedThisSession = {}
        end

    elseif req.mode == "match" then
        local targetData = {}
        for _, achID in ipairs(allIDs) do
            local completed, month, day, year = GetAchievementComparisonInfo(achID)
            if completed and year then
                local canon = CanonicalAchievementID(achID)
                local dateStr = string.format("%04d%02d%02d", year + 2000, month, day)
                -- 镜像的两个ID可能都命中（极少数换过阵营的情况），取较早的完成日期
                if not targetData[canon] or dateStr < targetData[canon] then
                    targetData[canon] = dateStr
                end
            end
        end
        CompareAgainstWatchList(targetData, req.guid, req.fullName)
    end
end

--============================================================
-- 采集：目标名字匹配关注列表时，采集其全部成就
--============================================================

local function TryCollectFromTarget(unit)
    Debug("TryCollectFromTarget", unit)
    if not UnitIsPlayer(unit) then return end -- 只考虑玩家，排除NPC
    if not UnitIsFriend("player", unit) then return end
    if UnitIsUnit(unit, "player") then return end
    local fullName = GetFullName(unit)
    if not fullName then return end
    --每个角色每天只采集一次
    if IKnowYouDB.watchList[fullName] and IKnowYouDB.watchList[fullName].collectedDate ~= TodayDateString() then
        EnqueueRequest(unit, "collect", fullName)
    end
end

--============================================================
-- 检测：与关注角色比对相似度（当前目标 / 小队团队成员共用）
--============================================================

local function TryMatchUnit(unit)
    if InCombatLockdown() then return end -- 只在非战斗状态检测
    if not UnitIsPlayer(unit) then return end -- 只考虑玩家，排除NPC
    if not UnitIsFriend("player", unit) then return end
    if UnitIsUnit(unit, "player") then return end

    local guid = UnitGUID(unit)
    if not guid or checkedThisSession[guid] then return end

    local fullName = GetFullName(unit)
    checkedThisSession[guid] = true
    EnqueueRequest(unit, "match", fullName)
end

--============================================================
-- 小队/团队扫描（每分钟）
--============================================================

local function GroupScanTick()
    if InCombatLockdown() then return end
    if not IKnowYouDB.settings.checkOnGroup then return end
    if not (IsInGroup() or IsInRaid()) then return end

    local num = GetNumGroupMembers()
    for i = 1, num do
        local unit
        if IsInRaid() then
            unit = "raid" .. i
        elseif i < num then
            unit = "party" .. i
        end
        if unit and UnitExists(unit) and not UnitIsUnit(unit, "player") then
            TryMatchUnit(unit)
        end
    end
end

--============================================================
-- 事件注册
--============================================================
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
eventFrame:RegisterEvent("INSPECT_ACHIEVEMENT_READY")

eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        EnsureDB()

    elseif event == "PLAYER_LOGIN" then
        C_Timer.NewTicker(60, GroupScanTick)
        -- 预热成就ID列表（延迟一点，避开登录瞬间）
        C_Timer.After(3, function()
            pcall(ns.GetAllAchievementIDs)
        end)

    elseif event == "PLAYER_TARGET_CHANGED" then
        if UnitExists("target") then
            TryCollectFromTarget("target")
            if IKnowYouDB.settings.checkOnTarget then
                TryMatchUnit("target")
            end
        end

    elseif event == "INSPECT_ACHIEVEMENT_READY" then
        Debug("INSPECT_ACHIEVEMENT_READY", arg1)
        if activeRequest and activeRequest.guid == arg1 then
            local req = activeRequest
            activeRequest = nil
            HandleScanResult(req)
            ProcessQueue()
        end
        -- 不是当前 activeRequest 对应的回包，忽略（可能是过期/无关请求）
    end
end)

-- 设置命令
SLASH_IKNOWYOU1 = "/iky"
SlashCmdList["IKNOWYOU"] = function(msg)
    local command, value = strsplit(" ", msg or "", 2)
    command = command and strlower(command) or ""
    
    if command == "debug" then
        debug = true
        Print("开启日志")
    elseif command == "release" then 
        debug = false
        Print("关闭日志")
    else
        Print("未知命令")
    end
end

-- 暴露给 Options.lua
ns.Print = Print
ns.Debug = Debug
ns.GetFullName = GetFullName
ns.FormatDate = FormatDate
ns.EnsureDB = EnsureDB