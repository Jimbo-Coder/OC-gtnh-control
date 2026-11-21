-- /home/nanoforge/config.example.lua
-- Example initial configuration for GTNH Tier 4 Nano Forge Controller (`gtnh-nanoforge-control`).
return {
    armed = false,
    pollSec = 2,
    extLinkMode = "auto",
    autoWake = true,
    forgeTier = 4,             -- 1..4 (4 = Eternity Nanite unlocked)
    mode = "both",             -- "both" | "od_only" | "passive_only"
    t3MinPerfectOc = true,     -- Automatically bump T3 recipes to >=2 parallels (4/4 Perfect OC)
    allowBootstrap1x = true,   -- Allow 1x run (0L Magmatter) when output nanite stock == 0
    autoSweepForeign = true,   -- Sweep foreign nanites out before dispatching next recipe
    magmatterReserveL = 10000, -- Keep minimum molten.magmatter in reserve
    defaultMaxParallel = 16,
}
