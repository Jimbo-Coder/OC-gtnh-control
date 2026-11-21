-- /home/bhc/lib/ui.lua
-- Visual 160x50 Touch Control Center for Pseudostable Black Hole Containment Field (BHC).
-- Packed 64-bit buffer, strictly width-1 glyphs.

local component = require("component")
local Common = require("gtnh_common")
local unicode = require("unicode")
local Hardware = require("lib.hardware")
local Scheduler = require("lib.scheduler")

local UI = {}
local TAB_CONTROL = 1
local TAB_TUNING  = 2
local TAB_SETUP   = 3

local COLORS = {
    bg          = 0x0C1117,
    headerBg    = 0x16202C,
    panelBg     = 0x121922,
    rowAltBg    = 0x10161E,
    selectedBg  = 0x1D2D42,
    border      = 0x334155,
    fg          = 0xE6EDF3,
    muted       = 0x7D8590,
    accent      = 0x58A6FF,
    green       = 0x3FB950,
    darkGreen   = 0x1B4D2B,
    yellow      = 0xE3B341,
    amberBg     = 0x4D340B,
    red         = 0xF85149,
    darkRed     = 0x5E1F1D,
    purple      = 0xBC8CFF,
    cyan        = 0x39C5CF,
    btnBg       = 0x283545,
    btnActiveBg = 0x1F6FEB,
}

local FRAMES = {
    round  = { tl = "╭", tr = "╮", bl = "╰", br = "╯", h = "─", v = "│" },
    double = { tl = "╔", tr = "╗", bl = "╚", br = "╝", h = "═", v = "║" },
}

local _wCache = {}
local function cpWidth(cp)
    if cp >= 32 and cp <= 126 then return 1 end
    local w = _wCache[cp]
    if w == nil then
        w = unicode.charWidth(utf8.char(cp))
        _wCache[cp] = w
    end
    return w
end

local function packMask(fg, bg)
    return ((math.floor(fg or COLORS.fg) & 0xFFFFFF) << 40)
        | ((math.floor(bg or COLORS.bg) & 0xFFFFFF) << 16)
end

local function padOrTrunc(str, width)
    return Common.padOrTrunc(str, width, "~")
end

local function fmtNum(n, suf)
    n = tonumber(n) or 0
    local a, s = math.abs(n), suf or ""
    if a >= 1e9 then return string.format("%.2fG%s", n / 1e9, s)
    elseif a >= 1e6 then return string.format("%.1fM%s", n / 1e6, s)
    elseif a >= 1e3 then return string.format("%.1fK%s", n / 1e3, s)
    else return string.format("%d%s", math.floor(n + 0.5), s) end
end

function UI.new(cfg, state, onSave, compLib, extras)
    local cl = compLib or component
    local gpu = (cl.isAvailable and cl.isAvailable("gpu") and cl.gpu) or nil
    if not gpu and cl.list then
        local a = cl.list("gpu", true)()
        if a then gpu = cl.proxy(a) end
    end
    local self = setmetatable({
        cfg = cfg,
        state = state,
        onSave = onSave,
        comp = cl,
        extras = extras or {},
        gpu = gpu,
        w = 160,
        h = 50,
        tab = TAB_CONTROL,
        running = true,
        statusMsg = "Ready (BHC stability & SpaceTime cost optimizer).",
        curBuf = {},
        nxtBuf = {},
        hitboxes = {},
    }, { __index = UI })
    local empty = packMask(COLORS.fg, COLORS.bg) | 32
    for i = 1, self.w * self.h do self.curBuf[i] = -1; self.nxtBuf[i] = empty end
    self:syncDisplay(true)
    return self
end

function UI:syncDisplay(forceRedraw)
    return Common.syncDisplay(self, {
        forceRedraw = forceRedraw,
        onResize = function(aw, ah)
            local empty = packMask(COLORS.fg, COLORS.bg) | 32
            local cur, nxt = {}, {}
            for i = 1, aw * ah do cur[i] = -1; nxt[i] = empty end
            self.curBuf = cur
            self.nxtBuf = nxt
        end,
    })
end

