-- /home/dtpf/lib/scheduler.lua
-- Passive Stocking, Loop Guard, Fallback, Catalyst Auto-Fallback, and On-Demand Safety Scheduler for DTPF

local Hardware = require("lib.hardware")
local RecipesDB = require("lib.recipes_db")

local Scheduler = {}

local MAX_CHANNELS = 64
local MAX_LOG_EVENTS = 64
local MAX_RATE_SAMPLES = 24
local MAX_RATE_KEYS = 96

local TIER_BY_INDEX = {}
local TIER_BY_CODE = {}
for i = 1, #RecipesDB.CATALYST_TIERS do
    local t = RecipesDB.CATALYST_TIERS[i]
    TIER_BY_INDEX[t.index] = t
    TIER_BY_CODE[t.code] = t
end

local FAMILY_BY_ID = RecipesDB.BY_ID or {}
if not next(FAMILY_BY_ID) then
    for i = 1, #RecipesDB.FAMILIES do
        local f = RecipesDB.FAMILIES[i]
        FAMILY_BY_ID[f.id] = f
    end
end
Scheduler.FAMILY_BY_ID = FAMILY_BY_ID

local WANTED_ITEM_NAMES = {}
for i = 1, #RecipesDB.FAMILIES do
    local fam = RecipesDB.FAMILIES[i]
    if fam.primaryOutput and not fam.primaryOutput.isFluid and fam.primaryOutput.type ~= "fluid" and fam.primaryOutput.name then
        WANTED_ITEM_NAMES[fam.primaryOutput.name] = true
    end
    for m = 1, #(fam.modifiers or {}) do
        local mod = fam.modifiers[m]
        for _, td in pairs((mod and mod.tiers) or {}) do
            for k = 1, #(td.itemsIn or {}) do
                if td.itemsIn[k].name then WANTED_ITEM_NAMES[td.itemsIn[k].name] = true end
            end
            for k = 1, #(td.itemsOut or {}) do
                if td.itemsOut[k].name then WANTED_ITEM_NAMES[td.itemsOut[k].name] = true end
            end
        end
    end
end

local function updateRateTracker(trackers, key, value, nowSec)
    if not trackers or not nowSec or value == nil then return nil end
    local buf = trackers[key]
    if not buf then
        local keyCount = 0
        for _ in pairs(trackers) do
            keyCount = keyCount + 1
            if keyCount >= MAX_RATE_KEYS then return nil end
        end
        buf = {}
        trackers[key] = buf
    end
    local n = #buf
    if n == 0 or nowSec > buf[n].t then
        buf[n + 1] = { t = nowSec, v = value }
        n = n + 1
    else
        buf[n].v = value
    end
    for _ = 1, MAX_RATE_SAMPLES do
        if n <= 2 or (nowSec - buf[1].t) <= 120.0 then break end
        table.remove(buf, 1)
        n = n - 1
    end
    if n > MAX_RATE_SAMPLES then
        table.remove(buf, 1)
        n = n - 1
    end
    if n < 2 then return nil end
    local dt = buf[n].t - buf[1].t
    if dt < 1.0 then return nil end
    return ((buf[n].v - buf[1].v) / dt) * 60.0
end

-- Default loop guards and target thresholds
local DEFAULT_RECIPE_PRESETS = {
    molten_neutronium = { enabled = true, target = 25000000000 },
    molten_cosmic_neutronium = { enabled = true, target = 5000000000, modifierIndex = 2 }, -- Comb + Circuit 1
    molten_bedrockium = { enabled = true, target = 25000000000 },
    molten_hypogen = {
        enabled = true,
        target = 350000000,
        modifierIndex = 1, -- Hypervisor Matrix
        guardKey = "fluid:molten.quantum",
        guardMin = 1000000,
    },
    molten_chromatic_glass = { enabled = false, target = 500000000 },
    molten_spacetime = {
        enabled = true,
        target = 500000000,
        modifierIndex = 1, -- Hypervisor Matrix (576L)
        guardKey = "fluid:dimensionallytranscendentresidue",
        guardMin = 10000000,
    },
    raw_tesseract = { enabled = true, target = 4000000 },
    quantum_anomaly = {
        enabled = true,
        target = 50000,
        modifierIndex = 1, -- Stable Boson + Molten Tritanium (1x -> 4x Loop)
        guardKey = "item:miscutils:MU-metaitem.01:32105", -- Keep >= 64 seed anomalies
        guardMin = 64,
    },
    celestial_tungsten = {
        enabled = true,
        target = 20000000000,
        tierOverride = 5,
        outputIndex = 2, -- Track Molten Transcendent Metal (Extracted) < 20B L
        guardKey = "item:gregtech:gt.metaitem.01:32415", -- Guard Raw Tesseract loop >= 10,000
        guardMin = 10000,
    },
    molten_shirabon = {
        enabled = true,
        target = 1000000,
        guardKey = "fluid:molten.spacetime",
        guardMin = 1000000,
    },
    molten_space_loop = {
        enabled = false,
        target = 50000000,
        tierOverride = 5,
        guardKey = "fluid:molten.spacetime",
        guardMin = 1000000,
    },
    molten_time_loop = {
        enabled = false,
        target = 50000000,
        tierOverride = 5,
        guardKey = "fluid:molten.spacetime",
        guardMin = 1000000,
    },
    molten_infinity = {
        enabled = false, -- Default Forever Fallback recipe
        target = 50000000000,
        modifierIndex = 3, -- Infinity Comb + Catalyst Dust (64x Batch)
        outputIndex = 1,
    },
}

local function normalizePriorities(cfg)
    local indexed = {}
    for i = 1, #RecipesDB.FAMILIES do
        local fam = RecipesDB.FAMILIES[i]
        local rc = cfg.recipes[fam.id]
        indexed[i] = { id = fam.id, prio = tonumber(rc.priority) or i, base = i }
    end
    table.sort(indexed, function(a, b)
        if a.prio ~= b.prio then return a.prio < b.prio end
        return a.base < b.base
    end)
    for i = 1, #indexed do
        cfg.recipes[indexed[i].id].priority = i
    end
end

