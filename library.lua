--[[
    ============================================================
    PLACEMENT MAP BUILDER v4
    ============================================================
    LocalScript в StarterPlayerScripts. Без внешних библиотек.

    Управление в мире:
      - ЛКМ-тяни по пустой земле (у шага нет зоны) — создать зону
        (простой клик = зона 4x4)
      - ЛКМ по зоне + тяни — двигать (шаг выбирается автоматически)
      - Ручки на краях — растягивать (ручки висят НАД зоной)
      - Кольцо — вращать вокруг Y
      - [ и ] — предыдущий / следующий шаг
      - Delete — удалить шаг, Esc — отменить создание
      - H — спрятать/показать редактор целиком
      - Номера в панели — быстрый выбор шага

    Визуал «тихий»: невыбранная зона — тонкие уголки + маленький
    номер; текст и заливка проявляются при наведении/выборе.

    Export / Import — простой текстовый формат (см. exportData).
    ============================================================
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- ============================================================
--  НАСТРОЙКИ
-- ============================================================

local CONFIG = {
    GridSnap = 1,              -- шаг сетки в студах (0 = выключить)
    AngleSnapDeg = 5,          -- шаг поворота в градусах (0 = выключить)
    MinSize = 1,
    DefaultSize = 4,           -- размер при простом клике
    ZoneThickness = 0.2,

    -- --- визуал ---
    FillIdle = 0.95,            -- заливка обычной зоны (1 = полностью выключить)
    FillSelected = 0.75,        -- заливка выбранной/наведённой
    CornerLength = 0.25,        -- длина уголка (доля стороны зоны)
    CornerThickness = 3,        -- толщина линий уголков, px
    OutlineTransparency = 0.7,  -- едва заметная обводка всего контура

    BillboardHeight = 2.5,      -- метка чуть над землёй
    BillboardMaxDistance = 120, -- дальше этого метки скрываются
    BadgeSize = 34,             -- размер кружка с номером

    GizmoOffset = 2,            -- насколько ручки выше зоны (студы)

    MaxRayDistance = 2000,
}

local PALETTE = {
    Color3.fromRGB(86, 214, 145),
    Color3.fromRGB(232, 96, 96),
    Color3.fromRGB(96, 162, 228),
    Color3.fromRGB(236, 190, 72),
    Color3.fromRGB(186, 122, 232),
}

local THEME = {
    Panel = Color3.fromRGB(22, 24, 29),
    Panel2 = Color3.fromRGB(32, 35, 42),
    Button = Color3.fromRGB(44, 48, 57),
    ButtonHover = Color3.fromRGB(60, 66, 78),
    Danger = Color3.fromRGB(150, 50, 55),
    Border = Color3.fromRGB(58, 62, 73),
    Text = Color3.fromRGB(230, 232, 236),
    Muted = Color3.fromRGB(140, 146, 158),
    Dark = Color3.fromRGB(18, 20, 25),
}

-- локальные оси граней Handles (Front = -Z, Back = +Z)
local FACE_AXIS = {
    [Enum.NormalId.Right] = Vector3.new(1, 0, 0),
    [Enum.NormalId.Left]  = Vector3.new(-1, 0, 0),
    [Enum.NormalId.Back]  = Vector3.new(0, 0, 1),
    [Enum.NormalId.Front] = Vector3.new(0, 0, -1),
}

-- ============================================================
--  СОСТОЯНИЕ
-- ============================================================

local Steps = {}
local currentIndex = 0
local nextStepId = 1
local PartToStep = {}

local visualFolder = Instance.new("Folder")
visualFolder.Name = "PlacementMap_Visuals"
visualFolder.Parent = Workspace

local placing = false
local placeStart = nil
local dragStep = nil
local dragOffsetX, dragOffsetZ = 0, 0
local gizmoDragging = false

local hoveredStep = nil
local editorHidden = false

local refreshUI
local selectStep
local setEditorHidden

-- ============================================================
--  УТИЛИТЫ
-- ============================================================

local function snap(value, increment)
    if not increment or increment <= 0 then
        return value
    end
    return math.round(value / increment) * increment
end

local function snapPoint(pos)
    return Vector3.new(snap(pos.X, CONFIG.GridSnap), pos.Y, snap(pos.Z, CONFIG.GridSnap))
end

local function tween(obj, time, props)
    local t = TweenService:Create(obj, TweenInfo.new(time, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props)
    t:Play()
    return t
end

local function getCurrentStep()
    return Steps[currentIndex]
end

-- ============================================================
--  RAYCAST
-- ============================================================

local function getMouseRay()
    local camera = Workspace.CurrentCamera
    if not camera then return nil end
    local m = UserInputService:GetMouseLocation()
    return camera:ViewportPointToRay(m.X, m.Y)
end

local function raycastGround()
    local ray = getMouseRay()
    if not ray then return nil end

    local ignore = { visualFolder }
    if player.Character then
        table.insert(ignore, player.Character)
    end

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = ignore

    local result = Workspace:Raycast(ray.Origin, ray.Direction * CONFIG.MaxRayDistance, params)
    return result and result.Position or nil
end

local function raycastZone()
    local ray = getMouseRay()
    if not ray then return nil end

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Include
    params.FilterDescendantsInstances = { visualFolder }

    local result = Workspace:Raycast(ray.Origin, ray.Direction * CONFIG.MaxRayDistance, params)
    if result and result.Instance then
        local step = PartToStep[result.Instance]
        if step then
            return step, result.Position
        end
    end
    return nil
end

-- ============================================================
--  ВИЗУАЛЫ: уголки зоны (SurfaceGui) и метка (Billboard)
-- ============================================================

-- тонкие уголки по периметру + еле заметная обводка; масштабируется вместе с партом
local function createBorder(part, color)
    local gui = Instance.new("SurfaceGui")
    gui.Name = "Border"
    gui.Face = Enum.NormalId.Top
    gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
    gui.PixelsPerStud = 20
    gui.LightInfluence = 0
    gui.Adornee = part
    gui.Parent = part

    local root = Instance.new("Frame")
    root.Size = UDim2.fromScale(1, 1)
    root.BackgroundTransparency = 1
    root.Parent = gui

    -- тонкая обводка всего контура, чтобы форма зоны была видна целиком
    local outline = Instance.new("Frame")
    outline.Size = UDim2.fromScale(1, 1)
    outline.BackgroundTransparency = 1
    outline.BorderSizePixel = 0
    outline.Parent = root
    local outlineStroke = Instance.new("UIStroke")
    outlineStroke.Color = color
    outlineStroke.Thickness = 1.5
    outlineStroke.Transparency = CONFIG.OutlineTransparency
    outlineStroke.Parent = outline

    -- 8 планок = 4 уголка
    local bars = {}
    local function addBar(x, y, anchor, horizontal)
        local bar = Instance.new("Frame")
        bar.AnchorPoint = anchor
        bar.Position = UDim2.fromScale(x, y)
        bar.Size = horizontal
            and UDim2.new(CONFIG.CornerLength, 0, 0, CONFIG.CornerThickness)
            or UDim2.new(0, CONFIG.CornerThickness, CONFIG.CornerLength, 0)
        bar.BackgroundColor3 = color
        bar.BorderSizePixel = 0
        bar.Parent = root
        table.insert(bars, bar)
    end
    addBar(0, 0, Vector2.new(0, 0), true);  addBar(0, 0, Vector2.new(0, 0), false)
    addBar(1, 0, Vector2.new(1, 0), true);  addBar(1, 0, Vector2.new(1, 0), false)
    addBar(0, 1, Vector2.new(0, 1), true);  addBar(0, 1, Vector2.new(0, 1), false)
    addBar(1, 1, Vector2.new(1, 1), true);  addBar(1, 1, Vector2.new(1, 1), false)

    return {
        SetColor = function(c)
            outlineStroke.Color = c
            for _, b in ipairs(bars) do b.BackgroundColor3 = c end
        end,
        SetTransparency = function(t)
            for _, b in ipairs(bars) do b.BackgroundTransparency = t end
        end,
    }
end

-- метка = маленький кружок с номером; текст раскрывается при наведении/выборе
local function createBillboard(position, text, color, parent)
    local anchor = Instance.new("Part")
    anchor.Name = "BillboardAnchor"
    anchor.Size = Vector3.new(0.1, 0.1, 0.1)
    anchor.Transparency = 1
    anchor.Anchored = true
    anchor.CanCollide = false
    anchor.CanQuery = false
    anchor.CanTouch = false
    anchor.Position = position
    anchor.Parent = parent

    local gui = Instance.new("BillboardGui")
    gui.Size = UDim2.fromOffset(CONFIG.BadgeSize, CONFIG.BadgeSize)
    gui.StudsOffsetWorldSpace = Vector3.new(0, CONFIG.BillboardHeight, 0)
    gui.AlwaysOnTop = true
    gui.MaxDistance = CONFIG.BillboardMaxDistance
    gui.Parent = anchor

    local badge = Instance.new("Frame")
    badge.Size = UDim2.fromScale(1, 1)
    badge.BackgroundColor3 = color
    badge.BackgroundTransparency = 0.15
    badge.BorderSizePixel = 0
    badge.Parent = gui
    Instance.new("UICorner", badge).CornerRadius = UDim.new(1, 0)

    local stroke = Instance.new("UIStroke")
    stroke.Color = color
    stroke.Thickness = 1.5
    stroke.Transparency = 0.4
    stroke.Parent = badge

    local badgeText = Instance.new("TextLabel")
    badgeText.Size = UDim2.fromScale(1, 1)
    badgeText.BackgroundTransparency = 1
    badgeText.Font = Enum.Font.GothamBold
    badgeText.TextScaled = true
    badgeText.TextColor3 = THEME.Dark
    badgeText.Text = "?"
    badgeText.Parent = badge
    local bpad = Instance.new("UIPadding", badgeText)
    bpad.PaddingTop = UDim.new(0, 6)
    bpad.PaddingBottom = UDim.new(0, 6)

    -- текстовая пилюля (скрыта по умолчанию)
    local pill = Instance.new("Frame")
    pill.AnchorPoint = Vector2.new(0, 0.5)
    pill.Position = UDim2.new(1, 8, 0.5, 0)
    pill.Size = UDim2.fromOffset(150, 26)
    pill.BackgroundColor3 = THEME.Dark
    pill.BackgroundTransparency = 0.35
    pill.BorderSizePixel = 0
    pill.Visible = false
    pill.Parent = gui
    Instance.new("UICorner", pill).CornerRadius = UDim.new(1, 0)

    local label = Instance.new("TextLabel")
    label.Size = UDim2.fromScale(1, 1)
    label.BackgroundTransparency = 1
    label.Text = text
    label.TextColor3 = Color3.new(1, 1, 1)
    label.Font = Enum.Font.GothamMedium
    label.TextSize = 14
    label.TextTruncate = Enum.TextTruncate.AtEnd
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Parent = pill
    local lpad = Instance.new("UIPadding", label)
    lpad.PaddingLeft = UDim.new(0, 12)
    lpad.PaddingRight = UDim.new(0, 12)

    return {
        Anchor = anchor,
        GUI = gui,
        Label = label,
        Badge = badge,
        BadgeText = badgeText,
        Pill = pill,
        Stroke = stroke,
    }
end

-- ============================================================
--  ТРАНСФОРМ / ВЫДЕЛЕНИЕ / ЦВЕТ
-- ============================================================

local function applyTransform(step)
    local part = step.Part
    if not part then return end
    part.Size = Vector3.new(step.Width, CONFIG.ZoneThickness, step.Length)
    part.CFrame = CFrame.new(step.Center) * CFrame.Angles(0, step.RotationY, 0)

    -- подложка гизмо едет вместе с зоной
    if step.GizmoPart then
        step.GizmoPart.Size = part.Size
        step.GizmoPart.CFrame = part.CFrame * CFrame.new(0, CONFIG.GizmoOffset, 0)
    end

    if step.BB then
        step.BB.Anchor.Position = step.Center + Vector3.new(0, 0.5, 0)
    end
end

local function setPulse(step, on)
    if step.PulseTween then
        step.PulseTween:Cancel()
        step.PulseTween = nil
    end
    if not step.Highlight then return end
    step.Highlight.OutlineTransparency = 0
    if on then
        step.PulseTween = TweenService:Create(
            step.Highlight,
            TweenInfo.new(1.3, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
            { OutlineTransparency = 0.4 }
        )
        step.PulseTween:Play()
    end
end

local function updateSelectionVisuals()
    for i, step in ipairs(Steps) do
        local selected = (i == currentIndex)
        local active = selected or (step == hoveredStep)

        if step.Part then
            tween(step.Part, 0.15, {
                Transparency = active and CONFIG.FillSelected or CONFIG.FillIdle,
            })
            if step.Border then
                step.Border.SetTransparency(active and 0 or 0.3)
            end
            if step.Highlight then
                step.Highlight.Enabled = selected
            end
            setPulse(step, selected)
        end
        if step.BB then
            step.BB.Pill.Visible = active
            step.BB.BadgeText.Text = tostring(i)
            step.BB.Badge.BackgroundTransparency = active and 0.1 or 0.4
            step.BB.Stroke.Thickness = selected and 2 or 1
        end
    end
end

local function applyColor(step, color)
    step.Color = color
    if step.Part then step.Part.Color = color end
    if step.Border then step.Border.SetColor(color) end
    if step.Highlight then
        step.Highlight.FillColor = color
        step.Highlight.OutlineColor = color
    end
    if step.Handles then step.Handles.Color3 = color end
    if step.ArcHandles then step.ArcHandles.Color3 = color end
    if step.BB then
        step.BB.Stroke.Color = color
        step.BB.Badge.BackgroundColor3 = color
    end
end

-- ============================================================
--  ПРЕВЬЮ ПРИ СОЗДАНИИ (+ живой размер)
-- ============================================================

local previewPart, previewHighlight, previewBorder, previewLabel

local function clearPreview()
    if previewPart then
        previewPart:Destroy()
        previewPart, previewHighlight, previewBorder, previewLabel = nil, nil, nil, nil
    end
end

local function rectFromPoints(a, b)
    local dx, dz = math.abs(b.X - a.X), math.abs(b.Z - a.Z)
    local width, length
    if dx < 0.5 and dz < 0.5 then
        width, length = CONFIG.DefaultSize, CONFIG.DefaultSize
    else
        width = math.max(dx, CONFIG.MinSize)
        length = math.max(dz, CONFIG.MinSize)
    end
    local center = Vector3.new((a.X + b.X) / 2, a.Y + CONFIG.ZoneThickness / 2, (a.Z + b.Z) / 2)
    return center, width, length
end

local function updatePreview(a, b, color)
    local center, width, length = rectFromPoints(a, b)

    if not previewPart then
        previewPart = Instance.new("Part")
        previewPart.Name = "Preview"
        previewPart.Anchored = true
        previewPart.CanCollide = false
        previewPart.CanQuery = false
        previewPart.CanTouch = false
        previewPart.Material = Enum.Material.SmoothPlastic
        previewPart.Transparency = CONFIG.FillSelected
        previewPart.Parent = visualFolder

        previewBorder = createBorder(previewPart, color)

        previewHighlight = Instance.new("Highlight")
        previewHighlight.Adornee = previewPart
        previewHighlight.FillTransparency = 1
        previewHighlight.OutlineTransparency = 0.5
        previewHighlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        previewHighlight.Parent = previewPart

        local gui = Instance.new("BillboardGui")
        gui.Adornee = previewPart
        gui.Size = UDim2.fromOffset(90, 26)
        gui.StudsOffsetWorldSpace = Vector3.new(0, 2, 0)
        gui.AlwaysOnTop = true
        gui.MaxDistance = CONFIG.BillboardMaxDistance
        gui.Parent = previewPart

        previewLabel = Instance.new("TextLabel")
        previewLabel.Size = UDim2.fromScale(1, 1)
        previewLabel.BackgroundColor3 = THEME.Dark
        previewLabel.BackgroundTransparency = 0.3
        previewLabel.TextColor3 = Color3.new(1, 1, 1)
        previewLabel.Font = Enum.Font.GothamBold
        previewLabel.TextSize = 14
        previewLabel.Parent = gui
        Instance.new("UICorner", previewLabel).CornerRadius = UDim.new(1, 0)
    end

    previewPart.Color = color
    previewBorder.SetColor(color)
    previewHighlight.OutlineColor = color
    previewPart.Size = Vector3.new(width, CONFIG.ZoneThickness, length)
    previewPart.CFrame = CFrame.new(center)
    previewLabel.Text = ("%.0f × %.0f"):format(width, length)
end

-- ============================================================
--  ГИЗМО
--  Ручки живут на невидимой подложке GizmoOffset студов выше зоны.
--  MouseDrag отдаёт значение ОТ НАЧАЛА перетаскивания —
--  поэтому исходное состояние запоминаем на MouseButton1Down.
-- ============================================================

local function clearGizmos(step)
    if step.Handles then
        step.Handles:Destroy()
        step.Handles = nil
    end
    if step.ArcHandles then
        step.ArcHandles:Destroy()
        step.ArcHandles = nil
    end
    if step.GizmoPart then
        step.GizmoPart:Destroy()
        step.GizmoPart = nil
    end
end

local function cancelPointerActions()
    placing = false
    placeStart = nil
    dragStep = nil
    clearPreview()
end

local function showGizmos(step)
    if not step.Part or not step.Visible or step.Handles then return end

    -- невидимая подложка: ручки висят над зоной, а не на ней
    local gizmoPart = Instance.new("Part")
    gizmoPart.Name = "GizmoAnchor"
    gizmoPart.Size = step.Part.Size
    gizmoPart.CFrame = step.Part.CFrame * CFrame.new(0, CONFIG.GizmoOffset, 0)
    gizmoPart.Anchored = true
    gizmoPart.CanCollide = false
    gizmoPart.CanQuery = false
    gizmoPart.CanTouch = false
    gizmoPart.Transparency = 1
    gizmoPart.Parent = step.Folder
    step.GizmoPart = gizmoPart

    local handles = Instance.new("Handles")
    handles.Adornee = gizmoPart
    handles.Style = Enum.HandlesStyle.Resize
    handles.Faces = Faces.new(Enum.NormalId.Front, Enum.NormalId.Back, Enum.NormalId.Left, Enum.NormalId.Right)
    handles.Color3 = step.Color
    handles.Parent = playerGui

    local startW, startL, startCFrame

    handles.MouseButton1Down:Connect(function()
        gizmoDragging = true
        cancelPointerActions()
        startW, startL = step.Width, step.Length
        startCFrame = step.Part.CFrame
    end)

    handles.MouseButton1Up:Connect(function()
        gizmoDragging = false
        startW, startL, startCFrame = nil, nil, nil
        refreshUI()
    end)

    handles.MouseDrag:Connect(function(face, distance)
        if not startCFrame then return end
        local axis = FACE_AXIS[face]
        if not axis then return end

        local sideSize = (math.abs(axis.X) > 0) and startW or startL
        local d = snap(distance, CONFIG.GridSnap)
        d = math.max(d, CONFIG.MinSize - sideSize)

        if math.abs(axis.X) > 0 then
            step.Width = startW + d
        else
            step.Length = startL + d
        end
        step.Center = (startCFrame * CFrame.new(axis * (d / 2))).Position
        applyTransform(step)
        refreshUI()
    end)

    local arc = Instance.new("ArcHandles")
    arc.Adornee = gizmoPart
    arc.Axes = Axes.new(Enum.Axis.Y)
    arc.Color3 = step.Color
    arc.Parent = playerGui

    local startRot

    arc.MouseButton1Down:Connect(function()
        gizmoDragging = true
        cancelPointerActions()
        startRot = step.RotationY
    end)

    arc.MouseButton1Up:Connect(function()
        gizmoDragging = false
        startRot = nil
        refreshUI()
    end)

    arc.MouseDrag:Connect(function(axis, relativeAngle)
        if axis ~= Enum.Axis.Y or not startRot then return end
        local angle = relativeAngle
        if CONFIG.AngleSnapDeg > 0 then
            angle = math.rad(snap(math.deg(relativeAngle), CONFIG.AngleSnapDeg))
        end
        step.RotationY = (startRot + angle) % (math.pi * 2)
        applyTransform(step)
        refreshUI()
    end)

    step.Handles = handles
    step.ArcHandles = arc
end

-- ============================================================
--  ЗОНА
-- ============================================================

local function createZonePart(step)
    local part = Instance.new("Part")
    part.Name = "Zone"
    part.Anchored = true
    part.CanCollide = false
    part.CanQuery = true
    part.CanTouch = false
    part.Material = Enum.Material.SmoothPlastic
    part.Color = step.Color
    part.Transparency = CONFIG.FillIdle
    part.Parent = step.Folder

    step.Border = createBorder(part, step.Color)

    local highlight = Instance.new("Highlight")
    highlight.Adornee = part
    highlight.FillColor = step.Color
    highlight.OutlineColor = step.Color
    highlight.FillTransparency = 0.85
    highlight.OutlineTransparency = 0
    highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    highlight.Enabled = false -- только у выбранной (лимит Highlight)
    highlight.Parent = part

    step.Part = part
    step.Highlight = highlight
    PartToStep[part] = step

    step.BB = createBillboard(step.Center + Vector3.new(0, 0.5, 0), step.BillboardText, step.Color, step.Folder)

    applyTransform(step)
    updateSelectionVisuals()
end

local function destroyZone(step)
    clearGizmos(step)
    setPulse(step, false)
    if step.Part then
        PartToStep[step.Part] = nil
        step.Part:Destroy()
        step.Part, step.Highlight, step.Border = nil, nil, nil
    end
    if step.BB then
        step.BB.Anchor:Destroy()
        step.BB = nil
    end
    step.Center = nil
end

-- ============================================================
--  ШАГИ
-- ============================================================

local function createStep(name, color, text)
    local id = nextStepId
    nextStepId += 1
    name = name or ("Step " .. id)

    local step = {
        Id = id,
        Name = name,
        Color = color or PALETTE[((id - 1) % #PALETTE) + 1],
        BillboardText = text or name,
        Center = nil,
        Width = CONFIG.DefaultSize,
        Length = CONFIG.DefaultSize,
        RotationY = 0,
        Visible = true,
        Folder = nil,
        Part = nil,
        Highlight = nil,
        Border = nil,
        PulseTween = nil,
        Handles = nil,
        ArcHandles = nil,
        GizmoPart = nil,
        BB = nil,
    }

    step.Folder = Instance.new("Folder")
    step.Folder.Name = ("Step_%d"):format(id)
    step.Folder.Parent = visualFolder

    table.insert(Steps, step)
    return step, #Steps
end

local function removeStepAt(index)
    local step = Steps[index]
    if not step then return end
    clearGizmos(step)
    setPulse(step, false)
    if step.Part then
        PartToStep[step.Part] = nil
    end
    if hoveredStep == step then
        hoveredStep = nil
    end
    step.Folder:Destroy()
    table.remove(Steps, index)
end

selectStep = function(index)
    for _, s in ipairs(Steps) do
        clearGizmos(s)
    end

    currentIndex = (#Steps > 0) and math.clamp(index, 1, #Steps) or 0

    local step = getCurrentStep()
    if step and step.Part then
        showGizmos(step)
    end
    updateSelectionVisuals()
    refreshUI()
end

-- ============================================================
--  ЭКСПОРТ / ИМПОРТ — простой текстовый формат
--
--      [Step 1]
--      text     = Sniper here
--      color    = 0, 255, 140
--      position = 12.5, 0.1, -30
--      size     = 8 x 6
--      rotation = 45
--      visible  = true
-- ============================================================

local function fmt(n)
    local s = ("%.2f"):format(n)
    s = (s:gsub("%.?0+$", ""))
    if s == "-0" or s == "" then s = "0" end
    return s
end

local function cleanLine(s)
    return (tostring(s):gsub("[\r\n]", " "))
end

local function exportData()
    local lines = {
        "# PLACEMENT MAP",
        "# Правь значения как угодно и жми Import. Строки, начинающиеся с #, -- или //, — комментарии.",
        "# position = X, Y, Z     size = ширина x длина     rotation = градусы     color = R, G, B  (или #RRGGBB)",
        "",
    }

    for _, s in ipairs(Steps) do
        table.insert(lines, ("[%s]"):format((s.Name:gsub("[%[%]\r\n]", ""))))
        table.insert(lines, "text     = " .. cleanLine(s.BillboardText))
        table.insert(lines, ("color    = %d, %d, %d"):format(
            math.round(s.Color.R * 255), math.round(s.Color.G * 255), math.round(s.Color.B * 255)
        ))
        if s.Center then
            table.insert(lines, ("position = %s, %s, %s"):format(fmt(s.Center.X), fmt(s.Center.Y), fmt(s.Center.Z)))
            table.insert(lines, ("size     = %s x %s"):format(fmt(s.Width), fmt(s.Length)))
            table.insert(lines, "rotation = " .. fmt(math.deg(s.RotationY) % 360))
        end
        table.insert(lines, "visible  = " .. tostring(s.Visible))
        table.insert(lines, "")
    end

    return table.concat(lines, "\n")
end

local function parseNumbers(str)
    local nums = {}
    for n in str:gmatch("[-+]?%d*%.?%d+") do
        table.insert(nums, tonumber(n))
    end
    return nums
end

local function parseColor(str)
    local hex = str:match("^#?(%x%x%x%x%x%x)$")
    if hex then
        return Color3.fromHex(hex)
    end
    local n = parseNumbers(str)
    if #n >= 3 then
        return Color3.fromRGB(math.clamp(n[1], 0, 255), math.clamp(n[2], 0, 255), math.clamp(n[3], 0, 255))
    end
    return nil
end

local function parseBool(str)
    local v = str:lower()
    if v == "true" or v == "yes" or v == "1" or v == "on" then return true end
    if v == "false" or v == "no" or v == "0" or v == "off" then return false end
    return nil
end

local function parseMap(text)
    local entries, warnings = {}, {}
    local current
    local lineNo = 0

    for raw in (text .. "\n"):gmatch("(.-)\r?\n") do
        lineNo += 1
        local line = raw:match("^%s*(.-)%s*$")
        local c1, c2 = line:sub(1, 1), line:sub(1, 2)

        if line == "" or c1 == "#" or c2 == "--" or c2 == "//" then
            -- пропускаем
        else
            local section = line:match("^%[(.-)%]$")
            if section then
                current = { name = section }
                table.insert(entries, current)
            else
                local key, value = line:match("^([%a_]+)%s*[=:]%s*(.-)$")
                if not key then
                    table.insert(warnings, ("строка %d: не понял «%s»"):format(lineNo, line))
                elseif not current then
                    table.insert(warnings, ("строка %d: значение вне секции [Step]"):format(lineNo, line))
                else
                    key = key:lower()
                    if key == "name" then
                        current.name = value
                    elseif key == "text" or key == "label" then
                        current.text = value
                    elseif key == "color" or key == "colour" then
                        local col = parseColor(value)
                        if col then current.color = col else
                            table.insert(warnings, ("строка %d: плохой цвет «%s»"):format(lineNo, value))
                        end
                    elseif key == "position" or key == "pos" then
                        local n = parseNumbers(value)
                        if #n >= 3 then
                            current.center = Vector3.new(n[1], n[2], n[3])
                        else
                            table.insert(warnings, ("строка %d: position нужно 3 числа"):format(lineNo))
                        end
                    elseif key == "size" then
                        local n = parseNumbers(value)
                        if #n >= 1 then
                            current.width = n[1]
                            current.length = n[2] or n[1]
                        else
                            table.insert(warnings, ("строка %d: плохой size"):format(lineNo))
                        end
                    elseif key == "rotation" or key == "rot" or key == "angle" then
                        local n = parseNumbers(value)
                        if #n >= 1 then current.rotation = n[1] else
                            table.insert(warnings, ("строка %d: плохой rotation"):format(lineNo))
                        end
                    elseif key == "visible" or key == "show" then
                        local b = parseBool(value)
                        if b ~= nil then current.visible = b else
                            table.insert(warnings, ("строка %d: visible = true/false"):format(lineNo))
                        end
                    else
                        table.insert(warnings, ("строка %d: неизвестный ключ «%s»"):format(lineNo, key))
                    end
                end
            end
        end
    end

    return entries, warnings
end

local function importData(text)
    local entries, warnings = parseMap(text)
    if #entries == 0 then
        return false, "Не найдено ни одной секции [Step]"
    end

    for i = #Steps, 1, -1 do
        removeStepAt(i)
    end
    currentIndex = 0

    for _, e in ipairs(entries) do
        local name = (e.name ~= "") and e.name or nil
        local step = createStep(name, e.color, e.text)
        step.Visible = e.visible ~= false

        if e.center then
            step.Center = e.center
            step.Width = math.max(e.width or CONFIG.DefaultSize, CONFIG.MinSize)
            step.Length = math.max(e.length or CONFIG.DefaultSize, CONFIG.MinSize)
            step.RotationY = math.rad(e.rotation or 0)
            createZonePart(step)
        end
        if not step.Visible then
            step.Folder.Parent = nil
        end
    end

    selectStep(1)

    local msg = ("Загружено шагов: %d"):format(#entries)
    if #warnings > 0 then
        msg ..= (" • предупреждений: %d (%s)"):format(#warnings, warnings[1])
    end
    return true, msg
end

-- ============================================================
--  ВВОД
-- ============================================================

UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end
    if editorHidden and input.KeyCode ~= Enum.KeyCode.H then return end

    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        if gizmoDragging then return end

        local zoneStep, hitPos = raycastZone()
        if zoneStep then
            local idx = table.find(Steps, zoneStep)
            if idx and idx ~= currentIndex then
                selectStep(idx)
            end
            dragStep = zoneStep
            dragOffsetX = hitPos.X - zoneStep.Center.X
            dragOffsetZ = hitPos.Z - zoneStep.Center.Z
            return
        end

        local step = getCurrentStep()
        if step and not step.Center then
            local pos = raycastGround()
            if pos then
                placing = true
                placeStart = snapPoint(pos)
                updatePreview(placeStart, placeStart, step.Color)
            end
        end

    elseif input.KeyCode == Enum.KeyCode.LeftBracket then
        selectStep(currentIndex - 1)
    elseif input.KeyCode == Enum.KeyCode.RightBracket then
        selectStep(currentIndex + 1)
    elseif input.KeyCode == Enum.KeyCode.Delete then
        if getCurrentStep() then
            removeStepAt(currentIndex)
            selectStep(currentIndex)
        end
    elseif input.KeyCode == Enum.KeyCode.H then
        setEditorHidden(not editorHidden)
    elseif input.KeyCode == Enum.KeyCode.Escape then
        cancelPointerActions()
    end
end)

UserInputService.InputChanged:Connect(function(input)
    if input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
    if editorHidden then return end

    if placing and placeStart then
        local pos = raycastGround()
        local step = getCurrentStep()
        if pos and step then
            updatePreview(placeStart, snapPoint(pos), step.Color)
        end
    elseif dragStep then
        local pos = raycastGround()
        if pos then
            local x = snap(pos.X - dragOffsetX, CONFIG.GridSnap)
            local z = snap(pos.Z - dragOffsetZ, CONFIG.GridSnap)
            dragStep.Center = Vector3.new(x, pos.Y + CONFIG.ZoneThickness / 2, z)
            applyTransform(dragStep)
        end
    elseif not gizmoDragging then
        -- подсветка зоны под курсором
        local zoneStep = raycastZone()
        if zoneStep ~= hoveredStep then
            hoveredStep = zoneStep
            updateSelectionVisuals()
        end
    end
end)

UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end

    if placing then
        local step = getCurrentStep()
        local endRaw = raycastGround()
        local endPos = endRaw and snapPoint(endRaw) or placeStart

        if step and placeStart and endPos and not step.Center then
            local center, width, length = rectFromPoints(placeStart, endPos)
            step.Center, step.Width, step.Length = center, width, length
            createZonePart(step)
            showGizmos(step)
            refreshUI()
        end
        cancelPointerActions()
    elseif dragStep then
        dragStep = nil
        refreshUI()
    end

    gizmoDragging = false
end)

-- ============================================================
--  UI
-- ============================================================

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "PlacementMapBuilderUI"
screenGui.ResetOnSpawn = false
screenGui.Parent = playerGui

-- H: спрятать/показать весь редактор (визуал + панель + гизмо)
setEditorHidden = function(hidden)
    editorHidden = hidden
    cancelPointerActions()
    hoveredStep = nil
    for _, s in ipairs(Steps) do
        clearGizmos(s)
    end
    visualFolder.Parent = hidden and nil or Workspace
    screenGui.Enabled = not hidden
    if not hidden then
        local step = getCurrentStep()
        if step and step.Part then
            showGizmos(step)
        end
    end
end

local function styleFrame(f)
    Instance.new("UICorner", f).CornerRadius = UDim.new(0, 10)
    local st = Instance.new("UIStroke")
    st.Color = THEME.Border
    st.Thickness = 1
    st.Parent = f
end

local frame = Instance.new("Frame")
frame.Size = UDim2.fromOffset(270, 0)
frame.AutomaticSize = Enum.AutomaticSize.Y
frame.Position = UDim2.fromOffset(16, 16)
frame.BackgroundColor3 = THEME.Panel
frame.BackgroundTransparency = 0.05
frame.BorderSizePixel = 0
frame.Parent = screenGui
styleFrame(frame)

local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 8)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = frame

local padding = Instance.new("UIPadding")
padding.PaddingTop = UDim.new(0, 12)
padding.PaddingBottom = UDim.new(0, 12)
padding.PaddingLeft = UDim.new(0, 12)
padding.PaddingRight = UDim.new(0, 12)
padding.Parent = frame

local function makeLabel(text, order, height, parent)
    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, 0, 0, height or 20)
    lbl.BackgroundTransparency = 1
    lbl.Text = text
    lbl.TextColor3 = THEME.Text
    lbl.Font = Enum.Font.Gotham
    lbl.TextSize = 13
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.LayoutOrder = order or 0
    lbl.Parent = parent or frame
    return lbl
end

-- variant: nil | "primary" | "danger"
local function makeButton(text, order, parent, size, variant)
    local base = (variant == "primary") and PALETTE[1] or THEME.Button
    local hover = (variant == "primary") and PALETTE[1]:Lerp(Color3.new(1, 1, 1), 0.25)
        or (variant == "danger") and THEME.Danger
        or THEME.ButtonHover

    local btn = Instance.new("TextButton")
    btn.Size = size or UDim2.new(1, 0, 0, 32)
    btn.BackgroundColor3 = base
    btn.TextColor3 = (variant == "primary") and THEME.Dark or THEME.Text
    btn.Font = Enum.Font.GothamMedium
    btn.TextSize = 13
    btn.Text = text
    btn.AutoButtonColor = false
    btn.LayoutOrder = order or 0
    btn.Parent = parent or frame
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 8)

    btn.MouseEnter:Connect(function() tween(btn, 0.12, { BackgroundColor3 = hover }) end)
    btn.MouseLeave:Connect(function() tween(btn, 0.12, { BackgroundColor3 = base }) end)
    return btn
end

local function makeRow(order, height)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, height)
    row.BackgroundTransparency = 1
    row.LayoutOrder = order
    row.Parent = frame
    local l = Instance.new("UIListLayout")
    l.FillDirection = Enum.FillDirection.Horizontal
    l.Padding = UDim.new(0, 6)
    l.Parent = row
    return row
end

-- заголовок с акцентной полоской (цвет = цвет текущего шага)
local header = Instance.new("Frame")
header.Size = UDim2.new(1, 0, 0, 24)
header.BackgroundTransparency = 1
header.LayoutOrder = 1
header.Parent = frame

local accentBar = Instance.new("Frame")
accentBar.Size = UDim2.fromOffset(4, 20)
accentBar.Position = UDim2.fromOffset(0, 2)
accentBar.BackgroundColor3 = PALETTE[1]
accentBar.BorderSizePixel = 0
accentBar.Parent = header
Instance.new("UICorner", accentBar).CornerRadius = UDim.new(1, 0)

local title = makeLabel("Placement Map Builder", 0, 24, header)
title.Position = UDim2.fromOffset(14, 0)
title.Size = UDim2.new(1, -14, 1, 0)
title.Font = Enum.Font.GothamBold
title.TextSize = 16

local statusLabel = makeLabel("", 2, 34)
statusLabel.TextWrapped = true
statusLabel.TextColor3 = THEME.Muted
statusLabel.TextYAlignment = Enum.TextYAlignment.Top

-- чипы шагов
local chipsFrame = Instance.new("Frame")
chipsFrame.Size = UDim2.new(1, 0, 0, 0)
chipsFrame.AutomaticSize = Enum.AutomaticSize.Y
chipsFrame.BackgroundTransparency = 1
chipsFrame.LayoutOrder = 3
chipsFrame.Parent = frame
local chipsGrid = Instance.new("UIGridLayout")
chipsGrid.CellSize = UDim2.fromOffset(30, 30)
chipsGrid.CellPadding = UDim2.fromOffset(5, 5)
chipsGrid.SortOrder = Enum.SortOrder.LayoutOrder
chipsGrid.Parent = chipsFrame

local nameBox = Instance.new("TextBox")
nameBox.Size = UDim2.new(1, 0, 0, 32)
nameBox.PlaceholderText = "Текст таблички (напр. 'Sniper here')"
nameBox.PlaceholderColor3 = THEME.Muted
nameBox.Text = ""
nameBox.BackgroundColor3 = THEME.Panel2
nameBox.TextColor3 = THEME.Text
nameBox.Font = Enum.Font.Gotham
nameBox.TextSize = 13
nameBox.ClearTextOnFocus = false
nameBox.LayoutOrder = 4
nameBox.Parent = frame
Instance.new("UICorner", nameBox).CornerRadius = UDim.new(0, 8)
local nameStroke = Instance.new("UIStroke")
nameStroke.Color = THEME.Border
nameStroke.Parent = nameBox
nameBox.Focused:Connect(function() tween(nameStroke, 0.15, { Color = PALETTE[1] }) end)
nameBox.FocusLost:Connect(function() tween(nameStroke, 0.15, { Color = THEME.Border }) end)

local newStepBtn = makeButton("＋  New Step", 5, nil, nil, "primary")

local navRow = makeRow(6, 32)
local half = UDim2.new(0.5, -3, 1, 0)
local prevBtn = makeButton("◀  Prev", 0, navRow, half)
local nextBtn = makeButton("Next  ▶", 0, navRow, half)

local actionRow = makeRow(7, 32)
local visibilityBtn = makeButton("Hide", 0, actionRow, half)
local resetRectBtn = makeButton("Reset Rect", 0, actionRow, half)

local deleteBtn = makeButton("Delete Step", 8, nil, nil, "danger")

local colorRow = makeRow(9, 28)
local dataBtn = makeButton("Export / Import", 10)

local hint = makeLabel(
    "Тяни по земле — создать зону\nКлик по зоне — двигать • ручки — размер\nКольцо — поворот • [ ] — шаги • Del — удалить\nH — спрятать редактор",
    11, 62
)
hint.TextWrapped = true
hint.TextYAlignment = Enum.TextYAlignment.Top
hint.TextColor3 = THEME.Muted
hint.TextSize = 11

-- --- панель данных ---

local dataFrame = Instance.new("Frame")
dataFrame.Size = UDim2.fromOffset(400, 380)
dataFrame.Position = UDim2.fromOffset(300, 16)
dataFrame.BackgroundColor3 = THEME.Panel
dataFrame.BackgroundTransparency = 0.05
dataFrame.BorderSizePixel = 0
dataFrame.Visible = false
dataFrame.Parent = screenGui
styleFrame(dataFrame)

local dataTitle = makeLabel("Export / Import", 0, 22, dataFrame)
dataTitle.Position = UDim2.fromOffset(14, 10)
dataTitle.Size = UDim2.new(1, -28, 0, 22)
dataTitle.Font = Enum.Font.GothamBold
dataTitle.TextSize = 15

local scroll = Instance.new("ScrollingFrame")
scroll.Position = UDim2.fromOffset(14, 40)
scroll.Size = UDim2.new(1, -28, 0, 250)
scroll.BackgroundColor3 = THEME.Panel2
scroll.BorderSizePixel = 0
scroll.ScrollBarThickness = 5
scroll.CanvasSize = UDim2.new()
scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
scroll.Parent = dataFrame
Instance.new("UICorner", scroll).CornerRadius = UDim.new(0, 8)

local dataBox = Instance.new("TextBox")
dataBox.Size = UDim2.new(1, -8, 0, 250)
dataBox.AutomaticSize = Enum.AutomaticSize.Y
dataBox.BackgroundTransparency = 1
dataBox.TextColor3 = THEME.Text
dataBox.Font = Enum.Font.Code
dataBox.TextSize = 13
dataBox.MultiLine = true
dataBox.TextWrapped = true
dataBox.ClearTextOnFocus = false
dataBox.TextXAlignment = Enum.TextXAlignment.Left
dataBox.TextYAlignment = Enum.TextYAlignment.Top
dataBox.PlaceholderText = "Нажми Export, чтобы получить текст карты,\nили вставь сюда свой и нажми Import"
dataBox.PlaceholderColor3 = THEME.Muted
dataBox.Text = ""
dataBox.Parent = scroll
local dbPad = Instance.new("UIPadding", dataBox)
dbPad.PaddingLeft = UDim.new(0, 8)
dbPad.PaddingTop = UDim.new(0, 6)

local exportBtn = makeButton("Export", 0, dataFrame, UDim2.new(0.5, -20, 0, 32), "primary")
exportBtn.Position = UDim2.fromOffset(14, 300)
local importBtn = makeButton("Import", 0, dataFrame, UDim2.new(0.5, -20, 0, 32))
importBtn.Position = UDim2.fromOffset(0.5, 6, 0, 300)

local dataStatus = makeLabel("", 0, 32, dataFrame)
dataStatus.Position = UDim2.fromOffset(14, 340)
dataStatus.Size = UDim2.new(1, -28, 0, 32)
dataStatus.TextWrapped = true
dataStatus.TextYAlignment = Enum.TextYAlignment.Top
dataStatus.TextColor3 = THEME.Muted
dataStatus.TextSize = 12

-- ============================================================
--  ПРИВЯЗКА UI К ЛОГИКЕ
-- ============================================================

local lastChipSig = ""

local function rebuildChips()
    local parts = { tostring(currentIndex) }
    for _, s in ipairs(Steps) do
        table.insert(parts, ("%s%d%d"):format(s.Color:ToHex(), s.Visible and 1 or 0, s.Center and 1 or 0))
    end
    local sig = table.concat(parts, "|")
    if sig == lastChipSig then return end
    lastChipSig = sig

    for _, child in ipairs(chipsFrame:GetChildren()) do
        if child:IsA("TextButton") then child:Destroy() end
    end

    for i, step in ipairs(Steps) do
        local chip = Instance.new("TextButton")
        chip.Text = tostring(i)
        chip.LayoutOrder = i
        chip.BackgroundColor3 = step.Color
        chip.BackgroundTransparency = (not step.Visible) and 0.85 or (step.Center and 0 or 0.55)
        chip.TextColor3 = THEME.Dark
        chip.TextTransparency = (not step.Visible) and 0.5 or 0
        chip.Font = Enum.Font.GothamBold
        chip.TextSize = 14
        chip.AutoButtonColor = true
        chip.Parent = chipsFrame
        Instance.new("UICorner", chip).CornerRadius = UDim.new(0, 8)

        if i == currentIndex then
            local st = Instance.new("UIStroke")
            st.Color = Color3.new(1, 1, 1)
            st.Thickness = 2
            st.Parent = chip
        end

        chip.MouseButton1Click:Connect(function()
            selectStep(i)
        end)
    end
end

refreshUI = function()
    local step = getCurrentStep()
    if step then
        local dims = step.Center
            and ("%.0f x %.0f  •  %d°"):format(step.Width, step.Length, math.floor(math.deg(step.RotationY) + 0.5) % 360)
            or "не размещена — тяни по земле"
        statusLabel.Text = ("Шаг %d из %d — %s\n%s"):format(currentIndex, #Steps, step.Name, dims)
        if not nameBox:IsFocused() then
            nameBox.Text = step.BillboardText
        end
        visibilityBtn.Text = step.Visible and "Hide" or "Show"
        tween(accentBar, 0.2, { BackgroundColor3 = step.Color })
    else
        statusLabel.Text = "Нет шагов — нажми New Step"
        nameBox.Text = ""
    end
    rebuildChips()
end

newStepBtn.MouseButton1Click:Connect(function()
    local _, index = createStep()
    selectStep(index)
end)

nameBox.FocusLost:Connect(function()
    local step = getCurrentStep()
    if step then
        step.BillboardText = nameBox.Text
        if step.BB then
            step.BB.Label.Text = nameBox.Text
        end
    end
end)

prevBtn.MouseButton1Click:Connect(function()
    selectStep(currentIndex - 1)
end)

nextBtn.MouseButton1Click:Connect(function()
    selectStep(currentIndex + 1)
end)

visibilityBtn.MouseButton1Click:Connect(function()
    local step = getCurrentStep()
    if not step then return end
    step.Visible = not step.Visible
    step.Folder.Parent = step.Visible and visualFolder or nil
    clearGizmos(step)
    if step.Visible then
        showGizmos(step)
    end
    refreshUI()
end)

resetRectBtn.MouseButton1Click:Connect(function()
    local step = getCurrentStep()
    if not step then return end
    destroyZone(step)
    refreshUI()
end)

deleteBtn.MouseButton1Click:Connect(function()
    if not getCurrentStep() then return end
    removeStepAt(currentIndex)
    selectStep(currentIndex)
end)

for _, color in ipairs(PALETTE) do
    local swatch = Instance.new("TextButton")
    swatch.Size = UDim2.new(0, 36, 1, 0)
    swatch.BackgroundColor3 = color
    swatch.Text = ""
    swatch.AutoButtonColor = true
    swatch.Parent = colorRow
    Instance.new("UICorner", swatch).CornerRadius = UDim.new(0, 8)

    swatch.MouseButton1Click:Connect(function()
        local step = getCurrentStep()
        if step then
            applyColor(step, color)
            refreshUI()
        end
    end)
end

dataBtn.MouseButton1Click:Connect(function()
    dataFrame.Visible = not dataFrame.Visible
end)

exportBtn.MouseButton1Click:Connect(function()
    local text = exportData()
    dataBox.Text = text
    print(text)
    dataStatus.Text = "Готово. Выдели текст (Ctrl+A, Ctrl+C) — он также выведен в Output."
end)

importBtn.MouseButton1Click:Connect(function()
    local _, msg = importData(dataBox.Text)
    dataStatus.Text = msg
end)

-- ============================================================
--  ИНИЦИАЛИЗАЦИЯ
-- ============================================================

local _, firstIndex = createStep()
selectStep(firstIndex)
