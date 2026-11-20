# GTNH Stock Control — Architecture & Performance Design

## 1. Hardware & AE2 Wiring
- Attach an OC **Adapter** (or 1 Wireless **MFU**) directly to a Mainnet `me_controller`, `me_interface`, or `fluid_interface` (`ME Dual Interface`).
- Attach an optional **Wireless Modem** (`strength >= 400`) or **Linked Card** for OC Mesh (`port 4205`) integration with `gtnh-ae2-control` (Main Brain), `gtnh-dtpf-control`, and the `:8765` Web Console.
- Attach an optional **Transposer + Chest** for in-game drop-in rule creation, and temporarily adapt physical `ME Level Maintainer` blocks (`level_maintainer`) if migrating existing slots.

## 2. Why It Outperforms Physical `TileLevelMaintainer` Blocks
Verified from `ae2fc` (`TileLevelMaintainer.class`) and GTNH 2.9 `OpenComputers` (`NetworkControl.scala`) bytecode:
- Each physical `TileLevelMaintainer` holds at most `5` slots, consumes `1` AE2 channel, and calls `getCpus()`, `isCraftable()`, `findPrecise()`, and `beginCraftingJob()` on `doWork()` every `5..120` AE2 ticks (`43` blocks / `135` slots in our world).
- `gtnh-stock-control` uses `0` AE2 channels per rule, polls `getCpus()` once per cycle, executes staggered O(1) `getItemInNetwork` / `getFluidInNetwork` hash lookups, applies hysteresis + exponential backoff, and deduplicates across DTPF via `STOCK_CLAIMS` / `DTPF_CLAIMS`.
- Note on `getItemInNetwork`: GTNH `NetworkControl.scala` injects an empty `{}` `NBTTagCompound` on the 3-argument string call; always pass the table form `{ name = ..., damage = ... }` for non-NBT items.
