# GTNH Quantum Force Transformer Controller (`gtnh-qft-control`)

OpenComputers control center for Quantum Force Transformer (QFT) multiblocks in GTNH 2.9.0+.

## Features
- **Flexible Hardware Wiring (1, 2, or 3 blocks per QFT)**:
  - **1-block** (Controller only): `setWorkAllowed`, active state, and problem detection.
  - **2-block** (+ `me_inputbus`): automated Focus Circuit (`#1..#N`) selection based on lowest-fill recipe output.
  - **3-block** (+ `me_inputhatch`): automated Neptunium (focus) & Fermium (speed) plasma boost toggling.
  - Tip: Place a single OC Adapter directly touching adjacent blocks (0 MFUs) or cluster at one wall.
- **Plasma-Voiding Safety Guard**:
  - Never removes Neptunium/Fermium plasma or changes Focus Circuit while `isMachineActive() == true` (pauses `setWorkAllowed(false)` first and reconfigures only once idle).
- **Consolidated Input Maintainer + Failover**:
  - Browse all 28 GTNH 2.9.0 QFT recipes (`lib/recipes_db.lua`) by tier (`T1`–`T4`), inspect inputs/catalysts/boosts, and click **Maintain Inputs** in one spot.
  - Automatically dispatches origin-tagged rules (`QFT: <Recipe>`) to Mainnet Stock Maintainer when online, or falls back seamlessly to a local AE2 interface when Mainnet is offline (syncing back when reconnected).

## Install & Test
```bash
# In OpenOS:
wget -f https://raw.githubusercontent.com/Jimbo-Coder/OC-gtnh-control/main/install.lua /tmp/install.lua && /tmp/install.lua qft

# Offline test suite (Mac/Linux):
python3 gtnh-qft-control/tools/test_offline.py
```
