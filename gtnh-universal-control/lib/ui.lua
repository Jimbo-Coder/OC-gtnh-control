-- /home/universal/lib/ui.lua
-- Visual Touch Control Center for GTNH Universal Automation (160x50 Tier 3 GPU).
-- Multi-Channel Colored-Hatch View, 16/32 NC Banks, MLFQ Tiers, and Strictly Width-1 Glyphs.

local component = require("component")
local Common = require("gtnh_common")
local unicode = require("unicode")
local okComp, computer = pcall(require, "computer")
if not okComp then computer = nil end
local Hardware = require("lib.hardware")
local Policy = require("lib.policy")
local Scheduler = require("lib.scheduler")

local UI = {}

local function playBeep(freq, dur)
    if computer and type(computer.beep) == "function" then
        pcall(computer.beep, freq, dur)
    end
end

local function isDefaultSliceLabel(slice, ncIdx)
    local ci = Hardware.COLORS[ncIdx % 16]
    local defLabel = ((ncIdx >= 16) and "B:" or "") .. (ci and ci.name or ("Color " .. (ncIdx % 16)))
    return (not slice.label) or slice.label == "" or slice.label == defLabel
end

local function nextUnboundSlice(pool, preferredNc)
    if not pool or not pool.slices then return nil end
    local maxNc = (tonumber(pool.numSlices) or 16) - 1
    if preferredNc ~= nil and preferredNc >= 0 and preferredNc <= maxNc then
        local ps = pool.slices[preferredNc]
        if ps and (not ps.ifaceAddr or ps.ifaceAddr == "") then
            return preferredNc
        end
    end
    for c = 0, maxNc do
        local s = pool.slices[c]
        if s and (not s.ifaceAddr or s.ifaceAddr == "") then
            return c
        end
    end
    return nil
end

