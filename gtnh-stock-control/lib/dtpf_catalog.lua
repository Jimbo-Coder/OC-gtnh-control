-- /home/stock/lib/dtpf_catalog.lua
-- Static GTNH 2.9.0 DTPF passive recipe output catalog for advisory cross-warnings
-- so Mainnet Stock Maintainer warns when DTPF already has a passive recipe for an item/fluid.

local Catalog = {}

Catalog.FAMILIES = {
    { key = "fluid:molten.neutronium:0", familyId = "molten_neutronium", name = "Molten Neutronium" },
    { key = "fluid:molten.cosmicneutronium:0", familyId = "molten_cosmic_neutronium", name = "Molten Cosmic Neutronium" },
    { key = "fluid:molten.bedrockium:0", familyId = "molten_bedrockium", name = "Molten Bedrockium" },
    { key = "fluid:molten.hypogen:0", familyId = "molten_hypogen", name = "Molten Hypogen" },
    { key = "fluid:molten.chromaticglass:0", familyId = "molten_chromatic_glass", name = "Molten Chromatic Glass" },
    { key = "fluid:molten.spacetime:0", familyId = "molten_spacetime", name = "Molten SpaceTime" },
    { key = "item:gregtech:gt.metaitem.01:32415", familyId = "raw_tesseract", name = "Raw Tesseract" },
    { key = "item:GalacticraftAmunRa:tile.baseBlockRock:14", familyId = "meteoric_iron_rock", name = "Dark Matter" },
    { key = "fluid:molten.infinity:0", familyId = "molten_infinity", name = "Molten Infinity" },
    { key = "fluid:molten.tetraindiumditindibariumtitaniumheptacoppertetrakaidekaoxid:0", familyId = "sc_base_luv", name = "Molten Superconductor Base LuV" },
    { key = "fluid:molten.tetranaquadahdiindiumhexaplatiumosminid:0", familyId = "sc_base_zpm", name = "Molten Superconductor Base ZPM" },
    { key = "fluid:molten.longasssuperconductornameforuvwire:0", familyId = "sc_base_uv", name = "Molten Superconductor Base UV" },
    { key = "fluid:molten.longasssuperconductornameforuhvwire:0", familyId = "sc_base_uhv", name = "Molten Superconductor Base UHV" },
    { key = "fluid:molten.superconductoruevbase:0", familyId = "sc_base_uev", name = "Molten Superconductor Base UEV" },
    { key = "fluid:molten.superconductoruivbase:0", familyId = "sc_base_uiv", name = "Molten Superconductor Base UIV" },
    { key = "fluid:molten.superconductorumvbase:0", familyId = "sc_base_umv", name = "Molten Superconductor Base UMV" },
    { key = "fluid:molten.celestialtungsten:0", familyId = "celestial_tungsten", name = "Molten Celestial Tungsten & Transcendent Metal" },
    { key = "fluid:molten.quantum:0", familyId = "astral_titanium_quantum", name = "Astral Titanium & Molten Quantum" },
    { key = "fluid:spatialfluid:0", familyId = "molten_space_loop", name = "Timepiece / Spatially Enlarged Fluid" },
    { key = "fluid:temporalfluid:0", familyId = "molten_time_loop", name = "Tachyon Rich Temporal Fluid" },
    { key = "item:miscutils:MU-metaitem.01:32105", familyId = "quantum_anomaly", name = "Quantum Anomaly" },
    { key = "fluid:dimensionallyshiftedsuperfluid:0", familyId = "dimensionally_shifted_superfluid", name = "Dimensionally Shifted Superfluid" },
    { key = "item:gregtech:gt.metaitem.01:32416", familyId = "gigachad_token", name = "Giga Chad Token" },
    { key = "fluid:molten.sixphasedcopper:0", familyId = "molten_six_phased_copper", name = "Molten Six-Phased Copper" },
    { key = "item:gregtech:gt.metaitem.02:27192", familyId = "chipped_amalgatite", name = "Chipped Amalgatite" },
    { key = "fluid:molten.shirabon:0", familyId = "molten_shirabon", name = "Molten Shirabon" },
    -- Secondary DTPF hybrid outputs
    { key = "fluid:molten.transcendentmetal:0", familyId = "celestial_tungsten", name = "Molten Transcendent Metal (DTPF)" },
    { key = "fluid:molten.astraltitanium:0", familyId = "astral_titanium_quantum", name = "Molten Astral Titanium (DTPF)" },
}

Catalog.BY_KEY = {}
for i = 1, #Catalog.FAMILIES do
    local e = Catalog.FAMILIES[i]
    Catalog.BY_KEY[e.key] = e
end

function Catalog.makeKey(rType, name, damage)
    local tp = (rType == "fluid") and "fluid" or "item"
    local dmg = (tp == "fluid") and 0 or math.max(0, math.floor(tonumber(damage) or 0))
    return string.format("%s:%s:%d", tp, tostring(name or ""), dmg)
end

function Catalog.lookup(rType, name, damage)
    return Catalog.BY_KEY[Catalog.makeKey(rType, name, damage)]
end

return Catalog