function UI:save(msg)
    self.statusMsg = msg or "Saved."
    if self.onSave then self.onSave(self.cfg) end
end

function UI:clearNextBuffer(bg, fg)
    local v = packMask(fg, bg) | 32
    for i = 1, self.w * self.h do self.nxtBuf[i] = v end
end

function UI:drawText(x, y, str, fg, bg)
    if y < 1 or y > self.h then return x end
    local col, mask, nb, w = x, packMask(fg, bg), self.nxtBuf, self.w
    local rowOff = (y - 1) * w
    for _, cp in utf8.codes(tostring(str or "")) do
        local cw = cpWidth(cp)
        if cw < 1 then cw = 1 end
        if col >= 1 and col <= w then nb[rowOff + col] = mask | (cp & 0xFFFF) end
        col = col + cw
        if col > w then break end
    end
    return col
end

function UI:fillRect(x, y, rw, rh, ch, fg, bg)
    local cp = utf8.codepoint(ch or " ", 1) or 32
    local packed = packMask(fg, bg) | (cp & 0xFFFF)
    local nb, w = self.nxtBuf, self.w
    for r = math.max(1, y), math.min(self.h, y + rh - 1) do
        local off = (r - 1) * w
        for c = math.max(1, x), math.min(w, x + rw - 1) do nb[off + c] = packed end
    end
end

function UI:drawFrame(x, y, fw, fh, fg, bg, style)
    if fw < 2 or fh < 2 then return end
    local st = FRAMES[style or "round"] or FRAMES.round
    if bg then self:fillRect(x, y, fw, fh, " ", fg, bg) end
    local bar = string.rep(st.h, fw - 2)
    self:drawText(x, y, st.tl .. bar .. st.tr, fg, bg)
    self:drawText(x, y + fh - 1, st.bl .. bar .. st.br, fg, bg)
    for ry = y + 1, y + fh - 2 do
        self:drawText(x, ry, st.v, fg, bg)
        self:drawText(x + fw - 1, ry, st.v, fg, bg)
    end
end

