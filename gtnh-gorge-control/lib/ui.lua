-- /home/gorge/lib/ui.lua
-- Visual Touch Control Center for Forge of the Gods & Multi-Exoticizer Rack (160x50 Tier 3 GPU).
-- Uses 64-bit packed integer screen buffers (zero per-cell string allocations) and strictly width-1 glyphs.

local component = require("component")
local unicode = require("unicode")
local Hardware = require("lib.hardware")
local Scheduler = require("lib.scheduler")

local UI = {}

local TAB_OVERVIEW  = 1
local TAB_INSPECTOR = 2
local TAB_SETUP     = 3

local LOG_LEVELS = { "quiet", "normal", "raw" }

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

local FRAME_STYLES = {
    sharp  = { tl = "┌", tr = "┐", bl = "└", br = "┘", h = "─", v = "│" },
    round  = { tl = "╭", tr = "╮", bl = "╰", br = "╯", h = "─", v = "│" },
    double = { tl = "╔", tr = "╗", bl = "╚", br = "╝", h = "═", v = "║" },
}

local _widthCache = {}
local function cpWidth(cp)
    if cp >= 32 and cp <= 126 then return 1 end
    local w = _widthCache[cp]
    if w == nil then
        w = unicode.charWidth(utf8.char(cp))
        _widthCache[cp] = w
    end
    return w
end

local function packColorMask(fg, bg)
    return ((math.floor(fg or COLORS.fg) & 0xFFFFFF) << 40)
        | ((math.floor(bg or COLORS.bg) & 0xFFFFFF) << 16)
end

local function padOrTrunc(str, width)
    str = tostring(str or "")
    if width <= 0 then return "" end
    local len = unicode.wlen(str)
    if len > width then
        if width == 1 then return unicode.sub(str, 1, 1) end
        return unicode.sub(str, 1, width - 1) .. "…"
    elseif len < width then
        return str .. string.rep(" ", width - len)
    end
    return str
end

function UI.formatNumber(n, suffix)
    n = tonumber(n) or 0
    local absN = math.abs(n)
    local suf = suffix or ""
    if absN >= 1e9 then return string.format("%.2fB%s", n / 1e9, suf)
    elseif absN >= 1e6 then return string.format("%.1fM%s", n / 1e6, suf)
    elseif absN >= 1e3 then return string.format("%.1fK%s", n / 1e3, suf)
    else return string.format("%d%s", math.floor(n + 0.5), suf)
    end
end

function UI.new(cfg, state, onSave, compLib, extras)
    local cl = compLib or component
    local gpu = cl.isAvailable and cl.isAvailable("gpu") and cl.gpu or (cl.list and cl.list("gpu", true)() and cl.proxy(cl.list("gpu", true)()))
    local w, h = 160, 50
    if gpu and gpu.maxResolution and gpu.setResolution then
        local mw, mh = gpu.maxResolution()
        w = math.min(160, math.floor(mw or 160))
        h = math.min(50, math.floor(mh or 50))
        pcall(gpu.setResolution, w, h)
    end

    local self = setmetatable({
        cfg = cfg,
        state = state,
        onSave = onSave,
        extras = extras or {},
        comp = cl,
        gpu = gpu,
        w = w,
        h = h,
        tab = TAB_OVERVIEW,
        running = true,
        selectedExIdx = 1,
        fleetPage = 0,
        setupFieldIdx = 1,
        logModalActive = false,
        logModalScroll = 0,
        statusMsg = "Ready. Press [PAUSED] or Space to arm Gorge & Exoticizers.",
        hitboxes = {},
        curBuf = {},
        nxtBuf = {},
    }, { __index = UI })

    for i = 1, self.w * self.h do
        self.curBuf[i] = -1
        self.nxtBuf[i] = 0
    end
    return self
end

function UI:save(msg)
    if self.onSave then self.onSave(self.cfg) end
    if msg then self.statusMsg = msg end
end

function UI:invalidateScreen()
    for i = 1, self.w * self.h do
        self.curBuf[i] = -1
    end
end

function UI:clearNextBuffer(bgCol, fgCol)
    local emptyCell = packColorMask(fgCol, bgCol) | 32
    local nxtBuf = self.nxtBuf
    for i = 1, self.w * self.h do
        nxtBuf[i] = emptyCell
    end
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

function UI:drawText(x, y, text, fg, bg)
    if y < 1 or y > self.h then return end
    text = tostring(text or "")
    local mask = packColorMask(fg, bg)
    local rowBase = (y - 1) * self.w
    local nxtBuf = self.nxtBuf
    local col = x
    for _, cp in utf8.codes(text) do
        if col >= 1 and col <= self.w then
            local safeCp = (cpWidth(cp) > 1 or cp > 0xFFFF) and 63 or cp
            nxtBuf[rowBase + col] = mask | safeCp
        end
        col = col + 1
        if col > self.w then break end
    end
end

function UI:fillRect(x, y, w, h, ch, bg, fg)
    local fillCp = (ch and ch ~= "") and utf8.codepoint(ch, 1) or 32
    if cpWidth(fillCp) > 1 or fillCp > 0xFFFF then fillCp = 63 end
    local cell = packColorMask(fg, bg) | (fillCp & 0xFFFF)
    local sw = self.w
    local nxtBuf = self.nxtBuf
    local x1, x2 = math.max(1, x), math.min(sw, x + w - 1)
    local y1, y2 = math.max(1, y), math.min(self.h, y + h - 1)
    for ry = y1, y2 do
        local rowBase = (ry - 1) * sw
        for rx = x1, x2 do
            nxtBuf[rowBase + rx] = cell
        end
    end
end

