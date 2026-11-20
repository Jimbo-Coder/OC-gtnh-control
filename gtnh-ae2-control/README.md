# GTNH AE2 Control (`gtnh-ae2-control`)

Mainnet AE2 InfluxDB Exporter, Remote Craft Requester / CPU Canceller, Level Maintainer Bridge, In-Game `160x50` Touch Control Center (`ae2_ui.lua`), and In-Game OC Mesh Gateway (`port 4205`).

## Features

- **160x50 9-Tab Touch Orchestrator (`ae2_ui.lua`)** *(automatically launches when Tier 3 GPU + Screen are present; pass `--headless` for console-only daemon mode)*:
  - **Tab 1 — Overview & Power**: AE2 power/storage bar, LSC EU fill & wireless EU, server TPS/MSPT/chunks, exporter/bridge/mesh status (`5` peers), top busy Crafting CPUs, and live scrollable Activity Log.
  - **Tab 2 — Crafting CPUs**: Full CPU table with busy filter, pagination, and 2-click `[Cancel Craft]` -> `[Confirm Cancel?]` safety guard.
  - **Tab 3 — OC Mesh Overview**: Live 5-card health grid & `[Open ->]` shortcuts for **DTPF**, **Space Pump**, **Universal RS**, **Gorge**, and **Stock Maintainer**.
  - **Tabs 4–8 — Dedicated Peer Orchestrators** (**DTPF**, **Universal**, **Gorge**, **Pump**, **Stock**): Full-screen status KPIs, remote actions (`[Arm]`, `[Pause]`, `[Poll Now]`, `[Unstick All]`, `[Retry Errors]`, `[Import Phys]`, `[Benchmark]`, `[Maint Sync]`, `[Clear Stalls]`, `[Wake / Poll]`, `[Refresh Pumps]`), per-unit/pool/exoticizer/fluid/rule tables, and offline setup guides.
  - **Tab 9 — Setup & Exports**: Live ON/OFF feature toggles and interval steppers (`s`) persisted immediately to `/home/config_overrides.lua` (survives updates without touching `/home/config.lua`).
- **GTNH 2.9 Extensions & Telemetry**:
  - Scientific notation (`2.42x10^21`) & LSC sensor telemetry + Crafting CPU duration metrics.
  - `ae2fc:fluid_drop` deduplication, batched Tier-3-RAM-safe item scanning (`allItemsMode = 5`), and O(1) `getItemInNetwork({ name, damage })` / `getFluidInNetwork` stock lookups in `inspectMainnetForMaint()` and `item_stocks`.
  - Zero-tick cached `getMeshTransports()` over port `4205` (`MESH_MAINT_SYNC`, `MESH_CRAFT`, `DTPF_METRICS`/`DTPF_CMD`, `PUMP_STATUS`/`PUMP_CMD`, `UNIV_METRICS`/`UNIV_CMD`, `GORGE_METRICS`/`GORGE_CMD`, `STOCK_METRICS`/`STOCK_CMD`, and mutual `STOCK_CLAIMS <-> DTPF_CLAIMS` overlap relay).
  - Exports `godforge_control` (`GORGE_METRICS`) and `stock_maintainer` (`STOCK_METRICS`) InfluxDB series and handles `univ_*`, `gorge_*`, and `stock_*` commands on the optional localhost TCP bridge (`enableBridge = false` by default).

## One-Line Install

```sh
wget -f https://raw.githubusercontent.com/Jimbo-Coder/OC-gtnh-control/main/install.lua /tmp/install.lua && /tmp/install.lua ae2
```

Existing `/home/config.lua` and `/home/config_overrides.lua` files are always preserved on install and update.
