-- /home/nanoforge/lib/recipes_db.lua
-- Complete GTNH 2.9.0 Nano Forge Catalog (all 12 Nanite recipes, verified from NaniteChain & MTENanoForge).

local RecipesDb = {}

RecipesDb.MAGMATTER_FLUID = "molten.magmatter"

-- Full 12-nanite catalog ordered Tier 1 -> Tier 4
RecipesDb.RECIPES = {
    {
        id = "carbon",
        label = "Carbon Nanites",
        tier = 1,
        durationTicks = 10000,
        eut = 10000000,
        output = { name = "gregtech:gt.metaitem.03", damage = 4010, size = 64, label = "Carbon Nanites" },
        items = {
            { name = "bartworks:bw.werkstoffblockscasingadvanced.01", damage = 31776, amount = 8, label = "Rebolted Carbon Casing" },
            { name = "gregtech:gt.metaitem.03", damage = 32047, amount = 64, label = "SoC" },
        },
        fluids = {
            { name = "ic2uumatter", amount = 200000, label = "UU-Matter" },
        },
    },
    {
        id = "neutronium",
        label = "Neutronium Nanites",
        tier = 1,
        durationTicks = 2000,
        eut = 100000000,
        output = { name = "gregtech:gt.metaitem.03", damage = 4129, size = 1, label = "Neutronium Nanites" },
        items = {
            { name = "gregtech:gt.blockmetal5", damage = 2, amount = 8, label = "Block of Neutronium" },
            { name = "gregtech:gt.metaitem.03", damage = 32049, amount = 96, label = "ASoC" },
        },
        fluids = {
            { name = "ic2uumatter", amount = 200000, label = "UU-Matter" },
        },
    },
    {
        id = "silver",
        label = "Silver Nanites",
        tier = 2,
        durationTicks = 15000,
        eut = 10000000,
        output = { name = "gregtech:gt.metaitem.03", damage = 4054, size = 1, label = "Silver Nanites" },
        items = {
            { name = "gregtech:gt.blockmetal6", damage = 10, amount = 8, label = "Block of Silver" },
            { name = "gregtech:gt.metaitem.03", damage = 32047, amount = 16, label = "SoC" },
        },
        fluids = {
            { name = "ic2uumatter", amount = 200000, label = "UU-Matter" },
        },
    },
    {
        id = "glowstone",
        label = "Glowstone Nanites",
        tier = 2,
        durationTicks = 4000,
        eut = 50000000,
        output = { name = "gregtech:gt.metaitem.03", damage = 4811, size = 64, label = "Glowstone Nanites" },
        items = {
            { name = "miscutils:blockCompressedObsidian", damage = 7, amount = 8, label = "Double Compressed Glowstone (81)" },
            { name = "gregtech:gt.metaitem.03", damage = 32049, amount = 64, label = "ASoC" },
        },
        fluids = {
            { name = "ic2uumatter", amount = 50000, label = "UU-Matter" },
        },
    },
    {
        id = "transcendent",
        label = "Transcendent Metal Nanites",
        tier = 2,
        durationTicks = 15000,
        eut = 1000000000,
        output = { name = "gregtech:gt.metaitem.03", damage = 4581, size = 1, label = "Transcendent Metal Nanites" },
        items = {
            { name = "gregtech:gt.blockmetal9", damage = 4, amount = 8, label = "Block of Transcendent Metal" },
            { name = "gregtech:gt.metaitem.03", damage = 32049, amount = 192, label = "ASoC" },
        },
        fluids = {
            { name = "ic2uumatter", amount = 2000000, label = "UU-Matter" },
        },
    },
    {
        id = "gold",
        label = "Gold Nanites",
        tier = 3,
        durationTicks = 20000,
        eut = 100000000,
        output = { name = "gregtech:gt.metaitem.03", damage = 4086, size = 1, label = "Gold Nanites" },
        items = {
            { name = "minecraft:gold_block", damage = 0, amount = 8, label = "Block of Gold" },
            { name = "gregtech:gt.metaitem.03", damage = 32047, amount = 16, label = "SoC" },
        },
        fluids = {
            { name = "ic2uumatter", amount = 300000, label = "UU-Matter" },
        },
    },
    {
        id = "six_phased_copper",
        label = "Six-Phased Copper Nanites",
        tier = 3,
        durationTicks = 2000,
        eut = 2000000000,
        output = { name = "gregtech:gt.metaitem.03", damage = 4147, size = 8, label = "Six-Phased Copper Nanites" },
        items = {
            { name = "gregtech:gt.blockmetal9", damage = 11, amount = 16, label = "Block of Six-Phased Copper" },
            { name = "gregtech:gt.metaitem.03", damage = 32049, amount = 192, label = "ASoC" },
        },
        fluids = {
            { name = "ic2uumatter", amount = 500000, label = "UU-Matter" },
            { name = "dimensionallytranscendentresidue", amount = 50000, label = "Dimensionally Transcendent Residue" },
            { name = "molten.creon", amount = 73728, label = "Molten Creon" },
        },
    },
    {
        id = "white_dwarf",
        label = "White Dwarf Matter Nanites",
        tier = 3,
        durationTicks = 15000,
        eut = 2000000000,
        output = { name = "gregtech:gt.metaitem.03", damage = 4585, size = 4, label = "White Dwarf Matter Nanites" },
        items = {
            { name = "gregtech:gt.blockmetal9", damage = 6, amount = 8, label = "Block of White Dwarf Matter" },
            { name = "gregtech:gt.metaitem.03", damage = 32269, amount = 64, label = "Atto Power IC" },
            { name = "gregtech:gt.metaitem.01", damage = 32668, amount = 64, label = "Living Crystal Chip" },
        },
        fluids = {
            { name = "ic2uumatter", amount = 500000, label = "UU-Matter" },
            { name = "rawstarmatter", amount = 50000, label = "Condensed Raw Stellar Plasma Mixture" },
            { name = "spatialfluid", amount = 720, label = "Spatially Enlarged Fluid" },
        },
    },
    {
        id = "black_dwarf",
        label = "Black Dwarf Matter Nanites",
        tier = 3,
        durationTicks = 15000,
        eut = 2000000000,
        output = { name = "gregtech:gt.metaitem.03", damage = 4586, size = 4, label = "Black Dwarf Matter Nanites" },
        items = {
            { name = "gregtech:gt.blockmetal9", damage = 7, amount = 8, label = "Block of Black Dwarf Matter" },
            { name = "gregtech:gt.metaitem.03", damage = 32269, amount = 64, label = "Atto Power IC" },
            { name = "gregtech:gt.metaitem.01", damage = 32668, amount = 64, label = "Living Crystal Chip" },
        },
        fluids = {
            { name = "ic2uumatter", amount = 500000, label = "UU-Matter" },
            { name = "rawstarmatter", amount = 50000, label = "Condensed Raw Stellar Plasma Mixture" },
            { name = "temporalfluid", amount = 720, label = "Tachyon Rich Temporal Fluid" },
        },
    },
    {
        id = "universium",
        label = "Universium Nanites",
        tier = 3,
        durationTicks = 15000,
        eut = 2000000000,
        output = { name = "gregtech:gt.metaitem.03", damage = 4139, size = 2, label = "Universium Nanites" },
        items = {
            { name = "gregtech:gt.blockmetal9", damage = 8, amount = 8, label = "Block of Universium" },
            { name = "gregtech:gt.metaitem.03", damage = 32269, amount = 64, label = "Atto Power IC" },
            { name = "gregtech:gt.metaitem.03", damage = 32189, amount = 64, label = "Living Bio Chip" },
        },
        fluids = {
            { name = "molten.spacetime", amount = 144, label = "Molten SpaceTime" },
            { name = "molten.infinity", amount = 576, label = "Molten Infinity" },
            { name = "primordialmatter", amount = 64000, label = "Liquid Primordial Matter" },
        },
    },
    {
        id = "eternity",
        label = "Eternity Nanites",
        tier = 3,
        durationTicks = 3750,
        eut = 2147483640,
        output = { name = "gregtech:gt.metaitem.03", damage = 4141, size = 1, label = "Eternity Nanites" },
        items = {
            { name = "gregtech:gt.metaitem.03", damage = 4139, amount = 2, label = "Universium Nanites", isNaniteInput = true },
            { name = "gregtech:gt.blockmetal9", damage = 9, amount = 8, label = "Block of Eternity" },
            { name = "gregtech:gt.metaitem.03", damage = 32269, amount = 64, label = "Atto Power IC" },
            { name = "gregtech:gt.metaitem.03", damage = 32757, amount = 1, label = "Timepiece" },
        },
        fluids = {
            { name = "spatialfluid", amount = 288, label = "Spatially Enlarged Fluid" },
            { name = "exciteddtsc", amount = 12500, label = "Excited DTSC" },
            { name = "primordialmatter", amount = 64000, label = "Liquid Primordial Matter" },
        },
    },
    {
        id = "magmatter",
        label = "Magmatter Nanites",
        tier = 4,
        durationTicks = 20000,
        eut = 2147483640,
        output = { name = "gregtech:gt.metaitem.03", damage = 4143, size = 1, label = "Magmatter Nanites" },
        items = {
            { name = "gregtech:gt.metaitem.03", damage = 4139, amount = 4, label = "Universium Nanites", isNaniteInput = true },
            { name = "gregtech:gt.blockmetal9", damage = 10, amount = 8, label = "Block of Magmatter" },
            { name = "gregtech:gt.metaitem.03", damage = 32273, amount = 64, label = "Yocto Power IC" },
            { name = "dreamcraft:PlanckCircuit", damage = 0, amount = 1, label = "Planck-Scale Circuit" },
        },
        fluids = {
            { name = "quarkgluonplasma", amount = 100000, label = "Degenerate Quark Gluon Plasma" },
            { name = "phononmedium", amount = 64000, label = "Lossless Phonon Transfer Medium" },
            { name = "primordialmatter", amount = 128000, label = "Liquid Primordial Matter" },
        },
    },
}

