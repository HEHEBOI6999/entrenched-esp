--[[
    Minimal ESP  (ENTRENCHED)
    Standalone LocalScript. Run it once and you get:
      - Chams (Highlight) on every visible enemy, up to 28 at a time
      - A thin vertical HP bar on the left edge of every enemy on screen
    No menu, no keybind, no other features. Reload-safe (re-running replaces
    the previous instance cleanly).

    Derived from the multi-part hub's en_06_game.lua, en_07_world.lua and the
    chams/HP parts of en_11_visuals.lua. Only the pieces needed for these two
    things are kept.
]]

------------------------------------------------------------------------
-- Boot / teardown of any previous copy
------------------------------------------------------------------------
local G = getgenv and getgenv() or _G
if G and type(G.__MINIMAL_ESP_CLEANUP) == "function" then
    pcall(G.__MINIMAL_ESP_CLEANUP)
end

local Players     = game:GetService("Players")
local RunService  = game:GetService("RunService")
local Teams       = game:GetService("Teams")
local LP          = Players.LocalPlayer

-- ENTRENCHED only. Outside it nothing useful happens.
local PLACE_ID, GAME_ID = 3678761576, 1281592938
local inGame = (game.PlaceId == PLACE_ID) or (game.GameId == GAME_ID)
if not inGame then
    warn("[MinimalESP] Not running outside ENTRENCHED.")
end

------------------------------------------------------------------------
-- Game helpers (liveness + team rules, straight from en_06_game.lua)
------------------------------------------------------------------------
local selectionRef = Teams:FindFirstChild("SelectionTeam")

local function humanoid(char)
    return char and char:FindFirstChildOfClass("Humanoid")
end

local function isEnemy(p)
    if p == LP or not p.Team or not LP.Team then return false end
    if selectionRef and selectionRef:IsA("ObjectValue") and p.Team == selectionRef.Value then return false end
    if p.Team.Name == "Selection" then return false end
    return p.Team ~= LP.Team
end

local function isDowned(char)
    return char ~= nil and char:FindFirstChild("ReviveTime") ~= nil
end

local function isAlive(char)
    local h = humanoid(char)
    if not h or h.Health <= 0 then return false end
    local ok, st = pcall(h.GetState, h)
    if ok and st == Enum.HumanoidStateType.Dead then return false end
    if char:FindFirstChild("RespawnDelay") then return false end
    return true
end

local spawnBase
local function inLobby(char)
    if not spawnBase or not spawnBase.Parent then
        local sb = workspace:FindFirstChild("Spawnbox")
        spawnBase = sb and sb:FindFirstChild("Base")
    end
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not (spawnBase and root) then return false end
    return (root.Position - spawnBase.Position).Magnitude < 250
end