-- Return legal catalyst tier indices (1..5) for a modifier, or { 0 } / "NONE" for catalyst-free
function Scheduler.getModifierTierInfo(modifier)
    local info = {
        usesCatalyst = false,
        indices = {},
        codes = {},
        minTier = 1,
        maxTier = 5,
    }
    if not modifier or not modifier.tiers then return info end
    if modifier.tiers["NONE"] then
        info.usesCatalyst = false
        info.codes = { "NONE" }
        info.indices = { 0 }
        return info
    end
    for idx = 1, #RecipesDB.CATALYST_TIERS do
        local ct = RecipesDB.CATALYST_TIERS[idx]
        if modifier.tiers[ct.code] then
            info.usesCatalyst = true
            info.indices[#info.indices + 1] = idx
            info.codes[#info.codes + 1] = ct.code
        end
    end
    if #info.indices > 0 then
        info.minTier = info.indices[1]
        info.maxTier = info.indices[#info.indices]
    end
    return info
end

-- Estimate un-discounted Convergence catalyst requirement for catalyst-free ("NONE") recipes
function Scheduler.estimateConvergenceCatalyst(tData, tierObj)
    local ticks = (tData and tData.durationTicks) or 200
    local eut = (tData and tData.eut) or 2000000
    local catEnergy = (tierObj and tierObj.energy) or 1073007393
    return math.max(1000, math.ceil((ticks * eut) / math.max(1, catEnergy)))
end

local function getCatalystFloor(cfg, tierCode)
    if cfg and cfg.catalystFloors and cfg.catalystFloors[tierCode] ~= nil then
        return tonumber(cfg.catalystFloors[tierCode]) or 0
    end
    return (cfg and tonumber(cfg.catalystReserveFloor)) or 100000
end

local function buildTierPreferenceOrder(allowedSet, prefIdx, allowFallback)
    local ordered = {}
    local seen = {}
    local function push(idx)
        if (not allowedSet or allowedSet[idx]) and not seen[idx] then
            seen[idx] = true
            ordered[#ordered + 1] = idx
        end
    end
    push(prefIdx)
    if allowFallback or not (allowedSet and allowedSet[prefIdx]) then
        for idx = prefIdx - 1, 1, -1 do
            push(idx)
        end
        for idx = prefIdx + 1, 5 do
            push(idx)
        end
    end
    return ordered
end

-- Resolve active modifier, tierCode, chosenTierIdx, tierData, catalystFluidName, tierInfo, meta
-- opts: { wantConvergence = bool, isFallback = bool, catOverride = number }
function Scheduler.resolveRecipe(fam, rc, cfg, stock, opts)
    if not fam or not fam.modifiers or #fam.modifiers == 0 then return nil end
    opts = opts or {}
    local modIdx = (rc and (rc.modifierIndex or rc.variantIndex)) or 1
    modIdx = math.max(1, math.min(#fam.modifiers, modIdx))
    local mod = fam.modifiers[modIdx]
    local tInfo = Scheduler.getModifierTierInfo(mod)

    local prefIdx = (cfg and cfg.defaultCatalystTier) or 4
    if opts.catOverride and opts.catOverride >= 1 and opts.catOverride <= 5 then
        prefIdx = opts.catOverride
    elseif rc and rc.catalystTier and rc.catalystTier >= 1 and rc.catalystTier <= 5 then
        prefIdx = rc.catalystTier
    end
    prefIdx = math.max(1, math.min(5, math.floor(prefIdx)))

    local allowFallback = (cfg == nil) or (cfg.catalystAutoFallback ~= false)

    if not tInfo.usesCatalyst then
        local tData = mod.tiers["NONE"]
        local convCatCode, convCatFluid, convCatAmount, convSatisfied, usedFallbackCat = nil, nil, 0, false, false
        local chosenIdx = prefIdx

        if opts.wantConvergence and tData then
            local allSet = { [1] = true, [2] = true, [3] = true, [4] = true, [5] = true }
            local ordered = buildTierPreferenceOrder(allSet, prefIdx, allowFallback)
            if not stock then
                local ct = TIER_BY_INDEX[prefIdx]
                convCatCode = ct and ct.code or "DTEC"
                convCatFluid = ct and ct.fluid or "exciteddtec"
                convCatAmount = Scheduler.estimateConvergenceCatalyst(tData, ct)
                convSatisfied = true
                chosenIdx = prefIdx
            else
                for i = 1, #ordered do
                    local idx = ordered[i]
                    local ct = TIER_BY_INDEX[idx]
                    local estNeed = Scheduler.estimateConvergenceCatalyst(tData, ct)
                    local floor = getCatalystFloor(cfg, ct.code)
                    local have = stock.fluids[ct.fluid] or 0
                    if have >= (estNeed + floor) then
                        chosenIdx = idx
                        convCatCode = ct.code
                        convCatFluid = ct.fluid
                        convCatAmount = estNeed
                        convSatisfied = true
                        usedFallbackCat = (idx ~= prefIdx)
                        break
                    end
                end
            end
        end

        local meta = {
            usesCatalyst = false,
            isNoneCat = true,
            preferredCode = (TIER_BY_INDEX[prefIdx] and TIER_BY_INDEX[prefIdx].code) or "DTEC",
            resolvedCode = "NONE",
            convCatCode = convCatCode,
            convCatIndex = chosenIdx,
            convCatAmount = convCatAmount,
            convSatisfied = convSatisfied,
            usedFallbackCat = usedFallbackCat,
        }
        return mod, "NONE", chosenIdx, tData, convCatFluid, tInfo, meta
    end

    -- Standard Catalyst recipe
    local allowedSet = {}
    for i = 1, #tInfo.indices do
        allowedSet[tInfo.indices[i]] = true
    end
    local ordered = buildTierPreferenceOrder(allowedSet, prefIdx, allowFallback)
    local primaryIdx = ordered[1] or tInfo.indices[1] or 4
    local chosenIdx = primaryIdx
    local usedFallbackCat = false

    if stock and allowFallback then
        for i = 1, #ordered do
            local idx = ordered[i]
            local ct = TIER_BY_INDEX[idx]
            local td = ct and mod.tiers[ct.code]
            local catNeed = (td and td.catalystAmount) or 1000
            local floor = getCatalystFloor(cfg, ct.code)
            local have = (ct and stock.fluids[ct.fluid]) or 0
            if have >= (catNeed + floor) then
                chosenIdx = idx
                usedFallbackCat = (idx ~= primaryIdx)
                break
            end
        end
    end

    local ct = TIER_BY_INDEX[chosenIdx]
    local tCode = (ct and ct.code) or "DTEC"
    local tData = mod.tiers[tCode]
    local catFluid = (ct and ct.fluid) or "exciteddtec"
    local meta = {
        usesCatalyst = true,
        isNoneCat = false,
        preferredCode = (TIER_BY_INDEX[primaryIdx] and TIER_BY_INDEX[primaryIdx].code) or tCode,
        resolvedCode = tCode,
        convCatCode = tCode,
        convCatIndex = chosenIdx,
        convCatAmount = (tData and tData.catalystAmount) or 1000,
        convSatisfied = true,
        usedFallbackCat = usedFallbackCat,
    }
    return mod, tCode, chosenIdx, tData, catFluid, tInfo, meta
end

-- Build selectable input reserve guard candidates for a tierData
function Scheduler.getGuardCandidates(tierData)
    local list = { { key = "none", label = "None" } }
    if not tierData then return list end
    for i = 1, #(tierData.fluidsIn or {}) do
        local f = tierData.fluidsIn[i]
        list[#list + 1] = {
            key = "fluid:" .. f.name,
            label = f.label or f.name,
            isFluid = true,
            minBatch = f.amount or 144,
        }
    end
    for i = 1, #(tierData.itemsIn or {}) do
        local it = tierData.itemsIn[i]
        if not it.nonConsumed and (it.amount or 0) > 0 then
            local k = string.format("item:%s:%d", it.name, it.damage or 0)
            list[#list + 1] = {
                key = k,
                label = it.label or it.name,
                isFluid = false,
                minBatch = it.amount or 1,
            }
        end
    end
    return list
end

-- Build all outputs of a tierData so the user can choose which output stock is tracked
function Scheduler.getOutputCandidates(tierData, family)
    local outs = {}
    if tierData then
        for i = 1, #(tierData.fluidsOut or {}) do
            local fo = tierData.fluidsOut[i]
            outs[#outs + 1] = {
                isFluid = true,
                name = fo.name,
                damage = 0,
                amount = fo.amount,
                label = fo.label or fo.name,
            }
        end
        if family and family.id == "celestial_tungsten" then
            outs[#outs + 1] = {
                isFluid = true,
                name = "molten.transcendentmetal",
                damage = 0,
                amount = 55296,
                label = "Molten Transcendent Metal",
            }
        elseif family and family.id == "astral_titanium_quantum" then
            outs[#outs + 1] = {
                isFluid = true,
                name = "molten.astraltitanium",
                damage = 0,
                amount = 5184,
                label = "Molten Astral Titanium",
            }
        end
        for i = 1, #(tierData.itemsOut or {}) do
            local io = tierData.itemsOut[i]
            outs[#outs + 1] = {
                isFluid = false,
                name = io.name,
                damage = io.damage or 0,
                amount = io.amount,
                label = io.label or io.name,
            }
        end
    end
    if #outs == 0 and family and family.primaryOutput then
        local po = family.primaryOutput
        outs[1] = {
            isFluid = (po.type == "fluid") or (po.isFluid == true),
            name = po.name,
            damage = po.damage or 0,
            amount = 1,
            label = po.label or po.name,
        }
    end
    return outs
end

-- Move a recipe up (delta < 0) or down (delta > 0) in priority order
function Scheduler.moveRecipePriority(cfg, familyId, delta, enabledOnly)
    normalizePriorities(cfg)
    if delta == "top" then
        if not cfg.recipes[familyId] then return false end
        cfg.recipes[familyId].priority = 0
        normalizePriorities(cfg)
        return true
    elseif delta == "bottom" then
        if not cfg.recipes[familyId] then return false end
        cfg.recipes[familyId].priority = 99999
        normalizePriorities(cfg)
        return true
    end

    local list = {}
    for i = 1, #RecipesDB.FAMILIES do
        local fam = RecipesDB.FAMILIES[i]
        local rc = cfg.recipes[fam.id]
        if (not enabledOnly) or rc.enabled or fam.id == familyId then
            list[#list + 1] = { id = fam.id, prio = rc.priority }
        end
    end
    table.sort(list, function(a, b) return a.prio < b.prio end)

    local pos = nil
    for i = 1, #list do
        if list[i].id == familyId then pos = i break end
    end
    if not pos then return false end

    local targetPos = pos + (delta < 0 and -1 or 1)
    if targetPos < 1 or targetPos > #list then return false end

    local aId = list[pos].id
    local bId = list[targetPos].id
    local aPrio = cfg.recipes[aId].priority
    cfg.recipes[aId].priority = cfg.recipes[bId].priority
    cfg.recipes[bId].priority = aPrio
    normalizePriorities(cfg)
    return true
end

-- Keep structured `cfg.subnets` synchronized with flat runtime fields
function Scheduler.syncSubnetsStruct(cfg)
    if not cfg then return end
    cfg.subnets = cfg.subnets or {}
    cfg.subnets.passive = cfg.subnets.passive or {}
    cfg.subnets.passive.interfaceAddr = cfg.stockNetAddr
    cfg.subnets.passive.transposerSide = cfg.stockTransposerSide or 1
    cfg.subnets.onDemand = cfg.subnets.onDemand or {}
    cfg.subnets.onDemand.interfaceAddr = cfg.onDemandNetAddr
    cfg.subnets.onDemand.transposerSide = cfg.odTransposerSide or 0
    cfg.subnets.transposer = cfg.subnets.transposer or {}
    cfg.subnets.transposer.address = cfg.transposerAddr
    cfg.subnets.transposer.enabled = (cfg.transposerEnabled ~= false)
    cfg.subnets.transposer.chunkLiters = cfg.transposerChunkLiters or 5120
    cfg.subnets.transposer.autoFlushPolls = math.max(0, math.floor(tonumber(cfg.odAutoFlushPolls) or 0))
end

-- Compact DTPF-room AE2 Level Maintainer presets (`id|type|name|damage|label|target|batch`)
local DEFAULT_MAINT_SPEC = [[
cat_dtcc|fluid|exciteddtcc|0|Excited Dimensionally Transcendent Crude Catalyst|10000000|1000000
cat_dtpc|fluid|exciteddtpc|0|Excited Dimensionally Transcendent Prosaic Catalyst|1000000|1000000
cat_dtrc|fluid|exciteddtrc|0|Excited Dimensionally Transcendent Resplendent Catalyst|20000000|5000000
cat_dtec|fluid|exciteddtec|0|Excited Dimensionally Transcendent Exotic Catalyst|1000000000|200000000
cat_dtsc|fluid|exciteddtsc|0|Excited Dimensionally Transcendent Stellar Catalyst|50000000|25000000
inf_cat|item|Avaritia:Resource|5|Infinity Catalyst|100000|100000
m_quantum|fluid|molten.quantum|0|Molten Quantum|4000000|4000000
m_steel|fluid|molten.steel|0|Molten Steel|400000000|300000000
ender_q|item|supersolarpanel:enderquantumcomponent|0|Ender-Quantum Component|4096|2048
en_tess|item|gregtech:gt.metaitem.01|32417|Energised Tesseract|10000|5000
m_pma|fluid|molten.precious metals alloy|0|Molten Precious Metals Alloy|10000000|10000000
m_ogan|fluid|molten.metastable oganesson|0|Molten Metastable Oganesson|10000000|10000000
cn_blk|item|Avaritia:Resource_Block|0|Cosmic Neutronium Block|1000|1000
m_titansteel|fluid|molten.titansteel|0|Molten Titansteel|10000000|10000000
m_callisto|fluid|molten.callistoice|0|Molten Callisto Ice|10000000|10000000
m_ledox|fluid|molten.ledox|0|Molten Ledox|10000000|10000000
m_tungsten|fluid|molten.tungsten|0|Molten Tungsten|10000000|10000000
cn_rod|item|gregtech:gt.metaitem.01|23982|Cosmic Neutronium Rod|40000|20000
tair_rod|item|bartworks:gt.bwMetaGeneratedstick|10106|Tairitsu Rod|40000|20000
tm_rod|item|gregtech:gt.metaitem.01|23581|Transcendent Metal Rod|10000|10000
bot_plate|item|miscutils:itemPlateBotmium|0|Botmium Plate|80000|70000
arc_screw|item|miscutils:itemScrewArcanite|0|Arcanite Screw|40000|20000
]]

-- Ensure config has valid defaults for Subnets, Global settings, Per-DTPF overrides, Channels, and all 27 Families
function Scheduler.ensureConfig(cfg)
    cfg = cfg or {}

    -- Safe first launch: default PAUSED (Read-Only Monitor) unless explicitly persisted
    if cfg.armed == nil then
        cfg.armed = false
    else
        cfg.armed = (cfg.armed == true)
    end

    cfg.pollInterval = tonumber(cfg.pollInterval) or 2.0
    cfg.globalConvMode = cfg.globalConvMode or "auto" -- "auto" | "passive_od" | "ondemand" | "always" | "off"
    cfg.fallbackConvMode = cfg.fallbackConvMode or "global" -- "global" | "on" | "off"
    if cfg.onDemandConvMode == nil then
        cfg.onDemandConvMode = (cfg.onDemandConvergence == false) and "off" or "auto_safe"
    end
    if cfg.pausePassivesOnOD == nil then
        cfg.pausePassivesOnOD = true
    end
    if type(cfg.subnets) == "table" and type(cfg.subnets.transposer) == "table" and cfg.subnets.transposer.autoFlushPolls ~= nil then
        cfg.odAutoFlushPolls = tonumber(cfg.subnets.transposer.autoFlushPolls)
    elseif cfg.odAutoFlushPolls == nil and cfg.odAutoFlushStall == true then
        cfg.odAutoFlushPolls = 15
    end
    cfg.odAutoFlushPolls = math.max(0, math.floor(tonumber(cfg.odAutoFlushPolls) or 0))
    cfg.defaultCatalystTier = math.max(1, math.min(5, math.floor(tonumber(cfg.defaultCatalystTier or cfg.onDemandCatalystTier or 4))))
    if cfg.catalystAutoFallback == nil then
        cfg.catalystAutoFallback = true
    end
    if cfg.uniformNcSubnet == nil then
        cfg.uniformNcSubnet = true
    end
    cfg.dtrReserveFloor = tonumber(cfg.dtrReserveFloor) or 10000000

    cfg.catalystFloors = cfg.catalystFloors or {}
    local legacyCatFloor = tonumber(cfg.catalystReserveFloor) or 100000
    for i = 1, #RecipesDB.CATALYST_TIERS do
        local code = RecipesDB.CATALYST_TIERS[i].code
        cfg.catalystFloors[code] = tonumber(cfg.catalystFloors[code]) or legacyCatFloor
    end

    if cfg.fallbackEnabled == nil then
        cfg.fallbackEnabled = true
    end
    cfg.fallbackFamilyId = cfg.fallbackFamilyId or "molten_infinity"
    if cfg.allowParallelSameRecipe == nil then
        cfg.allowParallelSameRecipe = false
    end
    if cfg.powerAwareAssign == nil then
        cfg.powerAwareAssign = true
    else
        cfg.powerAwareAssign = (cfg.powerAwareAssign == true)
    end
    cfg.maintEnabled = (cfg.maintEnabled == true)
    cfg.maintFreeCpus = math.max(0, math.floor(tonumber(cfg.maintFreeCpus) or 2))
    cfg.maintPollSec = math.max(5, math.floor(tonumber(cfg.maintPollSec) or 15))
    cfg.mainnetAddr = cfg.mainnetAddr or "auto"
    if type(cfg.maintRules) ~= "table" then
        cfg.maintRules = {}
        for line in DEFAULT_MAINT_SPEC:gmatch("[^\r\n]+") do
            local id, rType, name, dmg, lbl, tgt, bat = line:match("^([^|]+)|([^|]+)|([^|]+)|(%d+)|([^|]+)|(%d+)|(%d+)$")
            if id then
                cfg.maintRules[#cfg.maintRules + 1] = {
                    id = id,
                    type = rType,
                    name = name,
                    damage = tonumber(dmg) or 0,
                    label = lbl,
                    target = tonumber(tgt) or 1,
                    batch = tonumber(bat) or 1,
                    mode = "auto",
                }
            end
        end
    else
        local cleanRules = {}
        for i = 1, #cfg.maintRules do
            local r = cfg.maintRules[i]
            if type(r) == "table" and type(r.name) == "string" and r.name ~= "" then
                local rMode = r.mode
                if rMode ~= "auto" and rMode ~= "always" and rMode ~= "off" then
                    rMode = "auto"
                end
                cleanRules[#cleanRules + 1] = {
                    id = r.id or ("rule_" .. tostring(#cleanRules + 1)),
                    type = (r.type == "fluid") and "fluid" or "item",
                    name = r.name,
                    damage = math.max(0, math.floor(tonumber(r.damage) or 0)),
                    label = tostring(r.label or r.name),
                    target = math.max(1, math.floor(tonumber(r.target) or 1)),
                    batch = math.max(1, math.floor(tonumber(r.batch) or 1)),
                    mode = rMode,
                }
            end
        end
        cfg.maintRules = cleanRules
    end
    if cfg.uiAnimations == nil then
        cfg.uiAnimations = true
    else
        cfg.uiAnimations = (cfg.uiAnimations == true)
    end
    if type(cfg.authorName) ~= "string" or #cfg.authorName == 0 then
        cfg.authorName = "StankCIty"
    end
    if cfg.coilDisplayMode == "temp" then
        cfg.coilDisplayMode = "temp"
    else
        cfg.coilDisplayMode = "name"
    end
    if cfg.logLevel ~= "quiet" and cfg.logLevel ~= "normal" and cfg.logLevel ~= "raw" then
        cfg.logLevel = "normal"
    end

    local hasExplicitPassiveSide = (type(cfg.subnets) == "table" and type(cfg.subnets.passive) == "table" and cfg.subnets.passive.transposerSide ~= nil)
        or (cfg.stockTransposerSide ~= nil)
    local hasExplicitOdSide = (type(cfg.subnets) == "table" and type(cfg.subnets.onDemand) == "table" and cfg.subnets.onDemand.transposerSide ~= nil)
        or (cfg.odTransposerSide ~= nil)
    cfg._hasExplicitTpSides = hasExplicitPassiveSide or hasExplicitOdSide

    -- Hydrate flat subnet + Transposer fields from optional structured `cfg.subnets`
    if type(cfg.subnets) == "table" then
        if type(cfg.subnets.passive) == "table" then
            if cfg.subnets.passive.interfaceAddr ~= nil then
                cfg.stockNetAddr = cfg.subnets.passive.interfaceAddr
            end
            if cfg.subnets.passive.transposerSide ~= nil then
                cfg.stockTransposerSide = tonumber(cfg.subnets.passive.transposerSide)
            end
        end
        if type(cfg.subnets.onDemand) == "table" then
            if cfg.subnets.onDemand.interfaceAddr ~= nil then
                cfg.onDemandNetAddr = cfg.subnets.onDemand.interfaceAddr
            end
            if cfg.subnets.onDemand.transposerSide ~= nil then
                cfg.odTransposerSide = tonumber(cfg.subnets.onDemand.transposerSide)
            end
        end
        if type(cfg.subnets.transposer) == "table" then
            if cfg.subnets.transposer.address ~= nil then
                cfg.transposerAddr = cfg.subnets.transposer.address
            end
            if cfg.subnets.transposer.enabled ~= nil then
                cfg.transposerEnabled = (cfg.subnets.transposer.enabled ~= false)
            end
            if cfg.subnets.transposer.chunkLiters ~= nil then
                cfg.transposerChunkLiters = tonumber(cfg.subnets.transposer.chunkLiters)
            end
        end
    end

    cfg.stockNetAddr = cfg.stockNetAddr or nil
    cfg.onDemandNetAddr = cfg.onDemandNetAddr or nil
    cfg.transposerAddr = cfg.transposerAddr or nil
    cfg.stockTransposerSide = math.max(0, math.min(5, math.floor(tonumber(cfg.stockTransposerSide) or 1)))
    cfg.odTransposerSide = math.max(0, math.min(5, math.floor(tonumber(cfg.odTransposerSide) or 0)))
    if cfg.transposerEnabled == nil then
        cfg.transposerEnabled = true
    else
        cfg.transposerEnabled = (cfg.transposerEnabled == true)
    end
    cfg.transposerChunkLiters = math.max(100, math.floor(tonumber(cfg.transposerChunkLiters) or 5120))

    cfg.channels = cfg.channels or {}
    local hasExplicitChannels = (#cfg.channels > 0)
    cfg.dtpfs = cfg.dtpfs or {}
    if #cfg.dtpfs == 0 and type(cfg.dtpfUnits) == "table" then
        cfg.dtpfs = cfg.dtpfUnits
    end
    cfg.recipes = cfg.recipes or {}

    -- Normalize existing DTPF override fields and hydrate inline per-DTPF passive endpoints into channels
    local validRoles = {
        auto = true,
        passive_only = true,
        fallback_only = true,
        od_only = true,
        pinned = true,
        pinned_loop = true,
    }
    for i = 1, #cfg.dtpfs do
        local d = cfg.dtpfs[i]
        if not d.address and d.controllerAddr then
            d.address = d.controllerAddr
        end
        if type(d.coords) == "table" then
            d.x = d.x or d.coords.x
            d.y = d.y or d.coords.y
            d.z = d.z or d.coords.z
        end
        if d.enabled == nil then d.enabled = true end
        if d.convOverride == nil then
            if d.convMode == "on" then d.convOverride = "always"
            elseif d.convMode == "off" then d.convOverride = "off"
            elseif d.convMode == "ondemand" then d.convOverride = "ondemand"
            else d.convOverride = "global" end
        end
        d.catOverride = math.max(0, math.min(5, math.floor(tonumber(d.catOverride) or 0)))
        if not validRoles[d.roleOverride] then
            d.roleOverride = "auto"
        end
        if d.pinnedFamilyId ~= nil and not FAMILY_BY_ID[d.pinnedFamilyId] then
            d.pinnedFamilyId = nil
        end
        if (d.roleOverride == "pinned" or d.roleOverride == "pinned_loop") and not d.pinnedFamilyId then
            d.pinnedFamilyId = RecipesDB.FAMILIES[1] and RecipesDB.FAMILIES[1].id or "molten_neutronium"
        end
        d.channelId = d.channelId or ((d.passiveHatchAddr or d.passiveBusAddr) and ("ch" .. tostring(i)) or "ch1")
        d.odNetAddr = d.odNetAddr or "global"

        if d.passiveHatchAddr or d.passiveBusAddr then
            local chMatch = nil
            for k = 1, #cfg.channels do
                if cfg.channels[k].id == d.channelId then
                    chMatch = cfg.channels[k]
                    break
                end
            end
            if not chMatch then
                chMatch = {
                    id = d.channelId,
                    name = "Passive Ch " .. tostring(i) .. " (Hatch/Bus)",
                    mode = "hatch_pair",
                    hatchAddr = d.passiveHatchAddr,
                    busAddr = d.passiveBusAddr,
                    shareOnDemand = (d.shareOnDemand ~= false),
                    enabled = (d.channelEnabled ~= false),
                }
                cfg.channels[#cfg.channels + 1] = chMatch
            elseif not hasExplicitChannels then
                if d.passiveHatchAddr then chMatch.hatchAddr = d.passiveHatchAddr end
                if d.passiveBusAddr then chMatch.busAddr = d.passiveBusAddr end
                if d.shareOnDemand ~= nil then chMatch.shareOnDemand = (d.shareOnDemand ~= false) end
                if d.channelEnabled ~= nil then chMatch.enabled = (d.channelEnabled ~= false) end
            end
        end
    end

    for i = 1, #RecipesDB.FAMILIES do
        local fam = RecipesDB.FAMILIES[i]
        local rc = cfg.recipes[fam.id]
            or (fam.id == "meteoric_iron_rock" and cfg.recipes["dark_matter"])
            or {}
        local preset = DEFAULT_RECIPE_PRESETS[fam.id] or {}

        local modIdx = rc.modifierIndex or rc.variantIndex or preset.modifierIndex or 1
        if not fam.modifiers[modIdx] then
            modIdx = 1
        end
        rc.modifierIndex = modIdx
        rc.variantIndex = modIdx

        if rc.catalystTier == nil then
            rc.catalystTier = (preset.tierOverride ~= nil) and preset.tierOverride or 0
        else
            rc.catalystTier = math.max(0, math.min(5, math.floor(tonumber(rc.catalystTier) or 0)))
        end

        if rc.enabled == nil then
            rc.enabled = preset.enabled or false
        end
        rc.forever = (rc.forever == true)
        local poIsFluid = fam.primaryOutput and (fam.primaryOutput.type == "fluid" or fam.primaryOutput.isFluid)
        if rc.target == nil then
            rc.target = preset.target or (poIsFluid and 100000000 or 100000)
        end
        rc.outputIndex = rc.outputIndex or preset.outputIndex or 1
        local gKey = rc.guardKey or preset.guardKey or "none"
        if gKey == "fluid:molten.time" then
            gKey = "fluid:temporalfluid"
        elseif gKey == "fluid:molten.space" then
            gKey = "fluid:spatialfluid"
        elseif gKey == "fluid:stargate" then
            gKey = "fluid:sgcrystalslurry"
        end
        rc.guardKey = gKey
        rc.guardMin = rc.guardMin or preset.guardMin or 0
        rc.convMode = rc.convMode or "global" -- "global" | "on" | "below_tgt" | "force" | "off"
        rc.maxDtpfs = math.max(0, math.floor(tonumber(rc.maxDtpfs) or 0))
        rc.priority = rc.priority or i

        cfg.recipes[fam.id] = rc
    end

    normalizePriorities(cfg)
    Scheduler.syncSubnetsStruct(cfg)
    return cfg
end

local function buildSortedOdPools(nets, stockNetAddr)
    local odNets = {}
    for i = 1, #(nets or {}) do
        local n = nets[i]
        if n and n.address and n.address ~= stockNetAddr then
            odNets[#odNets + 1] = n
        end
    end
    table.sort(odNets, function(a, b)
        local ac = (a.x ~= nil and a.z ~= nil)
        local bc = (b.x ~= nil and b.z ~= nil)
        if ac and bc then
            if a.z ~= b.z then return a.z < b.z end
            if a.x ~= b.x then return a.x < b.x end
            if (a.y or 0) ~= (b.y or 0) then return (a.y or 0) < (b.y or 0) end
        elseif ac ~= bc then
            return ac
        end
        return a.address < b.address
    end)
    local addrs, coords = {}, {}
    for i = 1, #odNets do
        local n = odNets[i]
        addrs[#addrs + 1] = n.address
        if n.x ~= nil and n.z ~= nil then
            coords[n.address] = { x = n.x, y = n.y or 0, z = n.z }
        end
    end
    return odNets, addrs, coords
end

-- Pair each DTPF 1:1 with its nearest distinct On-Demand subnet interface
function Scheduler.pairPerDtpfOnDemand(cfg, nets)
    if not cfg or not cfg.dtpfs then return 0 end
    local _, odAddrs, odCoords = buildSortedOdPools(nets, cfg.stockNetAddr)
    local usedOd = {}
    local paired = 0
    for i = 1, #cfg.dtpfs do
        local d = cfg.dtpfs[i]
        local pick = Hardware.pickNearestAddress(d, odAddrs, odCoords, usedOd)
        if pick then
            d.odNetAddr = pick
            paired = paired + 1
        else
            d.odNetAddr = "global"
        end
    end
    return paired
end

-- Auto-bind hardware on startup or Rescan without dropping user per-DTPF overrides
function Scheduler.syncHardware(cfg)
    Hardware.discoverWorkers()
    local nets = Hardware.discoverAENetworks()
    if #nets > 0 then
        local validStock = false
        local validOD = false
        for i = 1, #nets do
            if nets[i].address == cfg.stockNetAddr then validStock = true end
            if nets[i].address == cfg.onDemandNetAddr then validOD = true end
        end
        if not validStock then
            cfg.stockNetAddr = nets[1].address
        end
        if not validOD and #nets >= 2 then
            for i = #nets, 1, -1 do
                if nets[i].address ~= cfg.stockNetAddr then
                    cfg.onDemandNetAddr = nets[i].address
                    break
                end
            end
        end
    end

    local transposers = Hardware.discoverTransposers()
    if #transposers > 0 and cfg.transposerAddr ~= "none" then
        local validTp = nil
        for i = 1, #transposers do
            if transposers[i].address == cfg.transposerAddr then
                validTp = transposers[i]
                break
            end
        end
        if not validTp then
            validTp = transposers[1]
            cfg.transposerAddr = validTp.address
        end
        if (not cfg._hasExplicitTpSides) and validTp.tankSides and #validTp.tankSides == 2 then
            local s1, s2 = validTp.tankSides[1], validTp.tankSides[2]
            if validTp.filledSide == s2 then
                cfg.stockTransposerSide, cfg.odTransposerSide = s2, s1
            else
                cfg.stockTransposerSide, cfg.odTransposerSide = s1, s2
            end
        end
    end

    local _, odAddrs, odCoords = buildSortedOdPools(nets, cfg.stockNetAddr)
    local validNonStock = {}
    for i = 1, #odAddrs do
        validNonStock[odAddrs[i]] = true
    end

    local discoveredDTPFs = Hardware.discoverDTPFs()
    local ep = Hardware.discoverPassiveEndpoints()
    if #nets >= 2 then
        local sNet = nil
        for i = 1, #nets do
            if nets[i].address == cfg.stockNetAddr then
                sNet = nets[i]
                break
            end
        end
        local bestTotal = (nets[1].itemTypes or 0) + (nets[1].fluidTypes or 0)
        local stockTotal = sNet and ((sNet.itemTypes or 0) + (sNet.fluidTypes or 0)) or 0
        if sNet and stockTotal <= 6 and bestTotal >= 15 then
            ep.warnings[#ep.warnings + 1] = "Stock AE2 Interface has <=6 items/fluids while another network has many - point Stock Interface at unfiltered Main Net, NOT the filtered Passive/OD subnet!"
        end
    end

    local placeholderReplaced = false
    if #cfg.channels == 1
        and cfg.channels[1].mode == "storage_bus"
        and not cfg.channels[1].itemStorageAddr
        and not cfg.channels[1].fluidStorageAddr
        and (#ep.hatches > 0 or #ep.buses > 0 or #ep.itemStorageBuses > 0 or #ep.fluidStorageBuses > 0) then
        cfg.channels = {}
        placeholderReplaced = true
    end

    if #cfg.channels == 0 then
        local chIdx = 1
        local sbCount = math.max(#ep.itemStorageBuses, #ep.fluidStorageBuses)
        for i = 1, sbCount do
            local isb = ep.itemStorageBuses[i]
            local fsb = ep.fluidStorageBuses[i]
            cfg.channels[#cfg.channels + 1] = {
                id = "ch" .. tostring(chIdx),
                name = "Passive Ch " .. tostring(chIdx) .. " (StorageBus)",
                mode = "storage_bus",
                itemStorageAddr = isb and isb.address or nil,
                itemStorageSide = (isb and isb.sides[1] and isb.sides[1].side) or 0,
                fluidStorageAddr = fsb and fsb.address or nil,
                fluidStorageSide = (fsb and fsb.sides[1] and fsb.sides[1].side) or 0,
                shareOnDemand = true,
                enabled = true,
            }
            chIdx = chIdx + 1
        end
        local usedHatches, usedBuses = {}, {}
        local pairCount = math.max(#ep.hatches, #ep.buses)
        for i = 1, pairCount do
            local refDtpf = discoveredDTPFs[i]
            local hAddr = Hardware.pickNearestAddress(refDtpf, ep.hatches, ep.hatchCoords, usedHatches)
            local bAddr = Hardware.pickNearestAddress(refDtpf, ep.buses, ep.busCoords, usedBuses)
            cfg.channels[#cfg.channels + 1] = {
                id = "ch" .. tostring(chIdx),
                name = "Passive Ch " .. tostring(chIdx) .. " (Hatch/Bus)",
                mode = "hatch_pair",
                hatchAddr = hAddr,
                busAddr = bAddr,
                shareOnDemand = true,
                enabled = true,
            }
            chIdx = chIdx + 1
        end
        if #cfg.channels == 0 then
            cfg.channels[1] = {
                id = "ch1",
                name = "Passive Ch 1",
                mode = "storage_bus",
                shareOnDemand = true,
                enabled = true,
            }
        end
    else
        local usedItemSB, usedFluidSB, usedHatches, usedBuses = {}, {}, {}, {}
        for i = 1, #cfg.channels do
            local ch = cfg.channels[i]
            if ch.itemStorageAddr then usedItemSB[ch.itemStorageAddr] = true end
            if ch.fluidStorageAddr then usedFluidSB[ch.fluidStorageAddr] = true end
            if ch.hatchAddr then usedHatches[ch.hatchAddr] = true end
            if ch.busAddr then usedBuses[ch.busAddr] = true end
        end

        local function takeUnusedAddr(list, usedSet, addrField)
            for k = 1, #list do
                local a = addrField and list[k][addrField] or list[k]
                if a and not usedSet[a] then
                    usedSet[a] = true
                    return list[k]
                end
            end
            return nil
        end

        local function findRefDtpfForChannel(chId, fallbackIdx)
            for k = 1, #(cfg.dtpfs or {}) do
                if cfg.dtpfs[k].channelId == chId and cfg.dtpfs[k].x and cfg.dtpfs[k].z then
                    return cfg.dtpfs[k]
                end
            end
            return discoveredDTPFs[fallbackIdx]
        end

        for i = 1, #cfg.channels do
            local ch = cfg.channels[i]
            if ch.mode == "hatch_pair" then
                local refDtpf = findRefDtpfForChannel(ch.id, i)
                if not ch.hatchAddr then
                    ch.hatchAddr = Hardware.pickNearestAddress(refDtpf, ep.hatches, ep.hatchCoords, usedHatches)
                end
                if not ch.busAddr then
                    ch.busAddr = Hardware.pickNearestAddress(refDtpf, ep.buses, ep.busCoords, usedBuses)
                end
            elseif ch.mode == "storage_bus" then
                if not ch.itemStorageAddr then
                    local pick = takeUnusedAddr(ep.itemStorageBuses, usedItemSB, "address")
                    if pick then
                        ch.itemStorageAddr = pick.address
                        ch.itemStorageSide = (pick.sides[1] and pick.sides[1].side) or 0
                    end
                end
                if not ch.fluidStorageAddr then
                    local pick = takeUnusedAddr(ep.fluidStorageBuses, usedFluidSB, "address")
                    if pick then
                        ch.fluidStorageAddr = pick.address
                        ch.fluidStorageSide = (pick.sides[1] and pick.sides[1].side) or 0
                    end
                end
            end
        end

        local nextIdx = #cfg.channels + 1
        local maxChNum = 0
        for i = 1, #cfg.channels do
            local n = tonumber(tostring(cfg.channels[i].id):match("^ch(%d+)$"))
            if n and n > maxChNum then maxChNum = n end
        end
        nextIdx = math.max(nextIdx, maxChNum + 1)

        for _ = 1, MAX_CHANNELS do
            if #cfg.channels >= MAX_CHANNELS then break end
            local isb = takeUnusedAddr(ep.itemStorageBuses, usedItemSB, "address")
            local fsb = takeUnusedAddr(ep.fluidStorageBuses, usedFluidSB, "address")
            if not isb and not fsb then break end
            cfg.channels[#cfg.channels + 1] = {
                id = "ch" .. tostring(nextIdx),
                name = "Passive Ch " .. tostring(nextIdx) .. " (StorageBus)",
                mode = "storage_bus",
                itemStorageAddr = isb and isb.address or nil,
                itemStorageSide = (isb and isb.sides[1] and isb.sides[1].side) or 0,
                fluidStorageAddr = fsb and fsb.address or nil,
                fluidStorageSide = (fsb and fsb.sides[1] and fsb.sides[1].side) or 0,
                shareOnDemand = true,
                enabled = true,
            }
            nextIdx = nextIdx + 1
        end
        for _ = 1, MAX_CHANNELS do
            if #cfg.channels >= MAX_CHANNELS then break end
            local refDtpf = discoveredDTPFs[#cfg.channels + 1]
            local h = Hardware.pickNearestAddress(refDtpf, ep.hatches, ep.hatchCoords, usedHatches)
            local b = Hardware.pickNearestAddress(refDtpf, ep.buses, ep.busCoords, usedBuses)
            if not h and not b then break end
            cfg.channels[#cfg.channels + 1] = {
                id = "ch" .. tostring(nextIdx),
                name = "Passive Ch " .. tostring(nextIdx) .. " (Hatch/Bus)",
                mode = "hatch_pair",
                hatchAddr = h,
                busAddr = b,
                shareOnDemand = true,
                enabled = true,
            }
            nextIdx = nextIdx + 1
        end
    end

    local validChIds = {}
    for i = 1, #cfg.channels do
        validChIds[cfg.channels[i].id] = true
    end

    local existingByAddr = {}
    for i = 1, #cfg.dtpfs do
        existingByAddr[cfg.dtpfs[i].address] = cfg.dtpfs[i]
    end
    local mergedDTPFs = {}
    for i = 1, #discoveredDTPFs do
        local d = discoveredDTPFs[i]
        local prev = existingByAddr[d.address] or {}
        local convOv = prev.convOverride
        if convOv == nil then
            if prev.convMode == "on" then convOv = "always"
            elseif prev.convMode == "off" then convOv = "off"
            elseif prev.convMode == "ondemand" then convOv = "ondemand"
            else convOv = "global" end
        end
        local chId = ((not placeholderReplaced) and prev.channelId and validChIds[prev.channelId]) and prev.channelId
            or (cfg.channels[i] and cfg.channels[i].id)
            or (cfg.channels[1] and cfg.channels[1].id)
            or "ch1"
        local pinId = (prev.pinnedFamilyId and FAMILY_BY_ID[prev.pinnedFamilyId]) and prev.pinnedFamilyId or nil
        local odAddr = "global"
        if prev.odNetAddr == "none" then
            odAddr = "none"
        elseif prev.odNetAddr and validNonStock[prev.odNetAddr] then
            odAddr = prev.odNetAddr
        end
        mergedDTPFs[#mergedDTPFs + 1] = {
            address = d.address,
            name = prev.name or string.format("DTPF #%d", i),
            enabled = (prev.enabled == nil) and true or prev.enabled,
            convOverride = convOv,
            catOverride = prev.catOverride or 0,
            roleOverride = prev.roleOverride or "auto",
            pinnedFamilyId = pinId,
            channelId = chId,
            odNetAddr = odAddr,
            x = d.x or prev.x,
            y = d.y or prev.y,
            z = d.z or prev.z,
            isRemote = d.isRemote,
            workerAddr = d.workerAddr,
            dtpfProxy = d.dtpfProxy,
            gtProxy = d.gtProxy,
        }
    end
    cfg.dtpfs = mergedDTPFs

    if #odAddrs >= 2 then
        local usedOd = {}
        for i = 1, #cfg.dtpfs do
            local a = cfg.dtpfs[i].odNetAddr
            if a and a ~= "global" and a ~= "none" then
                usedOd[a] = true
            end
        end
        for i = 1, #cfg.dtpfs do
            if cfg.dtpfs[i].odNetAddr == "global" then
                local pick = Hardware.pickNearestAddress(cfg.dtpfs[i], odAddrs, odCoords, usedOd)
                if pick then
                    cfg.dtpfs[i].odNetAddr = pick
                end
            end
        end
    end

    local chById = {}
    for i = 1, #cfg.channels do
        chById[cfg.channels[i].id] = cfg.channels[i]
    end
    for i = 1, #cfg.dtpfs do
        local d = cfg.dtpfs[i]
        local ch = chById[d.channelId]
        if ch and ch.mode == "hatch_pair" then
            d.passiveHatchAddr = ch.hatchAddr
            d.passiveBusAddr = ch.busAddr
            d.shareOnDemand = (ch.shareOnDemand ~= false)
            d.channelEnabled = (ch.enabled ~= false)
        end
    end
    Scheduler.syncSubnetsStruct(cfg)

    return nets, ep
end

function Scheduler.getOutputStock(stock, outDesc)
    if not outDesc then return 0 end
    if outDesc.isFluid or outDesc.type == "fluid" then
        return stock.fluids[outDesc.name] or 0
    else
        local key = outDesc.name .. ":" .. tostring(outDesc.damage or 0)
        return stock.items[key] or 0
    end
end

function Scheduler.getGuardKeyStock(stock, guardKey)
    if not guardKey or guardKey == "none" then return math.huge end
    local fName = guardKey:match("^fluid:(.+)$")
    if fName then
        return stock.fluids[fName] or 0
    end
    local iKey = guardKey:match("^item:(.+)$")
    if iKey then
        return stock.items[iKey] or 0
    end
    return 0
end

-- Check whether all recipe inputs, catalyst floor, global DTR floor, per-recipe guard, and coil heat are satisfied
function Scheduler.checkRecipeRunnable(cfg, stock, fam, rc, isCurrentlyRunning, isFallback, opts)
    opts = opts or {}
    local mod, tCode, tIdx, tData, catFluidName, tInfo, meta = Scheduler.resolveRecipe(fam, rc, cfg, stock, {
        wantConvergence = opts.wantConvergence,
        isFallback = isFallback,
        catOverride = opts.catOverride,
    })
    if not mod or not tData then
        return false, "No recipe data", nil, meta
    end

    -- 1. Check Catalyst availability + Reserve Floor for standard catalyst recipes
    if tInfo.usesCatalyst and catFluidName then
        local catNeed = tData.catalystAmount or 1000
        local floor = getCatalystFloor(cfg, tCode)
        local catHave = stock.fluids[catFluidName] or 0
        if catHave < (catNeed + floor) then
            return false, string.format("Low %s", tCode), catFluidName, meta
        end
    end

    -- 2. Check Coil Heat eligibility (if caller supplied maxCoilHeat from live DTPFs)
    if opts.maxCoilHeat and (tData.coilHeat or 0) > opts.maxCoilHeat then
        return false, string.format("Coil < %dK", tData.coilHeat), catFluidName, meta
    end

    -- 3. Check Global DTR Reserve Floor for any DTR-consuming recipe
    if (tData.dtrIn or 0) > 0 and (cfg.dtrReserveFloor or 0) > 0 then
        local dtrHave = stock.fluids["dimensionallytranscendentresidue"] or 0
        local threshold = isCurrentlyRunning and math.floor(cfg.dtrReserveFloor * 0.98) or cfg.dtrReserveFloor
        if dtrHave < (threshold + tData.dtrIn) then
            return false, "DTR < Floor", catFluidName, meta
        end
    end

    -- 4. Check Per-Recipe Loop Guard / Input Reserve Floor
    if rc.guardKey and rc.guardKey ~= "none" and (rc.guardMin or 0) > 0 then
        local gHave = Scheduler.getGuardKeyStock(stock, rc.guardKey)
        local threshold = isCurrentlyRunning and math.floor(rc.guardMin * 0.98) or rc.guardMin
        if gHave < threshold then
            local shortName = rc.guardKey:gsub("^fluid:", ""):gsub("^item:", "")
            return false, "Guard < Floor (" .. shortName .. ")", catFluidName, meta
        end
    end

    -- 5. Check every Fluid Input has at least 1 batch in stock
    for i = 1, #(tData.fluidsIn or {}) do
        local fi = tData.fluidsIn[i]
        local have = stock.fluids[fi.name] or 0
        local need = math.max(1, fi.amount or 144)
        if have < need then
            return false, "Missing " .. (fi.label or fi.name), catFluidName, meta
        end
    end

    -- 6. Check consumed Item Inputs (skipping nonConsumed items when uniformNcSubnet is enabled)
    for i = 1, #(tData.itemsIn or {}) do
        local ii = tData.itemsIn[i]
        local isNC = (ii.nonConsumed == true) or ((ii.amount or 0) == 0)
        if not (cfg.uniformNcSubnet and isNC) then
            local key = ii.name .. ":" .. tostring(ii.damage or 0)
            local have = stock.items[key] or 0
            local need = math.max(1, ii.amount or 1)
            if have < need then
                return false, "Missing " .. (ii.label or ii.name), catFluidName, meta
            end
        end
    end

    return true, "Ready", catFluidName, meta
end

-- Count how many whole batches of (fam, rc) current AE stock can support after floors/reserves
function Scheduler.countAvailableBatches(cfg, stock, fam, rc, opts)
    if not stock then return math.huge end
    opts = opts or {}
    local mod, tCode, _, tData, catFluidName, tInfo = Scheduler.resolveRecipe(fam, rc, cfg, stock, {
        wantConvergence = opts.wantConvergence,
        isFallback = opts.isFallback,
        catOverride = opts.catOverride,
    })
    if not mod or not tData then
        return 0
    end

    local isRunning = (opts.isCurrentlyRunning == true)
    local minBatches = math.huge

    if tInfo.usesCatalyst and catFluidName then
        local catNeed = math.max(1, tData.catalystAmount or 1000)
        local floor = getCatalystFloor(cfg, tCode)
        local catHave = stock.fluids[catFluidName] or 0
        minBatches = math.min(minBatches, math.floor(math.max(0, catHave - floor) / catNeed))
    end

    if (tData.dtrIn or 0) > 0 and (cfg.dtrReserveFloor or 0) > 0 then
        local dtrHave = stock.fluids["dimensionallytranscendentresidue"] or 0
        local floor = isRunning and math.floor(cfg.dtrReserveFloor * 0.98) or cfg.dtrReserveFloor
        minBatches = math.min(minBatches, math.floor(math.max(0, dtrHave - floor) / tData.dtrIn))
    end

    for i = 1, #(tData.fluidsIn or {}) do
        local fi = tData.fluidsIn[i]
        local have = stock.fluids[fi.name] or 0
        local need = math.max(1, fi.amount or 144)
        minBatches = math.min(minBatches, math.floor(have / need))
    end

    for i = 1, #(tData.itemsIn or {}) do
        local ii = tData.itemsIn[i]
        local isNC = (ii.nonConsumed == true) or ((ii.amount or 0) == 0)
        if not (cfg.uniformNcSubnet and isNC) then
            local key = ii.name .. ":" .. tostring(ii.damage or 0)
            local have = stock.items[key] or 0
            local need = math.max(1, ii.amount or 1)
            minBatches = math.min(minBatches, math.floor(have / need))
        end
    end

    return math.max(0, minBatches)
end

local function effectiveDTPFConvMode(cfg, d)
    if d and d.convOverride and d.convOverride ~= "global" then
        return d.convOverride
    end
    return (cfg and cfg.globalConvMode) or "auto"
end

-- 99%/100% hysteresis check for per-recipe "below_tgt" Convergence mode
function Scheduler.isRecipeBelowConvTarget(cfg, stock, fam, rc, prevActive)
    if not fam or not rc or not stock then return false end
    local _, _, _, tData0 = Scheduler.resolveRecipe(fam, rc, cfg, stock, { wantConvergence = false })
    local outs = Scheduler.getOutputCandidates(tData0, fam)
    local outIdx = math.max(1, math.min(#outs, rc.outputIndex or 1))
    local trackedOut = outs[outIdx] or fam.primaryOutput
    local curStock = Scheduler.getOutputStock(stock, trackedOut)
    local tgtStock = math.max(1, tonumber(rc.target) or 1)
    local thresh = prevActive and tgtStock or math.floor(tgtStock * 0.99)
    return curStock < thresh
end

-- Layered convergence evaluator combining Per-DTPF Override -> Forever Loop / Per-Recipe Policy -> Global Scope
function Scheduler.doesJobWantConvergence(cfg, jobMode, rc, dtpfConvOverride, discountPct, belowTarget)
    local discountOK = ((tonumber(discountPct) or 50) >= 49.9)
    local ov = dtpfConvOverride or "global"

    if ov == "off" or ov == "ondemand" then
        return false
    elseif ov == "always" then
        return true
    end

    if rc and rc.convMode and rc.convMode ~= "global" then
        local rMode = rc.convMode
        if rMode == "off" then
            return false
        elseif rMode == "force" then
            return true
        elseif rMode == "below_tgt" then
            return (belowTarget == true) and discountOK
        elseif rMode == "on" then
            return discountOK
        end
    end

    if jobMode == "FALLBACK" then
        if ov == "passive_od" then
            return false
        end
        local fbMode = (cfg and cfg.fallbackConvMode) or "global"
        if fbMode == "off" then
            return false
        elseif fbMode == "on" then
            return discountOK
        end
    end

    local effGlobal = (ov == "auto" and "auto")
        or (ov == "passive_od" and "passive_od")
        or (cfg and cfg.globalConvMode)
        or "auto"

    if effGlobal == "always" then
        return true
    elseif effGlobal == "auto" then
        return discountOK
    elseif effGlobal == "passive_od" then
        return (jobMode ~= "FALLBACK") and discountOK
    else -- "ondemand" or "off"
        return false
    end
end

local function pickAvailableCatalystTier(cfg, stock, prefIdx)
    prefIdx = math.max(1, math.min(5, math.floor(prefIdx or 4)))
    if not stock or not cfg or not cfg.catalystAutoFallback then
        return prefIdx
    end
    local allSet = { [1] = true, [2] = true, [3] = true, [4] = true, [5] = true }
    local ordered = buildTierPreferenceOrder(allSet, prefIdx, true)
    for i = 1, #ordered do
        local idx = ordered[i]
        local ct = TIER_BY_INDEX[idx]
        local floor = getCatalystFloor(cfg, ct.code)
        if (stock.fluids[ct.fluid] or 0) > floor then
            return idx
        end
    end
    return prefIdx
end

-- Match current On-Demand Subnet ingredients against RecipesDB to identify active OD recipe & batch count
function Scheduler.matchOnDemandRecipe(cfg, stock, odState)
    if not odState or not odState.hasWork then return nil end
    local fluids = odState.fluids or {}
    local items = odState.items or {}
    local totalOdInputs = (odState.fluidCount or 0) + (odState.itemCount or 0)
    if totalOdInputs <= 0 then return nil end

    local prefIdx = (cfg and cfg.defaultCatalystTier) or 4
    local allSet = { [1] = true, [2] = true, [3] = true, [4] = true, [5] = true }
    local ordered = buildTierPreferenceOrder(allSet, prefIdx, true)
    local tierRank = { NONE = 99 }
    for r = 1, #ordered do
        local ct = TIER_BY_INDEX[ordered[r]]
        if ct then tierRank[ct.code] = r end
    end

    local patCat = odState.patternedCatalystName
    local best = nil

    for fi = 1, #RecipesDB.FAMILIES do
        local fam = RecipesDB.FAMILIES[fi]
        for mi = 1, #(fam.modifiers or {}) do
            local mod = fam.modifiers[mi]
            for tCode, tData in pairs(mod.tiers or {}) do
                local ok = true
                local matched = 0
                local minBatches = math.huge
                local allExact = true

                for k = 1, #(tData.fluidsIn or {}) do
                    local fReq = tData.fluidsIn[k]
                    local need = math.max(1, fReq.amount or 1)
                    local have = fluids[fReq.name] or 0
                    if have < need then
                        ok = false
                        break
                    end
                    matched = matched + 1
                    local b = math.floor(have / need)
                    if b < minBatches then minBatches = b end
                    if (have % need) ~= 0 then allExact = false end
                end

                if ok then
                    for k = 1, #(tData.itemsIn or {}) do
                        local iReq = tData.itemsIn[k]
                        local isNC = (iReq.nonConsumed == true) or ((iReq.amount or 0) == 0)
                        if not isNC then
                            local key = iReq.name .. ":" .. tostring(iReq.damage or 0)
                            local need = math.max(1, iReq.amount or 1)
                            local have = items[key] or 0
                            if have < need then
                                ok = false
                                break
                            end
                            matched = matched + 1
                            local b = math.floor(have / need)
                            if b < minBatches then minBatches = b end
                            if (have % need) ~= 0 then allExact = false end
                        end
                    end
                end

                if ok and matched > 0 and minBatches >= 1 and minBatches < math.huge then
                    local ct = TIER_BY_CODE[tCode]
                    local catFluid = ct and ct.fluid or nil
                    local catAvailOK = (not ct) or (not stock) or (not stock.fluids)
                        or ((stock.fluids[ct.fluid] or 0) > getCatalystFloor(cfg, ct.code))
                    local cand = {
                        family = fam,
                        modifier = mod,
                        tierCode = tCode,
                        tierIndex = (ct and ct.index) or 0,
                        tierData = tData,
                        catFluid = catFluid,
                        batches = minBatches,
                        exactDiv = allExact,
                        explainsAll = (matched == totalOdInputs),
                        matched = matched,
                        patMatch = (patCat ~= nil and catFluid == patCat),
                        isNone = (tCode == "NONE"),
                        catAvailOK = catAvailOK,
                        tRank = tierRank[tCode] or 50,
                    }

                    local better = false
                    if not best then
                        better = true
                    elseif cand.explainsAll ~= best.explainsAll then
                        better = cand.explainsAll
                    elseif cand.matched ~= best.matched then
                        better = cand.matched > best.matched
                    elseif cand.patMatch ~= best.patMatch then
                        better = cand.patMatch
                    elseif (patCat == nil) and (cand.isNone ~= best.isNone) then
                        better = cand.isNone
                    elseif cand.exactDiv ~= best.exactDiv then
                        better = cand.exactDiv
                    elseif cand.catAvailOK ~= best.catAvailOK then
                        better = cand.catAvailOK
                    elseif cand.tRank ~= best.tRank then
                        better = cand.tRank < best.tRank
                    elseif cand.family.id ~= best.family.id then
                        better = cand.family.id < best.family.id
                    else
                        better = (cand.modifier.id or "") < (best.modifier.id or "")
                    end
                    if better then best = cand end
                end
            end
        end
    end

    return best
end

-- Request or cancel full 2-way evacuation of Color 1 OD inputs (`items + fluids + catalyst`) -> Passive -> Main AE2
function Scheduler.requestOdFlush(runtimeState)
    if not runtimeState then return end
    runtimeState.odFlushActive = true
    runtimeState.odFlushManual = true
    runtimeState._odItemDrainBackpressure = false
    runtimeState._forcePollNow = true
end

function Scheduler.cancelOdFlush(cfg, runtimeState)
    if not runtimeState then return end
    runtimeState.odFlushActive = false
    runtimeState.odFlushManual = false
    runtimeState._forcePollNow = true
    local odAddr = runtimeState._odIfAddr or (cfg and cfg.onDemandNetAddr)
    local stockAddr = cfg and cfg.stockNetAddr
    if runtimeState._odIfItemKey ~= nil and odAddr then
        Hardware.setDualInterfaceItemSlot(odAddr, 1, nil)
    end
    if runtimeState._odIfSlot1 ~= nil and odAddr then
        Hardware.setDualInterfaceFluidSlot(odAddr, 1, nil)
    end
    if runtimeState._stockIfSlot1 ~= nil and stockAddr then
        Hardware.setDualInterfaceFluidSlot(stockAddr, 1, nil)
    end
    runtimeState._odIfItemKey = nil
    runtimeState._odIfSlot1 = nil
    runtimeState._stockIfSlot1 = nil
end

-- 2-Way OC Transposer Catalyst Bridge (`Passive <-> On-Demand`) with zero steady-state overhead at 50% discount
function Scheduler.stepOdCatalystBridge(cfg, runtimeState, stock, globalOdAddr, globalOdState, rawDtpfSt, odMatch, channelById, pushEvent)
    runtimeState._odBridgeMovedLiters = 0
    local flushRequested = (runtimeState.odFlushActive == true)
    local manualFlush = (flushRequested and runtimeState.odFlushManual == true)
    local hasBridgeHardware = cfg.transposerAddr and cfg.transposerAddr ~= "" and cfg.transposerAddr ~= "none"
        and globalOdAddr and cfg.stockNetAddr

    if flushRequested then
        if not hasBridgeHardware then
            runtimeState.odFlushActive = false
            runtimeState.odFlushManual = false
            runtimeState.odBridgeStatus = "Flush err: No Transposer/OD IF"
            return
        end
        if (not manualFlush) and (cfg.armed ~= true or cfg.transposerEnabled == false) then
            runtimeState.odFlushActive = false
            runtimeState.odFlushManual = false
            runtimeState.odBridgeStatus = (cfg.transposerEnabled == false) and "Disabled" or "Paused"
            return
        end
    elseif cfg.transposerEnabled == false or not hasBridgeHardware then
        runtimeState.odBridgeStatus = "Disabled"
        return
    end

    if globalOdAddr then
        runtimeState._odIfAddr = globalOdAddr
    end

    local tpAddr = cfg.transposerAddr
    local stockSide = cfg.stockTransposerSide or 1
    local odSide = cfg.odTransposerSide or 0
    local chunkLiters = math.max(100, math.floor(tonumber(cfg.transposerChunkLiters) or 5120))
    local cats = (globalOdState and globalOdState.catalysts) or {}
    local totalOdCat = (globalOdState and globalOdState.totalCatalyst) or 0

    local function sleepBrief()
        if type(os) == "table" and type(os.sleep) == "function" then
            os.sleep(0.05)
        end
    end

    local function clearStockIf(forceClear)
        if runtimeState._stockIfSlot1 ~= nil and (cfg.armed or forceClear) then
            Hardware.setDualInterfaceFluidSlot(cfg.stockNetAddr, 1, nil)
            runtimeState._stockIfSlot1 = nil
        end
    end

    local function clearOdIf(forceClear)
        if runtimeState._odIfSlot1 ~= nil and (cfg.armed or forceClear) then
            Hardware.setDualInterfaceFluidSlot(globalOdAddr, 1, nil)
            runtimeState._odIfSlot1 = nil
        end
    end

    local function clearOdItemIf(forceClear)
        if runtimeState._odIfItemKey ~= nil and (cfg.armed or forceClear) then
            Hardware.setDualInterfaceItemSlot(globalOdAddr, 1, nil)
            runtimeState._odIfItemKey = nil
        end
    end

    -- Case 0: Active OD Evacuation (`Color 1 Items + Fluids + Catalyst -> Passive Dual IF -> Main AE2`)
    if flushRequested then
        clearStockIf(true)

        local function handleBackpressure(stuckCnt)
            if (stuckCnt or 0) <= 0 then return false end
            sleepBrief()
            stuckCnt = Hardware.getTransposerSlotCount(tpAddr, stockSide, 1)
            if stuckCnt <= 0 then return false end
            clearOdItemIf(true)
            Hardware.transferItemViaTransposer(tpAddr, stockSide, odSide, stuckCnt, 1)
            runtimeState._odItemDrainBackpressure = true
            runtimeState.odFlushActive = false
            runtimeState.odFlushManual = false
            runtimeState.odBridgeStatus = "! Set Passive Item SB -> Bi-Dir"
            pushEvent("warn", "! OD Flush halted: Passive Item Storage Bus rejected insert (set Extract+Insert)", { stage = "WARN", minLevel = 1 })
            return true
        end

        if handleBackpressure(Hardware.getTransposerSlotCount(tpAddr, stockSide, 1)) then
            return
        end

        local evacList = (globalOdState and globalOdState.evacItems) or {}
        local itemTarget = nil
        if runtimeState._odIfItemKey ~= nil then
            for idx = 1, #evacList do
                if evacList[idx].key == runtimeState._odIfItemKey then
                    itemTarget = evacList[idx]
                    break
                end
            end
        end
        if not itemTarget and #evacList > 0 then
            itemTarget = evacList[1]
        end

        local totalItemsMoved = 0
        if itemTarget then
            if runtimeState._odIfItemKey ~= itemTarget.key then
                Hardware.setDualInterfaceItemSlot(globalOdAddr, 1, {
                    name = itemTarget.name,
                    damage = itemTarget.damage,
                    size = itemTarget.maxSize,
                    tag = itemTarget.tag,
                })
                runtimeState._odIfItemKey = itemTarget.key
                sleepBrief()
            end
            for _ = 1, 4 do
                local curOdSlot = Hardware.getTransposerSlotCount(tpAddr, odSide, 1)
                local toMove = (curOdSlot > 0) and curOdSlot or (itemTarget.maxSize or 64)
                local okTr, movedI = Hardware.transferItemViaTransposer(tpAddr, odSide, stockSide, toMove, 1, 1)
                if not okTr or (movedI or 0) <= 0 then
                    break
                end
                totalItemsMoved = totalItemsMoved + movedI
                sleepBrief()
                if handleBackpressure(Hardware.getTransposerSlotCount(tpAddr, stockSide, 1)) then
                    return
                end
                if totalItemsMoved >= itemTarget.amount then
                    break
                end
            end
            if totalItemsMoved >= itemTarget.amount then
                clearOdItemIf(true)
                sleepBrief()
                local remOd = Hardware.getTransposerSlotCount(tpAddr, odSide, 1)
                if remOd > 0 then
                    local _, extraMoved = Hardware.transferItemViaTransposer(tpAddr, odSide, stockSide, remOd, 1, 1)
                    totalItemsMoved = totalItemsMoved + (extraMoved or 0)
                    if (extraMoved or 0) > 0 then
                        sleepBrief()
                        if handleBackpressure(Hardware.getTransposerSlotCount(tpAddr, stockSide, 1)) then
                            return
                        end
                    end
                end
            end
        else
            clearOdItemIf(true)
            local resOd = Hardware.getTransposerSlotCount(tpAddr, odSide, 1)
            if resOd > 0 then
                local _, resMoved = Hardware.transferItemViaTransposer(tpAddr, odSide, stockSide, resOd, 1, 1)
                totalItemsMoved = totalItemsMoved + (resMoved or 0)
                if (resMoved or 0) > 0 then
                    sleepBrief()
                    if handleBackpressure(Hardware.getTransposerSlotCount(tpAddr, stockSide, 1)) then
                        return
                    end
                end
            end
        end

        local odFluids = (globalOdState and globalOdState.fluids) or {}
        local drainFluid = runtimeState._odIfSlot1
        if drainFluid then
            local remCur = (odFluids[drainFluid] or 0) + (cats[drainFluid] or 0)
            if remCur <= 0 and Hardware.getTransposerTankLevel(tpAddr, odSide, 1) <= 0 then
                drainFluid = nil
            end
        end
        if not drainFluid then
            local bestAmt = -1
            for k, amt in pairs(odFluids) do
                if amt > bestAmt or (amt == bestAmt and k < tostring(drainFluid)) then
                    bestAmt = amt
                    drainFluid = k
                end
            end
            for k, amt in pairs(cats) do
                if amt > bestAmt or (amt == bestAmt and k < tostring(drainFluid)) then
                    bestAmt = amt
                    drainFluid = k
                end
            end
        end

        local movedFluid = 0
        if drainFluid then
            if runtimeState._odIfSlot1 ~= drainFluid then
                Hardware.setDualInterfaceFluidSlot(globalOdAddr, 1, drainFluid)
                runtimeState._odIfSlot1 = drainFluid
                sleepBrief()
            end
            local tankLvl = Hardware.getTransposerTankLevel(tpAddr, odSide, 1)
            local netRem = (odFluids[drainFluid] or 0) + (cats[drainFluid] or 0)
            local totalRem = netRem + tankLvl
            if totalRem > 0 then
                local _, mF = Hardware.transferViaTransposer(tpAddr, odSide, stockSide, math.min(totalRem, chunkLiters))
                movedFluid = mF or 0
                runtimeState._odBridgeMovedLiters = movedFluid
                if runtimeState.stepStats and movedFluid > 0 then
                    runtimeState.stepStats.bridgeLiters = (runtimeState.stepStats.bridgeLiters or 0) + movedFluid
                end
                local afterTank = Hardware.getTransposerTankLevel(tpAddr, odSide, 1)
                if (netRem == 0 and afterTank == 0) or (movedFluid >= totalRem and afterTank == 0) then
                    clearOdIf(true)
                end
            else
                clearOdIf(true)
            end
        else
            clearOdIf(true)
        end

        local odSlotAfter = Hardware.getTransposerSlotCount(tpAddr, odSide, 1)
        local odTankAfter = Hardware.getTransposerTankLevel(tpAddr, odSide, 1)
        local hasNetWork = (globalOdState and ((#(globalOdState.evacItems or {}) > 0) or ((globalOdState.fluidCount or 0) > 0))) or false
        if (not hasNetWork) and totalOdCat == 0 and totalItemsMoved == 0 and movedFluid == 0 and odSlotAfter == 0 and odTankAfter == 0 then
            clearOdItemIf(true)
            clearOdIf(true)
            runtimeState.odFlushActive = false
            runtimeState.odFlushManual = false
            runtimeState._odStallPolls = 0
            runtimeState.odStalled = false
            runtimeState.odStallReason = nil
            runtimeState.odBridgeStatus = "Idle (Flushed -> Main)"
            pushEvent("out", "✓ OD Flush complete -> returned Color 1 inputs to Main", { stage = "OUT", minLevel = 1 })
        else
            runtimeState.odFlushActive = true
            runtimeState.odBridgeStatus = string.format("Flushing OD (-%dI / -%dL)", totalItemsMoved, movedFluid)
            if totalItemsMoved > 0 or movedFluid > 0 then
                pushEvent("out", string.format("OD Bridge: flushed -%dI / -%dL -> Main", totalItemsMoved, movedFluid), { stage = "OUT", minLevel = 2 })
            end
        end
        return
    end

    if runtimeState._odIfItemKey ~= nil and cfg.armed then
        clearOdItemIf(false)
    end

    -- Case 1: OD Idle (0 items & 0 non-catalyst fluids) -> Zero-call fast path or Drain excess catalyst out
    if not (globalOdState and globalOdState.hasWork) then
        runtimeState._odPartialWaitSteps = 0

        if totalOdCat == 0 and runtimeState._odIfSlot1 == nil then
            clearStockIf()
            runtimeState._odIdleWithCatSteps = 0
            runtimeState.odBridgeStatus = "Idle (0 calls)"
            return
        end

        local drainFluid = runtimeState._odIfSlot1
        local drainNetAmt = drainFluid and (cats[drainFluid] or 0) or 0
        if not drainFluid then
            local bestAmt = -1
            for k, amt in pairs(cats) do
                if amt > bestAmt or (amt == bestAmt and k < tostring(drainFluid)) then
                    bestAmt = amt
                    drainFluid = k
                    drainNetAmt = amt
                end
            end
        end

        if not drainFluid then
            runtimeState._odIdleWithCatSteps = 0
            runtimeState.odBridgeStatus = "Idle (0 calls)"
            return
        end

        if not cfg.armed then
            runtimeState.odBridgeStatus = string.format("Preview: Drain %dL %s", totalOdCat, drainFluid)
            return
        end

        runtimeState._odIdleWithCatSteps = (runtimeState._odIdleWithCatSteps or 0) + 1
        if runtimeState._odIdleWithCatSteps < 2 and runtimeState._odIfSlot1 == nil then
            runtimeState.odBridgeStatus = "Hold (verifying OD idle)"
            return
        end

        clearStockIf()
        if runtimeState._odIfSlot1 ~= drainFluid then
            Hardware.setDualInterfaceFluidSlot(globalOdAddr, 1, drainFluid)
            runtimeState._odIfSlot1 = drainFluid
            sleepBrief()
        end

        local tankLvl = Hardware.getTransposerTankLevel(cfg.transposerAddr, odSide, 1)
        local netRem = cats[drainFluid] or 0
        local totalRem = netRem + tankLvl
        if totalRem > 0 then
            local _, moved = Hardware.transferViaTransposer(cfg.transposerAddr, odSide, stockSide, math.min(totalRem, chunkLiters))
            runtimeState._odBridgeMovedLiters = moved or 0
            if runtimeState.stepStats and moved and moved > 0 then
                runtimeState.stepStats.bridgeLiters = (runtimeState.stepStats.bridgeLiters or 0) + moved
            end
            local afterTank = Hardware.getTransposerTankLevel(cfg.transposerAddr, odSide, 1)
            if (netRem == 0 and afterTank == 0) or (moved >= totalRem and afterTank == 0) then
                clearOdIf()
                runtimeState._odIdleWithCatSteps = 0
                runtimeState.odBridgeStatus = "Idle (Drained clean)"
                pushEvent("out", string.format("OD Bridge: drained %dL %s -> Main", moved, drainFluid), { stage = "OUT", minLevel = 2 })
            else
                runtimeState.odBridgeStatus = string.format("Draining %s (-%dL)", drainFluid, moved)
            end
        else
            clearOdIf()
            runtimeState._odIdleWithCatSteps = 0
            runtimeState.odBridgeStatus = "Idle (0 calls)"
        end
        return
    end

    -- Case 2: Active OD Craft -> Determine catalyst requirement vs live OD discount & convergence
    runtimeState._odIdleWithCatSteps = 0
    if runtimeState._odIfSlot1 ~= nil and cfg.armed then
        clearOdIf()
    end

    local minOdDiscount, maxOdDiscount = 50, 0
    local sawServing = false
    local anyAlwaysOverride = false
    local maxExtraNeeded = 0
    local uniformPrefCat = nil
    local prefCatSame = true

    local anySupportsConv = false
    local anyManualConv = false
    for i = 1, #cfg.dtpfs do
        local d = cfg.dtpfs[i]
        local st = rawDtpfSt[i]
        local chObj = channelById and channelById[d.channelId or "ch1"]
        local usesGlobal = (d.odNetAddr == globalOdAddr)
            or ((d.odNetAddr == nil or d.odNetAddr == "global")
                and ((d.roleOverride == "od_only") or (not chObj) or (chObj.shareOnDemand ~= false)))
        if (d.enabled ~= false) and st and st.online and d.odNetAddr ~= "none" and usesGlobal then
            sawServing = true
            local disc = st.discountPct or 0
            if disc < minOdDiscount then minOdDiscount = disc end
            if disc > maxOdDiscount then maxOdDiscount = disc end
            if st.supportsConvControl == false then
                if st.convergenceEnabled == true then
                    anyManualConv = true
                end
            else
                anySupportsConv = true
                local effConv = effectiveDTPFConvMode(cfg, d)
                if d.convOverride == "always" or effConv == "always" then
                    anyAlwaysOverride = true
                end
            end
            if (st.extraCatalystNeeded or 0) > maxExtraNeeded then
                maxExtraNeeded = st.extraCatalystNeeded
            end
            local dPref = (d.catOverride and d.catOverride >= 1) and d.catOverride or (cfg.defaultCatalystTier or 4)
            if uniformPrefCat == nil then
                uniformPrefCat = dPref
            elseif uniformPrefCat ~= dPref then
                prefCatSame = false
            end
        end
    end
    if not sawServing then
        minOdDiscount = 50
        maxOdDiscount = 50
    end

    local odMode = cfg.onDemandConvMode or "auto_safe"
    local wantConv4x
    if sawServing and (not anySupportsConv) then
        wantConv4x = anyManualConv
    else
        wantConv4x = ((odMode == "on") and (maxOdDiscount >= 49.9)) or anyAlwaysOverride
    end

    local catFluid, catCode, baseCat, batches = nil, nil, 0, 1
    local isNoneRecipe = false

    if odMatch and odMatch.tierCode == "NONE" then
        isNoneRecipe = true
        if not wantConv4x then
            clearStockIf()
            runtimeState._odPartialWaitSteps = 0
            runtimeState.odBridgeStatus = "Idle (No-Cat OD)"
            return
        end
        local prefTier = (prefCatSame and uniformPrefCat) or cfg.defaultCatalystTier or 4
        local cIdx = pickAvailableCatalystTier(cfg, stock, prefTier)
        local ct = TIER_BY_INDEX[cIdx] or TIER_BY_INDEX[4]
        catFluid = ct.fluid
        catCode = ct.code
        baseCat = Scheduler.estimateConvergenceCatalyst(odMatch.tierData, ct)
        batches = odMatch.batches or 1
    elseif odMatch then
        catFluid = odMatch.catFluid
        catCode = odMatch.tierCode
        baseCat = (odMatch.tierData and odMatch.tierData.catalystAmount) or 1000
        batches = odMatch.batches or 1
    elseif globalOdState.hasPatternedCatalyst and globalOdState.patternedCatalystName then
        catFluid = globalOdState.patternedCatalystName
        for i = 1, #RecipesDB.CATALYST_TIERS do
            if RecipesDB.CATALYST_TIERS[i].fluid == catFluid then
                catCode = RecipesDB.CATALYST_TIERS[i].code
                break
            end
        end
        baseCat = (cats[catFluid] or 0) * 2
        batches = 1
    else
        clearStockIf()
        runtimeState._odPartialWaitSteps = 0
        runtimeState.odBridgeStatus = "Idle"
        return
    end

    local function needAtDisc(discPct)
        if isNoneRecipe then
            local baseNone = (maxExtraNeeded > 0) and maxExtraNeeded or baseCat
            return math.max(1, math.floor(baseNone / 2))
        end
        local discFactor = math.max(0.5, 1.0 - math.min(1.0, (discPct or 0) / 50.0) * 0.5)
        local need = math.floor(baseCat * discFactor + 0.5)
        if wantConv4x and (discPct or 0) >= 49.9 then
            local ct = catCode and TIER_BY_CODE[catCode]
            local extraEst = (maxExtraNeeded > 0) and maxExtraNeeded
                or (odMatch and ct and Scheduler.estimateConvergenceCatalyst(odMatch.tierData, ct))
                or 0
            need = math.floor((baseCat + extraEst) / 2)
        end
        return need
    end

    local needMin = needAtDisc(minOdDiscount)
    local needMax = needAtDisc(maxOdDiscount)
    local odHave = cats[catFluid] or 0
    local targetBuf = needMin * math.max(1, math.min(batches or 1, 2))

    -- Zero-overhead steady-state fast exit when OD already has enough catalyst (0 component calls!)
    if (runtimeState._stockIfSlot1 ~= catFluid and odHave >= needMin)
        or (runtimeState._stockIfSlot1 == catFluid and odHave >= targetBuf) then
        runtimeState._odPartialWaitSteps = 0
        clearStockIf()
        runtimeState.odBridgeStatus = "Ready (0 overhead)"
        return
    end

    -- Mixed-fleet 1-poll grace: wait 1 poll if at least one 50% DTPF can take the craft immediately
    if runtimeState._stockIfSlot1 == nil and odHave >= needMax and (runtimeState._odPartialWaitSteps or 0) < 1 then
        runtimeState._odPartialWaitSteps = 1
        runtimeState.odBridgeStatus = "Wait 1 poll (50% DTPF ready)"
        return
    end

    local floor = catCode and getCatalystFloor(cfg, catCode) or 100000
    local mainHave = (stock and stock.fluids and stock.fluids[catFluid]) or 0
    local avail = mainHave - floor
    if avail <= 0 then
        clearStockIf()
        runtimeState.odBridgeStatus = "Blocked: Main " .. tostring(catCode or catFluid) .. " <= Floor"
        return
    end

    local deficit = math.min(avail, math.max(needMin, targetBuf) - odHave)
    if deficit <= 0 then
        clearStockIf()
        runtimeState.odBridgeStatus = "Ready (0 overhead)"
        return
    end

    if not cfg.armed then
        runtimeState.odBridgeStatus = string.format("Preview: Top-Up +%dL %s", deficit, tostring(catCode or catFluid))
        return
    end

    if runtimeState._stockIfSlot1 ~= catFluid then
        Hardware.setDualInterfaceFluidSlot(cfg.stockNetAddr, 1, catFluid)
        runtimeState._stockIfSlot1 = catFluid
        sleepBrief()
    end

    local _, moved = Hardware.transferViaTransposer(cfg.transposerAddr, stockSide, odSide, math.min(deficit, chunkLiters))
    runtimeState._odBridgeMovedLiters = moved or 0
    if runtimeState.stepStats and moved and moved > 0 then
        runtimeState.stepStats.bridgeLiters = (runtimeState.stepStats.bridgeLiters or 0) + moved
    end
    local newHave = odHave + moved
    runtimeState.odBridgeStatus = string.format("Top-Up +%dL %s (%d/%dL)", moved, tostring(catCode or "CAT"), newHave, needMin)
    if moved > 0 then
        pushEvent("out", string.format("OD Bridge: +%dL %s -> OD", moved, tostring(catCode or catFluid)), { stage = "OUT", minLevel = 2 })
    end
    if newHave >= math.max(needMin, targetBuf) then
        clearStockIf()
    end
end

local function computeOnDemandWantConv(cfg, d, st, odState, odMatch)
    if not d.enabled then return false end
    local effConv = effectiveDTPFConvMode(cfg, d)
    if effConv == "off" then return false end
    if d.convOverride == "always" then return true end
    local discountOK = (effConv == "always") or ((st.discountPct or 0) >= 49.9)
    local odMode = cfg.onDemandConvMode or "auto_safe"
    if odMode == "off" then
        return false
    elseif odMode == "on" then
        return discountOK
    else -- "auto_safe"
        if not (odState.hasPatternedCatalyst == true and discountOK) then
            return false
        end
        if odMatch and odMatch.tierCode ~= "NONE" and (odMatch.batches or 1) >= 2 then
            local ct = TIER_BY_CODE[odMatch.tierCode]
            local baseCat = (odMatch.tierData and odMatch.tierData.catalystAmount) or 1000
            local extraCat = ((st and st.extraCatalystNeeded and st.extraCatalystNeeded > 0) and st.extraCatalystNeeded)
                or Scheduler.estimateConvergenceCatalyst(odMatch.tierData, ct)
            local conv4xSingle = math.floor((baseCat + extraCat) / 2)
            local haveCat = (odState.catalysts and odMatch.catFluid and odState.catalysts[odMatch.catFluid]) or 0
            if haveCat < (odMatch.batches * conv4xSingle) then
                return false
            end
        end
        return true
    end
end

local function clearPassiveChannelWithLog(ch, stock, runtimeState, useCache, pushEvent, reasonTag)
    local _, wroteHw = Hardware.clearChannel(ch, stock)
    ch.currentFamilyId = nil
    if wroteHw and not useCache then
        local stats = runtimeState and runtimeState.stepStats
        if stats then stats.chWrites = (stats.chWrites or 0) + 1 end
        if pushEvent then
            pushEvent("out", string.format("%s clear: 0-stock sentinels (%s)",
                tostring(ch.id), tostring(reasonTag or "idle")), { stage = "OUT", minLevel = 2 })
        end
    end
    return wroteHw
end

local function applyAndRecordChannelJob(cfg, stock, runtimeState, ch, args, useCache, pushEvent)
    local catAmt = (args.meta and args.meta.convCatAmount) or (args.tData and args.tData.catalystAmount) or 1000
    local catTag = (args.meta and args.meta.isNoneCat and args.meta.convSatisfied)
        and ("NONE+" .. tostring(args.meta.convCatCode))
        or (args.tCode or "NONE")
    if cfg.armed then
        local sig = string.format("%s:%s:%s", args.famId, args.mod and args.mod.id or "std", args.tCode or "NONE")
        local _, wroteHw = Hardware.applyRecipeToChannel(ch, sig, args.tData, args.catFluid, {
            skipNonConsumed = cfg.uniformNcSubnet,
            stock = stock,
            catalystAmount = catAmt,
        })
        ch.currentFamilyId = args.famId
        if wroteHw and not useCache then
            local stats = runtimeState and runtimeState.stepStats
            if stats then stats.chWrites = (stats.chWrites or 0) + 1 end
            if pushEvent then
                pushEvent("out", string.format("%s write: %df, %di [%s]",
                    tostring(ch.id), #(ch.lastFluids or {}), #(ch.lastItems or {}), tostring(catTag)),
                    { stage = "OUT", minLevel = 2 })
            end
        end
    end
    local famName = args.fam and args.fam.name or args.famId
    local modLabel = args.mod and args.mod.label or "Std"
    local label = args.labelPrefix
        and string.format("%s%s [%s @ %s]", args.labelPrefix, famName, modLabel, catTag)
        or string.format("%s%s [%s @ %s]", args.isForever and "24/7: " or "", famName, modLabel, catTag)
    runtimeState.channelStatus[ch.id] = {
        mode = args.mode,
        pinned = args.pinned,
        familyId = args.famId,
        tierCode = args.tCode,
        tierData = args.tData,
        isNoneCat = args.meta and args.meta.isNoneCat or false,
        convSatisfied = args.meta and args.meta.convSatisfied or false,
        convCatIndex = (args.meta and args.meta.convCatIndex) or args.tIdx,
        convCatCode = (args.meta and args.meta.convCatCode) or args.tCode,
        usedFallbackCat = (args.meta and args.meta.usedFallbackCat == true),
        label = label,
    }
end

local function stepPollSnapshots(cfg, runtimeState, opts, nowSec)
    local component = require("component")
    local hasCompLib, computerLib = pcall(require, "computer")
    local stockPolled = false
    local stockProxy = cfg.stockNetAddr and component.proxy(cfg.stockNetAddr) or nil

    local channelById = {}
    for i = 1, #cfg.channels do
        channelById[cfg.channels[i].id] = cfg.channels[i]
    end

    local useCache = (opts.cachedOnly == true)
        and (runtimeState._lastStock ~= nil)
        and (runtimeState._lastRawDtpfSt ~= nil)
    local globalOdAddr = (cfg.onDemandNetAddr and cfg.onDemandNetAddr ~= cfg.stockNetAddr) and cfg.onDemandNetAddr or nil
    local stock, idleOd, odByAddr, globalOdState

    if useCache then
        stock = runtimeState._lastStock
        idleOd = runtimeState._lastIdleOd or Hardware.pollOnDemandSubnet(nil)
        odByAddr = runtimeState._lastOdByAddr or {}
        globalOdState = runtimeState._lastGlobalOdState or (globalOdAddr and odByAddr[globalOdAddr]) or idleOd
    else
        runtimeState._lastPollUptime = nowSec
        Hardware.pollWorkers()
        runtimeState.workerCount = Hardware.getWorkerCount()
        local nowUptime = (hasCompLib and computerLib and computerLib.uptime) and computerLib.uptime() or nil
        local anyItemRecipeEnabled = false
        for i = 1, #RecipesDB.FAMILIES do
            local fam = RecipesDB.FAMILIES[i]
            local rc = cfg.recipes[fam.id]
            if rc and rc.enabled then
                if fam.primaryOutput and not fam.primaryOutput.isFluid and fam.primaryOutput.type ~= "fluid" then
                    anyItemRecipeEnabled = true
                    break
                end
                if type(rc.guardKey) == "string" and rc.guardKey:find("^item:") then
                    anyItemRecipeEnabled = true
                    break
                end
                local mod = fam.modifiers and fam.modifiers[rc.modifierIndex or 1]
                for _, td in pairs((mod and mod.tiers) or {}) do
                    for _, ii in ipairs(td.itemsIn or {}) do
                        if not cfg.uniformNcSubnet or (not ii.nonConsumed and (ii.amount or 0) > 0) then
                            anyItemRecipeEnabled = true
                            break
                        end
                    end
                    if anyItemRecipeEnabled or #(td.itemsOut or {}) > 0 then
                        anyItemRecipeEnabled = true
                        break
                    end
                end
                if anyItemRecipeEnabled then break end
            end
        end
        local itemTtl = anyItemRecipeEnabled and 18.0 or 45.0

        local fluidAge = nowUptime and runtimeState._lastFluidStockTime and (nowUptime - runtimeState._lastFluidStockTime) or math.huge
        local itemAge = nowUptime and runtimeState._lastItemStockTime and (nowUptime - runtimeState._lastItemStockTime) or math.huge
        stockPolled = true
        if opts.allowStockCache and runtimeState._lastStock and nowUptime and fluidAge < 5.0 then
            stock = runtimeState._lastStock
            stockPolled = false
        elseif opts.allowStockCache and runtimeState._lastStock and nowUptime and itemAge < itemTtl then
            stock = Hardware.pollNetworkStock(stockProxy, { skipItems = true, prevStock = runtimeState._lastStock })
            runtimeState._lastFluidStockTime = nowUptime
        else
            stock = Hardware.pollNetworkStock(stockProxy, { wantedItemNames = WANTED_ITEM_NAMES })
            runtimeState._lastFluidStockTime = nowUptime
            runtimeState._lastItemStockTime = nowUptime
        end
        if stockPolled and stock and stock.fluids then
            runtimeState.dtrRatePerMin = updateRateTracker(
                runtimeState._rateTrackers,
                "dtr",
                stock.fluids["dimensionallytranscendentresidue"] or 0,
                nowSec
            )
        end
        idleOd = Hardware.pollOnDemandSubnet(nil)
        odByAddr = {}
        if globalOdAddr then
            odByAddr[globalOdAddr] = Hardware.pollOnDemandSubnet(component.proxy(globalOdAddr))
        end
        for i = 1, #cfg.dtpfs do
            local a = cfg.dtpfs[i].odNetAddr
            if a and a ~= "global" and a ~= "none" and a ~= cfg.stockNetAddr and not odByAddr[a] then
                odByAddr[a] = Hardware.pollOnDemandSubnet(component.proxy(a))
            end
        end
        globalOdState = (globalOdAddr and odByAddr[globalOdAddr]) or idleOd
        runtimeState._lastStock = stock
        runtimeState._lastIdleOd = idleOd
        runtimeState._lastOdByAddr = odByAddr
        runtimeState._lastGlobalOdState = globalOdState
    end
    runtimeState.stock = stock

    local rawDtpfSt, dtpfOdState, dtpfHasOdWork = {}, {}, {}
    local dedicatedActive, activeOdDtpfs, channelOdInfo, onlineEnabled = {}, {}, {}, {}
    local fleetMaxKnownHeat = nil
    local anyOnline, anyConvControl = false, false
    local channelMaxHeat, channelMaxInputEu, channelRoles, channelCatOverrides, channelDtpfs = {}, {}, {}, {}, {}

    for i = 1, #cfg.dtpfs do
        local d = cfg.dtpfs[i]
        local chIdAll = d.channelId or "ch1"
        channelDtpfs[chIdAll] = channelDtpfs[chIdAll] or {}
        channelDtpfs[chIdAll][#channelDtpfs[chIdAll] + 1] = i

        local chObj = channelById[chIdAll]
        local dOd
        if d.odNetAddr == "none" then
            dOd = idleOd
        elseif d.odNetAddr and d.odNetAddr ~= "global" then
            dOd = odByAddr[d.odNetAddr] or idleOd
        else
            local usesGlobalOd = (d.roleOverride == "od_only") or (not chObj) or (chObj.shareOnDemand ~= false)
            dOd = usesGlobalOd and globalOdState or idleOd
        end
        dtpfOdState[i] = dOd
        local hasOd = (d.enabled ~= false) and (dOd.hasWork == true)
        dtpfHasOdWork[i] = hasOd
        if hasOd then
            if d.odNetAddr and d.odNetAddr ~= "global" and d.odNetAddr ~= "none" then
                dedicatedActive[#dedicatedActive + 1] = i
            end
            activeOdDtpfs[#activeOdDtpfs + 1] = i
            local rec = channelOdInfo[chIdAll]
            if not rec then
                rec = { hasWork = false, summary = nil, dtpfNums = {} }
                channelOdInfo[chIdAll] = rec
            end
            rec.hasWork = true
            rec.dtpfNums[#rec.dtpfNums + 1] = i
            if not rec.summary and dOd.summary and dOd.summary ~= "Idle" then
                rec.summary = dOd.summary
            end
        end

        local st = (useCache and runtimeState._lastRawDtpfSt[i])
            or Hardware.getDTPFStatus(d, { allowSensorCache = (opts.allowSensorCache == true) })
        rawDtpfSt[i] = st
        if st.x ~= nil then
            d.x, d.y, d.z = st.x, st.y, st.z
        end

        if st.online then
            anyOnline = true
            if st.supportsConvControl ~= false then
                anyConvControl = true
            end
        end
        if st.online and d.enabled then
            local chId = d.channelId or "ch1"
            onlineEnabled[#onlineEnabled + 1] = {
                chId = chId,
                convOverride = d.convOverride or "global",
                discountPct = st.discountPct or 0,
                supportsConvControl = (st.supportsConvControl ~= false),
                convergenceEnabled = (st.convergenceEnabled == true),
            }
            if st.coilHeat then
                if not fleetMaxKnownHeat or st.coilHeat > fleetMaxKnownHeat then
                    fleetMaxKnownHeat = st.coilHeat
                end
                if not channelMaxHeat[chId] or st.coilHeat > channelMaxHeat[chId] then
                    channelMaxHeat[chId] = st.coilHeat
                end
            end
            if (tonumber(st.maxInputEu) or 0) > (channelMaxInputEu[chId] or 0) then
                channelMaxInputEu[chId] = tonumber(st.maxInputEu)
            end
            channelRoles[chId] = channelRoles[chId] or {
                allFallbackOnly = true,
                allPassiveOnly = true,
                allOdOnly = true,
                hasAny = false,
                pinnedFamilyId = nil,
                pinMode = nil,
            }
            channelRoles[chId].hasAny = true
            if d.roleOverride ~= "od_only" then channelRoles[chId].allOdOnly = false end
            if d.roleOverride ~= "fallback_only" then channelRoles[chId].allFallbackOnly = false end
            if d.roleOverride ~= "passive_only" then channelRoles[chId].allPassiveOnly = false end
            if (d.roleOverride == "pinned" or d.roleOverride == "pinned_loop")
                and d.pinnedFamilyId and FAMILY_BY_ID[d.pinnedFamilyId]
                and not channelRoles[chId].pinnedFamilyId then
                channelRoles[chId].pinnedFamilyId = d.pinnedFamilyId
                channelRoles[chId].pinMode = d.roleOverride
            end
            if not channelCatOverrides[chId] then
                channelCatOverrides[chId] = { same = true, val = d.catOverride or 0 }
            elseif channelCatOverrides[chId].val ~= (d.catOverride or 0) then
                channelCatOverrides[chId].same = false
            end
        end
    end

    if not useCache then
        runtimeState._lastRawDtpfSt = rawDtpfSt
    end
    runtimeState.convControlSupported = (not anyOnline) or anyConvControl

    for i = 1, #cfg.channels do
        local ch = cfg.channels[i]
        if #(channelDtpfs[ch.id] or {}) == 0 and ch.shareOnDemand ~= false and globalOdState.hasWork then
            channelOdInfo[ch.id] = {
                hasWork = true,
                summary = globalOdState.summary,
                dtpfNums = {},
            }
        end
    end

    return {
        useCache = useCache,
        stockPolled = stockPolled,
        stock = stock,
        globalOdAddr = globalOdAddr,
        globalOdState = globalOdState,
        channelById = channelById,
        rawDtpfSt = rawDtpfSt,
        dtpfOdState = dtpfOdState,
        dtpfHasOdWork = dtpfHasOdWork,
        dedicatedActive = dedicatedActive,
        activeOdDtpfs = activeOdDtpfs,
        channelOdInfo = channelOdInfo,
        onlineEnabled = onlineEnabled,
        fleetMaxKnownHeat = fleetMaxKnownHeat,
        channelMaxHeat = channelMaxHeat,
        channelMaxInputEu = channelMaxInputEu,
        channelRoles = channelRoles,
        channelCatOverrides = channelCatOverrides,
        channelDtpfs = channelDtpfs,
    }
end

local function buildOdAmountSig(st)
    if not st or not st.hasWork then return "idle" end
    local parts = { tostring(st.summary or "") }
    local fKeys, iKeys = {}, {}
    for k in pairs(st.fluids or {}) do fKeys[#fKeys + 1] = k end
    table.sort(fKeys)
    for fi = 1, #fKeys do parts[#parts + 1] = fKeys[fi] .. "=" .. tostring(st.fluids[fKeys[fi]]) end
    for k in pairs(st.items or {}) do iKeys[#iKeys + 1] = k end
    table.sort(iKeys)
    for ii = 1, #iKeys do parts[#parts + 1] = iKeys[ii] .. "=" .. tostring(st.items[iKeys[ii]]) end
    return table.concat(parts, ";")
end

local function stepEvaluateOdAndBridge(cfg, runtimeState, ctx, opts, pushEvent)
    local odState
    if #ctx.dedicatedActive > 0 then
        local seenAddrs, tags = {}, {}
        local totalFluids, totalItems, totalCat = 0, 0, 0
        local hasPatCat, patCatName, firstDesc = false, nil, nil
        for k = 1, #ctx.activeOdDtpfs do
            local idx = ctx.activeOdDtpfs[k]
            local dst = ctx.dtpfOdState[idx]
            local dObj = cfg.dtpfs[idx]
            local a = (dObj.odNetAddr and dObj.odNetAddr ~= "global") and dObj.odNetAddr or (ctx.globalOdAddr or "__global")
            if not seenAddrs[a] then
                seenAddrs[a] = true
                totalFluids = totalFluids + (dst.fluidCount or 0)
                totalItems = totalItems + (dst.itemCount or 0)
                totalCat = totalCat + (dst.totalCatalyst or 0)
            end
            if dst.hasPatternedCatalyst then
                hasPatCat = true
                patCatName = patCatName or dst.patternedCatalystName
            end
            tags[#tags + 1] = "#" .. tostring(idx)
            if not firstDesc and dst.summary and dst.summary ~= "Idle" then
                firstDesc = dst.summary
            end
        end
        odState = {
            hasWork = true,
            hasPatternedCatalyst = hasPatCat,
            patternedCatalystName = patCatName,
            totalCatalyst = totalCat,
            fluidCount = totalFluids,
            itemCount = totalItems,
            activeDtpfs = ctx.activeOdDtpfs,
            summary = table.concat(tags, ", ") .. ": " .. (firstDesc or "Active"),
        }
    else
        odState = {
            hasWork = ctx.globalOdState.hasWork,
            hasPatternedCatalyst = ctx.globalOdState.hasPatternedCatalyst,
            patternedCatalystName = ctx.globalOdState.patternedCatalystName,
            totalCatalyst = ctx.globalOdState.totalCatalyst or 0,
            fluidCount = ctx.globalOdState.fluidCount,
            itemCount = ctx.globalOdState.itemCount,
            activeDtpfs = (#ctx.activeOdDtpfs > 0) and ctx.activeOdDtpfs or nil,
            summary = ctx.globalOdState.summary,
        }
    end
    runtimeState.onDemand = odState

    local odMatchByAddr = {}
    local function getOdMatch(addrKey, dst)
        if not dst or not dst.hasWork then return nil end
        if odMatchByAddr[addrKey] == nil then
            odMatchByAddr[addrKey] = Scheduler.matchOnDemandRecipe(cfg, ctx.stock, dst) or false
        end
        return odMatchByAddr[addrKey] or nil
    end
    local globalOdMatch = getOdMatch(ctx.globalOdAddr or "__global", ctx.globalOdState)
    odState.matchedFamilyId = globalOdMatch and globalOdMatch.family.id or nil
    odState.matchedBatches = globalOdMatch and globalOdMatch.batches or 0

    if not opts.interactive and not ctx.useCache then
        Scheduler.stepOdCatalystBridge(cfg, runtimeState, ctx.stock, ctx.globalOdAddr, ctx.globalOdState, ctx.rawDtpfSt, globalOdMatch, ctx.channelById, pushEvent)
    end

    if not ctx.useCache then
        if odState.hasWork then
            runtimeState._odAutoFlushIdlePolls = 0
        elseif not runtimeState.odFlushActive then
            runtimeState._odAutoFlushIdlePolls = (runtimeState._odAutoFlushIdlePolls or 0) + 1
            if runtimeState._odAutoFlushIdlePolls >= 2 then
                runtimeState._odAutoFlushLastSig = nil
                runtimeState._odAutoFlushLoopWarned = false
                runtimeState._odItemDrainBackpressure = false
            end
        end

        if not cfg.armed or not (odState.hasWork == true) or not cfg.pausePassivesOnOD then
            runtimeState._odStallPolls = 0
            runtimeState._odStallSig = nil
            runtimeState.odStalled = false
            runtimeState.odStallReason = nil
        elseif runtimeState.odFlushActive == true then
            runtimeState._odStallPolls = 0
        else
            local curOdSig = buildOdAmountSig(ctx.globalOdState)
            local sigChanged = (runtimeState._odStallSig ~= nil and curOdSig ~= runtimeState._odStallSig)
            runtimeState._odStallSig = curOdSig

            local anyOdDtpfActive, anyNonOdDtpfActive = false, false
            for di = 1, #cfg.dtpfs do
                local dr = ctx.rawDtpfSt[di]
                if dr and (dr.active == true or (dr.maxProgress or 0) > 0) then
                    if cfg.dtpfs[di].roleOverride == "od_only" then
                        anyOdDtpfActive = true
                    else
                        anyNonOdDtpfActive = true
                    end
                end
            end
            local bridgeBusy = ((runtimeState._odBridgeMovedLiters or 0) > 0)
                or (tostring(runtimeState.odBridgeStatus or ""):find("^Wait ", 1) ~= nil)
            local realOdProgress = anyOdDtpfActive or ((not runtimeState.odStalled) and anyNonOdDtpfActive)

            if realOdProgress or bridgeBusy or sigChanged then
                runtimeState._odStallPolls = 0
                if runtimeState.odStalled then
                    pushEvent("od", "⚡ On-Demand resumed / changed", { stage = "IN", minLevel = 1 })
                end
                runtimeState.odStalled = false
                runtimeState.odStallReason = nil
            else
                runtimeState._odStallPolls = (runtimeState._odStallPolls or 0) + 1
                if runtimeState._odStallPolls >= 4 then
                    local ncLabels = {}
                    if globalOdMatch and globalOdMatch.tierData then
                        for _, ii in ipairs(globalOdMatch.tierData.itemsIn or {}) do
                            if ii.nonConsumed == true or (ii.amount or 0) == 0 then
                                ncLabels[#ncLabels + 1] = ii.label or ii.name
                            end
                        end
                    end
                    local reasonStr = (#ncLabels > 0)
                        and ("0 active DTPFs; check " .. table.concat(ncLabels, " + ") .. " in NC/Pattern")
                        or "0 active DTPFs; check Circuit/NC/Coil"
                    local canAutoFlush = (cfg.armed == true)
                        and ((cfg.odAutoFlushPolls or 0) > 0)
                        and (cfg.transposerEnabled ~= false)
                        and cfg.transposerAddr and cfg.transposerAddr ~= "" and cfg.transposerAddr ~= "none"
                        and ctx.globalOdAddr and cfg.stockNetAddr
                        and (not runtimeState.odFlushActive)
                        and (not runtimeState._odItemDrainBackpressure)
                    if canAutoFlush then
                        if runtimeState._odAutoFlushLastSig ~= nil and curOdSig == runtimeState._odAutoFlushLastSig then
                            reasonStr = "AE2 CPU re-pushed craft (cancel CPU or click [Flush])"
                            if not runtimeState._odAutoFlushLoopWarned then
                                runtimeState._odAutoFlushLoopWarned = true
                                pushEvent("warn", "! OD Auto-Flush paused: AE2 CPU re-pushed same craft", { stage = "WARN", minLevel = 1 })
                            end
                        elseif runtimeState._odStallPolls >= math.max(4, cfg.odAutoFlushPolls) then
                            runtimeState.odFlushActive = true
                            runtimeState.odFlushManual = false
                            runtimeState._odAutoFlushLastSig = curOdSig
                            runtimeState._odAutoFlushLoopWarned = false
                            pushEvent("warn", "! OD Auto-Flush triggered -> cycling Color 1 to Main", { stage = "WARN", minLevel = 1 })
                        end
                    end
                    if not runtimeState.odStalled then
                        local odName = (globalOdMatch and globalOdMatch.family and globalOdMatch.family.name) or odState.summary
                        pushEvent("warn", "! OD Stalled (" .. tostring(odName) .. ") -> running Passives", { stage = "WARN", minLevel = 1 })
                    end
                    runtimeState.odStalled = true
                    runtimeState.odStallReason = reasonStr
                end
            end
        end
    end

    if runtimeState.odStalled == true then
        odState.stalled = true
        odState.stallReason = runtimeState.odStallReason
        runtimeState.bottlenecks[#runtimeState.bottlenecks + 1] = {
            kind = "od_stall",
            familyId = odState.matchedFamilyId,
            name = "OD Stalled: " .. tostring((globalOdMatch and globalOdMatch.family and globalOdMatch.family.name) or odState.summary or "On-Demand"),
            reason = runtimeState.odStallReason or "Check Circuit/NC",
        }
        for i = 1, #cfg.dtpfs do
            if cfg.dtpfs[i].roleOverride ~= "od_only" then
                ctx.dtpfHasOdWork[i] = false
            end
        end
        for chId in pairs(ctx.channelOdInfo) do
            local cr = ctx.channelRoles[chId]
            if not (cr and cr.hasAny and cr.allOdOnly) then
                ctx.channelOdInfo[chId] = nil
            end
        end
    end

    if runtimeState.odFlushActive == true then
        for i = 1, #cfg.dtpfs do
            ctx.dtpfHasOdWork[i] = false
        end
        for chId in pairs(ctx.channelOdInfo) do
            ctx.channelOdInfo[chId] = nil
        end
    end

    local odNow = (odState.hasWork == true)
    if runtimeState._prevOdWork == nil then
        if odNow then
            pushEvent("od", "⚡ On-Demand active: " .. tostring(odState.summary), { stage = "IN", minLevel = 1 })
        end
    elseif odNow ~= runtimeState._prevOdWork then
        if odNow then
            pushEvent("od", "⚡ On-Demand active: " .. tostring(odState.summary), { stage = "IN", minLevel = 1 })
        else
            pushEvent("run", "✓ On-Demand finished; resuming passives", { stage = "IN", minLevel = 1 })
        end
    end
    runtimeState._prevOdWork = odNow

    ctx.odState = odState
    ctx.getOdMatch = getOdMatch
end

local function stepEvaluateRecipes(cfg, runtimeState, ctx, nowSec, pushEvent)
    local stock = ctx.stock
    local stockPolled = ctx.stockPolled
    local onlineEnabled = ctx.onlineEnabled
    local fleetCoilLimit = ctx.fleetMaxKnownHeat or math.huge

    local function doesChannelWantConv(chId, jobMode, rc, belowTarget)
        local saw = false
        for idx = 1, #onlineEnabled do
            local entry = onlineEnabled[idx]
            if not chId or entry.chId == chId then
                saw = true
                if not entry.supportsConvControl then
                    if entry.convergenceEnabled then
                        return true
                    end
                elseif Scheduler.doesJobWantConvergence(cfg, jobMode, rc, entry.convOverride, entry.discountPct, belowTarget) then
                    return true
                end
            end
        end
        if not saw then
            if runtimeState.convControlSupported == false then
                return false
            end
            return Scheduler.doesJobWantConvergence(cfg, jobMode, rc, "global", 50, belowTarget)
        end
        return false
    end

    runtimeState._convBelowActive = runtimeState._convBelowActive or {}

    -- Track currently running recipes per channel (for 99%/100% stock hysteresis)
    local currentlyRunningMap = {}
    for i = 1, #cfg.channels do
        local ch = cfg.channels[i]
        if ch.currentFamilyId then
            currentlyRunningMap[ch.currentFamilyId] = true
        end
    end

    -- Evaluate all 27 recipe families
    local needyQueue = {}
    for i = 1, #RecipesDB.FAMILIES do
        local fam = RecipesDB.FAMILIES[i]
        local rc = cfg.recipes[fam.id]
        local isForever = (rc.forever == true)
        local isFbFamily = isForever or (cfg.fallbackEnabled and fam.id == cfg.fallbackFamilyId)
        local previewJobMode = (isForever or (isFbFamily and not rc.enabled)) and "FALLBACK" or "PASSIVE"
        local convBelowTarget = (rc.convMode == "below_tgt")
            and Scheduler.isRecipeBelowConvTarget(cfg, stock, fam, rc, runtimeState._convBelowActive[fam.id] == true)
            or false
        if not ctx.useCache then
            runtimeState._convBelowActive[fam.id] = (rc.convMode == "below_tgt") and convBelowTarget or nil
        end
        local recWantsConv = doesChannelWantConv(nil, previewJobMode, rc, convBelowTarget)
        local mod, tCode, tIdx, tData, catFluid, tInfo, meta = Scheduler.resolveRecipe(fam, rc, cfg, stock, {
            wantConvergence = recWantsConv,
            isFallback = isFbFamily,
        })
        local outs = Scheduler.getOutputCandidates(tData, fam)
        local outIdx = math.max(1, math.min(#outs, rc.outputIndex or 1))
        local trackedOut = outs[outIdx] or fam.primaryOutput
        local currentStock = Scheduler.getOutputStock(stock, trackedOut)
        local targetStock = math.max(1, tonumber(rc.target) or 1)
        local isRunning = currentlyRunningMap[fam.id] == true

        -- 99%/100% hysteresis (24/7 recipes always stay needy)
        local needsStock = false
        if rc.enabled then
            if isForever then
                needsStock = true
            elseif isRunning then
                needsStock = currentStock < targetStock
            else
                needsStock = currentStock < math.floor(targetStock * 0.99)
            end
        end
        if not ctx.useCache then
            if rc.enabled and not isForever then
                if runtimeState._prevNeedsStock[fam.id] == true and needsStock == false then
                    pushEvent("run", string.format("✓ Target met: %s", fam.name), { stage = "IN", minLevel = 1 })
                end
                runtimeState._prevNeedsStock[fam.id] = needsStock
            else
                runtimeState._prevNeedsStock[fam.id] = nil
            end
        end

        local runnable, reason = Scheduler.checkRecipeRunnable(cfg, stock, fam, rc, isRunning, isFbFamily, {
            wantConvergence = recWantsConv,
            maxCoilHeat = fleetCoilLimit,
        })
        local availBatches = 0
        if runnable then
            availBatches = Scheduler.countAvailableBatches(cfg, stock, fam, rc, {
                wantConvergence = recWantsConv,
                isFallback = isFbFamily,
                isCurrentlyRunning = isRunning,
            })
        end

        local ratio = currentStock / targetStock
        local stateStr = "Disabled"
        if isFbFamily and not rc.enabled then
            stateStr = runnable and "Fallback Ready" or ("Fallback: " .. reason)
        elseif rc.enabled then
            if isForever then
                if not runnable then
                    stateStr = reason
                else
                    stateStr = isRunning and "Looping 24/7" or "Ready 24/7"
                end
            elseif not needsStock then
                stateStr = "Stock Full"
            elseif not runnable then
                stateStr = reason
            else
                stateStr = isRunning and "Running" or "Queued"
            end
        end

        local sigKey = string.format("%s:%s:%s", fam.id, mod and mod.id or "std", tCode or "NONE")
        local ratePerMin = stockPolled
            and updateRateTracker(runtimeState._rateTrackers, "rec:" .. fam.id, currentStock, nowSec)
            or (runtimeState.recipeStatus[fam.id] and runtimeState.recipeStatus[fam.id].ratePerMin or nil)
        local etaSec = nil
        if (not isForever) and rc.enabled and needsStock and ratePerMin and ratePerMin > 0 and currentStock < targetStock then
            etaSec = ((targetStock - currentStock) / ratePerMin) * 60.0
        end
        local entry = {
            familyId = fam.id,
            priority = rc.priority or i,
            modifier = mod,
            tierCode = tCode,
            tierIndex = tIdx,
            tierData = tData,
            tierInfo = tInfo,
            meta = meta,
            sigKey = sigKey,
            trackedOutput = trackedOut,
            currentStock = currentStock,
            targetStock = targetStock,
            ratio = ratio,
            isForever = isForever,
            convBelowTarget = convBelowTarget,
            needsStock = needsStock,
            runnable = runnable,
            availBatches = availBatches,
            reason = reason,
            stateStr = stateStr,
            catalystFluid = catFluid,
            catalystAmount = (meta and meta.convCatAmount) or (tData and tData.catalystAmount) or 1000,
            ratePerMin = ratePerMin,
            etaSec = etaSec,
            activeDtpfs = {},
        }
        runtimeState.recipeStatus[fam.id] = entry

        if rc.enabled and needsStock and runnable then
            needyQueue[#needyQueue + 1] = entry
        end
    end

    -- Authoritative priority order, then running hysteresis tie-break, then lowest stock/target ratio
    table.sort(needyQueue, function(a, b)
        if a.priority ~= b.priority then
            return a.priority < b.priority
        end
        local aRun = currentlyRunningMap[a.familyId] and 1 or 0
        local bRun = currentlyRunningMap[b.familyId] and 1 or 0
        if aRun ~= bRun then return aRun > bRun end
        if math.abs(a.ratio - b.ratio) > 0.001 then
            return a.ratio < b.ratio
        end
        return a.familyId < b.familyId
    end)

    return needyQueue, currentlyRunningMap, doesChannelWantConv
end

-- Lightweight per-DTPF direct & embodied catalyst EU/t estimator
function Scheduler.estimateDtpfPower(st, tData, tCode, catTierIdx, wantConv)
    if not tData then return 0, 0, false end
    local baseEut = tonumber(tData.eut) or 0
    local durTicks = math.max(1, tonumber(tData.durationTicks) or 200)
    local speedDiv = wantConv and 4 or 2
    local liveDirect = (st and st.online and st.active and (tonumber(st.liveEut) or 0) > 0) and tonumber(st.liveEut) or 0
    local maxEu = (st and (tonumber(st.maxInputEu) or 0) > 0) and tonumber(st.maxInputEu) or 0
    local cap = (liveDirect > 0) and liveDirect or ((maxEu > 0) and maxEu or baseEut)

    local e = baseEut
    local d = durTicks
    for _ = 1, 16 do
        if e <= 0 or (e * 4) > cap or d < speedDiv then break end
        e = e * 4
        d = math.max(1, math.floor(d / speedDiv))
    end

    local directEut = (liveDirect > 0) and liveDirect or e
    local eutIsEstimate = (liveDirect == 0)

    local ct = TIER_BY_INDEX[catTierIdx or 4] or TIER_BY_INDEX[4]
    local discFrac = math.max(0, math.min(0.5, (tonumber(st and st.discountPct) or 0) / 100.0))
    local baseCat = (tCode and tCode ~= "NONE") and (tonumber(tData.catalystAmount) or 0) or 0
    local catPerCraft = 0
    if wantConv then
        local extraCat = (st and (tonumber(st.extraCatalystNeeded) or 0) > 0) and tonumber(st.extraCatalystNeeded)
            or Scheduler.estimateConvergenceCatalyst(tData, ct)
        catPerCraft = (baseCat + extraCat) * (1.0 - discFrac)
    elseif baseCat > 0 then
        catPerCraft = baseCat * (1.0 - discFrac)
    end
    local catEut = (ct and catPerCraft > 0 and directEut > 0)
        and math.floor((catPerCraft / math.max(1, d)) * ct.energy)
        or 0
    return math.floor(directEut + 0.5), catEut, eutIsEstimate
end

local function stepAssignPassiveChannels(cfg, runtimeState, ctx, needyQueue, currentlyRunningMap, doesChannelWantConv, pushEvent)
    local stock = ctx.stock
    local rawDtpfSt = ctx.rawDtpfSt
    local dtpfHasOdWork = ctx.dtpfHasOdWork
    local channelOdInfo = ctx.channelOdInfo
    local fleetCoilLimit = ctx.fleetMaxKnownHeat or math.huge
    local channelMaxHeat = ctx.channelMaxHeat
    local channelMaxInputEu = ctx.channelMaxInputEu or {}
    local channelRoles = ctx.channelRoles
    local channelCatOverrides = ctx.channelCatOverrides
    local channelDtpfs = ctx.channelDtpfs
    local odState = ctx.odState

    local function countChannelDtpfs(chId)
        local n = 0
        local lst = channelDtpfs[chId] or {}
        for k = 1, #lst do
            local dObj = cfg.dtpfs[lst[k]]
            if dObj and (dObj.enabled ~= false) and dObj.roleOverride ~= "od_only" then
                n = n + 1
            end
        end
        return math.max(1, n)
    end

    local usedRecipes = {}
    local assignedCount = {}
    local assignedDtpfCount = {}
    for i = 1, #cfg.channels do
        local ch = cfg.channels[i]
        local cr = channelRoles[ch.id]
        local chOd = channelOdInfo[ch.id]
        local odPreempt = (cfg.pausePassivesOnOD and ch.shareOnDemand ~= false) and (chOd and chOd.hasWork == true)
        if ch.enabled and (not odPreempt) and cr and cr.pinnedFamilyId and not (cr.hasAny and cr.allOdOnly) then
            usedRecipes[cr.pinnedFamilyId] = true
            assignedCount[cr.pinnedFamilyId] = (assignedCount[cr.pinnedFamilyId] or 0) + 1
            assignedDtpfCount[cr.pinnedFamilyId] = (assignedDtpfCount[cr.pinnedFamilyId] or 0) + countChannelDtpfs(ch.id)
        end
    end

    local function getChannelOvMeta(ch)
        local chHeatLimit = channelMaxHeat[ch.id] or fleetCoilLimit
        local chRole = channelRoles[ch.id] or {
            allFallbackOnly = false,
            allPassiveOnly = false,
            allOdOnly = false,
            hasAny = false,
            pinnedFamilyId = nil,
            pinMode = nil,
        }
        local chCatOv = nil
        local ovInfo = channelCatOverrides[ch.id]
        if ovInfo and ovInfo.same and ovInfo.val and ovInfo.val >= 1 then
            chCatOv = ovInfo.val
        end
        return chHeatLimit, chRole, chCatOv
    end

    local function canChannelRunCand(chHeatLimit, chRole, cand)
        if ((cand.tierData and cand.tierData.coilHeat) or 0) > chHeatLimit then
            return false
        end
        if chRole.hasAny and chRole.allPassiveOnly and cand.isForever then
            return false
        end
        if chRole.hasAny and chRole.allFallbackOnly and not cand.isForever then
            return false
        end
        return true
    end

    local function assignChosenToChannel(ch, chCatOv, chosen)
        usedRecipes[chosen.familyId] = true
        assignedCount[chosen.familyId] = (assignedCount[chosen.familyId] or 0) + 1
        assignedDtpfCount[chosen.familyId] = (assignedDtpfCount[chosen.familyId] or 0) + countChannelDtpfs(ch.id)
        local fam = FAMILY_BY_ID[chosen.familyId]
        local rc = cfg.recipes[chosen.familyId]
        local chJobMode = chosen.isForever and "FALLBACK" or "PASSIVE"
        local chWantsConv = doesChannelWantConv(ch.id, chJobMode, rc, chosen.convBelowTarget)
        local mod, tCode, tIdx, tData, catFluid, _, meta = Scheduler.resolveRecipe(fam, rc, cfg, stock, {
            wantConvergence = chWantsConv,
            isFallback = chosen.isForever or (chosen.familyId == cfg.fallbackFamilyId),
            catOverride = chCatOv,
        })
        applyAndRecordChannelJob(cfg, stock, runtimeState, ch, {
            mode = chJobMode,
            famId = chosen.familyId,
            fam = fam,
            mod = mod,
            tCode = tCode,
            tIdx = tIdx,
            tData = tData,
            catFluid = catFluid,
            meta = meta,
            isForever = chosen.isForever,
        }, ctx.useCache, pushEvent)
        if chosen.isForever then
            chosen.stateStr = (cfg.armed and "Looping (" or "Would Loop (") .. ch.id .. ")"
        else
            chosen.stateStr = (cfg.armed and "Running (" or "Would Run (") .. ch.id .. ")"
        end
    end

    local function assignFallbackOrIdleToChannel(ch, chHeatLimit, chRole, chCatOv)
        if cfg.fallbackEnabled and not (chRole.hasAny and chRole.allPassiveOnly) then
            local fbId = cfg.fallbackFamilyId or "molten_infinity"
            local fbFam = FAMILY_BY_ID[fbId]
            local fbRc = fbFam and cfg.recipes[fbId]
            local fbSt = runtimeState.recipeStatus[fbId]
            local maxD = (fbRc and tonumber(fbRc.maxDtpfs)) or 0
            local curDtpfs = assignedDtpfCount[fbId] or 0
            if fbFam and (maxD <= 0 or curDtpfs < maxD) then
                local chFbWantsConv = doesChannelWantConv(ch.id, "FALLBACK", fbRc, fbSt and fbSt.convBelowTarget)
                local fbMod, fbCode, fbIdx, fbData, fbCatFluid, _, fbMeta = Scheduler.resolveRecipe(fbFam, fbRc, cfg, stock, {
                    wantConvergence = chFbWantsConv,
                    isFallback = true,
                    catOverride = chCatOv,
                })
                local fbRunning = (currentlyRunningMap[fbId] == true)
                local fbOk, fbWhy = Scheduler.checkRecipeRunnable(cfg, stock, fbFam, fbRc, fbRunning, true, {
                    wantConvergence = chFbWantsConv,
                    maxCoilHeat = chHeatLimit,
                    catOverride = chCatOv,
                })
                if fbOk and fbData then
                    usedRecipes[fbId] = true
                    assignedCount[fbId] = (assignedCount[fbId] or 0) + 1
                    assignedDtpfCount[fbId] = (assignedDtpfCount[fbId] or 0) + countChannelDtpfs(ch.id)
                    applyAndRecordChannelJob(cfg, stock, runtimeState, ch, {
                        mode = "FALLBACK",
                        famId = fbId,
                        fam = fbFam,
                        mod = fbMod,
                        tCode = fbCode,
                        tIdx = fbIdx,
                        tData = fbData,
                        catFluid = fbCatFluid,
                        meta = fbMeta,
                        labelPrefix = "Fallback: ",
                    }, ctx.useCache, pushEvent)
                    if fbSt then
                        fbSt.stateStr = (cfg.armed and "Fallback (" or "Would FB (") .. ch.id .. ")"
                    end
                    return
                end
                if cfg.armed then
                    clearPassiveChannelWithLog(ch, stock, runtimeState, ctx.useCache, pushEvent, "fallback blocked")
                end
                local fbReason = tostring(fbWhy or (fbSt and fbSt.reason) or "No inputs")
                runtimeState.channelStatus[ch.id] = {
                    mode = "IDLE",
                    label = "Idle (Fallback blocked: " .. fbReason .. ")",
                    shortLabel = "Fallback Wait: " .. fbReason,
                }
                return
            end
            if cfg.armed then
                clearPassiveChannelWithLog(ch, stock, runtimeState, ctx.useCache, pushEvent, "fallback capped")
            end
            local capReason = (maxD > 0) and string.format("Max %d DTPFs", maxD) or "No inputs"
            runtimeState.channelStatus[ch.id] = {
                mode = "IDLE",
                label = "Idle (Fallback blocked: " .. capReason .. ")",
                shortLabel = "Fallback Wait: " .. capReason,
            }
            return
        end
        if cfg.armed then
            clearPassiveChannelWithLog(ch, stock, runtimeState, ctx.useCache, pushEvent, "targets full")
        end
        runtimeState.channelStatus[ch.id] = {
            mode = "IDLE",
            label = cfg.fallbackEnabled and "Idle (Passive-Only)" or "Idle (Fallback OFF)",
            shortLabel = cfg.fallbackEnabled and "Targets Full (Passive-Only)" or "All Targets Full (FB OFF)",
        }
    end

    -- Phase A: handle disabled, OD-preempted, OD-only, and Pinned channels first; collect Auto slots
    local autoSlots = {}
    for i = 1, #cfg.channels do
        local ch = cfg.channels[i]
        local chHeatLimit, chRole, chCatOv = getChannelOvMeta(ch)
        local chOd = channelOdInfo[ch.id]
        local chHasOd = (chOd and chOd.hasWork == true)

        if not ch.enabled then
            if cfg.armed then
                clearPassiveChannelWithLog(ch, stock, runtimeState, ctx.useCache, pushEvent, "disabled")
            end
            runtimeState.channelStatus[ch.id] = { mode = "Disabled", label = "Disabled", shortLabel = "Channel Disabled" }
        elseif (cfg.pausePassivesOnOD and ch.shareOnDemand ~= false) and chHasOd then
            local odSum = (chOd and chOd.summary) or odState.summary or "Active"
            if cfg.armed then
                clearPassiveChannelWithLog(ch, stock, runtimeState, ctx.useCache, pushEvent, "OD preempt")
            end
            runtimeState.channelStatus[ch.id] = {
                mode = "ON-DEMAND",
                label = "OD Active: " .. odSum,
                shortLabel = "OD: " .. odSum,
            }
        elseif chRole.hasAny and chRole.allOdOnly then
            if cfg.armed then
                clearPassiveChannelWithLog(ch, stock, runtimeState, ctx.useCache, pushEvent, "OD-only")
            end
            runtimeState.channelStatus[ch.id] = {
                mode = "IDLE",
                label = "Reserved for On-Demand",
                shortLabel = "OD-Only (Idle)",
            }
        elseif chRole.pinnedFamilyId then
            local pinId = chRole.pinnedFamilyId
            local isLoopPin = (chRole.pinMode == "pinned_loop")
            local pinFam = FAMILY_BY_ID[pinId]
            local pinRc = pinFam and cfg.recipes[pinId]
            local jobKind = isLoopPin and "FALLBACK" or "PASSIVE"
            local pinSt = runtimeState.recipeStatus[pinId]
            local chPinWantsConv = doesChannelWantConv(ch.id, jobKind, pinRc, pinSt and pinSt.convBelowTarget)
            local pinMod, pinCode, pinIdx, pinData, pinCatFluid, _, pinMeta = Scheduler.resolveRecipe(pinFam, pinRc, cfg, stock, {
                wantConvergence = chPinWantsConv,
                isFallback = isLoopPin,
                catOverride = chCatOv,
            })
            local outs = Scheduler.getOutputCandidates(pinData, pinFam)
            local outIdx = math.max(1, math.min(#outs, (pinRc and pinRc.outputIndex) or 1))
            local trackedOut = outs[outIdx] or (pinFam and pinFam.primaryOutput)
            local curStock = Scheduler.getOutputStock(stock, trackedOut)
            local tgtStock = math.max(1, tonumber(pinRc and pinRc.target) or 1)
            local pinRunning = (currentlyRunningMap[pinId] == true)
            local pinNeeds = isLoopPin or (curStock < (pinRunning and tgtStock or (tgtStock * 0.99)))

            if not pinNeeds then
                if cfg.armed then
                    clearPassiveChannelWithLog(ch, stock, runtimeState, ctx.useCache, pushEvent, "pin target met")
                end
                if pinSt then
                    pinSt.stateStr = "Target Met (" .. ch.id .. " PIN)"
                end
                runtimeState.channelStatus[ch.id] = {
                    mode = "IDLE",
                    pinned = true,
                    familyId = pinId,
                    label = "Pinned Target Met: " .. pinFam.name,
                    shortLabel = "Target Met: " .. pinFam.name,
                }
            else
                local pinOk, pinReason = Scheduler.checkRecipeRunnable(cfg, stock, pinFam, pinRc, pinRunning, isLoopPin, {
                    wantConvergence = chPinWantsConv,
                    maxCoilHeat = chHeatLimit,
                    catOverride = chCatOv,
                })
                if pinOk and pinData then
                    applyAndRecordChannelJob(cfg, stock, runtimeState, ch, {
                        mode = jobKind,
                        pinned = true,
                        famId = pinId,
                        fam = pinFam,
                        mod = pinMod,
                        tCode = pinCode,
                        tIdx = pinIdx,
                        tData = pinData,
                        catFluid = pinCatFluid,
                        meta = pinMeta,
                        labelPrefix = isLoopPin and "Pin 24/7: " or "Pinned: ",
                    }, ctx.useCache, pushEvent)
                    if pinSt then
                        if cfg.armed then
                            pinSt.stateStr = (isLoopPin and "Looping (" or "Running (") .. ch.id .. (isLoopPin and ")" or " PIN)")
                        else
                            pinSt.stateStr = (isLoopPin and "Would Loop (" or "Would Pin (") .. ch.id .. ")"
                        end
                    end
                else
                    if cfg.armed then
                        clearPassiveChannelWithLog(ch, stock, runtimeState, ctx.useCache, pushEvent, "pin blocked")
                    end
                    local rsn = tostring(pinReason or (pinSt and pinSt.reason) or "Blocked")
                    if pinSt then
                        pinSt.stateStr = rsn .. " (" .. ch.id .. " PIN)"
                    end
                    runtimeState.channelStatus[ch.id] = {
                        mode = "IDLE",
                        pinned = true,
                        familyId = pinId,
                        label = "Pin Blocked: " .. rsn,
                        shortLabel = "Pin Wait: " .. rsn,
                    }
                end
            end
        else
            autoSlots[#autoSlots + 1] = {
                idx = i,
                ch = ch,
                heatLimit = chHeatLimit,
                role = chRole,
                catOv = chCatOv,
                maxEu = channelMaxInputEu[ch.id] or 0,
                assigned = false,
            }
        end
    end

    -- Phase B: assign remaining unpinned channels (Power-Aware when hatches differ & powerAwareAssign ~= false)
    local hasHatchDiff = false
    if cfg.powerAwareAssign ~= false and #autoSlots > 1 then
        local firstEu = autoSlots[1].maxEu
        for s = 2, #autoSlots do
            if autoSlots[s].maxEu ~= firstEu then
                hasHatchDiff = true
                break
            end
        end
    end

    if hasHatchDiff then
        local function pickSlotForCandidate(cand)
            local candRc = cfg.recipes[cand.familyId]
            local candMode = cand.isForever and "FALLBACK" or "PASSIVE"
            local bestConvSlot, bestConvEu = nil, -1
            local bestPlainSlot, bestPlainEu = nil, math.huge
            for s = 1, #autoSlots do
                local sl = autoSlots[s]
                if (not sl.assigned) and canChannelRunCand(sl.heatLimit, sl.role, cand) then
                    if doesChannelWantConv(sl.ch.id, candMode, candRc, cand.convBelowTarget) then
                        if sl.maxEu > bestConvEu then
                            bestConvEu = sl.maxEu
                            bestConvSlot = sl
                        end
                    else
                        if sl.maxEu < bestPlainEu then
                            bestPlainEu = sl.maxEu
                            bestPlainSlot = sl
                        end
                    end
                end
            end
            return bestConvSlot or bestPlainSlot
        end

        -- Pass 1: distinct priority order -> largest hatch for Converged, smallest hatch for Non-Converged
        for q = 1, #needyQueue do
            local cand = needyQueue[q]
            if not usedRecipes[cand.familyId] then
                local sl = pickSlotForCandidate(cand)
                if sl then
                    sl.assigned = true
                    assignChosenToChannel(sl.ch, sl.catOv, cand)
                end
            end
        end

        -- Pass 2: parallel sharing across remaining free slots
        if cfg.allowParallelSameRecipe then
            for _ = 1, #autoSlots do
                local chosen, chosenSlot, bestScore = nil, nil, nil
                for q = 1, #needyQueue do
                    local cand = needyQueue[q]
                    local candRc = cfg.recipes[cand.familyId]
                    local maxD = (candRc and tonumber(candRc.maxDtpfs)) or 0
                    local curDtpfs = assignedDtpfCount[cand.familyId] or 0
                    local availB = cand.availBatches or math.huge
                    local loopRank = cand.isForever and 1 or 0
                    local cnt = assignedCount[cand.familyId] or 0
                    if (not chosen)
                        or (loopRank < bestScore.loopRank)
                        or (loopRank == bestScore.loopRank and cnt < bestScore.cnt) then
                        local sl = nil
                        if maxD <= 0 or curDtpfs < maxD then
                            for s = 1, #autoSlots do
                                local probe = autoSlots[s]
                                if (not probe.assigned)
                                    and canChannelRunCand(probe.heatLimit, probe.role, cand)
                                    and availB >= (curDtpfs + countChannelDtpfs(probe.ch.id)) then
                                    sl = pickSlotForCandidate(cand)
                                    break
                                end
                            end
                        end
                        if sl then
                            chosen = cand
                            chosenSlot = sl
                            bestScore = { loopRank = loopRank, cnt = cnt }
                        end
                    end
                end
                if not chosen or not chosenSlot then break end
                chosenSlot.assigned = true
                assignChosenToChannel(chosenSlot.ch, chosenSlot.catOv, chosen)
            end
        end

        -- Pass 3: Fallback / Idle sorted ascending (unless Fallback explicitly runs Converged)
        local fbRc = cfg.fallbackEnabled and cfg.fallbackFamilyId and cfg.recipes[cfg.fallbackFamilyId] or nil
        local fbSt = cfg.fallbackEnabled and cfg.fallbackFamilyId and runtimeState.recipeStatus[cfg.fallbackFamilyId] or nil
        local fbWantsConv = fbRc and doesChannelWantConv(nil, "FALLBACK", fbRc, fbSt and fbSt.convBelowTarget) or false
        local rem = {}
        for s = 1, #autoSlots do
            if not autoSlots[s].assigned then rem[#rem + 1] = autoSlots[s] end
        end
        table.sort(rem, function(a, b)
            if a.maxEu ~= b.maxEu then
                return fbWantsConv and (a.maxEu > b.maxEu) or (a.maxEu < b.maxEu)
            end
            return a.idx < b.idx
        end)
        for k = 1, #rem do
            local sl = rem[k]
            sl.assigned = true
            assignFallbackOrIdleToChannel(sl.ch, sl.heatLimit, sl.role, sl.catOv)
        end
    else
        for s = 1, #autoSlots do
            local sl = autoSlots[s]
            local chosen = nil
            local chUnits = countChannelDtpfs(sl.ch.id)
            for q = 1, #needyQueue do
                local cand = needyQueue[q]
                if canChannelRunCand(sl.heatLimit, sl.role, cand) and not usedRecipes[cand.familyId] then
                    chosen = cand
                    break
                end
            end
            if not chosen and cfg.allowParallelSameRecipe then
                local bestScore = nil
                for q = 1, #needyQueue do
                    local cand = needyQueue[q]
                    local candRc = cfg.recipes[cand.familyId]
                    local maxD = (candRc and tonumber(candRc.maxDtpfs)) or 0
                    local curDtpfs = assignedDtpfCount[cand.familyId] or 0
                    local availB = cand.availBatches or math.huge
                    if canChannelRunCand(sl.heatLimit, sl.role, cand) and (maxD <= 0 or curDtpfs < maxD) and availB >= (curDtpfs + chUnits) then
                        local loopRank = cand.isForever and 1 or 0
                        local cnt = assignedCount[cand.familyId] or 0
                        if (not chosen)
                            or (loopRank < bestScore.loopRank)
                            or (loopRank == bestScore.loopRank and cnt < bestScore.cnt) then
                            chosen = cand
                            bestScore = { loopRank = loopRank, cnt = cnt }
                        end
                    end
                end
            end
            if chosen then
                assignChosenToChannel(sl.ch, sl.catOv, chosen)
            else
                assignFallbackOrIdleToChannel(sl.ch, sl.heatLimit, sl.role, sl.catOv)
            end
        end
    end

    for i = 1, #cfg.channels do
        local ch = cfg.channels[i]
        local chStAfter = runtimeState.channelStatus[ch.id]
        if chStAfter then
            local chList = channelDtpfs[ch.id] or {}
            local chTag = (#chList == 1) and string.format("%s (#%d)", ch.id, chList[1]) or ch.id
            local isActiveMode = (chStAfter.mode == "PASSIVE" or chStAfter.mode == "FALLBACK")
            if isActiveMode and chStAfter.familyId and runtimeState.recipeStatus[chStAfter.familyId] then
                local activeList = runtimeState.recipeStatus[chStAfter.familyId].activeDtpfs
                for k = 1, #chList do
                    local dIdx = chList[k]
                    local dObj = cfg.dtpfs[dIdx]
                    local dRaw = rawDtpfSt[dIdx]
                    local canRunThis = dObj and (dObj.enabled ~= false) and dRaw and dRaw.online
                        and dObj.roleOverride ~= "od_only"
                        and (not dtpfHasOdWork[dIdx])
                        and not (chStAfter.mode == "FALLBACK" and dObj.roleOverride == "passive_only")
                    if canRunThis then
                        activeList[#activeList + 1] = dIdx
                    end
                end
            end

            local curSig = tostring(chStAfter.mode) .. ":" .. tostring(chStAfter.familyId or chStAfter.shortLabel or chStAfter.label or "")
            local prevSig = runtimeState._prevChSig[ch.id]
            if prevSig ~= curSig then
                runtimeState._prevChSig[ch.id] = curSig
                local famObj = chStAfter.familyId and FAMILY_BY_ID[chStAfter.familyId]
                local famName = (famObj and famObj.name) or tostring(chStAfter.familyId or "")
                if chStAfter.mode == "PASSIVE" and famName ~= "" then
                    pushEvent("run", chTag .. " → " .. famName, { stage = "DEC", minLevel = 1 })
                elseif chStAfter.mode == "FALLBACK" and famName ~= "" then
                    pushEvent("loop", chTag .. " → Loop: " .. famName, { stage = "DEC", minLevel = 1 })
                elseif chStAfter.mode == "IDLE" and prevSig and not prevSig:find("^IDLE:") then
                    pushEvent("idle", chTag .. " → " .. tostring(chStAfter.shortLabel or "Idle"), { stage = "DEC", minLevel = 1 })
                end
            end

            if isActiveMode and chStAfter.usedFallbackCat and chStAfter.tierCode then
                if runtimeState._prevCatFb[ch.id] ~= chStAfter.tierCode then
                    runtimeState._prevCatFb[ch.id] = chStAfter.tierCode
                    pushEvent("warn", "↓ " .. ch.id .. " catalyst fallback → " .. tostring(chStAfter.tierCode), { stage = "WARN", minLevel = 1 })
                end
            else
                runtimeState._prevCatFb[ch.id] = nil
            end
        end
    end

    local seenBnFam = {}
    for i = 1, #cfg.channels do
        local chStPin = runtimeState.channelStatus[cfg.channels[i].id]
        if chStPin and chStPin.pinned and chStPin.mode == "IDLE" and chStPin.label and chStPin.label:find("^Pin Blocked:") then
            local pFam = chStPin.familyId and FAMILY_BY_ID[chStPin.familyId]
            if chStPin.familyId then seenBnFam[chStPin.familyId] = true end
            runtimeState.bottlenecks[#runtimeState.bottlenecks + 1] = {
                kind = "pin",
                familyId = chStPin.familyId,
                name = (pFam and pFam.name) or tostring(chStPin.familyId),
                reason = chStPin.shortLabel or chStPin.label,
            }
        end
    end
    return seenBnFam
end

local function stepUpdateDtpfControls(cfg, runtimeState, ctx, opts, seenBnFam, pushEvent)
    local useCache = ctx.useCache
    local stock = ctx.stock
    local globalOdAddr = ctx.globalOdAddr
    local rawDtpfSt = ctx.rawDtpfSt
    local dtpfOdState = ctx.dtpfOdState
    local dtpfHasOdWork = ctx.dtpfHasOdWork
    local odState = ctx.odState
    local getOdMatch = ctx.getOdMatch

    local sumDirectEut, sumCatEut, maxUnitEut, maxUnitIdx = 0, 0, 0, nil
    for i = 1, #cfg.dtpfs do
        local d = cfg.dtpfs[i]
        local st = rawDtpfSt[i] or Hardware.getDTPFStatus(d, { allowSensorCache = (opts.allowSensorCache == true) })
        local chSt = runtimeState.channelStatus[d.channelId or "ch1"]
        local effConv = effectiveDTPFConvMode(cfg, d)
        local odPreemptsDtpf = (dtpfHasOdWork[i] == true)
        local dOd = dtpfOdState[i] or odState

        local wantConv = false
        local prefCat = (d.catOverride and d.catOverride >= 1) and d.catOverride or (cfg.defaultCatalystTier or 4)
        local wantCatTier = prefCat
        local jobMode = "IDLE"
        local jobLabel = "All Targets Full"
        local jobFamilyId = nil
        local jobTierData, jobTierCode = nil, nil

        local shouldAllowWork = (d.enabled ~= false)
        if shouldAllowWork and (not odPreemptsDtpf) then
            if d.roleOverride == "od_only" then
                shouldAllowWork = false
            elseif d.roleOverride == "passive_only" and (not chSt or chSt.mode ~= "PASSIVE") then
                shouldAllowWork = false
            end
        end

        if not d.enabled then
            wantConv = false
            jobMode = "DISABLED"
            jobLabel = "Disabled by OC"
        elseif odPreemptsDtpf then
            local odAddrKey = (d.odNetAddr and d.odNetAddr ~= "global") and d.odNetAddr or (globalOdAddr or "__global")
            local odM = getOdMatch(odAddrKey, dOd)
            wantConv = computeOnDemandWantConv(cfg, d, st, dOd, odM)
            wantCatTier = pickAvailableCatalystTier(cfg, stock, prefCat)
            jobMode = "ON-DEMAND"
            jobLabel = "OD: " .. (dOd.summary or "Active")
            jobTierData = odM and odM.tierData or nil
            jobTierCode = odM and odM.tierCode or nil
        elseif chSt and (chSt.mode == "PASSIVE" or chSt.mode == "FALLBACK") then
            jobMode = chSt.mode
            jobFamilyId = chSt.familyId
            local fam = chSt.familyId and FAMILY_BY_ID[chSt.familyId]
            local famRc = chSt.familyId and cfg.recipes[chSt.familyId] or nil
            local labelPrefix = (chSt.mode == "FALLBACK" and "* ") or (chSt.pinned and "◆ ") or ""
            jobLabel = labelPrefix .. (fam and fam.name or chSt.familyId or chSt.mode)

            local recSt = runtimeState.recipeStatus[chSt.familyId]
            wantConv = Scheduler.doesJobWantConvergence(cfg, chSt.mode, famRc, d.convOverride, st.discountPct, recSt and recSt.convBelowTarget)
            jobTierData = chSt.tierData or (recSt and recSt.tierData)
            jobTierCode = chSt.tierCode or (recSt and recSt.tierCode)

            -- Never deadlock a catalyst-free ("NONE") passive recipe when Convergence catalyst is unavailable or disabled
            if chSt.isNoneCat then
                if not chSt.convSatisfied then
                    wantConv = false
                else
                    wantCatTier = chSt.convCatIndex or prefCat
                end
            else
                wantCatTier = (d.catOverride and d.catOverride >= 1) and d.catOverride or chSt.convCatIndex or prefCat
            end
        else
            wantConv = (d.convOverride == "always") or ((d.convOverride == "global" or not d.convOverride) and cfg.globalConvMode == "always")
            wantCatTier = pickAvailableCatalystTier(cfg, stock, prefCat)
            if chSt and chSt.mode == "ON-DEMAND" then
                jobMode = "IDLE"
                jobLabel = "Hold (" .. tostring(chSt.shortLabel or "OD Paused") .. ")"
            else
                jobMode = chSt and chSt.mode or "IDLE"
                jobLabel = (chSt and (chSt.shortLabel or chSt.label)) or "All Targets Full"
            end
            if d.roleOverride == "pinned" or d.roleOverride == "pinned_loop" then
                jobFamilyId = d.pinnedFamilyId
            elseif chSt and chSt.familyId then
                jobFamilyId = chSt.familyId
            end
        end

        if st.online and st.supportsConvControl == false then
            -- Stock GTNH without DriverDTPF OC patch: preserve sensor-read DTPF GUI state
            wantConv = (st.convergenceEnabled == true)
        end

        if cfg.armed and st.online then
            if not useCache then
                -- Cover Conflict Detection: track if setWorkAllowed fails to stick across live polls
                if d._prevArmedReq ~= nil and d._prevArmedReq == shouldAllowWork and st.workAllowed ~= shouldAllowWork then
                    d._coverMismatch = (d._coverMismatch or 0) + 1
                elseif st.workAllowed == shouldAllowWork then
                    d._coverMismatch = 0
                end
                st.coverConflict = (d._coverMismatch or 0) >= 1
            end

            if st.workAllowed ~= shouldAllowWork then
                Hardware.setDTPFWorkAllowed(d, shouldAllowWork)
                if not useCache and not st.coverConflict then
                    runtimeState.stepStats.workWrites = (runtimeState.stepStats.workWrites or 0) + 1
                    pushEvent("out", string.format("%s: Work %s → %s",
                        d.name or ("DTPF #" .. i),
                        st.workAllowed and "ON" or "OFF",
                        shouldAllowWork and "ON" or "OFF"),
                        { stage = "OUT", minLevel = 2 })
                end
                if useCache then st.workAllowed = shouldAllowWork end
            end
            if not useCache then
                d._prevArmedReq = shouldAllowWork
            end

            if st.supportsConvControl ~= false and (st.convergenceEnabled ~= wantConv or st.catalystTier ~= wantCatTier) then
                Hardware.setDTPFConvergence(d, wantConv, wantCatTier)
                if not useCache then
                    runtimeState.stepStats.convWrites = (runtimeState.stepStats.convWrites or 0) + 1
                    local minLvl = (st.convergenceEnabled ~= wantConv) and 1 or 2
                    pushEvent("out", string.format("%s: Conv %s (T%d, %.0f%% disc)",
                        d.name or ("DTPF #" .. i),
                        wantConv and "ON" or "OFF",
                        wantCatTier or 4,
                        tonumber(st.discountPct) or 0),
                        { stage = "OUT", minLevel = minLvl })
                end
                if useCache then
                    st.convergenceEnabled = wantConv
                    st.catalystTier = wantCatTier
                end
            end
        else
            d._prevArmedReq = nil
            d._coverMismatch = 0
            st.coverConflict = false
        end

        -- GTNH MTEPlasmaForge reaches max 50% discount at running_time = 576,000 ticks (8.0h @ 20 t/s).
        local MAX_DISCOUNT_TICKS = 576000
        local discPct = tonumber(st.discountPct) or 0
        if (d.enabled ~= false) and st.online and st.active and discPct < 49.9 then
            local rTicks = tonumber(st.runningTicks) or 0
            local impliedPct = (rTicks / MAX_DISCOUNT_TICKS) * 50.0
            local remTicks
            if rTicks > 0 and rTicks < MAX_DISCOUNT_TICKS and math.abs(impliedPct - discPct) <= 1.5 then
                remTicks = MAX_DISCOUNT_TICKS - rTicks
            else
                remTicks = math.max(0, (1.0 - (discPct / 50.0)) * MAX_DISCOUNT_TICKS)
            end
            st.warmupEtaSec = remTicks / 20.0
            st.warmupRatePerMin = 50.0 / 480.0
        else
            st.warmupEtaSec = nil
            st.warmupRatePerMin = nil
        end

        local isPassiveArmed = (cfg.armed == true)
            and (st.online == true)
            and (d.enabled ~= false)
            and (shouldAllowWork == true)
            and (jobMode == "PASSIVE" or jobMode == "FALLBACK")
        local activeOrProg = (st.active == true) or ((st.progress or 0) > 0) or ((st.maxProgress or 0) > 0)
        local curJobSig = tostring(jobMode) .. ":" .. tostring(jobFamilyId or "")
        local prevJobSig = d._prevPassiveJobSig
        d._prevPassiveJobSig = curJobSig
        if isPassiveArmed and (not activeOrProg) and (not st.coverConflict) and (prevJobSig == curJobSig) then
            if not useCache then
                d._passiveStallPolls = (d._passiveStallPolls or 0) + 1
            end
        else
            d._passiveStallPolls = 0
        end
        st.passiveStalled = isPassiveArmed and ((d._passiveStallPolls or 0) >= 4)
        if st.passiveStalled ~= (d._wasPassiveStalled == true) then
            d._wasPassiveStalled = st.passiveStalled
            if st.passiveStalled then
                pushEvent("warn", string.format("! Passive Stalled on %s (%s)", d.name or ("DTPF #" .. i), tostring(jobLabel or jobFamilyId or "Idle")), { stage = "WARN", minLevel = 1 })
            end
        end

        st.name = d.name
        st.enabled = d.enabled
        st.shouldAllowWork = shouldAllowWork
        st.convOverride = d.convOverride
        st.effConv = effConv
        st.catOverride = d.catOverride
        st.roleOverride = d.roleOverride
        st.pinnedFamilyId = d.pinnedFamilyId
        st.channelId = d.channelId
        st.odNetAddr = d.odNetAddr or "global"
        st.odActive = odPreemptsDtpf
        st.wantConv = wantConv
        st.wantCatTier = wantCatTier
        st.jobMode = jobMode
        st.jobLabel = jobLabel
        st.familyId = jobFamilyId
        st.isPreview = not (cfg.armed == true)
        st.isCustom = (d.convOverride ~= "global")
            or ((d.catOverride or 0) > 0)
            or (d.roleOverride ~= "auto")
            or (not d.enabled)

        local directEut, catEut, eutIsEst = 0, 0, false
        if d.enabled ~= false and shouldAllowWork and (jobMode == "PASSIVE" or jobMode == "FALLBACK" or jobMode == "ON-DEMAND") then
            if st.active or (not cfg.armed) then
                if jobTierData then
                    directEut, catEut, eutIsEst = Scheduler.estimateDtpfPower(st, jobTierData, jobTierCode, wantCatTier, wantConv)
                elseif st.active and (tonumber(st.liveEut) or 0) > 0 then
                    directEut = math.floor(tonumber(st.liveEut) + 0.5)
                end
            end
        end
        st.directEut = directEut
        st.catEut = catEut
        st.totalEut = directEut + catEut
        st.eutIsEstimate = eutIsEst
        sumDirectEut = sumDirectEut + directEut
        sumCatEut = sumCatEut + catEut
        if directEut > maxUnitEut then
            maxUnitEut = directEut
            maxUnitIdx = i
        end

        if st.coverConflict then
            runtimeState.bottlenecks[#runtimeState.bottlenecks + 1] = {
                kind = "cover",
                name = d.name or ("DTPF #" .. i),
                reason = "Crowbar South GT Cover so OC can toggle Work",
                dtpfIdx = i,
            }
        elseif (d.enabled ~= false) and not st.online then
            runtimeState.bottlenecks[#runtimeState.bottlenecks + 1] = {
                kind = "offline",
                name = d.name or ("DTPF #" .. i),
                reason = "Controller MFU offline",
                dtpfIdx = i,
            }
        elseif st.passiveStalled then
            runtimeState.bottlenecks[#runtimeState.bottlenecks + 1] = {
                kind = "passive_stall",
                familyId = jobFamilyId,
                name = d.name or ("DTPF #" .. i),
                reason = "Armed >=4 polls at 0% on " .. tostring(jobLabel or "recipe") .. " (Check circuit/NC/hatch)",
                dtpfIdx = i,
            }
        end

        runtimeState.dtpfStatus[i] = st
    end

    local blockedRecipes = {}
    for i = 1, #RecipesDB.FAMILIES do
        local fam = RecipesDB.FAMILIES[i]
        local rc = cfg.recipes[fam.id]
        local rSt = runtimeState.recipeStatus[fam.id]
        if rc and rc.enabled and rSt and rSt.needsStock and not rSt.runnable and not seenBnFam[fam.id] then
            blockedRecipes[#blockedRecipes + 1] = {
                priority = rSt.priority or 999,
                familyId = fam.id,
                name = fam.name,
                reason = rSt.reason or "Blocked",
            }
        end
    end
    table.sort(blockedRecipes, function(a, b) return a.priority < b.priority end)
    for i = 1, #blockedRecipes do
        local b = blockedRecipes[i]
        runtimeState.bottlenecks[#runtimeState.bottlenecks + 1] = {
            kind = "recipe",
            familyId = b.familyId,
            name = b.name,
            reason = b.reason,
        }
    end
    runtimeState.powerSummary = {
        directEut = sumDirectEut,
        catEut = sumCatEut,
        totalEut = sumDirectEut + sumCatEut,
        maxDtpfIdx = maxUnitIdx,
    }
end

local LOG_LEVEL_RANK = { quiet = 1, normal = 2, raw = 3 }

local function fmtCompactLiters(n)
    n = tonumber(n) or 0
    if n >= 1e9 then return string.format("%.2fBL", n / 1e9) end
    if n >= 1e6 then return string.format("%.1fML", n / 1e6) end
    if n >= 1e3 then return string.format("%.1fKL", n / 1e3) end
    return string.format("%dL", math.floor(n + 0.5))
end

local function emitRawStepTrace(cfg, runtimeState, ctx, pushEvent)
    local fluids = (ctx.stock and ctx.stock.fluids) or {}
    local defIdx = math.max(1, math.min(5, math.floor(tonumber(cfg.defaultCatalystTier) or 4)))
    local defCat = TIER_BY_INDEX[defIdx] or TIER_BY_INDEX[4]
    local catAmt = fluids[defCat.fluid] or 0
    local dtrAmt = fluids["dimensionallytranscendentresidue"] or 0

    local nTotal = #cfg.dtpfs
    local nOnl, nAct, minD, maxD = 0, 0, 100, 0
    for i = 1, nTotal do
        local st = runtimeState.dtpfStatus[i]
        if st and st.online then
            nOnl = nOnl + 1
            if st.active then nAct = nAct + 1 end
            local dp = math.floor((tonumber(st.discountPct) or 0) + 0.5)
            if dp < minD then minD = dp end
            if dp > maxD then maxD = dp end
        end
    end
    local discStr = (nOnl == 0) and "0%" or ((minD == maxD) and (tostring(minD) .. "%") or string.format("%d-%d%%", minD, maxD))
    local odObj = runtimeState.onDemand or {}
    local odTxt = (odObj.hasWork == true) and tostring(odObj.summary or "Active") or "Idle"
    local inMsg = string.format("%s=%s DTR=%s | OD:%s | DTPFs:%d/%d act (%s disc)",
        defCat.code, fmtCompactLiters(catAmt), fmtCompactLiters(dtrAmt), odTxt, nAct, nOnl, discStr)

    local nRun, nLoop, nFull, nBlk = 0, 0, 0, 0
    local topRun = nil
    for i = 1, #RecipesDB.FAMILIES do
        local fam = RecipesDB.FAMILIES[i]
        local rc = cfg.recipes[fam.id]
        local rSt = runtimeState.recipeStatus[fam.id]
        if rc and rc.enabled and rSt then
            if #(rSt.activeDtpfs or {}) > 0 then
                if rSt.isForever then nLoop = nLoop + 1 else nRun = nRun + 1 end
                if not topRun then topRun = fam.name end
            elseif rSt.needsStock and not rSt.runnable then
                nBlk = nBlk + 1
            elseif not rSt.needsStock then
                nFull = nFull + 1
            end
        end
    end
    local topTag = topRun and (" | Top:" .. topRun) or ""
    local decMsg = string.format("Queue: %d run, %d loop, %d full, %d blk%s", nRun, nLoop, nFull, nBlk, topTag)

    local s = runtimeState.stepStats or {}
    local totW = (s.chWrites or 0) + (s.workWrites or 0) + (s.convWrites or 0) + (s.bridgeLiters or 0)
    local outMsg
    if totW == 0 then
        outMsg = string.format("0 hw writes (steady) | Bridge: %s", tostring(runtimeState.odBridgeStatus or "Idle"))
    else
        outMsg = string.format("Writes: ch=%d work=%d conv=%d bridge=%dL | %s",
            s.chWrites or 0, s.workWrites or 0, s.convWrites or 0, s.bridgeLiters or 0,
            tostring(runtimeState.odBridgeStatus or "Idle"))
    end

    -- Push OUT -> DEC -> IN so newest-first display reads IN / DEC / OUT top-to-bottom per poll
    pushEvent("out", outMsg, { stage = "OUT", minLevel = 3, allowRepeat = true })
    pushEvent("run", decMsg, { stage = "DEC", minLevel = 3, allowRepeat = true })
    pushEvent("info", inMsg, { stage = "IN", minLevel = 3, allowRepeat = true })
end

local CATALYST_FULL_LABELS = {
    exciteddtcc = "Excited Dimensionally Transcendent Crude Catalyst",
    exciteddtpc = "Excited Dimensionally Transcendent Prosaic Catalyst",
    exciteddtrc = "Excited Dimensionally Transcendent Resplendent Catalyst",
    exciteddtec = "Excited Dimensionally Transcendent Exotic Catalyst",
    exciteddtsc = "Excited Dimensionally Transcendent Stellar Catalyst",
}

local function roundNiceMaint(n)
    n = tonumber(n) or 0
    if n <= 0 then return 1 end
    local p = 10 ^ math.floor(math.log(n, 10))
    local norm = n / p
    if norm <= 1.2 then return math.floor(p + 0.5)
    elseif norm <= 2.5 then return math.floor(2 * p + 0.5)
    elseif norm <= 6.0 then return math.floor(5 * p + 0.5)
    else return math.floor(10 * p + 0.5) end
end

function Scheduler.defaultMaintTargetBatch(rType, name, perCraft)
    if type(name) == "string" and name:sub(1, 9) == "exciteddt" then
        return 50000000, 10000000
    end
    if rType == "fluid" then
        local tgt = roundNiceMaint(math.max(1000000, (tonumber(perCraft) or 1000) * 250))
        return tgt, math.max(100000, math.floor(tgt / 2))
    end
    local tgt = roundNiceMaint(math.max(1000, (tonumber(perCraft) or 1) * 128))
    return tgt, math.max(64, math.floor(tgt / 2))
end

function Scheduler.findMaintRule(cfg, rType, name, damage)
    local rules = (cfg and cfg.maintRules) or {}
    local tp = (rType == "fluid") and "fluid" or "item"
    local dmg = (tp == "fluid") and 0 or math.max(0, math.floor(tonumber(damage) or 0))
    for i = 1, #rules do
        local r = rules[i]
        if type(r) == "table" and ((r.type == "fluid") and "fluid" or "item") == tp and r.name == name then
            if tp == "fluid" or math.max(0, math.floor(tonumber(r.damage) or 0)) == dmg then
                return r, i
            end
        end
    end
    return nil, nil
end

function Scheduler.upsertMaintInput(cfg, spec)
    if not cfg or type(spec) ~= "table" or type(spec.name) ~= "string" or spec.name == "" then
        return nil, nil, false
    end
    cfg.maintRules = cfg.maintRules or {}
    local tp = (spec.type == "fluid") and "fluid" or "item"
    local dmg = (tp == "fluid") and 0 or math.max(0, math.floor(tonumber(spec.damage) or 0))
    local fullLbl = (tp == "fluid" and CATALYST_FULL_LABELS[spec.name]) or spec.label or spec.name
    local existing, idx = Scheduler.findMaintRule(cfg, tp, spec.name, dmg)
    if existing then
        if spec.mode == "auto" or spec.mode == "always" or spec.mode == "off" then
            existing.mode = spec.mode
        elseif existing.mode == "off" then
            existing.mode = "auto"
        end
        if spec.target ~= nil and tonumber(spec.target) then
            existing.target = math.max(1, math.floor(tonumber(spec.target)))
        end
        if spec.batch ~= nil and tonumber(spec.batch) then
            existing.batch = math.max(1, math.floor(tonumber(spec.batch)))
        end
        return existing, idx, false
    end
    local defTgt, defBat = Scheduler.defaultMaintTargetBatch(tp, spec.name, spec.amount)
    local mode = (spec.mode == "always" or spec.mode == "off") and spec.mode or "auto"
    local newRule = {
        id = tp .. ":" .. spec.name .. ":" .. tostring(dmg) .. ":" .. tostring(#cfg.maintRules + 1),
        type = tp,
        name = spec.name,
        damage = dmg,
        label = tostring(fullLbl),
        target = math.max(1, math.floor(tonumber(spec.target) or defTgt)),
        batch = math.max(1, math.floor(tonumber(spec.batch) or defBat)),
        mode = mode,
    }
    cfg.maintRules[#cfg.maintRules + 1] = newRule
    return newRule, #cfg.maintRules, true
end

function Scheduler.collectRecipeMaintInputs(cfg, famId)
    local fam = FAMILY_BY_ID[famId]
    if not fam then return {} end
    local rc = (cfg and cfg.recipes and cfg.recipes[famId]) or {}
    local _, tCode, _, tData, catFluid = Scheduler.resolveRecipe(fam, rc, cfg or {}, nil, { wantConvergence = true })
    local out, seen = {}, {}
    local function push(tp, name, dmg, label, amount, short, isCat)
        if type(name) ~= "string" or name == "" then return end
        local d = (tp == "fluid") and 0 or math.max(0, math.floor(tonumber(dmg) or 0))
        local k = tp .. ":" .. name .. ":" .. tostring(d)
        if seen[k] then return end
        seen[k] = true
        out[#out + 1] = {
            type = tp,
            name = name,
            damage = d,
            label = (tp == "fluid" and CATALYST_FULL_LABELS[name]) or label or name,
            amount = tonumber(amount) or 1,
            short = short,
            isCat = isCat == true,
        }
    end
    if tCode and tCode ~= "NONE" and catFluid then
        push("fluid", catFluid, 0, CATALYST_FULL_LABELS[catFluid] or catFluid,
            tData and tData.catalystAmount or 1000, tCode, true)
    end
    if tData then
        for _, fl in ipairs(tData.fluidsIn or {}) do
            if fl.name and fl.name ~= "dimensionallytranscendentresidue" then
                push("fluid", fl.name, 0, fl.label or fl.name, fl.amount or 144, nil, false)
            end
        end
        for _, it in ipairs(tData.itemsIn or {}) do
            if it.name and (not it.nonConsumed) and (tonumber(it.amount) or 0) > 0 then
                push("item", it.name, it.damage or 0, it.label or it.name, it.amount, nil, false)
            end
        end
    end
    return out
end

-- Build demand key set ("fluid:<name>:0" | "item:<name>:<dmg>") for active recipes, fallback, and pins
function Scheduler.computeMaintDemandSet(cfg, stock)
    local demanded = {}
    if not cfg then return demanded end
    local defCt = TIER_BY_INDEX[tonumber(cfg.defaultCatalystTier) or 4]
    if defCt and defCt.fluid then
        demanded["fluid:" .. defCt.fluid .. ":0"] = true
    end

    local wantedFams = {}
    if cfg.fallbackEnabled and cfg.fallbackFamilyId then
        wantedFams[cfg.fallbackFamilyId] = true
    end
    for _, d in ipairs(cfg.dtpfs or {}) do
        if d.enabled ~= false and (d.roleOverride == "pinned" or d.roleOverride == "pinned_loop") and d.pinnedFamilyId then
            wantedFams[d.pinnedFamilyId] = true
        end
    end
    for i = 1, #RecipesDB.FAMILIES do
        local fam = RecipesDB.FAMILIES[i]
        local rc = cfg.recipes and cfg.recipes[fam.id]
        if (rc and rc.enabled == true) or wantedFams[fam.id] then
            local _, _, _, tData, catFluid = Scheduler.resolveRecipe(fam, rc, cfg, stock, { wantConvergence = true })
            if catFluid then
                demanded["fluid:" .. catFluid .. ":0"] = true
            end
            if tData then
                for _, fl in ipairs(tData.fluidsIn or {}) do
                    if fl.name then demanded["fluid:" .. fl.name .. ":0"] = true end
                end
                for _, it in ipairs(tData.itemsIn or {}) do
                    if it.name and (not it.nonConsumed) and (it.amount or 0) > 0 then
                        demanded["item:" .. it.name .. ":" .. tostring(it.damage or 0)] = true
                    end
                end
            end
        end
    end
    return demanded
end

-- In-game AE2 Level Maintainer step (strictly via local Mainnet Adapter or OC Modem/Tunnel)
function Scheduler.stepLevelMaintainer(cfg, runtimeState, ctx, nowSec, opts, pushEvent)
    local rules = (cfg and cfg.maintRules) or {}
    local demanded = Scheduler.computeMaintDemandSet(cfg, ctx and ctx.stock)
    local pollSec = math.max(5, tonumber(cfg and cfg.maintPollSec) or 15)
    runtimeState._maintTrack = runtimeState._maintTrack or {}

    local activeReq = {}
    local ruleDemanded = {}
    for i = 1, #rules do
        local r = rules[i]
        local k = string.format("%s:%s:%d", r.type or "item", r.name or "", tonumber(r.damage) or 0)
        local isDem = (r.mode == "always") or (r.mode == "auto" and demanded[k] == true)
        ruleDemanded[r.id] = isDem
        if r.mode ~= "off" then
            activeReq[#activeReq + 1] = {
                id = r.id,
                type = r.type,
                name = r.name,
                damage = r.damage or 0,
                label = r.label,
            }
        end
    end

    local sync = runtimeState._lastMaintSync
    local syncAge = nowSec - (runtimeState._lastMaintPollSec or -1000)
    local forceSync = (runtimeState._forceMaintSync == true) or (opts and opts.forceMaintSync == true)
    if forceSync then runtimeState._forceMaintSync = false end

    local shouldQuery = (not ctx or not ctx.useCache)
        and (forceSync or sync == nil or (cfg.maintEnabled and syncAge >= pollSec) or ((not cfg.maintEnabled) and syncAge >= 60))
    if shouldQuery and not (opts and opts.skipMaintQuery) then
        sync = Hardware.queryMainnetMaintenance(cfg, activeReq)
        runtimeState._lastMaintSync = sync
        runtimeState._lastMaintPollSec = nowSec
        if sync and sync.failed then
            for fid, why in pairs(sync.failed) do
                local tr = runtimeState._maintTrack[fid] or {}
                tr.inFlightUntil = 0
                tr.backoffUntil = nowSec + 60
                tr.lastError = why
                runtimeState._maintTrack[fid] = tr
            end
        end
    end
    sync = sync or { ok = false, link = "none" }

    local linkOk = (sync.ok == true)
    local freeCpus = tonumber(sync.freeCpus) or 0
    local totalCpus = tonumber(sync.totalCpus) or 0
    local freeReserve = math.max(0, tonumber(cfg and cfg.maintFreeCpus) or 2)
    local cpuHeadroomOk = linkOk and (freeCpus > freeReserve)
    local busyByKey = sync.busyByKey or {}
    local busyByLabel = sync.busyByLabel or {}
    local syncStocks = sync.stocks or {}
    local fallbackFluids = (ctx and ctx.stock and ctx.stock.fluids) or {}
    local fallbackItems = (ctx and ctx.stock and ctx.stock.items) or {}

    local ruleOut = {}
    local lowList = {}
    local activeCount, craftingCount, lowCount = 0, 0, 0

    for i = 1, #rules do
        local r = rules[i]
        local k = string.format("%s:%s:%d", r.type or "item", r.name or "", tonumber(r.damage) or 0)
        local isDem = ruleDemanded[r.id] == true
        local tr = runtimeState._maintTrack[r.id] or {}
        if tr.inFlightUntil and nowSec >= tr.inFlightUntil then
            tr.inFlightUntil = 0
        end
        if tr.backoffUntil and nowSec >= tr.backoffUntil then
            tr.backoffUntil = 0
        end

        local curStock = linkOk and tonumber(syncStocks[r.id])
            or ((r.type == "fluid") and (fallbackFluids[r.name] or 0) or (fallbackItems[r.name .. ":" .. tostring(r.damage or 0)] or 0))
        curStock = curStock or 0

        local busyCpu = busyByKey[k] or busyByLabel[r.label]
        local inFlight = (not busyCpu) and ((tr.inFlightUntil or 0) > nowSec)
        local inBackoff = ((tr.backoffUntil or 0) > nowSec)
        local stateStr = "OK"

        if r.mode == "off" then
            stateStr = "Off"
        elseif not isDem then
            stateStr = "No Demand"
        else
            activeCount = activeCount + 1
            if busyCpu then
                craftingCount = craftingCount + 1
                tr.inFlightUntil = 0
                stateStr = "Crafting (" .. tostring(busyCpu) .. ")"
            elseif inFlight then
                craftingCount = craftingCount + 1
                stateStr = "Starting..."
            elseif not linkOk then
                stateStr = "No Mainnet Link"
            elseif curStock < (tonumber(r.target) or 1) then
                lowCount = lowCount + 1
                if inBackoff then
                    stateStr = "Wait (" .. tostring(tr.lastError or "Backoff") .. ")"
                elseif not cpuHeadroomOk then
                    stateStr = string.format("CPU Reserve (%d/%d free)", freeCpus, freeReserve)
                else
                    stateStr = cfg.maintEnabled and "Queued" or "Need Batch"
                    local deficit = ((tonumber(r.target) or 1) - curStock) / math.max(1, tonumber(r.target) or 1)
                    lowList[#lowList + 1] = { rule = r, deficit = deficit, track = tr }
                end
            else
                tr.lastError = nil
                stateStr = "OK"
            end
        end

        ruleOut[i] = {
            id = r.id,
            demanded = isDem,
            stock = curStock,
            stockKnown = linkOk or (curStock > 0),
            craftingCpu = busyCpu,
            stateStr = stateStr,
        }
    end

    if (cfg and cfg.armed == true) and (cfg and cfg.maintEnabled == true) and cpuHeadroomOk and shouldQuery and #lowList > 0 then
        table.sort(lowList, function(a, b)
            if math.abs(a.deficit - b.deficit) > 0.001 then
                return a.deficit > b.deficit
            end
            return tostring(a.rule.id) < tostring(b.rule.id)
        end)
        local top = lowList[1]
        local r = top.rule
        local ack = Hardware.requestMainnetCraft(cfg, r, r.batch)
        local tr = top.track
        if ack and ack.ok then
            tr.inFlightUntil = nowSec + 90
            tr.lastError = nil
            runtimeState._maintTrack[r.id] = tr
            craftingCount = craftingCount + 1
            for idx = 1, #ruleOut do
                if ruleOut[idx].id == r.id then
                    ruleOut[idx].stateStr = (ack.status == "computing") and "Computing..." or "Dispatched"
                    break
                end
            end
            if pushEvent then
                pushEvent("out", string.format("Maint: +%s %s", fmtCompactLiters(r.batch):gsub("L$", r.type == "fluid" and "L" or ""), r.label),
                    { stage = "OUT", minLevel = 1 })
            end
        else
            tr.backoffUntil = nowSec + 60
            tr.lastError = (ack and ack.error) or "Request failed"
            runtimeState._maintTrack[r.id] = tr
            for idx = 1, #ruleOut do
                if ruleOut[idx].id == r.id then
                    ruleOut[idx].stateStr = "Wait (" .. tostring(tr.lastError) .. ")"
                    break
                end
            end
        end
    end

    runtimeState.maintStatus = {
        enabled = (cfg and cfg.maintEnabled == true),
        link = linkOk and (sync.link or "adapter") or "none",
        linkError = sync.error,
        freeCpus = freeCpus,
        totalCpus = totalCpus,
        freeCpusReserve = freeReserve,
        pollSec = pollSec,
        activeCount = activeCount,
        craftingCount = craftingCount,
        lowCount = lowCount,
        rules = ruleOut,
    }
    return runtimeState.maintStatus
end

-- Check whether every enabled DTPF has 24/7 or Fallback work once <Tgt stocks fill and OD is idle
function Scheduler.evaluate247Coverage(cfg, runtimeState)
    local dtpfs = (cfg and cfg.dtpfs) or {}
    local enabledCount = 0
    for i = 1, #dtpfs do
        if dtpfs[i].enabled ~= false then enabledCount = enabledCount + 1 end
    end
    if enabledCount == 0 then return nil end

    local rStatuses = runtimeState and runtimeState.recipeStatus
    local hasLive = (type(rStatuses) == "table") and (next(rStatuses) ~= nil)
    local dtpfStatuses = (runtimeState and runtimeState.dtpfStatus) or {}

    local chMap, chOrder = {}, {}
    for i = 1, #((cfg and cfg.channels) or {}) do
        local ch = cfg.channels[i]
        chMap[ch.id] = { id = ch.id, enabled = (ch.enabled ~= false), list = {} }
        chOrder[#chOrder + 1] = chMap[ch.id]
    end
    for i = 1, #dtpfs do
        local d = dtpfs[i]
        if d.enabled ~= false then
            local cid = d.channelId or "ch1"
            if not chMap[cid] then
                chMap[cid] = { id = cid, enabled = true, list = {} }
                chOrder[#chOrder + 1] = chMap[cid]
            end
            chMap[cid].list[#chMap[cid].list + 1] = { idx = i, d = d, name = d.name or ("DTPF #" .. i) }
        end
    end

    local function simulate(requireRunnable)
        local uncovered, names, roleReason, firstDtpfIdx, firstFamId = 0, {}, nil, nil, nil
        local function markUncov(u, rsn, fid)
            uncovered = uncovered + 1
            names[#names + 1] = u.name
            if not firstDtpfIdx then firstDtpfIdx = u.idx end
            if rsn and not roleReason then roleReason = rsn end
            if fid and not firstFamId then firstFamId = fid end
        end

        local foreverList, blockedList = {}, {}
        for idx = 1, #RecipesDB.FAMILIES do
            local fam = RecipesDB.FAMILIES[idx]
            local rc = cfg.recipes and cfg.recipes[fam.id]
            if rc and rc.enabled == true and rc.forever == true then
                local rSt = hasLive and rStatuses[fam.id] or nil
                local heat = (rSt and rSt.tierData and rSt.tierData.coilHeat) or 0
                local maxD = tonumber(rc.maxDtpfs) or 0
                local ok = (not requireRunnable) or (not rSt) or (rSt.runnable ~= false)
                local rec = { id = fam.id, name = fam.name, priority = tonumber(rc.priority) or idx, order = idx, heat = heat, maxDtpfs = maxD, reason = rSt and rSt.reason }
                if ok then foreverList[#foreverList + 1] = rec else blockedList[#blockedList + 1] = rec end
            end
        end
        table.sort(foreverList, function(a, b) return (a.priority ~= b.priority) and (a.priority < b.priority) or (a.order < b.order) end)

        local fbId = cfg.fallbackFamilyId
        local fbFam = (cfg.fallbackEnabled == true) and fbId and FAMILY_BY_ID[fbId] or nil
        local fbRc = fbFam and cfg.recipes and cfg.recipes[fbId]
        local fbSt = (fbFam and hasLive) and rStatuses[fbId] or nil
        if requireRunnable and fbFam and fbSt and fbSt.runnable == false then
            blockedList[#blockedList + 1] = { id = fbId, name = fbFam.name, reason = fbSt.reason }
        end

        local autoQueue = {}
        for cIdx = 1, #chOrder do
            local grp = chOrder[cIdx]
            local autoUnits, pinOk, pinBlocked, chHeatLimit = {}, false, nil, math.huge
            if requireRunnable then
                local bestH
                for k = 1, #grp.list do
                    local st = dtpfStatuses[grp.list[k].idx]
                    if st and st.online and (st.coilHeat or 0) > 0 then
                        bestH = bestH and math.min(bestH, st.coilHeat) or st.coilHeat
                    end
                end
                if bestH then chHeatLimit = bestH end
            end
            for k = 1, #grp.list do
                local u = grp.list[k]
                local role = u.d.roleOverride or "auto"
                if role == "od_only" then markUncov(u, "OD-Only role stops when On-Demand is idle")
                elseif role == "passive_only" then markUncov(u, "Passive-Only role stops once <Tgt stocks fill")
                elseif role == "pinned" then markUncov(u, "Pin (<Tgt) stops at target; use Pin 24/7", u.d.pinnedFamilyId)
                elseif role == "pinned_loop" then
                    local pf = u.d.pinnedFamilyId and FAMILY_BY_ID[u.d.pinnedFamilyId]
                    if not pf then
                        markUncov(u, "Pin 24/7 has no recipe selected")
                    else
                        local rSt = (requireRunnable and hasLive) and rStatuses[pf.id] or nil
                        if rSt and rSt.runnable == false then
                            pinBlocked = { id = pf.id, name = pf.name, reason = tostring(rSt.reason or "Blocked") }
                            markUncov(u, pf.name .. " (" .. pinBlocked.reason .. ")", pf.id)
                        else
                            pinOk = true
                        end
                    end
                elseif not grp.enabled then
                    markUncov(u, "Channel " .. tostring(grp.id) .. " disabled")
                else
                    autoUnits[#autoUnits + 1] = u
                end
            end
            if #autoUnits > 0 then
                if pinBlocked then
                    for k = 1, #autoUnits do markUncov(autoUnits[k], pinBlocked.name .. " (" .. pinBlocked.reason .. ")", pinBlocked.id) end
                elseif not pinOk then
                    autoQueue[#autoQueue + 1] = { units = autoUnits, heatLimit = chHeatLimit }
                end
            end
        end

        local used, assigned = {}, {}
        for qIdx = 1, #autoQueue do
            local chQ = autoQueue[qIdx]
            local chUnits = #chQ.units
            local chosenId = nil
            for f = 1, #foreverList do
                local cand = foreverList[f]
                if (not used[cand.id]) and cand.heat <= chQ.heatLimit then
                    chosenId = cand.id
                    break
                end
            end
            if not chosenId and cfg.allowParallelSameRecipe ~= false then
                local bestCnt = nil
                for f = 1, #foreverList do
                    local cand = foreverList[f]
                    local cur = assigned[cand.id] or 0
                    if cand.heat <= chQ.heatLimit and (cand.maxDtpfs <= 0 or cur < cand.maxDtpfs) and ((not bestCnt) or cur < bestCnt) then
                        chosenId, bestCnt = cand.id, cur
                    end
                end
            end
            if chosenId then
                used[chosenId] = true
                assigned[chosenId] = (assigned[chosenId] or 0) + chUnits
            elseif fbFam then
                local fbMax = (fbRc and tonumber(fbRc.maxDtpfs)) or 0
                local fbCur = assigned[fbId] or 0
                local fbHeat = (fbSt and fbSt.tierData and fbSt.tierData.coilHeat) or 0
                local fbOk = (fbMax <= 0 or fbCur < fbMax) and ((not requireRunnable) or (((not fbSt) or fbSt.runnable ~= false) and fbHeat <= chQ.heatLimit))
                if fbOk then
                    assigned[fbId] = fbCur + chUnits
                else
                    for k = 1, chUnits do markUncov(chQ.units[k], nil, fbId) end
                end
            else
                for k = 1, chUnits do markUncov(chQ.units[k]) end
            end
        end
        return uncovered, names, roleReason, firstDtpfIdx, firstFamId, #foreverList, fbFam, fbRc, blockedList
    end

    local uncov, names, roleRsn, dtpfIdx, famId, nForever, fbFam, fbRc = simulate(false)
    if uncov > 0 then
        local covered = enabledCount - uncov
        local shortRsn, reason
        if roleRsn then
            local nameStr = table.concat(names, ", ")
            if not cfg.fallbackEnabled and nForever == 0 and #names > 1 then
                shortRsn = "Fallback OFF (0 24/7 recipes)"
                reason = string.format("Fallback is OFF & role stops idle DTPFs (%s)", nameStr)
            else
                shortRsn = roleRsn
                reason = string.format("%s (%s) - %d/%d DTPFs will lose 50%% discount", roleRsn, nameStr, uncov, enabledCount)
            end
        elseif not cfg.fallbackEnabled then
            if nForever == 0 then
                shortRsn = "Fallback OFF (0 24/7 recipes)"
                reason = "Fallback is OFF and 0 recipes are 24/7 - fleet will stop & lose 50% discount once <Tgt fills"
            elseif cfg.allowParallelSameRecipe == false then
                shortRsn = "Fallback OFF (Parallel OFF)"
                reason = "Fallback is OFF and Parallel is OFF - enable Fallback or add 24/7 recipes so all DTPFs keep 50% discount"
            else
                shortRsn = "Fallback OFF (Max-DTPF caps)"
                reason = string.format("Fallback is OFF and 24/7 Max-DTPF caps cover only %d/%d DTPFs - enable Fallback or raise Max DTPFs", covered, enabledCount)
            end
        else
            local fbName = fbFam and fbFam.name or "Fallback"
            shortRsn = string.format("%s Max:%d leaves idle", fbName:sub(1, 14), tonumber(fbRc and fbRc.maxDtpfs) or 0)
            reason = string.format("Fallback (%s) Max-DTPF cap leaves %d/%d DTPFs uncovered - set Max DTPFs to All", fbName, uncov, enabledCount)
            famId = famId or (fbFam and fbFam.id)
        end
        return {
            kind = "unconfigured",
            covered = covered,
            uncovered = uncov,
            total = enabledCount,
            names = names,
            summary = string.format("24/7 Coverage (%d/%d Covered)", covered, enabledCount),
            shortReason = shortRsn,
            reason = reason,
            familyId = famId,
            dtpfIdx = dtpfIdx,
        }
    end

    if hasLive then
        local bUncov, bNames, bRoleRsn, bDtpfIdx, bFamId, _, _, _, blockedList = simulate(true)
        if bUncov > 0 then
            local covered = enabledCount - bUncov
            local bEntry = blockedList[1]
            local bId = (bEntry and bEntry.id) or bFamId
            local bName = (bEntry and bEntry.name) or "24/7 Recipe"
            local bWhy = tostring((bEntry and bEntry.reason) or bRoleRsn or "Blocked")
            return {
                kind = "blocked",
                covered = covered,
                uncovered = bUncov,
                total = enabledCount,
                names = bNames,
                summary = string.format("24/7 Coverage Blocked (%d/%d Covered)", covered, enabledCount),
                shortReason = string.format("%d/%d lack 24/7: %s", bUncov, enabledCount, bName),
                reason = string.format("%s (%s) - %d/%d DTPFs (%s) will stop & lose 50%% discount once <Tgt stocks fill",
                    bName, bWhy, bUncov, enabledCount, table.concat(bNames, ", ")),
                familyId = bId,
                dtpfIdx = bDtpfIdx,
            }
        end
    end

    return nil
end

-- Execute one full scheduling / monitor cycle (only mutates hardware when cfg.armed == true)
function Scheduler.step(cfg, runtimeState, opts)
    opts = opts or {}
    runtimeState = runtimeState or {}
    runtimeState.stepCount = (runtimeState.stepCount or 0) + 1
    runtimeState.recipeStatus = runtimeState.recipeStatus or {}
    runtimeState.dtpfStatus = runtimeState.dtpfStatus or {}
    runtimeState.channelStatus = runtimeState.channelStatus or {}
    runtimeState.events = runtimeState.events or {}
    runtimeState._rateTrackers = runtimeState._rateTrackers or {}
    runtimeState._prevChSig = runtimeState._prevChSig or {}
    runtimeState._prevCatFb = runtimeState._prevCatFb or {}
    runtimeState._prevNeedsStock = runtimeState._prevNeedsStock or {}
    runtimeState.stepStats = { chWrites = 0, workWrites = 0, convWrites = 0, bridgeLiters = 0 }
    runtimeState.bottlenecks = {}

    local hasCompLib, computerLib = pcall(require, "computer")
    local osTbl = rawget(_G, "os")
    local nowSec = opts.nowUptime
        or ((hasCompLib and computerLib and computerLib.uptime) and computerLib.uptime())
        or ((type(osTbl) == "table" and osTbl.clock) and osTbl.clock() or 0)

    local logRank = LOG_LEVEL_RANK[cfg.logLevel or "normal"] or 2
    local function pushEvent(kind, text, evOpts)
        if not text or text == "" then return end
        local eo = evOpts or {}
        local stage = eo.stage
        local minLevel = eo.minLevel
        if not stage then
            if kind == "warn" then stage = "WARN"
            elseif kind == "od" then stage = "IN"
            elseif kind == "out" then stage = "OUT"
            else stage = "DEC"
            end
        end
        if not minLevel then
            minLevel = (stage == "OUT") and 2 or 1
        end
        if logRank < minLevel then return end

        local top = runtimeState.events[1]
        if (not eo.allowRepeat) and top and top.text == text and top.stage == stage then return end
        table.insert(runtimeState.events, 1, {
            step = runtimeState.stepCount,
            uptime = nowSec,
            stage = stage,
            kind = kind or "info",
            minLevel = minLevel,
            text = text,
        })
        for _ = 1, 8 do
            if #runtimeState.events <= MAX_LOG_EVENTS then break end
            table.remove(runtimeState.events)
        end
    end

    local ctx = stepPollSnapshots(cfg, runtimeState, opts, nowSec)
    stepEvaluateOdAndBridge(cfg, runtimeState, ctx, opts, pushEvent)
    local needyQueue, currentlyRunningMap, doesChannelWantConv = stepEvaluateRecipes(cfg, runtimeState, ctx, nowSec, pushEvent)
    local seenBnFam = stepAssignPassiveChannels(cfg, runtimeState, ctx, needyQueue, currentlyRunningMap, doesChannelWantConv, pushEvent)
    stepUpdateDtpfControls(cfg, runtimeState, ctx, opts, seenBnFam, pushEvent)
    Scheduler.stepLevelMaintainer(cfg, runtimeState, ctx, nowSec, opts, pushEvent)

    if (cfg.logLevel == "raw") and (not ctx.useCache) and (not opts.interactive) then
        emitRawStepTrace(cfg, runtimeState, ctx, pushEvent)
    end
    runtimeState.coverageWarning = Scheduler.evaluate247Coverage(cfg, runtimeState)
    local s = runtimeState.stepStats
    runtimeState.lastPollMeta = {
        uptime = nowSec,
        stockPolled = ctx.stockPolled,
        chWrites = s.chWrites or 0,
        workWrites = s.workWrites or 0,
        convWrites = s.convWrites or 0,
        bridgeLiters = s.bridgeLiters or 0,
    }

    return runtimeState
end

return Scheduler
