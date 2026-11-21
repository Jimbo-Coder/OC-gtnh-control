# GTNH Black Hole Compressor Controller (`gtnh-bhc-control`)

OpenComputers automation for the **Pseudostable Black Hole Containment Field** (`multimachine.blackholecompressor`) in GTNH 2.9.0.

## Verified GTNH 2.9.0 Mechanics
- **Stability & Parallels**: Starts at `100%`, decays `1/s`; `<50%` gives `2x` parallels, `<20%` gives `4x` parallels (`16x` with Supermassive Seed; uncapped for standard Compressor recipes). `<= 0%` turns **UNSTABLE** and voids outputs until self-closing.
- **SpaceTime Decay Halt**: Molten SpaceTime halts decay at `1 L/s` (`64 L/s` for Supermassive), doubling every `30s` held (`1 -> 2 -> 4 -> 8 -> ...`). Closing + re-seeding resets stability to `100%` and cost back to `1 L/s`.
- **Save Recipe Mode**: Inspired conceptually by `Navatusein/GTNH-OC-Black-Hole-Control` (MIT): if an active craft's remaining duration exceeds remaining decay headroom before `collapseFloor`, temporarily opens SpaceTime (and closes new input gate) just long enough to finish the craft without voiding, capped at `maxSaveRecipeCycles` (`27` = `810s`).
- **Pulse Sync**: Connects to a **Black Hole Utility Hatch** in **Pulse Mode** (one redstone pulse per second synced directly to BHC's internal stability tick) to prevent voiding even during TPS lag.

## Quick Install
```sh
wget -f https://raw.githubusercontent.com/Jimbo-Coder/OC-gtnh-control/main/install.lua /tmp/install.lua && /tmp/install.lua bhc
```
Or update locally from AE2 Brain / Web Console (`http://127.0.0.1:8765/oc-raw`).
