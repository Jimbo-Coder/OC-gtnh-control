-- /home/universal/lib/scheduler.lua
-- Multi-Channel Pool State Machine, Pluggable Policy Dispatch, Anti-Contamination Settle Guard,
-- Event-Driven Raw Delta Accounting, and Recipe Rate Learning for GTNH Universal Control.

local Hardware = require("lib.hardware")
local Policy = require("lib.policy")

local Scheduler = {}

local MAX_LOGS = 160
Scheduler.PRIORITY_WEIGHTS = Policy.PRIORITY_WEIGHTS
Scheduler.PRIORITY_ORDER = Policy.PRIORITY_ORDER
Scheduler.POOL_MODES = Policy.POLICIES

local DEFAULT_CHANNEL_DYES = { [1] = 0, [2] = 4, [3] = 14, [4] = 15 }
local DEFAULT_CHANNEL_NAMES = { [1] = "Ch1 High", [2] = "Ch2 Low", [3] = "Ch3 Low", [4] = "Ch4 Low" }

local function formatGtColorLabel(gtDye)
    local info = Policy.dyeInfo(gtDye)
    if info.gtDye < 0 then
        return "Unpainted"
    end
    return string.format("%s (#%d)", info.name, info.rank)
end

local function makeSlice(idx)
    local ci = Hardware.COLORS[idx % 16] or { name = "Color " .. tostring(idx % 16) }
    local prefix = (idx >= 16) and "B:" or ""
    return {
        color = idx,
        label = prefix .. ci.name,
        ifaceAddr = nil,
        priority = "normal",
        enabled = true,
        learnedRate = nil,
        baselineItems = {},
        baselineFluids = {},
    }
end

function Scheduler.newChannel(chIdx, rsAddr, side, gtDye)
    chIdx = math.max(1, math.min(4, math.floor(tonumber(chIdx) or 1)))
    local d = Policy.parseGtDye(gtDye, DEFAULT_CHANNEL_DYES[chIdx] or 15)
    local b1Side = (side ~= nil) and side or ((chIdx == 1) and 2 or ((chIdx == 2) and 3 or (chIdx + 1) % 6))
    local b2Side = (b1Side == 2 and 4) or ((b1Side == 3 and 5) or ((b1Side + 2) % 6))
    return {
        id = chIdx,
        name = DEFAULT_CHANNEL_NAMES[chIdx] or ("Ch" .. tostring(chIdx)),
        gtDye = d,
        gtColor = formatGtColorLabel(d),
        enabled = true,
        banks = {
            [1] = { rsAddr = rsAddr, side = b1Side },
            [2] = { rsAddr = nil,    side = b2Side },
        },
        overrides = {},
    }
end

function Scheduler.newPool(id, name, rsAddr, side)
    local defSide = (side ~= nil) and side or 2
    local slices = {}
    for idx = 0, 15 do
        slices[idx] = makeSlice(idx)
    end
    return {
        id = id or 1,
        name = name or ("Pool " .. tostring(id or 1)),
        rsAddr = rsAddr,
        side = defSide,
        _syncedRsAddr = rsAddr,
        _syncedSide = defSide,
        mode = "mlfq",
        numSlices = 16,
        enabled = true,
        channels = {
            [1] = Scheduler.newChannel(1, rsAddr, defSide),
        },
        slices = slices,
    }
end

function Scheduler.defaultConfig()
    return {
        armed = false,
        pollIntervalSec = 0.5,
        idlePollSec = 30.0,
        activeVerifySec = 5.0,
        idleVerifySec = 300.0,
        minHoldSec = 15.0,
        probeWindowSec = 1.5,
        probePreemptHoldSec = 1.5,
        fastThresholdSec = 3.0,
        settleSec = 1.0,
        emptyConfirmPolls = 2,
        preemptRatio = 0.35,
        agingPerMin = 0.15,
        starvePromoteSec = 180.0,
        stallTimeoutSec = 120.0,
        retryStalledSec = 60.0,
        defaultProbeRate = 8.0,
        maxRecipeCache = 4096,
        ignoreBuiltinNC = true,
        extLinkMode = "auto",
        autoWake = true,
        logLevel = "normal",
        pools = {
            Scheduler.newPool(1, "Pool 1", nil, 2),
        },
    }
end

local function isValidMode(m)
    for _, v in ipairs(Scheduler.POOL_MODES) do
        if v == m then return true end
    end
    return false
end

local function normalizeChannels(pool)
    if type(pool.channels) ~= "table" or #pool.channels == 0 then
        pool.channels = { Scheduler.newChannel(1, pool.rsAddr, pool.side) }
    end
    if #pool.channels > 4 then
        for k = #pool.channels, 5, -1 do pool.channels[k] = nil end
    end

    for ci = 1, #pool.channels do
        local ch = pool.channels[ci]
        if type(ch) ~= "table" then
            ch = Scheduler.newChannel(ci)
            pool.channels[ci] = ch
        end
        ch.id = ci
        ch.name = (type(ch.name) == "string" and ch.name ~= "") and ch.name or (DEFAULT_CHANNEL_NAMES[ci] or ("Ch" .. tostring(ci)))
        local defDye = DEFAULT_CHANNEL_DYES[ci] or 15
        ch.gtDye = Policy.parseGtDye((ch.gtDye ~= nil) and ch.gtDye or ch.gtColor, defDye)
        ch.gtColor = formatGtColorLabel(ch.gtDye)
        if ch.enabled == nil then ch.enabled = true else ch.enabled = (ch.enabled == true) end

        if type(ch.banks) ~= "table" then ch.banks = {} end
        for bi = 1, 2 do
            local bk = ch.banks[bi]
            if type(bk) ~= "table" then
                local def = Scheduler.newChannel(ci)
                ch.banks[bi] = def.banks[bi]
            else
                if bk.rsAddr == "" then bk.rsAddr = nil end
                local defSide = (ci == 1 and bi == 1) and 2 or ((bi == 1) and ((ci + 1) % 6) or ((ci + 3) % 6))
                bk.side = math.max(0, math.min(5, math.floor(tonumber(bk.side) or defSide)))
            end
        end
        if type(ch.overrides) ~= "table" then ch.overrides = {} end
    end

    -- Bidirectional V1 <-> V2 Ch1 Bank 1 sync
    local b1 = pool.channels[1].banks[1]
    if pool._syncedRsAddr ~= nil or pool._syncedSide ~= nil then
        if pool.rsAddr ~= pool._syncedRsAddr or pool.side ~= pool._syncedSide then
            b1.rsAddr = pool.rsAddr
            b1.side = pool.side
        else
            pool.rsAddr = b1.rsAddr
            pool.side = b1.side
        end
    else
        if b1.rsAddr == nil and pool.rsAddr ~= nil then
            b1.rsAddr = pool.rsAddr
            b1.side = pool.side
        else
            pool.rsAddr = b1.rsAddr
            pool.side = b1.side
        end
    end
    pool._syncedRsAddr = pool.rsAddr
    pool._syncedSide = pool.side
end

