-- /home/gorge/lib/plasmas.lua
-- GTNH 2.9 Bytecode-Verified Forge of the Gods Exoticizer Plasma & Output Recipe Tables.

local Plasmas = {}

Plasmas.GLUON = {
    ["Aluminium"]      = "plasma.aluminium",
    ["Americium"]      = "plasma.americium",
    ["Antimony"]       = "plasma.antimony",
    ["Ardite"]         = "plasma.ardite",
    ["Argon"]          = "plasma.argon",
    ["Arsenic"]        = "plasma.arsenic",
    ["Barium"]         = "plasma.barium",
    ["Beryllium"]      = "plasma.beryllium",
    ["Bismuth"]        = "plasma.bismuth",
    ["Cadmium"]        = "plasma.cadmium",
    ["Caesium"]        = "plasma.caesium",
    ["Calcium"]        = "plasma.calcium",
    ["Carbon"]         = "plasma.carbon",
    ["Cerium"]         = "plasma.cerium",
    ["Chlorine"]       = "plasma.chlorine",
    ["Chrome"]         = "plasma.chrome",
    ["Cobalt"]         = "plasma.cobalt",
    ["Copper"]         = "plasma.copper",
    ["Curium"]         = "plasma.curium",
    ["Desh"]           = "plasma.desh",
    ["Deuterium"]      = "plasma.deuterium",
    ["Dysprosium"]     = "plasma.dysprosium",
    ["Erbium"]         = "plasma.erbium",
    ["Europium"]       = "plasma.europium",
    ["Fluorine"]       = "plasma.fluorine",
    ["Gadolinium"]     = "plasma.gadolinium",
    ["Gallium"]        = "plasma.gallium",
    ["Germanium"]      = "plasma.germanium",
    ["Gold"]           = "plasma.gold",
    ["Hafnium"]        = "plasma.hafnium",
    ["Helium"]         = "plasma.helium",
    ["Holmium"]        = "plasma.holmium",
    ["Hydrogen"]       = "plasma.hydrogen",
    ["Indium"]         = "plasma.indium",
    ["Iodine"]         = "plasma.iodine",
    ["Iron"]           = "plasma.iron",
    ["Lanthanum"]      = "plasma.lanthanum",
    ["Lithium"]        = "plasma.lithium",
    ["Lutetium"]       = "plasma.lutetium",
    ["Magnesium"]      = "plasma.magnesium",
    ["Manganese"]      = "plasma.manganese",
    ["Mercury"]        = "plasma.mercury",
    ["Meteoric Iron"]  = "plasma.meteoriciron",
    ["Molybdenum"]     = "plasma.molybdenum",
    ["Neodymium"]      = "plasma.neodymium",
    ["Nickel"]         = "plasma.nickel",
    ["Niobium"]        = "plasma.niobium",
    ["Nitrogen"]       = "plasma.nitrogen",
    ["Oriharukon"]     = "plasma.oriharukon",
    ["Palladium"]      = "plasma.palladium",
    ["Phosphorus"]     = "plasma.phosphorus",
    ["Potassium"]      = "plasma.potassium",
    ["Praseodymium"]   = "plasma.praseodymium",
    ["Promethium"]     = "plasma.promethium",
    ["Radon"]          = "plasma.radon",
    ["Raw Silicon"]    = "plasma.silicon",
    ["Silicon"]        = "plasma.silicon",
    ["Rhenium"]        = "plasma.rhenium",
    ["Rhodium"]        = "plasma.rhodium",
    ["Rubidium"]       = "plasma.rubidium",
    ["Ruthenium"]      = "plasma.ruthenium",
    ["Samarium"]       = "plasma.samarium",
    ["Silver"]         = "plasma.silver",
    ["Sodium"]         = "plasma.sodium",
    ["Strontium"]      = "plasma.strontium",
    ["Sulfur"]         = "plasma.sulfur",
    ["Tantalum"]       = "plasma.tantalum",
    ["Tellurium"]      = "plasma.tellurium",
    ["Terbium"]        = "plasma.terbium",
    ["Thallium"]       = "plasma.thallium",
    ["Thorium 232"]    = "plasma.thorium232",
    ["Thulium"]        = "plasma.thulium",
    ["Tin"]            = "plasma.tin",
    ["Titanium"]       = "plasma.titanium",
    ["Tritium"]        = "plasma.tritium",
    ["Tungsten"]       = "plasma.tungsten",
    ["Uranium 235"]    = "plasma.uranium235",
    ["Uranium 238"]    = "plasma.uranium",
    ["Vanadium"]       = "plasma.vanadium",
    ["Ytterbium"]      = "plasma.ytterbium",
    ["Yttrium"]        = "plasma.yttrium",
    ["Zinc"]           = "plasma.zinc",
    ["Zirconium"]      = "plasma.zirconium",
}