function UI:drawButton(x, y, label, fg, bg, fn)
    local w = unicode.wlen(label)
    self:drawText(x, y, label, fg or COLORS.fg, bg or COLORS.btnBg)
    if fn then self.hitboxes[#self.hitboxes + 1] = { x1 = x, y1 = y, x2 = x + w - 1, y2 = y, fn = fn } end
    return x + w
end

function UI:flush()
    local gpu = self.gpu
    if not gpu then return end
    if Common.checkViewportDrift(self, function(f) return self:syncDisplay(f) end, function() self:render() end) then
        return
    end
    local w, h, cur, nxt = self.w, self.h, self.curBuf, self.nxtBuf
    local lastFg, lastBg = -1, -1
    for y = 1, h do
        local rowOff, x = (y - 1) * w, 1
        while x <= w do
            local idx = rowOff + x
            local nv = nxt[idx]
            if nv ~= cur[idx] then
                local fg, bg = (nv >> 40) & 0xFFFFFF, (nv >> 16) & 0xFFFFFF
                local startX, cps = x, { nv & 0xFFFF }
                cur[idx] = nv
                x = x + 1
                while x <= w do
                    local ni = rowOff + x
                    local v2 = nxt[ni]
                    if v2 ~= cur[ni] and ((v2 >> 40) & 0xFFFFFF) == fg and ((v2 >> 16) & 0xFFFFFF) == bg then
                        cps[#cps + 1] = v2 & 0xFFFF
                        cur[ni] = v2
                        x = x + 1
                    else break end
                end
                if bg ~= lastBg then pcall(gpu.setBackground, bg); lastBg = bg end
                if fg ~= lastFg then pcall(gpu.setForeground, fg); lastFg = fg end
                local chars = {}
                for k = 1, #cps do chars[k] = utf8.char(cps[k]) end
                pcall(gpu.set, startX, y, table.concat(chars))
            else x = x + 1 end
        end
    end
end

function UI:renderHeader()
    self:fillRect(1, 1, self.w, 2, " ", COLORS.fg, COLORS.headerBg)
    self:drawText(2, 1, "◈ GTNH BLACK HOLE COMPRESSOR CONTROL", COLORS.accent, COLORS.headerBg)
    local armed = (self.cfg.armed == true)
    local bx = 42
    bx = self:drawButton(bx, 1, armed and "[ARMED]" or "[PAUSED]",
        armed and COLORS.green or COLORS.yellow, armed and COLORS.darkGreen or COLORS.amberBg, function()
            self.cfg.armed = not armed
            self:save(self.cfg.armed and "BHC ARMED." or "BHC PAUSED.")
        end) + 2
    bx = self:drawButton(bx, 1, "[↻ Poll]", COLORS.cyan, COLORS.btnBg, function()
        Scheduler.step(self.cfg, self.state, nil, self.comp)
        self.statusMsg = "Polled BHC state."
    end) + 2
    bx = self:drawButton(bx, 1, "[Open BH]", COLORS.purple, COLORS.btnBg, function()
        self.state._manualOpen = true
        Scheduler.step(self.cfg, self.state, nil, self.comp)
        self.statusMsg = "Requested Black Hole open."
    end) + 2
    self:drawButton(bx, 1, "[Collapse BH]", COLORS.red, COLORS.darkRed, function()
        self.state._manualCollapse = true
        Scheduler.step(self.cfg, self.state, nil, self.comp)
        self.statusMsg = "Requested safe Black Hole collapse."
    end)

    local tx = 2
    for _, tb in ipairs({
        { id = TAB_CONTROL, label = "[1] CONTROL & STABILITY" },
        { id = TAB_TUNING,  label = "[2] PRESETS & TUNING" },
        { id = TAB_SETUP,   label = "[3] HARDWARE & SETUP" },
    }) do
        local act = (self.tab == tb.id)
        tx = self:drawButton(tx, 2, tb.label, act and COLORS.fg or COLORS.muted,
            act and COLORS.btnActiveBg or COLORS.headerBg, function() self.tab = tb.id end) + 2
    end
    self:drawText(1, 3, string.rep("─", self.w), COLORS.border, COLORS.bg)
end

function UI:renderControlTab()
    local st = self.state
    local m = st.machine or {}
    local stk = st.stock or {}
    local stab = math.max(0, math.min(100, tonumber(st.estStability) or 100))

    self:drawFrame(2, 5, 76, 21, COLORS.border, COLORS.panelBg, "round")
    self:drawText(4, 5, " ◈ BLACK HOLE STABILITY & PARALLELS ", COLORS.accent, COLORS.panelBg)
    local phCol = (st.phase == "HOLDING" or st.phase == "SUPERSTABLE") and COLORS.green
        or (st.phase == "COLLAPSING" and COLORS.yellow or (st.phase == "FREE_DECAY" and COLORS.cyan or COLORS.muted))
    self:drawText(4, 7, string.format("Phase      : %-14s  Seed Mode : %s%s",
        tostring(st.phase), tostring(self.cfg.seedMode), st.savingRecipe and " [SAVING RECIPE]" or ""), phCol, COLORS.panelBg)
    self:drawText(4, 9, string.format("Stability  : %5.1f%%   (Target %d%% | Safety Floor %d%%)", stab, self.cfg.targetStability, self.cfg.collapseFloor), COLORS.fg, COLORS.panelBg)

    local barW = 60
    local fillW = math.floor((stab / 100) * barW + 0.5)
    local barCol = (stab <= self.cfg.collapseFloor + 2) and COLORS.red or ((stab < 20) and COLORS.green or ((stab < 50) and COLORS.cyan or COLORS.yellow))
    self:drawText(4, 11, "[" .. string.rep("=", fillW) .. string.rep(".", barW - fillW) .. "]", barCol, COLORS.panelBg)
    self:drawText(4, 12, "0% VOID      |<20% 4x PARALLEL|          <50% 2x|                 100%", COLORS.muted, COLORS.panelBg)

    local parTxt = (st.effectiveParallels == -1) and "UNCAPPED (Non-BH)" or tostring(st.effectiveParallels or 0)
    self:drawText(4, 14, string.format("Tier/Par   : %s (%s base x mul) -> %s parallels",
        tostring(m.tierName or "UV"), tostring(m.baseParallels or 64), parTxt), COLORS.fg, COLORS.panelBg)
    local nextDbl = 30 - (tonumber(st.decayCounter) or 0)
    self:drawText(4, 15, string.format("SpaceTime  : Valve=%s | Cost=%d L/s | Next 2x in %ds | Cycle=%s L",
        st.haltingDecay and "OPEN" or "SHUT", tonumber(st.costMod) or 0, nextDbl, fmtNum(st.totalStCycle or 0)), COLORS.cyan, COLORS.panelBg)
    self:drawText(4, 16, string.format("Hold Timer : %ds / %ds max | Cycles Done: %d | Utility Sig: %s",
        tonumber(st.heldSec) or 0, self.cfg.maxHoldSec, tonumber(st.cyclesCompleted) or 0, tostring(st.utilSig or "nil")), COLORS.fg, COLORS.panelBg)

    local keepOn = (self.cfg.keepOpen == true)
    self:drawButton(4, 19, keepOn and "[Keep Warm: ON ]" or "[Keep Warm: OFF]",
        keepOn and COLORS.green or COLORS.muted, keepOn and COLORS.darkGreen or COLORS.btnBg, function()
            self.cfg.keepOpen = not keepOn
            self:save("Keep Warm -> " .. tostring(self.cfg.keepOpen))
        end)
    local bhOnly = (self.cfg.isBlackHoleRecipe ~= false)
    self:drawButton(23, 19, bhOnly and "[Mode: Singularity (21)]" or "[Mode: Compressor (20) ]",
        COLORS.cyan, COLORS.btnBg, function()
            self.cfg.isBlackHoleRecipe = not bhOnly
            self:save("Recipe Mode -> " .. (self.cfg.isBlackHoleRecipe and "Singularity (21)" or "Compressor (20)"))
        end)
    local saveOn = (self.cfg.saveRecipeMode ~= false)
    self:drawButton(49, 19, saveOn and "[Save Recipe: ON ]" or "[Save Recipe: OFF]",
        saveOn and COLORS.green or COLORS.muted, saveOn and COLORS.darkGreen or COLORS.btnBg, function()
            self.cfg.saveRecipeMode = not saveOn
            self:save("Save Recipe Mode -> " .. (self.cfg.saveRecipeMode and "ON" or "OFF"))
        end)

    self:drawFrame(2, 27, 76, 21, COLORS.border, COLORS.panelBg, "round")
    self:drawText(4, 27, " ◈ CATALYST & SPACETIME RESERVES ", COLORS.accent, COLORS.panelBg)
    self:drawText(4, 29, string.format("Black Hole Seed       : %d", tonumber(stk.pseudostable) or 0), COLORS.fg, COLORS.panelBg)
    self:drawText(4, 30, string.format("Supermassive BH Seed  : %d", tonumber(stk.supermassive) or 0), COLORS.fg, COLORS.panelBg)
    self:drawText(4, 31, string.format("Superstable BH Seed   : %d", tonumber(stk.superstable) or 0), COLORS.purple, COLORS.panelBg)
    self:drawText(4, 32, string.format("Black Hole Collapser  : %d", tonumber(stk.collapser) or 0),
        (tonumber(stk.collapser) or 0) > 0 and COLORS.green or COLORS.red, COLORS.panelBg)
    self:drawText(4, 34, string.format("Molten SpaceTime Tank : %s L", fmtNum(stk.spacetimeTankL or 0)), COLORS.cyan, COLORS.panelBg)
    self:drawText(4, 35, string.format("Molten SpaceTime ME   : %s L", fmtNum(stk.spacetimeMeL or 0)), COLORS.cyan, COLORS.panelBg)
    if st.lastError then
        self:drawText(4, 38, padOrTrunc("Alert: " .. tostring(st.lastError), 70), COLORS.red, COLORS.panelBg)
    end

    self:drawFrame(80, 5, 79, 43, COLORS.border, COLORS.panelBg, "round")
    self:drawText(82, 5, " ◈ BHC LIFECYCLE ACTIVITY LOG ", COLORS.accent, COLORS.panelBg)
    for i = 1, math.min(19, #(st.events or {})) do
        local e = st.events[i]
        local col = (e.stage == "ERR" and COLORS.red) or (e.stage == "WRN" and COLORS.yellow)
            or (e.stage == "OUT" and COLORS.green) or COLORS.fg
        self:drawText(82, 6 + i * 2, padOrTrunc(string.format("[%s] %s", e.stage or "INF", e.text or ""), 75), col, COLORS.panelBg)
    end
end

function UI:renderTuningTab()
    self:drawFrame(2, 5, 76, 43, COLORS.border, COLORS.panelBg, "round")
    self:drawText(4, 5, " ◈ STRATEGY PRESETS & SEED MODE ", COLORS.accent, COLORS.panelBg)
    self:drawText(4, 7, "Preset Profile: " .. tostring(self.cfg.preset), COLORS.fg, COLORS.panelBg)
    local bx = 4
    for idx, pKey in ipairs(Scheduler.PRESET_ORDER) do
        local p = Scheduler.PRESETS[pKey]
        local act = (self.cfg.preset == pKey)
        local rowY = (idx <= 3) and 9 or 11
        if idx == 4 then bx = 4 end
        bx = self:drawButton(bx, rowY, "[" .. p.label .. "]",
            act and COLORS.fg or COLORS.cyan, act and COLORS.btnActiveBg or COLORS.btnBg, function()
                Scheduler.applyPreset(self.cfg, pKey)
                self:save("Applied preset -> " .. p.label)
            end) + 2
    end
    self:drawText(4, 14, "Seed Type:", COLORS.muted, COLORS.panelBg)
    local sx = 16
    for _, sm in ipairs(Scheduler.SEED_MODES) do
        local act = (self.cfg.seedMode == sm)
        sx = self:drawButton(sx, 14, "[" .. sm .. "]", act and COLORS.green or COLORS.muted,
            act and COLORS.darkGreen or COLORS.btnBg, function()
                self.cfg.seedMode = sm
                self.cfg.preset = "custom"
                self:save("Seed Mode -> " .. sm)
            end) + 2
    end

    local proj = Scheduler.calcCycleProjection(self.cfg, self.state.machine and self.state.machine.voltageTier or 8)
    self:drawText(4, 18, "Cycle Projection (" .. tostring(self.state.machine and self.state.machine.tierName or "UV") .. "):", COLORS.accent, COLORS.panelBg)
    self:drawText(4, 20, string.format("  Peak Parallels   : %d", proj.peakParallels), COLORS.green, COLORS.panelBg)
    self:drawText(4, 21, string.format("  Hold Duration    : %ds (Sweet Spot <20%%: %ds = %.1f%% uptime)", proj.heldSec or 0, proj.sweetSpotSec, proj.sweetUptimePct), COLORS.fg, COLORS.panelBg)
    self:drawText(4, 22, string.format("  SpaceTime / Cycle: %s L (Peak %s L/s)", fmtNum(proj.totalStL), fmtNum(proj.peakStPerSec)), COLORS.cyan, COLORS.panelBg)

    self:drawFrame(80, 5, 79, 43, COLORS.border, COLORS.panelBg, "round")
    self:drawText(82, 5, " ◈ THRESHOLD & COST TUNING ", COLORS.accent, COLORS.panelBg)
    local rows = {
        { key = "targetStability",     lbl = "Hold Target Stability (%)", step = 2,   min = 6,  max = 90 },
        { key = "collapseFloor",       lbl = "Mandatory Collapse (%)",    step = 1,   min = 2,  max = 25 },
        { key = "maxHoldSec",          lbl = "Max Hold Time (sec)",       step = 30,  min = 0,  max = 600 },
        { key = "maxStPerSec",         lbl = "Max SpaceTime Rate (L/s)",  step = 64,  min = 0,  max = 16384 },
        { key = "idleCollapseSec",     lbl = "Idle Collapse Timeout (s)", step = 10,  min = 0,  max = 600 },
        { key = "minSpacetimeReserve", lbl = "Min SpaceTime Reserve (L)", step = 500, min = 0,  max = 1000000 },
        { key = "maxSaveRecipeCycles", lbl = "Save Recipe Max Cycles",    step = 1,   min = 1,  max = 60 },
    }
    for i, r in ipairs(rows) do
        local ry = 7 + i * 3
        self:drawText(82, ry, string.format("%-28s: %d", r.lbl, tonumber(self.cfg[r.key]) or 0), COLORS.fg, COLORS.panelBg)
        self:drawButton(124, ry, "[-]", COLORS.yellow, COLORS.btnBg, function()
            self.cfg[r.key] = math.max(r.min, (tonumber(self.cfg[r.key]) or 0) - r.step)
            self.cfg.preset = "custom"
            self:save(r.key .. " -> " .. self.cfg[r.key])
        end)
        self:drawButton(129, ry, "[+]", COLORS.green, COLORS.btnBg, function()
            self.cfg[r.key] = math.min(r.max, (tonumber(self.cfg[r.key]) or 0) + r.step)
            self.cfg.preset = "custom"
            self:save(r.key .. " -> " .. self.cfg[r.key])
        end)
    end
end

function UI:renderSetupTab()
    self:drawFrame(2, 5, 157, 43, COLORS.border, COLORS.panelBg, "round")
    self:drawText(4, 5, " ◈ HARDWARE BINDING, AUTO-WAKE & SETUP ", COLORS.accent, COLORS.panelBg)

    local awOn = (self.cfg.autoWake ~= false)
    self:drawButton(4, 7, awOn and "[AutoWake: ON ]" or "[AutoWake: OFF]",
        awOn and COLORS.green or COLORS.muted, COLORS.btnBg, function()
            self.cfg.autoWake = not awOn
            Hardware.openMeshPort(self.cfg, self.comp, self.state)
            self:save("Auto-Wake -> " .. (self.cfg.autoWake and "ON" or "OFF"))
        end)
    local extOff = (self.cfg.extLinkMode == "off")
    self:drawButton(22, 7, extOff and "[Mesh: OFF]" or "[Mesh: AUTO]", extOff and COLORS.yellow or COLORS.cyan, COLORS.btnBg, function()
        self.cfg.extLinkMode = extOff and "auto" or "off"
        self:save("Mesh -> " .. self.cfg.extLinkMode)
    end)
    local isPulse = (self.cfg.utilityMode ~= "static")
    self:drawButton(36, 7, isPulse and "[Utility: PULSE]" or "[Utility: STATIC]", COLORS.cyan, COLORS.btnBg, function()
        self.cfg.utilityMode = isPulse and "static" or "pulse"
        self:save("Utility Hatch Mode -> " .. self.cfg.utilityMode)
    end)
    local isRs = (self.cfg.spacetimeValveMode ~= "transposer")
    self:drawButton(55, 7, isRs and "[ST Valve: REDSTONE]" or "[ST Valve: TRANSPOSER]", COLORS.cyan, COLORS.btnBg, function()
        self.cfg.spacetimeValveMode = isRs and "transposer" or "redstone"
        self:save("SpaceTime Valve -> " .. self.cfg.spacetimeValveMode)
    end)
    if self.extras.isAutostartEnabled then
        local auto = self.extras.isAutostartEnabled()
        self:drawButton(80, 7, auto and "[Autostart: ON]" or "[Autostart: OFF]", auto and COLORS.green or COLORS.muted, COLORS.btnBg, function()
            local nxt = self.extras.toggleAutostart()
            self.statusMsg = "Autostart -> " .. tostring(nxt)
        end)
    end

    local disc = self.state.discovery or {}
    self:drawText(4, 10, string.format("Controller : %s (%d found)", tostring(self.cfg.controllerAddr or "-"), #(disc.controllers or {})), COLORS.fg, COLORS.panelBg)
    self:drawText(4, 12, string.format("Utility RS : %s side=%s", tostring(self.cfg.utilityRedstoneAddr or "-"), tostring(self.cfg.utilitySide)), COLORS.fg, COLORS.panelBg)
    self:drawText(4, 14, string.format("ST Valve RS: %s side=%s", tostring(self.cfg.spacetimeRedstoneAddr or "-"), tostring(self.cfg.spacetimeRedstoneSide)), COLORS.fg, COLORS.panelBg)
    self:drawText(4, 16, string.format("Input Gate : %s side=%s", tostring(self.cfg.inputGateRedstoneAddr or "-"), tostring(self.cfg.inputGateSide)), COLORS.fg, COLORS.panelBg)
    self:drawText(4, 18, string.format("Catalyst TP: %s (%s -> %s)", tostring(self.cfg.catalystTransposerAddr or "-"), tostring(self.cfg.catalystSrcSide), tostring(self.cfg.catalystDstSide)), COLORS.fg, COLORS.panelBg)
    self:drawText(4, 20, string.format("SpaceTimeTP: %s (%s -> %s)", tostring(self.cfg.stTransposerAddr or "-"), tostring(self.cfg.stSrcSide), tostring(self.cfg.stDstSide)), COLORS.fg, COLORS.panelBg)
    self:drawText(4, 22, string.format("AE Link    : %s", tostring(self.cfg.aeAddr or "-")), COLORS.fg, COLORS.panelBg)

    local function cycleSide(k)
        local cur = tostring(self.cfg[k] or "up"):lower()
        local nxt = Hardware.SIDES[1]
        for i, s in ipairs(Hardware.SIDES) do
            if s == cur then nxt = Hardware.SIDES[(i % #Hardware.SIDES) + 1]; break end
        end
        self.cfg[k] = nxt
        self:save(k .. " -> " .. nxt)
    end
    self:drawButton(80, 12, "[Util Side]", COLORS.cyan, COLORS.btnBg, function() cycleSide("utilitySide") end)
    self:drawButton(80, 14, "[ST RS Side]", COLORS.cyan, COLORS.btnBg, function() cycleSide("spacetimeRedstoneSide") end)
    self:drawButton(80, 16, "[Gate Side]", COLORS.cyan, COLORS.btnBg, function() cycleSide("inputGateSide") end)
    self:drawButton(80, 18, "[Cat Src]", COLORS.cyan, COLORS.btnBg, function() cycleSide("catalystSrcSide") end)
    self:drawButton(92, 18, "[Cat Dst]", COLORS.cyan, COLORS.btnBg, function() cycleSide("catalystDstSide") end)
    self:drawButton(80, 20, "[ST Src]", COLORS.cyan, COLORS.btnBg, function() cycleSide("stSrcSide") end)
    self:drawButton(92, 20, "[ST Dst]", COLORS.cyan, COLORS.btnBg, function() cycleSide("stDstSide") end)
end

function UI:render()
    self.hitboxes = {}
    self:clearNextBuffer(COLORS.bg, COLORS.fg)
    self:renderHeader()
    if self.tab == TAB_CONTROL then
        self:renderControlTab()
    elseif self.tab == TAB_TUNING then
        self:renderTuningTab()
    else
        self:renderSetupTab()
    end
    self:fillRect(1, self.h, self.w, 1, " ", COLORS.fg, COLORS.headerBg)
    self:drawText(2, self.h, padOrTrunc(self.statusMsg or "", self.w - 30), COLORS.fg, COLORS.headerBg)
    self:drawText(self.w - 26, self.h, "1-3:Tabs  Space:Arm  Q:Quit", COLORS.muted, COLORS.headerBg)
    self:flush()
end

function UI:handleTouch(x, y)
    for i = #self.hitboxes, 1, -1 do
        local hb = self.hitboxes[i]
        if x >= hb.x1 and x <= hb.x2 and y >= hb.y1 and y <= hb.y2 then
            hb.fn()
            return true
        end
    end
    return false
end

function UI:handleKeyDown(charCode, keyCode)
    if charCode == 49 then self.tab = TAB_CONTROL; return true
    elseif charCode == 50 then self.tab = TAB_TUNING; return true
    elseif charCode == 51 then self.tab = TAB_SETUP; return true
    elseif charCode == 32 then
        self.cfg.armed = not (self.cfg.armed == true)
        self:save("BHC -> " .. (self.cfg.armed and "ARMED" or "PAUSED"))
        return true
    elseif charCode == 81 or charCode == 113 then
        self.running = false
        return true
    end
    return false
end

return UI
