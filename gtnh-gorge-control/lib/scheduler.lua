-- /home/gorge/lib/scheduler.lua
-- Unified Multi-Exoticizer & Forge of the Gods State Machine:
--   - Self-healing component recovery & bounded RETRY_WAIT backoff (zero manual lockups)
--   - Auto Magmatter/Gluon batch detection via 10-slot/module DB partitioning
--   - Godforge On-Demand LSC hysteresis gating + single-shot timeout warnings

local Hardware = require("lib.hardware")
local Plasmas = require("lib.plasmas")

local Scheduler = {}

local MAX_LOGS = 160
Scheduler.MODES = { "magmatter", "gluon", "auto" }

function Scheduler.newExoticizer(id, mode)
    id = math.max(1, math.min(8, math.floor(tonumber(id) or 1)))
    mode = (mode == "magmatter" or mode == "gluon" or mode == "auto") and mode or ((id == 1) and "magmatter" or "gluon")
    return {
        id = id,
        name = "Exoticizer #" .. tostring(id),
        enabled = true,
        mode = mode,
        autoPrefer = (id == 1) and "magmatter" or "gluon",
        outputMeInterfaceAddress = nil,
        inputMeInterfaceAddress = nil,
        transposerAddress = nil,
        databaseAddress = nil,
        meIoPortSide = 5,   -- East
        meDriveSide = 4,    -- West
        redstoneIoAddress = nil,
        redstoneIoSide = 0, -- Down
        expectRedstone = true,
    }
end

function Scheduler.defaultConfig()
    return {
        armed = false,
        pollIntervalSec = 1.0,
        retryBackoffSec = 15.0,
        waitTimeoutSec = 240.0,
        extLinkMode = "auto",
        logLevel = "normal",
        godforge = {
            controllerAddr = nil,
            onDemandEnable = false,
            minLscPct = 20,
            resumeLscPct = 35,
        },
        exoticizers = {
            Scheduler.newExoticizer(1, "magmatter"),
            Scheduler.newExoticizer(2, "gluon"),
        },
    }
end

function Scheduler.normalizeConfig(cfg)
    local def = Scheduler.defaultConfig()
    if type(cfg) ~= "table" then return def end

    cfg.armed = (cfg.armed == true)
    cfg.pollIntervalSec = math.max(0.25, math.min(10.0, tonumber(cfg.pollIntervalSec) or def.pollIntervalSec))
    cfg.retryBackoffSec = math.max(2.0, math.min(300.0, tonumber(cfg.retryBackoffSec) or def.retryBackoffSec))
    cfg.waitTimeoutSec = math.max(10.0, math.min(3600.0, tonumber(cfg.waitTimeoutSec) or def.waitTimeoutSec))
    cfg.extLinkMode = (cfg.extLinkMode == "off") and "off" or "auto"
    if cfg.logLevel ~= "quiet" and cfg.logLevel ~= "normal" and cfg.logLevel ~= "raw" then
        cfg.logLevel = "normal"
    end

    if type(cfg.godforge) ~= "table" then cfg.godforge = {} end
    if cfg.godforge.controllerAddr == "" then cfg.godforge.controllerAddr = nil end
    cfg.godforge.onDemandEnable = (cfg.godforge.onDemandEnable == true)
    cfg.godforge.minLscPct = math.max(0, math.min(95, tonumber(cfg.godforge.minLscPct) or 20))
    cfg.godforge.resumeLscPct = math.max(cfg.godforge.minLscPct + 5, math.min(100, tonumber(cfg.godforge.resumeLscPct) or 35))

    if type(cfg.exoticizers) ~= "table" or #cfg.exoticizers == 0 then
        cfg.exoticizers = def.exoticizers
    end
    if #cfg.exoticizers > 8 then
        for k = #cfg.exoticizers, 9, -1 do cfg.exoticizers[k] = nil end
    end

    for i = 1, #cfg.exoticizers do
        local ex = cfg.exoticizers[i]
        if type(ex) ~= "table" then
            ex = Scheduler.newExoticizer(i)
            cfg.exoticizers[i] = ex
        end
        ex.id = i
        ex.name = (type(ex.name) == "string" and ex.name ~= "") and ex.name or ("Exoticizer #" .. tostring(i))
        if ex.enabled == nil then ex.enabled = true else ex.enabled = (ex.enabled == true) end
        if ex.mode ~= "magmatter" and ex.mode ~= "gluon" and ex.mode ~= "auto" then
            ex.mode = (i == 1) and "magmatter" or "gluon"
        end
        if ex.autoPrefer ~= "magmatter" and ex.autoPrefer ~= "gluon" then
            ex.autoPrefer = (i == 1) and "magmatter" or "gluon"
        end
        for _, f in ipairs({ "outputMeInterfaceAddress", "inputMeInterfaceAddress", "transposerAddress", "databaseAddress", "redstoneIoAddress" }) do
            if ex[f] == "" then ex[f] = nil end
        end
        ex.meIoPortSide = math.max(0, math.min(5, math.floor(tonumber(ex.meIoPortSide) or 5)))
        ex.meDriveSide = math.max(0, math.min(5, math.floor(tonumber(ex.meDriveSide) or 4)))
        ex.redstoneIoSide = math.max(0, math.min(5, math.floor(tonumber(ex.redstoneIoSide) or 0)))
        if ex.expectRedstone == nil then ex.expectRedstone = true else ex.expectRedstone = (ex.expectRedstone == true) end
    end

    return cfg
