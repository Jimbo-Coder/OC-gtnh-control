-- /home/nanoforge/lib/ui.lua
-- Visual 160x50 Touch Control Center for Tier 4 Nano Forge (`gtnh-nanoforge-control`).
-- Packed 64-bit buffer, strictly width-1 glyphs.

local component = require("component")
local Common = require("gtnh_common")
local unicode = require("unicode")
local RecipesDb = require("lib.recipes_db")
local Hardware = require("lib.hardware")
local Scheduler = require("lib.scheduler")

local UI = {}
local TAB_OVERVIEW = 1
local TAB_TARGETS  = 2
local TAB_POLICY   = 3
local TAB_SETUP    = 4

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
        tab = TAB_OVERVIEW,
        running = true,
        statusMsg = "Ready (T4 Nano Forge Magmatter metering & purity guard).",
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
    self:drawText(2, 1, "◈ GTNH TIER 4 NANO FORGE CONTROL", COLORS.accent, COLORS.headerBg)
    local armed = (self.cfg.armed == true)
    local bx = 38
    bx = self:drawButton(bx, 1, armed and "[ARMED]" or "[PAUSED]",
        armed and COLORS.green or COLORS.yellow, armed and COLORS.darkGreen or COLORS.amberBg, function()
            self.cfg.armed = not armed
            self:save(self.cfg.armed and "Nano Forge ARMED." or "Nano Forge PAUSED.")
        end) + 2
    bx = self:drawButton(bx, 1, "[↻ Poll]", COLORS.cyan, COLORS.btnBg, function()
        Scheduler.step(self.cfg, self.state, nil, self.comp)
        self.statusMsg = "Polled Nano Forge state."
    end) + 2
    self:drawButton(bx, 1, "[Sweep Bus]", COLORS.yellow, COLORS.btnBg, function()
        local scan = Hardware.scanBusNanites(self.cfg, nil, nil, self.comp, self.state)
        local moved = Hardware.sweepForeignNanites(self.cfg, scan.foreign, self.comp, self.state)
        self.state.busScan = Hardware.scanBusNanites(self.cfg, nil, nil, self.comp, self.state)
        self.statusMsg = "Swept " .. tostring(moved) .. " foreign nanite(s) to return chest."
    end)

    local tx = 2
    for _, tb in ipairs({
        { id = TAB_OVERVIEW, label = "[1] OVERVIEW & DISPATCH" },
        { id = TAB_TARGETS,  label = "[2] 12-NANITE TARGETS" },
        { id = TAB_POLICY,   label = "[3] TIER & METERING MATH" },
        { id = TAB_SETUP,    label = "[4] HARDWARE & SETUP" },
    }) do
        local act = (self.tab == tb.id)
        tx = self:drawButton(tx, 2, tb.label, act and COLORS.fg or COLORS.muted,
            act and COLORS.btnActiveBg or COLORS.headerBg, function() self.tab = tb.id end) + 2
    end
    self:drawText(1, 3, string.rep("─", self.w), COLORS.border, COLORS.bg)
end

