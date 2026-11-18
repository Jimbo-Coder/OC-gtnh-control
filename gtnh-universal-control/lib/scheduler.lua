-- /home/universal/lib/scheduler.lua
-- Per-Pool Mutual-Exclusion Scheduler, Anti-Contamination Settle Guard,
-- EMA Drain-Rate Estimator, SRTF Preemption + Aging, and Stall Isolation for GTNH Universal Control.

local Hardware = require("lib.hardware")

local Scheduler = {}

local MAX_LOGS = 160
Scheduler.PRIORITY_WEIGHTS = {
    pin = 4,
    high = 3,
    normal = 2,
    low = 1,
    off = 0,
}
Scheduler.PRIORITY_ORDER = { "normal", "high", "pin", "low", "off" }
Scheduler.POOL_MODES = { "srtf", "fifo", "round_robin" }

local function makeSlice(color)
    local cInfo = Hardware.COLORS[color] or { name = "Color " .. tostring(color) }
    return {
        color = color,
        label = cInfo.name,
        ifaceAddr = nil,
        priority = "normal",
        enabled = true,
        learnedRate = nil,
        baselineItems = {},
        baselineFluids = {},
    }
end

function Scheduler.newPool(id, name, rsAddr, side)
    local slices = {}
    for c = 0, 15 do
        slices[c] = makeSlice(c)
    end
    return {
        id = id or 1,
        name = name or ("Pool " .. tostring(id or 1)),
        rsAddr = rsAddr,
        side = (side ~= nil) and side or 2, -- Default North (2)
        mode = "srtf",
        enabled = true,
        slices = slices,
    }
end

function Scheduler.defaultConfig()
    return {
        armed = false,
        pollIntervalSec = 0.5,
        minHoldSec = 15.0,
        settleSec = 1.0,
        emptyConfirmPolls = 2,
        preemptRatio = 0.35,
        agingPerMin = 0.15,
        stallTimeoutSec = 120.0,
        retryStalledSec = 60.0,
        defaultProbeRate = 8.0,
        ignoreBuiltinNC = true,
        extLinkMode = "auto",
        logLevel = "normal",
        pools = {
            Scheduler.newPool(1, "Pool 1", nil, 2),
        },
    }
end