end

function Scheduler.newState()
    return {
        exStates = {},
        godforge = { bound = false, online = false, active = false, workAllowed = true },
        lscPct = nil,
        logs = {},
        kpis = {
            activeCount = 0,
            completedCycles = 0,
            errorCount = 0,
        },
        discovery = {
            interfaces = {},
            transposers = {},
            redstones = {},
            databases = {},
            machines = {},
            lscAddr = nil,
            hasModem = false,
            hasWireless = false,
            hasTunnel = false,
            hasGpu = false,
            hasScreen = false,
        },
        stepCount = 0,
        _proxies = {},
        _lastDigest = nil,
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
        tag = tag or "INF",
        msg = tostring(msg or ""),
    }
    if #logs > MAX_LOGS then
        table.remove(logs, 1)
    end
end

local function ensureExState(state, exId)
    state.exStates = state.exStates or {}
    local es = state.exStates[exId]
    if not es then
        es = {
            phase = "IDLE",
            activeMode = "gluon",
            fakeName = "",
            rsSignal = 0,
            rsOk = true,
            freeCpus = 0,
            totalCpus = 0,
            distinctOutputs = 0,
            lastOutputs = {},
            batchInputs = nil,
            previewInputs = nil,
            previewErr = nil,
            completedCycles = 0,
            craftFailCount = 0,
            retryAt = 0,
            waitSince = 0,
            warnedLongWait = false,
            lastError = nil,
            lastLoggedErr = nil,
        }
        state.exStates[exId] = es
    end
    return es
end

local function enterRetry(state, cfg, es, exName, errMsg, nowSec)
    es.phase = "RETRY_WAIT"
    es.retryAt = nowSec + (cfg.retryBackoffSec or 15.0)
    es.lastError = tostring(errMsg or "Error")
    if es.lastLoggedErr ~= es.lastError then
        es.lastLoggedErr = es.lastError
        Scheduler.log(state, cfg, "normal", "WRN", string.format("%s: %s (retry in %.0fs)", exName, es.lastError, cfg.retryBackoffSec or 15))
    end
end

local function detectEffectiveMode(ex, parsedOutputs, distinctCount)
    if ex.mode ~= "auto" then
        return ex.mode
    end
    if type(parsedOutputs) == "table" and distinctCount == 3
        and parsedOutputs["Spatially Enlarged Fluid"]
        and parsedOutputs["Tachyon Rich Temporal Fluid"] then
        return "magmatter"
    elseif distinctCount >= 7 then
        return "gluon"
    end
    return ex.autoPrefer or "gluon"
end

