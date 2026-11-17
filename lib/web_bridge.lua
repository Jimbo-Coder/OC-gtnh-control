-- lib/web_bridge.lua
-- Optional zero-idle-cost localhost TCP bridge client (`127.0.0.1:8766`, role="dtpf")
-- Wakes only on `internet_ready` events or poll cycles to serve live DTPF telemetry & edits.

local component = require("component")
local computer = require("computer")
local RecipesDB = require("lib.recipes_db")

local BRIDGE_HOST = "127.0.0.1"
local BRIDGE_PORT = 8766
local RECONNECT_INTERVAL = 10.0
local MAX_READ_ITER = 24

local FAMILY_BY_ID = RecipesDB.BY_ID or {}
if not next(FAMILY_BY_ID) then
    for i = 1, #RecipesDB.FAMILIES do
        local f = RecipesDB.FAMILIES[i]
        FAMILY_BY_ID[f.id] = f
    end
end

local json = {}
do
    local escMap = {
        ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b",
        ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
    }
    local function encodeStr(s)
        return '"' .. tostring(s):gsub('[%z\1-\31"\\]', function(c)
            return escMap[c] or string.format("\\u%04x", string.byte(c))
        end) .. '"'
    end

    local function isArray(t)
        local n = #t
        local count = 0
        for k in pairs(t) do
            if type(k) ~= "number" or k < 1 or k > n or k ~= math.floor(k) then
                return false
            end
            count = count + 1
        end
        return count == n
    end

    local function encodeVal(v, out)
        local tp = type(v)
        if v == nil then
            out[#out + 1] = "null"
        elseif tp == "boolean" then
            out[#out + 1] = v and "true" or "false"
        elseif tp == "number" then
            if v ~= v or v == math.huge or v == -math.huge then
                out[#out + 1] = "null"
            elseif v == math.floor(v) and math.abs(v) < 1e15 then
                out[#out + 1] = string.format("%.0f", v)
            else
                out[#out + 1] = tostring(v)
            end
        elseif tp == "string" then
            out[#out + 1] = encodeStr(v)
        elseif tp == "table" then
            if isArray(v) then
                out[#out + 1] = "["
                for i = 1, #v do
                    if i > 1 then out[#out + 1] = "," end
                    encodeVal(v[i], out)
                end
                out[#out + 1] = "]"
            else
                out[#out + 1] = "{"
                local first = true
                for k, val in pairs(v) do
                    if val ~= nil then
                        if not first then out[#out + 1] = "," end
                        first = false
                        out[#out + 1] = encodeStr(tostring(k))
                        out[#out + 1] = ":"
                        encodeVal(val, out)
                    end
                end
                out[#out + 1] = "}"
            end
        else
            out[#out + 1] = encodeStr(tostring(v))
        end
    end

    function json.encode(v)
        local out = {}
        encodeVal(v, out)
        return table.concat(out)
    end

    local unesc = {
        ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b",
        f = "\f", n = "\n", r = "\r", t = "\t",
    }

    function json.decode(str)
        if type(str) ~= "string" then return nil, "not a string" end
        local pos, n = 1, #str
        local function skipWs()
            while pos <= n do
                local b = str:byte(pos)
                if b == 32 or b == 9 or b == 10 or b == 13 then pos = pos + 1 else break end
            end
        end
        local parseValue
        local function parseString()
            pos = pos + 1
            local chunks = {}
            while pos <= n do
                local ch = str:sub(pos, pos)
                if ch == '"' then pos = pos + 1; return table.concat(chunks) end
                if ch == "\\" then
                    pos = pos + 1
                    local esc = str:sub(pos, pos)
                    if esc == "u" then
                        local hex = str:sub(pos + 1, pos + 4)
                        local cp = tonumber(hex, 16) or 63
                        pos = pos + 5
                        if cp < 128 then
                            chunks[#chunks + 1] = string.char(cp)
                        elseif cp < 2048 then
                            chunks[#chunks + 1] = string.char(192 + math.floor(cp / 64), 128 + (cp % 64))
                        else
                            chunks[#chunks + 1] = string.char(224 + math.floor(cp / 4096), 128 + (math.floor(cp / 64) % 64), 128 + (cp % 64))
                        end
                    else
                        chunks[#chunks + 1] = unesc[esc] or esc
                        pos = pos + 1
                    end
                else
                    chunks[#chunks + 1] = ch
                    pos = pos + 1
                end
            end
            error("unterminated string")
        end
        local function parseNumber()
            local s = str:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", pos)
            if not s or s == "" then error("invalid number at " .. pos) end
            pos = pos + #s
            return tonumber(s)
        end
        local function parseArray()
            pos = pos + 1
            local arr = {}
            skipWs()
            if str:sub(pos, pos) == "]" then pos = pos + 1; return arr end
            while pos <= n do
                arr[#arr + 1] = parseValue()
                skipWs()
                local ch = str:sub(pos, pos)
                if ch == "," then pos = pos + 1
                elseif ch == "]" then pos = pos + 1; return arr
                else error("expected ',' or ']' at " .. pos)
                end
            end
            error("unterminated array")
        end
        local function parseObject()
            pos = pos + 1
            local obj = {}
            skipWs()
            if str:sub(pos, pos) == "}" then pos = pos + 1; return obj end
            while pos <= n do
                skipWs()
                local key = parseString()
                skipWs()
                if str:sub(pos, pos) ~= ":" then error("expected ':' at " .. pos) end
                pos = pos + 1
                obj[key] = parseValue()
                skipWs()
                local ch = str:sub(pos, pos)
                if ch == "," then pos = pos + 1
                elseif ch == "}" then pos = pos + 1; return obj
                else error("expected ',' or '}' at " .. pos)
                end
            end
            error("unterminated object")
        end
        parseValue = function()
            skipWs()
            local ch = str:sub(pos, pos)
            if ch == '"' then return parseString()
            elseif ch == "{" then return parseObject()
            elseif ch == "[" then return parseArray()
            elseif str:sub(pos, pos + 3) == "true" then pos = pos + 4; return true
            elseif str:sub(pos, pos + 4) == "false" then pos = pos + 5; return false
            elseif str:sub(pos, pos + 3) == "null" then pos = pos + 4; return nil
            else return parseNumber()
            end
        end
        local ok, val = pcall(parseValue)
        if not ok then return nil, val end
        return val
    end
end

local VALID_GLOBAL_CONV = { auto = true, always = true, off = true, passive_od = true, ondemand = true }
local VALID_FB_CONV = { global = true, on = true, off = true }
local VALID_OD_CONV = { auto_safe = true, on = true, off = true }
local VALID_DTPF_ROLE = { auto = true, passive_only = true, fallback_only = true, od_only = true, pinned = true, pinned_loop = true }
local VALID_DTPF_CONV = { global = true, auto = true, ondemand = true, always = true, off = true, passive_od = true }
local VALID_REC_CONV = { global = true, on = true, below_tgt = true, force = true, off = true }

local WebBridge = {}
WebBridge.__index = WebBridge

function WebBridge.new(cfg, runtimeState, ui, scheduleSave, Scheduler, Hardware, host, port)
    local self = setmetatable({}, WebBridge)
    self.cfg = cfg
    self.state = runtimeState
    self.ui = ui
    self.scheduleSave = scheduleSave
    self.Scheduler = Scheduler
    self.Hardware = Hardware
    self.host = host or BRIDGE_HOST
    self.port = tonumber(port) or BRIDGE_PORT
    self.sock = nil
    self.ready = false
    self.rxBuf = ""
    self.lastTry = -100
    self.connectStart = 0
    return self
end

function WebBridge:close()
    if self.sock then
        pcall(self.sock.close)
        self.sock = nil
    end
    self.ready = false
    self.rxBuf = ""
    self.connectStart = 0
end

function WebBridge:sendLine(obj)
    if not self.sock or not self.ready then return false end
    local data = json.encode(obj) .. "\n"
    local emptyTries = 0
    while #data > 0 do
        local ok, wr = pcall(self.sock.write, data)
        if not ok or wr == nil then
            self:close()
            return false
        end
        local n = tonumber(wr) or 0
        if n <= 0 then
            emptyTries = emptyTries + 1
            if emptyTries >= 64 then
                self:close()
                return false
            end
        else
            emptyTries = 0
            data = data:sub(n + 1)
        end
    end
    return true
end

function WebBridge:buildSnapshot()
    local cfg = self.cfg
    local st = self.state or {}
    local stockFluids = (st.stock and st.stock.fluids) or {}

    local cats = {}
    local floors = cfg.catalystFloors or {}
    for i = 1, #RecipesDB.CATALYST_TIERS do
        local ct = RecipesDB.CATALYST_TIERS[i]
        cats[i] = {
            code = ct.code,
            index = ct.index,
            label = ct.label,
            stock = stockFluids[ct.fluid] or 0,
            floor = tonumber(floors[ct.code]) or 100000,
        }
    end

    local dtpfs = {}
    local rawDtpfs = st.dtpfStatus or {}
    for i = 1, #(cfg.dtpfs or {}) do
        local d = cfg.dtpfs[i]
        local dst = rawDtpfs[i] or {}
        dtpfs[i] = {
            index = i,
            name = d.name or ("DTPF #" .. i),
            address = d.address,
            coords = d.coords or { x = d.x or 0, y = d.y or 0, z = d.z or 0 },
            enabled = (d.enabled ~= false),
            role = d.roleOverride or "auto",
            pinnedFamilyId = d.pinnedFamilyId,
            convOverride = d.convOverride or "global",
            catOverride = tonumber(d.catOverride) or 0,
            online = (dst.online == true),
            active = (dst.active == true),
            progress = tonumber(dst.progress) or 0,
            maxProgress = tonumber(dst.maxProgress) or 0,
            discountPct = tonumber(dst.discountPct) or 0,
            coilHeat = tonumber(dst.coilHeat) or 0,
            convergenceEnabled = (dst.convergenceEnabled == true),
            wantConv = (dst.wantConv == true),
            supportsConvControl = (dst.supportsConvControl ~= false),
            catalystTier = dst.catalystTier or dst.wantCatTier or 0,
            jobMode = dst.jobMode or "IDLE",
            jobLabel = dst.jobLabel or "Idle",
            familyId = dst.familyId,
            passiveStalled = (dst.passiveStalled == true),
            coverConflict = (dst.coverConflict == true),
        }
    end

    local recipes = {}
    local rStatuses = st.recipeStatus or {}
    for i = 1, #RecipesDB.FAMILIES do
        local fam = RecipesDB.FAMILIES[i]
        local rc = cfg.recipes[fam.id] or {}
        local rst = rStatuses[fam.id] or {}
        local tracked = rst.trackedOutput or fam.primaryOutput or {}
        local outType = (tracked.isFluid or tracked.type == "fluid") and "fluid" or "item"
        local curStock = tonumber(rst.currentStock) or 0
        local tgt = math.max(1, tonumber(rc.target) or 1)
        recipes[i] = {
            id = fam.id,
            name = fam.name,
            category = fam.category,
            priority = tonumber(rc.priority) or i,
            enabled = (rc.enabled == true),
            forever = (rc.forever == true),
            convMode = rc.convMode or "global",
            modifierIndex = tonumber(rc.modifierIndex) or 1,
            catalystTier = tonumber(rc.catalystTier) or 0,
            outputIndex = tonumber(rc.outputIndex) or 1,
            maxDtpfs = tonumber(rc.maxDtpfs) or 0,
            guardKey = rc.guardKey or "none",
            guardMin = tonumber(rc.guardMin) or 0,
            outputLabel = tracked.label or fam.name,
            outputType = outType,
            stock = curStock,
            target = tgt,
            pct = math.floor(((curStock / tgt) * 1000) + 0.5) / 10.0,
            stateStr = rst.stateStr or (rc.enabled and "Queued" or "Disabled"),
            runnable = (rst.runnable ~= false),
            reason = rst.reason or "Ready",
            convBelowTarget = (rst.convBelowTarget == true),
            activeDtpfs = rst.activeDtpfs or {},
        }
    end

    local od = st.onDemand or {}
    local evOut = {}
    local rawEv = st.events or {}
    local evStart = math.max(1, #rawEv - 14)
    for idx = #rawEv, evStart, -1 do
        local ev = rawEv[idx]
        if ev then
            evOut[#evOut + 1] = { ts = ev.ts, kind = ev.kind, msg = ev.msg }
        end
    end

    local bnOut = {}
    for idx, bn in ipairs(st.bottlenecks or {}) do
        if idx > 12 then break end
        bnOut[idx] = { kind = bn.kind, name = bn.name, familyId = bn.familyId, reason = bn.reason }
    end

    return {
        ok = true,
        liveOc = true,
        armed = (cfg.armed == true),
        stepCount = tonumber(st.stepCount) or 0,
        convControlSupported = (st.convControlSupported ~= false),
        odBridgeStatus = st.odBridgeStatus or "Idle",
        odFlushActive = (st.odFlushActive == true),
        onDemand = {
            hasWork = (od.hasWork == true),
            stalled = (od.stalled == true),
            stallReason = od.stallReason,
            summary = od.summary or "Idle",
        },
        policy = {
            globalConvMode = cfg.globalConvMode or "auto",
            fallbackConvMode = cfg.fallbackConvMode or "global",
            onDemandConvMode = cfg.onDemandConvMode or "auto_safe",
            pausePassivesOnOD = (cfg.pausePassivesOnOD ~= false),
            defaultCatalystTier = tonumber(cfg.defaultCatalystTier) or 4,
            catalystAutoFallback = (cfg.catalystAutoFallback ~= false),
            fallbackEnabled = (cfg.fallbackEnabled == true),
            fallbackFamilyId = cfg.fallbackFamilyId or "molten_infinity",
            allowParallelSameRecipe = (cfg.allowParallelSameRecipe ~= false),
        },
        catalysts = cats,
        dtr = {
            stock = stockFluids["dimensionallytranscendentresidue"] or 0,
            floor = tonumber(cfg.dtrReserveFloor) or 10000000,
        },
        dtpfs = dtpfs,
        recipes = recipes,
        bottlenecks = bnOut,
        events = evOut,
    }
end

function WebBridge:applyPatch(patch)
    if type(patch) ~= "table" then return false, "invalid patch" end
    local cfg = self.cfg
    local changed = false

    if type(patch.armed) == "boolean" then
        cfg.armed = patch.armed
        changed = true
    end
    if patch.globalConvMode and VALID_GLOBAL_CONV[patch.globalConvMode] then
        cfg.globalConvMode = patch.globalConvMode
        changed = true
    end
    if patch.fallbackConvMode and VALID_FB_CONV[patch.fallbackConvMode] then
        cfg.fallbackConvMode = patch.fallbackConvMode
        changed = true
    end
    if patch.onDemandConvMode and VALID_OD_CONV[patch.onDemandConvMode] then
        cfg.onDemandConvMode = patch.onDemandConvMode
        changed = true
    end
    if type(patch.pausePassivesOnOD) == "boolean" then
        cfg.pausePassivesOnOD = patch.pausePassivesOnOD
        changed = true
    end
    if tonumber(patch.defaultCatalystTier) then
        local t = math.max(1, math.min(5, math.floor(tonumber(patch.defaultCatalystTier))))
        cfg.defaultCatalystTier = t
        changed = true
    end
    if type(patch.catalystAutoFallback) == "boolean" then
        cfg.catalystAutoFallback = patch.catalystAutoFallback
        changed = true
    end
    if type(patch.fallbackEnabled) == "boolean" then
        cfg.fallbackEnabled = patch.fallbackEnabled
        changed = true
    end
    if type(patch.fallbackFamilyId) == "string" and FAMILY_BY_ID[patch.fallbackFamilyId] then
        cfg.fallbackFamilyId = patch.fallbackFamilyId
        changed = true
    end
    if type(patch.allowParallelSameRecipe) == "boolean" then
        cfg.allowParallelSameRecipe = patch.allowParallelSameRecipe
        changed = true
    end
    if tonumber(patch.dtrReserveFloor) ~= nil then
        cfg.dtrReserveFloor = math.max(0, math.floor(tonumber(patch.dtrReserveFloor)))
        changed = true
    end
    if type(patch.catalystFloors) == "table" then
        cfg.catalystFloors = cfg.catalystFloors or {}
        for code, val in pairs(patch.catalystFloors) do
            if tonumber(val) ~= nil then
                cfg.catalystFloors[code] = math.max(0, math.floor(tonumber(val)))
                changed = true
            end
        end
    end

    if tonumber(patch.dtpfIndex) then
        local idx = math.floor(tonumber(patch.dtpfIndex))
        local d = cfg.dtpfs and cfg.dtpfs[idx]
        if not d then return false, "unknown dtpfIndex" end
        if type(patch.enabled) == "boolean" then
            d.enabled = patch.enabled
            changed = true
        end
        if patch.roleOverride and VALID_DTPF_ROLE[patch.roleOverride] then
            d.roleOverride = patch.roleOverride
            if d.roleOverride ~= "pinned" and d.roleOverride ~= "pinned_loop" then
                d.pinnedFamilyId = nil
            end
            changed = true
        end
        if patch.pinnedFamilyId ~= nil then
            if patch.pinnedFamilyId == "" or patch.pinnedFamilyId == false then
                d.pinnedFamilyId = nil
                if d.roleOverride == "pinned" or d.roleOverride == "pinned_loop" then
                    d.roleOverride = "auto"
                end
            elseif FAMILY_BY_ID[patch.pinnedFamilyId] then
                d.pinnedFamilyId = patch.pinnedFamilyId
                if d.roleOverride ~= "pinned" and d.roleOverride ~= "pinned_loop" then
                    d.roleOverride = "pinned"
                end
            end
            changed = true
        end
        if patch.convOverride and VALID_DTPF_CONV[patch.convOverride] then
            d.convOverride = patch.convOverride
            changed = true
        end
        if tonumber(patch.catOverride) ~= nil then
            d.catOverride = math.max(0, math.min(5, math.floor(tonumber(patch.catOverride))))
            changed = true
        end
    end

    if type(patch.familyId) == "string" and cfg.recipes and cfg.recipes[patch.familyId] then
        local rc = cfg.recipes[patch.familyId]
        if type(patch.enabled) == "boolean" then
            rc.enabled = patch.enabled
            if not rc.enabled and cfg.fallbackFamilyId == patch.familyId then
                cfg.fallbackEnabled = false
            end
            changed = true
        end
        if type(patch.forever) == "boolean" then
            rc.forever = patch.forever
            if rc.forever then rc.enabled = true end
            changed = true
        end
        if patch.convMode and VALID_REC_CONV[patch.convMode] then
            rc.convMode = patch.convMode
            changed = true
        end
        if tonumber(patch.target) ~= nil then
            rc.target = math.max(1, math.floor(tonumber(patch.target)))
            changed = true
        end
        if tonumber(patch.modifierIndex) ~= nil then
            local fam = FAMILY_BY_ID[patch.familyId]
            local maxM = (fam and fam.modifiers) and #fam.modifiers or 1
            rc.modifierIndex = math.max(1, math.min(maxM, math.floor(tonumber(patch.modifierIndex))))
            rc.variantIndex = rc.modifierIndex
            rc.outputIndex = 1
            changed = true
        end
        if tonumber(patch.catalystTier) ~= nil then
            rc.catalystTier = math.max(0, math.min(5, math.floor(tonumber(patch.catalystTier))))
            changed = true
        end
        if tonumber(patch.outputIndex) ~= nil then
            rc.outputIndex = math.max(1, math.floor(tonumber(patch.outputIndex)))
            changed = true
        end
        if tonumber(patch.maxDtpfs) ~= nil then
            rc.maxDtpfs = math.max(0, math.floor(tonumber(patch.maxDtpfs)))
            changed = true
        end
        if patch.movePriority ~= nil then
            local mv = patch.movePriority
            if mv == "top" or mv == "bottom" or tonumber(mv) then
                self.Scheduler.moveRecipePriority(cfg, patch.familyId, tonumber(mv) or mv, patch.enabledOnly == true)
                changed = true
            end
        end
    end

    if changed then
        self.state._forcePollNow = true
        pcall(self.Scheduler.step, cfg, self.state, { cachedOnly = true, interactive = true })
        if self.ui then
            pcall(self.ui.setStatus, self.ui, "Web console updated DTPF settings.")
        end
        if self.scheduleSave then
            self.scheduleSave()
        end
    end
    return true, nil
end

function WebBridge:handleCommand(cmd)
    local op = cmd.op
    local id = cmd.id
    if op == "ping" then
        self:sendLine({ id = id, ok = true, role = "dtpf", armed = (self.cfg.armed == true) })
        return
    elseif op == "dtpf_state" then
        local snap = self:buildSnapshot()
        snap.id = id
        self:sendLine(snap)
        return
    elseif op == "dtpf_patch" then
        local okP, errP = self:applyPatch(cmd.patch or cmd)
        if not okP then
            self:sendLine({ id = id, ok = false, error = tostring(errP or "patch failed") })
            return
        end
        local snap = self:buildSnapshot()
        snap.id = id
        self:sendLine(snap)
        return
    elseif op == "dtpf_action" then
        local action = cmd.action
        if action == "poll_now" then
            self.state._forcePollNow = true
        elseif action == "flush_od" then
            if self.state.odFlushActive then
                self.Scheduler.cancelOdFlush(self.cfg, self.state)
            else
                self.Scheduler.requestOdFlush(self.state)
            end
        elseif action == "lock_autopull" and self.Hardware and self.Hardware.lockAllPassiveAutoPull then
            self.Hardware.lockAllPassiveAutoPull()
        else
            self:sendLine({ id = id, ok = false, error = "unknown action: " .. tostring(action) })
            return
        end
        local snap = self:buildSnapshot()
        snap.id = id
        self:sendLine(snap)
        return
    elseif op == "reboot" then
        self:sendLine({ id = id, ok = true, rebooting = true })
        self:close()
        if computer.shutdown then pcall(computer.shutdown, true) end
        return
    end
    self:sendLine({ id = id, ok = false, error = "unknown op: " .. tostring(op) })
end

function WebBridge:ensureConnected(now)
    if self.sock then
        if self.ready then return true end
        local okF, conn = pcall(self.sock.finishConnect)
        if (not okF) or (conn == nil) or ((now - (self.connectStart or now)) > 8.0) then
            self:close()
            return false
        end
        if conn == true then
            self.ready = true
            self:sendLine({ op = "hello", role = "dtpf", version = 1 })
            return true
        end
        return false
    end

    if (now - self.lastTry) < RECONNECT_INTERVAL then return false end
    self.lastTry = now

    if not component.isAvailable("internet") then return false end
    local okGet, inet = pcall(function()
        local addr = component.list and component.list("internet", true)()
        if addr then return component.proxy(addr) end
        return component.internet
    end)
    if not okGet or not inet or not inet.connect then return false end

    local okConn, sock = pcall(inet.connect, tostring(self.host) .. ":" .. tostring(self.port))
    if not okConn or not sock then
        return false
    end
    self.sock = sock
    self.ready = false
    self.rxBuf = ""
    self.connectStart = now
    local okF, conn = pcall(sock.finishConnect)
    if (not okF) or (conn == nil) then
        self:close()
        return false
    end
    if conn == true then
        self.ready = true
        self:sendLine({ op = "hello", role = "dtpf", version = 1 })
        return true
    end
    return false
end

function WebBridge:drain()
    local now = computer.uptime()
    if not self:ensureConnected(now) then return false end
    local dirty = false
    for _ = 1, MAX_READ_ITER do
        if not self.sock or not self.ready then break end
        local okR, chunk = pcall(self.sock.read, 4096)
        if not okR or chunk == nil then
            self:close()
            break
        end
        if chunk == "" then
            break
        end
        self.rxBuf = self.rxBuf .. chunk
        while true do
            local nl = self.rxBuf:find("\n", 1, true)
            if not nl then break end
            local rawLine = self.rxBuf:sub(1, nl - 1):gsub("\r$", "")
            self.rxBuf = self.rxBuf:sub(nl + 1)
            if rawLine ~= "" then
                local cmd = json.decode(rawLine)
                if type(cmd) == "table" and cmd.op then
                    pcall(self.handleCommand, self, cmd)
                    dirty = true
                end
            end
        end
    end
    return dirty
end

function WebBridge:step(now)
    return self:ensureConnected(now or computer.uptime())
end

return WebBridge
