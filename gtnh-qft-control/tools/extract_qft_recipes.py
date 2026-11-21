#!/usr/bin/env python3
"""
Reusable QFT Recipe Extractor for GTNH 2.9.0+
Extracts all 28 Quantum Force Transformer recipes directly from the modpack jars
(RecipeLoaderChemicalSkips, NaquadahRecipeLoader, ScriptGregtechPlusPlus, CropRecipes)
and compiles them into a compact single-source-of-truth Lua database (`lib/recipes_db.lua`).
"""

import argparse
import glob
import os
import re
import shutil
import subprocess
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
QFT_ROOT = SCRIPT_DIR.parent


def _find_gtnh_root(start: Path) -> Path:
    for parent in start.parents:
        if (parent / "tools/jdks").exists() or list(parent.glob("GT_NH_*/mods/GTNewHorizonsCoreMod-*.jar")):
            return parent
    return start.parent.parent


def discover_mods_dir() -> Path:
    env_mods = os.environ.get("GTNH_MODS_DIR")
    if env_mods:
        return Path(env_mods)
    gtnh_root = _find_gtnh_root(QFT_ROOT)
    for cand in sorted(gtnh_root.glob("GT_NH_*/mods"), reverse=True):
        if list(cand.glob("GTNewHorizonsCoreMod-*.jar")):
            return cand
    return gtnh_root / "mods"


def discover_javap() -> str:
    env_javap = os.environ.get("JAVAP")
    if env_javap:
        return env_javap
    gtnh_root = _find_gtnh_root(QFT_ROOT)
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
OUTPUT_LUA = str(QFT_ROOT / "lib" / "recipes_db.lua")