function Scheduler.syncHardware(cfg, state, compLib)
    Scheduler.normalizeConfig(cfg)
    local disc = Hardware.discover(compLib, state)
    if state then
        state.discovery = disc
        for i, ex in ipairs(cfg.exoticizers) do
            ensureExState(state, ex.id or i)
        end
    end
    if (not cfg.godforge.controllerAddr or cfg.godforge.controllerAddr == "") and disc.machines then
        for _, m in ipairs(disc.machines) do
            if m.role == "godforge" then
                cfg.godforge.controllerAddr = m.address
                break
            end
        end
    end
    return disc
end

function Scheduler.cancelAllFakeCrafts(cfg, state, compLib)
    local total = 0
    for i, ex in ipairs((cfg and cfg.exoticizers) or {}) do
        local _, dbAddr = Hardware.resolveDatabase(ex, compLib, state)
        local fName = Hardware.fakeRecipeName(ex.id or i, dbAddr or "000000")
        local _, can = Hardware.cancelFakeCraft(ex, fName, compLib, state, 1.5)
        total = total + (can or 0)
        Hardware.encodeExoticizerPattern(ex, ex.id or i, nil, compLib, state)
        if state and state.exStates and state.exStates[ex.id or i] then
            local es = state.exStates[ex.id or i]
            if es.phase ~= "PAUSED" then
                es.phase = "IDLE"
            end
            es.batchInputs = nil
            es.craftFailCount = 0
            es.warnedLongWait = false
        end
    end
    if state then
        Scheduler.log(state, cfg, "normal", "OUT", string.format("Canceled %d active fake craft(s) & cleared slot-1 patterns.", total))
    end
    return total
end

