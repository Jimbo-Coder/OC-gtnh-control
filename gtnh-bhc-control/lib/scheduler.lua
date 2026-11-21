-- /home/bhc/lib/scheduler.lua
-- Black Hole Compressor (BHC) Lifecycle State Machine & Cost Optimizer.
-- Tracks stability (100 -> 0 @ 1/s), sweet-spot (<20%) holding with SpaceTime (doubling / 30s),
-- safety floor collapse before 0% (preventing output voiding), and remote RPC control.

local okComp, defaultComponent = pcall(require, "component")
if not okComp then defaultComponent = nil end
local Common = require("gtnh_common")
local okComputer, computer = pcall(require, "computer")
if not okComputer then computer = nil end
local Hardware = require("lib.hardware")

local Scheduler = {}

Scheduler.PRESETS = {
    throughput = {
        label = "Max Throughput",
        seedMode = "supermassive",
        targetStability = 12,
        collapseFloor = 4,
        maxHoldSec = 210,
        maxStPerSec = 4096,
        idleCollapseSec = 45,
    },
    balanced = {
        label = "Balanced",
        seedMode = "pseudostable",
        targetStability = 15,
        collapseFloor = 5,
        maxHoldSec = 150,
        maxStPerSec = 128,
        idleCollapseSec = 30,
    },
    save_seeds = {
        label = "Save Seeds",
        seedMode = "pseudostable",
        targetStability = 18,
        collapseFloor = 5,
        maxHoldSec = 270,
        maxStPerSec = 1024,
        idleCollapseSec = 120,
    },
    save_spacetime = {
        label = "Zero SpaceTime",
        seedMode = "pseudostable",
        targetStability = 10,
        collapseFloor = 5,
        maxHoldSec = 0,
        maxStPerSec = 0,
        idleCollapseSec = 20,
    },
    superstable = {
        label = "Superstable",
        seedMode = "superstable",
        targetStability = 100,
        collapseFloor = 0,
        maxHoldSec = 0,
        maxStPerSec = 0,
        idleCollapseSec = 0,
    },
}

Scheduler.PRESET_ORDER = { "balanced", "throughput", "save_seeds", "save_spacetime", "superstable" }
Scheduler.SEED_MODES = { "pseudostable", "supermassive", "superstable" }

local function clockNow()
    if computer and type(computer.uptime) == "function" then
        local ok, v = pcall(computer.uptime)
        if ok and type(v) == "number" then return v end
    end
    return os.clock()
end

local function logEvent(state, stage, text)
    if not state then return end
    state.events = state.events or {}
    table.insert(state.events, 1, { t = math.floor(clockNow()), stage = stage or "INFO", text = tostring(text or "") })
    while #state.events > 32 do table.remove(state.events) end
end

function Scheduler.defaultConfig()
    return {
        armed = false,
        pollSec = 1,
        extLinkMode = "auto",
        autoWake = true,
        preset = "balanced",
        seedMode = "pseudostable", -- "pseudostable" | "supermassive" | "superstable"
        utilityMode = "pulse",     -- "pulse" | "static"
        keepOpen = false,
        assumeWorkWhenNoSensor = true,
        requireCollapserReserve = true,
        isBlackHoleRecipe = true,
        saveRecipeMode = true,     -- halt decay during active craft when headroom <= remainingSec
        maxSaveRecipeCycles = 27,  -- max 30s SpaceTime doubling cycles for Save Recipe Mode (27 = 810s)
        targetStability = 15,      -- start halting decay inside <20% zone
        collapseFloor = 5,         -- mandatory collapse before 0% void point
        maxHoldSec = 150,          -- max total SpaceTime hold seconds per cycle (0 = no ST)
        maxStPerSec = 128,         -- stop holding once next doubling exceeds this L/s
        idleCollapseSec = 30,      -- collapse if idle > N sec (unless keepOpen=true)
        minSpacetimeReserve = 2000,
        spacetimeValveMode = "redstone", -- "redstone" | "transposer"
        manualMaxEuOverride = 0,
        controllerAddr = "",
        utilityRedstoneAddr = "",
        utilitySide = "up",
        spacetimeRedstoneAddr = "",
        spacetimeRedstoneSide = "north",
        spacetimeRedstoneInvert = false,
        inputGateRedstoneAddr = "",
        inputGateSide = "south",
        inputGateInvert = false,
        catalystTransposerAddr = "",
        catalystSrcSide = "west",
        catalystDstSide = "east",
        stTransposerAddr = "",
        stSrcSide = "down",
        stDstSide = "up",
        workSensorTransposerAddr = "",
        workSensorSide = "up",
        aeAddr = "",
    }
