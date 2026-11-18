# GTNH Forge of the Gods & Exoticizer Control (`gtnh-gorge-control`) — Scaffolded

> **Status**: Reserved & scaffolded architecture slot in `OC-gtnh-control`.

This module is planned to unify:
1. **Multi-Instance Heliofusion Exoticizer Scheduling** (merging dual separate OC computers — e.g. Magmatter + Quark-Gluon Plasma — onto one OpenComputers Server Rack).
2. **Direct Godforge Controller Telemetry & On-Demand Throttling** (`gt_machine` via Adapter or Wireless MFU targeting the Forge of the Gods controller).
3. **Whole-Base OC Mesh Integration (`port 4205`)** (`GORGE_METRICS` / `GORGE_CMD`) so `gtnh-ae2-control` and DTPF/Universal loops can coordinate plasma/magmatter demand dynamically.

See [`DESIGN.md`](DESIGN.md) and [`config.example.lua`](config.example.lua) for the planned schema.

## Upstream Credit

- Multi-Exoticizer ME I/O Port + Drive Transposer pattern inspired by **Navatusein**'s [`GTNH-OC-God-Forge-Control`](https://github.com/Navatusein/GTNH-OC-God-Forge-Control).
