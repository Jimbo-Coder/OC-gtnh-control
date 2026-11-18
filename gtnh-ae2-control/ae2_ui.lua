-- /home/ae2_ui.lua
-- Visual Touch Control Center for Mainnet AE2 Exporter & OC Mesh Hub (160x50 Tier 3 GPU).
-- Uses 64-bit packed integer screen buffers (zero per-cell string allocations) and strictly width-1 glyphs.

local component = require("component")
local unicode = require("unicode")

local UI = {}

local TAB_OVERVIEW = 1
local TAB_CPUS     = 2
local TAB_MESH     = 3
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
    if absN >= 1e15 then return string.format("%.2fP%s", n / 1e15, suf)
    elseif absN >= 1e12 then return string.format("%.2fT%s", n / 1e12, suf)
    elseif absN >= 1e9 then return string.format("%.2fG%s", n / 1e9, suf)
    elseif absN >= 1e6 then return string.format("%.1fM%s", n / 1e6, suf)
    elseif absN >= 1e3 then return string.format("%.1fK%s", n / 1e3, suf)
    else return string.format("%d%s", math.floor(n + 0.5), suf)
    end
end

function UI.formatAge(nowSec, thenSec)
    if not thenSec or thenSec < 0 then return "never" end
    local dt = math.max(0, math.floor((tonumber(nowSec) or 0) - tonumber(thenSec)))
    if dt < 60 then return string.format("%ds", dt)
    elseif dt < 3600 then return string.format("%dm", math.floor(dt / 60))
    else return string.format("%dh", math.floor(dt / 3600))
    end
end

function UI.new(cfg, hubState, callbacks, compLib)
    local cl = compLib or component
    local gpu = nil
    if cl.isAvailable and cl.isAvailable("gpu") and cl.gpu then
        gpu = cl.gpu
    elseif cl.list then
        local gAddr = cl.list("gpu", true)()
        if gAddr and cl.proxy then gpu = cl.proxy(gAddr) end
    end

    local w, h = 160, 50
    if gpu and gpu.maxResolution and gpu.setResolution then
        local okM, mw, mh = pcall(gpu.maxResolution)
        if okM and mw and mh then
            w = math.min(160, math.floor(tonumber(mw) or 160))
            h = math.min(50, math.floor(tonumber(mh) or 50))
            pcall(gpu.setResolution, w, h)
        end
    end

    local self = setmetatable({
        cfg = cfg or {},
        hub = hubState or {},
        cb = callbacks or {},
        comp = cl,
        gpu = gpu,
        w = w,
        h = h,
        tab = TAB_OVERVIEW,
        running = true,
        cpuScroll = 0,
        cpuBusyOnly = false,
        confirmCancelCpu = nil,
        logScroll = 0,
        logModalActive = false,
        logModalScroll = 0,
        statusMsg = "Ready. Touch tabs or controls to manage Mainnet AE2 & OC Mesh.",
        hitboxes = {},
        curBuf = {},
        nxtBuf = {},
    }, { __index = UI })

    local empty = packColorMask(COLORS.fg, COLORS.bg) | 32
    for i = 1, w * h do
        self.curBuf[i] = -1
        self.nxtBuf[i] = empty
    end
    return self
end

function UI:clearNextBuffer(bg, fg)
    local v = packColorMask(fg or COLORS.fg, bg or COLORS.bg) | 32
    local nb = self.nxtBuf
    for i = 1, self.w * self.h do
        nb[i] = v
    end
end

function UI:setCell(x, y, cp, fg, bg)
    if x < 1 or x > self.w or y < 1 or y > self.h then return end
    self.nxtBuf[(y - 1) * self.w + x] = packColorMask(fg, bg) | (cp & 0xFFFF)
end

function UI:drawText(x, y, str, fg, bg)
    if y < 1 or y > self.h then return x end
    str = tostring(str or "")
    local col = x
    local mask = packColorMask(fg, bg)
    local nb, w = self.nxtBuf, self.w
    local rowOff = (y - 1) * w
    for _, cp in utf8.codes(str) do
        local cw = cpWidth(cp)
        if cw < 1 then cw = 1 end
        if col >= 1 and col <= w then
            nb[rowOff + col] = mask | (cp & 0xFFFF)
        end
        col = col + cw
        if col > w then break end
    end
    return col
end

function UI:fillRect(x, y, rw, rh, ch, fg, bg)
    local cp = utf8.codepoint(ch or " ", 1) or 32
    local packed = packColorMask(fg, bg) | (cp & 0xFFFF)
    local nb, w = self.nxtBuf, self.w
    local x1 = math.max(1, x)
    local x2 = math.min(w, x + rw - 1)
    local y1 = math.max(1, y)
    local y2 = math.min(self.h, y + rh - 1)
    for r = y1, y2 do
        local off = (r - 1) * w
        for c = x1, x2 do
            nb[off + c] = packed
        end
    end
end

function UI:drawFrame(x, y, fw, fh, fg, bg, style)
    if fw < 2 or fh < 2 then return end
    local st = FRAME_STYLES[style or "round"] or FRAME_STYLES.round
    if bg then
        self:fillRect(x, y, fw, fh, " ", fg, bg)
    end
    local hBar = string.rep(st.h, fw - 2)
    self:drawText(x, y, st.tl .. hBar .. st.tr, fg, bg)
    self:drawText(x, y + fh - 1, st.bl .. hBar .. st.br, fg, bg)
    for ry = y + 1, y + fh - 2 do
        self:drawText(x, ry, st.v, fg, bg)
        self:drawText(x + fw - 1, ry, st.v, fg, bg)
    end
end

function UI:addHitbox(x1, y1, x2, y2, fn, kind)
    self.hitboxes[#self.hitboxes + 1] = {
        x1 = x1, y1 = y1, x2 = x2, y2 = y2,
        fn = fn, kind = kind or "btn",
    }
end