end

function Scheduler.normalizeConfig(raw)
    local d = Scheduler.defaultConfig()
    if type(raw) ~= "table" then return d end
    d.armed = (raw.armed == true)
    d.pollSec = math.max(1, math.min(30, math.floor(tonumber(raw.pollSec) or d.pollSec)))
    d.extLinkMode = (raw.extLinkMode == "off") and "off" or "auto"
    d.autoWake = (raw.autoWake ~= false)
    d.preset = Scheduler.PRESETS[raw.preset] and raw.preset or "custom"
    if raw.seedMode == "pseudostable" or raw.seedMode == "supermassive" or raw.seedMode == "superstable" then
        d.seedMode = raw.seedMode
    end
    d.utilityMode = (raw.utilityMode == "static") and "static" or "pulse"
    d.keepOpen = (raw.keepOpen == true)
    d.assumeWorkWhenNoSensor = (raw.assumeWorkWhenNoSensor ~= false)
    d.requireCollapserReserve = (raw.requireCollapserReserve ~= false)
    d.isBlackHoleRecipe = (raw.isBlackHoleRecipe ~= false)
    d.saveRecipeMode = (raw.saveRecipeMode ~= false)
    d.maxSaveRecipeCycles = math.max(1, math.min(60, math.floor(tonumber(raw.maxSaveRecipeCycles) or d.maxSaveRecipeCycles)))
    d.targetStability = math.max(5, math.min(95, math.floor(tonumber(raw.targetStability) or d.targetStability)))
    d.collapseFloor = math.max(2, math.min(d.targetStability - 1, math.floor(tonumber(raw.collapseFloor) or d.collapseFloor)))
    d.maxHoldSec = math.max(0, math.min(900, math.floor(tonumber(raw.maxHoldSec) or d.maxHoldSec)))
    d.maxStPerSec = math.max(0, math.min(1048576, math.floor(tonumber(raw.maxStPerSec) or d.maxStPerSec)))
    d.idleCollapseSec = math.max(0, math.min(3600, math.floor(tonumber(raw.idleCollapseSec) or d.idleCollapseSec)))
    d.minSpacetimeReserve = math.max(0, math.floor(tonumber(raw.minSpacetimeReserve) or d.minSpacetimeReserve))
    d.spacetimeValveMode = (raw.spacetimeValveMode == "transposer") and "transposer" or "redstone"
    d.manualMaxEuOverride = math.max(0, math.floor(tonumber(raw.manualMaxEuOverride) or 0))
    for _, k in ipairs({
        "controllerAddr", "utilityRedstoneAddr", "utilitySide",
        "spacetimeRedstoneAddr", "spacetimeRedstoneSide",
        "inputGateRedstoneAddr", "inputGateSide",
        "catalystTransposerAddr", "catalystSrcSide", "catalystDstSide",
        "stTransposerAddr", "stSrcSide", "stDstSide",
        "workSensorTransposerAddr", "workSensorSide", "aeAddr",
    }) do
        if type(raw[k]) == "string" then d[k] = raw[k] end
    end
    d.spacetimeRedstoneInvert = (raw.spacetimeRedstoneInvert == true)
    d.inputGateInvert = (raw.inputGateInvert == true)
    return d
end

function Scheduler.applyPreset(cfg, key)
    local p = Scheduler.PRESETS[key]
    if not cfg or not p then return false end
    cfg.preset = key
    for k, v in pairs(p) do
        if k ~= "label" then cfg[k] = v end
    end
    return true
end

