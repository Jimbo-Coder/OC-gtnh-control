# GTNH Tier 4 Nano Forge Controller (`gtnh-nanoforge-control`)

Clean-room OpenComputers automation for the **Tier 4 Nano Forge** (`multimachine.nanoforge`) in **GTNH 2.9.0+**, supporting **On-Demand AE2 Staging** and **Passive 12-Nanite Stocking**.

## Verified GTNH 2.9.0 Mechanics
- **Single Regular Magmatter Hatch**: `MTENanoForge` drains `Integer.MAX_VALUE` `molten.magmatter` from every Input Hatch on startup and consumes 1 output-nanite seed per hatch. Wire **exactly one** dedicated regular Input Hatch via the Magmatter Transposer (`meterMagmatter` transfers only `targetL - existingL`, preventing waste).
- **Exact Magmatter per Parallel**:
  - Tier 1 (`Carbon`, `Neutronium`): `36 L / parallel` (4/4 Perfect OC)
  - Tier 2 (`Silver`, `Glowstone`, `Transcendent Metal`): `72 L / parallel` (4/4 Perfect OC)
  - Tier 3 (`Gold`, `Six-Phased Copper`, `White Dwarf`, `Black Dwarf`, `Universium`, `Eternity`): `144 L / parallel` (4/4 Perfect OC when `parallels >= 2`, i.e., `>= 288 L`)
  - Tier 4 (`Magmatter Nanites`): `288 L / parallel` (2/4 OC)
- **T4 Speed Scaling**: Duration multiplier = `0.9999 ^ MaxParallel`.
- **Strict Nanite Purity Guard (Important!)**: Do **not** mix multiple nanite types inside an AE2 Stocking Input Bus — GTNH 2.9.0 disables T4 parallels whenever any foreign nanite sits in any Input Bus. Use a dedicated regular Input Bus managed by `itemTransposerAddr`, which enforces 1-recipe serialization and sweeps foreign nanites to `returnSide` before dispatch (while allowing `Universium Nanites` inputs for `Eternity` and `Magmatter`).

## Quick Install
```sh
wget -f https://raw.githubusercontent.com/Jimbo-Coder/OC-gtnh-control/main/install.lua /tmp/install.lua && /tmp/install.lua nanoforge
```
Or push input stocking rules directly to Mainnet Stock Maintainer via `[Push Inputs]` on Tab 2 or the Web Console.