------------------------------------------------------------------------
-- Sight-line raycast (same filter the game's server uses for bullets)
------------------------------------------------------------------------
local params = RaycastParams.new()
params.CollisionGroup = "Projectiles"
params.IgnoreWater = true
params.FilterType = Enum.RaycastFilterType.Exclude
local lastFilterChar, lastCosmetic

local function refreshFilter()
    local char = LP.Character
    local cosmetic = workspace:FindFirstChild("CosmeticProjectiles")
    if char ~= lastFilterChar or cosmetic ~= lastCosmetic then
        local f = { char }
        if cosmetic then f[#f + 1] = cosmetic end
        params.FilterDescendantsInstances = f
        lastFilterChar, lastCosmetic = char, cosmetic
    end
end

local function sightline(origin, part, char)
    if not part then return false end
    local dir = part.Position - origin
    local hit = workspace:Raycast(origin, dir, params)
    return hit == nil or hit.Instance:IsDescendantOf(char)
end

------------------------------------------------------------------------
-- Colours
------------------------------------------------------------------------
local C_GOOD = Color3.fromRGB(86, 214, 140)   -- visible enemy
local C_BAD  = Color3.fromRGB(242, 96, 98)    -- behind something
local C_MUTE = Color3.fromRGB(98, 98, 112)    -- downed

local function stateColor(e)
    if e.downed  then return C_MUTE end
    if e.visible then return C_GOOD end
    return C_BAD
end

-- Health colour: red -> warn -> green as HP goes 0 -> 1
local function healthColor(frac)
    local warn = Color3.fromRGB(250, 196, 84)
    if frac >= 0.5 then
        return warn:Lerp(C_GOOD, (frac - 0.5) * 2)
    end
    return C_BAD:Lerp(warn, frac * 2)
end

------------------------------------------------------------------------
-- Screen + Highlight pool (max 31 in Roblox, cap at 28 like the hub)
------------------------------------------------------------------------
local screen = Instance.new("ScreenGui")
screen.Name = "MinimalESP"
screen.ResetOnSpawn = false
screen.IgnoreGuiInset = true
screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

local host = (gethui and gethui())
    or (function()
        local ok, cg = pcall(function() return game:GetService("CoreGui") end)
        if ok and cg then return cg end
        return LP:WaitForChild("PlayerGui")
    end)()
screen.Parent = host

-- keep the screen alive through map changes / respawns
screen.AncestryChanged:Connect(function()
    if screen.Parent or not screen.Parent then return end
    task.defer(function()
        if screen.Parent == nil then
            pcall(function() screen.Parent = host end)
        end
    end)
end)

local CHAM_MAX = 28
local chamFolder = Instance.new("Folder")
chamFolder.Name = "Chams"
chamFolder.Parent = screen

local chamSlots = {}
for i = 1, CHAM_MAX do
    local hl = Instance.new("Highlight")
    hl.Name = "Cham" .. i
    hl.Enabled = false
    hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    hl.FillTransparency = 0.72
    hl.OutlineTransparency = 0.15
    hl.FillColor = C_BAD
    hl.OutlineColor = C_BAD
    hl.Parent = chamFolder
    chamSlots[i] = { hl = hl, char = nil, entry = nil }
end

------------------------------------------------------------------------
-- Per-player HP bar tag. Created once per player, reused every frame.
------------------------------------------------------------------------
local tags = {}  -- Player -> { holder, fill, stamp, char }

local function makeTag(player)
    local holder = Instance.new("Frame")
    holder.Name = "HpBar_" .. player.Name
    holder.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    holder.BackgroundTransparency = 0.45
    holder.BorderSizePixel = 0
    holder.Visible = false
    holder.ZIndex = 3
    holder.Parent = screen

    local fill = Instance.new("Frame")
    fill.Name = "Fill"
    fill.BackgroundColor3 = C_GOOD
    fill.BorderSizePixel = 0
    fill.AnchorPoint = Vector2.new(0, 1)  -- grows upward from the bottom
    fill.Position = UDim2.new(0, 1, 1, -1)
    fill.Size = UDim2.fromOffset(3, 0)
    fill.ZIndex = 4
    fill.Parent = holder

    tags[player] = { player = player, holder = holder, fill = fill, stamp = -1, char = nil }
    return tags[player]
end

local function destroyTag(player)
    local tag = tags[player]
    if not tag then return end
    tags[player] = nil
    pcall(function() tag.holder:Destroy() end)
end

Players.PlayerRemoving:Connect(function(p) destroyTag(p) end)

------------------------------------------------------------------------
-- Reusable scratch tables (no per-frame allocations)
------------------------------------------------------------------------
local list = {}
local candidates = {}
local wanted = {}

------------------------------------------------------------------------
-- Main render loop
------------------------------------------------------------------------
local BIND_NAME = "MinimalESP"
RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Last.Value, function()
    if not inGame then return end

    local cam = workspace.CurrentCamera
    if not cam then return end
    local camPos = cam.CFrame.Position
    local vp = cam.ViewportSize
    refreshFilter()

    --------------------------------------------------------------------
    -- 1) Snapshot of valid enemies this frame
    --------------------------------------------------------------------
    table.clear(list)
    for _, p in ipairs(Players:GetPlayers()) do
        if isEnemy(p) then
            local char = p.Character
            local root = char and char:FindFirstChild("HumanoidRootPart")
            local head = char and char:FindFirstChild("Head")
            local hum  = humanoid(char)
            if root and head and hum and isAlive(char) and not inLobby(char) then
                local torso = char:FindFirstChild("UpperTorso") or root
                local visHead  = sightline(camPos, head, char)
                local visTorso = sightline(camPos, torso, char)
                list[#list + 1] = {
                    player = p, char = char, root = root, head = head, hum = hum,
                    torso = torso,
                    downed = isDowned(char),
                    health = hum.Health,
                    maxHealth = math.max(hum.MaxHealth, 1),
                    dist = (root.Position - camPos).Magnitude,
                    visible = visHead or visTorso,
                }
            end
        end
    end

    -- nearest first so the closest 28 enemies keep their chams
    table.sort(list, function(a, b) return a.dist < b.dist end)

    --------------------------------------------------------------------
    -- 2) Chams assignment
    --------------------------------------------------------------------
    table.clear(candidates)
    for _, e in ipairs(list) do
        if e.dist <= 3000 then candidates[#candidates + 1] = e end
    end

    table.clear(wanted)
    local n = math.min(#candidates, CHAM_MAX)
    for i = 1, n do wanted[candidates[i].char] = candidates[i] end

    -- keep slots that already hold the right character (avoids flicker)
    for _, s in ipairs(chamSlots) do
        if s.char and wanted[s.char] then
            s.entry = wanted[s.char]
            wanted[s.char] = nil
        else
            s.entry, s.char = nil, nil
        end
    end
    -- assign the rest into free slots
    local cursor = 1
    for i = 1, n do
        local e = candidates[i]
        if wanted[e.char] then
            wanted[e.char] = nil
            while chamSlots[cursor] and chamSlots[cursor].char do cursor = cursor + 1 end
            local s = chamSlots[cursor]
            if not s then break end
            s.char, s.entry = e.char, e
        end
    end

    -- paint / clear chams
    for _, s in ipairs(chamSlots) do
        if s.entry then
            local col = stateColor(s.entry)
            s.hl.FillColor = col
            s.hl.OutlineColor = col
            s.hl.Adornee = s.char
            s.hl.Enabled = true
        else
            s.hl.Enabled = false
            s.hl.Adornee = nil
        end
    end

    --------------------------------------------------------------------
    -- 3) HP bars (projected on screen, anchored to the left of the body)
    --------------------------------------------------------------------
    local PAD = 3
    local DROP = Vector3.new(0, 3, 0)  -- foot fallback if needed
    local stamp = os.clock()

    for _, e in ipairs(list) do
        local tag = tags[e.player] or makeTag(e.player)
        tag.stamp = stamp
        tag.char = e.char

        -- vertical hull of the body: top of head to below the root
        local top = cam:WorldToViewportPoint(e.head.Position + Vector3.new(0, e.head.Size.Y * 0.6, 0))
        local bot = cam:WorldToViewportPoint(e.root.Position - DROP)

        if top.Z > 0 and bot.Z > 0 then
            local x0 = math.min(top.X, bot.X) - PAD
            local y0 = math.min(top.Y, bot.Y) - PAD
            local y1 = math.max(top.Y, bot.Y) + PAD
            local h  = math.max(y1 - y0, 1)

            local frac = math.clamp(e.health / e.maxHealth, 0, 1)
            local q    = math.floor(frac * 100 + 0.5)

            tag.holder.Position = UDim2.fromOffset(math.floor(x0 - 10), math.floor(y0 - 1))
            tag.holder.Size     = UDim2.fromOffset(5, math.floor(h + 2))
            tag.fill.Size       = UDim2.fromOffset(3, math.floor(h * q / 100 + 0.5))
            tag.fill.BackgroundColor3 = healthColor(q / 100)
            tag.holder.Visible  = true
        else
            tag.holder.Visible = false
        end
    end

    -- hide bars for enemies that dropped out of the snapshot this frame
    for player, tag in pairs(tags) do
        if tag.stamp ~= stamp then
            tag.holder.Visible = false
        end
        if player.Parent == nil then destroyTag(player) end
    end
end)

------------------------------------------------------------------------
-- Cleanup
------------------------------------------------------------------------
local function cleanup()
    pcall(function() RunService:UnbindFromRenderStep(BIND_NAME) end)
    pcall(function() screen:Destroy() end)
    for k in pairs(tags) do tags[k] = nil end
    if G and G.__MINIMAL_ESP_CLEANUP == cleanup then
        G.__MINIMAL_ESP_CLEANUP = nil
    end
end
if G then G.__MINIMAL_ESP_CLEANUP = cleanup end

print("[MinimalESP] loaded. Chams + HP bar for enemies only. Re-running replaces the previous copy.")
