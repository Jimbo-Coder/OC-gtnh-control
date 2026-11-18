# GTNH Forge of the Gods & Multi-Exoticizer Control (`gtnh-gorge-control`)

**Self-Healing Multi-Exoticizer Automation + Forge of the Gods (`Godforge`) Controller & `160x50` Touch GUI.**

- **Multi-Exoticizer on 1 Server Rack**: Runs `1..8` Heliofusion Exoticizer modules (`"magmatter"`, `"gluon"`, or `"auto"` mode) from a single OpenComputers server using **dynamic 10-slot/module Database Upgrade partitioning** (only the `3` or `7` active batch plasmas are written per cycle).
- **GTNH 2.9 Bytecode-Verified Plasma Map (`lib/plasmas.lua`)**: Full 82-plasma Quark-Gluon map (`Chrome`, `Bismuth`, `Mercury`, `Tiny Pile of ... Dust`, full `Dust`, clean `%s+Gas` stripping) + 17-entry Magmatter math (`|Spatial - Temporal| * 144`).
- **Fixes Upstream Deadlocks & Crashes**:
  - Self-healing component proxies re-resolve automatically if chunks/AE2 grids reload (`no such component`).
  - Dynamic cell count (`1..6` cells via `ME IO Port`) instead of hardcoded 3-cell / slot 9 loops.
  - Bounded `RETRY_WAIT` backoff auto-recovers from transient CPU contention or missing plasma instead of freezing at a manual `Press Enter` prompt.
- **Godforge Controller & Optional LSC Guard (`gt_machine`)**: Reads Rings, Connected Modules, Unlocked Upgrades, Progress, and optionally gates `setWorkAllowed(true/false)` on Mainnet LSC EU hysteresis (`minLscPct` / `resumeLscPct`).
- **Optional OC Mesh (`port 4205`)**: Reports `GORGE_METRICS` and handles `GORGE_CMD` (`pause`, `resume`, `poll_now`, `set_mode`, `retry_errors`), with `[Ext:Standalone]` opt-out.

## One-Line Install (OpenComputers)

```sh
wget -f https://raw.githubusercontent.com/Jimbo-Coder/OC-gtnh-control/main/install.lua /tmp/install.lua && /tmp/install.lua gorge
```

CLI commands: `gorge` (Touch GUI / headless fallback), `gorge --worker`, `gorge --check`, `gorge --off`, `gorge --update`.
