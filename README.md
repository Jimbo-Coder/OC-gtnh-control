# GTNH DTPF Automation Controller (OpenComputers)

A self-configuring **OpenComputers (Lua 5.3 / OpenOS)** control center for automating **Dimensionally Transcendent Plasma Forges (DTPFs)** in **GregTech: New Horizons 2.9+**.

Manages passive AE2 stock targets, 24/7 continuous loops, **AE2 On-Demand autocrafting priority**, optional Convergence control, Coil Tier & 8-hour warmup monitoring, DTR/catalyst reserve floors, and an optional Transposer catalyst bridge across **1 to 16+ DTPFs** in a 4-tab `160x50` touch GUI.

![[1] OVERVIEW — System Health, Fleet Glance, Queue, Reserves & Recent Activity](screenshots/gui_overview.png)
![[2] FLEET — Live In-Game DTPF Cards & Priority Queue](screenshots/gui_fleet_live.png)

---

## 1. One-Command Install & Safe Updating

Install on OpenOS from `/home` with an **Internet Card** slotted in your OC computer/server:

```sh
wget -f https://raw.githubusercontent.com/StankCIty/gtnh-dtpf-control/main/install.lua && install
```

*(If installing from a fork or custom branch: `wget -f https://raw.githubusercontent.com/<owner>/<repo>/<branch>/install.lua && install <owner>/<repo> <branch>`.)*

### Safe Updates & Reinstall Settings Preservation
- **In-place update (`config.cfg` untouched):**
  ```sh
  dtpf --update
  ```
- **Syntax-checked atomic updates:** `install.lua` stages all files into `.tmp` paths, compiles every Lua module with `load()`, and **aborts without touching existing files** if any transfer fails or fails syntax validation.
- **Survives full folder deletion (`rm -rf /home/dtpf`):** Every `saveConfig` and update automatically mirrors your settings to `/home/config.dtpf.bak`. If `/home/dtpf/config.cfg` is missing during a reinstall or boot, `/home/config.dtpf.bak` is automatically restored.
- **Offline / Local install (no Internet Card):** Copy the repo directory (e.g. `/home/dtpf_src`) onto your OpenOS disk and run:
  ```sh
  /home/dtpf_src/install.lua --local /home/dtpf_src
  ```
  *(Runs the same `load()` syntax checks, `.tmp` atomic install to `/home/dtpf`, `/usr/bin/dtpf.lua` wrapper setup, and `/home/config.dtpf.bak` restore.)*

---

## 2. Minimum OpenComputers Hardware (GTNH 2.9+)

| Component | Minimum Requirement | Why / Scaling Notes |
| :--- | :--- | :--- |
| **Case / Server** | **Tier 3 Computer Case** (`1–2` DTPFs) **or** **Server Rack + Tier 2/3 Server w/ Component Bus Tier 3** (`3–18` DTPFs) | Tier 3 Cases cap at `16` components (`3` MFUs per DTPF + AE2/Transposer = `2` DTPFs max). A Tier 2/3 Server with **Component Bus Tier 3** gives `48–64` slots; add headless `--worker` Servers in the same Rack up to `~78` DTPFs. |
| **CPU / APU** | **Tier 3 CPU** (or **APU Tier 3**) set to **Lua 5.3** | `Sneak + Right-Click` the CPU in hand until Lua `5.3` is selected. |
| **Memory (RAM)** | **2x Memory (Tier 3.5)** (`3,686 KB` 64-bit scaled heap) | Measured live 64-bit `libjnlua53` heap with all 4 GUI tabs + 64-entry Log Modal open is `~2,606 KB`. |
| **Storage (HDD)** | **Hard Disk Drive Tier 2 (`2 MB`)** or Tier 3 (`4 MB`) w/ OpenOS | OpenOS + controller + atomic `.tmp` update staging peaks around `~1.4 MB`. |
| **Display & Input** | **GPU Tier 3 + Screen Tier 3 (`160x50`)** + Keyboard | **Internet Card** is optional (needed only for `wget` / `dtpf --update`). |
| **Adapters & MFUs** | `3x` Wireless MFUs per DTPF + `2x` Adapters on Dual IFs (+ `1x` optional Transposer) | Bind Wireless MFUs (`512`-block range) inside Adapters back at your OC room so `0` OC blocks touch your DTPFs. |

