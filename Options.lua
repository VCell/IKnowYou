local ADDON_NAME, ns = ...

local panel
local rows = {}
local ROW_HEIGHT = 22
local COL_X = { name = 16, status = 190, matched = 320, delete = 500 }

local function CreateCheckbox(parent, label, x, y, get, set)
    local cb = CreateFrame("CheckButton", nil, parent, "InterfaceOptionsCheckButtonTemplate")
    cb:SetPoint("TOPLEFT", x, y)
    cb.Text:SetText(label)
    cb:SetChecked(get())
    cb:SetScript("OnClick", function(self)
        set(self:GetChecked() and true or false)
    end)
    return cb
end

local function CreateHeaderRow(parent, y)
    local h = CreateFrame("Frame", nil, parent)
    h:SetSize(560, ROW_HEIGHT)
    h:SetPoint("TOPLEFT", 0, y)

    local function AddHeaderText(text, x)
        local fs = h:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("LEFT", x, 0)
        fs:SetText(text)
        return fs
    end

    AddHeaderText("关注角色", COL_X.name)
    AddHeaderText("状态", COL_X.status)
    AddHeaderText("检测到的同账号角色", COL_X.matched)

    local line = h:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(1, 1, 1, 0.15)
    line:SetPoint("BOTTOMLEFT", 0, 0)
    line:SetPoint("BOTTOMRIGHT", 0, 0)
    line:SetHeight(1)

    return h
end

local function CreateRow(parent)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(560, ROW_HEIGHT)

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.name:SetPoint("LEFT", COL_X.name, 0)
    row.name:SetWidth(165)
    row.name:SetJustifyH("LEFT")

    row.status = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.status:SetPoint("LEFT", COL_X.status, 0)
    row.status:SetWidth(120)
    row.status:SetJustifyH("LEFT")

    row.matched = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.matched:SetPoint("LEFT", COL_X.matched, 0)
    row.matched:SetWidth(170)
    row.matched:SetJustifyH("LEFT")
    row.matched:SetWordWrap(false)

    row.delBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.delBtn:SetSize(50, 18)
    row.delBtn:SetPoint("LEFT", COL_X.delete, 0)
    row.delBtn:SetText("删除")

    return row
end

local function RefreshList()
    if not panel or not panel.scrollChild then return end

    for _, row in ipairs(rows) do row:Hide() end

    local names = {}
    for name in pairs(IKnowYouDB.watchList) do
        table.insert(names, name)
    end
    table.sort(names)

    local y = 0
    for idx, name in ipairs(names) do
        local entry = IKnowYouDB.watchList[name]
        local row = rows[idx]
        if not row then
            row = CreateRow(panel.scrollChild)
            rows[idx] = row
        end

        local statusText
        if entry.collected then
            statusText = "|cff33ff33已采集|r " .. ns.FormatDate(entry.collectedDate)
        else
            statusText = "|cffff3333未采集|r"
        end

        local matchedNames = {}
        for _, dispName in pairs(entry.matchedGUIDs) do
            table.insert(matchedNames, dispName)
        end
        local matchedText = (#matchedNames > 0) and table.concat(matchedNames, ", ") or "-"

        row.name:SetText(name)
        row.status:SetText(statusText)
        row.matched:SetText(matchedText)
        row.delBtn:SetScript("OnClick", function()
            ns.RemoveWatch(name)
        end)

        row:SetPoint("TOPLEFT", 0, -y)
        row:Show()
        y = y + ROW_HEIGHT
    end

    panel.scrollChild:SetHeight(math.max(y, 1))
end
ns.RefreshOptionsPanel = RefreshList

local function BuildPanel()
    panel = CreateFrame("Frame")
    panel.name = "IKnowYou"

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("IKnowYou")

    local subtitle = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    subtitle:SetText("通过对比全部成就完成情况，识别可能与关注角色同战网账号的目标")

    -- 添加关注角色
    local addLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    addLabel:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", 0, -18)
    addLabel:SetText("添加关注角色（格式：名字-服务器，不填服务器默认当前服务器）")

    local editBox = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    editBox:SetSize(220, 20)
    editBox:SetPoint("TOPLEFT", addLabel, "BOTTOMLEFT", 6, -8)
    editBox:SetAutoFocus(false)

    local confirmBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    confirmBtn:SetSize(60, 22)
    confirmBtn:SetPoint("LEFT", editBox, "RIGHT", 8, 0)
    confirmBtn:SetText("确认")

    local function DoAdd()
        local text = editBox:GetText()
        if text and text ~= "" then
            if not text:find("-") then
                text = text .. "-" .. GetRealmName()
            end
            ns.AddWatch(text)
            editBox:SetText("")
        end
    end
    editBox:SetScript("OnEnterPressed", DoAdd)
    confirmBtn:SetScript("OnClick", DoAdd)

    -- 检测时机（多选）
    local checkLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    checkLabel:SetPoint("TOPLEFT", editBox, "BOTTOMLEFT", -6, -16)
    checkLabel:SetText("检测时机")

    CreateCheckbox(panel, "当前目标", 16, -0,
        function() return IKnowYouDB.settings.checkOnTarget end,
        function(v) IKnowYouDB.settings.checkOnTarget = v end
    ):SetPoint("TOPLEFT", checkLabel, "BOTTOMLEFT", -2, -4)

    local cbGroup = CreateCheckbox(panel, "小队及团队成员", 16, -0,
        function() return IKnowYouDB.settings.checkOnGroup end,
        function(v) IKnowYouDB.settings.checkOnGroup = v end
    )
    cbGroup:SetPoint("TOPLEFT", checkLabel, "BOTTOMLEFT", 140, -4)

    -- 关注角色列表
    local listLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    listLabel:SetPoint("TOPLEFT", checkLabel, "BOTTOMLEFT", 0, -34)
    listLabel:SetText("关注角色列表")

    local header = CreateHeaderRow(panel, 0)
    header:SetPoint("TOPLEFT", listLabel, "BOTTOMLEFT", 0, -8)

    local scroll = CreateFrame("ScrollFrame", "IKnowYouOptionsScroll", panel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
    scroll:SetPoint("RIGHT", panel, "RIGHT", -32, 0)
    scroll:SetPoint("BOTTOM", panel, "BOTTOM", 0, 16)

    local scrollChild = CreateFrame("Frame", nil, scroll)
    scrollChild:SetSize(560, 1)
    scroll:SetScrollChild(scrollChild)
    panel.scrollChild = scrollChild

    panel:SetScript("OnShow", RefreshList)

    if Settings and Settings.RegisterCanvasLayoutCategory then
        local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
        category.ID = panel.name
        Settings.RegisterAddOnCategory(category)
        ns.optionsCategory = category
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:SetScript("OnEvent", function()
    BuildPanel()
end)


