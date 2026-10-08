--[[
    ============================================================
    PLACEMENT MAP BUILDER v5.1 — LIBRARY EDITION
    ============================================================
    Load with loadstring. The file RETURNS an API table:

        local PMB = loadstring(game:HttpGet("YOUR_RAW_URL_HERE"))()

    ► EDIT MODE (no arguments):
        PMB()

    ► INSTRUCTION MODE (playback):
        PMB({
            autoPlay = false, stepTime = 5, camFollow = true,
            showAllLabels = true, loop = true, append = false,
            data = "exported map text",       -- OR:
            steps = { { text = "Sniper here", position = {10,0,-20},
                        size = {6,6}, rotation = 45, color = {86,214,145} } },
        })
        PMB("exported map text")   -- raw string also works

    ► PROGRAMMATIC:
        PMB:Edit()  PMB:Play(cfg)  PMB:Preview()  PMB:Destroy()
        PMB:RebuildMenu()

    Hotkeys (playback): ← → or [ ] navigate • Space = auto-play • H = hide visuals
    Hotkeys (edit):     drag = create/move • handles = resize • ring = rotate (45° snap)
                        [ ] steps • Del = delete • Esc = cancel • H = hide
    ============================================================
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local FLUENT_URL = "https://github.com/StyearX/Fluent-Modded/releases/download/1.6.0/main.lua"

local GBridge = (typeof(getgenv) == "function") and getgenv() or _G
if GBridge.__PMB and type(GBridge.__PMB.Destroy) == "function" then
    pcall(GBridge.__PMB.Destroy)
end

local API = {}

-- ============================================================
--  CONFIG
-- ============================================================

local CONFIG = {
    GridSnap = 1,
    AngleSnapDeg = 45,         -- default rotation snap (was 5) — Settings slider can lower it
    MinSize = 1,
    DefaultSize = 4,
    ZoneThickness = 0.2,

    FillIdle = 0.95,
    FillSelected = 0.75,
    CornerLength = 0.25,
    CornerThickness = 3,
    OutlineTransparency = 0.7,

    BillboardHeight = 2.5,
    BillboardMaxDistance = 120,
    BadgeSize = 34,

    GizmoOffset = 2,
    RotRingSize = 3,           -- fixed-size rotation ring, does NOT scale with the zone
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

local FACE_AXIS = {
    [Enum.NormalId.Right] = Vector3.new(1, 0, 0),
    [Enum.NormalId.Left]  = Vector3.new(-1, 0, 0),
    [Enum.NormalId.Back]  = Vector3.new(0, 0, 1),
    [Enum.NormalId.Front] = Vector3.new(0, 0, -1),
}

-- ============================================================
--  STATE
-- ============================================================

local playback = {
    active = false,
    autoPlaying = false,
    stepTime = 5,
    camFollow = true,
    showAllLabels = true,
    loop = true,
    thread = nil,
}

local Steps = {}
local currentIndex = 0
local nextStepId = 1
local PartToStep = {}
local Connections = {}

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

local Fluent, Window, Tabs
local statusPara, playbackPara, labelInput, stepDropdown
local autoplayToggle, camFollowToggle, labelsToggle, visibilityToggle, hiddenToggle
local dataGui, dataBox, dataStatus, hudGui, hudTitle, hudBody
local fbRefs = {}

local labelSyncing, dropdownSyncing, autoSyncing, hiddenSyncing = false, false, false, false
local menuStats = { elements = 0, errors = {} }

-- forward declarations
local refreshUI, selectStep, setEditorHidden, refreshPlaybackUI, focusCameraOnStep, teleportToCurrentStep
local buildFallbackPanel, buildMenu, destroyMenu
local createStep, duplicateStep, clearGizmos, applyColor, startPlayback, setAutoPlaying, exitPlayback

-- ============================================================
--  UTILITIES
-- ============================================================

local function notify(title, content, dur)
    if Fluent and type(Fluent) == "table" then
        pcall(function()
            Fluent:Notify({ Title = title, Content = content, Duration = dur or 4 })
        end)
    end
end

local function snap(value, increment)
    if not increment or increment <= 0 then return value end
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

local function setParagraph(p, title, content)
    if not p then return end
    pcall(function()
        if p.SetTitle then p:SetTitle(title) end
        if p.SetDesc then p:SetDesc(content)
        elseif p.SetContent then p:SetContent(content) end
    end)
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
--  VISUALS
-- ============================================================

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
        Anchor = anchor, GUI = gui, Label = label,
        Badge = badge, BadgeText = badgeText, Pill = pill, Stroke = stroke,
    }
end

-- ============================================================
--  TRANSFORM / SELECTION / COLOR
-- ============================================================

local function applyTransform(step)
    local part = step.Part
    if not part then return end
    part.Size = Vector3.new(step.Width, CONFIG.ZoneThickness, step.Length)
    part.CFrame = CFrame.new(step.Center) * CFrame.Angles(0, step.RotationY, 0)

    if step.GizmoPart then
        step.GizmoPart.Size = part.Size
        step.GizmoPart.CFrame = part.CFrame * CFrame.new(0, CONFIG.GizmoOffset, 0)
    end

    -- fixed-size rotation ring stays centered above the zone
    if step.RotAnchor then
        step.RotAnchor.CFrame = CFrame.new(step.Center + Vector3.new(0, CONFIG.GizmoOffset, 0))
            * CFrame.Angles(0, step.RotationY, 0)
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
            local idle = playback.active and 0.86 or CONFIG.FillIdle
            tween(step.Part, 0.15, { Transparency = active and CONFIG.FillSelected or idle })
            if step.Border then
                step.Border.SetTransparency(active and 0 or (playback.active and 0.15 or 0.3))
            end
            if step.Highlight then
                step.Highlight.Enabled = selected
            end
            setPulse(step, selected)
        end
        if step.BB then
            step.BB.Pill.Visible = active or (playback.active and playback.showAllLabels)
            step.BB.BadgeText.Text = tostring(i)
            step.BB.Badge.BackgroundTransparency = active and 0.1 or 0.4
            step.BB.Stroke.Thickness = selected and 2 or 1
        end
    end
end

applyColor = function(step, color)
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
--  CAMERA
-- ============================================================

focusCameraOnStep = function(step, instant)
    if not (step and step.Center) then return end
    local cam = Workspace.CurrentCamera
    if not cam then return end

    local radius = math.max(step.Width, step.Length)
    local dist = math.clamp(radius * 1.4 + 16, 18, 120)
    local offset = Vector3.new(dist * 0.45, dist * 0.75, dist * 0.55)
    local target = CFrame.lookAt(step.Center + offset, step.Center)

    if instant then
        cam.CFrame = target
        return
    end
    TweenService:Create(cam, TweenInfo.new(0.9, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { CFrame = target }):Play()
end

teleportToCurrentStep = function()
    local step = getCurrentStep()
    if not (step and step.Center) then return end
    local char = player.Character
    local hrp = char and (char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart)
    if hrp then
        hrp.CFrame = CFrame.new(step.Center + Vector3.new(0, 5, 0))
        notify("Teleport", ("Moved to step %d"):format(currentIndex), 3)
    end
end

-- ============================================================
--  CREATE PREVIEW
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
--  GIZMOS
-- ============================================================

clearGizmos = function(step)
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
    if step.RotAnchor then
        step.RotAnchor:Destroy()
        step.RotAnchor = nil
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
    if playback.active then return end

    -- resize plate: matches the zone, handles sit at its edges
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

    -- separate small anchor for the rotation ring so huge zones stay rotatable
    local rotAnchor = Instance.new("Part")
    rotAnchor.Name = "RotAnchor"
    rotAnchor.Size = Vector3.new(CONFIG.RotRingSize, 0.1, CONFIG.RotRingSize)
    rotAnchor.CFrame = CFrame.new(step.Center + Vector3.new(0, CONFIG.GizmoOffset, 0))
    rotAnchor.Anchored = true
    rotAnchor.CanCollide = false
    rotAnchor.CanQuery = false
    rotAnchor.CanTouch = false
    rotAnchor.Transparency = 1
    rotAnchor.Parent = step.Folder
    step.RotAnchor = rotAnchor

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
    arc.Adornee = rotAnchor
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
--  ZONES
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
    highlight.Enabled = false
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
--  STEPS
-- ============================================================

createStep = function(name, color, text)
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
        RotAnchor = nil,
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

duplicateStep = function(index)
    local src = Steps[index]
    if not src then return nil end
    local step = createStep(src.Name .. " copy", src.Color, src.BillboardText)
    step.Width, step.Length = src.Width, src.Length
    step.RotationY = src.RotationY
    step.Visible = src.Visible
    if src.Center then
        step.Center = src.Center + Vector3.new(step.Width + 1, 0, 0)
        createZonePart(step)
        if not step.Visible then
            step.Folder.Parent = nil
        end
    end
    return step, #Steps
end

local function clearAllSteps()
    for i = #Steps, 1, -1 do
        removeStepAt(i)
    end
    currentIndex = 0
end

selectStep = function(index)
    for _, s in ipairs(Steps) do
        clearGizmos(s)
    end

    currentIndex = (#Steps > 0) and math.clamp(index, 1, #Steps) or 0

    local step = getCurrentStep()
    if step and step.Part and step.Visible and not playback.active then
        showGizmos(step)
    end

    if playback.active and playback.camFollow and step then
        focusCameraOnStep(step, false)
    end

    updateSelectionVisuals()
    refreshUI()
end

-- ============================================================
--  EXPORT / IMPORT
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
        "# Edit values freely and press Import. Lines starting with #, -- or // are comments.",
        "# position = X, Y, Z     size = width x length     rotation = degrees     color = R, G, B (or #RRGGBB)",
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

local function toColor3(c)
    if typeof(c) == "Color3" then return c end
    if type(c) == "string" then return parseColor(c) end
    if type(c) == "table" then
        if c.R then return Color3.new(c.R, c.G, c.B) end
        if #c >= 3 then
            if (c[1] > 1 or c[2] > 1 or c[3] > 1) then
                return Color3.fromRGB(c[1], c[2], c[3])
            end
            return Color3.new(c[1], c[2], c[3])
        end
    end
    return nil
end

local function toVector3(v)
    if typeof(v) == "Vector3" then return v end
    if typeof(v) == "Vector2" then return Vector3.new(v.X, 0, v.Y) end
    if type(v) == "table" then
        local x = v.X or v.x or v[1]
        local y = v.Y or v.y or v[2] or 0
        local z = v.Z or v.z or v[3]
        if x and z then return Vector3.new(x, y, z) end
        return nil
    end
    if type(v) == "string" then
        local n = parseNumbers(v)
        if #n >= 3 then return Vector3.new(n[1], n[2], n[3]) end
    end
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
            -- comment
        else
            local section = line:match("^%[(.-)%]$")
            if section then
                current = { name = section }
                table.insert(entries, current)
            else
                local key, value = line:match("^([%a_]+)%s*[=:]%s*(.-)$")
                if not key then
                    table.insert(warnings, ("line %d: could not parse '%s'"):format(lineNo, line))
                elseif not current then
                    table.insert(warnings, ("line %d: value outside a [Step] section"):format(lineNo))
                else
                    key = key:lower()
                    if key == "name" then
                        current.name = value
                    elseif key == "text" or key == "label" then
                        current.text = value
                    elseif key == "color" or key == "colour" then
                        local col = parseColor(value)
                        if col then current.color = col else
                            table.insert(warnings, ("line %d: bad color '%s'"):format(lineNo, value))
                        end
                    elseif key == "position" or key == "pos" then
                        local n = parseNumbers(value)
                        if #n >= 3 then
                            current.center = Vector3.new(n[1], n[2], n[3])
                        else
                            table.insert(warnings, ("line %d: position needs 3 numbers"):format(lineNo))
                        end
                    elseif key == "size" then
                        local n = parseNumbers(value)
                        if #n >= 1 then
                            current.width = n[1]
                            current.length = n[2] or n[1]
                        else
                            table.insert(warnings, ("line %d: bad size"):format(lineNo))
                        end
                    elseif key == "rotation" or key == "rot" or key == "angle" then
                        local n = parseNumbers(value)
                        if #n >= 1 then current.rotation = n[1] else
                            table.insert(warnings, ("line %d: bad rotation"):format(lineNo))
                        end
                    elseif key == "visible" or key == "show" then
                        local b = parseBool(value)
                        if b ~= nil then current.visible = b else
                            table.insert(warnings, ("line %d: visible = true/false"):format(lineNo))
                        end
                    else
                        table.insert(warnings, ("line %d: unknown key '%s'"):format(lineNo, key))
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
        return false, "No [Step] sections found"
    end

    clearAllSteps()

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

    local msg = ("Loaded %d steps"):format(#entries)
    if #warnings > 0 then
        msg ..= (" • %d warnings (%s)"):format(#warnings, warnings[1])
    end
    return true, msg
end

local function buildFromStepTable(list)
    for _, e in ipairs(list) do
        local name = e.name or e.title
        local color = toColor3(e.color)
        local text = e.text or e.label or name
        local step = createStep(name, color, text)

        local pos = toVector3(e.position or e.pos or e.center)
        if pos then
            local size = e.size
            if typeof(size) == "Vector2" then
                step.Width, step.Length = size.X, size.Y
            elseif type(size) == "table" then
                step.Width = math.max(tonumber(size[1] or size.Width or size.x) or CONFIG.DefaultSize, CONFIG.MinSize)
                step.Length = math.max(tonumber(size[2] or size.Length or size.z or size[1]) or CONFIG.DefaultSize, CONFIG.MinSize)
            elseif type(size) == "number" then
                step.Width, step.Length = size, size
            end
            step.RotationY = math.rad(tonumber(e.rotation or e.rot or e.angle) or 0)
            step.Center = pos
            createZonePart(step)
        end

        step.Visible = (e.visible ~= false)
        if not step.Visible then
            step.Folder.Parent = nil
        end
    end
end

-- ============================================================
--  PLAYBACK ENGINE
-- ============================================================

setAutoPlaying = function(on)
    playback.autoPlaying = on
    if playback.thread then
        pcall(task.cancel, playback.thread)
        playback.thread = nil
    end
    if on and playback.active and #Steps > 0 then
        playback.thread = task.spawn(function()
            while playback.active and playback.autoPlaying do
                for _ = 1, math.max(1, math.floor(playback.stepTime * 10)) do
                    if not (playback.active and playback.autoPlaying) then return end
                    task.wait(0.1)
                end
                local nextIdx = currentIndex + 1
                if nextIdx > #Steps then
                    if playback.loop == false then
                        playback.autoPlaying = false
                        playback.thread = nil
                        if autoplayToggle and autoplayToggle.Set then
                            autoSyncing = true
                            pcall(function() autoplayToggle:Set(false) end)
                            autoSyncing = false
                        end
                        refreshPlaybackUI()
                        return
                    end
                    nextIdx = 1
                end
                selectStep(nextIdx)
            end
        end)
    end
    if playback.active then
        refreshPlaybackUI()
    end
end

startPlayback = function(config)
    config = config or {}
    setAutoPlaying(false)

    playback.active = true
    playback.stepTime = tonumber(config.stepTime) or 5
    playback.camFollow = config.camFollow ~= false
    playback.showAllLabels = config.showAllLabels ~= false
    playback.loop = config.loop ~= false

    cancelPointerActions()
    for _, s in ipairs(Steps) do
        clearGizmos(s)
    end

    if #Steps > 0 then
        currentIndex = 1
        updateSelectionVisuals()
        if playback.camFollow then
            focusCameraOnStep(getCurrentStep(), true)
        end
    end

    autoSyncing = true
    if autoplayToggle and autoplayToggle.Set then
        pcall(function() autoplayToggle:Set(config.autoPlay == true) end)
    end
    autoSyncing = false
    if camFollowToggle and camFollowToggle.Set then
        pcall(function() camFollowToggle:Set(playback.camFollow) end)
    end
    if labelsToggle and labelsToggle.Set then
        pcall(function() labelsToggle:Set(playback.showAllLabels) end)
    end
    if config.autoPlay then
        setAutoPlaying(true)
    end

    pcall(function()
        if Tabs and Tabs.Playback then Tabs.Playback:Select() end
    end)

    refreshPlaybackUI()
    notify("Instruction mode",
        (#Steps > 0) and ("Loaded %d steps. Arrows / [ ] navigate • Space = auto-play."):format(#Steps)
        or "No steps found in the instructions.", 5)
end

exitPlayback = function()
    setAutoPlaying(false)
    playback.active = false
    updateSelectionVisuals()
    local step = getCurrentStep()
    if step and step.Part and step.Visible then
        showGizmos(step)
    end
    refreshUI()
end

-- ============================================================
--  INPUT
-- ============================================================

table.insert(Connections, UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end

    if playback.active then
        if input.KeyCode == Enum.KeyCode.Left or input.KeyCode == Enum.KeyCode.LeftBracket then
            selectStep(currentIndex - 1)
        elseif input.KeyCode == Enum.KeyCode.Right or input.KeyCode == Enum.KeyCode.RightBracket then
            selectStep(currentIndex + 1)
        elseif input.KeyCode == Enum.KeyCode.Space then
            setAutoPlaying(not playback.autoPlaying)
        elseif input.KeyCode == Enum.KeyCode.H then
            setEditorHidden(not editorHidden)
        end
        return
    end

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
end))

table.insert(Connections, UserInputService.InputChanged:Connect(function(input)
    if input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
    if editorHidden or playback.active then return end

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
        local zoneStep = raycastZone()
        if zoneStep ~= hoveredStep then
            hoveredStep = zoneStep
            updateSelectionVisuals()
        end
    end
end))

table.insert(Connections, UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
    if playback.active then return end

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
end))

-- ============================================================
--  HIDE / SHOW EDITOR
-- ============================================================

setEditorHidden = function(hidden)
    editorHidden = hidden
    cancelPointerActions()
    hoveredStep = nil
    for _, s in ipairs(Steps) do
        clearGizmos(s)
    end
    visualFolder.Parent = hidden and nil or Workspace
    if not hidden and not playback.active then
        local step = getCurrentStep()
        if step and step.Part then
            showGizmos(step)
        end
    end
    hiddenSyncing = true
    if hiddenToggle and type(hiddenToggle.Set) == "function" then
        pcall(function() hiddenToggle:Set(hidden) end)
    end
    hiddenSyncing = false
end

-- ============================================================
--  DATA EDITOR (custom multiline window — Fluent has no multiline input)
-- ============================================================

dataGui = Instance.new("ScreenGui")
dataGui.Name = "PMB_DataEditor"
dataGui.ResetOnSpawn = false
dataGui.DisplayOrder = 40
dataGui.Enabled = false
dataGui.Parent = playerGui

local dataFrame = Instance.new("Frame")
dataFrame.Size = UDim2.fromOffset(420, 400)
dataFrame.Position = UDim2.new(0.5, -210, 0.5, -200)
dataFrame.BackgroundColor3 = THEME.Panel
dataFrame.BackgroundTransparency = 0.05
dataFrame.BorderSizePixel = 0
dataFrame.Parent = dataGui
Instance.new("UICorner", dataFrame).CornerRadius = UDim.new(0, 10)
local dataStroke = Instance.new("UIStroke")
dataStroke.Color = THEME.Border
dataStroke.Parent = dataFrame

local dataTitle = Instance.new("TextLabel")
dataTitle.Position = UDim2.fromOffset(14, 10)
dataTitle.Size = UDim2.new(1, -28, 0, 22)
dataTitle.BackgroundTransparency = 1
dataTitle.Text = "Export / Import"
dataTitle.TextColor3 = THEME.Text
dataTitle.Font = Enum.Font.GothamBold
dataTitle.TextSize = 15
dataTitle.TextXAlignment = Enum.TextXAlignment.Left
dataTitle.Parent = dataFrame

local scroll = Instance.new("ScrollingFrame")
scroll.Position = UDim2.fromOffset(14, 40)
scroll.Size = UDim2.new(1, -28, 0, 240)
scroll.BackgroundColor3 = THEME.Panel2
scroll.BorderSizePixel = 0
scroll.ScrollBarThickness = 5
scroll.CanvasSize = UDim2.new()
scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
scroll.Parent = dataFrame
Instance.new("UICorner", scroll).CornerRadius = UDim.new(0, 8)

dataBox = Instance.new("TextBox")
dataBox.Size = UDim2.new(1, -8, 0, 240)
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
dataBox.PlaceholderText = "Press Export to get the map text,\nor paste your own and press Import"
dataBox.PlaceholderColor3 = THEME.Muted
dataBox.Text = ""
dataBox.Parent = scroll
local dbPad = Instance.new("UIPadding", dataBox)
dbPad.PaddingLeft = UDim.new(0, 8)
dbPad.PaddingTop = UDim.new(0, 6)

local function dButton(text, x, callback)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(0, 122, 0, 30)
    b.Position = UDim2.fromOffset(x, 292)
    b.BackgroundColor3 = THEME.Button
    b.TextColor3 = THEME.Text
    b.Font = Enum.Font.GothamMedium
    b.TextSize = 13
    b.Text = text
    b.AutoButtonColor = true
    b.Parent = dataFrame
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 8)
    b.MouseButton1Click:Connect(callback)
end

dButton("Export", 14, function()
    dataBox.Text = exportData()
    dataStatus.Text = "Exported — also printed to Output. Select all (Ctrl+A) and copy."
end)

dButton("Import", 149, function()
    local _, msg = importData(dataBox.Text)
    dataStatus.Text = tostring(msg)
    notify("Import", tostring(msg), 4)
end)

dButton("Close", 284, function()
    dataGui.Enabled = false
end)

dataStatus = Instance.new("TextLabel")
dataStatus.Position = UDim2.fromOffset(14, 330)
dataStatus.Size = UDim2.new(1, -28, 0, 56)
dataStatus.BackgroundTransparency = 1
dataStatus.Text = ""
dataStatus.TextWrapped = true
dataStatus.TextYAlignment = Enum.TextYAlignment.Top
dataStatus.TextColor3 = THEME.Muted
dataStatus.Font = Enum.Font.Gotham
dataStatus.TextSize = 12
dataStatus.TextXAlignment = Enum.TextXAlignment.Left
dataStatus.Parent = dataFrame

-- ============================================================
--  PLAYBACK HUD (independent of Fluent)
-- ============================================================

hudGui = Instance.new("ScreenGui")
hudGui.Name = "PMB_PlaybackHUD"
hudGui.ResetOnSpawn = false
hudGui.DisplayOrder = 50
hudGui.Parent = playerGui

local hud = Instance.new("Frame")
hud.AnchorPoint = Vector2.new(0.5, 0)
hud.Position = UDim2.new(0.5, 0, 0, 12)
hud.Size = UDim2.fromOffset(440, 58)
hud.BackgroundColor3 = THEME.Panel
hud.BackgroundTransparency = 0.12
hud.BorderSizePixel = 0
hud.Visible = false
hud.Parent = hudGui
Instance.new("UICorner", hud).CornerRadius = UDim.new(0, 12)
local hudStroke = Instance.new("UIStroke")
hudStroke.Color = THEME.Border
hudStroke.Parent = hud

hudTitle = Instance.new("TextLabel")
hudTitle.Position = UDim2.fromOffset(14, 6)
hudTitle.Size = UDim2.new(1, -28, 0, 18)
hudTitle.BackgroundTransparency = 1
hudTitle.Text = "Playback"
hudTitle.TextColor3 = THEME.Text
hudTitle.Font = Enum.Font.GothamBold
hudTitle.TextSize = 14
hudTitle.TextXAlignment = Enum.TextXAlignment.Left
hudTitle.Parent = hud

hudBody = Instance.new("TextLabel")
hudBody.Position = UDim2.fromOffset(14, 26)
hudBody.Size = UDim2.new(1, -28, 0, 26)
hudBody.BackgroundTransparency = 1
hudBody.Text = ""
hudBody.TextColor3 = THEME.Muted
hudBody.Font = Enum.Font.Gotham
hudBody.TextSize = 13
hudBody.TextWrapped = true
hudBody.TextTruncate = Enum.TextTruncate.AtEnd
hudBody.TextXAlignment = Enum.TextXAlignment.Left
hudBody.Parent = hud

-- ============================================================
--  FALLBACK PANEL (only used if Fluent is completely unavailable)
-- ============================================================

buildFallbackPanel = function()
    if fbRefs.Frame then return end

    local sg = Instance.new("ScreenGui")
    sg.Name = "PMB_FallbackPanel"
    sg.ResetOnSpawn = false
    sg.DisplayOrder = 45
    sg.Parent = playerGui

    local frame = Instance.new("Frame")
    frame.Size = UDim2.fromOffset(250, 0)
    frame.AutomaticSize = Enum.AutomaticSize.Y
    frame.Position = UDim2.fromOffset(16, 16)
    frame.BackgroundColor3 = THEME.Panel
    frame.BackgroundTransparency = 0.05
    frame.BorderSizePixel = 0
    frame.Parent = sg
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 10)
    local fst = Instance.new("UIStroke")
    fst.Color = THEME.Border
    fst.Parent = frame

    local list = Instance.new("UIListLayout")
    list.Padding = UDim.new(0, 6)
    list.SortOrder = Enum.SortOrder.LayoutOrder
    list.Parent = frame
    local fpad = Instance.new("UIPadding")
    fpad.PaddingTop = UDim.new(0, 10)
    fpad.PaddingBottom = UDim.new(0, 10)
    fpad.PaddingLeft = UDim.new(0, 10)
    fpad.PaddingRight = UDim.new(0, 10)
    fpad.Parent = frame

    local function label(text, order, h)
        local l = Instance.new("TextLabel")
        l.Size = UDim2.new(1, 0, 0, h or 16)
        l.BackgroundTransparency = 1
        l.Text = text
        l.TextColor3 = THEME.Muted
        l.Font = Enum.Font.Gotham
        l.TextSize = 12
        l.TextXAlignment = Enum.TextXAlignment.Left
        l.LayoutOrder = order
        l.Parent = frame
        return l
    end

    local function button(text, order, cb)
        local b = Instance.new("TextButton")
        b.Size = UDim2.new(1, 0, 0, 28)
        b.BackgroundColor3 = THEME.Button
        b.TextColor3 = THEME.Text
        b.Font = Enum.Font.GothamMedium
        b.TextSize = 13
        b.Text = text
        b.AutoButtonColor = true
        b.LayoutOrder = order
        b.Parent = frame
        Instance.new("UICorner", b).CornerRadius = UDim.new(0, 8)
        b.MouseButton1Click:Connect(cb)
        return b
    end

    local function row(order)
        local r = Instance.new("Frame")
        r.Size = UDim2.new(1, 0, 0, 28)
        r.BackgroundTransparency = 1
        r.LayoutOrder = order
        r.Parent = frame
        local rl = Instance.new("UIListLayout")
        rl.FillDirection = Enum.FillDirection.Horizontal
        rl.Padding = UDim.new(0, 6)
        rl.Parent = r
        return r
    end

    local function halfBtn(parent, text, cb)
        local b = Instance.new("TextButton")
        b.Size = UDim2.new(0.5, -3, 1, 0)
        b.BackgroundColor3 = THEME.Button
        b.TextColor3 = THEME.Text
        b.Font = Enum.Font.GothamMedium
        b.TextSize = 13
        b.Text = text
        b.AutoButtonColor = true
        b.Parent = parent
        Instance.new("UICorner", b).CornerRadius = UDim.new(0, 8)
        b.MouseButton1Click:Connect(cb)
        return b
    end

    local ttl = label("Placement Map Builder", 0, 20)
    ttl.Font = Enum.Font.GothamBold
    ttl.TextSize = 15
    ttl.TextColor3 = THEME.Text

    fbRefs.Status = label("", 1, 40)
    fbRefs.Status.TextWrapped = true
    fbRefs.Status.TextYAlignment = Enum.TextYAlignment.Top

    local nameBox = Instance.new("TextBox")
    nameBox.Size = UDim2.new(1, 0, 0, 28)
    nameBox.LayoutOrder = 2
    nameBox.PlaceholderText = "Billboard text"
    nameBox.PlaceholderColor3 = THEME.Muted
    nameBox.Text = ""
    nameBox.BackgroundColor3 = THEME.Panel2
    nameBox.TextColor3 = THEME.Text
    nameBox.Font = Enum.Font.Gotham
    nameBox.TextSize = 13
    nameBox.ClearTextOnFocus = false
    nameBox.Parent = frame
    Instance.new("UICorner", nameBox).CornerRadius = UDim.new(0, 8)
    fbRefs.Name = nameBox
    nameBox.FocusLost:Connect(function()
        local step = getCurrentStep()
        if step then
            step.BillboardText = nameBox.Text
            if step.BB then step.BB.Label.Text = nameBox.Text end
        end
    end)

    button("＋  New Step", 3, function()
        local _, i = createStep()
        selectStep(i)
    end)

    button("Duplicate Step", 4, function()
        local s, i = duplicateStep(currentIndex)
        if s then selectStep(i) end
    end)

    local nav = row(5)
    halfBtn(nav, "◀ Prev", function() selectStep(currentIndex - 1) end)
    halfBtn(nav, "Next ▶", function() selectStep(currentIndex + 1) end)

    local act = row(6)
    halfBtn(act, "Delete", function()
        if getCurrentStep() then
            removeStepAt(currentIndex)
            selectStep(currentIndex)
        end
    end)
    halfBtn(act, "Hide (H)", function() setEditorHidden(not editorHidden) end)

    button("▶  Preview as instructions", 7, function() startPlayback({}) end)
    fbRefs.Auto = button("Auto-play: OFF", 8, function()
        setAutoPlaying(not playback.autoPlaying)
    end)
    button("Teleport to step", 9, function() teleportToCurrentStep() end)
    button("Export / Import", 10, function()
        dataGui.Enabled = not dataGui.Enabled
    end)

    local colorRow = row(11)
    for _, color in ipairs(PALETTE) do
        local sw = Instance.new("TextButton")
        sw.Size = UDim2.new(0.2, -5, 1, 0)
        sw.BackgroundColor3 = color
        sw.Text = ""
        sw.AutoButtonColor = true
        sw.Parent = colorRow
        Instance.new("UICorner", sw).CornerRadius = UDim.new(0, 8)
        sw.MouseButton1Click:Connect(function()
            local step = getCurrentStep()
            if step then
                applyColor(step, color)
                refreshUI()
            end
        end)
    end

    local note = label("Emergency panel (Fluent unavailable). Hotkeys still work.", 12, 28)
    note.TextWrapped = true
    fbRefs.Frame = frame
end

-- ============================================================
--  UI REFRESH
-- ============================================================

refreshUI = function()
    local step = getCurrentStep()
    if step then
        local dims
        if step.Center then
            dims = ("%.0f × %.0f  •  %d°"):format(step.Width, step.Length, math.floor(math.deg(step.RotationY) + 0.5) % 360)
        else
            dims = "not placed — drag on the ground to draw the zone"
        end
        setParagraph(statusPara,
            ("Step %d / %d — %s"):format(currentIndex, #Steps, step.Name),
            dims .. "\nLabel: " .. tostring(step.BillboardText))

        labelSyncing = true
        if labelInput and type(labelInput.Set) == "function" then
            pcall(function() labelInput:Set(tostring(step.BillboardText)) end)
        end
        labelSyncing = false

        if visibilityToggle and type(visibilityToggle.Set) == "function" then
            pcall(function() visibilityToggle:Set(step.Visible) end)
        end

        if fbRefs.Status then
            local fdims = step.Center and ("%.0f x %.0f"):format(step.Width, step.Length) or "not placed"
            fbRefs.Status.Text = ("Step %d/%d — %s\n%s"):format(currentIndex, #Steps, step.Name, fdims)
            if not fbRefs.Name:IsFocused() then
                fbRefs.Name.Text = tostring(step.BillboardText)
            end
        end
    else
        setParagraph(statusPara, "No steps", "Press New Step to begin.")
        if fbRefs.Status then
            fbRefs.Status.Text = "No steps — press New Step"
            fbRefs.Name.Text = ""
        end
    end

    if stepDropdown then
        dropdownSyncing = true
        local values, current = { "-" }, "-"
        if #Steps > 0 then
            values = {}
            for i, s in ipairs(Steps) do
                values[i] = i .. ") " .. tostring(s.Name)
            end
            local cs = getCurrentStep()
            if cs then current = currentIndex .. ") " .. cs.Name end
        end
        pcall(function() if stepDropdown.SetValues then stepDropdown:SetValues(values) end end)
        pcall(function() if stepDropdown.Set then stepDropdown:Set(current) end end)
        dropdownSyncing = false
    end

    if playback.active then
        refreshPlaybackUI()
    end
end

refreshPlaybackUI = function()
    local step = getCurrentStep()
    if not step then
        setParagraph(playbackPara, "Playback idle", "No steps available.")
        hud.Visible = false
        if fbRefs.Auto then fbRefs.Auto.Text = "Auto-play: OFF" end
        return
    end

    local suffix = playback.autoPlaying and ("  ▶  auto (%.0fs/step)"):format(playback.stepTime) or ""
    local title = ("Step %d / %d — %s%s"):format(currentIndex, #Steps, step.Name, suffix)
    local body = tostring(step.BillboardText or step.Name)

    setParagraph(playbackPara, title, body)
    hud.Visible = playback.active
    hudTitle.Text = title
    hudBody.Text = body

    if fbRefs.Auto then
        fbRefs.Auto.Text = playback.autoPlaying and "Auto-play: ON" or "Auto-play: OFF"
    end
end

-- ============================================================
--  INITIALIZATION (before menu — editor works even if the menu fails)
-- ============================================================

do
    local _, idx = createStep()
    selectStep(idx)
end

-- ============================================================
--  FLUENT MENU
-- ============================================================

destroyMenu = function()
    if Window and type(Window.Destroy) == "function" then
        pcall(function() Window:Destroy() end)
    end
    Window, Tabs = nil, nil
end

buildMenu = function()
    destroyMenu()
    menuStats.elements = 0
    menuStats.errors = {}

    if not Fluent then
        local ok = pcall(function()
            Fluent = loadstring(game:HttpGet(FLUENT_URL))()
        end)
        if not ok or type(Fluent) ~= "table" then
            Fluent = nil
            warn("[PMB] Fluent could not be loaded — switching to fallback panel")
            return false
        end
    end

    pcall(function() Fluent.NotifyInsideWindow = true end)

    -- register a complete theme (the fork's AddTheme is the proven way to guarantee
    -- every color key exists — no nil lookups during element creation)
    pcall(function()
        Fluent:AddTheme({
            Name = "PMB Noir",
            Accent = "#b4b4c3",
            AcrylicMain = "#0c0c0e",
            AcrylicBorder = "#28282d",
            AcrylicGradient = ColorSequence.new({
                ColorSequenceKeypoint.new(0,    Color3.fromHex("#0a0a0c")),
                ColorSequenceKeypoint.new(0.33, Color3.fromHex("#121216")),
                ColorSequenceKeypoint.new(0.66, Color3.fromHex("#16161c")),
                ColorSequenceKeypoint.new(1,    Color3.fromHex("#19191e")),
            }),
            AcrylicNoise = 0.9,
            TitleBarLine = "#50505f",
            Tab = "#141417",
            Element = "#121215",
            ElementBorder = "#323237",
            InElementBorder = "#232328",
            ElementTransparency = 0.92,
            ElementBorderThickness = 1,
            ToggleSlider = "#37373c",
            ToggleToggled = "#c8c8d7",
            SliderRail = "#2d2d32",
            CheckboxUnchecked = "#28282d",
            CheckboxChecked = "#c8c8d7",
            CheckboxCheck = "#0f0f12",
            ProgressBarRail = "#232328",
            ProgressBarFill = "#c8c8d7",
            DropdownFrame = "#0f0f12",
            DropdownHolder = "#141418",
            DropdownBorder = "#323237",
            DropdownOption = "#19191d",
            DropdownBorderThickness = 1,
            Keybind = "#1e1e22",
            Input = "#141418",
            InputFocused = "#1e1e23",
            InputIndicator = "#b4b4c3",
            Dialog = "#0e0e11",
            DialogHolder = "#141418",
            DialogHolderLine = "#323237",
            DialogButton = "#32323a",
            DialogButtonBorder = "#4b4b55",
            DialogBorder = "#2d2d32",
            DialogInput = "#16161a",
            DialogInputLine = "#a0a0af",
            Text = "#ebebf0",
            SubText = "#8c8c94",
            Hover = "#232328",
            HoverChange = 0.06,
            Background = "",
            BackgroundTransparency = 1,
            ViewportBackground = Color3.fromHex("#101014"),
            ViewportBackgroundImages = false,
            DropdownOutsideWindowBackground = Color3.fromHex("#0a0a0e"),
            DropdownOutsideWindowBackgroundImages = false,
            ShineEnabled = false,
            StrokeShine = false,
            StrokeDark = Color3.fromHex("#19191e"),
            ButtonGradient = {
                Background = ColorSequence.new({
                    ColorSequenceKeypoint.new(0, Color3.fromHex("#2d2d34")),
                    ColorSequenceKeypoint.new(1, Color3.fromHex("#19191e")),
                }),
                Stroke = ColorSequence.new({
                    ColorSequenceKeypoint.new(0,   Color3.fromHex("#646473")),
                    ColorSequenceKeypoint.new(0.5, Color3.fromHex("#41414b")),
                    ColorSequenceKeypoint.new(1,   Color3.fromHex("#646473")),
                }),
            },
            DiscordJoinButton = "#5865f2",
            WarningNotifyColor = "#c8a028",
            SuccessNotifyColor = "#3cb45a",
            ErrorNotifyColor = "#c83232",
            InfoNotifyColor = "#5096dc",
        })
    end)

    local okW, errW = pcall(function()
        Window = Fluent:CreateWindow({
            Title = "Placement Map Builder",
            SubTitle = "v5.1 — edit + playback",
            TabWidth = 150,
            Size = UDim2.fromOffset(580, 480),
            Acrylic = false,
            Theme = "PMB Noir",
            Font = "GothamSSm",
            FolderName = "PlacementMapBuilder",
            ScreenGuiName = "PlacementMapBuilderUI",
            Search = {
                Search = true,
                Highlight = true,
                HighlightColor = Color3.fromRGB(160, 160, 175),
            },
        })
    end)
    if not okW or not Window then
        warn("[PMB] CreateWindow failed: " .. tostring(errW))
        Window = nil
        return false
    end

    local tabObjects = {}
    local function addTab(name, cfg)
        local ok, tab = pcall(function() return Window:AddTab(cfg) end)
        if ok and tab then
            tabObjects[name] = tab
        else
            warn("[PMB] AddTab failed: " .. name .. " | " .. tostring(tab))
        end
    end

    addTab("Editor",   { Title = "Editor",   Icon = "image" })
    addTab("Playback", { Title = "Playback", Icon = "circle-dot" })
    addTab("Data",     { Title = "Data",     Icon = "info" })
    addTab("Settings", { Title = "Settings", Icon = "settings" })
    Tabs = tabObjects

    local secCount = { Editor = 0, Playback = 0, Data = 0, Settings = 0 }

    local function safeAdd(label, fn)
        local ok, res = pcall(fn)
        if ok then
            menuStats.elements += 1
            return res
        end
        table.insert(menuStats.errors, ("%s -> %s"):format(label, tostring(res)))
        warn("[PMB] element failed: " .. label .. " | " .. tostring(res))
        return nil
    end

    local function addSection(tabName, title, icon)
        local tab = tabObjects[tabName]
        if not tab then return nil end
        local sec = safeAdd(tabName .. "/section '" .. title .. "'", function()
            return tab:AddSection(title, icon)
        end)
        if sec then
            secCount[tabName] += 1
        end
        return sec
    end

    -- ================= EDITOR =================
    local secEdit = addSection("Editor", "Step editing", "solar/gauge-bold")
    if secEdit then
        statusPara = safeAdd("Editor/status", function()
            return secEdit:AddParagraph({ Title = "No steps", Content = "Press New Step to begin." })
        end)

        labelInput = safeAdd("Editor/labelInput", function()
            return secEdit:AddInput("PMB_Label", {
                Title = "Billboard text",
                Placeholder = "e.g. 'Sniper here'",
                TextHint = "e.g. 'Sniper here'",
                Default = "",
                Finished = true,
                Callback = function(v)
                    if labelSyncing then return end
                    local step = getCurrentStep()
                    if step then
                        step.BillboardText = v
                        if step.BB then step.BB.Label.Text = v end
                        if playback.active then refreshPlaybackUI() end
                    end
                end,
            })
        end)

        safeAdd("Editor/newStep", function()
            return secEdit:AddButton({ Title = "New Step", Description = "Adds an empty step", Callback = function()
                local _, idx = createStep()
                selectStep(idx)
            end })
        end)

        safeAdd("Editor/duplicate", function()
            return secEdit:AddButton({ Title = "Duplicate Step", Description = "Copies the current zone, offset to the side", Callback = function()
                local s, i = duplicateStep(currentIndex)
                if s then selectStep(i) end
            end })
        end)

        safeAdd("Editor/prev", function()
            return secEdit:AddButton({ Title = "◀  Previous step", Callback = function()
                selectStep(currentIndex - 1)
            end })
        end)

        safeAdd("Editor/next", function()
            return secEdit:AddButton({ Title = "Next step  ▶", Callback = function()
                selectStep(currentIndex + 1)
            end })
        end)

        stepDropdown = safeAdd("Editor/stepDropdown", function()
            return secEdit:AddDropdown("PMB_StepSelect", {
                Title = "Jump to step",
                Values = { "-" },
                Default = "-",
                ThemedDropdown = true,
                Callback = function(v)
                    if dropdownSyncing then return end
                    local n = tonumber(tostring(v):match("^(%d+)"))
                    if n then selectStep(n) end
                end,
            })
        end)

        safeAdd("Editor/divider", function() return secEdit:AddDivider() end)

        safeAdd("Editor/focus", function()
            return secEdit:AddButton({ Title = "Focus camera", Description = "Fly the camera to the current zone", Callback = function()
                focusCameraOnStep(getCurrentStep(), false)
            end })
        end)

        safeAdd("Editor/resetRect", function()
            return secEdit:AddButton({ Title = "Reset rect", Description = "Detach the zone so you can redraw it", Callback = function()
                local step = getCurrentStep()
                if step then
                    destroyZone(step)
                    refreshUI()
                end
            end })
        end)

        visibilityToggle = safeAdd("Editor/visibleToggle", function()
            return secEdit:AddToggle("PMB_Visible", {
                Title = "Zone visible",
                Default = true,
                Callback = function(v)
                    local step = getCurrentStep()
                    if not step or v == step.Visible then return end
                    step.Visible = v
                    step.Folder.Parent = v and visualFolder or nil
                    clearGizmos(step)
                    if v and not playback.active then showGizmos(step) end
                    refreshUI()
                end,
            })
        end)

        safeAdd("Editor/delete", function()
            return secEdit:AddButton({ Title = "Delete step", Callback = function()
                if getCurrentStep() then
                    removeStepAt(currentIndex)
                    selectStep(currentIndex)
                end
            end })
        end)

        safeAdd("Editor/colorpicker", function()
            return secEdit:AddColorpicker("PMB_Color", {
                Title = "Zone color",
                Default = PALETTE[1],
                Callback = function(c)
                    local step = getCurrentStep()
                    if step then applyColor(step, c) end
                end,
            })
        end)

        safeAdd("Editor/preview", function()
            return secEdit:AddButton({ Title = "▶  Preview as instructions", Description = "Plays your current steps in playback mode", Callback = function()
                startPlayback({})
            end })
        end)

        safeAdd("Editor/hotkeys", function()
            return secEdit:AddParagraph({
                Title = "Hotkeys",
                Content = "Drag ground = create • drag zone = move • handles = resize • ring = rotate (45° snap)\n[ ] = prev/next • Del = delete • Esc = cancel • H = hide visuals",
            })
        end)
    end

    -- ================= PLAYBACK =================
    local secPlay = addSection("Playback", "Instruction playback", "solar/toggle-on-circle-bold")
    if secPlay then
        playbackPara = safeAdd("Playback/status", function()
            return secPlay:AddParagraph({
                Title = "Playback idle",
                Content = "Load the library with an instruction table/string, or press 'Preview as instructions' in the Editor tab.",
            })
        end)

        safeAdd("Playback/prev", function()
            return secPlay:AddButton({ Title = "◀  Previous", Callback = function()
                if playback.active then selectStep(currentIndex - 1) end
            end })
        end)

        safeAdd("Playback/next", function()
            return secPlay:AddButton({ Title = "Next  ▶", Callback = function()
                if playback.active then selectStep(currentIndex + 1) end
            end })
        end)

        autoplayToggle = safeAdd("Playback/autoplay", function()
            return secPlay:AddToggle("PMB_AutoPlay", {
                Title = "Auto-play",
                Description = "Advance steps automatically",
                Default = false,
                Callback = function(v)
                    if autoSyncing then return end
                    setAutoPlaying(v)
                end,
            })
        end)

        camFollowToggle = safeAdd("Playback/camFollow", function()
            return secPlay:AddToggle("PMB_CamFollow", {
                Title = "Camera follows steps",
                Default = true,
                Callback = function(v)
                    playback.camFollow = v
                    if v and playback.active then
                        focusCameraOnStep(getCurrentStep(), false)
                    end
                end,
            })
        end)

        labelsToggle = safeAdd("Playback/allLabels", function()
            return secPlay:AddToggle("PMB_AllLabels", {
                Title = "Show all step labels",
                Default = true,
                Callback = function(v)
                    playback.showAllLabels = v
                    updateSelectionVisuals()
                end,
            })
        end)

        safeAdd("Playback/stepTime", function()
            return secPlay:AddSlider("PMB_StepTime", {
                Title = "Seconds per step (auto-play)",
                Min = 1, Max = 15, Default = playback.stepTime, Rounding = 0,
                Callback = function(v) playback.stepTime = v end,
            })
        end)

        safeAdd("Playback/divider", function() return secPlay:AddDivider() end)

        safeAdd("Playback/teleport", function()
            return secPlay:AddButton({ Title = "Teleport to current step", Callback = function()
                teleportToCurrentStep()
            end })
        end)

        safeAdd("Playback/exit", function()
            return secPlay:AddButton({ Title = "Exit playback", Callback = function()
                exitPlayback()
            end })
        end)

        safeAdd("Playback/hotkeys", function()
            return secPlay:AddParagraph({
                Title = "Hotkeys",
                Content = "← → or [ ] = navigate • Space = auto-play on/off • H = hide visuals",
            })
        end)
    end

    -- ================= DATA =================
    local secData = addSection("Data", "Map data", "lucide/star")
    if secData then
        safeAdd("Data/format", function()
            return secData:AddParagraph({
                Title = "Format",
                Content = "Sections look like [Step 1] with text / color / position / size / rotation / visible keys. Lines starting with #, -- or // are comments. Import replaces all steps.",
            })
        end)

        safeAdd("Data/export", function()
            return secData:AddButton({ Title = "Export → open data window", Callback = function()
                if dataBox then
                    dataBox.Text = exportData()
                    dataGui.Enabled = true
                end
                print("[PMB] Export:\n" .. exportData())
            end })
        end)

        safeAdd("Data/import", function()
            return secData:AddButton({ Title = "Import ← data window", Callback = function()
                if dataBox then
                    local _, msg = importData(dataBox.Text)
                    dataStatus.Text = tostring(msg)
                    dataGui.Enabled = true
                    notify("Import", tostring(msg), 4)
                end
            end })
        end)

        safeAdd("Data/toggle", function()
            return secData:AddButton({ Title = "Show / hide data window", Callback = function()
                dataGui.Enabled = not dataGui.Enabled
            end })
        end)
    end

    -- ================= SETTINGS =================
    local secSet = addSection("Settings", "Builder settings", "solar/cursor-bold")
    if secSet then
        hiddenToggle = safeAdd("Settings/hide", function()
            return secSet:AddToggle("PMB_HideWorld", {
                Title = "Hide world visuals (H)",
                Default = false,
                Callback = function(v)
                    if hiddenSyncing then return end
                    setEditorHidden(v)
                end,
            })
        end)

        safeAdd("Settings/grid", function()
            return secSet:AddSlider("PMB_Grid", {
                Title = "Grid snap (studs)",
                Min = 0, Max = 10, Default = CONFIG.GridSnap, Rounding = 0,
                Callback = function(v) CONFIG.GridSnap = v end,
            })
        end)

        safeAdd("Settings/angle", function()
            return secSet:AddSlider("PMB_Angle", {
                Title = "Rotation snap (degrees)",
                Min = 0, Max = 90, Default = CONFIG.AngleSnapDeg, Rounding = 0,
                Callback = function(v) CONFIG.AngleSnapDeg = v end,
            })
        end)

        safeAdd("Settings/bbDist", function()
            return secSet:AddSlider("PMB_BBDist", {
                Title = "Label render distance",
                Min = 40, Max = 500, Default = CONFIG.BillboardMaxDistance, Rounding = 0,
                Callback = function(v)
                    CONFIG.BillboardMaxDistance = v
                    for _, s in ipairs(Steps) do
                        if s.BB then s.BB.GUI.MaxDistance = v end
                    end
                end,
            })
        end)

        safeAdd("Settings/divider", function() return secSet:AddDivider() end)

        safeAdd("Settings/rebuild", function()
            return secSet:AddButton({ Title = "Rebuild menu", Description = "Re-runs the Fluent UI builder (use if tabs look broken)", Callback = function()
                API.RebuildMenu()
            end })
        end)

        safeAdd("Settings/destroy", function()
            return secSet:AddButton({ Title = "Destroy builder", Description = "Removes everything this script created", Callback = function()
                API.Destroy()
            end })
        end)
    end

    -- custom empty-state text on any tab that ended up empty
    for name, tab in pairs(tabObjects) do
        if secCount[name] == 0 then
            pcall(function()
                tab:SetEmptyState({
                    Text = "Section failed to load",
                    SubText = "Press F9 and look for [PMB] lines, then use Settings > Rebuild menu",
                    Icon = "lucide/face-angry",
                })
            end)
        end
    end

    print(("[PMB] Menu built — %d elements, %d errors"):format(menuStats.elements, #menuStats.errors))
    return true
end

-- build the menu; fall back to the emergency panel if Fluent is hopeless
do
    local ok = buildMenu()
    if not ok then
        buildFallbackPanel()
    elseif menuStats.elements == 0 then
        warn("[PMB] Fluent window built but zero elements loaded — switching to fallback panel")
        destroyMenu()
        buildFallbackPanel()
    end
end

-- ============================================================
--  API
-- ============================================================

function API.Play(config)
    config = config or {}
    if config.data then
        local ok, msg = importData(tostring(config.data))
        if not ok then
            notify("Playback", tostring(msg), 5)
        end
    elseif type(config.steps) == "table" then
        if not config.append then
            clearAllSteps()
        end
        buildFromStepTable(config.steps)
        if #Steps > 0 then
            selectStep(1)
        end
    end
    startPlayback(config)
end

function API.Edit()
    if playback.active then
        exitPlayback()
    elseif #Steps == 0 then
        local _, idx = createStep()
        selectStep(idx)
    else
        selectStep(currentIndex)
    end
    notify("Edit mode", "Drag on the ground to create zones. Use the window for controls.", 4)
end

function API.Preview()
    startPlayback({})
end

function API.RebuildMenu()
    if buildMenu() then
        notify("Menu", ("Rebuilt — %d elements"):format(menuStats.elements), 3)
        if menuStats.elements == 0 then
            destroyMenu()
            buildFallbackPanel()
        end
    else
        buildFallbackPanel()
        notify("Menu", "Fluent unavailable — fallback panel active", 4)
    end
end

function API.Destroy()
    if playback.thread then
        pcall(task.cancel, playback.thread)
    end
    playback.active = false
    for _, c in ipairs(Connections) do
        pcall(function() c:Disconnect() end)
    end
    table.clear(Connections)
    destroyMenu()
    pcall(function() if visualFolder then visualFolder:Destroy() end end)
    pcall(function() if dataGui then dataGui:Destroy() end end)
    pcall(function() if hudGui then hudGui:Destroy() end end)
    if fbRefs.Frame and fbRefs.Frame.Parent then
        fbRefs.Frame.Parent:Destroy()
    end
    if GBridge.__PMB == API then
        GBridge.__PMB = nil
    end
end

setmetatable(API, {
    __call = function(_, arg)
        if type(arg) == "table" then
            return API.Play(arg)
        elseif type(arg) == "string" then
            return API.Play({ data = arg })
        end
        return API.Edit()
    end,
})

GBridge.__PMB = API

notify("Placement Map Builder", "Loaded — PMB() = edit mode • PMB(config) or PMB(text) = playback", 6)

return API
