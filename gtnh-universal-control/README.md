# GTNH Universal Control

**Multi-Channel `ME Toggle Bus` + ProjectRed Bundled Redstone + GTNH 2.9 Push-Event Universal Automation Controller.**

- **Zero Machine MFUs (`O(1)` 1-Tick Switching)**: Machines use native `Adv. Stocking Input Bus/Hatch` (`Auto-Pull = ON`, `Input Separation = ON`). Switching 4 or 64 machines takes **1 Bundled Redstone tick (`50 ms`)** with zero slot-by-slot wiping.
- **100% Arbitrary NCs (`Adv Blocking Card` Safe)**: Keep `NC #k` behind each channel's Toggle Bus on one-way `Extract-Only` Storage Buses (`2`-channel ad-hoc Waiting Rooms stay 100% empty when idle -> GT++ Extruder Shapes, Catalysts, Petri Dishes, and Circuits all work identically).
- **Start with 1 Cable, Expand In-Place to Color-Prioritized Hatches**: Wire `Ch1` (`Black` hatches = GT Prio `#1`) on one Bundled Cable (`Same Color = Same NC #k`). Add `Ch2` (`Blue` `#5`, `Red` `#2`, `Orange` `#15`, ...) onto another face anytime — configure each wire's spray color in Tab 3 (`POOLS & RULES`) and OC natively aligns `PROBE` fast-path vs `BULK` demotion to GTNH 2.9's exact `0..15` hatch check priority (`Black > Red > ... > Orange > White`).
- **Zero-Friction Pairing & Mainnet Guard**: Discovers both `me_interface` and full-block `ME Dual Interface` (`fluid_interface`), skips Mainnet `me_controller` components in auto-pairing, and provides an instant event-driven `[Guided Drop]` walker (with audible beep + automatic circuit/NC labeling), `[Auto-Bind]`, `[Auto-Scan Trunk]` (supporting bi-directional markers and `Extract-Only` drains), and a Tab 1 3-step Quick-Start Wizard.
- **Near-Zero Idle Cost, Fast Startup & Persisted Speed Cache**: Uses GTNH 2.9 `setItemEventSubscription` / `setFluidEventSubscription` (`0` polling calls while idle; `0`-tick `isItemEventSubscription`/`getBundledOutput` pre-checks eliminate redundant startup/redstone writes), staggers idle verification scans, skips idle GUI re-renders via state digests, and persists up to **4,096 recipes** (`113+` full 36-pattern Dual Interfaces) in a 64-bit Slow-Protected LRU (`/home/universal/rates.cache`).
- **Smart `MLFQ` Scheduling (`lib/policy.lua`)**: Short `PROBE` pass (`1.5s`) + 4,096-entry Slow-Protected LRU speed cache prevents large fast fluid batches (`250,000 L` Hydrogen) from being misclassified behind slow low-count recipes (`10` Xenoxene), with anti-starvation promotion (`starvePromoteSec = 180s`) so long `BULK` crafts never starve under continuous fast arrivals. Selectable policies: `mlfq`, `srtf`, `round_robin`, `fifo`, `priority`.

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

1. Attach an OC `Adapter` to each Waiting Room's **full-block `ME Dual Interface`** (`fluid_interface` / `me_interface` exposing `NetworkControl`), **not** a flat cable-part interface (`PartFluidInterface` does not implement OC `NetworkControl`). Any adapted Mainnet `me_controller` is automatically tagged `[MAINNET]` and excluded from auto-pairing.
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
