# GTNH Universal Control

**Multi-Channel `ME Toggle Bus` + ProjectRed Bundled Redstone + GTNH 2.9 Push-Event Universal Automation Controller.**

- **Zero Machine MFUs (`O(1)` 1-Tick Switching)**: Machines use native `Adv. Stocking Input Bus/Hatch` (`Auto-Pull = ON`, `Input Separation = ON`). Switching 4 or 64 machines takes **1 Bundled Redstone tick (`50 ms`)** with zero slot-by-slot wiping.
- **100% Arbitrary NCs (`Adv Blocking Card` Safe)**: Keep `NC #k` behind each channel's Toggle Bus on one-way `Extract-Only` Storage Buses (`2`-channel ad-hoc Waiting Rooms stay 100% empty when idle -> GT++ Extruder Shapes, Catalysts, Petri Dishes, and Circuits all work identically).
- **Start with 1 Cable, Expand In-Place to Color-Prioritized Hatches**: Wire `Ch1` (`Black` hatches = GT Prio `#1`) on one Bundled Cable (`Same Color = Same NC #k`). Add `Ch2` (`Blue` `#5`, `Red` `#2`, `Orange` `#15`, ...) onto another face anytime — configure each wire's spray color in Tab 3 (`POOLS & RULES`) and OC natively aligns `PROBE` fast-path vs `BULK` demotion to GTNH 2.9's exact `0..15` hatch check priority (`Black > Red > ... > Orange > White`).
- **Near-Zero Idle Cost (`0 ms` Push Wakeup)**: Uses GTNH 2.9 `setItemEventSubscription` / `setFluidEventSubscription` on full-block `ME Dual Interface` adapters — `0` polling calls while idle, waking instantly on `network_item_changed` / `network_fluid_changed`.
- **Smart `MLFQ` Scheduling (`lib/policy.lua`)**: Short `PROBE` pass (`1.5s`) + 128-entry recipe-fingerprint speed cache prevents large fast fluid batches (`250,000 L` Hydrogen) from being misclassified behind slow low-count recipes (`10` Xenoxene). Selectable policies: `mlfq`, `srtf`, `round_robin`, `fifo`, `priority`.

---

## One-Line Install (OpenComputers)

Via root monorepo installer (recommended):
```sh
wget -f https://raw.githubusercontent.com/Jimbo-Coder/OC-gtnh-control/main/install.lua /tmp/install.lua && /tmp/install.lua universal
```

Or standalone subproject installer:
```sh
wget -f https://raw.githubusercontent.com/Jimbo-Coder/OC-gtnh-control/main/gtnh-universal-control/install.lua && install
```

Update anytime while preserving `/home/universal/config.cfg`:
```sh
universal --update
```

---

## Hardware Notes (GTNH 2.9.0)

1. Attach an OC `Adapter` to each Waiting Room's **full-block `ME Dual Interface`** (`TileFluidInterface`), **not** a flat cable-part interface (`PartFluidInterface` does not implement OC `NetworkControl`).
2. `1x Redstone I/O` drives **6 Bundled Sides × 16 Colors = 96 Toggle Buses** (e.g., `Ch1 Bank A (00-15)` on North + `Ch2 Bank A (00-15)` on South, using the same color `0..15` for `NC #0..15` on every channel).
3. See [`DESIGN.md`](DESIGN.md) for full ASCII wiring, GTNH 2.9 hatch dye priority table (`Black(0) -> White(15)`), and scheduler details.

---

## CLI Usage

```sh
universal            # Launch 160x50 Tier 3 Touch Control Center (or --worker if headless)
universal --worker   # Run headless background daemon (Ctrl+C safely forces all OFF)
universal --check    # Read-only hardware, event subscription, & queue dry-run check
universal --off      # Immediately zero all bundled redstone outputs
universal --update   # Atomic syntax-checked updater (preserves config.cfg)
```
