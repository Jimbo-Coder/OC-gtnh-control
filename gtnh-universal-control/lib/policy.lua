-- /home/universal/lib/policy.lua
-- Pluggable Scheduling Policies (MLFQ Probe+Cache, SRTF, Round-Robin, FIFO, Priority)
-- and Multi-Channel Priority Assignment / High->Low Demotion for GTNH Universal Control.

local Policy = {}

Policy.POLICIES = { "mlfq", "srtf", "round_robin", "fifo", "priority" }
Policy.PRIORITY_ORDER = { "normal", "high", "pin", "low", "off" }
Policy.PRIORITY_WEIGHTS = {
    pin    = 4,
    high   = 3,
    normal = 2,
    low    = 1,
    off    = 0,
}

-- GregTech 2.9.0 Dyes.mIndex hatch check priority order (MTEMultiBlockBase scans 0 -> 15).
Policy.GT_DYE_PRIORITY = {
    [0]  = "Black",
    [1]  = "Red",
    [2]  = "Green",
    [3]  = "Brown",
    [4]  = "Blue",
    [5]  = "Purple",
    [6]  = "Cyan",
    [7]  = "LightGray",
    [8]  = "Gray",
    [9]  = "Pink",
    [10] = "Lime",
    [11] = "Yellow",
    [12] = "LightBlue",
    [13] = "Magenta",
    [14] = "Orange",
    [15] = "White",
}

local MAX_RECIPE_CACHE = 128

