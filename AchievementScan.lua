local ADDON_NAME, ns = ...

-- 全部成就ID缓存，构建一次后复用（成就分类结构在一次游戏会话中不会变化）
local allAchievementIDs

local function BuildAchievementIDList()
    local ids = {}
    local ok, categories = pcall(GetCategoryList)
    if not ok or not categories then
        return ids
    end

    for _, catID in ipairs(categories) do
        local numAch = select(1, GetCategoryNumAchievements(catID))
        if numAch and numAch > 0 then
            for index = 1, numAch do
                local id = GetAchievementInfo(catID, index)
                if id then
                    ids[#ids + 1] = id
                end
            end
        end
    end
    return ids
end

-- 获取全部成就ID（第一次调用时构建并缓存）
function ns.GetAllAchievementIDs()
    if not allAchievementIDs then
        allAchievementIDs = BuildAchievementIDList()
        if ns.Print then
            ns.Print(string.format("成就数据库建立完成，共 %d 项成就（用于后续对比）", #allAchievementIDs))
        end
    end
    return allAchievementIDs
end
