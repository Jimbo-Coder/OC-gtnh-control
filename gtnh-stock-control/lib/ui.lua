-- /home/stock/lib/ui.lua
-- 160x50 Tier 3 Touch Control Center for Mainnet AE2 Stock Maintainer.
-- Uses 64-bit packed integer screen buffers (zero per-cell string allocations) and strictly width-1 glyphs.

local component = require("component")
local unicode = require("unicode")
local DtpfCatalog = require("lib.dtpf_catalog")
local Hardware = require("lib.hardware")
local Scheduler = require("lib.scheduler")

local UI = {}

local TAB_OVERVIEW = 1
local TAB_RULES    = 2
local TAB_ADD      = 3
local TAB_PERF     = 4

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
    if absN >= 1e12 then return string.format("%.2fT%s", n / 1e12, suf)
    elseif absN >= 1e9 then return string.format("%.2fB%s", n / 1e9, suf)
    elseif absN >= 1e6 then return string.format("%.1fM%s", n / 1e6, suf)
    elseif absN >= 1e3 then return string.format("%.1fK%s", n / 1e3, suf)
    else return string.format("%d%s", math.floor(n + 0.5), suf)
    end
end

function UI.parseNumber(raw)
    local s = tostring(raw or ""):match("^%s*(.-)%s*$"):gsub(",", ""):gsub("[lL]$", ""):upper()
    local numS, suf = s:match("^([%d%.]+)([KMBT]?)$")
    local n = tonumber(numS or "")
    if not n or n <= 0 then return nil end
    local mult = ({ [""] = 1, K = 1e3, M = 1e6, B = 1e9, T = 1e12 })[suf or ""] or 1
    return math.max(1, math.floor(n * mult))
end

function UI.new(cfg, state, onSave, compLib, extras)
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
        state = state or {},
        onSave = onSave,
        extras = extras or {},
        comp = cl,
        gpu = gpu,
        w = w,
        h = h,
        tab = TAB_OVERVIEW,
        running = true,
        filterKind = "ALL", -- ALL | LOW | CRAFT | ERR | WARN | OFF | ITEMS | FLUIDS
        filterGroup = "ALL",
        searchQuery = "",
        sortMode = "state", -- state | name | pct | prio
        rulesScroll = 0,
        importScroll = 0,
        editRuleId = nil,
        numPrompt = nil, -- { title, buf, onApply, isNumeric }
        logModalActive = false,
        logModalScroll = 0,
        dropDraft = { target = 1024, lowPct = 100, batch = 256, priority = 3, group = "General" },
        statusMsg = "Ready. Press [PAUSED] or Space to arm Mainnet Stock Maintainer.",
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

function UI:save(msg)
    if msg then self.statusMsg = msg end
    if self.onSave then pcall(self.onSave, self.cfg) end
end