Plasmas.MAGMATTER = {
    ["Awakened Draconium"]          = "plasma.draconiumawakened",
    ["Bedrockium"]                  = "plasma.bedrockium",
    ["Celestial Tungsten"]          = "plasma.celestialtungsten",
    ["Chromatic Glass"]             = "plasma.chromaticglass",
    ["Cosmic Neutronium"]           = "plasma.cosmicneutronium",
    ["Draconium"]                   = "plasma.draconium",
    ["Dragonblood"]                 = "plasma.dragonblood",
    ["Flerovium"]                   = "plasma.flerovium_gt5u",
    ["Hypogen"]                     = "plasma.hypogen",
    ["Ichorium"]                    = "plasma.ichorium",
    ["Infinity"]                    = "plasma.infinity",
    ["Neutronium"]                  = "plasma.neutronium",
    ["Rhugnor"]                     = "plasma.rhugnor",
    ["Six-Phased Copper"]           = "plasma.sixphasedcopper",
    ["Tritanium"]                   = "plasma.tritanium",
    ["Spatially Enlarged Fluid"]    = "spatialfluid",
    ["Tachyon Rich Temporal Fluid"] = "temporalfluid",
}

local GLUON_LOWER = {}
for k, v in pairs(Plasmas.GLUON) do
    GLUON_LOWER[k:lower()] = v
end

local MAGMATTER_LOWER = {}
for k, v in pairs(Plasmas.MAGMATTER) do
    MAGMATTER_LOWER[k:lower()] = v
end

function Plasmas.resolve(mode, key)
    if type(key) ~= "string" or key == "" then return nil end
    local tbl = (mode == "magmatter") and Plasmas.MAGMATTER or Plasmas.GLUON
    local lowerTbl = (mode == "magmatter") and MAGMATTER_LOWER or GLUON_LOWER
    return tbl[key] or lowerTbl[key:lower()]
end

function Plasmas.normalizeItemLabel(label)
    label = tostring(label or ""):match("^%s*(.-)%s*$")
    if label == "" then return nil, 0 end
    local mat = label:match("^[Tt]iny%s+[Pp]ile%s+[Oo]f%s+(.+)%s+[Dd]ust$")
        or label:match("^[Tt]iny%s+(.+)%s+[Dd]ust$")
        or label:match("^[Pp]ile%s+[Oo]f%s+(.+)%s+[Dd]ust$")
    if mat and mat ~= "" then
        return mat, 1
    end
    local fullMat = label:match("^(.+)%s+[Dd]ust$")
    if fullMat and fullMat ~= "" then
        return fullMat, 9
    end
    return label, 1
end

function Plasmas.normalizeFluidLabel(label)
    label = tostring(label or ""):match("^%s*(.-)%s*$")
    if label == "" then return nil end
    local clean = label:gsub("%s+[Gg]as$", "")
    if clean == "" then return label end
    return clean
end