function Scheduler.newState()
    return {
        phase = "CLOSED", -- "CLOSED" | "OPENING" | "FREE_DECAY" | "HOLDING" | "COLLAPSING" | "SUPERSTABLE"
        estStability = 100,
        heldSec = 0,
        decayCounter = 0,
        costMod = 1,
        haltingDecay = false,
        savingRecipe = false,
        totalStCycle = 0,
        totalStLifetime = 0,
        cyclesCompleted = 0,
        pulseCount = 0,
        lastUtilitySig = 0,
        lastPulseAt = -1000,
        lastTickAt = -1000,
        openedAt = 0,
        lastActiveAt = 0,
        collapseStartedAt = 0,
        collapserInjected = false,
        effectiveParallels = 0,
        discovery = { controllers = {}, redstones = {}, transposers = {}, aeInterfaces = {} },
        machine = { online = false, voltageTier = 8, tierName = "UV", baseParallels = 64, remainingSec = 0 },
        stock = { pseudostable = 0, supermassive = 0, superstable = 0, collapser = 0, spacetimeTankL = 0, spacetimeMeL = 0 },
        events = {},
        lastError = nil,
    }
end

function Scheduler.calcEffectiveParallels(tier, seedMode, stability, isBlackHoleRecipe)
    local p = 8 * math.max(1, math.floor(tonumber(tier) or 1))
    local st = tonumber(stability) or 100
    if seedMode == "superstable" then
        if isBlackHoleRecipe == false then return -1 end -- uncapped
        return p * 4
    elseif seedMode == "supermassive" then
        p = p * 4
    end
    if st < 50 then
        p = p * 2
        if st < 20 then
            if isBlackHoleRecipe == false then return -1 end
            p = p * 2
        end
    end
    return p
end

function Scheduler.calcCycleProjection(cfg, tier)
    local seedMode = (cfg and cfg.seedMode) or "pseudostable"
    local basePar = 8 * math.max(1, math.floor(tonumber(tier) or 8))
    if seedMode == "superstable" then
        return {
            seedMode = seedMode,
            peakParallels = basePar * 4,
            sweetSpotSec = 0,
            totalCycleSec = 0,
            totalStL = 0,
            peakStPerSec = 0,
            sweetUptimePct = 100,
        }
    end
    local baseCost = (seedMode == "supermassive") and 64 or 1
    local tgt = math.floor(tonumber(cfg and cfg.targetStability) or 15)
    local flr = math.floor(tonumber(cfg and cfg.collapseFloor) or 5)
    local maxHold = math.floor(tonumber(cfg and cfg.maxHoldSec) or 150)
    local capRate = math.floor(tonumber(cfg and cfg.maxStPerSec) or 128)
    local freePreHold = math.max(0, 100 - tgt)
    local freePostHold = math.max(0, tgt - flr)
    local totalSt, held, curCost, cnt = 0, 0, baseCost, 0
    while held < maxHold and curCost <= capRate do
        totalSt = totalSt + curCost
        held = held + 1
        cnt = cnt + 1
        if cnt >= 30 then
            cnt = 0
            curCost = curCost * 2
        end
    end
    local pre20 = math.max(0, math.min(20, 100) - tgt)
    local sweetSec = held + pre20 + freePostHold
    local totalSec = freePreHold + held + freePostHold
    return {
        seedMode = seedMode,
        peakParallels = basePar * ((seedMode == "supermassive") and 16 or 4),
        sweetSpotSec = sweetSec,
        totalCycleSec = totalSec,
        heldSec = held,
        totalStL = totalSt,
        peakStPerSec = (held > 0) and curCost or 0,
        sweetUptimePct = totalSec > 0 and math.floor((sweetSec / totalSec) * 1000 + 0.5) / 10 or 0,
    }
end

function Scheduler.syncHardware(cfg, state, compLib)
    local disc = Hardware.discover(compLib, state)
    state.discovery = disc
    Hardware.autoBind(cfg, disc)
    return disc
end

local function needsRecipeSave(cfg, state, mach, availSt, spec)
    if cfg.saveRecipeMode == false or not spec or not spec.canDecay then return false end
    if not mach or not mach.active or (tonumber(mach.remainingSec) or 0) <= 0 then return false end
    local headroom = (tonumber(state.estStability) or 0) - (tonumber(cfg.collapseFloor) or 5)
    if headroom > (tonumber(mach.remainingSec) + 1) then return false end
    local maxSaveSec = math.max(1, math.floor(tonumber(cfg.maxSaveRecipeCycles) or 27)) * 30
    if (tonumber(state.heldSec) or 0) >= maxSaveSec then return false end
    if ((tonumber(availSt) or 0) - (tonumber(state.costMod) or 0)) < (tonumber(cfg.minSpacetimeReserve) or 0) then
        return false
    end
    return true
