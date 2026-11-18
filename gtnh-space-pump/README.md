# GTNH Space Elevator Pump (`gtnh-space-pump`)

Automated Fluid Pumping Module controller for the GTNH Space Elevator using OpenComputers.

## Credits & Provenance

- **Original Authors**: **Fox**, **samsonsin**, **San32** — [`GTNH-OC-Space-Pumping`](https://github.com/samsonsin/GTNH-OC-Space-Pumping) & GTNH Wiki 2.9 guide.
- **Our Additions**:
  - Target stock-keeping mode (`target`, `threshold`, `priority` sorted highest priority -> lowest fill ratio).
  - Non-blocking wireless/wired OC Mesh (`enableMesh = true` toggle in config; `PUMP_STATUS`, `PUMP_CMD` live priority/target overrides persisted to `/home/pump_overrides.lua`).
  - Set `local enableMesh = false` in `autoPump.lua` to run 100% standalone without any modem/tunnel traffic.

## One-Line Install

```sh
wget -f https://raw.githubusercontent.com/Jimbo-Coder/OC-gtnh-control/main/install.lua /tmp/install.lua && /tmp/install.lua pump
```
