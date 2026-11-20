# GTNH Stock Control (`gtnh-stock-control`)

High-performance OpenComputers **Mainnet AE2 Level Maintainer** (`items` + `fluids`) with a `160x50` Tier 3 Touch GUI, O(1) GTNH 2.9 lookups, hysteresis, exponential backoff, DTPF overlap advisories, physical `ME Level Maintainer` migration, and `:8765` Web Console integration.

## Features

- **Direct Mainnet O(1) AE2 APIs**: Uses GTNH 2.9's `getItemInNetwork({ name, damage })`, `getFluidInNetwork(name)`, and `getCraftable(detail, type)` to avoid expensive `getItemsInNetwork()` full-network scans, with staggered batch slicing (`staggerBatch`) for hundreds of rules at minimal MSPT.
- **Smart Dispatch Discipline**:
  - **Hysteresis (`lowThreshold` < `target`)** prevents continuous 1-item micro-crafting thrash.
  - **CPU Guardrails**: Honors `freeCpusReserve`, `maxConcurrentCrafts`, `maxDispatchPerCycle`, optional CPU name routing (`cpuFilter`), and deduplicates against busy CPUs (`finalOutput()`).
  - **Exponential Failure Backoff**: Backs off missing-resource / failed crafts (`30s -> 60s -> 120s -> ... -> 600s`) instead of hammering AE2 every tick.
- **DTPF Overlap Advisory & Coordination (`port 4205`)**:
  - Flags rules that overlap DTPF's passive catalog (`lib/dtpf_catalog.lua`), active DTPF passive outputs (`DTPF_CLAIMS`), or DTPF's local maintainer.
  - Emits `STOCK_CLAIMS` so DTPF can automatically defer overlapping rules or warn without duplicating crafts.
- **Drop-In Rule Adder & Physical Maintainer Importer**:
  - Optional `transposer` + chest slot auto-detects items and `ae2fc:fluid_drop` / tanks on Tab 3.
  - 1-click **`[+ Import All New]`** reads all 5 slots from any adapted physical AE2FC `level_maintainer` block (`getSlot(1..5)`), with optional post-import slot disabling (`setEnable(slot, false)`).

## One-Line Install

```sh
wget -f https://raw.githubusercontent.com/Jimbo-Coder/OC-gtnh-control/main/install.lua /tmp/install.lua && /tmp/install.lua stock
```

## CLI Usage

```sh
stock            # Launch 160x50 Touch Control Center (or --worker if headless)
stock --worker   # Run headless background daemon
stock --check    # Read-only AE2 O(1) & rule dry-run check
stock --bench    # Profile O(1) lookups vs legacy scans & physical maintainers
stock --import   # Scan & import physical ME Level Maintainer blocks
stock --off      # Disarm safely
stock --update   # Atomic syntax-checked updater (preserves config.cfg)
```