end

local function stepOneSecondInternal(cfg, state, availStL, opts)
    opts = opts or {}
    local spec = Hardware.CATALYSTS[cfg.seedMode] or Hardware.CATALYSTS.pseudostable
    if not spec.canDecay then
        state.estStability = 100
        state.haltingDecay = false
        return
    end
    local maxSaveSec = math.max(1, math.floor(tonumber(cfg.maxSaveRecipeCycles) or 27)) * 30
    local saveHold = (state.savingRecipe == true)
        and (state.heldSec < maxSaveSec)
        and ((availStL - state.costMod) >= cfg.minSpacetimeReserve)
    local budgetHold = (state.heldSec < cfg.maxHoldSec)
        and (state.costMod <= cfg.maxStPerSec)
        and ((availStL - state.costMod) >= cfg.minSpacetimeReserve)
    local canHold = (state.phase == "HOLDING") and (budgetHold or saveHold)

    if canHold then
        state.haltingDecay = true
        if (not opts.dryRun) and cfg.spacetimeValveMode == "transposer" then
            local moved = Hardware.transferSpacetime(cfg, state.costMod, opts.compLib, state)
            if moved < state.costMod then
                state.haltingDecay = false
                state.estStability = math.max(-900, state.estStability - 1)
                return
            end
        end
        state.heldSec = state.heldSec + 1
        state.totalStCycle = state.totalStCycle + state.costMod
        state.totalStLifetime = state.totalStLifetime + state.costMod
        state.decayCounter = state.decayCounter + 1
        if state.decayCounter >= 30 then
            state.decayCounter = 0
            if state.costMod <= 1000000000 then
                state.costMod = state.costMod * 2
            end
        end
    else
        state.haltingDecay = false
        state.estStability = math.max(-900, state.estStability - 1)
    end
end

function Scheduler.onUtilityPulse(cfg, state, nowSec, opts)
    nowSec = nowSec or clockNow()
    state.pulseCount = (state.pulseCount or 0) + 1
    state.lastPulseAt = nowSec
    local spec = Hardware.CATALYSTS[cfg.seedMode] or Hardware.CATALYSTS.pseudostable

    if state.phase == "CLOSED" or state.phase == "OPENING" then
        state.openedAt = nowSec
        state.lastActiveAt = nowSec
        state.estStability = 100
        state.heldSec = 0
        state.decayCounter = 0
        state.totalStCycle = 0
        state.collapserInjected = false
        state.costMod = math.max(0, spec.baseStPerSec)
        state.phase = spec.canDecay and "FREE_DECAY" or "SUPERSTABLE"
        logEvent(state, "OUT", string.format("Black Hole open (%s, %s)", spec.label, state.phase))
        return true
    end

    local availSt = math.max(state.stock.spacetimeTankL or 0, state.stock.spacetimeMeL or 0)
    stepOneSecondInternal(cfg, state, availSt, opts)
    return true
end

local function closeComplete(cfg, state, nowSec, reason)
    state.phase = "CLOSED"
    state.estStability = 100
    state.heldSec = 0
    state.decayCounter = 0
    state.costMod = (Hardware.CATALYSTS[cfg.seedMode] or Hardware.CATALYSTS.pseudostable).baseStPerSec
    state.haltingDecay = false
    state.savingRecipe = false
    state.collapserInjected = false
    state.cyclesCompleted = (state.cyclesCompleted or 0) + 1
    logEvent(state, "OUT", "Black Hole closed (" .. tostring(reason or "done") .. ")")
end