function UI:renderOverviewTab()
    local st = self.state
    local m = st.machine or {}
    local cur = st.currentBatch
    local clean = not (st.busScan and st.busScan.clean == false)

    self:drawFrame(2, 5, 76, 21, COLORS.border, COLORS.panelBg, "round")
    self:drawText(4, 5, " ◈ NANO FORGE DISPATCH & PURITY GUARD ", COLORS.accent, COLORS.panelBg)
    self:drawText(4, 7, string.format("Phase       : %-10s  Forge Tier : T%d   Mode : %s",
        tostring(st.phase or "IDLE"), tonumber(self.cfg.forgeTier) or 4, tostring(self.cfg.mode or "both")),
        st.phase == "RUNNING" and COLORS.green or COLORS.fg, COLORS.panelBg)
    self:drawText(4, 9, string.format("Bus Purity  : %s   (Seed in Bus: %d)   Completed Batches: %d",
        clean and "CLEAN (1-recipe serialized)" or "FOREIGN NANITE PRESENT",
        tonumber(st.busScan and st.busScan.outputSeedCount) or 0,
        tonumber(st.completedBatches) or 0),
        clean and COLORS.green or COLORS.red, COLORS.panelBg)

    if cur then
        self:drawText(4, 12, string.format("Active Batch: %dx %s (T%d)",
            tonumber(cur.parallels) or 1, tostring(cur.label or "-"), tonumber(cur.tier) or 1), COLORS.cyan, COLORS.panelBg)
        self:drawText(4, 13, string.format("Magmatter   : %d L metered  |  4/4 Perfect OC: %s  |  Speed: %.4fx",
            tonumber(cur.magmatterL) or 0, cur.perfectOC and "YES" or "NO", tonumber(cur.speedMult) or 1.0), COLORS.fg, COLORS.panelBg)
        self:drawText(4, 14, string.format("Progress    : %d / %d ticks (%.1fs rem)",
            tonumber(m.progress) or 0, tonumber(m.maxProgress) or 0, tonumber(m.remainingSec) or 0), COLORS.green, COLORS.panelBg)
    else
        self:drawText(4, 12, "Active Batch: IDLE (awaiting OD staging or passive target deficit)", COLORS.muted, COLORS.panelBg)
        self:drawText(4, 13, string.format("StagingWait : %s",
            st.stagingPending and string.format("%s (%d batch)", tostring(st.stagingPending.label), tonumber(st.stagingPending.batches) or 0) or "None"),
            st.stagingPending and COLORS.yellow or COLORS.muted, COLORS.panelBg)
    end
    self:drawText(4, 17, string.format("Machine     : Online=%s  Active=%s  Problems=%d  MaxIn=%s",
        tostring(m.online == true), tostring(m.active == true), tonumber(m.problems) or 0, fmtNum(m.maxInputEu or 0, "EU/t")),
        m.online and COLORS.fg or COLORS.yellow, COLORS.panelBg)
    if st.lastError then
        self:drawText(4, 21, padOrTrunc("Alert: " .. tostring(st.lastError), 70), COLORS.red, COLORS.panelBg)
    end

    self:drawFrame(2, 27, 76, 21, COLORS.border, COLORS.panelBg, "round")
    self:drawText(4, 27, " ◈ MAGMATTER METERING & STOCK OVERVIEW ", COLORS.accent, COLORS.panelBg)
    local hatchL, tankL = Hardware.getHatchMagmatter(self.cfg, self.comp, self.state)
    self:drawText(4, 29, string.format("Dedicated Input Hatch : %s L  (strict single-hatch metering)", fmtNum(hatchL)), COLORS.cyan, COLORS.panelBg)
    self:drawText(4, 30, string.format("Source Tank Magmatter : %s L  (reserve floor: %s L)", fmtNum(tankL), fmtNum(self.cfg.magmatterReserveL or 0)), COLORS.fg, COLORS.panelBg)
    self:drawText(4, 31, string.format("ME Network Magmatter  : %s L", fmtNum(st.magMeL or 0)), COLORS.purple, COLORS.panelBg)
    self:drawText(4, 33, "T4 Magmatter/Parallel : T1=36L  T2=72L  T3=144L  T4=288L  (1x=0L)", COLORS.muted, COLORS.panelBg)
    self:drawText(4, 34, "Duration Bonus        : 0.9999 ^ MaxParallel  |  T3 >=2x = 4/4 OC", COLORS.muted, COLORS.panelBg)

    self:drawFrame(80, 5, 79, 43, COLORS.border, COLORS.panelBg, "round")
    self:drawText(82, 5, " ◈ NANO FORGE ACTIVITY LOG ", COLORS.accent, COLORS.panelBg)
    for i = 1, math.min(19, #(st.events or {})) do
        local e = st.events[i]
        local col = (e.stage == "ERR" and COLORS.red) or (e.stage == "WRN" and COLORS.yellow)
            or (e.stage == "OUT" and COLORS.green) or COLORS.fg
        self:drawText(82, 6 + i * 2, padOrTrunc(string.format("[%s] %s", e.stage or "INF", e.text or ""), 75), col, COLORS.panelBg)
    end
end

function UI:renderTargetsTab()
    self:drawFrame(2, 5, 157, 43, COLORS.border, COLORS.panelBg, "round")
    self:drawText(4, 5, " ◈ GTNH 2.9.0 12-NANITE CATALOG & PASSIVE STOCKING ", COLORS.accent, COLORS.panelBg)
    self:drawText(4, 7, padOrTrunc(string.format("%-3s %-4s %-28s %-7s %-14s %-8s %-14s %-12s %s",
        "#", "Tier", "Nanite Recipe", "Mag/P", "Stock/Target", "Passive", "Target -/+", "Par -/+", "Actions"), 152), COLORS.muted, COLORS.panelBg)
    self:drawText(4, 8, string.rep("─", 152), COLORS.border, COLORS.panelBg)

    for idx, r in ipairs(RecipesDb.RECIPES) do
        local ry = 8 + idx * 3
        if ry > 46 then break end
        local bg = (idx % 2 == 0) and COLORS.rowAltBg or COLORS.panelBg
        self:fillRect(3, ry, 155, 1, " ", COLORS.fg, bg)
        local tg = (self.cfg.targets and self.cfg.targets[r.id]) or {}
        local stk = tonumber((self.state.naniteStocks or {})[r.id]) or 0
        local magP = RecipesDb.magmatterPerParallel(r.tier)
        self:drawText(4, ry, string.format("%-3d T%-3d %-28s %4dL  %6d/%-6d",
            idx, r.tier, padOrTrunc(r.label, 28), magP, stk, tonumber(tg.targetStock) or 0),
            tg.enabled and COLORS.fg or COLORS.muted, bg)

        local en = (tg.enabled == true)
        self:drawButton(62, ry, en and "[ON ]" or "[OFF]",
            en and COLORS.green or COLORS.muted, en and COLORS.darkGreen or COLORS.btnBg, function()
                tg.enabled = not en
                self:save(r.label .. " passive -> " .. tostring(tg.enabled))
            end)
        self:drawButton(71, ry, "[-]", COLORS.yellow, COLORS.btnBg, function()
            tg.targetStock = math.max(0, (tonumber(tg.targetStock) or 0) - 16)
            self:save(r.label .. " target -> " .. tg.targetStock)
        end)
        self:drawButton(76, ry, "[+]", COLORS.green, COLORS.btnBg, function()
            tg.targetStock = (tonumber(tg.targetStock) or 0) + 16
            self:save(r.label .. " target -> " .. tg.targetStock)
        end)
        self:drawText(83, ry, string.format("%3dx", tonumber(tg.targetParallels) or 1), COLORS.cyan, bg)
        self:drawButton(89, ry, "[-]", COLORS.yellow, COLORS.btnBg, function()
            tg.targetParallels = math.max(1, (tonumber(tg.targetParallels) or 1) - 1)
            self:save(r.label .. " parallels -> " .. tg.targetParallels)
        end)
        self:drawButton(94, ry, "[+]", COLORS.green, COLORS.btnBg, function()
            tg.targetParallels = math.min(1024, (tonumber(tg.targetParallels) or 1) + 2)
            self:save(r.label .. " parallels -> " .. tg.targetParallels)
        end)
        self:drawButton(102, ry, "[Run]", COLORS.purple, COLORS.btnBg, function()
            self.state.manualQueue[#self.state.manualQueue + 1] = { recipeId = r.id, parallels = tg.targetParallels or 4 }
            self.statusMsg = "Queued " .. tostring(tg.targetParallels or 4) .. "x " .. r.label
        end)
        self:drawButton(110, ry, "[Push Inputs]", COLORS.cyan, COLORS.btnBg, function()
            local rules, tag = RecipesDb.buildStockRules(r.id, 1)
            if rules then
                local ok, reqId = Hardware.pushRulesToStock(self.cfg, self.state, { tag = tag, group = "NanoForge", rules = rules }, self.comp)
                self.statusMsg = ok and ("Pushed " .. #rules .. " input rules -> Stock Maintainer (" .. tostring(reqId) .. ")")
                    or ("Push failed: " .. tostring(reqId))
            end
        end)
    end
end

function UI:renderPolicyTab()
    self:drawFrame(2, 5, 76, 43, COLORS.border, COLORS.panelBg, "round")
    self:drawText(4, 5, " ◈ DISPATCH POLICY & METERING RULES ", COLORS.accent, COLORS.panelBg)

    self:drawButton(4, 8, string.format("[Forge Tier: T%d]", tonumber(self.cfg.forgeTier) or 4), COLORS.cyan, COLORS.btnBg, function()
        self.cfg.forgeTier = (tonumber(self.cfg.forgeTier) or 4) % 4 + 1
        self:save("Forge Tier -> T" .. self.cfg.forgeTier)
    end)
    self:drawButton(23, 8, "[Mode: " .. tostring(self.cfg.mode or "both") .. "]", COLORS.cyan, COLORS.btnBg, function()
        local nxt = (self.cfg.mode == "both") and "od_only" or ((self.cfg.mode == "od_only") and "passive_only" or "both")
        self.cfg.mode = nxt
        self:save("Dispatch Mode -> " .. nxt)
    end)
    local t3On = (self.cfg.t3MinPerfectOc ~= false)
    self:drawButton(4, 11, t3On and "[T3 >=2x 4/4 OC: ON ]" or "[T3 >=2x 4/4 OC: OFF]", t3On and COLORS.green or COLORS.muted, COLORS.btnBg, function()
        self.cfg.t3MinPerfectOc = not t3On
        self:save("T3 Min 2x Perfect OC -> " .. tostring(self.cfg.t3MinPerfectOc))
    end)
    local bootOn = (self.cfg.allowBootstrap1x ~= false)
    self:drawButton(29, 11, bootOn and "[Bootstrap 1x: ON ]" or "[Bootstrap 1x: OFF]", bootOn and COLORS.green or COLORS.muted, COLORS.btnBg, function()
        self.cfg.allowBootstrap1x = not bootOn
        self:save("Bootstrap 1x (0L Mag) -> " .. tostring(self.cfg.allowBootstrap1x))
    end)
    local swpOn = (self.cfg.autoSweepForeign ~= false)
    self:drawButton(52, 11, swpOn and "[AutoSweep: ON ]" or "[AutoSweep: OFF]", swpOn and COLORS.green or COLORS.yellow, COLORS.btnBg, function()
        self.cfg.autoSweepForeign = not swpOn
        self:save("AutoSweep Foreign Nanites -> " .. tostring(self.cfg.autoSweepForeign))
    end)

    local rows = {
        { key = "magmatterReserveL",  lbl = "Magmatter Reserve Floor (L)", step = 1000, min = 0, max = 1000000 },
        { key = "defaultMaxParallel", lbl = "Default Max Parallels",       step = 2,    min = 1, max = 512 },
        { key = "pollSec",            lbl = "Poll Interval (sec)",         step = 1,    min = 1, max = 60 },
    }
    for i, rw in ipairs(rows) do
        local ry = 13 + i * 3
        self:drawText(4, ry, string.format("%-30s: %d", rw.lbl, tonumber(self.cfg[rw.key]) or 0), COLORS.fg, COLORS.panelBg)
        self:drawButton(48, ry, "[-]", COLORS.yellow, COLORS.btnBg, function()
            self.cfg[rw.key] = math.max(rw.min, (tonumber(self.cfg[rw.key]) or 0) - rw.step)
            self:save(rw.key .. " -> " .. self.cfg[rw.key])
        end)
        self:drawButton(53, ry, "[+]", COLORS.green, COLORS.btnBg, function()
            self.cfg[rw.key] = math.min(rw.max, (tonumber(self.cfg[rw.key]) or 0) + rw.step)
            self:save(rw.key .. " -> " .. self.cfg[rw.key])
        end)
    end

    self:drawFrame(80, 5, 79, 43, COLORS.border, COLORS.panelBg, "round")
    self:drawText(82, 5, " ◈ GTNH 2.9.0 T4 NANO FORGE INVARIANTS ", COLORS.accent, COLORS.panelBg)
    local notes = {
        "1. Magmatter Formula: 288 / (2^(4 - RecipeTier)) L per parallel",
        "   - Tier 1 (Carbon, Neutronium)            :  36 L / parallel",
        "   - Tier 2 (Silver, Glowstone, Transcendent):  72 L / parallel",
        "   - Tier 3 (Gold, 6PC, WDM, BDM, Univ, Eter): 144 L / parallel",
        "   - Tier 4 (Magmatter Nanites)              : 288 L / parallel",
        "",
        "2. T4 Speed & Overclock Mechanics:",
        "   - Duration Multiplier = 0.9999 ^ MaxParallel",
        "   - 4/4 Perfect OC: T1 & T2 always | T3 iff P >= 2 | T4 never",
        "   - T3 recipes auto-bumped to >=2x when affordable (288L)",
        "",
        "3. Strict Purity & Single-Hatch Metering:",
        "   - NEVER use multi-nanite Stocking Bus (voids T4 parallels!)",
        "   - Dedicated Regular Hatch receives exact (need - existing) L",
        "   - Foreign nanites swept to Return Chest before next recipe",
    }
    for i, ln in ipairs(notes) do
        self:drawText(82, 7 + i * 2, padOrTrunc(ln, 75), (i == 13) and COLORS.yellow or COLORS.fg, COLORS.panelBg)
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
    self:drawButton(36, 7, "[Rediscover]", COLORS.cyan, COLORS.btnBg, function()
        Scheduler.syncHardware(self.cfg, self.state, self.comp)
        self.statusMsg = "Rediscovered Nano Forge hardware."
    end)
    if self.extras.isAutostartEnabled then
        local auto = self.extras.isAutostartEnabled()
        self:drawButton(51, 7, auto and "[Autostart: ON]" or "[Autostart: OFF]", auto and COLORS.green or COLORS.muted, COLORS.btnBg, function()
            local nxt = self.extras.toggleAutostart()
            self.statusMsg = "Autostart -> " .. tostring(nxt)
        end)
    end

    local disc = self.state.discovery or {}
    self:drawText(4, 10, string.format("Controller    : %s (%d found)", tostring(self.cfg.controllerAddr or "-"), #(disc.controllers or {})), COLORS.fg, COLORS.panelBg)
    self:drawText(4, 12, string.format("Item TP       : %s", tostring(self.cfg.itemTransposerAddr or "-")), COLORS.fg, COLORS.panelBg)
    self:drawText(4, 14, string.format("Staging Side  : %-8s  Seed Side: %-8s  Bus Dst Side: %-8s",
        tostring(self.cfg.stagingSrcSide), tostring(self.cfg.seedSrcSide), tostring(self.cfg.dstBusSide)), COLORS.cyan, COLORS.panelBg)
    self:drawText(4, 16, string.format("Return Side   : %-8s  OD Fluid Dst Side: %-8s",
        tostring(self.cfg.returnSide), tostring(self.cfg.odFluidDstSide)), COLORS.cyan, COLORS.panelBg)
    self:drawText(4, 18, string.format("Magmatter TP  : %s  (Src: %-8s -> Hatch Dst: %-8s)",
        tostring(self.cfg.magTransposerAddr or "-"), tostring(self.cfg.magSrcSide), tostring(self.cfg.magDstSide)), COLORS.fg, COLORS.panelBg)
    self:drawText(4, 20, string.format("AE Link       : %s", tostring(self.cfg.aeAddr or "-")), COLORS.fg, COLORS.panelBg)

    local function cycleSide(k)
        local cur = tostring(self.cfg[k] or "up"):lower()
        local nxt = Hardware.SIDES[1]
        for i, s in ipairs(Hardware.SIDES) do
            if s == cur then nxt = Hardware.SIDES[(i % #Hardware.SIDES) + 1]; break end
        end
        self.cfg[k] = nxt
        self:save(k .. " -> " .. nxt)
    end
    self:drawButton(84, 14, "[Stage]", COLORS.cyan, COLORS.btnBg, function() cycleSide("stagingSrcSide") end)
    self:drawButton(93, 14, "[Seed]", COLORS.cyan, COLORS.btnBg, function() cycleSide("seedSrcSide") end)
    self:drawButton(101, 14, "[BusDst]", COLORS.cyan, COLORS.btnBg, function() cycleSide("dstBusSide") end)
    self:drawButton(84, 16, "[Return]", COLORS.cyan, COLORS.btnBg, function() cycleSide("returnSide") end)
    self:drawButton(94, 16, "[ODFluid]", COLORS.cyan, COLORS.btnBg, function() cycleSide("odFluidDstSide") end)
    self:drawButton(84, 18, "[MagSrc]", COLORS.cyan, COLORS.btnBg, function() cycleSide("magSrcSide") end)
    self:drawButton(94, 18, "[MagDst]", COLORS.cyan, COLORS.btnBg, function() cycleSide("magDstSide") end)
end

function UI:render()
    self.hitboxes = {}
    self:clearNextBuffer(COLORS.bg, COLORS.fg)
    self:renderHeader()
    if self.tab == TAB_OVERVIEW then
        self:renderOverviewTab()
    elseif self.tab == TAB_TARGETS then
        self:renderTargetsTab()
    elseif self.tab == TAB_POLICY then
        self:renderPolicyTab()
    else
        self:renderSetupTab()
    end
    self:fillRect(1, self.h, self.w, 1, " ", COLORS.fg, COLORS.headerBg)
    self:drawText(2, self.h, padOrTrunc(self.statusMsg or "", self.w - 30), COLORS.fg, COLORS.headerBg)
    self:drawText(self.w - 26, self.h, "1-4:Tabs  Space:Arm  Q:Quit", COLORS.muted, COLORS.headerBg)
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
    if charCode == 49 then self.tab = TAB_OVERVIEW; return true
    elseif charCode == 50 then self.tab = TAB_TARGETS; return true
    elseif charCode == 51 then self.tab = TAB_POLICY; return true
    elseif charCode == 52 then self.tab = TAB_SETUP; return true
    elseif charCode == 32 then
        self.cfg.armed = not (self.cfg.armed == true)
        self:save("Nano Forge -> " .. (self.cfg.armed and "ARMED" or "PAUSED"))
        return true
    elseif charCode == 81 or charCode == 113 then
        self.running = false
        return true
    end
    return false
end

return UI