function Scheduler.normalizeConfig(cfg)
    local def = Scheduler.defaultConfig()
    if type(cfg) ~= "table" then return def end

    cfg.armed = (cfg.armed == true)
    cfg.pollIntervalSec = math.max(0.1, math.min(10.0, tonumber(cfg.pollIntervalSec) or def.pollIntervalSec))
    cfg.minHoldSec = math.max(1.0, math.min(600.0, tonumber(cfg.minHoldSec) or def.minHoldSec))
    cfg.settleSec = math.max(0.0, math.min(30.0, tonumber(cfg.settleSec) or def.settleSec))
    cfg.emptyConfirmPolls = math.max(1, math.min(10, math.floor(tonumber(cfg.emptyConfirmPolls) or def.emptyConfirmPolls)))
    cfg.preemptRatio = math.max(0.05, math.min(0.95, tonumber(cfg.preemptRatio) or def.preemptRatio))
    cfg.agingPerMin = math.max(0.0, math.min(0.75, tonumber(cfg.agingPerMin) or def.agingPerMin))
    cfg.stallTimeoutSec = math.max(5.0, math.min(3600.0, tonumber(cfg.stallTimeoutSec) or def.stallTimeoutSec))
    cfg.retryStalledSec = math.max(5.0, math.min(3600.0, tonumber(cfg.retryStalledSec) or def.retryStalledSec))
    cfg.defaultProbeRate = math.max(0.1, math.min(1000.0, tonumber(cfg.defaultProbeRate) or def.defaultProbeRate))
    if cfg.ignoreBuiltinNC == nil then cfg.ignoreBuiltinNC = true else cfg.ignoreBuiltinNC = (cfg.ignoreBuiltinNC == true) end
    cfg.extLinkMode = (cfg.extLinkMode == "off") and "off" or "auto"
    if cfg.logLevel ~= "quiet" and cfg.logLevel ~= "normal" and cfg.logLevel ~= "raw" then
        cfg.logLevel = "normal"
    end

    if type(cfg.pools) ~= "table" or #cfg.pools == 0 then
        cfg.pools = def.pools
    end

    local nextId = 1
    for i = 1, #cfg.pools do
        local p = cfg.pools[i]
        if type(p) ~= "table" then
            p = Scheduler.newPool(nextId)
            cfg.pools[i] = p
        end
        p.id = math.max(1, math.floor(tonumber(p.id) or nextId))
        nextId = math.max(nextId + 1, p.id + 1)
        p.name = (type(p.name) == "string" and p.name ~= "") and p.name or ("Pool " .. tostring(p.id))
        if p.rsAddr == "" then p.rsAddr = nil end
        p.side = math.max(0, math.min(5, math.floor(tonumber(p.side) or 2)))
        if p.mode ~= "srtf" and p.mode ~= "fifo" and p.mode ~= "round_robin" then
            p.mode = "srtf"
        end
        if p.enabled == nil then p.enabled = true else p.enabled = (p.enabled == true) end
        if type(p.slices) ~= "table" then p.slices = {} end
        for c = 0, 15 do
            local s = p.slices[c]
            if type(s) ~= "table" then
                s = makeSlice(c)
                p.slices[c] = s
            else
                s.color = c
                local cInfo = Hardware.COLORS[c] or { name = "Color " .. c }
                s.label = (type(s.label) == "string" and s.label ~= "") and s.label or cInfo.name
                if s.ifaceAddr == "" then s.ifaceAddr = nil end
                if Scheduler.PRIORITY_WEIGHTS[s.priority] == nil then s.priority = "normal" end
                if s.enabled == nil then s.enabled = true else s.enabled = (s.enabled == true) end
                if type(s.learnedRate) ~= "number" or s.learnedRate <= 0 then s.learnedRate = nil end
                if type(s.baselineItems) ~= "table" then s.baselineItems = {} end
                if type(s.baselineFluids) ~= "table" then s.baselineFluids = {} end
            end
        end
    end

    return cfg
end

function Scheduler.newState()
    return {
        poolStates = {},
        sliceStates = {},
        queue = {},
        logs = {},
        rawSnapshot = {},
        forceColorByPool = {},
        kpis = {
            activePools = 0,
            queuedSlices = 0,
            stalledCount = 0,
            completedBatches = 0,
            preemptions = 0,
        },
        discovery = {
            redstones = {},
            interfaces = {},
            partWarnings = {},
            hasModem = false,
            hasWireless = false,
            hasTunnel = false,
            hasGpu = false,
            hasScreen = false,
        },
        stepCount = 0,
        _lastPollUptime = nil,
    }
end

local LOG_RANK = { quiet = 1, normal = 2, raw = 3 }

function Scheduler.log(state, cfg, lvl, tag, msg)
    if not state then return end
    local minLvl = (cfg and cfg.logLevel) or "normal"
    -- Always record WRN & DEC; filter IN/OUT raw churn if logLevel is quiet.
    if lvl == "raw" and minLvl ~= "raw" then return end
    if lvl == "normal" and minLvl == "quiet" and tag ~= "WRN" then return end
    local logs = state.logs
    logs[#logs + 1] = {
        t = state.lastStepSec or 0,
        lvl = lvl or "normal",
        tag = tag or "DEC",
        msg = tostring(msg or ""),
    }
    if #logs > MAX_LOGS then
        table.remove(logs, 1)
    end
end

local function sliceKey(poolId, color)
    return tostring(poolId) .. ":" .. tostring(color)
end

function Scheduler.sliceKey(poolId, color)
    return sliceKey(poolId, color)
end