function UI:clearNextBuffer(bg, fg)
    local v = packColorMask(fg or COLORS.fg, bg or COLORS.bg) | 32
    local nb = self.nxtBuf
    for i = 1, self.w * self.h do
        nb[i] = v
    end
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
    self.hitboxes[#self.hitboxes + 1] = { x1 = x1, y1 = y1, x2 = x2, y2 = y2, fn = fn, kind = kind or "btn" }
end

function UI:drawButton(x, y, label, fg, bg, fn, kind)
    local w = unicode.wlen(label)
    self:drawText(x, y, label, fg or COLORS.fg, bg or COLORS.btnBg)
    if fn then self:addHitbox(x, y, x + w - 1, y, fn, kind) end
    return x + w
end

function UI:drawProgressBar(x, y, width, pct, fgFill, fgEmpty, bg)
    pct = math.max(0, math.min(100, tonumber(pct) or 0))
    local filled = math.floor((pct / 100.0) * width + 0.5)
    for i = 1, width do
        if i <= filled then
            self:drawText(x + i - 1, y, "█", fgFill or COLORS.green, bg)
        else
            self:drawText(x + i - 1, y, "░", fgEmpty or COLORS.border, bg)
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

function UI:getRuleStatusMap()
    local m = {}
    for _, rs in ipairs((self.state and self.state.ruleStatuses) or {}) do
        if rs and rs.id then m[rs.id] = rs end
    end
    return m
end

function UI:renderHeader()
    local armed = (self.cfg.armed == true)
    local k = (self.state and self.state.kpis) or {}
    local p = (self.state and self.state.perf) or {}

    self:fillRect(1, 1, self.w, 2, " ", COLORS.fg, COLORS.headerBg)
    self:drawText(2, 1, "◈ GTNH STOCK MAINTAINER", COLORS.accent, COLORS.headerBg)

    local bx = self:drawButton(27, 1, armed and "[● ARMED: AUTO]" or "[○ PAUSED: SAFE]",
        armed and COLORS.fg or COLORS.yellow,
        armed and COLORS.darkGreen or COLORS.amberBg,
        function()
            self.cfg.armed = not armed
            if self.state then self.state._forcePollNow = true end
            self:save(self.cfg.armed and "Stock Maintainer ARMED." or "Stock Maintainer PAUSED.")
        end) + 2

    local summary = string.format("AE:%s  Rules:%d(%d on)  Low:%d  Craft:%d  Err:%d  Warn:%d  CPUs:%d/%d  %.1fms",
        tostring(k.aeLink or "none"), k.total or 0, k.enabled or 0, k.low or 0,
        k.crafting or 0, k.errors or 0, k.warnings or 0,
        k.freeCpus or 0, k.totalCpus or 0, tonumber(p.lastCycleMs) or 0)
    self:drawText(bx, 1, padOrTrunc(summary, self.w - bx - 36), COLORS.muted, COLORS.headerBg)

    local rx = self.w - 35
    rx = self:drawButton(rx, 1, "[↻ Poll]", COLORS.cyan, COLORS.btnBg, function()
        if self.state then self.state._forcePollNow = true end
        Scheduler.step(self.cfg, self.state, nil, self.comp, { forceFull = true })
        self.statusMsg = "Full O(1) stock & CPU refresh completed."
    end) + 1
    rx = self:drawButton(rx, 1, "[Retry Err]", COLORS.yellow, COLORS.btnBg, function()
        local n = Scheduler.clearBackoffs(self.state)
        if self.state then self.state._forcePollNow = true end
        self.statusMsg = string.format("Cleared %d rule backoff(s).", n)
    end) + 1
    rx = self:drawButton(rx, 1, "[Log]", COLORS.fg, COLORS.btnBg, function()
        self.logModalActive = true
        self.logModalScroll = 0
    end) + 1
    self:drawButton(rx, 1, "[Quit]", COLORS.red, COLORS.btnBg, function()
        self.running = false
    end)

    local tabs = {
        { id = TAB_OVERVIEW, label = "[1] OVERVIEW" },
        { id = TAB_RULES,    label = "[2] RULES" },
        { id = TAB_ADD,      label = "[3] ADD & IMPORT" },
        { id = TAB_PERF,     label = "[4] PERF & SETUP" },
    }
    local tx = 2
    for _, tb in ipairs(tabs) do
        local act = (self.tab == tb.id)
        tx = self:drawButton(tx, 2, tb.label,
            act and COLORS.fg or COLORS.muted,
            act and COLORS.btnActiveBg or COLORS.headerBg,
            function()
                self.tab = tb.id
                self.rulesScroll = 0
                self.importScroll = 0
                if tb.id == TAB_ADD then
                    self.state.dropPreview = Hardware.readDropSlot(self.cfg, self.comp, self.state)
                end
            end) + 2
    end

    local dtpfOn = (self.state and self.state.dtpfPeer ~= nil)
    local extStr = (self.cfg.extLinkMode == "off") and "Ext:Standalone"
        or (dtpfOn and "Mesh:ON | DTPF:OK" or "Mesh:ON | DTPF:--")
    self:drawText(self.w - 30, 2, padOrTrunc(extStr, 29), dtpfOn and COLORS.green or COLORS.muted, COLORS.headerBg)
    self:drawText(1, 3, string.rep("─", self.w), COLORS.border, COLORS.bg)
end

function UI:renderOverviewTab()
    local k = (self.state and self.state.kpis) or {}
    local p = (self.state and self.state.perf) or {}
    local armed = (self.cfg.armed == true)

    -- 4 KPI Cards across y=5..12
    self:drawFrame(2, 5, 38, 8, COLORS.border, COLORS.panelBg, "round")
    self:drawText(4, 5, " ◈ SYSTEM & AE2 LINK ", COLORS.accent, COLORS.panelBg)
    self:drawText(4, 7, "Mode : " .. (armed and "ARMED (Auto-Crafting)" or "PAUSED (Read-Only)"),
        armed and COLORS.green or COLORS.yellow, COLORS.panelBg)
    self:drawText(4, 8, padOrTrunc("AE2  : " .. tostring(k.aeLink or "none") .. " (" .. Hardware.shortAddr(k.aeAddr) .. ")", 34),
        k.aeLink == "adapter" and COLORS.cyan or COLORS.red, COLORS.panelBg)
    self:drawText(4, 9, padOrTrunc(string.format("O(1) : Item=%s Fluid=%s Craft=%s",
        (self.state.discovery and self.state.discovery.hasO1Item) and "Y" or "N",
        (self.state.discovery and self.state.discovery.hasO1Fluid) and "Y" or "N",
        (self.state.discovery and self.state.discovery.hasO1Craftable) and "Y" or "N"), 34), COLORS.muted, COLORS.panelBg)
    self:drawText(4, 11, padOrTrunc("DTPF Warn: " .. tostring(self.cfg.dtpfWarnMode or "warn"), 34), COLORS.fg, COLORS.panelBg)

    self:drawFrame(41, 5, 38, 8, COLORS.border, COLORS.panelBg, "round")
    self:drawText(43, 5, " ◈ MAINTAINER RULES ", COLORS.accent, COLORS.panelBg)
    self:drawText(43, 7, string.format("Total: %-4d  Enabled: %-4d", k.total or 0, k.enabled or 0), COLORS.fg, COLORS.panelBg)
    self:drawText(43, 8, string.format("OK: %-5d    Low: %-5d", k.ok or 0, k.low or 0),
        (k.low or 0) > 0 and COLORS.yellow or COLORS.green, COLORS.panelBg)
    self:drawText(43, 9, string.format("Craft: %-4d  Err: %-4d  Warn: %-3d", k.crafting or 0, k.errors or 0, k.warnings or 0),
        (k.errors or 0) > 0 and COLORS.red or COLORS.cyan, COLORS.panelBg)
    local okPct = ((k.enabled or 0) > 0) and (((k.ok or 0) / math.max(1, k.enabled or 1)) * 100.0) or 100.0
    self:drawProgressBar(43, 11, 34, okPct, COLORS.green, COLORS.border, COLORS.panelBg)

    self:drawFrame(80, 5, 39, 8, COLORS.border, COLORS.panelBg, "round")
    self:drawText(82, 5, " ◈ CPU BUDGET & RESERVE ", COLORS.accent, COLORS.panelBg)
    self:drawText(82, 7, string.format("Free CPUs : %d / %d (Reserve: %d)",
        k.freeCpus or 0, k.totalCpus or 0, tonumber(self.cfg.freeCpusReserve) or 2),
        (k.freeCpus or 0) > (tonumber(self.cfg.freeCpusReserve) or 2) and COLORS.green or COLORS.yellow, COLORS.panelBg)
    self:drawText(82, 8, string.format("Maint Jobs: %d / %d max concurrent",
        k.activeMaintCrafts or 0, tonumber(self.cfg.maxConcurrentCrafts) or 4), COLORS.cyan, COLORS.panelBg)
    self:drawText(82, 9, padOrTrunc("CPU Filter: " .. ((self.cfg.defaultCpuFilter and self.cfg.defaultCpuFilter ~= "") and self.cfg.defaultCpuFilter or "Auto (Any Free)"), 35), COLORS.muted, COLORS.panelBg)
    local cpuBusyPct = ((k.totalCpus or 0) > 0) and ((((k.totalCpus or 0) - (k.freeCpus or 0)) / math.max(1, k.totalCpus or 1)) * 100.0) or 0
    self:drawProgressBar(82, 11, 35, cpuBusyPct, COLORS.cyan, COLORS.border, COLORS.panelBg)

    self:drawFrame(120, 5, 39, 8, COLORS.border, COLORS.panelBg, "round")
    self:drawText(122, 5, " ◈ PERF & BLOCKS SAVED ", COLORS.accent, COLORS.panelBg)
    self:drawText(122, 7, string.format("Cycle Time: %.2fms (avg %.2fms)", tonumber(p.lastCycleMs) or 0, tonumber(p.avgCycleMs) or 0), COLORS.green, COLORS.panelBg)
    self:drawText(122, 8, string.format("AE Calls  : %d/cyc (%.2f/s)", tonumber(p.aeCallsLast) or 0, tonumber(p.aeCallsPerSec) or 0), COLORS.cyan, COLORS.panelBg)
    self:drawText(122, 9, string.format("OC RAM    : %dKB Lua | %dKB Free", tonumber(p.luaHeapKB) or 0, tonumber(p.freeMemKB) or 0), COLORS.muted, COLORS.panelBg)
    self:drawText(122, 11, string.format("Saved     : %d Blocks / %d AE Ch", tonumber(p.equivBlocksSaved) or 0, tonumber(p.equivChannelsSaved) or 0), COLORS.purple, COLORS.panelBg)

    -- Bottom Left: Priority Watchlist (Low / Craft / Error / Warn)
    self:drawFrame(2, 14, 96, 34, COLORS.border, COLORS.panelBg, "round")
    self:drawText(4, 14, " ◈ ACTIVE, LOW, ERROR & WARNING RULES ", COLORS.accent, COLORS.panelBg)
    self:drawButton(83, 14, "[All Rules ->]", COLORS.cyan, COLORS.btnBg, function()
        self.tab = TAB_RULES
    end)

    local watch = {}
    for _, rs in ipairs((self.state and self.state.ruleStatuses) or {}) do
        if rs.state ~= "OK" and rs.state ~= "OFF" or rs.warn then
            watch[#watch + 1] = rs
        end
    end
    if #watch == 0 then
        watch = self.state.ruleStatuses or {}
    end
    self:drawText(4, 16, padOrTrunc(string.format("%-2s %-28s %-10s %-10s %-8s %s",
        "P", "Rule", "Stock", "Target", "State", "Detail / DTPF Warning"), 92), COLORS.muted, COLORS.panelBg)
    self:drawText(4, 17, string.rep("─", 92), COLORS.border, COLORS.panelBg)
    if #watch == 0 then
        self:drawText(4, 19, "No rules yet. Open [3] ADD & IMPORT or use Web Console :8765.", COLORS.muted, COLORS.panelBg)
    else
        for i = 1, math.min(14, #watch) do
            local rs = watch[i]
            local ry = 17 + i * 2
            local bg = (i % 2 == 0) and COLORS.rowAltBg or COLORS.panelBg
            self:fillRect(3, ry, 94, 1, " ", COLORS.fg, bg)
            local isFl = (rs.type == "fluid")
            local stCol = (rs.state == "ERR" and COLORS.red)
                or (rs.state == "CRAFT" and COLORS.cyan)
                or (rs.state == "LOW" and COLORS.yellow)
                or (rs.state == "WARN" and COLORS.purple)
                or (rs.state == "OK" and COLORS.green or COLORS.muted)
            local det = rs.warn and (rs.stateDetail .. " | " .. rs.warn) or rs.stateDetail
            local line = string.format("P%d %-28s %-10s %-10s %-7s %s",
                rs.priority or 3,
                padOrTrunc(rs.label, 28),
                UI.formatNumber(rs.stock or 0, isFl and "L" or ""),
                UI.formatNumber(rs.target or 1, isFl and "L" or ""),
                rs.state,
                padOrTrunc(det, 30))
            self:drawButton(4, ry, padOrTrunc(line, 92), stCol, bg, function()
                self.editRuleId = rs.id
                self.tab = TAB_RULES
            end)
        end
    end

    -- Bottom Right: Activity Log
    self:drawFrame(99, 14, 60, 34, COLORS.border, COLORS.panelBg, "round")
    self:drawText(101, 14, " ◈ ACTIVITY LOG ", COLORS.accent, COLORS.panelBg)
    local logs = (self.state and self.state.events) or {}
    if #logs == 0 then
        self:drawText(101, 17, "Waiting for first poll / dispatch event...", COLORS.muted, COLORS.panelBg)
    else
        for i = 1, math.min(29, #logs) do
            local e = logs[i]
            local col = (e.stage == "ERR") and COLORS.red
                or ((e.stage == "WRN") and COLORS.yellow
                or ((e.stage == "OUT") and COLORS.green or COLORS.fg))
            local line = string.format("[%s] %s", tostring(e.stage or "DEC"), tostring(e.text or ""))
            self:drawText(101, 15 + i, padOrTrunc(line, 56), col, COLORS.panelBg)
        end
    end
end

function UI:renderRulesTab()
    self:drawFrame(2, 5, 157, 43, COLORS.border, COLORS.panelBg, "round")
    self:drawText(4, 5, " ◈ STOCK MAINTAINER RULES ", COLORS.accent, COLORS.panelBg)

    local fx = 33
    for _, fk in ipairs({ "ALL", "LOW", "CRAFT", "ERR", "WARN", "OFF", "DTPF", "ITEMS", "FLUIDS" }) do
        local act = (self.filterKind == fk)
        fx = self:drawButton(fx, 5, "[" .. fk .. "]",
            act and COLORS.fg or COLORS.muted, act and COLORS.btnActiveBg or COLORS.btnBg,
            function()
                self.filterKind = fk
                self.rulesScroll = 0
            end) + 1
    end

    local groups = { "ALL" }
    for _, g in ipairs(self.cfg.groups or Scheduler.DEFAULT_GROUPS) do
        groups[#groups + 1] = g
    end
    local sx = 4
    local qLbl = (self.searchQuery and self.searchQuery ~= "") and self.searchQuery or "/"
    sx = self:drawButton(sx, 6, "[Search: " .. padOrTrunc(qLbl, 24) .. "]",
        (self.searchQuery and self.searchQuery ~= "") and COLORS.cyan or COLORS.muted, COLORS.btnBg,
        function()
            self.numPrompt = {
                title = "Search Rules (label, id, group, cpu; blank = clear)",
                buf = self.searchQuery or "",
                rawText = true,
                onApply = function(txt)
                    self.searchQuery = tostring(txt or ""):match("^%s*(.-)%s*$")
                    self.rulesScroll = 0
                end,
            }
        end) + 1
    if self.searchQuery and self.searchQuery ~= "" then
        sx = self:drawButton(sx, 6, "[Clr]", COLORS.yellow, COLORS.btnBg, function()
            self.searchQuery = ""
            self.rulesScroll = 0
        end) + 1
    end

    local sortLabels = { state = "STATE", name = "NAME", pct = "FILL%", prio = "PRIO" }
    local sortOrder = { "state", "name", "pct", "prio" }
    sx = self:drawButton(sx + 1, 6, "[Sort: " .. (sortLabels[self.sortMode or "state"] or "STATE") .. "]", COLORS.fg, COLORS.btnBg, function()
        local cur = 1
        for i, sm in ipairs(sortOrder) do if sm == self.sortMode then cur = i break end end
        self.sortMode = sortOrder[(cur % #sortOrder) + 1]
        self.rulesScroll = 0
    end) + 1

    sx = self:drawButton(sx + 1, 6, "[Grp: " .. tostring(self.filterGroup) .. "]", COLORS.cyan, COLORS.btnBg, function()
        local cur = 1
        for i, g in ipairs(groups) do if g == self.filterGroup then cur = i break end end
        self.filterGroup = groups[(cur % #groups) + 1]
        self.rulesScroll = 0
    end) + 1

    if self.filterGroup ~= "ALL" then
        sx = self:drawButton(sx, 6, "[Grp ON]", COLORS.green, COLORS.darkGreen, function()
            local n = Scheduler.setGroupEnabled(self.cfg, self.filterGroup, true)
            self:save(string.format("Enabled %d rules in group %s.", n, self.filterGroup))
        end) + 1
        self:drawButton(sx, 6, "[Grp OFF]", COLORS.yellow, COLORS.amberBg, function()
            local n = Scheduler.setGroupEnabled(self.cfg, self.filterGroup, false)
            self:save(string.format("Disabled %d rules in group %s.", n, self.filterGroup))
        end)
    end

    local searchTerms = {}
    if self.searchQuery and self.searchQuery ~= "" then
        for tok in self.searchQuery:lower():gmatch("%S+") do
            searchTerms[#searchTerms + 1] = tok
        end
    end

    if self.filterKind == "DTPF" then
        local peer = self.state and self.state.dtpfPeer
        local dRows = {}
        local function matchDtpf(lbl, name, tp)
            if #searchTerms == 0 then return true end
            local hay = string.lower(string.format("%s %s %s dtpf", tostring(lbl or ""), tostring(name or ""), tostring(tp or "")))
            for _, tok in ipairs(searchTerms) do
                if not hay:find(tok, 1, true) then return false end
            end
            return true
        end
        if type(peer) == "table" then
            if peer.maintEnabled == true and type(peer.maintInfo) == "table" then
                for k, v in pairs(peer.maintInfo) do
                    if type(v) == "table" and matchDtpf(v.l or v.n, v.n or k, v.t) then
                        dRows[#dRows + 1] = {
                            role = "input", badge = "◈IN ", rank = 1,
                            type = v.t or "item", label = v.l or v.n or k,
                            stock = tonumber(v.stk) or 0, target = tonumber(v.tgt) or 0,
                            batch = tonumber(v.bat) or 0, mode = tostring(v.m or "auto"),
                            status = tostring(v.st or "DTPF Input"),
                        }
                    end
                end
            end
            if type(peer.passiveInfo) == "table" then
                for k, v in pairs(peer.passiveInfo) do
                    if type(v) == "table" and matchDtpf(v.l or v.n, v.n or k, v.t) then
                        dRows[#dRows + 1] = {
                            role = "passive", badge = "◈OUT", rank = 2,
                            type = v.t or "fluid", label = v.l or v.n or k,
                            stock = tonumber(v.stk) or 0, target = tonumber(v.tgt) or 0,
                            forever = (v.fv == true), mode = (v.fv == true) and "24/7" or "<Tgt",
                            status = "DTPF Passive",
                        }
                    end
                end
            end
        end
        table.sort(dRows, function(a, b)
            if a.rank ~= b.rank then return a.rank < b.rank end
            return tostring(a.label):lower() < tostring(b.label):lower()
        end)

        self:drawText(4, 8, padOrTrunc(string.format("%-5s %-34s %-6s %-11s %-11s %-11s %-8s %s",
            "Badge", "Item / Fluid", "Type", "ME Stock", "DTPF Tgt", "Batch", "Mode", "DTPF Status"), 152), COLORS.muted, COLORS.panelBg)
        self:drawText(4, 9, string.rep("─", 152), COLORS.border, COLORS.panelBg)

        local maxShow = 16
        local maxScroll = math.max(0, #dRows - maxShow)
        self.rulesScroll = math.max(0, math.min(maxScroll, self.rulesScroll or 0))
        if #dRows == 0 then
            local msg = (type(peer) == "table") and "No active DTPF Maintainer/Passive entries match filter."
                or "DTPF peer offline (waiting for DTPF_CLAIMS over OC Mesh port 4205)."
            self:drawText(4, 11, msg, COLORS.muted, COLORS.panelBg)
        else
            for i = 1, math.min(maxShow, #dRows - self.rulesScroll) do
                local dr = dRows[self.rulesScroll + i]
                local ry = 9 + i * 2
                local bg = (i % 2 == 0) and COLORS.rowAltBg or COLORS.panelBg
                self:fillRect(3, ry, 155, 1, " ", COLORS.fg, bg)
                local isFl = (dr.type == "fluid")
                local suf = isFl and "L" or ""
                local tgtStr = (dr.forever and dr.target <= 0) and "24/7" or UI.formatNumber(dr.target, suf)
                local batStr = (dr.role == "input" and dr.batch > 0) and UI.formatNumber(dr.batch, suf) or "-"
                local col = (dr.role == "input") and COLORS.purple or COLORS.cyan
                local line = string.format("%-5s %-34s %-6s %-11s %-11s %-11s %-8s %s",
                    dr.badge, padOrTrunc(dr.label, 34), isFl and "FLUID" or "ITEM",
                    UI.formatNumber(dr.stock, suf), tgtStr, batStr, padOrTrunc(dr.mode, 8), padOrTrunc(dr.status, 36))
                self:drawText(4, ry, padOrTrunc(line, 152), col, bg)
            end
        end
        local bx = 4
        bx = self:drawButton(bx, 45, "[▲ Prev]", self.rulesScroll > 0 and COLORS.fg or COLORS.muted, COLORS.btnBg, function()
            self.rulesScroll = math.max(0, self.rulesScroll - maxShow)
        end) + 2
        bx = self:drawButton(bx, 45, "[▼ Next]", self.rulesScroll < maxScroll and COLORS.fg or COLORS.muted, COLORS.btnBg, function()
            self.rulesScroll = math.min(maxScroll, self.rulesScroll + maxShow)
        end) + 2
        self:drawText(bx, 45, string.format("DTPF-maintained view: %d item(s)/fluid(s) read live from DTPF_CLAIMS", #dRows), COLORS.muted, COLORS.panelBg)
        return
    end

    local stMap = self:getRuleStatusMap()
    local rows = {}
    for _, r in ipairs(self.cfg.rules or {}) do
        local sr = stMap[r.id] or {
            stock = 0, target = r.target, lowThreshold = r.lowThreshold or r.target,
            pct = 0, state = (r.enabled == false) and "OFF" or "LOW",
            stateDetail = (r.enabled == false) and "Disabled" or "Pending",
        }
        local matchK = (self.filterKind == "ALL")
            or (self.filterKind == "LOW" and sr.state == "LOW")
            or (self.filterKind == "CRAFT" and sr.state == "CRAFT")
            or (self.filterKind == "ERR" and sr.state == "ERR")
            or (self.filterKind == "WARN" and sr.warn ~= nil)
            or (self.filterKind == "OFF" and (r.enabled == false or r.mode == "off" or sr.state == "OFF"))
            or (self.filterKind == "ITEMS" and r.type == "item")
            or (self.filterKind == "FLUIDS" and r.type == "fluid")
        local matchG = (self.filterGroup == "ALL") or (r.group == self.filterGroup)
        local matchS = true
        if #searchTerms > 0 then
            local hay = string.lower(string.format("%s %s %s %s %s",
                tostring(r.label or ""), tostring(r.name or ""), tostring(r.group or ""),
                tostring(r.type or ""), tostring(r.cpuFilter or "")))
            for _, tok in ipairs(searchTerms) do
                if not hay:find(tok, 1, true) then
                    matchS = false
                    break
                end
            end
        end
        if matchK and matchG and matchS then
            rows[#rows + 1] = { rule = r, sr = sr }
        end
    end

    local stateRank = { ERR = 1, WARN = 2, LOW = 3, CRAFT = 4, OK = 5, OFF = 6 }
    local sm = self.sortMode or "state"
    if sm == "name" then
        table.sort(rows, function(a, b)
            return tostring(a.rule.label or a.rule.name):lower() < tostring(b.rule.label or b.rule.name):lower()
        end)
    elseif sm == "pct" then
        table.sort(rows, function(a, b)
            local pa = tonumber(a.sr.pct) or 0
            local pb = tonumber(b.sr.pct) or 0
            if pa ~= pb then return pa < pb end
            return tostring(a.rule.label or a.rule.name) < tostring(b.rule.label or b.rule.name)
        end)
    elseif sm == "prio" then
        table.sort(rows, function(a, b)
            local pa = tonumber(a.rule.priority) or 3
            local pb = tonumber(b.rule.priority) or 3
            if pa ~= pb then return pa < pb end
            return tostring(a.rule.label or a.rule.name) < tostring(b.rule.label or b.rule.name)
        end)
    else
        table.sort(rows, function(a, b)
            local ra = stateRank[a.sr.state] or 9
            local rb = stateRank[b.sr.state] or 9
            if ra ~= rb then return ra < rb end
            local pa = tonumber(a.rule.priority) or 3
            local pb = tonumber(b.rule.priority) or 3
            if pa ~= pb then return pa < pb end
            return tostring(a.rule.label or a.rule.name) < tostring(b.rule.label or b.rule.name)
        end)
    end

    self:drawText(4, 8, padOrTrunc(string.format("%-6s %-2s %-9s %-28s %-6s %-10s %-10s %-10s %-10s %-7s %s",
        "State", "P", "Group", "Item / Fluid", "Type", "Stock", "LowThr", "Target", "Batch", "Mode", "Status / Warning"), 152), COLORS.muted, COLORS.panelBg)
    self:drawText(4, 9, string.rep("─", 152), COLORS.border, COLORS.panelBg)

    local maxShow = 16
    local maxScroll = math.max(0, #rows - maxShow)
    self.rulesScroll = math.max(0, math.min(maxScroll, self.rulesScroll or 0))
    for i = 1, math.min(maxShow, #rows - self.rulesScroll) do
        local ent = rows[self.rulesScroll + i]
        local r, sr = ent.rule, ent.sr
        local ry = 9 + i * 2
        local bg = (i % 2 == 0) and COLORS.rowAltBg or COLORS.panelBg
        self:fillRect(3, ry, 155, 1, " ", COLORS.fg, bg)

        local isOn = (r.enabled ~= false) and (r.mode ~= "off")
        self:drawButton(4, ry, isOn and "[ON ]" or "[OFF]",
            isOn and COLORS.green or COLORS.muted, isOn and COLORS.darkGreen or COLORS.btnBg,
            function()
                Scheduler.toggleRule(self.cfg, r.id)
                self:save((isOn and "Paused (kept cfg): " or "Enabled: ") .. r.label)
            end)

        local isFl = (r.type == "fluid")
        local suf = isFl and "L" or ""
        local di = sr.dtpfInfo
        local dtpfTag = ""
        if type(di) == "table" then
            if di.role == "input" then
                dtpfTag = string.format("◈IN %s/%s", UI.formatNumber(di.stock or 0, suf), UI.formatNumber(di.target or 0, suf))
            else
                dtpfTag = (di.forever and (tonumber(di.target) or 0) <= 0)
                    and string.format("◈OUT %s 24/7", UI.formatNumber(di.stock or 0, suf))
                    or string.format("◈OUT %s/%s", UI.formatNumber(di.stock or 0, suf), UI.formatNumber(di.target or 0, suf))
            end
        end
        local det = (dtpfTag ~= "") and (dtpfTag .. " | " .. tostring(sr.stateDetail or ""))
            or (sr.warn and (sr.stateDetail .. " | " .. sr.warn) or sr.stateDetail)
        local rowStr = string.format("P%d %-9s %-28s %-6s %-10s %-10s %-10s %-10s %-7s %s",
            r.priority or 3,
            padOrTrunc(r.group or "General", 9),
            padOrTrunc(r.label or r.name, 28),
            isFl and "FLUID" or "ITEM",
            UI.formatNumber(sr.stock or 0, suf),
            UI.formatNumber(r.lowThreshold or r.target or 1, suf),
            UI.formatNumber(r.target or 1, suf),
            (r.batchMode == "deficit") and "DEFICIT" or UI.formatNumber(r.batch or 1, suf),
            r.batchMode or "fixed",
            padOrTrunc(det, 36))
        local col = (sr.state == "ERR" and COLORS.red)
            or (sr.warn and COLORS.yellow)
            or (sr.state == "CRAFT" and COLORS.cyan)
            or (sr.state == "LOW" and COLORS.yellow)
            or (isOn and COLORS.fg or COLORS.muted)
        self:drawButton(11, ry, padOrTrunc(rowStr, 136), col, bg, function()
            self.editRuleId = r.id
        end)
        self:drawButton(149, ry, "[Edit]", COLORS.accent, COLORS.btnBg, function()
            self.editRuleId = r.id
        end)
    end

    local bx = 4
    bx = self:drawButton(bx, 45, "[▲ Prev]", self.rulesScroll > 0 and COLORS.fg or COLORS.muted, COLORS.btnBg, function()
        self.rulesScroll = math.max(0, self.rulesScroll - maxShow)
    end) + 2
    bx = self:drawButton(bx, 45, "[▼ Next]", self.rulesScroll < maxScroll and COLORS.fg or COLORS.muted, COLORS.btnBg, function()
        self.rulesScroll = math.min(maxScroll, self.rulesScroll + maxShow)
    end) + 2
    self:drawText(bx, 45, string.format("Showing %d of %d rules ([ON]/[OFF] pauses & keeps config; '/' searches)",
        math.min(maxShow, math.max(0, #rows - self.rulesScroll)), #rows), COLORS.muted, COLORS.panelBg)
end

function UI:renderAddImportTab()
    -- Left Card: Live Drop-In Transposer Reader
    self:drawFrame(2, 5, 76, 43, COLORS.border, COLORS.panelBg, "round")
    self:drawText(4, 5, " ◈ DROP-IN TRANSPOSER RULE ADDER ", COLORS.accent, COLORS.panelBg)

    local drop = self.state.dropPreview
    self:drawButton(4, 7, "[↻ Scan Drop Slot]", COLORS.cyan, COLORS.btnBg, function()
        self.state.dropPreview = Hardware.readDropSlot(self.cfg, self.comp, self.state)
        drop = self.state.dropPreview
        self.statusMsg = drop.found and ("Detected: " .. tostring(drop.label)) or tostring(drop.reason or "Empty")
    end)

    if not drop or not drop.hasTransposer then
        self:drawText(4, 10, "No OC Transposer attached (optional).", COLORS.yellow, COLORS.panelBg)
        self:drawText(4, 12, "Place an OC Transposer next to an Adapter + Chest/Barrel,", COLORS.muted, COLORS.panelBg)
        self:drawText(4, 13, "then drop any Item or AE2FC Fluid Drop/Tank inside to auto-fill.", COLORS.muted, COLORS.panelBg)
        self:drawText(4, 15, "You can also add/search all craftables via the :8765 Web Console!", COLORS.cyan, COLORS.panelBg)
    elseif not drop.found then
        self:drawText(4, 10, "Transposer: " .. Hardware.shortAddr(drop.transposerAddr) .. " (Empty)", COLORS.muted, COLORS.panelBg)
        self:drawText(4, 12, padOrTrunc(tostring(drop.reason or "Drop an item or fluid drop in chest slot 1."), 70), COLORS.fg, COLORS.panelBg)
    else
        local isFl = (drop.type == "fluid")
        self:drawText(4, 10, "Detected : " .. padOrTrunc(drop.label, 58), COLORS.green, COLORS.panelBg)
        self:drawText(4, 11, string.format("ID / Key : %s:%s:%d", drop.type, drop.name, drop.damage or 0), COLORS.muted, COLORS.panelBg)
        self:drawText(4, 12, string.format("In AE2   : %s | Pattern: %s",
            UI.formatNumber(drop.stock or 0, isFl and "L" or ""),
            drop.craftable and "YES" or "NOT FOUND"),
            drop.craftable and COLORS.cyan or COLORS.yellow, COLORS.panelBg)

        local nowSec = Scheduler.now()
        local dropInfo = Scheduler.getDtpfInfo(drop, self.state.dtpfPeer, nowSec)
        local _, warnText = Scheduler.classifyDtpfWarning(self.cfg, drop, self.state.dtpfPeer, nowSec)
        if dropInfo and not warnText then
            local dSuf = isFl and "L" or ""
            warnText = (dropInfo.role == "input")
                and string.format("◈ Already DTPF Input @ %s/%s", UI.formatNumber(dropInfo.stock or 0, dSuf), UI.formatNumber(dropInfo.target or 0, dSuf))
                or string.format("◈ Already DTPF Passive @ %s/%s", UI.formatNumber(dropInfo.stock or 0, dSuf), UI.formatNumber(dropInfo.target or 0, dSuf))
        end
        if warnText then
            self:drawText(4, 14, padOrTrunc(warnText, 70), COLORS.yellow, COLORS.amberBg)
        end

        local dd = self.dropDraft
        self:drawText(4, 17, "Target   : " .. UI.formatNumber(dd.target, isFl and "L" or ""), COLORS.fg, COLORS.panelBg)
        local tx = 28
        for _, v in ipairs({ 64, 1024, 16384, 100000, 1000000, 10000000 }) do
            tx = self:drawButton(tx, 17, "[" .. UI.formatNumber(v) .. "]", COLORS.cyan, COLORS.btnBg, function()
                dd.target = v
                dd.batch = math.max(1, math.floor(v / 4))
            end) + 1
        end

        self:drawText(4, 19, "Batch    : " .. UI.formatNumber(dd.batch, isFl and "L" or ""), COLORS.fg, COLORS.panelBg)
        local bx = 28
        for _, v in ipairs({ 16, 64, 256, 1024, 10000, 100000, 1000000 }) do
            bx = self:drawButton(bx, 19, "[" .. UI.formatNumber(v) .. "]", COLORS.fg, COLORS.btnBg, function()
                dd.batch = v
            end) + 1
        end

        self:drawButton(4, 22, "[+ Add Dropped Rule]", COLORS.fg, COLORS.darkGreen, function()
            local _, _, isNew = Scheduler.upsertRule(self.cfg, {
                type = drop.type,
                name = drop.name,
                damage = drop.damage,
                label = drop.label,
                hasTag = drop.hasTag,
                target = dd.target,
                batch = dd.batch,
                group = isFl and "Fluids" or dd.group,
                priority = dd.priority,
                enabled = true,
            })
            self:save((isNew and "Added rule: " or "Updated rule: ") .. drop.label)
        end)
    end

    -- Right Card: Physical AE2FC ME Level Maintainer Importer
    self:drawFrame(80, 5, 79, 43, COLORS.border, COLORS.panelBg, "round")
    self:drawText(82, 5, " ◈ PHYSICAL ME LEVEL MAINTAINER IMPORTER ", COLORS.accent, COLORS.panelBg)

    local slots = self.state.physicalMaintainers or {}
    local bx = 82
    bx = self:drawButton(bx, 7, "[↻ Scan Physical]", COLORS.cyan, COLORS.btnBg, function()
        local found, nBlocks = Hardware.scanPhysicalMaintainers(self.comp, self.state)
        self.state.physicalMaintainers = found
        self.importScroll = 0
        self.statusMsg = string.format("Found %d configured slots across %d physical Level Maintainer(s).", #found, nBlocks)
    end) + 1
    bx = self:drawButton(bx, 7, "[+ Import Non-DTPF]", COLORS.fg, COLORS.darkGreen, function()
        if #slots == 0 then
            slots = Hardware.scanPhysicalMaintainers(self.comp, self.state)
            self.state.physicalMaintainers = slots
        end
        local imp = Scheduler.importPhysicalSlots(self.cfg, slots, {
            includeDisabled = false,
            skipDtpfPassives = true,
            disablePhysical = (self.cfg.disablePhysicalAfterImport == true),
            disableFn = function(a, s) return Hardware.disablePhysicalMaintainerSlot(a, s, self.comp, self.state) end,
        })
        self:save(string.format("Imported %d non-DTPF (%d DTPF skipped, %d skip, %d dis).", imp.added, imp.skippedDtpf or 0, imp.skipped, imp.disabled))
    end) + 1
    self:drawButton(bx, 7, "[+ Import All New]", COLORS.fg, COLORS.btnBg, function()
        if #slots == 0 then
            slots = Hardware.scanPhysicalMaintainers(self.comp, self.state)
            self.state.physicalMaintainers = slots
        end
        local imp = Scheduler.importPhysicalSlots(self.cfg, slots, {
            includeDisabled = false,
            disablePhysical = (self.cfg.disablePhysicalAfterImport == true),
            disableFn = function(a, s) return Hardware.disablePhysicalMaintainerSlot(a, s, self.comp, self.state) end,
        })
        self:save(string.format("Imported %d new (%d skipped, %d disabled).", imp.added, imp.skipped, imp.disabled))
    end)

    local bx2 = 82
    local disOn = (self.cfg.disablePhysicalAfterImport == true)
    bx2 = self:drawButton(bx2, 8, disOn and "[Disable After: ON ]" or "[Disable After: OFF]",
        disOn and COLORS.yellow or COLORS.muted, disOn and COLORS.amberBg or COLORS.btnBg, function()
            self.cfg.disablePhysicalAfterImport = not disOn
            self:save("Disable physical slots after import -> " .. tostring(self.cfg.disablePhysicalAfterImport))
        end) + 2
    self:drawButton(bx2, 8, "[-> Send DTPF to DTPF]", COLORS.purple, COLORS.btnBg, function()
        local items = Scheduler.buildDtpfHandoffItems(self.cfg, self.state)
        if #items == 0 then
            self.statusMsg = "No active DTPF rules in local config to distribute."
        else
            local okH, errH = Hardware.sendDtpfHandoff(self.cfg, self.state, items, self.comp)
            self.statusMsg = okH and string.format("Sent %d rule(s) to DTPF over Mesh (awaiting ACK).", #items)
                or ("DTPF handoff failed: " .. tostring(errH))
        end
    end)

    self:drawText(82, 10, padOrTrunc(string.format("%-10s %-4s %-28s %-10s %-10s %s",
        "Block", "Slot", "Item / Fluid", "Target", "Batch", "Enabled"), 75), COLORS.muted, COLORS.panelBg)
    self:drawText(82, 11, string.rep("─", 75), COLORS.border, COLORS.panelBg)

    local maxImp = 15
    local maxImpScroll = math.max(0, #slots - maxImp)
    self.importScroll = math.max(0, math.min(maxImpScroll, self.importScroll or 0))
    if #slots == 0 then
        self:drawText(82, 13, "Click [Scan Physical] with Adapters on ME Level Maintainers.", COLORS.muted, COLORS.panelBg)
    else
        for i = 1, math.min(maxImp, #slots - self.importScroll) do
            local s = slots[self.importScroll + i]
            local ry = 11 + i * 2
            local bg = (i % 2 == 0) and COLORS.rowAltBg or COLORS.panelBg
            self:fillRect(81, ry, 77, 1, " ", COLORS.fg, bg)
            local suf = (s.type == "fluid") and "L" or ""
            local dInfo = Scheduler.getDtpfInfo(s, self.state.dtpfPeer, Scheduler.now())
            local isDtpfIn = (dInfo and dInfo.role == "input") == true
            local isDtpf = (DtpfCatalog.lookup(s.type, s.name, s.damage) ~= nil) or (dInfo and dInfo.role == "passive")
            local lblShown = isDtpfIn and ("[◈D-IN] " .. tostring(s.label or s.name))
                or (isDtpf and ("[DTPF] " .. tostring(s.label or s.name)) or tostring(s.label or s.name))
            local line = string.format("%-10s S%-3d %-28s %-10s %-10s %s",
                Hardware.shortAddr(s.addr), s.slot or 1,
                padOrTrunc(lblShown, 28),
                UI.formatNumber(s.target or 1, suf),
                UI.formatNumber(s.batch or 1, suf),
                s.enabled and "YES" or "NO")
            local rowCol = isDtpfIn and COLORS.purple or (isDtpf and COLORS.yellow or (s.enabled and COLORS.fg or COLORS.muted))
            self:drawText(82, ry, padOrTrunc(line, 75), rowCol, bg)
        end
    end
end

function UI:renderPerfSetupTab()
    -- Left Card: Global Guardrails & Policy
    self:drawFrame(2, 5, 77, 43, COLORS.border, COLORS.panelBg, "round")
    self:drawText(4, 5, " ◈ MAINTAINER GUARDRAILS & SETUP ", COLORS.accent, COLORS.panelBg)

    local settings = {
        { lbl = "Poll Interval (s)", val = tostring(self.cfg.pollSec) .. "s", dec = function() self.cfg.pollSec = math.max(2, self.cfg.pollSec - 2) end, inc = function() self.cfg.pollSec = math.min(300, self.cfg.pollSec + 2) end },
        { lbl = "Idle Poll (s)", val = tostring(self.cfg.idlePollSec or 25) .. "s", dec = function() self.cfg.idlePollSec = math.max(self.cfg.pollSec or 2, (self.cfg.idlePollSec or 25) - 5) end, inc = function() self.cfg.idlePollSec = math.min(300, (self.cfg.idlePollSec or 25) + 5) end },
        { lbl = "Stagger Batch Size", val = tostring(self.cfg.staggerBatch), dec = function() self.cfg.staggerBatch = math.max(5, self.cfg.staggerBatch - 5) end, inc = function() self.cfg.staggerBatch = math.min(500, self.cfg.staggerBatch + 5) end },
        { lbl = "Keep Free CPUs", val = tostring(self.cfg.freeCpusReserve), dec = function() self.cfg.freeCpusReserve = math.max(0, self.cfg.freeCpusReserve - 1) end, inc = function() self.cfg.freeCpusReserve = math.min(32, self.cfg.freeCpusReserve + 1) end },
        { lbl = "Max Concurrent Crafts", val = tostring(self.cfg.maxConcurrentCrafts), dec = function() self.cfg.maxConcurrentCrafts = math.max(1, self.cfg.maxConcurrentCrafts - 1) end, inc = function() self.cfg.maxConcurrentCrafts = math.min(64, self.cfg.maxConcurrentCrafts + 1) end },
        { lbl = "Max Dispatch / Cycle", val = tostring(self.cfg.maxDispatchPerCycle), dec = function() self.cfg.maxDispatchPerCycle = math.max(1, self.cfg.maxDispatchPerCycle - 1) end, inc = function() self.cfg.maxDispatchPerCycle = math.min(32, self.cfg.maxDispatchPerCycle + 1) end },
        { lbl = "Backoff Base (s)", val = tostring(self.cfg.backoffBaseSec) .. "s", dec = function() self.cfg.backoffBaseSec = math.max(5, self.cfg.backoffBaseSec - 5) end, inc = function() self.cfg.backoffBaseSec = math.min(300, self.cfg.backoffBaseSec + 5) end },
        { lbl = "Backoff Max (s)", val = tostring(self.cfg.backoffMaxSec) .. "s", dec = function() self.cfg.backoffMaxSec = math.max(self.cfg.backoffBaseSec, self.cfg.backoffMaxSec - 30) end, inc = function() self.cfg.backoffMaxSec = math.min(3600, self.cfg.backoffMaxSec + 30) end },
    }
    for i, st in ipairs(settings) do
        local ry = 6 + i * 2
        self:drawText(4, ry, padOrTrunc(st.lbl .. ":", 28), COLORS.fg, COLORS.panelBg)
        self:drawText(34, ry, padOrTrunc(st.val, 10), COLORS.cyan, COLORS.panelBg)
        self:drawButton(46, ry, "[-]", COLORS.yellow, COLORS.btnBg, function() st.dec(); self:save("Updated " .. st.lbl) end)
        self:drawButton(51, ry, "[+]", COLORS.green, COLORS.btnBg, function() st.inc(); self:save("Updated " .. st.lbl) end)
    end

    local wm = self.cfg.dtpfWarnMode or "warn"
    self:drawText(4, 26, "DTPF Overlap Policy:", COLORS.fg, COLORS.panelBg)
    self:drawButton(28, 26, "[" .. wm:upper() .. "]", COLORS.yellow, COLORS.btnBg, function()
        self.cfg.dtpfWarnMode = (wm == "warn" and "block_overlap") or (wm == "block_overlap" and "off") or "warn"
        self:save("DTPF Warn Mode -> " .. self.cfg.dtpfWarnMode)
    end)

    local extOff = (self.cfg.extLinkMode == "off")
    self:drawText(4, 28, "OC Mesh Link (port 4205):", COLORS.fg, COLORS.panelBg)
    self:drawButton(31, 28, extOff and "[Standalone]" or "[Mesh/Auto ]",
        extOff and COLORS.yellow or COLORS.cyan, COLORS.btnBg, function()
            self.cfg.extLinkMode = extOff and "auto" or "off"
            self:save("ExtLink Mode -> " .. self.cfg.extLinkMode)
        end)

    if self.extras and self.extras.isAutostartEnabled then
        local autoOn = self.extras.isAutostartEnabled()
        self:drawText(4, 30, "Boot Autostart (.shrc):", COLORS.fg, COLORS.panelBg)
        self:drawButton(31, 30, autoOn and "[ ON ]" or "[OFF ]",
            autoOn and COLORS.green or COLORS.muted, autoOn and COLORS.darkGreen or COLORS.btnBg, function()
                local nextOn = self.extras.toggleAutostart()
                self.statusMsg = "Boot Autostart -> " .. (nextOn and "ON" or "OFF")
            end)
    end

    -- Right Card: Live Performance & Physical Maintainer Comparison
    self:drawFrame(81, 5, 78, 43, COLORS.border, COLORS.panelBg, "round")
    self:drawText(83, 5, " ◈ PERFORMANCE PROFILER & BENCHMARK ", COLORS.accent, COLORS.panelBg)
    self:drawButton(83, 7, "[▶ Run Live AE2 Benchmark]", COLORS.fg, COLORS.darkGreen, function()
        Hardware.runBenchmark(self.cfg, self.state, self.comp)
        self.statusMsg = "Benchmark completed."
    end)

    local p = (self.state and self.state.perf) or {}
    local b = self.state and self.state.lastBenchmark
    self:drawText(83, 10, string.format("Rolling Cycle Time : %.2f ms (avg %.2f ms)", tonumber(p.lastCycleMs) or 0, tonumber(p.avgCycleMs) or 0), COLORS.green, COLORS.panelBg)
    self:drawText(83, 11, string.format("AE2 Calls / Cycle  : %d calls (%.2f calls/sec)", tonumber(p.aeCallsLast) or 0, tonumber(p.aeCallsPerSec) or 0), COLORS.cyan, COLORS.panelBg)
    self:drawText(83, 12, string.format("Memory Footprint   : %d KB Lua | %d KB Free / %d KB Total",
        tonumber(p.luaHeapKB) or 0, tonumber(p.freeMemKB) or 0, tonumber(p.totalMemKB) or 0), COLORS.fg, COLORS.panelBg)
    self:drawText(83, 13, string.format("Physical Savings   : %d Level Maintainer blocks & %d AE2 channels replaced",
        tonumber(p.equivBlocksSaved) or 0, tonumber(p.equivChannelsSaved) or 0), COLORS.purple, COLORS.panelBg)

    if b then
        self:drawText(83, 16, "Latest Live Benchmark:", COLORS.accent, COLORS.panelBg)
        self:drawText(83, 17, string.format("  O(1) Lookup (%d calls) : %.3f ms total (%.3f ms/call)", b.sampleCalls or 0, b.o1TotalMs or 0, b.o1AvgMs or 0), COLORS.green, COLORS.panelBg)
        self:drawText(83, 18, string.format("  getCpus() Call          : %.3f ms", b.cpuMs or 0), COLORS.fg, COLORS.panelBg)
        if b.legacyFluidMs then
            self:drawText(83, 19, string.format("  Legacy getFluidsInNet() : %.3f ms (full list)", b.legacyFluidMs), COLORS.yellow, COLORS.panelBg)
        end
        if b.legacyItemFilterMs then
            self:drawText(83, 20, string.format("  Legacy getItemsInNet()  : %.3f ms (filtered scan)", b.legacyItemFilterMs), COLORS.yellow, COLORS.panelBg)
        end
    else
        self:drawText(83, 16, "Click [Run Live AE2 Benchmark] or run `stock --bench` in shell.", COLORS.muted, COLORS.panelBg)
    end

    self:drawText(83, 24, "Why OC Outperforms Physical AE2FC Level Maintainers:", COLORS.accent, COLORS.panelBg)
    self:drawText(83, 26, "1. 1-tick bulk fluid cache (getFluidsInNetwork) + lazy CPU finalOutput()", COLORS.muted, COLORS.panelBg)
    self:drawText(83, 27, "   + cached Craftable handles + live ICraftingLink skip (0 calls/craft).", COLORS.muted, COLORS.panelBg)
    self:drawText(83, 28, "2. TileLevelMaintainer repeats CraftingJobV2 on SAME ticks on CantCraft,", COLORS.muted, COLORS.panelBg)
    self:drawText(83, 29, "   lacks hysteresis/CPU reserve, and burns 1 AE2 channel per 5 slots.", COLORS.muted, COLORS.panelBg)
    self:drawText(83, 30, "3. OC uses 0 extra channels, adaptive idle backoff & round-robin parity.", COLORS.muted, COLORS.panelBg)
end

function UI:renderRuleEditModal()
    if not self.editRuleId then return end
    local r = Scheduler.findRule(self.cfg, nil, nil, nil, self.editRuleId)
    if not r then self.editRuleId = nil; return end
    self.hitboxes = {}

    local mx, my, mw, mh = 18, 7, 124, 34
    self:drawFrame(mx, my, mw, mh, COLORS.accent, COLORS.headerBg, "double")
    self:fillRect(mx + 1, my + 1, mw - 2, mh - 2, " ", COLORS.fg, COLORS.headerBg)
    self:drawText(mx + 3, my + 1, padOrTrunc("EDIT RULE: " .. tostring(r.label or r.name), mw - 20), COLORS.accent, COLORS.headerBg)
    self:drawButton(mx + mw - 12, my + 1, "[ X CLOSE ]", COLORS.red, COLORS.darkRed, function()
        self.editRuleId = nil
    end)

    local isFl = (r.type == "fluid")
    local suf = isFl and "L" or ""
    local function openNum(fieldLbl, curVal, setter)
        self.numPrompt = {
            title = fieldLbl .. " (" .. r.label .. ")",
            buf = UI.formatNumber(curVal or 1, ""),
            onApply = function(parsed)
                if parsed and parsed > 0 then
                    setter(parsed)
                    self:save(r.label .. " " .. fieldLbl .. " -> " .. UI.formatNumber(parsed, suf))
                end
            end,
        }
    end

    self:drawText(mx + 3, my + 4, padOrTrunc(string.format("Key: %s:%s:%d", r.type, r.name, r.damage or 0), 56), COLORS.muted, COLORS.headerBg)
    local isEn = (r.enabled ~= false) and (r.mode ~= "off")
    self:drawButton(mx + 62, my + 4, isEn and "[Status: ENABLED (Click to Pause)]" or "[Status: PAUSED (Keep Cfg)]",
        isEn and COLORS.fg or COLORS.yellow, isEn and COLORS.darkGreen or COLORS.amberBg, function()
            Scheduler.toggleRule(self.cfg, r.id)
            self:save((isEn and "Paused (kept cfg): " or "Enabled: ") .. r.label)
        end)

    -- Target
    self:drawText(mx + 3, my + 7, "Target Stock :", COLORS.fg, COLORS.headerBg)
    self:drawButton(mx + 18, my + 7, "[" .. UI.formatNumber(r.target, suf) .. "]", COLORS.cyan, COLORS.btnBg, function()
        openNum("Target", r.target, function(v) r.target = v end)
    end)
    local px = mx + 34
    for _, v in ipairs({ 64, 1024, 10000, 100000, 1000000, 10000000, 100000000 }) do
        px = self:drawButton(px, my + 7, "[" .. UI.formatNumber(v) .. "]", COLORS.fg, COLORS.btnBg, function()
            r.target = v
            if r.lowThreshold and r.lowThreshold > r.target then r.lowThreshold = r.target end
            self:save(r.label .. " target -> " .. UI.formatNumber(v, suf))
        end) + 1
    end

    -- Low Threshold (Hysteresis)
    self:drawText(mx + 3, my + 10, "Low Trigger  :", COLORS.fg, COLORS.headerBg)
    local lowV = r.lowThreshold or r.target
    self:drawButton(mx + 18, my + 10, "[" .. UI.formatNumber(lowV, suf) .. "]", COLORS.yellow, COLORS.btnBg, function()
        openNum("Low Threshold", lowV, function(v) r.lowThreshold = math.min(r.target, v) end)
    end)
    local lx = mx + 34
    for _, pct in ipairs({ 50, 75, 85, 95, 100 }) do
        lx = self:drawButton(lx, my + 10, string.format("[%d%%]", pct), COLORS.yellow, COLORS.btnBg, function()
            r.lowThreshold = (pct == 100) and nil or math.max(1, math.floor(r.target * pct / 100))
            self:save(r.label .. " low threshold -> " .. tostring(pct) .. "%")
        end) + 1
    end

    -- Batch & Mode
    self:drawText(mx + 3, my + 13, "Batch Size   :", COLORS.fg, COLORS.headerBg)
    self:drawButton(mx + 18, my + 13, "[" .. UI.formatNumber(r.batch, suf) .. "]", COLORS.cyan, COLORS.btnBg, function()
        openNum("Batch Size", r.batch, function(v) r.batch = v end)
    end)
    self:drawButton(mx + 34, my + 13, "[Mode: " .. tostring(r.batchMode or "fixed"):upper() .. "]", COLORS.purple, COLORS.btnBg, function()
        r.batchMode = (r.batchMode == "deficit") and "fixed" or "deficit"
        self:save(r.label .. " batch mode -> " .. r.batchMode)
    end)

    -- Priority & Group
    self:drawText(mx + 3, my + 16, "Priority/Grp :", COLORS.fg, COLORS.headerBg)
    local gx = mx + 18
    for p = 1, 5 do
        local act = (r.priority == p)
        gx = self:drawButton(gx, my + 16, "[P" .. p .. "]", act and COLORS.fg or COLORS.muted, act and COLORS.btnActiveBg or COLORS.btnBg, function()
            r.priority = p
            self:save(r.label .. " priority -> P" .. p)
        end) + 1
    end
    local groups = self.cfg.groups or Scheduler.DEFAULT_GROUPS
    self:drawButton(gx + 2, my + 16, "[Group: " .. tostring(r.group or "General") .. "]", COLORS.cyan, COLORS.btnBg, function()
        local cur = 1
        for idx, g in ipairs(groups) do if g == r.group then cur = idx break end end
        r.group = groups[(cur % #groups) + 1]
        self:save(r.label .. " group -> " .. r.group)
    end)

    -- CPU Filter & DTPF Overlap Opt-Out
    self:drawText(mx + 3, my + 19, "CPU / DTPF   :", COLORS.fg, COLORS.headerBg)
    local cf = (r.cpuFilter and r.cpuFilter ~= "") and r.cpuFilter or "Auto"
    self:drawButton(mx + 18, my + 19, "[CPU: " .. cf .. "]", COLORS.fg, COLORS.btnBg, function()
        self.numPrompt = {
            title = "CPU Name Filter (blank for Auto)",
            buf = r.cpuFilter or "",
            rawText = true,
            onApply = function(txt)
                r.cpuFilter = tostring(txt or "")
                self:save(r.label .. " CPU filter -> " .. (r.cpuFilter ~= "" and r.cpuFilter or "Auto"))
            end,
        }
    end)
    self:drawButton(mx + 42, my + 19, r.allowDtpfOverlap and "[Allow DTPF Overlap: YES]" or "[Allow DTPF Overlap: NO ]",
        r.allowDtpfOverlap and COLORS.green or COLORS.yellow, COLORS.btnBg, function()
            r.allowDtpfOverlap = not (r.allowDtpfOverlap == true)
            self:save(r.label .. " allowDtpfOverlap -> " .. tostring(r.allowDtpfOverlap))
        end)

    self:drawButton(mx + 3, my + 24, "[Delete Rule]", COLORS.fg, COLORS.darkRed, function()
        Scheduler.deleteRule(self.cfg, r.id)
        self.editRuleId = nil
        self:save("Deleted rule: " .. r.label)
    end)
    self:drawButton(mx + 20, my + 24, "[-> Move to DTPF]", COLORS.purple, COLORS.btnBg, function()
        local items = Scheduler.buildDtpfHandoffItems(self.cfg, self.state, { r.id })
        local okH, errH = Hardware.sendDtpfHandoff(self.cfg, self.state, items, self.comp)
        if okH then
            self.editRuleId = nil
            self.statusMsg = "Sent " .. tostring(r.label or r.name) .. " to DTPF over Mesh (awaiting ACK)."
        else
            self.statusMsg = "Move to DTPF failed: " .. tostring(errH)
        end
    end)
end

function UI:renderNumPrompt()
    if not self.numPrompt then return end
    self.hitboxes = {}
    local mx, my, mw, mh = 40, 18, 80, 11
    self:drawFrame(mx, my, mw, mh, COLORS.cyan, COLORS.headerBg, "double")
    self:fillRect(mx + 1, my + 1, mw - 2, mh - 2, " ", COLORS.fg, COLORS.headerBg)
    self:drawText(mx + 3, my + 2, padOrTrunc(self.numPrompt.title, mw - 6), COLORS.accent, COLORS.headerBg)
    self:drawText(mx + 3, my + 4, "> " .. padOrTrunc(self.numPrompt.buf or "", mw - 10) .. "_", COLORS.fg, COLORS.panelBg)
    self:drawButton(mx + 3, my + 7, "[ Apply (Enter) ]", COLORS.fg, COLORS.darkGreen, function()
        local p = self.numPrompt
        self.numPrompt = nil
        if p.rawText then
            p.onApply(p.buf)
        else
            p.onApply(UI.parseNumber(p.buf))
        end
    end)
    self:drawButton(mx + 24, my + 7, "[ Cancel (Esc) ]", COLORS.yellow, COLORS.btnBg, function()
        self.numPrompt = nil
    end)
end

function UI:renderLogModal()
    if not self.logModalActive then return end
    self.hitboxes = {}
    local mx, my, mw, mh = 10, 4, 140, 42
    self:drawFrame(mx, my, mw, mh, COLORS.accent, COLORS.headerBg, "double")
    self:fillRect(mx + 1, my + 1, mw - 2, mh - 2, " ", COLORS.fg, COLORS.headerBg)
    self:drawText(mx + 2, my, " ◈ STOCK MAINTAINER ACTIVITY LOG ", COLORS.accent, COLORS.headerBg)
    self:drawButton(mx + mw - 10, my + 1, "[Close]", COLORS.red, COLORS.btnBg, function()
        self.logModalActive = false
    end)
    local list = (self.state and self.state.events) or {}
    local maxLines = mh - 5
    local maxScroll = math.max(0, #list - maxLines)
    self.logModalScroll = math.max(0, math.min(maxScroll, self.logModalScroll or 0))
    for i = 1, math.min(maxLines, #list - self.logModalScroll) do
        local e = list[self.logModalScroll + i]
        local col = (e.stage == "ERR") and COLORS.red
            or ((e.stage == "WRN") and COLORS.yellow
            or ((e.stage == "OUT") and COLORS.green or COLORS.fg))
        self:drawText(mx + 3, my + 3 + i, padOrTrunc(string.format("[%s] %s", tostring(e.stage or "DEC"), tostring(e.text or "")), mw - 6), col, COLORS.headerBg)
    end
end

function UI:render()
    self.hitboxes = {}
    self:clearNextBuffer(COLORS.bg, COLORS.fg)
    self:renderHeader()
    if self.tab == TAB_OVERVIEW then
        self:renderOverviewTab()
    elseif self.tab == TAB_RULES then
        self:renderRulesTab()
    elseif self.tab == TAB_ADD then
        self:renderAddImportTab()
    elseif self.tab == TAB_PERF then
        self:renderPerfSetupTab()
    end

    self:drawText(1, self.h - 1, string.rep("─", self.w), COLORS.border, COLORS.bg)
    self:drawText(2, self.h, padOrTrunc(self.statusMsg or "", self.w - 64), COLORS.fg, COLORS.bg)
    self:drawText(self.w - 60, self.h, "Keys: 1-4 Tabs | / Search | Space Arm | R Poll | L Log | Q Quit", COLORS.muted, COLORS.bg)

    self:renderRuleEditModal()
    self:renderNumPrompt()
    self:renderLogModal()
    self:flush()
end

function UI:handleTouch(x, y, _button)
    for i = #self.hitboxes, 1, -1 do
        local hb = self.hitboxes[i]
        if x >= hb.x1 and x <= hb.x2 and y >= hb.y1 and y <= hb.y2 then
            hb.fn()
            if self.running then self:render() end
            return true
        end
    end
    return false
end

function UI:handleScroll(dir)
    local delta = (dir > 0) and -3 or 3
    if self.logModalActive then
        self.logModalScroll = math.max(0, (self.logModalScroll or 0) + delta)
    elseif self.tab == TAB_RULES then
        self.rulesScroll = math.max(0, (self.rulesScroll or 0) + delta)
    elseif self.tab == TAB_ADD then
        self.importScroll = math.max(0, (self.importScroll or 0) + delta)
    end
    self:render()
end

function UI:handleKeyDown(char, code)
    if self.numPrompt then
        if char == 13 or char == 10 then
            local p = self.numPrompt
            self.numPrompt = nil
            if p.rawText then p.onApply(p.buf) else p.onApply(UI.parseNumber(p.buf)) end
        elseif char == 27 or code == 1 then
            self.numPrompt = nil
        elseif char == 8 or code == 14 then
            self.numPrompt.buf = self.numPrompt.buf:sub(1, math.max(0, #self.numPrompt.buf - 1))
        elseif char >= 32 and char <= 126 then
            self.numPrompt.buf = self.numPrompt.buf .. string.char(char)
        end
        self:render()
        return
    end
    if char == 27 or code == 1 then
        if self.editRuleId then self.editRuleId = nil
        elseif self.logModalActive then self.logModalActive = false end
    elseif char == 113 or char == 81 then
        self.running = false
    elseif char >= 49 and char <= 52 then
        self.tab = char - 48
        self.rulesScroll = 0
        self.importScroll = 0
    elseif char == 47 then -- '/' quick search on Rules tab
        self.tab = TAB_RULES
        self.rulesScroll = 0
        self.numPrompt = {
            title = "Search Rules (label, id, group, cpu; blank = clear)",
            buf = self.searchQuery or "",
            rawText = true,
            onApply = function(txt)
                self.searchQuery = tostring(txt or ""):match("^%s*(.-)%s*$")
                self.rulesScroll = 0
            end,
        }
    elseif char == 32 then
        self.cfg.armed = not (self.cfg.armed == true)
        self:save(self.cfg.armed and "Stock Maintainer ARMED." or "Stock Maintainer PAUSED.")
    elseif char == 114 or char == 82 then
        Scheduler.step(self.cfg, self.state, nil, self.comp, { forceFull = true })
        self.statusMsg = "Full poll completed."
    elseif char == 108 or char == 76 then
        self.logModalActive = not self.logModalActive
    end
    if self.running then self:render() end
end

return UI