function Scheduler.normalizeConfig(cfg)
    local def = Scheduler.defaultConfig()
    if type(cfg) ~= "table" then return def end

    cfg.armed = (cfg.armed == true)
    cfg.pollIntervalSec = math.max(0.1, math.min(10.0, tonumber(cfg.pollIntervalSec) or def.pollIntervalSec))
    cfg.idlePollSec = math.max(2.0, math.min(300.0, tonumber(cfg.idlePollSec) or def.idlePollSec))
    cfg.activeVerifySec = math.max(1.0, math.min(60.0, tonumber(cfg.activeVerifySec) or def.activeVerifySec))
    cfg.idleVerifySec = math.max(0.0, math.min(3600.0, (cfg.idleVerifySec ~= nil) and tonumber(cfg.idleVerifySec) or def.idleVerifySec))
    cfg.minHoldSec = math.max(0.5, math.min(600.0, tonumber(cfg.minHoldSec) or def.minHoldSec))
    cfg.probeWindowSec = math.max(0.25, math.min(30.0, tonumber(cfg.probeWindowSec) or def.probeWindowSec))
    cfg.probePreemptHoldSec = math.max(0.25, math.min(60.0, tonumber(cfg.probePreemptHoldSec) or def.probePreemptHoldSec))
    cfg.fastThresholdSec = math.max(0.5, math.min(60.0, tonumber(cfg.fastThresholdSec) or def.fastThresholdSec))
    cfg.settleSec = math.max(0.0, math.min(30.0, tonumber(cfg.settleSec) or def.settleSec))
    cfg.emptyConfirmPolls = math.max(1, math.min(10, math.floor(tonumber(cfg.emptyConfirmPolls) or def.emptyConfirmPolls)))
    cfg.preemptRatio = math.max(0.05, math.min(0.95, tonumber(cfg.preemptRatio) or def.preemptRatio))
    cfg.agingPerMin = math.max(0.0, math.min(0.75, tonumber(cfg.agingPerMin) or def.agingPerMin))
    cfg.starvePromoteSec = math.max(0.0, math.min(3600.0, (cfg.starvePromoteSec ~= nil) and tonumber(cfg.starvePromoteSec) or def.starvePromoteSec))
    cfg.stallTimeoutSec = math.max(5.0, math.min(3600.0, tonumber(cfg.stallTimeoutSec) or def.stallTimeoutSec))
    cfg.retryStalledSec = math.max(5.0, math.min(3600.0, tonumber(cfg.retryStalledSec) or def.retryStalledSec))
    cfg.defaultProbeRate = math.max(0.1, math.min(1000.0, tonumber(cfg.defaultProbeRate) or def.defaultProbeRate))
    cfg.maxRecipeCache = math.max(256, math.min(8192, math.floor(tonumber(cfg.maxRecipeCache) or def.maxRecipeCache)))
    if cfg.ignoreBuiltinNC == nil then cfg.ignoreBuiltinNC = true else cfg.ignoreBuiltinNC = (cfg.ignoreBuiltinNC == true) end
    cfg.extLinkMode = (cfg.extLinkMode == "off") and "off" or "auto"
    cfg.autoWake = (cfg.autoWake ~= false)
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
        if not isValidMode(p.mode) then p.mode = "mlfq" end
        if p.enabled == nil then p.enabled = true else p.enabled = (p.enabled == true) end

        normalizeChannels(p)

        if type(p.slices) ~= "table" then p.slices = {} end
        local hasUpper = false
        for c = 16, 31 do
            if type(p.slices[c]) == "table" and p.slices[c].ifaceAddr and p.slices[c].ifaceAddr ~= "" then
                hasUpper = true
                break
            end
        end
        p.numSlices = (p.numSlices == 32 or hasUpper) and 32 or 16

        for c = 0, p.numSlices - 1 do
            local s = p.slices[c]
            if type(s) ~= "table" then
                s = makeSlice(c)
                p.slices[c] = s
            else
                s.color = c
                local cInfo = Hardware.COLORS[c % 16] or { name = "Color " .. (c % 16) }
                local defLabel = ((c >= 16) and "B:" or "") .. cInfo.name
                s.label = (type(s.label) == "string" and s.label ~= "") and s.label or defLabel
                if s.ifaceAddr == "" then s.ifaceAddr = nil end
                if Scheduler.PRIORITY_WEIGHTS[s.priority] == nil then s.priority = "normal" end
                if s.enabled == nil then s.enabled = true else s.enabled = (s.enabled == true) end
                if type(s.learnedRate) ~= "number" or s.learnedRate <= 0 then s.learnedRate = nil end
                if type(s.baselineItems) ~= "table" then s.baselineItems = {} end
                if type(s.baselineFluids) ~= "table" then s.baselineFluids = {} end
            end
        end
    end

    cfg.recipeRateOrder = nil
    if type(cfg.recipeRates) ~= "table" or next(cfg.recipeRates) == nil then
        cfg.recipeRates = nil
    end

    return cfg
end

function Scheduler.newState()
    return {
        poolStates = {},
        sliceStates = {},
        recipeRates = {},
        recipeRateCount = 0,
        recipeSlowCount = 0,
        recipeSeq = 0,
        _ratesDirty = false,
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
            scanCalls = 0,
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
        _proxies = {},
        _lastBundled = {},
        _addrToSlices = {},
        _allSubscribed = false,
        _lastPollUptime = nil,
    }
end

function Scheduler.log(state, cfg, lvl, tag, msg)
    if not state then return end
    local minLvl = (cfg and cfg.logLevel) or "normal"
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

local function sliceKey(poolId, ncIdx)
    return tostring(poolId) .. ":" .. tostring(ncIdx)
end

function Scheduler.sliceKey(poolId, ncIdx)
    return sliceKey(poolId, ncIdx)
end

local function ensureChannelState(pState, chIdx)
    pState.channels = pState.channels or {}
    local cs = pState.channels[chIdx]
    if not cs then
        cs = {
            phase = "IDLE",
            activeNc = nil,
            pendingNc = nil,
            lastNc = nil,
            activeSince = 0,
            lastProgressAt = 0,
            lastActiveWork = nil,
            lastWorkSampleAt = nil,
            lastOffAt = nil,
            settleUntil = 0,
            pulseUntil = 0,
            pulseNc = nil,
            zeroStreak = 0,
            lastServedNc = -1,
            batchSig = "",
            activeLabel = "",
            activeEtaSec = nil,
            activeRate = nil,
        }
        pState.channels[chIdx] = cs
    end
    return cs
end

local function ensurePoolState(state, poolId, numChannels)
    local p = state.poolStates[poolId]
    if not p then
        p = {
            phase = "IDLE",
            activeColor = nil,
            pendingColor = nil,
            activeSince = 0,
            lastProgressAt = 0,
            lastScanAt = nil,
            lastStepAt = nil,
            lastOffAt = nil,
            settleUntil = 0,
            pulseUntil = 0,
            pulseColor = nil,
            lastServedColor = -1,
            activeLabel = "",
            activeEtaSec = nil,
            activeRate = nil,
            channels = {},
        }
        state.poolStates[poolId] = p
    end
    for ci = 1, math.max(1, numChannels or 1) do
        ensureChannelState(p, ci)
    end
    return p
end

local function ensureSliceState(state, poolId, ncIdx)
    local k = sliceKey(poolId, ncIdx)
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
            ingredientSig = "",
            busySince = nil,
            activeRunSec = 0,
            tier = "BULK",
            stalledUntil = 0,
            stalledReason = nil,
            lastStallWork = nil,
            etaSec = nil,
            effectiveEtaSec = nil,
            lastScanAt = -1000,
            _seeded = false,
            _hasEventSub = false,
            _needsVerify = false,
            _activeCh = nil,
            _batchRate = nil,
            _batchSamples = 0,
            _rawItems = {},
            _rawItemsMeta = {},
            _rawFluids = {},
            _rawFluidLabels = {},
        }
        state.sliceStates[k] = s
    end
    return s