-- Parse raw AE2 getItemsInNetwork + getFluidsInNetwork into distinct material buckets.
function Plasmas.parseOutputNetwork(items, fluids)
    local outputs = {}
    local distinct = 0

    local function addEntry(key, amount, isLiquid, rawFluidName)
        if not key or key == "" or amount <= 0 then return end
        local existing = outputs[key]
        if existing then
            existing.count = existing.count + amount
        else
            outputs[key] = {
                label = key,
                count = amount,
                isLiquid = isLiquid,
                fluidName = rawFluidName,
            }
            distinct = distinct + 1
        end
    end

    if type(items) == "table" then
        for i = 1, #items do
            local it = items[i]
            if type(it) == "table" then
                local sz = math.floor(tonumber(it.size or it.amount) or 0)
                if sz > 0 and tostring(it.name or "") ~= "ae2fc:fluid_drop" then
                    local key, coeff = Plasmas.normalizeItemLabel(it.label or it.name)
                    addEntry(key, sz * coeff, false, nil)
                end
            end
        end
    end

    if type(fluids) == "table" then
        for i = 1, #fluids do
            local fl = fluids[i]
            if type(fl) == "table" then
                local amt = math.floor(tonumber(fl.amount or fl.size) or 0)
                if amt > 0 then
                    local key = Plasmas.normalizeFluidLabel(fl.label or fl.name)
                    addEntry(key, amt, true, fl.name)
                end
            end
        end
    end

    return outputs, distinct
end

-- Compute deterministic plasma fluid inputs for either "magmatter" (3) or "gluon" (7).
function Plasmas.computeBatchInputs(mode, parsedOutputs)
    if type(parsedOutputs) ~= "table" then
        return nil, "No parsed outputs"
    end
    local count = 0
    local keys = {}
    for k in pairs(parsedOutputs) do
        count = count + 1
        keys[#keys + 1] = k
    end
    table.sort(keys)

    if mode == "magmatter" then
        if count ~= 3 then
            return nil, string.format("Expected 3 Magmatter outputs, got %d", count)
        end
        local sp = parsedOutputs["Spatially Enlarged Fluid"]
        local tp = parsedOutputs["Tachyon Rich Temporal Fluid"]
        if not sp or not tp then
            return nil, "Missing Spatial or Temporal fluid in Magmatter output"
        end
        local diffL = math.abs((sp.count or 0) - (tp.count or 0))
        if diffL <= 0 then
            return nil, "Spatial/Temporal fluid difference is 0"
        end
        local plasmaKey = nil
        for _, k in ipairs(keys) do
            if k ~= "Spatially Enlarged Fluid" and k ~= "Tachyon Rich Temporal Fluid" then
                plasmaKey = k
                break
            end
        end
        local plasmaFluid = plasmaKey and Plasmas.resolve("magmatter", plasmaKey)
        if not plasmaFluid then
            return nil, "Unrecognized Magmatter plasma: " .. tostring(plasmaKey)
        end
        return {
            { label = "Spatially Enlarged Fluid", fluid = "spatialfluid", amount = sp.count },
            { label = "Tachyon Rich Temporal Fluid", fluid = "temporalfluid", amount = tp.count },
            { label = plasmaKey, fluid = plasmaFluid, amount = diffL * 144 },
        }
    end

    -- Default: "gluon" (Quark-Gluon Plasma)
    if count ~= 7 then
        return nil, string.format("Expected 7 Gluon outputs, got %d", count)
    end
    local out = {}
    for _, k in ipairs(keys) do
        local entry = parsedOutputs[k]
        local flName = Plasmas.resolve("gluon", k)
        if not flName then
            return nil, "Unrecognized Gluon output: " .. tostring(k)
        end
        out[#out + 1] = {
            label = k,
            fluid = flName,
            amount = entry.count * (entry.isLiquid and 1000 or 144),
        }
    end
    return out
end

return Plasmas