function UI:drawFrame(x, y, w, h, borderFg, bg, style)
    local s = FRAME_STYLES[style or "round"] or FRAME_STYLES.round
    if w < 2 or h < 2 then return end
    self:fillRect(x + 1, y + 1, w - 2, h - 2, " ", bg, borderFg)
    self:drawText(x, y, s.tl .. string.rep(s.h, w - 2) .. s.tr, borderFg, bg)
    for ry = y + 1, y + h - 2 do
        self:drawText(x, ry, s.v, borderFg, bg)
        self:drawText(x + w - 1, ry, s.v, borderFg, bg)
    end
    self:drawText(x, y + h - 1, s.bl .. string.rep(s.h, w - 2) .. s.br, borderFg, bg)
end

function UI:drawButton(x, y, label, fg, bg, onClick)
    self:drawText(x, y, label, fg, bg)
    local len = unicode.wlen(label)
    if onClick then
        self:addHitbox(x, y, x + len - 1, y, onClick)
    end
    return x + len
end

function UI:flush()
    local gpu = self.gpu
    if not gpu then return end
    local lastFg, lastBg = -1, -1
    local w = self.w
    local nxt, cur = self.nxtBuf, self.curBuf
    for ry = 1, self.h do
        local rowBase = (ry - 1) * w
        local rx = 1
        while rx <= w do
            local idx = rowBase + rx
            local cell = nxt[idx]
            if cur[idx] ~= cell then
                local startX = rx
                local colBits = cell >> 16
                local runCps = {}
                while rx <= w do
                    local nIdx = rowBase + rx
                    local nCell = nxt[nIdx]
                    if (nCell >> 16) ~= colBits or cur[nIdx] == nCell then
                        break
                    end
                    cur[nIdx] = nCell
                    runCps[#runCps + 1] = nCell & 0xFFFF
                    rx = rx + 1
                end
                local fg = (colBits >> 24) & 0xFFFFFF
                local bg = colBits & 0xFFFFFF
                if bg ~= lastBg then
                    gpu.setBackground(bg)
                    lastBg = bg
                end
                if fg ~= lastFg then
                    gpu.setForeground(fg)
                    lastFg = fg
                end
                gpu.set(startX, ry, utf8.char(table.unpack(runCps)))
            else
                rx = rx + 1
            end
        end
    end
end

function UI:selectedExoticizer()
    local list = self.cfg.exoticizers or {}
    if #list == 0 then return nil, 0 end
    self.selectedExIdx = math.max(1, math.min(#list, self.selectedExIdx or 1))
    return list[self.selectedExIdx], self.selectedExIdx
end

local function phaseColor(ph)
    if ph == "WAIT_END" or ph == "ENCODE" or ph == "CLEAR_AE" or ph == "REQUEST" then return COLORS.green
    elseif ph == "RETRY_WAIT" then return COLORS.red
    elseif ph == "PAUSED" or ph == "UNBOUND" then return COLORS.yellow
    else return COLORS.cyan
    end
end

function UI:renderHeader()
    self:fillRect(1, 1, self.w, 2, " ", COLORS.headerBg)
    self:drawText(2, 1, "◈ GTNH GORGE & EXOTICIZER CONTROL", COLORS.accent, COLORS.headerBg)

    local armed = (self.cfg.armed == true)
    local nx = self:drawButton(37, 1, armed and "[ARMED ]" or "[PAUSED]",
        armed and COLORS.fg or COLORS.yellow,
        armed and COLORS.darkGreen or COLORS.amberBg,
        function()
            self.cfg.armed = not armed
            if self.cfg.armed then
                self.state._forcePollNow = true
                self:save("Armed: Multi-Exoticizer & Godforge monitor active.")
            else
                self:save("Paused: Exoticizer dispatch halted.")
            end
        end) + 2

    local kpis = self.state.kpis or {}
    local gf = self.state.godforge or {}
    local lscTxt = self.state.lscPct and string.format("%.0f%%", self.state.lscPct) or "--"
    local gfTxt = not gf.bound and "UNBOUND" or (gf.active and "ACT" or (gf.workAllowed == false and "HOLD" or "IDLE"))
    local linkTxt = (self.cfg.extLinkMode == "off") and "Standalone" or "Mesh"
    local summary = string.format("Ex:%d/%d  Active:%d  Cycles:%d  Errors:%d  GF:%s  LSC:%s  [%s]",
        #(self.cfg.exoticizers or {}), 8, kpis.activeCount or 0, kpis.completedCycles or 0,
        kpis.errorCount or 0, gfTxt, lscTxt, linkTxt)
    self:drawText(nx, 1, padOrTrunc(summary, self.w - nx - 38), COLORS.muted, COLORS.headerBg)

    local rx = self.w - 35
    rx = self:drawButton(rx, 1, "[Poll]", COLORS.cyan, COLORS.btnBg, function()
        self.state._forcePollNow = true
        self.statusMsg = "Manual poll requested."
    end) + 1
    rx = self:drawButton(rx, 1, "[Unstick All]", COLORS.yellow, COLORS.amberBg, function()
        local nRec, nCan = Scheduler.unstickExoticizer(self.cfg, self.state, nil, self.comp, "manual")
        self.state._forcePollNow = true
        self.statusMsg = string.format("Unstuck all: recovered %d cell(s), canceled %d craft(s).", nRec or 0, nCan or 0)
    end) + 1
    rx = self:drawButton(rx, 1, "[Log]", COLORS.fg, COLORS.btnBg, function()
        self.logModalActive = true
        self.logModalScroll = 0
    end) + 1
    self:drawButton(rx, 1, "[Quit]", COLORS.red, COLORS.btnBg, function()
        self:save("Saved Gorge config.")
        self.running = false
    end)

    local tabs = {
        { id = TAB_OVERVIEW,  label = "[1] OVERVIEW" },
        { id = TAB_INSPECTOR, label = "[2] EXOTICIZER INSPECTOR" },
        { id = TAB_SETUP,     label = "[3] SETUP & WIRING" },
    }
    local tx = 2
    for _, tb in ipairs(tabs) do
        local act = (self.tab == tb.id)
        tx = self:drawButton(tx, 2, tb.label,
            act and COLORS.fg or COLORS.muted,
            act and COLORS.btnActiveBg or COLORS.headerBg,
            function() self.tab = tb.id end) + 2
    end
    self:drawText(1, 3, string.rep("─", self.w), COLORS.border, COLORS.bg)
end

function UI:renderOverviewTab()
    local gf = self.state.godforge or {}
    local gCfg = self.cfg.godforge or {}

    -- Top Card: Forge of the Gods Controller & LSC On-Demand Guard (y=5..10)
    self:drawFrame(2, 5, 158, 6, COLORS.border, COLORS.panelBg, "round")
    self:drawText(4, 5, " ◈ FORGE OF THE GODS CONTROLLER & LSC GUARD ", COLORS.accent, COLORS.panelBg)
    local gfBadge = not gf.bound and "NO CONTROLLER" or (not gf.online and "OFFLINE" or (gf.active and "ACTIVE" or (gf.workAllowed == false and "THROTTLED" or "ONLINE")))
    local gfCol = (gfBadge == "ACTIVE" or gfBadge == "ONLINE") and COLORS.green or (gfBadge == "THROTTLED" and COLORS.yellow or COLORS.muted)
    self:drawText(143, 5, " " .. padOrTrunc(gfBadge, 13) .. " ", gfCol, COLORS.panelBg)

    local lscStr = self.state.lscPct and string.format("%.1f%%", self.state.lscPct) or "--"
    local gfLine = string.format("Ctrl:%s   Rings:%s   Connected:%s   Upgrades:%s   Progress:%d/%d   LSC Fill:%s   Work:%s",
        Hardware.shortAddr(gCfg.controllerAddr),
        tostring(gf.rings or "--"), tostring(gf.connected or "--"), tostring(gf.upgrades or "--"),
        math.floor(gf.progress or 0), math.floor(gf.maxProgress or 0),
        lscStr, gf.workAllowed ~= false and "ENABLED" or "HOLD")
    self:drawText(4, 7, padOrTrunc(gfLine, 152), COLORS.fg, COLORS.panelBg)

    local gx = 4
    gx = self:drawButton(gx, 9, gCfg.onDemandEnable and "[LSC On-Demand: ON]" or "[LSC On-Demand: OFF]",
        gCfg.onDemandEnable and COLORS.green or COLORS.muted, COLORS.btnBg, function()
            gCfg.onDemandEnable = not gCfg.onDemandEnable
            self:save("Godforge LSC On-Demand -> " .. tostring(gCfg.onDemandEnable))
        end) + 2
    self:drawText(gx, 9, string.format("Stop < %.0f%%", gCfg.minLscPct or 20), COLORS.fg, COLORS.panelBg)
    gx = gx + 12
    gx = self:drawButton(gx, 9, "[-]", COLORS.yellow, COLORS.btnBg, function()
        gCfg.minLscPct = math.max(0, (gCfg.minLscPct or 20) - 5)
        self:save("Min LSC % -> " .. tostring(gCfg.minLscPct))
    end) + 1
    gx = self:drawButton(gx, 9, "[+]", COLORS.green, COLORS.btnBg, function()
        gCfg.minLscPct = math.min(90, (gCfg.minLscPct or 20) + 5)
        Scheduler.normalizeConfig(self.cfg)
        self:save("Min LSC % -> " .. tostring(gCfg.minLscPct))
    end) + 3
    self:drawText(gx, 9, string.format("Resume >= %.0f%%", gCfg.resumeLscPct or 35), COLORS.fg, COLORS.panelBg)
    gx = gx + 15
    gx = self:drawButton(gx, 9, "[-]", COLORS.yellow, COLORS.btnBg, function()
        gCfg.resumeLscPct = math.max((gCfg.minLscPct or 20) + 5, (gCfg.resumeLscPct or 35) - 5)
        self:save("Resume LSC % -> " .. tostring(gCfg.resumeLscPct))
    end) + 1
    gx = self:drawButton(gx, 9, "[+]", COLORS.green, COLORS.btnBg, function()
        gCfg.resumeLscPct = math.min(100, (gCfg.resumeLscPct or 35) + 5)
        self:save("Resume LSC % -> " .. tostring(gCfg.resumeLscPct))
    end) + 3
    self:drawButton(gx, 9, "[Rescan Hardware]", COLORS.cyan, COLORS.btnBg, function()
        Scheduler.syncHardware(self.cfg, self.state, self.comp)
        self:save("Rescanned Gorge hardware & Database slots.")
    end)

    -- Exoticizer Fleet Cards (y=12..47)
    local exList = self.cfg.exoticizers or {}
    local maxPerPage = 4
    local nPages = math.max(1, math.ceil(#exList / maxPerPage))
    self.fleetPage = math.max(0, math.min(nPages - 1, self.fleetPage or 0))
    if #exList > maxPerPage then
        self:drawButton(134, 11, "[<Prev]", COLORS.cyan, COLORS.btnBg, function() self.fleetPage = math.max(0, self.fleetPage - 1) end)
        self:drawText(142, 11, string.format("Page %d/%d", self.fleetPage + 1, nPages), COLORS.muted, COLORS.bg)
        self:drawButton(152, 11, "[Next>]", COLORS.cyan, COLORS.btnBg, function() self.fleetPage = math.min(nPages - 1, self.fleetPage + 1) end)
    end

    local startIdx = self.fleetPage * maxPerPage + 1
    local shown = math.min(maxPerPage, #exList - startIdx + 1)
    local twoRow = (shown > 2)
    local cardH = twoRow and 17 or 35

    for slot = 0, shown - 1 do
        local exIdx = startIdx + slot
        local ex = exList[exIdx]
        local es = (self.state.exStates and self.state.exStates[ex.id or exIdx]) or {}
        local col = slot % 2
        local row = math.floor(slot / 2)
        local cx = 2 + col * 80
        local cy = 12 + row * (cardH + 1)
        local cw = 78

        self:drawFrame(cx, cy, cw, cardH, COLORS.border, COLORS.panelBg, "round")
        self:drawText(cx + 2, cy, string.format(" ◈ %s (DB:%d-%d) ", padOrTrunc(ex.name, 16), (exIdx - 1) * 10 + 1, exIdx * 10), COLORS.accent, COLORS.panelBg)
        local ph = es.phase or "IDLE"
        self:drawText(cx + cw - 13, cy, " " .. padOrTrunc(ph, 10) .. " ", phaseColor(ph), COLORS.panelBg)

        local bx = self:drawButton(cx + 3, cy + 2, "[Mode: " .. tostring(ex.mode):upper() .. "]", COLORS.purple, COLORS.btnBg, function()
            local cur = 1
            for k, m in ipairs(Scheduler.MODES) do if m == ex.mode then cur = k break end end
            ex.mode = Scheduler.MODES[(cur % #Scheduler.MODES) + 1]
            self.state._forcePollNow = true
            self:save(string.format("%s mode -> %s", ex.name, ex.mode))
        end) + 2
        bx = self:drawButton(bx, cy + 2, ex.enabled ~= false and "[ON]" or "[OFF]",
            ex.enabled ~= false and COLORS.green or COLORS.red, COLORS.btnBg, function()
                ex.enabled = not (ex.enabled ~= false)
                self.state._forcePollNow = true
                self:save(string.format("%s enabled -> %s", ex.name, tostring(ex.enabled)))
            end) + 2
        bx = self:drawButton(bx, cy + 2, "[Unstick]", COLORS.yellow, COLORS.btnBg, function()
            local nRec, nCan = Scheduler.unstickExoticizer(self.cfg, self.state, ex.id or exIdx, self.comp, "manual")
            self.state._forcePollNow = true
            self.statusMsg = string.format("Unstuck %s (cells:%d, crafts:%d).", ex.name, nRec or 0, nCan or 0)
        end) + 2
        self:drawButton(bx, cy + 2, "[Inspect]", COLORS.cyan, COLORS.btnBg, function()
            self.selectedExIdx = exIdx
            self.tab = TAB_INSPECTOR
        end)

        local statsTxt = string.format("Eff:%s  RS:%s (%d)  Outputs:%d  FreeCPU:%d/%d  Cycles:%d",
            tostring(es.activeMode or ex.mode):upper(),
            ex.expectRedstone == false and "IGN" or (es.rsSignal and es.rsSignal > 0 and "ON" or "LOW"),
            es.rsSignal or 0, es.distinctOutputs or 0, es.freeCpus or 0, es.totalCpus or 0, es.completedCycles or 0)
        self:drawText(cx + 3, cy + 4, padOrTrunc(statsTxt, cw - 6), COLORS.fg, COLORS.panelBg)

        if es.lastError then
            self:drawText(cx + 3, cy + 6, padOrTrunc("! " .. tostring(es.lastError), cw - 6), COLORS.red, COLORS.panelBg)
        else
            local bindTxt = string.format("Out:%s  In:%s  TP:%s  RS:%s",
                Hardware.shortAddr(ex.outputMeInterfaceAddress),
                Hardware.shortAddr(ex.inputMeInterfaceAddress),
                Hardware.shortAddr(ex.transposerAddress),
                Hardware.shortAddr(ex.redstoneIoAddress))
            self:drawText(cx + 3, cy + 6, padOrTrunc(bindTxt, cw - 6), COLORS.muted, COLORS.panelBg)
        end

        local listY = cy + 8
        local maxLines = cardH - 10
        local showList = es.batchInputs or es.previewInputs
        if showList and #showList > 0 then
            self:drawText(cx + 3, listY, "Active / Preview Plasma Batch:", COLORS.cyan, COLORS.panelBg)
            for pi = 1, math.min(maxLines - 1, #showList) do
                local inp = showList[pi]
                self:drawText(cx + 4, listY + pi, padOrTrunc(string.format("%-26s -> %-24s %s",
                    inp.label, inp.fluid, UI.formatNumber(inp.amount, "L")), cw - 8), COLORS.green, COLORS.panelBg)
            end
        elseif ph == "UNBOUND" then
            self:drawText(cx + 3, listY, "Unbound module: configure addresses in [3] SETUP & WIRING.", COLORS.yellow, COLORS.panelBg)
        else
            self:drawText(cx + 3, listY, "Idle: waiting for Redstone demand & output subnet batch.", COLORS.muted, COLORS.panelBg)
        end
    end
end

function UI:renderInspectorTab()
    local exList = self.cfg.exoticizers or {}
    local ex, exIdx = self:selectedExoticizer()
    local bx = 2
    for i = 1, #exList do
        local sel = (i == exIdx)
        bx = self:drawButton(bx, 5, "[" .. padOrTrunc(exList[i].name, 14) .. "]",
            sel and COLORS.fg or COLORS.muted, sel and COLORS.btnActiveBg or COLORS.btnBg,
            function() self.selectedExIdx = i end) + 1
    end
    if not ex then return end
    local es = (self.state.exStates and self.state.exStates[ex.id or exIdx]) or {}

    -- Left Card: Raw Output Subnet Inventory
    self:drawFrame(2, 7, 78, 40, COLORS.border, COLORS.panelBg, "round")
    self:drawText(4, 7, " ◈ OUTPUT SUBNET INVENTORY (" .. padOrTrunc(ex.name, 16) .. ") ", COLORS.accent, COLORS.panelBg)
    self:drawText(4, 9, string.format("Phase: %-10s | EffMode: %-9s | RS: %d | Cycles: %d",
        tostring(es.phase or "IDLE"), tostring(es.activeMode or ex.mode):upper(), es.rsSignal or 0, es.completedCycles or 0),
        COLORS.cyan, COLORS.panelBg)
    self:drawText(4, 11, "Material                        Kind     Qty / Count", COLORS.muted, COLORS.panelBg)
    self:drawText(3, 12, string.rep("─", 75), COLORS.border, COLORS.panelBg)

    local keys = {}
    for k in pairs(es.lastOutputs or {}) do keys[#keys + 1] = k end
    table.sort(keys)
    if #keys == 0 then
        self:drawText(4, 14, "Output subnet is empty.", COLORS.muted, COLORS.panelBg)
    else
        for r = 1, math.min(28, #keys) do
            local entry = es.lastOutputs[keys[r]]
            local ry = 12 + r
            self:drawText(4, ry, padOrTrunc(entry.label, 31), COLORS.fg, COLORS.panelBg)
            self:drawText(36, ry, entry.isLiquid and "FLUID" or "DUST", COLORS.purple, COLORS.panelBg)
            self:drawText(45, ry, UI.formatNumber(entry.count, entry.isLiquid and "L" or "u"), COLORS.green, COLORS.panelBg)
        end
    end

    -- Right Card: Computed Injection Recipe & Manual Actions
    self:drawFrame(82, 7, 78, 40, COLORS.border, COLORS.panelBg, "round")
    self:drawText(84, 7, string.format(" ◈ FAKE PATTERN & DB SLOTS %d-%d ", (exIdx - 1) * 10 + 1, exIdx * 10), COLORS.accent, COLORS.panelBg)
    self:drawText(84, 9, padOrTrunc("Marker Recipe: " .. tostring(es.fakeName or "--"), 74), COLORS.muted, COLORS.panelBg)
    self:drawText(84, 11, "Slot  Fluid ID                    Amount", COLORS.muted, COLORS.panelBg)
    self:drawText(83, 12, string.rep("─", 75), COLORS.border, COLORS.panelBg)

    local baseSlot = (exIdx - 1) * 10 + 1
    local recList = es.batchInputs or es.previewInputs
    if recList and #recList > 0 then
        for i = 1, math.min(10, #recList) do
            local inp = recList[i]
            self:drawText(84, 12 + i, string.format("#%02d   %-26s  %s", baseSlot + i, padOrTrunc(inp.fluid, 26), UI.formatNumber(inp.amount, "L")), COLORS.green, COLORS.panelBg)
        end
    elseif es.previewErr then
        self:drawText(84, 14, padOrTrunc("Preview blocked: " .. tostring(es.previewErr), 74), COLORS.yellow, COLORS.panelBg)
    else
        self:drawText(84, 14, "No full batch ready yet.", COLORS.muted, COLORS.panelBg)
    end

    self:drawText(84, 38, "Manual Maintenance Actions:", COLORS.muted, COLORS.panelBg)
    local ax = 84
    ax = self:drawButton(ax, 40, "[Clear Output Drive]", COLORS.yellow, COLORS.amberBg, function()
        local ok, moved, err = Hardware.clearOutputCells(ex, self.comp, self.state, 4.0)
        self.statusMsg = ok and string.format("Cleared %d storage cell(s) via ME IO Port.", moved or 0) or ("Clear failed: " .. tostring(err))
    end) + 2
    ax = self:drawButton(ax, 40, "[Encode Idle]", COLORS.cyan, COLORS.btnBg, function()
        local ok, info = Hardware.encodeExoticizerPattern(ex, exIdx, nil, self.comp, self.state)
        self.statusMsg = ok and ("Reset slot-1 pattern to safe idle: " .. tostring(info)) or ("Encode failed: " .. tostring(info))
    end) + 2
    ax = self:drawButton(ax, 40, "[Cancel Craft]", COLORS.red, COLORS.darkRed, function()
        local _, n = Hardware.cancelFakeCraft(ex, es.fakeName or "", self.comp, self.state, 1.5)
        self.statusMsg = string.format("Canceled %d matching craft(s).", n or 0)
    end) + 2
    self:drawButton(ax, 40, "[Unstick]", COLORS.green, COLORS.btnBg, function()
        local nRec, nCan = Scheduler.unstickExoticizer(self.cfg, self.state, ex.id or exIdx, self.comp, "manual")
        self.state._forcePollNow = true
        self.statusMsg = string.format("Unstuck %s (cells:%d, crafts:%d).", ex.name, nRec or 0, nCan or 0)
    end)
end

function UI:renderSetupTab()
    local disc = self.state.discovery or {}
    local exList = self.cfg.exoticizers or {}
    local ex, exIdx = self:selectedExoticizer()

    local bx = 2
    for i = 1, #exList do
        local sel = (i == exIdx)
        bx = self:drawButton(bx, 5, "[" .. padOrTrunc(exList[i].name, 14) .. "]",
            sel and COLORS.fg or COLORS.muted, sel and COLORS.btnActiveBg or COLORS.btnBg,
            function() self.selectedExIdx = i end) + 1
    end
    bx = self:drawButton(bx + 1, 5, "[+ Add Exoticizer]", COLORS.green, COLORS.btnBg, function()
        if #self.cfg.exoticizers < 8 then
            local nxt = #self.cfg.exoticizers + 1
            self.cfg.exoticizers[nxt] = Scheduler.newExoticizer(nxt, "auto")
            self.selectedExIdx = nxt
            self:save("Added Exoticizer #" .. nxt)
        end
    end) + 1
    if #exList > 1 and ex then
        self:drawButton(bx, 5, "[- Remove]", COLORS.red, COLORS.btnBg, function()
            table.remove(self.cfg.exoticizers, exIdx)
            self.selectedExIdx = math.max(1, exIdx - 1)
            Scheduler.normalizeConfig(self.cfg)
            self:save("Removed Exoticizer #" .. exIdx)
        end)
    end

    -- Left Card: Selected Exoticizer Component & Side Mapping
    self:drawFrame(2, 7, 78, 40, COLORS.border, COLORS.panelBg, "round")
    self:drawText(4, 7, " ◈ EXOTICIZER COMPONENT WIRING ", COLORS.accent, COLORS.panelBg)
    if ex then
        local function cycleAddr(field, list)
            if not list or #list == 0 then
                self.statusMsg = "No matching components discovered for " .. field
                return
            end
            local cur = ex[field]
            local nextIdx = 1
            for idx, item in ipairs(list) do
                if item.address == cur then nextIdx = idx + 1 break end
            end
            ex[field] = (nextIdx <= #list) and list[nextIdx].address or nil
            self:save(string.format("%s %s -> %s", ex.name, field, Hardware.shortAddr(ex[field])))
        end

        local rows = {
            { lbl = "Output ME Interface", field = "outputMeInterfaceAddress", list = disc.interfaces },
            { lbl = "Input ME Interface",  field = "inputMeInterfaceAddress",  list = disc.interfaces },
            { lbl = "Transposer",          field = "transposerAddress",        list = disc.transposers },
            { lbl = "Redstone I/O",        field = "redstoneIoAddress",        list = disc.redstones },
            { lbl = "Database Override",   field = "databaseAddress",          list = disc.databases },
        }
        for i, r in ipairs(rows) do
            local ry = 9 + (i - 1) * 2
            self:drawText(4, ry, padOrTrunc(r.lbl .. ":", 22), COLORS.muted, COLORS.panelBg)
            local addr = ex[r.field]
            local hintTag = ""
            if addr and r.list == disc.interfaces then
                for _, item in ipairs(disc.interfaces or {}) do
                    if item.address == addr and item.roleHint then
                        hintTag = " " .. item.roleHint
                        break
                    end
                end
            end
            self:drawButton(27, ry, "[" .. (addr and (Hardware.shortAddr(addr) .. hintTag) or "Auto/None") .. " (Cycle)]",
                addr and COLORS.cyan or COLORS.yellow, COLORS.btnBg,
                function() cycleAddr(r.field, r.list) end)
        end

        local sideRows = {
            { lbl = "ME IO Port Side", field = "meIoPortSide" },
            { lbl = "ME Drive Side",   field = "meDriveSide" },
            { lbl = "Redstone Side",   field = "redstoneIoSide" },
        }
        for i, sr in ipairs(sideRows) do
            local ry = 21 + (i - 1) * 2
            self:drawText(4, ry, padOrTrunc(sr.lbl .. ":", 22), COLORS.muted, COLORS.panelBg)
            local val = tonumber(ex[sr.field]) or 0
            self:drawButton(27, ry, "[" .. (Hardware.SIDE_NAMES[val] or tostring(val)) .. "]", COLORS.cyan, COLORS.btnBg, function(step)
                ex[sr.field] = (val + (step or 1) + 6) % 6
                self:save(string.format("%s %s -> %s", ex.name, sr.lbl, Hardware.SIDE_NAMES[ex[sr.field]] or ex[sr.field]))
            end)
        end

        self:drawText(4, 28, "Require RS Demand:", COLORS.muted, COLORS.panelBg)
        self:drawButton(27, 28, ex.expectRedstone ~= false and "[ON (Level Emitter)]" or "[OFF (Outputs Only)]",
            ex.expectRedstone ~= false and COLORS.green or COLORS.yellow, COLORS.btnBg, function()
                ex.expectRedstone = not (ex.expectRedstone ~= false)
                self:save(ex.name .. " Require RS -> " .. tostring(ex.expectRedstone))
            end)

        self:drawText(4, 30, "Auto Mode Default:", COLORS.muted, COLORS.panelBg)
        self:drawButton(27, 30, "[" .. tostring(ex.autoPrefer or "gluon"):upper() .. "]", COLORS.purple, COLORS.btnBg, function()
            ex.autoPrefer = (ex.autoPrefer == "magmatter") and "gluon" or "magmatter"
            self:save(ex.name .. " autoPrefer -> " .. ex.autoPrefer)
        end)

        self:drawText(4, 33, string.format("Reserved DB Slots: #%02d..#%02d on Tier-3 Database (%d discovered)",
            (exIdx - 1) * 10 + 1, exIdx * 10, #(disc.databases or {})), COLORS.muted, COLORS.panelBg)
    end

    -- Right Card: Godforge Controller & Global Settings
    self:drawFrame(82, 7, 78, 40, COLORS.border, COLORS.panelBg, "round")
    self:drawText(84, 7, " ◈ GODFORGE CONTROLLER & GLOBAL TUNING ", COLORS.accent, COLORS.panelBg)

    local gCfg = self.cfg.godforge or {}
    self:drawText(84, 9, "Godforge Controller:", COLORS.muted, COLORS.panelBg)
    self:drawButton(106, 9, "[" .. (gCfg.controllerAddr and Hardware.shortAddr(gCfg.controllerAddr) or "None") .. "]",
        gCfg.controllerAddr and COLORS.green or COLORS.yellow, COLORS.btnBg, function()
            local list = disc.machines or {}
            if #list == 0 then self.statusMsg = "No gt_machine discovered."; return end
            local nextIdx = 1
            for idx, m in ipairs(list) do if m.address == gCfg.controllerAddr then nextIdx = idx + 1 break end end
            gCfg.controllerAddr = (nextIdx <= #list) and list[nextIdx].address or nil
            self:save("Godforge Ctrl -> " .. Hardware.shortAddr(gCfg.controllerAddr))
        end)

    self:drawText(84, 11, "OC Mesh Link (4205):", COLORS.muted, COLORS.panelBg)
    local isStand = (self.cfg.extLinkMode == "off")
    self:drawButton(106, 11, isStand and "[Standalone (OFF)]" or "[Mesh / Auto (4205)]",
        isStand and COLORS.yellow or COLORS.cyan, isStand and COLORS.amberBg or COLORS.btnBg, function()
            self.cfg.extLinkMode = isStand and "auto" or "off"
            self:save("ExtLink -> " .. self.cfg.extLinkMode)
        end)

    local tunes = {
        { key = "pollIntervalSec", lbl = "Poll Interval (s)",  step = 0.25, min = 0.25, max = 10,  fmt = "%.2fs" },
        { key = "retryBackoffSec", lbl = "Retry Backoff (s)",  step = 5,    min = 2,    max = 300, fmt = "%.0fs" },
        { key = "waitTimeoutSec",  lbl = "Wait Timeout Warn",  step = 30,   min = 30,   max = 3600, fmt = "%.0fs" },
    }
    for i, tn in ipairs(tunes) do
        local ry = 13 + (i - 1) * 2
        self:drawText(84, ry, padOrTrunc(tn.lbl .. ":", 21), COLORS.muted, COLORS.panelBg)
        self:drawText(106, ry, string.format(tn.fmt, tonumber(self.cfg[tn.key]) or tn.min), COLORS.cyan, COLORS.panelBg)
        self:drawButton(118, ry, "[-]", COLORS.yellow, COLORS.btnBg, function()
            self.cfg[tn.key] = math.max(tn.min, (tonumber(self.cfg[tn.key]) or tn.min) - tn.step)
            self:save(tn.lbl .. " -> " .. tostring(self.cfg[tn.key]))
        end)
        self:drawButton(123, ry, "[+]", COLORS.green, COLORS.btnBg, function()
            self.cfg[tn.key] = math.min(tn.max, (tonumber(self.cfg[tn.key]) or tn.min) + tn.step)
            self:save(tn.lbl .. " -> " .. tostring(self.cfg[tn.key]))
        end)
    end

    self:drawText(84, 19, "Log Verbosity:", COLORS.muted, COLORS.panelBg)
    self:drawButton(106, 19, "[" .. tostring(self.cfg.logLevel):upper() .. "]", COLORS.cyan, COLORS.btnBg, function()
        local cur = 2
        for k, lv in ipairs(LOG_LEVELS) do if lv == self.cfg.logLevel then cur = k break end end
        self.cfg.logLevel = LOG_LEVELS[(cur % #LOG_LEVELS) + 1]
        self:save("Log Level -> " .. self.cfg.logLevel)
    end)

    self:drawText(84, 21, "Auto-Unstick Watch:", COLORS.muted, COLORS.panelBg)
    local auEn = (self.cfg.autoUnstickEnable ~= false)
    self:drawButton(106, 21, auEn and "[ON ]" or "[OFF]", auEn and COLORS.green or COLORS.yellow, COLORS.btnBg, function()
        self.cfg.autoUnstickEnable = not auEn
        self:save("Auto-Unstick Watchdog -> " .. tostring(self.cfg.autoUnstickEnable))
    end)
    self:drawText(113, 21, string.format("%.0fs", tonumber(self.cfg.autoUnstickSec) or 600), COLORS.cyan, COLORS.panelBg)
    self:drawButton(120, 21, "[-]", COLORS.yellow, COLORS.btnBg, function()
        self.cfg.autoUnstickSec = math.max(60, (tonumber(self.cfg.autoUnstickSec) or 600) - 60)
        self:save("Auto-Unstick Sec -> " .. tostring(self.cfg.autoUnstickSec))
    end)
    self:drawButton(125, 21, "[+]", COLORS.green, COLORS.btnBg, function()
        self.cfg.autoUnstickSec = math.min(3600, (tonumber(self.cfg.autoUnstickSec) or 600) + 60)
        self:save("Auto-Unstick Sec -> " .. tostring(self.cfg.autoUnstickSec))
    end)

    self:drawText(84, 23, "Boot Autostart:", COLORS.muted, COLORS.panelBg)
    local autoOn = (self.extras.isAutostartEnabled and self.extras.isAutostartEnabled()) == true
    self:drawButton(106, 23, autoOn and "[.shrc: ON ]" or "[.shrc: OFF]", autoOn and COLORS.green or COLORS.muted, COLORS.btnBg, function()
        if self.extras.toggleAutostart then
            local nowOn = self.extras.toggleAutostart()
            self.statusMsg = "Boot Autostart (/home/.shrc) -> " .. (nowOn and "ENABLED" or "DISABLED")
        else
            self.statusMsg = "Autostart toggle unavailable in standalone UI."
        end
    end)

    self:drawText(84, 25, string.format("Discovered: IF=%d  TP=%d  RS=%d  DB=%d  GT=%d  LSC=%s",
        #(disc.interfaces or {}), #(disc.transposers or {}), #(disc.redstones or {}),
        #(disc.databases or {}), #(disc.machines or {}), disc.lscAddr and "YES" or "NO"),
        COLORS.fg, COLORS.panelBg)

    self:drawText(84, 28, "Multi-Exoticizer Rack Architecture:", COLORS.accent, COLORS.panelBg)
    self:drawText(84, 30, "1. One Tier-3 Database Upgrade holds up to 8 Exoticizers (10 slots each).", COLORS.fg, COLORS.panelBg)
    self:drawText(84, 32, "2. Each Exoticizer encodes ONLY its active batch fluids (3 Mag or 7 Gluon).", COLORS.fg, COLORS.panelBg)
    self:drawText(84, 34, "3. Dynamic cell count (1..6) clears Output Drive cleanly via ME IO Port.", COLORS.fg, COLORS.panelBg)
    self:drawText(84, 36, "4. Boot + Auto-Unstick recovers IO Port cells & preserves in-flight batches.", COLORS.fg, COLORS.panelBg)
end

function UI:renderLogModal()
    if not self.logModalActive then return end
    self.hitboxes = {}
    local mx, my, mw, mh = 10, 4, 140, 42
    self:drawFrame(mx, my, mw, mh, COLORS.accent, COLORS.headerBg, "double")
    self:drawText(mx + 2, my, " ◈ GORGE & EXOTICIZER ACTIVITY LOG ", COLORS.accent, COLORS.headerBg)
    self:drawButton(mx + mw - 10, my + 1, "[Close]", COLORS.red, COLORS.btnBg, function()
        self.logModalActive = false
    end)

    local list = self.state.logs or {}
    local maxLines = mh - 5
    local maxScroll = math.max(0, #list - maxLines)
    self.logModalScroll = math.max(0, math.min(maxScroll, self.logModalScroll or 0))
    for i = 1, math.min(maxLines, #list - self.logModalScroll) do
        local entry = list[#list - (self.logModalScroll + i - 1)]
        if type(entry) == "table" then
            local col = (entry.tag == "WRN") and COLORS.yellow or ((entry.tag == "OUT") and COLORS.green or COLORS.fg)
            local txt = string.format("[%s] %.1fs %s", tostring(entry.tag or "LOG"), tonumber(entry.t) or 0, tostring(entry.msg or ""))
            self:drawText(mx + 3, my + 3 + i, padOrTrunc(txt, mw - 6), col, COLORS.headerBg)
        end
    end
end

function UI:render()
    self.hitboxes = {}
    self:clearNextBuffer(COLORS.bg, COLORS.fg)
    self:renderHeader()

    if self.tab == TAB_OVERVIEW then
        self:renderOverviewTab()
    elseif self.tab == TAB_INSPECTOR then
        self:renderInspectorTab()
    elseif self.tab == TAB_SETUP then
        self:renderSetupTab()
    end

    self:drawText(1, self.h - 1, string.rep("─", self.w), COLORS.border, COLORS.bg)
    self:fillRect(1, self.h, self.w, 1, " ", COLORS.headerBg)
    self:drawText(2, self.h, padOrTrunc(self.statusMsg, 108), COLORS.fg, COLORS.headerBg)
    self:drawText(112, self.h, "1-3:Tabs  Space:Arm  L:Log  R:Scan  Q:Quit", COLORS.muted, COLORS.headerBg)

    if self.logModalActive then self:renderLogModal() end
    self:flush()
end

function UI:handleTouch(x, y, button)
    for i = #self.hitboxes, 1, -1 do
        local hb = self.hitboxes[i]
        if x >= hb.x1 and x <= hb.x2 and y >= hb.y1 and y <= hb.y2 then
            hb.fn((button == 1) and -1 or 1, button)
            return true
        end
    end
    return false
end

function UI:handleScroll(dir)
    if self.logModalActive then
        self.logModalScroll = math.max(0, (self.logModalScroll or 0) - dir * 2)
    end
end

function UI:handleKeyDown(char, code)
    if self.logModalActive then
        if code == 1 or char == string.byte("l") or char == string.byte("L") then
            self.logModalActive = false
        elseif code == 200 then self.logModalScroll = math.max(0, (self.logModalScroll or 0) - 1)
        elseif code == 208 then self.logModalScroll = (self.logModalScroll or 0) + 1
        end
        return
    end
    if char == string.byte("1") then self.tab = TAB_OVERVIEW
    elseif char == string.byte("2") then self.tab = TAB_INSPECTOR
    elseif char == string.byte("3") then self.tab = TAB_SETUP
    elseif code == 15 or char == 9 then self.tab = (self.tab % 3) + 1
    elseif char == 32 then
        self.cfg.armed = not self.cfg.armed
        if self.cfg.armed then self.state._forcePollNow = true end
        self:save(self.cfg.armed and "Armed." or "Paused.")
    elseif char == string.byte("l") or char == string.byte("L") then
        self.logModalActive = true; self.logModalScroll = 0
    elseif char == string.byte("r") or char == string.byte("R") then
        Scheduler.syncHardware(self.cfg, self.state, self.comp)
        self.state._forcePollNow = true
        self:save("Rescanned hardware.")
    elseif char == string.byte("q") or char == string.byte("Q") then
        self:save("Saved Gorge config.")
        self.running = false
    end
end

return UI