local function ensurePoolState(state, poolId)
    local p = state.poolStates[poolId]
    if not p then
        p = {
            phase = "IDLE",
            activeColor = nil,
            lastWrittenColor = "__INIT__",
            pendingColor = nil,
            activeSince = 0,
            lastProgressAt = 0,
            lastScanAt = nil,
            lastActiveWork = nil,
            lastOffAt = nil,
            settleUntil = 0,
            pulseUntil = 0,
            pulseColor = nil,
            zeroStreak = 0,
            lastServedColor = -1,
            activeLabel = "",
            activeEtaSec = nil,
            activeRate = nil,
        }
        state.poolStates[poolId] = p
    end
    return p
end

local function ensureSliceState(state, poolId, color)
    local k = sliceKey(poolId, color)
    local s = state.sliceStates[k]
    if not s then
        s = {
            ok = true,
            err = nil,
            workScore = 0,
            itemUnits = 0,
            fluidUnits = 0,
            activeItemTypes = 0,
            activeFluidTypes = 0,
            topLabel = "",
            busySince = nil,
            stalledUntil = 0,
            stalledReason = nil,
            lastStallWork = nil,
            etaSec = nil,
            effectiveEtaSec = nil,
            lastScanAt = 0,
        }
        state.sliceStates[k] = s
    end
    return s
end

function Scheduler.syncHardware(cfg, state, compLib)
    Scheduler.normalizeConfig(cfg)
    local disc = Hardware.discover(compLib)
    if state then
        state.discovery = disc
    end

    -- Auto-select first bundled Redstone I/O on Pool 1 if unconfigured
    local firstBundled = nil
    for i = 1, #disc.redstones do
        if disc.redstones[i].bundled then
            firstBundled = disc.redstones[i].address
            break
        end
    end
    if firstBundled then
        for pi = 1, #cfg.pools do
            if not cfg.pools[pi].rsAddr then
                cfg.pools[pi].rsAddr = firstBundled
                break
            end
        end
    end
    return disc
end

function Scheduler.triggerPulseTest(cfg, state, poolId, color, durationSec, nowSec, compLib)
    local pool = nil
    for i = 1, #(cfg.pools or {}) do
        if cfg.pools[i].id == poolId then pool = cfg.pools[i] break end
    end
    if not pool or not pool.rsAddr then return false, "Configure Redstone I/O first" end
    cfg.armed = false
    Hardware.zeroAllManagedPools(cfg, compLib)
    local pState = ensurePoolState(state, pool.id)
    pState.phase = "PULSE_TEST"
    pState.activeColor = color
    pState.pulseColor = color
    pState.pulseUntil = (nowSec or 0) + (tonumber(durationSec) or 2.0)
    pState.lastWrittenColor = color
    Hardware.setPoolOutputs(pool.rsAddr, pool.side, color, compLib)
    Scheduler.log(state, cfg, "normal", "OUT", string.format("%s: Pulse test Color %d (%s) for %.1fs",
        pool.name, color, (Hardware.COLORS[color] and Hardware.COLORS[color].name or color), durationSec or 2.0))
    return true
end

function Scheduler.allOff(cfg, state, nowSec, compLib)
    cfg.armed = false
    Hardware.zeroAllManagedPools(cfg, compLib)
    if state then
        state.forceColorByPool = {}
        for i = 1, #(cfg.pools or {}) do
            local p = cfg.pools[i]
            local pState = ensurePoolState(state, p.id)
            pState.phase = "PAUSED"
            pState.activeColor = nil
            pState.pendingColor = nil
            pState.pulseColor = nil
            pState.pulseUntil = 0
            pState.lastWrittenColor = nil
            pState.lastOffAt = nowSec or pState.lastOffAt
        end
        Scheduler.log(state, cfg, "normal", "OUT", "ALL OUTPUTS FORCED OFF (PAUSED)")
    end
end

function Scheduler.clearStall(cfg, state, poolId, color)
    if not state then return end
    local sState = ensureSliceState(state, poolId, color)
    sState.stalledUntil = 0
    sState.stalledReason = nil
    sState.lastStallWork = nil
    Scheduler.log(state, cfg, "normal", "DEC", string.format("Cleared stall on Pool %s Color %d", tostring(poolId), tonumber(color) or -1))
