# Architecture — GTNH Gorge & Multi-Exoticizer Control

## 1. Dynamic 10-Slot Database Partitioning (Up to 8 Exoticizers on 1 Tier-3 Database)

Upstream Exoticizer controllers pre-loaded 80 static plasma entries into a single 81-slot Tier-3 `Database Upgrade`, locking one computer to a single Exoticizer module.

`gtnh-gorge-control` writes **only the active batch** dynamically:
- Exoticizer `#i` (`1..8`) owns slots `slotBase .. slotBase + 9` where `slotBase = (i - 1) * 10 + 1`:
  - `slotBase`: Marker item (`minecraft:paper` named `Fake recipe G<i> <dbShort>`) used as the Slot-1 Pattern Output and safe idle self-loop input.
  - `slotBase + 1 .. slotBase + 7`: Active `ae2fc:fluid_drop` inputs (`{Fluid:"..."}`), encoded alongside `setInterfacePatternInput` amounts right before draining the Output Subnet ME Drive (`3` plasmas for Magmatter, `7` for Quark-Gluon Plasma).

## 2. Non-Blocking, Self-Healing State Machine (`lib/scheduler.lua`)

Each Exoticizer runs independently through:
`IDLE -> ENCODE -> CLEAR_AE -> REQUEST -> WAIT_END -> IDLE`
- Any transient error (`no such component`, `missing plasma`, `IO port timeout`, `3x craft failure`) moves that Exoticizer into **`RETRY_WAIT` (`retryBackoffSec = 15s`)**, logs once (no log spam), and automatically retries without blocking sibling Exoticizer modules.
- Returning from `WAIT_END` cancels any active fake recipe with a bounded `2s` loop and resets Slot 1 back to the safe placeholder pattern.
- `clearOutputCells` measures the exact occupied cell count (`1..10`) on `meDriveSide`, drains all moved cells through `meIoPortSide` (`slots 7..12`), and returns them even if IO Port times out.
