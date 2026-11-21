# Upstream Credits & Attribution

`OC-gtnh-control` builds upon open-source scripts and automation patterns shared by the GregTech: New Horizons community:

- **`gtnh-ae2-control/`** — Built on **UncountablyInfinite**'s [`oc-influxdb-exporter`](https://gitlab.com/uncountablyinfinite1056/oc-influxdb-exporter) (which in turn credits `fourk` on the GTNH Discord for loop structure and OC Crop Bot for event handling).
- **`gtnh-space-pump/`** — Built on **Fox**, **samsonsin**, and **San32**'s [`GTNH-OC-Space-Pumping`](https://github.com/samsonsin/GTNH-OC-Space-Pumping) & GTNH Wiki 2.9 guide.
- **`gtnh-universal-control/`** — Toggle Bus Universal Automation architecture inspired by community builds (**kuba6000**, **Telling Salamander**), alongside OC automation patterns from **Vlamonster** ([`Vlamonster/universal`](https://github.com/Vlamonster/universal)) and **S4mpsa** ([`S4mpsa/InfOS`](https://github.com/S4mpsa/InfOS)).
- **`gtnh-gorge-control/`** — Multi-Exoticizer IO Port + Drive Transposer design inspired by **Navatusein** ([`Navatusein/GTNH-OC-God-Forge-Control`](https://github.com/Navatusein/GTNH-OC-God-Forge-Control)).
- **`gtnh-stock-control/`** — Clean-room standalone implementation taking conceptual inspiration and UX/O(1) AE2 patterns from community OpenComputers stock maintainers:
  - **S4mpsa** (`S4mpsa/InfOS`, [`Programs/Autostocker/`](../references/universal_automation/s4mpsa_infos/Programs/Autostocker/), no explicit license file in upstream repo) — AE2 autostocker pattern.
  - **NIDAS** (`NIDAS` `autostocker.lua`, [`nidas/`](../references/nidas/)) — Drop-in Transposer slot + interactive configuration UX.
  - **DylanTaylor1** ([`DylanTaylor1/GTNH-Stocking`](https://github.com/DylanTaylor1/GTNH-Stocking), MIT License) — O(1) AE2 `getItemInNetwork` / `getFluidInNetwork` lookup concepts.
  - **KaseiFR** ([`KaseiFR/ae2-manager`](https://github.com/KaseiFR/ae2-manager), GPL-3.0 upstream reference; no upstream code copied) — Multi-page/grouped AE2 level-maintaining concepts.
- **`gtnh-bhc-control/`** — Clean-room implementation inspired conceptually by **Navatusein** ([`Navatusein/GTNH-OC-Black-Hole-Control`](https://github.com/Navatusein/GTNH-OC-Black-Hole-Control), MIT License) including SpaceTime decay holding and "Save Recipe Mode", paired with GTNH 2.9.0 Black Hole Utility Hatch pulse/static sync.
- **`gtnh-nanoforge-control/`** — Clean-room Tier 4 Nano Forge automation informed by **GTNH Wiki** ([`Nano Forge`](https://wiki.gtnewhorizons.com/wiki/Nano_Forge), CC BY-SA 4.0) and GTNH 2.9.0 `MTENanoForge` / `NaniteChain` bytecode mechanics.