end

local function writePoolColor(cfg, state, pool, pState, colorOrNil, nowSec, compLib)
    if pState.lastWrittenColor == colorOrNil then
        return true
    end
    local ok, err = Hardware.setPoolOutputs(pool.rsAddr, pool.side, colorOrNil, compLib)
    if ok then
        local prev = pState.lastWrittenColor
        pState.lastWrittenColor = colorOrNil
        if colorOrNil == nil and type(prev) == "number" then
            pState.lastOffAt = nowSec
        end
        if colorOrNil == nil then
            Scheduler.log(state, cfg, "raw", "OUT", string.format("%s [%s]: Bundled OFF", pool.name, Hardware.SIDE_NAMES[pool.side] or pool.side))
        else
            local cname = Hardware.COLORS[colorOrNil] and Hardware.COLORS[colorOrNil].name or tostring(colorOrNil)
            Scheduler.log(state, cfg, "normal", "OUT", string.format("%s [%s]: ON Color %d (%s)", pool.name, Hardware.SIDE_NAMES[pool.side] or pool.side, colorOrNil, cname))
        end
        return true
    end
    Scheduler.log(state, cfg, "normal", "WRN", string.format("%s redstone write failed: %s", pool.name, tostring(err)))
    return false
end

local function computeSliceMetrics(slice, sState, cfg, nowSec)
    local rate = tonumber(slice.learnedRate) or cfg.defaultProbeRate or 8.0
    rate = math.max(0.05, rate)
    local rawEta = sState.workScore / rate
    local waitSec = sState.busySince and math.max(0, nowSec - sState.busySince) or 0
    local discount = math.min(0.80, (waitSec / 60.0) * (cfg.agingPerMin or 0.15))
    local effEta = rawEta * (1.0 - discount)
    sState.etaSec = rawEta
    sState.effectiveEtaSec = effEta
    return rawEta, effEta, rate, waitSec
end

local function pickCandidate(pool, state, cfg, nowSec, lastServedColor)
    local mode = pool.mode or "srtf"
    local forcedColor = state.forceColorByPool and state.forceColorByPool[pool.id]
    local cands = {}

    for c = 0, 15 do
        local slice = pool.slices[c]
        if slice and slice.ifaceAddr and slice.ifaceAddr ~= "" and slice.enabled ~= false and slice.priority ~= "off" then
            local sState = ensureSliceState(state, pool.id, c)
            local isForced = (forcedColor == c)
            if isForced and sState.workScore > 0 then
                sState.stalledUntil = 0
                sState.stalledReason = nil
                local rawEta, effEta, rate = computeSliceMetrics(slice, sState, cfg, nowSec)
                return {
                    color = c,
                    slice = slice,
                    sState = sState,
                    priWeight = (Scheduler.PRIORITY_WEIGHTS[slice.priority] or 2),
                    rawEta = rawEta,
                    effectiveEta = effEta,
                    rate = rate,
                    forced = true,
                }
            end
            if sState.ok and sState.workScore > 0 and nowSec >= (sState.stalledUntil or 0) then
                local rawEta, effEta, rate = computeSliceMetrics(slice, sState, cfg, nowSec)
                cands[#cands + 1] = {
                    color = c,
                    slice = slice,
                    sState = sState,
                    priWeight = (Scheduler.PRIORITY_WEIGHTS[slice.priority] or 2),
                    rawEta = rawEta,
                    effectiveEta = effEta,
                    rate = rate,
                    busySince = sState.busySince or nowSec,
                    forced = false,
                }
            end
        end
    end

    if #cands == 0 then return nil end

    table.sort(cands, function(a, b)
        if a.priWeight ~= b.priWeight then
            return a.priWeight > b.priWeight
        end
        if mode == "fifo" then
            if math.abs(a.busySince - b.busySince) > 1e-6 then
                return a.busySince < b.busySince
            end
        elseif mode == "round_robin" then
            local last = tonumber(lastServedColor) or -1
            local da = (a.color - last - 1 + 16) % 16
            local db = (b.color - last - 1 + 16) % 16
            if da ~= db then
                return da < db
            end
        else -- "srtf"
            if math.abs(a.effectiveEta - b.effectiveEta) > 1e-6 then
                return a.effectiveEta < b.effectiveEta
            end
            if math.abs(a.busySince - b.busySince) > 1e-6 then
                return a.busySince < b.busySince
            end
        end
        return a.color < b.color
    end)

    return cands[1]
