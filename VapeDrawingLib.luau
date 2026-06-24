--!nocheck
--[[
    VapeDrawingLib — A complete port of the VapeV4 GUI architecture to Drawing.new
    =============================================================================
    Public API mirrors VapeV4:
        mainapi:CreateCategory{Name=}
        category:CreateModule{Name=, Tooltip=, Function=}
        module:CreateToggle{Name=, Default=, Function=}
        module:CreateButton{Name=, Function=}
        module:CreateSlider{Name=, Min=, Max=, Default=, Decimals=, Suffix=, Function=}
        module:CreateTwoSlider{Name=, Min=, Max=, DefaultMin=, DefaultMax=, Function=}
        module:CreateDropdown{Name=, List=, Default=, Function=}
        module:CreateTextBox{Name=, Default=, Placeholder=, Function=}
        module:CreateColorSlider{Name=, Default=, Function=}
        module:CreateKeybind{Name=, Default=, Function=}
        module:SetBind{ "Key", ... }
        mainapi:CreateNotification(title, text, duration, type)
        mainapi:Save() / :Load() / :Uninject()

    Everything is rendered with Drawing.new primitives — no Roblox Instances,
    no ScreenGui, no UIListLayout, no TweenService. The library reimplements
    layout, hit-testing, tweening, scrolling, keyboard capture and theming
    inside a single RunService.RenderStepped loop (the "Pattern A + manual
    layout" approach described in the Drawing.new UI library analysis).

    Educational reference only. Using executor APIs in live Roblox games
    violates Roblox ToS.
]]

-- ============================================================
-- 1. SERVICES
-- ============================================================
local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TextService      = game:GetService("TextService")
local HttpService      = game:GetService("HttpService")
local Workspace        = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
local Camera      = Workspace.CurrentCamera or Workspace:WaitForChild("Camera")

Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
    Camera = Workspace.CurrentCamera or Camera
end)

-- ============================================================
-- 2. SAFE EXECUTOR FUNCTION ACCESS
-- ============================================================
local function isExecutorFn(fn)
    return type(fn) == "function"
end

local function isGameActive()
    if not isExecutorFn(isrbxactive) then return true end
    local ok, active = pcall(isrbxactive)
    return ok and active == true
end

-- ============================================================
-- 3. STATE: mainapi
-- ============================================================
local mainapi = {
    Categories     = {},
    Modules        = {},
    Windows        = {},
    GUIColor       = { Hue = 0.46, Sat = 0.96, Value = 0.52, Rainbow = false },
    Keybind        = { "RightShift" },
    HeldKeybinds   = {},
    Profile        = "default",
    Profiles       = {},
    Scale          = { Value = 1 },
    Version        = "4.18-drawing",
    Loaded         = false,
    RainbowSpeed   = { Value = 1 },
    RainbowTable   = {},
    Notifications  = { Enabled = true },
    GUIVisible     = true,
    -- Text GUI / arraylist watermark (bottom-right list of enabled modules)
    TextGUI        = { Enabled = true, Sort = "Alphabetical", Background = false, Suffix = false },
    CustomText     = {},   -- extra user lines shown in the arraylist
    -- internal
    Drawings       = {},   -- every drawing object, for cleanup
    HitTargets     = {},   -- {id = {bounds, callbacks, hovered, pressed}}
    Tweens         = {},   -- active tweens
    Layouts        = {},   -- {id = layout}
    ThemedDrawings = {},   -- drawings whose Color follows GUIColor
    ComponentDrags = {},   -- per-frame drag update closures (sliders etc.)
    _hidCounter    = 0,
    _layoutCounter = 0,
    Binding        = nil,
}

-- ============================================================
-- 4. UIPALLET / COLOR HELPERS
-- ============================================================
local uipallet = {
    -- Exact VapeV4 dark theme colors.
    Main  = Color3.fromRGB(26, 25, 26),
    Text  = Color3.fromRGB(200, 200, 200),
    Font  = Drawing.Fonts.UI,
    Tween = 0.16,
}

local color = {}

function color.Dark(col, num)
    local h, s, v = col:ToHSV()
    local baseV = select(3, uipallet.Main:ToHSV())
    return Color3.fromHSV(h, s, math.clamp(baseV > 0.5 and v + num or v - num, 0, 1))
end

function color.Light(col, num)
    local h, s, v = col:ToHSV()
    local baseV = select(3, uipallet.Main:ToHSV())
    return Color3.fromHSV(h, s, math.clamp(baseV > 0.5 and v - num or v + num, 0, 1))
end

function mainapi:Color(h)
    local s = 0.75 + (0.15 * math.min(h / 0.03, 1))
    if h > 0.57 then s = 0.9 - (0.4 * math.min((h - 0.57) / 0.09, 1)) end
    if h > 0.66 then s = 0.5 + (0.4 * math.min((h - 0.66) / 0.16, 1)) end
    if h > 0.87 then s = 0.9 - (0.15 * math.min((h - 0.87) / 0.13, 1)) end
    return h, s, 1
end

function mainapi:TextColor(h, s, v)
    if v >= 0.7 and (s < 0.6 or (h > 0.04 and h < 0.56)) then
        return Color3.new(0.19, 0.19, 0.19)
    end
    return Color3.new(1, 1, 1)
end

local function accentColor()
    return Color3.fromHSV(mainapi.GUIColor.Hue, mainapi.GUIColor.Sat, mainapi.GUIColor.Value)
end

-- ============================================================
-- 5. DRAW HELPER
-- ============================================================
local function Draw(typeName, props)
    if not Drawing or not isExecutorFn(Drawing.new) then return nil end
    local ok, obj = pcall(Drawing.new, typeName)
    if not ok or not obj then return nil end
    for k, v in pairs(props or {}) do
        pcall(function() obj[k] = v end)
    end
    table.insert(mainapi.Drawings, obj)
    return obj
end

local function destroyDraw(obj)
    if not obj then return end
    pcall(function() obj.Visible = false end)
    pcall(function() obj:Remove() end)
    for i = #mainapi.Drawings, 1, -1 do
        if mainapi.Drawings[i] == obj then
            table.remove(mainapi.Drawings, i)
            break
        end
    end
end

-- ============================================================
-- 6. IMAGE BYTE CACHE
-- ============================================================
local imageCache = {}

local function getDrawingImage(url)
    if not url or url == "" then return nil end
    if imageCache[url] ~= nil then return imageCache[url] end
    local ok, data = pcall(function() return game:HttpGet(url, true) end)
    if not ok or not data or #data == 0 then
        imageCache[url] = false
        return nil
    end
    imageCache[url] = data
    return data
end

-- ============================================================
-- 6b. ASSET REGISTRY (icons uploaded to GitHub)
-- ============================================================
-- All icons live in the VapeV5 ASSETS folder on GitHub. We build the raw
-- URLs from a single base so the whole icon set is available by name.
local ASSET_BASE = "https://raw.githubusercontent.com/xxxpawnstarxxx/VapeV5/refs/heads/main/ASSETS/"
local function assetURL(name) return ASSET_BASE .. name end

local Assets = {
    -- branding / chrome
    Logo        = assetURL("VapeLogo1.png"),
    LogoAlt      = assetURL("vapelogo.png"),
    Settings     = assetURL("newsettings.png"),
    SettingsWheel = assetURL("SettingsWheel1.png"),
    Close        = assetURL("ExitIcon1.png"),
    CloseAlt     = assetURL("newclose.png"),
    Dots         = assetURL("dots.png"),
    MoreButton   = assetURL("MoreButton1.png"),
    Expand       = assetURL("downexpand.png"),
    Collapse     = assetURL("upcollapse.png"),
    RightArrow   = assetURL("RightArrow.png"),
    DownArrow    = assetURL("DownArrow.png"),
    UpArrow      = assetURL("UpArrow.png"),
    HoverArrow   = assetURL("HoverArrow.png"),
    Check        = assetURL("check.png"),
    Pencil       = assetURL("PencilIcon.png"),
    Search       = assetURL("SearchBarIcon.png"),
    Pin          = assetURL("PinButton.png"),
    -- category icons
    Combat       = assetURL("CombatIcon.png"),
    Render       = assetURL("RenderIcon.png"),
    Utility      = assetURL("UtilityIcon.png"),
    World        = assetURL("WorldIcon.png"),
    Target       = assetURL("TargetIcon1.png"),
    Radar        = assetURL("RadarIcon1.png"),
    Keybind      = assetURL("KeybindIcon.png"),
    Profiles     = assetURL("ProfilesIcon.png"),
    Friends      = assetURL("FriendsIcon.png"),
    Discord      = assetURL("DiscordIcon.png"),
    Rainbow      = assetURL("RainbowIcon1.png"),
    LegitMode    = assetURL("LegitModeIcon.png"),
    -- component art
    ToggleBg     = assetURL("togglebg.png"),
    ToggleFront  = assetURL("togglefront.png"),
    ToggleDot    = assetURL("toggledot.png"),
    SliderButton = assetURL("SliderButton1.png"),
    SliderArrow  = assetURL("SliderArrow1.png"),
    ColorPreview = assetURL("colorpreview.png"),
    ColorSlider1 = assetURL("ColorSlider1.png"),
    TextBoxBKG   = assetURL("TextBoxBKG.png"),
    BindBackground = assetURL("BindBackground.png"),
    DropdownNotch  = assetURL("dropdownnotch.png"),
}
mainapi.Assets = Assets

-- Resolve an asset by friendly name OR raw url. Returns a url string or nil.
local function resolveAsset(nameOrUrl)
    if not nameOrUrl or nameOrUrl == "" then return nil end
    if Assets[nameOrUrl] then return Assets[nameOrUrl] end
    return nameOrUrl
end

-- Create an Image drawing from a (possibly remote) asset. Returns nil if the
-- bytes can't be fetched so callers can fall back to a text/shape glyph.
local function DrawImage(nameOrUrl, props)
    local url = resolveAsset(nameOrUrl)
    local data = getDrawingImage(url)
    if not data then return nil end
    local img = Draw("Image", props)
    if not img then return nil end
    -- Different executors expose raw image bytes under different fields.
    local ok = pcall(function() img.Data = data end)
    if not ok then pcall(function() img.Uri = url end) end
    return img
end
mainapi._DrawImage = DrawImage

-- ============================================================
-- 7. HIT-TEST FRAMEWORK
-- ============================================================
local function registerHit(bounds, callbacks, visObj)
    mainapi._hidCounter = mainapi._hidCounter + 1
    local id = mainapi._hidCounter
    mainapi.HitTargets[id] = {
        bounds    = bounds,
        callbacks = callbacks or {},
        hovered   = false,
        pressed   = false,
        -- Optional representative drawing. When provided, the hit target is
        -- only considered when that drawing is actually Visible. This kills
        -- "ghost hitboxes" left behind by collapsed panels / hidden controls.
        visObj    = visObj,
    }
    return id
end

local function unregisterHit(id)
    mainapi.HitTargets[id] = nil
end

local function pointInRect(px, py, pos, size)
    return px >= pos.X and px <= pos.X + size.X
       and py >= pos.Y and py <= pos.Y + size.Y
end

-- ============================================================
-- 8. TWEEN SYSTEM
-- ============================================================
local function tweenProperty(obj, prop, goal, duration, easingFn)
    if not obj then return end
    duration = duration or 0.16
    easingFn = easingFn or function(a) return a end
    for i = #mainapi.Tweens, 1, -1 do
        local t = mainapi.Tweens[i]
        if t.obj == obj and t.prop == prop then
            table.remove(mainapi.Tweens, i)
        end
    end
    local ok, start = pcall(function() return obj[prop] end)
    if not ok then return end
    if typeof(start) == "number" then
        table.insert(mainapi.Tweens, {
            obj = obj, prop = prop, start = start, goal = goal,
            startTime = os.clock(), duration = duration, easing = easingFn, kind = "number",
        })
    elseif typeof(start) == "Color3" then
        table.insert(mainapi.Tweens, {
            obj = obj, prop = prop,
            sr = start.R, sg = start.G, sb = start.B,
            gr = goal.R, gg = goal.G, gb = goal.B,
            startTime = os.clock(), duration = duration, easing = easingFn, kind = "color",
        })
    elseif typeof(start) == "Vector2" then
        table.insert(mainapi.Tweens, {
            obj = obj, prop = prop,
            sx = start.X, sy = start.Y, gx = goal.X, gy = goal.Y,
            startTime = os.clock(), duration = duration, easing = easingFn, kind = "vector2",
        })
    end
end

local function updateTweens()
    local now = os.clock()
    for i = #mainapi.Tweens, 1, -1 do
        local t = mainapi.Tweens[i]
        local raw = math.clamp((now - t.startTime) / t.duration, 0, 1)
        local a = t.easing(raw)
        if t.kind == "number" then
            pcall(function() t.obj[t.prop] = t.start + (t.goal - t.start) * a end)
        elseif t.kind == "color" then
            local c = Color3.new(
                t.sr + (t.gr - t.sr) * a,
                t.sg + (t.gg - t.sg) * a,
                t.sb + (t.gb - t.sb) * a)
            pcall(function() t.obj[t.prop] = c end)
        elseif t.kind == "vector2" then
            local v = Vector2.new(t.sx + (t.gx - t.sx) * a, t.sy + (t.gy - t.sy) * a)
            pcall(function() t.obj[t.prop] = v end)
        end
        if raw >= 1 then table.remove(mainapi.Tweens, i) end
    end
end

local Easing = {
    Linear  = function(a) return a end,
    Quad    = function(a) return a * a end,
    Cubic   = function(a) return a * a * a end,
    Quart   = function(a) return a * a * a * a end,
    Expo    = function(a) return a == 1 and 1 or 2 ^ (10 * (a - 1)) end,
    OutExpo = function(a) return a == 1 and 1 or 1 - 2 ^ (-10 * a) end,
}

-- ============================================================
-- 9. MANUAL LAYOUT SYSTEM
-- ============================================================
local function createLayout(opts)
    mainapi._layoutCounter = mainapi._layoutCounter + 1
    local id = mainapi._layoutCounter
    local layout = {
        children     = {},
        startY       = opts.startY or 0,
        padding      = opts.padding or 0,
        clipPos      = opts.clipPos or nil,
        clipSize     = opts.clipSize or nil,
        scrollOffset = 0,
        maxScroll    = 0,
    }
    mainapi.Layouts[id] = layout
    return layout, id