function Scheduler.step(cfg, state, nowSec, compLib, opts)
    nowSec = nowSec or clockNow()
    opts = opts or {}
    local dryRun = (opts.dryRun == true)

    local disc = Scheduler.syncHardware(cfg, state, compLib)
    local mach = Hardware.readMachine(cfg, compLib, state)
    local stk = Hardware.scanStock(cfg, compLib, state)
    state.machine = mach
    state.stock = stk

    local utilSig = Hardware.readUtilitySignal(cfg, compLib, state)
    state.utilSig = utilSig

    -- Detect utility hatch open/pulse edges
    if utilSig ~= nil then
        if cfg.utilityMode == "pulse" then
            if utilSig > 0 and (state.lastUtilitySig or 0) == 0 then
                Scheduler.onUtilityPulse(cfg, state, nowSec, { dryRun = dryRun, compLib = compLib })
            elseif utilSig == 0 and state.phase ~= "CLOSED" and state.phase ~= "OPENING"
                and (nowSec - (state.lastPulseAt or 0)) >= 3.5 then
                closeComplete(cfg, state, nowSec, "Utility pulse stopped")
            end
        else
            if utilSig > 0 then
                if state.phase == "CLOSED" or state.phase == "OPENING" then
                    Scheduler.onUtilityPulse(cfg, state, nowSec, { dryRun = dryRun, compLib = compLib })
                elseif state.lastTickAt > 0 then
                    local elapsed = math.floor(nowSec - state.lastTickAt)
                    local availSt = math.max(stk.spacetimeTankL or 0, stk.spacetimeMeL or 0)
                    for _ = 1, math.min(10, math.max(0, elapsed)) do
                        stepOneSecondInternal(cfg, state, availSt, { dryRun = dryRun, compLib = compLib })
                    end
                    if elapsed >= 1 then state.lastTickAt = nowSec end
                else
                    state.lastTickAt = nowSec
                end
            elseif state.phase ~= "CLOSED" and state.phase ~= "OPENING" then
                closeComplete(cfg, state, nowSec, "Utility signal OFF")
            end
        end
        state.lastUtilitySig = utilSig
    end

    if mach.active then state.lastActiveAt = nowSec end

    local spec = Hardware.CATALYSTS[cfg.seedMode] or Hardware.CATALYSTS.pseudostable
    local hasWork = mach.active or (stk.workWaiting == true)
        or (cfg.assumeWorkWhenNoSensor and (not cfg.workSensorTransposerAddr or cfg.workSensorTransposerAddr == ""))
    local availSt = math.max(stk.spacetimeTankL or 0, stk.spacetimeMeL or 0)

    -- Handle manual force commands
    if state._manualCollapse then
        state._manualCollapse = nil
        if state.phase ~= "CLOSED" then
            state.phase = "COLLAPSING"
            state.collapseStartedAt = nowSec
        end
    end

    -- Phase transitions & safety enforcement
    if state.phase == "CLOSED" then
        if not dryRun then
            Hardware.setSpacetimeValve(cfg, false, compLib, state)
            Hardware.setInputGate(cfg, cfg.armed == true, compLib, state)
        end
        if (cfg.armed and (hasWork or cfg.keepOpen)) or state._manualOpen then
            state._manualOpen = nil
            local seedCount = stk[cfg.seedMode] or 0
            local needColl = spec.canDecay and (cfg.requireCollapserReserve ~= false)
            if seedCount < 1 then
                state.lastError = "Missing " .. spec.label
            elseif needColl and (stk.collapser or 0) < 1 then
                state.lastError = "Missing Black Hole Collapser reserve"
            elseif not dryRun then
                local okInj, injErr = Hardware.injectCatalyst(cfg, cfg.seedMode, compLib, state)
                if okInj then
                    state.lastError = nil
                    state.phase = "OPENING"
                    state.openedAt = nowSec
                    state.lastPulseAt = nowSec
                    state.lastTickAt = nowSec
                    logEvent(state, "OUT", "Injected " .. spec.label .. " -> OPENING")
                else
                    state.lastError = injErr
                end
            end
        end
    elseif state.phase == "OPENING" then
        if (nowSec - (state.openedAt or nowSec)) > 15 then
            state.lastError = "Opening timeout (no Utility Hatch pulse/start)"
        end
    elseif state.phase == "FREE_DECAY" then
        state.savingRecipe = false
        if needsRecipeSave(cfg, state, mach, availSt, spec) then
            state.savingRecipe = true
            state.phase = "HOLDING"
            if not dryRun then
                Hardware.setSpacetimeValve(cfg, true, compLib, state)
                Hardware.setInputGate(cfg, false, compLib, state)
            end
            logEvent(state, "WRN", string.format("Save Recipe Mode -> HOLDING at %.0f%% (%.1fs rem)", state.estStability, mach.remainingSec or 0))
        elseif state.estStability <= cfg.collapseFloor then
            state.phase = "COLLAPSING"
            state.collapseStartedAt = nowSec
            logEvent(state, "WRN", "Reached collapse floor in FREE_DECAY -> COLLAPSING")
        else
            if not dryRun then Hardware.setInputGate(cfg, true, compLib, state) end
            if state.estStability <= cfg.targetStability then
                local canAffordHold = (cfg.maxHoldSec > 0)
                    and (state.costMod <= cfg.maxStPerSec)
                    and ((availSt - state.costMod) >= cfg.minSpacetimeReserve)
                if canAffordHold then
                    state.phase = "HOLDING"
                    if not dryRun then Hardware.setSpacetimeValve(cfg, true, compLib, state) end
                    logEvent(state, "OUT", string.format("Entered HOLDING at %d%% (%d L/s)", math.floor(state.estStability), state.costMod))
                end
            end
        end
    elseif state.phase == "HOLDING" then
        local holdExpired = (state.heldSec >= cfg.maxHoldSec)
        local rateExceeded = (state.costMod > cfg.maxStPerSec)
        local stLow = ((availSt - state.costMod) < cfg.minSpacetimeReserve)
        local idleExpired = (not cfg.keepOpen) and (cfg.idleCollapseSec > 0)
            and (not mach.active) and (not stk.workWaiting)
            and ((nowSec - (state.lastActiveAt or state.openedAt)) >= cfg.idleCollapseSec)
        local wantSave = needsRecipeSave(cfg, state, mach, availSt, spec)
        local wasSaving = (state.savingRecipe == true)

        if wantSave and (state.estStability <= cfg.collapseFloor or holdExpired or rateExceeded or wasSaving) then
            state.savingRecipe = true
            if not dryRun then
                Hardware.setSpacetimeValve(cfg, true, compLib, state)
                Hardware.setInputGate(cfg, false, compLib, state)
            end
        elseif state.estStability <= cfg.collapseFloor or stLow or rateExceeded or holdExpired or idleExpired then
            state.savingRecipe = false
            if not dryRun then Hardware.setSpacetimeValve(cfg, false, compLib, state) end
            if state.estStability <= cfg.collapseFloor or stLow or (wasSaving and state.estStability <= (cfg.collapseFloor + 2)) then
                state.phase = "COLLAPSING"
                state.collapseStartedAt = nowSec
                logEvent(state, stLow and "WRN" or "OUT", stLow and "SpaceTime reserve low -> COLLAPSING" or (wasSaving and "Saved recipe finished -> COLLAPSING" or "Hold complete -> COLLAPSING"))
            else
                -- Let it free-decay down from targetStability to collapseFloor at max 4x speed & 0 ST cost!
                state.phase = "FREE_DECAY"
                logEvent(state, "OUT", "Hold budget reached -> free-decay coast to floor")
            end
        else
            state.savingRecipe = false
            if not dryRun then
                Hardware.setSpacetimeValve(cfg, true, compLib, state)
                Hardware.setInputGate(cfg, true, compLib, state)
            end
        end
    end

    if state.phase == "COLLAPSING" then
        if not dryRun then
            Hardware.setSpacetimeValve(cfg, false, compLib, state)
            Hardware.setInputGate(cfg, false, compLib, state)
        end
        local emergency = (state.estStability <= math.max(2, cfg.collapseFloor - 1))
        local canWaitFinish = mach.active and (mach.remainingSec or 0) > 0 and (mach.remainingSec < (state.estStability - 2))
        if (not state.collapserInjected) and (emergency or (not canWaitFinish) or (not mach.active)) then
            if not dryRun then
                local okC, errC = Hardware.injectCatalyst(cfg, "collapser", compLib, state)
                if okC then
                    state.collapserInjected = true
                    state.lastError = nil
                    logEvent(state, "OUT", "Injected Black Hole Collapser at " .. tostring(math.floor(state.estStability)) .. "%")
                    if utilSig == nil then
                        closeComplete(cfg, state, nowSec, "Collapsed cleanly")
                    end
                else
                    state.lastError = errC
                end
            end
        end
    elseif state.phase == "SUPERSTABLE" then
        if not dryRun then
            Hardware.setSpacetimeValve(cfg, false, compLib, state)
            Hardware.setInputGate(cfg, cfg.armed == true, compLib, state)
        end
        state.estStability = 100
        if (not cfg.armed) and state._manualCollapse then
            state.phase = "COLLAPSING"
        end
    end

    state.effectiveParallels = Scheduler.calcEffectiveParallels(mach.voltageTier, cfg.seedMode, state.estStability, cfg.isBlackHoleRecipe)
    return true