TIER_EU_MAP = {
    "RECIPE_LV": 30,
    "RECIPE_MV": 120,
    "RECIPE_HV": 480,
    "RECIPE_EV": 1920,
    "RECIPE_IV": 7680,
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

# GTValues.VP[tierIndex] = 30 * 4^(tierIndex-1) * ... wait: in GT5U VP[1]=30, VP[8]=491520? Wait:
# GTValues.VP = {0, 32, 128, 512, 2048, 8192, 32768, 131072, 524288, 2097152, 8388608...}? No!
# In GTNH 2.9: TierEU.RECIPE_UV = 491520, VP[tier]: VP[1]=30(LV)... VP[7]=ZPM(122880), VP[8]=UV(491520),
# VP[9]=UHV(1966080), VP[10]=UEV(7864320), VP[11]=UIV(31457280), VP[12]=UMV(125829120).
# Let's check exact values: VP[10]..VP[12] in NaquadahRecipeLoader:
GTVALUES_VP = {
    1: 30,
    2: 120,
    3: 480,
    4: 1920,
    5: 7680,
    6: 30720,
    7: 122880,
    8: 491520,
    9: 1966080,
    10: 7864320,
    11: 31457280,
    12: 125829120,
    13: 503316480,
    14: 2013265920,
}

CATALYST_META_MAP = {
    "PlatinumGroupCatalyst": (16, "Platinum Group Catalyst"),
    "PlasticPolymerCatalyst": (17, "Plastic Polymer Catalyst"),
    "RubberPolymerCatalyst": (18, "Rubber Polymer Catalyst"),
    "AdhesionPromoterCatalyst": (19, "Adhesion Promoter Catalyst"),
    "TitaTungstenIndiumCatalyst": (20, "Tita-Tungsten Indium Catalyst"),
    "RadioactivityCatalyst": (21, "Radioactivity Catalyst"),
    "RareEarthGroupCatalyst": (22, "Rare-Earth Group Catalyst"),
    "SimpleNaquadahCatalyst": (23, "Simple Naquadah Catalyst"),
    "AdvancedNaquadahCatalyst": (24, "Advanced Naquadah Catalyst"),
    "RawIntelligenceCatalyst": (25, "Raw Intelligence Catalyst"),
    "UltimatePlasticCatalyst": (26, "Ultimate Plasticizer Catalyst"),
    "BiologicalIntelligenceCatalyst": (27, "Biological Intelligence Catalyst"),
    "TemporalHarmonyCatalyst": (28, "Temporal Harmonizer Catalyst"),
    "AlgagenicGrowthPromoterCatalyst": (33, "Algagenic Growth Promoter Catalyst"),
    "HellishForceCatalyst": (34, "Hellish Force Catalyst"),
    "CrystalColorizationCatalyst": (35, "Crystal Colorization Catalyst"),
}

ITEM_MAP = {
    "ItemList.Circuit_Chip_Stemcell": ("gregtech:gt.metaitem.03", 32073, "Stemcells"),
    "ItemList.Circuit_Chip_Biocell": ("gregtech:gt.metaitem.03", 32076, "Biocells"),
    "ItemList.StableAdhesive": ("gregtech:gt.metaitem.01", 32427, "Stable Adhesive"),
    "ItemList.SuperconductorComposite": ("gregtech:gt.metaitem.01", 32428, "Superconductor Composite"),
    "ItemList.NaquadriaSupersolid": ("gregtech:gt.metaitem.01", 32429, "Black Body Naquadria Supersolid"),
    "ItemList.EnergisedTesseract": ("gregtech:gt.metaitem.01", 32417, "Energised Tesseract"),
    "ItemList.Intensely_Bonded_Netherite_Nanoparticles": ("gregtech:gt.metaitem.03", 32246, "Intensely Bonded Netherite Nanoparticles"),
    "ItemList.Timepiece": ("gregtech:gt.metaitem.03", 32757, "Timepiece"),
    "Materials.Prismarine:shard": ("etfuturum:prismarine_shard", 0, "Prismarine Shard"),
    "WerkstoffLoader.PTMetallicPowder": ("bartworks:gt.bwMetaGenerateddust", 47, "Platinum Metallic Powder Dust"),
    "WerkstoffLoader.PDMetallicPowder": ("bartworks:gt.bwMetaGenerateddust", 53, "Palladium Metallic Powder Dust"),
    "WerkstoffLoader.LeachResidue": ("bartworks:gt.bwMetaGenerateddust", 60, "Leach Residue Dust"),
    "WerkstoffLoader.Ruthenium": ("bartworks:gt.bwMetaGenerateddust", 64, "Ruthenium Dust"),
    "WerkstoffLoader.IrOsLeachResidue": ("bartworks:gt.bwMetaGenerateddust", 69, "Rarest Metal Residue Dust"),
    "WerkstoffLoader.IrLeachResidue": ("bartworks:gt.bwMetaGenerateddust", 70, "Iridium Metal Residue Dust"),
    "WerkstoffLoader.Rhodium": ("bartworks:gt.bwMetaGenerateddust", 78, "Rhodium Dust"),
    "WerkstoffLoader.CrudeRhMetall": ("bartworks:gt.bwMetaGenerateddust", 79, "Crude Rhodium Metal Dust"),
    "WerkstoffLoader.RhodiumPlatedPalladium": ("bartworks:gt.bwMetaGenerateddust", 88, "Rhodium-Plated Palladium Dust"),
    "Werkstoff:3": ("bartworks:gt.bwMetaGenerateddust", 3, "Zirconium Dust"),
    "Werkstoff:11002": ("bartworks:gt.bwMetaGenerateddust", 11002, "Hafnia Dust"),
    "WerkstoffMaterialPool.CeriumRichMixture": ("bartworks:gt.bwMetaGenerateddust", 11029, "Cerium-Rich Mixture Dust"),
    "GGMaterial.naquadahEarth": ("bartworks:gt.bwMetaGenerateddust", 10054, "Naquadah Oxide Mixture Dust"),
    "GGMaterial.enrichedNaquadahEarth": ("bartworks:gt.bwMetaGenerateddust", 10067, "Enriched Naquadah Oxide Mixture Dust"),
    "GGMaterial.naquadriaEarth": ("bartworks:gt.bwMetaGenerateddust", 10072, "Naquadria Oxide Mixture Dust"),
    "GGMaterial.inertNaquadah": ("bartworks:gt.bwMetaGenerateddust", 10113, "Inert Naquadah Dust"),
    "GGMaterial.inertEnrichedNaquadah": ("bartworks:gt.bwMetaGenerateddust", 10114, "Inert Enriched Naquadah Dust"),
    "GGMaterial.inertNaquadria": ("bartworks:gt.bwMetaGenerateddust", 10115, "Inert Naquadria Dust"),
    "dustShirabon": ("bartworks:gt.bwMetaGenerateddust", 10112, "Shirabon Dust"),
    "MaterialsElements.RHENIUM": ("miscutils:itemDustRhenium", 0, "Rhenium Dust"),
    "MaterialsElements.HAFNIUM": ("miscutils:itemDustHafnium", 0, "Hafnium Dust"),
    "MaterialsElements.THORIUM232": ("miscutils:itemDustThorium232", 0, "Thorium 232 Dust"),
    "MaterialsElements.URANIUM233": ("miscutils:itemDustUranium233", 0, "Uranium 233 Dust"),
    "MaterialsElements.PLUTONIUM238": ("miscutils:itemDustPlutonium238", 0, "Plutonium-238 Dust"),
    "CombType.PLATINUM": ("gregtech:gt.comb", 69, "Platinum Comb"),
    "CombType.IRIDIUM": ("gregtech:gt.comb", 70, "Iridium Comb"),
    "CombType.OSMIUM": ("gregtech:gt.comb", 72, "Osmium Comb"),
    "CombType.KEVLAR": ("gregtech:gt.comb", 161, "Kevlar Comb"),
    "CombType.PALLADIUM": ("gregtech:gt.comb", 164, "Palladium Comb"),
    "CropsNHItemList.iridineFlower": ("cropsnh:materialLeaf", 5, "Iridine Leaf"),
    "CropsNHItemList.osmianthFlower": ("cropsnh:materialLeaf", 11, "Osmianth Flower"),
    "CropsNHItemList.platinaLeaf": ("cropsnh:materialLeaf", 12, "Platina Leaf"),
    "Mods.EtFuturumRequiem:ancient_debris:0": ("etfuturum:ancient_debris", 0, "Ancient Debris"),
    "Mods.EtFuturumRequiem:netherite_scrap:0": ("etfuturum:netherite_scrap", 0, "Netherite Scrap"),
    "Mods.NewHorizonsCoreMod:GTNHBioItems:2": ("dreamcraft:GTNHBioItems", 2, "Agar"),
    "Mods.NewHorizonsCoreMod:TCetiESeaweedExtract:0": ("dreamcraft:item.TCetiESeaweedExtract", 0, "TCetiE-Seaweed Extract"),
    "Mods.GalaxySpace:tcetiedandelions:4": ("GalaxySpace:tcetiedandelions", 4, "T Ceti E Seaweed"),
    "Mods.EternalSingularity:combined_singularity:15": ("eternalsingularity:combined_singularity", 15, "Combined Singularity"),
    "cropSeaweed": ("harvestcraft:seaweedItem", 0, "Seaweed"),
}

MATERIAL_LABEL_OVERRIDES = {
    "Platinum": "Platinum",
    "Palladium": "Palladium",
    "Iridium": "Iridium",
    "Osmium": "Osmium",
    "Carbon": "Carbon",
    "Sulfur": "Sulfur",
    "Bismuth": "Bismuth",
    "Lead": "Lead",
    "Bauxite": "Bauxite",
    "Tungstate": "Tungstate",
    "Titanium": "Titanium",
    "TungstenSteel": "Tungstensteel",
    "TungstenCarbide": "Tungsten Carbide",
    "Indium": "Indium",
    "Rutile": "Rutile",
    "Scheelite": "Scheelite",
    "Ilmenite": "Ilmenite",
    "Tantalum": "Tantalum",
    "Niobium": "Niobium",
    "Thorium": "Thorium",
    "Uranium": "Uranium 238",
    "Uranium235": "Uranium 235",
    "Plutonium": "Plutonium 239",
    "Plutonium241": "Plutonium 241",
    "Monazite": "Monazite",
    "Cerium": "Cerium",
    "Gadolinium": "Gadolinium",
    "Samarium": "Samarium",
    "Osmiridium": "Osmiridium",
    "Bastnasite": "Bastnasite",
    "Holmium": "Holmium",
    "Lanthanum": "Lanthanum",
    "Netherrack": "Netherrack",
    "NaquadahEnriched": "Enriched Naquadah",
    "PrismaticNaquadah": "Prismatic Naquadah",
    "Calcium": "Calcium",
    "MeatRaw": "Raw Meat",
    "InfinityCatalyst": "Infinity Catalyst",
    "Mytryl": "Mytryl",
    "Sodium": "Sodium",
    "Adamantium": "Adamantium",
    "Gallium": "Gallium",
    "Zinc": "Zinc",
    "Trinium": "Trinium",
    "Magnesium": "Magnesium",
    "Barium": "Barium",
}

FLUID_MAP = {
    "Materials.Oxygen:getGas": ("oxygen", "Oxygen Gas"),
    "Materials.Hydrogen:getGas": ("hydrogen", "Hydrogen Gas"),
    "Materials.Chlorine:getGas": ("chlorine", "Chlorine Gas"),
    "Materials.Fluorine:getGas": ("fluorine", "Fluorine Gas"),
    "Materials.Nitrogen:getGas": ("nitrogen", "Nitrogen Gas"),
    "Materials.Polyethylene:getMolten": ("molten.plastic", "Molten Polyethylene"),
    "Materials.PolyvinylChloride:getMolten": ("molten.polyvinylchloride", "Molten Polyvinyl Chloride"),
    "Materials.Polystyrene:getMolten": ("molten.polystyrene", "Molten Polystyrene"),
    "Materials.Polytetrafluoroethylene:getMolten": ("molten.polytetrafluoroethylene", "Molten Polytetrafluoroethylene"),
    "Materials.Epoxid:getMolten": ("molten.epoxid", "Molten Epoxid"),
    "Materials.Polybenzimidazole:getMolten": ("molten.polybenzimidazole", "Molten Polybenzimidazole"),
    "Materials.RubberSilicone:getMolten": ("molten.silicone", "Molten Silicone Rubber"),
    "Materials.StyreneButadieneRubber:getMolten": ("molten.styrenebutadienerubber", "Molten Styrene-Butadiene Rubber"),
    "Materials.PolyphenyleneSulfide:getMolten": ("molten.polyphenylenesulfide", "Molten Polyphenylene Sulfide"),
    "Materials.Rubber:getMolten": ("molten.rubber", "Molten Rubber"),
    "Materials.GlueAdvanced:getFluid": ("advancedglue", "Advanced Glue"),
    "Materials.SolderingAlloy:getMolten": ("molten.solderingalloy", "Molten Soldering Alloy"),
    "Materials.NetherAir:getFluid": ("netherair", "Nether Air"),
    "Materials.HellishMetal:getMolten": ("molten.hellishmetal", "Molten Hellish Metal"),
    "Materials.Lava:getFluid": ("lava", "Lava"),
    "Materials.NefariousOil:getFluid": ("nefariousoil", "Nefarious Oil"),
    "Materials.PrismaticAcid:getFluid": ("prismaticacid", "Prismatic Acid"),
    "Materials.Strontium:getMolten": ("molten.strontium", "Molten Strontium"),
    "Materials.GrowthMediumRaw:getFluid": ("growthmediumraw", "Raw Growth Catalyst Medium"),
    "Materials.GrowthMediumSterilized:getFluid": ("growthmediumsterilized", "Growth Catalyst Medium"),
    "Materials.Xenoxene:getFluid": ("xenoxene", "Xenoxene"),
    "Materials.RadoxPolymer:getMolten": ("molten.radoxpoly", "Molten Radox Polymer"),
    "Materials.RadoxHeavy:getFluid": ("heavyradox", "Heavy Radox"),
    "Materials.Kevlar:getMolten": ("molten.kevlar", "Molten Kevlar"),
    "Materials.PolyurethaneResin:getFluid": ("polyurethaneresin", "Polyurethane Resin"),
    "Materials.LiquidCrystalKevlar:getFluid": ("liquidcrystalkevlar", "Liquid Crystal Kevlar"),
    "Materials.Osmium:getMolten": ("molten.osmium", "Molten Osmium"),
    "Materials.Palladium:getMolten": ("molten.palladium", "Molten Palladium"),
    "Materials.Iridium:getMolten": ("molten.iridium", "Molten Iridium"),
    "Materials.Platinum:getMolten": ("molten.platinum", "Molten Platinum"),
    "Materials.BioMediumSterilized:getFluid": ("biohmediumsterilized", "Sterilized Bio Catalyst Medium"),
    "Materials.BioMediumRaw:getFluid": ("biomediumraw", "Raw Bio Catalyst Medium"),
    "Materials.SulfuricAcid:getFluid": ("sulfuricacid", "Sulfuric Acid"),
    "Materials.PhosphoricAcid:getFluid": ("phosphoricacid_gt5u", "Phosphoric Acid"),
    "Materials.PrimordialMatter:getFluid": ("primordialmatter", "Liquid Primordial Matter"),
    "Materials.Eternity:getMolten": ("molten.eternity", "Molten Eternity"),
    "Materials.Time:getMolten": ("temporalfluid", "Tachyon Rich Temporal Fluid"),
    "MaterialMisc.ETHYL_CYANOACRYLATE:getFluidStack": ("molten.ethylcyanoacrylatesuperglue", "Ethyl Cyanoacrylate (Super Glue)"),
    "MaterialsAlloy.INDALLOY_140:getFluidStack": ("molten.indalloy140", "Molten Indalloy 140"),
    "MaterialMisc.MUTATED_LIVING_SOLDER:getFluidStack": ("molten.mutatedlivingsolder", "Mutated Living Solder"),
    "GGMaterial.wasteLiquid:getFluidOrGas": ("waste liquid", "Waste Liquid"),
    "WerkstoffMaterialPool.Iodine:getFluidOrGas": ("iodine", "Iodine"),
    "FluidRegistry:unknowwater": ("unknowwater", "Unknow Water"),
    "FluidRegistry:seaweedbroth": ("seaweedbroth", "Seaweed Broth"),
}

RECIPE_NAME_HINTS = {
    ("WerkstoffLoader.PTMetallicPowder", 1): ("pt_metallic_powder", "Pt Metallic Powder"),
    ("WerkstoffLoader.PDMetallicPowder", 1): ("pd_metallic_powder", "Pd Metallic Powder"),
    ("WerkstoffLoader.IrLeachResidue", 1): ("ir_leach_residue", "Ir Metal Residue"),
    ("WerkstoffLoader.IrOsLeachResidue", 1): ("ir_os_leach_residue", "Rarest Metal Residue"),
    ("WerkstoffLoader.CrudeRhMetall", 1): ("crude_rh_metal", "Crude Rhodium Metal"),
    ("WerkstoffLoader.LeachResidue", 1): ("leach_residue", "Leach Residue"),
    ("PlasticPolymerCatalyst", 1): ("plastics_line", "Polyethylene & Plastics"),
    ("RubberPolymerCatalyst", 1): ("rubber_line", "Rubbers & Silicone"),
    ("AdhesionPromoterCatalyst", 1): ("adhesives_solder", "Adhesives & Indalloy"),
    ("Materials.Lead", 1): ("ti_w_in_bauxite", "Ti/W/In (Bauxite/Tungstate)"),
    ("Materials.Rutile", 1): ("ti_ta_nb_re_hf", "Ti/W/Ta/Re/Nb/Hf (Rutile)"),
    ("RadioactivityCatalyst", 1): ("thorium_uranium_plutonium", "Th-232 / U-233 / Pu-238"),
    ("Materials.Monazite", 2): ("rare_earth_monazite", "Rare Earth (Monazite)"),
    ("Materials.Bastnasite", 2): ("rare_earth_bastnasite", "Rare Earth (Bastnasite)"),
    ("WerkstoffMaterialPool.CeriumRichMixture", 2): ("rare_earth_cerium", "Rare Earth (Cerium-Rich)"),
    ("HellishForceCatalyst", 2): ("netherite_nanoparticles", "Netherite & Nefarious Oil"),
    ("CrystalColorizationCatalyst", 2): ("prismatic_naquadah", "Prismatic Naquadah & Acid"),
    ("RawIntelligenceCatalyst", 3): ("stemcells_growth_medium", "Stemcells & Growth Medium"),
    ("Materials.Osmium", 4): ("xenoxene_radox_kevlar", "Xenoxene, Radox & Kevlar"),
    ("CombType.KEVLAR", 4): ("kevlar_combs", "Kevlar (Combs)"),
    ("CombType.PLATINUM", 1): ("platline_combs", "Platline Metals (Combs)"),
    ("BiologicalIntelligenceCatalyst", 4): ("biocells_living_solder", "Biocells & Mutated Solder"),
    ("AlgagenicGrowthPromoterCatalyst", 4): ("seaweed_broth_extract", "Seaweed Extract, Broth & I2"),
    ("GGMaterial.naquadahEarth", 2): ("naquadah_earth", "Naquadah Oxide Refining"),
    ("GGMaterial.enrichedNaquadahEarth", 2): ("enriched_naquadah_earth", "Enriched Naquadah Refining"),
    ("GGMaterial.naquadriaEarth", 3): ("naquadria_earth", "Naquadria Refining"),
    ("TemporalHarmonyCatalyst", 4): ("shirabon_timepiece_eternity", "Shirabon, Eternity & Timepiece"),
    ("CropsNHItemList.platinaLeaf", 1): ("platline_crops", "Platline Metals (CropsNH)"),
}


def parse_materials_id_map(gt_jar: str, javap_bin: str) -> dict:
    txt = subprocess.check_output(
        [javap_bin, "-cp", gt_jar, "-c", "-p", "gregtech.api.enums.MaterialsIDMap"],
        text=True,
    )
    mat_ids = {}
    lines = txt.splitlines()
    for i, ln in enumerate(lines):
        m = re.search(r"Field gregtech/api/enums/Materials\.(\w+):", ln)
        if m and i + 1 < len(lines) and "Method r:" in lines[i + 1]:
            prev = lines[i - 1].strip()
            vm = re.search(r"iconst_(\d)|(?:bipush|sipush)\s+(\d+)|ldc\w*\s+.*int\s+(\d+)", prev)
            if vm:
                mat_ids[m.group(1)] = int(next(x for x in vm.groups() if x is not None))
    return mat_ids


def parse_javap_method(javap_text: str, method_header: str) -> list:
    code = javap_text.split(method_header)[1]
    if "LineNumberTable:" in code:
        code = code.split("LineNumberTable:")[0]
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
            stack.append(-1 if op == "iconst_m1" else int(op.split("_")[1]))
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
            if stack:
                locals_map[idx] = stack.pop()
        elif op in ("l2i", "i2l", "d2l", "l2d", "i2d", "f2d", "checkcast"):
            pass
        elif op == "dup":
            stack.append(stack[-1] if stack else None)
        elif op == "pop":
            if stack:
                stack.pop()
        elif op in ("anewarray", "newarray"):
            sz = stack.pop() if stack else 0
            stack.append([None] * (int(sz) if isinstance(sz, (int, float)) else 0))
        elif op == "aastore":
            val = stack.pop() if stack else None
            idx = stack.pop() if stack else None
            arr = stack.pop() if stack else None
            if isinstance(arr, list) and isinstance(idx, (int, float)) and 0 <= int(idx) < len(arr):
                arr[int(idx)] = val
        elif op == "iaload":
            idx = stack.pop() if stack else None
            arr = stack.pop() if stack else None
            stack.append(("IALOAD", arr, idx))
        elif op == "laload":
            idx = stack.pop() if stack else None
            arr = stack.pop() if stack else None
            stack.append(("LALOAD", arr, idx))
        elif op == "getstatic":
            stack.append(("STATIC", comment.replace("Field ", "")))
        elif op == "getfield":
            obj = stack.pop() if stack else None
            stack.append(("FIELD", obj, comment.replace("Field ", "")))
        elif op == "new":
            stack.append(("NEW", comment.replace("class ", "")))
        elif op in ("invokespecial", "invokevirtual", "invokestatic", "invokeinterface"):
            meth = comment.replace("InterfaceMethod ", "").replace("Method ", "")
            if meth == "java/lang/Integer.valueOf:(I)Ljava/lang/Integer;":
                pass
            elif meth == "gregtech/api/interfaces/internal/IGTRecipeAdder.stdBuilder:()Lgregtech/api/util/GTRecipeBuilder;":
                if stack:
                    stack.pop()
                stack.append({
                    "items_in": [], "items_out": [], "fluids_in": [], "fluids_out": [],
                    "catalyst": None, "focus_tier": 1, "duration": None, "eut": None,
                })
            elif meth.endswith(":(II)Lgregtech/api/util/GTRecipeBuilder;"):
                # CropsNH helper methods like uvRecipe(seconds, ticks) returning a GTRecipeBuilder
                mname = (meth.split(".")[1] if "." in meth else meth).split(":")[0]
                b_raw = stack.pop() if stack else 0
                a_raw = stack.pop() if stack else 0
                if op != "invokestatic" and stack:
                    stack.pop()
                a_sec = int(a_raw) if isinstance(a_raw, (int, float)) else 20
                b_ticks = int(b_raw) if isinstance(b_raw, (int, float)) else 0
                eut_val = TIER_EU_MAP["RECIPE_UV"] if "uv" in mname.lower() else TIER_EU_MAP["RECIPE_MV"]
                stack.append({
                    "items_in": [], "items_out": [], "fluids_in": [], "fluids_out": [],
                    "catalyst": None, "focus_tier": 1, "duration": a_sec * 20 + b_ticks, "eut": eut_val,
                })
            elif meth.startswith("gregtech/api/util/GTRecipeBuilder."):
                bname = meth.split(".")[1].split(":")[0]
                desc = meth.split(":")[1]
                args_part = desc[1:desc.index(")")]
                arg_types = re.findall(r"\[*(?:L[^;]+;|[ZBCSIFJD])", args_part)
                args = [stack.pop() if stack else None for _ in range(len(arg_types))][::-1]
                builder = stack.pop() if stack else {}
                if isinstance(builder, dict) and "items_in" in builder:
                    if bname == "metadata":
                        if "QFT_CATALYST" in str(args[0]):
                            builder["catalyst"] = args[1]
                        elif "QFT_FOCUS_TIER" in str(args[0]):
                            builder["focus_tier"] = args[1]
                    elif bname == "addTo":
                        if "quantumForceTransformerRecipes" in str(args[0]):
                            recipes.append(builder)
                        stack.append("COLLECTION")
                        continue
                    elif bname == "itemInputs":
                        builder["items_in"] = args[0] if len(args) == 1 and isinstance(args[0], list) else list(args)
                    elif bname == "itemOutputs":
                        builder["items_out"] = args[0] if len(args) == 1 and isinstance(args[0], list) else list(args)
                    elif bname == "fluidInputs":
                        builder["fluids_in"] = args[0] if len(args) == 1 and isinstance(args[0], list) else list(args)
                    elif bname == "fluidOutputs":
                        builder["fluids_out"] = args[0] if len(args) == 1 and isinstance(args[0], list) else list(args)
                    elif bname == "duration":
                        builder["duration"] = tuple(args) if len(args) > 1 else args[0]
                    elif bname == "eut":
                        builder["eut"] = args[0]
                stack.append(builder)
            else:
                desc = meth.split(":")[1]
                args_part = desc[1:desc.index(")")]
                arg_types = re.findall(r"\[*(?:L[^;]+;|[ZBCSIFJD])", args_part)
                args = [stack.pop() if stack else None for _ in range(len(arg_types))][::-1]
                target = None if op == "invokestatic" else (stack.pop() if stack else None)
                ret = desc[desc.index(")") + 1:]
                if op == "invokespecial" and ".<init>" in meth.replace('"', ""):
                    if stack:
                        stack[-1] = ("INIT", meth.split(".")[0], args)
                elif ret != "V":
                    stack.append(("CALL", meth.split(":")[0], target, args))
    return recipes


def resolve_val(val) -> int:
    if isinstance(val, (int, float)):
        return int(val)
    if isinstance(val, tuple) and val[0] == "STATIC" and "TierEU." in str(val[1]):
        tier_key = str(val[1]).split("TierEU.")[1].split(":")[0]
        return TIER_EU_MAP[tier_key]
    if isinstance(val, tuple) and val[0] == "LALOAD" and "GTValues.VP" in str(val[1]):
        return GTVALUES_VP[int(val[2])]
    if isinstance(val, tuple) and len(val) == 2:
        a, b = resolve_val(val[0]), resolve_val(val[1])
        return a * 20 + b
    raise ValueError(f"Cannot resolve numeric value: {val}")


def resolve_catalyst(cat_node) -> dict:
    s = str(cat_node)
    m = re.search(r"GregtechItemList\.(\w+):", s)
    if not m or m.group(1) not in CATALYST_META_MAP:
        raise ValueError(f"Unknown QFT catalyst: {cat_node}")
    meta, label = CATALYST_META_MAP[m.group(1)]
    return {
        "key": m.group(1),
        "name": "miscutils:BasicGenericChemItem",
        "damage": meta,
        "label": label,
    }


def resolve_item(it, mat_ids: dict) -> dict:
    if isinstance(it, tuple) and it[0] == "INIT" and it[1] == "net/minecraft/item/ItemStack":
        args = it[2]
        if "WerkstoffLoader.items" in str(args[0]):
            amt = int(args[1])
            meta = int(args[2])
            k = f"Werkstoff:{meta}"
            reg, m, label = ITEM_MAP[k]
            return {"name": reg, "damage": m, "amount": amt, "label": label}

    if not (isinstance(it, tuple) and it[0] == "CALL"):
        raise ValueError(f"Unmapped item AST: {it}")

    meth, target, args = it[1], str(it[2]), it[3]
    if "GTUtility.copyAmountUnsafe" in meth or "GTUtility.copyAmount" in meth:
        amt = int(args[0])
        inner = resolve_item(args[1], mat_ids)
        inner["amount"] = amt
        return inner

    if meth == "gregtech/api/enums/Materials.getDust":
        mat_name = target.split("Materials.")[1].split(":")[0]
        amt = int(args[0])
        sub_id = mat_ids[mat_name]
        nice = MATERIAL_LABEL_OVERRIDES.get(mat_name, mat_name)
        return {
            "name": "gregtech:gt.metaitem.01",
            "damage": 2000 + sub_id,
            "amount": amt,
            "label": f"{nice} Dust",
        }

    if "GTOreDictUnificator.get" in meth:
        if len(args) >= 2 and isinstance(args[0], str):
            k = args[0]
            amt = int(args[1])
            reg, m, label = ITEM_MAP[k]
            return {"name": reg, "damage": m, "amount": amt, "label": label}
        pref = str(args[0]).split("OrePrefixes.")[1].split(":")[0]
        mat_name = str(args[1]).split("Materials.")[1].split(":")[0]
        amt = int(args[2])
        if pref == "dust":
            sub_id = mat_ids[mat_name]
            nice = MATERIAL_LABEL_OVERRIDES.get(mat_name, mat_name)
            return {
                "name": "gregtech:gt.metaitem.01",
                "damage": 2000 + sub_id,
                "amount": amt,
                "label": f"{nice} Dust",
            }
        reg, m, label = ITEM_MAP[f"Materials.{mat_name}:{pref}"]
        return {"name": reg, "damage": m, "amount": amt, "label": label}

    if "Werkstoff.get" in meth:
        amt = int(args[1])
        m = re.search(r"(WerkstoffLoader|WerkstoffMaterialPool|GGMaterial)\.(\w+):", target)
        key = f"{m.group(1)}.{m.group(2)}"
        reg, dmg, label = ITEM_MAP[key]
        return {"name": reg, "damage": dmg, "amount": amt, "label": label}

    if "gtPlusPlus/core/material/Material.getDust" in meth:
        amt = int(args[0])
        m = re.search(r"MaterialsElements\.(\w+):", target)
        reg, dmg, label = ITEM_MAP[f"MaterialsElements.{m.group(1)}"]
        return {"name": reg, "damage": dmg, "amount": amt, "label": label}

    if "ItemList.get" in meth or "CropsNHItemList.get" in meth:
        amt = int(args[0])
        m = re.search(r"((?:CropsNHItemList|ItemList)\.\w+):", target)
        reg, dmg, label = ITEM_MAP[m.group(1)]
        return {"name": reg, "damage": dmg, "amount": amt, "label": label}

    if "ItemComb.getStackForType" in meth:
        amt = int(args[1])
        m = re.search(r"CombType\.(\w+):", str(args[0]))
        reg, dmg, label = ITEM_MAP[f"CombType.{m.group(1)}"]
        return {"name": reg, "damage": dmg, "amount": amt, "label": label}

    if "getModItem" in meth:
        mod_id = re.search(r"Mods\.(\w+):", str(args[0])).group(1)
        item_name = str(args[1])
        amt = int(args[2])
        meta = int(args[3]) if len(args) > 3 else 0
        reg, dmg, label = ITEM_MAP[f"Mods.{mod_id}:{item_name}:{meta}"]
        return {"name": reg, "damage": dmg, "amount": amt, "label": label}

    raise ValueError(f"Unmapped QFT item call: {it}")


def resolve_fluid(fl) -> dict:
    if not (isinstance(fl, tuple) and fl[0] == "CALL"):
        raise ValueError(f"Unmapped fluid AST: {fl}")
    meth, target, args = fl[1], str(fl[2]), fl[3]
    if "FluidRegistry.getFluidStack" in meth:
        fname = str(args[0])
        amt = int(args[1])
        reg, label = FLUID_MAP[f"FluidRegistry:{fname}"]
        return {"name": reg, "amount": amt, "label": label}
    mtype = meth.split(".")[-1]
    amt = int(args[0])
    if "Materials." in target:
        mat = target.split("Materials.")[1].split(":")[0]
        key = f"Materials.{mat}:{mtype}"
    elif "MaterialMisc." in target:
        mat = target.split("MaterialMisc.")[1].split(":")[0]
        key = f"MaterialMisc.{mat}:{mtype}"
    elif "MaterialsAlloy." in target:
        mat = target.split("MaterialsAlloy.")[1].split(":")[0]
        key = f"MaterialsAlloy.{mat}:{mtype}"
    elif "GGMaterial." in target:
        mat = target.split("GGMaterial.")[1].split(":")[0]
        key = f"GGMaterial.{mat}:{mtype}"
    elif "WerkstoffMaterialPool." in target:
        mat = target.split("WerkstoffMaterialPool.")[1].split(":")[0]
        key = f"WerkstoffMaterialPool.{mat}:{mtype}"
    else:
        raise ValueError(f"Unknown fluid target: {fl}")
    reg, label = FLUID_MAP[key]
    return {"name": reg, "amount": amt, "label": label}


def classify_recipe(raw_cat, focus_tier, raw_items_in, idx):
    cat_key = raw_cat["key"]
    all_in = " ".join(str(x) for x in (raw_items_in or []))
    for (needle, t_req), info in RECIPE_NAME_HINTS.items():
        if t_req == focus_tier and (needle == cat_key or needle in all_in):
            return info
    return (f"qft_recipe_{idx}", f"{raw_cat['label']} #{idx}")


def extract_all(mods_dir: str, javap_bin: str) -> list:
    gt_jars = sorted(glob.glob(os.path.join(mods_dir, "gregtech-*.jar")))
    nh_jars = sorted(glob.glob(os.path.join(mods_dir, "GTNewHorizonsCoreMod-*.jar")))
    cr_jars = sorted(glob.glob(os.path.join(mods_dir, "cropsnh-*.jar")))
    if not gt_jars or not nh_jars or not cr_jars:
        raise FileNotFoundError(f"Missing required GTNH jars in {mods_dir}")

    gt_jar, nh_jar, cr_jar = gt_jars[0], nh_jars[0], cr_jars[0]
    mat_ids = parse_materials_id_map(gt_jar, javap_bin)

    sources = [
        (gt_jar, "gtPlusPlus.xmod.gregtech.loaders.recipe.RecipeLoaderChemicalSkips", "private static void quantumTransformerRecipes();"),
        (gt_jar, "goodgenerator.loader.NaquadahRecipeLoader", "public static void RecipeLoad();"),
        (nh_jar, "com.dreammaster.scripts.ScriptGregtechPlusPlus", "public void loadRecipes();"),
        (cr_jar, "com.gtnewhorizon.cropsnh.loaders.gtrecipes.CropRecipes", "private static void addOreConversionRecipes();"),
    ]

    extracted = []
    seen_ids = set()
    for jar, cls, hdr in sources:
        txt = subprocess.check_output([javap_bin, "-cp", jar, "-c", "-p", cls], text=True)
        for raw in parse_javap_method(txt, hdr):
            cat = resolve_catalyst(raw["catalyst"])
            tier = int(raw["focus_tier"] or 1)
            dur = resolve_val(raw["duration"])
            eut = resolve_val(raw["eut"])
            items_in = [resolve_item(x, mat_ids) for x in raw["items_in"] if x is not None]
            items_out = [resolve_item(x, mat_ids) for x in raw["items_out"] if x is not None]
            fluids_in = [resolve_fluid(x) for x in raw["fluids_in"] if x is not None]
            fluids_out = [resolve_fluid(x) for x in raw["fluids_out"] if x is not None]

            rid, rname = classify_recipe(cat, tier, raw["items_in"], len(extracted) + 1)
            base_rid = rid
            n = 2
            while rid in seen_ids:
                rid = f"{base_rid}_{n}"
                n += 1
            seen_ids.add(rid)

            extracted.append({
                "id": rid,
                "name": rname,
                "tier": tier,
                "focusTier": tier,
                "catalyst": cat,
                "durationTicks": dur,
                "eut": eut,
                "itemsIn": items_in,
                "fluidsIn": fluids_in,
                "itemsOut": items_out,
                "fluidsOut": fluids_out,
            })

    # Sort nicely by tier then name for clean UI browsing
    extracted.sort(key=lambda r: (r["tier"], r["name"]))
    return extracted


def lua_str(s: str) -> str:
    return '"' + str(s).replace("\\", "\\\\").replace('"', '\\"') + '"'


def format_lua(recipes: list) -> str:
    lines = [
        "-- AUTO-GENERATED BY tools/extract_qft_recipes.py — DO NOT EDIT MANUALLY",
        f"-- Source of Truth: GTNH 2.9.0 ({len(recipes)} Quantum Force Transformer recipes across Tiers 1-4)",
        "local M = {}",
        "",
        "M.TIERS = {",
        '  { tier = 1, code = "T1", name = "T1 Neutron",   casing = "Neutron Pulse Manipulator" },',
        '  { tier = 2, code = "T2", name = "T2 Cosmic",    casing = "Cosmic Pulse Manipulator" },',
        '  { tier = 3, code = "T3", name = "T3 Infinity",  casing = "Infinity Pulse Manipulator" },',
        '  { tier = 4, code = "T4", name = "T4 Spacetime", casing = "Spacetime Pulse Manipulator" },',
        "}",
        "",
        "M.PLASMAS = {",
        '  neptunium = { type = "fluid", name = "plasma.neptunium", damage = 0, label = "Neptunium Plasma", role = "focus" },',
        '  fermium   = { type = "fluid", name = "plasma.fermium",   damage = 0, label = "Fermium Plasma",   role = "speed" },',
        "}",
        "",
        "M.RECIPES = {",
    ]
    for r in recipes:
        cat = r["catalyst"]
        lines.append("  {")
        lines.append(f"    id = {lua_str(r['id'])},")
        lines.append(f"    name = {lua_str(r['name'])},")
        lines.append(f"    tier = {r['tier']},")
        lines.append(f"    focusTier = {r['focusTier']},")
        lines.append(f"    durationTicks = {r['durationTicks']},")
        lines.append(f"    eut = {r['eut']},")
        lines.append(f"    catalyst = {{ name = {lua_str(cat['name'])}, damage = {cat['damage']}, label = {lua_str(cat['label'])} }},")
        lines.append("    itemsIn = {")
        for it in r["itemsIn"]:
            lines.append(f"      {{ name = {lua_str(it['name'])}, damage = {it['damage']}, amount = {it['amount']}, label = {lua_str(it['label'])} }},")
        lines.append("    },")
        lines.append("    fluidsIn = {")
        for fl in r["fluidsIn"]:
            lines.append(f"      {{ name = {lua_str(fl['name'])}, amount = {fl['amount']}, label = {lua_str(fl['label'])} }},")
        lines.append("    },")
        lines.append("    itemsOut = {")
        for it in r["itemsOut"]:
            lines.append(f"      {{ name = {lua_str(it['name'])}, damage = {it['damage']}, amount = {it['amount']}, label = {lua_str(it['label'])} }},")
        lines.append("    },")
        lines.append("    fluidsOut = {")
        for fl in r["fluidsOut"]:
            lines.append(f"      {{ name = {lua_str(fl['name'])}, amount = {fl['amount']}, label = {lua_str(fl['label'])} }},")
        lines.append("    },")
        lines.append("  },")
    cat_groups = {}
    for r in recipes:
        c = r["catalyst"]
        dmg = int(c["damage"])
        grp = cat_groups.get(dmg)
        if not grp:
            lbl = str(c["label"])
            short_lbl = lbl[:-len(" Catalyst")] if lbl.endswith(" Catalyst") else lbl
            grp = {
                "damage": dmg,
                "label": lbl,
                "shortLabel": short_lbl,
                "tier": int(r["tier"]),
                "recipeIds": [],
            }
            cat_groups[dmg] = grp
        grp["tier"] = min(grp["tier"], int(r["tier"]))
        grp["recipeIds"].append(r["id"])
    catalysts = sorted(cat_groups.values(), key=lambda c: (c["tier"], c["label"]))

    lines.extend([
        "}",
        "",
        "M.CATALYSTS = {",
    ])
    for c in catalysts:
        rids = ", ".join(lua_str(rid) for rid in c["recipeIds"])
        lines.append(
            f"  {{ damage = {c['damage']}, label = {lua_str(c['label'])}, "
            f"shortLabel = {lua_str(c['shortLabel'])}, tier = {c['tier']}, recipeIds = {{ {rids} }} }},"
        )
    lines.extend([
        "}",
        "",
        "M.BY_ID = {}",
        "for _, r in ipairs(M.RECIPES) do",
        "  M.BY_ID[r.id] = r",
        "end",
        "",
        'M.BY_ID["qft_recipe_19"] = M.BY_ID["xenoxene_radox_kevlar"]',
        "",
        "M.CATALYST_BY_DAMAGE = {}",
        "for _, c in ipairs(M.CATALYSTS) do",
        "  M.CATALYST_BY_DAMAGE[c.damage] = c",
        "end",
        "",
        "return M",
        "",
    ])
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="Extract all GTNH 2.9+ QFT recipes into lib/recipes_db.lua.")
    parser.add_argument("--mods-dir", default=MODS_DIR)
    parser.add_argument("--javap", default=JAVAP)
    parser.add_argument("--output", default=OUTPUT_LUA)
    args = parser.parse_args()

    recipes = extract_all(args.mods_dir, args.javap)
    os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
    lua_txt = format_lua(recipes)
    with open(args.output, "w") as f:
        f.write(lua_txt)

    counts = {1: 0, 2: 0, 3: 0, 4: 0}
    for r in recipes:
        counts[r["tier"]] = counts.get(r["tier"], 0) + 1
    print(f"Extracted {len(recipes)} QFT recipes (T1={counts[1]}, T2={counts[2]}, T3={counts[3]}, T4={counts[4]}) -> {args.output} ({len(lua_txt)} bytes)")


if __name__ == "__main__":
    main()
