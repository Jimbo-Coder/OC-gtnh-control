# GTNH Universal Control

**OpenComputers Bundled-Redstone + AE2 `ME Toggle Bus` Universal Automation Controller for GTNH 2.9.0+.**

- **Zero Machine MFUs / Transposers**: OpenComputers touches **only** `1x Redstone I/O` block (`ProjectRed Bundled Cable`, up to 16 toggle slices per cable face, 96 per Redstone I/O) and each slice's **full-block `ME Dual Interface`** (`me_interface`).
- **Works with 100% Arbitrary NCs**: Supports both **Dual-Trunk Arbitrary-NC** (GT++ Extruder Shapes/Molds, chemical catalysts, petri dishes, research/data sticks, fluid NCs — zero `Advanced Blocking Card` interference!) and **Single-Trunk Circuit/Mold** (with built-in GTNH 2.9 ignore filters + 1-click `[Calibrate Idle NCs]`).
- **4-Second Automatic Setup**: Place 1 cobble marker on the Machine Trunk and click **`[AUTO-SCAN TRUNK]`** — OC automatically maps `Bundled Color 0..15 <-> me_interface`.
- **SRTF Priority Preemption**: Estimates remaining job duration from live subnet contents + EMA drain rates, so quick crafts automatically preempt multi-hour backlog jobs (e.g., 15h Universium Screws) cleanly through an all-OFF **Anti-Contamination Settle Guard**.
- **Standalone First**: Wireless port `4205` telemetry (`Ext:Mesh/Auto`) is 100% optional and can be toggled to `Ext:Standalone` in Tab 4 (`[4] SETUP & WIRING`).

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

## Hardware Requirements & Critical AE2 Note

1. **1x OpenComputers Server / Tier 3 Case** (`Redstone I/O` block adjacent to OC Cable + `Adapter` touching each slice's full-block Dual Interface, or `p2p`/OC cable to Adapters).
2. **IMPORTANT — Full-Block `ME Dual Interface` vs Flat Cable Part**:
   - Connect the OC Adapter to a **full-block `ME Dual Interface`** (`TileFluidInterface`) or full-block `ME Interface` (`TileInterface`).
   - Do **not** attach the OC Adapter to a flat cable-part interface (`PartFluidInterface`): in GTNH 2.9.0 / OpenComputers `1.12.68`, cable-part interfaces do not implement `NetworkControl` (`getItemsInNetwork()`). Discovery flags them automatically with a yellow warning!
3. **Topologies**: See [`DESIGN.md`](DESIGN.md) for **Topology A (Dual-Trunk Arbitrary-NC)** and **Topology B (Single-Trunk Circuit/Mold)** ASCII diagrams.

---

## CLI Usage

```sh
universal            # Launch 160x50 Tier 3 Touch Control Center (or --worker if headless)
universal --worker   # Run headless background scheduler (Ctrl+C safely forces all OFF)
universal --check    # Read-only hardware, subnet, & SRTF dry-run check
universal --off      # Immediately zero all bundled redstone outputs
universal --update   # Atomic syntax-checked updater (preserves config.cfg)
```