end

local function enterSettleOrIdle(cfg, state, pool, pState, nextColor, nowSec, compLib)
    pState.activeColor = nil
    pState.lastActiveWork = nil
    pState.zeroStreak = 0
    pState.activeLabel = ""
    pState.activeEtaSec = nil
    pState.activeRate = nil
    writePoolColor(cfg, state, pool, pState, nil, nowSec, compLib)
    if nextColor ~= nil and (cfg.settleSec or 0) > 0 then
        pState.phase = "SETTLING"
        pState.pendingColor = nextColor
        pState.settleUntil = nowSec + cfg.settleSec
    elseif nextColor ~= nil then
        pState.phase = "ACTIVE"
        pState.activeColor = nextColor
        pState.lastServedColor = nextColor
        pState.activeSince = nowSec
        pState.lastProgressAt = nowSec
        local sState = ensureSliceState(state, pool.id, nextColor)
        pState.lastActiveWork = sState.workScore
        pState.activeLabel = pool.slices[nextColor].label
        pState.activeEtaSec = sState.etaSec
        pState.activeRate = pool.slices[nextColor].learnedRate or cfg.defaultProbeRate
        writePoolColor(cfg, state, pool, pState, nextColor, nowSec, compLib)
    else
        pState.phase = "IDLE"
        pState.pendingColor = nil
    end
end