end

local function removeLayout(id)
    mainapi.Layouts[id] = nil
end

local function layoutAdd(layout, child)
    table.insert(layout.children, child)
end

local function applyLayout(layout)
    local contentHeight = 0
    for i, child in ipairs(layout.children) do
        local childY = layout.startY + contentHeight - layout.scrollOffset
        local visible = true
        if layout.clipPos and layout.clipSize then
            visible = childY + child.height >= layout.clipPos.Y
                  and childY <= layout.clipPos.Y + layout.clipSize.Y
        end
        if child.apply then child.apply(childY, visible) end
        contentHeight = contentHeight + child.height + layout.padding
    end
    layout.maxScroll = math.max(0, contentHeight - (layout.clipSize and layout.clipSize.Y or 0))
    layout.scrollOffset = math.clamp(layout.scrollOffset, 0, layout.maxScroll)
end

-- ============================================================
-- 10. KEYBOARD CAPTURE
-- ============================================================
local keyCapture = {
    active = false,
    callback = nil,
    buffer = "",
    isText = false,
    placeholder = "",
    doneCallback = nil,
}

local function startKeyCapture(callback)
    keyCapture.active = true
    keyCapture.callback = callback
    keyCapture.isText = false
end

local function startTextCapture(initialText, placeholder, doneCallback)
    keyCapture.active = true
    keyCapture.buffer = initialText or ""
    keyCapture.placeholder = placeholder or ""
    keyCapture.doneCallback = doneCallback
    keyCapture.isText = true
end

local function stopCapture()
    keyCapture.active = false
    keyCapture.callback = nil
    keyCapture.doneCallback = nil
    keyCapture.buffer = ""
end

local function keyCodeName(keyCode)
    if not keyCode then return "" end
    return tostring(keyCode.Name or keyCode)
end

-- ============================================================
-- 11. MAID
-- ============================================================
local function addMaid(object)
    object.Connections = {}
    function object:Clean(callback)
        if type(callback) == "function" then
            table.insert(self.Connections, { Disconnect = callback })
        elseif type(callback) == "table" and callback.Disconnect then
            table.insert(self.Connections, callback)
        end
    end
    function object:CleanAll()
        for _, c in ipairs(self.Connections) do
            pcall(function() c:Disconnect() end)
        end
        self.Connections = {}
    end
end

-- ============================================================
-- 12. RENDER LOOP
-- ============================================================
local renderConn

local function getMousePos()
    return UserInputService:GetMouseLocation()
end

local function updateHitTesting()
    if keyCapture.active then return end
    -- Ghost-hitbox fix: when the menu is toggled off the drawing objects are
    -- invisible but their math bounds still exist. Clear stale hover state and
    -- bail so hidden controls can never be hovered/clicked.
    if not mainapi.GUIVisible then
        for _, target in pairs(mainapi.HitTargets) do
            if target.hovered then
                target.hovered = false
                if target.callbacks.onLeave then pcall(target.callbacks.onLeave) end
            end
        end
        return
    end
    local mouse = getMousePos()
    for _, target in pairs(mainapi.HitTargets) do
        -- Skip controls whose representative drawing is currently hidden, and
        -- clear any stale hover so a hidden control can't stay "hovered".
        local controlVisible = true
        if target.visObj then
            local okv, vis = pcall(function() return target.visObj.Visible end)
            controlVisible = okv and vis == true
        end
        if not controlVisible then
            if target.hovered then
                target.hovered = false
                if target.callbacks.onLeave then pcall(target.callbacks.onLeave) end
            end
        elseif type(target.bounds) == "function" then
            local ok, pos, size = pcall(target.bounds)
            if ok and pos and size then
                local inside = pointInRect(mouse.X, mouse.Y, pos, size)
                if inside and not target.hovered then
                    target.hovered = true
                    if target.callbacks.onEnter then pcall(target.callbacks.onEnter) end
                elseif not inside and target.hovered then
                    target.hovered = false
                    if target.callbacks.onLeave then pcall(target.callbacks.onLeave) end
                end
            end
        end
    end
end

local function updateLayouts()
    for _, layout in pairs(mainapi.Layouts) do
        pcall(applyLayout, layout)
    end
end

local function updateRainbow()
    if not mainapi.GUIColor.Rainbow then return end
    mainapi.GUIColor.Hue = (mainapi.GUIColor.Hue + 0.001 * (mainapi.RainbowSpeed.Value or 1)) % 1
    mainapi:UpdateGUI(mainapi.GUIColor.Hue, mainapi.GUIColor.Sat, mainapi.GUIColor.Value)
end

local function updatePanelDrags()
    if not mainapi._draggablePanels then return end
    for cat, fn in pairs(mainapi._draggablePanels) do
        if mainapi.Categories[cat.Name] == cat then pcall(fn) end
    end
end

local function updateSidebarDrag()
    if mainapi._sidebarDrag then pcall(mainapi._sidebarDrag) end
end

local function updateComponentDrags()
    for _, fn in pairs(mainapi.ComponentDrags) do
        pcall(fn)
    end
end

local function startRenderLoop()
    if renderConn then return end
    renderConn = RunService.RenderStepped:Connect(function()
        if not isGameActive() then return end
        pcall(updateTweens)
        pcall(updatePanelDrags)
        pcall(updateSidebarDrag)
        pcall(updateComponentDrags)
        pcall(updateHitTesting)
        pcall(updateLayouts)
        pcall(updateRainbow)
        if mainapi._updateArraylist then pcall(mainapi._updateArraylist) end
    end)
end

local function stopRenderLoop()
    if renderConn then
        renderConn:Disconnect()
        renderConn = nil
    end
end

-- ============================================================
-- 13. INPUT HANDLERS
-- ============================================================
UserInputService.InputBegan:Connect(function(input, gpe)
    -- Text capture has priority
    if keyCapture.active and keyCapture.isText then
        if input.KeyCode == Enum.KeyCode.Return then
            local cb, text = keyCapture.doneCallback, keyCapture.buffer
            stopCapture()
            if cb then pcall(cb, text, true) end
            return
        elseif input.KeyCode == Enum.KeyCode.Escape then
            local cb = keyCapture.doneCallback
            stopCapture()
            if cb then pcall(cb, "", false) end
            return
        elseif input.KeyCode == Enum.KeyCode.Backspace then
            keyCapture.buffer = keyCapture.buffer:sub(1, -2)
            if keyCapture.doneCallback then pcall(keyCapture.doneCallback, keyCapture.buffer, false) end
            return
        end
        local ch = input.KeyCode.Name
        if ch and #ch == 1 then
            local letter = ch
            if not UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
               and not UserInputService:IsKeyDown(Enum.KeyCode.RightShift) then
                letter = string.lower(letter)
            end
            keyCapture.buffer = keyCapture.buffer .. letter
        elseif ch and ch:match("^%a$") == nil and ch:match("^[A-Za-z]+%d$") then
            keyCapture.buffer = keyCapture.buffer .. ch:sub(-1)
        elseif ch == "Space" then
            keyCapture.buffer = keyCapture.buffer .. " "
        end
        if keyCapture.doneCallback then pcall(keyCapture.doneCallback, keyCapture.buffer, false) end
        return
    end

    if keyCapture.active and not keyCapture.isText and keyCapture.callback then
        local kc = input.KeyCode
        if kc ~= Enum.KeyCode.Unknown then
            local stop = keyCapture.callback(kc)
            if stop then stopCapture() end
        end
        return
    end

    -- Per-module keybind matching
    if input.KeyCode ~= Enum.KeyCode.Unknown and not gpe then
        local kcName = input.KeyCode.Name
        for _, module in pairs(mainapi.Modules) do
            if module.Bind and #module.Bind > 0 and table.find(module.Bind, kcName) then
                local allHeld = true
                for _, k in ipairs(module.Bind) do
                    if not UserInputService:IsKeyDown(Enum.KeyCode[k]) then allHeld = false break end
                end
                if allHeld and not module._bindFired then
                    module._bindFired = true
                    module:Toggle()
                end
            end
        end
    end

    -- Global GUI keybind
    if input.KeyCode ~= Enum.KeyCode.Unknown then
        local allHeld = true
        for _, k in ipairs(mainapi.Keybind) do
            if not UserInputService:IsKeyDown(Enum.KeyCode[k]) then allHeld = false break end
        end
        if allHeld and #mainapi.Keybind > 0 and not mainapi._guiBindFired then
            mainapi._guiBindFired = true
            mainapi:ToggleGUI()
        end
    end

    -- Mouse clicks
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        if gpe then return end
        -- Ghost-hitbox fix: ignore clicks entirely while the GUI is hidden.
        if not mainapi.GUIVisible then return end
        for _, target in pairs(mainapi.HitTargets) do
            if target.hovered then
                target.pressed = true
                if target.callbacks.onDown then pcall(target.callbacks.onDown) end
            end
        end
    end
end)

UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        for _, target in pairs(mainapi.HitTargets) do
            if target.pressed then
                target.pressed = false
                if target.callbacks.onUp then pcall(target.callbacks.onUp) end
                if target.hovered and target.callbacks.onClick then pcall(target.callbacks.onClick) end
            end
        end
    end

    if input.KeyCode ~= Enum.KeyCode.Unknown then
        local kcName = input.KeyCode.Name
        for _, module in pairs(mainapi.Modules) do
            if module.Bind and #module.Bind > 0 and table.find(module.Bind, kcName) then
                module._bindFired = false
            end
        end
        if mainapi.Keybind and table.find(mainapi.Keybind, kcName) then
            mainapi._guiBindFired = false
        end
    end
end)

UserInputService.InputChanged:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseWheel then
        if not mainapi.GUIVisible then return end
        local mouse = getMousePos()
        local delta = input.Position.Z
        for _, layout in pairs(mainapi.Layouts) do
            if layout.maxScroll > 0 and layout.clipPos and layout.clipSize then
                if pointInRect(mouse.X, mouse.Y, layout.clipPos, layout.clipSize) then
                    layout.scrollOffset = math.clamp(
                        layout.scrollOffset - (delta > 0 and 30 or -30), 0, layout.maxScroll)
                    return
                end
            end
        end
    end
end)

-- ============================================================
-- 14. THEMING
-- ============================================================
function mainapi:UpdateGUI(hue, sat, val)
    for _, entry in ipairs(self.ThemedDrawings) do
        if entry.obj then
            pcall(function()
                if entry.kind == "accent" then
                    entry.obj.Color = Color3.fromHSV(hue, sat, val)
                elseif entry.kind == "rainbow" and self.GUIColor.Rainbow then
                    local h2 = (hue - (entry.index * 0.025)) % 1
                    local hs, ss, vs = self:Color(h2)
                    entry.obj.Color = Color3.fromHSV(hs, ss, vs)
                -- Enabled-module row background. In rainbow mode each row gets a
                -- per-index hue (the flowing gradient look from VapeV4); otherwise
                -- it's a solid fill of the current GUI accent color.
                elseif entry.kind == "rowbg" then
                    if self.GUIColor.Rainbow then
                        -- VapeV4 uses 0.025 offset per module index
                        local h2 = (hue - (entry.index * 0.025)) % 1
                        local hs, ss, vs = self:Color(h2)
                        entry.obj.Color = Color3.fromHSV(hs, ss, vs)
                    else
                        entry.obj.Color = Color3.fromHSV(hue, sat, val)
                    end
                -- Text drawn on top of a colored row needs a contrasting color so
                -- it stays readable on bright backgrounds.
                elseif entry.kind == "rowtext" then
                    if self.GUIColor.Rainbow then
                        -- VapeV4: dark text (0.19) on rainbow-colored rows
                        entry.obj.Color = Color3.new(0.19, 0.19, 0.19)
                    else
                        entry.obj.Color = self:TextColor(hue, sat, val)
                    end
                end
            end)
        end
    end
    if self._updateArraylist then pcall(self._updateArraylist) end
end

function mainapi:registerThemed(obj, kind, index)
    table.insert(self.ThemedDrawings, { obj = obj, kind = kind, index = index or 0 })
end

function mainapi:unregisterThemed(obj)
    for i = #self.ThemedDrawings, 1, -1 do
        if self.ThemedDrawings[i].obj == obj then
            table.remove(self.ThemedDrawings, i)
        end
    end
end

function mainapi:ToggleGUI()
    self.GUIVisible = not self.GUIVisible
    local vis = self.GUIVisible
    if self._clickguiRoot then
        for _, d in ipairs(self._clickguiRoot) do
            if d then pcall(function() d.Visible = vis end) end
        end
    end
    -- headerDivider is tracked in _clickguiRoot above
    for _, cat in pairs(self.Categories) do
        -- Sidebar entry always follows the GUI visibility.
        for _, d in ipairs(cat._sidebarDrawings or {}) do
            pcall(function() d.Visible = vis end)
        end
        -- Panel + modules only show when both visible AND expanded.
        local showPanel = vis and cat.Expanded
        for _, d in ipairs(cat._panelDrawings or {}) do
            pcall(function() d.Visible = showPanel end)
        end
        if cat._closeImg and cat._closeText then cat._closeText.Visible = false end
        for _, mod in ipairs(cat._moduleList) do mod:_setVisible(showPanel) end
    end
end

-- ============================================================
-- 15. NOTIFICATIONS
-- ============================================================
local notificationsContainer = { list = {} }

