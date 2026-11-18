# Design & Architecture — GTNH Universal Control

## 1. Why `Advanced Blocking Card` Fails on Arbitrary NCs (GTNH 2.9.0 Bytecode)

In `appliedenergistics2-rv3-beta-1095-GTNH.jar` (`AdaptorDualityInterface.containsItems()`):
- When an `Advanced Blocking Card` (`DEFAULT` mode) is installed, AE2 scans `IMEMonitor.getStorageList()` across **all** item and fluid stacks in the receiving subnet.
- Only stacks registered in `AE2Compat.registerBlockingModeIgnoreItems()` (`BlockingModeIgnoreItemRegistry`) are skipped: **Integrated Circuits**, **Inscriber Presses**, **Blood Orbs**, **standard GT Molds / Extruder Shapes / Slicer Blades**, and **Lenses**.
- **GT++ Extruder Shapes/Molds**, **Chemical Catalysts**, **Petri Dishes**, **Data/Research Sticks**, **Schematics**, and **Fluid NCs** are **NOT** ignored! Putting them inside the ingredient subnet's `ME Drive` causes `containsItems()` to return `true` and permanently blocks Mainnet pattern insertion.

---

## 2. Two Supported Topologies (Zero Machine MFUs)

### Topology A — Dual-Trunk Arbitrary-NC (Universal, 100% of GTNH Recipes)

```text
MAINNET (Always On)
  |
  v
[Mainnet Pattern Dual Interface]  (Adv Blocking Mode + Allow Insert Same Recipe)
  | (face-to-face)
[Full-Block Subnet Dual Interface #k] <-- OC Adapter reads getItemsInNetwork/getFluidsInNetwork
  |
  +-- [ME Drive: Item Cell + Fluid Cell]   (NO NC item here -> 0 items when idle!)
  |     ^
  |     `-- Powered 24/7 via Quartz Fiber (uses only 2 channels: NO ME Controller needed!)
  |
  +-- Bundled Color k --> [ME Toggle Bus #k-Ing] --> MACHINE INGREDIENT TRUNK
  `-- Bundled Color k --> [ME Toggle Bus #k-NC ] <-- [1-ch Storage Bus + Chest/Drawer with NC #k]
                                                        |
                                                        v
                                                   MACHINE NC TRUNK

MULTIBLOCKS (Input Separation: OFF — safe because OC enforces strict 1-slice mutual exclusion + Settle Guard):
  - Adv. Stocking Input Bus + Adv. Stocking Input Hatch (autoPull = ON) on MACHINE INGREDIENT TRUNK
  - Stocking Input Bus (+ optional Stocking Input Hatch, autoPull = ON) on MACHINE NC TRUNK
  - ME Output Bus / ME Output Hatch -> Mainnet
```

**Why this works with every NC in GTNH**:
- Because `MACHINE NC TRUNK` and `MACHINE INGREDIENT TRUNK` never merge in AE2, `Ingredient Subnet #k` **never** sees `NC #k` — neither when `Toggle Bus #k` is `OFF`, nor when `Toggle Bus #k` is `ON` and Mainnet streams additional batches under `Allow Insert Same Recipe`!
- Because OC guarantees **at most one bundled color `k` active at any instant**, plus a configurable **All-OFF Settle Guard** (`settleSec`, default `1.0s`) before turning on color `j`, `Input Separation: OFF` never mixes recipes across slices.

### Topology B — Single-Trunk Circuit/Mold (Minimum Cable Count)

For standard GT Circuits, standard GT Molds/Extruder Shapes, and Lenses (all ignored by `Advanced Blocking Card`):
- Put the Circuit/Mold directly inside `Ingredient Subnet #k`'s `ME Drive`, wire 1 `ME Toggle Bus #k` to a single Machine Trunk, and let `Hardware.isBuiltinIgnoredNC()` skip it automatically.
- If a Single-Trunk subnet holds a non-registered NC while `Blocking Mode: OFF` (or custom fluids/items), press **`[CALIBRATE IDLE NCs]`** in Tab 4 (`[4] SETUP & WIRING`) to snapshot idle quantities and subtract them from remaining work cleanly.

---

## 3. Scheduler Invariants (`lib/scheduler.lua`)

1. **Strict Mutual Exclusion & Settle Guard**:
   Switching `Color A -> Color B` always drives all 16 colors to `0` (`SETTLING`) for `settleSec` (`1.0s` default) before driving `Color B = 255`.
2. **Minimum Hold Quantum (`minHoldSec = 15s`)**:
   Prevents thrashing on noisy updates or rapid back-to-back arrivals.
3. **SRTF Preemption + Starvation Aging**:
   - Each bound slice tracks an EMA drain rate (`u/s`) computed from live `workScore = itemUnits + fluidUnits / 1000`.
   - Waiting time applies an aging discount (`15%/min`, capped at `80%`) so even multi-hour crafts eventually execute.
   - A strictly higher priority slice (`pin > high > normal > low`) or a short slice (`candidateEffEta < activeEffEta * preemptRatio`, default `0.35`) preempts after `minHoldSec`, and the preempted slice resumes automatically once the short craft finishes.
4. **Stall Isolation & Auto-Recovery**:
   If an `ACTIVE` slice shows `0` drain for `stallTimeoutSec` (`120s` default), it transitions to `STALLED`, turns OFF, yields the pool to other runnable slices, and retries after `retryStalledSec` (`60s`) or immediately if subnet stock changes.