function Scheduler.step(cfg, state, nowSec, opts, compLib)
    opts = opts or {}
    nowSec = tonumber(nowSec) or 0
    Scheduler.normalizeConfig(cfg)
    state.stepCount = (state.stepCount or 0) + 1
    state.lastStepSec = nowSec
    state._lastPollUptime = nowSec

    local queue = {}
    local rawSnap = {}
    local activePools = 0
    local queuedSlices = 0
    local stalledCount = 0

    for pi = 1, #cfg.pools do
        local pool = cfg.pools[pi]
        local pState = ensurePoolState(state, pool.id)
        local dtPoll = pState.lastScanAt and math.max(0, nowSec - pState.lastScanAt) or 0

        -- 1. Scan all bound subnets in this pool (unless cachedOnly)
        if not opts.cachedOnly then
            pState.lastScanAt = nowSec
            for c = 0, 15 do
                local slice = pool.slices[c]
                local sState = ensureSliceState(state, pool.id, c)
                if slice and slice.ifaceAddr and slice.ifaceAddr ~= "" then
                    local scan = Hardware.scanSubnet(slice.ifaceAddr, slice, { ignoreBuiltinNC = cfg.ignoreBuiltinNC }, compLib)
                    sState.ok = scan.ok
                    sState.err = scan.err
                    sState.itemUnits = scan.itemUnits or 0
                    sState.fluidUnits = scan.fluidUnits or 0
                    sState.workScore = scan.workScore or 0
                    sState.activeItemTypes = scan.activeItemTypes or 0
                    sState.activeFluidTypes = scan.activeFluidTypes or 0
                    sState.topLabel = scan.topLabel or ""
                    sState.lastScanAt = nowSec
                    if scan.ok then
                        if sState.workScore > 0 then
                            sState.busySince = sState.busySince or nowSec
                            if (sState.stalledUntil or 0) > nowSec and sState.lastStallWork ~= nil
                                and math.abs(sState.workScore - sState.lastStallWork) > 1e-6 then
                                sState.stalledUntil = 0
                                sState.stalledReason = nil
                                sState.lastStallWork = nil
                                Scheduler.log(state, cfg, "normal", "DEC", string.format("%s C%d: Stock changed -> cleared stall", pool.name, c))
                            end
                            computeSliceMetrics(slice, sState, cfg, nowSec)
                        else
                            sState.busySince = nil
                            sState.stalledUntil = 0
                            sState.stalledReason = nil
                            sState.lastStallWork = nil
                            sState.etaSec = 0
                            sState.effectiveEtaSec = 0
                        end
                    end
                    rawSnap[#rawSnap + 1] = string.format("P%d C%02d (%s): %s work=%.2f (%dI/%dL) err=%s",
                        pool.id, c, slice.label, scan.ok and "OK" or "ERR", sState.workScore,
                        sState.itemUnits, sState.fluidUnits, tostring(scan.err or "-"))
                else
                    sState.workScore = 0
                    sState.itemUnits = 0
                    sState.fluidUnits = 0
                    sState.busySince = nil
                    sState.ok = true
                    sState.err = nil
                end
            end
        end

        -- 2. Handle PULSE_TEST (runs briefly while paused, auto-expiring back to PAUSED/OFF)
        if pState.phase == "PULSE_TEST" then
            if (not cfg.armed) and nowSec < (pState.pulseUntil or 0) and pool.rsAddr then
                writePoolColor(cfg, state, pool, pState, pState.pulseColor, nowSec, compLib)
            else
                pState.pulseColor = nil
                pState.pulseUntil = 0
                pState.activeColor = nil
                writePoolColor(cfg, state, pool, pState, nil, nowSec, compLib)
                pState.phase = cfg.armed and "IDLE" or "PAUSED"
            end
        end

        -- 3. Scheduling decision per pool (Skip redstone state changes on dryRun!)
        if not opts.dryRun and pState.phase ~= "PULSE_TEST" then
            if (not cfg.armed) or (not pool.enabled) or (not pool.rsAddr) then
                pState.phase = pool.rsAddr and "PAUSED" or "NO_RS"
                pState.activeColor = nil
                pState.pendingColor = nil
                pState.activeLabel = ""
                pState.activeEtaSec = nil
                pState.activeRate = nil
                if pool.rsAddr then
                    writePoolColor(cfg, state, pool, pState, nil, nowSec, compLib)
                end
            else
                -- Check progress / completion / stall on active slice
                if pState.phase == "ACTIVE" and pState.activeColor ~= nil then
                    local ac = pState.activeColor
                    local aSlice = pool.slices[ac]
                    local aState = ensureSliceState(state, pool.id, ac)
                    local prevWork = pState.lastActiveWork

                    if aSlice and aSlice.enabled ~= false and aSlice.priority ~= "off" and aSlice.ifaceAddr then
                        if aState.workScore <= 0 then
                            pState.zeroStreak = (pState.zeroStreak or 0) + 1
                            pState.lastActiveWork = 0
                            pState.lastProgressAt = nowSec
                            if pState.zeroStreak >= cfg.emptyConfirmPolls then
                                state.kpis.completedBatches = (state.kpis.completedBatches or 0) + 1
                                Scheduler.log(state, cfg, "normal", "DEC", string.format("%s C%d (%s): Batch complete", pool.name, ac, aSlice.label))
                                if state.forceColorByPool and state.forceColorByPool[pool.id] == ac then
                                    state.forceColorByPool[pool.id] = nil
                                end
                                local nxt = pickCandidate(pool, state, cfg, nowSec, pState.lastServedColor)
                                enterSettleOrIdle(cfg, state, pool, pState, nxt and nxt.color or nil, nowSec, compLib)
                            end
                        else
                            pState.zeroStreak = 0
                            if prevWork ~= nil and aState.workScore < (prevWork - 1e-6) and dtPoll > 0 then
                                local instRate = math.max(0.01, (prevWork - aState.workScore) / dtPoll)
                                aSlice.learnedRate = aSlice.learnedRate and (0.35 * instRate + 0.65 * aSlice.learnedRate) or instRate
                                pState.lastActiveWork = aState.workScore
                                pState.lastProgressAt = nowSec
                            elseif prevWork == nil or aState.workScore > prevWork then
                                -- Fresh batch pushed into active slice via Allow Same Recipe!
                                pState.lastActiveWork = aState.workScore
                                pState.lastProgressAt = nowSec
                            elseif (nowSec - (pState.lastProgressAt or nowSec)) >= cfg.stallTimeoutSec then
                                aState.stalledUntil = nowSec + cfg.retryStalledSec
                                aState.stalledReason = string.format("No drain for %ds", math.floor(cfg.stallTimeoutSec))
                                aState.lastStallWork = aState.workScore
                                Scheduler.log(state, cfg, "normal", "WRN", string.format("%s C%d (%s): STALLED -> yielding pool", pool.name, ac, aSlice.label))
                                if state.forceColorByPool and state.forceColorByPool[pool.id] == ac then
                                    state.forceColorByPool[pool.id] = nil
                                end
                                local nxt = pickCandidate(pool, state, cfg, nowSec, pState.lastServedColor)
                                enterSettleOrIdle(cfg, state, pool, pState, nxt and nxt.color or nil, nowSec, compLib)
                            end

                            -- Preemption evaluation if still ACTIVE
                            if pState.phase == "ACTIVE" and pState.activeColor == ac then
                                local rawEta, effEta, rate = computeSliceMetrics(aSlice, aState, cfg, nowSec)
                                pState.activeLabel = aSlice.label
                                pState.activeEtaSec = rawEta
                                pState.activeRate = rate

                                local best = pickCandidate(pool, state, cfg, nowSec, pState.lastServedColor)
                                local heldSec = nowSec - (pState.activeSince or nowSec)
                                if best and best.color ~= ac then
                                    local aWeight = Scheduler.PRIORITY_WEIGHTS[aSlice.priority] or 2
                                    local shouldSwitch = false
                                    local reason = ""
                                    if best.forced then
                                        shouldSwitch, reason = true, "manual force"
                                    elseif aWeight < 4 and heldSec >= cfg.minHoldSec then
                                        if best.priWeight > aWeight then
                                            shouldSwitch, reason = true, "higher priority"
                                        elseif pool.mode == "round_robin" and best.priWeight >= aWeight then
                                            shouldSwitch, reason = true, "round-robin slice quantum"
                                        elseif pool.mode == "srtf" and best.priWeight == aWeight and best.effectiveEta < (effEta * cfg.preemptRatio) then
                                            shouldSwitch, reason = true, string.format("SRTF %.0fs < %.0fs", best.effectiveEta, effEta * cfg.preemptRatio)
                                        end
                                    end
                                    if shouldSwitch then
                                        state.kpis.preemptions = (state.kpis.preemptions or 0) + 1
                                        Scheduler.log(state, cfg, "normal", "DEC", string.format("%s: Switch C%d (%s) -> C%d (%s) [%s]",
                                            pool.name, ac, aSlice.label, best.color, best.slice.label, reason))
                                        enterSettleOrIdle(cfg, state, pool, pState, best.color, nowSec, compLib)
                                    end
                                end
                            end
                        end
                    else
                        local nxt = pickCandidate(pool, state, cfg, nowSec, pState.lastServedColor)
                        enterSettleOrIdle(cfg, state, pool, pState, nxt and nxt.color or nil, nowSec, compLib)
                    end

                elseif pState.phase == "SETTLING" then
                    writePoolColor(cfg, state, pool, pState, nil, nowSec, compLib)
                    if nowSec >= (pState.settleUntil or 0) then
                        local best = pickCandidate(pool, state, cfg, nowSec, pState.lastServedColor)
                        if best then
                            pState.phase = "ACTIVE"
                            pState.activeColor = best.color
                            pState.lastServedColor = best.color
                            pState.pendingColor = nil
                            pState.activeSince = nowSec
                            pState.lastProgressAt = nowSec
                            pState.zeroStreak = 0
                            pState.lastActiveWork = best.sState.workScore
                            pState.activeLabel = best.slice.label
                            pState.activeEtaSec = best.rawEta
                            pState.activeRate = best.rate
                            writePoolColor(cfg, state, pool, pState, best.color, nowSec, compLib)
                        else
                            pState.phase = "IDLE"
                            pState.pendingColor = nil
                        end
                    end

                else -- IDLE / PAUSED recovery
                    local best = pickCandidate(pool, state, cfg, nowSec, pState.lastServedColor)
                    if best then
                        local sinceOff = pState.lastOffAt and (nowSec - pState.lastOffAt) or math.huge
                        if sinceOff < (cfg.settleSec or 0) then
                            pState.phase = "SETTLING"
                            pState.pendingColor = best.color
                            pState.settleUntil = (pState.lastOffAt or nowSec) + cfg.settleSec
                            writePoolColor(cfg, state, pool, pState, nil, nowSec, compLib)
                        else
                            pState.phase = "ACTIVE"
                            pState.activeColor = best.color
                            pState.lastServedColor = best.color
                            pState.activeSince = nowSec
                            pState.lastProgressAt = nowSec
                            pState.zeroStreak = 0
                            pState.lastActiveWork = best.sState.workScore
                            pState.activeLabel = best.slice.label
                            pState.activeEtaSec = best.rawEta
                            pState.activeRate = best.rate
                            writePoolColor(cfg, state, pool, pState, best.color, nowSec, compLib)
                        end
                    else
                        pState.phase = "IDLE"
                        pState.activeColor = nil
                        pState.activeLabel = ""
                        pState.activeEtaSec = nil
                        pState.activeRate = nil
                        writePoolColor(cfg, state, pool, pState, nil, nowSec, compLib)
                    end
                end
            end
        end

        -- 4. Gather queue + KPIs for this pool
        if pState.phase == "ACTIVE" then
            activePools = activePools + 1
        end
        for c = 0, 15 do
            local slice = pool.slices[c]
            local sState = ensureSliceState(state, pool.id, c)
            if slice and slice.ifaceAddr and sState.workScore > 0 then
                queuedSlices = queuedSlices + 1
                local isStalled = (nowSec < (sState.stalledUntil or 0))
                if isStalled then stalledCount = stalledCount + 1 end
                local rawEta, effEta, rate = computeSliceMetrics(slice, sState, cfg, nowSec)
                queue[#queue + 1] = {
                    poolId = pool.id,
                    poolName = pool.name,
                    color = c,
                    label = slice.label,
                    priority = slice.priority,
                    enabled = slice.enabled,
                    itemUnits = sState.itemUnits,
                    fluidUnits = sState.fluidUnits,
                    workScore = sState.workScore,
                    topLabel = sState.topLabel,
                    etaSec = rawEta,
                    effectiveEtaSec = effEta,
                    rate = rate,
                    isActive = (pState.phase == "ACTIVE" and pState.activeColor == c),
                    isPending = (pState.phase == "SETTLING" and pState.pendingColor == c),
                    isStalled = isStalled,
                    stalledReason = sState.stalledReason,
                }
            end
        end
    end

    table.sort(queue, function(a, b)
        if a.isActive ~= b.isActive then return a.isActive end
        if a.isStalled ~= b.isStalled then return not a.isStalled end
        local wa = Scheduler.PRIORITY_WEIGHTS[a.priority] or 2
        local wb = Scheduler.PRIORITY_WEIGHTS[b.priority] or 2
        if wa ~= wb then return wa > wb end
        if math.abs((a.effectiveEtaSec or 0) - (b.effectiveEtaSec or 0)) > 1e-6 then
            return (a.effectiveEtaSec or 0) < (b.effectiveEtaSec or 0)
        end
        if a.poolId ~= b.poolId then return a.poolId < b.poolId end
        return a.color < b.color
    end)

    state.queue = queue
    state.rawSnapshot = rawSnap
    state.kpis.activePools = activePools
    state.kpis.queuedSlices = queuedSlices
    state.kpis.stalledCount = stalledCount
    return state
end

return Scheduler