end

local function resetSliceBatchState(sState)
    sState.busySince = nil
    sState.activeRunSec = 0
    sState.tier = "BULK"
    sState.stalledUntil = 0
    sState.stalledReason = nil
    sState.lastStallWork = nil
    sState.etaSec = 0
    sState.effectiveEtaSec = 0
    sState._batchRate = nil
    sState._batchSamples = 0
    sState._activeTickAt = nil
    sState._starveCooldownUntil = nil
end

function Scheduler.loadPersistedRates(cfg, state)
    if not cfg or not state then return 0 end
    if type(cfg.recipeRates) ~= "table" or next(cfg.recipeRates) == nil then
        cfg.recipeRates = nil
        cfg.recipeRateOrder = nil
        return 0
    end
    state.recipeRates = state.recipeRates or {}
    local cap = math.max(256, math.floor(tonumber(cfg.maxRecipeCache) or Policy.DEFAULT_MAX_RECIPE_CACHE))
    local loaded = 0
    for k, rawV in pairs(cfg.recipeRates) do
        local v = tonumber(rawV)
        if type(k) == "string" and k ~= "" and v and v > 0 and (state.recipeRateCount or 0) < cap then
            local h = Policy.fnv1a64(k)
            if h and state.recipeRates[h] == nil then
                local slow = v < ((cfg.defaultProbeRate or 8.0) * 0.5)
                state.recipeSeq = (state.recipeSeq or 0) + 1
                state.recipeRates[h] = Policy.packRecipeEntry(v, state.recipeSeq, slow)
                loaded = loaded + 1
            end
        end
    end
    Policy.recountRecipeStats(state)
    if loaded > 0 then
        state._ratesDirty = true
    end
    cfg.recipeRates = nil
    cfg.recipeRateOrder = nil
    return loaded
end

function Scheduler.exportPersistedRates(cfg, _)
    if cfg then
        cfg.recipeRates = nil
        cfg.recipeRateOrder = nil
    end
    return 0
end

local function writeRatesStream(path, rates)
    if type(path) ~= "string" or path == "" then return false end
    local f = io.open(path, "w")
    if not f then return false end
    f:write("# univ-rates-v2\n")
    for k, v in pairs(rates or {}) do
        if type(k) == "number" and type(v) == "number" then
            f:write(string.format("%x:%x\n", k, v))
        end
    end
    f:close()
    return true
end

function Scheduler.saveRatesFile(path, state, backupPath)
    if not state then return 0 end
    local rates = state.recipeRates or {}
    local okMain = writeRatesStream(path, rates)
    if backupPath and backupPath ~= "" then
        writeRatesStream(backupPath, rates)
    end
    if okMain then
        state._ratesDirty = false
    end
    return state.recipeRateCount or 0
end

function Scheduler.loadRatesFile(path, state, maxCap, backupPath)
    if not state then return 0 end
    local raw = nil
    for _, p in ipairs({ path, backupPath }) do
        if type(p) == "string" and p ~= "" then
            local f = io.open(p, "r")
            if f then
                raw = f:read("*a")
                f:close()
                if type(raw) == "string" and #raw > 0 then break end
                raw = nil
            end
        end
    end
    state.recipeRates = {}
    if not raw then
        Policy.recountRecipeStats(state)
        state._ratesDirty = false
        return 0
    end
    local cap = math.max(256, math.floor(tonumber(maxCap) or Policy.DEFAULT_MAX_RECIPE_CACHE))
    local loaded = 0
    for line in raw:gmatch("[^\r\n]+") do
        if line:sub(1, 1) ~= "#" then
            local kh, vh = line:match("^([0-9a-fA-F]+):([0-9a-fA-F]+)$")
            if kh and vh then
                local k = tonumber("0x" .. kh)
                local v = tonumber("0x" .. vh)
                if k and k ~= 0 and v and math.type(k) == "integer" and math.type(v) == "integer" then
                    state.recipeRates[k] = v
                    loaded = loaded + 1
                    if loaded >= cap then break end
                end
            end
        end
    end
    Policy.recountRecipeStats(state)
    state._ratesDirty = false
    return loaded
end

local function applyScanToSliceState(sState, scan, nowSec)
    sState.ok = scan.ok
    sState.err = scan.err
    sState.itemUnits = scan.itemUnits or 0
    sState.fluidUnits = scan.fluidUnits or 0
    sState.workScore = scan.workScore or 0
    sState.activeItemTypes = scan.activeItemTypes or 0
    sState.activeFluidTypes = scan.activeFluidTypes or 0
    sState.topLabel = scan.topLabel or ""
    sState.ingredientSig = scan.ingredientSig or ""
    sState.lastScanAt = nowSec
    sState._needsVerify = false
    if scan.ok then
        sState._seeded = true
        sState._rawItems = scan.itemsMap or {}
        sState._rawItemsMeta = scan.itemsMeta or {}
        sState._rawFluids = scan.fluidsMap or {}
        sState._rawFluidLabels = scan.fluidLabels or {}
    end
end

