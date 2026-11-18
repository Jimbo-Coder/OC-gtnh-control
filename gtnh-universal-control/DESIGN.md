# Design & Architecture — GTNH Universal Control

## 1. Core Concept: Always-On NC Waiting Rooms + Per-Channel Bundled Toggle Buses

Every NC bucket (`Circuit 1`, `Circuit 2`, `Pink Catalyst`, `GT++ Extruder Shape`, `Petri Dish`, ...) is an **always-on 2-channel AE2 subnet** ("Waiting Room") containing **0 Non-Consumable items** at idle:

```text
  MAINNET (Always On)
    |
    v
  [Mainnet Pattern Dual Interface]  (Adv Blocking Mode + Allow Insert Same Recipe)
    | (face-to-face)
  [Full-Block Subnet Dual Interface #k]  <-- OC Adapter (GTNH 2.9 Push Event Subscription!)
    |
    +-- [ME Drive: Item Cell + Fluid Cell]   (NO NC item here -> 0 items when idle!)
    |     `-- Powered 24/7 via Quartz Fiber (uses only 2 channels: NO ME Controller needed!)
    |
    |-- Face 1: Extract-Only Item & Fluid Storage Buses + [Chest w/ NC #k]
    |     `--> [Toggle Bus Ch1 Color k] --> MACHINE TRUNK CH1 (Sprayed Black = GT Prio 1)
    |
    `-- Face 2: Extract-Only Item & Fluid Storage Buses + [Chest w/ NC #k]   (optional 2nd channel!)
          `--> [Toggle Bus Ch2 Color k] --> MACHINE TRUNK CH2 (Sprayed Blue = GT Prio 5)

  MACHINES (Adv. Stocking Input Bus + Adv. Stocking Input Hatch, Auto-Pull = ON, Refresh = 1-2t, Input Separation = ON):
    - Channel 1 hatches sprayed BLACK (index 0: checked FIRST by GTNH MTEMultiBlockBase!)
    - Optional Channel 2 hatches sprayed BLUE (index 4: checked AFTER Channel 1!)
    - ME Output Bus / ME Output Hatch -> Mainnet
```

### Why `Advanced Blocking Card` Works for 100% of GTNH Recipes
- In `appliedenergistics2-rv3-beta-1095-GTNH.jar` (`AdaptorDualityInterface.containsItems()`), `Advanced Blocking Card` only skips Circuits, Standard GT Shapes/Molds/Slicers, Lenses, Presses, Blood Orbs, Division Sigil, and TF Trophy — **not** GT++ Extruder Shapes, Catalysts, Petri Dishes, or Fluid NCs.
- By placing `NC #k` behind `Toggle Bus #k` on the **machine side** with **Extract-Only** Storage Buses against the Waiting Room's full-block `ME Dual Interface` (`AEFluidInterfaceHandler.class`), the Waiting Room sees **0 items/fluids when idle** and never sees `NC #k` or any other subnet!
- If an external NC ever resides inside the Waiting Room anyway, `[CALIBRATE IDLE NCs]` snapshots its idle baseline cleanly.

---

## 2. Clean `(Input Channels x NC Subnets)` ProjectRed Wiring

- **1 Bundled Cable per Input Channel per 16-NC Bank — Same Color = Same NC Everywhere**:
  - `NC #00..15` (`Bank A`) always maps to Bundled Color `k = 0..15` on `channel.banks[1]` (`rsAddr, side`).
  - Optional `NC #16..31` (`Bank B`) maps to Bundled Color `k % 16` on `channel.banks[2]` (`rsAddr, side`).
  - Adding Channel 2 later only adds a second `Extract-Only Storage Bus + Toggle Bus` row on another face of each Waiting Room (`Ch1 = North Color k`, `Ch2 = South Color k`), zero teardown and `0` color-translation math.
  - Per-`(channel, nc)` overrides (`channel.overrides[nc]`) are also supported.
- **Native 1-Tick Multi-Side Writes**: `Hardware.flushWireTargets` dirty-checks `(rsAddr, side)` bitmasks and flushes multi-side updates atomically via GTNH 2.9 `RedstoneBundled.setBundledOutput(sidePayload)` (`0` OC calls on unchanged ticks).

---

## 3. Near-Zero Idle Overhead via GTNH 2.9 Push Subscriptions (`OpenComputers-1.12.68-GTNH.jar`)

- Bound full-block `me_interface` components enable `setItemEventSubscription(true)` + `setFluidEventSubscription(true)`.
- At boot / bind, each interface is scanned once (`_seeded = true`). Thereafter:
  - When **idle**: OC performs **`0` `getItemsInNetwork` calls**, sleeping in `event.pull(idlePollSec)` (`30.0s`) and waking in **`0 ticks` (`0 ms`)** the instant `network_item_changed` or `network_fluid_changed` arrives.
  - While **draining**: delta events (`ev[3..N]`) update Lua item/fluid count maps in `O(k)` without indirect calls; when incremental counts reach `0`, OC executes **1 ground-truth confirm scan** before marking batch complete (and periodically cross-checks active slices every `activeVerifySec = 5.0s`).

---

## 4. Pluggable Policy Engine (`lib/policy.lua`)

- **`mlfq` *(default — solves `Amount != Duration` without a recipe DB)***:
  1. New / unknown or known-fast recipes start in **`PROBE`** tier (`probeWindowSec = 1.5s`, `fastThresholdSec = 3.0s`). Truly fast recipes (`128,000 L` Hydrogen finishing in `0.2s`) complete inside `PROBE` without ever losing to small slow crafts (`10` Xenoxene).
  2. Slices still running past `probeWindowSec` graduate to **`BULK`**, using live EWMA drain rates (`+` 128-entry bounded recipe fingerprint cache `recipeRates[pool:nc:sig]`) and SRTF + starvation aging (`15%/min`). Repeat slow crafts immediately classify `BULK`; repeat fast crafts immediately classify `PROBE`.
  3. **Multi-Channel High->Low Demotion (`K >= 2`)**: As soon as a job graduates to `BULK` while fewer jobs than channels are queued (`#winners < K`), `Policy.decide` moves that `BULK` job onto the lowest-priority enabled channel (`ChK`) and leaves `Ch1 (Black, GT Prio 1)` **`IDLE` and pre-settled (`OFF`)** so the next fast craft jumps onto `Ch1` in `0s` and takes native hardware priority over `Ch2`.
- **Native Wire-to-Hatch-Color Priority Mapping (`gtDye = 0..15`)**: Each Input Channel stores its physical GregTech spray-can / AE2 cable color (`ch.gtDye`). In GTNH 2.9 (`MTEMultiBlockBase.getHatchColors`), multiblocks always check hatches strictly in `Dyes.mIndex` order `0=Black (#1)` > `1=Red (#2)` > `2=Green (#3)` > `3=Brown (#4)` > `4=Blue (#5)` > ... > `14=Orange (#15)` > `15=White (#16)` (`-1=Unpainted` matches every color pass and is flagged if enabled on multi-channel pools). `Policy.orderedEnabledChannels()` automatically ranks active channels by their configured `gtDye` — regardless of array index — so `PROBE` crafts always target whichever wire is actually sprayed the highest-priority color!
- **Selectable Policies**: `"srtf"`, `"round_robin"`, `"fifo"`, `"priority"`.
- **Invariants**: Never assigns the same NC to two channels simultaneously, refuses duplicate `(rsAddr, side)` wire writes on miswiring, and protects every slice change behind `settleSec` (`1.0s` All-OFF guard).
