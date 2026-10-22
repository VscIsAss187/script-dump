--=====================================================================
-- SPIELEVENT PIZZA AUTOFARM + ADDRESS FINDER   (hash-index build)
--=====================================================================
-- Index root: Workspace/Map/Adressen  (auto-detected, case-insensitive)
-- Attribute keys are CLASSIFIED by keyword, not exact name, so it works
-- whether they are Straße/Nr/Ort/Typ or street/number/city/type or one
-- single combined "Adresse" field.
-- Coordinates come from the Adresse part's own CFrame property.
--
-- Finder tab:  Suchen · Keys (diagnose) · Test · Index · Dex
-- Toggle GUI : RightShift      Start/Stop : RightControl
--=====================================================================

local Players = game:GetService("Players")
local RS      = game:GetService("ReplicatedStorage")
local UIS     = game:GetService("UserInputService")

local LP = Players.LocalPlayer
local PG = LP:WaitForChild("PlayerGui")

local CONFIG = {
    ToggleKey   = Enum.KeyCode.RightShift,
    FarmKey     = Enum.KeyCode.RightControl,
    AutoShow    = true,
    MaxResults  = 25,
    Mark        = true,
    TpYOffset   = 3,
    KeepRotation = true,
    RootCandidates = { "workspace.Map.Adressen", "workspace.Map.Adressen2" },
    IndexTTL    = 60,      -- seconds before a rebuild is allowed
    NameFilter  = { "adresse" },
    RemotePath  = "ReplicatedStorage.Spiel",
    OnlySpielEvent = false,
}

local CONFIRM_WORDS = {
    "geliefert", "delivered", "zugestellt", "abgeliefert", "abgegeben",
    "trinkgeld", "verdient", "erhalten", "pizza delivered", "tip",
}

--=====================================================================
-- BASIC HELPERS
--=====================================================================
local L = "[%aäöüÄÖÜ]"

local function norm(s, stripDigits)
    if s == nil then return "" end
    s = tostring(s):lower()
    s = s:gsub("ß", "ss"):gsub("ä", "ae"):gsub("ö", "oe"):gsub("ü", "ue")
    s = s:gsub("[^%w]", "")
    if stripDigits then s = s:gsub("%d", "") end
    return s
end

local function resolvePath(path)
    local node = game
    for part in tostring(path):gmatch("[^%.]+") do
        node = node:FindFirstChild(part)
        if not node then return nil end
    end
    return node
end

local function findEvent()
    local f = RS:FindFirstChild("Spiel")
    if f then local e = f:FindFirstChild("SpielEvent"); if e then return e end end
    for _, d in ipairs(RS:GetDescendants()) do
        if d:IsA("RemoteEvent") and d.Name == "SpielEvent" then return d end
    end
end
local Event = findEvent()

