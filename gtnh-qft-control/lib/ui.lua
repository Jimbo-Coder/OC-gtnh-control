-- /home/qft/lib/ui.lua
-- Visual 160x50 Touch Control Center for GTNH Quantum Force Transformer (Tier 3 GPU).
-- Packed 64-bit buffer, strictly width-1 glyphs.

local component = require("component")
local unicode = require("unicode")
local Hardware = require("lib.hardware")
local Scheduler = require("lib.scheduler")
local RecipesDb = require("lib.recipes_db")

local UI = {}
local TAB_FLEET   = 1
local TAB_RECIPES = 2
local TAB_HW      = 3
local TAB_SETUP   = 4

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
    str = tostring(str or "")
    if width <= 0 then return "" end
    local len = unicode.wlen(str)
    if len > width then
        if width == 1 then return unicode.sub(str, 1, 1) end
        return unicode.sub(str, 1, width - 1) .. "~"
    elseif len < width then
        return str .. string.rep(" ", width - len)
    end
    return str
end

function UI.formatNumber(n, suffix)
    n = tonumber(n) or 0
    local a, suf = math.abs(n), suffix or ""
    if a >= 1e9 then return string.format("%.2fG%s", n / 1e9, suf)
    elseif a >= 1e6 then return string.format("%.1fM%s", n / 1e6, suf)
    elseif a >= 1e3 then return string.format("%.1fK%s", n / 1e3, suf)
    else return string.format("%d%s", math.floor(n + 0.5), suf) end
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
        tab = TAB_FLEET,
        selectedUnitId = (cfg.units[1] and cfg.units[1].id) or nil,
        tierFilter = 0,
        selectedRecipeId = (cfg.units[1] and cfg.units[1].recipeId) or RecipesDb.RECIPES[1].id,
        recipeScroll = 0,
        hwScroll = 0,
        inputDrafts = {},
        running = true,
        statusMsg = "Ready (Click a recipe to inspect/maintain inputs or configure QFTs).",
        curBuf = {},
        nxtBuf = {},
        hitboxes = {},
    }, { __index = UI })
    if self.gpu then
        pcall(self.gpu.setResolution, self.w, self.h)
        local empty = packMask(COLORS.fg, COLORS.bg) | 32
        for i = 1, self.w * self.h do self.curBuf[i] = -1; self.nxtBuf[i] = empty end
    end
    return self
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
    self:drawText(2, 1, "◈ GTNH QUANTUM FORCE TRANSFORMER CONTROL", COLORS.accent, COLORS.headerBg)
    local armed = (self.cfg.armed == true)
    local bx = 46
    bx = self:drawButton(bx, 1, armed and "[ARMED]" or "[PAUSED]",
        armed and COLORS.green or COLORS.yellow, armed and COLORS.darkGreen or COLORS.amberBg, function()
            self.cfg.armed = not armed
            self:save(self.cfg.armed and "QFT Fleet ARMED." or "QFT Fleet PAUSED.")
        end) + 2
    bx = self:drawButton(bx, 1, "[↻ Poll Now]", COLORS.cyan, COLORS.btnBg, function()
        Scheduler.step(self.cfg, self.state, nil, self.comp)
        self.statusMsg = "Polled QFT fleet."
    end) + 2

    local ms = self.state.maintMode or { mode = "offline", label = "OFFLINE" }
    local mCol = (ms.mode == "mainnet" and COLORS.green) or (ms.mode == "local" and COLORS.yellow) or COLORS.muted
    local mBg = (ms.mode == "mainnet" and COLORS.darkGreen) or (ms.mode == "local" and COLORS.amberBg) or COLORS.btnBg
    self:drawText(bx, 1, "[Maint: " .. tostring(ms.label) .. "]", mCol, mBg)

    local tx = 2
    for _, tb in ipairs({
        { id = TAB_FLEET, label = "[1] QFT FLEET" },
        { id = TAB_RECIPES, label = "[2] RECIPES & INPUTS" },
        { id = TAB_HW, label = "[3] HARDWARE BINDING" },
        { id = TAB_SETUP, label = "[4] LOGS & SETUP" },
    }) do
        local act = (self.tab == tb.id)
        tx = self:drawButton(tx, 2, tb.label, act and COLORS.fg or COLORS.muted,
            act and COLORS.btnActiveBg or COLORS.headerBg, function() self.tab = tb.id end) + 2
    end
    self:drawText(1, 3, string.rep("─", self.w), COLORS.border, COLORS.bg)
