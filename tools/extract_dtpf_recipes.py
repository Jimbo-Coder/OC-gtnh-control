#!/usr/bin/env python3
"""
Reusable DTPF Recipe Extractor for GTNH 2.9.0+
Extracts all 78 Dimensionally Transcendent Plasma Forge recipes directly from the modpack jars
(DTPFRecipes, PlasmaForgeRecipes, RecipeLoader2, and DTPFCalculator) and compiles them into a
compact, deduplicated single-source-of-truth Lua database (`lib/recipes_db.lua`).
"""

import argparse
import glob
import os
import re
import shutil
import subprocess
from collections import OrderedDict
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
DTPF_ROOT = SCRIPT_DIR.parent


def discover_mods_dir() -> Path:
    env_mods = os.environ.get("GTNH_MODS_DIR")
    if env_mods:
        return Path(env_mods)
    gtnh_root = DTPF_ROOT.parent.parent
    for cand in sorted(gtnh_root.glob("GT_NH_*/mods"), reverse=True):
        if list(cand.glob("GTNewHorizonsCoreMod-*.jar")):
            return cand
    return gtnh_root / "mods"


def discover_javap() -> str:
    env_javap = os.environ.get("JAVAP")
    if env_javap:
        return env_javap
    gtnh_root = DTPF_ROOT.parent.parent
    jdks = sorted(gtnh_root.glob("tools/jdks/**/bin/javap"), reverse=True)
    if jdks:
        return str(jdks[0])
    which_javap = shutil.which("javap")
    if which_javap:
        try:
            chk = subprocess.run([which_javap, "-version"], capture_output=True, check=False)
            if chk.returncode == 0:
                return which_javap
        except OSError:
            pass
    return "javap"


MODS_DIR = str(discover_mods_dir())
JAVAP = discover_javap()
OUTPUT_LUA = str(DTPF_ROOT / "lib" / "recipes_db.lua")

# Exact DTPFCalculator constants & EBF/Vacuum Freezer parameters from MaterialsInit
CATALYST_ENERGY_VALUES = [14514983, 66768460, 269326451, 1073007393, 4276767521]
CATALYST_TIERS = ["DTCC", "DTPC", "DTRC", "DTEC", "DTSC"]
CATALYST_FLUIDS = {
    "DTCC": ("exciteddtcc", "Excited DTCC"),
    "DTPC": ("exciteddtpc", "Excited DTPC"),
    "DTRC": ("exciteddtrc", "Excited DTRC"),
    "DTEC": ("exciteddtec", "Excited DTEC"),
    "DTSC": ("exciteddtsc", "Excited DTSC"),
}

EBF_VF_PARAMS = {
    "Neutronium": (7600, 491520, 1250, 7680),
    "CosmicNeutronium": (11400, 122880, 1100, 122880),
    "Bedrockium": (11400, 122880, 1200, 122880),
    "SuperconductorLuVBase": (4200, 7680, 400, 30720),
    "SuperconductorZPMBase": (4800, 7680, 400, 122880),
    "SuperconductorUVBase": (8400, 30720, 800, 491520),
    "SuperconductorUHVBase": (10800, 122880, 1600, 1966080),
    "SuperconductorUEVBase": (15720, 491520, 3200, 7864320),
    "SuperconductorUIVBase": (15720, 1966080, 3200, 31457280),
    "SuperconductorUMVBase": (15720, 7864320, 3200, 125829120),
}


