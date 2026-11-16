# DTPF OpenComputers Automation — Architecture & Operations Guide

## 1. Uniform In-World Hardware Layout

### Per-DTPF Rig (Uniform Across All Units)
1. **1x MFU pointed at the DTPF Controller (`1004`):**
   - `CompoundBlockDriver` merges [`DriverDTPF` (GTNewHorizons/OpenComputers#228)](https://github.com/GTNewHorizons/OpenComputers/pull/228) (`priority=10`, `"dtpf"`) with Computronics `DriverMachine` + `DriverDeviceInformation` + `DriverPlasmaForge` into a single `"dtpf"` component exposing Convergence, Catalyst Tier, Progress, Coordinates, Work Control, and Sensor Information (falling back gracefully to read-only Convergence status when `#228` is absent).
   - **Machine Controller Cover Check:** If the South face (`z+1`) still has a legacy GregTech Machine Controller Cover attached, it overrides `setWorkAllowed()` every tick. Crowbar that cover off if you want OC's `[Work: ON/OFF]` toggle to control the DTPF. (The UI automatically surfaces a `! COVER OVERRIDE` banner if detected.)
2. **Color 1 (`mColor=1` White) — On-Demand Channel:**
   - Dedicated `Stocking Input Hatch (ME)` + `Stocking Input Bus (ME)` (wallsharable since OD crafts pause passive queues cleanly) connected either to `1` shared On-Demand subnet OR `1` dedicated On-Demand mini-subnet per DTPF (Main -> `Color 1` Pattern `ME Dual Interface` MUST have **`Blocking Mode: ON` + `Advanced Blocking Card`**; optional small `ME Drive` on `Color 1`; OD adapters auto-pair `1:1` and are selectable via `[OD NET]` / `[ 1:1 PAIR OD ]` on **Tab 4 (`SETUP`)**).
3. **Color 2 (`mColor=2` Orange) — Passive Channel (`ch1..chN`):**
   - Dedicated `Stocking Input Hatch (ME)` + `Stocking Input Bus (ME)` (`autoPull = OFF` on Direct MFU Main AE2, or `autoPull = ON` when fed by a Storage-Bus subnet bridge).
   - Additional channels (`ch2..chN`) auto-pair `1:1` by 3D coordinates so every DTPF can run an independent passive recipe simultaneously.
4. **Unpainted (`mColor=0`) — Uniform Shared NC Aux Subnet:**
   - Shared `Stocking Input Bus (ME)` holding **all non-consumed (NC) items** across every DTPF evenly (Programmed Circuits, Lenses, Hypervisor Matrices, `Hi-Computation Station T5`, SpaceTime Bending Cores, Casings).
   - Because GT `doCheckRecipe()` combines unpainted (`-1`) buses with every colored pass, OC keeps `uniformNcSubnet = true` by default so Main Net stocks are not checked for NC items and Passive buses/Storage Buses do not duplicate NC items.

### Two Supported Passive Control Topologies (Zero OC Blocks Touching Any DTPF)

An **MFU (`Upgrade MF`)** is an item slotted inside an OC `Adapter` back in your OC rack (wireless up to `512` blocks). You `Sneak + Right-Click` the 1 accessible front face of each machine, then put the MFU into your OC Adapter back at your base — **nothing blocks any face of any DTPF**.

| Subsystem | Option A — Zero-Subnet Direct MFU (Simplest Wiring) | Option B — Storage-Bus Subnet Bridge (Fewer MFUs) |
| :--- | :--- | :--- |
| **Passive Hatches & Buses on each DTPF** | All `Color 2` passive `Stocking Input Hatch/Bus (ME)` connect **straight to Main AE2 Net** (`autoPull = OFF`; direct on Main AE2 with `0` Dual IFs, `0` Storage Buses, `0` Quartz Fibers, no 16-color or P2P limit). | Each channel (`ch1..chN`) gets an Extract-Only `ME Fluid Storage Bus + ME Storage Bus` on **2 separate cable blocks** facing a Main Net `ME Dual Interface`, feeding `Color 2+` `Stocking Input Hatch/Bus (ME)` (`autoPull = ON`). |
| **OC Hardware for Passives** | **`2` wireless MFUs + `2` plain Adapters per DTPF** in OC rack (or 1 Adapter per pair if `mfg` / rack slots arranged; bound to each DTPF's `Stocking Input Hatch (ME)` + `Stocking Input Bus (ME)`). OC auto-pairs by 3D `(x,y,z)`. | **`1` plain Adapter (`0` MFUs)** per `1–2` channels back in the AE2 room touching the Storage Bus cable blocks (`fluid_storagebus` + `me_storagebus`). |
| **Each DTPF Controller (`N` units)** | `1x wireless MFU + Adapter` bound to DTPF Controller (`1004`). (`3` MFUs total per DTPF.) | `1x wireless MFU + Adapter` bound to DTPF Controller (`1004`). (`1` MFU total per DTPF.) |
| **Main Net Stock Reader** | `1x plain Adapter` (`0 MFUs`) on any unfiltered Main Net `ME Dual IF` / `ME IF` / `ME Controller`. | Same (`1x plain Adapter` on unfiltered Main Net IF, or shared with StorageBus Adapter). |
| **On-Demand (`Color 1`) Detector** | `1x plain Adapter` (`0 MFUs`) on `1` shared `Color 1` OD IF **or** `1x plain Adapter` per DTPF OD mini-subnet (`[OD NET]` / `[ 1:1 PAIR OD ]` on **Tab 4**). | Same. |
| **Unpainted (`Color 0`) NC Aux Subnet** | Shared `Stocking Input Bus (ME)` (`0 Adapters, 0 MFUs`). | Same. |

> **Why Choose Option A vs. Option B:**
> - **Choose Option A (Direct Wireless MFUs)** if building `N` isolated Quartz-Fiber Storage-Bus subnets feels like too much AE2 wiring overhead: every passive `Stocking Input Hatch/Bus (ME)` plugs straight onto your Main AE2 cable, giving **1:1 Per-DTPF Passive Control** for `5–18+` DTPFs with **zero AE2 subnets**.
> - **Choose Option B (Storage-Bus Bridge)** if you want **1 MFU per DTPF total** or want one shared Storage-Bus channel (`ch1`) to feed an entire group of DTPFs (`3` components for `10` grouped DTPFs).

```text
  OPTION A: ZERO-SUBNET DIRECT WIRELSES MFUs (1:1 Per-DTPF Passives, Zero Passive Subnets!)
  -----------------------------------------------------------------------------------------
  UNFILTERED MAIN AE2 NET ──► Directly to every DTPF's Color 2 Stocking Hatch + Bus (autoPull=OFF)
                                 ▲              ▲
                     (wireless MFU #1)   (wireless MFU #2)   (+ MFU #3 on Controller)
                     Bound via Sneak-RClick on Hatch & Bus; MFUs sit in Adapters in OC rack!

  OPTION B: STORAGE-BUS SUBNET BRIDGE (0 Passive MFUs — Sits Back in AE2 Room)
  -----------------------------------------------------------------------------------------
  Main Net [ME Dual Interface] ◄── OC Adapter (Stock Reader)
     ▲           ▲
  [Fluid SB]  [Item SB]  (Extract Only, 2 SEPARATE Color-2 cable blocks) ◄── OC Adapter (0 MFUs)
     └─────┬─────┘
           └──► Color 2 Subnet ──► DTPF Stocking Input Hatch/Bus (ME) [autoPull=ON]
```

> **Note on "OC Read Subnet" vs. Direct Main Net Interface:** If you already have an unfiltered OC Read Subnet fed by `Main Net Dual Interface -> Extract-Only Item+Fluid Storage Buses -> OC Subnet -> Adapter on OC Subnet Dual Interface`, that works fine as the **Main Net Stock Reader** because nothing filters its Storage Buses. Keep it separate from any Option B passive Storage Buses.

- **Storage Bus Shadowing Rule (Option B — 2 Separate Cable Blocks):** Never place `ME Storage Bus` and `ME Fluid Storage Bus` on the same AE2 cable block (`CompoundBlockDriver` merges them and `fluid_storagebus` `priority=2` shadows `me_storagebus` `priority=1`). Put them on 2 adjacent/separate cable blocks touching the Adapter.
- **ME Dual Interface Detection (`"fluid_interface"`):** In GTNH 2.9.0 (`ae2fc-1.5.116-gtnh` + `OpenComputers-1.12.68-GTNH`), AE2FC's `TileFluidInterface` extends AE2 `TileInterface`, so OC exposes full `NetworkControl` (`getItemsInNetwork` + `getFluidsInNetwork`) under component type `"fluid_interface"`. `Hardware.discoverAENetworks()` scans `"me_interface"`, `"fluid_interface"`, and `"me_controller"`.
- **Scaling to 10–32+ Independent DTPFs, Minimum OC Hardware & Budget (Verified in GTNH 2.9.0 `OpenComputers.cfg` + `libjnlua53`):**
  - **Minimum OC Spec (`OpenComputers.cfg` defaults: `ramSizes=[192,256,384,512,768,1024]`, `ramScaleFor64Bit=1.8`, `hddSizes=[1024,2048,4096]`, `cpuComponentCount=[8,12,16,1024]`):**
    - **Memory:** Minimum **`2x Memory (Tier 3.5)`** (`3,686 KB` scaled 64-bit Lua heap). Measured live `libjnlua53` heap across all 4 GUI tabs + `[Log]` modal views is **`2,606 KB`**.
    - **Storage:** Minimum **`Hard Disk Drive Tier 2 (2 MB)`** (`~1.4 MB` peak during `.tmp` atomic updates).
    - **Case / Server:** **Tier 3 Case** (`16` components max -> up to **`2` DTPFs** in 1:1 MFU mode) or **Server Rack + Tier 2/3 Server w/ Component Bus Tier 3** (`48–64` components -> `3` to **`18`** independent DTPFs on `1` Server).
  - **CPU / Lua 5.3:** Requires **Tier 3 CPU / APU Tier 3** in **Lua 5.3** mode (`Sneak + Right-Click`).
  - **No Server TPS Risk from Component Count Alone:** Verified in `OpenComputers-1.12.68-GTNH.jar` that `ManagedEnvironment.canUpdate()` returns `false` on StorageBus / GT environments, so connected Storage Buses and MFUs do **not** run per-tick polling loops. Lua execution is separately rate-limited by `callBudgets = [0.5, 1, 1.5]` and `executionDelay = 12ms`, and our script only writes configuration calls when state actually changes (`pollInterval = 2.0s` / `3.0s`).
  - Click **`[ 1:1 PAIR DTPFS ]`** on **Tab 4 (`SETUP`)** to bind `DTPF #1..#N` -> `ch1..chN` (auto-matched by 3D coordinates for Option A hatches/buses).
- **0-Stock Empty Filter Sentinel (Option B only):** Whenever a Storage Bus channel has zero items or fluids (or is cleared during On-Demand preemption or `OD-Only`), OC automatically writes a verified 0-stock sentinel (`ic2pahoehoelava` / `minecraft:fire`) to Slot 1 so an empty whitelist never exposes all of Main Net. (Option A direct `me_inputhatch`/`me_inputbus` slots clear directly to `nil` with no sentinels needed.)

### Multi-Server Single-Rack Scaling (`19–78+` DTPFs)
One **OpenComputers Server Rack** holds up to **4 Tier 3 Servers** (`64` components per Server stock with `Tier 3 CPU + 3x Tier 3 Component Bus`):
- **Server 1 (Master):** Install GPU, Screen/Terminal Server, Network Card, + up to `~18` DTPFs (`<= 64` total components). Runs `/home/dtpf/main.lua`.
- **Servers 2–4 (Headless Workers):** No GPU or Screen needed (`Tier 3 CPU + 3x Tier 3 Component Bus + Network Card + HDD/EEPROM`). Each Worker handles up to **`20` independent Option A DTPFs** (`60` MFUs + `1` Network Card = `<= 64`). Run `/home/dtpf/main.lua --worker` (configure `/etc/rc.cfg` to auto-start on boot). **1 full Rack = up to `~78` independent DTPFs on 1 unified GUI!**
- **Exact Server Rack & Multi-Rack Wiring:**
  1. Connect each Server's **thick main component line** (`I/O`) to a **different face** of the Rack (`Left`, `Right`, `Top`, `Back`) so each Server's Adapters stay completely isolated (`<= 64` components per Server — never exceeding any cap).
  2. Connect every Server's **thin `Network Card` line** to **one shared Rack face (e.g. `Bottom`)** with Rack **Relay ON**. That passes Master/Worker RPC over port `4104` inside the Rack **without** merging component buses across Servers!
  3. **Multiple Server Racks (`>78` DTPFs):** Simply connect the **Relay face** of additional Server Racks together using regular OC Cables/Switch (with only Network Card lines on that Relay bus) — `Hardware.discoverWorkers()` broadcasts `DTPF_DISC` across the entire bridged LAN and merges workers from any number of Racks automatically.

---

## 2. Scheduler Rules & Safety Mechanisms

### Master Mode: Safe `PAUSED` Startup
- On first boot (no `config.cfg`), `armed` defaults to **`false` (`PAUSED / SAFE MONITOR`)**.
- While `PAUSED`, the scheduler polls live DTPF telemetry, AE2 stock, and On-Demand activity and displays full "would-run" previews in the Control Center **without mutating any hatch, Storage Bus, Convergence setting, or Work toggle**.
- Click **`[○ PAUSED: SAFE]`** in the top bar once you have verified wiring and thresholds to arm **`[● ARMED: AUTO]`**.

### Global vs. Per-DTPF Settings & 3-Layer Convergence Policy
- **Layer 1 — Global Convergence & Fleet Settings** (apply everywhere set to `GLOBAL`):
  - `⚡Converge` (`globalConvMode`):
    - `AUTO (ALL 50%)` (`auto`): converges Priority Passives, Forever Loops, and OD jobs whenever the active DTPF reaches `49.9%+` discount.
    - `PRIO+OD` (`passive_od`): converges Priority Passives and OD crafts (`>= 50%` discount), while keeping Forever Loops catalyst-free (`2x`).
    - `OD ONLY` (`ondemand`): converges On-Demand crafts only; all Passive & Forever Loop jobs stay catalyst-free (`2x`).
    - `ALWAYS 4x` (`always`): converges regardless of discount.
    - `OFF` (`off`): disables Convergence fleet-wide.
  - `On-Demand` (`onDemandConvMode`): `AUTO-SAFE` (enables OD Convergence only when Color 1 already holds a patterned catalyst, preventing catalyst-free OD crafts from stalling) / `FORCE 4x` / `2x OFF`.
  - `During OD` (`pausePassivesOnOD`): `PAUSE PASSIVES` / `KEEP RUNNING`.
  - `Default Catalyst` (`DTCC`–`DTSC`, default `DTEC`) + `Fallback` (`AUTO` / `OFF`, steps down/across legal catalyst tiers when the preferred tier drops below its per-tier Reserve Floor).
  - `Catalyst & DTR Reserves`: per-tier catalyst floors and `Global DTR Reserve Floor` (default `10M L`), which automatically pauses all `dtrIn > 0` recipes (e.g. `Molten Shirabon`, `Molten SpaceTime`) when Main Net DTR falls below the floor.
  - `Forever Passive`: keeps idle DTPFs running a continuous loop (default `Molten Infinity`) so the 50% fuel discount never resets, with its own **`Forever Loop Conv`** override (`fallbackConvMode`: `GLOBAL` / `LOOP 4x` / `LOOP 2x`).
- **Layer 2 — Per-Recipe Convergence Policy (`rc.convMode`)**:
  - Set inline in the Passive Queue (`⚡` / `◇` / `[⚡]` / `⚡!` / `[◇]` toggle) or in **Tab 3 (`Recipes`)** Inspector (`GLOBAL` / `AUTO@50%` / `FORCE 4x` / `2x OFF`), alongside per-recipe Catalyst Tier, Recipe Variant, Stock Target Floor, and Guard Floor.
- **Layer 3 — Per-DTPF Direct Card Controls & Passive Assignment Modal** override individual DTPFs right on their in-world card in **Tab 2 (`Fleet`)** (with faithful `7x4` multiblock coil icon, `[Compact]` 14-DTPF overview + row paging for `10–24+` DTPFs, and surfacing `[Reset]` + fleet `[Reset All]` / `[Reset Rec⚡]`):
  - `[● ON ]` / `[○ OFF]` power toggle, clickable unit name (rename), clickable coil sprite, `⚡Conv` (`GLOBAL / AUTO 50% / PRIO+OD / OD ONLY / ALWAYS / OFF`), `Cat` (`GLOBAL / DTCC..DTSC`), and **`Pass:`** picker button:
    - Left-click opens the **Per-DTPF Passive Assignment Modal** to set **`AUTO (Queue+Loop)`**, **`QUEUE ONLY`** (pauses unit on fallback), **`FOREVER LOOP`**, **`ON-DEMAND ONLY`** (keeps unit idle until OD crafts arrive), or pin any specific recipe as **`◆ Pin <Target`** or **`* Loop 24/7`**. Right-click quick-cycles modes.
    - When `>1` channel exists, each card shows a clickable `[CH# · Dedicated]` / `[CH# · Shared xN]` channel selector. Pinned recipes reserve their slot in the queue so `AUTO` DTPFs won't duplicate them.

### Cross-Screen Navigation, 4-Tab Layout & Walk-Up Touch Ergonomics
- **1-Click Cross-Navigation (`Tab 1 Overview <-> Tab 2 Fleet <-> Modal <-> Tab 3 Recipes <-> Tab 4 Setup`):**
  - **Tab 1 (`Overview`)** surfaces single-screen System Health, DTPF Fleet at a Glance, Recipe Queue breakdown, Catalyst/DTR reserve gauges, and Recent Activity (`[←]`/`[→]` jump straight into Fleet, Recipes, Setup, or the Log Modal).
  - Left-clicking the active or preview recipe name on any DTPF card in **Tab 2 (`Fleet`)** jumps straight to that recipe in **Tab 3 (`Recipes`)** while keeping that DTPF selected; right-clicking opens its **Passive Assignment Modal**.
  - Inside **Tab 3 (`Recipes`)**, `[<- Fleet]` returns to **Tab 2**, and the **`DTPF: [◀] #N [▶] [◆ Pin <Tgt] [* 24/7] [Auto]`** bar pins the currently inspected recipe directly to any DTPF (flagged with `◆` in the left list).
  - Inside the **Passive Assignment Modal**, `[◀]`/`[▶]` step across DTPFs without closing, filter tabs (`[All 27]`, `[Enabled]`, `[Cat-Free]`, `[Loops]`, `[Coil OK]`) narrow choices by coil heat or role, clicking any recipe name inspects it in **Tab 3**, and right-clicking quick modes or pin actions applies while keeping the modal open.
  - Clicking any DTPF row in **Tab 4 (`DISCOVERED DTPF CONTROLLERS`)** focuses and scrolls to that DTPF back on **Tab 2 (`Fleet`)**. Keyboard shortcuts: `[1-4]` select Overview/Fleet/Recipes/Setup, `[` / `]` cycle DTPFs, `[P]` opens the Passive Modal, `[C]` toggles Compact Fleet view.
- **1-Click Fleet Presets (`y = 47` Quick Bar on Tab 2):**
  - **`[Copy->All]`** clones the selected DTPF's Convergence, Catalyst, and Passive Role/Pin across the fleet.
  - **`[1 Loop+Rest Q]`** keeps the selected DTPF on `AUTO` (Queue + Forever Loop) while setting non-OD DTPFs to `QUEUE ONLY` so all units clear active queue targets together, then all but one sleep to save fuel/catalysts once targets are met.
  - **`[Last OD]`** toggles the last DTPF between `ON-DEMAND ONLY` and `AUTO`.
- **100% Walk-Up Touch Number Picker:** Reserve Floors (`[Min:...]`), Custom Stock Targets, and Guard Floors include 1-click preset chips (`[0]`, `[10K]`..`[50B]`) and relative adjustment buttons (`[/10]`, `[/2]`, `[-25%]`, `[+25%]`, `[x2]`, `[x10]`) so no keyboard input is needed at the monitor.
- **Live Observability, Stage Logging & Raw I/O Snapshot:**
  - Header heartbeat pulse (`◐`–`◒`), **`[↻ Poll]`** immediate refresh button, and **`[Log:N]` / `[! N Alert]`** (`[L]` hotkey) diagnostics modal with two views:
    - **`[1: Activity Log]`**: 64-entry RAM rolling buffer tagged with structured stages (**`[IN ]`**, **`[DEC]`**, **`[OUT]`**, **`[WRN]`**), stage filter buttons (`ALL/IN/DEC/OUT/WARN`), and **`[Quiet]` / `[Normal]` / `[Raw]`** verbosity modes (hotkey `[V]`; `normal` is default with `0` steady-state overhead, `raw` traces per-poll inputs/decisions/outputs on live polls only).
    - **`[2: Raw I/O Snapshot]`**: On-demand live view showing exact **RAW INPUTS** (`DTEC`, `DTR`, active DTPFs), **RAW DECISIONS** (`Queue`, per-channel assignment + reason), and **RAW OUTPUTS** (`ch1..chN` written Hatch Fluid & Bus Item slots + Convergence/Work policy) computed only when rendered.
  - Smooth 8-step sub-pixel progress bars (`█`/`▏`..`▉`/`░`) on DTPF cards and Tab 3 stock thresholds, animated plasma pinch (`‹⚡›` ↔ `⚡◈⚡`), double-line focus frame (`╔═╗`) vs. rounded panels (`╭─╮`), card top-border role/remote badges (`[PIN]`, `[24/7]`, `[QUEUE]`, `[LOOP]`, `[OD-ONLY]`, `[W]`), micro-telemetry footers (convergence warmup/4x badge, catalyst tank gauges `▁`–`█`, GTNH coil tier names `◉Eternal`/`◉Hypogen`), Tab 3 recipe category glyphs (`◈`/`▣`/`⊕`), Tab 4 signal-flow topology bar (`◈ TOPOLOGY:`), and live AE2 ingredient checkmarks (`✓`/`✗` + estimated crafts) + `[! BLOCKED]` filter.
  - Right-click **`▲` / `▼`** jumps a recipe straight to top/bottom priority; right-click any catalyst **`[Min:...]`** floor copies that reserve floor across all 5 catalyst tiers (`DTCC`–`DTSC`); clicking an active `#N` unit status badge in the Passive Queue focuses that DTPF.

### Catalyst-Free (`NONE`) Recipes Under Convergence
Recipes with no recipe-native catalyst (`Molten Shirabon`, `Molten SpaceTime`, `Molten Six-Phased Copper`, `Giga Chad`, `Chipped Amalgatite`, `Superfluid`) dynamically accept a catalyst tier (`1..5`) in `MTEPlasmaForge.recipeAfterAdjustments()` when Convergence is enabled:
- When Convergence will be active, OC injects the selected (or auto-fallback) catalyst fluid into the Passive channel AND calls `setConvergenceCatalystType(tierIndex)`.
- If every legal Convergence catalyst drops below its reserve floor, OC automatically disables Convergence on those DTPFs for that cycle so the recipe continues safely at `2x` OC instead of deadlocking.

---

## 3. Workflow & Entrypoints

| Command | Purpose |
| :--- | :--- |
| `python3 tools/test_offline.py` | Runs the offline Lua 5.3 + OpenComputers `JNLua` regression suite (`19` suites) and UI framebuffer/heap verification. |
| `install --local <dir>` | Inside OpenOS: offline/local atomic install into `/home/dtpf/` (restores `/home/config.dtpf.bak` if present). |
| `dtpf --check` | Inside OpenOS: prints structured Raw Inputs, Scheduler Decisions, and Dry-Run Outputs read-only check and exits. |
| `dtpf --update` | Inside OpenOS: downloads and syntax-verifies the latest Lua files via Internet Card (`config.cfg` preserved). |
| `dtpf` | Inside OpenOS: launches the clickable `160x50` **Overview**, **Fleet**, **Recipes (27)**, and **Wiring & Setup** GUI. |

## 4. Re-Extracting Recipes (Future Modpack Updates)
- `python3 tools/extract_dtpf_recipes.py` regenerates [`lib/recipes_db.lua`](lib/recipes_db.lua) directly from `GTNewHorizonsCoreMod` and `gregtech` jars.