end

function UI:renderFleetTab()
    self:drawFrame(2, 5, 102, 43, COLORS.border, COLORS.panelBg, "round")
    self:drawText(4, 5, " ◈ QFT UNITS (1, 2 OR 3 BLOCKS PER QFT) ", COLORS.accent, COLORS.panelBg)
    local units = self.state.unitStatuses or {}
    if #units == 0 then
        self:drawText(4, 8, "No QFTs configured yet. Go to [3] HARDWARE BINDING or click below.", COLORS.yellow, COLORS.panelBg)
        self:drawButton(4, 10, "[↻ Auto-Discover QFTs]", COLORS.cyan, COLORS.btnBg, function()
            local disc = Scheduler.syncHardware(self.cfg, self.state, self.comp)
            local added = Scheduler.autoBindDiscoveredUnits(self.cfg, disc)
            self:save(string.format("Discovered %d QFT(s), added %d.", #(disc.controllers or {}), added))
        end)
    else
        self:drawText(4, 7, padOrTrunc(string.format("%-6s %-10s %-4s %-22s %-8s %-7s %-7s %s",
            "State", "Unit", "Tier", "Recipe", "Focus", "Np", "Fm", "Output Target"), 98), COLORS.muted, COLORS.panelBg)
        self:drawText(4, 8, string.rep("─", 98), COLORS.border, COLORS.panelBg)
        for i, us in ipairs(units) do
            if i > 17 then break end
            local ry = 8 + i * 2
            local sel = (us.id == self.selectedUnitId)
            local bg = sel and COLORS.selectedBg or ((i % 2 == 0) and COLORS.rowAltBg or COLORS.panelBg)
            self:fillRect(3, ry, 100, 1, " ", COLORS.fg, bg)
            local stCol = (us.state == "RUN" and COLORS.green) or (us.state == "RECFG" and COLORS.yellow)
                or (us.state == "OFF" and COLORS.red) or COLORS.muted
            local line = string.format("%-6s %-10s T%-3d %-22s #%-7d %-7s %-7s %s",
                us.state, padOrTrunc(us.label, 10), us.tier, padOrTrunc(us.recipeName, 22),
                us.focusCircuit or 0,
                us.hasNeptunium and "ON" or tostring(us.boostNeptunium):upper(),
                us.hasFermium and "ON" or tostring(us.boostFermium):upper(),
                us.targetStock > 0 and UI.formatNumber(us.targetStock) or "24/7")
            self:drawButton(4, ry, padOrTrunc(line, 98), stCol, bg, function()
                self.selectedUnitId = us.id
            end)
        end
    end

    self:drawFrame(106, 5, 53, 43, COLORS.border, COLORS.panelBg, "round")
    self:drawText(108, 5, " ◈ UNIT CONTROL ", COLORS.accent, COLORS.panelBg)
    local u = self.selectedUnitId and Scheduler.findUnit(self.cfg, self.selectedUnitId) or self.cfg.units[1]
    if not u then
        self:drawText(108, 8, "Select a QFT unit to configure.", COLORS.muted, COLORS.panelBg)
        return
    end
    local rcp = RecipesDb.BY_ID[u.recipeId] or RecipesDb.RECIPES[1]
    self:drawText(108, 7, "Unit   : " .. padOrTrunc(u.label, 24) .. " (" .. (u.enabled and "ON" or "OFF") .. ")", COLORS.fg, COLORS.panelBg)
    self:drawButton(145, 7, u.enabled and "[Disable]" or "[Enable ]", u.enabled and COLORS.green or COLORS.muted, COLORS.btnBg, function()
        u.enabled = not (u.enabled ~= false)
        self:save(u.label .. " -> " .. (u.enabled and "ENABLED" or "DISABLED"))
    end)
    self:drawText(108, 9, "Recipe : " .. padOrTrunc(rcp.name, 40), COLORS.cyan, COLORS.panelBg)
    self:drawButton(108, 10, "[Pick Recipe / Maintain Inputs ->]", COLORS.fg, COLORS.btnActiveBg, function()
        self.selectedRecipeId = u.recipeId
        self.tab = TAB_RECIPES
    end)

    self:drawText(108, 12, "QFT Tier (Pulse Casings):", COLORS.fg, COLORS.panelBg)
    local tx = 108
    for t = 1, 4 do
        local act = (u.tier == t)
        tx = self:drawButton(tx, 13, "[T" .. t .. "]", act and COLORS.fg or COLORS.muted, act and COLORS.btnActiveBg or COLORS.btnBg, function()
            u.tier = t
            self:save(u.label .. " tier -> T" .. t)
        end) + 1
    end

    self:drawText(108, 15, "Focus Circuit Mode:", COLORS.fg, COLORS.panelBg)
    local fx = 108
    for _, fm in ipairs({ "auto", "fixed", "none" }) do
        local act = (u.focusMode == fm)
        fx = self:drawButton(fx, 16, "[" .. fm:upper() .. "]", act and COLORS.fg or COLORS.muted, act and COLORS.btnActiveBg or COLORS.btnBg, function()
            u.focusMode = fm
            self:save(u.label .. " focus -> " .. fm)
        end) + 1
    end
    if u.focusMode == "fixed" then
        self:drawButton(fx + 1, 16, "[# " .. tostring(u.focusCircuit) .. " ->]", COLORS.cyan, COLORS.btnBg, function()
            local maxO = #Scheduler.recipeOutputs(rcp)
            u.focusCircuit = (u.focusCircuit % math.max(1, maxO)) + 1
            self:save(u.label .. " focus circuit -> #" .. u.focusCircuit)
        end)
    end

    self:drawText(108, 18, "Np Boost:", COLORS.fg, COLORS.panelBg)
    local nx = 119
    for _, m in ipairs({ "auto", "on", "off" }) do
        local act = (u.boostNeptunium == m)
        nx = self:drawButton(nx, 18, "[" .. m:upper() .. "]", act and COLORS.fg or COLORS.muted, act and COLORS.btnActiveBg or COLORS.btnBg, function()
            u.boostNeptunium = m
            self:save(u.label .. " Np boost -> " .. m)
        end) + 1
    end
    self:drawText(108, 20, "Fm Boost:", COLORS.fg, COLORS.panelBg)
    local mx = 119
    for _, m in ipairs({ "auto", "on", "off" }) do
        local act = (u.boostFermium == m)
        mx = self:drawButton(mx, 20, "[" .. m:upper() .. "]", act and COLORS.fg or COLORS.muted, act and COLORS.btnActiveBg or COLORS.btnBg, function()
            u.boostFermium = m
            self:save(u.label .. " Fm boost -> " .. m)
        end) + 1
    end

    self:drawText(108, 22, "Output Stock Cap (0 = 24/7): " .. (u.targetStock > 0 and UI.formatNumber(u.targetStock) or "24/7"), COLORS.fg, COLORS.panelBg)
    local cx = 108
    for _, v in ipairs({ 0, 1024, 16384, 100000, 1000000 }) do
        cx = self:drawButton(cx, 23, "[" .. (v == 0 and "24/7" or UI.formatNumber(v)) .. "]", COLORS.cyan, COLORS.btnBg, function()
            u.targetStock = v
            self:save(u.label .. " output cap -> " .. (v == 0 and "24/7" or UI.formatNumber(v)))
        end) + 1
    end

    self:drawText(108, 26, "Safety: Focus/plasma changes wait for", COLORS.muted, COLORS.panelBg)
    self:drawText(108, 27, "isMachineActive()==false to prevent voiding.", COLORS.muted, COLORS.panelBg)
end

function UI:renderRecipesTab()
    self:drawFrame(2, 5, 62, 43, COLORS.border, COLORS.panelBg, "round")
    self:drawText(4, 5, " ◈ QFT RECIPES BY TIER ", COLORS.accent, COLORS.panelBg)
    local fx = 4
    for t = 0, 4 do
        local act = (self.tierFilter == t)
        fx = self:drawButton(fx, 7, t == 0 and "[ALL]" or ("[T" .. t .. "]"),
            act and COLORS.fg or COLORS.muted, act and COLORS.btnActiveBg or COLORS.btnBg, function()
                self.tierFilter = t
                self.recipeScroll = 0
            end) + 1
    end
    local filtered = {}
    for _, r in ipairs(RecipesDb.RECIPES) do
        if self.tierFilter == 0 or r.tier == self.tierFilter then
            filtered[#filtered + 1] = r
        end
    end
    local maxShow = 18
    self.recipeScroll = math.max(0, math.min(math.max(0, #filtered - maxShow), self.recipeScroll))
    for i = 1, math.min(maxShow, #filtered - self.recipeScroll) do
        local r = filtered[self.recipeScroll + i]
        local ry = 8 + i * 2
        local sel = (r.id == self.selectedRecipeId)
        local bg = sel and COLORS.selectedBg or ((i % 2 == 0) and COLORS.rowAltBg or COLORS.panelBg)
        self:fillRect(3, ry, 59, 1, " ", COLORS.fg, bg)
        local line = string.format("T%d %-34s %d in / %d out", r.tier, padOrTrunc(r.name, 34), #r.itemsIn + #r.fluidsIn, #r.itemsOut + #r.fluidsOut)
        self:drawButton(4, ry, padOrTrunc(line, 58), sel and COLORS.cyan or COLORS.fg, bg, function()
            self.selectedRecipeId = r.id
        end)
    end

    local r = RecipesDb.BY_ID[self.selectedRecipeId] or RecipesDb.RECIPES[1]
    self:drawFrame(66, 5, 93, 43, COLORS.border, COLORS.panelBg, "round")
    self:drawText(68, 5, " ◈ INPUTS & ONE-CLICK MAINTAINER: " .. padOrTrunc(r.name, 45) .. " ", COLORS.accent, COLORS.panelBg)
    self:drawText(68, 7, string.format("Tier: T%d | Catalyst: %s | %d EU/t (%ds)",
        r.focusTier, r.catalyst.label, r.eut, math.floor(r.durationTicks / 20)), COLORS.muted, COLORS.panelBg)

    local draft = self.inputDrafts[r.id]
    if not draft then
        draft = Scheduler.buildDefaultInputs(r, { batches = 8 })
        self.inputDrafts[r.id] = draft
    end
    self:drawText(68, 9, padOrTrunc(string.format("%-5s %-30s %-8s %-10s %-10s %s", "Use", "Input Item / Fluid", "Craft", "Target", "Batch", "Status"), 89), COLORS.muted, COLORS.panelBg)
    self:drawText(68, 10, string.rep("─", 89), COLORS.border, COLORS.panelBg)
    local peerKeys = (self.state.stockPeer and self.state.stockPeer.keys) or {}
    for i, ent in ipairs(draft) do
        if i > 10 then break end
        local ry = 10 + i * 2
        local isFl = (ent.type == "fluid")
        local suf = isFl and "L" or ""
        local fullK = string.format("%s:%s:%d", ent.type, ent.name, ent.damage or 0)
        local mSt = peerKeys[fullK] and "Mainnet" or "New"
        self:drawButton(68, ry, ent.enabled and "[X]" or "[ ]", ent.enabled and COLORS.green or COLORS.muted, COLORS.btnBg, function()
            ent.enabled = not ent.enabled
        end)
        self:drawText(73, ry, padOrTrunc(ent.label, 30), ent.enabled and COLORS.fg or COLORS.muted, COLORS.panelBg)
        self:drawText(104, ry, padOrTrunc(UI.formatNumber(ent.perCraft or 1, suf), 8), COLORS.muted, COLORS.panelBg)
        self:drawButton(113, ry, "[" .. UI.formatNumber(ent.target, suf) .. "]", COLORS.cyan, COLORS.btnBg, function()
            ent.target = ent.target * 2
            ent.batch = math.max(ent.batch, math.floor(ent.target / 4))
        end)
        self:drawButton(127, ry, "[" .. UI.formatNumber(ent.batch, suf) .. "]", COLORS.fg, COLORS.btnBg, function()
            ent.batch = math.max(1, math.floor(ent.batch * 2))
        end)
        self:drawText(142, ry, mSt, mSt == "Mainnet" and COLORS.green or COLORS.yellow, COLORS.panelBg)
    end

    local by = 34
    self:drawButton(68, by, "[◈ Maintain Inputs (" .. tostring(self.state.maintMode and self.state.maintMode.label or "OFF") .. ")]",
        COLORS.fg, COLORS.darkGreen, function()
            local res = Scheduler.pushRecipeInputs(self.cfg, self.state, { recipeId = r.id, rules = draft }, self.comp)
            self:save(string.format("Maintained %d input(s) via %s [%s]", res.count or 0, tostring(res.dispatched), tostring(res.tag or r.name)))
        end)
    local selU = self.selectedUnitId and Scheduler.findUnit(self.cfg, self.selectedUnitId) or self.cfg.units[1]
    if selU then
        self:drawButton(112, by, "[Assign to " .. padOrTrunc(selU.label, 10) .. "]", COLORS.cyan, COLORS.btnBg, function()
            selU.recipeId = r.id
            self:save("Assigned " .. r.name .. " -> " .. selU.label)
        end)
    end
    self:drawButton(68, by + 2, "[Retire / Pause Recipe Inputs]", COLORS.yellow, COLORS.amberBg, function()
        local res = Scheduler.retireRecipeInputs(self.cfg, self.state, { recipeId = r.id, pauseOrphans = true }, self.comp)
        self:save(string.format("Retired %s (%d untagged)", tostring(res.tag), res.untagged or 0))
    end)

    -- Outputs preview
    local outs = Scheduler.recipeOutputs(r)
    self:drawText(68, 39, "Focus Outputs (#1..#" .. tostring(#outs) .. "):", COLORS.accent, COLORS.panelBg)
    local ox = 68
    for idx, o in ipairs(outs) do
        if idx > 6 then break end
        self:drawText(68, 39 + idx, string.format("  #%d  %-36s (%s)", o.circuit, padOrTrunc(o.label, 36),
            UI.formatNumber(o.amount, o.type == "fluid" and "L" or "")), COLORS.fg, COLORS.panelBg)
    end
end

function UI:renderHardwareTab()
    self:drawFrame(2, 5, 157, 43, COLORS.border, COLORS.panelBg, "round")
    self:drawText(4, 5, " ◈ QFT HARDWARE DISCOVERY & 1/2/3-BLOCK BINDING ", COLORS.accent, COLORS.panelBg)
    self:drawButton(4, 7, "[↻ Scan & Auto-Bind]", COLORS.cyan, COLORS.btnBg, function()
        local disc = Scheduler.syncHardware(self.cfg, self.state, self.comp)
        local added = Scheduler.autoBindDiscoveredUnits(self.cfg, disc)
        self:save(string.format("Scanned QFT=%d Bus=%d Hatch=%d (added %d)",
            #(disc.controllers or {}), #(disc.inputBuses or {}), #(disc.inputHatches or {}), added))
    end)
    local disc = self.state.discovery or {}
    self:drawText(4, 9, string.format("Controllers: %d  |  ME Stocking Buses: %d  |  ME Stocking Hatches: %d  |  Local AE2: %d",
        #(disc.controllers or {}), #(disc.inputBuses or {}), #(disc.inputHatches or {}), #(disc.aeInterfaces or {})), COLORS.fg, COLORS.panelBg)
    self:drawText(4, 11, "Tip: Place 1 OC Adapter touching adjacent blocks (0 MFUs) or bind 1-3 MFUs for remote wireless.", COLORS.muted, COLORS.panelBg)
    for i, u in ipairs(self.cfg.units or {}) do
        if i > 12 then break end
        self:drawText(4, 12 + i * 2, string.format("%-10s Ctrl:%-10s Bus:%-10s Hatch:%-10s",
            padOrTrunc(u.label, 10), Hardware.shortAddr(u.controllerAddr),
            Hardware.shortAddr(u.busAddr), Hardware.shortAddr(u.hatchAddr)), COLORS.cyan, COLORS.panelBg)
    end
end

function UI:renderSetupTab()
    self:drawFrame(2, 5, 76, 43, COLORS.border, COLORS.panelBg, "round")
    self:drawText(4, 5, " ◈ QFT SETUP & MAINTAINER FAILOVER ", COLORS.accent, COLORS.panelBg)
    self:drawButton(4, 7, "[Poll: " .. tostring(self.cfg.pollSec) .. "s]", COLORS.cyan, COLORS.btnBg, function()
        self.cfg.pollSec = (self.cfg.pollSec >= 20) and 2 or (self.cfg.pollSec + 2)
        self:save("Poll interval -> " .. self.cfg.pollSec .. "s")
    end)
    local extOff = (self.cfg.extLinkMode == "off")
    self:drawButton(20, 7, extOff and "[Mesh: OFF]" or "[Mesh: AUTO]", extOff and COLORS.yellow or COLORS.cyan, COLORS.btnBg, function()
        self.cfg.extLinkMode = extOff and "auto" or "off"
        self:save("ExtLink -> " .. self.cfg.extLinkMode)
    end)
    if self.extras.isAutostartEnabled then
        local auto = self.extras.isAutostartEnabled()
        self:drawButton(36, 7, auto and "[Autostart: ON]" or "[Autostart: OFF]", auto and COLORS.green or COLORS.muted, COLORS.btnBg, function()
            local nxt = self.extras.toggleAutostart()
            self.statusMsg = "Autostart -> " .. tostring(nxt)
        end)
    end
    local ms = self.state.maintMode or {}
    self:drawText(4, 10, "Maintainer Status : " .. tostring(ms.label or "OFFLINE"), COLORS.fg, COLORS.panelBg)
    self:drawText(4, 11, padOrTrunc(tostring(ms.detail or ""), 70), COLORS.muted, COLORS.panelBg)
    self:drawText(4, 13, "Tracked Inputs    : " .. tostring(#(self.cfg.localRules or {})) .. " rule(s)", COLORS.cyan, COLORS.panelBg)

    self:drawFrame(80, 5, 79, 43, COLORS.border, COLORS.panelBg, "round")
    self:drawText(82, 5, " ◈ ACTIVITY LOG ", COLORS.accent, COLORS.panelBg)
    for i = 1, math.min(19, #((self.state and self.state.events) or {})) do
        local e = self.state.events[i]
        local col = (e.stage == "ERR" and COLORS.red) or (e.stage == "WRN" and COLORS.yellow)
            or (e.stage == "OUT" and COLORS.green) or COLORS.fg
        self:drawText(82, 6 + i * 2, padOrTrunc(string.format("[%s] %s", e.stage or "DEC", e.text or ""), 75), col, COLORS.panelBg)
    end
end

function UI:render()
    self.hitboxes = {}
    self:clearNextBuffer(COLORS.bg, COLORS.fg)
    self:renderHeader()
    if self.tab == TAB_FLEET then self:renderFleetTab()
    elseif self.tab == TAB_RECIPES then self:renderRecipesTab()
    elseif self.tab == TAB_HW then self:renderHardwareTab()
    elseif self.tab == TAB_SETUP then self:renderSetupTab() end
    self:drawText(1, self.h - 1, string.rep("─", self.w), COLORS.border, COLORS.bg)
    self:drawText(2, self.h, padOrTrunc(self.statusMsg or "", self.w - 50), COLORS.fg, COLORS.bg)
    self:drawText(self.w - 46, self.h, "Keys: 1-4 Tabs | Space Arm | R Poll | Q Quit", COLORS.muted, COLORS.bg)
    self:flush()
end

function UI:handleTouch(x, y)
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
    if self.tab == TAB_RECIPES then
        self.recipeScroll = math.max(0, (self.recipeScroll or 0) + ((dir > 0) and -3 or 3))
        self:render()
    end
end

function UI:handleKeyDown(char)
    if char == 113 or char == 81 then self.running = false
    elseif char >= 49 and char <= 52 then self.tab = char - 48
    elseif char == 32 then
        self.cfg.armed = not (self.cfg.armed == true)
        self:save(self.cfg.armed and "QFT Fleet ARMED." or "QFT Fleet PAUSED.")
    elseif char == 114 or char == 82 then
        Scheduler.step(self.cfg, self.state, nil, self.comp)
        self.statusMsg = "Poll complete."
    end
    if self.running then self:render() end
end

return UI