RecipesDb.BY_ID = {}
RecipesDb.NANITE_BY_DAMAGE = {}
for _, r in ipairs(RecipesDb.RECIPES) do
    RecipesDb.BY_ID[r.id] = r
    RecipesDb.NANITE_BY_DAMAGE[r.output.damage] = r
end

function RecipesDb.isNaniteStack(st)
    if type(st) ~= "table" then return false end
    local n = tostring(st.name or "")
    local d = math.floor(tonumber(st.damage) or -1)
    if n == "gregtech:gt.metaitem.03" and (RecipesDb.NANITE_BY_DAMAGE[d] or (d >= 4000 and d < 5000)) then
        return true, d
    end
    local lbl = tostring(st.label or ""):lower()
    if lbl:find("nanite", 1, true) then
        return true, d
    end
    return false, d
end

-- Exact GTNH 2.9.0 MTENanoForge formula: 288 / (2 ^ (4 - RecipeTier))
function RecipesDb.magmatterPerParallel(recipeTier)
    local t = math.max(1, math.min(4, math.floor(tonumber(recipeTier) or 1)))
    return math.floor(288 / (2 ^ (4 - t)))
end

-- Parallels > 1 require exact Magmatter multiples; 1 parallel needs 0 Magmatter
function RecipesDb.exactMagmatter(recipeTier, parallels)
    local p = math.max(1, math.floor(tonumber(parallels) or 1))
    if p <= 1 then return 0 end
    return p * RecipesDb.magmatterPerParallel(recipeTier)
