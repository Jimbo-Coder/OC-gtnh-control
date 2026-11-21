-- /home/nanoforge/lib/scheduler.lua
-- Strict Serialized Dispatcher & T4 Magmatter/Seed Batch Planner for Nano Forge.
-- Enforces 1 nanite recipe in the bus at a time so T4 parallels & 0.9999^P speed boost stay active.

local okComp, defaultComponent = pcall(require, "component")
if not okComp then defaultComponent = nil end
local Common = require("gtnh_common")
local okComputer, computer = pcall(require, "computer")
if not okComputer then computer = nil end
local RecipesDb = require("lib.recipes_db")
local Hardware = require("lib.hardware")

local Scheduler = {}

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

local function defaultTargets()
    local t = {}
    for idx, r in ipairs(RecipesDb.RECIPES) do
        t[r.id] = {
            enabled = false,
            targetStock = 64,
            targetParallels = (r.tier == 4) and 4 or ((r.tier == 3) and 8 or 16),
            maxMagmatterL = 4096,
            priority = 100 - idx * 5,
        }
    end
    return t
end

function Scheduler.defaultConfig()
    return {
        armed = false,
        pollSec = 2,
        extLinkMode = "auto",
        autoWake = true,
        forgeTier = 4,             -- 1..4 (4 = Eternity Nanite unlocked)
        mode = "both",             -- "both" | "od_only" | "passive_only"
        t3MinPerfectOc = true,     -- bump T3 crafts >= 2 parallels when affordable (unlocks 4/4 OC)
        allowBootstrap1x = true,   -- allow 1x craft with 0 Magmatter if output nanite stock == 0
        autoSweepForeign = true,   -- sweep foreign nanites out of bus before dispatch
        magmatterReserveL = 10000, -- minimum molten.magmatter kept in tank/ME reserve
        defaultMaxParallel = 16,
        controllerAddr = "",
        itemTransposerAddr = "",
        magTransposerAddr = "",
        aeAddr = "",
        stagingSrcSide = "north",
        seedSrcSide = "west",
        dstBusSide = "east",
        returnSide = "south",
        odFluidDstSide = "east",
        magSrcSide = "down",
        magDstSide = "up",
        targets = defaultTargets(),
    }
end

function Scheduler.normalizeConfig(raw)
    local d = Scheduler.defaultConfig()
    if type(raw) ~= "table" then return d end
    d.armed = (raw.armed == true)
    d.pollSec = math.max(1, math.min(60, math.floor(tonumber(raw.pollSec) or d.pollSec)))
    d.extLinkMode = (raw.extLinkMode == "off") and "off" or "auto"
    d.autoWake = (raw.autoWake ~= false)
    d.forgeTier = math.max(1, math.min(4, math.floor(tonumber(raw.forgeTier) or d.forgeTier)))
    if raw.mode == "both" or raw.mode == "od_only" or raw.mode == "passive_only" then d.mode = raw.mode end
    d.t3MinPerfectOc = (raw.t3MinPerfectOc ~= false)
    d.allowBootstrap1x = (raw.allowBootstrap1x ~= false)
    d.autoSweepForeign = (raw.autoSweepForeign ~= false)
    d.magmatterReserveL = math.max(0, math.floor(tonumber(raw.magmatterReserveL) or d.magmatterReserveL))
    d.defaultMaxParallel = math.max(1, math.min(1024, math.floor(tonumber(raw.defaultMaxParallel) or d.defaultMaxParallel)))
    for _, k in ipairs({
        "controllerAddr", "itemTransposerAddr", "magTransposerAddr", "aeAddr",
        "stagingSrcSide", "seedSrcSide", "dstBusSide", "returnSide",
        "odFluidDstSide", "magSrcSide", "magDstSide",
    }) do
        if type(raw[k]) == "string" and raw[k] ~= "" then d[k] = raw[k] end
    end
    if type(raw.targets) == "table" then
        for id, def in pairs(d.targets) do
            local rt = raw.targets[id]
            if type(rt) == "table" then
                def.enabled = (rt.enabled == true)
                def.targetStock = math.max(0, math.floor(tonumber(rt.targetStock) or def.targetStock))
                def.targetParallels = math.max(1, math.min(1024, math.floor(tonumber(rt.targetParallels) or def.targetParallels)))
                def.maxMagmatterL = math.max(0, math.floor(tonumber(rt.maxMagmatterL) or def.maxMagmatterL))
                def.priority = math.max(0, math.min(100, math.floor(tonumber(rt.priority) or def.priority)))
            end
        end
    end
    return d