def compute_dtpf_calculator(calc_cfg):
    base_parallel = calc_cfg.get("setBaseParallel", 1)
    min_tier = calc_cfg.get("setLowestCatalystTier", 0)
    max_tier = calc_cfg.get("setHighestCatalystTier", 3)
    cat_discount = calc_cfg.get("setCatalystDiscount", 0)
    time_discount = calc_cfg.get("setProcessingTimeDiscount", 0)
    scaling = calc_cfg.get("setScalingFactor", 2)
    eut_divisor = float(calc_cfg.get("setEUtDivisor", 1.0))

    if "calculateGenericEBFBasedRecipe" in calc_cfg:
        mat_expr = str(calc_cfg["calculateGenericEBFBasedRecipe"])
        mat_name = mat_expr.split("Materials.")[1].split(":")[0]
        ebf_base_dur, ebf_eut, vf_dur, vf_eut = EBF_VF_PARAMS[mat_name]
        ebf_dur = int(ebf_base_dur * 0.3)
        recipe_dur = ebf_dur
        total_base_eu = (vf_eut * vf_dur + ebf_eut * ebf_dur) * base_parallel
        dtpf_eut = (total_base_eu // ebf_dur) // 10
    else:
        eut, dur = calc_cfg["calculateNonEBFRecipe"]
        recipe_dur = dur
        total_base_eu = eut * dur * base_parallel
        dtpf_eut = (total_base_eu // dur) // 10

    cap = 2147483647.0 / (scaling ** (max_tier - min_tier))
    while dtpf_eut > cap:
        dtpf_eut //= scaling

    cat_amounts = {}
    res_amounts = {}
    durations = {}
    euts = {}
    for i in range(max_tier - min_tier + 1):
        tier = min_tier + i
        term1 = total_base_eu * (0.8 - i * 0.1) * (scaling ** i)
        term2 = (dtpf_eut * (scaling ** i) * (recipe_dur / (scaling ** (i + 1)))) / eut_divisor
        cat_amt = int(((term1 - term2) / CATALYST_ENERGY_VALUES[tier]) * (1.0 - cat_discount / 100.0))
        cat_amounts[tier] = cat_amt
        res_amounts[tier] = int(cat_amt * ((2.0 ** tier) / 8.0))
        durations[tier] = int((recipe_dur / (scaling ** (tier + 1 - min_tier))) * (1.0 - time_discount / 100.0))
        euts[tier] = int((dtpf_eut * (scaling ** (tier - min_tier))) / eut_divisor)

    return {
        "cat": cat_amounts,
        "res": res_amounts,
        "dur": durations,
        "eut": euts,
    }


ITEM_MAP = {
    "GGMaterial.tairitsu": ("bartworks:gt.bwMetaGeneratedstick", 10106, "Tairitsu Rod"),
    "BlockList.Quantinum": ("dreamcraft:Quantinum", 0, "Block of Quantinum"),
    "NHItemList.MysteriousCrystalLens": ("dreamcraft:MysteriousCrystalLens", 0, "Mysterious Crystal Lens"),
    "Mods.Avaritia:Resource:5": ("Avaritia:Resource", 5, "Infinity Catalyst"),
    "Mods.Avaritia:Resource:8": ("Avaritia:Resource", 8, "Infinity Block"),
    "Mods.GalacticraftAmunRa:tile.baseBlockRock:14": ("GalacticraftAmunRa:tile.baseBlockRock", 14, "Dark Matter"),
    "Mods.SuperSolarPanels:enderquantumcomponent": ("supersolarpanel:enderquantumcomponent", 0, "Ender Quantum Component"),
    "ItemRefer.HiC_T5": ("GoodGenerator:huiCircuit", 4, "Hi-Computation Station T5"),
    "Loaders.huiCircuit": ("GoodGenerator:huiCircuit", 4, "Hi-Computation Station T5"),
    "ItemList.EnergisedTesseract": ("gregtech:gt.metaitem.01", 32417, "Energised Tesseract"),
    "ItemList.Field_Generator_UEV": ("gregtech:gt.metaitem.01", 32679, "Field Generator (UEV)"),
    "ItemList.Field_Generator_UIV": ("gregtech:gt.metaitem.01", 32045, "Field Generator (UIV)"),
    "ItemList.Field_Generator_UMV": ("gregtech:gt.metaitem.01", 32046, "Field Generator (UMV)"),
    "ItemList.GigaChad": ("gregtech:gt.metaitem.01", 32416, "Giga Chad Token"),
    "ItemList.StableBosonContainmentUnit": ("gregtech:gt.metaitem.03", 32303, "Stable Boson Containment Unit"),
    "ItemList.Tesseract": ("gregtech:gt.metaitem.01", 32415, "Raw Tesseract"),
    "ItemList.Timepiece": ("gregtech:gt.metaitem.03", 32757, "Timepiece"),
    "Materials.TranscendentMetal:getBlocks": ("gregtech:gt.blockmetal9", 4, "Block of Transcendent Metal"),
    "Materials.TranscendentMetal:block": ("gregtech:gt.blockmetal9", 4, "Block of Transcendent Metal"),
    "Materials.TranscendentMetal:getDust": ("gregtech:gt.metaitem.01", 2581, "Transcendent Metal Dust"),
    "Materials.TranscendentMetal:stick": ("gregtech:gt.metaitem.01", 23581, "Transcendent Metal Rod"),
    "Materials.Dilithium:getGems": ("gregtech:gt.metaitem.01", 8515, "Dilithium Crystal"),
    "Materials.Universium:getNanite": ("gregtech:gt.metaitem.03", 4139, "Universium Nanite"),
    "Materials.MagMatter:nanite": ("gregtech:gt.metaitem.03", 4143, "Magmatter Nanite"),
    "Mods.Avaritia:Singularity:5": ("Avaritia:Singularity", 5, "Copper Singularity"),
    "Mods.NewHorizonsCoreMod:ChromaticLens": ("dreamcraft:ChromaticLens", 0, "Chromatic Lens"),
    "blockCosmicNeutronium": ("Avaritia:Resource_Block", 0, "Cosmic Neutronium Block"),
    "Materials.ZPM:circuit": ("gregtech:gt.metaitem.03", 32088, "ZPM Circuit (Any)"),
    "Materials.Amalgatite:gemChipped": ("gregtech:gt.metaitem.02", 27192, "Chipped Amalgatite"),
    "Materials.Jasper:gemExquisite": ("gregtech:gt.metaitem.02", 30511, "Exquisite Jasper"),
    "Materials.Opal:gemExquisite": ("gregtech:gt.metaitem.02", 30510, "Exquisite Opal"),
    "Materials.Ruby:gemExquisite": ("gregtech:gt.metaitem.02", 30502, "Exquisite Ruby"),
    "Materials.Sapphire:gemExquisite": ("gregtech:gt.metaitem.02", 30503, "Exquisite Sapphire"),
    "Materials.DarkIron:plateDense": ("gregtech:gt.metaitem.01", 22342, "Dense Deep Dark Iron Plate"),
    "Materials.Eternity:round": ("gregtech:gt.metaitem.01", 25141, "Eternity Round"),
    "Materials.Hexanite:round": ("gregtech:gt.metaitem.01", 25174, "Hexanite Round"),
    "Materials.MagMatter:round": ("gregtech:gt.metaitem.01", 25143, "Magmatter Round"),
    "Materials.CosmicNeutronium:stick": ("gregtech:gt.metaitem.01", 23982, "Cosmic Neutronium Rod"),
    "Materials.Sunnarium:stick": ("gregtech:gt.metaitem.01", 23318, "Sunnarium Rod"),
    "CombType.COSMICNEUTRONIUM": ("gregtech:gt.comb", 117, "Cosmic Neutronium Comb"),
    "CombType.INFINITY": ("gregtech:gt.comb", 119, "Infinity Comb"),
    "ASTRAL_TITANIUM:getBlock": ("miscutils:blockBlockAstralTitanium", 0, "Block of Astral Titanium"),
    "ABYSSAL:getPlate": ("miscutils:itemPlateAbyssalAlloy", 0, "Abyssal Alloy Plate"),
    "BLACK_TITANIUM:getPlate": ("miscutils:itemPlateBlackTitanium", 0, "Black Titanium Plate"),
    "BOTMIUM:getPlate": ("miscutils:itemPlateBotmium", 0, "Botmium Plate"),
    "OCTIRON:getRod": ("miscutils:itemRodOctiron", 0, "Octiron Rod"),
    "ARCANITE:getScrew": ("miscutils:itemScrewArcanite", 0, "Arcanite Screw"),
    "BOTMIUM:getScrew": ("miscutils:itemScrewBotmium", 0, "Botmium Screw"),
    "ZERON_100:getScrew": ("miscutils:itemScrewZeron100", 0, "Zeron-100 Screw"),
    "Compressed_Fusion_Reactor": ("miscutils:MU-metaitem.01", 32100, "Hypervisor Matrix (Fusion)"),
    "Energy_Core_UHV": ("miscutils:item.itemBufferCore10", 0, "Energy Core (UHV)"),
    "Laser_Lens_Special": ("miscutils:MU-metaitem.01", 32105, "Quantum Anomaly"),
    "SpaceTimeBendingCore": ("miscutils:gtplusplus.blockcasings.5", 14, "SpaceTime Bending Core"),
    "SpaceTimeContinuumRipper": ("miscutils:gtplusplus.blockcasings.5", 10, "SpaceTime Continuum Ripper"),
    "itemStandarParticleBase": ("miscutils:particleBase", 24, "Unknown Particle"),
}

FLUID_MAP = {
    "GGMaterial.metastableOganesson:getMolten": ("molten.metastable oganesson", "Molten Metastable Oganesson"),
    "GGMaterial.tairitsu:getMolten": ("molten.tairitsu", "Molten Tairitsu"),
    "Materials.DTR:getFluid": ("dimensionallytranscendentresidue", "Dimensionally Transcendent Residue (DTR)"),
    "Materials.DimensionallyShiftedSuperfluid:getFluid": ("dimensionallyshiftedsuperfluid", "Dimensionally Shifted Superfluid"),
    "Materials.ExcitedDTCC:getFluid": ("exciteddtcc", "Excited DTCC"),
    "Materials.ExcitedDTPC:getFluid": ("exciteddtpc", "Excited DTPC"),
    "Materials.ExcitedDTRC:getFluid": ("exciteddtrc", "Excited DTRC"),
    "Materials.ExcitedDTEC:getFluid": ("exciteddtec", "Excited DTEC"),
    "Materials.ExcitedDTSC:getFluid": ("exciteddtsc", "Excited DTSC"),
    "Materials.Grade8PurifiedWater:getFluid": ("grade8purifiedwater", "Subatomically Perfect Water (Grade 8)"),
    "Materials.RadoxHeavy:getFluid": ("heavyradox", "Heavy Radox"),
    "Materials.RadoxSuperHeavy:getFluid": ("superheavyradox", "Super Heavy Radox"),
    "Materials.StableBaryonicMatter:getFluid": ("stablebaryonicmatter", "Stabilised Baryonic Matter"),
    "Materials.StargateCrystalSlurry:getFluid": ("sgcrystalslurry", "Stargate Crystal Slurry"),
    "Materials.Americium:getMolten": ("molten.americium", "Molten Americium"),
    "Materials.Barium:getMolten": ("molten.barium", "Molten Barium"),
    "Materials.Bedrockium:getMolten": ("molten.bedrockium", "Molten Bedrockium"),
    "Materials.Bismuth:getMolten": ("molten.bismuth", "Molten Bismuth"),
    "Materials.CallistoIce:getMolten": ("molten.callistoice", "Molten Callisto Ice"),
    "Materials.Copper:getMolten": ("molten.copper", "Molten Copper"),
    "Materials.CosmicNeutronium:getMolten": ("molten.cosmicneutronium", "Molten Cosmic Neutronium"),
    "Materials.Draconium:getMolten": ("molten.draconium", "Molten Draconium"),
    "Materials.DraconiumAwakened:getMolten": ("molten.draconiumawakened", "Molten Awakened Draconium"),
    "Materials.Duranium:getMolten": ("molten.duranium", "Molten Duranium"),
    "Materials.Europium:getMolten": ("molten.europium", "Molten Europium"),
    "Materials.Glass:getMolten": ("molten.glass", "Molten Glass"),
    "Materials.Indium:getMolten": ("molten.indium", "Molten Indium"),
    "Materials.Infinity:getMolten": ("molten.infinity", "Molten Infinity"),
    "Materials.Iron:getMolten": ("molten.iron", "Molten Iron"),
    "Materials.Ledox:getMolten": ("molten.ledox", "Molten Ledox"),
    "Materials.Mellion:getMolten": ("molten.mellion", "Molten Mellion"),
    "Materials.Naquadah:getMolten": ("molten.naquadah", "Molten Naquadah"),
    "Materials.Naquadria:getMolten": ("molten.naquadria", "Molten Naquadria"),
    "Materials.Neutronium:getMolten": ("molten.neutronium", "Molten Neutronium"),
    "Materials.Osmiridium:getMolten": ("molten.osmiridium", "Molten Osmiridium"),
    "Materials.Osmium:getMolten": ("molten.osmium", "Molten Osmium"),
    "Materials.Palladium:getMolten": ("molten.palladium", "Molten Palladium"),
    "Materials.RadoxPolymer:getMolten": ("molten.radoxpoly", "Molten Radox Polymer"),
    "Materials.Samarium:getMolten": ("molten.samarium", "Molten Samarium"),
    "Materials.SixPhasedCopper:getMolten": ("molten.sixphasedcopper", "Molten Six-Phased Copper"),
    "Materials.Space:getMolten": ("spatialfluid", "Spatially Enlarged Fluid"),
    "Materials.SpaceTime:getMolten": ("molten.spacetime", "Molten SpaceTime"),
    "Materials.Steel:getMolten": ("molten.steel", "Molten Steel"),
    "Materials.SuperconductorLuVBase:getMolten": ("molten.tetraindiumditindibariumtitaniumheptacoppertetrakaidekaoxid", "Molten Superconductor Base LuV"),
    "Materials.SuperconductorZPMBase:getMolten": ("molten.tetranaquadahdiindiumhexaplatiumosminid", "Molten Superconductor Base ZPM"),
    "Materials.SuperconductorUVBase:getMolten": ("molten.longasssuperconductornameforuvwire", "Molten Superconductor Base UV"),
    "Materials.SuperconductorUHVBase:getMolten": ("molten.longasssuperconductornameforuhvwire", "Molten Superconductor Base UHV"),
    "Materials.SuperconductorUEVBase:getMolten": ("molten.superconductoruevbase", "Molten Superconductor Base UEV"),
    "Materials.SuperconductorUIVBase:getMolten": ("molten.superconductoruivbase", "Molten Superconductor Base UIV"),
    "Materials.SuperconductorUMVBase:getMolten": ("molten.superconductorumvbase", "Molten Superconductor Base UMV"),
    "Materials.Time:getMolten": ("temporalfluid", "Tachyon Rich Temporal Fluid"),
    "Materials.Tin:getMolten": ("molten.tin", "Molten Tin"),
    "Materials.Titanium:getMolten": ("molten.titanium", "Molten Titanium"),
    "Materials.TranscendentMetal:getMolten": ("molten.transcendentmetal", "Molten Transcendent Metal"),
    "Materials.Tritanium:getMolten": ("molten.tritanium", "Molten Tritanium"),
    "Materials.Tungsten:getMolten": ("molten.tungsten", "Molten Tungsten"),
    "Materials.Bismuth:getPlasma": ("plasma.bismuth", "Bismuth Plasma"),
    "Materials.Iron:getPlasma": ("plasma.iron", "Iron Plasma"),
    "Materials.Oxygen:getPlasma": ("plasma.oxygen", "Oxygen Plasma"),
    "Materials.Titanium:getPlasma": ("plasma.titanium", "Titanium Plasma"),
    "BLACK_TITANIUM:getFluidStack": ("molten.blacktitanium", "Molten Black Titanium"),
    "QUANTUM:getFluidStack": ("molten.quantum", "Molten Quantum"),
    "QUANTUM:getFluid": ("molten.quantum", "Molten Quantum"),
    "TITANSTEEL:getFluidStack": ("molten.titansteel", "Molten Titansteel"),
    "ASTRAL_TITANIUM:getFluidStack": ("molten.astraltitanium", "Molten Astral Titanium"),
    "CELESTIAL_TUNGSTEN:getFluidStack": ("molten.celestialtungsten", "Molten Celestial Tungsten"),
    "CELESTIAL_TUNGSTEN:getPlasma": ("plasma.celestialtungsten", "Celestial Tungsten Plasma"),
    "CHRONOMATIC_GLASS:getFluidStack": ("molten.chromaticglass", "Molten Chromatic Glass"),
    "HYPOGEN:getFluidStack": ("molten.hypogen", "Molten Hypogen"),
    "HYPOGEN:getFluid": ("molten.hypogen", "Molten Hypogen"),
    "RHUGNOR:getFluidStack": ("molten.rhugnor", "Molten Rhugnor"),
    "molten.advancednitinol": ("molten.advancednitinol", "Molten Advanced Nitinol"),
    "molten.celestialtungsten": ("molten.celestialtungsten", "Molten Celestial Tungsten"),
    "molten.chromaticglass": ("molten.chromaticglass", "Molten Chromatic Glass"),
    "molten.dragonblood": ("molten.dragonblood", "Molten Dragonblood"),
    "molten.hypogen": ("molten.hypogen", "Molten Hypogen"),
    "molten.orundum": ("molten.orundum", "Molten Orundum"),
    "molten.rhugnor": ("molten.rhugnor", "Molten Rhugnor"),
    "molten.titansteel": ("molten.titansteel", "Molten Titansteel"),
}


TIER_EU_MAP = {
    "RECIPE_LuV": 30720,
    "RECIPE_ZPM": 122880,
    "RECIPE_UV": 491520,
    "RECIPE_UHV": 1966080,
    "RECIPE_UEV": 7864320,
    "RECIPE_UIV": 31457280,
    "RECIPE_UMV": 125829120,
    "RECIPE_UXV": 503316480,
    "RECIPE_MAX": 2013265920,
}


def resolve_val(val):
    if isinstance(val, (int, float)):
        return int(val)
    if isinstance(val, tuple) and val[0] == "STATIC" and "TierEU." in str(val[1]):
        tier_key = str(val[1]).split("TierEU.")[1].split(":")[0]
        return TIER_EU_MAP[tier_key]
    if isinstance(val, tuple) and len(val) == 3 and val[0] in ("ADD", "SUB", "MUL", "DIV"):
        op, a, b = val[0], resolve_val(val[1]), resolve_val(val[2])
        if op == "ADD": return a + b
        if op == "SUB": return a - b
        if op == "MUL": return a * b
        if op == "DIV": return a // b
    if isinstance(val, tuple) and len(val) == 3 and str(val[0]).startswith("get"):
        mname, calc_cfg, tier = val
        res = compute_dtpf_calculator(calc_cfg)
        if mname == "getCatalystAmount":
            return res["cat"][tier]
        if mname == "getResidueAmount":
            return res["res"][tier]
        if mname == "getDuration":
            return res["dur"][tier]
        if mname == "getEUt":
            return res["eut"][tier]
    if isinstance(val, tuple) and len(val) == 2:
        a, b = resolve_val(val[0]), resolve_val(val[1])
        # GTRecipeBuilder.duration(mins_or_secs, secs_or_ticks)
        return a * 1200 + b * 20 if a <= 10 else a * 20 + b
    raise ValueError(f"Cannot resolve numeric value: {val}")


def resolve_item(it):
    s = str(it)
    if "GTUtility.copyAmount" in s:
        amt = it[3][0]
        inner = resolve_item(it[3][1])
        inner["amount"] = int(amt)
        return inner

    amt = 1
    if isinstance(it, tuple) and it[0] == "INIT":
        args = it[2]
        amt = int(args[1])
        if "huiCircuit" in str(args[0]):
            reg, meta, label = ITEM_MAP["Loaders.huiCircuit"]
            return {"name": reg, "damage": meta, "amount": amt, "label": label}
        if "itemStandarParticleBase" in str(args[0]):
            reg, meta, label = ITEM_MAP["itemStandarParticleBase"]
            return {"name": reg, "damage": meta, "amount": amt, "label": label}

    if isinstance(it, tuple) and it[0] == "CALL":
        meth, target, args = it[1], str(it[2]), it[3]
        if args and isinstance(args[-1], (int, float)) and "getModItem" not in meth:
            amt = int(args[-1])
        elif args and isinstance(args[0], (int, float)) and ("ItemList.get" in meth or "BlockList.get" in meth or "NHItemList.get" in meth or "ItemRefer.get" in meth):
            amt = int(args[0])

        if "GGMaterial.tairitsu" in target:
            reg, meta, label = ITEM_MAP["GGMaterial.tairitsu"]
            return {"name": reg, "damage": meta, "amount": amt, "label": label}
        if "BlockList.Quantinum" in target:
            reg, meta, label = ITEM_MAP["BlockList.Quantinum"]
            return {"name": reg, "damage": meta, "amount": amt, "label": label}
        if "MysteriousCrystalLens" in target:
            reg, meta, label = ITEM_MAP["NHItemList.MysteriousCrystalLens"]
            return {"name": reg, "damage": meta, "amount": amt, "label": label}
        if "getModItem" in meth:
            mod = str(args[0])
            item_key = args[1]
            amt = int(args[2])
            meta = int(args[3]) if len(args) > 3 else 0
            if "Avaritia" in mod and item_key == "Resource" and meta == 5:
                reg, m, label = ITEM_MAP["Mods.Avaritia:Resource:5"]
                return {"name": reg, "damage": m, "amount": amt, "label": label}
            if "Avaritia" in mod and item_key == "Resource" and meta == 8:
                reg, m, label = ITEM_MAP["Mods.Avaritia:Resource:8"]
                return {"name": reg, "damage": m, "amount": amt, "label": label}
            if "Avaritia" in mod and item_key == "Singularity":
                reg, m, label = ITEM_MAP["Mods.Avaritia:Singularity:5"]
                return {"name": reg, "damage": m, "amount": amt, "label": label}
            if "GalacticraftAmunRa" in mod:
                reg, m, label = ITEM_MAP["Mods.GalacticraftAmunRa:tile.baseBlockRock:14"]
                return {"name": reg, "damage": m, "amount": amt, "label": label}
            if "SuperSolarPanels" in mod:
                reg, m, label = ITEM_MAP["Mods.SuperSolarPanels:enderquantumcomponent"]
                return {"name": reg, "damage": m, "amount": amt, "label": label}
            if "NewHorizonsCoreMod" in mod and item_key == "ChromaticLens":
                reg, m, label = ITEM_MAP["Mods.NewHorizonsCoreMod:ChromaticLens"]
                return {"name": reg, "damage": m, "amount": amt, "label": label}
        if "HiC_T5" in target:
            reg, m, label = ITEM_MAP["ItemRefer.HiC_T5"]
            return {"name": reg, "damage": m, "amount": amt, "label": label}
        for k in ["EnergisedTesseract", "Field_Generator_UEV", "Field_Generator_UIV", "Field_Generator_UMV", "GigaChad", "StableBosonContainmentUnit", "Tesseract", "Timepiece"]:
            if f"ItemList.{k}:" in target:
                reg, m, label = ITEM_MAP[f"ItemList.{k}"]
                return {"name": reg, "damage": m, "amount": amt, "label": label}
        for k in ["Compressed_Fusion_Reactor", "Energy_Core_UHV", "Laser_Lens_Special", "SpaceTimeBendingCore", "SpaceTimeContinuumRipper"]:
            if f"GregtechItemList.{k}:" in target:
                reg, m, label = ITEM_MAP[k]
                return {"name": reg, "damage": m, "amount": amt, "label": label}
        if "CombType.COSMICNEUTRONIUM" in str(args):
            reg, m, label = ITEM_MAP["CombType.COSMICNEUTRONIUM"]
            return {"name": reg, "damage": m, "amount": 1, "label": label}
        if "CombType.INFINITY" in str(args):
            reg, m, label = ITEM_MAP["CombType.INFINITY"]
            return {"name": reg, "damage": m, "amount": 1, "label": label}
        if "blockCosmicNeutronium" in str(args):
            reg, m, label = ITEM_MAP["blockCosmicNeutronium"]
            return {"name": reg, "damage": m, "amount": amt, "label": label}
        if "GTOreDictUnificator.get" in meth:
            pref = str(args[0]).split("OrePrefixes.")[1].split(":")[0]
            mat = str(args[1]).split("Materials.")[1].split(":")[0]
            reg, m, label = ITEM_MAP[f"Materials.{mat}:{pref}"]
            return {"name": reg, "damage": m, "amount": amt, "label": label}
        if "Materials.get" in meth:
            mtype = meth.split(".")[1]
            mat = target.split("Materials.")[1].split(":")[0]
            reg, m, label = ITEM_MAP[f"Materials.{mat}:{mtype}"]
            return {"name": reg, "damage": m, "amount": amt, "label": label}
        if "gtPlusPlus/core/material/Material." in meth:
            mtype = meth.split(".")[1]
            mat = target.split(".")[1].split(":")[0]
            reg, m, label = ITEM_MAP[f"{mat}:{mtype}"]
            return {"name": reg, "damage": m, "amount": amt, "label": label}

    raise ValueError(f"Unmapped item: {it}")


def resolve_fluid(fl):
    if isinstance(fl, tuple) and fl[0] == "INIT":
        inner_call, amt_raw = fl[2][0], fl[2][1]
        amt = resolve_val(amt_raw)
        meth, target, args = inner_call[1], str(inner_call[2]), inner_call[3]
        if "FluidRegistry.getFluid" in meth:
            fname = args[0]
            reg, label = FLUID_MAP[fname]
            return {"name": reg, "amount": amt, "label": label}
        mtype = meth.split(".")[1]
        mat = target.split(".")[1].split(":")[0]
        reg, label = FLUID_MAP[f"{mat}:{mtype}"]
        return {"name": reg, "amount": amt, "label": label}

    if isinstance(fl, tuple) and fl[0] == "CALL":
        meth, target, args = fl[1], str(fl[2]), fl[3]
        amt = resolve_val(args[0])
        mtype = meth.split(".")[1]
        if "GGMaterial." in target:
            mat = target.split("GGMaterial.")[1].split(":")[0]
            reg, label = FLUID_MAP[f"GGMaterial.{mat}:{mtype}"]
            return {"name": reg, "amount": amt, "label": label}
        if "Materials." in target:
            mat = target.split("Materials.")[1].split(":")[0]
            reg, label = FLUID_MAP[f"Materials.{mat}:{mtype}"]
            return {"name": reg, "amount": amt, "label": label}
        if "gtPlusPlus" in target:
            mat = target.split(".")[1].split(":")[0]
            reg, label = FLUID_MAP[f"{mat}:{mtype}"]
            return {"name": reg, "amount": amt, "label": label}

    raise ValueError(f"Unmapped fluid: {fl}")


def parse_javap_method(javap_text, method_header="public void run();"):
    code = javap_text.split(method_header)[1].split("LineNumberTable:")[0]
    stack = []
    locals_map = {}
    recipes = []

    for raw_line in code.splitlines():
        line = raw_line.strip()
        m = re.match(r"^\d+:\s+(\S+)(?:\s+(.*))?$", line)
        if not m:
            continue
        op, rest = m.group(1), m.group(2) or ""
        comment = ""
        if "//" in rest:
            rest, comment = [x.strip() for x in rest.split("//", 1)]

        if op.startswith("iconst_"):
            val = -1 if op == "iconst_m1" else int(op.split("_")[1])
            stack.append(val)
        elif op.startswith("lconst_"):
            stack.append(int(op.split("_")[1]))
        elif op.startswith("fconst_"):
            stack.append(float(op.split("_")[1]))
        elif op in ("bipush", "sipush"):
            stack.append(int(rest))
        elif op in ("ldc", "ldc_w", "ldc2_w"):
            if comment.startswith("long "):
                stack.append(int(comment.split()[1].rstrip("l")))
            elif comment.startswith("int "):
                stack.append(int(comment.split()[1]))
            elif comment.startswith("float "):
                stack.append(float(comment.split()[1].rstrip("f")))
            elif comment.startswith("double "):
                stack.append(float(comment.split()[1].rstrip("d")))
            elif comment.startswith("String "):
                stack.append(comment[len("String "):])
            else:
                stack.append(comment)
        elif op == "aconst_null":
            stack.append(None)
        elif op.startswith(("iload", "lload", "fload", "aload")):
            idx = int(op.split("_")[1]) if "_" in op else int(rest)
            stack.append(locals_map.get(idx))
        elif op.startswith(("istore", "lstore", "fstore", "astore")):
            idx = int(op.split("_")[1]) if "_" in op else int(rest)
            locals_map[idx] = stack.pop()
        elif op in ("iadd", "ladd"):
            b, a = stack.pop(), stack.pop()
            stack.append(a + b if isinstance(a, (int, float)) and isinstance(b, (int, float)) else ("ADD", a, b))
        elif op in ("isub", "lsub"):
            b, a = stack.pop(), stack.pop()
            stack.append(a - b if isinstance(a, (int, float)) and isinstance(b, (int, float)) else ("SUB", a, b))
        elif op in ("imul", "lmul"):
            b, a = stack.pop(), stack.pop()
            stack.append(a * b if isinstance(a, (int, float)) and isinstance(b, (int, float)) else ("MUL", a, b))
        elif op in ("idiv", "ldiv"):
            b, a = stack.pop(), stack.pop()
            stack.append(a // b if isinstance(a, (int, float)) and isinstance(b, (int, float)) else ("DIV", a, b))
        elif op in ("l2i", "i2l", "d2l", "l2d", "i2d", "f2d"):
            pass
        elif op == "dup":
            stack.append(stack[-1])
        elif op == "pop":
            stack.pop()
        elif op in ("anewarray", "newarray"):
            sz = stack.pop()
            stack.append([None] * sz)
        elif op == "aastore":
            val = stack.pop()
            idx = stack.pop()
            arr = stack.pop()
            if isinstance(arr, list) and 0 <= idx < len(arr):
                arr[idx] = val
        elif op == "getstatic":
            field = comment.replace("Field ", "")
            stack.append(("STATIC", field))
        elif op == "getfield":
            obj = stack.pop()
            field = comment.replace("Field ", "")
            stack.append(("FIELD", obj, field))
        elif op == "new":
            cls = comment.replace("class ", "")
            stack.append(("NEW", cls))
        elif op in ("invokespecial", "invokevirtual", "invokestatic", "invokeinterface"):
            meth = comment.replace("InterfaceMethod ", "").replace("Method ", "")
            if meth == "java/lang/Integer.valueOf:(I)Ljava/lang/Integer;":
                pass
            elif meth.startswith("com/dreammaster/gthandler/DTPFCalculator."):
                mname = meth.split(".")[1].split(":")[0].strip('"')
                desc = meth.split(":")[1]
                args_part = desc[1 : desc.index(")")]
                arg_types = re.findall(r"\[*(?:L[^;]+;|[ZBCSIFJD])", args_part)
                args = [stack.pop() for _ in range(len(arg_types))][::-1]
                calc = None if op == "invokestatic" else stack.pop()
                if mname == "<init>":
                    stack[-1] = {"type": "calc"}
                elif mname == "dtpfCalculator":
                    stack.append({"type": "calc"})
                elif mname.startswith("set") or mname.startswith("calculate"):
                    if isinstance(calc, dict):
                        calc[mname] = args[0] if len(args) == 1 else tuple(args)
                    stack.append(calc)
                elif mname.startswith("get"):
                    stack.append((mname, dict(calc) if isinstance(calc, dict) else calc, args[0] if args else None))
            elif meth == "gregtech/api/interfaces/internal/IGTRecipeAdder.stdBuilder:()Lgregtech/api/util/GTRecipeBuilder;":
                stack.pop()
                stack.append(
                    {
                        "items_in": [],
                        "items_out": [],
                        "fluids_in": [],
                        "fluids_out": [],
                        "circuit": None,
                        "duration": None,
                        "eut": None,
                        "coil": None,
                    }
                )
            elif meth.startswith("gregtech/api/util/GTRecipeBuilder."):
                bname = meth.split(".")[1].split(":")[0]
                desc = meth.split(":")[1]
                args_part = desc[1 : desc.index(")")]
                arg_types = re.findall(r"\[*(?:L[^;]+;|[ZBCSIFJD])", args_part)
                args = [stack.pop() for _ in range(len(arg_types))][::-1]
                builder = stack.pop()
                if isinstance(builder, dict):
                    if bname == "metadata":
                        if "COIL_HEAT" in str(args[0]):
                            builder["coil"] = args[1]
                    elif bname == "addTo":
                        if "plasmaForgeRecipes" in str(args[0]):
                            recipes.append(builder)
                        stack.append("COLLECTION")
                        continue
                    elif bname == "itemInputs":
                        builder["items_in"] = (
                            args[0] if len(args) == 1 and isinstance(args[0], list) else list(args)
                        )
                    elif bname == "itemOutputs":
                        builder["items_out"] = (
                            args[0] if len(args) == 1 and isinstance(args[0], list) else list(args)
                        )
                    elif bname == "fluidInputs":
                        builder["fluids_in"] = (
                            args[0] if len(args) == 1 and isinstance(args[0], list) else list(args)
                        )
                    elif bname == "fluidOutputs":
                        builder["fluids_out"] = (
                            args[0] if len(args) == 1 and isinstance(args[0], list) else list(args)
                        )
                    elif bname == "circuit":
                        builder["circuit"] = args[0]
                    elif bname == "duration":
                        builder["duration"] = tuple(args) if len(args) > 1 else args[0]
                    elif bname == "eut":
                        builder["eut"] = args[0]
                stack.append(builder)
            else:
                desc = meth.split(":")[1]
                args_part = desc[1 : desc.index(")")]
                arg_types = re.findall(r"\[*(?:L[^;]+;|[ZBCSIFJD])", args_part)
                args = [stack.pop() for _ in range(len(arg_types))][::-1]
                target = None if op == "invokestatic" else stack.pop()
                ret = desc[desc.index(")") + 1 :]
                if op == "invokespecial" and ".<init>" in meth.replace('"', ""):
                    stack[-1] = ("INIT", meth.split(".")[0], args)
                elif ret != "V":
                    stack.append(("CALL", meth.split(":")[0], target, args))
    return recipes


def normalize_recipe(raw):
    items_in = [resolve_item(x) for x in raw["items_in"] if x is not None]
    items_out = [resolve_item(x) for x in raw["items_out"] if x is not None]
    fluids_in = [resolve_fluid(x) for x in raw["fluids_in"] if x is not None]
    fluids_out = [resolve_fluid(x) for x in raw["fluids_out"] if x is not None]
    circuit = int(raw["circuit"]) if raw["circuit"] is not None else None
    if circuit is not None:
        items_in.append(
            {
                "name": "gregtech:gt.integrated_circuit",
                "damage": circuit,
                "amount": 0,
                "label": f"Programmed Circuit #{circuit}",
            }
        )
    duration = resolve_val(raw["duration"])
    eut = resolve_val(raw["eut"])
    coil = int(raw["coil"]) if raw["coil"] is not None else 0

    catalyst_tier = None
    catalyst_amount = 0
    non_cat_fluids_in = []
    for fl in fluids_in:
        matched_cat = False
        for tier_code, (f_id, _) in CATALYST_FLUIDS.items():
            if fl["name"] == f_id:
                catalyst_tier = tier_code
                catalyst_amount = fl["amount"]
                matched_cat = True
                break
        if not matched_cat:
            non_cat_fluids_in.append(fl)

    dtr_out = 0
    non_dtr_fluids_out = []
    for fl in fluids_out:
        if fl["name"] == "dimensionallytranscendentresidue":
            dtr_out += fl["amount"]
        else:
            non_dtr_fluids_out.append(fl)

    dtr_in = 0
    for fl in non_cat_fluids_in:
        if fl["name"] == "dimensionallytranscendentresidue":
            dtr_in += fl["amount"]

    if dtr_out > 0 and dtr_in == 0:
        dtr_role = "producer"
    elif dtr_in > 0 and dtr_out == 0:
        dtr_role = "consumer"
    else:
        dtr_role = "neutral"

    return {
        "catalyst_tier": catalyst_tier,
        "catalyst_amount": catalyst_amount,
        "dtr_in": dtr_in,
        "dtr_out": dtr_out,
        "dtr_role": dtr_role,
        "circuit": circuit,
        "items_in": items_in,
        "items_out": items_out,
        "fluids_in": non_cat_fluids_in,
        "fluids_out": non_dtr_fluids_out,
        "duration_ticks": duration,
        "eut": eut,
        "coil_heat": coil,
    }


def extract_all_raw_recipes(mods_dir: str = MODS_DIR, javap_bin: str = JAVAP):
    nh_jars = sorted(glob.glob(os.path.join(mods_dir, "GTNewHorizonsCoreMod-*.jar")))
    gt_jars = sorted(glob.glob(os.path.join(mods_dir, "gregtech-*.jar")))
    if not nh_jars or not gt_jars:
        raise FileNotFoundError(
            f"Could not find GTNewHorizonsCoreMod-*.jar and gregtech-*.jar in {mods_dir}. Pass --mods-dir or set GTNH_MODS_DIR."
        )
    nh_jar = nh_jars[0]
    gt_jar = gt_jars[0]

    javap_dtpf = subprocess.check_output(
        [javap_bin, "-cp", nh_jar, "-c", "com.dreammaster.gthandler.recipes.DTPFRecipes"], text=True
    )
    javap_pf = subprocess.check_output(
        [javap_bin, "-cp", gt_jar, "-c", "gregtech.loaders.postload.recipes.PlasmaForgeRecipes"], text=True
    )

    raw_list = parse_javap_method(javap_dtpf) + parse_javap_method(javap_pf)
    normalized = [normalize_recipe(r) for r in raw_list]

    # 78th recipe: Molten Shirabon from goodgenerator.loader.RecipeLoader2
    normalized.append(
        {
            "catalyst_tier": None,
            "catalyst_amount": 0,
            "dtr_in": 5000,
            "dtr_out": 0,
            "dtr_role": "consumer",
            "circuit": None,
            "items_in": [
                {
                    "name": "GoodGenerator:huiCircuit",
                    "damage": 4,
                    "amount": 0,
                    "label": "Hi-Computation Station T5",
                }
            ],
            "items_out": [],
            "fluids_in": [
                {"name": "molten.metastable oganesson", "amount": 1152, "label": "Molten Metastable Oganesson"},
                {"name": "molten.precious metals alloy", "amount": 2304, "label": "Molten Precious Metals Alloy"},
                {"name": "molten.spacetime", "amount": 288, "label": "Molten SpaceTime"},
                {
                    "name": "dimensionallytranscendentresidue",
                    "amount": 5000,
                    "label": "Dimensionally Transcendent Residue (DTR)",
                },
            ],
            "fluids_out": [{"name": "molten.shirabon", "amount": 144, "label": "Molten Shirabon"}],
            "duration_ticks": 600,
            "eut": 1572864000,
            "coil_heat": 13500,
        }
    )
    return normalized


def classify_family_and_modifier(r):
    f_out = [f["name"] for f in r["fluids_out"]]
    i_out = [i["name"] for i in r["items_out"]]
    i_in = [i["name"] for i in r["items_in"]]

    if "molten.neutronium" in f_out:
        return ("molten_neutronium", "Molten Neutronium", "Fluid", "standard", "Molten Iron (No Item)")
    if "molten.cosmicneutronium" in f_out:
        if "gregtech:gt.comb" in i_in:
            return ("molten_cosmic_neutronium", "Molten Cosmic Neutronium", "Fluid", "comb", "Cosmic Neutronium Comb + Circuit 1")
        return ("molten_cosmic_neutronium", "Molten Cosmic Neutronium", "Fluid", "standard", "Molten Copper + Circuit 4")
    if "molten.bedrockium" in f_out:
        return ("molten_bedrockium", "Molten Bedrockium", "Fluid", "standard", "Molten Steel (No Item)")
    if "molten.hypogen" in f_out:
        if r["catalyst_tier"] == "DTPC":
            return ("molten_hypogen", "Molten Hypogen", "Fluid", "seed_dtpc", "Molten Hypogen Seed (DTPC)")
        return ("molten_hypogen", "Molten Hypogen", "Fluid", "hypervisor", "Hypervisor Matrix (DTEC / DTSC)")
    if "molten.chromaticglass" in f_out:
        return ("molten_chromatic_glass", "Molten Chromatic Glass", "Fluid", "standard", "Molten Glass (No Item)")
    if "molten.spacetime" in f_out:
        if any(f["name"] == "molten.hypogen" for f in r["fluids_in"]):
            return ("molten_spacetime", "Molten SpaceTime", "Fluid", "hypogen", "DTR + Infinity + Hypogen (144L)")
        return ("molten_spacetime", "Molten SpaceTime", "Fluid", "hypervisor", "DTR + Infinity + Hypervisor Matrix (576L)")
    if "molten.infinity" in f_out:
        out_amt = r["fluids_out"][0]["amount"]
        has_comb = "gregtech:gt.comb" in i_in
        if has_comb:
            if out_amt == 144:
                return ("molten_infinity", "Molten Infinity", "Fluid", "comb_1x", "Infinity Comb + Catalyst Dust (1x Base)")
            return ("molten_infinity", "Molten Infinity", "Fluid", "comb_64x", "Infinity Comb + Catalyst Dust (64x Batch)")
        else:
            if out_amt == 144:
                return ("molten_infinity", "Molten Infinity", "Fluid", "dust_1x", "Infinity Catalyst Dust Only (1x Base)")
            return ("molten_infinity", "Molten Infinity", "Fluid", "dust_64x", "Infinity Catalyst Dust Only (64x Batch)")
    if "molten.tetraindiumditindibariumtitaniumheptacoppertetrakaidekaoxid" in f_out:
        return ("sc_base_luv", "Molten Superconductor Base LuV", "Fluid", "standard", "Molten Metals + Circuit 6")
    if "molten.tetranaquadahdiindiumhexaplatiumosminid" in f_out:
        return ("sc_base_zpm", "Molten Superconductor Base ZPM", "Fluid", "standard", "Molten Metals (No Item)")
    if "molten.longasssuperconductornameforuvwire" in f_out:
        return ("sc_base_uv", "Molten Superconductor Base UV", "Fluid", "standard", "Molten Metals (No Item)")
    if "molten.longasssuperconductornameforuhvwire" in f_out:
        return ("sc_base_uhv", "Molten Superconductor Base UHV", "Fluid", "standard", "Molten Metals (No Item)")
    if "molten.superconductoruevbase" in f_out:
        return ("sc_base_uev", "Molten Superconductor Base UEV", "Fluid", "standard", "Molten Metals + Iron Plasma")
    if "molten.superconductoruivbase" in f_out:
        return ("sc_base_uiv", "Molten Superconductor Base UIV", "Fluid", "standard", "Molten Metals + Bismuth Plasma")
    if "molten.superconductorumvbase" in f_out:
        return ("sc_base_umv", "Molten Superconductor Base UMV", "Fluid", "standard", "Molten Metals + Oxygen Plasma")
    if "molten.celestialtungsten" in f_out:
        return ("celestial_tungsten", "Molten Celestial Tungsten & Transcendent Metal", "Hybrid", "standard", "Raw Tesseract + Cosmic Block")
    if "molten.quantum" in f_out:
        return ("astral_titanium_quantum", "Astral Titanium & Molten Quantum", "Hybrid", "standard", "Block of Quantinum + Energy Core UHV")
    if "spatialfluid" in f_out and any(i["damage"] == 32757 for i in r["items_out"]):
        return ("timepiece", "Timepiece & Spatially Enlarged Fluid", "Hybrid", "standard", "Dense Deep Dark Iron + Dilithium + Universium Nanite")
    if "spatialfluid" in f_out and any(i["damage"] == 32415 for i in r["items_out"]):
        return ("molten_space_loop", "Spatially Enlarged Fluid", "Hybrid", "standard", "Energised Tesseract + Quantum Anomaly + Tachyon Rich Temporal Fluid")
    if "temporalfluid" in f_out:
        return ("molten_time_loop", "Tachyon Rich Temporal Fluid", "Hybrid", "standard", "Energised Tesseract + Timepiece + Spatially Enlarged Fluid")
    if "dimensionallyshiftedsuperfluid" in f_out:
        return ("dimensionally_shifted_superfluid", "Dimensionally Shifted Superfluid", "Fluid", "standard", "Stabilised Baryonic + Metastable Oganesson + Radox")
    if "molten.sixphasedcopper" in f_out:
        return ("molten_six_phased_copper", "Molten Six-Phased Copper", "Fluid", "standard", "Copper Singularity + 6 Molten Metals")
    if "molten.shirabon" in f_out:
        return ("molten_shirabon", "Molten Shirabon", "Fluid", "standard", "DTR + Metastable Oganesson + Precious Metals + SpaceTime")
    if any(i["damage"] == 32415 for i in r["items_out"]) and not f_out:
        return ("raw_tesseract", "Raw Tesseract", "Item", "standard", "Tesseract Components (DTRC / DTEC / DTSC)")
    if "GalacticraftAmunRa:tile.baseBlockRock" in i_out:
        return ("meteoric_iron_rock", "Dark Matter", "Item", "standard", "Transcendent Block + Infinity Block + Boson Unit")
    if any(i["damage"] == 32105 for i in r["items_out"]):
        if any(i["name"] == "miscutils:particleBase" for i in r["items_in"]):
            return ("quantum_anomaly", "Quantum Anomaly", "Item", "unknown_particle", "Unknown Particle + Molten Duranium (1x Output)")
        return ("quantum_anomaly", "Quantum Anomaly", "Item", "boson_loop", "Stable Boson + Molten Tritanium (1x -> 4x Loop)")
    if any(i["damage"] == 32416 for i in r["items_out"]):
        return ("gigachad_token", "Giga Chad Token", "Item", "standard", "64x UEV/UIV/UMV Field Generators + SpaceTime")
    if any(i["damage"] == 27192 for i in r["items_out"]):
        return ("chipped_amalgatite", "Chipped Amalgatite", "Item", "standard", "Eternity/Magmatter/Hexanite Rounds + Exquisite Gems")

    raise ValueError(f"Unclassified recipe: {r}")


def lua_str(s):
    return '"' + str(s).replace("\\", "\\\\").replace('"', '\\"') + '"'


def format_lua_db(families):
    lines = [
        "-- AUTO-GENERATED BY tools/extract_dtpf_recipes.py — DO NOT EDIT MANUALLY",
        f"-- Source of Truth: GTNH 2.9.0 (78 raw DTPF recipes collapsed into {len(families)} deduplicated families)",
        "local M = {}",
        "",
        "M.CATALYST_TIERS = {",
        '  { code = "DTCC", index = 1, fluid = "exciteddtcc", label = "Excited DTCC", energy = 14514983 },',
        '  { code = "DTPC", index = 2, fluid = "exciteddtpc", label = "Excited DTPC", energy = 66768460 },',
        '  { code = "DTRC", index = 3, fluid = "exciteddtrc", label = "Excited DTRC", energy = 269326451 },',
        '  { code = "DTEC", index = 4, fluid = "exciteddtec", label = "Excited DTEC", energy = 1073007393 },',
        '  { code = "DTSC", index = 5, fluid = "exciteddtsc", label = "Excited DTSC", energy = 4276767521 },',
        "}",
        "",
        "M.FAMILIES = {",
    ]

    for fam_id, fam in families.items():
        lines.append("  {")
        lines.append(f"    id = {lua_str(fam_id)},")
        lines.append(f"    name = {lua_str(fam['name'])},")
        lines.append(f"    category = {lua_str(fam['category'])},")
        lines.append(f"    dtrRole = {lua_str(fam['dtr_role'])},")
        if fam["primary_output"]:
            po = fam["primary_output"]
            lines.append(
                f"    primaryOutput = {{ type = {lua_str(po['type'])}, name = {lua_str(po['name'])}, damage = {po.get('damage', 0)}, label = {lua_str(po['label'])} }},"
            )
        lines.append("    modifiers = {")
        for mod_id, mod in fam["modifiers"].items():
            lines.append("      {")
            lines.append(f"        id = {lua_str(mod_id)},")
            lines.append(f"        label = {lua_str(mod['label'])},")
            lines.append(f"        circuit = {mod['circuit'] if mod['circuit'] is not None else 'nil'},")
            lines.append("        tiers = {")
            # Sort tiers in canonical order: NONE, DTCC, DTPC, DTRC, DTEC, DTSC
            tier_order = {"NONE": 0, "DTCC": 1, "DTPC": 2, "DTRC": 3, "DTEC": 4, "DTSC": 5}
            for t_code in sorted(mod["tiers"].keys(), key=lambda x: tier_order.get(x, 99)):
                t = mod["tiers"][t_code]
                lines.append(f"          [{lua_str(t_code)}] = {{")
                lines.append(f"            circuit = {t['circuit'] if t['circuit'] is not None else 'nil'},")
                lines.append(f"            catalystAmount = {t['catalyst_amount']},")
                lines.append(f"            dtrIn = {t['dtr_in']},")
                lines.append(f"            dtrOut = {t['dtr_out']},")
                lines.append(f"            coilHeat = {t['coil_heat']},")
                lines.append(f"            durationTicks = {t['duration_ticks']},")
                lines.append(f"            eut = {t['eut']},")
                lines.append("            itemsIn = {")
                for it in t["items_in"]:
                    non_cons = "true" if it["amount"] == 0 else "false"
                    lines.append(
                        f"              {{ name = {lua_str(it['name'])}, damage = {it['damage']}, amount = {it['amount']}, label = {lua_str(it['label'])}, nonConsumed = {non_cons} }},"
                    )
                lines.append("            },")
                lines.append("            fluidsIn = {")
                for fl in t["fluids_in"]:
                    lines.append(
                        f"              {{ name = {lua_str(fl['name'])}, amount = {fl['amount']}, label = {lua_str(fl['label'])} }},"
                    )
                lines.append("            },")
                lines.append("            itemsOut = {")
                for it in t["items_out"]:
                    lines.append(
                        f"              {{ name = {lua_str(it['name'])}, damage = {it['damage']}, amount = {it['amount']}, label = {lua_str(it['label'])} }},"
                    )
                lines.append("            },")
                lines.append("            fluidsOut = {")
                for fl in t["fluids_out"]:
                    lines.append(
                        f"              {{ name = {lua_str(fl['name'])}, amount = {fl['amount']}, label = {lua_str(fl['label'])} }},"
                    )
                lines.append("            },")
                lines.append("          },")
            lines.append("        },")
            lines.append("      },")
        lines.append("    },")
        lines.append("  },")

    lines.append("}")
    lines.append("")
    lines.append("M.BY_ID = {}")
    lines.append("for _, fam in ipairs(M.FAMILIES) do")
    lines.append("  M.BY_ID[fam.id] = fam")
    lines.append("end")
    lines.append("")
    lines.append("return M")
    lines.append("")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(
        description="Extract all 78 GTNH 2.9+ DTPF recipes from modpack jars into lib/recipes_db.lua."
    )
    parser.add_argument("--mods-dir", default=MODS_DIR, help="Path to GTNH mods/ directory (or set GTNH_MODS_DIR)")
    parser.add_argument("--javap", default=JAVAP, help="Path to JDK javap binary (or set JAVAP)")
    parser.add_argument("--output", default=OUTPUT_LUA, help="Output Lua manifest path (default: lib/recipes_db.lua)")
    args = parser.parse_args()

    raw_recipes = extract_all_raw_recipes(args.mods_dir, args.javap)
    families = OrderedDict()

    for r in raw_recipes:
        fam_id, fam_name, category, mod_id, mod_label = classify_family_and_modifier(r)
        if fam_id not in families:
            primary_out = None
            if r["fluids_out"]:
                fo = r["fluids_out"][0]
                primary_out = {"type": "fluid", "name": fo["name"], "label": fo["label"]}
            elif r["items_out"]:
                io = r["items_out"][0]
                primary_out = {"type": "item", "name": io["name"], "damage": io["damage"], "label": io["label"]}
            families[fam_id] = {
                "name": fam_name,
                "category": category,
                "dtr_role": r["dtr_role"],
                "primary_output": primary_out,
                "modifiers": OrderedDict(),
            }
        fam = families[fam_id]
        if mod_id not in fam["modifiers"]:
            fam["modifiers"][mod_id] = {
                "label": mod_label,
                "circuit": r["circuit"],
                "tiers": OrderedDict(),
            }
        t_code = r["catalyst_tier"] or "NONE"
        fam["modifiers"][mod_id]["tiers"][t_code] = r

    os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
    lua_content = format_lua_db(families)
    with open(args.output, "w") as f:
        f.write(lua_content)

    total_tiers = sum(
        len(mod["tiers"]) for fam in families.values() for mod in fam["modifiers"].values()
    )
    print(f"Extracted {len(raw_recipes)} raw DTPF recipes -> {len(families)} families ({total_tiers} tier entries) in {args.output}")


if __name__ == "__main__":
    main()