---

## 3. End-to-End Physical Wiring (AE2 + OpenComputers)

Every subsystem is auto-discovered by component type and 3D coordinates — **you never need to type UUIDs manually**.

### Overview Diagram
```text
                        ┌──────────────┐
                        │  MAIN AE2    │  (Unfiltered Main Network)
                        └──────┬───────┘
          ┌────────────────────┼──────────────────────┐
          │ (Color 2: Orange)  │                      ▼
          ▼                    │               [Main Dual IF] ◄── OC Adapter (Stock Reader)
  Passive ME Stocking          │                      │
  Hatch + Bus on each DTPF     │                [OC Transposer] (Optional Catalyst Bridge)
  (Direct on Main AE2,         │                      │
   autoPull = OFF)             │                      ▼
          ▲                    │               [OD Dual IF]   ◄── OC Adapter (On-Demand Detector)
          │ (Wireless MFUs)    │                      │
  ┌───────┴────────┐           │                      ▼ (Color 1: White)
  │ OC Case / Rack │           │               On-Demand ME Stocking Hatch + Bus on DTPFs
  └───────┬────────┘           │
          │ (Wireless MFU)     │               (Color 0: Unpainted)
          ▼                    └────────────► Shared NC Aux Subnet -> Non-Consumed Input Bus
   DTPF Controller
```

### Visual Wiring Reference

![AE2 Subnets, Pattern Interface Blocking Mode, and Transposer Catalyst Bridge](screenshots/ae2_subnets_and_bridge.png)
![Wallshared DTPF Hatch & Bus Color Layout](screenshots/dtpf_wallsharing_underside.png)
![Wireless MFU Adapter Bank & Server Rack Room](screenshots/oc_wireless_mfu_room.png)

### Step-by-Step Build Checklist

1. **OpenComputers Hardware & Wireless MFU Bank**
   - Install **Tier 3 CPU (Lua 5.3)**, **2x Memory (Tier 3.5)**, **Tier 2+ HDD (OpenOS)**, and **Tier 3 GPU + `160x50` Screen** in a Tier 3 Case (up to `2` DTPFs) or a **Server Rack + Server w/ Component Bus Tier 3** (`3–18+` DTPFs).
   - Connect **Wireless MFUs** inside OC Adapters (`Sneak + Right-Click` the target block, drop the MFU into an Adapter back at the OC rack — max range `512` blocks, `0` OC blocks touching your DTPFs). As shown above, a `5`-DTPF setup uses `5` stacks of `3` MFU Adapters (`DTPF`, `Color 2 Hatch`, `Color 2 Bus`) plus `2` Adapters on the Main & On-Demand Dual Interfaces.
   - *(Tip for `>16` components)* A **Tier 3 Server** holds a CPU + 3 Component Buses (`64` components stock = ~18 DTPFs). Beyond `~18` DTPFs, slot extra headless Servers in the same Rack running `dtpf --worker` with per-Server I/O faces isolated and only their Network Cards bridged via the Rack Relay.

2. **DTPF Controllers (1 MFU or Adapter per DTPF)**
   - Bind 1 MFU (or Adapter) to each **DTPF Controller**.
   - **Important:** Crowbar any **GregTech Machine Controller Cover** off the South face (`z+1`) so OpenComputers `setWorkAllowed()` has full control. The UI shows a `! COVER OVERRIDE` warning automatically if a cover overrides OC.