end

function Scheduler.newState()
    return {
        phase = "IDLE", -- "IDLE" | "DISPATCHING" | "RUNNING"
        currentBatch = nil,
        manualQueue = {},
        completedBatches = 0,
        magAvailableL = 0,
        magMeL = 0,
        naniteStocks = {},
        machine = { online = false, active = false, remainingSec = 0, maxInputEu = 0 },
        busScan = { clean = true, foreign = {}, outputSeedCount = 0 },
        stagingPending = nil,
        discovery = { controllers = {}, transposers = {}, aeInterfaces = {} },
        events = {},
        lastError = nil,
    }
end

-- Pure deterministic T4 batch planner matching MTENanoForge$1 & NaniteChain rules
function Scheduler.planBatch(cfg, recipe, desiredParallels, outputStock, magAvailableL, targetMaxMagL, maxParallelsCap)
    if not recipe then return { blockedReason = "Unknown recipe" } end
    local ft = math.floor(tonumber(cfg.forgeTier) or 4)
    if ft < recipe.tier then
        return { blockedReason = string.format("Forge Tier %d < Recipe Tier %d", ft, recipe.tier) }
    end
    if ft < 4 then
        local ticks, perf = RecipesDb.estimateCycleTicks(recipe, nil, ft, 1)
        return {
            parallels = 1, magmatterL = 0, needsSeed = false, bootstrap1x = false,
            perfectOC = perf, speedMult = 1.0, estTicks = ticks,
        }
    end

    local stock = math.floor(tonumber(outputStock) or 0)
    local magPerP = RecipesDb.magmatterPerParallel(recipe.tier)
    local spendableMag = math.max(0, math.floor((tonumber(magAvailableL) or 0) - (tonumber(cfg.magmatterReserveL) or 0)))
    local capMag = math.min(spendableMag, tonumber(targetMaxMagL) or 1e9)
    local wantP = math.max(1, math.floor(tonumber(desiredParallels) or cfg.defaultMaxParallel or 16))
    if recipe.tier == 3 and cfg.t3MinPerfectOc ~= false then
        wantP = math.max(wantP, 2)
    end
    if tonumber(maxParallelsCap) then
        wantP = math.max(1, math.min(wantP, math.floor(tonumber(maxParallelsCap))))
    end

    if stock < 1 then
        if cfg.allowBootstrap1x ~= false then
            local ticks, perf = RecipesDb.estimateCycleTicks(recipe, nil, ft, 1)
            return {
                parallels = 1, magmatterL = 0, needsSeed = false, bootstrap1x = true,
                perfectOC = perf, speedMult = RecipesDb.speedMultiplier(1, ft), estTicks = ticks,
            }
        end
        return { blockedReason = "Missing output nanite seed (bootstrap disabled)" }
    end

    local maxByMag = math.floor(capMag / magPerP)
    local parallels = math.max(1, math.min(wantP, maxByMag))
    if parallels <= 1 then
        local ticks, perf = RecipesDb.estimateCycleTicks(recipe, nil, ft, 1)
        return {
            parallels = 1, magmatterL = 0, needsSeed = false, bootstrap1x = false,
            perfectOC = perf, speedMult = RecipesDb.speedMultiplier(1, ft), estTicks = ticks,
        }
    end
    local exactMag = parallels * magPerP
    local ticks, perf = RecipesDb.estimateCycleTicks(recipe, nil, ft, parallels)
    return {
        parallels = parallels,
        magmatterL = exactMag,
        needsSeed = true,
        bootstrap1x = false,
        perfectOC = perf,
        speedMult = RecipesDb.speedMultiplier(parallels, ft),
        estTicks = ticks,
    }
end

function Scheduler.syncHardware(cfg, state, compLib)
    local disc = Hardware.discover(compLib, state)
    state.discovery = disc
    Hardware.autoBind(cfg, disc)
    return disc