function Scheduler.step(cfg, state, nowSec, opts, compLib)
    opts = opts or {}
    nowSec = tonumber(nowSec) or 0
    Scheduler.normalizeConfig(cfg)
    state.stepCount = (state.stepCount or 0) + 1
    state.lastStepSec = nowSec

    -- 1. Godforge & LSC Telemetry + Hysteresis On-Demand Gating
    local disc = state.discovery or {}
    if opts.lscPctOverride ~= nil then
        state.lscPct = tonumber(opts.lscPctOverride)
    elseif disc.lscAddr then
        local pct = Hardware.readLscPct(disc.lscAddr, compLib, state)
        if pct ~= nil then state.lscPct = pct end
    end

    local gf = Hardware.readGodforge(cfg.godforge.controllerAddr, compLib, state)
    state.godforge = gf
    if (not opts.dryRun) and cfg.armed and cfg.godforge.onDemandEnable and gf.online and state.lscPct ~= nil then
        if state.lscPct < cfg.godforge.minLscPct and gf.workAllowed ~= false then
            if Hardware.setGodforgeWork(cfg.godforge.controllerAddr, false, compLib, state) then
                gf.workAllowed = false
                Scheduler.log(state, cfg, "normal", "WRN",
                    string.format("Godforge PAUSED: LSC %.1f%% < %.0f%% min", state.lscPct, cfg.godforge.minLscPct))
            end
        elseif state.lscPct >= cfg.godforge.resumeLscPct and gf.workAllowed == false then
            if Hardware.setGodforgeWork(cfg.godforge.controllerAddr, true, compLib, state) then
                gf.workAllowed = true
                Scheduler.log(state, cfg, "normal", "DEC",
                    string.format("Godforge RESUMED: LSC %.1f%% >= %.0f%% target", state.lscPct, cfg.godforge.resumeLscPct))
            end
        end
    end

    -- 2. Step each Exoticizer independently
    local activeCount, errorCount = 0, 0
    for i = 1, #cfg.exoticizers do
        local ex = cfg.exoticizers[i]
        local exId = ex.id or i
        local es = ensureExState(state, exId)

        local _, dbAddr = Hardware.resolveDatabase(ex, compLib, state)
        es.fakeName = Hardware.fakeRecipeName(exId, dbAddr or "000000")

        local rsOk, rsVal = Hardware.readRedstoneInput(ex, compLib, state)
        es.rsOk = rsOk
        es.rsSignal = rsVal

        local outRes = Hardware.readOutputSubnet(ex, compLib, state)
        es.lastOutputs = outRes.outputs or {}
        es.distinctOutputs = outRes.distinct or 0

        local freeCpus, totalCpus = Hardware.getFreeCpusCount(ex, compLib, state)
        es.freeCpus = freeCpus
        es.totalCpus = totalCpus

        local effMode = detectEffectiveMode(ex, es.lastOutputs, es.distinctOutputs)
        es.activeMode = effMode
        local prevInputs, prevErr = Plasmas.computeBatchInputs(effMode, es.lastOutputs)
        es.previewInputs = prevInputs
        es.previewErr = prevErr

        local isBound = (type(ex.outputMeInterfaceAddress) == "string" and ex.outputMeInterfaceAddress ~= ""
            and type(ex.inputMeInterfaceAddress) == "string" and ex.inputMeInterfaceAddress ~= ""
            and type(ex.transposerAddress) == "string" and ex.transposerAddress ~= "")

        if opts.dryRun then
            -- telemetry & preview only
        elseif (not cfg.armed) or (not ex.enabled) or (not isBound) then
            if es.phase ~= "PAUSED" then
                es.phase = isBound and "PAUSED" or "UNBOUND"
            end
            if not isBound then es.phase = "UNBOUND" else es.phase = "PAUSED" end
            es.lastError = nil
        else
            if es.phase == "PAUSED" or es.phase == "UNBOUND" then
                es.phase = "IDLE"
            end

            -- Auto-recover from RETRY_WAIT when backoff elapses
            if es.phase == "RETRY_WAIT" and nowSec >= (es.retryAt or 0) then
                es.phase = "IDLE"
                es.craftFailCount = 0
                es.lastError = nil
                es.lastLoggedErr = nil
            end

            -- Advance pipeline states without hanging
            if es.phase == "IDLE" then
                if not outRes.ok then
                    enterRetry(state, cfg, es, ex.name, outRes.err or "Output subnet read failed", nowSec)
                else
                    local needRs = (ex.expectRedstone ~= false)
                    local rsReady = (not needRs) or (es.rsOk and es.rsSignal > 0)
                    local reqCount = (effMode == "magmatter") and 3 or 7
                    if rsReady and es.distinctOutputs >= reqCount then
                        local batchInputs, compErr = Plasmas.computeBatchInputs(effMode, es.lastOutputs)
                        if batchInputs then
                            es.batchInputs = batchInputs
                            es.phase = "ENCODE"
                        else
                            enterRetry(state, cfg, es, ex.name, compErr, nowSec)
                        end
                    else
                        es.lastError = nil
                        es.lastLoggedErr = nil
                    end
                end
            end

            if es.phase == "ENCODE" then
                local okEnc, encInfo = Hardware.encodeExoticizerPattern(ex, exId, es.batchInputs, compLib, state)
                if okEnc then
                    es.fakeName = encInfo
                    es.phase = "CLEAR_AE"
                    Scheduler.log(state, cfg, "normal", "DEC", string.format("%s [%s]: Encoded %d plasmas",
                        ex.name, tostring(effMode):upper(), #(es.batchInputs or {})))
                else
                    enterRetry(state, cfg, es, ex.name, encInfo, nowSec)
                end
            end

            if es.phase == "CLEAR_AE" then
                local okClr, moved, clrErr = Hardware.clearOutputCells(ex, compLib, state, opts.ioWaitSec, opts.sleepFn)
                if okClr then
                    es.craftFailCount = 0
                    es.phase = "REQUEST"
                    Scheduler.log(state, cfg, "raw", "DEC", string.format("%s: Drained %d cell(s) via ME IO Port", ex.name, moved or 0))
                else
                    enterRetry(state, cfg, es, ex.name, clrErr or "Clear Output AE failed", nowSec)
                end
            end

            if es.phase == "REQUEST" then
                if Hardware.hasActiveFakeCraft(ex, es.fakeName, compLib, state) then
                    es.craftFailCount = 0
                    es.waitSince = nowSec
                    es.warnedLongWait = false
                    es.lastError = nil
                    es.lastLoggedErr = nil
                    es.phase = "WAIT_END"
                elseif es.freeCpus >= 1 then
                    local okReq, reqWhy = Hardware.requestFakeCraft(ex, es.fakeName, compLib, state, opts.craftWaitSec, opts.sleepFn)
                    if okReq or Hardware.hasActiveFakeCraft(ex, es.fakeName, compLib, state) then
                        es.craftFailCount = 0
                        es.waitSince = nowSec
                        es.warnedLongWait = false
                        es.lastError = nil
                        es.lastLoggedErr = nil
                        es.phase = "WAIT_END"
                        Scheduler.log(state, cfg, "normal", "OUT", string.format("%s [%s]: Dispatched %s",
                            ex.name, tostring(effMode):upper(), es.fakeName))
                    else
                        es.craftFailCount = (es.craftFailCount or 0) + 1
                        if es.craftFailCount >= 3 then
                            enterRetry(state, cfg, es, ex.name, reqWhy or "Fake craft failed", nowSec)
                        end
                    end
                end
            elseif es.phase == "WAIT_END" then
                local curRes = Hardware.readOutputSubnet(ex, compLib, state)
                if curRes.ok then
                    es.lastOutputs = curRes.outputs or {}
                    es.distinctOutputs = curRes.distinct or 0
                    if es.distinctOutputs > 0 then
                        Hardware.cancelFakeCraft(ex, es.fakeName, compLib, state, opts.cancelWaitSec, opts.sleepFn)
                        Hardware.encodeExoticizerPattern(ex, exId, nil, compLib, state)
                        es.completedCycles = (es.completedCycles or 0) + 1
                        state.kpis.completedCycles = (state.kpis.completedCycles or 0) + 1
                        es.batchInputs = nil
                        es.warnedLongWait = false
                        es.lastError = nil
                        es.lastLoggedErr = nil
                        es.phase = "IDLE"
                        Scheduler.log(state, cfg, "normal", "DEC", string.format("%s [%s]: Batch complete (cycle #%d)",
                            ex.name, tostring(effMode):upper(), es.completedCycles))
                    elseif (nowSec - (es.waitSince or nowSec)) >= (cfg.waitTimeoutSec or 240) and not es.warnedLongWait then
                        es.warnedLongWait = true
                        Scheduler.log(state, cfg, "normal", "WRN", string.format("%s: Waiting in WAIT_END > %.0fs",
                            ex.name, cfg.waitTimeoutSec or 240))
                    end
                end
            end
        end

        if es.phase ~= "IDLE" and es.phase ~= "PAUSED" and es.phase ~= "UNBOUND" and es.phase ~= "RETRY_WAIT" then
            activeCount = activeCount + 1
        elseif es.phase == "RETRY_WAIT" then
            errorCount = errorCount + 1
        end
    end

    state.kpis.activeCount = activeCount
    state.kpis.errorCount = errorCount
    return state
end

function Scheduler.renderDigest(cfg, state)
    if not state then return "" end
    local k = state.kpis or {}
    local gf = state.godforge or {}
    local parts = {
        (cfg and cfg.armed) and "1" or "0",
        tostring(k.activeCount or 0),
        tostring(k.completedCycles or 0),
        tostring(k.errorCount or 0),
        tostring(#(state.logs or {})),
        gf.active and "A" or "I",
        gf.workAllowed ~= false and "W" or "H",
        tostring(state.lscPct and math.floor(state.lscPct) or "-"),
    }
    for i, ex in ipairs((cfg and cfg.exoticizers) or {}) do
        local es = state.exStates and state.exStates[ex.id or i]
        parts[#parts + 1] = string.format("%d:%s:%s:%s:%d:%d",
            ex.id or i, ex.mode or "?", es and es.phase or "-", es and es.activeMode or "-",
            es and es.distinctOutputs or 0, es and es.rsSignal or 0)
    end
    return table.concat(parts, ";")
end

function Scheduler.nextWakeupDelay(cfg, state, nowSec)
    if not (cfg and cfg.armed) then
        return 5.0
    end
    return tonumber(cfg.pollIntervalSec) or 1.0
end

return Scheduler