function Scheduler.syncHardware(cfg, state, compLib)
    Scheduler.normalizeConfig(cfg)
    local disc = Hardware.discover(compLib, state)
    if state then
        state.discovery = disc
    end

    local firstBundled = nil
    for i = 1, #disc.redstones do
        if disc.redstones[i].bundled then
            firstBundled = disc.redstones[i].address
            break
        end
    end
    if firstBundled then
        for pi = 1, #cfg.pools do
            local pl = cfg.pools[pi]
            if not pl.channels[1].banks[1].rsAddr then
                pl.channels[1].banks[1].rsAddr = firstBundled
                pl.rsAddr = firstBundled
                pl._syncedRsAddr = firstBundled
                break
            end
        end
    end

    if state then
        if next(state.recipeRates or {}) == nil then
            Scheduler.loadPersistedRates(cfg, state)
        end
        for _, pool in ipairs(cfg.pools) do
            ensurePoolState(state, pool.id, #(pool.channels or {}))
            for c = 0, (pool.numSlices or 16) - 1 do
                ensureSliceState(state, pool.id, c)
            end
        end
        Hardware.syncSubscriptions(cfg, state, compLib)
    end
    return disc
end

function Scheduler.refreshSubscriptions(cfg, state, compLib)
    if not state then return false end
    return Hardware.syncSubscriptions(cfg, state, compLib)
end

-- Handle GTNH 2.9 push event (`network_item_changed` / `network_fluid_changed`) in O(k) pure Lua.
function Scheduler.handleNetworkEvent(cfg, state, evName, ifaceAddr, deltas, nowSec)
    if not state or type(ifaceAddr) ~= "string" or ifaceAddr == "" then return false end
    if evName ~= "network_item_changed" and evName ~= "network_fluid_changed" then return false end

    local entries = state._addrToSlices and state._addrToSlices[ifaceAddr]
    if not entries or #entries == 0 then
        -- Rebuild index once in case UI bound a slice recently
        Hardware.syncSubscriptions(cfg, state)
        entries = state._addrToSlices and state._addrToSlices[ifaceAddr]
        if not entries or #entries == 0 then return false end
    end

    local isFluid = (evName == "network_fluid_changed")
    local anyDirty = false
    local now = nowSec or state.lastStepSec or 0

    for _, ref in ipairs(entries) do
        local sState = ensureSliceState(state, ref.poolId, ref.ncIdx)
        if not sState._seeded then
            sState._needsVerify = true
            state._forcePollNow = true
            anyDirty = true
        else
            local nApplied = Hardware.applyDeltas(sState, isFluid, deltas)
            if nApplied > 0 then
                local agg = Hardware.computeStatsFromMaps(
                    sState._rawItems, sState._rawItemsMeta,
                    sState._rawFluids, sState._rawFluidLabels,
                    ref.slice, { ignoreBuiltinNC = cfg and cfg.ignoreBuiltinNC }
                )
                local prevScore = sState.workScore or 0
                sState.itemUnits = agg.itemUnits
                sState.fluidUnits = agg.fluidUnits
                sState.workScore = agg.workScore
                sState.activeItemTypes = agg.activeItemTypes
                sState.activeFluidTypes = agg.activeFluidTypes
                sState.topLabel = agg.topLabel
                sState.lastEventAt = now
                if agg.ingredientSig ~= "" then
                    sState.ingredientSig = agg.ingredientSig
                end

                if prevScore <= 0 and agg.workScore > 0 then
                    sState.busySince = sState.busySince or now
                    state._forcePollNow = true
                elseif agg.workScore <= 0 then
                    sState._needsVerify = true
                    state._forcePollNow = true
                end
                if (sState.stalledUntil or 0) > now and sState.lastStallWork ~= nil
                    and math.abs(agg.workScore - sState.lastStallWork) > 1e-6 then
                    sState.stalledUntil = 0
                    sState.stalledReason = nil
                    sState.lastStallWork = nil
                end
                anyDirty = true
            end
        end
    end
    return anyDirty
end

function Scheduler.triggerPulseTest(cfg, state, poolId, ncIdx, durationSec, nowSec, compLib, chIdx)
    local pool = nil
    for i = 1, #(cfg.pools or {}) do
        if cfg.pools[i].id == poolId then pool = cfg.pools[i] break end
    end
    chIdx = math.max(1, math.floor(tonumber(chIdx) or 1))
    local rsAddr, side, color = pool and Hardware.resolveSignal(pool, chIdx, ncIdx) or nil
    if not pool or not rsAddr then return false, "Configure Redstone I/O & Channel first" end

    cfg.armed = false
    Hardware.zeroAllManagedPools(cfg, compLib, state)
    local pState = ensurePoolState(state, pool.id, #(pool.channels or {}))
    local cs = ensureChannelState(pState, chIdx)
    cs.phase = "PULSE_TEST"
    cs.activeNc = ncIdx
    cs.pulseNc = ncIdx
    cs.pulseUntil = (nowSec or 0) + (tonumber(durationSec) or 2.0)

    pState.phase = "PULSE_TEST"
    pState.activeColor = ncIdx
    pState.pulseColor = ncIdx
    pState.pulseUntil = cs.pulseUntil

    Hardware.setPoolOutputs(rsAddr, side, color, compLib, state)
    Scheduler.log(state, cfg, "normal", "OUT", string.format("%s Ch%d: Pulse NC %02d (%s) for %.1fs",
        pool.name, chIdx, ncIdx, (Hardware.COLORS[color] and Hardware.COLORS[color].name or color), durationSec or 2.0))
    return true
end

function Scheduler.allOff(cfg, state, nowSec, compLib)
    cfg.armed = false
    Hardware.zeroAllManagedPools(cfg, compLib, state)
    if state then
        state.forceColorByPool = {}
        for i = 1, #(cfg.pools or {}) do
            local p = cfg.pools[i]
            local pState = ensurePoolState(state, p.id, #(p.channels or {}))
            pState.phase = "PAUSED"
            pState.activeColor = nil
            pState.pendingColor = nil
            pState.pulseColor = nil
            pState.pulseUntil = 0
            pState.lastOffAt = nowSec or pState.lastOffAt
            for ci = 1, #(p.channels or {}) do
                local cs = ensureChannelState(pState, ci)
                cs.phase = "PAUSED"
                if cs.activeNc ~= nil then
                    cs.lastNc = cs.activeNc
                    cs.lastOffAt = nowSec or cs.lastOffAt
                end
                cs.activeNc = nil
                cs.pendingNc = nil
                cs.pulseNc = nil
                cs.pulseUntil = 0
                cs.zeroStreak = 0
            end
        end
        for _, ss in pairs(state.sliceStates or {}) do
            ss._activeCh = nil
            ss._activeTickAt = nil
        end
        Scheduler.log(state, cfg, "normal", "OUT", "ALL OUTPUTS FORCED OFF (PAUSED)")
    end
end

function Scheduler.clearStall(cfg, state, poolId, ncIdx)
    if not state then return end
    local sState = ensureSliceState(state, poolId, ncIdx)
    sState.stalledUntil = 0
    sState.stalledReason = nil
    sState.lastStallWork = nil
    Scheduler.log(state, cfg, "normal", "DEC", string.format("Cleared stall on Pool %s NC %d", tostring(poolId), tonumber(ncIdx) or -1))
end

local function activateChannel(cs, pState, pool, ncIdx, sState, cfg, nowSec, state, reason)
    local slice = pool.slices[ncIdx]
    cs.phase = "ACTIVE"
    cs.activeNc = ncIdx
    cs.pendingNc = nil
    cs.lastServedNc = ncIdx
    cs.activeSince = nowSec
    cs.lastProgressAt = nowSec
    cs.lastWorkSampleAt = nowSec
    cs.lastActiveWork = sState.workScore
    cs.batchWork = math.max(cs.batchWork or 0, sState.workScore or 0)
    cs.zeroStreak = 0
    cs.batchSig = sState.ingredientSig or ""
    cs.activeLabel = slice and slice.label or ("NC " .. tostring(ncIdx))
    cs.activeEtaSec = sState.etaSec
    cs.activeRate = sState._batchRate or Policy.lookupRecipeRate(state, pool.id, ncIdx, cs.batchSig) or (slice and slice.learnedRate) or cfg.defaultProbeRate
    sState._activeCh = cs
    sState._activeTickAt = nowSec
    Scheduler.log(state, cfg, "normal", "OUT", string.format("%s Ch%d: ON NC %02d (%s)%s",
        pool.name, cs._idx or 1, ncIdx, cs.activeLabel, reason and (" [" .. reason .. "]") or ""))
end

local function syncPoolSummaryFields(pool, pState)
    local bestCh = nil
    local hasPulse, hasSettle, hasActive = false, false, false
    local ordered = Policy.orderedEnabledChannels(pool)
    local seen = {}
    for _, ci in ipairs(ordered) do seen[ci] = true end
    for ci = 1, #(pool.channels or {}) do
        if not seen[ci] then ordered[#ordered + 1] = ci end
    end

    for _, ci in ipairs(ordered) do
        local cs = pState.channels[ci]
        if cs then
            if cs.phase == "PULSE_TEST" then
                hasPulse = true
                if not bestCh then bestCh = cs end
            elseif cs.phase == "ACTIVE" then
                hasActive = true
                if not bestCh or bestCh.phase ~= "ACTIVE" then bestCh = cs end
            elseif cs.phase == "SETTLING" then
                hasSettle = true
                if not bestCh then bestCh = cs end
            end
        end
    end

    if hasPulse then pState.phase = "PULSE_TEST"
    elseif hasActive then pState.phase = "ACTIVE"
    elseif hasSettle then pState.phase = "SETTLING"
    elseif pState.phase ~= "PAUSED" and pState.phase ~= "NO_RS" then
        pState.phase = "IDLE"
    end

    if bestCh and bestCh.phase == "ACTIVE" then
        pState.activeColor = bestCh.activeNc
        pState.activeLabel = bestCh.activeLabel
        pState.activeEtaSec = bestCh.activeEtaSec
        pState.activeRate = bestCh.activeRate
        pState.activeSince = bestCh.activeSince
        pState.pendingColor = nil
        pState.settleUntil = 0
    elseif bestCh and bestCh.phase == "SETTLING" then
        pState.activeColor = nil
        pState.pendingColor = bestCh.pendingNc
        pState.settleUntil = bestCh.settleUntil
        pState.activeLabel = ""
        pState.activeEtaSec = nil
        pState.activeRate = nil
    else
        pState.activeColor = nil
        pState.pendingColor = nil
        pState.settleUntil = 0
        pState.activeLabel = ""
        pState.activeEtaSec = nil
        pState.activeRate = nil
    end

    local firstIdx = ordered[1] or 1
    local c1 = pState.channels[firstIdx]
    if c1 then
        pState.lastServedColor = c1.lastServedNc
        pState.lastOffAt = c1.lastOffAt
    end
end

-- Check GTNH 2.9 hatch color validity on multi-channel pools (warn on unpainted -1 or duplicate colors).
function Scheduler.validateChannelColors(pool)
    local enCh = Policy.orderedEnabledChannels(pool)
    if #enCh < 2 then return nil end
    local seenDye = {}
    for _, ci in ipairs(enCh) do
        local ch = pool.channels[ci]
        local d = tonumber(ch.gtDye)
        if d == nil or d < 0 then
            return string.format("%s Ch%d is Unpainted: in multi-channel mode unpainted hatches accept ALL colors!", pool.name, ci)
        end
        if seenDye[d] then
            local info = Policy.dyeInfo(d)
            return string.format("%s Ch%d & Ch%d share GT hatch color %s (#%d): use distinct spray colors!",
                pool.name, seenDye[d], ci, info.name, info.rank)
        end
        seenDye[d] = ci
    end
    return nil
end

function Scheduler.step(cfg, state, nowSec, opts, compLib)
    opts = opts or {}
    nowSec = tonumber(nowSec) or 0
    Scheduler.normalizeConfig(cfg)
    state.stepCount = (state.stepCount or 0) + 1
    state.lastStepSec = nowSec
    state._lastPollUptime = nowSec

    local forceFullScan = (opts.forceFullScan == true) or (state._forceFullScan == true) or (opts.dryRun == true)
    state._forceFullScan = false
    if not opts.dryRun and not opts.cachedOnly then
        state._forcePollNow = false
    end

    local queue = {}
    local rawSnap = {}
    local activePools = 0
    local queuedSlices = 0
    local stalledCount = 0

    for pi = 1, #cfg.pools do
        local pool = cfg.pools[pi]
        local numSlices = tonumber(pool.numSlices) or 16
        local numCh = #(pool.channels or {})
        local pState = ensurePoolState(state, pool.id, numCh)
        for ci = 1, numCh do pState.channels[ci]._idx = ci end
        pState.lastStepAt = nowSec

        -- 0. Update cumulative activeRunSec for any slice actively running since last step
        local scannedThisStep = {}
        for c = 0, numSlices - 1 do
            local sState = ensureSliceState(state, pool.id, c)
            local wasOnAny = false
            for ci = 1, numCh do
                local cs = pState.channels[ci]
                if cs.phase == "ACTIVE" and cs.activeNc == c then
                    wasOnAny = true
                    break
                end
            end
            if wasOnAny and cfg.armed and pool.enabled ~= false then
                if sState._activeTickAt ~= nil and nowSec > sState._activeTickAt then
                    sState.activeRunSec = (sState.activeRunSec or 0) + (nowSec - sState._activeTickAt)
                end
                sState._activeTickAt = nowSec
            else
                sState._activeTickAt = nil
            end
        end

        -- 1. Selectively scan bound subnets (0 indirect calls for already-seeded idle subscribed slices!)
        if not opts.cachedOnly then
            pState.lastScanAt = nowSec
            local idleVerifiesThisStep = 0
            local idleSecCfg = tonumber(cfg.idleVerifySec) or 300
            for c = 0, numSlices - 1 do
                local slice = pool.slices[c]
                local sState = ensureSliceState(state, pool.id, c)
                if slice and slice.ifaceAddr and slice.ifaceAddr ~= "" then
                    local isActiveSlice = false
                    for ci = 1, numCh do
                        if pState.channels[ci].phase == "ACTIVE" and pState.channels[ci].activeNc == c then
                            isActiveSlice = true
                            break
                        end
                    end
                    local ageIdle = math.max(0, nowSec - (sState.lastScanAt or -1000))
                    local ageActive = math.max(0, nowSec - math.max(sState.lastScanAt or -1000, sState.lastEventAt or -1000))
                    local idleVerifyLimit = idleSecCfg + (c * 2.0)
                    local isIdleVerifyDue = (not forceFullScan) and sState._seeded and (not isActiveSlice)
                        and (not sState._needsVerify) and (idleSecCfg > 0)
                        and (ageIdle >= idleVerifyLimit) and (idleVerifiesThisStep < 2)
                    local needScan = forceFullScan
                        or (not sState._seeded)
                        or (not sState._hasEventSub)
                        or (sState._needsVerify == true)
                        or (isActiveSlice and ageActive >= (cfg.activeVerifySec or 5.0))
                        or isIdleVerifyDue

                    if needScan then
                        if isIdleVerifyDue then
                            idleVerifiesThisStep = idleVerifiesThisStep + 1
                        end
                        state.kpis.scanCalls = (state.kpis.scanCalls or 0) + 1
                        local scan = Hardware.scanSubnet(slice.ifaceAddr, slice, {
                            ignoreBuiltinNC = cfg.ignoreBuiltinNC,
                            proxyCache = state._proxies,
                        }, compLib)
                        applyScanToSliceState(sState, scan, nowSec)
                        scannedThisStep[c] = true
                    end

                    if sState.ok then
                        if sState.workScore > 0 then
                            sState.busySince = sState.busySince or nowSec
                            if (sState.stalledUntil or 0) > nowSec and sState.lastStallWork ~= nil
                                and math.abs(sState.workScore - sState.lastStallWork) > 1e-6 then
                                sState.stalledUntil = 0
                                sState.stalledReason = nil
                                sState.lastStallWork = nil
                                Scheduler.log(state, cfg, "normal", "DEC", string.format("%s NC%d: Stock changed -> cleared stall", pool.name, c))
                            end
                            Policy.classifyCandidate(pool.id, c, slice, sState, state, cfg, nowSec, false)
                        else
                            -- Wait until active completion logic finishes recording final drain sample if slice was active
                            local wasActive = false
                            for ci = 1, numCh do
                                if pState.channels[ci].phase == "ACTIVE" and pState.channels[ci].activeNc == c then
                                    wasActive = true
                                    break
                                end
                            end
                            if not wasActive then
                                resetSliceBatchState(sState)
                            end
                        end
                    end

                    rawSnap[#rawSnap + 1] = string.format("P%d NC%02d (%s): %s tier=%s work=%.2f (%dI/%dL) sub=%s err=%s",
                        pool.id, c, slice.label, sState.ok and "OK" or "ERR", tostring(sState.tier),
                        sState.workScore, sState.itemUnits, sState.fluidUnits, tostring(sState._hasEventSub), tostring(sState.err or "-"))
                else
                    sState.workScore = 0
                    sState.itemUnits = 0
                    sState.fluidUnits = 0
                    sState.ok = true
                    sState.err = nil
                    sState._seeded = false
                    resetSliceBatchState(sState)
                end
            end
        end

        -- 2. Handle PULSE_TEST (runs briefly while paused, auto-expiring back to OFF)
        local inPulseTest = false
        for ci = 1, numCh do
            local cs = pState.channels[ci]
            if cs.phase == "PULSE_TEST" then
                inPulseTest = true
                if (not cfg.armed) and nowSec < (cs.pulseUntil or 0) then
                    -- Hold pulse color via wireTargets below
                else
                    cs.pulseNc = nil
                    cs.pulseUntil = 0
                    cs.activeNc = nil
                    cs.phase = cfg.armed and "IDLE" or "PAUSED"
                    inPulseTest = false
                end
            end
        end

        -- 3. Active Channel Progress, Completion, Stall Isolation & Multi-Channel Policy Dispatch
        if not opts.dryRun and not inPulseTest then
            local anyChConfigured = false
            for ci = 1, numCh do
                if Hardware.resolveSignal(pool, ci, 0) ~= nil then
                    anyChConfigured = true
                    break
                end
            end

            if (not cfg.armed) or (not pool.enabled) or (not anyChConfigured) then
                pState.phase = anyChConfigured and "PAUSED" or "NO_RS"
                for ci = 1, numCh do
                    local cs = pState.channels[ci]
                    if cs.phase == "ACTIVE" and cs.activeNc ~= nil then
                        cs.lastNc = cs.activeNc
                        cs.lastOffAt = nowSec
                    end
                    cs.phase = pState.phase
                    cs.activeNc = nil
                    cs.pendingNc = nil
                    cs.activeLabel = ""
                    cs.activeEtaSec = nil
                    cs.activeRate = nil
                end
            else
                pState.phase = "IDLE"
                -- 3a. Evaluate active channels for drain progress, batch completion, or stalls
                for ci = 1, numCh do
                    local cs = pState.channels[ci]
                    if cs.phase == "ACTIVE" and cs.activeNc ~= nil then
                        local ac = cs.activeNc
                        local aSlice = pool.slices[ac]
                        local aState = ensureSliceState(state, pool.id, ac)
                        local prevWork = cs.lastActiveWork

                        if not (aSlice and aSlice.enabled ~= false and aSlice.priority ~= "off" and aSlice.ifaceAddr and aState.ok) then
                            cs.lastNc = ac
                            cs.lastOffAt = nowSec
                            cs.phase = "IDLE"
                            cs.activeNc = nil
                        else
                            -- Learn drain rate on any downward change (including fast drain to 0!)
                            if prevWork ~= nil and aState.workScore < (prevWork - 1e-6) then
                                local dtRate = math.max(0.05, nowSec - (cs.lastWorkSampleAt or cs.activeSince or nowSec))
                                local instRate = math.max(0.01, (prevWork - aState.workScore) / dtRate)
                                aSlice.learnedRate = aSlice.learnedRate and (0.35 * instRate + 0.65 * aSlice.learnedRate) or instRate
                                aState._batchSamples = (aState._batchSamples or 0) + 1
                                aState._batchRate = aState._batchRate and (0.35 * instRate + 0.65 * aState._batchRate) or instRate
                                local batchWork = math.max(cs.batchWork or 0, prevWork or 0, aState.workScore or 0)
                                local effRate = aState._batchRate or instRate
                                local isSlow = (aState.tier == "BULK")
                                    or ((aState.activeRunSec or 0) >= (cfg.probeWindowSec or 1.5))
                                    or ((batchWork / math.max(0.01, effRate)) > (cfg.fastThresholdSec or 3.0))
                                Policy.recordRecipeRate(state, pool.id, ac, (cs.batchSig ~= "" and cs.batchSig) or aState.ingredientSig, instRate, isSlow, cfg.maxRecipeCache)
                                cs.lastActiveWork = aState.workScore
                                cs.lastWorkSampleAt = nowSec
                                cs.lastProgressAt = nowSec
                            elseif prevWork == nil or aState.workScore > (prevWork + 1e-6) then
                                cs.lastActiveWork = aState.workScore
                                cs.batchWork = math.max(cs.batchWork or 0, aState.workScore or 0)
                                cs.lastWorkSampleAt = nowSec
                                cs.lastProgressAt = nowSec
                                if aState.ingredientSig and aState.ingredientSig ~= "" then
                                    cs.batchSig = aState.ingredientSig
                                end
                            end

                            if aState.workScore <= 0 then
                                cs.zeroStreak = (cs.zeroStreak or 0) + 1
                                cs.lastActiveWork = 0
                                local confirmed = (aState._hasEventSub and scannedThisStep[ac]) or (cs.zeroStreak >= cfg.emptyConfirmPolls)
                                if confirmed then
                                    state.kpis.completedBatches = (state.kpis.completedBatches or 0) + 1
                                    Scheduler.log(state, cfg, "normal", "DEC", string.format("%s Ch%d NC%d (%s): Batch complete",
                                        pool.name, ci, ac, aSlice.label))
                                    if state.forceColorByPool and state.forceColorByPool[pool.id] == ac then
                                        state.forceColorByPool[pool.id] = nil
                                    end
                                    resetSliceBatchState(aState)
                                    aState._activeCh = nil
                                    cs.lastNc = ac
                                    cs.lastOffAt = nowSec
                                    cs.phase = "IDLE"
                                    cs.activeNc = nil
                                    cs.batchWork = 0
                                    cs.zeroStreak = 0
                                end
                            else
                                cs.zeroStreak = 0
                                if (nowSec - (cs.lastProgressAt or nowSec)) >= cfg.stallTimeoutSec then
                                    aState.stalledUntil = nowSec + cfg.retryStalledSec
                                    aState.stalledReason = string.format("No drain for %ds", math.floor(cfg.stallTimeoutSec))
                                    aState.lastStallWork = aState.workScore
                                    aState._activeCh = nil
                                    Scheduler.log(state, cfg, "normal", "WRN", string.format("%s Ch%d NC%d (%s): STALLED -> yielding",
                                        pool.name, ci, ac, aSlice.label))
                                    if state.forceColorByPool and state.forceColorByPool[pool.id] == ac then
                                        state.forceColorByPool[pool.id] = nil
                                    end
                                    cs.lastNc = ac
                                    cs.lastOffAt = nowSec
                                    cs.phase = "IDLE"
                                    cs.activeNc = nil
                                    cs.batchWork = 0
                                end
                            end
                        end
                    end
                end

                -- 3b. Gather all runnable candidates & let pluggable Policy assign channels 1..numCh
                local candidates = {}
                local forcedNc = state.forceColorByPool and state.forceColorByPool[pool.id]
                local emptyConfirmLock = {}
                for ci = 1, numCh do
                    local cs = pState.channels[ci]
                    if cs.phase == "ACTIVE" and cs.activeNc ~= nil and (cs.zeroStreak or 0) > 0 then
                        emptyConfirmLock[ci] = cs.activeNc
                    end
                end
                for c = 0, numSlices - 1 do
                    local slice = pool.slices[c]
                    local sState = ensureSliceState(state, pool.id, c)
                    if slice and slice.ifaceAddr and slice.ifaceAddr ~= "" and slice.enabled ~= false and slice.priority ~= "off" then
                        local isForced = (forcedNc == c)
                        if isForced and sState.workScore > 0 then
                            sState.stalledUntil = 0
                            sState.stalledReason = nil
                            candidates[#candidates + 1] = Policy.classifyCandidate(pool.id, c, slice, sState, state, cfg, nowSec, true)
                        elseif sState.ok and sState.workScore > 0 and nowSec >= (sState.stalledUntil or 0) then
                            candidates[#candidates + 1] = Policy.classifyCandidate(pool.id, c, slice, sState, state, cfg, nowSec, false)
                        end
                    end
                end

                local desiredByCh, reasonsByCh = Policy.decide(pool, pState, candidates, state, cfg, nowSec)
                for ci, lockedNc in pairs(emptyConfirmLock) do
                    desiredByCh[ci] = lockedNc
                    reasonsByCh[ci] = "empty confirm"
                end

                -- 3c. Pass 1: Turn OFF / move away any channels leaving their current NC
                for ci = 1, numCh do
                    local cs = pState.channels[ci]
                    local targetNc = desiredByCh[ci]
                    if cs.phase == "ACTIVE" and cs.activeNc ~= targetNc then
                        local prevNc = cs.activeNc
                        local prevLabel = cs.activeLabel or ("NC " .. tostring(prevNc))
                        if targetNc ~= nil then
                            state.kpis.preemptions = (state.kpis.preemptions or 0) + 1
                            Scheduler.log(state, cfg, "normal", "DEC", string.format("%s Ch%d: Switch NC%d (%s) -> NC%d (%s) [%s]",
                                pool.name, ci, prevNc, prevLabel, targetNc, pool.slices[targetNc].label, tostring(reasonsByCh[ci] or "")))
                        end
                        cs.lastNc = prevNc
                        cs.lastOffAt = nowSec
                        cs.activeNc = nil
                        cs.batchWork = 0
                        cs.zeroStreak = 0
                        cs.activeLabel = ""
                        cs.activeEtaSec = nil
                        cs.activeRate = nil
                        local prevState = ensureSliceState(state, pool.id, prevNc)
                        prevState._activeCh = nil
                        if targetNc == nil then
                            cs.phase = "IDLE"
                            cs.pendingNc = nil
                        elseif (cfg.settleSec or 0) > 0 then
                            cs.phase = "SETTLING"
                            cs.pendingNc = targetNc
                            cs.settleUntil = nowSec + cfg.settleSec
                        else
                            cs.phase = "IDLE"
                            cs.pendingNc = targetNc
                        end
                    elseif cs.phase == "SETTLING" then
                        if targetNc == nil then
                            cs.phase = "IDLE"
                            cs.pendingNc = nil
                        elseif cs.pendingNc ~= targetNc then
                            cs.pendingNc = targetNc
                            cs.settleUntil = nowSec + (cfg.settleSec or 0)
                        end
                    end
                end

                -- 3d. Pass 2: Activate targets that have satisfied settle delay & NC mutual exclusion
                for ci = 1, numCh do
                    local cs = pState.channels[ci]
                    local targetNc = desiredByCh[ci]
                    if targetNc ~= nil then
                        if cs.phase == "ACTIVE" and cs.activeNc == targetNc then
                            local aSlice = pool.slices[targetNc]
                            local aState = ensureSliceState(state, pool.id, targetNc)
                            cs.activeLabel = aSlice and aSlice.label or ""
                            cs.activeEtaSec = aState.etaSec
                            cs.activeRate = aState._batchRate or Policy.lookupRecipeRate(state, pool.id, targetNc, cs.batchSig) or (aSlice and aSlice.learnedRate) or cfg.defaultProbeRate
                        elseif cs.phase == "SETTLING" then
                            if nowSec >= (cs.settleUntil or 0) then
                                local tState = ensureSliceState(state, pool.id, targetNc)
                                activateChannel(cs, pState, pool, targetNc, tState, cfg, nowSec, state, reasonsByCh[ci])
                            end
                        else -- IDLE with targetNc ~= nil
                            local sameAsLast = (cs.lastNc == targetNc)
                            local sinceOff = cs.lastOffAt and (nowSec - cs.lastOffAt) or math.huge
                            if (not sameAsLast) and (cfg.settleSec or 0) > 0 and sinceOff < cfg.settleSec then
                                cs.phase = "SETTLING"
                                cs.pendingNc = targetNc
                                cs.settleUntil = (cs.lastOffAt or nowSec) + cfg.settleSec
                            else
                                local tState = ensureSliceState(state, pool.id, targetNc)
                                activateChannel(cs, pState, pool, targetNc, tState, cfg, nowSec, state, reasonsByCh[ci])
                            end
                        end
                    else
                        if cs.phase ~= "SETTLING" then
                            cs.phase = "IDLE"
                            cs.activeNc = nil
                            cs.pendingNc = nil
                        end
                    end
                end
            end
        end

        local colorWarn = Scheduler.validateChannelColors(pool)
        if colorWarn ~= pState._lastColorWarn then
            pState._lastColorWarn = colorWarn
            if colorWarn then
                Scheduler.log(state, cfg, "normal", "WRN", colorWarn)
            end
        end

        -- 4. Flush all dirty Bundled Wires for this pool (with duplicate-wire conflict guard;
        --    highest native GT hatch dye priority channel claims shared wire first!)
        if not opts.dryRun then
            local wireTargets = {}
            for _, ch in ipairs(pool.channels or {}) do
                for bi = 1, 2 do
                    local bk = ch.banks and ch.banks[bi]
                    if bk and bk.rsAddr and bk.rsAddr ~= "" and bk.side ~= nil then
                        wireTargets[bk.rsAddr] = wireTargets[bk.rsAddr] or {}
                        wireTargets[bk.rsAddr][bk.side] = false
                    end
                end
                if type(ch.overrides) == "table" then
                    for _, ov in pairs(ch.overrides) do
                        if ov and ov.rsAddr and ov.rsAddr ~= "" and ov.side ~= nil then
                            wireTargets[ov.rsAddr] = wireTargets[ov.rsAddr] or {}
                            wireTargets[ov.rsAddr][ov.side] = false
                        end
                    end
                end
            end

            local wireOrder = Policy.orderedEnabledChannels(pool)
            local seenWire = {}
            for _, ci in ipairs(wireOrder) do seenWire[ci] = true end
            for ci = 1, numCh do if not seenWire[ci] then wireOrder[#wireOrder + 1] = ci end end

            for _, ci in ipairs(wireOrder) do
                local cs = pState.channels[ci]
                local driveNc = (cs.phase == "ACTIVE" and cs.activeNc) or (cs.phase == "PULSE_TEST" and cs.pulseNc) or nil
                if driveNc ~= nil then
                    local rsAddr, side, color = Hardware.resolveSignal(pool, ci, driveNc)
                    if rsAddr and side ~= nil then
                        wireTargets[rsAddr] = wireTargets[rsAddr] or {}
                        if type(wireTargets[rsAddr][side]) == "number" then
                            Scheduler.log(state, cfg, "normal", "WRN", string.format(
                                "%s Ch%d shares wire (%s side %d) with higher-priority channel! Change Ch%d Side.",
                                pool.name, ci, Hardware.shortAddr(rsAddr), side, ci))
                        else
                            wireTargets[rsAddr][side] = color
                        end
                    end
                end
            end

            if next(wireTargets) ~= nil then
                local okW, errW = Hardware.flushWireTargets(wireTargets, compLib, state)
                if not okW then
                    Scheduler.log(state, cfg, "normal", "WRN", string.format("%s redstone write failed: %s", pool.name, tostring(errW)))
                end
            end
        end

        syncPoolSummaryFields(pool, pState)
        if pState.phase == "ACTIVE" then
            activePools = activePools + 1
        end

        -- 5. Build Priority Queue & KPIs for this pool
        for c = 0, numSlices - 1 do
            local slice = pool.slices[c]
            local sState = ensureSliceState(state, pool.id, c)
            if slice and slice.ifaceAddr and sState.workScore > 0 then
                queuedSlices = queuedSlices + 1
                local isStalled = (nowSec < (sState.stalledUntil or 0))
                if isStalled then stalledCount = stalledCount + 1 end
                local cand = Policy.classifyCandidate(pool.id, c, slice, sState, state, cfg, nowSec,
                    (state.forceColorByPool and state.forceColorByPool[pool.id] == c))

                local actCh, pendCh = nil, nil
                for ci = 1, numCh do
                    local cs = pState.channels[ci]
                    if cs.phase == "ACTIVE" and cs.activeNc == c then actCh = ci
                    elseif cs.phase == "SETTLING" and cs.pendingNc == c then pendCh = ci
                    end
                end

                queue[#queue + 1] = {
                    poolId = pool.id,
                    poolName = pool.name,
                    color = c,
                    ncIdx = c,
                    label = slice.label,
                    priority = slice.priority,
                    enabled = slice.enabled,
                    tier = cand.tier,
                    tierRank = cand.tierRank,
                    activeChannel = actCh,
                    pendingChannel = pendCh,
                    itemUnits = sState.itemUnits,
                    fluidUnits = sState.fluidUnits,
                    workScore = sState.workScore,
                    topLabel = sState.topLabel,
                    etaSec = cand.rawEta,
                    effectiveEtaSec = cand.effectiveEta,
                    rate = cand.rate,
                    isActive = (actCh ~= nil),
                    isPending = (pendCh ~= nil),
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
        if (a.tierRank or 0) ~= (b.tierRank or 0) then return (a.tierRank or 0) > (b.tierRank or 0) end
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

-- Compact deterministic UI digest so idle ticks skip redundant screen buffer rebuilds.
function Scheduler.renderDigest(cfg, state)
    if not state then return "" end
    local k = state.kpis or {}
    local parts = {
        (cfg and cfg.armed) and "1" or "0",
        tostring(k.activePools or 0),
        tostring(k.queuedSlices or 0),
        tostring(k.stalledCount or 0),
        tostring(k.completedBatches or 0),
        tostring(k.preemptions or 0),
        tostring(k.scanCalls or 0),
        tostring(#(state.queue or {})),
        tostring(#(state.logs or {})),
        state._allSubscribed and "S" or "P",
    }
    for _, pool in ipairs((cfg and cfg.pools) or {}) do
        local pst = state.poolStates and state.poolStates[pool.id]
        parts[#parts + 1] = tostring(pool.id) .. ":" .. tostring(pst and pst.phase or "-")
        if pst and pst.channels then
            for ci, cs in ipairs(pst.channels) do
                parts[#parts + 1] = tostring(ci) .. "=" .. tostring(cs.phase or "-")
                    .. ":" .. tostring(cs.activeNc or "-")
                    .. ":" .. tostring(cs.pendingNc or "-")
            end
        end
    end
    for _, q in ipairs(state.queue or {}) do
        parts[#parts + 1] = string.format("%d/%d:%s:%s%s%s:%d/%d",
            q.poolId or 0, q.color or 0, tostring(q.tier or "B"),
            q.isActive and "A" or "", q.isPending and "P" or "", q.isStalled and "S" or "",
            math.floor(tonumber(q.workScore) or 0), math.floor(tonumber(q.etaSec) or 0))
    end
    return table.concat(parts, ";")
end

-- Adaptive zero-overhead event.pull delay:
-- - Sleeps cfg.idlePollSec (30s) when armed/idle & subscribed (waking immediately on AE2 storage events!)
-- - Wakes tightly for pending SETTLING guards, PULSE_TEST expiry, or active PROBE window deadlines.
function Scheduler.nextWakeupDelay(cfg, state, nowSec)
    nowSec = tonumber(nowSec) or 0
    if not state then return tonumber(cfg and cfg.pollIntervalSec) or 0.5 end
    if state._forcePollNow then return 0.05 end

    local minTimer = nil
    local function clampTimer(sec)
        if sec ~= nil then
            local rem = math.max(0.05, sec)
            if minTimer == nil or rem < minTimer then minTimer = rem end
        end
    end

    local anySettlingOrPulse = false
    local anyActive = false
    for _, pool in ipairs((cfg and cfg.pools) or {}) do
        local pState = state.poolStates and state.poolStates[pool.id]
        if pState then
            for _, cs in ipairs(pState.channels or {}) do
                if cs.phase == "PULSE_TEST" and cs.pulseUntil then
                    anySettlingOrPulse = true
                    clampTimer(cs.pulseUntil - nowSec)
                elseif cs.phase == "SETTLING" and cs.settleUntil then
                    anySettlingOrPulse = true
                    clampTimer(cs.settleUntil - nowSec)
                elseif cs.phase == "ACTIVE" and cs.activeNc ~= nil then
                    anyActive = true
                    local ss = state.sliceStates and state.sliceStates[sliceKey(pool.id, cs.activeNc)]
                    if ss and ss.tier == "PROBE" then
                        local probeRem = (tonumber(cfg and cfg.probeWindowSec) or 1.5) - (tonumber(ss.activeRunSec) or 0)
                        if probeRem > 0.05 then
                            clampTimer(probeRem)
                        end
                    end
                end
            end
        end
    end

    if not (cfg and cfg.armed) then
        if anySettlingOrPulse and minTimer then return minTimer end
        return tonumber(cfg and cfg.idlePollSec) or 30.0
    end

    for _, refs in pairs(state._addrToSlices or {}) do
        for _, ref in ipairs(refs) do
            local ss = state.sliceStates and state.sliceStates[sliceKey(ref.poolId, ref.ncIdx)]
            if ss and (ss._needsVerify or not ss._seeded) then
                return 0.05
            end
        end
    end

    if (anySettlingOrPulse or minTimer) and minTimer then
        return math.min(tonumber(cfg.pollIntervalSec) or 0.5, minTimer)
    end

    if anyActive or (state.kpis and (state.kpis.queuedSlices or 0) > 0) then
        return tonumber(cfg.pollIntervalSec) or 0.5
    end

    if state._allSubscribed then
        return tonumber(cfg.idlePollSec) or 30.0
    end
    return tonumber(cfg.pollIntervalSec) or 0.5
end

return Scheduler