end

local function allowedInputsMap(recipe)
    local m = {}
    for _, it in ipairs((recipe and recipe.items) or {}) do
        if it.isNaniteInput then
            m[tonumber(it.damage)] = true
        end
    end
    return m
end

local function selectNextJob(cfg, state, stocks, magTankL, stgRecipe, stgBatches)
    if state.manualQueue and #state.manualQueue > 0 then
        local job = state.manualQueue[1]
        local rec = RecipesDb.BY_ID[job.recipeId]
        if rec then
            return { kind = "manual", recipe = rec, parallels = job.parallels, cap = job.cap or 1e9 }
        end
    end
    if cfg.mode ~= "passive_only" and stgRecipe and (stgBatches or 0) >= 1 then
        local tg = cfg.targets[stgRecipe.id] or {}
        local desP = math.max(stgBatches, tonumber(tg.targetParallels) or cfg.defaultMaxParallel)
        return { kind = "staging", recipe = stgRecipe, parallels = math.min(stgBatches, desP), cap = tg.maxMagmatterL, maxCap = stgBatches }
    end
    if cfg.mode ~= "od_only" then
        local best, bestScore = nil, -1
        for _, r in ipairs(RecipesDb.RECIPES) do
            local tg = cfg.targets[r.id]
            if tg and tg.enabled and r.tier <= cfg.forgeTier then
                local have = tonumber(stocks[r.id]) or 0
                if have < tg.targetStock then
                    local deficit = (tg.targetStock - have) / math.max(1, tg.targetStock)
                    local score = (tg.priority or 50) * 10 + deficit
                    if score > bestScore then
                        bestScore = score
                        best = { kind = "passive", recipe = r, parallels = tg.targetParallels, cap = tg.maxMagmatterL }
                    end
                end
            end
        end
        if best then return best end
    end
    return nil
end

function Scheduler.step(cfg, state, nowSec, compLib, opts)
    nowSec = nowSec or clockNow()
    opts = opts or {}
    local dryRun = (opts.dryRun == true)

    Scheduler.syncHardware(cfg, state, compLib)
    local mach = Hardware.readMachine(cfg, compLib, state)
    local stocks, magMeL = Hardware.readMeStocks(cfg, compLib, state)
    local hatchMag, srcMag = Hardware.getHatchMagmatter(cfg, compLib, state)
    local stgRecipe, stgBatches = Hardware.detectStagingOrder(cfg, compLib, state)

    state.machine = mach
    state.naniteStocks = stocks
    state.magMeL = magMeL
    state.magAvailableL = math.max(srcMag or 0, hatchMag or 0)
    state.stagingPending = stgRecipe and { id = stgRecipe.id, label = stgRecipe.label, batches = stgBatches } or nil

    if state.phase == "RUNNING" then
        if not mach.active then
            state.phase = "IDLE"
            state.completedBatches = (state.completedBatches or 0) + 1
            if state.currentBatch then
                logEvent(state, "OUT", string.format("Completed %dx %s", state.currentBatch.parallels or 1, state.currentBatch.label or "batch"))
            end
            state.currentBatch = nil
        else
            return true
        end
    end

    local candidate = selectNextJob(cfg, state, stocks, state.magAvailableL, stgRecipe, stgBatches)
    if not candidate then
        state.busScan = Hardware.scanBusNanites(cfg, nil, nil, compLib, state)
        return true
    end

    local rec = candidate.recipe
    local allowIn = allowedInputsMap(rec)
    local scan = Hardware.scanBusNanites(cfg, rec.output.damage, allowIn, compLib, state)
    state.busScan = scan

    -- Strictly enforce nanite purity before touching Magmatter or seeds
    if not scan.clean then
        if cfg.autoSweepForeign ~= false and (not dryRun) then
            local swept = Hardware.sweepForeignNanites(cfg, scan.foreign, compLib, state)
            logEvent(state, "WRN", string.format("Swept %d foreign nanite(s) for %s purity", swept, rec.label))
            scan = Hardware.scanBusNanites(cfg, rec.output.damage, allowIn, compLib, state)
            state.busScan = scan
        end
        if not scan.clean then
            state.lastError = "Foreign nanite in bus blocked dispatch"
            return false
        end
    end

    local outStock = (stocks[rec.id] or 0) + (scan.outputSeedCount or 0)
    local plan = Scheduler.planBatch(cfg, rec, candidate.parallels, outStock, state.magAvailableL, candidate.cap, candidate.maxCap)
    if plan.blockedReason then
        state.lastError = plan.blockedReason
        return false
    end

    if (not cfg.armed) or dryRun then
        state.lastError = nil
        return true
    end

    -- Exact Magmatter metering -> seed injection (if parallels > 1 & not already in bus) -> staging transfer
    local okMag, movedMag, magErr = Hardware.meterMagmatter(cfg, plan.magmatterL, compLib, state)
    if not okMag then
        state.lastError = magErr
        return false
    end
    if plan.needsSeed and (scan.outputSeedCount or 0) < 1 then
        local okSeed, seedErr = Hardware.injectOutputSeed(cfg, rec, compLib, state)
        if not okSeed then
            state.lastError = seedErr
            return false
        end
    end
    if candidate.kind == "staging" then
        local okStg, stgErr = Hardware.transferStagingBatch(cfg, rec, plan.parallels, compLib, state)
        if not okStg then
            state.lastError = stgErr
            return false
        end
    elseif candidate.kind == "manual" then
        table.remove(state.manualQueue, 1)
    end

    state.lastError = nil
    state.currentBatch = {
        recipeId = rec.id,
        label = rec.label,
        tier = rec.tier,
        parallels = plan.parallels,
        magmatterL = plan.magmatterL,
        perfectOC = plan.perfectOC,
        speedMult = plan.speedMult,
        startedAt = nowSec,
    }
    state.phase = "RUNNING"
    logEvent(state, "OUT", string.format("Dispatched %dx %s (Mag=%dL, 4/4OC=%s)",
        plan.parallels, rec.label, plan.magmatterL, tostring(plan.perfectOC)))
    return true
