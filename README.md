# OC-gtnh-control

Modular OpenComputers automation suite for **GregTech: New Horizons (GTNH 2.9.0+)**.

Each subfolder is **100% self-contained** (no hidden cross-folder runtime dependencies on OpenOS), runs cleanly **standalone** without external servers, and optionally communicates over wireless/wired OC port `4205` (`Ext:Mesh/Auto`).

---

## Modules

| Module | Directory | Purpose | Status |
|---|---|---|---|
| **DTPF Control** | [`gtnh-dtpf-control/`](gtnh-dtpf-control/) | Passive/OD/Catalyst DTPF Fleet Scheduler, `160x50` Touch GUI & Level Maintainer | Production |
| **Universal Control** | [`gtnh-universal-control/`](gtnh-universal-control/) | Bundled-Redstone `ME Toggle Bus` + SRTF Preemption + Dual-Trunk Arbitrary-NC Support | Production |
| **AE2 Control** | [`gtnh-ae2-control/`](gtnh-ae2-control/) | Mainnet InfluxDB Exporter, Remote Craft Requester/Canceller & OC Mesh Hub (`port 4205`) | Production |
| **Space Pump** | [`gtnh-space-pump/`](gtnh-space-pump/) | Space Elevator Fluid Pump target stock controller + optional `port 4205` Mesh (`enableMesh`) | Production |
| **Gorge Control** | [`gtnh-gorge-control/`](gtnh-gorge-control/) | Unified Forge of the Gods controller + multi-Exoticizer Rack (`Magmatter` + `QGP`) | Scaffolded |

---

## One-Line Install & Update (Inside OpenComputers)

Interactive menu (installs **only** the selected module to the computer):
```sh
wget -f https://raw.githubusercontent.com/Jimbo-Coder/OC-gtnh-control/main/install.lua /tmp/install.lua && /tmp/install.lua
```

Direct install or list:
```sh
/tmp/install.lua universal      # or: dtpf, ae2, pump
/tmp/install.lua --list
```

Update every installed module on this computer while preserving `config.cfg` / `config.lua`:
```sh
wget -f https://raw.githubusercontent.com/Jimbo-Coder/OC-gtnh-control/main/install.lua /tmp/install.lua && /tmp/install.lua --update
```

---

## Upstream Attribution

See [`CREDITS.md`](CREDITS.md) for upstream authors, starter repositories, and references (`UncountablyInfinite`, `Fox / samsonsin / San32`, `Navatusein`, `kuba6000`, `Telling Salamander`, `Vlamonster`, `S4mpsa`).