function UI:drawButton(x, y, label, fg, bg, fn, kind)
    local w = unicode.wlen(label)
    self:drawText(x, y, label, fg or COLORS.fg, bg or COLORS.btnBg)
    if fn then
        self:addHitbox(x, y, x + w - 1, y, fn, kind)
    end
    return x + w
end

function UI:drawProgressBar(x, y, width, pct, fgFill, fgEmpty, bg)
    pct = math.max(0, math.min(100, tonumber(pct) or 0))
    local filled = math.floor((pct / 100.0) * width + 0.5)
    for i = 1, width do
        if i <= filled then
            self:drawText(x + i - 1, y, "#", fgFill or COLORS.green, bg)
        else
            self:drawText(x + i - 1, y, "-", fgEmpty or COLORS.border, bg)
        end
    end
end

function UI:flush()
    local gpu = self.gpu
    if not gpu then return end
    local w, h = self.w, self.h
    local cur, nxt = self.curBuf, self.nxtBuf
    local lastFg, lastBg = -1, -1

    for y = 1, h do
        local rowOff = (y - 1) * w
        local x = 1
        while x <= w do
            local idx = rowOff + x
            local nv = nxt[idx]
            if nv ~= cur[idx] then
                local attr = nv >> 16
                local fg = (nv >> 40) & 0xFFFFFF
                local bg = (nv >> 16) & 0xFFFFFF
                local chars = { utf8.char(nv & 0xFFFF) }
                cur[idx] = nv
                local nx = x + 1
                while nx <= w do
                    local nIdx = rowOff + nx
                    local v2 = nxt[nIdx]
                    if v2 ~= cur[nIdx] and (v2 >> 16) == attr then
                        chars[#chars + 1] = utf8.char(v2 & 0xFFFF)
                        cur[nIdx] = v2
                        nx = nx + 1
                    else
                        break
                    end
                end
                if fg ~= lastFg then gpu.setForeground(fg); lastFg = fg end
                if bg ~= lastBg then gpu.setBackground(bg); lastBg = bg end
                gpu.set(x, y, table.concat(chars))
                x = nx
            else
                x = x + 1
            end
        end
    end
end

function UI:renderHeader()
    local hub = self.hub
    local paused = (self.cfg.exportPaused == true)
    self:fillRect(1, 1, self.w, 2, " ", COLORS.fg, COLORS.headerBg)
    self:drawText(2, 1, "◈ GTNH MAINNET AE2 CONTROL", COLORS.accent, COLORS.headerBg)

    local nx = self:drawButton(31, 1, paused and "[EXPORT: PAUSED]" or "[EXPORT: ON    ]",
        paused and COLORS.yellow or COLORS.fg,
        paused and COLORS.amberBg or COLORS.darkGreen,
        function()
            if self.cb.onTogglePauseExport then
                self.statusMsg = tostring(self.cb.onTogglePauseExport() or "Toggled export state.")
            else
                self.cfg.exportPaused = not paused
                self.statusMsg = self.cfg.exportPaused and "Exports PAUSED." or "Exports RESUMED."
            end
        end) + 2

    local freeKB = math.floor((tonumber(hub.freeMem) or 0) / 1024)
    local totKB = math.floor((tonumber(hub.totalMem) or 0) / 1024)
    local cpus = (hub.cpus) or {}
    local tpsVal = (hub.tps and hub.tps.tps) and string.format("%.1f", hub.tps.tps) or "--"
    local brTxt = (self.cfg.enableBridge) and (hub.bridgeConnected and "ON" or "WAIT") or "OFF"
    local mTxt = (self.cfg.enableMesh ~= false)
        and ((hub.meshTunnelOk and "M+T" or (hub.meshModemOk and "MOD" or "NONE"))) or "OFF"
    local summary = string.format("RAM:%d/%dK  Bridge:%s  Mesh:%s  CPUs:%d/%d  TPS:%s",
        freeKB, totKB, brTxt, mTxt, tonumber(cpus.busyCount) or 0, tonumber(cpus.total) or 0, tpsVal)
    self:drawText(nx, 1, padOrTrunc(summary, self.w - nx - 35), COLORS.muted, COLORS.headerBg)

    local rx = self.w - 34
    rx = self:drawButton(rx, 1, "[Scan Now]", COLORS.cyan, COLORS.btnBg, function()
        if self.cb.onScanNow then self.cb.onScanNow() end
        self.statusMsg = "Immediate scan & telemetry refresh queued."
    end) + 1
    rx = self:drawButton(rx, 1, "[Mesh Ping]", COLORS.green, COLORS.btnBg, function()
        if self.cb.onMeshPing then self.cb.onMeshPing() end
        self.statusMsg = "Broadcast MESH_MAINNET_HELLO beacon to peers."
    end) + 1
    rx = self:drawButton(rx, 1, "[Log]", COLORS.fg, COLORS.btnBg, function()
        self.logModalActive = true
        self.logModalScroll = 0
    end) + 1
    self:drawButton(rx, 1, "[Quit]", COLORS.red, COLORS.btnBg, function()
        self.running = false
    end)

    local tabs = {
        { id = TAB_OVERVIEW, label = "[1] OVERVIEW & POWER" },
        { id = TAB_CPUS,     label = "[2] CRAFTING CPUs" },
        { id = TAB_MESH,     label = "[3] OC MESH PEERS" },
        { id = TAB_SETUP,    label = "[4] SETUP & EXPORTS" },
    }
    local tx = 2
    for _, tb in ipairs(tabs) do
        local act = (self.tab == tb.id)
        tx = self:drawButton(tx, 2, tb.label,
            act and COLORS.fg or COLORS.muted,
            act and COLORS.btnActiveBg or COLORS.headerBg,
            function()
                self.tab = tb.id
                self.confirmCancelCpu = nil
            end) + 2
    end
    self:drawText(1, 3, string.rep("─", self.w), COLORS.border, COLORS.bg)
end

function UI:renderOverviewTab()
    local hub = self.hub
    local ae2 = hub.ae2 or {}
    local lsc = hub.lsc or {}
    local tps = hub.tps or {}
    local cpus = hub.cpus or {}
    local peers = hub.peers or {}
    local now = tonumber(hub.nowUptime) or 0

    -- 4 KPI Cards across y=5..12 (width ~38 each)
    -- Card 1: AE2 Power & Storage (x=2, w=38)
    self:drawFrame(2, 5, 38, 8, COLORS.border, COLORS.panelBg, "round")
    self:drawText(4, 5, " ◈ AE2 POWER & STORAGE ", COLORS.accent, COLORS.panelBg)
    if ae2.connected then
        local unit = (self.cfg.energyAE2ExportAsEU ~= false) and "EU/t" or "AE/t"
        local pct = (ae2.maxStorage and ae2.maxStorage > 0) and ((ae2.currStorage / ae2.maxStorage) * 100) or 0
        self:drawText(4, 7, padOrTrunc(string.format("Usage: %s  Idle: %s", UI.formatNumber(ae2.avgUsage, unit), UI.formatNumber(ae2.idleUsage, unit)), 34), COLORS.fg, COLORS.panelBg)
        self:drawText(4, 8, padOrTrunc(string.format("Injet: %s  Fill: %.1f%%", UI.formatNumber(ae2.avgInjection, unit), pct), 34), COLORS.cyan, COLORS.panelBg)
        self:drawText(4, 9, padOrTrunc(string.format("Cell : %s / %s", UI.formatNumber(ae2.currStorage), UI.formatNumber(ae2.maxStorage)), 34), COLORS.muted, COLORS.panelBg)
        self:drawProgressBar(4, 11, 34, pct, COLORS.cyan, COLORS.border, COLORS.panelBg)
    else
        self:drawText(4, 8, "No AE2 Interface bound", COLORS.yellow, COLORS.panelBg)
    end

    -- Card 2: LSC Grid & Wireless (x=41, w=38)
    self:drawFrame(41, 5, 38, 8, COLORS.border, COLORS.panelBg, "round")
    self:drawText(43, 5, " ◈ LSC ENERGY & WIRELESS ", COLORS.accent, COLORS.panelBg)
    if lsc.online then
        local pct = tonumber(lsc.pct) or 0
        self:drawText(43, 7, padOrTrunc(string.format("LSC Fill : %.1f%%  (in:%s)", pct, UI.formatNumber(lsc.in5s or 0, "EU/t")), 34),
            pct < 20 and COLORS.red or (pct < 50 and COLORS.yellow or COLORS.green), COLORS.panelBg)
        self:drawText(43, 8, padOrTrunc(string.format("Net 5s   : %s  Out:%s", UI.formatNumber(lsc.net5s or 0, "EU/t"), UI.formatNumber(lsc.out5s or 0, "EU/t")), 34), COLORS.fg, COLORS.panelBg)
        self:drawText(43, 9, padOrTrunc(string.format("Wireless : %s EU (%s)", tostring(lsc.wirelessStr or "0"), (lsc.wirelessOn ~= false) and "ON" or "OFF"), 34), COLORS.purple, COLORS.panelBg)
        self:drawProgressBar(43, 11, 34, pct, pct < 20 and COLORS.red or COLORS.green, COLORS.border, COLORS.panelBg)
    else
        self:drawText(43, 8, "No LSC Controller detected", COLORS.muted, COLORS.panelBg)
    end

    -- Card 3: Server TPS / MSPT (x=80, w=39)
    self:drawFrame(80, 5, 39, 8, COLORS.border, COLORS.panelBg, "round")
    self:drawText(82, 5, " ◈ SERVER TPS & CHUNKS ", COLORS.accent, COLORS.panelBg)
    if tps.online then
        local tVal = tonumber(tps.tps) or 20
        local tCol = (tVal >= 19.0) and COLORS.green or ((tVal >= 15.0) and COLORS.yellow or COLORS.red)
        self:drawText(82, 7, padOrTrunc(string.format("Server TPS : %.2f / 20.0", tVal), 35), tCol, COLORS.panelBg)
        self:drawText(82, 8, padOrTrunc(string.format("Tick Time  : %.2f mspt", tonumber(tps.mspt) or 0), 35), COLORS.fg, COLORS.panelBg)
        self:drawText(82, 9, padOrTrunc(string.format("Loaded     : %d chunks / %d dims", tonumber(tps.chunks) or 0, tonumber(tps.dims) or 0), 35), COLORS.cyan, COLORS.panelBg)
        self:drawProgressBar(82, 11, 35, (tVal / 20.0) * 100, tCol, COLORS.border, COLORS.panelBg)
    else
        self:drawText(82, 8, "TPS Card disabled or missing", COLORS.muted, COLORS.panelBg)
    end

    -- Card 4: Exports & Mesh Status (x=120, w=39)
    self:drawFrame(120, 5, 39, 8, COLORS.border, COLORS.panelBg, "round")
    self:drawText(122, 5, " ◈ HUB, BRIDGE & OC MESH ", COLORS.accent, COLORS.panelBg)
    local peerOnline = 0
    local peerMap = {
        { key = "dtpf", win = 60 },
        { key = "pump", win = 180 },
        { key = "univ", win = 60 },
        { key = "gorge", win = 60 },
    }
    for _, pm in ipairs(peerMap) do
        local p = peers[pm.key]
        if p and p.addr and (now - (p.lastSeen or -1000)) < pm.win then
            peerOnline = peerOnline + 1
        end
    end
    self:drawText(122, 7, padOrTrunc(string.format("Exporter   : %s (mode=%s)",
        self.cfg.exportPaused and "PAUSED" or "ACTIVE", tostring(self.cfg.allItemsMode or 0)), 35),
        self.cfg.exportPaused and COLORS.yellow or COLORS.green, COLORS.panelBg)
    self:drawText(122, 8, padOrTrunc(string.format("TCP Bridge : %s",
        not self.cfg.enableBridge and "Disabled" or (hub.bridgeConnected and "Connected" or "Connecting")), 35),
        hub.bridgeConnected and COLORS.green or COLORS.muted, COLORS.panelBg)
    self:drawText(122, 9, padOrTrunc(string.format("Mesh Peers : %d / 4 online (p:%d)",
        peerOnline, tonumber(self.cfg.meshPort) or 4205), 35),
        peerOnline > 0 and COLORS.cyan or COLORS.muted, COLORS.panelBg)
    self:drawText(122, 11, padOrTrunc(string.format("Last Scan  : %.2fs | AE Items:%d",
        tonumber(hub.lastScanDurSec) or 0, tonumber(hub.lastItemsCount) or 0), 35), COLORS.muted, COLORS.panelBg)

    -- Bottom Left: Active Crafting CPUs (x=2, y=14, w=78, h=34)
    self:drawFrame(2, 14, 78, 34, COLORS.border, COLORS.panelBg, "round")
    self:drawText(4, 14, " ◈ BUSY CRAFTING CPUs ", COLORS.accent, COLORS.panelBg)
    self:drawButton(67, 14, "[All CPUs]", COLORS.cyan, COLORS.btnBg, function()
        self.tab = TAB_CPUS
    end)

    local cpuList = cpus.list or {}
    local busyRows = {}
    for _, c in ipairs(cpuList) do
        if c.busy then busyRows[#busyRows + 1] = c end
    end
    if #busyRows == 0 then
        self:drawText(4, 17, string.format("All %d Crafting CPUs are currently IDLE.", tonumber(cpus.total) or #cpuList), COLORS.muted, COLORS.panelBg)
    else
        self:drawText(4, 16, padOrTrunc(string.format("%-14s %-34s %-12s %s", "CPU", "Crafting Output", "Count", "Stor/Co"), 74), COLORS.muted, COLORS.panelBg)
        self:drawText(4, 17, string.rep("─", 74), COLORS.border, COLORS.panelBg)
        for idx = 1, math.min(12, #busyRows) do
            local c = busyRows[idx]
            local ry = 17 + idx * 2
            local bg = (idx % 2 == 0) and COLORS.rowAltBg or COLORS.panelBg
            self:fillRect(3, ry, 76, 1, " ", COLORS.fg, bg)
            local rowTxt = string.format("%-14s %-34s %-12s %s/%d",
                padOrTrunc(c.name or "CPU", 14),
                padOrTrunc(c.craftingItem or "Working...", 34),
                UI.formatNumber(c.craftingCount or 0),
                UI.formatNumber(c.storage or 0),
                tonumber(c.coprocessors) or 0)
            self:drawButton(4, ry, padOrTrunc(rowTxt, 74), COLORS.fg, bg, function()
                self.tab = TAB_CPUS
            end)
        end
    end

    -- Bottom Right: Live Activity Log (x=81, y=14, w=78, h=34)
    self:drawFrame(81, 14, 78, 34, COLORS.border, COLORS.panelBg, "round")
    self:drawText(83, 14, " ◈ LIVE ACTIVITY & EXPORT LOG ", COLORS.accent, COLORS.panelBg)
    local logs = hub.logs or {}
    local visLog = 29
    local maxScroll = math.max(0, #logs - visLog)
    self.logScroll = math.max(0, math.min(maxScroll, self.logScroll))
    if #logs == 0 then
        self:drawText(83, 17, "Waiting for first export / mesh event...", COLORS.muted, COLORS.panelBg)
    else
        for i = 1, math.min(visLog, #logs - self.logScroll) do
            local e = logs[#logs - (self.logScroll + i - 1)]
            if type(e) == "table" then
                local col = (e.tag == "ERR") and COLORS.red
                    or ((e.tag == "WRN") and COLORS.yellow
                    or ((e.tag == "MESH") and COLORS.cyan
                    or ((e.tag == "OUT") and COLORS.green or COLORS.fg)))
                local line = string.format("[%s] %.0fs %s", tostring(e.tag or "LOG"), tonumber(e.t) or 0, tostring(e.msg or ""))
                self:drawText(83, 15 + i, padOrTrunc(line, 74), col, COLORS.panelBg)
            end
        end
    end
end

function UI:renderCpusTab()
    local cpus = (self.hub and self.hub.cpus) or {}
    local rawList = cpus.list or {}
    local rows = {}
    for _, c in ipairs(rawList) do
        if (not self.cpuBusyOnly) or c.busy then
            rows[#rows + 1] = c
        end
    end

    self:drawFrame(2, 5, 157, 43, COLORS.border, COLORS.panelBg, "round")
    self:drawText(4, 5, string.format(" ◈ MAINNET CRAFTING CPUs (%d busy / %d total) ",
        tonumber(cpus.busyCount) or 0, tonumber(cpus.total) or #rawList), COLORS.accent, COLORS.panelBg)

    local fx = 55
    fx = self:drawButton(fx, 5, self.cpuBusyOnly and "[Filter: BUSY ONLY]" or "[Filter: ALL CPUs ]",
        self.cpuBusyOnly and COLORS.cyan or COLORS.fg, COLORS.btnBg, function()
            self.cpuBusyOnly = not self.cpuBusyOnly
            self.cpuScroll = 0
            self.confirmCancelCpu = nil
        end) + 2

    local maxShow = 18
    local maxScroll = math.max(0, #rows - maxShow)
    self.cpuScroll = math.max(0, math.min(maxScroll, self.cpuScroll))

    fx = self:drawButton(fx, 5, "[Prev Page]", self.cpuScroll > 0 and COLORS.fg or COLORS.muted, COLORS.btnBg, function()
        self.cpuScroll = math.max(0, self.cpuScroll - maxShow)
        self.confirmCancelCpu = nil
    end) + 1
    self:drawButton(fx, 5, "[Next Page]", self.cpuScroll < maxScroll and COLORS.fg or COLORS.muted, COLORS.btnBg, function()
        self.cpuScroll = math.min(maxScroll, self.cpuScroll + maxShow)
        self.confirmCancelCpu = nil
    end)

    self:drawText(4, 7, padOrTrunc(string.format("%-4s %-18s %-11s %-9s %-10s %-46s %-14s %s",
        "#", "CPU Name", "Storage", "Co-Procs", "Status", "Active Craft Output", "Amount", "Control"), 152), COLORS.muted, COLORS.panelBg)
    self:drawText(4, 8, string.rep("─", 152), COLORS.border, COLORS.panelBg)

    if #rows == 0 then
        self:drawText(4, 11, self.cpuBusyOnly and "No busy CPUs right now." or "No Crafting CPUs reported by AE2 interface.", COLORS.muted, COLORS.panelBg)
        return
    end

    local prevConfirm = self.confirmCancelCpu
    for i = 1, math.min(maxShow, #rows - self.cpuScroll) do
        local idx = self.cpuScroll + i
        local c = rows[idx]
        local ry = 8 + i * 2
        local bg = (i % 2 == 0) and COLORS.rowAltBg or COLORS.panelBg
        self:fillRect(3, ry, 155, 1, " ", COLORS.fg, bg)

        local stCol = c.busy and COLORS.green or COLORS.muted
        local stStr = c.busy and "CRAFTING" or "IDLE"
        local outStr = c.busy and (c.craftingItem or "Working...") or "-"
        local amtStr = c.busy and UI.formatNumber(c.craftingCount or 0) or "-"

        local textPart = string.format("%-4d %-18s %-11s %-9d %-10s %-46s %-14s",
            idx, padOrTrunc(c.name or ("CPU #" .. idx), 18), UI.formatNumber(c.storage or 0),
            tonumber(c.coprocessors) or 0, stStr, padOrTrunc(outStr, 46), amtStr)
        self:drawText(4, ry, textPart, c.busy and COLORS.fg or COLORS.muted, bg)
        self:drawText(44, ry, padOrTrunc(stStr, 10), stCol, bg)

        if c.busy then
            local cpuName = c.name or ""
            local isConfirm = (prevConfirm == cpuName)
            self:drawButton(125, ry, isConfirm and "[Confirm Cancel?]" or "[Cancel Craft]",
                isConfirm and COLORS.fg or COLORS.yellow,
                isConfirm and COLORS.darkRed or COLORS.btnBg,
                function()
                    if prevConfirm == cpuName then
                        self.confirmCancelCpu = nil
                        if self.cb.onCancelCpu then
                            local okC, msgC = self.cb.onCancelCpu(cpuName)
                            self.statusMsg = tostring(msgC or (okC and ("Canceled " .. cpuName) or "Cancel failed"))
                        end
                    else
                        self.confirmCancelCpu = cpuName
                        self.statusMsg = "Click [Confirm Cancel?] again to abort job on " .. cpuName .. "."
                    end
                end, "cancel")
        else
            self:drawText(125, ry, "[Idle]", COLORS.muted, bg)
        end
    end
end

function UI:renderMeshPeerCard(x, y, cw, ch, title, peerKey, peer, winSec, renderBodyFn)
    self:drawFrame(x, y, cw, ch, COLORS.border, COLORS.panelBg, "round")
    self:drawText(x + 2, y, " ◈ " .. title .. " ", COLORS.accent, COLORS.panelBg)

    local now = tonumber(self.hub.nowUptime) or 0
    local fresh = peer and peer.addr ~= nil and (now - (peer.lastSeen or -1000)) < winSec
    local badge = fresh and ("ONLINE (" .. UI.formatAge(now, peer.lastSeen) .. ")") or "OFFLINE"
    local bCol = fresh and COLORS.green or COLORS.red
    self:drawText(x + cw - #badge - 3, y, " " .. badge .. " ", bCol, COLORS.panelBg)

    local bx = x + 3
    bx = self:drawButton(bx, y + ch - 3, "[Pause]", COLORS.yellow, COLORS.btnBg, function()
        if self.cb.onPeerAction then
            self.statusMsg = tostring(self.cb.onPeerAction(peerKey, "pause") or ("Sent Pause -> " .. peerKey))
        end
    end) + 2
    bx = self:drawButton(bx, y + ch - 3, "[Resume]", COLORS.green, COLORS.btnBg, function()
        if self.cb.onPeerAction then
            self.statusMsg = tostring(self.cb.onPeerAction(peerKey, "resume") or ("Sent Resume -> " .. peerKey))
        end
    end) + 2
    self:drawButton(bx, y + ch - 3, "[Poll]", COLORS.cyan, COLORS.btnBg, function()
        if self.cb.onPeerAction then
            self.statusMsg = tostring(self.cb.onPeerAction(peerKey, "poll") or ("Polled " .. peerKey))
        end
    end)

    local st = peer and peer.status or nil
    if type(st) ~= "table" then
        self:drawText(x + 3, y + 3, peer and peer.addr and "Peer seen; waiting for telemetry packet..." or "No telemetry received on OC Mesh yet.", COLORS.muted, COLORS.panelBg)
        return
    end
    renderBodyFn(st, x + 3, y + 2, cw - 6)
end

function UI:renderMeshTab()
    local peers = (self.hub and self.hub.peers) or {}

    -- Card 1: DTPF Fleet (x=2, y=5, w=77, h=21)
    self:renderMeshPeerCard(2, 5, 77, 21, "DTPF FLEET CONTROLLER", "dtpf", peers.dtpf, 60, function(st, bx, by, bw)
        local units = type(st.units) == "table" and st.units or {}
        local onN, actN = 0, 0
        for _, u in ipairs(units) do
            if type(u) == "table" then
                if u.online then onN = onN + 1 end
                if u.active then actN = actN + 1 end
            end
        end
        self:drawText(bx, by, string.format("Armed: %-5s  Units: %d online / %d active (%d total)  OD: %s",
            tostring(st.armed == true), onN, actN, #units, st.odActive and "YES" or "NO"),
            st.armed and COLORS.green or COLORS.yellow, COLORS.panelBg)
        self:drawText(bx, by + 2, padOrTrunc(string.format("Total EU/t: %s   Direct: %s   Cat: %s   DTR: %s",
            UI.formatNumber(st.totalEut or 0), UI.formatNumber(st.directEut or 0),
            UI.formatNumber(st.catEut or 0), UI.formatNumber(st.dtrStock or 0)), bw), COLORS.cyan, COLORS.panelBg)
        for i = 1, math.min(10, #units) do
            local u = units[i]
            if type(u) == "table" then
                local line = string.format("  %-12s %-7s Disc:%4.1f%% Heat:%s %s",
                    padOrTrunc(u.name or ("DTPF#" .. i), 12),
                    u.active and "ACTIVE" or (u.online and "IDLE" or "OFF"),
                    tonumber(u.discountPct) or 0, UI.formatNumber(u.coilHeat or 0),
                    padOrTrunc(u.familyId or "idle", 18))
                self:drawText(bx, by + 3 + i, padOrTrunc(line, bw), u.active and COLORS.green or COLORS.fg, COLORS.panelBg)
            end
        end
    end)

    -- Card 2: Space Pump Array (x=81, y=5, w=78, h=21)
    self:renderMeshPeerCard(81, 5, 78, 21, "SPACE PUMP ARRAY", "pump", peers.pump, 180, function(st, bx, by, bw)
        local pumps = type(st.pumps) == "table" and st.pumps or {}
        local actN, multSum = 0, 0
        for _, p in ipairs(pumps) do
            if type(p) == "table" then
                if p.active then actN = actN + 1 end
                multSum = multSum + (tonumber(p.mult) or 0)
            end
        end
        local flOk, flLow, flRows = 0, 0, {}
        local thresh = tonumber(st.threshold) or 0.95
        for k, fl in pairs(type(st.fluids) == "table" and st.fluids or {}) do
            if type(fl) == "table" and (tonumber(fl.target) or 0) > 0 then
                local eff = tonumber(fl.total) or ((tonumber(fl.meAmount) or 0) + (tonumber(fl.queued) or 0))
                local ok = eff >= (thresh * tonumber(fl.target))
                if ok then flOk = flOk + 1 else flLow = flLow + 1 end
                flRows[#flRows + 1] = { label = fl.label or tostring(k), eff = eff, target = tonumber(fl.target), ok = ok }
            end
        end
        table.sort(flRows, function(a, b) return a.label < b.label end)
        self:drawText(bx, by, string.format("Paused: %-5s  Pumps: %d/%d active  Total Mult: %d",
            tostring(st.paused == true), actN, #pumps, multSum),
            st.paused and COLORS.yellow or COLORS.green, COLORS.panelBg)
        self:drawText(bx, by + 2, string.format("Managed Fluids: %d OK  |  %d Low (thresh %.0f%%)",
            flOk, flLow, thresh * 100), flLow > 0 and COLORS.yellow or COLORS.cyan, COLORS.panelBg)
        for i = 1, math.min(10, #flRows) do
            local r = flRows[i]
            self:drawText(bx, by + 3 + i, padOrTrunc(string.format("  %-24s %s / %s",
                r.label, UI.formatNumber(r.eff), UI.formatNumber(r.target)), bw),
                r.ok and COLORS.fg or COLORS.yellow, COLORS.panelBg)
        end
    end)

    -- Card 3: Universal RS Controller (x=2, y=27, w=77, h=21)
    self:renderMeshPeerCard(2, 27, 77, 21, "UNIVERSAL RS CONTROLLER", "univ", peers.univ, 60, function(st, bx, by, bw)
        self:drawText(bx, by, string.format("Armed: %-5s  Active Pools: %d  Queued: %d  Stalled: %d",
            tostring(st.armed == true), tonumber(st.activePools) or 0,
            tonumber(st.queuedSlices) or 0, tonumber(st.stalledCount) or 0),
            (tonumber(st.stalledCount) or 0) > 0 and COLORS.yellow or (st.armed and COLORS.green or COLORS.muted), COLORS.panelBg)
        self:drawText(bx, by + 2, string.format("Completed Batches: %d   Preemptions: %d",
            tonumber(st.completedBatches) or 0, tonumber(st.preemptions) or 0), COLORS.cyan, COLORS.panelBg)
        local pools = type(st.pools) == "table" and st.pools or {}
        for i = 1, math.min(10, #pools) do
            local p = pools[i]
            if type(p) == "table" then
                local line = string.format("  Pool %-14s %-8s %s",
                    padOrTrunc(p.name or ("#" .. i), 14), tostring(p.phase or "IDLE"),
                    padOrTrunc(p.activeLabel or p.activeItem or "-", 28))
                self:drawText(bx, by + 3 + i, padOrTrunc(line, bw), COLORS.fg, COLORS.panelBg)
            end
        end
    end)

    -- Card 4: Gorge & Exoticizer Rack (x=81, y=27, w=78, h=21)
    self:renderMeshPeerCard(81, 27, 78, 21, "GORGE & EXOTICIZER RACK", "gorge", peers.gorge, 60, function(st, bx, by, bw)
        local gf = type(st.godforge) == "table" and st.godforge or {}
        self:drawText(bx, by, string.format("Armed: %-5s  Active Ex: %d  Cycles: %d  Errors: %d",
            tostring(st.armed == true), tonumber(st.activeCount) or 0,
            tonumber(st.completedCycles) or 0, tonumber(st.errorCount) or 0),
            (tonumber(st.errorCount) or 0) > 0 and COLORS.red or (st.armed and COLORS.green or COLORS.muted), COLORS.panelBg)
        self:drawText(bx, by + 2, padOrTrunc(string.format("Godforge: %s  Rings:%s  Conn:%s  LSC:%s",
            gf.active and "ACTIVE" or (gf.workAllowed == false and "HOLD" or "IDLE"),
            tostring(gf.rings or "-"), tostring(gf.connected or "-"),
            st.lscPct and string.format("%.1f%%", st.lscPct) or "--"), bw), COLORS.cyan, COLORS.panelBg)
        local exs = type(st.exoticizers) == "table" and st.exoticizers or {}
        for i = 1, math.min(10, #exs) do
            local ex = exs[i]
            if type(ex) == "table" then
                local line = string.format("  %-14s %-9s %-10s Cycles:%d %s",
                    padOrTrunc(ex.name or ("Ex#" .. i), 14), tostring(ex.activeMode or ex.mode or "?"),
                    tostring(ex.phase or "IDLE"), tonumber(ex.cycles) or 0,
                    ex.lastError and ("[" .. ex.lastError .. "]") or "")
                self:drawText(bx, by + 3 + i, padOrTrunc(line, bw),
                    ex.lastError and COLORS.red or ((ex.phase == "WAIT_END") and COLORS.green or COLORS.fg), COLORS.panelBg)
            end
        end
    end)
end

function UI:renderSetupTab()
    -- Left Card: Live Exporter Feature Toggles
    self:drawFrame(2, 5, 77, 43, COLORS.border, COLORS.panelBg, "round")
    self:drawText(4, 5, " ◈ INFLUXDB STREAM & FEATURE TOGGLES ", COLORS.accent, COLORS.panelBg)

    local toggles = {
        { key = "enableItems",     lbl = "Export Items Stream" },
        { key = "enableFluids",    lbl = "Export Fluids Stream" },
        { key = "enableEssentia",  lbl = "Export Essentia Stream" },
        { key = "enableEnergy",    lbl = "Export LSC Energy Grid" },
        { key = "enableWireless",  lbl = "Export Wireless EU" },
        { key = "enableEnergyAE2", lbl = "Export AE2 Power Grid" },
        { key = "enableCpus",      lbl = "Export Crafting CPUs" },
        { key = "enableTps",       lbl = "Export Server TPS / MSPT" },
        { key = "detailedTps",     lbl = "Detailed Per-Dim MSPT" },
        { key = "enableBridge",    lbl = "Out-of-Game TCP Bridge" },
        { key = "enableMesh",      lbl = "OC Wireless/Tunnel Mesh" },
        { key = "enableLogging",   lbl = "Activity Console Logs" },
        { key = "enableDebug",     lbl = "Verbose Line Debug" },
    }
    for i, tg in ipairs(toggles) do
        local ry = 6 + i * 2
        local val = (self.cfg[tg.key] == true)
        self:drawText(4, ry, padOrTrunc(tg.lbl .. ":", 30), COLORS.fg, COLORS.panelBg)
        self:drawButton(38, ry, val and "[ ON ]" or "[OFF ]",
            val and COLORS.fg or COLORS.muted,
            val and COLORS.darkGreen or COLORS.btnBg,
            function()
                local nextV = not val
                if self.cb.onConfigChanged then
                    self.cb.onConfigChanged("toggle", tg.key, nextV)
                else
                    self.cfg[tg.key] = nextV
                end
                self.statusMsg = string.format("%s -> %s (saved override)", tg.key, tostring(nextV))
            end)
    end

    local ay = 40
    self:drawButton(4, ay, "[Force Scan Now]", COLORS.cyan, COLORS.btnBg, function()
        if self.cb.onScanNow then self.cb.onScanNow() end
        self.statusMsg = "Forced full scan now."
    end)
    self:drawButton(24, ay, "[Reset Overrides]", COLORS.yellow, COLORS.amberBg, function()
        if self.cb.onResetOverrides then
            self.statusMsg = tostring(self.cb.onResetOverrides() or "Overrides cleared.")
        end
    end)
    self:drawText(4, 43, "Changes save immediately to /home/config_overrides.lua (survives updates).", COLORS.muted, COLORS.panelBg)

    -- Right Card: Polling Intervals (Seconds)
    self:drawFrame(81, 5, 78, 43, COLORS.border, COLORS.panelBg, "round")
    self:drawText(83, 5, " ◈ POLLING INTERVALS (SECONDS) ", COLORS.accent, COLORS.panelBg)

    local secTbl = self.cfg._sec or {}
    local intervals = {
        { key = "itemInterval",     lbl = "Item Stock Scan (s)",    step = 5,  min = 5,  max = 3600 },
        { key = "fluidInterval",    lbl = "Fluid Stock Scan (s)",   step = 5,  min = 5,  max = 3600 },
        { key = "essentiaInterval", lbl = "Essentia Scan (s)",      step = 5,  min = 5,  max = 3600 },
        { key = "energyInterval",   lbl = "LSC Energy Poll (s)",    step = 2,  min = 2,  max = 600 },
        { key = "energyAE2Interval",lbl = "AE2 Power Poll (s)",     step = 2,  min = 2,  max = 600 },
        { key = "cpuInterval",      lbl = "Crafting CPUs Poll (s)", step = 2,  min = 2,  max = 600 },
        { key = "tpsInterval",      lbl = "Server TPS Poll (s)",    step = 1,  min = 1,  max = 300 },
        { key = "allItemsInterval", lbl = "Full Item ID Refresh(s)",step = 60, min = 60, max = 7200 },
    }
    for i, iv in ipairs(intervals) do
        local ry = 7 + (i - 1) * 3
        local curSec = tonumber(secTbl[iv.key])
        if not curSec then
            curSec = math.max(iv.min, math.floor(((tonumber(self.cfg[iv.key]) or (iv.min * 72)) / 72) + 0.5))
        end
        self:drawText(83, ry, padOrTrunc(iv.lbl .. ":", 27), COLORS.fg, COLORS.panelBg)
        self:drawText(112, ry, string.format("%5ds", curSec), COLORS.cyan, COLORS.panelBg)
        self:drawButton(120, ry, "[-]", COLORS.yellow, COLORS.btnBg, function()
            local nxtS = math.max(iv.min, curSec - iv.step)
            if self.cb.onConfigChanged then
                self.cb.onConfigChanged("interval", iv.key, nxtS)
            else
                secTbl[iv.key] = nxtS
                self.cfg[iv.key] = nxtS * 72
            end
            self.statusMsg = string.format("%s -> %ds (%d ticks)", iv.key, nxtS, nxtS * 72)
        end)
        self:drawButton(125, ry, "[+]", COLORS.green, COLORS.btnBg, function()
            local nxtS = math.min(iv.max, curSec + iv.step)
            if self.cb.onConfigChanged then
                self.cb.onConfigChanged("interval", iv.key, nxtS)
            else
                secTbl[iv.key] = nxtS
                self.cfg[iv.key] = nxtS * 72
            end
            self.statusMsg = string.format("%s -> %ds (%d ticks)", iv.key, nxtS, nxtS * 72)
        end)
    end

    self:drawText(83, 35, "Endpoints & Mode Info:", COLORS.accent, COLORS.panelBg)
    self:drawText(83, 37, padOrTrunc("InfluxDB : " .. tostring(self.cfg.dbHostname or "none"), 72), COLORS.muted, COLORS.panelBg)
    self:drawText(83, 39, padOrTrunc(string.format("Bridge   : %s:%s", tostring(self.cfg.bridgeHost or "127.0.0.1"), tostring(self.cfg.bridgePort or 8766)), 72), COLORS.muted, COLORS.panelBg)
    self:drawText(83, 41, padOrTrunc(string.format("allItemsMode=%s   maxID=%s   batchSize=%s",
        tostring(self.cfg.allItemsMode or 0), tostring(self.cfg.maxID or 0), tostring(self.cfg.batchSize or 0)), 72), COLORS.muted, COLORS.panelBg)
end

function UI:renderLogModal()
    if not self.logModalActive then return end
    self.hitboxes = {}
    local mx, my, mw, mh = 10, 4, 140, 42
    self:drawFrame(mx, my, mw, mh, COLORS.accent, COLORS.headerBg, "double")
    self:drawText(mx + 2, my, " ◈ MAINNET AE2 & MESH ACTIVITY LOG ", COLORS.accent, COLORS.headerBg)
    self:drawButton(mx + mw - 10, my + 1, "[Close]", COLORS.red, COLORS.btnBg, function()
        self.logModalActive = false
    end)

    local list = (self.hub and self.hub.logs) or {}
    local maxLines = mh - 5
    local maxScroll = math.max(0, #list - maxLines)
    self.logModalScroll = math.max(0, math.min(maxScroll, self.logModalScroll or 0))
    for i = 1, math.min(maxLines, #list - self.logModalScroll) do
        local e = list[#list - (self.logModalScroll + i - 1)]
        if type(e) == "table" then
            local col = (e.tag == "ERR") and COLORS.red
                or ((e.tag == "WRN") and COLORS.yellow
                or ((e.tag == "MESH") and COLORS.cyan
                or ((e.tag == "OUT") and COLORS.green or COLORS.fg)))
            local txt = string.format("[%s] %.1fs %s", tostring(e.tag or "LOG"), tonumber(e.t) or 0, tostring(e.msg or ""))
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
    elseif self.tab == TAB_CPUS then
        self:renderCpusTab()
    elseif self.tab == TAB_MESH then
        self:renderMeshTab()
    elseif self.tab == TAB_SETUP then
        self:renderSetupTab()
    end

    self:drawText(1, self.h - 1, string.rep("─", self.w), COLORS.border, COLORS.bg)
    self:drawText(2, self.h, padOrTrunc(self.statusMsg or "", self.w - 60), COLORS.fg, COLORS.bg)
    self:drawText(self.w - 57, self.h, "Keys: 1-4 Tabs | S Scan | P Ping | L Log | R Reset | Q Quit", COLORS.muted, COLORS.bg)

    self:renderLogModal()
    self:flush()
end

function UI:handleTouch(x, y, _button)
    local hit = nil
    for i = #self.hitboxes, 1, -1 do
        local hb = self.hitboxes[i]
        if x >= hb.x1 and x <= hb.x2 and y >= hb.y1 and y <= hb.y2 then
            hit = hb
            break
        end
    end
    if not hit then
        if self.confirmCancelCpu then
            self.confirmCancelCpu = nil
            self:render()
            return true
        end
        return false
    end
    if hit.kind ~= "cancel" then
        self.confirmCancelCpu = nil
    end
    hit.fn()
    if self.running then self:render() end
    return true
end

function UI:handleScroll(dir)
    local delta = (dir > 0) and -2 or 2
    if self.logModalActive then
        self.logModalScroll = math.max(0, (self.logModalScroll or 0) + delta)
    elseif self.tab == TAB_OVERVIEW then
        self.logScroll = math.max(0, (self.logScroll or 0) + delta)
    elseif self.tab == TAB_CPUS then
        self.cpuScroll = math.max(0, (self.cpuScroll or 0) + delta)
    end
    self:render()
end

function UI:handleKeyDown(char, _code)
    if char == 113 or char == 81 then -- 'q'/'Q'
        self.running = false
    elseif char == 49 then self.tab = TAB_OVERVIEW; self.confirmCancelCpu = nil
    elseif char == 50 then self.tab = TAB_CPUS; self.confirmCancelCpu = nil
    elseif char == 51 then self.tab = TAB_MESH; self.confirmCancelCpu = nil
    elseif char == 52 then self.tab = TAB_SETUP; self.confirmCancelCpu = nil
    elseif char == 108 or char == 76 then -- 'l'/'L'
        self.logModalActive = not self.logModalActive
    elseif char == 115 or char == 83 then -- 's'/'S'
        if self.cb.onScanNow then self.cb.onScanNow() end
        self.statusMsg = "Immediate scan triggered via keyboard."
    elseif char == 112 or char == 80 then -- 'p'/'P'
        if self.cb.onMeshPing then self.cb.onMeshPing() end
        self.statusMsg = "Broadcast MESH_MAINNET_HELLO beacon."
    elseif char == 114 or char == 82 then -- 'r'/'R'
        self.confirmCancelCpu = nil
        self.logModalActive = false
    end
    if self.running then self:render() end
end

return UI