end

function Scheduler.renderDigest(cfg, state)
    local cur = state.currentBatch or {}
    return string.format("%s:%s:%s:%d:%d:%d",
        tostring(cfg.armed), tostring(state.phase), tostring(cur.recipeId),
        tonumber(cur.parallels) or 0, tonumber(state.completedBatches) or 0,
        tonumber(state.magAvailableL) or 0)
end

function Scheduler.buildSnapshot(cfg, state)
    local targetsOut = {}
    for _, r in ipairs(RecipesDb.RECIPES) do
        local tg = cfg.targets[r.id] or {}
        targetsOut[#targetsOut + 1] = {
            id = r.id,
            label = r.label,
            tier = r.tier,
            magPerP = RecipesDb.magmatterPerParallel(r.tier),
            outSize = r.output.size,
            enabled = (tg.enabled == true),
            stock = tonumber((state.naniteStocks or {})[r.id]) or 0,
            targetStock = tonumber(tg.targetStock) or 0,
            targetParallels = tonumber(tg.targetParallels) or 1,
            maxMagmatterL = tonumber(tg.maxMagmatterL) or 0,
            priority = tonumber(tg.priority) or 50,
        }
    end
    return {
        ok = true,
        role = "nano",
        armed = (cfg.armed == true),
        forgeTier = cfg.forgeTier,
        mode = cfg.mode,
        t3MinPerfectOc = (cfg.t3MinPerfectOc ~= false),
        allowBootstrap1x = (cfg.allowBootstrap1x ~= false),
        autoSweepForeign = (cfg.autoSweepForeign ~= false),
        autoWake = (cfg.autoWake ~= false),
        magmatterReserveL = cfg.magmatterReserveL,
        phase = state.phase,
        currentBatch = state.currentBatch,
        completedBatches = state.completedBatches or 0,
        magAvailableL = state.magAvailableL or 0,
        magMeL = state.magMeL or 0,
        busClean = (state.busScan and state.busScan.clean ~= false),
        stagingPending = state.stagingPending,
        machine = state.machine,
        targets = targetsOut,
        lastError = state.lastError,
        events = state.events or {},
    }
end