3. **Passive Stocking — `Color 2` (Orange) Direct on Main AE2 *(Recommended)***
   - Keep **Passive (`Color 2` Orange)** dedicated **per DTPF** (on each unit's outer wing, **never** on wallshared faces) so every DTPF can run an independent passive recipe concurrently.
   - Install **1x ME Stocking Input Hatch** and **1x ME Stocking Input Bus**, paint both **Color 2 (Orange)**, and connect them straight to your **Main AE2 cable**.
   - Bind a **Wireless MFU** to each Passive Stocking Hatch and Passive Stocking Bus (OC automatically pairs Hatch + Bus + DTPF `1:1` by closest 3D coordinates).
   - **Keep them disconnected from Main AE2 or run `dtpf --lock` BEFORE connecting** so `autoPull` is locked **OFF** — OC populates the exact recipe fluid/item slots dynamically per craft!
   - *(Why Tab 4 `[4] SETUP` says "Direct on Main AE2":* this mode needs zero passive sub-networks, zero Quartz Fibers, and zero Storage Buses. If you prefer fewer MFUs and shared sub-networks, **Option B: Storage-Bus Subnet Bridge** with extract-only Fluid + Item Storage Buses on 2 separate cable blocks is also auto-detected.)

4. **Main Stock Reader & On-Demand (`Color 1` White) Crafting Subnet**
   - **Main Stock Reader:** Place `1` OC Adapter next to any unfiltered **ME Dual Interface** (or ME Interface / ME Controller) on Main AE2.
   - **Pattern Dual Interface (`Blocking Mode: ON` + `Advanced Blocking Card`):** On the Main -> `Color 1` ME Dual Interface that holds your AE2 DTPF **Processing Patterns** and pushes ingredients into the `Color 1` On-Demand subnet, enable **`Blocking Mode: ON`** and insert an **`Advanced Blocking Card`** (required so AE2 pushes 1 craft at a time while checking existing subnet contents). Optionally attach a small **`ME Drive`** (`Storage Cell`) on `Color 1` if buffering multiple craft ingredients in the subnet.
   - **On-Demand Hatch/Bus Wiring (`Color 1` White):** Paint your On-Demand `Stocking Input Hatch/Bus (ME)` **Color 1** (`autoPull = ON`) and attach `1` OC Adapter (or MFU) to the `Color 1` **OD Dual Interface**. Because wallshared On-Demand crafts pause the passive queue cleanly, `Color 1` hatches/buses **can sit on wallshared DTPF walls**, or you can wire `1` dedicated On-Demand Dual Interface per DTPF and click **`[ 1:1 PAIR OD ]`** on **Tab 4 (`[4] SETUP`)**.

5. **Why OC Pauses Passives During On-Demand (`On AE2 Craft: [Pause Queue]`)**
   - Painting hatches **Color 1 (OD)** vs **Color 2 (Passive)** keeps *ingredients* separated in their own hatches/buses, **not** the DTPF controller itself — a DTPF can only execute one recipe at a time.
   - When an AE2 autocraft enters **Color 1**, pausing/clearing **Color 2** prevents passive recipes from grabbing the next machine cycle ahead of your AE2 pattern craft (and prevents catalyst/Convergence policy clashes). You can toggle **`[Pause Queue]` / `[Keep Queue ]`** globally in **Tab 2 (`[2] FLEET`)**.

6. **Shared Non-Consumed Aux Subnet (`Color 0` Unpainted)**
   - Put shared non-consumed (NC) items (Programmed Circuits, Lenses, Hypervisor Matrices, Hi-Computation Station T5, Bending Cores) into a small unpainted (**Color 0**) subnet feeding Stocking Input Buses on wallshared or outer faces (`uniformNcSubnet = true` by default).

7. **Optional Catalyst Bridge (OC Transposer)**
   - Sandwich `1` OC **Transposer** between your Main AE2 **ME Dual Interface** and your **Color 1 OD Dual Interface**.
   - When an On-Demand pattern runs without catalyst fluids baked into the pattern, OC tops up the exact catalyst required (and handles warmup discount / Convergence adjustments), while protecting Main AE2 reserve floors.
   - Fluid tank sides are auto-detected or configurable on **Tab 4 (`[4] SETUP` → `[P:...]` / `[OD:...]`)**.

---

## 4. First Boot Sequence

1. Run hardware safety lock & read-only check:
   ```sh
   dtpf --lock    # Locks autoPull = OFF on all passive Stocking Hatches & Buses
   dtpf --check   # Raw Inputs -> Scheduler Decisions -> Dry-Run Outputs check
   ```
2. Launch the GUI:
   ```sh
   dtpf
   ```
   - Fresh installs boot safely in **`[○ PAUSED: SAFE]`** mode (zero machine/hatch mutations) and write `/home/dtpf/config.cfg`.
   - Open **Tab 4 (`[4] SETUP`)** to verify `1. DTPFs`, `2. Stock AE2`, `3. Passive (Color 2)`, and `4. On-Demand C1` all read `[OK]`.
   - Check **[1] OVERVIEW** for fleet health, then set reserve floors & recipe targets in **Tab 2 (`[2] FLEET`) / Tab 3 (`[3] RECIPES`)** and click **`[○ PAUSED: SAFE]` → `[● ARMED: AUTO]`**.

---

## 5. Stock GTNH vs. Optional `DriverDTPF` OC Patch

| Capability | Stock GTNH 2.9 (`gt_machine`) | Patched `DriverDTPF` OC Driver |
| :--- | :--- | :--- |
| Work control (`setWorkAllowed`), Passive stocking, OD preemption, Coil/Warmup readout | Fully supported | Fully supported |
| Reading live Convergence status via `getSensorInformation()` | Supported (read-only) | Supported |
| Programmatic Convergence & Catalyst Tier toggling (`setConvergenceEnabled`) | **Graceful Manual Fallback** | Automated (`Auto @50%`, `Always`, `OFF`) |

If no custom `DriverDTPF` OC patch is present on your server/modpack:
- **Never fatal:** OC detects missing driver methods cleanly and skips `setConvergenceEnabled` writes.
- UI controls display **`[Manual (No OC Patch)]`** / **`[Manual]`**.
- Toggle Convergence directly inside the **DTPF GUI in-world** — OC detects your live setting via Computronics sensor lines and adjusts catalyst handling automatically (including avoiding catalyst injection on catalyst-free `NONE` recipes when Convergence is OFF).

---

## 6. UI Quick Reference & Icon Legend

### 4-Tab Control Center Layout
- **`[1] OVERVIEW`:** Single-screen health banner, fleet summary, queue breakdown, active/blocked recipes, catalyst/DTR reserve bars, and recent activity feed with 1-click drill-down links.
- **`[2] FLEET`:** Per-DTPF live cards (or `[Compact]` 14-unit table), Global Settings, and the reorderable Priority Queue.
- **`[3] RECIPES`:** All 27 deduplicated DTPF families, modifier/output variants, stock/guard floors, and 1-click per-DTPF pinning.
- **`[4] SETUP`:** Catalyst/DTR reserve floors, hardware auto-discovery, `[ 1:1 PAIR DTPFS ]`, `[ 1:1 PAIR OD ]`, and Transposer side selection.

### Recipe Symbols & Category Icons (**Tab 2 (`FLEET`)** / **Tab 3 (`RECIPES`)**)
| Symbol / Text | Meaning |
| :--- | :--- |
| **`08*`** | **24/7 Continuous Loop** (keeps running indefinitely once higher-priority `<Target` jobs are full) |
| **`◆`** | **Pinned** directly to one or more specific DTPFs |
| **`◈`** *(cyan)* | **Fluid** output recipe |
| **`▣`** *(gold)* | **Item** output recipe |
| **`⊕`** *(green)* | **Hybrid** (outputs both Fluid + Item) |

### Telemetry, Stage Logs & Raw I/O Inspector
- **Warmup Display (`Disc:26% (3.8h)`):** Exact remaining time until the DTPF reaches its maximum `50%` catalyst fuel discount (`576,000` active ticks = `8.0` hours at `20` ticks/sec).
- **Coil Display (`Eternal`, `Hypogen`, `Infinity`, etc.):** Click any coil readout (or press **`[K]`**) to switch between GTNH Coil Tier Names and Kelvin (`13500K`).
- **Structured Log Modal (`[Log:N]` / `[! N Alert]`, hotkey `[L]`):**
  - **`[1: Activity Log]`:** 64-entry RAM rolling log tagged by stage (**`[IN ]`** AE2/DTPF/OD telemetry, **`[DEC]`** scheduler assignments & milestones, **`[OUT]`** Hatch/Bus/Work/Conv/Transposer writes, **`[WRN]`** alerts) with stage filter pills (`ALL/IN/DEC/OUT/WARN`) and 1-click `[Inspect →]` / `[Focus →]` navigation.
  - **`[2: Raw I/O Snapshot]`:** On-demand live inspector showing exact Raw Inputs (`DTEC`, `DTR`, active DTPFs), Scheduler Decisions (`Queue`, per-channel assignment + reason), and exact Hatch fluid / Bus item slots currently written (`ch1..chN`).
  - **Verbosity (`[Quiet]` / `[Normal]` / `[Raw]`, hotkey `[V]`):** `Normal` (default) adds `0` steady-state overhead and records transitions/hardware writes; `Quiet` records only warnings, target-met milestones, and Convergence toggles; `Raw` captures full `[IN]`/`[DEC]`/`[OUT]` triplets on every live poll (`3s` default).

![Structured [IN] / [DEC] / [OUT] Activity Log & Verbosity Controls](screenshots/gui_log_modal.png)

### Keyboard Shortcuts
`[1]` Overview · `[2]` Fleet · `[3]` Recipes · `[4]` Setup · `[` / `]` Select DTPF · `[P]` Pin Modal · `[L]` Log & Raw I/O Modal (`[1]/[2]` View, `[V]` Verbosity, `[PgUp/PgDn]`) · `[K]` Coil Name/Kelvin · `[C]` Compact Fleet · `[A]` Animations · `[R]` Rescan Hardware · `[Q]` Save & Quit.

---

## 7. Included Tooling (`tools/` & Recipe Manifest)

Both the **compiled recipe manifest** and the **Python extractor that generated it** are included in this repo:

| File | Purpose |
| :--- | :--- |
| [`lib/recipes_db.lua`](lib/recipes_db.lua) | Single-source-of-truth manifest of **all 78 GTNH 2.9 DTPF recipes** collapsed into **27 deduplicated families** (`DTCC`–`DTSC` & `NONE` variants, modifiers, EU/t, coil heat, duration, DTR balance). |
| [`tools/extract_dtpf_recipes.py`](tools/extract_dtpf_recipes.py) | Standalone bytecode extractor (`javap` over `DTPFRecipes`, `PlasmaForgeRecipes`, `RecipeLoader2`) that regenerates `lib/recipes_db.lua` for future GTNH updates (`python3 tools/extract_dtpf_recipes.py --mods-dir <path/to/mods>`). |
| [`tools/test_offline.py`](tools/test_offline.py) | Offline **Lua 5.3 + OpenComputers `JNLua`** regression suite (`19` suites + live heap audit) with `160x50` framebuffer emulation, width-1 Unifont glyph audit, strict `_G` undeclared-global trap, stock-GTNH unpatched mode test, and `install.lua` update/rollback/backup tests. |
| [`DESIGN.md`](DESIGN.md) | Detailed multi-server scaling, AE2 Storage-Bus topology notes, and internal scheduler design reference. |