end

function Scheduler.renderDigest(cfg, state)
    return string.format("%s:%s:%s:%.0f:%d:%d:%s:%d:%d",
        tostring(cfg.armed), tostring(state.phase), tostring(cfg.seedMode),
        tonumber(state.estStability) or 100, tonumber(state.heldSec) or 0,
        tonumber(state.costMod) or 0, tostring(state.haltingDecay),
        tonumber(state.effectiveParallels) or 0, tonumber(state.cyclesCompleted) or 0)
end

function Scheduler.buildSnapshot(cfg, state)
    local proj = Scheduler.calcCycleProjection(cfg, state.machine and state.machine.voltageTier or 8)
    return {
        ok = true,
        role = "bhc",
        armed = (cfg.armed == true),
        preset = cfg.preset,
        seedMode = cfg.seedMode,
        utilityMode = cfg.utilityMode,
        keepOpen = (cfg.keepOpen == true),
        autoWake = (cfg.autoWake ~= false),
        phase = state.phase,
        stability = math.floor((tonumber(state.estStability) or 100) * 10 + 0.5) / 10,
        heldSec = math.floor(tonumber(state.heldSec) or 0),
        costMod = math.floor(tonumber(state.costMod) or 0),
        haltingDecay = (state.haltingDecay == true),
        savingRecipe = (state.savingRecipe == true),
        totalStCycle = math.floor(tonumber(state.totalStCycle) or 0),
        cyclesCompleted = math.floor(tonumber(state.cyclesCompleted) or 0),
        effectiveParallels = tonumber(state.effectiveParallels) or 0,
        machine = state.machine,
        stock = state.stock,
        projection = proj,
        policy = {
            targetStability = cfg.targetStability,
            collapseFloor = cfg.collapseFloor,
            maxHoldSec = cfg.maxHoldSec,
            maxStPerSec = cfg.maxStPerSec,
            idleCollapseSec = cfg.idleCollapseSec,
            minSpacetimeReserve = cfg.minSpacetimeReserve,
            requireCollapserReserve = cfg.requireCollapserReserve,
            isBlackHoleRecipe = cfg.isBlackHoleRecipe,
            saveRecipeMode = (cfg.saveRecipeMode ~= false),
            maxSaveRecipeCycles = cfg.maxSaveRecipeCycles,
        },
        lastError = state.lastError,
        events = state.events or {},
    }