local function unboundNonMainnetAddrs(pool, discInterfaces)
    local boundMap = {}
    if pool and pool.slices then
        local maxNc = (tonumber(pool.numSlices) or 16) - 1
        for c = 0, maxNc do
            local a = pool.slices[c] and pool.slices[c].ifaceAddr
            if a and a ~= "" then boundMap[a] = true end
        end
    end
    local unbound = {}
    for _, it in ipairs(discInterfaces or {}) do
        if (not it.isMainnet) and not boundMap[it.address] then
            unbound[#unbound + 1] = it.address
        end
    end
    return unbound
end

local function countTotalBoundSlices(pools)
    local total = 0
    for _, pl in ipairs(pools or {}) do
        local maxNc = (tonumber(pl.numSlices) or 16) - 1
        for c = 0, maxNc do
            local s = pl.slices and pl.slices[c]
            if s and s.ifaceAddr and s.ifaceAddr ~= "" then
                total = total + 1
            end
        end
    end
    return total
end

local TAB_OVERVIEW = 1
local TAB_SLICES   = 2
local TAB_POOLS    = 3
local TAB_SETUP    = 4

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

local padOrTrunc = Common.padOrTrunc

function UI.formatNumber(n, isFluid)
    n = tonumber(n) or 0
    local absN = math.abs(n)
    local suf = isFluid and "L" or ""
    if absN >= 1e9 then return string.format("%.2fB%s", n / 1e9, suf)
    elseif absN >= 1e6 then return string.format("%.1fM%s", n / 1e6, suf)
    elseif absN >= 1e3 then return string.format("%.1fK%s", n / 1e3, suf)
    else return string.format("%d%s", math.floor(n + 0.5), suf)
    end
end

function UI.formatEta(sec)
    if sec == nil then return "--" end
    sec = math.max(0, math.floor(tonumber(sec) or 0))
    if sec == 0 then return "0s" end
    local h = math.floor(sec / 3600)
    local m = math.floor((sec % 3600) / 60)
    local s = sec % 60
    if h >= 1 then return string.format("%dh%02dm", h, m)
    elseif m >= 1 then return string.format("%dm%02ds", m, s)
    else return string.format("%ds", s)
    end
end

function UI.new(cfg, state, onSave, compLib)
    local cl = compLib or component
    local gpu = cl.isAvailable and cl.isAvailable("gpu") and cl.gpu or (cl.list and cl.list("gpu", true)() and cl.proxy(cl.list("gpu", true)()))
    local w, h = 160, 50

    local self = setmetatable({
        cfg = cfg,
        state = state,
        onSave = onSave,
        comp = cl,
        gpu = gpu,
        w = w,
        h = h,
        tab = TAB_OVERVIEW,
        running = true,
        selectedPoolIdx = 1,
        selectedColor = 0,
        selectedChIdx = 1,
        setupChIdx = 1,
        sliceBank = 0,
        ifacePage = 0,
        queueScroll = 0,
        logModalActive = false,
        logModalTab = 1,
        logModalScroll = 0,
        promptActive = false,
        promptTitle = "",
        promptBuffer = "",
        promptCallback = nil,
        guidedDropActive = false,
        guidedDropSnap = nil,
        statusMsg = "Ready. Press [PAUSED] or Space to arm.",
        hitboxes = {},
        curBuf = {},
        nxtBuf = {},
    }, { __index = UI })

    local curBuf, nxtBuf = self.curBuf, self.nxtBuf
    for i = 1, self.w * self.h do
        curBuf[i] = -1
        nxtBuf[i] = 0
    end
    self:syncDisplay(true)
    return self
end

function UI:syncDisplay(forceRedraw)
    return Common.syncDisplay(self, {
        forceRedraw = forceRedraw,
        onResize = function(aw, ah)
            local curBuf, nxtBuf = {}, {}
            for i = 1, aw * ah do
                curBuf[i] = -1
                nxtBuf[i] = 0
            end
            self.curBuf = curBuf
            self.nxtBuf = nxtBuf
        end,
    })
end

function UI:save(msg)
    if self.onSave then self.onSave(self.cfg) end
    if msg then self.statusMsg = msg end
end

function UI:invalidateScreen()
    local curBuf = self.curBuf
    for i = 1, self.w * self.h do
        curBuf[i] = -1
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
    if Common.checkViewportDrift(self, function(f) return self:syncDisplay(f) end, function() self:render() end) then
        return
    end
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

function UI:openTextPrompt(title, initial, cb)
    self.promptActive = true
    self.promptTitle = title or "Enter Value:"
    self.promptBuffer = tostring(initial or "")
    self.promptCallback = cb
end

function UI:selectedPool()
    local n = #(self.cfg.pools or {})
    if n == 0 then return nil, 0 end
    self.selectedPoolIdx = math.max(1, math.min(n, self.selectedPoolIdx or 1))
    local pool = self.cfg.pools[self.selectedPoolIdx]
    if pool then
        local maxNc = (tonumber(pool.numSlices) or 16) - 1
        if (self.selectedColor or 0) > maxNc then
            self.selectedColor = 0
        end
        if maxNc < 16 then
            self.sliceBank = 0
        end
        self.selectedChIdx = math.max(1, math.min(#(pool.channels or {}), self.selectedChIdx or 1))
        self.setupChIdx = math.max(1, math.min(#(pool.channels or {}), self.setupChIdx or 1))
    end
    return pool, self.selectedPoolIdx
end

function UI:startGuidedDrop()
    local pool = self:selectedPool()
    if not pool then return false end
    local unbound = unboundNonMainnetAddrs(pool, self.state.discovery and self.state.discovery.interfaces)
    local targetNc = nextUnboundSlice(pool, self.selectedColor)
    if #unbound == 0 or targetNc == nil then
        self.guidedDropActive = false
        self.guidedDropSnap = nil
        self.statusMsg = "Guided Drop: all slices or non-mainnet interfaces are already bound."
        return false
    end
    self.selectedColor = targetNc
    self.sliceBank = math.floor(targetNc / 16)
    self.guidedDropActive = true
    Hardware.setGuidedSubscriptions(unbound, true, self.comp, self.state)
    self.guidedDropSnap = Hardware.snapshotInterfaces(unbound, self.comp)
    local ci = Hardware.COLORS[targetNc % 16]
    self.statusMsg = string.format("Guided Drop -> NC %02d (%s): Drop 1 item into an unbound Waiting Room!",
        targetNc, ci and ci.name or targetNc)
    return true
end

function UI:stopGuidedDrop(reasonMsg)
    self.guidedDropActive = false
    self.guidedDropSnap = nil
    Hardware.setGuidedSubscriptions(nil, false, self.comp, self.state)
    if reasonMsg then
        self.statusMsg = reasonMsg
    end
end

function UI:stepGuidedDrop()
    if not self.guidedDropActive then return false end
    local pool = self:selectedPool()
    if not pool then
        self:stopGuidedDrop()
        return false
    end
    local unbound = unboundNonMainnetAddrs(pool, self.state.discovery and self.state.discovery.interfaces)
    if #unbound == 0 then
        self:stopGuidedDrop("Guided Drop done: no unbound interfaces left.")
        playBeep(1320, 0.12)
        return true
    end
    if not self.guidedDropSnap then
        self.guidedDropSnap = Hardware.snapshotInterfaces(unbound, self.comp)
        return false
    end
    local hitAddr, _, hitMeta = Hardware.detectChangedInterface(unbound, self.guidedDropSnap, self.comp)
    if hitAddr then
        local targetNc = nextUnboundSlice(pool, self.selectedColor)
        if targetNc ~= nil then
            local slice = pool.slices[targetNc]
            slice.ifaceAddr = hitAddr
            if isDefaultSliceLabel(slice, targetNc) then
                local suggested = Hardware.suggestNcLabel(hitMeta)
                if suggested and suggested ~= "" then
                    slice.label = suggested
                end
            end
            Scheduler.refreshSubscriptions(self.cfg, self.state, self.comp)

            local rem = {}
            for _, a in ipairs(unbound) do
                if a ~= hitAddr then rem[#rem + 1] = a end
            end
            local nextNc = nextUnboundSlice(pool, targetNc)
            if #rem == 0 or nextNc == nil then
                self.selectedColor = targetNc
                self.sliceBank = math.floor(targetNc / 16)
                self:stopGuidedDrop(string.format("Guided Drop complete! Bound NC %02d (%s) -> %s",
                    targetNc, slice.label, Hardware.shortAddr(hitAddr)))
                self:save()
                playBeep(1320, 0.12)
            else
                self.selectedColor = nextNc
                self.sliceBank = math.floor(nextNc / 16)
                self.guidedDropSnap = Hardware.snapshotInterfaces(rem, self.comp)
                local nextCi = Hardware.COLORS[nextNc % 16]
                self:save(string.format("Bound NC %02d (%s) -> %s | Next: NC %02d (%s)",
                    targetNc, slice.label, Hardware.shortAddr(hitAddr), nextNc, nextCi and nextCi.name or nextNc))
                playBeep(880, 0.08)
            end
            return true
        else
            self:stopGuidedDrop("Guided Drop done: all NC slots bound.")
            playBeep(1320, 0.12)
            return true
        end
    end
    return false
end

function UI:renderHeader()
    self:fillRect(1, 1, self.w, 2, " ", COLORS.headerBg)
    self:drawText(2, 1, "◈ GTNH UNIVERSAL CONTROL", COLORS.accent, COLORS.headerBg)

    local armed = (self.cfg.armed == true)
    local nx = self:drawButton(28, 1, armed and "[ARMED ]" or "[PAUSED]",
        armed and COLORS.fg or COLORS.yellow,
        armed and COLORS.darkGreen or COLORS.amberBg,
        function()
            self.cfg.armed = not armed
            if not self.cfg.armed then
                Scheduler.allOff(self.cfg, self.state, nil, self.comp)
                self:save("Paused: all bundled redstone forced OFF.")
            else
                self.state._forcePollNow = true
                self:save("Armed: universal toggle scheduler active.")
            end
        end) + 2

    local kpis = self.state.kpis or {}
    local evTag = (self.state._allSubscribed and "EvSub" or "Poll")
    local summary = string.format("Pools:%d/%d  Queued:%d  Stalled:%d  Done:%d  Preempt:%d  [%s]",
        kpis.activePools or 0, #(self.cfg.pools or {}), kpis.queuedSlices or 0,
        kpis.stalledCount or 0, kpis.completedBatches or 0, kpis.preemptions or 0, evTag)
    self:drawText(nx, 1, padOrTrunc(summary, self.w - nx - 33), COLORS.muted, COLORS.headerBg)

    local rx = self.w - 31
    rx = self:drawButton(rx, 1, "[Poll]", COLORS.cyan, COLORS.btnBg, function()
        self.state._forcePollNow = true
        self.state._forceFullScan = true
        self.statusMsg = "Manual full-scan poll requested."
    end) + 1
    rx = self:drawButton(rx, 1, "[All OFF]", COLORS.red, COLORS.darkRed, function()
        Scheduler.allOff(self.cfg, self.state, nil, self.comp)
        self:save("Emergency All OFF triggered.")
    end) + 1
    rx = self:drawButton(rx, 1, "[Log]", COLORS.fg, COLORS.btnBg, function()
        self.logModalActive = true
        self.logModalScroll = 0
    end) + 1
    self:drawButton(rx, 1, "[Quit]", COLORS.red, COLORS.btnBg, function()
        if self.guidedDropActive then self:stopGuidedDrop() end
        Scheduler.allOff(self.cfg, self.state, nil, self.comp)
        self:save("Saved and turned outputs OFF.")
        self.running = false
    end)

    local tabs = {
        { id = TAB_OVERVIEW, label = "[1] OVERVIEW" },
        { id = TAB_SLICES,   label = "[2] SLICES" },
        { id = TAB_POOLS,    label = "[3] POOLS & RULES" },
        { id = TAB_SETUP,    label = "[4] SETUP & WIRING" },
    }
    local tx = 2
    for _, tb in ipairs(tabs) do
        local act = (self.tab == tb.id)
        tx = self:drawButton(tx, 2, tb.label,
            act and COLORS.fg or COLORS.muted,
            act and COLORS.btnActiveBg or COLORS.headerBg,
            function() self.tab = tb.id end) + 2
    end

    if self.guidedDropActive then
        local poolG = self:selectedPool()
        local nxtNc = poolG and nextUnboundSlice(poolG, self.selectedColor)
        local ciG = (nxtNc ~= nil) and Hardware.COLORS[nxtNc % 16] or nil
        local gTxt = (nxtNc ~= nil)
            and string.format("[GUIDED DROP -> NC %02d (%s): Drop item... Stop]", nxtNc, ciG and ciG.name or nxtNc)
            or "[GUIDED DROP: Waiting for item in unbound subnet... Stop]"
        self:drawButton(self.w - unicode.wlen(gTxt) - 1, 2, gTxt, COLORS.yellow, COLORS.amberBg, function()
            self:stopGuidedDrop("Guided Drop Pairing stopped.")
        end)
    else
        local warnCnt = #((self.state.discovery and self.state.discovery.partWarnings) or {})
        if warnCnt > 0 then
            local wTxt = string.format("! %d Flat Part IF Warning", warnCnt)
            self:drawButton(self.w - unicode.wlen(wTxt) - 1, 2, wTxt, COLORS.yellow, COLORS.amberBg, function()
                self.tab = TAB_SETUP
            end)
        end
    end

    self:drawText(1, 3, string.rep("─", self.w), COLORS.border, COLORS.bg)
end

function UI:renderOverviewTab()
    local kpis = self.state.kpis or {}
    local disc = self.state.discovery or {}
    local pools = self.cfg.pools or {}
    local p1Mode = (pools[1] and tostring(pools[1].mode or "mlfq"):upper()) or "MLFQ"

    local cards = {
        { title = " ACTIVE POOLS ", val = string.format("%d / %d", kpis.activePools or 0, #pools), sub = self.cfg.armed and "Scheduler Armed" or "Safely Paused", col = self.cfg.armed and COLORS.green or COLORS.yellow },
        { title = " QUEUED SLICES ", val = tostring(kpis.queuedSlices or 0), sub = string.format("Mode:%s | Probe:%.1fs | Pre:%.2fx", p1Mode, self.cfg.probeWindowSec or 1.5, self.cfg.preemptRatio or 0.35), col = COLORS.cyan },
        { title = " COMPLETED ", val = tostring(kpis.completedBatches or 0), sub = string.format("Preemptions: %d | Stalled: %d", kpis.preemptions or 0, kpis.stalledCount or 0), col = (kpis.stalledCount or 0) > 0 and COLORS.red or COLORS.green },
        { title = " HARDWARE & EVENTS ", val = string.format("RS:%d IF:%d Scans:%d", #(disc.redstones or {}), #(disc.interfaces or {}), kpis.scanCalls or 0), sub = string.format("%s | Ext:%s", self.state._allSubscribed and "Push EvSub (0-idle)" or "Polling", self.cfg.extLinkMode == "off" and "Standalone" or "Mesh"), col = (#(disc.partWarnings or {}) > 0) and COLORS.yellow or COLORS.accent },
    }
    for i = 1, 4 do
        local cx = 2 + (i - 1) * 40
        local cw = 38
        local c = cards[i]
        self:drawFrame(cx, 5, cw, 4, COLORS.border, COLORS.panelBg, "round")
        self:drawText(cx + 2, 5, c.title, COLORS.accent, COLORS.panelBg)
        self:drawText(cx + 3, 6, padOrTrunc(c.val, cw - 6), c.col, COLORS.panelBg)
        self:drawText(cx + 3, 7, padOrTrunc(c.sub, cw - 6), COLORS.muted, COLORS.panelBg)
    end

    -- Pool Cards (up to 2 wide, y=10..18)
    self:drawText(2, 10, "◈ MULTI-CHANNEL BUNDLED POOLS", COLORS.accent, COLORS.bg)
    local showPools = math.min(2, #pools)
    local pW = (showPools == 1) and 158 or 78
    for i = 1, showPools do
        local pool = pools[i]
        local pst = (self.state.poolStates and self.state.poolStates[pool.id]) or {}
        local px = 2 + (i - 1) * 80
        self:drawFrame(px, 11, pW, 8, COLORS.border, COLORS.panelBg, "round")
        self:drawText(px + 2, 11, " " .. padOrTrunc(pool.name, 20) .. " ", COLORS.accent, COLORS.panelBg)
        local ph = pst.phase or "IDLE"
        local phCol = (ph == "ACTIVE") and COLORS.green or ((ph == "SETTLING" or ph == "PULSE_TEST") and COLORS.yellow or ((ph == "PAUSED" or ph == "NO_RS") and COLORS.red or COLORS.muted))
        self:drawText(px + pW - 12, 11, " " .. padOrTrunc(ph, 8) .. " ", phCol, COLORS.panelBg)

        local nCh = #(pool.channels or {})
        local rsTxt = string.format("Policy:%s  Slices:%d  Ch:%d  RS:%s (%s)",
            tostring(pool.mode):upper(), tonumber(pool.numSlices) or 16, nCh,
            Hardware.shortAddr(pool.rsAddr), Hardware.SIDE_NAMES[pool.side] or "?")
        self:drawText(px + 3, 13, padOrTrunc(rsTxt, pW - 6), COLORS.muted, COLORS.panelBg)

        if nCh <= 1 then
            local cs1 = pst.channels and pst.channels[1]
            local ch1 = pool.channels and pool.channels[1]
            local di1 = Policy.dyeInfo(ch1 and ch1.gtDye or 0)
            local actNc = (cs1 and cs1.activeNc) or pst.activeColor
            if actNc ~= nil then
                local ci = Hardware.COLORS[actNc % 16]
                self:drawText(px + 3, 15, "■", di1.hex == 0x21262D and COLORS.fg or di1.hex, COLORS.panelBg)
                self:drawText(px + 5, 15, string.format("Ch1 NC %02d [%-9s]", actNc, ci and ci.name or "?"), COLORS.fg, COLORS.panelBg)
                self:drawText(px + 26, 15, "■", ci and ci.hex or COLORS.fg, COLORS.panelBg)
                local ss = self.state.sliceStates and self.state.sliceStates[Scheduler.sliceKey(pool.id, actNc)]
                local tStr = ss and tostring(ss.tier or "BULK") or "BULK"
                self:drawText(px + 29, 15, padOrTrunc(string.format("[%s] %s", tStr, tostring(pst.activeLabel or "")), pW - 32), COLORS.cyan, COLORS.panelBg)
                local held = (self.state.lastStepSec or 0) - ((cs1 and cs1.activeSince) or pst.activeSince or 0)
                local rTxt = string.format("ETA: %-8s  Rate: %.1f/s  Hold: %ds",
                    UI.formatEta(pst.activeEtaSec), tonumber(pst.activeRate) or 0, math.max(0, math.floor(held)))
                self:drawText(px + 3, 17, padOrTrunc(rTxt, pW - 6), COLORS.green, COLORS.panelBg)
            elseif ph == "SETTLING" then
                local pNc = tonumber(pst.pendingColor) or 0
                self:drawText(px + 3, 15, string.format("ALL OFF Settle Guard -> NC %02d (%s)",
                    pNc, (Hardware.COLORS[pNc % 16] and Hardware.COLORS[pNc % 16].name or "?")),
                    COLORS.yellow, COLORS.panelBg)
            else
                self:drawText(px + 3, 15, "No active craft slice.", COLORS.muted, COLORS.panelBg)
            end
        else
            local ordered = Policy.orderedEnabledChannels(pool)
            local seen = {}
            for _, ciIdx in ipairs(ordered) do seen[ciIdx] = true end
            for ciIdx = 1, nCh do if not seen[ciIdx] then ordered[#ordered + 1] = ciIdx end end

            for rowPos = 1, math.min(4, #ordered) do
                local ciIdx = ordered[rowPos]
                local ch = pool.channels[ciIdx]
                local cs = pst.channels and pst.channels[ciIdx] or {}
                local di = Policy.dyeInfo(ch and ch.gtDye)
                local ryCh = 14 + rowPos
                self:drawText(px + 3, ryCh, "■", di.hex == 0x21262D and COLORS.fg or di.hex, COLORS.panelBg)
                local rankStr = (di.gtDye >= 0) and string.format("#%d", di.rank) or "UNP"
                if cs.phase == "ACTIVE" and cs.activeNc ~= nil then
                    local ss = self.state.sliceStates and self.state.sliceStates[Scheduler.sliceKey(pool.id, cs.activeNc)]
                    local tier = ss and tostring(ss.tier or "BULK") or "BULK"
                    local cLine = string.format("P%d Ch%d(%s %-4s): NC%02d %s (%s %s)",
                        rowPos, ciIdx, rankStr, padOrTrunc(di.short, 4), cs.activeNc, padOrTrunc(cs.activeLabel, 13),
                        tier, UI.formatEta(cs.activeEtaSec))
                    self:drawText(px + 5, ryCh, padOrTrunc(cLine, pW - 8), COLORS.green, COLORS.panelBg)
                elseif cs.phase == "SETTLING" then
                    self:drawText(px + 5, ryCh, padOrTrunc(string.format("P%d Ch%d(%s): SETTLING -> NC%02d",
                        rowPos, ciIdx, rankStr, tonumber(cs.pendingNc) or 0), pW - 8), COLORS.yellow, COLORS.panelBg)
                else
                    self:drawText(px + 5, ryCh, padOrTrunc(string.format("P%d Ch%d(%s %-4s): %s (Pre-settled)",
                        rowPos, ciIdx, rankStr, padOrTrunc(di.short, 4), tostring(cs.phase or "IDLE")), pW - 8), COLORS.muted, COLORS.panelBg)
                end
            end
        end
    end

    -- Priority Queue (y = 20..48)
    self:drawText(2, 20, "◈ SCHEDULER QUEUE (TIER / PRIORITY / ETA)", COLORS.accent, COLORS.bg)
    self:drawFrame(2, 21, 158, 27, COLORS.border, COLORS.panelBg, "round")
    self:drawText(4, 22, "Pool       Col Slice          Pri  Tier  Ch   Items    Fluids   Top Ingredient       Rate    ETA     State       Action", COLORS.muted, COLORS.panelBg)
    self:drawText(3, 23, string.rep("─", 156), COLORS.border, COLORS.panelBg)

    local q = self.state.queue or {}
    local maxShow = 22
    self.queueScroll = math.max(0, math.min(math.max(0, #q - maxShow), self.queueScroll or 0))
    if #q == 0 then
        local totalBound = countTotalBoundSlices(pools)
        if totalBound == 0 then
            local p1 = pools[1]
            local ch1 = p1 and p1.channels and p1.channels[1]
            local b1 = ch1 and ch1.banks and ch1.banks[1]
            local roomCount = 0
            for _, inf in ipairs(disc.interfaces or {}) do
                if not inf.isMainnet then roomCount = roomCount + 1 end
            end

            self:drawText(4, 24, "◈ QUICK-START WIZARD (0 BOUND WAITING ROOMS YET)", COLORS.cyan, COLORS.panelBg)
            self:drawText(4, 25, "Follow these 3 quick steps to start universal craft dispatching:", COLORS.muted, COLORS.panelBg)

            local rsShort = Hardware.shortAddr(b1 and b1.rsAddr or (p1 and p1.rsAddr))
            local sSide = (b1 and b1.side) or (p1 and p1.side) or 2
            self:drawText(4, 27, string.format("1. Bundled Redstone Wire : Pool 1 Ch1 -> RS %s (%s)", rsShort, Hardware.SIDE_NAMES[sSide] or "?"),
                COLORS.fg, COLORS.panelBg)
            local xStep1 = self:drawButton(68, 27, "[Side: " .. (Hardware.SIDE_NAMES[sSide] or "?") .. "]", COLORS.cyan, COLORS.btnBg, function(step)
                if p1 and b1 then
                    Hardware.zeroAllManagedPools(self.cfg, self.comp, self.state)
                    b1.side = (b1.side + (step or 1) + 6) % 6
                    p1.side = b1.side
                    self:save("Pool 1 Ch1 Side -> " .. (Hardware.SIDE_NAMES[b1.side] or b1.side))
                end
            end) + 2
            xStep1 = self:drawButton(xStep1, 27, "[Pulse NC 00 (2s)]", COLORS.yellow, COLORS.amberBg, function()
                if p1 then
                    local okP, errP = Scheduler.triggerPulseTest(self.cfg, self.state, p1.id, 0, 2.0, self.state.lastStepSec or 0, self.comp, 1)
                    if not okP then self.statusMsg = tostring(errP) end
                end
            end) + 2
            self:drawButton(xStep1, 27, "[Pools Tab]", COLORS.fg, COLORS.btnBg, function() self.tab = TAB_POOLS end)

            self:drawText(4, 30, string.format("2. Pair Waiting Rooms    : %d non-mainnet full-block Dual IF(s) ready", roomCount),
                roomCount > 0 and COLORS.green or COLORS.yellow, COLORS.panelBg)
            local xStep2 = self:drawButton(68, 30, self.guidedDropActive and "[Stop Guided Drop]" or "[▶ Guided Drop Pair]",
                self.guidedDropActive and COLORS.yellow or COLORS.purple, COLORS.btnBg, function()
                    if self.guidedDropActive then
                        self:stopGuidedDrop("Guided Drop stopped.")
                    else
                        self:startGuidedDrop()
                    end
                end) + 2
            xStep2 = self:drawButton(xStep2, 30, "[Auto-Bind Discovered]", COLORS.cyan, COLORS.btnBg, function()
                if not p1 then return end
                local bound = 0
                local maxS = tonumber(p1.numSlices) or 16
                for _, inf in ipairs(disc.interfaces or {}) do
                    if not inf.isMainnet then
                        p1.slices[bound].ifaceAddr = inf.address
                        bound = bound + 1
                        if bound >= maxS then break end
                    end
                end
                Scheduler.refreshSubscriptions(self.cfg, self.state, self.comp)
                self:save(string.format("Auto-bound %d Waiting Room(s) -> NC 00..%02d.", bound, math.max(0, bound - 1)))
            end) + 2
            self:drawButton(xStep2, 30, "[Open Setup Tab]", COLORS.fg, COLORS.btnBg, function() self.tab = TAB_SETUP end)

            self:drawText(4, 33, "3. Arm Automation        : Safely start once wires & interfaces are bound", COLORS.fg, COLORS.panelBg)
            self:drawButton(68, 33, self.cfg.armed and "[Scheduler Armed ✓]" or "[Arm Scheduler]",
                self.cfg.armed and COLORS.green or COLORS.fg, self.cfg.armed and COLORS.darkGreen or COLORS.btnActiveBg, function()
                    self.cfg.armed = true
                    self.state._forcePollNow = true
                    self:save("Armed: universal toggle scheduler active.")
                end)
        else
            self:drawText(4, 25, "All bound NC subnets are empty (Idle - 0 tick scan overhead).", COLORS.muted, COLORS.panelBg)
        end
    else
        for r = 1, math.min(maxShow, #q - self.queueScroll) do
            local item = q[r + self.queueScroll]
            local ry = 23 + r
            local ci = Hardware.COLORS[item.color % 16]
            local stTxt, stCol = "Queued", COLORS.cyan
            if item.isActive then stTxt, stCol = "ACTIVE", COLORS.green
            elseif item.isPending then stTxt, stCol = "SETTLING", COLORS.yellow
            elseif item.isStalled then stTxt, stCol = "STALLED", COLORS.red
            end
            local chStr = item.activeChannel and ("Ch" .. item.activeChannel)
                or (item.pendingChannel and ("~C" .. item.pendingChannel) or "-")
            self:drawText(4, ry, padOrTrunc(item.poolName, 10), COLORS.fg, COLORS.panelBg)
            self:drawText(15, ry, "■", ci and ci.hex or COLORS.fg, COLORS.panelBg)
            self:drawText(17, ry, string.format("%02d", item.color), COLORS.muted, COLORS.panelBg)
            self:drawText(20, ry, padOrTrunc(item.label, 14), COLORS.fg, COLORS.panelBg)
            self:drawText(35, ry, padOrTrunc(tostring(item.priority):upper(), 4), COLORS.purple, COLORS.panelBg)
            self:drawText(40, ry, padOrTrunc(tostring(item.tier or "BULK"), 5),
                item.tier == "PROBE" and COLORS.cyan or COLORS.muted, COLORS.panelBg)
            self:drawText(46, ry, padOrTrunc(chStr, 4), COLORS.green, COLORS.panelBg)
            self:drawText(51, ry, padOrTrunc(UI.formatNumber(item.itemUnits, false), 8), COLORS.fg, COLORS.panelBg)
            self:drawText(60, ry, padOrTrunc(UI.formatNumber(item.fluidUnits, true), 8), COLORS.cyan, COLORS.panelBg)
            self:drawText(69, ry, padOrTrunc(item.topLabel, 20), COLORS.muted, COLORS.panelBg)
            self:drawText(90, ry, padOrTrunc(string.format("%.1f/s", item.rate or 0), 7), COLORS.muted, COLORS.panelBg)
            self:drawText(98, ry, padOrTrunc(UI.formatEta(item.etaSec), 7), COLORS.yellow, COLORS.panelBg)
            self:drawText(106, ry, padOrTrunc(stTxt, 11), stCol, COLORS.panelBg)

            local poolForced = self.state.forceColorByPool and self.state.forceColorByPool[item.poolId] == item.color
            local bx = self:drawButton(118, ry, poolForced and "[Unforce]" or "[Force]",
                poolForced and COLORS.yellow or COLORS.cyan, COLORS.btnBg,
                function()
                    self.state.forceColorByPool[item.poolId] = poolForced and nil or item.color
                    self.state._forcePollNow = true
                    self:save(poolForced and "Cleared manual force." or string.format("Forced %s NC %02d.", item.poolName, item.color))
                end) + 1
            if item.isStalled then
                self:drawButton(bx, ry, "[Clear Stall]", COLORS.yellow, COLORS.amberBg, function()
                    Scheduler.clearStall(self.cfg, self.state, item.poolId, item.color)
                    self.state._forcePollNow = true
                    self:save("Cleared stall on NC " .. tostring(item.color))
                end)
            end
        end
    end
end

function UI:renderSlicesTab()
    local pools = self.cfg.pools or {}
    local pool, poolIdx = self:selectedPool()
    local bx = 2
    for i = 1, #pools do
        local sel = (i == poolIdx)
        bx = self:drawButton(bx, 5, "[" .. padOrTrunc(pools[i].name, 14) .. "]",
            sel and COLORS.fg or COLORS.muted,
            sel and COLORS.btnActiveBg or COLORS.btnBg,
            function() self.selectedPoolIdx = i end) + 1
    end
    bx = self:drawButton(bx + 1, 5, "[+ Add Pool]", COLORS.green, COLORS.btnBg, function()
        local nxtId = 1
        for i = 1, #self.cfg.pools do nxtId = math.max(nxtId, (self.cfg.pools[i].id or i) + 1) end
        self.cfg.pools[#self.cfg.pools + 1] = Scheduler.newPool(nxtId, "Pool " .. nxtId, nil, (nxtId + 1) % 6)
        self.selectedPoolIdx = #self.cfg.pools
        self:save("Added Pool " .. nxtId)
    end)

    if not pool then return end

    if (tonumber(pool.numSlices) or 16) == 32 then
        self:drawButton(122, 5, self.sliceBank == 0 and "[Bank A: 00-15]" or " Bank A: 00-15 ",
            self.sliceBank == 0 and COLORS.fg or COLORS.muted,
            self.sliceBank == 0 and COLORS.btnActiveBg or COLORS.btnBg,
            function() self.sliceBank = 0 end)
        self:drawButton(139, 5, self.sliceBank == 1 and "[Bank B: 16-31]" or " Bank B: 16-31 ",
            self.sliceBank == 1 and COLORS.fg or COLORS.muted,
            self.sliceBank == 1 and COLORS.btnActiveBg or COLORS.btnBg,
            function() self.sliceBank = 1 end)
    end

    -- 16-Row Matrix for current Bank (y=7..25)
    self:drawFrame(2, 7, 158, 19, COLORS.border, COLORS.panelBg, "round")
    self:drawText(4, 8, "NC Swatch     Label            Interface    Pri   Status       Work (Items / Fluids)    Base  Rate     ETA      Tier", COLORS.muted, COLORS.panelBg)
    local pst = (self.state.poolStates and self.state.poolStates[pool.id]) or {}
    local discIfs = (self.state.discovery and self.state.discovery.interfaces) or {}
    local bankOffset = (self.sliceBank or 0) * 16

    for row = 0, 15 do
        local nc = bankOffset + row
        local slice = pool.slices[nc]
        if slice then
            local sState = (self.state.sliceStates and self.state.sliceStates[Scheduler.sliceKey(pool.id, nc)]) or {}
            local ci = Hardware.COLORS[nc % 16]
            local ry = 9 + row
            local isSel = (nc == (self.selectedColor or 0))
            local rowBg = isSel and COLORS.selectedBg or ((row % 2 == 0) and COLORS.panelBg or COLORS.rowAltBg)
            self:fillRect(3, ry, 156, 1, " ", rowBg)

            self:drawText(4, ry, string.format("%02d", nc), COLORS.muted, rowBg)
            self:drawText(7, ry, "■", ci.hex, rowBg)
            self:drawText(9, ry, padOrTrunc(ci.name, 9), ci.hex == 0x21262D and COLORS.fg or ci.hex, rowBg)
            self:drawText(19, ry, padOrTrunc(slice.label, 16), COLORS.fg, rowBg)
            self:drawText(36, ry, slice.ifaceAddr and Hardware.shortAddr(slice.ifaceAddr) or "--",
                slice.ifaceAddr and COLORS.cyan or COLORS.muted, rowBg)
            self:drawText(49, ry, padOrTrunc(tostring(slice.priority):upper(), 5), COLORS.purple, rowBg)

            local actCh, pendCh, pulseCh = nil, nil, nil
            for chIdx, cs in ipairs(pst.channels or {}) do
                if cs.phase == "ACTIVE" and cs.activeNc == nc then actCh = chIdx
                elseif cs.phase == "SETTLING" and cs.pendingNc == nc then pendCh = chIdx
                elseif cs.phase == "PULSE_TEST" and cs.pulseNc == nc then pulseCh = chIdx
                end
            end

            local stStr, stCol = "Unbound", COLORS.muted
            if slice.ifaceAddr then
                if actCh then stStr, stCol = "ACT:Ch" .. actCh, COLORS.green
                elseif pulseCh then stStr, stCol = "PULSE:C" .. pulseCh, COLORS.yellow
                elseif pendCh then stStr, stCol = "SETL:C" .. pendCh, COLORS.yellow
                elseif sState.stalledUntil and (self.state.lastStepSec or 0) < sState.stalledUntil then stStr, stCol = "STALL", COLORS.red
                elseif slice.enabled == false or slice.priority == "off" then stStr, stCol = "Off", COLORS.muted
                elseif (sState.workScore or 0) > 0 then stStr, stCol = "Queued", COLORS.cyan
                else stStr, stCol = "Idle", COLORS.fg
                end
            end
            self:drawText(55, ry, padOrTrunc(stStr, 11), stCol, rowBg)

            local wStr = slice.ifaceAddr
                and string.format("%-8s / %-8s", UI.formatNumber(sState.itemUnits or 0, false), UI.formatNumber(sState.fluidUnits or 0, true))
                or "--"
            self:drawText(67, ry, padOrTrunc(wStr, 24), COLORS.fg, rowBg)

            local bCnt = 0
            for _ in pairs(slice.baselineItems or {}) do bCnt = bCnt + 1 end
            for _ in pairs(slice.baselineFluids or {}) do bCnt = bCnt + 1 end
            self:drawText(92, ry, bCnt > 0 and string.format("%dNC", bCnt) or "-", bCnt > 0 and COLORS.cyan or COLORS.muted, rowBg)
            self:drawText(97, ry, slice.learnedRate and string.format("%.1f/s", slice.learnedRate) or "--", COLORS.muted, rowBg)
            self:drawText(106, ry, (sState.workScore or 0) > 0 and UI.formatEta(sState.etaSec) or "--", COLORS.yellow, rowBg)
            self:drawText(115, ry, (sState.workScore or 0) > 0 and tostring(sState.tier or "BULK") or "--",
                sState.tier == "PROBE" and COLORS.cyan or COLORS.muted, rowBg)

            self:addHitbox(3, ry, 158, ry, function() self.selectedColor = nc end)
        end
    end

    -- Selected Slice Inspector (y=27..48)
    local selC = self.selectedColor or 0
    local sel = pool.slices[selC]
    if not sel then return end
    local sci = Hardware.COLORS[selC % 16]
    self:drawFrame(2, 27, 158, 21, COLORS.border, COLORS.panelBg, "round")
    self:drawText(4, 27, string.format(" ◈ INSPECTOR: NC %02d (%s) ", selC, sci.name), COLORS.accent, COLORS.panelBg)

    local ix = self:drawButton(4, 29, "[Rename: " .. padOrTrunc(sel.label, 16) .. "]", COLORS.fg, COLORS.btnBg, function()
        self:openTextPrompt("Slice Label (e.g. Circuit 1 / Pink Catalyst / Extruder Plate):", sel.label, function(v)
            if v and v ~= "" then
                sel.label = v
                self:save("Renamed NC " .. selC .. " -> " .. v)
            end
        end)
    end) + 2

    ix = self:drawButton(ix, 29, "[Pri: " .. tostring(sel.priority):upper() .. "]", COLORS.purple, COLORS.btnBg, function()
        local cur = 1
        for k, p in ipairs(Scheduler.PRIORITY_ORDER) do if p == sel.priority then cur = k break end end
        sel.priority = Scheduler.PRIORITY_ORDER[(cur % #Scheduler.PRIORITY_ORDER) + 1]
        self:save("Priority NC " .. selC .. " -> " .. sel.priority)
    end) + 2

    ix = self:drawButton(ix, 29, sel.enabled ~= false and "[Enabled: ON]" or "[Enabled: OFF]",
        sel.enabled ~= false and COLORS.green or COLORS.red, COLORS.btnBg, function()
            sel.enabled = not (sel.enabled ~= false)
            self:save("Slice NC " .. selC .. " enabled -> " .. tostring(sel.enabled))
        end) + 2

    local nCh = #(pool.channels or {})
    local pCh = math.max(1, math.min(nCh, self.selectedChIdx or 1))
    if nCh > 1 then
        ix = self:drawButton(ix, 29, "[Ch" .. pCh .. "]", COLORS.cyan, COLORS.btnBg, function()
            self.selectedChIdx = (pCh % nCh) + 1
        end) + 1
    end
    ix = self:drawButton(ix, 29, "[Pulse 2s]", COLORS.yellow, COLORS.amberBg, function()
        local okP, errP = Scheduler.triggerPulseTest(self.cfg, self.state, pool.id, selC, 2.0, self.state.lastStepSec or 0, self.comp, pCh)
        if not okP then self.statusMsg = tostring(errP) end
    end) + 2

    local isForced = self.state.forceColorByPool and self.state.forceColorByPool[pool.id] == selC
    ix = self:drawButton(ix, 29, isForced and "[Unforce]" or "[Force]", COLORS.cyan, COLORS.btnBg, function()
        self.state.forceColorByPool[pool.id] = isForced and nil or selC
        self.state._forcePollNow = true
        self:save(isForced and "Cleared force." or ("Forced NC " .. selC))
    end) + 2

    if sel.ifaceAddr then
        ix = self:drawButton(ix, 29, "[Calibrate NC]", COLORS.cyan, COLORS.btnBg, function()
            local okC, nI, nF = Hardware.calibrateBaseline(sel, { ignoreBuiltinNC = self.cfg.ignoreBuiltinNC }, self.comp)
            if okC then
                self:save(string.format("Calibrated NC%02d baseline (%d items, %d fluids).", selC, nI or 0, nF or 0))
            else
                self.statusMsg = "Calibrate failed: " .. tostring(nI)
            end
        end) + 2
        self:drawButton(ix, 29, "[Unbind]", COLORS.red, COLORS.btnBg, function()
            sel.ifaceAddr = nil
            Scheduler.refreshSubscriptions(self.cfg, self.state, self.comp)
            self:save("Unbound NC " .. selC)
        end)
    end

    -- Bindable interface picker list (y=31..44, paged 24 per page)
    self:drawText(4, 31, string.format("Bind Full-Block ME Dual Interface (%d discovered):", #discIfs), COLORS.muted, COLORS.panelBg)
    if #discIfs > 24 then
        local maxPg = math.floor((#discIfs - 1) / 24)
        self.ifacePage = math.max(0, math.min(maxPg, self.ifacePage or 0))
        self:drawButton(60, 31, "[<Prev]", COLORS.cyan, COLORS.btnBg, function() self.ifacePage = math.max(0, self.ifacePage - 1) end)
        self:drawButton(68, 31, "[Next>]", COLORS.cyan, COLORS.btnBg, function() self.ifacePage = math.min(maxPg, self.ifacePage + 1) end)
    else
        self.ifacePage = 0
    end

    if #discIfs == 0 then
        self:drawText(4, 33, "No valid full-block me_interface discovered yet. Attach OC Adapter to a FULL-BLOCK Dual Interface and Rescan.", COLORS.yellow, COLORS.panelBg)
    else
        local usedElsewhere = {}
        for _, pl in ipairs(self.cfg.pools) do
            for cc = 0, (pl.numSlices or 16) - 1 do
                local a = pl.slices[cc] and pl.slices[cc].ifaceAddr
                if a and not (pl.id == pool.id and cc == selC) then
                    usedElsewhere[a] = string.format("P%d:%02d", pl.id, cc)
                end
            end
        end
        local startIdx = (self.ifacePage or 0) * 24 + 1
        for k = 0, 23 do
            local idx = startIdx + k
            local inf = discIfs[idx]
            if not inf then break end
            local colIdx = k % 3
            local rowIdx = math.floor(k / 3)
            local bxIf = 4 + colIdx * 51
            local byIf = 33 + rowIdx
            local isBoundHere = (sel.ifaceAddr == inf.address)
            local tag = usedElsewhere[inf.address]
            local suffix = tag and (" (" .. tag .. ")")
                or (inf.isMainnet and " [MAINNET]" or (" (" .. tostring(inf.ctype or "free") .. ")"))
            local lbl = string.format("[%s %s%s]",
                isBoundHere and "✓" or " ",
                inf.shortAddr,
                suffix)
            self:drawButton(bxIf, byIf, padOrTrunc(lbl, 48),
                isBoundHere and COLORS.green or (inf.isMainnet and COLORS.yellow or (tag and COLORS.muted or COLORS.fg)),
                isBoundHere and COLORS.darkGreen or COLORS.btnBg,
                function()
                    sel.ifaceAddr = inf.address
                    Scheduler.refreshSubscriptions(self.cfg, self.state, self.comp)
                    self:save(string.format("Bound NC %02d -> %s", selC, inf.shortAddr))
                end)
        end
    end

    self:drawButton(4, 46, "[Clear Learned Baselines]", COLORS.yellow, COLORS.btnBg, function()
        sel.baselineItems = {}
        sel.baselineFluids = {}
        self:save("Cleared idle baseline on NC " .. selC)
    end)
    self:drawButton(31, 46, "[Reset Rate]", COLORS.muted, COLORS.btnBg, function()
        sel.learnedRate = nil
        self:save("Reset learned drain rate on NC " .. selC)
    end)
end

function UI:renderPoolsTab()
    local pool, poolIdx = self:selectedPool()
    local disc = self.state.discovery or {}
    local rsList = disc.redstones or {}

    -- Left Card: Pool & Multi-Channel Management
    self:drawFrame(2, 5, 78, 43, COLORS.border, COLORS.panelBg, "round")
    self:drawText(4, 5, " ◈ POOLS & INPUT CHANNELS ", COLORS.accent, COLORS.panelBg)
    if pool then
        self:drawButton(4, 7, "[Pool Name: " .. padOrTrunc(pool.name, 18) .. "]", COLORS.fg, COLORS.btnBg, function()
            self:openTextPrompt("Pool Name (e.g. LCR Pool / Extruder Bank):", pool.name, function(v)
                if v and v ~= "" then pool.name = v; self:save("Renamed pool -> " .. v) end
            end)
        end)
        self:drawButton(38, 7, pool.enabled ~= false and "[Pool: ON]" or "[Pool: OFF]",
            pool.enabled ~= false and COLORS.green or COLORS.red, COLORS.btnBg, function()
                pool.enabled = not (pool.enabled ~= false)
                self:save(pool.name .. " enabled -> " .. tostring(pool.enabled))
            end)
        local nSlices = tonumber(pool.numSlices) or 16
        self:drawButton(51, 7, string.format("[Capacity: %d NCs]", nSlices), COLORS.cyan, COLORS.btnBg, function()
            pool.numSlices = (nSlices == 16) and 32 or 16
            Scheduler.normalizeConfig(self.cfg)
            self:save(pool.name .. " capacity -> " .. tostring(pool.numSlices) .. " NCs")
        end)

        self:drawText(4, 9, "Policy:", COLORS.muted, COLORS.panelBg)
        self:drawButton(12, 9, "[" .. tostring(pool.mode):upper() .. "]", COLORS.purple, COLORS.btnBg, function()
            local cur = 1
            for k, m in ipairs(Scheduler.POOL_MODES) do if m == pool.mode then cur = k break end end
            pool.mode = Scheduler.POOL_MODES[(cur % #Scheduler.POOL_MODES) + 1]
            self:save(pool.name .. " mode -> " .. pool.mode)
        end)
        self:drawText(29, 9, "Channels:", COLORS.muted, COLORS.panelBg)
        self:drawButton(39, 9, "[+Ch]", COLORS.green, COLORS.btnBg, function()
            local nC = #(pool.channels or {})
            if nC < 4 then
                local sugDye, sugSide = Policy.suggestNextChannelDyeAndSide(pool)
                pool.channels[nC + 1] = Scheduler.newChannel(nC + 1, pool.rsAddr, sugSide, sugDye)
                self.selectedChIdx = nC + 1
                self:save(string.format("Added Input Channel %d (%s, Side %s) on %s.",
                    nC + 1, Policy.dyeInfo(sugDye).name, Hardware.SIDE_NAMES[sugSide] or sugSide, pool.name))
            end
        end)
        self:drawButton(46, 9, "[-Ch]", COLORS.red, COLORS.btnBg, function()
            local nC = #(pool.channels or {})
            if nC > 1 then
                Hardware.zeroAllManagedPools(self.cfg, self.comp, self.state)
                table.remove(pool.channels, nC)
                self.selectedChIdx = math.min(self.selectedChIdx, #pool.channels)
                self:save(string.format("Removed Input Channel %d from %s.", nC, pool.name))
            end
        end)

        -- Channel List sorted view (y=11..16)
        local ordered = Policy.orderedEnabledChannels(pool)
        local relRank = {}
        for pos, chIdx in ipairs(ordered) do
            relRank[chIdx] = string.format("P%d", pos)
        end
        self:drawText(4, 11, "Wire Priority = GT Hatch Color (0=Black #1 .. 15=White #16):", COLORS.muted, COLORS.panelBg)
        for ci, ch in ipairs(pool.channels or {}) do
            local ryC = 11 + ci
            local sel = (ci == self.selectedChIdx)
            local rowBg = sel and COLORS.selectedBg or COLORS.panelBg
            self:fillRect(4, ryC, 75, 1, " ", rowBg)
            local di = Policy.dyeInfo(ch.gtDye)
            local b1 = ch.banks and ch.banks[1] or {}
            local b2 = ch.banks and ch.banks[2] or {}
            local rTag = relRank[ci] or "OFF"
            self:drawText(4, ryC, sel and ">" or " ", COLORS.accent, rowBg)
            self:drawText(6, ryC, string.format("Ch%d", ci), sel and COLORS.fg or COLORS.cyan, rowBg)
            self:drawText(10, ryC, rTag, rTag == "P1" and COLORS.green or (rTag == "OFF" and COLORS.red or COLORS.yellow), rowBg)
            self:drawText(14, ryC, "■", di.hex == 0x21262D and COLORS.fg or di.hex, rowBg)
            local colorLbl = padOrTrunc(di.gtDye >= 0 and (di.name .. "#" .. di.rank) or "Unpainted", 13)
            self:drawText(16, ryC, colorLbl, di.gtDye < 0 and COLORS.yellow or COLORS.fg, rowBg)
            local restTxt = string.format("%-8s B1:%s(%s) B2:%s(%s)",
                padOrTrunc(ch.name, 8), Hardware.shortAddr(b1.rsAddr), Hardware.SIDE_NAMES[b1.side] or "?",
                Hardware.shortAddr(b2.rsAddr), Hardware.SIDE_NAMES[b2.side] or "?")
            self:drawText(30, ryC, padOrTrunc(restTxt, 48), COLORS.muted, rowBg)
            self:addHitbox(4, ryC, 78, ryC, function() self.selectedChIdx = ci end)
        end

        local colorWarn = Scheduler.validateChannelColors(pool)
        if colorWarn then
            self:drawText(4, 16, padOrTrunc("! " .. colorWarn, 75), COLORS.yellow, COLORS.panelBg)
        else
            self:drawText(4, 16, "Native GT Check Order: P1 checked 1st by multiblocks, PK checked last.", COLORS.muted, COLORS.panelBg)
        end

        -- Selected Channel Editor (y=17..43)
        local ch = pool.channels and pool.channels[self.selectedChIdx]
        if ch then
            local ci = self.selectedChIdx
            local di = Policy.dyeInfo(ch.gtDye)
            self:drawText(4, 17, string.rep("─", 74), COLORS.border, COLORS.panelBg)
            self:drawText(4, 18, string.format("Editing Ch%d | Hatch Dye: %s | Wire Priority: %s",
                ci, ch.gtColor or di.name, relRank[ci] or "OFF"), COLORS.accent, COLORS.panelBg)
            self:drawButton(4, 20, "[Name: " .. padOrTrunc(ch.name, 10) .. "]", COLORS.fg, COLORS.btnBg, function()
                self:openTextPrompt("Channel Name (e.g. Ch1 High / Express):", ch.name, function(v)
                    if v and v ~= "" then ch.name = v; self:save("Renamed Ch" .. ci .. " -> " .. v) end
                end)
            end)
            self:drawButton(24, 20, ch.enabled ~= false and "[Ch: ENABLED]" or "[Ch: OFF]",
                ch.enabled ~= false and COLORS.green or COLORS.red, COLORS.btnBg, function()
                    ch.enabled = not (ch.enabled ~= false)
                    self:save(string.format("%s Ch%d -> %s", pool.name, ci, tostring(ch.enabled)))
                end)
            self:drawButton(40, 20, "[Hatch Dye: " .. padOrTrunc(ch.gtColor or di.name, 15) .. "]", COLORS.cyan, COLORS.btnBg, function(step)
                local curD = tonumber(ch.gtDye) or 0
                local nxt = ((curD + 1 + (step or 1)) % 17) - 1
                ch.gtDye = nxt
                Scheduler.normalizeConfig(self.cfg)
                self:save(string.format("Ch%d Hatch Dye -> %s", ci, ch.gtColor))
            end)

            -- Inline 16-color GT spray-can swatch strip (High Prio Black=0 -> Low Prio White=15 + [U] unpainted)
            self:drawText(4, 22, "Spray Color (Hi->Lo):", COLORS.muted, COLORS.panelBg)
            for d = 0, 15 do
                local dInfo = Policy.GT_DYES[d]
                local sx = 26 + d * 3
                local selD = (ch.gtDye == d)
                local bgS = selD and COLORS.selectedBg or COLORS.panelBg
                self:drawText(sx, 22, selD and "[" or " ", COLORS.yellow, bgS)
                self:drawText(sx + 1, 22, "■", dInfo.hex == 0x21262D and 0x3A4352 or dInfo.hex, bgS)
                self:drawText(sx + 2, 22, selD and "]" or " ", COLORS.yellow, bgS)
                self:addHitbox(sx, 22, sx + 2, 22, function()
                    ch.gtDye = d
                    Scheduler.normalizeConfig(self.cfg)
                    self:save(string.format("Ch%d Hatch Color -> %s (#%d)", ci, dInfo.name, dInfo.rank))
                end)
            end
            self:drawButton(74, 22, "[U]", ch.gtDye == -1 and COLORS.yellow or COLORS.muted, COLORS.btnBg, function()
                ch.gtDye = -1
                Scheduler.normalizeConfig(self.cfg)
                self:save("Ch" .. ci .. " Hatch Color -> Unpainted")
            end)

            local b1 = ch.banks[1]
            self:drawText(4, 24, "Bank A (NC 00-15) Side:", COLORS.muted, COLORS.panelBg)
            self:drawButton(28, 24, "[" .. (Hardware.SIDE_NAMES[b1.side] or "?") .. "]", COLORS.cyan, COLORS.btnBg, function(step)
                Hardware.zeroAllManagedPools(self.cfg, self.comp, self.state)
                b1.side = (b1.side + (step or 1) + 6) % 6
                if ci == 1 then pool.side = b1.side end
                self:save(string.format("Ch%d Bank A Side -> %s", ci, Hardware.SIDE_NAMES[b1.side] or b1.side))
            end)

            local b2 = ch.banks[2]
            self:drawText(4, 26, "Bank B (NC 16-31) Side:", COLORS.muted, COLORS.panelBg)
            self:drawButton(28, 26, "[" .. (Hardware.SIDE_NAMES[b2.side] or "?") .. "]", COLORS.cyan, COLORS.btnBg, function(step)
                Hardware.zeroAllManagedPools(self.cfg, self.comp, self.state)
                b2.side = (b2.side + (step or 1) + 6) % 6
                self:save(string.format("Ch%d Bank B Side -> %s", ci, Hardware.SIDE_NAMES[b2.side] or b2.side))
            end)
            local b2Btn = string.format("[BankB RS: %s]", Hardware.shortAddr(b2.rsAddr))
            self:drawButton(39, 26, b2Btn, b2.rsAddr and COLORS.green or COLORS.muted, COLORS.btnBg, function()
                if #rsList == 0 then return end
                local nextIdx = 1
                for idx, rs in ipairs(rsList) do
                    if rs.address == b2.rsAddr then nextIdx = idx + 1 break end
                end
                b2.rsAddr = (nextIdx <= #rsList) and rsList[nextIdx].address or nil
                self:save(string.format("Ch%d Bank B RS -> %s", ci, Hardware.shortAddr(b2.rsAddr)))
            end)

            self:drawText(4, 29, "Bank A Redstone I/O:", COLORS.muted, COLORS.panelBg)
            if #rsList == 0 then
                self:drawText(26, 29, "None discovered (connect Redstone I/O)", COLORS.red, COLORS.panelBg)
            else
                for i = 1, math.min(6, #rsList) do
                    local rs = rsList[i]
                    local act = (b1.rsAddr == rs.address)
                    self:drawButton(26, 28 + i, string.format("[%s %s (%s)]",
                        act and "✓" or " ", rs.shortAddr, rs.bundled and "Bundled" or "No-Bundle"),
                        act and COLORS.green or (rs.bundled and COLORS.fg or COLORS.red),
                        act and COLORS.darkGreen or COLORS.btnBg,
                        function()
                            b1.rsAddr = rs.address
                            if ci == 1 then pool.rsAddr = rs.address end
                            self:save(string.format("%s Ch%d Bank A RS -> %s", pool.name, ci, rs.shortAddr))
                        end)
                end
            end
        end

        if #self.cfg.pools > 1 then
            self:drawButton(4, 44, "[Delete Selected Pool]", COLORS.red, COLORS.darkRed, function()
                Hardware.zeroAllManagedPools(self.cfg, self.comp, self.state)
                table.remove(self.cfg.pools, poolIdx)
                self.selectedPoolIdx = math.max(1, poolIdx - 1)
                self:save("Deleted pool.")
            end)
        end
    end

    -- Right Card: Global Scheduler & MLFQ Tuning
    self:drawFrame(82, 5, 78, 43, COLORS.border, COLORS.panelBg, "round")
    self:drawText(84, 5, " ◈ GLOBAL MLFQ & SCHEDULER TUNING ", COLORS.accent, COLORS.panelBg)

    local rows = {
        { key = "probeWindowSec",      label = "MLFQ Probe Window (s)",   step = 0.25, min = 0.25, max = 30,   fmt = "%.2fs" },
        { key = "fastThresholdSec",    label = "Known Fast Thresh (s)",   step = 0.5,  min = 0.5,  max = 60,   fmt = "%.1fs" },
        { key = "probePreemptHoldSec", label = "Probe Preempt Hold (s)",  step = 0.25, min = 0.25, max = 60,   fmt = "%.2fs" },
        { key = "minHoldSec",          label = "Min Hold Quantum (s)",    step = 5,    min = 0.5,  max = 600,  fmt = "%.1fs" },
        { key = "settleSec",           label = "Settle Guard All-OFF",    step = 0.25, min = 0,    max = 30,   fmt = "%.2fs" },
        { key = "preemptRatio",        label = "SRTF Preempt Ratio",      step = 0.05, min = 0.05, max = 0.95, fmt = "%.2fx" },
        { key = "agingPerMin",         label = "Wait Aging / Minute",     step = 0.05, min = 0,    max = 0.75, fmt = "%.2f" },
        { key = "stallTimeoutSec",     label = "Stall Yield Timeout",     step = 15,   min = 5,    max = 3600, fmt = "%.0fs" },
        { key = "idlePollSec",         label = "Idle Sleep Fallback (s)", step = 5,    min = 2,    max = 300,  fmt = "%.0fs" },
        { key = "pollIntervalSec",     label = "Active Poll Interval",    step = 0.25, min = 0.1,  max = 10,   fmt = "%.2fs" },
        { key = "emptyConfirmPolls",   label = "Empty Confirm Polls",     step = 1,    min = 1,    max = 10,   fmt = "%.0f" },
        { key = "defaultProbeRate",    label = "Initial Probe Rate u/s",  step = 2,    min = 0.5,  max = 500,  fmt = "%.1f" },
    }
    for i, r in ipairs(rows) do
        local ry = 8 + (i - 1) * 2
        self:drawText(85, ry, padOrTrunc(r.label, 25), COLORS.fg, COLORS.panelBg)
        self:drawText(112, ry, string.format(r.fmt, tonumber(self.cfg[r.key]) or 0), COLORS.cyan, COLORS.panelBg)
        self:drawButton(124, ry, "[-]", COLORS.yellow, COLORS.btnBg, function()
            self.cfg[r.key] = math.max(r.min, (tonumber(self.cfg[r.key]) or r.min) - r.step)
            self:save(r.label .. " -> " .. string.format(r.fmt, self.cfg[r.key]))
        end)
        self:drawButton(129, ry, "[+]", COLORS.green, COLORS.btnBg, function()
            self.cfg[r.key] = math.min(r.max, (tonumber(self.cfg[r.key]) or r.min) + r.step)
            self:save(r.label .. " -> " .. string.format(r.fmt, self.cfg[r.key]))
        end)
    end

    self:drawText(85, 35, "Ignore Built-in NCs:", COLORS.muted, COLORS.panelBg)
    self:drawButton(112, 35, self.cfg.ignoreBuiltinNC ~= false and "[ON (Circuits/Molds/Lenses)]" or "[OFF (Baseline Only)]",
        self.cfg.ignoreBuiltinNC ~= false and COLORS.green or COLORS.yellow, COLORS.btnBg, function()
            self.cfg.ignoreBuiltinNC = not (self.cfg.ignoreBuiltinNC ~= false)
            self:save("Ignore Built-in GTNH NCs -> " .. tostring(self.cfg.ignoreBuiltinNC))
        end)

    self:drawText(85, 38, "Log Verbosity      :", COLORS.muted, COLORS.panelBg)
    self:drawButton(112, 38, "[" .. tostring(self.cfg.logLevel):upper() .. "]", COLORS.cyan, COLORS.btnBg, function()
        local cur = 2
        for k, lv in ipairs(LOG_LEVELS) do if lv == self.cfg.logLevel then cur = k break end end
        self.cfg.logLevel = LOG_LEVELS[(cur % #LOG_LEVELS) + 1]
        self:save("Log verbosity -> " .. self.cfg.logLevel)
    end)

    local cacheCnt = self.state.recipeRateCount or 0
    local cacheMax = self.cfg.maxRecipeCache or Policy.DEFAULT_MAX_RECIPE_CACHE or 4096
    local cacheSlow = self.state.recipeSlowCount or 0
    self:drawText(85, 41, padOrTrunc(string.format("Recipe Cache: %d/%d (%d slow)", cacheCnt, cacheMax, cacheSlow), 39), COLORS.muted, COLORS.panelBg)
    self:drawButton(126, 41, "[Clear Cache]", COLORS.yellow, COLORS.btnBg, function()
        Policy.clearRecipeCache(self.state)
        self:save("Cleared learned recipe speed cache.")
    end)
end

function UI:renderSetupTab()
    local disc = self.state.discovery or {}
    local pool = self:selectedPool()
    local isStandalone = (self.cfg.extLinkMode == "off")

    local function drawBigAction(bx, by, bw, label, fg, borderCol, bg, fn)
        self:drawFrame(bx, by, bw, 3, borderCol, bg, "round")
        local txt = padOrTrunc(label, bw - 2)
        local tw = unicode.wlen(txt)
        local tx = bx + math.max(1, math.floor((bw - tw) / 2))
        self:drawText(tx, by + 1, txt, fg, bg)
        self:addHitbox(bx, by, bx + bw - 1, by + 2, fn)
    end

    local scanCh = pool and math.max(1, math.min(#(pool.channels or {}), self.setupChIdx or 1)) or 1
    drawBigAction(7, 5, 34, "↻  RESCAN HARDWARE", COLORS.cyan, COLORS.cyan, COLORS.btnBg, function()
        Scheduler.syncHardware(self.cfg, self.state, self.comp)
        self:save("Rescanned Redstone I/O and Subnet Interfaces.")
    end)
    drawBigAction(45, 5, 34, string.format("⚡ AUTO-SCAN CH%d TRUNK", scanCh), COLORS.green, COLORS.green, COLORS.btnBg, function()
        if not pool then return end
        self.cfg.armed = false
        local addrs = {}
        for _, it in ipairs(disc.interfaces or {}) do
            if not it.isMainnet then
                addrs[#addrs + 1] = it.address
            end
        end
        if #addrs == 0 then
            self.statusMsg = "Auto-Scan skipped: no non-mainnet full-block interfaces found."
            return
        end
        local res = Hardware.autoScanTrunkPool(pool, addrs, { pulseSec = 0.25, channelIdx = scanCh }, self.comp)
        if res.ok then
            Scheduler.refreshSubscriptions(self.cfg, self.state, self.comp)
            self:save(string.format("Auto-Scan Ch%d bound %d slice(s) on %s.", scanCh, res.boundCount or 0, pool.name))
        else
            self.statusMsg = "Auto-Scan error: " .. tostring(res.error)
        end
    end)
    drawBigAction(83, 5, 34, self.guidedDropActive and "■  STOP GUIDED DROP" or "▶  GUIDED DROP PAIR",
        self.guidedDropActive and COLORS.yellow or COLORS.purple,
        self.guidedDropActive and COLORS.yellow or COLORS.purple, COLORS.btnBg,
        function()
            if self.guidedDropActive then
                self:stopGuidedDrop("Guided Drop stopped.")
            else
                self:startGuidedDrop()
            end
        end)
    drawBigAction(121, 5, 34, "⊕  CALIBRATE IDLE NCs", COLORS.cyan, COLORS.cyan, COLORS.btnBg, function()
        if not pool then return end
        local nOk = 0
        for c = 0, (pool.numSlices or 16) - 1 do
            local s = pool.slices[c]
            if s and s.ifaceAddr then
                if Hardware.calibrateBaseline(s, { ignoreBuiltinNC = self.cfg.ignoreBuiltinNC }, self.comp) then
                    nOk = nOk + 1
                end
            end
        end
        self:save(string.format("Calibrated idle NC baselines across %d slice(s).", nOk))
    end)

    -- Hardware Card (left) & Auto-Scan Guide (right)
    self:drawFrame(2, 9, 78, 16, COLORS.border, COLORS.panelBg, "round")
    self:drawText(4, 9, " ◈ DISCOVERY, EVENTS & LINK ", COLORS.accent, COLORS.panelBg)
    self:drawButton(57, 9, isStandalone and "[Ext:Standalone]" or "[Ext:Mesh/Auto ]",
        isStandalone and COLORS.yellow or COLORS.cyan,
        isStandalone and COLORS.amberBg or COLORS.btnBg,
        function()
            self.cfg.extLinkMode = isStandalone and "auto" or "off"
            self:save("External Link -> " .. (self.cfg.extLinkMode == "off" and "Standalone" or "Mesh/Auto"))
        end)

    self:drawText(4, 11, string.format("Bundled Redstone I/O : %d found (96 wires/block)", #(disc.redstones or {})), COLORS.fg, COLORS.panelBg)
    local roomIfs, mainIfs = 0, 0
    for _, inf in ipairs(disc.interfaces or {}) do
        if inf.isMainnet then mainIfs = mainIfs + 1 else roomIfs = roomIfs + 1 end
    end
    self:drawText(4, 13, string.format("Full-Block Dual IFs  : %d room / %d net", roomIfs, mainIfs), COLORS.green, COLORS.panelBg)
    self:drawButton(44, 13, "[Auto-Bind Sequential]", COLORS.cyan, COLORS.btnBg, function()
        if not pool then return end
        local list = disc.interfaces or {}
        local bound = 0
        local maxS = tonumber(pool.numSlices) or 16
        for i = 1, #list do
            if not list[i].isMainnet then
                pool.slices[bound].ifaceAddr = list[i].address
                bound = bound + 1
                if bound >= maxS then break end
            end
        end
        Scheduler.refreshSubscriptions(self.cfg, self.state, self.comp)
        self:save(string.format("Sequentially bound %d room interface(s) -> NC 00..%02d.", bound, math.max(0, bound - 1)))
    end)

    local subStatus = self.state._allSubscribed and "ACTIVE (GTNH 2.9 Push Events -> 0-tick Idle!)" or "Polling Fallback (bind event-capable IFs)"
    self:drawText(4, 15, padOrTrunc("Event Subscriptions  : " .. subStatus, 74), self.state._allSubscribed and COLORS.green or COLORS.yellow, COLORS.panelBg)

    self:drawText(4, 17, string.format("Wireless Modem/Tunnel: %s",
        disc.hasModem and (disc.hasWireless and "Wireless (port 4205)" or "Wired Modem") or (disc.hasTunnel and "Linked Card" or "None (Standalone OK)")),
        COLORS.muted, COLORS.panelBg)

    if pool and #(pool.channels or {}) > 1 then
        self:drawButton(4, 19, string.format("[Scan Channel: Ch%d (Click to cycle)]", scanCh), COLORS.cyan, COLORS.btnBg, function()
            self.setupChIdx = (scanCh % #(pool.channels or {})) + 1
        end)
    end

    local warns = disc.partWarnings or {}
    if #warns > 0 then
        self:drawText(4, 21, string.format("! WARNING: %d Flat Cable-Part ME Interface(s) detected!", #warns), COLORS.yellow, COLORS.panelBg)
        for wi = 1, math.min(2, #warns) do
            self:drawText(4, 21 + wi, padOrTrunc(warns[wi].message, 74), COLORS.yellow, COLORS.panelBg)
        end
    else
        self:drawText(4, 22, "✓ All discovered ME Interfaces expose NetworkControl (full-block OK).", COLORS.green, COLORS.panelBg)
    end

    self:drawFrame(82, 9, 78, 16, COLORS.border, COLORS.panelBg, "round")
    self:drawText(84, 9, " ◈ FAST PAIRING (GUIDED DROP & TRUNK SCAN) ", COLORS.accent, COLORS.panelBg)
    self:drawText(84, 11, "A) [GUIDED DROP PAIR]: Best for 1-way Extract-Only Waiting Rooms!", COLORS.purple, COLORS.panelBg)
    self:drawText(84, 13, "   Click Guided Drop -> walk down your row & drop 1 item/circuit.", COLORS.fg, COLORS.panelBg)
    self:drawText(84, 15, "   Binds in 0ms via push event, auto-labels circuits & plays beep!", COLORS.fg, COLORS.panelBg)
    self:drawText(84, 17, "B) [AUTO-SCAN CH# TRUNK]: Sweeps NC 00..15/31 and detects either", COLORS.green, COLORS.panelBg)
    self:drawText(84, 19, "   bi-directional Marker arrival OR Extract-Only chest item drain.", COLORS.fg, COLORS.panelBg)
    self:drawText(84, 21, "C) Multi-Channel Rule: Same Color #k = Same NC #k on every channel!", COLORS.cyan, COLORS.panelBg)

    -- Wiring Topology (bottom)
    self:drawFrame(2, 26, 158, 22, COLORS.border, COLORS.panelBg, "round")
    self:drawText(4, 26, " ◈ MULTI-CHANNEL COLORED-HATCH TOPOLOGY (0-TICK PUSH + 1-TICK SWITCH) ", COLORS.accent, COLORS.panelBg)
    local diag = {
        "ALWAYS-ON NC WAITING ROOM #k (2ch ad-hoc subnet, NO ME Controller, 0 NCs inside -> Adv Blocking Card works for ALL GTNH recipes!):",
        "  [Mainnet Pattern Dual IF] (Adv Blocking Card ON + Allow Insert Same Recipe)",
        "     `-> [Full-Block Subnet Dual IF #k] <-> Quartz Fiber 24/7 + [ME Drive: Item Cell + Fluid Cell]   <-- OC Adapter (Push EvSub!)",
        "            |-- Face 1: Extract-Only Storage Buses + [Chest/Holder NC #k] --> [Toggle Bus Ch1 Color k] --> CH1 TRUNK (Black, Prio 1)",
        "            `-- Face 2: Extract-Only Storage Buses + [Chest/Holder NC #k] --> [Toggle Bus Ch2 Color k] --> CH2 TRUNK (Blue, Prio 5)",
        "",
        "MACHINES (Adv. Stocking Input Bus + Adv. Stocking Input Hatch, Auto-Pull = ON, Refresh = 1-2 ticks, Input Separation = ON):",
        "  * Spray CH1 Bus+Hatch BLACK (checked 1st by GTNH!) -> Fast PROBE jobs always land on Ch1 with 0s interruption.",
        "  * Optional CH2: Spray CH2 Bus+Hatch BLUE (checked 5th) -> OC demotes long BULK jobs onto Ch2, leaving Ch1 IDLE & pre-settled!",
        "  * In-flight machines NEVER fail or lose items when a Toggle Bus switches: Stocking inputs extract atomically on recipe start.",
        "  * GT++ Extruder Shapes, Catalysts, Petri Dishes & Data Sticks work 100% natively because NC #k sits on the Toggle Bus trunk side.",
    }
    for i, line in ipairs(diag) do
        local col = (i == 1 or i == 7) and COLORS.green or ((i >= 8) and COLORS.cyan or COLORS.fg)
        self:drawText(4, 28 + i, padOrTrunc(line, 154), col, COLORS.panelBg)
    end
end

function UI:renderLogModal()
    if not self.logModalActive then return end
    self.hitboxes = {}
    local mx, my, mw, mh = 10, 4, 140, 42
    self:drawFrame(mx, my, mw, mh, COLORS.accent, COLORS.headerBg, "double")
    self:drawText(mx + 2, my, " ◈ UNIVERSAL ACTIVITY LOG & RAW SUBNET SNAPSHOT ", COLORS.accent, COLORS.headerBg)
    self:drawButton(mx + mw - 10, my + 1, "[Close]", COLORS.red, COLORS.btnBg, function()
        self.logModalActive = false
    end)
    self:drawButton(mx + 3, my + 1, "[1] Activity Log", self.logModalTab == 1 and COLORS.fg or COLORS.muted,
        self.logModalTab == 1 and COLORS.btnActiveBg or COLORS.btnBg, function()
            self.logModalTab = 1; self.logModalScroll = 0
        end)
    self:drawButton(mx + 21, my + 1, "[2] Raw Snapshot", self.logModalTab == 2 and COLORS.fg or COLORS.muted,
        self.logModalTab == 2 and COLORS.btnActiveBg or COLORS.btnBg, function()
            self.logModalTab = 2; self.logModalScroll = 0
        end)

    local list = (self.logModalTab == 1) and (self.state.logs or {}) or (self.state.rawSnapshot or {})
    local maxLines = mh - 5
    local maxScroll = math.max(0, #list - maxLines)
    self.logModalScroll = math.max(0, math.min(maxScroll, self.logModalScroll or 0))
    for i = 1, math.min(maxLines, #list - self.logModalScroll) do
        local entry = list[#list - (self.logModalScroll + i - 1)]
        if self.logModalTab == 1 and type(entry) == "table" then
            local col = (entry.tag == "WRN") and COLORS.yellow or ((entry.tag == "OUT") and COLORS.green or COLORS.fg)
            local txt = string.format("[%s] %.1fs %s", tostring(entry.tag or "LOG"), tonumber(entry.t) or 0, tostring(entry.msg or ""))
            self:drawText(mx + 3, my + 3 + i, padOrTrunc(txt, mw - 6), col, COLORS.headerBg)
        else
            self:drawText(mx + 3, my + 3 + i, padOrTrunc(tostring(entry), mw - 6), COLORS.fg, COLORS.headerBg)
        end
    end
end

function UI:renderPromptModal()
    if not self.promptActive then return end
    self.hitboxes = {}
    local mx, my, mw, mh = 34, 20, 92, 9
    self:drawFrame(mx, my, mw, mh, COLORS.accent, COLORS.headerBg, "double")
    self:drawText(mx + 3, my + 2, padOrTrunc(self.promptTitle, mw - 6), COLORS.fg, COLORS.headerBg)
    self:fillRect(mx + 3, my + 4, mw - 6, 1, " ", COLORS.bg)
    self:drawText(mx + 4, my + 4, padOrTrunc(self.promptBuffer .. "_", mw - 8), COLORS.yellow, COLORS.bg)
    self:drawText(mx + 3, my + 6, "Type text + [Enter] to save, or [Esc] to cancel.", COLORS.muted, COLORS.headerBg)
end

function UI:render()
    self.hitboxes = {}
    self:clearNextBuffer(COLORS.bg, COLORS.fg)
    self:renderHeader()

    if self.tab == TAB_OVERVIEW then
        self:renderOverviewTab()
    elseif self.tab == TAB_SLICES then
        self:renderSlicesTab()
    elseif self.tab == TAB_POOLS then
        self:renderPoolsTab()
    elseif self.tab == TAB_SETUP then
        self:renderSetupTab()
    end

    self:drawText(1, self.h - 1, string.rep("─", self.w), COLORS.border, COLORS.bg)
    self:fillRect(1, self.h, self.w, 1, " ", COLORS.headerBg)
    local keysStr = "1-4:Tabs  Space:Arm  L:Log  R:Scan  Q:Quit"
    local keysX = Common.fitRightX(self.w, keysStr, 2)
    self:drawText(2, self.h, padOrTrunc(self.statusMsg, math.max(0, keysX - 4)), COLORS.fg, COLORS.headerBg)
    self:drawText(keysX, self.h, keysStr, COLORS.muted, COLORS.headerBg)

    if self.logModalActive then self:renderLogModal() end
    if self.promptActive then self:renderPromptModal() end
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
    elseif self.tab == TAB_OVERVIEW then
        self.queueScroll = math.max(0, (self.queueScroll or 0) - dir)
    end
end

function UI:handleKeyDown(char, code)
    if self.promptActive then
        if code == 28 or char == 13 then
            local cb, val = self.promptCallback, self.promptBuffer
            self.promptActive, self.promptCallback = false, nil
            if cb then cb(val) end
        elseif code == 1 then
            self.promptActive, self.promptCallback = false, nil
        elseif code == 14 or char == 8 then
            if #self.promptBuffer > 0 then self.promptBuffer = self.promptBuffer:sub(1, -2) end
        elseif char >= 32 and char <= 126 then
            self.promptBuffer = self.promptBuffer .. string.char(char)
        end
        return
    end
    if self.logModalActive then
        if code == 1 or char == string.byte("l") or char == string.byte("L") then
            self.logModalActive = false
        elseif char == string.byte("1") then self.logModalTab = 1; self.logModalScroll = 0
        elseif char == string.byte("2") then self.logModalTab = 2; self.logModalScroll = 0
        elseif code == 200 then self.logModalScroll = math.max(0, (self.logModalScroll or 0) - 1)
        elseif code == 208 then self.logModalScroll = (self.logModalScroll or 0) + 1
        end
        return
    end
    if char == string.byte("1") then self.tab = TAB_OVERVIEW
    elseif char == string.byte("2") then self.tab = TAB_SLICES
    elseif char == string.byte("3") then self.tab = TAB_POOLS
    elseif char == string.byte("4") then self.tab = TAB_SETUP
    elseif code == 15 or char == 9 then self.tab = (self.tab % 4) + 1
    elseif char == 32 then
        self.cfg.armed = not self.cfg.armed
        if not self.cfg.armed then Scheduler.allOff(self.cfg, self.state, nil, self.comp)
        else self.state._forcePollNow = true end
        self:save(self.cfg.armed and "Armed." or "Paused (all OFF).")
    elseif char == string.byte("l") or char == string.byte("L") then
        self.logModalActive = true; self.logModalScroll = 0
    elseif char == string.byte("r") or char == string.byte("R") then
        Scheduler.syncHardware(self.cfg, self.state, self.comp)
        self.state._forcePollNow = true
        self.state._forceFullScan = true
        self:save("Rescanned hardware.")
    elseif char == string.byte("q") or char == string.byte("Q") then
        if self.guidedDropActive then self:stopGuidedDrop() end
        Scheduler.allOff(self.cfg, self.state, nil, self.comp)
        self:save("Saved and turned outputs OFF.")
        self.running = false
    end
end

return UI
