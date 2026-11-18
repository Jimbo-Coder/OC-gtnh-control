# GTNH AE2 Control (`gtnh-ae2-control`)

Mainnet AE2 InfluxDB Exporter, Remote Craft Requester / CPU Canceller, Level Maintainer Bridge, and In-Game OC Mesh Gateway (`port 4205`).

## Credits & Provenance

- **Original Exporter**: **UncountablyInfinite** — [`oc-influxdb-exporter`](https://gitlab.com/uncountablyinfinite1056/oc-influxdb-exporter) (`fourk` for main loop design, OC Crop Bot for event handling).
- **GTNH 2.9 Extensions**:
  - Scientific notation (`2.42x10^21`) & LSC sensor telemetry + Crafting CPU duration metrics.
  - `ae2fc:fluid_drop` deduplication and batched Tier-3-RAM-safe item scanning (`allItemsMode = 5`).
  - Optional port `4205` wireless/wired OC Mesh Gateway (`MESH_MAINT_SYNC`, `MESH_CRAFT`, `DTPF_METRICS`, `PUMP_STATUS`, `UNIV_METRICS`, `GORGE_METRICS`).
  - Optional localhost-only Web Console TCP bridge (`enableBridge = false` by default).

## One-Line Install

```sh
wget -f https://raw.githubusercontent.com/Jimbo-Coder/OC-gtnh-control/main/install.lua /tmp/install.lua && /tmp/install.lua ae2
```

Existing `/home/config.lua` files are always preserved on install and update.
