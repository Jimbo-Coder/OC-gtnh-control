# GTNH Forge of the Gods & Multi-Exoticizer Control (`gtnh-gorge-control`)

**Self-Healing Multi-Exoticizer Automation + Forge of the Gods (`Godforge`) Controller & `160x50` Touch GUI.**

- **Multi-Exoticizer on 1 Server Rack**: Runs `1..8` Heliofusion Exoticizer modules (`"magmatter"`, `"gluon"`, or `"auto"` mode) from a single OpenComputers server using **dynamic 10-slot/module Database Upgrade partitioning** (only the `3` or `7` active batch plasmas are written per cycle).
- **GTNH 2.9 Bytecode-Verified Plasma Map (`lib/plasmas.lua`)**: Full 82-plasma Quark-Gluon map (`Chrome`, `Bismuth`, `Mercury`, `Tiny Pile of ... Dust`, `Tiny ... Dust`, full `Dust`, clean `%s+Gas` stripping) + 17-entry Magmatter math (`|Spatial - Temporal| * 144`).
- **Self-Unsticking & Crash Recovery (Zero Deadlocks)**:
  - **Self-healing proxies**: re-resolves stale components automatically after chunk/AE2 reloads (`no such component`).
  - **In-flight batch persistence**: saves post-`CLEAR_AE` batch inputs to `inflight.dat` so temporary `RETRY_WAIT` backoffs or computer reboots never lose a drained batch.
  - **Stranded IO Port recovery & `Auto-Unstick` watchdog**: automatically returns cells left inside the ME IO Port on startup, clears wedged `WAIT_END` states after `autoUnstickSec` (`600s` default), and reconciles pre-existing fake crafts.
  - **Auto-restart supervisor + Boot autostart**: both GUI and `--worker` modes automatically restart after unexpected faults, with `[.shrc: ON/OFF]` and `gorge --autostart on|off`.
- **Godforge Controller & Optional LSC Guard (`gt_machine`)**: Reads Rings, Connected Modules, Unlocked Upgrades, Progress, and optionally gates `setWorkAllowed(true/false)` on Mainnet LSC EU hysteresis (`minLscPct` / `resumeLscPct`).
- **Optional OC Mesh (`port 4205`)**: Reports `GORGE_METRICS` and handles `GORGE_CMD` (`pause`, `resume`, `poll_now`, `unstick`, `set_mode`, `retry_errors`), with `[Ext:Standalone]` opt-out.

## Consolidating 2 Exoticizer Computers onto 1 Computer (Rewiring Checklist)

1. Remove the duplicate OpenComputers case and route all cables (both Output ME Interfaces, both Input ME Interfaces, both Transposers, both Redstone I/O blocks, Godforge controller, and 1 shared Tier-3 Database Upgrade) onto one OC computer/server.
2. **Watch the OC Component Limit**: a bare OC CPU has a 16-component limit; combining 2 Exoticizers + Godforge + GPU/Screen/Network needs ~10–14 components (well under a Tier 3 Server + Component Bus / Tier 3 CPU, which raises the cap to 32+).
3. Run `gorge`, open **`[3] SETUP & WIRING`**, and use **`[+ Add Exoticizer]`** if needed. Interface cycle buttons tag each discovered ME Interface as **`IN`** (has slot-1 pattern / CPUs) vs **`OUT`** (output subnet) so you can pair Magmatter (`DB:1-10`) and Gluon (`DB:11-20`) cleanly.
4. Keep each Input ME Interface's slot 1 populated with a blank/placeholder encoded pattern and verify **`Boot Autostart (.shrc)`** is `[ON]`.

## One-Line Install (OpenComputers)

```sh
wget -f https://raw.githubusercontent.com/Jimbo-Coder/OC-gtnh-control/main/install.lua /tmp/install.lua && /tmp/install.lua gorge
```

CLI commands: `gorge` (Touch GUI / headless fallback), `gorge --worker`, `gorge --check`, `gorge --unstick`, `gorge --autostart on|off`, `gorge --off`, `gorge --update`.