end

-- Exact GTNH 2.9.0 duration multiplier on T4 Nano Forge: 0.9999 ^ MaxParallel
function RecipesDb.speedMultiplier(parallels, forgeTier)
    if (tonumber(forgeTier) or 4) < 4 then return 1.0 end
    local p = math.max(1, math.floor(tonumber(parallels) or 1))
    return 0.9999 ^ p
end

-- Exact GTNH 2.9.0 overclock rule from MTENanoForge$1.createOverclockCalculator
function RecipesDb.hasPerfectOC(forgeTier, recipeTier, parallels)
    local ft = math.floor(tonumber(forgeTier) or 4)
    local rt = math.floor(tonumber(recipeTier) or 1)
    local p = math.max(1, math.floor(tonumber(parallels) or 1))
    if ft >= 4 then
        if rt <= 2 then return true end
        if rt == 3 then return p > 1 end
        return false
    end
    return ft > rt
end

function RecipesDb.estimateCycleTicks(recipe, maxInputEu, forgeTier, parallels)
    if not recipe then return 0, false end
    local baseTicks = tonumber(recipe.durationTicks) or 1000
    local eut = math.max(1, tonumber(recipe.eut) or 1)
    local availEu = math.max(eut, tonumber(maxInputEu) or eut)
    local ocs = math.max(0, math.floor(math.log(availEu / eut) / math.log(4)))
    local perf = RecipesDb.hasPerfectOC(forgeTier, recipe.tier, parallels)
    local ocFactor = perf and (4 ^ ocs) or (2 ^ ocs)
    local mult = RecipesDb.speedMultiplier(parallels, forgeTier)
    local ticks = math.max(1, math.floor((baseTicks / ocFactor) * mult + 0.5))
    return ticks, perf
end

function RecipesDb.buildStockRules(recipeId, mult)
    local r = RecipesDb.BY_ID[recipeId]
    if not r then return nil, "Unknown nanite recipe: " .. tostring(recipeId) end
    local m = math.max(1, math.floor(tonumber(mult) or 1))
    local out = {}
    for _, it in ipairs(r.items or {}) do
        if not it.isNaniteInput then
            out[#out + 1] = {
                type = "item",
                name = it.name,
                damage = it.damage or 0,
                label = it.label,
                target = it.amount * m,
                batch = it.amount,
            }
        end
    end
    for _, fl in ipairs(r.fluids or {}) do
        out[#out + 1] = {
            type = "fluid",
            name = fl.name,
            damage = 0,
            label = fl.label,
            target = fl.amount * m,
            batch = fl.amount,
        }
    end
    return out, "Nano: " .. r.label
end

return RecipesDb