function Scheduler.executeRpcTable(cfg, state, cmd, compLib, onMutate)
    if type(cmd) ~= "table" then return { ok = false, error = "Invalid command" } end
    local op, id = cmd.op, cmd.id
    local mutated = false
    if op == "ping" then
        return { id = id, ok = true, role = "nano", armed = (cfg.armed == true) }
    elseif op == "get_state" or op == "nano_state" then
        local snap = Scheduler.buildSnapshot(cfg, state)
        snap.id = id
        return snap
    elseif op == "patch_settings" or op == "nano_patch" then
        local p = type(cmd.patch) == "table" and cmd.patch or cmd
        if type(p.armed) == "boolean" then cfg.armed = p.armed; mutated = true end
        if tonumber(p.forgeTier) then cfg.forgeTier = math.max(1, math.min(4, math.floor(tonumber(p.forgeTier)))); mutated = true end
        if p.mode == "both" or p.mode == "od_only" or p.mode == "passive_only" then cfg.mode = p.mode; mutated = true end
        if type(p.t3MinPerfectOc) == "boolean" then cfg.t3MinPerfectOc = p.t3MinPerfectOc; mutated = true end
        if type(p.allowBootstrap1x) == "boolean" then cfg.allowBootstrap1x = p.allowBootstrap1x; mutated = true end
        if type(p.autoSweepForeign) == "boolean" then cfg.autoSweepForeign = p.autoSweepForeign; mutated = true end
        if type(p.autoWake) == "boolean" then cfg.autoWake = p.autoWake; Hardware.openMeshPort(cfg, compLib, state); mutated = true end
        if tonumber(p.magmatterReserveL) then cfg.magmatterReserveL = math.max(0, math.floor(tonumber(p.magmatterReserveL))); mutated = true end
        if type(p.target) == "table" and p.target.id and cfg.targets[p.target.id] then
            local pt, tg = p.target, cfg.targets[p.target.id]
            if type(pt.enabled) == "boolean" then tg.enabled = pt.enabled end
            if tonumber(pt.targetStock) then tg.targetStock = math.max(0, math.floor(tonumber(pt.targetStock))) end
            if tonumber(pt.targetParallels) then tg.targetParallels = math.max(1, math.min(1024, math.floor(tonumber(pt.targetParallels)))) end
            if tonumber(pt.maxMagmatterL) then tg.maxMagmatterL = math.max(0, math.floor(tonumber(pt.maxMagmatterL))) end
            if tonumber(pt.priority) then tg.priority = math.max(0, math.min(100, math.floor(tonumber(pt.priority)))) end
            mutated = true
        end
    elseif op == "craft_batch" and type(cmd.recipeId) == "string" and RecipesDb.BY_ID[cmd.recipeId] then
        local par = math.max(1, math.floor(tonumber(cmd.parallels) or 4))
        state.manualQueue[#state.manualQueue + 1] = { recipeId = cmd.recipeId, parallels = par }
        Scheduler.step(cfg, state, clockNow(), compLib)
    elseif op == "push_inputs" and type(cmd.recipeId) == "string" then
        local rules, tag = RecipesDb.buildStockRules(cmd.recipeId, cmd.mult or 1)
        if not rules then return { id = id, ok = false, error = tag } end
        local ok, info = Hardware.pushRulesToStock(cfg, state, { tag = tag, group = "NanoForge", rules = rules }, compLib)
        return { id = id, ok = ok == true, reqId = info, tag = tag, count = #rules }
    elseif op == "action" or op == "nano_action" then
        local act = cmd.action
        if act == "arm" or act == "resume" then cfg.armed = true; mutated = true
        elseif act == "pause" then cfg.armed = false; mutated = true
        elseif act == "poll_now" or act == "poll" then Scheduler.step(cfg, state, clockNow(), compLib)
        elseif act == "sweep_bus" then
            local scan = Hardware.scanBusNanites(cfg, nil, nil, compLib, state)
            local moved = Hardware.sweepForeignNanites(cfg, scan.foreign, compLib, state)
            state.busScan = Hardware.scanBusNanites(cfg, nil, nil, compLib, state)
            logEvent(state, "OUT", "Manual sweep moved " .. tostring(moved) .. " foreign nanite(s)")
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
            return { id = id, ok = false, error = "Unknown Nano Forge action: " .. tostring(act) }
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