function mainapi:CreateNotification(title, text, duration, ntype)
    if not self.Notifications.Enabled then return end
    duration = duration or 5
    ntype = ntype or "info"

    local vp = Camera.ViewportSize
    local notifW = math.max(220, (#tostring(text) * 7) + 60)
    local notifH = 60
    local index = #notificationsContainer.list
    local startY = vp.Y - 20 - notifH - (index * (notifH + 8))
    local targetX = vp.X - 20 - notifW
    local startX = vp.X + 20

    local bg = Draw("Square", {
        Size = Vector2.new(notifW, notifH), Position = Vector2.new(startX, startY),
        Color = color.Dark(uipallet.Main, 0.05), Filled = true, Transparency = 1, ZIndex = 50, Visible = true,
    })
    local accentCol = (ntype == "alert" and Color3.fromRGB(250, 50, 56))
                   or (ntype == "warning" and Color3.fromRGB(236, 129, 43))
                   or accentColor()
    local accent = Draw("Square", {
        Size = Vector2.new(3, notifH), Position = Vector2.new(startX, startY),
        Color = accentCol, Filled = true, Transparency = 1, ZIndex = 51, Visible = true,
    })
    local titleText = Draw("Text", {
        Text = tostring(title or ""), Position = Vector2.new(startX + 12, startY + 8),
        Size = 15, Font = Drawing.Fonts.Plex, Color = Color3.fromRGB(220, 220, 220),
        Transparency = 1, ZIndex = 52, Visible = true,
    })
    local bodyText = Draw("Text", {
        Text = tostring(text or ""), Position = Vector2.new(startX + 12, startY + 28),
        Size = 13, Font = Drawing.Fonts.UI, Color = Color3.fromRGB(170, 170, 170),
        Transparency = 1, ZIndex = 52, Visible = true,
    })
    local progress = Draw("Square", {
        Size = Vector2.new(notifW - 4, 2), Position = Vector2.new(startX + 2, startY + notifH - 4),
        Color = accentCol, Filled = true, Transparency = 1, ZIndex = 53, Visible = true,
    })

    local entry = {
        bg = bg, accent = accent, title = titleText, body = bodyText, progress = progress,
        startedAt = os.clock(), duration = duration, width = notifW, height = notifH,
        targetX = targetX, startY = startY,
    }
    table.insert(notificationsContainer.list, entry)

    tweenProperty(bg, "Position", Vector2.new(targetX, startY), 0.4, Easing.OutExpo)
    tweenProperty(accent, "Position", Vector2.new(targetX, startY), 0.4, Easing.OutExpo)
    tweenProperty(titleText, "Position", Vector2.new(targetX + 12, startY + 8), 0.4, Easing.OutExpo)
    tweenProperty(bodyText, "Position", Vector2.new(targetX + 12, startY + 28), 0.4, Easing.OutExpo)
    tweenProperty(progress, "Position", Vector2.new(targetX + 2, startY + notifH - 4), 0.4, Easing.OutExpo)
    tweenProperty(progress, "Size", Vector2.new(0, 2), duration, Easing.Linear)

    task.delay(duration, function()
        tweenProperty(bg, "Position", Vector2.new(vp.X + 20, startY), 0.4, Easing.Expo)
        tweenProperty(accent, "Position", Vector2.new(vp.X + 20, startY), 0.4, Easing.Expo)
        tweenProperty(titleText, "Position", Vector2.new(vp.X + 32, startY + 8), 0.4, Easing.Expo)
        tweenProperty(bodyText, "Position", Vector2.new(vp.X + 32, startY + 28), 0.4, Easing.Expo)
        tweenProperty(progress, "Position", Vector2.new(vp.X + 22, startY + notifH - 4), 0.4, Easing.Expo)
        task.wait(0.45)
        destroyDraw(bg); destroyDraw(accent); destroyDraw(titleText); destroyDraw(bodyText); destroyDraw(progress)
        for i = #notificationsContainer.list, 1, -1 do
            if notificationsContainer.list[i] == entry then table.remove(notificationsContainer.list, i) end
        end
        for i, e in ipairs(notificationsContainer.list) do
            local newY = vp.Y - 20 - e.height - ((i - 1) * (e.height + 8))
            e.startY = newY
            tweenProperty(e.bg, "Position", Vector2.new(e.targetX, newY), 0.3, Easing.Linear)
            tweenProperty(e.accent, "Position", Vector2.new(e.targetX, newY), 0.3, Easing.Linear)
            tweenProperty(e.title, "Position", Vector2.new(e.targetX + 12, newY + 8), 0.3, Easing.Linear)
            tweenProperty(e.body, "Position", Vector2.new(e.targetX + 12, newY + 28), 0.3, Easing.Linear)
            tweenProperty(e.progress, "Position", Vector2.new(e.targetX + 2, newY + e.height - 4), 0.3, Easing.Linear)
        end
    end)
end

-- ============================================================
-- 15b. TEXT GUI / ARRAYLIST WATERMARK
-- ============================================================
-- A bottom/top-right list of every currently-enabled module (plus any custom
-- text lines). Each entry is colored with the GUI accent, or a per-index
-- rainbow hue when Rainbow is on — the classic VapeV4 arraylist look.
local arraylist = { lines = {}, title = nil, titleSub = nil, bg = nil, built = false }
local ARRAY_POOL = 60

local function measureText(obj, fallback)
    local ok, b = pcall(function() return obj.TextBounds end)
    if ok and b and b.X and b.X > 0 then return b.X end
    return fallback or (#tostring(obj.Text) * 7)
end

function mainapi:CreateArraylist()
    if arraylist.built then return end
    arraylist.built = true

    -- optional translucent panel behind the lines
    arraylist.bg = Draw("Square", {
        Size = Vector2.new(0, 0), Position = Vector2.new(0, 0),
        Color = color.Dark(uipallet.Main, 0.04), Filled = true,
        Transparency = 0.45, ZIndex = 40, Visible = false,
    })

    -- "VAPE" + "V4" header (matches VapeV4 TextGUI style: VAPE in accent, V4 in accent too)
    arraylist.title = Draw("Text", {
        Text = "VAPE", Position = Vector2.new(0, 0), Size = 20,
        Font = Drawing.Fonts.Plex, Color = accentColor(), Transparency = 1,
        ZIndex = 42, Visible = false, Center = false,
    })
    arraylist.titleSub = Draw("Text", {
        Text = "V4", Position = Vector2.new(0, 0), Size = 16,
        Font = Drawing.Fonts.Plex, Color = accentColor(), Transparency = 1,
        ZIndex = 42, Visible = false, Center = false,
    })
    self:registerThemed(arraylist.title, "accent")
    self:registerThemed(arraylist.titleSub, "accent")

    for i = 1, ARRAY_POOL do
        local txt = Draw("Text", {
            Text = "", Position = Vector2.new(0, 0), Size = 14,
            Font = Drawing.Fonts.UI, Color = accentColor(), Transparency = 1,
            ZIndex = 42, Visible = false, Center = false,
        })
        local bar = Draw("Square", {
            Size = Vector2.new(2, 18), Position = Vector2.new(0, 0),
            Color = accentColor(), Filled = true, Transparency = 1,
            ZIndex = 42, Visible = false,
        })
        arraylist.lines[i] = { txt = txt, bar = bar }
    end

    self._updateArraylist = function() mainapi:_renderArraylist() end
end

-- Gather + sort the strings the arraylist should display.
function mainapi:_arraylistEntries()
    local entries = {}
    for _, mod in pairs(self.Modules) do
        if mod.Enabled and mod.Category ~= "Settings" then
            entries[#entries + 1] = mod.Name .. (mod.ExtraText and (" " .. tostring(mod.ExtraText)) or "")
        end
    end
    for _, line in ipairs(self.CustomText) do
        if line and line ~= "" then entries[#entries + 1] = line end
    end
    local sort = self.TextGUI.Sort
    if sort == "Length" then
        table.sort(entries, function(a, b) return #a > #b end)
    elseif sort == "Reverse Length" then
        table.sort(entries, function(a, b) return #a < #b end)
    else
        table.sort(entries, function(a, b) return a:lower() < b:lower() end)
    end
    return entries
end

function mainapi:_renderArraylist()
    if not arraylist.built then return end
    local vp = Camera.ViewportSize
    local margin = 8
    local lineH = 18
    local rightX = vp.X - margin

    local enabled = self.TextGUI.Enabled
    -- Header (VAPE + V4 text, right-aligned, top-right corner)
    local lineH = 20
    local startY = 10
    local titleW = enabled and (measureText(arraylist.title, 52) + 2 + measureText(arraylist.titleSub, 22)) or 0
    if arraylist.title then
        arraylist.title.Visible = enabled
        arraylist.titleSub.Visible = enabled
        if enabled then
            local subW = measureText(arraylist.titleSub, 22)
            local mainW = measureText(arraylist.title, 52)
            -- "V4" immediately right of "VAPE" with 1px gap
            arraylist.title.Position = Vector2.new(rightX - subW - 2 - mainW, startY)
            arraylist.titleSub.Position = Vector2.new(rightX - subW, startY + 4)
        end
    end

    local entries = enabled and self:_arraylistEntries() or {}
    local maxW = titleW
    for i, line in ipairs(arraylist.lines) do
        local data = entries[i]
        if data then
            local y = startY + 26 + (i - 1) * lineH
            line.txt.Text = data
            local w = measureText(line.txt, #data * 7)
            if w > maxW then maxW = w end
            line.txt.Position = Vector2.new(rightX - w - 6, y)
            line.bar.Position = Vector2.new(rightX - 3, y + 1)
            line.bar.Size = Vector2.new(2, 18)

            -- per-line color (VapeV4 uses 0.025 offset per index)
            local col
            if self.GUIColor.Rainbow then
                local h2 = (self.GUIColor.Hue - ((i - 1) * 0.025)) % 1
                col = Color3.fromHSV(self:Color(h2))
            else
                col = accentColor()
            end
            line.txt.Color = col
            line.bar.Color = col
            line.txt.Visible = true
            line.bar.Visible = true
        else
            line.txt.Visible = false
            line.bar.Visible = false
        end
    end

    -- optional background panel
    if arraylist.bg then
        local show = enabled and self.TextGUI.Background and #entries > 0
        arraylist.bg.Visible = show
        if show then
            local totalH = 26 + #entries * lineH + 4
            arraylist.bg.Size = Vector2.new(maxW + 16, totalH)
            arraylist.bg.Position = Vector2.new(rightX - maxW - 14, startY - 4)
        end
    end
end

-- ============================================================
-- 16. GUI ROOT (CreateGUI) — main sidebar
-- ============================================================
function mainapi:CreateGUI()
    if self._clickguiRoot then return end

    local sidebarW = 220
    self._sidebarPos = self._sidebarPos or { X = 6, Y = 60 }
    local headerH = 41  -- matches VapeV4 window header height

    local header = Draw("Square", {
        Size = Vector2.new(sidebarW, headerH), Position = Vector2.new(self._sidebarPos.X, self._sidebarPos.Y),
        Color = color.Dark(uipallet.Main, 0.02), Filled = true, Transparency = 1, ZIndex = 10, Visible = true,
    })
    -- Thin divider line at bottom of header (matches VapeV4 style)
    local headerDivider = Draw("Square", {
        Size = Vector2.new(sidebarW, 1), Position = Vector2.new(self._sidebarPos.X, self._sidebarPos.Y + headerH),
        Color = Color3.new(1, 1, 1), Filled = true, Transparency = 0.93, ZIndex = 11, Visible = true,
    })
    -- Prefer the uploaded GitHub logo image; fall back to text if it can't load.
    local logoImg = DrawImage(Assets.Logo, {
        Size = Vector2.new(62, 18), Position = Vector2.new(self._sidebarPos.X + 11, self._sidebarPos.Y + 11),
        Transparency = 1, ZIndex = 11, Visible = true,
    })
    local logo = Draw("Text", {
        Text = "Vape", Position = Vector2.new(self._sidebarPos.X + 11, self._sidebarPos.Y + 12),
        Size = 16, Font = Drawing.Fonts.Plex, Color = accentColor(), Transparency = 1, ZIndex = 11,
        Visible = logoImg == nil,
    })
    -- Settings gear button (uses the uploaded settings icon) opens the Settings panel.
    local gearImg = DrawImage(Assets.Settings, {
        Size = Vector2.new(14, 14), Position = Vector2.new(self._sidebarPos.X + sidebarW - 26, self._sidebarPos.Y + 14),
        Transparency = 1, ZIndex = 12, Visible = true,
    })
    local gearText = Draw("Text", {
        Text = "*", Position = Vector2.new(self._sidebarPos.X + sidebarW - 22, self._sidebarPos.Y + 12),
        Size = 16, Font = Drawing.Fonts.UI, Color = color.Light(uipallet.Main, 0.37),
        Transparency = 1, ZIndex = 12, Visible = gearImg == nil,
    })
    local versionLabel = Draw("Text", {
        Text = "v" .. self.Version, Position = Vector2.new(self._sidebarPos.X + 11, self._sidebarPos.Y + headerH - 1),
        Size = 9, Font = Drawing.Fonts.UI, Color = color.Dark(uipallet.Text, 0.43),
        Transparency = 1, ZIndex = 11, Visible = false,
    })
    self:registerThemed(logo, "accent")

    -- Gear hit-target: toggle the Settings category open/closed.
    registerHit(
        function() return Vector2.new(self._sidebarPos.X + sidebarW - 30, self._sidebarPos.Y + 10), Vector2.new(22, 22) end,
        {
            onEnter = function() if gearText then tweenProperty(gearText, "Color", uipallet.Text, 0.16) end end,
            onLeave = function() if gearText then tweenProperty(gearText, "Color", color.Light(uipallet.Main, 0.37), 0.16) end end,
            onClick = function()
                local s = self.Categories["Settings"]
                if s then s:Expand(not s.Expanded) end
            end,
        }
    )

    self._clickguiRoot = { header, headerDivider, logo, versionLabel, gearText }
    if logoImg then table.insert(self._clickguiRoot, logoImg) end
    if gearImg then table.insert(self._clickguiRoot, gearImg) end
    self._headerLogoImg = logoImg
    self._headerGearImg = gearImg
    self.GUIVisible = true

    local dragState = { dragging = false, offset = Vector2.new(0, 0) }
    registerHit(
        function() return Vector2.new(self._sidebarPos.X, self._sidebarPos.Y), Vector2.new(sidebarW, headerH) end,
        { onDown = function()
            dragState.dragging = true
            dragState.offset = getMousePos() - Vector2.new(self._sidebarPos.X, self._sidebarPos.Y)
        end }
    )
    self._sidebarDrag = function()
        if dragState.dragging then
            local m = getMousePos()
            self._sidebarPos.X = math.clamp(m.X - dragState.offset.X, 0, Camera.ViewportSize.X - sidebarW)
            self._sidebarPos.Y = math.clamp(m.Y - dragState.offset.Y, 0, Camera.ViewportSize.Y - headerH)
            header.Position = Vector2.new(self._sidebarPos.X, self._sidebarPos.Y)
            headerDivider.Position = Vector2.new(self._sidebarPos.X, self._sidebarPos.Y + headerH)
            logo.Position = Vector2.new(self._sidebarPos.X + 11, self._sidebarPos.Y + 12)
            if logoImg then logoImg.Position = Vector2.new(self._sidebarPos.X + 11, self._sidebarPos.Y + 11) end
            if gearImg then gearImg.Position = Vector2.new(self._sidebarPos.X + sidebarW - 26, self._sidebarPos.Y + 14) end
            gearText.Position = Vector2.new(self._sidebarPos.X + sidebarW - 22, self._sidebarPos.Y + 12)
            versionLabel.Position = Vector2.new(self._sidebarPos.X + 11, self._sidebarPos.Y + headerH - 1)
            if self._sidebarEntryUpdaters then
                for _, upd in pairs(self._sidebarEntryUpdaters) do pcall(upd) end
            end
        end
    end
    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then dragState.dragging = false end
    end)

    return self._clickguiRoot
end

-- ============================================================
-- 17. CATEGORY
-- ============================================================
function mainapi:CreateCategory(settings)
    assert(settings and settings.Name, "CreateCategory: Name required")
    if not self._clickguiRoot then self:CreateGUI() end

    local categoryapi = {
        Type = "Category", Expanded = false, Options = {}, Name = settings.Name,
        _drawings = {}, _moduleLayout = nil, _moduleList = {},
        _pos = { X = 236, Y = 60 }, _panelSize = { W = 220, H = 380 },
    }
    addMaid(categoryapi)

    local sidebarIndex = 0
    for _ in pairs(self.Categories) do sidebarIndex = sidebarIndex + 1 end

    if not self._sidebarPos then self._sidebarPos = { X = 6, Y = 60 } end
    local sidebarW, entryH, headerH = 220, 41, 41
    local function sidebarEntryY() return self._sidebarPos.Y + headerH + 4 + sidebarIndex * (entryH + 2) end
    local function sidebarX() return self._sidebarPos.X end

    local entryBg = Draw("Square", {
        Size = Vector2.new(sidebarW, entryH), Position = Vector2.new(sidebarX(), sidebarEntryY()),
        Color = uipallet.Main, Filled = true, Transparency = 1, ZIndex = 10, Visible = true,
    })
    -- Optional category icon (uploaded to GitHub). When present the label is
    -- shifted right to make room for a 16x16 icon.
    local entryIcon = settings.Icon and DrawImage(settings.Icon, {
        Size = Vector2.new(16, 16), Position = Vector2.new(sidebarX() + 12, sidebarEntryY() + 13),
        Transparency = 1, ZIndex = 11, Visible = true,
    }) or nil
    local textLeft = entryIcon and 36 or 12

    local entryText = Draw("Text", {
        Text = settings.Name, Position = Vector2.new(sidebarX() + textLeft, sidebarEntryY() + 13),
        Size = 13, Font = Drawing.Fonts.UI, Color = color.Dark(uipallet.Text, 0.16),
        Transparency = 1, ZIndex = 11, Visible = true,
    })
    local entryArrowImg = DrawImage(Assets.RightArrow, {
        Size = Vector2.new(10, 10), Position = Vector2.new(sidebarX() + sidebarW - 20, sidebarEntryY() + 15),
        Transparency = 1, ZIndex = 11, Visible = true,
    })
    local entryArrow = Draw("Text", {
        Text = ">", Position = Vector2.new(sidebarX() + sidebarW - 18, sidebarEntryY() + 13),
        Size = 12, Font = Drawing.Fonts.UI, Color = color.Light(uipallet.Main, 0.37),
        Transparency = 1, ZIndex = 11, Visible = entryArrowImg == nil,
    })

    -- Sidebar entry drawings are tracked separately from panel drawings so
    -- ToggleGUI / Expand can show/hide each group without fragile indexing.
    categoryapi._sidebarDrawings = { entryBg, entryText, entryArrow }
    if entryIcon then table.insert(categoryapi._sidebarDrawings, entryIcon) end
    if entryArrowImg then table.insert(categoryapi._sidebarDrawings, entryArrowImg) end
    for _, d in ipairs(categoryapi._sidebarDrawings) do table.insert(categoryapi._drawings, d) end

    local function updateEntryPos()
        local ex, ey = sidebarX(), sidebarEntryY()
        entryBg.Position = Vector2.new(ex, ey)
        if entryIcon then entryIcon.Position = Vector2.new(ex + 12, ey + 13) end
        entryText.Position = Vector2.new(ex + textLeft, ey + 13)
        entryArrow.Position = Vector2.new(ex + sidebarW - (categoryapi.Expanded and 14 or 18), ey + 13)
        if entryArrowImg then entryArrowImg.Position = Vector2.new(ex + sidebarW - 20, ey + 15) end
    end
    self._sidebarEntryUpdaters = self._sidebarEntryUpdaters or {}
    self._sidebarEntryUpdaters[categoryapi] = updateEntryPos

    registerHit(
        function() return Vector2.new(sidebarX(), sidebarEntryY()), Vector2.new(sidebarW, entryH) end,
        {
            onEnter = function()
                if not categoryapi.Expanded then
                    tweenProperty(entryBg, "Color", color.Light(uipallet.Main, 0.04), 0.16)
                    tweenProperty(entryText, "Color", uipallet.Text, 0.16)
                end
            end,
            onLeave = function()
                if not categoryapi.Expanded then
                    tweenProperty(entryBg, "Color", uipallet.Main, 0.16)
                    tweenProperty(entryText, "Color", color.Dark(uipallet.Text, 0.16), 0.16)
                end
            end,
            onClick = function() categoryapi:Expand(not categoryapi.Expanded) end,
        }
    )

    -- VapeV4: all panels default to X=236 (right of 220px sidebar + 16px gap),
    -- stacked at the same position. Users drag them apart as needed.
    -- A small cascade offset (sidebarIndex * 16) avoids exact overlap on first open.
    local panelDefaultX = (self._sidebarPos and self._sidebarPos.X or 6) + 220 + 16
    categoryapi._pos = {
        X = panelDefaultX + sidebarIndex * 16,
        Y = 60 + sidebarIndex * 16,
    }
    local panelW, panelH = categoryapi._panelSize.W, categoryapi._panelSize.H

    local panelBg = Draw("Square", {
        Size = Vector2.new(panelW, panelH), Position = Vector2.new(categoryapi._pos.X, categoryapi._pos.Y),
        Color = uipallet.Main, Filled = true, Transparency = 1, ZIndex = 5, Visible = false,
    })
    local panelTitle = Draw("Text", {
        Text = settings.Name, Position = Vector2.new(categoryapi._pos.X + 40, categoryapi._pos.Y + 13),
        Size = 13, Font = Drawing.Fonts.UI, Color = uipallet.Text, Transparency = 1, ZIndex = 6, Visible = false,
    })
    -- Panel category icon
    local panelIcon = settings.Icon and DrawImage(settings.Icon, {
        Size = Vector2.new(18, 18), Position = Vector2.new(categoryapi._pos.X + 12, categoryapi._pos.Y + 12),
        Transparency = 1, ZIndex = 6, Visible = false,
    }) or nil
    local panelDivider = Draw("Square", {
        Size = Vector2.new(panelW, 1), Position = Vector2.new(categoryapi._pos.X, categoryapi._pos.Y + 37),
        Color = Color3.new(1, 1, 1), Filled = true, Transparency = 0.93, ZIndex = 6, Visible = false,
    })
    local closeHit = Draw("Square", {
        Size = Vector2.new(24, 24), Position = Vector2.new(categoryapi._pos.X + panelW - 30, categoryapi._pos.Y + 9),
        Color = Color3.new(0, 0, 0), Filled = true, Transparency = 0, ZIndex = 7, Visible = false,
    })
    local closeImg = DrawImage(Assets.Close, {
        Size = Vector2.new(14, 14), Position = Vector2.new(categoryapi._pos.X + panelW - 26, categoryapi._pos.Y + 14),
        Transparency = 1, ZIndex = 8, Visible = false,
    })
    local closeText = Draw("Text", {
        Text = "x", Position = Vector2.new(categoryapi._pos.X + panelW - 20, categoryapi._pos.Y + 13),
        Size = 14, Font = Drawing.Fonts.UI, Color = color.Light(uipallet.Main, 0.37),
        Transparency = 1, ZIndex = 8, Visible = false,
    })
    -- Panel drawings tracked separately for clean show/hide.
    categoryapi._panelDrawings = { panelBg, panelTitle, panelDivider, closeHit, closeText }
    categoryapi._closeImg, categoryapi._closeText = closeImg, closeText
    if panelIcon then table.insert(categoryapi._panelDrawings, panelIcon) end
    if closeImg then table.insert(categoryapi._panelDrawings, closeImg) end
    for _, d in ipairs(categoryapi._panelDrawings) do table.insert(categoryapi._drawings, d) end

    local function applyPanelPos()
        local px, py = categoryapi._pos.X, categoryapi._pos.Y
        panelBg.Position = Vector2.new(px, py)
        panelTitle.Position = Vector2.new(px + 40, py + 13)
        if panelIcon then panelIcon.Position = Vector2.new(px + 12, py + 12) end
        panelDivider.Position = Vector2.new(px, py + 37)
        closeHit.Position = Vector2.new(px + panelW - 30, py + 9)
        closeText.Position = Vector2.new(px + panelW - 20, py + 13)
        if closeImg then closeImg.Position = Vector2.new(px + panelW - 26, py + 14) end
        categoryapi._moduleLayout.clipPos = Vector2.new(px, py + 41)
        categoryapi._moduleLayout.clipSize = Vector2.new(panelW, panelH - 41)
        categoryapi._moduleLayout.startY = py + 41
    end

    registerHit(
        function() return Vector2.new(categoryapi._pos.X + panelW - 30, categoryapi._pos.Y + 9), Vector2.new(24, 24) end,
        {
            onEnter = function() tweenProperty(closeText, "Color", uipallet.Text, 0.16) end,
            onLeave = function() tweenProperty(closeText, "Color", color.Light(uipallet.Main, 0.37), 0.16) end,
            onClick = function() categoryapi:Expand(false) end,
        },
        closeHit
    )

    local panelDrag = { dragging = false, offset = Vector2.new(0, 0) }
    registerHit(
        function() return Vector2.new(categoryapi._pos.X, categoryapi._pos.Y), Vector2.new(panelW - 26, 33) end,
        { onDown = function()
            panelDrag.dragging = true
            panelDrag.offset = getMousePos() - Vector2.new(categoryapi._pos.X, categoryapi._pos.Y)
        end },
        panelBg
    )
    mainapi._draggablePanels = mainapi._draggablePanels or {}
    mainapi._draggablePanels[categoryapi] = function()
        if panelDrag.dragging then
            local m = getMousePos()
            categoryapi._pos.X = math.clamp(m.X - panelDrag.offset.X, 0, Camera.ViewportSize.X - panelW)
            categoryapi._pos.Y = math.clamp(m.Y - panelDrag.offset.Y, 0, Camera.ViewportSize.Y - panelH)
            applyPanelPos()
        end
    end
    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then panelDrag.dragging = false end
    end)

    local moduleLayout, moduleLayoutId = createLayout({
        startY = categoryapi._pos.Y + 41, padding = 0,
        clipPos = Vector2.new(categoryapi._pos.X, categoryapi._pos.Y + 41),
        clipSize = Vector2.new(panelW, panelH - 41),
    })
    categoryapi._moduleLayout = moduleLayout
    categoryapi._moduleLayoutId = moduleLayoutId

    function categoryapi:Expand(check)
        self.Expanded = check
        for _, d in ipairs(self._panelDrawings) do
            d.Visible = check and mainapi.GUIVisible
        end
        -- If a close-icon image loaded, keep the text "x" hidden.
        if closeImg and closeText then closeText.Visible = false end
        if check then
            tweenProperty(entryArrow, "Position", Vector2.new(sidebarX() + sidebarW - 14, sidebarEntryY() + 13), 0.16)
            tweenProperty(entryText, "Color", accentColor(), 0.16)
        else
            tweenProperty(entryArrow, "Position", Vector2.new(sidebarX() + sidebarW - 18, sidebarEntryY() + 13), 0.16)
            tweenProperty(entryText, "Color", color.Dark(uipallet.Text, 0.16), 0.16)
        end
        for _, mod in ipairs(self._moduleList) do mod:_setVisible(check and mainapi.GUIVisible) end
    end

    function categoryapi:CreateModule(moduleSettings)
        assert(moduleSettings and moduleSettings.Name, "CreateModule: Name required")
        if mainapi.Modules[moduleSettings.Name] then mainapi:Remove(moduleSettings.Name) end

        local moduleapi = {
            Type = "Module", Enabled = false, Options = {}, Bind = {},
            Name = moduleSettings.Name, Tooltip = moduleSettings.Tooltip,
            ExtraText = moduleSettings.ExtraText, Category = settings.Name,
            Index = (function() local n = 0 for _ in pairs(mainapi.Modules) do n = n + 1 end return n end)(),
            _drawings = {}, _expanded = false, _hitIds = {}, _visible = false,
        }
        addMaid(moduleapi)
        mainapi.Modules[moduleSettings.Name] = moduleapi
        moduleSettings.Function = moduleSettings.Function or function() end

        local rowH, rowW = 40, panelW
        local rowY = categoryapi._pos.Y + 38
        local function rowX() return categoryapi._pos.X end

        local rowBg = Draw("Square", {
            Size = Vector2.new(rowW, rowH), Position = Vector2.new(rowX(), rowY),
            Color = uipallet.Main, Filled = true, Transparency = 1, ZIndex = 6, Visible = false,
        })
        -- Bottom divider shown only when module is enabled (matches VapeV4)
        local rowDivider = Draw("Square", {
            Size = Vector2.new(rowW, 1), Position = Vector2.new(rowX(), rowY + rowH - 1),
            Color = Color3.new(0, 0, 0), Filled = true, Transparency = 0.85, ZIndex = 7, Visible = false,
        })
        local rowText = Draw("Text", {
            -- VapeV4 indents module names ~44px from left (matching '            '..name)
            Text = moduleSettings.Name, Position = Vector2.new(rowX() + 44, rowY + 13),
            Size = 14, Font = Drawing.Fonts.UI, Color = color.Dark(uipallet.Text, 0.16),
            Transparency = 1, ZIndex = 7, Visible = false,
        })
        local rowDotsImg = DrawImage(Assets.Dots, {
            Size = Vector2.new(4, 14), Position = Vector2.new(rowX() + rowW - 22, rowY + 13),
            Transparency = 1, ZIndex = 7, Visible = false,
        })
        local rowDots = Draw("Text", {
            Text = "...", Position = Vector2.new(rowX() + rowW - 22, rowY + 13),
            Size = 13, Font = Drawing.Fonts.UI, Color = color.Light(uipallet.Main, 0.37),
            Transparency = 1, ZIndex = 7, Visible = false,
        })
        local bindBg = Draw("Square", {
            Size = Vector2.new(30, 18), Position = Vector2.new(rowX() + rowW - 50, rowY + 11),
            Color = Color3.new(1, 1, 1), Filled = true, Transparency = 0.92, ZIndex = 7, Visible = false,
        })
        local bindText = Draw("Text", {
            Text = "", Position = Vector2.new(rowX() + rowW - 50, rowY + 12),
            Size = 11, Font = Drawing.Fonts.UI, Color = color.Dark(uipallet.Text, 0.43),
            Transparency = 1, ZIndex = 8, Visible = false, Center = true,
        })
        table.insert(moduleapi._drawings, rowBg)
        table.insert(moduleapi._drawings, rowDivider)
        table.insert(moduleapi._drawings, rowText)
        table.insert(moduleapi._drawings, rowDots)
        if rowDotsImg then table.insert(moduleapi._drawings, rowDotsImg) end
        table.insert(moduleapi._drawings, bindBg)
        table.insert(moduleapi._drawings, bindText)

        local childLayout, childLayoutId = createLayout({ startY = rowY + rowH, padding = 0 })
        -- CRITICAL: the module row drives its own children manually inside its
        -- layoutEntry.apply (with correct expand/visibility gating). If we also
        -- leave this child layout registered globally, updateLayouts() would
        -- re-apply every component each frame with visible=true and no clip,
        -- forcing all toggles/sliders/buttons of every module visible on top of
        -- each other (the overlapping jumble bug). So unregister it from the
        -- global layout loop while keeping the table for manual driving.
        removeLayout(childLayoutId)
        local childrenContainer = { _drawings = {}, _visible = false, _layout = childLayout, _layoutId = childLayoutId, _totalHeight = 0 }
        moduleapi._children = childrenContainer

        local layoutEntry
        layoutEntry = {
            height = rowH,
            apply = function(y, isVisible)
                rowY = y
                rowBg.Position = Vector2.new(rowX(), y)
                rowDivider.Position = Vector2.new(rowX(), y + rowH - 1)
                rowText.Position = Vector2.new(rowX() + 44, y + 13)
                rowDots.Position = Vector2.new(rowX() + rowW - 22, y + 13)
                if rowDotsImg then rowDotsImg.Position = Vector2.new(rowX() + rowW - 22, y + 13) end
                childrenContainer._layout.startY = y + rowH
                local totalChildH = 0
                for _, child in ipairs(childrenContainer._layout.children) do
                    local cY = y + rowH + totalChildH
                    if child.apply then child.apply(cY, moduleapi._expanded and moduleapi._visible and isVisible) end
                    totalChildH = totalChildH + child.height
                end
                childrenContainer._totalHeight = totalChildH
                layoutEntry.height = rowH + (moduleapi._expanded and totalChildH or 0)

                local vis = moduleapi._visible and isVisible
                rowBg.Visible = vis
                -- Bottom divider only shows when module is enabled (VapeV4 style)
                rowDivider.Visible = vis and moduleapi.Enabled
                rowText.Visible = vis
                if rowDotsImg then
                    rowDotsImg.Visible = vis
                    rowDots.Visible = false
                else
                    rowDots.Visible = vis
                end
                bindBg.Visible = vis and #moduleapi.Bind > 0
                bindText.Visible = vis and #moduleapi.Bind > 0
                if #moduleapi.Bind > 0 then
                    local w = #bindText.Text * 6 + 8
                    bindBg.Size = Vector2.new(w, 18)
                    bindBg.Position = Vector2.new(rowX() + rowW - w - 28, y + 11)
                    bindText.Position = Vector2.new(rowX() + rowW - w - 28 + w / 2, y + 12)
                end
            end,
        }
        layoutAdd(categoryapi._moduleLayout, layoutEntry)

        local rowHitId = registerHit(
            function() return Vector2.new(rowX(), rowY), Vector2.new(rowW - 34, rowH) end,
            {
                onEnter = function()
                    if not moduleapi.Enabled then
                        tweenProperty(rowBg, "Color", color.Light(uipallet.Main, 0.02), 0.16)
                        tweenProperty(rowText, "Color", uipallet.Text, 0.16)
                    end
                end,
                onLeave = function()
                    if not moduleapi.Enabled then
                        tweenProperty(rowBg, "Color", uipallet.Main, 0.16)
                        tweenProperty(rowText, "Color", color.Dark(uipallet.Text, 0.16), 0.16)
                    end
                end,
                onClick = function() moduleapi:Toggle() end,
            },
            rowBg
        )
        table.insert(moduleapi._hitIds, rowHitId)

        local dotsHitId = registerHit(
            function() return Vector2.new(rowX() + rowW - 34, rowY), Vector2.new(34, rowH) end,
            {
                onEnter = function()
                    local dotsCol = moduleapi.Enabled and Color3.new(0.19, 0.19, 0.19) or uipallet.Text
                    tweenProperty(rowDots, "Color", dotsCol, 0.16)
                end,
                onLeave = function()
                    local dotsCol = moduleapi.Enabled and Color3.fromRGB(50, 50, 50) or color.Light(uipallet.Main, 0.37)
                    tweenProperty(rowDots, "Color", dotsCol, 0.16)
                end,
                onClick = function() moduleapi._expanded = not moduleapi._expanded end,
            },
            rowBg
        )
        table.insert(moduleapi._hitIds, dotsHitId)

        local bindHitId = registerHit(
            function() return Vector2.new(rowX() + rowW - 50, rowY + 11), Vector2.new(30, 18) end,
            {
                onClick = function()
                    if #moduleapi.Bind == 0 then return end
                    bindText.Text = "..."
                    startKeyCapture(function(kc)
                        local name = keyCodeName(kc)
                        if name and name ~= "Unknown" then moduleapi:SetBind({ name }) return true end
                        return false
                    end)
                end,
            },
            bindBg
        )
        table.insert(moduleapi._hitIds, bindHitId)

        function moduleapi:Toggle(silent)
            self.Enabled = not self.Enabled
            if self.Enabled then
                -- VapeV4 look: the whole row fills with the accent (or per-row
                -- rainbow) color and the label flips to a contrasting tone.
                self:registerThemedRow()
                mainapi:UpdateGUI(mainapi.GUIColor.Hue, mainapi.GUIColor.Sat, mainapi.GUIColor.Value)
                rowDivider.Visible = self._visible
            else
                self:unregisterThemedRow()
                tweenProperty(rowBg, "Color", uipallet.Main, 0.16)
                tweenProperty(rowText, "Color", color.Dark(uipallet.Text, 0.16), 0.16)
                rowDivider.Visible = false
            end
            if mainapi._updateArraylist then pcall(mainapi._updateArraylist) end
            moduleSettings.Function(self.Enabled)
        end

        -- Register both the row background and its label as themed so they track
        -- the GUI color / rainbow each frame while the module is enabled.
        function moduleapi:registerThemedRow()
            self:unregisterThemedRow()
            self._themedRow = { rowBg, rowText }
            mainapi:registerThemed(rowBg, "rowbg", self.Index)
            mainapi:registerThemed(rowText, "rowtext", self.Index)
        end
        function moduleapi:unregisterThemedRow()
            if self._themedRow then
                for _, o in ipairs(self._themedRow) do mainapi:unregisterThemed(o) end
                self._themedRow = nil
            end
        end

        function moduleapi:SetBind(keys)
            self.Bind = keys
            if #keys > 0 then
                bindText.Text = table.concat(keys, "+"):upper()
            else
                bindBg.Visible = false
                bindText.Visible = false
            end
        end

        function moduleapi:_setVisible(vis) self._visible = vis end

        -- Component factories
        function moduleapi:CreateToggle(opts) return mainapi._components.Toggle(self, opts) end
        function moduleapi:CreateButton(opts) return mainapi._components.Button(self, opts) end
        function moduleapi:CreateSlider(opts) return mainapi._components.Slider(self, opts) end
        function moduleapi:CreateTwoSlider(opts) return mainapi._components.TwoSlider(self, opts) end
        function moduleapi:CreateDropdown(opts) return mainapi._components.Dropdown(self, opts) end
        function moduleapi:CreateTextBox(opts) return mainapi._components.TextBox(self, opts) end
        function moduleapi:CreateColorSlider(opts) return mainapi._components.ColorSlider(self, opts) end
        function moduleapi:CreateKeybind(opts) return mainapi._components.Keybind(self, opts) end

        table.insert(categoryapi._moduleList, moduleapi)
        return moduleapi
    end

    self.Categories[settings.Name] = categoryapi
    return categoryapi
end

-- ============================================================
-- 18. COMPONENT HELPERS
-- ============================================================
mainapi._components = {}

-- shared helpers for components: panel X & width getters from the owning module
local function moduleX(moduleapi)
    return moduleapi.Category and mainapi.Categories[moduleapi.Category]._pos.X or 236
end
local function moduleW(moduleapi)
    return moduleapi.Category and mainapi.Categories[moduleapi.Category]._panelSize.W or 220
end

-- ============================================================
-- 18a. TOGGLE
-- ============================================================
function mainapi._components.Toggle(moduleapi, optionsettings)
    assert(optionsettings and optionsettings.Name, "CreateToggle: Name required")
    local optionapi = {
        Type = "Toggle", Enabled = false, Name = optionsettings.Name,
        Index = (function() local n = 0 for _ in pairs(moduleapi.Options) do n = n + 1 end return n end)(),
        _drawings = {}, _hitIds = {},
    }
    addMaid(optionapi)
    moduleapi.Options[optionsettings.Name] = optionapi
    optionsettings.Function = optionsettings.Function or function() end

    local rowH = 32
    local function rowX() return moduleX(moduleapi) end
    local rowW = moduleW(moduleapi)

    local bg = Draw("Square", { Size = Vector2.new(rowW, rowH), Position = Vector2.new(rowX(), 0), Color = uipallet.Main, Filled = true, Transparency = 1, ZIndex = 7, Visible = false })
    local label = Draw("Text", { Text = optionsettings.Name, Position = Vector2.new(rowX() + 12, 8), Size = 13, Font = Drawing.Fonts.UI, Color = color.Dark(uipallet.Text, 0.16), Transparency = 1, ZIndex = 8, Visible = false })
    local knobW, knobH = 28, 14
    local function knobX() return rowX() + rowW - 40 end
    local track = Draw("Square", { Size = Vector2.new(knobW, knobH), Position = Vector2.new(knobX(), 9), Color = color.Light(uipallet.Main, 0.14), Filled = true, Transparency = 1, ZIndex = 8, Visible = false })
    local knob = Draw("Circle", { Radius = 5, Position = Vector2.new(knobX() + 7, 16), Color = Color3.fromRGB(200, 200, 200), Filled = true, Transparency = 1, ZIndex = 9, Visible = false, NumSides = 18 })

    table.insert(optionapi._drawings, bg)
    table.insert(optionapi._drawings, label)
    table.insert(optionapi._drawings, track)
    table.insert(optionapi._drawings, knob)

    local curY = 0
    layoutAdd(moduleapi._children._layout, {
        height = rowH,
        apply = function(y, isVisible)
            curY = y
            bg.Position = Vector2.new(rowX(), y)
            label.Position = Vector2.new(rowX() + 12, y + 8)
            track.Position = Vector2.new(knobX(), y + 9)
            knob.Position = Vector2.new(knobX() + (optionapi.Enabled and 21 or 7), y + 16)
            local vis = isVisible
            bg.Visible = vis; label.Visible = vis; track.Visible = vis; knob.Visible = vis
        end,
    })

    local hovered = false
    local hitId = registerHit(
        function() return Vector2.new(rowX(), curY), Vector2.new(rowW, rowH) end,
        {
            onEnter = function() hovered = true if not optionapi.Enabled then tweenProperty(track, "Color", color.Light(uipallet.Main, 0.37), 0.16) end end,
            onLeave = function() hovered = false if not optionapi.Enabled then tweenProperty(track, "Color", color.Light(uipallet.Main, 0.14), 0.16) end end,
            onClick = function() optionapi:Toggle() end,
        },
        bg
    )
    table.insert(optionapi._hitIds, hitId)

    function optionapi:Toggle()
        self.Enabled = not self.Enabled
        local rainbow = mainapi.GUIColor.Rainbow
        local ac = rainbow and Color3.fromHSV(mainapi:Color((mainapi.GUIColor.Hue - (self.Index * 0.075)) % 1)) or accentColor()
        if self.Enabled then
            tweenProperty(track, "Color", ac, 0.16)
            tweenProperty(knob, "Color", Color3.fromRGB(240, 240, 240), 0.16)
            tweenProperty(knob, "Position", Vector2.new(knobX() + 21, knob.Position.Y), 0.16)
            mainapi:registerThemed(track, "rainbow", self.Index)
        else
            tweenProperty(track, "Color", hovered and color.Light(uipallet.Main, 0.37) or color.Light(uipallet.Main, 0.14), 0.16)
            tweenProperty(knob, "Color", Color3.fromRGB(200, 200, 200), 0.16)
            tweenProperty(knob, "Position", Vector2.new(knobX() + 7, knob.Position.Y), 0.16)
            mainapi:unregisterThemed(track)
        end
        optionsettings.Function(self.Enabled)
    end

    function optionapi:Save(tab) tab[optionsettings.Name] = { Enabled = self.Enabled } end
    function optionapi:Load(tab) if tab and self.Enabled ~= tab.Enabled then self:Toggle() end end

    if optionsettings.Default then optionapi:Toggle() end
    return optionapi
end

-- ============================================================
-- 18b. BUTTON
-- ============================================================
function mainapi._components.Button(moduleapi, optionsettings)
    assert(optionsettings and optionsettings.Name, "CreateButton: Name required")
    local optionapi = { Type = "Button", Name = optionsettings.Name, _drawings = {}, _hitIds = {} }
    addMaid(optionapi)
    moduleapi.Options[optionsettings.Name] = optionapi
    optionsettings.Function = optionsettings.Function or function() end

    local rowH = 31
    local function rowX() return moduleX(moduleapi) end
    local rowW = moduleW(moduleapi)

    local btnBg = Draw("Square", { Size = Vector2.new(rowW - 20, 27), Position = Vector2.new(rowX() + 10, 2), Color = color.Light(uipallet.Main, 0.05), Filled = true, Transparency = 1, ZIndex = 7, Visible = false })
    -- Inner frame matches VapeV4's Button > bkg > label structure
    local btnLabel = Draw("Text", { Text = optionsettings.Name, Position = Vector2.new(rowX() + 10 + (rowW - 20) / 2, 8), Size = 14, Font = Drawing.Fonts.UI, Color = color.Dark(uipallet.Text, 0.16), Transparency = 1, ZIndex = 8, Visible = false, Center = true })

    table.insert(optionapi._drawings, btnBg)
    table.insert(optionapi._drawings, btnLabel)

    local curY = 0
    layoutAdd(moduleapi._children._layout, {
        height = rowH,
        apply = function(y, isVisible)
            curY = y
            btnBg.Position = Vector2.new(rowX() + 10, y + 2)
            btnLabel.Position = Vector2.new(rowX() + 10 + (rowW - 20) / 2, y + 8)
            btnBg.Visible = isVisible; btnLabel.Visible = isVisible
        end,
    })

    local hitId = registerHit(
        function() return Vector2.new(rowX() + 10, curY + 2), Vector2.new(rowW - 20, 27) end,
        {
            onEnter = function() tweenProperty(btnBg, "Color", color.Light(uipallet.Main, 0.0875), 0.16) end,
            onLeave = function() tweenProperty(btnBg, "Color", color.Light(uipallet.Main, 0.05), 0.16) end,
            onClick = function() optionsettings.Function() end,
        },
        btnBg
    )
    table.insert(optionapi._hitIds, hitId)
    return optionapi
end

-- ============================================================
-- 18c. SLIDER
-- ============================================================
function mainapi._components.Slider(moduleapi, optionsettings)
    assert(optionsettings and optionsettings.Name, "CreateSlider: Name required")
    local minV = optionsettings.Min or 0
    local maxV = optionsettings.Max or 100
    local decimals = optionsettings.Decimals or 0
    local suffix = optionsettings.Suffix or ""
    local optionapi = {
        Type = "Slider", Name = optionsettings.Name,
        Value = optionsettings.Default or minV,
        _drawings = {}, _hitIds = {},
    }
    addMaid(optionapi)
    moduleapi.Options[optionsettings.Name] = optionapi
    optionsettings.Function = optionsettings.Function or function() end

    local rowH = 40
    local function rowX() return moduleX(moduleapi) end
    local rowW = moduleW(moduleapi)
    local barX = function() return rowX() + 12 end
    local barW = rowW - 24
    local barH = 4

    local function roundVal(v)
        local mult = 10 ^ decimals
        return math.floor(v * mult + 0.5) / mult
    end

    local label = Draw("Text", { Text = optionsettings.Name, Position = Vector2.new(rowX() + 12, 4), Size = 11, Font = Drawing.Fonts.UI, Color = color.Dark(uipallet.Text, 0.16), Transparency = 1, ZIndex = 8, Visible = false })
    local valueText = Draw("Text", { Text = "", Position = Vector2.new(rowX() + rowW - 12, 4), Size = 11, Font = Drawing.Fonts.UI, Color = color.Dark(uipallet.Text, 0.16), Transparency = 1, ZIndex = 8, Visible = false })
    local track = Draw("Square", { Size = Vector2.new(barW, barH), Position = Vector2.new(barX(), 28), Color = color.Light(uipallet.Main, 0.034), Filled = true, Transparency = 1, ZIndex = 7, Visible = false })
    local fill = Draw("Square", { Size = Vector2.new(0, barH), Position = Vector2.new(barX(), 28), Color = accentColor(), Filled = true, Transparency = 1, ZIndex = 8, Visible = false })
    local knob = Draw("Circle", { Radius = 6, Position = Vector2.new(barX(), 30), Color = accentColor(), Filled = true, Transparency = 1, ZIndex = 9, Visible = false, NumSides = 18 })

    table.insert(optionapi._drawings, label)
    table.insert(optionapi._drawings, valueText)
    table.insert(optionapi._drawings, track)
    table.insert(optionapi._drawings, fill)
    table.insert(optionapi._drawings, knob)
    mainapi:registerThemed(fill, "accent")
    mainapi:registerThemed(knob, "accent")

    local curY = 0
    local function alpha() return (optionapi.Value - minV) / (maxV - minV) end

    layoutAdd(moduleapi._children._layout, {
        height = rowH,
        apply = function(y, isVisible)
            curY = y
            label.Position = Vector2.new(rowX() + 12, y + 4)
            valueText.Text = tostring(roundVal(optionapi.Value)) .. suffix
            valueText.Position = Vector2.new(rowX() + rowW - 12 - (#valueText.Text * 6), y + 4)
            track.Position = Vector2.new(barX(), y + 28)
            local a = alpha()
            fill.Size = Vector2.new(barW * a, barH)
            fill.Position = Vector2.new(barX(), y + 28)
            knob.Position = Vector2.new(barX() + barW * a, y + 30)
            local vis = isVisible
            label.Visible = vis; valueText.Visible = vis; track.Visible = vis; fill.Visible = vis; knob.Visible = vis
        end,
    })

    local dragging = false
    local dragId = "slider_" .. tostring(optionapi) .. tostring(math.random())
    mainapi.ComponentDrags[dragId] = function()
        if dragging then
            local mx = getMousePos().X
            local a = math.clamp((mx - barX()) / barW, 0, 1)
            optionapi:Set(minV + (maxV - minV) * a)
        end
    end

    local hitId = registerHit(
        function() return Vector2.new(barX() - 6, curY + 18), Vector2.new(barW + 12, 20) end,
        {
            onDown = function() dragging = true end,
            onUp = function() dragging = false end,
        },
        track
    )
    table.insert(optionapi._hitIds, hitId)
    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
    end)

    function optionapi:Set(v, silent)
        self.Value = math.clamp(roundVal(v), minV, maxV)
        if not silent then optionsettings.Function(self.Value) end
    end
    function optionapi:Save(tab) tab[optionsettings.Name] = { Value = self.Value } end
    function optionapi:Load(tab) if tab and tab.Value then self:Set(tab.Value) end end

    optionapi:Set(optionapi.Value)
    return optionapi
end

-- ============================================================
-- 18d. TWO-SLIDER (min/max range)
-- ============================================================
function mainapi._components.TwoSlider(moduleapi, optionsettings)
    assert(optionsettings and optionsettings.Name, "CreateTwoSlider: Name required")
    local minV = optionsettings.Min or 0
    local maxV = optionsettings.Max or 100
    local suffix = optionsettings.Suffix or ""
    local optionapi = {
        Type = "TwoSlider", Name = optionsettings.Name,
        ValueMin = optionsettings.DefaultMin or minV,
        ValueMax = optionsettings.DefaultMax or maxV,
        _drawings = {}, _hitIds = {},
    }
    addMaid(optionapi)
    moduleapi.Options[optionsettings.Name] = optionapi
    optionsettings.Function = optionsettings.Function or function() end

    local rowH = 40
    local function rowX() return moduleX(moduleapi) end
    local rowW = moduleW(moduleapi)
    local barX = function() return rowX() + 12 end
    local barW = rowW - 24

    local label = Draw("Text", { Text = optionsettings.Name, Position = Vector2.new(rowX() + 12, 4), Size = 11, Font = Drawing.Fonts.UI, Color = color.Dark(uipallet.Text, 0.16), Transparency = 1, ZIndex = 8, Visible = false })
    local valueText = Draw("Text", { Text = "", Position = Vector2.new(rowX() + rowW - 12, 4), Size = 11, Font = Drawing.Fonts.UI, Color = color.Dark(uipallet.Text, 0.16), Transparency = 1, ZIndex = 8, Visible = false })
    local track = Draw("Square", { Size = Vector2.new(barW, 4), Position = Vector2.new(barX(), 28), Color = color.Light(uipallet.Main, 0.034), Filled = true, Transparency = 1, ZIndex = 7, Visible = false })
    local fill = Draw("Square", { Size = Vector2.new(0, 4), Position = Vector2.new(barX(), 28), Color = accentColor(), Filled = true, Transparency = 1, ZIndex = 8, Visible = false })
    local knobMin = Draw("Circle", { Radius = 6, Position = Vector2.new(barX(), 30), Color = accentColor(), Filled = true, Transparency = 1, ZIndex = 9, Visible = false, NumSides = 18 })
    local knobMax = Draw("Circle", { Radius = 6, Position = Vector2.new(barX() + barW, 30), Color = accentColor(), Filled = true, Transparency = 1, ZIndex = 9, Visible = false, NumSides = 18 })

    for _, d in ipairs({ label, valueText, track, fill, knobMin, knobMax }) do table.insert(optionapi._drawings, d) end
    mainapi:registerThemed(fill, "accent")
    mainapi:registerThemed(knobMin, "accent")
    mainapi:registerThemed(knobMax, "accent")

    local curY = 0
    local function aMin() return (optionapi.ValueMin - minV) / (maxV - minV) end
    local function aMax() return (optionapi.ValueMax - minV) / (maxV - minV) end

    layoutAdd(moduleapi._children._layout, {
        height = rowH,
        apply = function(y, isVisible)
            curY = y
            label.Position = Vector2.new(rowX() + 12, y + 4)
            valueText.Text = math.floor(optionapi.ValueMin) .. " - " .. math.floor(optionapi.ValueMax) .. suffix
            valueText.Position = Vector2.new(rowX() + rowW - 12 - (#valueText.Text * 6), y + 4)
            track.Position = Vector2.new(barX(), y + 28)
            fill.Position = Vector2.new(barX() + barW * aMin(), y + 28)
            fill.Size = Vector2.new(barW * (aMax() - aMin()), 4)
            knobMin.Position = Vector2.new(barX() + barW * aMin(), y + 30)
            knobMax.Position = Vector2.new(barX() + barW * aMax(), y + 30)
            for _, d in ipairs({ label, valueText, track, fill, knobMin, knobMax }) do d.Visible = isVisible end
        end,
    })

    local draggingMin, draggingMax = false, false
    local dragId = "twoslider_" .. tostring(optionapi) .. tostring(math.random())
    mainapi.ComponentDrags[dragId] = function()
        if draggingMin or draggingMax then
            local mx = getMousePos().X
            local a = math.clamp((mx - barX()) / barW, 0, 1)
            local v = minV + (maxV - minV) * a
            if draggingMin then optionapi:Set(math.min(v, optionapi.ValueMax), optionapi.ValueMax)
            else optionapi:Set(optionapi.ValueMin, math.max(v, optionapi.ValueMin)) end
        end
    end

    local hitId = registerHit(
        function() return Vector2.new(barX() - 6, curY + 18), Vector2.new(barW + 12, 20) end,
        {
            onDown = function()
                local mx = getMousePos().X
                local minPx = barX() + barW * aMin()
                local maxPx = barX() + barW * aMax()
                if math.abs(mx - minPx) <= math.abs(mx - maxPx) then draggingMin = true else draggingMax = true end
            end,
            onUp = function() draggingMin = false draggingMax = false end,
        },
        track
    )
    table.insert(optionapi._hitIds, hitId)
    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then draggingMin = false draggingMax = false end
    end)

    function optionapi:Set(lo, hi, silent)
        self.ValueMin = math.clamp(math.floor(lo + 0.5), minV, maxV)
        self.ValueMax = math.clamp(math.floor(hi + 0.5), minV, maxV)
        if not silent then optionsettings.Function(self.ValueMin, self.ValueMax) end
    end
    function optionapi:Save(tab) tab[optionsettings.Name] = { Min = self.ValueMin, Max = self.ValueMax } end
    function optionapi:Load(tab) if tab then self:Set(tab.Min or self.ValueMin, tab.Max or self.ValueMax) end end

    optionapi:Set(optionapi.ValueMin, optionapi.ValueMax)
    return optionapi
end

-- ============================================================
-- 18e. DROPDOWN
-- ============================================================
function mainapi._components.Dropdown(moduleapi, optionsettings)
    assert(optionsettings and optionsettings.Name, "CreateDropdown: Name required")
    local list = optionsettings.List or {}
    local optionapi = {
        Type = "Dropdown", Name = optionsettings.Name,
        Value = optionsettings.Default or list[1] or "",
        _drawings = {}, _hitIds = {}, _open = false, _rowDrawings = {},
    }
    addMaid(optionapi)
    moduleapi.Options[optionsettings.Name] = optionapi
    optionsettings.Function = optionsettings.Function or function() end

    local rowH = 40
    local function rowX() return moduleX(moduleapi) end
    local rowW = moduleW(moduleapi)
    local entryH = 26

    local boxBg = Draw("Square", { Size = Vector2.new(rowW - 20, 31), Position = Vector2.new(rowX() + 10, 4), Color = color.Light(uipallet.Main, 0.034), Filled = true, Transparency = 1, ZIndex = 7, Visible = false })
    -- Inner button to match VapeV4's border-within-border look
    local boxInner = Draw("Square", { Size = Vector2.new(rowW - 22, 29), Position = Vector2.new(rowX() + 11, 5), Color = uipallet.Main, Filled = true, Transparency = 1, ZIndex = 8, Visible = false })
    local boxLabel = Draw("Text", { Text = "         " .. optionsettings.Name .. " - " .. tostring(optionapi.Value), Position = Vector2.new(rowX() + 14, 11), Size = 13, Font = Drawing.Fonts.UI, Color = color.Dark(uipallet.Text, 0.16), Transparency = 1, ZIndex = 9, Visible = false })
    local boxArrow = Draw("Text", { Text = "v", Position = Vector2.new(rowX() + rowW - 20, 11), Size = 11, Font = Drawing.Fonts.UI, Color = Color3.fromRGB(140, 140, 140), Transparency = 1, ZIndex = 9, Visible = false })

    table.insert(optionapi._drawings, boxBg)
    table.insert(optionapi._drawings, boxInner)
    table.insert(optionapi._drawings, boxLabel)
    table.insert(optionapi._drawings, boxArrow)

    -- Pre-create the expanded list rows (one Square + Text per entry)
    local rowEntries = {}
    for i, item in ipairs(list) do
        local eBg = Draw("Square", { Size = Vector2.new(rowW - 20, entryH), Position = Vector2.new(rowX() + 10, 0), Color = uipallet.Main, Filled = true, Transparency = 1, ZIndex = 20, Visible = false })
        local eTxt = Draw("Text", { Text = "         " .. tostring(item), Position = Vector2.new(rowX() + 14, 0), Size = 13, Font = Drawing.Fonts.UI, Color = color.Dark(uipallet.Text, 0.16), Transparency = 1, ZIndex = 21, Visible = false })
        table.insert(optionapi._drawings, eBg)
        table.insert(optionapi._drawings, eTxt)
        rowEntries[i] = { bg = eBg, txt = eTxt, item = item, y = 0 }
    end

    local curY = 0
    local function dropdownHeight() return rowH + (optionapi._open and (#list * entryH - 4) or 0) end

    local layoutEntry
    layoutEntry = {
        height = rowH,
        apply = function(y, isVisible)
            curY = y
            boxBg.Position = Vector2.new(rowX() + 10, y + 4)
            boxInner.Position = Vector2.new(rowX() + 11, y + 5)
            boxLabel.Text = "         " .. optionsettings.Name .. " - " .. tostring(optionapi.Value)
            boxLabel.Position = Vector2.new(rowX() + 14, y + 11)
            boxArrow.Position = Vector2.new(rowX() + rowW - 20, y + 11)
            boxBg.Visible = isVisible; boxInner.Visible = isVisible
            boxLabel.Visible = isVisible; boxArrow.Visible = isVisible

            local openVis = isVisible and optionapi._open
            for i, e in ipairs(rowEntries) do
                local ey = y + 36 + (i - 1) * entryH
                e.y = ey
                e.bg.Position = Vector2.new(rowX() + 10, ey)
                e.txt.Position = Vector2.new(rowX() + 20, ey + 4)
                e.txt.Color = (e.item == optionapi.Value) and accentColor() or color.Dark(uipallet.Text, 0.16)
                e.bg.Visible = openVis; e.txt.Visible = openVis
            end
            layoutEntry.height = dropdownHeight()
        end,
    }
    layoutAdd(moduleapi._children._layout, layoutEntry)

    local boxHit = registerHit(
        function() return Vector2.new(rowX() + 10, curY + 4), Vector2.new(rowW - 20, 31) end,
        {
            onEnter = function() tweenProperty(boxBg, "Color", color.Light(uipallet.Main, 0.0875), 0.16) end,
            onLeave = function() tweenProperty(boxBg, "Color", color.Light(uipallet.Main, 0.034), 0.16) end,
            onClick = function() optionapi._open = not optionapi._open end,
        },
        boxBg
    )
    table.insert(optionapi._hitIds, boxHit)

    for i, e in ipairs(rowEntries) do
        local hit = registerHit(
            function() return Vector2.new(rowX() + 10, e.y), Vector2.new(rowW - 20, entryH) end,
            {
                onEnter = function()
                    tweenProperty(e.bg, "Color", color.Light(uipallet.Main, 0.02), 0.16)
                end,
                onLeave = function()
                    tweenProperty(e.bg, "Color", uipallet.Main, 0.16)
                end,
                onClick = function()
                    if not optionapi._open then return end
                    optionapi:Set(e.item)
                    optionapi._open = false
                end,
            },
            e.bg
        )
        table.insert(optionapi._hitIds, hit)
    end

    function optionapi:Set(v, silent)
        self.Value = v
        if not silent then optionsettings.Function(v) end
    end
    function optionapi:Save(tab) tab[optionsettings.Name] = { Value = self.Value } end
    function optionapi:Load(tab) if tab and tab.Value then self:Set(tab.Value) end end

    optionapi:Set(optionapi.Value, true)
    return optionapi
end

-- ============================================================
-- 18f. TEXTBOX
-- ============================================================
function mainapi._components.TextBox(moduleapi, optionsettings)
    assert(optionsettings and optionsettings.Name, "CreateTextBox: Name required")
    local optionapi = {
        Type = "TextBox", Name = optionsettings.Name,
        Value = optionsettings.Default or "",
        _drawings = {}, _hitIds = {}, _focused = false,
    }
    addMaid(optionapi)
    moduleapi.Options[optionsettings.Name] = optionapi
    optionsettings.Function = optionsettings.Function or function() end
    local placeholder = optionsettings.Placeholder or "..."

    local rowH = 37
    local function rowX() return moduleX(moduleapi) end
    local rowW = moduleW(moduleapi)

    local label = Draw("Text", { Text = optionsettings.Name, Position = Vector2.new(rowX() + 12, 5), Size = 11, Font = Drawing.Fonts.UI, Color = color.Dark(uipallet.Text, 0.16), Transparency = 1, ZIndex = 8, Visible = false })
    local boxBg = Draw("Square", { Size = Vector2.new(rowW - 20, 18), Position = Vector2.new(rowX() + 10, 16), Color = color.Light(uipallet.Main, 0.02), Filled = true, Transparency = 1, ZIndex = 7, Visible = false })
    local boxText = Draw("Text", { Text = "", Position = Vector2.new(rowX() + 14, 17), Size = 12, Font = Drawing.Fonts.UI, Color = color.Dark(uipallet.Text, 0.43), Transparency = 1, ZIndex = 8, Visible = false })

    table.insert(optionapi._drawings, label)
    table.insert(optionapi._drawings, boxBg)
    table.insert(optionapi._drawings, boxText)

    local curY = 0
    local function displayText()
        if optionapi._focused then return optionapi._buffer .. "|" end
        if optionapi.Value == "" then return placeholder end
        return optionapi.Value
    end

    layoutAdd(moduleapi._children._layout, {
        height = rowH,
        apply = function(y, isVisible)
            curY = y
            label.Position = Vector2.new(rowX() + 12, y + 5)
            boxBg.Position = Vector2.new(rowX() + 10, y + 16)
            boxText.Text = displayText()
            boxText.Color = (optionapi.Value == "" and not optionapi._focused) and color.Light(uipallet.Main, 0.37) or color.Dark(uipallet.Text, 0.43)
            boxText.Position = Vector2.new(rowX() + 14, y + 17)
            label.Visible = isVisible; boxBg.Visible = isVisible; boxText.Visible = isVisible
        end,
    })

    local hitId = registerHit(
        function() return Vector2.new(rowX() + 10, curY + 16), Vector2.new(rowW - 20, 18) end,
        {
            onEnter = function() tweenProperty(boxBg, "Color", color.Light(uipallet.Main, 0.034), 0.16) end,
            onLeave = function() tweenProperty(boxBg, "Color", color.Light(uipallet.Main, 0.02), 0.16) end,
            onClick = function()
                optionapi._focused = true
                optionapi._buffer = optionapi.Value
                startTextCapture(optionapi.Value, placeholder, function(finalText, enter)
                    optionapi._focused = false
                    if enter then optionapi:Set(finalText) end
                end)
                -- live update buffer via doneCallback already handled; mirror into buffer
                keyCapture.doneCallback = function(buf, enter)
                    optionapi._buffer = buf
                    if enter then
                        optionapi._focused = false
                        optionapi:Set(buf)
                    end
                end
            end,
        },
        boxBg
    )
    table.insert(optionapi._hitIds, hitId)

    function optionapi:Set(v, silent)
        self.Value = v or ""
        self._buffer = self.Value
        if not silent then optionsettings.Function(self.Value) end
    end
    function optionapi:Save(tab) tab[optionsettings.Name] = { Value = self.Value } end
    function optionapi:Load(tab) if tab and tab.Value then self:Set(tab.Value) end end

    optionapi._buffer = optionapi.Value
    optionapi:Set(optionapi.Value, true)
    return optionapi
end

-- ============================================================
-- 18g. COLOR SLIDER (hue / sat / value bars built from segments)
-- ============================================================
function mainapi._components.ColorSlider(moduleapi, optionsettings)
    assert(optionsettings and optionsettings.Name, "CreateColorSlider: Name required")
    local def = optionsettings.Default or Color3.fromRGB(255, 0, 0)
    local h0, s0, v0 = def:ToHSV()
    local optionapi = {
        Type = "ColorSlider", Name = optionsettings.Name,
        Hue = h0, Sat = s0, Value = v0,
        _drawings = {}, _hitIds = {}, _open = false, _segments = {},
    }
    addMaid(optionapi)
    moduleapi.Options[optionsettings.Name] = optionapi
    optionsettings.Function = optionsettings.Function or function() end

    local rowH = 30
    local function rowX() return moduleX(moduleapi) end
    local rowW = moduleW(moduleapi)
    local barW = rowW - 24
    local SEG = 24  -- segments per bar

    local label = Draw("Text", { Text = optionsettings.Name, Position = Vector2.new(rowX() + 12, 7), Size = 14, Font = Drawing.Fonts.UI, Color = color.Dark(uipallet.Text, 0.16), Transparency = 1, ZIndex = 8, Visible = false })
    local preview = Draw("Square", { Size = Vector2.new(20, 14), Position = Vector2.new(rowX() + rowW - 32, 8), Color = def, Filled = true, Transparency = 1, ZIndex = 8, Visible = false })

    table.insert(optionapi._drawings, label)
    table.insert(optionapi._drawings, preview)

    -- Build 3 bars (hue, sat, value), each SEG segments + a knob
    local bars = {}
    local function makeBar(kind)
        local segs = {}
        for i = 1, SEG do
            local sq = Draw("Square", { Size = Vector2.new(barW / SEG + 1, 8), Position = Vector2.new(0, 0), Color = Color3.new(0, 0, 0), Filled = true, Transparency = 1, ZIndex = 20, Visible = false })
            table.insert(optionapi._drawings, sq)
            segs[i] = sq
        end
        local knob = Draw("Square", { Size = Vector2.new(3, 12), Position = Vector2.new(0, 0), Color = Color3.new(1, 1, 1), Filled = true, Transparency = 1, ZIndex = 22, Visible = false })
        table.insert(optionapi._drawings, knob)
        local bar = { kind = kind, segs = segs, knob = knob, y = 0 }
        table.insert(bars, bar)
        return bar
    end
    local hueBar = makeBar("hue")
    local satBar = makeBar("sat")
    local valBar = makeBar("val")

    local curY = 0
    local function colorHeight() return rowH + (optionapi._open and (3 * 16 + 6) or 0) end

    local function segColor(kind, t)
        if kind == "hue" then return Color3.fromHSV(t, 1, 1)
        elseif kind == "sat" then return Color3.fromHSV(optionapi.Hue, t, optionapi.Value)
        else return Color3.fromHSV(optionapi.Hue, optionapi.Sat, t) end
    end
    local function barValue(kind)
        if kind == "hue" then return optionapi.Hue
        elseif kind == "sat" then return optionapi.Sat
        else return optionapi.Value end
    end

    local layoutEntry
    layoutEntry = {
        height = rowH,
        apply = function(y, isVisible)
            curY = y
            label.Position = Vector2.new(rowX() + 12, y + 7)
            preview.Position = Vector2.new(rowX() + rowW - 32, y + 8)
            preview.Color = Color3.fromHSV(optionapi.Hue, optionapi.Sat, optionapi.Value)
            label.Visible = isVisible; preview.Visible = isVisible

            local openVis = isVisible and optionapi._open
            for bi, bar in ipairs(bars) do
                local by = y + 28 + (bi - 1) * 16
                bar.y = by
                for i = 1, SEG do
                    local t = (i - 1) / (SEG - 1)
                    bar.segs[i].Position = Vector2.new(rowX() + 12 + (i - 1) * (barW / SEG), by)
                    bar.segs[i].Color = segColor(bar.kind, t)
                    bar.segs[i].Visible = openVis
                end
                local a = barValue(bar.kind)
                bar.knob.Position = Vector2.new(rowX() + 12 + barW * a - 1, by - 2)
                bar.knob.Visible = openVis
            end
            layoutEntry.height = colorHeight()
        end,
    }
    layoutAdd(moduleapi._children._layout, layoutEntry)

    -- preview click toggles open
    local prevHit = registerHit(
        function() return Vector2.new(rowX() + rowW - 32, curY + 8), Vector2.new(20, 14) end,
        { onClick = function() optionapi._open = not optionapi._open end },
        preview
    )
    table.insert(optionapi._hitIds, prevHit)

    -- drag on each bar
    local activeBar = nil
    local dragId = "color_" .. tostring(optionapi) .. tostring(math.random())
    mainapi.ComponentDrags[dragId] = function()
        if activeBar then
            local a = math.clamp((getMousePos().X - (rowX() + 12)) / barW, 0, 1)
            if activeBar.kind == "hue" then optionapi.Hue = a
            elseif activeBar.kind == "sat" then optionapi.Sat = a
            else optionapi.Value = a end
            optionapi:_fire()
        end
    end
    for _, bar in ipairs(bars) do
        local hit = registerHit(
            function() return Vector2.new(rowX() + 12, bar.y - 2), Vector2.new(barW, 12) end,
            { onDown = function() if optionapi._open then activeBar = bar end end, onUp = function() activeBar = nil end },
            bar.knob
        )
        table.insert(optionapi._hitIds, hit)
    end
    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then activeBar = nil end
    end)

    function optionapi:_fire() optionsettings.Function(Color3.fromHSV(self.Hue, self.Sat, self.Value)) end
    function optionapi:Set(c, silent)
        self.Hue, self.Sat, self.Value = c:ToHSV()
        if not silent then self:_fire() end
    end
    function optionapi:Save(tab) tab[optionsettings.Name] = { H = self.Hue, S = self.Sat, V = self.Value } end
    function optionapi:Load(tab)
        if tab then self.Hue, self.Sat, self.Value = tab.H or self.Hue, tab.S or self.Sat, tab.V or self.Value self:_fire() end
    end

    optionapi:_fire()
    return optionapi
end

-- ============================================================
-- 18h. KEYBIND (component-level)
-- ============================================================
function mainapi._components.Keybind(moduleapi, optionsettings)
    assert(optionsettings and optionsettings.Name, "CreateKeybind: Name required")
    local optionapi = {
        Type = "Keybind", Name = optionsettings.Name,
        Key = optionsettings.Default or "",
        _drawings = {}, _hitIds = {}, _binding = false,
    }
    addMaid(optionapi)
    moduleapi.Options[optionsettings.Name] = optionapi
    optionsettings.Function = optionsettings.Function or function() end

    local rowH = 32
    local function rowX() return moduleX(moduleapi) end
    local rowW = moduleW(moduleapi)

    local label = Draw("Text", { Text = optionsettings.Name, Position = Vector2.new(rowX() + 12, 8), Size = 13, Font = Drawing.Fonts.UI, Color = color.Dark(uipallet.Text, 0.16), Transparency = 1, ZIndex = 8, Visible = false })
    local keyBg = Draw("Square", { Size = Vector2.new(54, 18), Position = Vector2.new(rowX() + rowW - 66, 7), Color = color.Light(uipallet.Main, 0.034), Filled = true, Transparency = 1, ZIndex = 7, Visible = false })
    local keyTxt = Draw("Text", { Text = optionapi.Key ~= "" and optionapi.Key:upper() or "NONE", Position = Vector2.new(rowX() + rowW - 39, 9), Size = 11, Font = Drawing.Fonts.UI, Color = color.Dark(uipallet.Text, 0.43), Transparency = 1, ZIndex = 8, Visible = false, Center = true })

    table.insert(optionapi._drawings, label)
    table.insert(optionapi._drawings, keyBg)
    table.insert(optionapi._drawings, keyTxt)

    local curY = 0
    layoutAdd(moduleapi._children._layout, {
        height = rowH,
        apply = function(y, isVisible)
            curY = y
            label.Position = Vector2.new(rowX() + 12, y + 8)
            keyBg.Position = Vector2.new(rowX() + rowW - 66, y + 7)
            keyTxt.Text = optionapi._binding and "..." or (optionapi.Key ~= "" and optionapi.Key:upper() or "NONE")
            keyTxt.Position = Vector2.new(rowX() + rowW - 39, y + 9)
            label.Visible = isVisible; keyBg.Visible = isVisible; keyTxt.Visible = isVisible
        end,
    })

    local hitId = registerHit(
        function() return Vector2.new(rowX() + rowW - 66, curY + 7), Vector2.new(54, 18) end,
        {
            onEnter = function() tweenProperty(keyBg, "Color", color.Light(uipallet.Main, 0.0875), 0.16) end,
            onLeave = function() tweenProperty(keyBg, "Color", color.Light(uipallet.Main, 0.034), 0.16) end,
            onClick = function()
                optionapi._binding = true
                startKeyCapture(function(kc)
                    local name = keyCodeName(kc)
                    optionapi._binding = false
                    if name == "Escape" then optionapi:Set("") else optionapi:Set(name) end
                    return true
                end)
            end,
        },
        keyBg
    )
    table.insert(optionapi._hitIds, hitId)

    -- listen for the bound key
    optionapi._conn = UserInputService.InputBegan:Connect(function(input, gpe)
        if gpe or optionapi._binding then return end
        if optionapi.Key ~= "" and input.KeyCode == Enum.KeyCode[optionapi.Key] then
            optionsettings.Function(optionapi.Key)
        end
    end)
    optionapi:Clean(optionapi._conn)

    function optionapi:Set(key, silent) self.Key = key or "" if not silent then end end
    function optionapi:Save(tab) tab[optionsettings.Name] = { Key = self.Key } end
    function optionapi:Load(tab) if tab and tab.Key then self:Set(tab.Key) end end

    return optionapi
end

-- ============================================================
-- 19. REMOVE / UNINJECT
-- ============================================================
function mainapi:Remove(name)
    local module = self.Modules[name]
    if module then
        for _, d in ipairs(module._drawings) do destroyDraw(d) end
        for _, id in ipairs(module._hitIds) do unregisterHit(id) end
        if module._children then
            for _, opt in pairs(module.Options) do
                if opt._drawings then for _, d in ipairs(opt._drawings) do destroyDraw(d) end end
                if opt._hitIds then for _, id in ipairs(opt._hitIds) do unregisterHit(id) end end
                if type(opt.CleanAll) == "function" then pcall(opt.CleanAll, opt) end
            end
            removeLayout(module._children._layoutId or 0)
        end
        module:CleanAll()
        self.Modules[name] = nil
    end

    local category = self.Categories[name]
    if category then
        for _, d in ipairs(category._drawings) do destroyDraw(d) end
        if category._moduleLayoutId then removeLayout(category._moduleLayoutId) end
        if self._draggablePanels then self._draggablePanels[category] = nil end
        if self._sidebarEntryUpdaters then self._sidebarEntryUpdaters[category] = nil end
        category:CleanAll()
        self.Categories[name] = nil
    end
end

function mainapi:Uninject()
    for name in pairs(self.Categories) do self:Remove(name) end
    for name in pairs(self.Modules) do self:Remove(name) end
    for _, n in ipairs(notificationsContainer.list) do
        destroyDraw(n.bg); destroyDraw(n.accent); destroyDraw(n.title); destroyDraw(n.body); destroyDraw(n.progress)
    end
    notificationsContainer.list = {}
    stopRenderLoop()
    self._draggablePanels = {}
    self._sidebarDrag = nil
    self._sidebarEntryUpdaters = {}
    self._sidebarPos = nil
    self._clickguiRoot = nil
    self.HitTargets = {}
    self.Layouts = {}
    self.Tweens = {}
    self.ThemedDrawings = {}
    self.ComponentDrags = {}
    for i = #self.Drawings, 1, -1 do
        pcall(function() self.Drawings[i]:Remove() end)
        table.remove(self.Drawings, i)
    end
    pcall(function() Drawing.clear() end)
    self.Loaded = false
end

-- ============================================================
-- 20. SAVE / LOAD (JSON persistence)
-- ============================================================
local function getProfilePath(profileName)
    return "newvape/profiles/" .. (profileName or mainapi.Profile) .. ".json"
end

function mainapi:Save(newProfileName)
    local profile = newProfileName or self.Profile
    local data = {
        GUIColor = { Hue = self.GUIColor.Hue, Sat = self.GUIColor.Sat, Value = self.GUIColor.Value, Rainbow = self.GUIColor.Rainbow },
        Keybind = self.Keybind, Scale = self.Scale.Value, Modules = {},
    }
    for name, module in pairs(self.Modules) do
        local moduleData = { Enabled = module.Enabled, Bind = module.Bind, Options = {} }
        for _, opt in pairs(module.Options) do
            if opt.Save then opt:Save(moduleData.Options) end
        end
        data.Modules[name] = moduleData
    end
    local json = HttpService:JSONEncode(data)
    pcall(function() writefile(getProfilePath(profile), json) end)
end

function mainapi:Load(skipGui, profile)
    profile = profile or self.Profile
    local ok, content = pcall(function() return readfile(getProfilePath(profile)) end)
    if not ok or not content then return false end
    local ok2, data = pcall(function() return HttpService:JSONDecode(content) end)
    if not ok2 or type(data) ~= "table" then return false end

    if not skipGui then
        if data.GUIColor then
            self.GUIColor.Hue = data.GUIColor.Hue or self.GUIColor.Hue
            self.GUIColor.Sat = data.GUIColor.Sat or self.GUIColor.Sat
            self.GUIColor.Value = data.GUIColor.Value or self.GUIColor.Value
            self.GUIColor.Rainbow = data.GUIColor.Rainbow or false
        end
        if data.Keybind then self.Keybind = data.Keybind end
        if data.Scale then self.Scale.Value = data.Scale end
    end

    if data.Modules then
        for name, moduleData in pairs(data.Modules) do
            local module = self.Modules[name]
            if module then
                if moduleData.Bind then module:SetBind(moduleData.Bind) end
                if moduleData.Enabled and not module.Enabled then module:Toggle(true) end
                if moduleData.Options then
                    for optName, optData in pairs(moduleData.Options) do
                        local opt = module.Options[optName]
                        if opt and opt.Load then pcall(opt.Load, opt, optData) end
                    end
                end
            end
        end
    end
    return true
end

function mainapi:SaveOptions(object, savedOptions)
    for _, opt in pairs(object.Options or {}) do if opt.Save then opt:Save(savedOptions) end end
end

function mainapi:LoadOptions(object, savedOptions)
    for name, opt in pairs(object.Options or {}) do
        if opt.Load and savedOptions[name] then pcall(opt.Load, opt, savedOptions[name]) end
    end
end

-- ============================================================
-- 20b. SETTINGS MENU (built-in)
-- ============================================================
-- Creates a "Settings" category (with the uploaded gear icon) exposing the
-- core GUI options: accent color, rainbow, menu keybind, notifications, and
-- config save/load/reset. Reuses the standard component factories so it
-- behaves exactly like a user-defined category.
function mainapi:CreateSettings()
    if self.Categories["Settings"] then return self.Categories["Settings"] end

    local settings = self:CreateCategory({ Name = "Settings", Icon = Assets.Settings })

    -- ---- Interface module ----
    local interface = settings:CreateModule({ Name = "Interface", Tooltip = "Customize the menu" })

    interface:CreateColorSlider({
        Name = "GUI Color",
        Default = Color3.fromHSV(self.GUIColor.Hue, self.GUIColor.Sat, self.GUIColor.Value),
        Function = function(c)
            local h, s, v = c:ToHSV()
            self.GUIColor.Hue, self.GUIColor.Sat, self.GUIColor.Value = h, s, v
            self:UpdateGUI(h, s, v)
        end,
    })

    interface:CreateToggle({
        Name = "Rainbow",
        Default = self.GUIColor.Rainbow,
        Function = function(on)
            self.GUIColor.Rainbow = on
            -- Refresh immediately so enabled-module backgrounds and the
            -- arraylist switch between solid accent and rainbow right away.
            self:UpdateGUI(self.GUIColor.Hue, self.GUIColor.Sat, self.GUIColor.Value)
        end,
    })

    local menuKey = interface:CreateKeybind({
        Name = "Menu Key",
        Default = (self.Keybind and self.Keybind[1]) or "RightShift",
    })
    -- Rebinding the menu key updates the global GUI toggle keybind.
    local origMenuSet = menuKey.Set
    function menuKey:Set(key, silent)
        origMenuSet(self, key, silent)
        mainapi.Keybind = (key and key ~= "") and { key } or {}
    end

    interface:CreateToggle({
        Name = "Notifications",
        Default = self.Notifications.Enabled,
        Function = function(on) self.Notifications.Enabled = on end,
    })

    -- ---- Text GUI module ----
    local textgui = settings:CreateModule({ Name = "Text GUI", Tooltip = "Arraylist of enabled modules" })

    textgui:CreateToggle({
        Name = "Enabled",
        Default = self.TextGUI.Enabled,
        Function = function(on)
            self.TextGUI.Enabled = on
            self:_renderArraylist()
        end,
    })

    textgui:CreateDropdown({
        Name = "Sort",
        List = { "Alphabetical", "Length", "Reverse Length" },
        Default = self.TextGUI.Sort,
        Function = function(v)
            self.TextGUI.Sort = v
            self:_renderArraylist()
        end,
    })

    textgui:CreateToggle({
        Name = "Background",
        Default = self.TextGUI.Background,
        Function = function(on)
            self.TextGUI.Background = on
            self:_renderArraylist()
        end,
    })

    textgui:CreateTextBox({
        Name = "Add custom text",
        Placeholder = "Click to set (comma separated)",
        Default = "",
        Function = function(text)
            self.CustomText = {}
            for piece in tostring(text):gmatch("[^,]+") do
                local trimmed = piece:match("^%s*(.-)%s*$")
                if trimmed and trimmed ~= "" then
                    table.insert(self.CustomText, trimmed)
                end
            end
            self:_renderArraylist()
        end,
    })

    -- ---- Config module ----
    local config = settings:CreateModule({ Name = "Config", Tooltip = "Save / load your setup" })

    config:CreateButton({
        Name = "Save Config",
        Function = function()
            self:Save()
            self:CreateNotification("Config", "Configuration saved.", 3, "info")
        end,
    })
    config:CreateButton({
        Name = "Load Config",
        Function = function()
            local ok = self:Load()
            self:CreateNotification("Config", ok and "Configuration loaded." or "No saved config found.", 3, ok and "info" or "warning")
        end,
    })
    config:CreateButton({
        Name = "Reset Defaults",
        Function = function()
            self.GUIColor.Hue, self.GUIColor.Sat, self.GUIColor.Value = 0.46, 0.96, 0.52
            self.GUIColor.Rainbow = false
            self:UpdateGUI(self.GUIColor.Hue, self.GUIColor.Sat, self.GUIColor.Value)
            self:CreateNotification("Config", "Reset to defaults.", 3, "warning")
        end,
    })

    return settings
end

-- ============================================================
-- 21. STARTUP
-- ============================================================
mainapi.Loaded = true
startRenderLoop()
mainapi:CreateGUI()
mainapi:CreateArraylist()
mainapi:CreateSettings()
mainapi:_renderArraylist()

return mainapi
