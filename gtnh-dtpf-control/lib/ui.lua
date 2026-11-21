-- /home/dtpf/lib/ui.lua
-- Visual Control Center & Recipe Catalog GUI for GTNH 2.9+ DTPF Automation (160x50 Tier 3 GPU)
-- Strictly uses width-1 Unifont glyphs so character counts match terminal cell widths 1:1.
-- Sections: Formatters | DTPF Cards | Tab 1 Overview | Tab 2 Fleet | Tab 3 Recipes | Tab 4 Setup | Modals | Framebuffer

local component = require("component")
local Common = require("gtnh_common")
local unicode = require("unicode")
local Hardware = require("lib.hardware")
local RecipesDB = require("lib.recipes_db")
local Scheduler = require("lib.scheduler")

local UI = {}

local TAB_OVERVIEW = 1
local TAB_FLEET    = 2
local TAB_RECIPES  = 3
local TAB_SETUP    = 4

local LOG_LEVELS = {
    { id = "quiet",  label = "Quiet"  },
    { id = "normal", label = "Normal" },
    { id = "raw",    label = "Raw"    },
}

local COLORS = {
    bg = 0x0C1117,
    headerBg = 0x16202C,
    panelBg = 0x121922,
    rowAltBg = 0x10161E,
    selectedBg = 0x1D2D42,
    border = 0x334155,
    fg = 0xE6EDF3,
    muted = 0x7D8590,
    accent = 0x58A6FF,
    green = 0x3FB950,
    darkGreen = 0x1B4D2B,
    yellow = 0xE3B341,
    amberBg = 0x4D340B,
    red = 0xF85149,
    darkRed = 0x5E1F1D,
    purple = 0xBC8CFF,
    cyan = 0x39C5CF,
    btnBg = 0x283545,
    btnActiveBg = 0x1F6FEB,
}

local CATALYST_SHORT = { "DTCC", "DTPC", "DTRC", "DTEC", "DTSC" }
local SIDE_NAMES = { [0] = "Down", [1] = "Up", [2] = "North", [3] = "South", [4] = "West", [5] = "East" }

local GLOBAL_CONV_MODES = {
    { id = "auto",   label = "⚡Auto @50%", short = "Auto" },
    { id = "always", label = "⚡Always ON", short = "ON" },
    { id = "off",    label = "◇OFF",        short = "OFF" },
}

local DTPF_CONV_MODES = {
    { id = "global",   label = "Default",     short = "Auto" },
    { id = "auto",     label = "⚡Auto @50%", short = "⚡50%" },
    { id = "ondemand", label = "⚡OD Only",   short = "⚡OD" },
    { id = "always",   label = "⚡Always ON", short = "⚡ON" },
    { id = "off",      label = "◇OFF",        short = "OFF" },
}

local RECIPE_CONV_MODES = {
    { id = "global",    label = "Default" },
    { id = "on",        label = "⚡Auto @50%" },
    { id = "below_tgt", label = "⚡<Tgt" },
    { id = "force",     label = "⚡Always ON" },
    { id = "off",       label = "◇OFF" },
}

local OD_CONV_MODES = {
    { id = "auto_safe", label = "⚡Auto-Safe", pill = "[⚡Auto-Safe]" },
    { id = "on",        label = "⚡Always ON", pill = "[⚡Always ON]" },
    { id = "off",       label = "◇OFF",        pill = "[◇OFF]" },
}

local ROLE_MODES = {
    { id = "auto", label = "AUTO", short = "AUTO" },
    { id = "passive_only", label = "PASSIVE", short = "PASS" },
    { id = "fallback_only", label = "LOOP", short = "LOOP" },
    { id = "od_only", label = "OD ONLY", short = "OD" },
}

local FAMILY_BY_ID = Scheduler.FAMILY_BY_ID

local NO_CONV_PATCH_MSG = "Stock GTNH (no DriverDTPF OC patch): toggle Convergence in DTPF GUI."

function UI:isConvControlSupported()
    return not (self.state and self.state.convControlSupported == false)
end

function UI.formatNumber(n, isFluid)
    n = tonumber(n) or 0
    local absN = math.abs(n)
    local suffix = isFluid and "L" or ""
    if absN >= 1e12 then
        return string.format("%.2fT%s", n / 1e12, suffix)
    elseif absN >= 1e9 then
        return string.format("%.2fB%s", n / 1e9, suffix)
    elseif absN >= 1e6 then
        return string.format("%.1fM%s", n / 1e6, suffix)
    elseif absN >= 1e3 then
        return string.format("%.1fK%s", n / 1e3, suffix)
    else
        return string.format("%d%s", math.floor(n), suffix)
    end
end

function UI.parseNumber(str)
    if type(str) ~= "string" then return nil end
    local s = str:gsub("%s+", ""):gsub(",", ""):gsub("[lL]$", ""):upper()
    local numPart, multChar = s:match("^([%d%.]+)([KMBT]?)$")
    if not numPart then return nil end
    local val = tonumber(numPart)
    if not val then return nil end
    local mult = 1
    if multChar == "K" then mult = 1e3
    elseif multChar == "M" then mult = 1e6
    elseif multChar == "B" then mult = 1e9
    elseif multChar == "T" then mult = 1e12
    end
    return math.floor(val * mult)
end

local function formatInt(n)
    local s = tostring(math.floor(tonumber(n) or 0))
    return (s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

local SUB_BLOCKS = { "▏", "▎", "▍", "▌", "▋", "▊", "▉" }
local TANK_LEVELS = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }
local FRAME_STYLES = {
    sharp  = { tl = "┌", tr = "┐", bl = "└", br = "┘", h = "─", v = "│" },
    round  = { tl = "╭", tr = "╮", bl = "╰", br = "╯", h = "─", v = "│" },
    double = { tl = "╔", tr = "╗", bl = "╚", br = "╝", h = "═", v = "║" },
}

local function fmtCompactNum(n, isFluid)
    return (UI.formatNumber(n, isFluid):gsub("%.00?([KMBTL])", "%1"):gsub("(%.[1-9])0([BT])", "%1%2"))
end

function UI.formatDurationShort(sec)
    sec = tonumber(sec)
    if not sec or sec <= 0 then return nil end
    if sec < 60 then
        return string.format("%ds", math.floor(sec + 0.5))
    elseif sec < 3600 then
        return string.format("%dm", math.floor(sec / 60 + 0.5))
    elseif sec < 86400 then
        return string.format("%.1fh", sec / 3600)
    else
        return string.format("%.1fd", sec / 86400)
    end
end

local function formatDtpfIdList(ids, maxShown)
    if not ids or #ids == 0 then return "" end
    local lim = math.min(#ids, maxShown or #ids)
    local parts = {}
    for i = 1, lim do
        parts[i] = tostring(ids[i]):gsub("^#", "")
    end
    return "#" .. table.concat(parts, ",") .. ((#ids > lim) and "+" or "")
end

local function compactRecipeName(name, maxLen)
    local s = tostring(name or "")
    if unicode.wlen(s) <= maxLen then return s end
    s = s:gsub("Molten Celestial Tungsten & Transcendent Metal",
        (maxLen >= 30 and "Celestial Tungsten & Transc.")
        or (maxLen >= 20 and "Celestial + Transc.")
        or "Celestial/Transc")
    s = s:gsub("Timepiece & Spatially Enlarged Fluid",
        (maxLen >= 30 and "Timepiece & Spatially Enlarged")
        or (maxLen >= 19 and "Timepiece + Spatial")
        or "Timepiece+Spatial")
    s = s:gsub("Tachyon Rich Temporal Fluid",
        (maxLen >= 21 and "Tachyon Rich Temporal") or "Tachyon Temporal")
    s = s:gsub("Spatially Enlarged Fluid", "Spatially Enlarged")
    s = s:gsub("Continuum Ripper Loop", "Ripper Loop")
    s = s:gsub("Molten Superconductor Base ", "SC Base ")
    s = s:gsub("Dimensionally Shifted Superfluid",
        (maxLen >= 23 and "Dim. Shifted Superfluid") or "Shifted Superfluid")
    s = s:gsub("Astral Titanium & Molten Quantum",
        (maxLen >= 25 and "Astral Titanium & Quantum") or "Astral + Quantum")
    if unicode.wlen(s) <= maxLen then return s end
    s = s:gsub("^Molten%s+", "")
    if unicode.wlen(s) <= maxLen then return s end
    s = s:gsub("Superconductor Base ", "SC Base ")
    return s
end

local function compactStatusText(sStr, maxLen)
    local s = tostring(sStr or "")
    if unicode.wlen(s) <= maxLen then return s end
    s = s:gsub("^Fallback:%s*", "FB: ")
    s = s:gsub("DTR < Floor", "DTR<Floor")
    if s:find("^Guard < Floor", 1) then
        local k = s:match("%((.-)%)") or ""
        local shortK = k
        if k:find("quantum", 1, true) then shortK = "Quantum"
        elseif k:find("32415", 1, true) then shortK = "Tess"
        elseif k:find("32105", 1, true) then shortK = "Anomaly"
        elseif k:find("dimensionallytranscendentresidue", 1, true) then shortK = "DTR"
        end
        local cand = "Grd<Flr:" .. shortK
        if unicode.wlen(cand) > maxLen then cand = "Grd:" .. shortK end
        if unicode.wlen(cand) > maxLen then cand = "Grd<Floor" end
        return cand
    end
    if s:find("^Coil < ", 1) then
        s = s:gsub("^Coil < ", "<")
        if unicode.wlen(s) <= maxLen then return s end
    end
    if s:find("^Missing%s+") then
        s = s:gsub("^Missing%s+", "No ")
        s = s:gsub("Molten%s+", "")
        if unicode.wlen(s) > maxLen then
            s = s:gsub("Stable Boson Containment Unit", (maxLen >= 15 and "Stable Boson") or "Boson")
            s = s:gsub("Cosmic Neutronium Rod", (maxLen >= 13 and "Cosmic Rod") or "Cosm.Rod")
            s = s:gsub("Energised Tesseract", (maxLen >= 13 and "Energ.Tess") or "En.Tess")
            s = s:gsub("Infinity Catalyst", "Inf.Cat")
            s = s:gsub("Infinity Comb", "Inf.Comb")
            s = s:gsub("Transcendent Metal", "Transc.Mtl")
            s = s:gsub("Celestial Tungsten", (maxLen >= 15 and "Celest.Tungst") or "Celest")
            s = s:gsub("Cosmic Neutronium", "Cosmic N.")
            s = s:gsub("Chromatic Glass", "Chrom.Gls")
        end
    end
    return s
end

function UI.buildProgressBar(ratio, innerW)
    ratio = math.max(0, math.min(1, tonumber(ratio) or 0))
    local exact = ratio * innerW
    local full = math.floor(exact)
    if full >= innerW then
        return "[" .. string.rep("█", innerW) .. "]"
    end
    local fracIdx = math.floor((exact - full) * 7 + 0.5)
    if fracIdx >= 1 then
        return "[" .. string.rep("█", full) .. SUB_BLOCKS[fracIdx] .. string.rep("░", math.max(0, innerW - full - 1)) .. "]"
    end
    return "[" .. string.rep("█", full) .. string.rep("░", math.max(0, innerW - full)) .. "]"
end

local buildProgressBar = UI.buildProgressBar

local function getTankGaugeChar(amt, floor)
    amt = tonumber(amt) or 0
    floor = tonumber(floor) or 0
    if amt <= 0 then return "✗" end
    if amt <= floor then return "!" end
    local lvl = math.max(1, math.min(8, math.ceil((amt / math.max(1, floor * 4)) * 8)))
    return TANK_LEVELS[lvl]
end

local function getCoilTierInfo(coilHeat)
    coilHeat = tonumber(coilHeat)
    if not coilHeat or coilHeat <= 0 then return "◌Coil?", COLORS.muted, "?", "?" end
    if coilHeat >= 13500 then return "◉Eternal", COLORS.purple, "Eternal", "Etern." end
    if coilHeat >= 12600 then return "◉Hypogen", COLORS.red, "Hypogen", "Hypog." end
    if coilHeat >= 11700 then return "◉Infinity", COLORS.fg, "Infinity", "Infin." end
    if coilHeat >= 10800 then return "◉Awakened", COLORS.yellow, "Awakened", "Awak." end
    if coilHeat >= 9900 then return "◉Draconium", COLORS.purple, "Draconium", "Drac." end
    if coilHeat >= 9000 then return "◉Flux", COLORS.cyan, "Flux", "Flux" end
    if coilHeat >= 8100 then return "◉Trinium", COLORS.fg, "Trinium", "Trin." end
    if coilHeat >= 7200 then return "◉Naquadah", COLORS.green, "Naquadah", "Naq." end
    if coilHeat >= 5400 then return "◉HSS-S", COLORS.cyan, "HSS-S", "HSS-S" end
    if coilHeat >= 4500 then return "◉HSS-G", COLORS.cyan, "HSS-G", "HSS-G" end
    if coilHeat >= 3600 then return "◉TPV", COLORS.yellow, "TPV", "TPV" end
    if coilHeat >= 2700 then return "◉Nichrome", COLORS.yellow, "Nichrome", "Nichr." end
    if coilHeat >= 1800 then return "◉Cupro", COLORS.yellow, "Cupro.", "Cupro." end
    local k = tostring(math.floor(coilHeat)) .. "K"
    return "◌" .. k, COLORS.cyan, k, k
end

local function localizeCoilStatus(ui, sStr)
    local s = tostring(sStr or "")
    if not ui or not ui:isCoilNameMode() then return s end
    local heatNum = s:match("^Coil < (%d+)K$")
    if heatNum then
        local _, _, tierName = getCoilTierInfo(tonumber(heatNum))
        if tierName and tierName ~= "?" then
            return "Coil < " .. tierName
        end
    end
    return s
end

local function getCategoryBadge(category)
    if category == "Fluid" then return "◈", COLORS.cyan
    elseif category == "Item" then return "▣", COLORS.yellow
    elseif category == "Hybrid" then return "⊕", COLORS.green
    end
    return "·", COLORS.muted
end

local function getStockRatioColor(ratio, isEnabled)
    if (ratio or 0) >= 1.0 then return COLORS.green end
    if not isEnabled then return COLORS.muted end
    if (ratio or 0) >= 0.5 then return COLORS.cyan end
    return COLORS.yellow
end

local padOrTrunc = Common.padOrTrunc

local function centerText(str, width)
    str = tostring(str or "")
    local len = unicode.wlen(str)
    if len >= width then
        return padOrTrunc(str, width)
    end
    local padTotal = width - len
    local leftPad = math.floor(padTotal / 2)
    return string.rep(" ", leftPad) .. str .. string.rep(" ", padTotal - leftPad)
end

local function clusterAxisValues(vals)
    if #vals == 0 then return {} end
    local sorted = {}
    for i = 1, #vals do sorted[i] = vals[i] end
    table.sort(sorted)
    local clusters = { sorted[1] }
    for i = 2, #sorted do
        if (sorted[i] - clusters[#clusters]) > 6 then
            clusters[#clusters + 1] = sorted[i]
        end
    end
    return clusters
end

local function findClusterIndex(clusters, val)
    local bestIdx, bestDist = 1, math.huge
    for i = 1, #clusters do
        local d = math.abs(clusters[i] - val)
        if d < bestDist then
            bestDist = d
            bestIdx = i
        end
    end
    return bestIdx
end

-- Map DTPFs into an in-world (X, Z) room layout grid, falling back to a 2- or 3-column grid when coords are absent.
function UI.computeSpatialGrid(dtpfs, statuses)
    local count = #(dtpfs or {})
    if count == 0 then
        return { cols = 2, rows = 1, slots = {}, grid = {}, colCoords = {}, rowCoords = {}, usedSpatial = false }
    end

    local xs, zs, coords = {}, {}, {}
    local allHaveCoords = true
    for i = 1, count do
        local d = dtpfs[i]
        local st = statuses and statuses[i]
        local x = tonumber(d.x or (st and st.x))
        local z = tonumber(d.z or (st and st.z))
        if x and z then
            coords[i] = { x = math.floor(x), z = math.floor(z) }
            xs[#xs + 1] = math.floor(x)
            zs[#zs + 1] = math.floor(z)
        else
            allHaveCoords = false
        end
    end

    if allHaveCoords then
        local xClusters = clusterAxisValues(xs)
        local zClusters = clusterAxisValues(zs)
        if #xClusters >= 1 and #xClusters <= 4 and #zClusters >= 1 then
            local grid = {}
            local slots = {}
            local collision = false
            for r = 1, #zClusters do grid[r] = {} end
            for i = 1, count do
                local c = findClusterIndex(xClusters, coords[i].x)
                local r = findClusterIndex(zClusters, coords[i].z)
                if grid[r][c] then
                    collision = true
                    break
                end
                grid[r][c] = i
                slots[i] = { index = i, col = c, row = r, x = coords[i].x, z = coords[i].z }
            end
            if not collision then
                return {
                    cols = math.max(1, #xClusters),
                    rows = math.max(1, #zClusters),
                    slots = slots,
                    grid = grid,
                    colCoords = xClusters,
                    rowCoords = zClusters,
                    usedSpatial = true,
                }
            end
        end
    end

    local cols = 2
    local rows = math.max(1, math.ceil(count / cols))
    local grid = {}
    local slots = {}
    for r = 1, rows do grid[r] = {} end
    for i = 1, count do
        local c = ((i - 1) % cols) + 1
        local r = math.floor((i - 1) / cols) + 1
        grid[r][c] = i
        local ci = coords[i]
        slots[i] = { index = i, col = c, row = r, x = ci and ci.x or nil, z = ci and ci.z or nil }
    end
    return { cols = cols, rows = rows, slots = slots, grid = grid, colCoords = {}, rowCoords = {}, usedSpatial = false }
end

local COL_MUL = 16777216

function UI.new(cfg, runtimeState, onSaveCallback)
    local gpu = component.gpu
    local w, h = 160, 50

    local self = {
        gpu = gpu,
        w = w,
        h = h,
        cfg = cfg,
        state = runtimeState,
        onSave = onSaveCallback,
        tab = TAB_OVERVIEW, -- 1 = Overview, 2 = Fleet, 3 = Recipes, 4 = Setup
        selectedDtpf = 1,
        selectedFamilyId = RecipesDB.FAMILIES[1] and RecipesDB.FAMILIES[1].id or "molten_neutronium",
        recipeFilter = "all", -- "all" | "enabled" | "loops" | "nocat"
        queueShowAll = false,
        activeScroll = 0,
        overviewDtpfScroll = 0,
        overviewRecScroll = 0,
        recipeScroll = 0,
        dtpfRowScroll = 0,
        fleetCompact = false,
        wiringChScroll = 0,
        wiringDtpfScroll = 0,
        passiveModalActive = false,
        passiveModalDtpfIdx = 1,
        passiveModalScroll = 0,
        passiveModalFilter = "all",
        logModalActive = false,
        logModalScroll = 0,
        logModalTab = 1,
        logStageFilter = "ALL",
        maintModalActive = false,
        maintModalScroll = 0,
        maintModalSearch = "",
        maintFilterActive = true,
        hitboxes = {},
        running = true,
        configDirty = false,
        statusMsg = "Ready - Left/Right click any shaded button or pill.",
        statusStep = 0,
        promptActive = false,
        promptIsNumeric = false,
        promptTitle = "",
        promptHint = "",
        promptBuffer = "",
        promptCallback = nil,
        animTick = 0,
        animNow = nil,
        discoveredNets = {},
        discoveredTransposers = {},
        discoveredEndpoints = { hatches = {}, buses = {}, itemStorageBuses = {}, fluidStorageBuses = {}, warnings = {} },
        curCh = {},
        curCol = {},
        nxtCh = {},
        nxtCol = {},
    }
    local defCol = COLORS.fg * COL_MUL + COLORS.bg
    for ry = 1, h do
        self.curCh[ry], self.curCol[ry] = {}, {}
        local rCh, rCol = {}, {}
        for rx = 1, w do
            rCh[rx] = " "
            rCol[rx] = defCol
        end
        self.nxtCh[ry], self.nxtCol[ry] = rCh, rCol
    end
    setmetatable(self, { __index = UI })
    self:syncDisplay(true)
    self:refreshDiscovery()
    return self
end

function UI:syncDisplay(forceRedraw)
    return Common.syncDisplay(self, {
        forceRedraw = forceRedraw,
        onResize = function(aw, ah)
            local defCol = COLORS.fg * COL_MUL + COLORS.bg
            self.curCh, self.curCol, self.nxtCh, self.nxtCol = {}, {}, {}, {}
            for ry = 1, ah do
                self.curCh[ry], self.curCol[ry] = {}, {}
                local rCh, rCol = {}, {}
                for rx = 1, aw do
                    rCh[rx] = " "
                    rCol[rx] = defCol
                end
                self.nxtCh[ry], self.nxtCol[ry] = rCh, rCol
            end
        end,
    })
end

function UI:invalidateScreen()
    for ry = 1, self.h do
        self.curCh[ry] = {}
        self.curCol[ry] = {}
    end
end

function UI:clearNextBuffer(bgCol, fgCol)
    local packed = (fgCol or COLORS.fg) * COL_MUL + (bgCol or COLORS.bg)
    local w = self.w
    for ry = 1, self.h do
        local rCh = self.nxtCh[ry]
        local rCol = self.nxtCol[ry]
        for rx = 1, w do
            rCh[rx] = " "
            rCol[rx] = packed
        end
    end
end

function UI:setStatus(msg)
    if msg then
        self.statusMsg = msg
        self.statusStep = (self.state and self.state.stepCount) or 0
    end
end

function UI:consumeConfigDirty()
    local d = (self.configDirty == true)
    self.configDirty = false
    return d
end

function UI:save(msg)
    self.configDirty = true
    if self.onSave then
        self.onSave(self.cfg)
    end
    self:setStatus(msg)
end

local ANIM_SPIN4 = { "◐", "◓", "◑", "◒" }
local ANIM_BRAILLE = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧" }
local CONV_SPRITE_FRAMES = {
    { "⚡◈⚡", "◈◉◈" },
    { "◈⚡◈", "◉◈◉" },
    { "⚡◉⚡", "◈⚡◈" },
    { "◉⚡◉", "⚡◈⚡" },
}

function UI:isAnimEnabled()
    return self.cfg.uiAnimations ~= false
end

function UI:advanceAnim(nowUptime)
    if not self:isAnimEnabled() then
        self.animTick = 0
        self.animNow = nil
        return
    end
    self.animTick = ((self.animTick or 0) % 8) + 1
    self.animNow = nowUptime
end

function UI:toggleAnimations()
    self.cfg.uiAnimations = not (self.cfg.uiAnimations ~= false)
    if not self.cfg.uiAnimations then
        self.animTick = 0
        self.animNow = nil
    end
    self:save("UI Animations -> " .. (self.cfg.uiAnimations and "ON (0-poll GPU diff)" or "OFF (Static)"))
end

function UI:isCoilNameMode()
    return (self.cfg.coilDisplayMode or "name") ~= "temp"
end

function UI:toggleCoilDisplay()
    if (self.cfg.coilDisplayMode or "name") == "temp" then
        self.cfg.coilDisplayMode = "name"
        self:save("Coil Display -> Tier Name (click any Coil label to show Kelvin)")
    else
        self.cfg.coilDisplayMode = "temp"
        self:save("Coil Display -> Temperature K (click any Coil label to show Name)")
    end
end

local function getEffectiveProgress(self, st)
    local maxProg = (st and tonumber(st.maxProgress)) or 0
    local prog = (st and tonumber(st.progress)) or 0
    if self:isAnimEnabled() and self.cfg.armed and (self.animTick or 0) > 0
        and st and st.active and maxProg > 0
        and self.animNow and self.state and self.state._lastPollUptime
        and self.animNow > self.state._lastPollUptime then
        local elapsed = math.min(5.0, self.animNow - self.state._lastPollUptime)
        prog = math.min(maxProg, prog + math.floor(elapsed * 20))
    end
    return prog, maxProg
end

function UI:refreshDiscovery()
    local nets, ep = Scheduler.syncHardware(self.cfg)
    self.discoveredNets = nets or {}
    self.discoveredTransposers = Hardware.discoverTransposers() or {}
    self.discoveredEndpoints = ep or { hatches = {}, buses = {}, itemStorageBuses = {}, fluidStorageBuses = {}, warnings = {} }
    if self.selectedDtpf > #self.cfg.dtpfs then
        self.selectedDtpf = math.max(1, #self.cfg.dtpfs)
    end
end

function UI:ensureDtpfVisible(dtpfIdx)
    local count = #self.cfg.dtpfs
    if count == 0 then return end
    local layout = UI.computeSpatialGrid(self.cfg.dtpfs, self.state.dtpfStatus)
    local slot = layout.slots[dtpfIdx]
    if not slot or not slot.row then return end
    local visibleRows = self.fleetCompact and 7 or ((layout.cols <= 2) and 3 or 4)
    local maxRowScroll = math.max(0, layout.rows - visibleRows)
    self.dtpfRowScroll = math.max(0, math.min(maxRowScroll, self.dtpfRowScroll or 0))
    if slot.row <= self.dtpfRowScroll then
        self.dtpfRowScroll = math.max(0, slot.row - 1)
    elseif slot.row > self.dtpfRowScroll + visibleRows then
        self.dtpfRowScroll = math.min(maxRowScroll, slot.row - visibleRows)
    end
end

function UI:selectDtpfByDelta(delta)
    local count = #self.cfg.dtpfs
    if count == 0 then return end
    local cur = math.max(1, math.min(count, self.selectedDtpf or 1))
    self.selectedDtpf = ((cur - 1 + (delta or 1)) % count) + 1
    self:ensureDtpfVisible(self.selectedDtpf)
end

function UI:addHitbox(x1, y1, x2, y2, fn)
    if x2 < 1 or y2 < 1 or x1 > self.w or y1 > self.h then return end
    self.hitboxes[#self.hitboxes + 1] = {
        x1 = math.max(1, x1),
        y1 = math.max(1, y1),
        x2 = math.min(self.w, x2),
        y2 = math.min(self.h, y2),
        fn = fn,
    }
end

function UI:fillRect(x, y, w, h, ch, bg)
    if x > self.w or y > self.h or w <= 0 or h <= 0 then return end
    local cx = math.max(1, x)
    local cy = math.max(1, y)
    local cw = math.min(self.w - cx + 1, w - (cx - x))
    local chh = math.min(self.h - cy + 1, h - (cy - y))
    if cw <= 0 or chh <= 0 then return end
    local x2 = cx + cw - 1
    local y2 = cy + chh - 1
    local fillCh = ch or " "
    local packedBlank = (bg and fillCh == " ") and (COLORS.fg * COL_MUL + bg) or nil
    for ry = cy, y2 do
        local rCh = self.nxtCh[ry]
        local rCol = self.nxtCol[ry]
        if packedBlank then
            for rx = cx, x2 do
                rCh[rx] = fillCh
                rCol[rx] = packedBlank
            end
        else
            for rx = cx, x2 do
                rCh[rx] = fillCh
                local old = rCol[rx]
                local nfg = (fillCh == " ") and COLORS.fg or math.floor(old / COL_MUL)
                local nbg = bg or (old % COL_MUL)
                rCol[rx] = nfg * COL_MUL + nbg
            end
        end
    end
end

function UI:drawText(x, y, text, fg, bg)
    if y < 1 or y > self.h or x > self.w then return end
    local s = tostring(text or "")
    if x < 1 then
        s = unicode.sub(s, 2 - x)
        x = 1
    end
    local rCh = self.nxtCh[y]
    local rCol = self.nxtCol[y]
    local col = x
    local w = self.w
    local packed = (fg and bg) and (fg * COL_MUL + bg) or nil
    for ch in s:gmatch("[\1-\127\194-\244][\128-\191]*") do
        if col > w then break end
        rCh[col] = ch
        if packed then
            rCol[col] = packed
        elseif fg or bg then
            local old = rCol[col]
            rCol[col] = (fg or math.floor(old / COL_MUL)) * COL_MUL + (bg or (old % COL_MUL))
        end
        col = col + 1
    end
end

function UI:drawButton(x, y, label, fg, bg, onClick)
    local len = unicode.wlen(label)
    self:drawText(x, y, label, fg or COLORS.fg, bg or COLORS.btnBg)
    if onClick and len > 0 then
        self:addHitbox(x, y, x + len - 1, y, onClick)
    end
    return x + len
end

function UI:drawFrame(x, y, w, h, borderCol, bgCol, style)
    local fc = FRAME_STYLES[style or "sharp"] or FRAME_STYLES.sharp
    self:fillRect(x, y, w, h, " ", bgCol)
    self:drawText(x, y, fc.tl .. string.rep(fc.h, w - 2) .. fc.tr, borderCol, bgCol)
    self:drawText(x, y + h - 1, fc.bl .. string.rep(fc.h, w - 2) .. fc.br, borderCol, bgCol)
    for ry = 1, h - 2 do
        self:drawText(x, y + ry, fc.v, borderCol, bgCol)
        self:drawText(x + w - 1, y + ry, fc.v, borderCol, bgCol)
    end
end

function UI:openPrompt(title, initialVal, hint, callback)
    self.promptActive = true
    self.promptIsNumeric = false
    self.promptTitle = title
    self.promptBuffer = tostring(initialVal or "")
    self.promptHint = hint or "Type value and press [Enter] / click [APPLY], or [Esc] / [CANCEL]."
    self.promptCallback = callback
end

function UI:openNumberPrompt(title, initialVal, callback)
    self:openPrompt(
        title,
        initialVal,
        "Touch preset chips above, or type digits + K/M/B/T & click [ APPLY ].",
        callback
    )
    self.promptIsNumeric = true
end

function UI:openTargetPrompt(fam, rc, trackedOut)
    local isFluid = trackedOut and (trackedOut.isFluid or trackedOut.type == "fluid")
    self:openNumberPrompt("Target Stock for " .. fam.name .. ":", UI.formatNumber(rc.target, false), function(val)
        local parsed = UI.parseNumber(val)
        if parsed and parsed > 0 then
            rc.target = parsed
            self:save(fam.name .. " target -> " .. UI.formatNumber(parsed, isFluid))
        end
    end)
end

function UI:getSelectedFamily()
    local fam = FAMILY_BY_ID[self.selectedFamilyId]
    if not fam then
        fam = RecipesDB.FAMILIES[1]
        self.selectedFamilyId = fam and fam.id or nil
    end
    return fam
end

function UI:renderHeader()
    -- Rows 1-2: Stylized Reactor Emblem & Block-Letter `DTPF CONTROL` Banner + Interactive Bar
    local armed = (self.cfg.armed == true)
    local animOn = self:isAnimEnabled()
    local tick = self.animTick or 0
    local od = (self.state and self.state.onDemand) or {}

    self:fillRect(1, 1, self.w, 2, " ", COLORS.headerBg)

    -- Left Reactor Emblem (x = 2..6, y = 1..2; click toggles zero-overhead animations)
    local topEmb, botEmb, embCol
    if not armed then
        topEmb, botEmb, embCol = "╭≡○≡╮", "╰═◇═╯", COLORS.yellow
    elseif od.hasWork and not od.stalled then
        if animOn and tick > 0 and (tick % 2 == 0) then
            topEmb, botEmb, embCol = "╭◈⚡◈╮", "╰◉◈◉╯", COLORS.purple
        else
            topEmb, botEmb, embCol = "╭⚡◈⚡╮", "╰◈◉◈╯", COLORS.purple
        end
    else
        local spinCore = (animOn and tick > 0) and ANIM_SPIN4[((tick - 1) % 4) + 1] or "●"
        local botCore = (animOn and tick > 0 and (tick % 2 == 0)) and "◉" or "◈"
        topEmb, botEmb, embCol = "╭≡" .. spinCore .. "≡╮", "╰═" .. botCore .. "═╯", COLORS.cyan
    end
    self:drawText(2, 1, topEmb, embCol, COLORS.headerBg)
    self:drawText(2, 2, botEmb, embCol, COLORS.headerBg)
    self:addHitbox(2, 1, 6, 2, function()
        self:toggleAnimations()
    end)

    -- Stylized 2-Row Block Title (`DTPF CONTROL`)
    local dTopCol = armed and COLORS.cyan or COLORS.yellow
    local dBotCol = armed and COLORS.accent or COLORS.yellow
    self:drawText(8, 1, "█▀▀▄ ▀█▀ █▀▀▄ █▀▀▀", dTopCol, COLORS.headerBg)
    self:drawText(8, 2, "█▄▄▀  █  █▀▀  █▀▀ ", dBotCol, COLORS.headerBg)
    self:drawText(28, 1, "▄▀▀▀ ▄▀▀▄ █▄ █ ▀█▀ █▀▀▄ ▄▀▀▄ █  ", COLORS.fg, COLORS.headerBg)
    self:drawText(28, 2, "▀▄▄▄ ▀▄▄▀ █ ▀█  █  █▀▄  ▀▄▄▀ █▄▄", COLORS.accent, COLORS.headerBg)

    self:drawText(61, 1, "│", COLORS.border, COLORS.headerBg)
    self:drawText(61, 2, "│", COLORS.border, COLORS.headerBg)

    -- Row 1 Right (x = 63..159): Mode, Tabs, Poll, Log, Anim Toggle, Quit
    local armLabel = armed and "[● ARMED]" or "[○ PAUSED]"
    local armFg = armed and COLORS.green or COLORS.yellow
    local armBg = armed and COLORS.darkGreen or COLORS.amberBg
    local tx = self:drawButton(63, 1, armLabel, armFg, armBg, function()
        self.cfg.armed = not (self.cfg.armed == true)
        self:save(self.cfg.armed
            and "ARMED: Controller actively managing passive channels and DTPFs."
            or "PAUSED: Safe read-only monitor mode (zero hardware writes).")
    end) + 1

    local tabs = {
        { id = TAB_OVERVIEW, label = "[1] OVERVIEW" },
        { id = TAB_FLEET,    label = "[2] FLEET" },
        { id = TAB_RECIPES,  label = "[3] RECIPES" },
        { id = TAB_SETUP,    label = "[4] SETUP" },
    }
    for i = 1, #tabs do
        local t = tabs[i]
        local active = (self.tab == t.id)
        tx = self:drawButton(
            tx, 1, t.label,
            active and COLORS.fg or COLORS.muted,
            active and COLORS.btnActiveBg or COLORS.btnBg,
            function() self.tab = t.id end
        ) + 1
    end

    tx = self:drawButton(tx, 1, "[↻ Poll]", COLORS.cyan, COLORS.btnBg, function()
        self.animNow = nil
        Scheduler.step(self.cfg, self.state)
        self:setStatus("Polled sensors & AE2 (step #" .. tostring(self.state.stepCount or 1) .. ").")
    end) + 1

    local bnCount = #((self.state and self.state.bottlenecks) or {})
    local evCount = #((self.state and self.state.events) or {})
    local logLbl = (bnCount > 0) and string.format("[! %d Alert]", bnCount) or string.format("[Log:%d]", evCount)
    tx = self:drawButton(tx, 1, logLbl,
        (bnCount > 0) and COLORS.yellow or COLORS.cyan,
        (bnCount > 0) and COLORS.amberBg or COLORS.btnBg,
        function()
            self.logModalActive = true
            self.passiveModalActive = false
            self.promptActive = false
            self.logModalScroll = 0
        end) + 1

    local animGlyph = animOn
        and ((tick > 0) and ANIM_SPIN4[((tick - 1) % 4) + 1] or "◐")
        or "○"
    local animLbl = "[" .. animGlyph .. " Anim]"
    if tx + unicode.wlen(animLbl) <= self.w - 8 then
        tx = self:drawButton(tx, 1, animLbl,
            animOn and COLORS.cyan or COLORS.muted,
            animOn and COLORS.btnActiveBg or COLORS.btnBg,
            function()
                self:toggleAnimations()
            end) + 1
    end

    self:drawButton(self.w - 6, 1, "[QUIT]", COLORS.red, COLORS.darkRed, function()
        self:save("Configuration saved.")
        self.running = false
    end)

    -- Row 2 Right (x = 63..159): Live Fleet Role Summary + On-Demand Badge
    local conflictNames = {}
    local onlineCount = 0
    for i = 1, #self.cfg.dtpfs do
        local st = self.state.dtpfStatus and self.state.dtpfStatus[i]
        if st and st.online then onlineCount = onlineCount + 1 end
        if st and st.coverConflict then
            conflictNames[#conflictNames + 1] = st.name or ("DTPF #" .. tostring(i))
        end
    end

    local maxOdW = 48
    local odStr, odCol
    if od.stalled then
        odStr = padOrTrunc(string.format("! OD STALLED: %s (Passives running)", tostring(od.summary or "Check NC")), maxOdW)
        odCol = COLORS.yellow
    elseif od.hasWork then
        local odIco = (animOn and tick > 0 and (tick % 2 == 0)) and "◈" or "⚡"
        odStr = padOrTrunc(string.format("%s OD CRAFT: %s [Cat:%s]",
            odIco,
            tostring(od.summary or ""),
            od.hasPatternedCatalyst and "YES" or "NO"), maxOdW)
        odCol = COLORS.purple
    else
        odStr = "ON-DEMAND: IDLE"
        odCol = COLORS.muted
    end
    local odX = math.max(96, self.w - unicode.wlen(odStr))
    self:drawText(odX, 2, odStr, odCol, COLORS.headerBg)
    self:addHitbox(odX, 2, self.w, 2, function() self.tab = TAB_SETUP end)

    local leftMsg
    if #self.cfg.channels > 1 then
        local runN, loopN, odN, idleN = 0, 0, 0, 0
        for i = 1, #self.cfg.dtpfs do
            local dst = self.state.dtpfStatus and self.state.dtpfStatus[i]
            local jm = dst and dst.jobMode
            if jm == "PASSIVE" then
                runN = runN + 1
            elseif jm == "FALLBACK" then
                loopN = loopN + 1
            elseif jm == "ON-DEMAND" then
                odN = odN + 1
            else
                idleN = idleN + 1
            end
        end
        leftMsg = string.format("%d/%d Online | Run:%d Loop:%d OD:%d Idle:%d",
            onlineCount, #self.cfg.dtpfs, runN, loopN, odN, idleN)
    else
        local ch1St = (self.cfg.channels[1] and self.state.channelStatus and self.state.channelStatus[self.cfg.channels[1].id]) or {}
        leftMsg = string.format("%d/%d Online | Ch1: %s",
            onlineCount, #self.cfg.dtpfs, tostring(ch1St.label or "Idle"))
    end
    self:drawText(63, 2, padOrTrunc(leftMsg, math.max(12, odX - 65)), armed and COLORS.green or COLORS.yellow, COLORS.headerBg)
    self:addHitbox(63, 2, math.max(63, odX - 2), 2, function() self.tab = TAB_FLEET end)

    -- Row 3 (Full Width): Alert / Paused Safety Notice OR Live Catalyst & DTR Reserve Bar (omitted on Overview & Setup)
    local floorsBtnW = 9
    local epWarnings = (self.discoveredEndpoints and self.discoveredEndpoints.warnings) or {}
    local showHeaderReserves = (#conflictNames > 0) or (#epWarnings > 0) or (not armed) or (self.tab ~= TAB_OVERVIEW and self.tab ~= TAB_SETUP)
    if #conflictNames > 0 then
        self:fillRect(1, 3, self.w, 1, " ", COLORS.darkRed)
        local msg = "! COVER OVERRIDE on " .. table.concat(conflictNames, ", ")
            .. " - Crowbar South Machine Controller Cover so OC can toggle Work."
        self:drawText(2, 3, padOrTrunc(msg, self.w - floorsBtnW - 4), COLORS.yellow, COLORS.darkRed)
    elseif #epWarnings > 0 then
        self:fillRect(1, 3, self.w, 1, " ", COLORS.darkRed)
        self:drawText(2, 3, padOrTrunc("! WIRING WARNING: " .. tostring(epWarnings[1]), self.w - floorsBtnW - 4), COLORS.yellow, COLORS.darkRed)
    elseif not armed then
        self:fillRect(1, 3, self.w, 1, " ", COLORS.amberBg)
        local msg = "PAUSED (SAFE PREVIEW): Live telemetry with ZERO hardware writes. Click [○ PAUSED] above to arm."
        self:drawText(2, 3, padOrTrunc(msg, self.w - floorsBtnW - 4), COLORS.yellow, COLORS.amberBg)
    elseif self.tab == TAB_OVERVIEW or self.tab == TAB_SETUP then
        self:fillRect(1, 3, self.w, 1, " ", COLORS.bg)
        self:drawText(1, 3, string.rep("─", self.w), COLORS.border, COLORS.bg)
    else
        self:fillRect(1, 3, self.w, 1, " ", COLORS.panelBg)
        self:drawText(2, 3, "◈ RESERVES", COLORS.accent, COLORS.panelBg)
        local fluids = (self.state and self.state.stock and self.state.stock.fluids) or {}
        local tickerParts = {}
        local totalTickerW = 0
        for i = 1, #RecipesDB.CATALYST_TIERS do
            local ct = RecipesDB.CATALYST_TIERS[i]
            local amt = fluids[ct.fluid] or 0
            local flr = (self.cfg.catalystFloors and self.cfg.catalystFloors[ct.code]) or 100000
            local gauge = getTankGaugeChar(amt, flr)
            local txt = string.format("%s%s:%s", gauge, ct.code, UI.formatNumber(amt, true))
            tickerParts[#tickerParts + 1] = {
                txt = txt,
                col = (amt == 0) and COLORS.red or ((amt > flr) and COLORS.green or COLORS.yellow),
            }
            totalTickerW = totalTickerW + unicode.wlen(txt) + 1
        end
        local dtrAmt = fluids["dimensionallytranscendentresidue"] or 0
        local dtrRate = self.state and self.state.dtrRatePerMin
        local dtrArrow = (dtrRate and dtrRate > 50 and "▲")
            or ((dtrRate and dtrRate < -50 and "▼") or "")
        local dtrTxt = "DTR:" .. UI.formatNumber(dtrAmt, true) .. dtrArrow
        if dtrRate and math.abs(dtrRate) >= 1 then
            local rateTag = string.format(" (%s%s/m)", (dtrRate >= 0) and "+" or "", fmtCompactNum(dtrRate, true))
            if 14 + totalTickerW + unicode.wlen(dtrTxt) + #rateTag + 2 <= self.w - floorsBtnW - 2 then
                dtrTxt = dtrTxt .. rateTag
            end
        end
        local dtrCol = (dtrAmt < (self.cfg.dtrReserveFloor or 0)) and COLORS.red
            or ((dtrArrow == "▼") and COLORS.yellow or COLORS.cyan)
        tickerParts[#tickerParts + 1] = {
            txt = "| " .. dtrTxt,
            col = dtrCol,
        }
        totalTickerW = totalTickerW + unicode.wlen(dtrTxt) + 2

        local cx = math.max(14, self.w - totalTickerW - floorsBtnW - 2)
        for i = 1, #tickerParts do
            local p = tickerParts[i]
            if cx + unicode.wlen(p.txt) <= self.w - floorsBtnW - 2 then
                self:drawText(cx, 3, p.txt, p.col, COLORS.panelBg)
                cx = cx + unicode.wlen(p.txt) + 1
            end
        end
    end

    if showHeaderReserves then
        self:drawButton(self.w - floorsBtnW - 1, 3, "[Floors…]", COLORS.cyan, COLORS.btnBg, function()
            self.tab = TAB_SETUP
        end)
    end
end

local function findModeIndex(list, val, defaultIdx)
    for i = 1, #list do
        if list[i].id == val then return i end
    end
    return defaultIdx or 1
end

local function effectiveGlobalConvShort(cfg)
    local g = cfg and cfg.globalConvMode or "auto"
    if g == "always" then return "ON" end
    if g == "off" or g == "ondemand" then return "OFF" end
    return "Auto"
end

local function getCoilColor(coilHeat)
    coilHeat = tonumber(coilHeat)
    if not coilHeat or coilHeat <= 0 then return COLORS.muted end
    if coilHeat >= 13500 then return COLORS.purple end
    if coilHeat >= 12600 then return COLORS.red end
    if coilHeat >= 11700 then return COLORS.fg end
    if coilHeat >= 10800 then return COLORS.yellow end
    return COLORS.cyan
end

local function countChannelShares(cfg, chId)
    local n = 0
    for i = 1, #(cfg.dtpfs or {}) do
        if (cfg.dtpfs[i].channelId or "ch1") == chId then
            n = n + 1
        end
    end
    return n
end

local function getDistinctTierCodes(fam)
    local mods = fam and fam.modifiers
    if not mods or #mods ~= 1 then return nil end
    local tiers = mods[1] and mods[1].tiers
    if not tiers then return nil end
    local list, sigs = {}, {}
    for idx = 1, #CATALYST_SHORT do
        local code = CATALYST_SHORT[idx]
        local td = tiers[code]
        if td then
            local parts = {}
            local itemsIn = td.itemsIn or {}
            for k = 1, #itemsIn do
                local ii = itemsIn[k]
                parts[#parts + 1] = tostring(ii.name) .. ":" .. tostring(ii.damage or 0)
            end
            table.sort(parts)
            sigs[table.concat(parts, ";")] = true
            list[#list + 1] = { idx = idx, code = code, td = td }
        end
    end
    local uniqSigs = 0
    for _ in pairs(sigs) do uniqSigs = uniqSigs + 1 end
    if #list >= 2 and uniqSigs >= 2 then
        return list
    end
    return nil
end

local function formatDtpfPassLabel(self, d, shortForm)
    local r = d.roleOverride or "auto"
    if r == "pinned" or r == "pinned_loop" then
        local fam = d.pinnedFamilyId and FAMILY_BY_ID[d.pinnedFamilyId]
        local nm = fam and fam.name or tostring(d.pinnedFamilyId or "?")
        if shortForm then
            return (r == "pinned_loop" and "*" or "◆") .. nm
        end
        return (r == "pinned_loop" and "* 24/7: " or "◆ ") .. nm
    elseif r == "passive_only" then
        return shortForm and "<Tgt" or "<Target Only"
    elseif r == "fallback_only" then
        return shortForm and "24/7" or "24/7 Only"
    elseif r == "od_only" then
        return shortForm and "OD" or "On-Demand Only"
    end
    return shortForm and "Queue" or "Auto Queue"
end

function UI:openPassiveModal(dtpfIdx, focusFamilyId)
    local d = self.cfg.dtpfs[dtpfIdx]
    if not d then return end
    self.promptActive = false
    self.promptCallback = nil
    self.selectedDtpf = dtpfIdx
    self.passiveModalActive = true
    self.passiveModalDtpfIdx = dtpfIdx
    self.passiveModalScroll = 0
    if focusFamilyId and self.cfg.recipes[focusFamilyId] then
        self.passiveModalFilter = "all"
        local targetPrio = self.cfg.recipes[focusFamilyId].priority or 999
        local rank = 1
        for i = 1, #RecipesDB.FAMILIES do
            local fid = RecipesDB.FAMILIES[i].id
            local pr = (self.cfg.recipes[fid] and self.cfg.recipes[fid].priority) or 999
            if pr < targetPrio then rank = rank + 1 end
        end
        self.passiveModalScroll = math.max(0, rank - 12)
    end
end

local function cycleChannelForDtpf(self, d, step, unitName)
    local nCh = #self.cfg.channels
    if nCh == 0 then return end
    local cur = 1
    for k = 1, nCh do
        if self.cfg.channels[k].id == d.channelId then cur = k break end
    end
    local nxt = ((cur - 1 + (step or 1)) % nCh) + 1
    d.channelId = self.cfg.channels[nxt].id
    self:save(unitName .. " Channel -> " .. d.channelId)
end

local function applyOneLoopRestQueue(self, keepIdx)
    local dKeep = self.cfg.dtpfs[keepIdx]
    if not dKeep then return end
    for k = 1, #self.cfg.dtpfs do
        local dt = self.cfg.dtpfs[k]
        if k == keepIdx then
            dt.roleOverride = "auto"
            dt.pinnedFamilyId = nil
        elseif dt.roleOverride ~= "od_only" then
            dt.roleOverride = "passive_only"
            dt.pinnedFamilyId = nil
        end
    end
    local unitName = dKeep.name or ("DTPF #" .. keepIdx)
    self:save("Fleet preset: " .. unitName .. " = Auto (Loop), others = Queue Only.")
end

local function openRecipeOrPassiveModal(self, slot, d, st, unitName, button)
    self.selectedDtpf = slot.index
    local jumpFamId = (st and st.familyId) or d.pinnedFamilyId
        or ((st and st.jobMode == "FALLBACK") and (self.cfg.fallbackFamilyId or "molten_infinity"))
        or nil
    if button ~= 1 and jumpFamId and FAMILY_BY_ID[jumpFamId] then
        self.selectedFamilyId = jumpFamId
        self.tab = TAB_RECIPES
        self.statusMsg = "Inspecting " .. (FAMILY_BY_ID[jumpFamId].name or jumpFamId) .. " (from " .. unitName .. ")."
    else
        self:openPassiveModal(slot.index)
    end
end

local function getRecipeCoilHeat(self, fam, rc)
    local st = self.state and self.state.recipeStatus and self.state.recipeStatus[fam.id]
    if st and st.tierData and st.tierData.coilHeat then
        return st.tierData.coilHeat
    end
    local _, _, _, tData = Scheduler.resolveRecipe(fam, rc, self.cfg, self.state and self.state.stock, { wantConvergence = false })
    return tData and tData.coilHeat or nil
end

local function buildDtpfActions(self, slot, d, unitName)
    local function cycleConv(step)
        step = step or 1
        self.selectedDtpf = slot.index
        local idx = findModeIndex(DTPF_CONV_MODES, d.convOverride or "global", 1)
        local nxt = DTPF_CONV_MODES[((idx - 1 + step) % #DTPF_CONV_MODES) + 1]
        d.convOverride = nxt.id
        self:save(unitName .. " Convergence -> " .. nxt.label)
    end

    local function cycleCat(step)
        step = step or 1
        self.selectedDtpf = slot.index
        local cur = d.catOverride or 0
        d.catOverride = (cur + step) % 6
        local lbl = (d.catOverride == 0) and "GLOBAL" or (CATALYST_SHORT[d.catOverride] or "DTEC")
        self:save(unitName .. " Catalyst -> " .. lbl)
    end

    local function cycleRoleQuick(step)
        step = step or 1
        self.selectedDtpf = slot.index
        local curRole = d.roleOverride or "auto"
        local nxt
        if curRole == "pinned" or curRole == "pinned_loop" then
            nxt = ROLE_MODES[1]
        else
            local idx = findModeIndex(ROLE_MODES, curRole, 1)
            nxt = ROLE_MODES[((idx - 1 + step) % #ROLE_MODES) + 1]
        end
        d.roleOverride = nxt.id
        d.pinnedFamilyId = nil
        self:save(unitName .. " Passive -> " .. nxt.label)
    end

    local function openPassOrQuick(step, button)
        self.selectedDtpf = slot.index
        if button == 1 then
            cycleRoleQuick(step)
        else
            self:openPassiveModal(slot.index)
        end
    end

    local function cycleChannel(step)
        self.selectedDtpf = slot.index
        cycleChannelForDtpf(self, d, step, unitName)
    end

    local function resetDtpf()
        self.selectedDtpf = slot.index
        d.enabled = true
        d.convOverride = "global"
        d.catOverride = 0
        d.roleOverride = "auto"
        d.pinnedFamilyId = nil
        self:save(unitName .. " reset to Global defaults.")
    end

    return {
        cycleConv = cycleConv,
        cycleCat = cycleCat,
        cycleRoleQuick = cycleRoleQuick,
        openPassOrQuick = openPassOrQuick,
        cycleChannel = cycleChannel,
        resetDtpf = resetDtpf,
    }
end

function UI:drawDTPFSquare(bx, by, bw, bh, slot, d, st, isSelected)
    local isOnline = st and st.online
    local hasCover = st and st.coverConflict or false
    local isPreview = (not self.cfg.armed)

    local modeCol = COLORS.yellow
    local borderCol = isSelected and COLORS.accent or COLORS.border
    if not isOnline or d.enabled == false or hasCover then
        modeCol = hasCover and COLORS.yellow or COLORS.red
        borderCol = COLORS.red
    elseif st and st.passiveStalled then
        modeCol = COLORS.yellow
        borderCol = COLORS.yellow
    elseif st and st.jobMode == "ON-DEMAND" then
        modeCol = COLORS.purple
        borderCol = COLORS.purple
    elseif st and st.active and st.jobMode == "FALLBACK" then
        modeCol = COLORS.cyan
        borderCol = COLORS.cyan
    elseif st and st.active then
        modeCol = COLORS.green
        borderCol = COLORS.green
    end

    local cardBg = isSelected and COLORS.selectedBg or COLORS.panelBg
    self:drawFrame(bx, by, bw, bh, borderCol, cardBg, isSelected and "double" or "round")

    -- Register background card selection BEFORE inner buttons so reverse hit-testing hits inner buttons first.
    self:addHitbox(bx, by, bx + bw - 1, by + bh - 1, function()
        self.selectedDtpf = slot.index
    end)

    local curRole = d.roleOverride or "auto"
    local passIsCustom = (curRole ~= "auto")
    local isCustomLocal = (d.enabled == false)
        or ((d.convOverride or "global") ~= "global")
        or ((d.catOverride or 0) ~= 0)
        or passIsCustom
    local chId = d.channelId or "ch1"
    local jumpFamId = (st and st.familyId) or d.pinnedFamilyId
        or ((st and st.jobMode == "FALLBACK") and (self.cfg.fallbackFamilyId or "molten_infinity"))
        or nil

    local cx = bx + 2
    local innerW = bw - 4
    local unitName = d.name or ("DTPF #" .. slot.index)

    -- Row by (Top Border): Renameable [DTPF #N…] + optional Hatch rating + [W] + (x,z) coordinates
    local coordStr = (innerW >= 22 and slot.x and slot.z) and string.format("(%d,%d)", slot.x, slot.z) or ""
    local hatchAmps = st and tonumber(st.hatchAmps)
    local hatchTier = st and st.hatchTier
    local hatchShort = ""
    if innerW >= 30 and hatchAmps and hatchTier and hatchAmps > 0 then
        local aS = (hatchAmps >= 1000) and (tostring(math.floor(hatchAmps / 1000)) .. "K") or tostring(math.floor(hatchAmps))
        hatchShort = aS .. "A·" .. tostring(hatchTier)
    end
    local remoteW = (d.isRemote and bw >= 16) and 4 or 0
    if #coordStr > 0 then
        self:drawText(bx + bw - 2 - unicode.wlen(coordStr), by, coordStr, COLORS.muted, cardBg)
    end
    if #hatchShort > 0 then
        local hxPos = bx + bw - 2 - (#coordStr > 0 and (unicode.wlen(coordStr) + 1) or 0) - unicode.wlen(hatchShort)
        self:drawText(hxPos, by, hatchShort, COLORS.cyan, cardBg)
    end
    if remoteW > 0 then
        local wx = bx + bw - 2 - (#coordStr > 0 and (unicode.wlen(coordStr) + 1) or 0) - (#hatchShort > 0 and (unicode.wlen(hatchShort) + 1) or 0) - 3
        self:drawText(wx, by, "[W]", COLORS.purple, cardBg)
    end
    local rightUsed = (#coordStr > 0 and (unicode.wlen(coordStr) + 1) or 0) + (#hatchShort > 0 and (unicode.wlen(hatchShort) + 1) or 0) + remoteW
    local nameBudget = math.max(6, bw - 4 - rightUsed)
    local suffix = (innerW >= 22) and "…" or ""
    local dispName = padOrTrunc(unitName, math.max(3, nameBudget - 2 - unicode.wlen(suffix)))
    -- Trim trailing padding spaces inside bracketed name chip
    dispName = dispName:gsub("%s+$", "")
    self:drawButton(cx, by, "[" .. dispName .. suffix .. "]", isSelected and COLORS.cyan or COLORS.fg, COLORS.btnBg, function()
        self.selectedDtpf = slot.index
        self:openPrompt("Rename DTPF #" .. slot.index .. ":", unitName,
            "Enter short name and press [Enter] or click [ APPLY ].", function(val)
                local trimmed = val:gsub("^%s+", ""):gsub("%s+$", "")
                if #trimmed > 0 then
                    d.name = trimmed
                    self:save("Renamed DTPF #" .. slot.index .. " to " .. trimmed)
                end
            end)
    end)

    local act = buildDtpfActions(self, slot, d, unitName)
    local convNow = isOnline and ((self.cfg.armed and (st.convergenceEnabled == true)) or ((not self.cfg.armed) and (st.wantConv == true))) or false
    local convSuffix = convNow and " ⚡CONV" or ""
    local coilCol = getCoilColor(st and st.coilHeat)

    local animActiveNow = self:isAnimEnabled() and (self.cfg.armed == true) and ((self.animTick or 0) > 0)
    local animTick = self.animTick or 0
    local curProg, curMaxProg = getEffectiveProgress(self, st)

    local stateStr, stCol
    if not isOnline then
        stateStr, stCol = "○ OFFLINE", COLORS.red
    elseif hasCover then
        stateStr, stCol = "! COVER!", COLORS.yellow
    elseif d.enabled == false then
        stateStr, stCol = "■ DISABLED", COLORS.red
    elseif st and st.passiveStalled then
        stateStr, stCol = "! STALLED ◇", COLORS.yellow
    elseif st and st.jobMode == "ON-DEMAND" then
        stateStr, stCol = (st.active and "⚡ OD" or "⚡ RDY") .. convSuffix, COLORS.purple
    elseif st and st.active and st.jobMode == "FALLBACK" then
        stateStr, stCol = (animActiveNow and ANIM_SPIN4[((animTick - 1) % 4) + 1] or "●") .. " LOOP" .. convSuffix, COLORS.cyan
    elseif st and st.active then
        stateStr, stCol = (animActiveNow and ANIM_SPIN4[((animTick - 1) % 4) + 1] or "●") .. " RUN" .. convSuffix, COLORS.green
    elseif st and (st.jobMode == "PASSIVE" or st.jobMode == "FALLBACK") then
        stateStr, stCol = (isPreview and "◇ PRV" or "○ WAIT") .. convSuffix, isPreview and COLORS.yellow or modeCol
    else
        stateStr, stCol = "○ IDLE" .. convSuffix, COLORS.yellow
    end

    local rightTxt = ""
    if hasCover then
        rightTxt = "Crowbar S!"
    elseif curMaxProg > 0 then
        local pr = math.floor(curProg / 20)
        local mp = math.max(1, math.floor(curMaxProg / 20))
        local pct = math.min(100, math.floor((curProg / curMaxProg) * 100 + 0.5))
        rightTxt = string.format("%d/%ds %d%%", pr, mp, pct)
    end

    -- Row +1: Power toggle + Run state + Timer / Percentage
    local pwrLabel = (innerW >= 22)
        and ((d.enabled ~= false) and "[● ON ]" or "[○ OFF]")
        or ((d.enabled ~= false) and "[ON]" or "[OF]")
    local pwrFg = (d.enabled ~= false) and COLORS.green or COLORS.red
    local pwrBg = (d.enabled ~= false) and COLORS.darkGreen or COLORS.darkRed
    local hx = self:drawButton(cx, by + 1, pwrLabel, pwrFg, pwrBg, function()
        self.selectedDtpf = slot.index
        d.enabled = not (d.enabled ~= false)
        self:save(string.format("%s Work -> %s", unitName, d.enabled and "ON" or "OFF"))
    end) + 1

    if #rightTxt > 0 then
        self:drawText(bx + bw - 2 - unicode.wlen(rightTxt), by + 1, rightTxt, hasCover and COLORS.yellow or COLORS.muted, cardBg)
    end
    local availStateW = math.max(4, (bx + bw - 2 - (#rightTxt > 0 and (unicode.wlen(rightTxt) + 1) or 0)) - hx)
    self:drawText(hx, by + 1, padOrTrunc(stateStr, availStateW), stCol, cardBg)

    local twPre = (innerW >= 30 and bh >= 10) and (innerW - 8) or innerW
    local maxChipW = math.max(3, twPre - 2)
    local rawJob = tostring((st and st.jobLabel) or "All Targets Full")
    local function fitJob(prefix, txt)
        local s = prefix .. txt
        if unicode.wlen(s) <= maxChipW then return s end
        return prefix .. compactRecipeName(txt, math.max(3, maxChipW - unicode.wlen(prefix)))
    end
    local jobStr = rawJob
    local jobCol = COLORS.fg
    if hasCover or d.enabled == false then
        jobStr = fitJob("", rawJob)
        jobCol = COLORS.yellow
    elseif st and st.jobMode == "ON-DEMAND" then
        jobStr = fitJob("⚡ ", rawJob)
        jobCol = COLORS.purple
    elseif st and st.jobMode == "FALLBACK" then
        local clean = rawJob:gsub("^%*%s+", "")
        jobStr = fitJob(isPreview and "Preview: * " or "* ", clean)
        jobCol = isPreview and COLORS.yellow or COLORS.cyan
    elseif st and st.jobMode == "PASSIVE" then
        jobStr = fitJob(isPreview and "Preview: " or "▸ ", rawJob)
        jobCol = isPreview and COLORS.yellow or COLORS.green
    else
        jobStr = fitJob("", rawJob)
        jobCol = COLORS.muted
    end

    -- Draw miniature DTPF multiblock sprite (pure telemetry status visualization; no hidden hitbox)
    local tx, tw = cx, innerW
    if innerW >= 30 and bh >= 10 then
        local casingCol = (not isOnline or d.enabled == false) and COLORS.red or COLORS.muted
        local ctrlCol = (hasCover and COLORS.yellow) or ((isOnline and d.enabled ~= false) and COLORS.green or COLORS.red)
        local coreStr, coreCol = " ○ ", COLORS.muted
        local glowStr, glowCol = " · ", COLORS.muted
        if hasCover then
            coreStr, coreCol = "!✗!", COLORS.yellow
            glowStr, glowCol = " ! ", COLORS.yellow
        elseif not isOnline or d.enabled == false then
            coreStr, coreCol = " ✗ ", COLORS.red
            glowStr, glowCol = " · ", COLORS.red
        elseif convNow and st and (st.active or st.jobMode == "ON-DEMAND") then
            if animActiveNow then
                local cf = CONV_SPRITE_FRAMES[((animTick - 1) % 4) + 1]
                coreStr, glowStr = cf[1], cf[2]
            else
                coreStr, glowStr = "⚡◈⚡", "◈◉◈"
            end
            coreCol, glowCol = COLORS.purple, modeCol
        elseif convNow then
            coreStr, coreCol = " ⚡ ", COLORS.purple
            glowStr, glowCol = " ◌ ", COLORS.muted
        elseif st and st.active then
            if animActiveNow then
                coreStr = "‹" .. ANIM_SPIN4[((animTick - 1) % 4) + 1] .. "›"
                glowStr = (animTick % 2 == 0) and "‹◉›" or "‹◎›"
            else
                coreStr, glowStr = "‹●›", "‹◎›"
            end
            coreCol, glowCol = modeCol, modeCol
        end

        self:drawText(cx, by + 2, "╭", casingCol, cardBg)
        self:drawText(cx + 1, by + 2, "≡", coilCol, cardBg)
        self:drawText(cx + 2, by + 2, "─▄─", casingCol, cardBg)
        self:drawText(cx + 5, by + 2, "≡", coilCol, cardBg)
        self:drawText(cx + 6, by + 2, "╮", casingCol, cardBg)

        self:drawText(cx, by + 3, "│", casingCol, cardBg)
        self:drawText(cx + 1, by + 3, "≡", coilCol, cardBg)
        self:drawText(cx + 2, by + 3, coreStr, coreCol, cardBg)
        self:drawText(cx + 5, by + 3, "≡", coilCol, cardBg)
        self:drawText(cx + 6, by + 3, "│", casingCol, cardBg)

        self:drawText(cx, by + 4, "│", casingCol, cardBg)
        self:drawText(cx + 1, by + 4, "≡", coilCol, cardBg)
        self:drawText(cx + 2, by + 4, glowStr, glowCol, cardBg)
        self:drawText(cx + 5, by + 4, "≡", coilCol, cardBg)
        self:drawText(cx + 6, by + 4, "│", casingCol, cardBg)

        self:drawText(cx, by + 5, "╰═─", casingCol, cardBg)
        self:drawText(cx + 3, by + 5, "■", ctrlCol, cardBg)
        self:drawText(cx + 4, by + 5, "─═╯", casingCol, cardBg)

        tx = cx + 8
        tw = innerW - 8
    end

    -- Row +2: Smooth Block Progress Bar (or compact coil badge + progress bar when narrow)
    if tx == cx then
        local activeBadge = (animActiveNow and st and st.active) and ANIM_SPIN4[((animTick - 1) % 4) + 1] or "●"
        local convBadge = (animActiveNow and st and (st.active or st.jobMode == "ON-DEMAND") and (animTick % 2 == 0)) and "◈" or "⚡"
        local badgeCore = hasCover and "!" or (convNow and convBadge or ((st and st.active) and activeBadge or "◇"))
        local badgeCol = hasCover and COLORS.yellow or (convNow and COLORS.purple or ((st and st.active) and modeCol or COLORS.muted))
        self:drawText(cx, by + 2, "≡", coilCol, cardBg)
        self:drawText(cx + 1, by + 2, badgeCore, badgeCol, cardBg)
        self:drawText(cx + 2, by + 2, "≡", coilCol, cardBg)
        local barW = math.max(4, innerW - 6)
        local ratio = (curMaxProg > 0) and math.min(1, curProg / curMaxProg) or 0
        local barCol = (st and (st.active or st.jobMode == "ON-DEMAND")) and modeCol or COLORS.muted
        self:drawText(cx + 4, by + 2, padOrTrunc(buildProgressBar(ratio, barW), innerW - 4), barCol, cardBg)
    else
        local barInnerW = math.max(4, tw - 2)
        local ratio = (curMaxProg > 0) and math.min(1, curProg / curMaxProg) or 0
        local barStr = buildProgressBar(ratio, barInnerW)
        local barCol = (st and (st.active or st.jobMode == "ON-DEMAND")) and modeCol or COLORS.muted
        self:drawText(tx, by + 2, padOrTrunc(barStr, tw), barCol, cardBg)
    end

    -- Row +3: Active Recipe / Job Chip on btnBg (L-click=Inspector, R-click=Pin/Mode Modal)
    local chipText = "[" .. padOrTrunc(jobStr, math.max(3, tw - 2)) .. "]"
    self:drawButton(tx, by + 3, chipText, jobCol, COLORS.btnBg, function(_, button)
        openRecipeOrPassiveModal(self, slot, d, st, unitName, button)
    end)

    -- Row +4: Clean stock context + rate/ETA + live EU/t draw
    local recSt = jumpFamId and self.state and self.state.recipeStatus and self.state.recipeStatus[jumpFamId]
    local recCfg = jumpFamId and self.cfg.recipes and self.cfg.recipes[jumpFamId]
    local ctxText, ctxCol = "Idle · Queue Standby", COLORS.muted
    if d.enabled == false then
        ctxText = "Disabled · Work OFF"
        ctxCol = COLORS.red
    elseif hasCover then
        ctxText = "! Crowbar South Cover"
        ctxCol = COLORS.yellow
    elseif st and st.passiveStalled then
        ctxText = "! Check Circuit/NC/Hatch"
        ctxCol = COLORS.yellow
    elseif st and (st.jobMode == "PASSIVE" or (curRole == "pinned" and st.jobMode == "IDLE")) and recSt and recCfg then
        local isFl = recSt.trackedOutput and (recSt.trackedOutput.isFluid or recSt.trackedOutput.type == "fluid")
        local pct = math.min(999, math.floor((recSt.ratio or 0) * 100 + 0.5))
        local etaStr = UI.formatDurationShort(recSt.etaSec)
        local rateStr = (recSt.ratePerMin and math.abs(recSt.ratePerMin) >= 1)
            and ((recSt.ratePerMin >= 0 and "+" or "") .. fmtCompactNum(recSt.ratePerMin, isFl) .. "/m")
            or nil
        if tw >= 24 and etaStr then
            ctxText = string.format("Stk %s/%s ~%s",
                fmtCompactNum(recSt.currentStock or 0, isFl),
                fmtCompactNum(recCfg.target or 1, isFl),
                etaStr)
        elseif tw >= 25 and rateStr then
            ctxText = string.format("Stk %s/%s %s",
                fmtCompactNum(recSt.currentStock or 0, isFl),
                fmtCompactNum(recCfg.target or 1, isFl),
                rateStr)
        else
            ctxText = string.format("Stk %s/%s (%d%%)",
                fmtCompactNum(recSt.currentStock or 0, isFl),
                fmtCompactNum(recCfg.target or 1, isFl),
                pct)
        end
        ctxCol = getStockRatioColor(recSt.ratio or 0, true)
    elseif st and (st.jobMode == "FALLBACK" or curRole == "pinned_loop") and recSt then
        local isFl = recSt.trackedOutput and (recSt.trackedOutput.isFluid or recSt.trackedOutput.type == "fluid")
        if tw >= 21 and recSt.ratePerMin and math.abs(recSt.ratePerMin) >= 1 and (tonumber(st.directEut) or 0) <= 0 then
            ctxText = string.format("Loop:%s %s%s/m",
                fmtCompactNum(recSt.currentStock or 0, isFl),
                (recSt.ratePerMin >= 0) and "+" or "",
                fmtCompactNum(recSt.ratePerMin, isFl))
        else
            ctxText = string.format("Loop Stk:%s", fmtCompactNum(recSt.currentStock or 0, isFl))
        end
        ctxCol = COLORS.cyan
    elseif curRole == "od_only" and (not st or st.jobMode ~= "ON-DEMAND") then
        ctxText = "Standing By for OD"
        ctxCol = COLORS.purple
    elseif curRole == "passive_only" and st and st.jobMode == "IDLE" then
        ctxText = "Sleeping (Targets Met)"
        ctxCol = COLORS.muted
    elseif st and st.jobMode == "ON-DEMAND" then
        ctxText = "AE2 Auto-Craft"
        ctxCol = COLORS.purple
    end
    local dEut = (st and tonumber(st.directEut)) or 0
    if d.enabled ~= false and not hasCover and not (st and st.passiveStalled) and dEut > 0 then
        local eutTxt = (st and st.eutIsEstimate and "~" or "") .. fmtCompactNum(dEut, false) .. "/t"
        local eutCol = (not convNow and dEut >= 1e12) and COLORS.yellow or (convNow and COLORS.purple or COLORS.fg)
        local eutW = unicode.wlen(eutTxt)
        if tw > eutW + 6 then
            self:drawText(tx, by + 4, padOrTrunc(ctxText, tw - eutW - 1), ctxCol, cardBg)
            self:drawText(tx + tw - eutW, by + 4, eutTxt, eutCol, cardBg)
        else
            self:drawText(tx, by + 4, padOrTrunc(ctxText, tw), ctxCol, cardBg)
        end
    else
        self:drawText(tx, by + 4, padOrTrunc(ctxText, tw), ctxCol, cardBg)
    end

    -- Row +5: Discount (+ Warmup ETA) + Clickable Coil Tier/Heat (or Cover/Disabled Hint)
    if d.enabled == false then
        if st and st.coilHeat then
            local _, _, tierName = getCoilTierInfo(st.coilHeat)
            local coilVal = self:isCoilNameMode() and tierName or (formatInt(st.coilHeat) .. "K")
            local heatStr = "Coil:" .. coilVal
            local showW = math.min(tw, unicode.wlen(heatStr))
            self:drawText(tx, by + 5, padOrTrunc(heatStr, tw), COLORS.muted, cardBg)
            self:addHitbox(tx, by + 5, tx + showW - 1, by + 5, function()
                self:toggleCoilDisplay()
            end)
        else
            self:drawText(tx, by + 5, padOrTrunc("Click [OFF] to enable", tw), COLORS.muted, cardBg)
        end
    elseif hasCover then
        self:drawText(tx, by + 5, padOrTrunc("! Remove South GT Cover !", tw), COLORS.yellow, cardBg)
    else
        local discVal = (st and tonumber(st.discountPct)) or 0
        local discCol = (discVal >= 49.9) and COLORS.green or COLORS.yellow
        local warmStr = (discVal < 49.9 and st and st.active and st.warmupEtaSec) and UI.formatDurationShort(st.warmupEtaSec) or nil
        local discLbl
        if warmStr and tw >= 22 then
            discLbl = string.format("Disc:%.0f%% (%s)", discVal, warmStr)
        elseif warmStr then
            discLbl = string.format("D:%.0f%% (%s)", discVal, warmStr)
        else
            discLbl = (tw >= 20) and string.format("Disc:%.0f%%", discVal) or string.format("D:%.0f%%", discVal)
        end
        local useShortCoil = (tw < 20) or (warmStr ~= nil)
        self:drawText(tx, by + 5, discLbl, discCol, cardBg)

        local avail = tw - unicode.wlen(discLbl)
        local cands
        if not (st and st.coilHeat) then
            cands = { "  Coil:?", " C:?", " ?" }
        elseif self:isCoilNameMode() then
            local _, _, tierName, shortName = getCoilTierInfo(st.coilHeat)
            if not useShortCoil then
                cands = { "  Coil:" .. tierName, " Coil:" .. tierName, " C:" .. tierName, " " .. tierName, " " .. shortName }
            else
                cands = { " C:" .. tierName, "  " .. tierName, " " .. tierName, " C:" .. shortName, " " .. shortName }
            end
        else
            local fullK = formatInt(st.coilHeat) .. "K"
            local shortK = string.format("%.1fkK", st.coilHeat / 1000)
            if not useShortCoil then
                cands = { "  Coil:" .. fullK, " Coil:" .. fullK, " C:" .. shortK, " " .. shortK }
            else
                cands = { " C:" .. shortK, " " .. shortK }
            end
        end
        local coilTxt
        for _, cand in ipairs(cands) do
            if unicode.wlen(cand) <= avail then
                coilTxt = cand
                break
            end
        end
        if coilTxt then
            local coilX = tx + unicode.wlen(discLbl)
            self:drawText(coilX, by + 5, coilTxt, coilCol, cardBg)
            local leadSpaces = #(coilTxt:match("^%s*") or "")
            self:addHitbox(coilX + leadSpaces, by + 5, coilX + unicode.wlen(coilTxt) - 1, by + 5, function()
                self:toggleCoilDisplay()
            end)
        end
    end

    local hasNonPowerOverride = passIsCustom or ((d.convOverride or "global") ~= "global") or ((d.catOverride or 0) ~= 0)
    if d.enabled == false then
        if hasNonPowerOverride then
            if bh >= 10 then
                self:drawText(cx, by + 6, string.rep("─", innerW), COLORS.border, cardBg)
            end
            local cyBase = (bh >= 10) and (by + 7) or (by + 6)
            self:drawButton(cx, cyBase, "[↺ Reset Overrides]", COLORS.yellow, COLORS.amberBg, act.resetDtpf)
        end
        return
    end

    if bh >= 10 then
        self:drawText(cx, by + 6, string.rep("─", innerW), COLORS.border, cardBg)
    end

    -- Streamlined 2-Row Per-DTPF Control Strip (Mode + 4x / Cat / Shared Channel)
    local cyBase = (bh >= 10) and (by + 7) or (by + 6)
    local convIsGlobal = ((d.convOverride or "global") == "global")
    local convModeObj = DTPF_CONV_MODES[findModeIndex(DTPF_CONV_MODES, d.convOverride or "global", 1)]
    local catIsGlobal = ((d.catOverride or 0) == 0)
    local globalCatCode = CATALYST_SHORT[self.cfg.defaultCatalystTier or 4] or "DTEC"
    local chStLive = self.state and self.state.channelStatus and self.state.channelStatus[chId]
    local chShareCount = countChannelShares(self.cfg, chId)

    if innerW >= 30 then
        local resetReserve = isCustomLocal and 4 or 0
        local modeW = innerW - 6 - resetReserve
        local passText = formatDtpfPassLabel(self, d, false)
        local passFg = (curRole == "pinned" or curRole == "pinned_loop") and COLORS.cyan
            or ((curRole == "od_only") and COLORS.purple or COLORS.fg)
        local passBg = passIsCustom and COLORS.btnActiveBg or COLORS.btnBg

        self:drawText(cx, cyBase, "Mode:", COLORS.muted, cardBg)
        self:drawButton(cx + 6, cyBase, "[" .. padOrTrunc(passText, modeW - 2) .. "]",
            passFg, passBg, act.openPassOrQuick)
        if isCustomLocal then
            self:drawButton(bx + bw - 5, cyBase, "[↺]", COLORS.yellow, COLORS.amberBg, act.resetDtpf)
        end

        -- Row cyBase + 1: Conv:[...] Cat:[...] + shared [CHn xN] only when shared
        local convCtrlOk = self:isConvControlSupported()
        local effConv = effectiveGlobalConvShort(self.cfg)
        local convLabel = convCtrlOk and (convIsGlobal and effConv or convModeObj.short) or "Manual"
        local convFg = (not convCtrlOk) and COLORS.yellow
            or (convIsGlobal and COLORS.muted or ((d.convOverride == "off") and COLORS.yellow or COLORS.fg))
        local convBg = (not convCtrlOk) and COLORS.btnBg
            or (convIsGlobal and COLORS.btnBg or ((d.convOverride == "off") and COLORS.amberBg or COLORS.btnActiveBg))
        local catLabel, catCol, catBg
        if not catIsGlobal then
            catLabel = CATALYST_SHORT[d.catOverride] or "DTEC"
            catCol, catBg = COLORS.fg, COLORS.btnActiveBg
        elseif chStLive and (chStLive.mode == "PASSIVE" or chStLive.mode == "FALLBACK")
            and chStLive.tierCode and chStLive.tierCode ~= globalCatCode then
            catLabel = "→" .. chStLive.tierCode
            catCol, catBg = COLORS.yellow, COLORS.btnBg
        else
            catLabel = globalCatCode
            catCol, catBg = COLORS.muted, COLORS.btnBg
        end

        self:drawText(cx, cyBase + 1, "Conv:", COLORS.muted, cardBg)
        local x4 = self:drawButton(cx + 5, cyBase + 1, "[" .. convLabel .. "]",
            convFg, convBg,
            function(step)
                if not convCtrlOk then
                    self:setStatus(NO_CONV_PATCH_MSG)
                else
                    act.cycleConv(step)
                end
            end) + 2
        self:drawText(x4, cyBase + 1, "Cat:", COLORS.muted, cardBg)
        local xCatEnd = self:drawButton(x4 + 4, cyBase + 1, "[" .. catLabel .. "]",
            catCol, catBg,
            function(step) act.cycleCat(step) end)

        if #self.cfg.channels > 1 and chShareCount > 1 then
            local chTag = string.format("[%s x%d]", chId:upper(), chShareCount)
            local chX = math.max(xCatEnd + 1, bx + bw - 2 - unicode.wlen(chTag))
            if chX + unicode.wlen(chTag) <= bx + bw - 2 then
                self:drawButton(chX, cyBase + 1, chTag, COLORS.yellow, COLORS.btnBg, act.cycleChannel)
            end
        end
    else
        local passPrefix = (innerW >= 20) and "Md:" or "M:"
        local resetReserve = isCustomLocal and 4 or 0
        local maxPassW = math.max(4, innerW - unicode.wlen(passPrefix) - resetReserve - 2)
        local passFg = (curRole == "pinned" or curRole == "pinned_loop") and COLORS.cyan
            or ((curRole == "od_only") and COLORS.purple or COLORS.fg)
        self:drawText(cx, cyBase, passPrefix, COLORS.muted, cardBg)
        self:drawButton(cx + unicode.wlen(passPrefix), cyBase,
            "[" .. padOrTrunc(formatDtpfPassLabel(self, d, true), maxPassW) .. "]",
            passFg, passIsCustom and COLORS.btnActiveBg or COLORS.btnBg, act.openPassOrQuick)
        if isCustomLocal then
            self:drawButton(bx + bw - 5, cyBase, "[↺]", COLORS.yellow, COLORS.amberBg, act.resetDtpf)
        end

        local convCtrlOk = self:isConvControlSupported()
        local effConv = effectiveGlobalConvShort(self.cfg)
        local convShort = convCtrlOk and (convIsGlobal and effConv or convModeObj.short) or "Manual"
        local catShort = catIsGlobal and globalCatCode or (CATALYST_SHORT[d.catOverride] or "DTEC")
        self:drawText(cx, cyBase + 1, "Cv:", COLORS.muted, cardBg)
        local rx = self:drawButton(cx + 3, cyBase + 1, convCtrlOk and ("[" .. convShort .. "]") or convShort,
            (not convCtrlOk) and COLORS.yellow or (convIsGlobal and COLORS.muted or COLORS.fg),
            (not convCtrlOk or convIsGlobal) and COLORS.btnBg or COLORS.btnActiveBg,
            function(step)
                if not convCtrlOk then
                    self:setStatus(NO_CONV_PATCH_MSG)
                else
                    act.cycleConv(step)
                end
            end) + 1
        self:drawText(rx, cyBase + 1, "Ct:", COLORS.muted, cardBg)
        rx = self:drawButton(rx + 3, cyBase + 1, "[" .. catShort .. "]",
            catIsGlobal and COLORS.muted or COLORS.fg, catIsGlobal and COLORS.btnBg or COLORS.btnActiveBg,
            function(step) act.cycleCat(step) end) + 1
        if #self.cfg.channels > 1 and chShareCount > 1 and rx + #chId + 2 <= bx + bw - 2 then
            self:drawButton(rx, cyBase + 1, "[" .. chId .. "]", COLORS.yellow, COLORS.btnBg, act.cycleChannel)
        end
    end
end

function UI:drawCompactDTPFSquare(bx, by, bw, bh, slot, d, st, isSelected)
    local isOnline = st and st.online
    local hasCover = st and st.coverConflict or false
    local modeCol = COLORS.yellow
    local borderCol = isSelected and COLORS.accent or COLORS.border
    if not isOnline or d.enabled == false or hasCover then
        modeCol = hasCover and COLORS.yellow or COLORS.red
        borderCol = COLORS.red
    elseif st and st.passiveStalled then
        modeCol = COLORS.yellow
        borderCol = COLORS.yellow
    elseif st and st.jobMode == "ON-DEMAND" then
        modeCol = COLORS.purple
        borderCol = COLORS.purple
    elseif st and st.active and st.jobMode == "FALLBACK" then
        modeCol = COLORS.cyan
        borderCol = COLORS.cyan
    elseif st and st.active then
        modeCol = COLORS.green
        borderCol = COLORS.green
    end

    local cardBg = isSelected and COLORS.selectedBg or COLORS.panelBg
    self:drawFrame(bx, by, bw, bh, borderCol, cardBg, isSelected and "double" or "round")
    self:addHitbox(bx, by, bx + bw - 1, by + bh - 1, function()
        self.selectedDtpf = slot.index
    end)

    local cx = bx + 2
    local innerW = bw - 4
    local unitName = d.name or ("DTPF #" .. slot.index)
    local act = buildDtpfActions(self, slot, d, unitName)
    local convNow = isOnline and ((self.cfg.armed and (st.convergenceEnabled == true)) or ((not self.cfg.armed) and (st.wantConv == true))) or false
    local coilCol = getCoilColor(st and st.coilHeat)

    -- Row +1: [ON] [Name] [CH#] (x,z)
    local hx = self:drawButton(cx, by + 1, (d.enabled ~= false) and "[ON]" or "[OF]",
        (d.enabled ~= false) and COLORS.green or COLORS.red,
        (d.enabled ~= false) and COLORS.darkGreen or COLORS.darkRed,
        function()
            self.selectedDtpf = slot.index
            d.enabled = not (d.enabled ~= false)
            self:save(string.format("%s Work -> %s", unitName, d.enabled and "ON" or "OFF"))
        end) + 1

    local coordStr = (slot.x and slot.z) and string.format("(%d,%d)", slot.x, slot.z) or ""
    if #coordStr > 0 then
        self:drawText(bx + bw - 2 - unicode.wlen(coordStr), by + 1, coordStr, COLORS.muted, cardBg)
    end
    local chId = d.channelId or "ch1"
    local chShareCount = countChannelShares(self.cfg, chId)
    local showCh = (#self.cfg.channels > 1) and (chShareCount > 1)
    local chW = showCh and (#chId + 3) or 0
    local rightEdge = bx + bw - 2 - (#coordStr > 0 and (unicode.wlen(coordStr) + 1) or 0) - chW
    local nameMax = math.max(3, rightEdge - hx - 2)
    local trimmedName = padOrTrunc(unitName, nameMax):gsub("%s+$", "")
    local nx = self:drawButton(hx, by + 1, "[" .. trimmedName .. "]",
        isSelected and COLORS.cyan or COLORS.fg, COLORS.btnBg, function()
        self.selectedDtpf = slot.index
        self:openPrompt("Rename DTPF #" .. slot.index .. ":", unitName,
            "Enter short name and press [Enter] or click [ APPLY ].", function(val)
                local trimmed = val:gsub("^%s+", ""):gsub("%s+$", "")
                if #trimmed > 0 then
                    d.name = trimmed
                    self:save("Renamed DTPF #" .. slot.index .. " to " .. trimmed)
                end
            end)
    end) + 1
    if showCh then
        self:drawButton(nx, by + 1, "[" .. chId .. "]",
            (chShareCount <= 1) and COLORS.muted or COLORS.yellow, COLORS.btnBg, act.cycleChannel)
    end

    -- Row +2: Coil badge + State + Disc / Coil (no hidden sprite hitbox)
    local animActiveNow = self:isAnimEnabled() and (self.cfg.armed == true) and ((self.animTick or 0) > 0)
    local animTick = self.animTick or 0
    local curProg, curMaxProg = getEffectiveProgress(self, st)
    local convSuffix = convNow and " ⚡CONV" or ""
    local activeBadge = (animActiveNow and st and st.active) and ANIM_SPIN4[((animTick - 1) % 4) + 1] or "●"
    local convBadge = (animActiveNow and st and (st.active or st.jobMode == "ON-DEMAND") and (animTick % 2 == 0)) and "◈" or "⚡"
    local badgeCore = hasCover and "!" or (convNow and convBadge or ((st and st.active) and activeBadge or "◇"))
    local badgeCol = hasCover and COLORS.yellow or (convNow and COLORS.purple or ((st and st.active) and modeCol or COLORS.muted))
    self:drawText(cx, by + 2, "≡", coilCol, cardBg)
    self:drawText(cx + 1, by + 2, badgeCore, badgeCol, cardBg)
    self:drawText(cx + 2, by + 2, "≡", coilCol, cardBg)

    local stStr, stCol
    if not isOnline then stStr, stCol = "OFFLINE", COLORS.red
    elseif hasCover then stStr, stCol = "COVER!", COLORS.yellow
    elseif d.enabled == false then stStr, stCol = "DISABLED", COLORS.red
    elseif st and st.passiveStalled then stStr, stCol = "STALLED!", COLORS.yellow
    elseif st and st.jobMode == "ON-DEMAND" then stStr, stCol = "OD" .. convSuffix, COLORS.purple
    elseif st and st.active and st.jobMode == "FALLBACK" then stStr, stCol = "LOOP" .. convSuffix, COLORS.cyan
    elseif st and st.active then stStr, stCol = "RUN" .. convSuffix, COLORS.green
    else stStr, stCol = (self.cfg.armed and "WAIT" or "PRV") .. convSuffix, COLORS.yellow end

    if curMaxProg > 0 and st and st.active then
        local pct = math.min(100, math.floor((curProg / curMaxProg) * 100 + 0.5))
        stStr = stStr .. " " .. pct .. "%"
    end

    local discVal = (st and tonumber(st.discountPct)) or 0
    local coilPart
    if not (st and st.coilHeat) then
        coilPart = self:isCoilNameMode() and "?" or "?K"
    elseif self:isCoilNameMode() then
        local _, _, tierName, shortName = getCoilTierInfo(st.coilHeat)
        coilPart = (innerW >= 28) and tierName or shortName
    else
        coilPart = string.format("%.1fk", st.coilHeat / 1000)
    end
    local infoTxt = string.format("%.0f%% %s", discVal, coilPart)
    local infoW = unicode.wlen(infoTxt)
    local infoX = bx + bw - 2 - infoW
    self:drawText(cx + 4, by + 2, padOrTrunc(stStr, math.max(5, innerW - 5 - infoW)), stCol, cardBg)
    self:drawText(infoX, by + 2, infoTxt, coilCol, cardBg)
    self:addHitbox(infoX, by + 2, infoX + infoW - 1, by + 2, function()
        self:toggleCoilDisplay()
    end)

    -- Row +3: Shaded Recipe Button (L-click = Inspector, R-click = Passive Modal)
    local rawJob = (d.enabled == false) and "Disabled (Work OFF)" or tostring((st and st.jobLabel) or "All Targets Full")
    local maxJobW = math.max(3, innerW - 2)
    if unicode.wlen(rawJob) > maxJobW then
        rawJob = compactRecipeName(rawJob, maxJobW)
    end
    self:drawButton(cx, by + 3, "[" .. padOrTrunc(rawJob, maxJobW) .. "]",
        (d.enabled == false) and COLORS.red or ((st and st.active) and COLORS.fg or COLORS.muted),
        COLORS.btnBg, function(_, button)
        openRecipeOrPassiveModal(self, slot, d, st, unitName, button)
    end)

    -- Row +4: 1-click Conv, Cat, Pass, Reset (collapsed when DTPF work is disabled)
    local convIsGlobal = ((d.convOverride or "global") == "global")
    local convObj = DTPF_CONV_MODES[findModeIndex(DTPF_CONV_MODES, d.convOverride or "global", 1)]
    local catIsGlobal = ((d.catOverride or 0) == 0)
    local catCode = CATALYST_SHORT[catIsGlobal and (self.cfg.defaultCatalystTier or 4) or d.catOverride] or "DTEC"
    local curRole = d.roleOverride or "auto"
    local passIsCustom = (curRole ~= "auto")
    local hasNonPowerOverride = (not convIsGlobal) or (not catIsGlobal) or passIsCustom
    local isCustom = (d.enabled == false) or hasNonPowerOverride

    if d.enabled == false then
        if hasNonPowerOverride then
            self:drawButton(cx, by + 4, "[↺ Reset]", COLORS.yellow, COLORS.amberBg, act.resetDtpf)
        else
            self:drawText(cx, by + 4, padOrTrunc("Click [OF] above to enable", innerW), COLORS.muted, cardBg)
        end
        return
    end

    local convCtrlOk = self:isConvControlSupported()
    local effConv = effectiveGlobalConvShort(self.cfg)
    local px = self:drawButton(cx, by + 4, convCtrlOk and ("[" .. (convIsGlobal and effConv or convObj.short) .. "]") or "Manual",
        (not convCtrlOk) and COLORS.yellow or (convIsGlobal and COLORS.muted or COLORS.fg),
        (not convCtrlOk or convIsGlobal) and COLORS.btnBg or COLORS.btnActiveBg,
        function(step)
            if not convCtrlOk then
                self:setStatus(NO_CONV_PATCH_MSG)
            else
                act.cycleConv(step)
            end
        end) + 1
    px = self:drawButton(px, by + 4, "[" .. catCode .. "]",
        catIsGlobal and COLORS.muted or COLORS.fg, catIsGlobal and COLORS.btnBg or COLORS.btnActiveBg, act.cycleCat) + 1

    local maxPassW = (bx + bw - 2) - px - (isCustom and 4 or 0) - 2
    local passTxt = padOrTrunc(formatDtpfPassLabel(self, d, true), math.max(4, maxPassW))
    self:drawButton(px, by + 4, "[" .. passTxt .. "]",
        (curRole == "pinned" or curRole == "pinned_loop") and COLORS.cyan or COLORS.fg,
        passIsCustom and COLORS.btnActiveBg or COLORS.btnBg,
        act.openPassOrQuick)

    if isCustom then
        self:drawButton(bx + bw - 5, by + 4, "[↺]", COLORS.yellow, COLORS.amberBg, act.resetDtpf)
    end
end

local function getFilteredRecipeList(self, filterOverride, maxCoilHeat)
    local out = {}
    local flt = filterOverride or self.recipeFilter or "all"
    for i = 1, #RecipesDB.FAMILIES do
        local fam = RecipesDB.FAMILIES[i]
        local rc = self.cfg.recipes[fam.id]
        if rc then
            local keep = false
            if flt == "all" then
                keep = true
            elseif flt == "enabled" then
                keep = (rc.enabled == true)
            elseif flt == "loops" then
                keep = (rc.forever == true)
                    or (fam.id == self.cfg.fallbackFamilyId)
                    or (rc.guardKey and rc.guardKey ~= "none")
                    or fam.id == "molten_infinity"
                    or fam.id == "raw_star_matter"
                    or fam.id == "molten_neutronium"
            elseif flt == "nocat" then
                local mod = fam.modifiers[rc.modifierIndex or 1]
                local tInfo = Scheduler.getModifierTierInfo(mod)
                keep = (tInfo and not tInfo.usesCatalyst) == true
            elseif flt == "blocked" then
                local rSt = self.state and self.state.recipeStatus and self.state.recipeStatus[fam.id]
                keep = (rc.enabled == true) and (rSt ~= nil) and (rSt.needsStock == true) and (not rSt.runnable)
            elseif flt == "coil" then
                local heat = getRecipeCoilHeat(self, fam, rc)
                keep = (not maxCoilHeat) or (maxCoilHeat <= 0) or (not heat) or (heat <= maxCoilHeat)
            end
            if keep then
                out[#out + 1] = { fam = fam, rc = rc }
            end
        end
    end
    table.sort(out, function(a, b)
        return (a.rc.priority or 999) < (b.rc.priority or 999)
    end)
    return out
end

local function isFamilyLoop(cfg, famId, rc)
    if not rc then return false end
    return (rc.forever == true)
        or ((cfg.fallbackEnabled == true) and cfg.fallbackFamilyId == famId and not rc.enabled)
end

function UI:renderFleetPane()
    local anyDtpfCustom = false
    for i = 1, #self.cfg.dtpfs do
        local d = self.cfg.dtpfs[i]
        if (d.enabled == false)
            or ((d.convOverride or "global") ~= "global")
            or ((d.catOverride or 0) ~= 0)
            or ((d.roleOverride or "auto") ~= "auto") then
            anyDtpfCustom = true
            break
        end
    end

    -- LEFT PANE: In-World DTPF Squares (x = 2..78, y = 4..48)
    self:drawText(2, 4, "◈ IN-WORLD DTPF FLEET", COLORS.accent, COLORS.bg)
    if anyDtpfCustom then
        self:drawButton(24, 4, "[Reset All]", COLORS.yellow, COLORS.amberBg, function()
            for i = 1, #self.cfg.dtpfs do
                local d = self.cfg.dtpfs[i]
                d.enabled = true
                d.convOverride = "global"
                d.catOverride = 0
                d.roleOverride = "auto"
                d.pinnedFamilyId = nil
            end
            self:save("All DTPFs reset to Global defaults.")
        end)
    end
    if (#self.cfg.dtpfs > 6) or self.fleetCompact then
        self:drawButton(36, 4, self.fleetCompact and "[Cards  ]" or "[Compact]",
            self.fleetCompact and COLORS.fg or COLORS.cyan,
            self.fleetCompact and COLORS.btnActiveBg or COLORS.btnBg,
            function()
                self.fleetCompact = not self.fleetCompact
                self.dtpfRowScroll = 0
            end)
    end
    self:drawText(46, 4, "■", COLORS.green, COLORS.bg)
    self:drawText(47, 4, " Run ", COLORS.muted, COLORS.bg)
    self:drawText(52, 4, "■", COLORS.purple, COLORS.bg)
    self:drawText(53, 4, " OD ", COLORS.muted, COLORS.bg)
    self:drawText(57, 4, "■", COLORS.cyan, COLORS.bg)
    self:drawText(58, 4, " Loop ", COLORS.muted, COLORS.bg)
    self:drawText(64, 4, "■", COLORS.yellow, COLORS.bg)
    self:drawText(65, 4, " Idle ", COLORS.muted, COLORS.bg)
    self:drawText(71, 4, "■", COLORS.red, COLORS.bg)
    self:drawText(72, 4, " Off", COLORS.muted, COLORS.bg)

    local layout = UI.computeSpatialGrid(self.cfg.dtpfs, self.state.dtpfStatus)
    local visibleRows = self.fleetCompact and 7 or ((layout.cols <= 2) and 3 or 4)
    local maxRowScroll = math.max(0, layout.rows - visibleRows)
    self.dtpfRowScroll = math.max(0, math.min(maxRowScroll, self.dtpfRowScroll or 0))

    if #self.cfg.dtpfs == 0 then
        self:fillRect(2, 5, 77, 42, " ", COLORS.panelBg)
        self:drawText(4, 7, "No DTPF Controllers discovered yet.", COLORS.yellow, COLORS.panelBg)
        self:drawText(4, 9, "Connect 1x Adapter + 1x MFU to each DTPF Controller and check [4] SETUP.", COLORS.muted, COLORS.panelBg)
    else
        local boxW = (layout.cols <= 2) and 37 or ((layout.cols == 3) and 25 or 18)
        local gapX = (layout.cols <= 2) and 3 or 1
        local boxH = self.fleetCompact and 6 or 10
        local gapY = self.fleetCompact and 0 or 1

        for visR = 1, math.min(visibleRows, layout.rows - self.dtpfRowScroll) do
            local r = visR + self.dtpfRowScroll
            for c = 1, math.min(layout.cols, 4) do
                local bx = 2 + (c - 1) * (boxW + gapX)
                local by = 5 + (visR - 1) * (boxH + gapY)
                local idx = layout.grid[r] and layout.grid[r][c]
                if idx and self.cfg.dtpfs[idx] then
                    local slot = layout.slots[idx]
                    local d = self.cfg.dtpfs[idx]
                    local st = (self.state.dtpfStatus and self.state.dtpfStatus[idx]) or {}
                    if self.fleetCompact then
                        self:drawCompactDTPFSquare(bx, by, boxW, boxH, slot, d, st, idx == self.selectedDtpf)
                    else
                        self:drawDTPFSquare(bx, by, boxW, boxH, slot, d, st, idx == self.selectedDtpf)
                    end
                elseif layout.usedSpatial and layout.colCoords[c] and layout.rowCoords[r] then
                    self:drawFrame(bx, by, boxW, boxH, COLORS.border, COLORS.rowAltBg, "round")
                    self:drawText(bx + 2, by + math.floor(boxH / 2),
                        padOrTrunc(string.format("Empty Grid (%d,%d)", layout.colCoords[c], layout.rowCoords[r]), boxW - 4),
                        COLORS.muted, COLORS.rowAltBg)
                end
            end
        end
    end

    local allCardsFitFull = (not self.fleetCompact) and (layout.rows <= visibleRows) and (layout.cols <= 3)
    if #self.cfg.dtpfs >= 1 and not allCardsFitFull then
        local selIdx = math.max(1, math.min(#self.cfg.dtpfs, self.selectedDtpf or 1))
        self.selectedDtpf = selIdx
        local selD = self.cfg.dtpfs[selIdx]
        local fx = self:drawButton(2, 47, "[◀]", COLORS.fg, COLORS.btnBg, function()
            self:selectDtpfByDelta(-1)
        end) + 1
        local selName = padOrTrunc("#" .. tostring(selIdx) .. " " .. (selD.name or ("DTPF #" .. selIdx)), 18):gsub("%s+$", "")
        fx = self:drawButton(fx, 47, "[" .. selName .. "]", COLORS.cyan, COLORS.btnBg, function()
            self:ensureDtpfVisible(selIdx)
        end) + 1
        fx = self:drawButton(fx, 47, "[▶]", COLORS.fg, COLORS.btnBg, function()
            self:selectDtpfByDelta(1)
        end) + 2
        self:drawButton(fx, 47, "[Assign Passive / Mode...]", COLORS.fg, COLORS.btnBg, function()
            self:openPassiveModal(selIdx)
        end)
    end

    if layout.rows > visibleRows then
        local px = self:drawButton(2, 48, "[▲ Prev]",
            (self.dtpfRowScroll > 0) and COLORS.fg or COLORS.muted, COLORS.btnBg, function(_, btn)
                local delta = (btn == 1) and 1 or visibleRows
                self.dtpfRowScroll = math.max(0, self.dtpfRowScroll - delta)
            end) + 1
        px = self:drawButton(px, 48, "[▼ Next]",
            (self.dtpfRowScroll < maxRowScroll) and COLORS.fg or COLORS.muted, COLORS.btnBg, function(_, btn)
                local delta = (btn == 1) and 1 or visibleRows
                self.dtpfRowScroll = math.min(maxRowScroll, self.dtpfRowScroll + delta)
            end) + 2
        local firstRow = self.dtpfRowScroll + 1
        local lastRow = math.min(layout.rows, self.dtpfRowScroll + visibleRows)
        self:drawText(px, 48, padOrTrunc(string.format("Rows %d-%d/%d (%d DTPFs)",
            firstRow, lastRow, layout.rows, #self.cfg.dtpfs), 78 - px), COLORS.muted, COLORS.bg)
    end
end

function UI:renderGlobalSettingsCard()
    -- RIGHT PANE Card 1: Global Settings (rows 4..8)
    local convCtrlOk = self:isConvControlSupported()
    self:drawText(82, 4, "◈ GLOBAL SETTINGS", COLORS.accent, COLORS.bg)
    if convCtrlOk then
        local anyRecConvCustom = (self.cfg.fallbackConvMode or "global") ~= "global"
        if not anyRecConvCustom then
            for _, rc in pairs(self.cfg.recipes) do
                if (rc.convMode or "global") ~= "global" then
                    anyRecConvCustom = true
                    break
                end
            end
        end
        if anyRecConvCustom then
            self:drawButton(143, 4, "[Reset Overrides]", COLORS.yellow, COLORS.amberBg, function()
                self.cfg.fallbackConvMode = "global"
                for _, rc in pairs(self.cfg.recipes) do
                    rc.convMode = "global"
                end
                self:save("Reset all recipe & Forever Loop Convergence policies to GLOBAL.")
            end)
        end
    end
    self:drawFrame(82, 5, 78, 4, COLORS.border, COLORS.panelBg, "round")

    -- Row 6: Passive Convergence, On-Demand Convergence, Default Catalyst (or Manual badge on stock GTNH)
    local gx
    if not convCtrlOk then
        self:drawText(84, 6, "Convergence:", COLORS.muted, COLORS.panelBg)
        gx = self:drawButton(97, 6, "[Manual (No OC Patch)]", COLORS.yellow, COLORS.btnBg, function()
            self:setStatus(NO_CONV_PATCH_MSG)
        end) + 2
    else
        local rawGConv = self.cfg.globalConvMode or "auto"
        local curGConv = (rawGConv == "passive_od") and "auto" or ((rawGConv == "ondemand") and "off" or rawGConv)
        local gIdx = findModeIndex(GLOBAL_CONV_MODES, curGConv, 1)
        local gObj = GLOBAL_CONV_MODES[gIdx]
        self:drawText(84, 6, "Convergence:", COLORS.muted, COLORS.panelBg)
        gx = self:drawButton(97, 6, "[" .. gObj.label .. "]",
            (gObj.id == "off") and COLORS.yellow or COLORS.fg,
            (gObj.id == "off") and COLORS.amberBg or COLORS.btnActiveBg,
            function(step)
                local nxt = ((gIdx - 1 + (step or 1)) % #GLOBAL_CONV_MODES) + 1
                local nxtMode = GLOBAL_CONV_MODES[nxt]
                self.cfg.globalConvMode = nxtMode.id
                self:save("Convergence -> " .. nxtMode.label)
            end) + 2

        self:drawText(gx, 6, "OD Conv:", COLORS.muted, COLORS.panelBg)
        local odIdx = findModeIndex(OD_CONV_MODES, self.cfg.onDemandConvMode or "auto_safe", 1)
        local odObj = OD_CONV_MODES[odIdx]
        local odFg = (odObj.id == "off") and COLORS.yellow or ((odObj.id == "on") and COLORS.fg or COLORS.purple)
        local odBg = (odObj.id == "off") and COLORS.amberBg or ((odObj.id == "on") and COLORS.btnActiveBg or COLORS.btnBg)
        gx = self:drawButton(gx + 9, 6, odObj.pill or "[⚡Auto-Safe]", odFg, odBg, function(step)
            local nxt = ((odIdx - 1 + (step or 1)) % #OD_CONV_MODES) + 1
            local nxtMode = OD_CONV_MODES[nxt]
            self.cfg.onDemandConvMode = nxtMode.id
            self:save("OD Convergence -> " .. nxtMode.label)
        end) + 2
    end

    self:drawText(gx, 6, "Catalyst:", COLORS.muted, COLORS.panelBg)
    local defCatIdx = self.cfg.defaultCatalystTier or 4
    local defCatCode = CATALYST_SHORT[defCatIdx] or "DTEC"
    self:drawButton(gx + 10, 6, "[" .. defCatCode .. "]", COLORS.yellow, COLORS.btnBg, function(step)
        local cur = self.cfg.defaultCatalystTier or 4
        local nxt = ((cur - 1 + (step or 1)) % 5) + 1
        self.cfg.defaultCatalystTier = nxt
        self:save("Default Catalyst -> " .. (CATALYST_SHORT[nxt] or "DTEC"))
    end)

    -- Row 7: AE2 On-Demand Queue Pause + Multi-DTPF Queue Splitting (2 clean toggle pills)
    self:drawText(84, 7, "On AE2 Craft:", COLORS.muted, COLORS.panelBg)
    local rx7 = self:drawButton(98, 7, self.cfg.pausePassivesOnOD and "[Pause Queue]" or "[Keep Queue ]",
        self.cfg.pausePassivesOnOD and COLORS.fg or COLORS.cyan,
        self.cfg.pausePassivesOnOD and COLORS.btnActiveBg or COLORS.btnBg,
        function()
            self.cfg.pausePassivesOnOD = not self.cfg.pausePassivesOnOD
            self:save(self.cfg.pausePassivesOnOD and "On AE2 Craft -> Pause Queue" or "On AE2 Craft -> Keep Queue")
        end) + 2

    self:drawText(rx7, 7, "Queue Split:", COLORS.muted, COLORS.panelBg)
    self:drawButton(rx7 + 13, 7, self.cfg.allowParallelSameRecipe and "[Parallel DTPFs]" or "[1 DTPF / Recipe]",
        self.cfg.allowParallelSameRecipe and COLORS.fg or COLORS.cyan,
        self.cfg.allowParallelSameRecipe and COLORS.btnActiveBg or COLORS.btnBg,
        function()
            self.cfg.allowParallelSameRecipe = not self.cfg.allowParallelSameRecipe
            self:save(self.cfg.allowParallelSameRecipe and "Queue Split -> Parallel DTPFs" or "Queue Split -> 1 DTPF per Recipe")
        end)
    local pwrSmart = (self.cfg.powerAwareAssign ~= false)
    self:drawButton(147, 7, pwrSmart and "[Pwr:Smart]" or "[Pwr:Order]",
        pwrSmart and COLORS.cyan or COLORS.muted,
        pwrSmart and COLORS.btnActiveBg or COLORS.btnBg,
        function()
            self.cfg.powerAwareAssign = not pwrSmart
            self:save(self.cfg.powerAwareAssign
                and "Power Placement -> Smart (Conv on big hatches, Passive/Loop on small)"
                or "Power Placement -> Channel Order")
        end)
end

function UI:renderPriorityQueueCard()
    -- Row 9 (`x=82..159, y=9`): 24/7 Discount-Retention Warning OR Concise Fallback Controls
    local cw = self.state and self.state.coverageWarning
    if cw then
        self:fillRect(82, 9, 78, 1, " ", COLORS.amberBg)
        local btnLbl, btnFn
        if not self.cfg.fallbackEnabled then
            btnLbl = "[Fallback:ON]"
            btnFn = function()
                self.cfg.fallbackFamilyId = self.cfg.fallbackFamilyId or "molten_infinity"
                self.cfg.fallbackEnabled = true
                local fbFam = FAMILY_BY_ID[self.cfg.fallbackFamilyId]
                self:save("Enabled Fallback (" .. (fbFam and fbFam.name or self.cfg.fallbackFamilyId) .. ")")
            end
        elseif cw.familyId then
            btnLbl = "[Inspect ->]"
            btnFn = function()
                self.selectedFamilyId = cw.familyId
                self.tab = TAB_RECIPES
            end
        else
            btnLbl = "[Fix ->]"
            btnFn = function()
                if cw.dtpfIdx then
                    self.selectedDtpf = cw.dtpfIdx
                    self:ensureDtpfVisible(cw.dtpfIdx)
                else
                    self.queueShowAll = true
                    self.activeScroll = 0
                end
            end
        end
        local bx = 160 - unicode.wlen(btnLbl) + 1
        self:drawButton(bx, 9, btnLbl, COLORS.yellow, COLORS.btnBg, btnFn)
        local wTxt = "! " .. tostring(cw.shortReason or cw.summary) .. " - " .. tostring(cw.reason)
        self:drawText(83, 9, padOrTrunc(wTxt, math.max(12, bx - 84)), COLORS.yellow, COLORS.amberBg)
    else
        self:fillRect(82, 9, 78, 1, " ", COLORS.bg)
        self:drawText(82, 9, "Fallback:", COLORS.muted, COLORS.bg)
        local fx = self:drawButton(92, 9, self.cfg.fallbackEnabled and "[ON ]" or "[OFF]",
            self.cfg.fallbackEnabled and COLORS.green or COLORS.muted,
            self.cfg.fallbackEnabled and COLORS.darkGreen or COLORS.btnBg,
            function()
                self.cfg.fallbackEnabled = not (self.cfg.fallbackEnabled == true)
                self:save("Global Fallback -> " .. (self.cfg.fallbackEnabled and "ON" or "OFF"))
            end) + 1
        if self.cfg.fallbackEnabled then
            local fbId = self.cfg.fallbackFamilyId or "molten_infinity"
            local fbFam = FAMILY_BY_ID[fbId]
            local fbName = fbFam and compactRecipeName(fbFam.name, 22) or fbId
            fx = self:drawButton(fx, 9, "[" .. padOrTrunc(fbName, 22):gsub("%s+$", "") .. "]",
                COLORS.cyan, COLORS.btnBg, function()
                    self.selectedFamilyId = fbId
                    self.tab = TAB_RECIPES
                end) + 1
            if self:isConvControlSupported() then
                local fbConvModes = {
                    { id = "global", lbl = "Def",  col = COLORS.muted },
                    { id = "on",     lbl = "⚡50%", col = COLORS.cyan  },
                    { id = "off",    lbl = "◇OFF", col = COLORS.yellow },
                }
                local fbC = self.cfg.fallbackConvMode or "global"
                local fbIdx = 1
                for k = 1, #fbConvModes do if fbConvModes[k].id == fbC then fbIdx = k break end end
                local curFc = fbConvModes[fbIdx]
                self:drawText(fx, 9, "Conv:", COLORS.muted, COLORS.bg)
                fx = self:drawButton(fx + 5, 9, "[" .. curFc.lbl .. "]", curFc.col, COLORS.btnBg, function(step)
                    local nxt = fbConvModes[((fbIdx - 1 + (step or 1)) % #fbConvModes) + 1]
                    self.cfg.fallbackConvMode = nxt.id
                    self:save("Fallback Convergence -> " .. nxt.lbl)
                end) + 1
            end
        end
        if fx <= 150 then
            self:drawText(151, 9, "✓ 24/7 OK", COLORS.green, COLORS.bg)
        end
    end

    -- RIGHT PANE Card 2: Expanded Unified Priority Queue (rows 10..47, 36 visible rows)
    local enabledList, allSortedList = {}, {}
    for i = 1, #RecipesDB.FAMILIES do
        local fam = RecipesDB.FAMILIES[i]
        local rc = self.cfg.recipes[fam.id]
        local item = { fam = fam, rc = rc }
        allSortedList[#allSortedList + 1] = item
        if rc and (rc.enabled or (self.cfg.fallbackEnabled and fam.id == self.cfg.fallbackFamilyId)) then
            enabledList[#enabledList + 1] = item
        end
    end
    local function byPriority(a, b) return (a.rc.priority or 999) < (b.rc.priority or 999) end
    table.sort(enabledList, byPriority)
    table.sort(allSortedList, byPriority)
    local queueList = self.queueShowAll and allSortedList or enabledList

    self:drawText(82, 10, "◈ PRIORITY QUEUE", COLORS.accent, COLORS.bg)
    local qx = self:drawButton(99, 10, string.format("[Enabled:%d]", #enabledList),
        (not self.queueShowAll) and COLORS.fg or COLORS.muted,
        (not self.queueShowAll) and COLORS.btnActiveBg or COLORS.btnBg,
        function()
            self.queueShowAll = false
            self.activeScroll = 0
        end) + 1
    qx = self:drawButton(qx, 10, string.format("[All:%d]", #RecipesDB.FAMILIES),
        self.queueShowAll and COLORS.fg or COLORS.muted,
        self.queueShowAll and COLORS.btnActiveBg or COLORS.btnBg,
        function()
            self.queueShowAll = true
            self.activeScroll = 0
        end) + 1
    local blockedN, fullN = 0, 0
    for k = 1, #enabledList do
        local eSt = self.state.recipeStatus and self.state.recipeStatus[enabledList[k].fam.id]
        if eSt then
            if eSt.needsStock and not eSt.runnable then
                blockedN = blockedN + 1
            elseif not eSt.needsStock and not eSt.isForever then
                fullN = fullN + 1
            end
        end
    end
    if blockedN > 0 then
        self:drawButton(qx, 10, string.format("[! %d Blocked]", blockedN), COLORS.yellow, COLORS.amberBg, function()
            self.logModalActive = true
            self.logModalScroll = 0
        end)
    elseif #enabledList > 0 and fullN == #enabledList then
        self:drawText(qx, 10, "✓ All Full", COLORS.green, COLORS.bg)
    end
    local allRecBtn = "[Inspector →]"
    self:drawButton(160 - unicode.wlen(allRecBtn), 10, allRecBtn, COLORS.cyan, COLORS.btnBg, function()
        self.tab = TAB_RECIPES
    end)

    self:fillRect(82, 11, 78, 1, " ", COLORS.headerBg)
    self:drawText(83, 11, "ORD", COLORS.muted, COLORS.headerBg)
    self:drawText(87, 11, "ON", COLORS.muted, COLORS.headerBg)
    self:drawText(93, 11, "RECIPE", COLORS.muted, COLORS.headerBg)
    self:drawText(117, 11, "CONV", COLORS.muted, COLORS.headerBg)
    self:drawText(124, 11, "MODE", COLORS.muted, COLORS.headerBg)
    self:drawText(131, 11, "STOCK", COLORS.muted, COLORS.headerBg)
    self:drawText(139, 11, "TARGET", COLORS.muted, COLORS.headerBg)
    self:drawText(147, 11, "STATUS", COLORS.muted, COLORS.headerBg)

    local maxActiveRows = self.h - 14 -- rows 12..47 (36 rows)
    self.activeScroll = math.max(0, math.min(math.max(0, #queueList - maxActiveRows), self.activeScroll))

    if #queueList == 0 then
        self:fillRect(82, 12, 78, maxActiveRows, " ", COLORS.panelBg)
        self:drawText(84, 14, "No passive recipes enabled.", COLORS.yellow, COLORS.panelBg)
        self:drawText(84, 16, "Click [All:" .. #RecipesDB.FAMILIES .. "] above to quick-enable or toggle [24/7] loops.", COLORS.muted, COLORS.panelBg)
    else
        local convCtrlOk = self:isConvControlSupported()
        local defConvShort = effectiveGlobalConvShort(self.cfg)
        local defConv4 = (defConvShort == "ON" and " ON ") or (defConvShort == "OFF" and "OFF ") or "Auto"
        local recipeConvShort = {
            global    = { "[" .. defConv4 .. "]", COLORS.muted, COLORS.btnBg },
            on        = { "[⚡50%]", COLORS.fg, COLORS.btnActiveBg },
            below_tgt = { "[⚡<Tg]", COLORS.cyan, COLORS.btnActiveBg },
            force     = { "[⚡ON ]", COLORS.fg, COLORS.btnActiveBg },
            off       = { "[◇OFF]", COLORS.yellow, COLORS.amberBg },
        }
        for r = 1, maxActiveRows do
            local y = 11 + r
            local idx = r + self.activeScroll
            local rowBg = (r % 2 == 0) and COLORS.rowAltBg or COLORS.panelBg
            self:fillRect(82, y, 78, 1, " ", rowBg)
            local item = queueList[idx]
            if item then
                local fam = item.fam
                local rc = item.rc
                local st = (self.state.recipeStatus and self.state.recipeStatus[fam.id]) or {}
                local isLoop = isFamilyLoop(self.cfg, fam.id, rc)
                local isOn = (rc.enabled == true) or (self.cfg.fallbackEnabled and self.cfg.fallbackFamilyId == fam.id)

                self:drawButton(83, y, "▲", COLORS.fg, COLORS.btnBg, function(_, button)
                    local dlt = (button == 1) and "top" or -1
                    Scheduler.moveRecipePriority(self.cfg, fam.id, dlt, not self.queueShowAll)
                    self:save((button == 1) and ("Moved " .. fam.name .. " to top priority.") or ("Moved " .. fam.name .. " up in priority."))
                end)
                self:drawButton(85, y, "▼", COLORS.fg, COLORS.btnBg, function(_, button)
                    local dlt = (button == 1) and "bottom" or 1
                    Scheduler.moveRecipePriority(self.cfg, fam.id, dlt, not self.queueShowAll)
                    self:save((button == 1) and ("Moved " .. fam.name .. " to bottom priority.") or ("Moved " .. fam.name .. " down in priority."))
                end)
                self:drawButton(87, y, isOn and "[ON]" or "[--]",
                    isOn and COLORS.green or COLORS.muted, COLORS.btnBg, function()
                        rc.enabled = not isOn
                        self:save((rc.enabled and "Enabled " or "Disabled ") .. fam.name)
                    end)

                local catIco, catIcoCol = getCategoryBadge(fam.category)
                self:drawText(92, y, catIco, catIcoCol, rowBg)
                self:drawButton(93, y, "[" .. padOrTrunc(compactRecipeName(fam.name, 20), 20) .. "▸]",
                    isOn and COLORS.fg or COLORS.muted, COLORS.btnBg, function()
                        self.selectedFamilyId = fam.id
                        self.tab = TAB_RECIPES
                    end)

                if convCtrlOk then
                    local rConvIdx = findModeIndex(RECIPE_CONV_MODES, rc.convMode or "global", 1)
                    local rConvObj = RECIPE_CONV_MODES[rConvIdx]
                    local rBadge = recipeConvShort[rConvObj.id] or recipeConvShort.global
                    self:drawButton(117, y, rBadge[1], rBadge[2], rBadge[3], function(step)
                        local nxt = ((rConvIdx - 1 + (step or 1)) % #RECIPE_CONV_MODES) + 1
                        local nxtMode = RECIPE_CONV_MODES[nxt]
                        rc.convMode = nxtMode.id
                        self:save(fam.name .. " Convergence -> " .. nxtMode.label)
                    end)
                else
                    self:drawButton(117, y, "Manual", COLORS.yellow, COLORS.panelBg, function()
                        self:setStatus(NO_CONV_PATCH_MSG)
                    end)
                end

                self:drawButton(124, y, isLoop and "[24/7]" or "[<Tgt]",
                    COLORS.fg,
                    isLoop and COLORS.btnActiveBg or COLORS.btnBg,
                    function()
                        if isLoop then
                            rc.forever = false
                            self:save(fam.name .. " mode -> Stop at Target (<Tgt)")
                        else
                            rc.forever = true
                            rc.enabled = true
                            self:save(fam.name .. " mode -> Run 24/7 (ignores target)")
                        end
                    end)

                local isFluid = st.trackedOutput and (st.trackedOutput.isFluid or st.trackedOutput.type == "fluid")
                local curStockStr = fmtCompactNum(st.currentStock or 0, isFluid)
                local stkCol = isLoop and COLORS.cyan or getStockRatioColor(st.ratio or 0, isOn)
                self:drawText(131, y, padOrTrunc(curStockStr, 7), stkCol, rowBg)

                if isLoop and rc.convMode ~= "below_tgt" then
                    self:drawText(139, y, " Loop  ", COLORS.muted, rowBg)
                else
                    local tgtTxt = centerText(fmtCompactNum(rc.target or 1, isFluid), 5)
                    local tgtCol = (isLoop and rc.convMode == "below_tgt")
                        and ((st.convBelowTarget == true) and COLORS.cyan or COLORS.green)
                        or stkCol
                    self:drawButton(139, y, "[" .. tgtTxt .. "]", tgtCol, COLORS.btnBg, function()
                        self:openTargetPrompt(fam, rc, st.trackedOutput)
                    end)
                end

                local sStr = localizeCoilStatus(self, st.stateStr or "Queued")
                local sCol = COLORS.accent
                local isBlocked = false
                if not isOn then
                    sCol = COLORS.muted
                elseif sStr:find("Running", 1, true) or sStr:find("Would Run", 1, true) or sStr:find("Full", 1, true) then
                    sCol = COLORS.green
                elseif sStr:find("Loop", 1, true) or sStr:find("24/7", 1, true) or sStr:find("Fallback", 1, true) or sStr:find("Would FB", 1, true) then
                    sCol = COLORS.cyan
                elseif sStr:find("Low", 1, true) or sStr:find("Guard", 1, true) or sStr:find("Missing", 1, true) or sStr:find("DTR", 1, true) or sStr:find("Coil", 1, true) then
                    sCol = COLORS.yellow
                    isBlocked = true
                end
                local activeD = st.activeDtpfs or {}
                if #activeD > 0 then
                    local tag = formatDtpfIdList(activeD, 5)
                    local isFbRun = (sStr:find("Loop", 1, true) ~= nil or sStr:find("Fallback", 1, true) ~= nil or sStr:find("Would FB", 1, true) ~= nil)
                    local modeW = isFbRun and "24/7" or (self.cfg.armed and "Run" or "Prv")
                    local animActiveQ = self:isAnimEnabled() and (self.cfg.armed == true) and ((self.animTick or 0) > 0)
                    local qTick = self.animTick or 0
                    local pfx
                    if isFbRun then
                        pfx = animActiveQ and (ANIM_BRAILLE[((qTick - 1) % 8) + 1] .. " ") or "* "
                    elseif self.cfg.armed then
                        pfx = animActiveQ and (ANIM_SPIN4[((qTick - 1) % 4) + 1] .. " ") or "● "
                    else
                        pfx = "◇ "
                    end
                    local dispStatus = pfx .. tag .. " " .. modeW
                    if unicode.wlen(dispStatus) > 11 then
                        dispStatus = pfx .. tag
                        if unicode.wlen(dispStatus) > 11 then
                            dispStatus = pfx .. formatDtpfIdList(activeD, 4)
                        end
                    end
                    local firstD = activeD[1]
                    self:drawButton(147, y, "[" .. padOrTrunc(dispStatus, 11) .. "]",
                        COLORS.fg, isFbRun and COLORS.btnBg or COLORS.darkGreen, function()
                            self.selectedDtpf = firstD
                            self:ensureDtpfVisible(firstD)
                        end)
                elseif isBlocked then
                    self:drawButton(147, y, "[!" .. padOrTrunc(compactStatusText(sStr, 9), 9) .. "▸]",
                        COLORS.yellow, COLORS.amberBg, function()
                            self.selectedFamilyId = fam.id
                            self.tab = TAB_RECIPES
                        end)
                else
                    self:drawText(147, y, padOrTrunc(compactStatusText(sStr, 13), 13), sCol, rowBg)
                end
            end
        end
    end

    if #queueList > maxActiveRows then
        self:drawButton(82, 48, "[▲ Up]", COLORS.fg, COLORS.btnBg, function()
            self.activeScroll = math.max(0, self.activeScroll - 5)
        end)
        self:drawButton(89, 48, "[▼ Dn]", COLORS.fg, COLORS.btnBg, function()
            self.activeScroll = math.min(math.max(0, #queueList - maxActiveRows), self.activeScroll + 5)
        end)
        self:drawText(97, 48, string.format("%d-%d of %d", self.activeScroll + 1, math.min(#queueList, self.activeScroll + maxActiveRows), #queueList), COLORS.muted, COLORS.bg)
    end
end

function UI:renderControlCenter()
    -- Vertical divider between Left DTPF Fleet (x=2..78) and Right Global Sidebar (x=82..159)
    for y = 4, self.h - 1 do
        self:drawText(80, y, "│", COLORS.border, COLORS.bg)
    end
    self:renderFleetPane()
    self:renderGlobalSettingsCard()
    self:renderPriorityQueueCard()
end

local STAGE_STYLE = {
    IN   = { badge = "[IN ]", col = COLORS.purple },
    DEC  = { badge = "[DEC]", col = COLORS.green  },
    OUT  = { badge = "[OUT]", col = COLORS.cyan   },
    WARN = { badge = "[WRN]", col = COLORS.yellow },
}

local function formatLogUptime(sec)
    if sec == nil then return "--:--:--" end
    sec = math.max(0, math.floor(tonumber(sec) or 0))
    local h = math.min(999, math.floor(sec / 3600))
    local m = math.floor((sec % 3600) / 60)
    local s = sec % 60
    return string.format("+%02d:%02d:%02d", h, m, s)
end

local function cycleLogLevel(ui, step)
    local idx = findModeIndex(LOG_LEVELS, ui.cfg.logLevel or "normal", 2)
    local nxt = ((idx - 1 + (step or 1)) % #LOG_LEVELS) + 1
    ui.cfg.logLevel = LOG_LEVELS[nxt].id
    ui:save("Log Verbosity -> " .. LOG_LEVELS[nxt].label)
end

local function setLogLevel(ui, lvlId)
    ui.cfg.logLevel = lvlId
    local idx = findModeIndex(LOG_LEVELS, lvlId, 2)
    ui:save("Log Verbosity -> " .. LOG_LEVELS[idx].label)
end

local function getEventLineColor(ev)
    if ev.kind == "warn" then return COLORS.yellow
    elseif ev.kind == "od" then return COLORS.purple
    elseif ev.kind == "loop" then return COLORS.cyan
    elseif ev.kind == "run" then return COLORS.green
    elseif ev.kind == "out" then return COLORS.cyan
    elseif ev.kind == "idle" then return COLORS.muted
    end
    return COLORS.fg
end

local function gatherOverviewStats(ui)
    local nTotal = #ui.cfg.dtpfs
    local nOnline, nActive, nRun, nLoop, nOd, nIdle, nIssues, convOn = 0, 0, 0, 0, 0, 0, 0, 0
    local minD, maxD = 100, 0
    for i = 1, nTotal do
        local d = ui.cfg.dtpfs[i]
        local st = (ui.state and ui.state.dtpfStatus and ui.state.dtpfStatus[i]) or {}
        if st.online then
            nOnline = nOnline + 1
            if st.active then nActive = nActive + 1 end
            if st.convergenceEnabled then convOn = convOn + 1 end
            local dp = math.floor((tonumber(st.discountPct) or 0) + 0.5)
            if dp < minD then minD = dp end
            if dp > maxD then maxD = dp end
        elseif d.enabled ~= false then
            nIssues = nIssues + 1
        end
        if st.coverConflict or st.passiveStalled then
            nIssues = nIssues + 1
        end
        local jm = st.jobMode
        if jm == "PASSIVE" then nRun = nRun + 1
        elseif jm == "FALLBACK" then nLoop = nLoop + 1
        elseif jm == "ON-DEMAND" then nOd = nOd + 1
        else nIdle = nIdle + 1
        end
    end
    if nOnline == 0 then minD, maxD = 0, 0 end

    local nEnabled, nTargetRec, nFull, nRunRec, nLoopRec, nQueuedRec, nBlockedRec = 0, 0, 0, 0, 0, 0, 0
    local fullNames = {}
    for i = 1, #RecipesDB.FAMILIES do
        local fam = RecipesDB.FAMILIES[i]
        local rc = ui.cfg.recipes[fam.id]
        local rSt = ui.state and ui.state.recipeStatus and ui.state.recipeStatus[fam.id]
        if rc and rc.enabled then
            nEnabled = nEnabled + 1
            if not rc.forever then
                nTargetRec = nTargetRec + 1
            end
            if rSt then
                if #(rSt.activeDtpfs or {}) > 0 then
                    if rSt.isForever then nLoopRec = nLoopRec + 1 else nRunRec = nRunRec + 1 end
                elseif rSt.needsStock and not rSt.runnable then
                    nBlockedRec = nBlockedRec + 1
                elseif not rSt.needsStock and not rSt.isForever then
                    nFull = nFull + 1
                    fullNames[#fullNames + 1] = fam.name
                elseif rSt.needsStock and rSt.runnable then
                    nQueuedRec = nQueuedRec + 1
                end
            end
        end
    end

    return {
        nTotal = nTotal, nOnline = nOnline, nActive = nActive,
        nRun = nRun, nLoop = nLoop, nOd = nOd, nIdle = nIdle,
        nIssues = nIssues, convOn = convOn, minD = minD, maxD = maxD,
        nEnabled = nEnabled, nTargetRec = nTargetRec, nFull = nFull, nRunRec = nRunRec,
        nLoopRec = nLoopRec, nQueuedRec = nQueuedRec, nBlockedRec = nBlockedRec,
        fullNames = fullNames,
    }
end

local function formatCleanBridgeStatus(raw)
    local s = tostring(raw or "Idle")
    if s == "Idle (0 calls)" then return "Idle" end
    if s == "Ready (0 overhead)" then return "Ready" end
    return s
end

function UI:renderOverviewKpis(ov)
    local armed = (self.cfg.armed == true)
    local bns = (self.state and self.state.bottlenecks) or {}
    local cw = self.state and self.state.coverageWarning
    local meta = (self.state and self.state.lastPollMeta) or {}
    local upStr = formatLogUptime(meta.uptime or (self.state and self.state._lastPollUptime))

    -- Card 1: System Health (x = 2..40, w = 39) -> click opens [Log]
    local hBorder = (#bns > 0 or cw ~= nil or not armed) and COLORS.yellow or COLORS.green
    self:drawFrame(2, 5, 39, 5, hBorder, COLORS.panelBg, "round")
    self:addHitbox(2, 5, 40, 9, function()
        self.logModalActive = true
        self.logModalScroll = 0
    end)
    self:drawText(4, 6, "SYSTEM HEALTH", COLORS.muted, COLORS.panelBg)
    self:drawText(math.max(20, 40 - unicode.wlen(upStr) - 1), 6, upStr, COLORS.muted, COLORS.panelBg)
    if not armed then
        self:drawText(4, 7, "○ PAUSED (SAFE PREVIEW)", COLORS.yellow, COLORS.panelBg)
        local subWarn = (#bns > 0) and ("! " .. tostring(bns[1].name) .. ": " .. tostring(bns[1].reason))
            or (cw and ("! " .. tostring(cw.shortReason or cw.reason)))
            or "Read-only monitor; 0 writes"
        self:drawText(4, 8, padOrTrunc(subWarn, 35), COLORS.muted, COLORS.panelBg)
    elseif #bns > 0 then
        self:drawText(4, 7, string.format("! %d ALERT(S)", #bns), COLORS.yellow, COLORS.panelBg)
        self:drawText(4, 8, padOrTrunc(tostring(bns[1].name or "?") .. ": " .. tostring(bns[1].reason or "Blocked"), 35), COLORS.fg, COLORS.panelBg)
    elseif cw then
        self:drawText(4, 7, "! 24/7 DISCOUNT WARN", COLORS.yellow, COLORS.panelBg)
        self:drawText(4, 8, padOrTrunc(cw.shortReason or cw.reason, 35), COLORS.fg, COLORS.panelBg)
    else
        self:drawText(4, 7, "✓ ALL SYSTEMS HEALTHY", COLORS.green, COLORS.panelBg)
        self:drawText(4, 8, "All DTPFs & stock targets nominal", COLORS.muted, COLORS.panelBg)
    end

    -- Card 2: DTPF Fleet (x = 42..80, w = 39) -> click opens Fleet tab
    local fBorder = (ov.nOnline < ov.nTotal or ov.nIssues > 0) and COLORS.yellow or COLORS.green
    self:drawFrame(42, 5, 39, 5, fBorder, COLORS.panelBg, "round")
    self:addHitbox(42, 5, 80, 9, function() self.tab = TAB_FLEET end)
    self:drawText(44, 6, "DTPF FLEET", COLORS.muted, COLORS.panelBg)
    self:drawText(66, 6, "[2: Fleet →]", COLORS.cyan, COLORS.panelBg)
    local discTxt = (ov.minD == ov.maxD) and string.format("Disc %d%%", ov.maxD) or string.format("Disc %d-%d%%", ov.minD, ov.maxD)
    local fleetTop = (ov.nIssues > 0)
        and string.format("%d/%d Active · ! %d Issue(s)", ov.nActive, ov.nTotal, ov.nIssues)
        or string.format("%d/%d Active · %s", ov.nActive, ov.nTotal, discTxt)
    self:drawText(44, 7, padOrTrunc(fleetTop, 35), (ov.nIssues > 0 or ov.nOnline < ov.nTotal) and COLORS.yellow or COLORS.fg, COLORS.panelBg)
    local pwr = self.state and self.state.powerSummary
    local pwrTotal = (pwr and tonumber(pwr.totalEut)) or 0
    local fleetSub
    if pwrTotal > 0 then
        fleetSub = string.format("Q:%d·L:%d·4x:%d · ⚡%s/t", ov.nRun, ov.nLoop, ov.convOn, fmtCompactNum(pwrTotal, false))
    elseif ov.nOd > 0 then
        fleetSub = string.format("Queue:%d · Loop:%d · OD:%d · ⚡4x:%d", ov.nRun, ov.nLoop, ov.nOd, ov.convOn)
    else
        fleetSub = string.format("Queue:%d · Loop:%d · ⚡4x:%d/%d", ov.nRun, ov.nLoop, ov.convOn, ov.nOnline)
    end
    self:drawText(44, 8, padOrTrunc(fleetSub, 35), (pwrTotal >= 2e12) and COLORS.yellow or COLORS.muted, COLORS.panelBg)

    -- Card 3: Stock Targets (x = 82..120, w = 39) -> click opens Recipes tab
    local qBorder = (ov.nEnabled == 0 or ov.nBlockedRec > 0) and COLORS.yellow or COLORS.accent
    self:drawFrame(82, 5, 39, 5, qBorder, COLORS.panelBg, "round")
    self:addHitbox(82, 5, 120, 9, function() self.tab = TAB_RECIPES end)
    self:drawText(84, 6, "STOCK TARGETS", COLORS.muted, COLORS.panelBg)
    self:drawText(104, 6, "[3: Recipes →]", COLORS.cyan, COLORS.panelBg)
    local targetRow = ((ov.nTargetRec or 0) > 0)
        and string.format("%d / %d Targets Full", ov.nFull, ov.nTargetRec)
        or string.format("%d Active Loop(s)", ov.nLoopRec)
    local targetCol = ((ov.nTargetRec or 0) > 0 and ov.nFull == ov.nTargetRec) and COLORS.green or COLORS.fg
    self:drawText(84, 7, padOrTrunc(targetRow, 35), targetCol, COLORS.panelBg)
    self:drawText(84, 8, padOrTrunc(string.format("▶%d Crafting · ↻%d Loop%s · !%d Blocked",
        ov.nRunRec, ov.nLoopRec, (ov.nLoopRec == 1) and "" or "s", ov.nBlockedRec), 35),
        (ov.nBlockedRec > 0) and COLORS.yellow or COLORS.muted, COLORS.panelBg)

    -- Card 4: On-Demand & Bridge (x = 122..159, w = 38) -> click opens Setup tab
    local od = (self.state and self.state.onDemand) or {}
    local flushingNow = (self.state and self.state.odFlushActive == true)
    local canFlushOd = self.cfg.transposerAddr and self.cfg.transposerAddr ~= "" and self.cfg.transposerAddr ~= "none"
        and self.cfg.onDemandNetAddr and self.cfg.stockNetAddr
    local showOdFlushBtn = canFlushOd and (flushingNow or od.hasWork or ((od.totalCatalyst or 0) > 0))
    local odBorder = (flushingNow or od.stalled) and COLORS.yellow or (od.hasWork and COLORS.purple or COLORS.border)
    self:drawFrame(122, 5, 38, 5, odBorder, COLORS.panelBg, "round")
    self:addHitbox(122, 5, 159, 9, function() self.tab = TAB_SETUP end)
    if showOdFlushBtn then
        self:drawText(124, 6, "OD & BRIDGE", COLORS.muted, COLORS.panelBg)
        if flushingNow then
            self:drawButton(141, 6, "[Stop ]", COLORS.red, COLORS.btnBg, function()
                Scheduler.cancelOdFlush(self.cfg, self.state)
                self:setStatus("Cancelled OD flush.")
            end)
        else
            self:drawButton(141, 6, "[Flush]", od.stalled and COLORS.yellow or COLORS.purple, COLORS.btnBg, function()
                Scheduler.requestOdFlush(self.state)
                self:setStatus("Flushing Color 1 OD inputs -> Passive -> Main AE2...")
            end)
        end
    else
        self:drawText(124, 6, "ON-DEMAND & BRIDGE", COLORS.muted, COLORS.panelBg)
    end
    self:drawText(150, 6, "[Setup →]", COLORS.cyan, COLORS.panelBg)
    if flushingNow then
        self:drawText(124, 7, "↻ FLUSHING OD -> MAIN AE2", COLORS.yellow, COLORS.panelBg)
    elseif od.stalled then
        self:drawText(124, 7, "! OD STALLED (Passives Running)", COLORS.yellow, COLORS.panelBg)
    elseif od.hasWork then
        self:drawText(124, 7, padOrTrunc("⚡ CRAFTING: " .. tostring(od.summary or "Active"), 34), COLORS.purple, COLORS.panelBg)
    else
        self:drawText(124, 7, "IDLE (Passive Queue Active)", COLORS.green, COLORS.panelBg)
    end
    self:drawText(124, 8, padOrTrunc("Bridge: " .. formatCleanBridgeStatus(self.state and self.state.odBridgeStatus), 34), COLORS.muted, COLORS.panelBg)
end

local function gatherProductionOverviewItems(self)
    local rows = {}
    local cw = self.state and self.state.coverageWarning
    if cw then
        rows[#rows + 1] = {
            group = 0,
            prio = 0,
            bottleneck = {
                name = cw.summary,
                reason = cw.reason,
                familyId = cw.familyId,
                dtpfIdx = cw.dtpfIdx,
                isCoverage = true,
            },
        }
    end
    local bns = (self.state and self.state.bottlenecks) or {}
    for bi = 1, #bns do
        local b = bns[bi]
        if b and not b.familyId then
            rows[#rows + 1] = { group = 0, prio = bi, bottleneck = b }
        end
    end

    for i = 1, #RecipesDB.FAMILIES do
        local fam = RecipesDB.FAMILIES[i]
        local rc = self.cfg.recipes[fam.id]
        local st = self.state and self.state.recipeStatus and self.state.recipeStatus[fam.id]
        if rc and st then
            local act = st.activeDtpfs or {}
            if #act > 0 then
                rows[#rows + 1] = { group = st.isForever and 3 or 2, prio = rc.priority or i, fam = fam, rc = rc, st = st }
            elseif rc.enabled and st.needsStock and not st.runnable then
                rows[#rows + 1] = { group = 1, prio = rc.priority or i, fam = fam, rc = rc, st = st }
            elseif rc.enabled and st.needsStock and st.runnable then
                rows[#rows + 1] = { group = 4, prio = rc.priority or i, fam = fam, rc = rc, st = st }
            end
        end
    end
    table.sort(rows, function(a, b)
        if a.group ~= b.group then return a.group < b.group end
        return a.prio < b.prio
    end)
    return rows
end

local function gatherSatisfiedTargetItems(self)
    local full = {}
    for i = 1, #RecipesDB.FAMILIES do
        local fam = RecipesDB.FAMILIES[i]
        local rc = self.cfg.recipes[fam.id]
        local rSt = self.state and self.state.recipeStatus and self.state.recipeStatus[fam.id]
        if rc and rc.enabled and (not rc.forever) and rSt and (not rSt.needsStock) and (not rSt.isForever) then
            full[#full + 1] = { prio = rc.priority or i, fam = fam, rc = rc, st = rSt }
        end
    end
    table.sort(full, function(a, b) return a.prio < b.prio end)
    return full
end

function UI:renderOverviewProductionPanel(ov)
    -- Left Panel: Spacious Recipe-Aggregated Production & Alerts (x = 2..79, y = 11..48)
    self:drawFrame(2, 11, 78, 38, COLORS.border, COLORS.panelBg, "round")
    self:drawText(4, 11, " ◈ ACTIVE PRODUCTION & ALERTS ", COLORS.accent, COLORS.panelBg)
    self:drawButton(65, 11, "[Recipes →]", COLORS.cyan, COLORS.btnBg, function()
        self.tab = TAB_RECIPES
    end)

    local rows = gatherProductionOverviewItems(self)
    local fullItems = gatherSatisfiedTargetItems(self)
    local total = #rows
    local showFullList = (#fullItems > 0) and (total <= 6)
    local prodBottomY = showFullList and 30 or 44

    if total == 0 then
        self:drawText(5, 14, (ov.nEnabled > 0) and "✓ All enabled targets are satisfied!" or "No passive recipes enabled.",
            (ov.nEnabled > 0) and COLORS.green or COLORS.yellow, COLORS.panelBg)
    else
        local stride = ((not showFullList and total <= 8) or (showFullList and total <= 5)) and 3 or 2
        local maxVis = math.max(1, math.floor((prodBottomY - 12) / stride))
        local maxScroll = math.max(0, total - maxVis)
        self.overviewRecScroll = math.max(0, math.min(maxScroll, self.overviewRecScroll or 0))
        local showN = math.min(maxVis, total - self.overviewRecScroll)

        for k = 1, showN do
            local item = rows[k + self.overviewRecScroll]
            local by = 13 + (k - 1) * stride
            local titleLeft, titleCol, rightTag, rightCol, subTxt, subCol

            if item.group == 0 then
                local b = item.bottleneck
                titleLeft = "! " .. tostring(b.name or "System Alert")
                titleCol = COLORS.yellow
                rightTag = "ALERT"
                rightCol = COLORS.yellow
                subTxt = tostring(b.reason or "Check [4] SETUP")
                subCol = COLORS.yellow
                self:addHitbox(4, by, 77, by + 1, function()
                    if b.familyId then
                        self.selectedFamilyId = b.familyId
                        self.tab = TAB_RECIPES
                    elseif b.dtpfIdx or b.isCoverage then
                        if b.dtpfIdx then
                            self.selectedDtpf = b.dtpfIdx
                            self:ensureDtpfVisible(b.dtpfIdx)
                        end
                        self.tab = TAB_FLEET
                    else
                        self.tab = TAB_SETUP
                    end
                end)
            else
                local fam, rc, st = item.fam, item.rc, item.st
                local isFl = st.trackedOutput and (st.trackedOutput.isFluid or st.trackedOutput.type == "fluid")
                self:addHitbox(4, by, 77, by + 1, function()
                    self.selectedFamilyId = fam.id
                    self.tab = TAB_RECIPES
                end)

                if item.group == 1 then
                    titleLeft = "! " .. tostring(fam.name)
                    titleCol = COLORS.yellow
                    rightTag = "BLOCKED"
                    rightCol = COLORS.yellow
                    subTxt = localizeCoilStatus(self, st.stateStr or "Blocked")
                    subCol = COLORS.yellow
                elseif item.group == 2 then
                    local nAct = #(st.activeDtpfs or {})
                    local dList = formatDtpfIdList(st.activeDtpfs, 4)
                    titleLeft = "▶ " .. tostring(fam.name)
                    titleCol = COLORS.fg
                    rightTag = string.format("x%d DTPF%s (%s)", nAct, (nAct == 1) and "" or "s", dList)
                    rightCol = COLORS.green
                elseif item.group == 3 then
                    local dList = formatDtpfIdList(st.activeDtpfs, 4)
                    titleLeft = "↻ " .. tostring(fam.name)
                    titleCol = COLORS.fg
                    rightTag = "24/7 Loop (" .. dList .. ")"
                    rightCol = COLORS.cyan
                    local rate = st.ratePerMin
                    local rateTxt = (rate and math.abs(rate) >= 1)
                        and string.format("Rate: %s%s/m", (rate >= 0) and "+" or "", fmtCompactNum(rate, isFl))
                        or "Continuous discount keeper"
                    subTxt = string.format("Stock: %s   %s", fmtCompactNum(st.currentStock or 0, isFl), rateTxt)
                    subCol = COLORS.muted
                else
                    titleLeft = "… " .. tostring(fam.name)
                    titleCol = COLORS.fg
                    rightTag = "QUEUED"
                    rightCol = COLORS.accent
                    subTxt = string.format("Stock: %s / %s   Waiting for free DTPF",
                        fmtCompactNum(st.currentStock or 0, isFl), fmtCompactNum(rc.target or 1, isFl))
                    subCol = COLORS.muted
                end
            end

            local rightW = unicode.wlen(rightTag)
            local leftMax = math.max(16, 72 - rightW - 2)
            self:drawText(5, by, padOrTrunc(titleLeft, leftMax), titleCol, COLORS.panelBg)
            self:drawText(math.max(5, 77 - rightW), by, rightTag, rightCol, COLORS.panelBg)

            if item.group == 2 then
                local st, rc = item.st, item.rc
                local isFl = st.trackedOutput and (st.trackedOutput.isFluid or st.trackedOutput.type == "fluid")
                local pct = math.min(99, math.floor((st.ratio or 0) * 100 + 0.5))
                local etaStr = (st.etaSec and st.etaSec > 0) and ("   ~" .. (UI.formatDurationShort(st.etaSec) or "")) or ""
                local barStr = buildProgressBar(st.ratio or 0, 20)
                self:drawText(7, by + 1, barStr, COLORS.cyan, COLORS.panelBg)
                local detail = string.format("%3d%%   %s / %s%s",
                    pct, fmtCompactNum(st.currentStock or 0, isFl), fmtCompactNum(rc.target or 1, isFl), etaStr)
                self:drawText(30, by + 1, padOrTrunc(detail, 47), COLORS.muted, COLORS.panelBg)
            else
                self:drawText(7, by + 1, padOrTrunc(subTxt or "", 70), subCol or COLORS.muted, COLORS.panelBg)
            end
        end

        if total > maxVis then
            self:drawButton(4, 48, "[▲]", (self.overviewRecScroll > 0) and COLORS.fg or COLORS.muted, COLORS.btnBg, function()
                self.overviewRecScroll = math.max(0, self.overviewRecScroll - 3)
            end)
            self:drawButton(8, 48, "[▼]", (self.overviewRecScroll < maxScroll) and COLORS.fg or COLORS.muted, COLORS.btnBg, function()
                self.overviewRecScroll = math.min(maxScroll, self.overviewRecScroll + 3)
            end)
        end
    end

    if showFullList then
        self:drawText(4, 31, string.rep("─", 74), COLORS.border, COLORS.panelBg)
        self:drawText(5, 31, string.format(" ◈ STOCK TARGETS FULL (%d / %d) ", #fullItems, ov.nTargetRec), COLORS.accent, COLORS.panelBg)

        local startY = 33
        local availH = 14 -- rows 33..46
        local fStride = (#fullItems * 2 <= availH) and 2 or 1
        local maxFit = math.max(1, math.floor(availH / fStride))
        local reserveMore = (#fullItems > maxFit) and 1 or 0
        local showFull = math.min(#fullItems, math.max(1, maxFit - reserveMore))

        for k = 1, showFull do
            local entry = fullItems[k]
            local fam, rc, st = entry.fam, entry.rc, entry.st
            local fy = startY + (k - 1) * fStride
            local isFl = st.trackedOutput and (st.trackedOutput.isFluid or st.trackedOutput.type == "fluid")
            self:addHitbox(4, fy, 77, fy, function()
                self.selectedFamilyId = fam.id
                self.tab = TAB_RECIPES
            end)
            self:drawText(5, fy, "✓", COLORS.green, COLORS.panelBg)
            self:drawText(7, fy, padOrTrunc(fam.name, 42), COLORS.fg, COLORS.panelBg)
            local stkTxt = fmtCompactNum(st.currentStock or 0, isFl)
            local tgtTxt = " / " .. fmtCompactNum(rc.target or 1, isFl)
            local totalW = unicode.wlen(stkTxt) + unicode.wlen(tgtTxt)
            local sx = math.max(50, 77 - totalW)
            self:drawText(sx, fy, stkTxt, COLORS.green, COLORS.panelBg)
            self:drawText(sx + unicode.wlen(stkTxt), fy, tgtTxt, COLORS.muted, COLORS.panelBg)
        end

        if #fullItems > showFull then
            local rem = #fullItems - showFull
            local moreY = math.min(47, startY + showFull * fStride)
            self:drawText(7, moreY, string.format("+%d more satisfied target(s) in [3: Recipes]", rem), COLORS.muted, COLORS.panelBg)
            self:addHitbox(4, moreY, 77, moreY, function() self.tab = TAB_RECIPES end)
        end
    else
        self:drawText(4, 45, string.rep("─", 74), COLORS.border, COLORS.panelBg)
        if #ov.fullNames > 0 then
            local shown = {}
            for k = 1, math.min(3, #ov.fullNames) do
                shown[k] = compactRecipeName(ov.fullNames[k], 15)
            end
            local suffix = (#ov.fullNames > 3) and string.format(" (+%d)", #ov.fullNames - 3) or ""
            local fullMsg = string.format("✓ %d Stock Target(s) Full: %s%s", #ov.fullNames, table.concat(shown, ", "), suffix)
            self:drawText(5, 46, padOrTrunc(fullMsg, 72), COLORS.green, COLORS.panelBg)
        else
            local emptyMsg = (ov.nTargetRec == 0)
                and "All active DTPFs dedicated to 24/7 loops"
                or "No stock targets filled yet — active items running above"
            self:drawText(5, 46, padOrTrunc(emptyMsg, 72), COLORS.muted, COLORS.panelBg)
        end
    end
end

function UI:renderOverviewRightPanel()
    -- Right Panel: Spacious Catalyst & DTR Reserves + Human-Only Recent Milestones (x = 82..159, y = 11..48)
    self:drawFrame(82, 11, 78, 38, COLORS.border, COLORS.panelBg, "round")
    self:drawText(84, 11, " ◈ CATALYST & DTR RESERVES ", COLORS.accent, COLORS.panelBg)
    self:drawButton(148, 11, "[Setup →]", COLORS.cyan, COLORS.btnBg, function()
        self.tab = TAB_SETUP
    end)

    local fluids = (self.state and self.state.stock and self.state.stock.fluids) or {}
    local reserveRows = {}
    for i = 1, #RecipesDB.CATALYST_TIERS do
        local ct = RecipesDB.CATALYST_TIERS[i]
        local flr = (self.cfg.catalystFloors and self.cfg.catalystFloors[ct.code]) or 100000
        reserveRows[i] = { name = ct.code, amt = fluids[ct.fluid] or 0, floor = flr, isDtr = false }
    end
    reserveRows[6] = {
        name = "DTR",
        amt = fluids["dimensionallytranscendentresidue"] or 0,
        floor = self.cfg.dtrReserveFloor or 10000000,
        isDtr = true,
    }

    for i = 1, 6 do
        local rr = reserveRows[i]
        local ry = 13 + (i - 1) * 3
        self:addHitbox(84, ry, 157, ry, function()
            local promptTitle = rr.isDtr and "DTR Reserve Floor (L):" or (rr.name .. " Reserve Floor (L):")
            self:openNumberPrompt(promptTitle, UI.formatNumber(rr.floor, true), function(num)
                if rr.isDtr then
                    self.cfg.dtrReserveFloor = num
                else
                    self.cfg.catalystFloors = self.cfg.catalystFloors or {}
                    self.cfg.catalystFloors[rr.name] = num
                end
                self:save(rr.name .. " reserve floor -> " .. UI.formatNumber(num, true))
            end)
        end)

        local ok = (rr.amt > rr.floor)
        local col = (rr.amt <= 0) and COLORS.red or (ok and COLORS.green or COLORS.yellow)
        local ratio = rr.amt / math.max(1, rr.floor)
        local norm = 0
        if rr.amt > 0 then
            if ratio < 1.0 then
                norm = 0.25 * ratio
            else
                norm = 0.25 + 0.75 * math.min(1.0, (math.log(ratio) / 2.302585092994046) / 3.0)
            end
        end
        local filled = math.max(0, math.min(24, math.floor(norm * 24 + 0.5)))

        local note
        if rr.isDtr and self.state and self.state.dtrRatePerMin and math.abs(self.state.dtrRatePerMin) >= 1 then
            local r = self.state.dtrRatePerMin
            note = string.format("%s%s/m", (r >= 0) and "+" or "", fmtCompactNum(r, true))
        elseif rr.amt <= 0 then
            note = "Empty"
        elseif not ok then
            note = "<= Floor"
        elseif rr.floor > 0 then
            note = string.format("%.1fx Floor", math.min(999.9, rr.amt / rr.floor))
        else
            note = "OK"
        end

        self:drawText(85, ry, rr.name, COLORS.fg, COLORS.panelBg)
        self:drawText(92, ry, "[", COLORS.muted, COLORS.panelBg)
        if filled > 0 then
            self:drawText(93, ry, string.rep("━", filled), col, COLORS.panelBg)
        end
        if filled < 24 then
            self:drawText(93 + filled, ry, string.rep("─", 24 - filled), COLORS.border, COLORS.panelBg)
        end
        self:drawText(117, ry, "]", COLORS.muted, COLORS.panelBg)

        local amtStr = UI.formatNumber(rr.amt, true)
        local flrStr = " / " .. UI.formatNumber(rr.floor, true)
        self:drawText(120, ry, padOrTrunc(amtStr, 9), col, COLORS.panelBg)
        self:drawText(120 + math.min(9, unicode.wlen(amtStr)), ry, padOrTrunc(flrStr, 12), COLORS.muted, COLORS.panelBg)
        self:drawText(143, ry, padOrTrunc(note, 15), col, COLORS.panelBg)
    end

    self:drawText(84, 31, string.rep("─", 74), COLORS.border, COLORS.panelBg)
    self:drawText(85, 31, " ◈ RECENT MILESTONES ", COLORS.accent, COLORS.panelBg)
    self:drawButton(149, 31, "[Log →]", COLORS.cyan, COLORS.panelBg, function()
        self.logModalActive = true
        self.logModalScroll = 0
    end)

    local events = (self.state and self.state.events) or {}
    local milestones = {}
    for i = 1, #events do
        local ev = events[i]
        if ev and (tonumber(ev.minLevel) or 1) <= 1 then
            milestones[#milestones + 1] = ev
            if #milestones >= 7 then break end
        end
    end

    if #milestones == 0 then
        self:drawText(85, 35, "All systems steady - no recent transitions.", COLORS.muted, COLORS.panelBg)
    else
        local mStride = (#milestones <= 6) and 2 or 1
        for k = 1, #milestones do
            local ev = milestones[k]
            local ry = 33 + (k - 1) * mStride
            self:addHitbox(84, ry, 157, ry, function()
                self.logModalActive = true
                self.logModalScroll = 0
            end)
            self:drawText(85, ry, formatLogUptime(ev.uptime), COLORS.muted, COLORS.panelBg)
            self:drawText(96, ry, padOrTrunc(tostring(ev.text or ""), 61), getEventLineColor(ev), COLORS.panelBg)
        end
    end
end

function UI:renderOverviewTab()
    local ov = gatherOverviewStats(self)
    self:renderOverviewKpis(ov)
    self:renderOverviewProductionPanel(ov)
    self:renderOverviewRightPanel()
end

function UI:renderRecipeListPane(list, pinnedByFam, rankById)
    -- LEFT PANE: Clean Filterable Recipe Catalog (x = 2..82)
    local fx = 2
    local filters = {
        { id = "all", label = string.format("[ALL %d]", #RecipesDB.FAMILIES) },
        { id = "enabled", label = "[ENABLED]" },
        { id = "loops", label = "[24/7 LOOP]" },
        { id = "nocat", label = "[CAT-FREE]" },
        { id = "blocked", label = "[! BLOCKED]" },
    }
    for i = 1, #filters do
        local fl = filters[i]
        local active = (self.recipeFilter == fl.id)
        fx = self:drawButton(fx, 4, fl.label,
            active and COLORS.fg or COLORS.muted,
            active and COLORS.btnActiveBg or COLORS.btnBg,
            function()
                self.recipeFilter = fl.id
                self.recipeScroll = 0
            end) + 1
    end

    self:fillRect(2, 5, 80, 1, " ", COLORS.headerBg)
    self:drawText(3, 5, "ON", COLORS.muted, COLORS.headerBg)
    self:drawText(8, 5, "#", COLORS.muted, COLORS.headerBg)
    self:drawText(14, 5, "RECIPE FAMILY", COLORS.muted, COLORS.headerBg)
    self:drawText(47, 5, "STOCK / TARGET", COLORS.muted, COLORS.headerBg)
    self:drawText(65, 5, "STATUS", COLORS.muted, COLORS.headerBg)

    local maxRows = self.h - 8 -- rows 6..47
    self.recipeScroll = math.max(0, math.min(math.max(0, #list - maxRows), self.recipeScroll))

    for r = 1, maxRows do
        local y = 5 + r
        local idx = r + self.recipeScroll
        local entry = list[idx]
        if not entry then
            self:fillRect(2, y, 80, 1, " ", COLORS.panelBg)
        else
            local fam = entry.fam
            local rc = entry.rc
            local st = (self.state.recipeStatus and self.state.recipeStatus[fam.id]) or {}
            local isSel = (fam.id == self.selectedFamilyId)
            local rowBg = isSel and COLORS.selectedBg or ((r % 2 == 0) and COLORS.rowAltBg or COLORS.panelBg)
            self:fillRect(2, y, 80, 1, " ", rowBg)

            -- Full-row selection hitbox BEFORE inner [ON] button so reverse hit-testing hits [ON] first
            self:addHitbox(2, y, 81, y, function()
                self.selectedFamilyId = fam.id
            end)

            self:drawButton(3, y, rc.enabled and "[ON]" or "[--]", rc.enabled and COLORS.green or COLORS.muted, COLORS.btnBg, function()
                rc.enabled = not rc.enabled
                self.selectedFamilyId = fam.id
                self:save((rc.enabled and "Enabled " or "Disabled ") .. fam.name)
            end)

            local isFb = (rc.forever == true) or (self.cfg.fallbackEnabled and self.cfg.fallbackFamilyId == fam.id)
            local isPinned = pinnedByFam[fam.id] ~= nil
            local markCh = isPinned and "◆" or (isFb and "*" or " ")
            local markCol = isPinned and (isFb and COLORS.yellow or COLORS.cyan) or (isFb and COLORS.cyan or COLORS.muted)
            self:drawText(8, y, string.format("%02d%s", rankById[fam.id] or idx, markCh), isSel and COLORS.cyan or markCol, rowBg)

            local catIco, catIcoCol = getCategoryBadge(fam.category)
            self:drawText(12, y, catIco, catIcoCol, rowBg)
            self:drawText(14, y, padOrTrunc(compactRecipeName(fam.name, 32), 32), isSel and COLORS.cyan or (rc.enabled and COLORS.fg or COLORS.muted), rowBg)

            local isFluid = st.trackedOutput and (st.trackedOutput.isFluid or st.trackedOutput.type == "fluid")
            local stockTxt = isFb
                and string.format("%s / 24/7", fmtCompactNum(st.currentStock or 0, isFluid))
                or string.format("%s / %s", fmtCompactNum(st.currentStock or 0, isFluid), fmtCompactNum(rc.target or 1, isFluid))
            self:drawText(47, y, padOrTrunc(stockTxt, 17), isFb and COLORS.cyan or getStockRatioColor(st.ratio or 0, rc.enabled), rowBg)

            local sStr = localizeCoilStatus(self, st.stateStr or "Disabled")
            local sCol = COLORS.muted
            if sStr:find("Running", 1, true) or sStr:find("Would Run", 1, true) or sStr:find("Full", 1, true) then sCol = COLORS.green
            elseif sStr:find("Loop", 1, true) or sStr:find("24/7", 1, true) or sStr:find("Fallback", 1, true) then sCol = COLORS.cyan
            elseif sStr:find("Low", 1, true) or sStr:find("Guard", 1, true) or sStr:find("Missing", 1, true) or sStr:find("DTR", 1, true) or sStr:find("Coil", 1, true) then sCol = COLORS.yellow
            elseif sStr:find("Queued", 1, true) then sCol = COLORS.accent
            end
            self:drawText(65, y, padOrTrunc(compactStatusText(sStr, 15), 15), sCol, rowBg)
            if isSel then
                self:drawText(81, y, "▸", COLORS.cyan, rowBg)
            end
        end
    end

    if #list > maxRows then
        self:drawButton(2, 48, "[▲ PgUp]", COLORS.fg, COLORS.btnBg, function()
            self.recipeScroll = math.max(0, self.recipeScroll - 10)
        end)
        self:drawButton(11, 48, "[▼ PgDn]", COLORS.fg, COLORS.btnBg, function()
            self.recipeScroll = math.min(math.max(0, #list - maxRows), self.recipeScroll + 10)
        end)
        self:drawText(21, 48, string.format("%d shown | * 24/7  ◆ Pinned | ◈Fluid ▣Item ⊕Hybrid", #list), COLORS.muted, COLORS.bg)
    else
        self:drawText(2, 48, "* 24/7  ◆ Pinned  │  ◈ Fluid  ▣ Item  ⊕ Hybrid (Fluid+Item)", COLORS.muted, COLORS.bg)
    end
end

function UI:renderRecipeInspectorPane(fam, pinnedByFam, rankById)
    -- RIGHT PANE: Selected Recipe Inspector (x = 85..159, w = 75)
    self:fillRect(85, 5, 75, 44, " ", COLORS.panelBg)
    if not fam then return end

    local rc = self.cfg.recipes[fam.id]
    local st = (self.state.recipeStatus and self.state.recipeStatus[fam.id]) or {}
    local isLoopMode = isFamilyLoop(self.cfg, fam.id, rc)
    local convCtrlOk = self:isConvControlSupported()
    local effRecConv
    if convCtrlOk then
        local belowTgt = (st.convBelowTarget ~= nil) and st.convBelowTarget
            or ((st.currentStock or 0) < (rc.target or 1))
        effRecConv = Scheduler.doesJobWantConvergence(self.cfg, isLoopMode and "FALLBACK" or "PASSIVE", rc, "global", 50, belowTgt)
    else
        effRecConv = false
        for i = 1, #(self.state and self.state.dtpfStatus or {}) do
            local dst = self.state.dtpfStatus[i]
            if dst and dst.online and dst.convergenceEnabled then
                effRecConv = true
                break
            end
        end
    end
    local mod, tCode, tIdx, tData, _, tInfo, meta = Scheduler.resolveRecipe(fam, rc, self.cfg, self.state.stock, {
        wantConvergence = effRecConv,
        isFallback = isLoopMode,
    })

    self:drawText(85, 4, "◈ RECIPE INSPECTOR", COLORS.accent, COLORS.bg)
    self:drawButton(150, 4, "[<- Fleet]", COLORS.cyan, COLORS.btnBg, function()
        self.tab = TAB_FLEET
    end)

    local rawState = localizeCoilStatus(self, st.stateStr or (rc.enabled and "Ready" or "Disabled"))
    local nameDisp = compactRecipeName(fam.name, 48)
    local maxStW = math.max(18, 158 - (89 + unicode.wlen(nameDisp) + 2))
    local inspState = compactStatusText(rawState, maxStW)
    if unicode.wlen(inspState) > maxStW then
        inspState = unicode.sub(inspState, 1, maxStW - 1) .. "…"
    end
    local stLen = unicode.wlen(inspState)
    local nameColW = math.max(14, 158 - stLen - 2 - 89)
    local inspCol = COLORS.muted
    if rawState:find("Running", 1, true) or rawState:find("Would Run", 1, true) or rawState:find("Full", 1, true) or rawState:find("Target Met", 1, true) then
        inspCol = COLORS.green
    elseif rawState:find("Fallback", 1, true) or rawState:find("Loop", 1, true) or rawState:find("24/7", 1, true) then
        inspCol = COLORS.cyan
    elseif rawState:find("Low", 1, true) or rawState:find("Guard", 1, true) or rawState:find("Missing", 1, true) or rawState:find("DTR", 1, true) or rawState:find("Coil", 1, true) or rawState:find("Stalled", 1, true) then
        inspCol = COLORS.yellow
    elseif rawState:find("Queued", 1, true) or rc.enabled then
        inspCol = COLORS.accent
    end
    for ry = 5, 48 do
        self:drawText(85, ry, "┃", inspCol, COLORS.panelBg)
    end
    local rCatIco, rCatCol = getCategoryBadge(fam.category)
    self:drawText(87, 5, rCatIco, rCatCol, COLORS.panelBg)
    self:drawText(89, 5, padOrTrunc(compactRecipeName(fam.name, nameColW), nameColW), COLORS.cyan, COLORS.panelBg)
    self:drawText(159 - stLen, 5, inspState, inspCol, COLORS.panelBg)

    local rawHeat = (tData and tData.coilHeat) or 10800
    local _, rCoilCol, coilTierTag = getCoilTierInfo(rawHeat)
    local coilSeg = "Coil:" .. (self:isCoilNameMode() and coilTierTag or (formatInt(rawHeat) .. "K"))
    local dtrArrow = (fam.dtrRole == "producer" and "▲prod") or (fam.dtrRole == "consumer" and "▼cons") or "·neut"
    local durSec = ((tData and tData.durationTicks) or 0) / 20
    local eutAmt = (tData and tData.eut) or 0
    local preSeg = string.format("%s | DTR:%s | ", tostring(fam.category or "?"), dtrArrow)
    local postSeg = string.format(" | %.1fs | EU/t:%s", durSec, UI.formatNumber(eutAmt, false))
    if unicode.wlen(preSeg) + unicode.wlen(coilSeg) + unicode.wlen(postSeg) > 72 then
        local catShort = tostring(fam.category or "?")
        preSeg = string.format("%s · DTR:%s · ", catShort, dtrArrow)
        postSeg = string.format(" · %.1fs · EU/t:%s", durSec, fmtCompactNum(eutAmt, false))
    end
    local preW = unicode.wlen(preSeg)
    local coilW = unicode.wlen(coilSeg)
    self:drawText(87, 6, preSeg, COLORS.muted, COLORS.panelBg)
    self:drawText(87 + preW, 6, coilSeg, rCoilCol, COLORS.panelBg)
    if 72 - preW - coilW > 0 then
        self:drawText(87 + preW + coilW, 6, padOrTrunc(postSeg, 72 - preW - coilW), COLORS.muted, COLORS.panelBg)
    end
    self:addHitbox(87 + preW, 6, 87 + preW + coilW - 1, 6, function()
        self:toggleCoilDisplay()
    end)

    -- Row 8: Enable + Queue Mode (<Target vs 24/7 Loop) + Priority controls
    local bx = self:drawButton(87, 8, rc.enabled and "[● ON ]" or "[○ OFF]",
        rc.enabled and COLORS.green or COLORS.muted, rc.enabled and COLORS.darkGreen or COLORS.btnBg, function()
            rc.enabled = not rc.enabled
            self:save(fam.name .. " enabled -> " .. (rc.enabled and "ON" or "OFF"))
        end) + 2
    self:drawText(bx, 8, "Mode:", COLORS.muted, COLORS.panelBg)
    bx = bx + 6
    bx = self:drawButton(bx, 8, "[<Target]",
        (not isLoopMode) and COLORS.fg or COLORS.muted,
        (not isLoopMode) and COLORS.btnActiveBg or COLORS.btnBg,
        function()
            rc.forever = false
            self:save(fam.name .. " mode -> Stop at Target (<Target)")
        end) + 1
    bx = self:drawButton(bx, 8, "[24/7 Loop]",
        isLoopMode and COLORS.fg or COLORS.cyan,
        isLoopMode and COLORS.btnActiveBg or COLORS.btnBg,
        function()
            rc.forever = true
            rc.enabled = true
            self:save(fam.name .. " mode -> Run 24/7 (Priority Queue)")
        end) + 1
    local isFbPrimary = (self.cfg.fallbackEnabled == true) and (self.cfg.fallbackFamilyId == fam.id)
    self:drawButton(bx, 8, isFbPrimary and "[*Fallback]" or "[Fallback]",
        isFbPrimary and COLORS.cyan or COLORS.muted,
        isFbPrimary and COLORS.btnActiveBg or COLORS.btnBg,
        function()
            if isFbPrimary then
                self.cfg.fallbackEnabled = false
                self:save("Disabled global Fallback (" .. fam.name .. ")")
            else
                self.cfg.fallbackFamilyId = fam.id
                self.cfg.fallbackEnabled = true
                self:save("Fallback recipe -> " .. fam.name)
            end
        end)

    local myRank = rankById[fam.id] or 1
    local rankStr = string.format("Prio: #%d", myRank)
    local prx = 158 - 7 - unicode.wlen(rankStr) - 1
    self:drawText(prx, 8, rankStr, COLORS.fg, COLORS.panelBg)
    local ubtn = self:drawButton(prx + unicode.wlen(rankStr) + 1, 8, "[▲]", COLORS.fg, COLORS.btnBg, function(_, button)
        local dlt = (button == 1) and "top" or -1
        Scheduler.moveRecipePriority(self.cfg, fam.id, dlt, false)
        self:save((button == 1) and ("Moved " .. fam.name .. " to top.") or ("Moved " .. fam.name .. " up."))
    end) + 1
    self:drawButton(ubtn, 8, "[▼]", COLORS.fg, COLORS.btnBg, function(_, button)
        local dlt = (button == 1) and "bottom" or 1
        Scheduler.moveRecipePriority(self.cfg, fam.id, dlt, false)
        self:save((button == 1) and ("Moved " .. fam.name .. " to bottom.") or ("Moved " .. fam.name .. " down."))
    end)

    -- Row 9: Assignment status + contextual Max: cap + [Pin to a DTPF…] modal launcher
    local pinSummary = "Assignment: Priority Queue"
    local pinCol = COLORS.muted
    local pinnedList = pinnedByFam[fam.id]
    if pinnedList and #pinnedList > 0 then
        local pNames = {}
        for i = 1, math.min(3, #pinnedList) do pNames[i] = pinnedList[i].name end
        pinSummary = "Pinned to: " .. table.concat(pNames, ", ") .. (#pinnedList > 3 and "…" or "")
        pinCol = COLORS.cyan
    elseif st.activeDtpfs and #st.activeDtpfs > 0 then
        pinSummary = "Running on: " .. formatDtpfIdList(st.activeDtpfs, 8)
        pinCol = COLORS.green
    end
    local showMaxBtn = (self.cfg.allowParallelSameRecipe == true)
    local pinSummaryW = 51
    if showMaxBtn then
        local maxCap = math.max(0, math.floor(tonumber(rc.maxDtpfs) or 0))
        local maxLbl = (maxCap > 0) and string.format("[Max:%d DTPF]", maxCap) or "[Max:All]"
        local maxX = 140 - unicode.wlen(maxLbl)
        pinSummaryW = math.max(12, maxX - 88)
        self:drawButton(maxX, 9, maxLbl,
            (maxCap > 0) and COLORS.fg or COLORS.muted,
            (maxCap > 0) and COLORS.btnActiveBg or COLORS.btnBg,
            function(step)
                local lim = math.max(1, #self.cfg.dtpfs)
                local nxt = (maxCap + (step or 1)) % (lim + 1)
                rc.maxDtpfs = nxt
                self:save(fam.name .. " Parallel Cap -> " .. ((nxt > 0) and (nxt .. " DTPF") or "All"))
            end)
    end
    self:drawText(87, 9, padOrTrunc(pinSummary, pinSummaryW), pinCol, COLORS.panelBg)
    self:drawButton(141, 9, "[Pin to a DTPF…]", COLORS.cyan, COLORS.btnBg, function()
        self:openPassiveModal(self.selectedDtpf or 1, fam.id)
    end)

    -- Row 10-12: Stock, Editable Target chip, Presets (when <Target), Multi-Output picker (when #outs > 1)
    local outs = Scheduler.getOutputCandidates(tData, fam)
    local outIdx = math.max(1, math.min(#outs, rc.outputIndex or 1))
    local trackedOut = outs[outIdx] or fam.primaryOutput
    local isFluid = trackedOut and (trackedOut.isFluid or trackedOut.type == "fluid")

    local curY = 11
    if isLoopMode then
        local rateSuffix = ""
        if st.ratePerMin and math.abs(st.ratePerMin) >= 1 then
            rateSuffix = string.format(" | %s%s/m",
                (st.ratePerMin >= 0) and "+" or "",
                fmtCompactNum(st.ratePerMin, isFluid))
        end
        if rc.convMode == "below_tgt" then
            local stkPrefix = string.format("Stock: %s  (24/7%s) ", UI.formatNumber(st.currentStock or 0, isFluid), rateSuffix)
            self:drawText(87, curY, padOrTrunc(stkPrefix, 44), COLORS.cyan, COLORS.panelBg)
            local btnX = math.min(134, 87 + unicode.wlen(stkPrefix))
            local btnLbl = "[Conv < " .. UI.formatNumber(rc.target or 1, isFluid) .. "…]"
            local btnCol = (st.convBelowTarget == true) and COLORS.cyan or COLORS.green
            self:drawButton(btnX, curY, padOrTrunc(btnLbl, 158 - btnX), btnCol, COLORS.btnBg, function()
                self:openTargetPrompt(fam, rc, trackedOut)
            end)
        else
            self:drawText(87, curY, padOrTrunc(string.format("Stock: %s  (24/7 Loop%s)",
                UI.formatNumber(st.currentStock or 0, isFluid), rateSuffix), 71), COLORS.cyan, COLORS.panelBg)
        end
        curY = curY + 1
    else
        local stkRatio = math.max(0, (st.currentStock or 0) / math.max(1, rc.target or 1))
        local stkPct = math.min(999, math.floor(stkRatio * 100 + 0.5))
        local stkTxt = string.format("Stock: %s", UI.formatNumber(st.currentStock or 0, isFluid))
        self:drawText(87, curY, stkTxt, COLORS.fg, COLORS.panelBg)
        local tgtX = 87 + unicode.wlen(stkTxt) + 2
        local tgtEnd = self:drawButton(tgtX, curY,
            "[Target: " .. UI.formatNumber(rc.target or 1, isFluid) .. "…]",
            COLORS.cyan, COLORS.btnBg, function()
                self:openTargetPrompt(fam, rc, trackedOut)
            end)
        local pctStr = string.format(" %d%%", stkPct)
        local etaStr = UI.formatDurationShort(st.etaSec)
        if etaStr and (158 - (tgtEnd + 1) - (unicode.wlen(pctStr) + #etaStr + 2)) >= 8 then
            pctStr = pctStr .. " ~" .. etaStr
        end
        local remBarW = math.max(6, 158 - (tgtEnd + 1) - unicode.wlen(pctStr))
        local barW = math.min(18, remBarW)
        if barW >= 6 then
            local barX = 158 - barW - unicode.wlen(pctStr)
            self:drawText(barX, curY, buildProgressBar(stkRatio, barW) .. pctStr, getStockRatioColor(stkRatio, true), COLORS.panelBg)
        end
        curY = curY + 1

        local presets = isFluid
            and { { "10M", 1e7 }, { "100M", 1e8 }, { "350M", 3.5e8 }, { "2B", 2e9 }, { "5B", 5e9 }, { "25B", 2.5e10 } }
            or { { "1K", 1e3 }, { "10K", 1e4 }, { "50K", 5e4 }, { "250K", 2.5e5 }, { "1M", 1e6 } }
        local px = 87
        for i = 1, #presets do
            local p = presets[i]
            local active = (rc.target == p[2])
            px = self:drawButton(px, curY, "[" .. p[1] .. "]",
                active and COLORS.fg or COLORS.accent,
                active and COLORS.btnActiveBg or COLORS.btnBg,
                function()
                    rc.target = p[2]
                    self:save(fam.name .. " target -> " .. p[1])
                end) + 1
        end
        self:drawButton(px, curY, "[Custom…]", COLORS.cyan, COLORS.btnBg, function()
            self:openTargetPrompt(fam, rc, trackedOut)
        end)
        curY = curY + 1
    end

    if #outs > 1 then
        self:drawText(87, curY, "Tracked Output:", COLORS.muted, COLORS.panelBg)
        self:drawButton(103, curY, padOrTrunc("[" .. tostring(trackedOut and trackedOut.label or "Output") .. "]", 53),
            COLORS.cyan, COLORS.btnBg, function()
                rc.outputIndex = (outIdx % #outs) + 1
                self:save(fam.name .. " tracked output -> " .. tostring(outs[rc.outputIndex].label))
            end)
        curY = curY + 1
    end
    curY = curY + 1

    -- Unified Variant & Catalyst Tier Selector
    local modList = fam.modifiers or {}
    local tierVars = (#modList <= 1) and getDistinctTierCodes(fam) or nil
    local isNone = (tInfo and not tInfo.usesCatalyst)

    if #modList > 1 then
        self:drawText(87, curY, string.format("RECIPE VARIANT (%d options):", #modList), COLORS.cyan, COLORS.panelBg)
        curY = curY + 1
        local curModIdx = rc.modifierIndex or 1
        for vi = 1, #modList do
            local vm = modList[vi]
            local isCur = (curModIdx == vi)
            local rLbl = string.format("%s %d. %s", isCur and "[●]" or "[ ]", vi, padOrTrunc(vm.label, 65))
            self:drawButton(87, curY, rLbl,
                isCur and COLORS.fg or COLORS.accent,
                isCur and COLORS.btnActiveBg or COLORS.btnBg,
                function()
                    rc.modifierIndex, rc.variantIndex, rc.outputIndex = vi, vi, 1
                    self:save(fam.name .. " variant -> " .. vm.label)
                end)
            curY = curY + 1
        end
        curY = curY + 1
    elseif tierVars then
        self:drawText(87, curY, "RECIPE VARIANT BY TIER:", COLORS.cyan, COLORS.panelBg)
        curY = curY + 1
        local curCat = rc.catalystTier or 0
        local isAuto = (curCat == 0)
        self:drawButton(87, curY, string.format("%s Auto (Global -> %s)", isAuto and "[●]" or "[ ]", tostring(tCode or "DTEC")),
            isAuto and COLORS.fg or COLORS.accent,
            isAuto and COLORS.btnActiveBg or COLORS.btnBg,
            function()
                rc.catalystTier = 0
                self:save(fam.name .. " variant tier -> Auto (Global)")
            end)
        curY = curY + 1

        local lblFreq = {}
        for _, tv in ipairs(tierVars) do
            local seenInTier = {}
            for _, ii in ipairs((tv.td and tv.td.itemsIn) or {}) do
                local lbl = tostring(ii.label or ii.name or "Item")
                if not seenInTier[lbl] then
                    seenInTier[lbl] = true
                    lblFreq[lbl] = (lblFreq[lbl] or 0) + 1
                end
            end
        end

        for _, tv in ipairs(tierVars) do
            local isCur = (curCat == tv.idx)
            local outItem = tv.td and tv.td.itemsOut and tv.td.itemsOut[1]
            local outFluid = tv.td and tv.td.fluidsOut and tv.td.fluidsOut[1]
            local outTag = outItem
                and string.format("%dx", math.floor(tonumber(outItem.amount) or 1))
                or (outFluid and fmtCompactNum(outFluid.amount or 0, true) or "1x")
            local uniqFirst, sharedRest = {}, {}
            local itemsIn = (tv.td and tv.td.itemsIn) or {}
            for iiIdx = #itemsIn, 1, -1 do
                local lbl = tostring(itemsIn[iiIdx].label or itemsIn[iiIdx].name or "Item")
                if (lblFreq[lbl] or 0) < #tierVars then
                    uniqFirst[#uniqFirst + 1] = lbl
                else
                    sharedRest[#sharedRest + 1] = lbl
                end
            end
            for k = 1, #sharedRest do uniqFirst[#uniqFirst + 1] = sharedRest[k] end
            local prefixTier = string.format("%s %s (%s): ", isCur and "[●]" or "[ ]", tv.code, outTag)
            local rawTierLine = prefixTier .. ((#uniqFirst > 0) and table.concat(uniqFirst, " + ") or "Fluid Only")
            if unicode.wlen(rawTierLine) > 72 and #uniqFirst > 0 then
                local parts = {}
                for k = 1, #uniqFirst do
                    parts[k] = tostring(uniqFirst[k])
                        :gsub(" %(Any%)", "")
                        :gsub("Component", "Comp.")
                        :gsub("Containment Unit", "Unit")
                        :gsub("Neutronium", "Neutr.")
                        :gsub("Transcendent Metal", "Transc.")
                        :gsub("Titanium", "Tit.")
                end
                rawTierLine = prefixTier .. table.concat(parts, " + ")
                for _ = 1, 16 do
                    if #parts <= 1 or unicode.wlen(rawTierLine .. ((#uniqFirst > #parts) and (" (+" .. (#uniqFirst - #parts) .. ")") or "")) <= 72 then
                        break
                    end
                    table.remove(parts)
                    rawTierLine = prefixTier .. table.concat(parts, " + ")
                end
                if #uniqFirst > #parts then
                    rawTierLine = rawTierLine .. " (+" .. (#uniqFirst - #parts) .. ")"
                end
            end
            local lineTxt = padOrTrunc(rawTierLine, 72)
            self:drawButton(87, curY, lineTxt,
                isCur and COLORS.fg or COLORS.accent,
                isCur and COLORS.btnActiveBg or COLORS.btnBg,
                function()
                    rc.catalystTier = tv.idx
                    self:save(fam.name .. " recipe tier -> " .. tv.code)
                end)
            curY = curY + 1
        end
        curY = curY + 1
    end

    -- Recipe Convergence Policy (1 compact row)
    local rConv = rc.convMode or "global"
    self:drawText(87, curY, "Convergence:", COLORS.muted, COLORS.panelBg)
    if not convCtrlOk then
        self:drawButton(100, curY, "[Manual in DTPF GUI (No OC Patch)]", COLORS.yellow, COLORS.btnBg, function()
            self:setStatus(NO_CONV_PATCH_MSG)
        end)
    else
        local rcx = 100
        for _, cm in ipairs(RECIPE_CONV_MODES) do
            local active = (rConv == cm.id)
            local lbl = (cm.id == "global") and string.format("Default (%s)", effectiveGlobalConvShort(self.cfg)) or cm.label
            rcx = self:drawButton(rcx, curY, "[" .. lbl .. "]",
                active and COLORS.fg or ((cm.id == "off") and COLORS.yellow or COLORS.muted),
                active and ((cm.id == "off") and COLORS.amberBg or COLORS.btnActiveBg) or COLORS.btnBg,
                function()
                    rc.convMode = cm.id
                    self:save(fam.name .. " Convergence -> " .. cm.label)
                end) + 1
        end
    end
    curY = curY + 1

    -- Catalyst Tier Selector (only when NOT unified under tierVars, and hidden when NONE without active/requested Conv)
    local showCatSelector = (not tierVars) and (not isNone or (convCtrlOk and rConv ~= "off") or effRecConv)
    if showCatSelector then
        local catHdr = isNone and "Conv Cat:" or "Catalyst:"
        self:drawText(87, curY, catHdr, isNone and COLORS.purple or COLORS.muted, COLORS.panelBg)
        local allowedMap = {}
        if isNone then
            for i = 1, 5 do allowedMap[i] = true end
        elseif tInfo then
            for i = 1, #tInfo.indices do allowedMap[tInfo.indices[i]] = true end
        end
        local cx = 100
        local gActive = ((rc.catalystTier or 0) == 0)
        cx = self:drawButton(cx, curY, string.format("[Default (%s)]", CATALYST_SHORT[self.cfg.defaultCatalystTier or 4] or "DTEC"),
            gActive and COLORS.fg or COLORS.muted,
            gActive and COLORS.btnActiveBg or COLORS.btnBg,
            function()
                rc.catalystTier = 0
                self:save(fam.name .. " catalyst -> Default")
            end) + 1
        for idx = 1, 5 do
            if allowedMap[idx] then
                local active = (rc.catalystTier == idx)
                cx = self:drawButton(cx, curY, "[" .. CATALYST_SHORT[idx] .. "]",
                    active and COLORS.fg or COLORS.yellow,
                    active and COLORS.btnActiveBg or COLORS.btnBg,
                    function()
                        rc.catalystTier = idx
                        self:save(fam.name .. " catalyst -> " .. CATALYST_SHORT[idx])
                    end) + 1
            end
        end
        curY = curY + 1
        local catInfoLine = isNone
            and string.format("Resolved Conv Cat: %s (~%s/cycle when 4x)", tostring(meta and meta.convCatCode or CATALYST_SHORT[tIdx or 4]), UI.formatNumber(meta and meta.convCatAmount or 0, true))
            or string.format("Resolved Catalyst: %s (%s/cycle)", tostring(tCode), UI.formatNumber(tData and tData.catalystAmount or 0, true))
        self:drawText(87, curY, padOrTrunc(catInfoLine, 71), COLORS.muted, COLORS.panelBg)
        curY = curY + 1
    else
        self:drawText(87, curY, padOrTrunc(string.format("Resolved Tier Catalyst: %s (%s/cycle)",
            tostring(tCode), UI.formatNumber(tData and tData.catalystAmount or 0, true)), 71),
            COLORS.muted, COLORS.panelBg)
        curY = curY + 1
    end

    -- Loop Input Guard (hide floor presets & extra row when Guard is None)
    local guards = Scheduler.getGuardCandidates(tData)
    local gLabel, gIsFluid = "None", true
    for g = 1, #guards do
        if guards[g].key == rc.guardKey then
            gLabel = guards[g].label
            gIsFluid = (guards[g].isFluid ~= false)
            break
        end
    end
    self:drawText(87, curY, "Input Guard:", COLORS.muted, COLORS.panelBg)
    self:drawButton(100, curY, padOrTrunc("[" .. gLabel .. "]", 56), COLORS.purple, COLORS.btnBg, function()
        local curG = 1
        for g = 1, #guards do if guards[g].key == rc.guardKey then curG = g break end end
        local nxtG = (curG % #guards) + 1
        rc.guardKey = guards[nxtG].key
        if rc.guardKey ~= "none" and (rc.guardMin or 0) <= 0 then
            rc.guardMin = guards[nxtG].isFluid and 1000000 or 10000
        end
        self:save(fam.name .. " Guard -> " .. guards[nxtG].label)
    end)
    curY = curY + 1

    if (rc.guardKey or "none") ~= "none" then
        self:drawText(87, curY, "Guard Floor: " .. UI.formatNumber(rc.guardMin or 0, gIsFluid), COLORS.fg, COLORS.panelBg)
        local gx = 109
        for _, gp in ipairs({ { "0", 0 }, { "10K", 1e4 }, { "1M", 1e6 }, { "10M", 1e7 } }) do
            gx = self:drawButton(gx, curY, "[" .. gp[1] .. "]", COLORS.purple, COLORS.btnBg, function()
                rc.guardMin = gp[2]
                self:save(fam.name .. " Guard Floor -> " .. gp[1])
            end) + 1
        end
        self:drawButton(gx, curY, "[Custom…]", COLORS.cyan, COLORS.btnBg, function()
            self:openNumberPrompt("Loop Guard Floor for " .. fam.name .. ":", UI.formatNumber(rc.guardMin or 0, false), function(val)
                local parsed = UI.parseNumber(val)
                if parsed and parsed >= 0 then
                    rc.guardMin = parsed
                    self:save(fam.name .. " Guard Floor -> " .. UI.formatNumber(parsed, gIsFluid))
                end
            end)
        end)
        curY = curY + 1
    end
    curY = curY + 1

    -- Ingredients vs Live AE2 Stock Preview (+ Click-to-Maintain tags)
    self:drawText(87, curY, "── ◈ INPUTS (Click: Maint · RClick: Tgt) " .. string.rep("─", 31), COLORS.border, COLORS.panelBg)
    local stock = (self.state and self.state.stock) or { fluids = {}, items = {} }
    local stockFluids = stock.fluids or {}
    local stockItems = stock.items or {}

    local ingLines = {}
    local minCrafts = math.huge

    local usesCat = (tInfo and tInfo.usesCatalyst) == true
    local convWanted = effRecConv == true
    if usesCat and tCode and tCode ~= "NONE" then
        local cNeed = math.max(1, (tData and tData.catalystAmount) or 1000)
        local cFloor = (self.cfg.catalystFloors and self.cfg.catalystFloors[tCode]) or 100000
        local cFluid = (RecipesDB.CATALYST_TIERS[tIdx or 4] and RecipesDB.CATALYST_TIERS[tIdx or 4].fluid) or "exciteddtec"
        local cHave = stockFluids[cFluid] or 0
        local cAvail = math.max(0, cHave - cFloor)
        local cCrafts = math.floor(cAvail / cNeed)
        minCrafts = math.min(minCrafts, cCrafts)
        local cOk = (cAvail >= cNeed)
        ingLines[#ingLines + 1] = {
            txt = string.format("  %s %s x %s (AE2: %s | Min:%s)",
                cOk and "✓" or "✗", UI.formatNumber(cNeed, true), tostring(tCode),
                UI.formatNumber(cHave, true), fmtCompactNum(cFloor, true)),
            col = cOk and COLORS.green or COLORS.yellow,
            maintSpec = { type = "fluid", name = cFluid, damage = 0, label = tostring(tCode), amount = cNeed },
        }
    elseif (not usesCat) and convWanted then
        local cCode = (meta and meta.convCatCode) or CATALYST_SHORT[tIdx or 4] or "DTEC"
        local cIdx = (meta and meta.convCatIndex) or tIdx or 4
        local cFluid = (RecipesDB.CATALYST_TIERS[cIdx] and RecipesDB.CATALYST_TIERS[cIdx].fluid) or "exciteddtec"
        local cHave = stockFluids[cFluid] or 0
        local cSat = (meta and meta.convSatisfied == true)
        ingLines[#ingLines + 1] = {
            txt = cSat
                and string.format("  ⚡ Conv %s (~%s | AE2: %s)", cCode, UI.formatNumber(meta and meta.convCatAmount or 0, true), UI.formatNumber(cHave, true))
                or string.format("  ! Conv catalyst %s below floor -> runs safely at 2x", cCode),
            col = cSat and COLORS.purple or COLORS.yellow,
            maintSpec = { type = "fluid", name = cFluid, damage = 0, label = cCode, amount = (meta and meta.convCatAmount) or 1000 },
        }
    end

    for i = 1, #(tData and tData.fluidsIn or {}) do
        local f = tData.fluidsIn[i]
        local need = math.max(1, f.amount or 144)
        local have = stockFluids[f.name] or 0
        if f.name == "dimensionallytranscendentresidue" and (self.cfg.dtrReserveFloor or 0) > 0 then
            local flr = self.cfg.dtrReserveFloor
            local avail = math.max(0, have - flr)
            minCrafts = math.min(minCrafts, math.floor(avail / need))
            local ok = (avail >= need)
            ingLines[#ingLines + 1] = {
                txt = string.format("  %s %s x Transcendent Residue (DTR) (AE2: %s | Min:%s)",
                    ok and "✓" or "✗", UI.formatNumber(need, true),
                    UI.formatNumber(have, true), fmtCompactNum(flr, true)),
                col = ok and COLORS.green or COLORS.yellow,
            }
        else
            minCrafts = math.min(minCrafts, math.floor(have / need))
            local ok = (have >= need)
            local canMaint = (f.name and f.name ~= "dimensionallytranscendentresidue")
            ingLines[#ingLines + 1] = {
                txt = string.format("  %s %s x %s (AE2: %s)",
                    ok and "✓" or "✗", UI.formatNumber(need, true), tostring(f.label or f.name), UI.formatNumber(have, true)),
                col = ok and COLORS.green or COLORS.red,
                maintSpec = canMaint and { type = "fluid", name = f.name, damage = 0, label = tostring(f.label or f.name), amount = need } or nil,
            }
        end
    end

    for i = 1, #(tData and tData.itemsIn or {}) do
        local it = tData.itemsIn[i]
        local isNC = (it.nonConsumed == true) or ((it.amount or 0) == 0)
        if isNC and self.cfg.uniformNcSubnet then
            ingLines[#ingLines + 1] = {
                txt = string.format("  ◆ %s [NC Aux Color 0]", tostring(it.label or it.name)),
                col = COLORS.cyan,
            }
        else
            local need = math.max(1, it.amount or 1)
            local key = tostring(it.name) .. ":" .. tostring(it.damage or 0)
            local have = stockItems[key] or 0
            minCrafts = math.min(minCrafts, math.floor(have / need))
            local ok = (have >= need)
            ingLines[#ingLines + 1] = {
                txt = string.format("  %s %dx %s (AE2: %s)",
                    ok and "✓" or "✗", need, tostring(it.label or it.name), UI.formatNumber(have, false)),
                col = ok and COLORS.green or COLORS.red,
                maintSpec = (not isNC) and { type = "item", name = it.name, damage = it.damage or 0, label = tostring(it.label or it.name), amount = need } or nil,
            }
        end
    end

    local iy = curY + 1
    local hdrY = iy
    local function addIngLine(txt, col, maxW)
        if iy <= 47 then
            self:drawText(87, iy, padOrTrunc(txt, maxW or 72), col or COLORS.fg, COLORS.panelBg)
            iy = iy + 1
        end
    end

    local maintInputs = fam and Scheduler.collectRecipeMaintInputs and Scheduler.collectRecipeMaintInputs(self.cfg, fam.id) or {}
    local hdrW = (#maintInputs > 0 and hdrY <= 47) and 56 or 72
    if minCrafts == math.huge then
        addIngLine("INPUTS vs AE2 (✓ Catalyst/NC only):", COLORS.green, hdrW)
    elseif minCrafts > 0 then
        addIngLine(string.format("INPUTS vs AE2 (✓ ~%s crafts ready):", UI.formatNumber(minCrafts, false)), COLORS.green, hdrW)
    else
        addIngLine("INPUTS vs AE2 (✗ 0 crafts - missing below):", COLORS.yellow, hdrW)
    end
    if #maintInputs > 0 and hdrY <= 47 then
        local mSt = (self.state and self.state.maintStatus) or {}
        local toMain = (mSt.maintMode == "mainnet")
        self:drawButton(146, hdrY, toMain and "[Push->Stock]" or "[Push->Local]",
            toMain and COLORS.cyan or COLORS.green, COLORS.btnBg,
            function()
                local tag = "DTPF: " .. tostring(fam.name or fam.id)
                local pushRules = {}
                for i = 1, #maintInputs do
                    local sp = maintInputs[i]
                    local defTgt, defBat = Scheduler.defaultMaintTargetBatch(sp.type, sp.name, sp.amount)
                    pushRules[#pushRules + 1] = {
                        type = sp.type, name = sp.name, damage = sp.damage or 0,
                        label = sp.label or sp.name, target = defTgt, batch = defBat,
                        mode = "auto", group = "DTPF", tag = tag,
                    }
                end
                if toMain and Hardware and Hardware.pushRulesToStock then
                    local res = Hardware.pushRulesToStock(self.cfg, self.state, { tag = tag, group = "DTPF", rules = pushRules })
                    if res and res.ok then
                        self.statusMsg = string.format("Pushed %d inputs -> Mainnet Stock (%s).", #pushRules, tag)
                        return
                    end
                end
                for i = 1, #pushRules do
                    Scheduler.upsertMaintInput(self.cfg, pushRules[i])
                end
                self.cfg.maintEnabled = true
                self:save(string.format("Local Maintainer + %d inputs (%s)", #pushRules, fam.name))
            end)
    end
    local firstIngY = iy
    local lastIngY = firstIngY - 1
    for i = 1, #ingLines do
        if iy <= 47 then
            local ent = ingLines[i]
            local spec = ent.maintSpec
            if spec then
                self:drawText(87, iy, padOrTrunc(ent.txt, 59), ent.col or COLORS.fg, COLORS.panelBg)
                local rule = Scheduler.findMaintRule(self.cfg, spec.type, spec.name, spec.damage)
                local tagTxt, tagCol = "[  +Maint  ]", COLORS.muted
                if rule and rule.mode == "auto" then
                    tagTxt = padOrTrunc("[↻" .. fmtCompactNum(rule.target or 1, spec.type == "fluid"), 11) .. "]"
                    tagCol = COLORS.cyan
                elseif rule and rule.mode == "always" then
                    tagTxt = padOrTrunc("[●" .. fmtCompactNum(rule.target or 1, spec.type == "fluid"), 11) .. "]"
                    tagCol = COLORS.green
                end
                self:drawText(147, iy, tagTxt, tagCol, COLORS.btnBg)
            else
                self:drawText(87, iy, padOrTrunc(ent.txt, 72), ent.col or COLORS.fg, COLORS.panelBg)
            end
            lastIngY = iy
            iy = iy + 1
        end
    end
    if lastIngY >= firstIngY then
        self.hitboxes[#self.hitboxes + 1] = {
            x1 = 87,
            y1 = firstIngY,
            x2 = 158,
            y2 = lastIngY,
            fn = function(_, btn, _, ty)
                local ent = ingLines[(ty - firstIngY) + 1]
                local spec = ent and ent.maintSpec
                if not spec then return end
                local isFl = (spec.type == "fluid")
                if btn == 1 then
                    local rule = Scheduler.findMaintRule(self.cfg, spec.type, spec.name, spec.damage)
                    if not rule or rule.mode == "off" then
                        rule = Scheduler.upsertMaintInput(self.cfg, spec)
                    end
                    self:openNumberPrompt("Maintain Target for " .. rule.label .. ":", UI.formatNumber(rule.target or 1, false), function(val)
                        local p = UI.parseNumber(val)
                        if p and p > 0 then
                            local oldDefBat = math.max(1, math.floor((rule.target or 1) / 2))
                            rule.target = p
                            if not rule.batch or rule.batch > p or rule.batch == oldDefBat then
                                rule.batch = math.max(1, math.floor(p / 2))
                            end
                            self:save(rule.label .. " maintain target -> " .. UI.formatNumber(p, isFl))
                        end
                    end)
                else
                    local rule = Scheduler.findMaintRule(self.cfg, spec.type, spec.name, spec.damage)
                    if not rule or rule.mode == "off" then
                        rule = Scheduler.upsertMaintInput(self.cfg, spec)
                        self:save("Maintainer + " .. tostring(rule.label) .. " (Auto)")
                    elseif rule.mode == "auto" then
                        rule.mode = "always"
                        self:save(rule.label .. " maintainer -> always")
                    else
                        rule.mode = "off"
                        self:save(rule.label .. " maintainer -> off")
                    end
                end
            end,
        }
    end
    if #ingLines == 0 then
        addIngLine("  (none)", COLORS.muted)
    end

    addIngLine("OUTPUTS:", COLORS.accent)
    for i = 1, #outs do
        local o = outs[i]
        local oHave = Scheduler.getOutputStock(stock, o)
        addIngLine(string.format("  + %s -> %s (AE2: %s)",
            UI.formatNumber(o.amount or 1, o.isFluid),
            tostring(o.label or o.name),
            UI.formatNumber(oHave, o.isFluid)),
            (i == outIdx) and COLORS.green or COLORS.fg)
    end
    if tData and (tData.dtrOut or 0) > 0 then
        local dtrHave = stockFluids["dimensionallytranscendentresidue"] or 0
        addIngLine(string.format("  + %s -> Dimensionally Transcendent Residue (AE2: %s)",
            UI.formatNumber(tData.dtrOut, true),
            UI.formatNumber(dtrHave, true)),
            COLORS.cyan)
    end
end

function UI:renderRecipesTab()
    for y = 4, self.h - 1 do
        self:drawText(83, y, "│", COLORS.border, COLORS.bg)
    end

    local pinnedByFam = {}
    for k = 1, #self.cfg.dtpfs do
        local dt = self.cfg.dtpfs[k]
        if (dt.roleOverride == "pinned" or dt.roleOverride == "pinned_loop") and dt.pinnedFamilyId then
            pinnedByFam[dt.pinnedFamilyId] = pinnedByFam[dt.pinnedFamilyId] or {}
            local listPin = pinnedByFam[dt.pinnedFamilyId]
            listPin[#listPin + 1] = {
                idx = k,
                name = dt.name or ("DTPF #" .. k),
                isLoop = (dt.roleOverride == "pinned_loop"),
            }
        end
    end

    local sortedAll = {}
    for i = 1, #RecipesDB.FAMILIES do
        local f = RecipesDB.FAMILIES[i]
        sortedAll[i] = { id = f.id, prio = (self.cfg.recipes[f.id] and self.cfg.recipes[f.id].priority) or 999 }
    end
    table.sort(sortedAll, function(a, b) return a.prio < b.prio end)
    local rankById = {}
    for i = 1, #sortedAll do rankById[sortedAll[i].id] = i end

    local list = getFilteredRecipeList(self)
    self:renderRecipeListPane(list, pinnedByFam, rankById)
    self:renderRecipeInspectorPane(self:getSelectedFamily(), pinnedByFam, rankById)
end

local function pairDtpfsOneToOne(self, ep)
    local need = #self.cfg.dtpfs
    if #self.cfg.channels == 1
        and self.cfg.channels[1].mode == "storage_bus"
        and not self.cfg.channels[1].itemStorageAddr
        and not self.cfg.channels[1].fluidStorageAddr
        and (#(ep.hatches or {}) > 0 or #(ep.buses or {}) > 0)
        and #(ep.itemStorageBuses or {}) == 0
        and #(ep.fluidStorageBuses or {}) == 0 then
        self.cfg.channels = {}
    end
    local usedI, usedF, usedH, usedB = {}, {}, {}, {}
    for k = 1, #self.cfg.channels do
        local c = self.cfg.channels[k]
        if c.itemStorageAddr then usedI[c.itemStorageAddr] = true end
        if c.fluidStorageAddr then usedF[c.fluidStorageAddr] = true end
        if c.hatchAddr then usedH[c.hatchAddr] = true end
        if c.busAddr then usedB[c.busAddr] = true end
    end
    local function takeUnusedSB(list, used)
        for k = 1, #(list or {}) do
            local a = list[k].address
            if a and not used[a] then used[a] = true return list[k] end
        end
        return nil
    end
    for _ = 1, 64 do
        if #self.cfg.channels >= need then break end
        local nIdx = #self.cfg.channels + 1
        local isb = takeUnusedSB(ep.itemStorageBuses, usedI)
        local fsb = takeUnusedSB(ep.fluidStorageBuses, usedF)
        local refDtpf = self.cfg.dtpfs[nIdx]
        local h = (not isb and not fsb) and Hardware.pickNearestAddress(refDtpf, ep.hatches, ep.hatchCoords, usedH) or nil
        local b = (not isb and not fsb) and Hardware.pickNearestAddress(refDtpf, ep.buses, ep.busCoords, usedB) or nil
        local useHatch = (not isb and not fsb and (h or b))
        self.cfg.channels[nIdx] = {
            id = "ch" .. tostring(nIdx),
            name = "Passive Ch " .. tostring(nIdx) .. (useHatch and " (Hatch/Bus)" or " (StorageBus)"),
            mode = useHatch and "hatch_pair" or "storage_bus",
            itemStorageAddr = isb and isb.address or nil,
            itemStorageSide = (isb and isb.sides[1] and isb.sides[1].side) or 0,
            fluidStorageAddr = fsb and fsb.address or nil,
            fluidStorageSide = (fsb and fsb.sides[1] and fsb.sides[1].side) or 0,
            hatchAddr = h,
            busAddr = b,
            shareOnDemand = true,
            enabled = true,
        }
    end
    for i = 1, #self.cfg.dtpfs do
        self.cfg.dtpfs[i].channelId = self.cfg.channels[i].id
    end
    self:save(string.format("1:1 paired %d DTPFs -> ch1..ch%d.", need, need))
end

function UI:renderSetupActionBar(ctx)
    local ep = ctx.ep or {}
    local nD = #self.cfg.dtpfs
    local apOn = (ep.autoPullOnCount or 0) > 0
    local pairedCnt = 0
    local chById = {}
    for k = 1, #self.cfg.channels do chById[self.cfg.channels[k].id] = self.cfg.channels[k] end
    for i = 1, nD do
        local ch = chById[self.cfg.dtpfs[i].channelId or ("ch" .. i)]
        if ch and ch.hatchAddr and ch.busAddr then pairedCnt = pairedCnt + 1 end
    end
    local allPaired = (nD > 0) and (pairedCnt == nD)
    local hasTp = (#(self.discoveredTransposers or {}) > 0)
        or (self.cfg.transposerAddr and self.cfg.transposerAddr ~= "" and self.cfg.transposerAddr ~= "none")
    local flushingNow = (self.state and self.state.odFlushActive == true)
    local odBusyOrStalled = self.state and self.state.onDemand and (self.state.onDemand.stalled or self.state.onDemand.hasWork)

    local function drawBigActionBtn(bx, by, bw, label, fgCol, borderCol, bgCol, onClick)
        self:drawFrame(bx, by, bw, 3, borderCol, bgCol, "round")
        local txt = (unicode.wlen(label) > bw - 2) and unicode.sub(label, 1, bw - 2) or label
        local tw = unicode.wlen(txt)
        local tx = bx + math.max(1, math.floor((bw - tw) / 2))
        self:drawText(tx, by + 1, txt, fgCol, bgCol)
        self:addHitbox(bx, by, bx + bw - 1, by + 2, onClick)
        self:addHitbox(tx, by + 1, tx + tw - 1, by + 1, onClick)
    end

    -- 4 symmetric 34x3 buttons centered across 160 columns (x=7, 45, 83, 121; 6-col outer margin, 4-col gaps)
    drawBigActionBtn(7, 5, 34, "↻  RESCAN HARDWARE", COLORS.cyan, COLORS.cyan, COLORS.btnBg, function()
        self:refreshDiscovery()
        self:save("Rescanned all connected OpenComputers components.")
    end)

    drawBigActionBtn(45, 5, 34, "⚡  1:1 PAIR DTPFS", allPaired and COLORS.green or COLORS.cyan,
        allPaired and COLORS.green or COLORS.cyan, COLORS.btnBg, function()
            pairDtpfsOneToOne(self, ep)
        end)

    local apLbl = apOn and "!  LOCK AUTOPULL OFF" or "✓  LOCK AUTOPULL OFF"
    drawBigActionBtn(83, 5, 34, apLbl, apOn and COLORS.yellow or COLORS.green,
        apOn and COLORS.yellow or COLORS.green, apOn and COLORS.amberBg or COLORS.btnBg, function()
            local chg, tot = Hardware.lockAllPassiveAutoPull()
            self:refreshDiscovery()
            self:setStatus(string.format("Locked autoPull=OFF (%d switched, %d checked).", chg or 0, tot or 0))
        end)

    local flLbl = flushingNow and "■  STOP FLUSH" or "⇄  FLUSH OD"
    local flCol = flushingNow and COLORS.red or (odBusyOrStalled and COLORS.yellow or (hasTp and COLORS.purple or COLORS.muted))
    local flBorder = flushingNow and COLORS.red or (odBusyOrStalled and COLORS.yellow or (hasTp and COLORS.purple or COLORS.border))
    drawBigActionBtn(121, 5, 34, flLbl, flCol, flBorder, COLORS.btnBg, function()
        if flushingNow then
            Scheduler.cancelOdFlush(self.cfg, self.state)
            self:setStatus("Cancelled OD flush.")
        elseif hasTp then
            Scheduler.requestOdFlush(self.state)
            self:setStatus("Flushing Color 1 OD inputs -> Passive -> Main AE2...")
        else
            self:setStatus("Requires Transposer bridge between Passive & OD Dual IFs.")
        end
    end)
end

function UI:renderWiringReservesCard()
    -- Left Card: Reserve Floors & Policy (x = 2..79, y = 9..17)
    self:drawFrame(2, 9, 78, 9, COLORS.border, COLORS.panelBg, "round")
    self:drawText(4, 9, " ◈ RESERVE FLOORS & POLICY ", COLORS.accent, COLORS.panelBg)

    local stockFluids = (self.state and self.state.stock and self.state.stock.fluids) or {}
    local function drawFloorCell(px, py, label, fluidKey, curFloor, onSet)
        local amt = stockFluids[fluidKey] or 0
        local ico = getTankGaugeChar(amt, curFloor)
        local okCol = (amt == 0) and COLORS.red or ((amt > curFloor) and COLORS.green or COLORS.yellow)
        self:drawText(px, py, string.format("%s %-4s", ico, label), okCol, COLORS.panelBg)
        local flrTxt = string.format("[Min:%6s]", fmtCompactNum(curFloor, true))
        self:drawButton(px + 8, py, flrTxt, COLORS.cyan, COLORS.btnBg, onSet)
    end

    for i = 1, 5 do
        local ct = RecipesDB.CATALYST_TIERS[i]
        local flr = (self.cfg.catalystFloors and self.cfg.catalystFloors[ct.code]) or 100000
        local rowY = (i <= 3) and 11 or 13
        local colX = 5 + ((i <= 3) and (i - 1) or (i - 4)) * 24
        drawFloorCell(colX, rowY, ct.code, ct.fluid, flr, function(_, button)
            if button == 1 then
                for _, tier in ipairs(RecipesDB.CATALYST_TIERS) do
                    self.cfg.catalystFloors[tier.code] = flr
                end
                self:save("Copied " .. UI.formatNumber(flr, true) .. " reserve floor to all 5 catalysts.")
            else
                self:openNumberPrompt("Set Reserve Floor for " .. ct.code .. " (" .. ct.label .. "):", UI.formatNumber(flr, false), function(val)
                    local parsed = UI.parseNumber(val)
                    if parsed and parsed >= 0 then
                        self.cfg.catalystFloors[ct.code] = parsed
                        self:save(ct.code .. " reserve floor -> " .. UI.formatNumber(parsed, true))
                    end
                end)
            end
        end)
    end
    drawFloorCell(53, 13, "DTR ", "dimensionallytranscendentresidue", self.cfg.dtrReserveFloor or 10000000, function()
        self:openNumberPrompt("Set Global DTR Reserve Floor (protects Shirabon / SpaceTime):", UI.formatNumber(self.cfg.dtrReserveFloor, false), function(val)
            local parsed = UI.parseNumber(val)
            if parsed and parsed >= 0 then
                self.cfg.dtrReserveFloor = parsed
                self:save("Global DTR reserve floor -> " .. UI.formatNumber(parsed, true))
            end
        end)
    end)

    self:drawText(5, 15, "OD Conv:", COLORS.muted, COLORS.panelBg)
    if not self:isConvControlSupported() then
        self:drawButton(14, 15, "[Manual    ]", COLORS.yellow, COLORS.btnBg, function()
            self:setStatus(NO_CONV_PATCH_MSG)
        end)
    else
        local curMode = OD_CONV_MODES[1]
        local curIdx = 1
        for k = 1, #OD_CONV_MODES do
            if OD_CONV_MODES[k].id == self.cfg.onDemandConvMode then
                curMode = OD_CONV_MODES[k]
                curIdx = k
                break
            end
        end
        self:drawButton(14, 15, "[" .. curMode.label .. "]", COLORS.purple, COLORS.btnBg, function(step)
            local nxt = ((curIdx - 1 + (step or 1) + #OD_CONV_MODES) % #OD_CONV_MODES) + 1
            self.cfg.onDemandConvMode = OD_CONV_MODES[nxt].id
            self:save("On-Demand Convergence -> " .. OD_CONV_MODES[nxt].label)
        end)
    end

    self:drawText(30, 15, "CatFB:", COLORS.muted, COLORS.panelBg)
    self:drawButton(37, 15, self.cfg.catalystAutoFallback and "[AUTO]" or "[OFF ]",
        self.cfg.catalystAutoFallback and COLORS.green or COLORS.muted, COLORS.btnBg, function()
            self.cfg.catalystAutoFallback = not self.cfg.catalystAutoFallback
            self:save("Catalyst Auto-Fallback -> " .. (self.cfg.catalystAutoFallback and "AUTO" or "OFF"))
        end)

    self:drawText(46, 15, "NC:", COLORS.muted, COLORS.panelBg)
    local nx = self:drawButton(50, 15,
        self.cfg.uniformNcSubnet and "[Aux Subnet]" or "[Main Net  ]",
        self.cfg.uniformNcSubnet and COLORS.cyan or COLORS.yellow,
        COLORS.btnBg,
        function()
            self.cfg.uniformNcSubnet = not self.cfg.uniformNcSubnet
            for c = 1, #self.cfg.channels do self.cfg.channels[c].activeKey = nil end
            self:save("Non-Consumed Items -> " .. (self.cfg.uniformNcSubnet and "Uniform Aux Subnet" or "Main Net"))
        end) + 2
    local mSt = (self.state and self.state.maintStatus) or {}
    local mMode = mSt.maintMode or ((self.cfg.maintEnabled == true) and "local" or "off")
    local mBtnLbl = (mMode == "mainnet") and "[Maint:MAINNET]" or ((mMode == "local") and "[Maint:LOCAL  ]" or "[Maint:OFF    ]")
    local mBtnFg = (mMode == "mainnet") and COLORS.cyan or ((mMode == "local") and COLORS.green or COLORS.muted)
    local mBtnBg = (mMode == "mainnet") and COLORS.btnActiveBg or ((mMode == "local") and COLORS.darkGreen or COLORS.btnBg)
    self:drawButton(nx, 15, mBtnLbl,
        mBtnFg,
        mBtnBg,
        function()
            self.maintModalActive = true
            self.maintModalScroll = 0
        end)
end

function UI:renderWiringTopologyCard(ctx)
    local ep, warnings = ctx.ep, ctx.warnings
    local sNet, odNet = ctx.sNet, ctx.odNet
    local nonStockNets = ctx.nonStockNets

    -- Right Card: Subnets & Bridge (x = 82..159, y = 9..17)
    self:drawFrame(82, 9, 78, 9, COLORS.border, COLORS.panelBg, "round")
    self:drawText(84, 9, " ◈ SUBNETS & BRIDGE ", COLORS.accent, COLORS.panelBg)
    local isStandalone = (self.cfg.extLinkMode == "off")
    local awOn = (self.cfg.autoWake ~= false)
    self:drawButton(131, 9, awOn and "[AW:ON ]" or "[AW:OFF]",
        awOn and COLORS.green or COLORS.muted,
        awOn and COLORS.darkGreen or COLORS.btnBg,
        function()
            self.cfg.autoWake = not awOn
            if Hardware and Hardware.openMeshPort then pcall(Hardware.openMeshPort, self.comp, self.cfg) end
            self:save("Auto-Wake -> " .. (self.cfg.autoWake and "ON" or "OFF"))
        end)
    self:drawButton(140, 9, isStandalone and "[Ext:Standalone]" or "[Ext:Mesh/Auto ]",
        isStandalone and COLORS.yellow or COLORS.cyan,
        isStandalone and COLORS.amberBg or COLORS.btnBg,
        function()
            self.cfg.extLinkMode = isStandalone and "auto" or "off"
            self:save("External Link -> " .. (self.cfg.extLinkMode == "off" and "Standalone (No Mesh/Web)" or "Mesh / Auto"))
        end)

    local stockOK = (sNet ~= nil)
    self:drawText(85, 11, "Passive DI :", COLORS.muted, COLORS.panelBg)
    self:drawButton(98, 11, string.format("[ %s (%dI / %dF) ]",
        self.cfg.stockNetAddr and self.cfg.stockNetAddr:sub(1, 8) or "None",
        sNet and sNet.itemTypes or 0, sNet and sNet.fluidTypes or 0), COLORS.green, COLORS.btnBg, function()
            if #self.discoveredNets == 0 then return end
            local idx = 0
            for i = 1, #self.discoveredNets do
                if self.discoveredNets[i].address == self.cfg.stockNetAddr then idx = i break end
            end
            self.cfg.stockNetAddr = self.discoveredNets[(idx % #self.discoveredNets) + 1].address
            Scheduler.syncSubnetsStruct(self.cfg)
            self:save("Stock Net Interface -> " .. self.cfg.stockNetAddr:sub(1, 12))
        end)
    local passiveBadge = (stockOK and #warnings == 0) and "✓ OK" or "! Check"
    self:drawText(158 - unicode.wlen(passiveBadge), 11, passiveBadge,
        (stockOK and #warnings == 0) and COLORS.green or COLORS.yellow, COLORS.panelBg)

    local odDistinct = (odNet ~= nil) and (odNet.address ~= self.cfg.stockNetAddr)
    local odOk = odDistinct or (ctx.perDtpfOdCount > 0)
    self:drawText(85, 13, "On-Demand  :", COLORS.muted, COLORS.panelBg)
    self:drawButton(98, 13, string.format("[ %s (%dI / %dF) ]",
        self.cfg.onDemandNetAddr and self.cfg.onDemandNetAddr:sub(1, 8) or "None",
        odNet and odNet.itemTypes or 0, odNet and odNet.fluidTypes or 0), COLORS.purple, COLORS.btnBg, function()
            if #self.discoveredNets == 0 then return end
            local idx = 0
            for i = 1, #self.discoveredNets do
                if self.discoveredNets[i].address == self.cfg.onDemandNetAddr then idx = i break end
            end
            self.cfg.onDemandNetAddr = self.discoveredNets[(idx % #self.discoveredNets) + 1].address
            Scheduler.syncSubnetsStruct(self.cfg)
            self:save("On-Demand Interface -> " .. self.cfg.onDemandNetAddr:sub(1, 12))
        end)
    if #nonStockNets >= 2 and #self.cfg.dtpfs >= 2 then
        self:drawButton(128, 13, "[ 1:1 PAIR OD ]", COLORS.cyan, COLORS.btnBg, function()
            local paired = Scheduler.pairPerDtpfOnDemand(self.cfg, self.discoveredNets)
            self:save(string.format("1:1 paired %d DTPFs -> nearest Color 1 OD subnets.", paired))
        end)
        local nLbl = string.format("%d OD Nets", #nonStockNets)
        self:drawText(158 - unicode.wlen(nLbl), 13, nLbl, COLORS.cyan, COLORS.panelBg)
    else
        local odBadge = odOk and "✓ Split" or "! Unsplit"
        self:drawText(158 - unicode.wlen(odBadge), 13, odBadge, odOk and COLORS.green or COLORS.yellow, COLORS.panelBg)
    end

    local hasTp = (#(self.discoveredTransposers or {}) > 0) or (self.cfg.transposerAddr and self.cfg.transposerAddr ~= "")
    if hasTp then
        self:drawText(85, 15, "Bridge (TP):", COLORS.muted, COLORS.panelBg)
        local bxTp = self:drawButton(98, 15, self.cfg.transposerEnabled and "[ON]" or "[--]",
            self.cfg.transposerEnabled and COLORS.green or COLORS.red, COLORS.btnBg, function()
                self.cfg.transposerEnabled = not (self.cfg.transposerEnabled ~= false)
                Scheduler.syncSubnetsStruct(self.cfg)
                self:save("Transposer Catalyst Bridge -> " .. (self.cfg.transposerEnabled and "ON" or "OFF"))
            end) + 1
        local tpLabel = (self.cfg.transposerAddr == "none") and "None"
            or (self.cfg.transposerAddr and self.cfg.transposerAddr:sub(1, 6) or "None")
        bxTp = self:drawButton(bxTp, 15, string.format("[%s]", tpLabel), COLORS.cyan, COLORS.btnBg, function()
            if #(self.discoveredTransposers or {}) == 0 then return end
            local opts = {}
            for k = 1, #self.discoveredTransposers do
                opts[#opts + 1] = self.discoveredTransposers[k].address
            end
            opts[#opts + 1] = "none"
            local curIdx = 0
            for k = 1, #opts do
                if opts[k] == self.cfg.transposerAddr then curIdx = k break end
            end
            self.cfg.transposerAddr = opts[(curIdx % #opts) + 1]
            Scheduler.syncSubnetsStruct(self.cfg)
            self:save("Bridge Transposer -> " .. tostring(self.cfg.transposerAddr):sub(1, 12))
        end) + 1
        local pSide = self.cfg.stockTransposerSide or 1
        bxTp = self:drawButton(bxTp, 15, "[P:" .. (SIDE_NAMES[pSide] or "Up") .. "]", COLORS.green, COLORS.btnBg, function(step)
            self.cfg.stockTransposerSide = ((self.cfg.stockTransposerSide or 1) + (step or 1) + 6) % 6
            self.cfg._hasExplicitTpSides = true
            Scheduler.syncSubnetsStruct(self.cfg)
            self:save("Transposer Passive Side -> " .. (SIDE_NAMES[self.cfg.stockTransposerSide] or "?"))
        end) + 1
        local odSide = self.cfg.odTransposerSide or 0
        bxTp = self:drawButton(bxTp, 15, "[OD:" .. (SIDE_NAMES[odSide] or "Down") .. "]", COLORS.purple, COLORS.btnBg, function(step)
            self.cfg.odTransposerSide = ((self.cfg.odTransposerSide or 0) + (step or 1) + 6) % 6
            self.cfg._hasExplicitTpSides = true
            Scheduler.syncSubnetsStruct(self.cfg)
            self:save("Transposer OD Side -> " .. (SIDE_NAMES[self.cfg.odTransposerSide] or "?"))
        end) + 1

        local afPolls = math.max(0, math.floor(tonumber(self.cfg.odAutoFlushPolls) or 0))
        local afSec = math.floor(afPolls * (tonumber(self.cfg.pollInterval) or 2.0) + 0.5)
        local afLbl = (afPolls > 0) and string.format("[AutoFlush:%ds]", afSec) or "[AutoFlush:OFF]"
        bxTp = self:drawButton(bxTp, 15, afLbl, (afPolls > 0) and COLORS.yellow or COLORS.muted, COLORS.btnBg, function(step)
            local presets = { 0, 8, 15, 30 }
            local curP = 1
            for pi = 1, #presets do
                if presets[pi] == afPolls then curP = pi break end
            end
            local nxtIdx = ((curP - 1 + (step or 1) + #presets) % #presets) + 1
            self.cfg.odAutoFlushPolls = presets[nxtIdx]
            Scheduler.syncSubnetsStruct(self.cfg)
            local nxtSec = math.floor(self.cfg.odAutoFlushPolls * (tonumber(self.cfg.pollInterval) or 2.0) + 0.5)
            self:save("Stalled OD Auto-Flush -> " .. ((self.cfg.odAutoFlushPolls > 0) and (tostring(nxtSec) .. "s") or "OFF"))
        end) + 1

        local bSt = formatCleanBridgeStatus((self.state and self.state.odBridgeStatus) or "Idle")
        local bCol = (bSt:find("^Blocked") or bSt:find("^! ") or bSt:find("^Flush err")) and COLORS.red
            or ((bSt:find("^Flushing") or bSt:find("^Top%-Up") or bSt:find("^Draining") or bSt:find("^Preview")) and COLORS.yellow)
            or COLORS.green
        local remW = math.max(4, 158 - bxTp)
        self:drawText(bxTp, 15, padOrTrunc(bSt, remW), bCol, COLORS.panelBg)
    else
        self:drawText(85, 15, "Bridge (TP): None (optional catalyst ramp & OD flush)", COLORS.muted, COLORS.panelBg)
    end
end

function UI:renderWiringChannelsCard(ep, startY)
    local y = startY or 19
    self:drawText(2, y, string.format("PASSIVE CHANNELS (%d)", #self.cfg.channels), COLORS.accent, COLORS.bg)
    local cxBtn = self:drawButton(24, y, "[ + ADD CHANNEL ]", COLORS.green, COLORS.btnBg, function()
        local newId = "ch" .. tostring(#self.cfg.channels + 1)
        self.cfg.channels[#self.cfg.channels + 1] = {
            id = newId,
            name = "Passive Ch " .. tostring(#self.cfg.channels + 1),
            mode = "storage_bus",
            shareOnDemand = true,
            enabled = true,
        }
        self:save("Added channel " .. newId)
    end) + 2
    if #self.cfg.channels > 1 then
        cxBtn = self:drawButton(cxBtn, y, "[ - REMOVE LAST ]", COLORS.red, COLORS.btnBg, function()
            table.remove(self.cfg.channels)
            self:save("Removed last passive channel.")
        end) + 2
    end
    if #self.cfg.dtpfs >= 2 then
        self:drawButton(cxBtn, y, "[ 1:1 PAIR DTPFS ]", COLORS.cyan, COLORS.btnBg, function()
            pairDtpfsOneToOne(self, ep)
        end)
    end

    local maxChShow = math.max(1, math.min(2, #self.cfg.channels))
    local chStep = 2
    local maxChScroll = math.max(0, #self.cfg.channels - maxChShow)
    self.wiringChScroll = math.max(0, math.min(maxChScroll, self.wiringChScroll or 0))
    if #self.cfg.channels > maxChShow then
        self:drawButton(self.w - 18, y, "[▲]", (self.wiringChScroll > 0) and COLORS.fg or COLORS.muted, COLORS.btnBg, function()
            self.wiringChScroll = math.max(0, self.wiringChScroll - 1)
        end)
        self:drawButton(self.w - 14, y, "[▼]", (self.wiringChScroll < maxChScroll) and COLORS.fg or COLORS.muted, COLORS.btnBg, function()
            self.wiringChScroll = math.min(maxChScroll, self.wiringChScroll + 1)
        end)
        self:drawText(self.w - 10, y, string.format("%d-%d/%d", self.wiringChScroll + 1, self.wiringChScroll + maxChShow, #self.cfg.channels), COLORS.muted, COLORS.bg)
    end
    y = y + 1

    local chUsers = {}
    for i = 1, #self.cfg.dtpfs do
        local cid = self.cfg.dtpfs[i].channelId or "ch1"
        chUsers[cid] = chUsers[cid] or {}
        chUsers[cid][#chUsers[cid] + 1] = i
    end

    for visC = 1, math.min(maxChShow, #self.cfg.channels - self.wiringChScroll) do
        local i = visC + self.wiringChScroll
        local ch = self.cfg.channels[i]
        self:fillRect(2, y, self.w - 2, 2, " ", COLORS.panelBg)
        self:drawButton(4, y, ch.enabled and "[ON ]" or "[OFF]", ch.enabled and COLORS.green or COLORS.red, COLORS.btnBg, function()
            ch.enabled = not ch.enabled
            self:save(ch.id .. " enabled -> " .. (ch.enabled and "ON" or "OFF"))
        end)
        self:drawText(10, y, ch.id:upper(), COLORS.cyan, COLORS.panelBg)
        local hasLegacyHatch = (ch.mode == "hatch_pair") or (#(ep.hatches or {}) > 0) or (#(ep.buses or {}) > 0)
        if hasLegacyHatch then
            self:drawButton(15, y, "[" .. (ch.mode == "storage_bus" and "StorageBus Pair" or "MFU Hatch+Bus") .. "]",
                COLORS.accent, COLORS.btnBg, function()
                    ch.mode = (ch.mode == "storage_bus") and "hatch_pair" or "storage_bus"
                    ch.activeKey = nil
                    self:save(ch.id .. " mode -> " .. ch.mode)
                end)
        else
            self:drawText(15, y, "StorageBus(SB)", COLORS.accent, COLORS.panelBg)
        end

        if ch.mode == "hatch_pair" then
            local hc = ep.hatchCoords and ch.hatchAddr and ep.hatchCoords[ch.hatchAddr]
            local hTxt = ch.hatchAddr
                and (hc and string.format("[%s %d,%d]", ch.hatchAddr:sub(1, 6), hc.x, hc.z) or ("[" .. ch.hatchAddr:sub(1, 10) .. "]"))
                or "[None]"
            self:drawText(34, y, "Hatch:", COLORS.muted, COLORS.panelBg)
            local bxPos = self:drawButton(41, y, hTxt, COLORS.fg, COLORS.btnBg, function()
                if #(ep.hatches or {}) == 0 then return end
                local cur = 0
                for k = 1, #ep.hatches do if ep.hatches[k] == ch.hatchAddr then cur = k break end end
                ch.hatchAddr = ep.hatches[(cur % #ep.hatches) + 1]
                ch.activeKey = nil
                self:save(ch.id .. " Hatch updated")
            end) + 2

            local bc = ep.busCoords and ch.busAddr and ep.busCoords[ch.busAddr]
            local bTxt = ch.busAddr
                and (bc and string.format("[%s %d,%d]", ch.busAddr:sub(1, 6), bc.x, bc.z) or ("[" .. ch.busAddr:sub(1, 10) .. "]"))
                or "[None]"
            self:drawText(bxPos, y, "Bus:", COLORS.muted, COLORS.panelBg)
            self:drawButton(bxPos + 5, y, bTxt, COLORS.fg, COLORS.btnBg, function()
                if #(ep.buses or {}) == 0 then return end
                local cur = 0
                for k = 1, #ep.buses do if ep.buses[k] == ch.busAddr then cur = k break end end
                ch.busAddr = ep.buses[(cur % #ep.buses) + 1]
                ch.activeKey = nil
                self:save(ch.id .. " Bus updated")
            end)
        else
            self:drawText(34, y, "FluidSB:", COLORS.muted, COLORS.panelBg)
            self:drawButton(43, y, "[" .. tostring(ch.fluidStorageAddr and ch.fluidStorageAddr:sub(1, 8) or "None") .. "]", COLORS.fg, COLORS.btnBg, function()
                if #(ep.fluidStorageBuses or {}) == 0 then return end
                local cur = 0
                for k = 1, #ep.fluidStorageBuses do if ep.fluidStorageBuses[k].address == ch.fluidStorageAddr then cur = k break end end
                local pick = ep.fluidStorageBuses[(cur % #ep.fluidStorageBuses) + 1]
                ch.fluidStorageAddr = pick.address
                if pick.sides[1] then ch.fluidStorageSide = pick.sides[1].side end
                ch.activeKey = nil
                self:save(ch.id .. " Fluid StorageBus updated")
            end)
            self:drawButton(54, y, "[" .. (SIDE_NAMES[ch.fluidStorageSide or 0] or "Down") .. "]", COLORS.yellow, COLORS.btnBg, function()
                ch.fluidStorageSide = ((ch.fluidStorageSide or 0) + 1) % 6
                ch.activeKey = nil
                self:save(ch.id .. " Fluid side -> " .. SIDE_NAMES[ch.fluidStorageSide])
            end)

            self:drawText(63, y, "ItemSB:", COLORS.muted, COLORS.panelBg)
            self:drawButton(71, y, "[" .. tostring(ch.itemStorageAddr and ch.itemStorageAddr:sub(1, 8) or "None") .. "]", COLORS.fg, COLORS.btnBg, function()
                if #(ep.itemStorageBuses or {}) == 0 then return end
                local cur = 0
                for k = 1, #ep.itemStorageBuses do if ep.itemStorageBuses[k].address == ch.itemStorageAddr then cur = k break end end
                local pick = ep.itemStorageBuses[(cur % #ep.itemStorageBuses) + 1]
                ch.itemStorageAddr = pick.address
                if pick.sides[1] then ch.itemStorageSide = pick.sides[1].side end
                ch.activeKey = nil
                self:save(ch.id .. " Item StorageBus updated")
            end)
            self:drawButton(82, y, "[" .. (SIDE_NAMES[ch.itemStorageSide or 0] or "Down") .. "]", COLORS.yellow, COLORS.btnBg, function()
                ch.itemStorageSide = ((ch.itemStorageSide or 0) + 1) % 6
                ch.activeKey = nil
                self:save(ch.id .. " Item side -> " .. SIDE_NAMES[ch.itemStorageSide])
            end)
        end

        if ch.shareOnDemand == false then
            self:drawButton(125, y, "[Ignore OD: YES]", COLORS.yellow, COLORS.amberBg, function()
                ch.shareOnDemand = true
                self:save(ch.id .. " Yield to OD -> YES")
            end)
        elseif #self.cfg.channels < #self.cfg.dtpfs then
            self:drawButton(125, y, "[Yield to OD: YES]", COLORS.purple, COLORS.btnBg, function()
                ch.shareOnDemand = false
                self:save(ch.id .. " Yield to OD -> NO")
            end)
        end

        local usersStr = (chUsers[ch.id] and #chUsers[ch.id] > 0) and formatDtpfIdList(chUsers[ch.id], 6) or "None"
        local sentinelSeg = (ch.mode == "storage_bus")
            and string.format(" | 0-Stock: F=%s I=%s", tostring(ch.fluidSentinel or "-"), tostring(ch.itemSentinel or "-"))
            or ""
        local keyLine = string.format("DTPFs: %-12s | Key: %s%s",
            padOrTrunc(usersStr, 12),
            tostring(ch.activeKey or "Pending/Paused"),
            sentinelSeg)
        self:drawText(10, y + 1, padOrTrunc(keyLine, self.w - 14), COLORS.muted, COLORS.panelBg)
        y = y + chStep
    end

    return y
end

function UI:renderWiringControllersTable(yStart, nonStockNets)
    -- Card 4 (SB Mode): Discovered DTPF Controllers table
    local y = math.max(yStart + 1, 27)
    if y > self.h - 4 then return end

    local maxShow = math.max(1, (self.h - 1) - (y + 2))
    local maxDScroll = math.max(0, #self.cfg.dtpfs - maxShow)
    self.wiringDtpfScroll = math.max(0, math.min(maxDScroll, self.wiringDtpfScroll or 0))

    self:drawText(2, y, string.format("DISCOVERED DTPF CONTROLLERS (%d)", #self.cfg.dtpfs), COLORS.accent, COLORS.bg)
    if #self.cfg.dtpfs > maxShow then
        self:drawButton(self.w - 18, y, "[▲]", (self.wiringDtpfScroll > 0) and COLORS.fg or COLORS.muted, COLORS.btnBg, function()
            self.wiringDtpfScroll = math.max(0, self.wiringDtpfScroll - 1)
        end)
        self:drawButton(self.w - 14, y, "[▼]", (self.wiringDtpfScroll < maxDScroll) and COLORS.fg or COLORS.muted, COLORS.btnBg, function()
            self.wiringDtpfScroll = math.min(maxDScroll, self.wiringDtpfScroll + 1)
        end)
        self:drawText(self.w - 10, y, string.format("%d-%d/%d", self.wiringDtpfScroll + 1, math.min(#self.cfg.dtpfs, self.wiringDtpfScroll + maxShow), #self.cfg.dtpfs), COLORS.muted, COLORS.bg)
    end
    y = y + 1
    self:fillRect(2, y, self.w - 2, 1, " ", COLORS.headerBg)
    self:drawText(4, y, "UNIT           ADDR      CHAN  OD NET     COORDS         WORK  COIL     DISC  CONV  CAT   MODE / COVER", COLORS.muted, COLORS.headerBg)
    self:addHitbox(67, y, 74, y, function()
        self:toggleCoilDisplay()
    end)
    y = y + 1

    local convCtrlOk = self:isConvControlSupported()
    for visD = 1, math.min(maxShow, #self.cfg.dtpfs - self.wiringDtpfScroll) do
        local i = visD + self.wiringDtpfScroll
        local d = self.cfg.dtpfs[i]
        local st = (self.state.dtpfStatus and self.state.dtpfStatus[i]) or {}
        local rowBg = (visD % 2 == 0) and COLORS.rowAltBg or COLORS.panelBg
        self:fillRect(2, y, self.w - 2, 1, " ", rowBg)
        local function focusDtpfInFleet()
            self.selectedDtpf = i
            self:ensureDtpfVisible(i)
            self.tab = TAB_FLEET
            self.statusMsg = "Focused " .. (d.name or ("DTPF #" .. i)) .. " in Fleet view."
        end
        self:addHitbox(2, y, self.w - 1, y, focusDtpfInFleet)

        local cStr = (d.x and d.z) and string.format("%d,%d,%d", d.x, d.y or 0, d.z) or "-"
        local passTxt = formatDtpfPassLabel(self, d, false)
        local tailStr = (st and st.coverConflict) and "! Cover Override" or passTxt
        local addrTxt = d.isRemote and ("W:" .. d.address:sub(1, 6)) or d.address:sub(1, 8)
        local baseCol = (st and st.coverConflict) and COLORS.yellow or COLORS.fg
        local unitLabel = padOrTrunc(d.name or ("DTPF #" .. i), 11):gsub("%s+$", "")
        self:drawButton(4, y, "[" .. unitLabel .. "]", COLORS.cyan, COLORS.btnBg, focusDtpfInFleet)
        self:drawText(19, y, string.format("%-9s %-5s", addrTxt, padOrTrunc(tostring(d.channelId or "ch1"), 5)), baseCol, rowBg)

        local odOptions = { "global" }
        for k = 1, #nonStockNets do
            odOptions[#odOptions + 1] = nonStockNets[k].address
        end
        odOptions[#odOptions + 1] = "none"
        local curOd = d.odNetAddr or "global"
        local odBtnTxt, odBtnCol
        if curOd == "none" then
            odBtnTxt = "[None    ]"
            odBtnCol = COLORS.muted
        elseif curOd == "global" then
            odBtnTxt = "[Global  ]"
            odBtnCol = COLORS.purple
        else
            odBtnTxt = string.format("[%-8s]", curOd:sub(1, 8))
            odBtnCol = (st and st.odActive) and COLORS.green or COLORS.cyan
        end
        self:drawButton(35, y, odBtnTxt, odBtnCol, COLORS.btnBg, function(step)
            local idx = 1
            for k = 1, #odOptions do
                if odOptions[k] == curOd then idx = k break end
            end
            local nxt = ((idx - 1 + (step or 1)) % #odOptions) + 1
            d.odNetAddr = odOptions[nxt]
            local lbl = (d.odNetAddr == "global" and "Global OD")
                or (d.odNetAddr == "none" and "None")
                or d.odNetAddr:sub(1, 10)
            self:save((d.name or ("DTPF #" .. i)) .. " OD Net -> " .. lbl)
        end)

        local midSeg = string.format("%-14s %-5s",
            padOrTrunc(cStr, 14),
            (st and st.workAllowed) and "YES" or "NO")
        self:drawText(46, y, midSeg, baseCol, rowBg)
        local coilStr = "?"
        if st and st.coilHeat then
            if self:isCoilNameMode() then
                local _, _, tierName, shortName = getCoilTierInfo(st.coilHeat)
                coilStr = (unicode.wlen(tierName) <= 8) and tierName or shortName
            else
                coilStr = tostring(st.coilHeat) .. "K"
            end
        end
        self:drawText(67, y, padOrTrunc(coilStr, 8),
            (st and st.coverConflict) and COLORS.yellow or getCoilColor(st and st.coilHeat), rowBg)
        self:addHitbox(67, y, 74, y, function()
            self:toggleCoilDisplay()
        end)
        self:drawText(76, y, string.format("%-5s", string.format("%.0f%%", (st and st.discountPct) or 0)), baseCol, rowBg)
        local convOn = (st and st.convergenceEnabled == true)
        local convCell = convOn and "⚡ON  " or "OFF  "
        self:drawText(82, y, convCell, convOn and COLORS.purple or COLORS.muted, rowBg)
        local catCode = CATALYST_SHORT[(st and st.catalystTier) or 4] or "DTEC"
        self:drawText(88, y, padOrTrunc(string.format("%-5s %s", catCode, tailStr), self.w - 90), baseCol, rowBg)
        y = y + 1
    end
end

function UI:renderUnifiedMfuPairingPanel(ctx)
    local ep = ctx.ep or {}
    local nonStockNets = ctx.nonStockNets or {}
    local hatches = ep.hatches or {}
    local buses = ep.buses or {}
    local hatchCoords = ep.hatchCoords or {}
    local busCoords = ep.busCoords or {}

    local chById = {}
    for k = 1, #self.cfg.channels do
        local c = self.cfg.channels[k]
        chById[c.id] = c
    end

    local function ensureChannelForDtpf(dtpfIdx, d)
        local cid = d.channelId or ("ch" .. tostring(dtpfIdx))
        d.channelId = cid
        local ch = chById[cid]
        if not ch then
            ch = {
                id = cid,
                name = "Passive " .. cid,
                mode = "hatch_pair",
                shareOnDemand = true,
                enabled = true,
            }
            self.cfg.channels[#self.cfg.channels + 1] = ch
            chById[cid] = ch
        end
        return ch
    end

    local function formatEndpointBadge(addr, coordsMap, dtpf, missingLabel, maxInnerW)
        if not addr or addr == "" then
            return "[" .. missingLabel .. "]", COLORS.red
        end
        local c = coordsMap and coordsMap[addr]
        local dist = nil
        local inner
        if c and c.x and c.z and dtpf and dtpf.x and dtpf.z then
            local dx = c.x - dtpf.x
            local dy = (c.y or dtpf.y or 0) - (dtpf.y or c.y or 0)
            local dz = c.z - dtpf.z
            dist = math.floor(math.sqrt(dx * dx + dy * dy + dz * dz) + 0.5)
            inner = string.format("%s (%d,%d,%d) %dm", addr:sub(1, 6), c.x, c.y or 0, c.z, dist)
        elseif c and c.x and c.z then
            inner = string.format("%s (%d,%d,%d)", addr:sub(1, 6), c.x, c.y or 0, c.z)
        else
            inner = addr:sub(1, 10)
        end
        local col = (dist and dist > 16) and COLORS.yellow or COLORS.green
        return "[" .. padOrTrunc(inner, maxInnerW):gsub("%s+$", "") .. "]", col
    end

    local nD = #self.cfg.dtpfs
    local workerCnt = (self.state and self.state.workerCount) or 0
    local stride = (nD <= 13) and 2 or 1
    local maxShow = (stride == 2) and 13 or 25
    local maxDScroll = math.max(0, nD - maxShow)
    self.wiringDtpfScroll = math.max(0, math.min(maxDScroll, self.wiringDtpfScroll or 0))

    -- Bottom Table (MFU Mode): Unified Discovered DTPF Controllers & 3x MFU Pairing (rows 19..48)
    self:drawFrame(2, 19, 158, 30, COLORS.border, COLORS.panelBg, "round")
    self:drawText(4, 19, string.format(" ◈ DISCOVERED DTPF CONTROLLERS (%d) ", nD), COLORS.accent, COLORS.panelBg)
    local poolBadge = (workerCnt > 0)
        and string.format(" Master + %d Worker Srv · %dH + %dB MFU ", workerCnt, #hatches, #buses)
        or string.format(" %dH + %dB MFU (nearest 3D x,y,z) ", #hatches, #buses)
    self:drawText(41, 19, padOrTrunc(poolBadge, 94), COLORS.muted, COLORS.panelBg)

    if nD > maxShow then
        self:drawButton(138, 19, "[▲]", (self.wiringDtpfScroll > 0) and COLORS.fg or COLORS.muted, COLORS.btnBg, function()
            self.wiringDtpfScroll = math.max(0, self.wiringDtpfScroll - 1)
        end)
        self:drawButton(142, 19, "[▼]", (self.wiringDtpfScroll < maxDScroll) and COLORS.fg or COLORS.muted, COLORS.btnBg, function()
            self.wiringDtpfScroll = math.min(maxDScroll, self.wiringDtpfScroll + 1)
        end)
        self:drawText(147, 19, string.format("%d-%d/%d", self.wiringDtpfScroll + 1, math.min(nD, self.wiringDtpfScroll + maxShow), nD), COLORS.muted, COLORS.panelBg)
    end

    local hdrY = 21
    self:fillRect(3, hdrY, 156, 1, " ", COLORS.headerBg)
    self:drawText(5, hdrY, "DTPF", COLORS.muted, COLORS.headerBg)
    self:drawText(19, hdrY, "CONTROLLER (x,y,z)", COLORS.muted, COLORS.headerBg)
    self:drawText(45, hdrY, "PASSIVE HATCH MFU", COLORS.muted, COLORS.headerBg)
    self:drawText(79, hdrY, "PASSIVE BUS MFU", COLORS.muted, COLORS.headerBg)
    self:drawText(113, hdrY, "OD SUBNET", COLORS.muted, COLORS.headerBg)
    self:drawText(126, hdrY, "COIL", COLORS.muted, COLORS.headerBg)
    self:addHitbox(126, hdrY, 134, hdrY, function()
        self:toggleCoilDisplay()
    end)
    self:drawText(136, hdrY, "DISC", COLORS.muted, COLORS.headerBg)
    self:drawText(143, hdrY, "STATUS", COLORS.muted, COLORS.headerBg)

    if nD == 0 then
        self:drawText(6, 25, "No DTPF Controllers found — wire MFU Adapters and click RESCAN HARDWARE above.", COLORS.muted, COLORS.panelBg)
        return
    end

    local ry = 23
    for visD = 1, math.min(maxShow, nD - self.wiringDtpfScroll) do
        local i = visD + self.wiringDtpfScroll
        local d = self.cfg.dtpfs[i]
        local st = (self.state.dtpfStatus and self.state.dtpfStatus[i]) or {}
        local chId = d.channelId or ("ch" .. tostring(i))
        local ch = chById[chId]
        local rowBg = COLORS.panelBg

        local function focusDtpfInFleet()
            self.selectedDtpf = i
            self:ensureDtpfVisible(i)
            self.tab = TAB_FLEET
            self.statusMsg = "Focused " .. (d.name or ("DTPF #" .. i)) .. " in Fleet view."
        end
        self:addHitbox(3, ry, 158, ry, focusDtpfInFleet)

        local unitLabel = padOrTrunc(d.name or ("DTPF #" .. i), 10):gsub("%s+$", "")
        self:drawButton(5, ry, "[" .. unitLabel .. "]", COLORS.cyan, COLORS.btnBg, focusDtpfInFleet)

        local onlineDot = st.online and "●" or "○"
        local dotCol = (st.coverConflict) and COLORS.yellow or (st.online and COLORS.green or COLORS.red)
        self:drawText(19, ry, onlineDot, dotCol, rowBg)
        local addrTxt = d.isRemote and ("W:" .. tostring(d.address):sub(1, 6)) or tostring(d.address):sub(1, 6)
        local cStr = (d.x and d.z) and string.format("(%d,%d,%d)", d.x, d.y or 0, d.z) or "(?)"
        local baseCol = (st and st.coverConflict) and COLORS.yellow or COLORS.fg
        self:drawText(21, ry, padOrTrunc(addrTxt .. " " .. cStr, 23), baseCol, rowBg)

        local hLbl, hCol = formatEndpointBadge(ch and ch.hatchAddr, hatchCoords, d, "! Unbound Hatch", 30)
        self:drawButton(45, ry, hLbl, hCol, COLORS.btnBg, function(step)
            if #hatches == 0 then return end
            local targetCh = ensureChannelForDtpf(i, d)
            local cur = 0
            for k = 1, #hatches do
                if hatches[k] == targetCh.hatchAddr then cur = k break end
            end
            local nxt = ((cur - 1 + (step or 1) + #hatches) % #hatches) + 1
            targetCh.hatchAddr = hatches[nxt]
            targetCh.activeKey = nil
            self:save((d.name or ("DTPF #" .. i)) .. " Passive Hatch -> " .. targetCh.hatchAddr:sub(1, 8))
        end)

        local bLbl, bCol = formatEndpointBadge(ch and ch.busAddr, busCoords, d, "! Unbound Bus", 30)
        self:drawButton(79, ry, bLbl, bCol, COLORS.btnBg, function(step)
            if #buses == 0 then return end
            local targetCh = ensureChannelForDtpf(i, d)
            local cur = 0
            for k = 1, #buses do
                if buses[k] == targetCh.busAddr then cur = k break end
            end
            local nxt = ((cur - 1 + (step or 1) + #buses) % #buses) + 1
            targetCh.busAddr = buses[nxt]
            targetCh.activeKey = nil
            self:save((d.name or ("DTPF #" .. i)) .. " Passive Bus -> " .. targetCh.busAddr:sub(1, 8))
        end)

        local odOptions = { "global" }
        for k = 1, #nonStockNets do
            odOptions[#odOptions + 1] = nonStockNets[k].address
        end
        odOptions[#odOptions + 1] = "none"
        local curOd = d.odNetAddr or "global"
        local odBtnTxt, odBtnCol
        if curOd == "none" then
            odBtnTxt = "[None    ]"
            odBtnCol = COLORS.muted
        elseif curOd == "global" then
            odBtnTxt = "[Global  ]"
            odBtnCol = COLORS.purple
        else
            odBtnTxt = string.format("[%-8s]", curOd:sub(1, 8))
            odBtnCol = (st and st.odActive) and COLORS.green or COLORS.cyan
        end
        self:drawButton(113, ry, odBtnTxt, odBtnCol, COLORS.btnBg, function(step)
            local idx = 1
            for k = 1, #odOptions do
                if odOptions[k] == curOd then idx = k break end
            end
            local nxt = ((idx - 1 + (step or 1) + #odOptions) % #odOptions) + 1
            d.odNetAddr = odOptions[nxt]
            local lbl = (d.odNetAddr == "global" and "Global OD")
                or (d.odNetAddr == "none" and "None")
                or d.odNetAddr:sub(1, 10)
            self:save((d.name or ("DTPF #" .. i)) .. " OD Net -> " .. lbl)
        end)

        local coilStr = "?"
        if st and st.coilHeat then
            if self:isCoilNameMode() then
                local _, _, tierName, shortName = getCoilTierInfo(st.coilHeat)
                coilStr = (unicode.wlen(tierName) <= 8) and tierName or shortName
            else
                coilStr = tostring(st.coilHeat) .. "K"
            end
        end
        self:drawText(126, ry, padOrTrunc(coilStr, 8),
            (st and st.coverConflict) and COLORS.yellow or getCoilColor(st and st.coilHeat), rowBg)
        self:addHitbox(126, ry, 134, ry, function()
            self:toggleCoilDisplay()
        end)

        self:drawText(136, ry, string.format("%.0f%%", (st and st.discountPct) or 0), baseCol, rowBg)

        local stTxt, stCol
        if st and st.coverConflict then
            stTxt, stCol = "! Cover", COLORS.yellow
        elseif st and st.odActive then
            stTxt, stCol = "⚡OD", COLORS.purple
        elseif st and st.workAllowed and st.convergenceEnabled then
            stTxt, stCol = "⚡4x · Active", COLORS.cyan
        elseif st and st.workAllowed then
            stTxt, stCol = "Active", COLORS.green
        elseif self.cfg.armed then
            stTxt, stCol = "Idle", COLORS.muted
        else
            stTxt, stCol = "Paused", COLORS.muted
        end
        self:drawText(143, ry, padOrTrunc(stTxt, 14), stCol, rowBg)

        ry = ry + stride
    end
end

function UI:renderWiringTab()
    local function findNetInfo(addr)
        for i = 1, #self.discoveredNets do
            if self.discoveredNets[i].address == addr then return self.discoveredNets[i] end
        end
        return nil
    end

    local ep = self.discoveredEndpoints or {}
    local warnings = ep.warnings or {}
    local nonStockNets = {}
    for i = 1, #self.discoveredNets do
        local n = self.discoveredNets[i]
        if n.address and n.address ~= self.cfg.stockNetAddr then
            nonStockNets[#nonStockNets + 1] = n
        end
    end
    local perDtpfOdCount = 0
    for i = 1, #self.cfg.dtpfs do
        local a = self.cfg.dtpfs[i].odNetAddr
        if a and a ~= "global" and a ~= "none" then
            perDtpfOdCount = perDtpfOdCount + 1
        end
    end
    local onlineDtpfs, coverConflicts = 0, 0
    for i = 1, #self.cfg.dtpfs do
        local st = self.state.dtpfStatus and self.state.dtpfStatus[i]
        if st and st.online then onlineDtpfs = onlineDtpfs + 1 end
        if st and st.coverConflict then coverConflicts = coverConflicts + 1 end
    end

    local hasSbHardware = (#(ep.fluidStorageBuses or {}) > 0) or (#(ep.itemStorageBuses or {}) > 0)
    local hasSbCfg = false
    for i = 1, #self.cfg.channels do
        local c = self.cfg.channels[i]
        if c.mode == "storage_bus" and (c.fluidStorageAddr or c.itemStorageAddr) then
            hasSbCfg = true
            break
        end
    end
    local isMfuMode = (not hasSbHardware) and (not hasSbCfg)
    self._setupMfuMode = isMfuMode

    local ctx = {
        ep = ep,
        warnings = warnings,
        sNet = findNetInfo(self.cfg.stockNetAddr),
        odNet = findNetInfo(self.cfg.onDemandNetAddr),
        nonStockNets = nonStockNets,
        perDtpfOdCount = perDtpfOdCount,
        onlineDtpfs = onlineDtpfs,
        coverConflicts = coverConflicts,
        isMfuMode = isMfuMode,
        hasHatchMode = (#(ep.hatches or {}) > 0 or #(ep.buses or {}) > 0)
            and (#(ep.fluidStorageBuses or {}) == 0 and #(ep.itemStorageBuses or {}) == 0),
    }

    self:renderSetupActionBar(ctx)
    self:renderWiringReservesCard()
    self:renderWiringTopologyCard(ctx)
    if isMfuMode then
        self:renderUnifiedMfuPairingPanel(ctx)
    else
        local nextY = self:renderWiringChannelsCard(ep, 19)
        self:renderWiringControllersTable(nextY, nonStockNets)
    end
end

function UI:renderPassiveModal()
    if not self.passiveModalActive then return end
    local dtpfIdx = math.max(1, math.min(#self.cfg.dtpfs, self.passiveModalDtpfIdx or 1))
    self.passiveModalDtpfIdx = dtpfIdx
    local d = self.cfg.dtpfs[dtpfIdx]
    if not d then
        self.passiveModalActive = false
        return
    end
    self.hitboxes = {}

    local mx, my, mw, mh = 23, 6, 114, 38
    self:drawFrame(mx, my, mw, mh, COLORS.accent, COLORS.headerBg, "double")
    self:fillRect(mx + 1, my + 1, mw - 2, mh - 2, " ", COLORS.headerBg)

    local unitName = d.name or ("DTPF #" .. dtpfIdx)
    local chId = d.channelId or "ch1"
    local shareN = countChannelShares(self.cfg, chId)
    local function stepModalDtpf(delta)
        local n = #self.cfg.dtpfs
        if n == 0 then return end
        local nxt = ((dtpfIdx - 1 + delta) % n) + 1
        self.passiveModalDtpfIdx = nxt
        self.selectedDtpf = nxt
    end

    self:drawText(mx + 2, my + 1, "PASSIVE ASSIGNMENT: ", COLORS.cyan, COLORS.headerBg)
    local hx = mx + 22
    if #self.cfg.dtpfs > 1 then
        hx = self:drawButton(hx, my + 1, "[◀]", COLORS.fg, COLORS.btnBg, function() stepModalDtpf(-1) end) + 1
    end
    self:drawText(hx, my + 1, padOrTrunc(unitName, 22), COLORS.fg, COLORS.headerBg)
    hx = hx + math.min(22, unicode.wlen(unitName)) + 1
    if #self.cfg.dtpfs > 1 then
        hx = self:drawButton(hx, my + 1, "[▶]", COLORS.fg, COLORS.btnBg, function() stepModalDtpf(1) end) + 2
    else
        hx = hx + 1
    end
    local chTag = (shareN <= 1) and string.format("[%s · Dedicated]", chId:upper()) or string.format("[%s · Shared x%d]", chId:upper(), shareN)
    if #self.cfg.channels > 1 then
        self:drawButton(hx, my + 1, chTag, (shareN <= 1) and COLORS.green or COLORS.yellow, COLORS.btnBg, function(step)
            cycleChannelForDtpf(self, d, step, unitName)
        end)
    else
        self:drawText(hx, my + 1, chTag, (shareN <= 1) and COLORS.green or COLORS.yellow, COLORS.headerBg)
    end
    self:drawButton(mx + mw - 13, my + 1, "[ X CLOSE ]", COLORS.red, COLORS.darkRed, function()
        self.passiveModalActive = false
    end)

    if shareN > 1 then
        self:drawText(mx + 2, my + 2, padOrTrunc(string.format("! %s is shared by %d DTPFs - changes apply to all %s units. Wire separate Color SB for 1:1 control.",
            chId:upper(), shareN, chId:upper()), mw - 4), COLORS.yellow, COLORS.headerBg)
    else
        self:drawText(mx + 2, my + 2, "Dedicated channel (1:1) - changes here affect ONLY " .. unitName .. ".", COLORS.green, COLORS.headerBg)
    end

    -- Quick Mode buttons
    self:drawText(mx + 2, my + 4, "Quick Mode:", COLORS.muted, COLORS.headerBg)
    local qModes = {
        { id = "auto", label = "[ AUTO (Queue+Loop) ]" },
        { id = "passive_only", label = "[ QUEUE ONLY ]" },
        { id = "fallback_only", label = "[ FOREVER LOOP ]" },
        { id = "od_only", label = "[ ON-DEMAND ONLY ]" },
    }
    local qx = mx + 14
    for _, qm in ipairs(qModes) do
        local isAct = (d.roleOverride or "auto") == qm.id
        qx = self:drawButton(qx, my + 4, qm.label,
            isAct and COLORS.fg or COLORS.muted,
            isAct and COLORS.btnActiveBg or COLORS.btnBg,
            function(_, button)
                d.roleOverride = qm.id
                d.pinnedFamilyId = nil
                if button ~= 1 then
                    self.passiveModalActive = false
                end
                self:save(unitName .. " Passive -> " .. qm.label)
            end) + 1
    end
    if #self.cfg.dtpfs >= 2 then
        self:drawButton(qx, my + 4, "[1 Loop+Rest Q]", COLORS.cyan, COLORS.btnBg, function(_, button)
            applyOneLoopRestQueue(self, dtpfIdx)
            if button ~= 1 then
                self.passiveModalActive = false
            end
        end)
    end

    local dSt = (self.state and self.state.dtpfStatus and self.state.dtpfStatus[dtpfIdx]) or {}
    local dtpfCoilHeat = tonumber(dSt.coilHeat)

    self:drawText(mx + 2, my + 6, "Filter:", COLORS.cyan, COLORS.headerBg)
    local mfx = mx + 10
    local mFilters = {
        { id = "all", label = string.format("[All %d]", #RecipesDB.FAMILIES) },
        { id = "enabled", label = "[Enabled]" },
        { id = "nocat", label = "[Cat-Free]" },
        { id = "loops", label = "[Loops]" },
        { id = "coil", label = "[Coil OK]" },
    }
    for _, mf in ipairs(mFilters) do
        local active = ((self.passiveModalFilter or "all") == mf.id)
        mfx = self:drawButton(mfx, my + 6, mf.label,
            active and COLORS.fg or COLORS.muted,
            active and COLORS.btnActiveBg or COLORS.btnBg,
            function()
                self.passiveModalFilter = mf.id
                self.passiveModalScroll = 0
            end) + 1
    end
    self:drawText(mfx + 1, my + 6, padOrTrunc("Click name=Inspect | R-click=Stay", (mx + mw - 2) - (mfx + 1)), COLORS.muted, COLORS.headerBg)

    self:fillRect(mx + 1, my + 7, mw - 2, 1, " ", COLORS.panelBg)
    self:drawText(mx + 2, my + 7, "RECIPE", COLORS.muted, COLORS.panelBg)
    self:drawText(mx + 33, my + 7, "COIL", COLORS.muted, COLORS.panelBg)
    self:addHitbox(mx + 33, my + 7, mx + 41, my + 7, function()
        self:toggleCoilDisplay()
    end)
    self:drawText(mx + 43, my + 7, "STOCK / TARGET", COLORS.muted, COLORS.panelBg)
    self:drawText(mx + 60, my + 7, "STATUS", COLORS.muted, COLORS.panelBg)
    self:drawText(mx + 84, my + 7, "PIN ACTION", COLORS.muted, COLORS.panelBg)

    local list = getFilteredRecipeList(self, self.passiveModalFilter or "all", dtpfCoilHeat)

    local maxRows = 24
    local maxScroll = math.max(0, #list - maxRows)
    self.passiveModalScroll = math.max(0, math.min(maxScroll, self.passiveModalScroll or 0))
    for r = 1, maxRows do
        local y = my + 7 + r
        local idx = r + self.passiveModalScroll
        local entry = list[idx]
        local rBg = (r % 2 == 0) and COLORS.rowAltBg or COLORS.panelBg
        if entry then
            local fam = entry.fam
            local rc = entry.rc
            local st = (self.state.recipeStatus and self.state.recipeStatus[fam.id]) or {}
            local isPinTarget = (d.roleOverride == "pinned" and d.pinnedFamilyId == fam.id)
            local isPinLoop = (d.roleOverride == "pinned_loop" and d.pinnedFamilyId == fam.id)
            if isPinTarget or isPinLoop then rBg = COLORS.selectedBg end
            self:fillRect(mx + 1, y, mw - 2, 1, " ", rBg)

            self:drawButton(mx + 2, y, padOrTrunc(compactRecipeName(fam.name, 30), 30), (isPinTarget or isPinLoop) and COLORS.cyan or COLORS.fg, rBg, function()
                self.passiveModalActive = false
                self.selectedFamilyId = fam.id
                self.tab = TAB_RECIPES
                self.statusMsg = "Inspecting " .. fam.name .. "."
            end)
            local heat = getRecipeCoilHeat(self, fam, rc)
            local coilBad = (dtpfCoilHeat and dtpfCoilHeat > 0 and heat and heat > dtpfCoilHeat)
            local coilTxt
            if heat then
                if self:isCoilNameMode() then
                    local _, _, tierName, shortName = getCoilTierInfo(heat)
                    local nm = (unicode.wlen(tierName) <= 8) and tierName or shortName
                    coilTxt = (coilBad and "!" or "") .. nm
                else
                    coilTxt = (coilBad and "!" or "") .. string.format("%.1fkK", heat / 1000)
                end
            else
                coilTxt = "Any"
            end
            self:drawText(mx + 33, y, padOrTrunc(coilTxt, 9), coilBad and COLORS.red or getCoilColor(heat), rBg)
            self:addHitbox(mx + 33, y, mx + 41, y, function()
                self:toggleCoilDisplay()
            end)
            local isFl = st.trackedOutput and (st.trackedOutput.isFluid or st.trackedOutput.type == "fluid")
            local stkTxt = string.format("%s/%s", UI.formatNumber(st.currentStock or 0, isFl), UI.formatNumber(rc.target or 1, isFl))
            self:drawText(mx + 43, y, padOrTrunc(stkTxt, 16), COLORS.fg, rBg)
            self:drawText(mx + 60, y, padOrTrunc(compactStatusText(localizeCoilStatus(self, st.stateStr or "Ready"), 22), 22), st.runnable and COLORS.green or COLORS.muted, rBg)

            self:drawButton(mx + 84, y, "[◆ Pin <Target]",
                isPinTarget and COLORS.fg or COLORS.cyan,
                isPinTarget and COLORS.btnActiveBg or COLORS.btnBg,
                function(_, button)
                    d.roleOverride = "pinned"
                    d.pinnedFamilyId = fam.id
                    if button ~= 1 then
                        self.passiveModalActive = false
                    end
                    self:save(unitName .. " pinned -> " .. fam.name .. " (<Target)")
                end)
            self:drawButton(mx + 99, y, "[* Loop 24/7]",
                isPinLoop and COLORS.fg or COLORS.yellow,
                isPinLoop and COLORS.btnActiveBg or COLORS.btnBg,
                function(_, button)
                    d.roleOverride = "pinned_loop"
                    d.pinnedFamilyId = fam.id
                    if button ~= 1 then
                        self.passiveModalActive = false
                    end
                    self:save(unitName .. " pinned loop -> " .. fam.name)
                end)
        else
            self:fillRect(mx + 1, y, mw - 2, 1, " ", rBg)
        end
    end

    local footY = my + 33
    self:drawButton(mx + 2, footY, "[▲ PgUp]", COLORS.fg, COLORS.btnBg, function()
        self.passiveModalScroll = math.max(0, self.passiveModalScroll - 8)
    end)
    self:drawButton(mx + 12, footY, "[▼ PgDn]", COLORS.fg, COLORS.btnBg, function()
        self.passiveModalScroll = math.min(maxScroll, self.passiveModalScroll + 8)
    end)
    local shownFrom = (#list > 0) and (self.passiveModalScroll + 1) or 0
    local shownTo = math.min(#list, self.passiveModalScroll + maxRows)
    self:drawText(mx + 24, footY, string.format("Showing %d-%d of %d recipes | [Esc] or [ X CLOSE ] to cancel",
        shownFrom, shownTo, #list), COLORS.muted, COLORS.headerBg)
end

local function formatAdjustedPromptNumber(n)
    n = math.max(0, math.floor(n))
    if n == 0 then return "0" end
    if n >= 1e9 and n % 1e8 == 0 then
        return (UI.formatNumber(n, false):gsub("%.00B$", "B"):gsub("(%.[1-9])0B$", "%1B"))
    elseif n >= 1e6 and n % 1e5 == 0 then
        return (UI.formatNumber(n, false):gsub("%.0M$", "M"))
    elseif n >= 1e3 and n % 100 == 0 then
        return (UI.formatNumber(n, false):gsub("%.0K$", "K"))
    end
    return string.format("%d", n)
end

function UI:renderPromptModal()
    if not self.promptActive then return end
    -- Replace underlying hitboxes so modal owns touch clicks exclusively while open.
    self.hitboxes = {}

    local isNum = (self.promptIsNumeric == true)
    local mw = isNum and 84 or 76
    local mh = isNum and 13 or 9
    local mx = math.floor((self.w - mw) / 2)
    local my = math.floor((self.h - mh) / 2)

    self:drawFrame(mx, my, mw, mh, COLORS.accent, COLORS.headerBg, "double")
    self:drawText(mx + 2, my + 1, padOrTrunc(self.promptTitle, mw - 4), COLORS.cyan, COLORS.headerBg)

    self:fillRect(mx + 2, my + 3, mw - 4, 1, " ", COLORS.bg)
    self:drawText(mx + 3, my + 3, padOrTrunc(self.promptBuffer .. "_", mw - 6), COLORS.fg, COLORS.bg)

    if isNum then
        self:drawText(mx + 2, my + 5, "Set:", COLORS.muted, COLORS.headerBg)
        local sx = mx + 7
        for _, tok in ipairs({ "0", "10K", "100K", "500K", "1M", "10M", "100M", "1B", "10B", "50B" }) do
            local active = (self.promptBuffer:upper() == tok)
            sx = self:drawButton(sx, my + 5, "[" .. tok .. "]",
                active and COLORS.fg or COLORS.accent,
                active and COLORS.btnActiveBg or COLORS.btnBg,
                function()
                    self.promptBuffer = tok
                end) + 1
        end

        self:drawText(mx + 2, my + 7, "Adj:", COLORS.muted, COLORS.headerBg)
        local ax = mx + 7
        for _, adj in ipairs({
            { label = "/10", factor = 0.1 },
            { label = "/2", factor = 0.5 },
            { label = "-25%", factor = 0.75 },
            { label = "+25%", factor = 1.25 },
            { label = "x2", factor = 2.0 },
            { label = "x10", factor = 10.0 },
        }) do
            ax = self:drawButton(ax, my + 7, "[" .. adj.label .. "]", COLORS.cyan, COLORS.btnBg, function()
                local cur = UI.parseNumber(self.promptBuffer) or 0
                local nxt = math.max(0, math.floor(cur * adj.factor + 0.5))
                self.promptBuffer = formatAdjustedPromptNumber(nxt)
            end) + 1
        end
    end

    local hintY = isNum and (my + 9) or (my + 5)
    local btnY = isNum and (my + 11) or (my + 7)
    self:drawText(mx + 2, hintY, padOrTrunc(self.promptHint, mw - 4), COLORS.muted, COLORS.headerBg)

    local bx = mx + 2
    bx = self:drawButton(bx, btnY, "[ CLEAR ]", COLORS.yellow, COLORS.btnBg, function()
        self.promptBuffer = ""
    end) + 2
    bx = self:drawButton(bx, btnY, "[ APPLY ]", COLORS.green, COLORS.darkGreen, function()
        local cb = self.promptCallback
        local val = self.promptBuffer
        self.promptActive = false
        self.promptIsNumeric = false
        self.promptCallback = nil
        if cb then cb(val) end
    end) + 2
    self:drawButton(bx, btnY, "[ CANCEL ]", COLORS.red, COLORS.darkRed, function()
        self.promptActive = false
        self.promptIsNumeric = false
        self.promptCallback = nil
    end)
end

local function appendRawInputs(self, lines)
    local st = self.state or {}
    local stock = st.stock or {}
    local fluids = stock.fluids or {}
    local od = st.onDemand or {}

    lines[#lines + 1] = { text = "── 1. RAW INPUTS (What OC Sees From AE2 & DTPFs) ──", col = COLORS.cyan }
    local stockNet = self.cfg.stockNetAddr and self.cfg.stockNetAddr:sub(1, 8) or "None"
    local catParts = {}
    for i = 1, #RecipesDB.CATALYST_TIERS do
        local ct = RecipesDB.CATALYST_TIERS[i]
        local flr = (self.cfg.catalystFloors and self.cfg.catalystFloors[ct.code]) or 100000
        catParts[i] = string.format("%s=%s(min:%s)", ct.code, fmtCompactNum(fluids[ct.fluid] or 0, true), fmtCompactNum(flr, true))
    end
    lines[#lines + 1] = {
        text = string.format("Stock AE2 (%s): %s | %s | %s", stockNet, catParts[1], catParts[2], catParts[3]),
        col = COLORS.fg,
    }
    local dtrAmt = fluids["dimensionallytranscendentresidue"] or 0
    local dtrRate = st.dtrRatePerMin and string.format(" (%s%s/m)", (st.dtrRatePerMin >= 0) and "+" or "", fmtCompactNum(st.dtrRatePerMin, true)) or ""
    lines[#lines + 1] = {
        text = string.format("  %s | %s | DTR=%s%s (min:%s)",
            catParts[4], catParts[5], fmtCompactNum(dtrAmt, true), dtrRate, fmtCompactNum(self.cfg.dtrReserveFloor or 0, true)),
        col = COLORS.fg,
    }
    local odAddr = self.cfg.onDemandNetAddr and self.cfg.onDemandNetAddr:sub(1, 8) or "None"
    lines[#lines + 1] = {
        text = string.format("On-Demand AE2 (%s): hasWork=%s stalled=%s patCat=%s summary=%s",
            odAddr, tostring(od.hasWork == true), tostring(od.stalled == true),
            tostring(od.hasPatternedCatalyst == true), tostring(od.summary or "Idle")),
        col = od.stalled and COLORS.yellow or (od.hasWork and COLORS.purple or COLORS.muted),
    }

    for i = 1, #self.cfg.dtpfs do
        local d = self.cfg.dtpfs[i]
        local dst = (st.dtpfStatus and st.dtpfStatus[i]) or {}
        local coord = (d.x and d.z) and string.format("%d,%d,%d", d.x, d.y or 0, d.z) or "?"
        lines[#lines + 1] = {
            text = string.format("  DTPF #%d (%s @ %s): onl=%s act=%s prog=%d/%d work=%s disc=%.0f%% coil=%s conv=%s(ctrl=%s) cat=T%d",
                i, tostring(d.address):sub(1, 6), coord, tostring(dst.online == true), tostring(dst.active == true),
                dst.progress or 0, dst.maxProgress or 0, tostring(dst.workAllowed == true),
                tonumber(dst.discountPct) or 0, tostring(dst.coilHeat or "?"),
                tostring(dst.convergenceEnabled == true), tostring(dst.supportsConvControl ~= false),
                tonumber(dst.catalystTier) or 4),
            col = dst.online and COLORS.fg or COLORS.red,
        }
    end
end

local function appendRawDecisions(self, lines)
    local st = self.state or {}
    lines[#lines + 1] = { text = "── 2. RAW DECISIONS (Policy & Priority Queue Evaluation) ──", col = COLORS.green }
    lines[#lines + 1] = {
        text = string.format("Policy: armed=%s conv=%s odConv=%s pauseOnOD=%s cat=T%d(fb=%s) split=%s nc=%s log=%s",
            tostring(self.cfg.armed == true), tostring(self.cfg.globalConvMode), tostring(self.cfg.onDemandConvMode),
            tostring(self.cfg.pausePassivesOnOD == true), tonumber(self.cfg.defaultCatalystTier) or 4,
            tostring(self.cfg.catalystAutoFallback == true),
            self.cfg.allowParallelSameRecipe and "Parallel" or "Distinct",
            self.cfg.uniformNcSubnet and "Color0" or "Main", tostring(self.cfg.logLevel or "normal")),
        col = COLORS.fg,
    }
    local enabledRecs = {}
    for i = 1, #RecipesDB.FAMILIES do
        local fam = RecipesDB.FAMILIES[i]
        local rc = self.cfg.recipes[fam.id]
        if rc and rc.enabled then
            enabledRecs[#enabledRecs + 1] = { fam = fam, rc = rc }
        end
    end
    table.sort(enabledRecs, function(a, b) return (a.rc.priority or 999) < (b.rc.priority or 999) end)
    if #enabledRecs == 0 then
        lines[#lines + 1] = { text = "  (No enabled passive recipes in queue)", col = COLORS.muted }
        return
    end
    for k = 1, #enabledRecs do
        local fam, rc = enabledRecs[k].fam, enabledRecs[k].rc
        local rSt = (st.recipeStatus and st.recipeStatus[fam.id]) or {}
        local isFl = rSt.trackedOutput and (rSt.trackedOutput.isFluid or rSt.trackedOutput.type == "fluid")
        local tgtStr = rc.forever and "24/7" or fmtCompactNum(rc.target or 1, isFl)
        local dList = (#(rSt.activeDtpfs or {}) > 0) and (" [" .. formatDtpfIdList(rSt.activeDtpfs, 4) .. "]") or ""
        local col = (#(rSt.activeDtpfs or {}) > 0) and COLORS.green
            or ((rSt.needsStock and not rSt.runnable) and COLORS.yellow or COLORS.muted)
        lines[#lines + 1] = {
            text = string.format("  #%02d %s %s: %s / %s -> %s%s",
                rc.priority or k, rc.forever and "[24/7]" or "[<Tgt]", compactRecipeName(fam.name, 26),
                fmtCompactNum(rSt.currentStock or 0, isFl), tgtStr, tostring(rSt.stateStr or "?"), dList),
            col = col,
        }
    end
end

local function formatSlotFilters(list, isFluid, sentinelName)
    if type(list) == "table" and #list > 0 then
        local out = {}
        for i = 1, math.min(6, #list) do
            local e = list[i]
            if isFluid then
                out[i] = string.format("%s(%s)", tostring(e.name), fmtCompactNum(e.amount or 0, true))
            else
                out[i] = string.format("%s:%dx%d", tostring(e.name), e.damage or 0, e.amount or 1)
            end
        end
        if #list > 6 then out[#out + 1] = "+" .. tostring(#list - 6) end
        return table.concat(out, ", ")
    end
    if sentinelName then
        return "0-stock sentinel (" .. tostring(sentinelName) .. ")"
    end
    return "(cleared / none)"
end

local function appendRawOutputs(self, lines)
    local st = self.state or {}
    local meta = st.lastPollMeta or {}
    lines[#lines + 1] = { text = "── 3. RAW OUTPUTS (Hardware Commands & Channel Slot Filters) ──", col = COLORS.purple }
    lines[#lines + 1] = {
        text = string.format("Last Poll Write Counts: step=#%d chWrites=%d workWrites=%d convWrites=%d bridge=%dL | Bridge: %s",
            (st.stepCount or 0), meta.chWrites or 0, meta.workWrites or 0, meta.convWrites or 0, meta.bridgeLiters or 0,
            tostring(st.odBridgeStatus or "Idle")),
        col = COLORS.fg,
    }
    for i = 1, #self.cfg.channels do
        local ch = self.cfg.channels[i]
        local cSt = (st.channelStatus and st.channelStatus[ch.id]) or {}
        lines[#lines + 1] = {
            text = string.format("  %s (%s): mode=%s key=%s",
                ch.id, tostring(ch.mode), tostring(cSt.mode or "IDLE"), tostring(ch.activeKey or "unset")),
            col = (cSt.mode == "PASSIVE" or cSt.mode == "FALLBACK") and COLORS.cyan or COLORS.muted,
        }
        lines[#lines + 1] = {
            text = "    Hatch: " .. formatSlotFilters(ch.lastFluids, true, ch.fluidSentinel),
            col = COLORS.fg,
        }
        lines[#lines + 1] = {
            text = "    Bus  : " .. formatSlotFilters(ch.lastItems, false, ch.itemSentinel),
            col = COLORS.fg,
        }
    end
    for i = 1, #self.cfg.dtpfs do
        local d = self.cfg.dtpfs[i]
        local dst = (st.dtpfStatus and st.dtpfStatus[i]) or {}
        lines[#lines + 1] = {
            text = string.format("  DTPF #%d (%s): allowWork=%s wantConv=%s wantCat=T%d job=%s (%s)",
                i, d.name or ("DTPF #" .. i), tostring(dst.shouldAllowWork == true), tostring(dst.wantConv == true),
                tonumber(dst.wantCatTier) or 4, tostring(dst.jobMode or "IDLE"), tostring(dst.jobLabel or "-")),
            col = dst.shouldAllowWork and COLORS.fg or COLORS.muted,
        }
    end
end

function UI:renderLogActivityPane(mx, my, mw, mh)
    local bottlenecks = (self.state and self.state.bottlenecks) or {}
    local cw = self.state and self.state.coverageWarning
    local alertList = {}
    for k = 1, #bottlenecks do
        alertList[#alertList + 1] = bottlenecks[k]
    end
    if cw then
        alertList[#alertList + 1] = {
            kind = "coverage",
            name = cw.summary,
            reason = cw.reason,
            familyId = cw.familyId,
            dtpfIdx = cw.dtpfIdx,
        }
    end
    self:drawText(mx + 2, my + 3, string.format("BOTTLENECKS & ALERTS (%d):", #alertList), COLORS.accent, COLORS.headerBg)
    local divY
    if #alertList == 0 then
        self:fillRect(mx + 1, my + 4, mw - 2, 1, " ", COLORS.panelBg)
        self:drawText(mx + 2, my + 4, "✓ 0 Bottlenecks - all enabled passive recipes & DTPFs are runnable.", COLORS.green, COLORS.panelBg)
        divY = my + 5
    else
        local showBn = math.min(6, #alertList)
        for k = 1, showBn do
            local y = my + 3 + k
            local bn = alertList[k]
            local rBg = (k % 2 == 0) and COLORS.rowAltBg or COLORS.panelBg
            self:fillRect(mx + 1, y, mw - 2, 1, " ", rBg)
            local bnCol = (bn.kind == "cover" or bn.kind == "offline") and COLORS.red or COLORS.yellow
            local txt = string.format("! %s - %s", tostring(bn.name or "?"), tostring(bn.reason or "Blocked"))
            self:drawText(mx + 2, y, padOrTrunc(txt, mw - 18), bnCol, rBg)
            if bn.kind == "coverage" then
                self:drawButton(mx + mw - 14, y, "[Fix 24/7 →]", COLORS.yellow, COLORS.btnBg, function()
                    self.logModalActive = false
                    if bn.familyId then
                        self.selectedFamilyId = bn.familyId
                        self.tab = TAB_RECIPES
                    else
                        if bn.dtpfIdx then
                            self.selectedDtpf = bn.dtpfIdx
                            self:ensureDtpfVisible(bn.dtpfIdx)
                        end
                        self.tab = TAB_FLEET
                    end
                    self:setStatus("24/7 Coverage: " .. tostring(bn.reason or ""))
                end)
            elseif bn.familyId then
                self:drawButton(mx + mw - 14, y, "[Inspect →]", COLORS.cyan, COLORS.btnBg, function()
                    self.logModalActive = false
                    self.selectedFamilyId = bn.familyId
                    self.tab = TAB_RECIPES
                    self:setStatus("Inspecting bottleneck: " .. tostring(bn.name or bn.familyId))
                end)
            elseif bn.dtpfIdx or bn.kind == "coverage" then
                self:drawButton(mx + mw - 14, y, bn.dtpfIdx and "[Focus →]" or "[Fleet →]", COLORS.cyan, COLORS.btnBg, function()
                    self.logModalActive = false
                    if bn.dtpfIdx then
                        self.selectedDtpf = bn.dtpfIdx
                        self:ensureDtpfVisible(bn.dtpfIdx)
                    end
                    self.tab = TAB_FLEET
                    self:setStatus("Focused " .. tostring(bn.name or "DTPF Fleet"))
                end)
            end
        end
        divY = my + 4 + showBn
    end

    self:drawText(mx + 1, divY, string.rep("─", mw - 2), COLORS.border, COLORS.headerBg)
    local filterY = divY + 1
    self:drawText(mx + 2, filterY, "STAGE:", COLORS.accent, COLORS.headerBg)
    local fx = mx + 9
    for _, fl in ipairs({
        { id = "ALL",  label = "[All]"  },
        { id = "IN",   label = "[IN]"   },
        { id = "DEC",  label = "[DEC]"  },
        { id = "OUT",  label = "[OUT]"  },
        { id = "WARN", label = "[WARN]" },
    }) do
        local active = ((self.logStageFilter or "ALL") == fl.id)
        fx = self:drawButton(fx, filterY, fl.label,
            active and COLORS.fg or COLORS.muted,
            active and COLORS.btnActiveBg or COLORS.btnBg,
            function()
                self.logStageFilter = fl.id
                self.logModalScroll = 0
            end) + 1
    end

    local allEvents = (self.state and self.state.events) or {}
    local curFilter = self.logStageFilter or "ALL"
    local events = {}
    for i = 1, #allEvents do
        local ev = allEvents[i]
        if curFilter == "ALL" or (ev.stage or "DEC") == curFilter then
            events[#events + 1] = ev
        end
    end

    local hdrY = filterY + 1
    self:fillRect(mx + 1, hdrY, mw - 2, 1, " ", COLORS.panelBg)
    self:drawText(mx + 2, hdrY, "TIME", COLORS.muted, COLORS.panelBg)
    self:drawText(mx + 13, hdrY, "STEP", COLORS.muted, COLORS.panelBg)
    self:drawText(mx + 21, hdrY, "STAGE", COLORS.muted, COLORS.panelBg)
    self:drawText(mx + 28, hdrY, "EVENT MESSAGE", COLORS.muted, COLORS.panelBg)

    local footY = my + mh - 2
    local maxEvRows = footY - hdrY - 1
    local maxEvScroll = math.max(0, #events - maxEvRows)
    self.logModalScroll = math.max(0, math.min(maxEvScroll, self.logModalScroll or 0))
    if #events == 0 then
        self:fillRect(mx + 1, hdrY + 1, mw - 2, 1, " ", COLORS.panelBg)
        self:drawText(mx + 2, hdrY + 1, "No matching events yet - steady polls stay quiet in Quiet/Normal mode; pick [Raw] for full traces.", COLORS.muted, COLORS.panelBg)
    else
        for r = 1, maxEvRows do
            local y = hdrY + r
            local rBg = (r % 2 == 0) and COLORS.rowAltBg or COLORS.panelBg
            self:fillRect(mx + 1, y, mw - 2, 1, " ", rBg)
            local ev = events[r + self.logModalScroll]
            if ev then
                local stg = ev.stage or "DEC"
                local stStyle = STAGE_STYLE[stg] or STAGE_STYLE.DEC
                self:drawText(mx + 2, y, formatLogUptime(ev.uptime), COLORS.muted, rBg)
                self:drawText(mx + 13, y, string.format("#%-5d", tonumber(ev.step) or 0), COLORS.muted, rBg)
                self:drawText(mx + 21, y, stStyle.badge, stStyle.col, rBg)
                self:drawText(mx + 28, y, padOrTrunc(tostring(ev.text or ""), mw - 30), getEventLineColor(ev), rBg)
            end
        end
    end
    return #events, maxEvRows, maxEvScroll
end

function UI:renderLogRawSnapshotPane(mx, my, mw, mh)
    local st = self.state or {}
    local meta = st.lastPollMeta or {}
    local lvlObj = LOG_LEVELS[findModeIndex(LOG_LEVELS, self.cfg.logLevel or "normal", 2)]
    self:drawText(mx + 2, my + 3, padOrTrunc(string.format(
        "LIVE SNAPSHOT: Step #%d | Uptime %s | Verbosity: %s | StockPolled=%s | Poll Interval: %.0fs",
        st.stepCount or 0, formatLogUptime(meta.uptime or st._lastPollUptime), lvlObj.label,
        tostring(meta.stockPolled == true), tonumber(self.cfg.pollInterval) or 2), mw - 4), COLORS.accent, COLORS.headerBg)

    local lines = {}
    appendRawInputs(self, lines)
    lines[#lines + 1] = { text = "", col = COLORS.fg }
    appendRawDecisions(self, lines)
    lines[#lines + 1] = { text = "", col = COLORS.fg }
    appendRawOutputs(self, lines)

    local startY = my + 4
    local footY = my + mh - 2
    local maxRows = footY - startY - 1
    local maxScroll = math.max(0, #lines - maxRows)
    self.logModalScroll = math.max(0, math.min(maxScroll, self.logModalScroll or 0))
    for r = 1, maxRows do
        local ry = startY + r - 1
        local rBg = (r % 2 == 0) and COLORS.rowAltBg or COLORS.panelBg
        self:fillRect(mx + 1, ry, mw - 2, 1, " ", rBg)
        local entry = lines[r + self.logModalScroll]
        if entry and entry.text ~= "" then
            self:drawText(mx + 2, ry, padOrTrunc(entry.text, mw - 4), entry.col or COLORS.fg, rBg)
        end
    end
    return #lines, maxRows, maxScroll
end

function UI:renderMaintModal()
    if not self.maintModalActive then return end
    self.hitboxes = {}

    local mx, my, mw, mh = 6, 4, 148, 43
    self:drawFrame(mx, my, mw, mh, COLORS.accent, COLORS.headerBg, "double")
    self:fillRect(mx + 1, my + 1, mw - 2, mh - 2, " ", COLORS.headerBg)

    local mSt = (self.state and self.state.maintStatus) or {}
    local mEn = (self.cfg.maintEnabled == true)
    self:drawText(mx + 2, my + 1, "AE2 LEVEL MAINTAINER:", COLORS.cyan, COLORS.headerBg)
    local bx = self:drawButton(mx + 24, my + 1, mEn and "[● ON ]" or "[○ OFF]",
        mEn and COLORS.green or COLORS.muted, mEn and COLORS.darkGreen or COLORS.btnBg, function()
            self.cfg.maintEnabled = not mEn
            self:save("In-Game Maintainer -> " .. (self.cfg.maintEnabled and "ON" or "OFF"))
        end) + 2

    local lk = mSt.link or "none"
    local lkTxt = (lk == "adapter") and "✓ Mainnet Adapter"
        or ((lk == "modem" or lk == "tunnel") and "✓ In-Game Modem"
        or "! Unwired (Adapter/Modem)")
    local lkCol = (lk ~= "none") and COLORS.green or COLORS.yellow
    self:drawText(bx, my + 1, lkTxt, lkCol, COLORS.headerBg)
    bx = bx + unicode.wlen(lkTxt) + 2

    local freeRes = tonumber(self.cfg.maintFreeCpus) or 2
    bx = self:drawButton(bx, my + 1, string.format("[Keep Free:%d CPUs]", freeRes), COLORS.fg, COLORS.btnBg, function(step)
        self.cfg.maintFreeCpus = (freeRes + (step or 1) + 5) % 5
        self:save("Maintainer Keep Free CPUs -> " .. tostring(self.cfg.maintFreeCpus))
    end) + 1

    local cMode = self.cfg.maintConflictMode or "defer"
    local cLbl = (cMode == "defer" and "[Stock:Defer]") or (cMode == "warn" and "[Stock:Warn ]") or "[Stock:Ign  ]"
    bx = self:drawButton(bx, my + 1, cLbl, cMode == "defer" and COLORS.cyan or (cMode == "warn" and COLORS.yellow or COLORS.muted), COLORS.btnBg, function()
        local nxt = (cMode == "defer" and "warn") or (cMode == "warn" and "ignore") or "defer"
        self.cfg.maintConflictMode = nxt
        self:save("Maintainer Stock Overlap Mode -> " .. nxt)
    end) + 1

    local filtAct = (self.maintFilterActive ~= false)
    bx = self:drawButton(bx, my + 1, filtAct and "[Show:Active]" or "[Show:All   ]",
        filtAct and COLORS.cyan or COLORS.fg, COLORS.btnBg, function()
            self.maintFilterActive = not filtAct
            self.maintModalScroll = 0
        end) + 1

    self:drawButton(bx, my + 1, "[↻ Sync]", COLORS.cyan, COLORS.btnBg, function()
        if self.state then self.state._forceMaintSync = true end
        Scheduler.step(self.cfg, self.state, { cachedOnly = true, forceMaintSync = true })
        self:setStatus("Synced Maintainer with Mainnet AE2.")
    end)

    self:drawButton(mx + mw - 13, my + 1, "[ X CLOSE ]", COLORS.red, COLORS.darkRed, function()
        self.maintModalActive = false
    end)

    local peerInfo = mSt.stockPeerOnline
        and string.format("StockOC:ON (Overlap:%d)", mSt.overlapCount or 0)
        or "StockOC:--"
    local mMode = mSt.maintMode or ((mEn == true) and "local" or "off")
    local mModeLbl = (mMode == "mainnet") and "MAINNET STOCK" or ((mMode == "local") and "LOCAL FALLBACK" or "OFF")
    local sub = string.format("Mode:%s · Act:%d Lo:%d Cr:%d · FreeCPU:%d/%d (>%d) · %s | Tab3 inputs toggle",
        mModeLbl, mSt.activeCount or 0, mSt.lowCount or 0, mSt.craftingCount or 0, mSt.freeCpus or 0, mSt.totalCpus or 0, freeRes, peerInfo)
    self:drawText(mx + 2, my + 2, padOrTrunc(sub, mw - 4), (mSt.overlapCount or 0) > 0 and COLORS.yellow or COLORS.muted, COLORS.headerBg)

    local mq = tostring(self.maintModalSearch or "")
    local sx = mx + 2
    sx = self:drawButton(sx, my + 3, "[/: " .. padOrTrunc(mq ~= "" and mq or "Search rules...", 28) .. "]",
        (mq ~= "") and COLORS.cyan or COLORS.fg, COLORS.btnBg, function()
            self:openPrompt("Search Level Maintainer Rules (name, mode, status):", mq,
                "Type query & press [Enter] / [APPLY], or blank to clear.", function(txt)
                    self.maintModalSearch = tostring(txt or "")
                    self.maintModalScroll = 0
                    self:setStatus((self.maintModalSearch ~= "") and ("Maintainer filter: " .. self.maintModalSearch) or "Cleared Maintainer search.")
                end)
        end) + 1
    if mq ~= "" then
        self:drawButton(sx, my + 3, "[Clr]", COLORS.yellow, COLORS.btnBg, function()
            self.maintModalSearch = ""
            self.maintModalScroll = 0
        end)
    end

    local hdrY = my + 4
    self:fillRect(mx + 1, hdrY, mw - 2, 1, " ", COLORS.panelBg)
    self:drawText(mx + 2, hdrY, "MODE", COLORS.muted, COLORS.panelBg)
    self:drawText(mx + 10, hdrY, "ITEM / FLUID", COLORS.muted, COLORS.panelBg)
    self:drawText(mx + 52, hdrY, "STOCK", COLORS.muted, COLORS.panelBg)
    self:drawText(mx + 65, hdrY, "TARGET", COLORS.muted, COLORS.panelBg)
    self:drawText(mx + 81, hdrY, "BATCH", COLORS.muted, COLORS.panelBg)
    self:drawText(mx + 97, hdrY, "DEMAND", COLORS.muted, COLORS.panelBg)
    self:drawText(mx + 109, hdrY, "STATUS", COLORS.muted, COLORS.panelBg)

    local rules = self.cfg.maintRules or {}
    local rMap = {}
    for k = 1, #(mSt.rules or {}) do
        local sr = mSt.rules[k]
        if sr and sr.id then rMap[sr.id] = sr end
    end

    local mTerms = {}
    for tok in string.lower(mq):gmatch("%S+") do mTerms[#mTerms + 1] = tok end
    local visRules = {}
    for i = 1, #rules do
        local r = rules[i]
        if r then
            local sr = rMap[r.id] or {}
            local isAct = (r.mode == "always") or (sr.demanded == true)
                or (sr.stockKnown and (sr.stock or 0) < (r.target or 1) and r.mode ~= "off")
            if (not filtAct) or isAct then
                local okQ = true
                if #mTerms > 0 then
                    local hay = string.lower(table.concat({
                        tostring(r.label or ""),
                        tostring(r.name or ""),
                        tostring(r.type or ""),
                        tostring(r.mode or ""),
                        tostring(sr.status or ""),
                        tostring(sr.err or ""),
                    }, " "))
                    for _, tok in ipairs(mTerms) do
                        if not hay:find(tok, 1, true) then okQ = false; break end
                    end
                end
                if okQ then
                    visRules[#visRules + 1] = { rule = r, realIdx = i, sr = sr }
                end
            end
        end
    end

    local maxRows = mh - 7
    local maxScroll = math.max(0, #visRules - maxRows)
    self.maintModalScroll = math.max(0, math.min(maxScroll, self.maintModalScroll or 0))
    for row = 1, maxRows do
        local y = hdrY + row
        local rBg = (row % 2 == 0) and COLORS.rowAltBg or COLORS.panelBg
        self:fillRect(mx + 1, y, mw - 2, 1, " ", rBg)
        local ent = visRules[row + self.maintModalScroll]
        if ent then
            local rule, sr = ent.rule, ent.sr
            local isFl = (rule.type == "fluid")
            local mMode = rule.mode or "auto"
            local mLbl = (mMode == "always" and "[Alw ]") or (mMode == "off" and "[Off ]") or "[Auto]"
            local mCol = (mMode == "always" and COLORS.green) or (mMode == "off" and COLORS.muted) or COLORS.cyan
            self:drawText(mx + 2, y, mLbl, mCol, COLORS.btnBg)

            self:drawText(mx + 10, y, padOrTrunc(rule.label, 40), (mMode == "off") and COLORS.muted or COLORS.fg, rBg)
            local stkStr = sr.stockKnown and UI.formatNumber(sr.stock or 0, isFl) or "?"
            self:drawText(mx + 52, y, padOrTrunc(stkStr, 11),
                (sr.stockKnown and (sr.stock or 0) < (rule.target or 1) and sr.demanded) and COLORS.yellow or COLORS.muted, rBg)

            self:drawText(mx + 65, y, "[" .. padOrTrunc(UI.formatNumber(rule.target or 1, isFl), 11):gsub("%s+$", "") .. "]",
                COLORS.cyan, COLORS.btnBg)
            self:drawText(mx + 81, y, "[" .. padOrTrunc(UI.formatNumber(rule.batch or 1, isFl), 11):gsub("%s+$", "") .. "]",
                COLORS.fg, COLORS.btnBg)

            local demTxt = (mMode == "always" and "Always") or (sr.demanded and "✓ Active" or "· Idle")
            local demCol = (mMode == "always" or sr.demanded) and COLORS.green or COLORS.muted
            self:drawText(mx + 97, y, padOrTrunc(demTxt, 10), demCol, rBg)

            local sStr = tostring(sr.stateStr or (mMode == "off" and "Off" or "Idle"))
            if sr.warn and not sStr:find("Stock", 1, true) then
                sStr = sStr .. " (" .. tostring(sr.warn) .. ")"
            end
            local sCol = COLORS.muted
            if sStr == "OK" then sCol = COLORS.green
            elseif sStr:find("Crafting", 1, true) or sStr:find("Starting", 1, true) or sStr:find("Dispatch", 1, true) then sCol = COLORS.cyan
            elseif sStr:find("Deferred", 1, true) or sStr:find("Overlap", 1, true) then sCol = COLORS.purple
            elseif sStr:find("Wait", 1, true) or sStr:find("No ", 1, true) or sStr:find("CPU", 1, true) then sCol = COLORS.yellow
            end
            self:drawText(mx + 109, y, padOrTrunc(sStr, (mx + mw - 6) - (mx + 109)), sCol, rBg)
            self:drawText(mx + mw - 5, y, "[x]", COLORS.red, COLORS.btnBg)
        elseif row == 1 and #visRules == 0 then
            self:drawText(mx + 10, y, "No active rules. Click [Show:All   ], [+ Selected Recipe], or inputs on Tab 3.", COLORS.muted, rBg)
        end
    end
    self.hitboxes[#self.hitboxes + 1] = {
        x1 = mx + 2,
        y1 = hdrY + 1,
        x2 = mx + mw - 3,
        y2 = hdrY + maxRows,
        fn = function(_, _, tx, ty)
            local ent = visRules[(ty - hdrY) + (self.maintModalScroll or 0)]
            if not ent then return end
            local rule = ent.rule
            local isFl = (rule.type == "fluid")
            if tx >= mx + mw - 6 then
                table.remove(self.cfg.maintRules, ent.realIdx)
                self:save("Removed Maintainer rule: " .. tostring(rule.label or rule.name))
            elseif tx <= mx + 8 then
                local mMode = rule.mode or "auto"
                rule.mode = (mMode == "auto" and "always") or (mMode == "always" and "off") or "auto"
                self:save(rule.label .. " maintainer -> " .. rule.mode)
            elseif tx >= mx + 65 and tx <= mx + 79 then
                self:openNumberPrompt("Target Stock for " .. rule.label .. ":", UI.formatNumber(rule.target or 1, false), function(val)
                    local p = UI.parseNumber(val)
                    if p and p > 0 then
                        rule.target = p
                        self:save(rule.label .. " target -> " .. UI.formatNumber(p, isFl))
                    end
                end)
            elseif tx >= mx + 81 and tx <= mx + 94 then
                self:openNumberPrompt("Batch Size for " .. rule.label .. ":", UI.formatNumber(rule.batch or 1, false), function(val)
                    local p = UI.parseNumber(val)
                    if p and p > 0 then
                        rule.batch = p
                        self:save(rule.label .. " batch -> " .. UI.formatNumber(p, isFl))
                    end
                end)
            end
        end,
    }

    local footY = my + mh - 2
    self:drawButton(mx + 2, footY, "[▲ PgUp]", COLORS.fg, COLORS.btnBg, function()
        self.maintModalScroll = math.max(0, (self.maintModalScroll or 0) - 8)
    end)
    self:drawButton(mx + 12, footY, "[▼ PgDn]", COLORS.fg, COLORS.btnBg, function()
        self.maintModalScroll = math.min(maxScroll, (self.maintModalScroll or 0) + 8)
    end)
    self:drawButton(mx + 22, footY, "[+ Selected Recipe]", COLORS.green, COLORS.btnBg, function()
        local inps = Scheduler.collectRecipeMaintInputs(self.cfg, self.selectedFamilyId)
        for i = 1, #inps do
            Scheduler.upsertMaintInput(self.cfg, inps[i])
        end
        self:save(string.format("Maintained %d inputs for %s", #inps, tostring(self.selectedFamilyId)))
    end)
    local shownFrom = (#visRules > 0) and (self.maintModalScroll + 1) or 0
    local shownTo = math.min(#visRules, self.maintModalScroll + maxRows)
    self:drawText(mx + 42, footY, string.format("Showing %d-%d of %d (%d total) | [Up/Dn]Scroll [M/Esc]Close", shownFrom, shownTo, #visRules, #rules),
        COLORS.muted, COLORS.headerBg)
end

function UI:renderLogModal()
    if not self.logModalActive then return end
    self.hitboxes = {}

    local mx, my, mw, mh = 8, 4, 144, 43
    self:drawFrame(mx, my, mw, mh, COLORS.accent, COLORS.headerBg, "double")
    self:fillRect(mx + 1, my + 1, mw - 2, mh - 2, " ", COLORS.headerBg)

    self:drawText(mx + 2, my + 1, "LOG:", COLORS.cyan, COLORS.headerBg)
    local lx = mx + 7
    lx = self:drawButton(lx, my + 1, "[1: Activity Log]",
        (self.logModalTab ~= 2) and COLORS.fg or COLORS.muted,
        (self.logModalTab ~= 2) and COLORS.btnActiveBg or COLORS.btnBg,
        function()
            self.logModalTab = 1
            self.logModalScroll = 0
        end) + 1
    lx = self:drawButton(lx, my + 1, "[2: Raw I/O Snapshot]",
        (self.logModalTab == 2) and COLORS.fg or COLORS.muted,
        (self.logModalTab == 2) and COLORS.btnActiveBg or COLORS.btnBg,
        function()
            self.logModalTab = 2
            self.logModalScroll = 0
        end) + 3

    self:drawText(lx, my + 1, "Verbosity:", COLORS.muted, COLORS.headerBg)
    lx = lx + 11
    for i = 1, #LOG_LEVELS do
        local ll = LOG_LEVELS[i]
        local active = ((self.cfg.logLevel or "normal") == ll.id)
        lx = self:drawButton(lx, my + 1, "[" .. ll.label .. "]",
            active and COLORS.fg or COLORS.muted,
            active and COLORS.btnActiveBg or COLORS.btnBg,
            function()
                setLogLevel(self, ll.id)
            end) + 1
    end

    self:drawButton(mx + mw - 22, my + 1, "[Clear]", COLORS.yellow, COLORS.btnBg, function()
        if self.state then
            self.state.events = {}
            self.state._prevChSig = {}
            self.state._prevCatFb = {}
        end
        self.logModalScroll = 0
        self:setStatus("Cleared controller activity log.")
    end)
    self:drawButton(mx + mw - 13, my + 1, "[ X CLOSE ]", COLORS.red, COLORS.darkRed, function()
        self.logModalActive = false
    end)

    local totalRows, maxRows, maxScroll
    if self.logModalTab == 2 then
        totalRows, maxRows, maxScroll = self:renderLogRawSnapshotPane(mx, my, mw, mh)
    else
        totalRows, maxRows, maxScroll = self:renderLogActivityPane(mx, my, mw, mh)
    end

    local footY = my + mh - 2
    self:drawButton(mx + 2, footY, "[▲ PgUp]", COLORS.fg, COLORS.btnBg, function()
        self.logModalScroll = math.max(0, (self.logModalScroll or 0) - 8)
    end)
    self:drawButton(mx + 12, footY, "[▼ PgDn]", COLORS.fg, COLORS.btnBg, function()
        self.logModalScroll = math.min(maxScroll, (self.logModalScroll or 0) + 8)
    end)
    local shownFrom = (totalRows > 0) and (self.logModalScroll + 1) or 0
    local shownTo = math.min(totalRows, self.logModalScroll + maxRows)
    self:drawText(mx + 23, footY, string.format("Showing %d-%d of %d rows | [1/2]View [V]Verbosity [Up/Dn]Scroll [L/Esc]Close",
        shownFrom, shownTo, totalRows), COLORS.muted, COLORS.headerBg)
end

function UI:renderFooter()
    self:fillRect(1, self.h, self.w, 1, " ", COLORS.headerBg)
    local author = tostring(self.cfg.authorName or "StankCIty")
    local sigPrefix = "│ "
    local sigGem = "◈ "
    local sigBy = "by "
    local sigX = Common.fitRightX(self.w, sigPrefix .. sigGem .. sigBy .. author, 2)
    self:drawText(sigX, self.h, sigPrefix, COLORS.border, COLORS.headerBg)
    self:drawText(sigX + 2, self.h, sigGem, COLORS.cyan, COLORS.headerBg)
    self:drawText(sigX + 4, self.h, sigBy, COLORS.muted, COLORS.headerBg)
    self:drawText(sigX + 7, self.h, author, COLORS.accent, COLORS.headerBg)

    local keysHint = "[1-4]Tab [[/]]DTPF [P]Pin [M]Maint [L]Log [A]Anim [R]Scan [Q]Quit"
    local keysX = math.max(2, sigX - unicode.wlen(keysHint) - 1)
    self:drawText(keysX, self.h, keysHint, COLORS.muted, COLORS.headerBg)

    local stepDiff = ((self.state and self.state.stepCount) or 0) - (self.statusStep or 0)
    local ev1 = self.state and self.state.events and self.state.events[1]
    local leftTxt, leftCol = self.statusMsg, COLORS.fg
    if stepDiff >= 2 and ev1 and ev1.text then
        leftTxt = "Live: " .. tostring(ev1.text)
        leftCol = COLORS.cyan
    end
    self:drawText(2, self.h, padOrTrunc(leftTxt, math.max(12, keysX - 4)), leftCol, COLORS.headerBg)
end

function UI:flushFramebuffer()
    if not self.gpu then return end
    if Common.checkViewportDrift(self, function(f) return self:syncDisplay(f) end, function() self:render() end) then
        return
    end
    local lastBg, lastFg = nil, nil
    local w = self.w

    local function cellChanged(cCh, cCol, nCh, nCol)
        if cCol == nil or cCh ~= nCh or (cCol % COL_MUL) ~= (nCol % COL_MUL) then return true end
        if nCh == " " then return false end
        return cCol ~= nCol
    end

    for y = 1, self.h do
        local cCh = self.curCh[y]
        local cCol = self.curCol[y]
        local nCh = self.nxtCh[y]
        local nCol = self.nxtCol[y]

        local x = 1
        while x <= w do
            if cellChanged(cCh[x], cCol[x], nCh[x], nCol[x]) then
                local nc = nCol[x]
                local runBg = nc % COL_MUL
                local runFg = math.floor(nc / COL_MUL)
                if nCh[x] == " " then
                    local probe = x + 1
                    while probe <= w and (nCol[probe] % COL_MUL) == runBg and nCh[probe] == " " do
                        probe = probe + 1
                    end
                    if probe <= w and (nCol[probe] % COL_MUL) == runBg then
                        runFg = math.floor(nCol[probe] / COL_MUL)
                    end
                end
                local runCol = runFg * COL_MUL + runBg

                local xEnd = x
                while xEnd < w do
                    local nx = xEnd + 1
                    local nxtC = nCol[nx]
                    local nextSameStyle = ((nxtC % COL_MUL) == runBg) and (nCh[nx] == " " or nxtC == runCol)
                    if not nextSameStyle then break end

                    if cellChanged(cCh[nx], cCol[nx], nCh[nx], nxtC) then
                        xEnd = nx
                    elseif (nx + 1 <= w) then
                        local nx2C = nCol[nx + 1]
                        if ((nx2C % COL_MUL) == runBg)
                            and (nCh[nx + 1] == " " or nx2C == runCol)
                            and cellChanged(cCh[nx + 1], cCol[nx + 1], nCh[nx + 1], nx2C) then
                            -- Coalesce 1-cell unchanged gaps of identical style into a single gpu.set call
                            xEnd = nx + 1
                        else
                            break
                        end
                    else
                        break
                    end
                end

                for k = x, xEnd do
                    cCh[k] = nCh[k]
                    cCol[k] = (nCh[k] == " ") and runCol or nCol[k]
                end

                if runBg ~= lastBg then
                    self.gpu.setBackground(runBg)
                    lastBg = runBg
                end
                if runFg ~= lastFg then
                    self.gpu.setForeground(runFg)
                    lastFg = runFg
                end
                self.gpu.set(x, y, table.concat(nCh, "", x, xEnd))
                x = xEnd + 1
            else
                x = x + 1
            end
        end
    end
end

function UI:render()
    self.hitboxes = {}
    self:clearNextBuffer(COLORS.bg, COLORS.fg)

    self:renderHeader()
    if self.tab == TAB_OVERVIEW then
        self:renderOverviewTab()
    elseif self.tab == TAB_FLEET then
        self:renderControlCenter()
    elseif self.tab == TAB_RECIPES then
        self:renderRecipesTab()
    elseif self.tab == TAB_SETUP then
        self:renderWiringTab()
    end
    self:renderFooter()
    self:renderPassiveModal()
    self:renderMaintModal()
    self:renderLogModal()
    self:renderPromptModal()
    self:flushFramebuffer()
end

function UI:handleTouch(x, y, button)
    local step = (button == 1) and -1 or 1
    for i = #self.hitboxes, 1, -1 do
        local hb = self.hitboxes[i]
        if x >= hb.x1 and x <= hb.x2 and y >= hb.y1 and y <= hb.y2 then
            hb.fn(step, button, x, y)
            return
        end
    end
end

function UI:handleScroll(dir, x, y)
    if self.promptActive then return end
    if self.maintModalActive then
        self.maintModalScroll = math.max(0, (self.maintModalScroll or 0) - (dir * 3))
        return
    end
    if self.promptActive then
        if code == 28 or char == 13 then -- Enter
            local cb = self.promptCallback
            local val = self.promptBuffer
            self.promptActive = false
            self.promptIsNumeric = false
            self.promptCallback = nil
            if cb then cb(val) end
        elseif code == 1 then -- Escape
            self.promptActive = false
            self.promptIsNumeric = false
            self.promptCallback = nil
        elseif code == 14 or char == 8 then -- Backspace
            if #self.promptBuffer > 0 then
                self.promptBuffer = self.promptBuffer:sub(1, -2)
            end
        elseif char >= 32 and char <= 126 then
            self.promptBuffer = self.promptBuffer .. string.char(char)
        end
        return
    end
    if self.maintModalActive then
        if code == 1 or char == string.byte("m") or char == string.byte("M") then
            self.maintModalActive = false
        elseif code == 200 then
            self.maintModalScroll = math.max(0, (self.maintModalScroll or 0) - 1)
        elseif code == 208 then
            self.maintModalScroll = (self.maintModalScroll or 0) + 1
        elseif code == 201 then
            self.maintModalScroll = math.max(0, (self.maintModalScroll or 0) - 8)
        elseif code == 209 then
            self.maintModalScroll = (self.maintModalScroll or 0) + 8
        end
        return
    end
    if self.logModalActive then
        self.logModalScroll = math.max(0, (self.logModalScroll or 0) - (dir * 3))
        return
    end
    if self.passiveModalActive then
        self.passiveModalScroll = math.max(0, (self.passiveModalScroll or 0) - (dir * 3))
        return
    end
    if self.tab == TAB_OVERVIEW then
        self.overviewRecScroll = math.max(0, (self.overviewRecScroll or 0) - dir)
    elseif self.tab == TAB_FLEET then
        if x and x < 80 then
            self.dtpfRowScroll = math.max(0, (self.dtpfRowScroll or 0) - dir)
        else
            self.activeScroll = math.max(0, self.activeScroll - (dir * 3))
        end
    elseif self.tab == TAB_RECIPES then
        self.recipeScroll = math.max(0, self.recipeScroll - (dir * 3))
    elseif self.tab == TAB_SETUP then
        if self._setupMfuMode then
            if y and y >= 19 then
                self.wiringDtpfScroll = math.max(0, (self.wiringDtpfScroll or 0) - dir)
            end
        elseif y and y >= 27 then
            self.wiringDtpfScroll = math.max(0, (self.wiringDtpfScroll or 0) - dir)
        else
            self.wiringChScroll = math.max(0, (self.wiringChScroll or 0) - dir)
        end
    end
end

function UI:handleKeyDown(char, code)
    if self.promptActive then
        if code == 28 or char == 13 then -- Enter
            local cb = self.promptCallback
            local val = self.promptBuffer
            self.promptActive = false
            self.promptIsNumeric = false
            self.promptCallback = nil
            if cb then cb(val) end
        elseif code == 1 then -- Escape
            self.promptActive = false
            self.promptIsNumeric = false
            self.promptCallback = nil
        elseif code == 14 or char == 8 then -- Backspace
            if #self.promptBuffer > 0 then
                self.promptBuffer = self.promptBuffer:sub(1, -2)
            end
        elseif char >= 32 and char <= 126 then
            self.promptBuffer = self.promptBuffer .. string.char(char)
        end
        return
    end
    if self.maintModalActive then
        if char == 47 then -- '/' search filter
            self:openPrompt("Search Level Maintainer Rules (name, mode, status):", self.maintModalSearch or "",
                "Type query & press [Enter] / [APPLY], or blank to clear.", function(txt)
                    self.maintModalSearch = tostring(txt or "")
                    self.maintModalScroll = 0
                    self:setStatus((self.maintModalSearch ~= "") and ("Maintainer filter: " .. self.maintModalSearch) or "Cleared Maintainer search.")
                end)
        elseif code == 1 or char == string.byte("m") or char == string.byte("M") then
            self.maintModalActive = false
        elseif code == 200 then
            self.maintModalScroll = math.max(0, (self.maintModalScroll or 0) - 1)
        elseif code == 208 then
            self.maintModalScroll = (self.maintModalScroll or 0) + 1
        elseif code == 201 then
            self.maintModalScroll = math.max(0, (self.maintModalScroll or 0) - 8)
        elseif code == 209 then
            self.maintModalScroll = (self.maintModalScroll or 0) + 8
        end
        return
    end
    if self.logModalActive then
        if code == 1 or char == string.byte("l") or char == string.byte("L") then
            self.logModalActive = false
        elseif char == string.byte("1") then
            self.logModalTab = 1
            self.logModalScroll = 0
        elseif char == string.byte("2") then
            self.logModalTab = 2
            self.logModalScroll = 0
        elseif char == string.byte("v") or char == string.byte("V") then
            cycleLogLevel(self, 1)
        elseif code == 200 then
            self.logModalScroll = math.max(0, (self.logModalScroll or 0) - 1)
        elseif code == 208 then
            self.logModalScroll = (self.logModalScroll or 0) + 1
        elseif code == 201 then
            self.logModalScroll = math.max(0, (self.logModalScroll or 0) - 8)
        elseif code == 209 then
            self.logModalScroll = (self.logModalScroll or 0) + 8
        end
        return
    end
    if self.passiveModalActive then
        local nD = #self.cfg.dtpfs
        if code == 1 or char == string.byte("p") or char == string.byte("P") then
            self.passiveModalActive = false
        elseif char == string.byte("k") or char == string.byte("K") then
            self:toggleCoilDisplay()
        elseif code == 200 then
            self.passiveModalScroll = math.max(0, (self.passiveModalScroll or 0) - 1)
        elseif code == 208 then
            self.passiveModalScroll = (self.passiveModalScroll or 0) + 1
        elseif nD > 0 and (code == 203 or char == string.byte("[")) then
            local nxt = (( (self.passiveModalDtpfIdx or 1) - 2 ) % nD) + 1
            self.passiveModalDtpfIdx = nxt
            self.selectedDtpf = nxt
        elseif nD > 0 and (code == 205 or char == string.byte("]")) then
            local nxt = ((self.passiveModalDtpfIdx or 1) % nD) + 1
            self.passiveModalDtpfIdx = nxt
            self.selectedDtpf = nxt
        end
        return
    end
    -- Top-level hotkeys below handle remaining non-modal navigation.

    if code == 15 or char == 9 then -- Tab
        self.tab = (self.tab % 4) + 1
        return
    end
    if char == string.byte("[") or ((self.tab == TAB_OVERVIEW or self.tab == TAB_FLEET or self.tab == TAB_RECIPES) and code == 203) then
        self:selectDtpfByDelta(-1)
        return
    elseif char == string.byte("]") or ((self.tab == TAB_OVERVIEW or self.tab == TAB_FLEET or self.tab == TAB_RECIPES) and code == 205) then
        self:selectDtpfByDelta(1)
        return
    elseif (char == string.byte("b") or char == string.byte("B")) and self.tab ~= TAB_OVERVIEW then
        self.tab = (self.tab == TAB_FLEET) and TAB_OVERVIEW or TAB_FLEET
        return
    elseif (self.tab == TAB_OVERVIEW or self.tab == TAB_FLEET) and (char == string.byte("p") or char == string.byte("P")) then
        if #self.cfg.dtpfs > 0 then
            self:openPassiveModal(self.selectedDtpf)
        end
        return
    elseif char == string.byte("m") or char == string.byte("M") then
        self.maintModalActive = true
        self.maintModalScroll = 0
        return
    elseif char == string.byte("l") or char == string.byte("L") then
        self.logModalActive = true
        self.logModalScroll = 0
        return
    elseif char == string.byte("a") or char == string.byte("A") then
        self:toggleAnimations()
        return
    elseif char == string.byte("k") or char == string.byte("K") then
        self:toggleCoilDisplay()
        return
    elseif self.tab == TAB_FLEET and (char == string.byte("c") or char == string.byte("C")) then
        if #self.cfg.dtpfs >= 5 then
            self.fleetCompact = not self.fleetCompact
            self.dtpfRowScroll = 0
        end
        return
    end

    if self.tab == TAB_RECIPES and (code == 200 or code == 208) then
        local list = getFilteredRecipeList(self)
        if #list > 0 then
            local curIdx = 1
            for i = 1, #list do
                if list[i].fam.id == self.selectedFamilyId then curIdx = i break end
            end
            local nxtIdx = math.max(1, math.min(#list, curIdx + (code == 200 and -1 or 1)))
            self.selectedFamilyId = list[nxtIdx].fam.id
            local maxRows = self.h - 8
            if nxtIdx <= self.recipeScroll then
                self.recipeScroll = math.max(0, nxtIdx - 1)
            elseif nxtIdx > self.recipeScroll + maxRows then
                self.recipeScroll = math.max(0, nxtIdx - maxRows)
            end
        end
        return
    end

    if char == string.byte("1") then self.tab = TAB_OVERVIEW
    elseif char == string.byte("2") then self.tab = TAB_FLEET
    elseif char == string.byte("3") then self.tab = TAB_RECIPES
    elseif char == string.byte("4") then self.tab = TAB_SETUP
    elseif char == string.byte("r") or char == string.byte("R") then
        self:refreshDiscovery()
        self:save("Rescanned hardware components.")
    elseif char == string.byte("q") or char == string.byte("Q") then
        self:save("Configuration saved.")
        self.running = false
    end
end

return UI
