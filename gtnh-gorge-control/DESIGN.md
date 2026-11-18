# Planned Design — GTNH Forge of the Gods & Exoticizer Control

## 1. Consolidating 2 Exoticizer Computers into 1 Server Rack

Currently in late-game GTNH bases, players often run one OC computer per Heliofusion Exoticizer module (one dedicated to Magmatter, one dedicated to Quark-Gluon Plasma), each polling an Input/Output AE subnet Transposer + ME IO Port + ME Drive + Level Emitter Redstone I/O.

`gtnh-gorge-control` consolidates **all** Exoticizer modules into one OC Server Rack configuration array:

```text
exoticizers = {
  { id = 1, name = "Exoticizer #1", mode = "magmatter", ... },
  { id = 2, name = "Exoticizer #2", mode = "gluon",     ... },
}
```

Each entry stores its own component UUIDs (`inputMeInterfaceAddress`, `outputMeInterfaceAddress`, `transposerAddress`, `meIoPortSide`, `meDriveSide`, `redstoneIoAddress`, `redstoneIoSide`) alongside a dynamic `mode` (`"magmatter"` | `"gluon"` | `"auto"`).

---

## 2. Direct Forge of the Gods Controller Adapter (`gt_machine`)

Connecting an OpenComputers Adapter (or Wireless MFU) to the main **Forge of the Gods (`Godforge`)** multiblock controller enables:
- Reading heat / fuel / stellar energy / milestone telemetry from `getSensorInformation()` and `getWorkProgress()` / `getWorkMaxProgress()`.
- On-demand gating (`setWorkAllowed(true/false)`) based on Mainnet LSC EU % or target fuel reserves (e.g. DTR / SpaceTime / Shirabon).
- Automatic `auto` Exoticizer rebalancing: switching Exoticizer `#2` dynamically between Quark-Gluon Plasma and Magmatter depending on Mainnet stock ratios vs targets.

---

## 3. Reserved Port `4205` Mesh Contract (`gtnh-ae2-control` Gateway)

- Outbound beacon: `GORGE_METRICS` (serialized state of Godforge controller + Exoticizer modules, already recognized & ACKed with `GORGE_ACK` by `gtnh-ae2-control/exporter.lua`).
- Inbound RPC: `GORGE_CMD` (`set_mode`, `pause`, `resume`, `poll_now`).
- Opt-out: `extLinkMode = "off"` runs strictly locally with zero modem traffic.