end

function Scheduler.executeRpcTable(cfg, state, cmd, compLib, onMutate)
    if type(cmd) ~= "table" then return { ok = false, error = "Invalid command" } end
    local op, id = cmd.op, cmd.id
    local mutated = false
    if op == "ping" then
        return { id = id, ok = true, role = "bhc", armed = (cfg.armed == true) }
    elseif op == "get_state" or op == "bhc_state" then
        local snap = Scheduler.buildSnapshot(cfg, state)
        snap.id = id
        return snap
    elseif op == "patch_settings" or op == "bhc_patch" then
        local p = type(cmd.patch) == "table" and cmd.patch or cmd
        if type(p.preset) == "string" and Scheduler.PRESETS[p.preset] then
            Scheduler.applyPreset(cfg, p.preset)
            mutated = true
        end
        if type(p.armed) == "boolean" then cfg.armed = p.armed; mutated = true end
        if p.seedMode == "pseudostable" or p.seedMode == "supermassive" or p.seedMode == "superstable" then
            cfg.seedMode = p.seedMode; mutated = true
        end
        if p.utilityMode == "pulse" or p.utilityMode == "static" then cfg.utilityMode = p.utilityMode; mutated = true end
        if type(p.keepOpen) == "boolean" then cfg.keepOpen = p.keepOpen; mutated = true end
        if type(p.autoWake) == "boolean" then cfg.autoWake = p.autoWake; Hardware.openMeshPort(cfg, compLib, state); mutated = true end
        if type(p.requireCollapserReserve) == "boolean" then cfg.requireCollapserReserve = p.requireCollapserReserve; mutated = true end
        if type(p.isBlackHoleRecipe) == "boolean" then cfg.isBlackHoleRecipe = p.isBlackHoleRecipe; mutated = true end
        if type(p.saveRecipeMode) == "boolean" then cfg.saveRecipeMode = p.saveRecipeMode; mutated = true end
        for _, k in ipairs({ "targetStability", "collapseFloor", "maxHoldSec", "maxStPerSec", "idleCollapseSec", "minSpacetimeReserve", "maxSaveRecipeCycles" }) do
            if tonumber(p[k]) ~= nil then cfg[k] = tonumber(p[k]); mutated = true end
        end
        if mutated then
            local norm = Scheduler.normalizeConfig(cfg)
            for k, v in pairs(norm) do cfg[k] = v end
            if onMutate then pcall(onMutate, cfg) end
            Scheduler.step(cfg, state, clockNow(), compLib)
        end
        local snap = Scheduler.buildSnapshot(cfg, state)
        snap.id = id
        return snap
    elseif op == "action" or op == "bhc_action" then
        local act = cmd.action
        if act == "arm" or act == "resume" then cfg.armed = true; mutated = true
        elseif act == "pause" then cfg.armed = false; mutated = true
        elseif act == "poll_now" or act == "poll" then Scheduler.step(cfg, state, clockNow(), compLib)
        elseif act == "open_bh" then state._manualOpen = true; Scheduler.step(cfg, state, clockNow(), compLib)
        elseif act == "collapse_bh" then state._manualCollapse = true; Scheduler.step(cfg, state, clockNow(), compLib)
        elseif act == "apply_preset" and type(cmd.preset) == "string" and Scheduler.PRESETS[cmd.preset] then
            Scheduler.applyPreset(cfg, cmd.preset); mutated = true
        elseif act == "sync_stability" and tonumber(cmd.stability) then
            state.estStability = math.max(0, math.min(100, tonumber(cmd.stability)))
            if state.phase == "CLOSED" and state.estStability < 100 then state.phase = "FREE_DECAY" end
        elseif act == "set_auto_wake" then
            cfg.autoWake = (cmd.enabled ~= false)
            Hardware.openMeshPort(cfg, compLib, state)
            mutated = true
        elseif act == "update_local" then
            local cl = compLib or defaultComponent or _G.component
            local tx = Common.detectOtaTransport(cl)
            if not tx.hasInternet and not tx.hasMesh then
                return { id = id, ok = false, error = "No Internet Card or OC Mesh modem/tunnel" }
            end
            local url = (type(cmd.url) == "string" and cmd.url ~= "") and cmd.url or Common.LOCAL_UPDATE_URL
            if not Common.isAllowedOtaUrl(url) then return { id = id, ok = false, error = "Invalid update URL" } end
            state._pendingUpdateUrl = url
            state._pendingReboot = true
            return { id = id, ok = true, updating = true, viaMesh = tx.viaMesh, url = url }
        elseif act == "reboot" then
            state._pendingReboot = true
            return { id = id, ok = true, rebooting = true }
        else
            return { id = id, ok = false, error = "Unknown BHC action: " .. tostring(act) }
        end
    else
        return { id = id, ok = false, error = "Unknown op: " .. tostring(op) }
    end
    if mutated then
        if onMutate then pcall(onMutate, cfg) end
        Hardware.pushMeshMetrics(cfg, state, clockNow(), compLib, true)
    end
    local snap = Scheduler.buildSnapshot(cfg, state)
    snap.id = id
    return snap
end

return Scheduler
