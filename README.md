# GTNH DTPF Automation Controller (OpenComputers)

A self-configuring **OpenComputers (Lua 5.3 / OpenOS)** controller for automating **Dimensionally Transcendent Plasma Forges (DTPFs)** in **GregTech: New Horizons 2.9+**.

Handles passive AE2 stock targets, 24/7 loops, **AE2 On-Demand autocrafting priority**, optional Convergence automation, Coil Tier & 8h warmup tracking, DTR/catalyst reserve floors, and an optional Transposer catalyst bridge in a 4-tab `160x50` touch GUI.

### `[1] OVERVIEW` — Health, Fleet, Queue, Reserves & Activity
![Overview Tab](screenshots/gui_overview.png)

### `[2] FLEET` — Per-DTPF Cards, Global Policy & Priority Queue
![Fleet Tab](screenshots/gui_fleet.png)

---

## 1. Install & Update

Run on OpenOS from `/home` with an **Internet Card**:

```sh
wget -f https://raw.githubusercontent.com/Jimbo-Coder/gtnh-dtpf-control/main/install.lua && install
```

- **Safe update (settings untouched):** `dtpf --update` stages files as `.tmp`, validates syntax with `load()`, and aborts cleanly on error.
- **Survives folder wipes:** Settings save to `/home/dtpf/config.cfg` and auto-mirror to `/home/config.dtpf.bak` (restored automatically on reinstall).
- **No Internet Card:** Copy the repo folder to OpenOS (e.g. `/home/dtpf_src`) and run `/home/dtpf_src/install.lua --local /home/dtpf_src`.

---

## 2. OC Requirements & DTPF Scaling

**Minimum OC parts:** **Tier 3 CPU (or APU) in Lua 5.3** (`Sneak + Right-Click` in hand), **`2x` Memory Tier 3.5**, **HDD Tier 2 (`2 MB`) + OpenOS**, **Tier 3 GPU + Screen (`160x50`)**, optional **Internet Card**.

| OC Setup | Component Limit | Max DTPFs (`3` MFUs/DTPF) | Notes |
| :--- | :--- | :--- | :--- |
| **Tier 3 Computer Case** | `16` | **Up to `2` DTPFs** | Starter case (`6` DTPF MFUs + display/HDD/AE2). |
| **1x Tier 3 Server** *(in a Rack)* | `64` *(w/ 3x Bus T3)* | **Up to `~18` DTPFs** | Single-server sweet spot (`54` DTPF MFUs + AE2/screen). |
| **1x Full Server Rack** *(1 Master + 3 `--worker` Servers)* | `4 x 64 = 256` | **Up to `~78` DTPFs from 1 Rack** | Keep each Server's Adapter I/O face separate; link only their Network Card lines via **Rack Relay Mode** (`+20` DTPFs per headless `--worker`). |
| **Multiple Server Racks** | `+256` / Rack | **`80–150+` DTPFs** | Already supported: bridge Rack Relay faces over an OC Cable (see [`DESIGN.md`](DESIGN.md)). |

---

## 3. Simple Physical Setup

Everything is auto-discovered by component type and 3D coordinates — **no manual UUID config needed**.

1. **`Color 2` (Orange) — Passive (`1` Stocking Hatch + `1` Stocking Bus per DTPF, never wallshared):**
   Wire straight to your **Main AE2 net** (`autoPull = OFF` — run `dtpf --lock` before connecting). Bind **`3` Wireless MFUs** per DTPF (`Controller` + `Color 2 Hatch` + `Color 2 Bus`) and put them in Adapters back at your OC Rack (`0` OC blocks touching your DTPFs).
2. **`Color 1` (White) — On-Demand AE2 Patterns *(wallsharable)*:**
   Main AE2 Pattern Dual Interface (**`Blocking Mode: ON` + `Advanced Blocking Card`**) pushing into an isolated **Color 1** subnet feeding `Color 1` Stocking Hatch + Bus on the DTPFs. Whenever an AE2 craft enters `Color 1`, OC automatically pauses passives so your pattern runs next.
3. **`Color 0` (Unpainted) — Shared Non-Consumed Items *(wallsharable)*:**
   Small unpainted subnet holding shared Programmed Circuits, Lenses, Hypervisor Matrices, Hi-Computation Station T5, and Bending Cores.
4. **AE2 Readers (+ Optional Transposer Catalyst Bridge):**
   Put `1` Adapter/MFU on an unfiltered **Main Dual IF** (reads stocks) and `1` on the **Color 1 OD Dual IF** (detects crafts). Optionally sandwich `1` **OC Transposer** between them so OC tops up catalysts automatically for patterns without catalyst fluids.

![AE2 Subnets and Transposer Bridge](screenshots/ae2_subnets_and_bridge.png)
![DTPF Wallsharing Layout](screenshots/dtpf_wallsharing_underside.png)
![Wireless MFU Adapter Room](screenshots/oc_wireless_mfu_room.png)

---

## 4. First Boot

```sh
dtpf --lock    # Locks autoPull = OFF on passive Stocking Hatches/Buses
dtpf --check   # Read-only Raw Inputs -> Decisions -> Outputs diagnostic
dtpf           # Launch 160x50 GUI (starts safely in PAUSED mode)
```

Verify **`[4] SETUP`** shows `[OK]`, set stock targets in **`[3] RECIPES`** / **`[2] FLEET`**, then click **`[○ PAUSED: SAFE]` -> `[● ARMED: AUTO]`**.

---

## 5. Convergence Control (Stock GTNH 2.9 vs. OC PR #228)

- **Stock GTNH 2.9 (`gt_machine`):** Works out of the box — full passive scheduling, On-Demand priority, Work control, Coil/Warmup tracking, and live Convergence status reading (toggle Convergence manually inside the DTPF GUI).
- **Automated Convergence & Catalyst Tier switching (`Auto @50%`, `Always`, `OFF`):** Supported automatically when using an OpenComputers build with **[GTNewHorizons/OpenComputers#228](https://github.com/GTNewHorizons/OpenComputers/pull/228)** (`DriverDTPF`).

---

## 6. UI, Logs & Tooling

- **4 Tabs (`[1-4]`):** **`[1] OVERVIEW`** · **`[2] FLEET`** · **`[3] RECIPES`** (27 deduplicated families) · **`[4] SETUP`** (`[1:1 PAIR DTPFS]`, `[1:1 PAIR OD]`, Reserve Floors).
- **`[Log]` (`[L]`):** Structured **`[IN ]` / `[DEC]` / `[OUT]` / `[WRN]`** Activity Log + live **`Raw I/O Snapshot`** inspector with **`[Quiet]` / `[Normal]` / `[Raw]`** verbosity (`[V]`).

![Activity Log Modal](screenshots/gui_log_modal.png)

| Resource | Purpose |
| :--- | :--- |
| [`DESIGN.md`](DESIGN.md) | Multi-server / Multi-Rack wiring, Storage-Bus subnet alternative, full UI/hotkey & scheduler docs. |
| [`lib/recipes_db.lua`](lib/recipes_db.lua) / [`tools/extract_dtpf_recipes.py`](tools/extract_dtpf_recipes.py) | Compiled manifest + bytecode extractor for all `78` GTNH 2.9 DTPF recipes across `27` families. |
| [`tools/test_offline.py`](tools/test_offline.py) | `19`-suite offline Lua 5.3 + `JNLua` regression test, width-1 Unifont glyph audit & memory check. |
| [`LICENSE`](LICENSE) | MIT License. |