local function similar(a, b)
    if a == "" or b == "" then return 0 end
    local n, i = math.min(#a, #b), 1
    while i <= n and a:sub(i, i) == b:sub(i, i) do i += 1 end
    return (i - 1) / math.max(#a, #b)
end

--=====================================================================
-- ROOT DETECTION  (Workspace/Map/Adressen, case-insensitive + search)
--=====================================================================
local ActiveRoot, ActiveRootPath = nil, ""

local function findChildCI(parent, name)
    if not parent then return nil end
    local n = name:lower()
    for _, c in ipairs(parent:GetChildren()) do
        if c.Name:lower() == n then return c end
    end
    return nil
end

local function detectRoot()
    for _, p in ipairs(CONFIG.RootCandidates) do
        local r = resolvePath(p)
        if r and #r:GetChildren() > 0 then
            ActiveRoot, ActiveRootPath = r, p
            return r, p
        end
    end
    -- case-insensitive / search fallback
    local map = findChildCI(workspace, "Map")
    if map then
        local adr = findChildCI(map, "Adressen") or findChildCI(map, "Adressen2")
        if not adr then
            for _, c in ipairs(map:GetChildren()) do
                if c.Name:lower():find("adress", 1, true) then adr = c; break end
            end
        end
        if adr then
            ActiveRoot, ActiveRootPath = adr, "workspace.Map." .. adr.Name
            return ActiveRoot, ActiveRootPath
        end
    end
    ActiveRoot, ActiveRootPath = workspace, "workspace"
    return ActiveRoot, ActiveRootPath
end
detectRoot()

--=====================================================================
-- POSITION  (part CFrame first)
--=====================================================================
local function toVector(v, depth)
    depth = depth or 0
    if v == nil or depth > 3 then return nil end
    local t = typeof(v)
    if t == "CFrame" then return v.Position end
    if t == "Vector3" then return v end
    if t == "table" then
        local inner = toVector(v.Position or v.position or v.pos, depth + 1)
        if inner then return inner end
        local x, y, z = v.X or v.x or v[1], v.Y or v.y or v[2], v.Z or v.z or v[3]
        if type(x) == "number" and type(y) == "number" and type(z) == "number" then
            return Vector3.new(x, y, z)
        end
    end
    if t == "string" then
        local x, y, z = v:match("(-?%d+%.?%d*)[,;%s]+(-?%d+%.?%d*)[,;%s]+(-?%d+%.?%d*)")
        if x then return Vector3.new(tonumber(x), tonumber(y), tonumber(z)) end
    end
end

local function childCFrame(obj)
    if obj:IsA("BasePart") then return obj.CFrame end
    if obj:IsA("Model") then
        local ok, pivot = pcall(function() return obj:GetPivot() end)
        if ok then return pivot end
    end
    for _, c in ipairs(obj:GetChildren()) do
        if c:IsA("BasePart") then return c.CFrame end
    end
    for _, c in ipairs(obj:GetDescendants()) do
        if c:IsA("BasePart") then return c.CFrame end
    end
end

local function readPosition(obj)
    local ok, attrs = pcall(function() return obj:GetAttributes() end)
    if ok and attrs and attrs.CFrame ~= nil then
        local pos = toVector(attrs.CFrame)
        if pos then return pos, (typeof(attrs.CFrame) == "CFrame" and attrs.CFrame or nil) end
    end
    local cf = childCFrame(obj)
    if cf then return cf.Position, cf end
    if ok and attrs and attrs.Position ~= nil then
        local pos = toVector(attrs.Position)
        if pos then return pos, nil end
    end
    return nil, nil
end

local function parseMoney(text)
    local n = text:match("%$%s*([%d]+%.?%d*)") or text:match("([%d]+%.?%d*)%s*%$")
        or text:match("[Tt]rinkgeld[:%s]*([%d]+%.?%d*)")
    return tonumber(n)
end

--=====================================================================
-- ADDRESS PARSER (street optional-number, city)
--=====================================================================
local SUFFIXES = { "strasse", "str", "weg", "gasse", "platz", "allee", "ring", "chaussee", "damm", "ufer", "berg" }

local function parseAddress(text)
    if type(text) ~= "string" or #text < 4 then return nil end
    local t = text:gsub("ß", "ss")
    for _, suf in ipairs(SUFFIXES) do
        local street, num = t:match("(" .. L .. "+" .. suf .. "%.?)%s*(%d+%s*" .. L .. "?)")
        if street then
            local city = t:match("%d%s*" .. L .. "?%s*,%s*(" .. L .. "+)")
            return { street = street, number = num and num:match("%d+") or nil, city = city, raw = text }
        end
    end
    -- street only (number may arrive in another argument)
    local street = t:match("(" .. L .. "+strasse)") or t:match("(" .. L .. "+weg)")
    if street then return { street = street, number = nil, city = nil, raw = text } end
    return nil
end

local function addrLabel(a)
    return a.street .. (a.number and (" " .. tostring(a.number)) or "") .. (a.city and (", " .. a.city) or "")
end

--=====================================================================
-- FINDER  ·  hash index with keyword-based key classification
--=====================================================================
local Finder = {
    entries = {}, byKey = {}, byStreet = {}, byNum = {},
    stamp = 0, built = 0, withAttrs = 0, keyHist = {},
}

local KEYWORDS = {
    number = { "hausnr", "hausnummer", "nummer", "number", "nr", "no" },
    street = { "straße", "strasse", "street", "strase", "str.", "weg", "gasse", "platz", "allee", "ring" },
    city   = { "stadt", "ort", "city", "town", "gemeinde" },
    type   = { "typ", "type", "art", "kategorie", "kind" },
    index  = { "index", "id", "key" },
}

local function classifyKey(k)
    local lk = k:lower()
    for field, words in pairs(KEYWORDS) do
        for _, w in ipairs(words) do
            if lk:find(w, 1, true) then return field end
        end
    end
    return nil
end

local function nameAllowed(name)
    if #CONFIG.NameFilter == 0 then return true end
    local n = name:lower()
    for _, f in ipairs(CONFIG.NameFilter) do
        if n:find(f, 1, true) then return true end
    end
    return false
end

local function buildEntry(obj)
    local ok, attrs = pcall(function() return obj:GetAttributes() end)
    attrs = (ok and attrs) or {}
    local e = { obj = obj, attrs = attrs, street = nil, number = nil, city = nil, type = nil, index = nil }

    for k, v in pairs(attrs) do
        local cls = classifyKey(k)
        if cls and e[cls] == nil then
            if type(v) == "number" and cls == "street" then e.number = e.number or tostring(v)
            else e[cls] = tostring(v) end
        end
    end

    -- single combined field ("Nibelungenstraße 9")
    if e.street and not e.number then
        local s, n = e.street:match("^(.-)%s*(%d+%s*" .. L .. "?)$")
        if n then e.street, e.number = s, n end
    end

    -- scan values for a street pattern if still nothing
    if not e.street then
        for k, v in pairs(attrs) do
            if type(v) == "string" then
                local st, nu = v:match("(" .. L .. "+strasse)%s*(%d*%s*" .. L .. "?)")
                    or v:match("(" .. L .. "+weg)%s*(%d*)")
                if st then e.street, e.number = st, (nu ~= "" and nu or nil); break end
            end
        end
    end

    -- name / StringValue child fallback
    if not e.street and obj.Name:lower() ~= "adresse" then
        local st, nu = obj.Name:match("(" .. L .. "+strasse)%s*(%d*)") or obj.Name:match("(" .. L .. "+weg)%s*(%d*)")
        if st then e.street, e.number = st, (nu ~= "" and nu or nil) end
    end
    if not e.street then
        for _, c in ipairs(obj:GetChildren()) do
            if c:IsA("StringValue") or c:IsA("ObjectValue") then
                local val = c:IsA("StringValue") and c.Value or (c.Value and c.Value.Name or "")
                local st, nu = tostring(val):match("(" .. L .. "+strasse)%s*(%d*)")
                if st then e.street, e.number = st, (nu ~= "" and nu or nil) end
            end
        end
    end

    for k in pairs(attrs) do Finder.keyHist[k] = (Finder.keyHist[k] or 0) + 1 end
    return e
end

local function push(list, e)
    list[#list + 1] = e
end

function Finder.rebuild()
    if not ActiveRoot or not ActiveRoot.Parent then detectRoot() end
    Finder.entries, Finder.byKey, Finder.byStreet, Finder.byNum, Finder.keyHist = {}, {}, {}, {}, {}
    Finder.built, Finder.withAttrs = 0, 0

    local i = 0
    for _, obj in ipairs(ActiveRoot:GetDescendants()) do
        if obj:IsA("Terrain") then continue end
        if nameAllowed(obj.Name) then
            local e = buildEntry(obj)
            if e.street then
                i += 1
                push(Finder.entries, e)
                local ns, nn = norm(e.street, true), norm(e.number)
                if ns ~= "" then
                    if nn ~= "" and not Finder.byKey[ns .. "#" .. nn] then Finder.byKey[ns .. "#" .. nn] = e end
                    local bs = Finder.byStreet[ns]; if not bs then bs = {}; Finder.byStreet[ns] = bs end
                    push(bs, e)
                end
                if nn ~= "" then
                    local bn = Finder.byNum[nn]; if not bn then bn = {}; Finder.byNum[nn] = bn end
                    push(bn, e)
                end
            end
            if next(e.attrs) then Finder.withAttrs += 1 end
            Finder.built += 1
        end
        if i % 400 == 0 then task.wait() end
    end
    Finder.stamp = os.clock()
    return #Finder.entries
end

local function ensureIndex(force)
    if force or #Finder.entries == 0 or (os.clock() - Finder.stamp) > CONFIG.IndexTTL then
        return Finder.rebuild()
    end
    return #Finder.entries
end

-- ranked candidates for an address
function Finder.candidates(addr, limit)
    ensureIndex()
    limit = limit or CONFIG.MaxResults
    local ns, nn, nc = norm(addr.street, true), norm(addr.number), norm(addr.city, true)
    local out, seen = {}, {}

    local function add(e, how, score)
        if e and not seen[e] then
            seen[e] = true
            out[#out + 1] = { entry = e, obj = e.obj, how = how, score = score,
                street = e.street, num = e.number, city = e.city, type = e.type, index = e.index }
        end
    end

    if nn ~= "" then add(Finder.byKey[ns .. "#" .. nn], "exact", 100) end
    if nn == "" and #out == 0 then
        for _, e in ipairs(Finder.byStreet[ns] or {}) do add(e, "street", 90) end
    end
    if #out == 0 then
        for k, list in pairs(Finder.byStreet) do
            if k == ns or k:find(ns, 1, true) or ns:find(k, 1, true) then
                for _, e in ipairs(list) do
                    if nn == "" or norm(e.number) == nn then add(e, "prefix", 80) end
                end
            end
        end
    end
    if #out == 0 and nn ~= "" then
        for _, e in ipairs(Finder.byNum[nn] or {}) do
            local es = norm(e.street, true)
            if es == ns or es:find(ns, 1, true) or ns:find(es, 1, true) then add(e, "bynum", 70) end
        end
    end
    if #out == 0 then -- fuzzy
        local best, bestScore = nil, 0
        for k, list in pairs(Finder.byStreet) do
            local s = similar(k, ns)
            if s > bestScore then best, bestScore = list, s end
        end
        if best and bestScore >= 0.72 then
            for _, e in ipairs(best) do
                if nn == "" or norm(e.number) == nn then add(e, string.format("fuzzy %.0f%%", bestScore * 100), 60) end
            end
        end
    end

    if nc ~= "" then
        for _, r in ipairs(out) do
            if norm(r.city, true) == nc then r.score += 10 end
        end
    end
    table.sort(out, function(a, b) return a.score > b.score end)
    while #out > limit do table.remove(out) end
    return out
end

local LastResolved = nil

function Finder.resolve(addr, tries)
    tries = tries or 2
    for i = 1, tries do
        local list = Finder.candidates(addr)
        if #list > 0 then
            local hit = list[1]
            local pos, cf = readPosition(hit.obj)
            if not pos and hit.obj.Parent then pos, cf = readPosition(hit.obj.Parent) end
            if pos then
                LastResolved = { addr = addr, obj = hit.obj, pos = pos, cf = cf, list = list, how = hit.how }
                return LastResolved
            end
        end
        if i < tries then Finder.rebuild(); task.wait(0.1) end
    end
    return nil
end

--=====================================================================
-- MARK / TELEPORT / COPY / DEX
--=====================================================================
local marks = {}
local function clearMarks()
    for _, m in ipairs(marks) do pcall(function() m:Destroy() end) end
    marks = {}
end

local function mark(obj)
    clearMarks()
    local h = Instance.new("Highlight")
    h.Name = "AddressFinderMark"
    h.Adornee = obj
    h.FillColor = Color3.fromRGB(63, 163, 77)
    h.FillTransparency = 0.5
    h.OutlineColor = Color3.fromRGB(120, 255, 140)
    h.Parent = workspace
    marks[#marks + 1] = h
end

local function tpToPosition(pos, cf)
    local char = LP.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp or not pos then return end
    local offset = Vector3.new(0, CONFIG.TpYOffset, 0)
    if CONFIG.KeepRotation and cf then hrp.CFrame = cf + offset
    else hrp.CFrame = CFrame.new(pos + offset) end
end

local function tpToResolved(res) if res then tpToPosition(res.pos, res.cf) end end

local function copyCoords(obj)
    local pos = readPosition(obj)
    if not pos then return nil end
    local s = string.format("%.3f, %.3f, %.3f", pos.X, pos.Y, pos.Z)
    if typeof(setclipboard) == "function" then pcall(setclipboard, s) end
    return s
end

local function pushToDex(term)
    local env = (typeof(getgenv) == "function" and getgenv()) or _G
    local Dex = env and env.Dex
    if Dex then
        if type(Dex.SetSearchTerm) == "function" then pcall(Dex.SetSearchTerm, term) end
        if type(Dex.SetSetting) == "function" then pcall(Dex.SetSetting, "Search", term) end
    end
    local dexGui = game:GetService("CoreGui"):FindFirstChild("Dex")
    if dexGui then
        for _, d in ipairs(dexGui:GetDescendants()) do
            if d:IsA("TextBox") and (d.Name:lower():find("search") or (d.PlaceholderText or ""):lower():find("search")) then
                d.Text = term; pcall(function() d:CaptureFocus(); d:ReleaseFocus() end); break
            end
        end
    end
end

--=====================================================================
-- GUI
--=====================================================================
local function mk(class, props, parent)
    local o = Instance.new(class)
    for k, v in pairs(props) do o[k] = v end
    o.Parent = parent
    return o
end

local COL = {
    bg = Color3.fromRGB(24, 24, 24), bar = Color3.fromRGB(34, 34, 34),
    row = Color3.fromRGB(37, 37, 37), rowAlt = Color3.fromRGB(43, 43, 43),
    text = Color3.fromRGB(226, 226, 226), dim = Color3.fromRGB(150, 150, 150),
    green = Color3.fromRGB(63, 163, 77), accent = Color3.fromRGB(90, 170, 255),
    yellow = Color3.fromRGB(240, 200, 120), red = Color3.fromRGB(230, 110, 110),
}

local gui = mk("ScreenGui", {
    Name = "SpielEventFarm", ResetOnSpawn = false,
    IgnoreGuiInset = true, ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
}, PG)

local main = mk("Frame", {
    Name = "Main", Size = UDim2.new(0, 470, 0, 410), Position = UDim2.new(0.5, 0, 0, 60),
    AnchorPoint = Vector2.new(0.5, 0), BackgroundColor3 = COL.bg, BorderSizePixel = 0, Visible = false,
}, gui)
mk("UICorner", { CornerRadius = UDim.new(0, 8) }, main)
mk("UIStroke", { Color = Color3.fromRGB(60, 60, 60), Thickness = 1 }, main)

local bar = mk("Frame", { Size = UDim2.new(1, 0, 0, 28), BackgroundColor3 = COL.bar, BorderSizePixel = 0 }, main)
mk("UICorner", { CornerRadius = UDim.new(0, 8) }, bar)
mk("TextLabel", {
    Size = UDim2.new(1, -140, 1, 0), Position = UDim2.new(0, 10, 0, 0), BackgroundTransparency = 1,
    Font = Enum.Font.Code, TextSize = 13, TextColor3 = COL.text,
    TextXAlignment = Enum.TextXAlignment.Left, Text = "Pizza Autofarm  ·  Address Finder",
}, bar)
local statePill = mk("TextLabel", {
    Size = UDim2.new(0, 92, 1, 0), Position = UDim2.new(1, -120, 0, 0), BackgroundTransparency = 1,
    Font = Enum.Font.Code, TextSize = 11, TextColor3 = COL.dim,
    TextXAlignment = Enum.TextXAlignment.Right, Text = "[idle]",
}, bar)
local closeBtn = mk("TextButton", {
    Size = UDim2.new(0, 24, 0, 22), Position = UDim2.new(1, -28, 0, 3),
    BackgroundColor3 = Color3.fromRGB(60, 60, 60), Text = "×", Font = Enum.Font.Code,
    TextSize = 16, TextColor3 = COL.text, BorderSizePixel = 0,
}, bar)
mk("UICorner", { CornerRadius = UDim.new(0, 6) }, closeBtn)

local tabBar = mk("Frame", { Size = UDim2.new(1, -12, 0, 24), Position = UDim2.new(0, 6, 0, 32), BackgroundTransparency = 1 }, main)
local function mkTab(text, x, w)
    local b = mk("TextButton", {
        Size = UDim2.new(0, w, 1, 0), Position = UDim2.new(0, x, 0, 0),
        BackgroundColor3 = COL.row, BorderSizePixel = 0, Font = Enum.Font.Code,
        TextSize = 12, TextColor3 = COL.text, Text = text,
    }, tabBar)
    mk("UICorner", { CornerRadius = UDim.new(0, 5) }, b)
    return b
end
local farmTab   = mkTab("Farm", 0, 70)
local finderTab = mkTab("Finder", 76, 70)

local farmPage   = mk("Frame", { Size = UDim2.new(1, -12, 1, -66), Position = UDim2.new(0, 6, 0, 60), BackgroundTransparency = 1 }, main)
local finderPage = mk("Frame", { Size = UDim2.new(1, -12, 1, -66), Position = UDim2.new(0, 6, 0, 60), BackgroundTransparency = 1, Visible = false }, main)

local function setTab(which)
    farmPage.Visible = (which == "farm")
    finderPage.Visible = not farmPage.Visible
    farmTab.BackgroundColor3 = farmPage.Visible and COL.green or COL.row
    finderTab.BackgroundColor3 = farmPage.Visible and COL.row or COL.green
end
farmTab.MouseButton1Click:Connect(function() setTab("farm") end)
finderTab.MouseButton1Click:Connect(function() setTab("finder") end)
setTab("farm")

local function mkBtn(text, w, h, col, parent, x, y)
    local b = mk("TextButton", {
        Size = UDim2.new(0, w, 0, h), Position = UDim2.new(0, x, 0, y),
        BackgroundColor3 = col or COL.row, BorderSizePixel = 0, Font = Enum.Font.Code,
        TextSize = 11, TextColor3 = COL.text, Text = text,
    }, parent)
    mk("UICorner", { CornerRadius = UDim.new(0, 4) }, b)
    return b
end

--=====================================================================
-- TAB 1 · FARM
--=====================================================================
local Farm = {
    Running = false, State = "idle", Pending = nil, Confirmed = false,
    Deliveries = 0, Fails = 0, Money = 0, StartTime = 0,
    Pizza = Vector3.new(16, 141, -40),
    DelayPizza = 0.6, TimeoutAddress = 8, TimeoutDeliver = 12, LoopDelay = 0.4,
}

mk("TextLabel", {
    Size = UDim2.new(0, 70, 0, 20), Position = UDim2.new(0, 2, 0, 6), BackgroundTransparency = 1,
    Font = Enum.Font.Code, TextSize = 11, TextColor3 = COL.dim,
    TextXAlignment = Enum.TextXAlignment.Left, Text = "Pizza Ziel",
}, farmPage)

local function mkBox(x, y, w, text, parent)
    local b = mk("TextBox", {
        Size = UDim2.new(0, w, 0, 20), Position = UDim2.new(0, x, 0, y), BackgroundColor3 = COL.row,
        BorderSizePixel = 0, Font = Enum.Font.Code, TextSize = 11, TextColor3 = COL.text,
        ClearTextOnFocus = false, Text = text, TextXAlignment = Enum.TextXAlignment.Center,
    }, parent or farmPage)
    mk("UICorner", { CornerRadius = UDim.new(0, 4) }, b)
    return b
end

local px = mkBox(74, 6, 52, "16")
local py = mkBox(130, 6, 52, "141")
local pz = mkBox(186, 6, 52, "-40")
local hereBtn = mkBtn("hier", 46, 20, COL.row, farmPage, 242, 6)

local function readPizza()
    Farm.Pizza = Vector3.new(tonumber(px.Text) or 16, tonumber(py.Text) or 141, tonumber(pz.Text) or -40)
end
px.FocusLost:Connect(readPizza); py.FocusLost:Connect(readPizza); pz.FocusLost:Connect(readPizza)
hereBtn.MouseButton1Click:Connect(function()
    local hrp = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
    if not hrp then return end
    px.Text = string.format("%.0f", hrp.Position.X)
    py.Text = string.format("%.0f", hrp.Position.Y)
    pz.Text = string.format("%.0f", hrp.Position.Z)
    readPizza()
end)

local startBtn = mkBtn("▶ START", 110, 26, COL.green, farmPage, 2, 34)
startBtn.TextSize = 13
startBtn.TextColor3 = Color3.new(1, 1, 1)
local stopBtn = mkBtn("■ STOP", 70, 26, COL.row, farmPage, 116, 34)

local farmState = mk("TextLabel", {
    Size = UDim2.new(1, -200, 0, 26), Position = UDim2.new(0, 192, 0, 34), BackgroundTransparency = 1,
    Font = Enum.Font.Code, TextSize = 11, TextColor3 = COL.dim,
    TextXAlignment = Enum.TextXAlignment.Left, Text = "bereit", TextWrapped = true,
}, farmPage)

local statDeliveries = mk("TextLabel", {
    Size = UDim2.new(0, 110, 0, 16), Position = UDim2.new(0, 2, 0, 66), BackgroundTransparency = 1,
    Font = Enum.Font.Code, TextSize = 11, TextColor3 = COL.text, TextXAlignment = Enum.TextXAlignment.Left,
    Text = "Lieferungen: 0",
}, farmPage)
local statMoney = mk("TextLabel", {
    Size = UDim2.new(0, 110, 0, 16), Position = UDim2.new(0, 116, 0, 66), BackgroundTransparency = 1,
    Font = Enum.Font.Code, TextSize = 11, TextColor3 = COL.green, TextXAlignment = Enum.TextXAlignment.Left,
    Text = "Verdient: $0",
}, farmPage)
local statFails = mk("TextLabel", {
    Size = UDim2.new(0, 110, 0, 16), Position = UDim2.new(0, 230, 0, 66), BackgroundTransparency = 1,
    Font = Enum.Font.Code, TextSize = 11, TextColor3 = COL.red, TextXAlignment = Enum.TextXAlignment.Left,
    Text = "Fehler: 0",
}, farmPage)
local statTime = mk("TextLabel", {
    Size = UDim2.new(0, 110, 0, 16), Position = UDim2.new(0, 340, 0, 66), BackgroundTransparency = 1,
    Font = Enum.Font.Code, TextSize = 11, TextColor3 = COL.dim, TextXAlignment = Enum.TextXAlignment.Left,
    Text = "Laufzeit: 0s",
}, farmPage)

mk("TextLabel", {
    Size = UDim2.new(0, 330, 0, 14), Position = UDim2.new(0, 2, 0, 86), BackgroundTransparency = 1,
    Font = Enum.Font.Code, TextSize = 10, TextColor3 = COL.dim, TextXAlignment = Enum.TextXAlignment.Left,
    Text = "Pause@Pizza   Timeout Adresse   Timeout Lieferung   Loop-Pause",
}, farmPage)

local dPizza = mkBox(2, 100, 40, "0.6")
local dAddr  = mkBox(48, 100, 40, "8")
local dDeliv = mkBox(94, 100, 40, "12")
local dLoop  = mkBox(140, 100, 40, "0.4")
local function readTimings()
    Farm.DelayPizza     = tonumber(dPizza.Text) or 0.6
    Farm.TimeoutAddress = tonumber(dAddr.Text) or 8
    Farm.TimeoutDeliver = tonumber(dDeliv.Text) or 12
    Farm.LoopDelay      = tonumber(dLoop.Text) or 0.4
end
for _, b in ipairs({ dPizza, dAddr, dDeliv, dLoop }) do b.FocusLost:Connect(readTimings) end

local farmLog = mk("ScrollingFrame", {
    Size = UDim2.new(1, -4, 1, -124), Position = UDim2.new(0, 2, 0, 124),
    BackgroundColor3 = Color3.fromRGB(18, 18, 18), BorderSizePixel = 0, ScrollBarThickness = 4,
    CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y,
    ScrollBarImageColor3 = COL.dim,
}, farmPage)
mk("UICorner", { CornerRadius = UDim.new(0, 5) }, farmLog)
mk("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }, farmLog)

local function farmLine(text, col)
    mk("TextLabel", {
        Size = UDim2.new(1, -8, 0, 14), BackgroundTransparency = 1, Font = Enum.Font.Code,
        TextSize = 11, TextColor3 = col or COL.dim, TextXAlignment = Enum.TextXAlignment.Left,
        Text = os.date("%H:%M:%S ") .. text, LayoutOrder = #farmLog:GetChildren(),
        TextTruncate = Enum.TextTruncate.AtEnd,
    }, farmLog)
    farmLog.CanvasPosition = Vector2.new(0, 1e6)
end

local function refreshStats()
    statDeliveries.Text = "Lieferungen: " .. Farm.Deliveries
    statMoney.Text = string.format("Verdient: $%d", Farm.Money)
    statFails.Text = "Fehler: " .. Farm.Fails
    statePill.Text = Farm.Running and "[läuft]" or "[idle]"
    statePill.TextColor3 = Farm.Running and COL.green or COL.dim
end

local function setFarmState(s) Farm.State = s; farmState.Text = s end

--=====================================================================
-- FARM LOOP
--=====================================================================
local function stopFarm()
    if not Farm.Running then return end
    Farm.Running = false
    startBtn.Text = "▶ START"; startBtn.BackgroundColor3 = COL.green
    setFarmState("gestoppt"); farmLine("Farm gestoppt.", COL.yellow); refreshStats()
end

local function farmLoop()
    while Farm.Running do
        setFarmState(string.format("→ Pizza (%.0f,%.0f,%.0f)", Farm.Pizza.X, Farm.Pizza.Y, Farm.Pizza.Z))
        tpToPosition(Farm.Pizza, nil)
        task.wait(Farm.DelayPizza)
        if not Farm.Running then break end

        Farm.Pending, Farm.Confirmed = nil, false
        setFarmState("→ Job anfordern")
        if Event then pcall(function() Event:FireServer("job", "pizza") end)
        else farmLine("SpielEvent nicht gefunden!", COL.red) end

        local t0 = os.clock()
        while Farm.Running and not Farm.Pending and (os.clock() - t0) < Farm.TimeoutAddress do task.wait(0.05) end
        if not Farm.Running then break end
        if not Farm.Pending then
            Farm.Fails += 1; farmLine("keine Adresse erhalten (Timeout)", COL.red); refreshStats()
            task.wait(Farm.LoopDelay); continue
        end

        local addr = Farm.Pending
        local label = addrLabel(addr)
        setFarmState("→ Finder: " .. label)

        local tSearch, res = os.clock(), nil
        while Farm.Running and not res and (os.clock() - tSearch) < Farm.TimeoutAddress do
            if LastResolved and LastResolved.addr == addr then res = LastResolved
            else res = Finder.resolve(addr, 1) end
            if not res then task.wait(0.2) end
        end
        if not Farm.Running then break end
        if not res then
            Farm.Fails += 1
            farmLine(string.format("kein Treffer: str=%s nr=%s | Index %d Einträge (%d m. Attributen) | Root %s",
                addr.street, tostring(addr.number), #Finder.entries, Finder.withAttrs, ActiveRootPath), COL.red)
            refreshStats(); task.wait(Farm.LoopDelay); continue
        end

        farmLine(string.format("Treffer [%s] %s.%s -> CFrame (%.2f, %.2f, %.2f)",
            res.how, ActiveRootPath, res.obj.Name, res.pos.X, res.pos.Y, res.pos.Z), COL.accent)
        if CONFIG.Mark then mark(res.obj) end
        setFarmState("→ " .. label)

        local t1, nextPush = os.clock(), 0
        while Farm.Running and not Farm.Confirmed and (os.clock() - t1) < Farm.TimeoutDeliver do
            if os.clock() >= nextPush then tpToResolved(res); nextPush = os.clock() + 1.5 end
            task.wait(0.1)
        end

        if Farm.Confirmed then Farm.Deliveries += 1; farmLine("geliefert: " .. label, COL.green)
        elseif Farm.Running then Farm.Fails += 1; farmLine("keine Bestätigung (Timeout)", COL.yellow) end
        refreshStats()
        task.wait(Farm.LoopDelay)
    end
    setFarmState("gestoppt")
end

local function startFarm()
    if Farm.Running then return end
    readPizza(); readTimings(); detectRoot()
    local n = Finder.rebuild()
    Farm.Running = true
    Farm.StartTime = os.clock()
    Farm.Deliveries, Farm.Fails, Farm.Money = 0, 0, 0
    startBtn.Text = "▶ LÄUFT"; startBtn.BackgroundColor3 = COL.accent
    farmLine("Farm gestartet · " .. n .. " Adressen indexiert · Root " .. ActiveRootPath, COL.green)
    refreshStats()
    task.spawn(farmLoop)
end

startBtn.MouseButton1Click:Connect(function() if Farm.Running then stopFarm() else startFarm() end end)
stopBtn.MouseButton1Click:Connect(stopFarm)

task.spawn(function()
    while true do
        if Farm.Running then statTime.Text = string.format("Laufzeit: %ds", math.floor(os.clock() - Farm.StartTime)) end
        task.wait(0.5)
    end
end)

--=====================================================================
-- TAB 2 · FINDER
--=====================================================================
local box = mk("TextBox", {
    Size = UDim2.new(1, -140, 0, 24), Position = UDim2.new(0, 2, 0, 4), BackgroundColor3 = COL.row,
    BorderSizePixel = 0, Font = Enum.Font.Code, TextSize = 12, TextColor3 = COL.text,
    ClearTextOnFocus = false, PlaceholderText = "Straße + Nr", PlaceholderColor3 = COL.dim,
    TextXAlignment = Enum.TextXAlignment.Left, Text = "",
}, finderPage)
mk("UICorner", { CornerRadius = UDim.new(0, 5) }, box)
mk("UIPadding", { PaddingLeft = UDim.new(0, 6) }, box)

local searchBtn  = mkBtn("Suchen", 60, 24, COL.green, finderPage, 288, 4)
local rebuildBtn = mkBtn("Index", 56, 24, COL.row, finderPage, 352, 4)
local keysBtn    = mkBtn("Keys", 60, 20, COL.accent, finderPage, 2, 32)
local testBtn    = mkBtn("Test", 60, 20, COL.accent, finderPage, 66, 32)
local dexBtn     = mkBtn("Dex", 50, 20, COL.accent, finderPage, 130, 32)

local rootLabel = mk("TextLabel", {
    Size = UDim2.new(1, -190, 0, 20), Position = UDim2.new(0, 186, 0, 32), BackgroundTransparency = 1,
    Font = Enum.Font.Code, TextSize = 10, TextColor3 = COL.dim,
    TextXAlignment = Enum.TextXAlignment.Left, Text = "ROOT: " .. ActiveRootPath,
}, finderPage)

local log = mk("ScrollingFrame", {
    Size = UDim2.new(1, -4, 0, 66), Position = UDim2.new(0, 2, 0, 56),
    BackgroundColor3 = Color3.fromRGB(18, 18, 18), BorderSizePixel = 0, ScrollBarThickness = 4,
    CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y,
    ScrollBarImageColor3 = COL.dim,
}, finderPage)
mk("UICorner", { CornerRadius = UDim.new(0, 5) }, log)
mk("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }, log)

local function logLine(text, col)
    mk("TextLabel", {
        Size = UDim2.new(1, -8, 0, 14), BackgroundTransparency = 1, Font = Enum.Font.Code,
        TextSize = 11, TextColor3 = col or COL.dim, TextXAlignment = Enum.TextXAlignment.Left,
        Text = text, LayoutOrder = #log:GetChildren(), TextTruncate = Enum.TextTruncate.AtEnd,
    }, log)
end

mk("TextLabel", {
    Size = UDim2.new(1, -4, 0, 12), Position = UDim2.new(0, 2, 0, 126), BackgroundTransparency = 1,
    Font = Enum.Font.Code, TextSize = 10, TextColor3 = COL.dim, TextXAlignment = Enum.TextXAlignment.Left,
    Text = "Index      Nr    Ort                 Straße                        Typ",
}, finderPage)

local results = mk("ScrollingFrame", {
    Size = UDim2.new(1, -4, 1, -144), Position = UDim2.new(0, 2, 0, 140), BackgroundTransparency = 1,
    BorderSizePixel = 0, ScrollBarThickness = 4, CanvasSize = UDim2.new(0, 0, 0, 0),
    AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarImageColor3 = COL.dim,
}, finderPage)
mk("UIListLayout", { Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder }, results)

local function fmtPos(p)
    if not p then return "keine Position" end
    return string.format("X:%.3f  Y:%.3f  Z:%.3f", p.X, p.Y, p.Z)
end

local function addRow(r, i)
    local pos, cf = readPosition(r.obj)
    local row = mk("Frame", {
        Size = UDim2.new(1, -6, 0, 34), BackgroundColor3 = (i % 2 == 0 and COL.row or COL.rowAlt),
        BorderSizePixel = 0, LayoutOrder = i,
    }, results)
    mk("UICorner", { CornerRadius = UDim.new(0, 5) }, row)

    local function cell(text, x, w, col)
        mk("TextLabel", {
            Size = UDim2.new(0, w, 0, 15), Position = UDim2.new(0, x, 0, 3), BackgroundTransparency = 1,
            Font = Enum.Font.Code, TextSize = 12, TextColor3 = col or COL.text,
            TextXAlignment = Enum.TextXAlignment.Left, Text = tostring(text or "-"),
            TextTruncate = Enum.TextTruncate.AtEnd,
        }, row)
    end
    cell(r.index, 8, 46, COL.dim)
    cell(r.num, 56, 34)
    cell(r.city, 92, 92)
    cell(r.street, 186, 130, COL.accent)
    cell(r.type, 318, 44, COL.dim)
    mk("TextLabel", {
        Size = UDim2.new(0, 230, 0, 12), Position = UDim2.new(0, 8, 0, 19), BackgroundTransparency = 1,
        Font = Enum.Font.Code, TextSize = 10, TextColor3 = COL.dim,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = r.obj.Name .. "   " .. (r.how or "") .. "   " .. fmtPos(pos),
    }, row)

    local tp = mkBtn("TP", 22, 18, COL.green, row, 0, 8); tp.Position = UDim2.new(1, -100, 0, 8)
    local mrk = mkBtn("◆", 22, 18, COL.accent, row, 0, 8); mrk.Position = UDim2.new(1, -70, 0, 8)
    local cpy = mkBtn("⧉", 22, 18, COL.yellow, row, 0, 8); cpy.Position = UDim2.new(1, -40, 0, 8)

    tp.MouseButton1Click:Connect(function() tpToPosition(pos, cf) end)
    mrk.MouseButton1Click:Connect(function() mark(r.obj) end)
    cpy.MouseButton1Click:Connect(function()
        local s = copyCoords(r.obj)
        logLine(s and ("» kopiert: " .. s) or "» keine Position", s and COL.yellow or COL.red)
    end)
    row.InputBegan:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 then tpToPosition(pos, cf) end
    end)
end

local function render(list, addr)
    for _, c in ipairs(results:GetChildren()) do if c:IsA("Frame") then c:Destroy() end end
    if #list == 0 then
        logLine("» kein Treffer für " .. addrLabel(addr), COL.red)
        return
    end
    for i, r in ipairs(list) do addRow(r, i) end
    logLine(string.format("» %d Treffer für %s (bester: %s)", #list, addrLabel(addr), tostring(list[1].how)), COL.green)
    if CONFIG.Mark then mark(list[1].obj) end
end

searchBtn.MouseButton1Click:Connect(function()
    local addr = parseAddress(box.Text) or { street = box.Text, number = nil, city = nil, raw = box.Text }
    local list = Finder.candidates(addr)
    render(list, addr)
end)

rebuildBtn.MouseButton1Click:Connect(function()
    local n = Finder.rebuild()
    rootLabel.Text = string.format("ROOT: %s · %d Adressen (%d m. Attr.)", ActiveRootPath, n, Finder.withAttrs)
    logLine(rootLabel.Text, COL.green)
end)

keysBtn.MouseButton1Click:Connect(function()
    ensureIndex()
    logLine("— Attribut-Keys im Index —", COL.accent)
    local arr = {}
    for k, c in pairs(Finder.keyHist) do arr[#arr + 1] = { k, c } end
    table.sort(arr, function(a, b) return a[2] > b[2] end)
    for i = 1, math.min(#arr, 12) do
        logLine(string.format("   %-24s x%d", arr[i][1], arr[i][2]), COL.text)
    end
    logLine(string.format("Einträge: %d · mit Attributen: %d · Root: %s", #Finder.entries, Finder.withAttrs, ActiveRootPath))
    if #Finder.entries > 0 then
        local e = Finder.entries[1]
        logLine("Beispiel: " .. tostring(e.street) .. " " .. tostring(e.number) .. " / " .. tostring(e.city) .. " / " .. tostring(e.type), COL.yellow)
    else
        logLine("KEIN Eintrag mit Straße gefunden -> Root/NameFilter prüfen!", COL.red)
    end
end)

testBtn.MouseButton1Click:Connect(function()
    local text = box.Text ~= "" and box.Text or "Nibelungenstraße 9, Tiefenbach"
    local addr = parseAddress(text)
    logLine("Test: " .. text, COL.accent)
    if not addr then logLine("   parse: FEHLGESCHLAGEN", COL.red); return end
    logLine(string.format("   parse: str=%s nr=%s city=%s", addr.street, tostring(addr.number), tostring(addr.city)), COL.yellow)
    ensureIndex()
    logLine(string.format("   Index: %d Einträge · Root %s", #Finder.entries, ActiveRootPath))
    local list = Finder.candidates(addr)
    logLine("   Kandidaten: " .. #list, #list > 0 and COL.green or COL.red)
    for i = 1, math.min(#list, 3) do
        local p = readPosition(list[i].obj)
        logLine(string.format("     [%s] %s · %s %s · %s", list[i].how, list[i].obj:GetFullName(), list[i].street, tostring(list[i].num), fmtPos(p)))
    end
end)

dexBtn.MouseButton1Click:Connect(function()
    pushToDex(box.Text); logLine("» Dex-Suche: " .. box.Text, COL.accent)
end)

--=====================================================================
-- HOOK REMOTES  (join all string args before parsing)
--=====================================================================
local hooked = {}
local function hookRemote(remote)
    if hooked[remote] then return end
    hooked[remote] = true
    remote.OnClientEvent:Connect(function(...)
        local args = { ... }
        local parts, line = {}, remote.Name .. "  "
        for _, v in ipairs(args) do
            if typeof(v) == "string" then parts[#parts + 1] = v end
            line = line .. (typeof(v) == "string" and ('"' .. v .. '"') or tostring(v)) .. "  "
        end
        logLine(line)

        local joined = table.concat(parts, " ")
        if joined == "" then return end

        local low = joined:lower()
        for _, w in ipairs(CONFIRM_WORDS) do
            if low:find(w, 1, true) then
                Farm.Confirmed = true
                local m = parseMoney(joined)
                if m then Farm.Money += m; refreshStats() end
                farmLine("Bestätigung: " .. joined, COL.green)
                break
            end
        end

        local addr = parseAddress(joined)
        if addr then
            if not addr.number then
                local n = joined:match("%s(%d+)%s*[,%s]") or joined:match("(%d+)%s*$")
                if n then addr.number = n end
            end
            box.Text = addrLabel(addr)
            logLine("» Adresse: " .. box.Text, COL.yellow)
            Farm.Pending = addr
            farmLine("Adresse: " .. box.Text, COL.yellow)
            local res = Finder.resolve(addr)
            render(res and res.list or Finder.candidates(addr), addr)
            if CONFIG.AutoShow then main.Visible = true end
        end
    end)
end

task.spawn(function()
    detectRoot()
    rootLabel.Text = "ROOT: " .. ActiveRootPath
    local folder = resolvePath(CONFIG.RemotePath)
    if folder then
        for _, o in ipairs(folder:GetDescendants()) do
            if (o:IsA("RemoteEvent") or o:IsA("UnreliableRemoteEvent")) and
               (not CONFIG.OnlySpielEvent or o.Name == "SpielEvent") then hookRemote(o) end
        end
        folder.DescendantAdded:Connect(function(o)
            if o:IsA("RemoteEvent") or o:IsA("UnreliableRemoteEvent") then hookRemote(o) end
        end)
    elseif Event then hookRemote(Event) end

    if ActiveRoot then
        local conn
        conn = ActiveRoot.DescendantAdded:Connect(function()
            if (os.clock() - Finder.stamp) > 2 then Finder.stamp = 0 end
        end)
    end
    logLine("» " .. #hooked .. " Remotes · Root: " .. ActiveRootPath, COL.green)
    farmLine(#hooked .. " Remotes · Root: " .. ActiveRootPath, COL.green)
end)

--=====================================================================
-- TOGGLE / DRAG / KEYS
--=====================================================================
local floating = mk("TextButton", {
    Name = "ToggleButton", Size = UDim2.new(0, 34, 0, 34), Position = UDim2.new(1, -46, 0.5, 0),
    BackgroundColor3 = COL.bar, BorderSizePixel = 0, Font = Enum.Font.Code,
    TextSize = 14, TextColor3 = COL.green, Text = "◆",
}, gui)
mk("UICorner", { CornerRadius = UDim.new(1, 0) }, floating)
mk("UIStroke", { Color = COL.green, Thickness = 1 }, floating)

local function toggle(state) main.Visible = (state ~= nil) and state or not main.Visible end
floating.MouseButton1Click:Connect(function() toggle() end)
closeBtn.MouseButton1Click:Connect(function() toggle(false) end)

UIS.InputBegan:Connect(function(inp, gpe)
    if gpe then return end
    if inp.KeyCode == CONFIG.ToggleKey then toggle()
    elseif inp.KeyCode == CONFIG.FarmKey then
        if Farm.Running then stopFarm() else startFarm() end
    end
end)

do -- drag
    local dragging, dragStart, startPos
    bar.InputBegan:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
            dragging = true; dragStart = inp.Position; startPos = main.Position
            inp.Changed:Connect(function()
                if inp.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    UIS.InputChanged:Connect(function(inp)
        if dragging and (inp.UserInputType == Enum.UserInputType.MouseMovement or inp.UserInputType == Enum.UserInputType.Touch) then
            local d = inp.Position - dragStart
            main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end)
end

_G.__Finder = {
    finder = Finder, farm = Farm, resolve = Finder.resolve, candidates = Finder.candidates,
    rebuild = Finder.rebuild, parse = parseAddress, root = function() return ActiveRootPath end,
    start = startFarm, stop = stopFarm,
}
farmLine("bereit · Root: " .. ActiveRootPath, COL.green)
logLine("» bereit · Root: " .. ActiveRootPath, COL.green)