-- Build a compact deterministic fingerprint of up to 8 sorted active ingredient keys.
function Policy.buildIngredientSig(activeItems, activeFluids)
    local parts = {}
    if type(activeItems) == "table" then
        for i = 1, math.min(6, #activeItems) do
            parts[#parts + 1] = "i:" .. tostring(activeItems[i].key or "")
        end
    end
    if type(activeFluids) == "table" then
        for i = 1, math.min(6, #activeFluids) do
            parts[#parts + 1] = "f:" .. tostring(activeFluids[i].key or "")
        end
    end
    if #parts == 0 then return "" end
    table.sort(parts)
    if #parts > 8 then
        local trimmed = {}
        for i = 1, 8 do trimmed[i] = parts[i] end
        return table.concat(trimmed, "|")
    end
    return table.concat(parts, "|")
end

local function recipeCacheKey(poolId, ncIdx, sig)
    if type(sig) ~= "string" or sig == "" then return nil end
    return tostring(poolId) .. ":" .. tostring(ncIdx) .. ":" .. sig
end

function Policy.lookupRecipeRate(state, poolId, ncIdx, sig)
    if not state or type(state.recipeRates) ~= "table" then return nil end
    local k = recipeCacheKey(poolId, ncIdx, sig)
    if not k then return nil end
    return state.recipeRates[k]
end

function Policy.recordRecipeRate(state, poolId, ncIdx, sig, instRate)
    if not state or type(instRate) ~= "number" or instRate <= 0 then return end
    local k = recipeCacheKey(poolId, ncIdx, sig)
    if not k then return end
    state.recipeRates = state.recipeRates or {}
    state.recipeRateOrder = state.recipeRateOrder or {}

    local prev = state.recipeRates[k]
    if prev == nil then
        while #state.recipeRateOrder >= MAX_RECIPE_CACHE do
            local oldest = table.remove(state.recipeRateOrder, 1)
            if oldest then state.recipeRates[oldest] = nil end
        end
        state.recipeRateOrder[#state.recipeRateOrder + 1] = k
        state.recipeRates[k] = instRate
    else
        state.recipeRates[k] = 0.35 * instRate + 0.65 * prev
    end
end

-- Classify a slice candidate and compute rate, ETA, wait aging, and MLFQ tier.
function Policy.classifyCandidate(poolId, ncIdx, slice, sState, state, cfg, nowSec, forced)
    local cachedRate = Policy.lookupRecipeRate(state, poolId, ncIdx, sState.ingredientSig)
    local liveRate = ((sState._batchSamples or 0) > 0) and tonumber(sState._batchRate) or nil
    local baseRate = liveRate or cachedRate or tonumber(slice.learnedRate) or tonumber(cfg.defaultProbeRate) or 8.0
    local rate = math.max(0.01, baseRate)

    local workScore = tonumber(sState.workScore) or 0
    local rawEta = workScore / rate
    local waitSec = sState.busySince and math.max(0, (nowSec or 0) - sState.busySince) or 0
    local discount = math.min(0.80, (waitSec / 60.0) * (tonumber(cfg.agingPerMin) or 0.15))
    local effEta = rawEta * (1.0 - discount)

    local probeWin = tonumber(cfg.probeWindowSec) or 1.5
    local fastThresh = tonumber(cfg.fastThresholdSec) or 3.0
    local activeRun = tonumber(sState.activeRunSec) or 0

    local tier = "BULK"
    if (slice and slice._forceBulk ~= true) and activeRun < probeWin then
        if liveRate == nil and cachedRate ~= nil then
            local knownEta = workScore / math.max(0.01, cachedRate)
            tier = (knownEta <= fastThresh) and "PROBE" or "BULK"
        else
            tier = "PROBE"
        end
    end

    sState.etaSec = rawEta
    sState.effectiveEtaSec = effEta
    sState.tier = tier

    return {
        ncIdx = ncIdx,
        color = ncIdx,
        slice = slice,
        sState = sState,
        priWeight = Policy.PRIORITY_WEIGHTS[slice.priority] or 2,
        forced = (forced == true),
        tier = tier,
        tierRank = (tier == "PROBE") and 1 or 0,
        rate = rate,
        rawEta = rawEta,
        effectiveEta = effEta,
        busySince = sState.busySince or nowSec or 0,
        activeRunSec = activeRun,
        workScore = workScore,
    }
end

local function compareCandidates(a, b, mode, lastServedNc, maxSlices)
    if a.forced ~= b.forced then
        return a.forced
    end
    if a.priWeight ~= b.priWeight then
        return a.priWeight > b.priWeight
    end

    if mode == "priority" then
        if math.abs(a.busySince - b.busySince) > 1e-6 then
            return a.busySince < b.busySince
        end
    elseif mode == "fifo" then
        if math.abs(a.busySince - b.busySince) > 1e-6 then
            return a.busySince < b.busySince
        end
    elseif mode == "round_robin" then
        local span = math.max(16, tonumber(maxSlices) or 16)
        local last = tonumber(lastServedNc) or -1
        local da = (a.ncIdx - last - 1 + span) % span
        local db = (b.ncIdx - last - 1 + span) % span
        if da ~= db then
            return da < db
        end
    elseif mode == "srtf" then
        if math.abs(a.effectiveEta - b.effectiveEta) > 1e-6 then
            return a.effectiveEta < b.effectiveEta
        end
        if math.abs(a.busySince - b.busySince) > 1e-6 then
            return a.busySince < b.busySince
        end
    else -- "mlfq" (default)
        if a.tierRank ~= b.tierRank then
            return a.tierRank > b.tierRank
        end
        if a.tier == "PROBE" then
            if math.abs(a.effectiveEta - b.effectiveEta) > 1e-6 then
                return a.effectiveEta < b.effectiveEta
            end
            if math.abs(a.busySince - b.busySince) > 1e-6 then
                return a.busySince < b.busySince
            end
        else
            if math.abs(a.effectiveEta - b.effectiveEta) > 1e-6 then
                return a.effectiveEta < b.effectiveEta
            end
            if math.abs(a.busySince - b.busySince) > 1e-6 then
                return a.busySince < b.busySince
            end
        end
    end
    return a.ncIdx < b.ncIdx
end

local function canPreempt(curChState, curCand, newcomer, heldSec, cfg, mode)
    if newcomer.forced then
        return true, "manual force"
    end
    if curCand.priWeight >= 4 then
        return false, "pinned"
    end

    local probeHold = tonumber(cfg.probePreemptHoldSec) or 1.5
    local minHold = tonumber(cfg.minHoldSec) or 15.0
    local ratio = tonumber(cfg.preemptRatio) or 0.35

    -- Avoid swapping while channel is already mid-settle unless newcomer is strictly higher user priority.
    if curChState and curChState.phase == "SETTLING" then
        if newcomer.priWeight > curCand.priWeight then
            return true, "higher priority"
        end
        return false, "settling"
    end

    if mode == "fifo" or mode == "priority" then
        if newcomer.priWeight > curCand.priWeight and heldSec >= probeHold then
            return true, "higher priority"
        end
        return false, "hold"
    elseif mode == "round_robin" then
        if heldSec >= minHold and newcomer.priWeight >= curCand.priWeight then
            return true, "round-robin slice quantum"
        end
        return false, "hold"
    elseif mode == "srtf" then
        if heldSec >= minHold then
            if newcomer.priWeight > curCand.priWeight then
                return true, "higher priority"
            elseif newcomer.priWeight == curCand.priWeight
                and newcomer.effectiveEta < (curCand.effectiveEta * ratio) then
                return true, string.format("SRTF %.1fs < %.1fs", newcomer.effectiveEta, curCand.effectiveEta * ratio)
            end
        end
        return false, "hold"
    else -- "mlfq"
        if newcomer.priWeight > curCand.priWeight and heldSec >= probeHold then
            return true, "higher priority"
        elseif newcomer.priWeight == curCand.priWeight then
            if newcomer.tier == "PROBE" and curCand.tier == "BULK" and heldSec >= probeHold then
                return true, string.format("MLFQ fast probe (ETA %.1fs) vs BULK", newcomer.effectiveEta)
            elseif newcomer.tier == "PROBE" and curCand.tier == "PROBE" then
                return false, "probe window active"
            elseif heldSec >= minHold and newcomer.effectiveEta < (curCand.effectiveEta * ratio) then
                return true, string.format("SRTF %.1fs < %.1fs", newcomer.effectiveEta, curCand.effectiveEta * ratio)
            end
        end
        return false, "hold"
    end
end

local function isChannelConfigured(pool, chIdx, ch)
    if not ch or ch.enabled == false then return false end
    local b1 = ch.banks and ch.banks[1]
    if b1 and b1.rsAddr and b1.rsAddr ~= "" then return true end
    if chIdx == 1 and pool.rsAddr and pool.rsAddr ~= "" then return true end
    if type(ch.overrides) == "table" then
        for _, ov in pairs(ch.overrides) do
            if ov and ov.rsAddr and ov.rsAddr ~= "" then return true end
        end
    end
    return false
end

-- Decide desired NC index (0..numSlices-1) or nil for every enabled channel in `pool`.
-- Invariants guaranteed:
--   1. At most 1 NC assigned per enabled channel; no two channels get the same NC.
--   2. In MLFQ with K >= 2 channels and fewer runnable NCs than K, BULK NCs are placed
--      on lowest-priority enabled channels so Channel 1 (High Prio) stays IDLE & pre-settled.
function Policy.decide(pool, pState, candidates, state, cfg, nowSec)
    local enCh = {}
    for chIdx, ch in ipairs(pool.channels or {}) do
        if isChannelConfigured(pool, chIdx, ch) then
            enCh[#enCh + 1] = chIdx
        end
    end
    if #enCh == 0 then return {}, {} end

    local desired = {}
    local reasons = {}
    if type(candidates) ~= "table" or #candidates == 0 then
        return desired, reasons
    end

    local mode = pool.mode or "mlfq"
    local maxSlices = tonumber(pool.numSlices) or 16
    local ch1LastServed = (pState and pState.channels and pState.channels[enCh[1]] and pState.channels[enCh[1]].lastServedNc)
        or (pState and pState.lastServedColor) or -1

    local sorted = {}
    local candByNc = {}
    for i = 1, #candidates do
        local c = candidates[i]
        sorted[#sorted + 1] = c
        candByNc[c.ncIdx] = c
    end
    table.sort(sorted, function(a, b)
        return compareCandidates(a, b, mode, ch1LastServed, maxSlices)
    end)

    -- Current valid occupants per enabled channel
    local chStates = (pState and pState.channels) or {}
    local curOwnerByNc = {}
    local occupants = {}
    for _, chIdx in ipairs(enCh) do
        local cs = chStates[chIdx]
        local occNc = nil
        if cs then
            if cs.phase == "ACTIVE" then occNc = cs.activeNc
            elseif cs.phase == "SETTLING" then occNc = cs.pendingNc
            end
        end
        if occNc ~= nil and candByNc[occNc] and not curOwnerByNc[occNc] then
            curOwnerByNc[occNc] = chIdx
            occupants[chIdx] = candByNc[occNc]
        end
    end

    -- 1. Select up to K winning candidates (respecting hold hysteresis).
    local K = #enCh
    local M = math.min(K, #sorted)
    local topSet = {}
    for i = 1, M do
        topSet[sorted[i].ncIdx] = true
    end

    local displacedByNc = {}
    local retainedByNc = {}
    local newbies = {}
    for i = 1, M do
        local c = sorted[i]
        if not curOwnerByNc[c.ncIdx] then
            newbies[#newbies + 1] = c
        else
            retainedByNc[c.ncIdx] = true
        end
    end

    local holdSurvivors = {}
    for _, chIdx in ipairs(enCh) do
        local occ = occupants[chIdx]
        if occ and not topSet[occ.ncIdx] then
            holdSurvivors[#holdSurvivors + 1] = { chIdx = chIdx, cand = occ }
        end
    end
    -- Weakest occupant challenges strongest newbie first
    table.sort(holdSurvivors, function(a, b)
        return compareCandidates(b.cand, a.cand, mode, ch1LastServed, maxSlices)
    end)

    local finalNewbies = {}
    for _, hs in ipairs(holdSurvivors) do
        local chIdx = hs.chIdx
        local occ = hs.cand
        local cs = chStates[chIdx]
        local heldSec = (cs and cs.phase == "ACTIVE") and math.max(0, (nowSec or 0) - (cs.activeSince or nowSec or 0)) or 0
        if #newbies > 0 then
            local challenger = newbies[1]
            local okPre, reason = canPreempt(cs, occ, challenger, heldSec, cfg, mode)
            if okPre then
                table.remove(newbies, 1)
                finalNewbies[#finalNewbies + 1] = challenger
                displacedByNc[challenger.ncIdx] = reason
            else
                -- Occupant keeps its seat; drop weakest unseated newbie
                table.remove(newbies, #newbies)
                retainedByNc[occ.ncIdx] = true
            end
        end
    end
    for i = 1, #newbies do
        finalNewbies[#finalNewbies + 1] = newbies[i]
    end

    local winners = {}
    for ncIdx in pairs(retainedByNc) do
        winners[#winners + 1] = candByNc[ncIdx]
    end
    for i = 1, #finalNewbies do
        winners[#winners + 1] = finalNewbies[i]
    end
    table.sort(winners, function(a, b)
        return compareCandidates(a, b, mode, ch1LastServed, maxSlices)
    end)
    while #winners > K do
        table.remove(winners)
    end

    if K == 1 then
        desired[enCh[1]] = winners[1].ncIdx
        reasons[enCh[1]] = displacedByNc[winners[1].ncIdx] or ((winners[1].tier == "PROBE") and "MLFQ probe" or "active")
        return desired, reasons
    end

    -- 2. Map M winners onto K channels:
    --    Keep Channel 1 (High Prio) IDLE & pre-settled when fewer winners than K in MLFQ
    --    and a BULK job can safely demote to the lowest free channel.
    local highPool, lowPool = {}, {}
    for i = 1, #winners do
        local w = winners[i]
        local needsHigh = w.forced or (w.priWeight >= 3) or (mode ~= "mlfq") or (w.tier == "PROBE")
        if needsHigh then
            highPool[#highPool + 1] = w
        else
            lowPool[#lowPool + 1] = w
        end
    end

    -- Assign BULK (demotable) winners bottom-up, preserving sticky lower-channel ownership first
    local usedCh = {}
    local assignedNc = {}

    local chPos = {}
    for pos, chIdx in ipairs(enCh) do
        chPos[chIdx] = pos
    end

    -- Preserve sticky owners in lowPool when already below any highPool slots
    -- (and strictly off Channel 1 whenever #winners < K so Channel 1 stays free & settled).
    local stickyLow = {}
    local minLowPos = (#highPool > 0) and (#highPool + 1) or ((#winners < K) and (K - #lowPool + 1) or 1)
    for _, w in ipairs(lowPool) do
        local curCh = curOwnerByNc[w.ncIdx]
        local alreadyLowEnough = curCh ~= nil and (chPos[curCh] or 0) >= minLowPos
        if curCh and alreadyLowEnough and not usedCh[curCh] then
            desired[curCh] = w.ncIdx
            reasons[curCh] = "sticky low-prio"
            usedCh[curCh] = true
            assignedNc[w.ncIdx] = true
        else
            stickyLow[#stickyLow + 1] = w
        end
    end

    -- Assign highPool winners top-down, preferring sticky placement if already not colliding with demotion
    local unplacedHigh = {}
    for _, w in ipairs(highPool) do
        local curCh = curOwnerByNc[w.ncIdx]
        if curCh and not usedCh[curCh] and (curCh == enCh[1] or not (w.forced or w.tier == "PROBE")) then
            desired[curCh] = w.ncIdx
            reasons[curCh] = displacedByNc[w.ncIdx] or "sticky active"
            usedCh[curCh] = true
            assignedNc[w.ncIdx] = true
        else
            unplacedHigh[#unplacedHigh + 1] = w
        end
    end

    for _, w in ipairs(unplacedHigh) do
        for pos = 1, K do
            local chIdx = enCh[pos]
            if not usedCh[chIdx] then
                desired[chIdx] = w.ncIdx
                reasons[chIdx] = displacedByNc[w.ncIdx] or ((w.tier == "PROBE") and "MLFQ high-prio probe" or "dispatch")
                usedCh[chIdx] = true
                assignedNc[w.ncIdx] = true
                break
            end
        end
    end

    -- Place remaining demotable BULK winners bottom-up (lowest priority channel first!)
    for _, w in ipairs(stickyLow) do
        for pos = K, 1, -1 do
            local chIdx = enCh[pos]
            if not usedCh[chIdx] then
                local wasOnCh1 = (curOwnerByNc[w.ncIdx] == enCh[1] and chIdx ~= enCh[1])
                desired[chIdx] = w.ncIdx
                reasons[chIdx] = wasOnCh1 and "demote BULK -> low-prio ch" or (displacedByNc[w.ncIdx] or "BULK low-prio ch")
                usedCh[chIdx] = true
                assignedNc[w.ncIdx] = true
                break
            end
        end
    end

    return desired, reasons
end

return Policy
