-- /home/bhc/config.example.lua
-- Example initial configuration for GTNH Black Hole Compressor Controller (`gtnh-bhc-control`).
return {
    armed = false,
    pollSec = 1,
    extLinkMode = "auto",
    autoWake = true,
    preset = "balanced",         -- "balanced" | "throughput" | "save_seeds" | "save_spacetime" | "superstable"
    seedMode = "pseudostable",   -- "pseudostable" | "supermassive" | "superstable"
    utilityMode = "pulse",       -- Match Black Hole Utility Hatch mode ("pulse" | "static")
    keepOpen = false,
    targetStability = 15,        -- Halt decay once inside <20% (4x parallels) zone
    collapseFloor = 5,           -- Mandatory Collapser injection before 0% void point
    maxHoldSec = 150,            -- Max total SpaceTime hold time per cycle (0 = zero SpaceTime)
    maxStPerSec = 128,           -- Stop holding when doubling exceeds this L/s rate
    idleCollapseSec = 30,        -- Collapse if idle longer than this (unless keepOpen = true)
    minSpacetimeReserve = 2000,
    spacetimeValveMode = "redstone", -- "redstone" (Export Bus redstone card) | "transposer"
    requireCollapserReserve = true,
    isBlackHoleRecipe = true,
    saveRecipeMode = true,       -- Hold SpaceTime only as needed to keep active crafts from voiding
    maxSaveRecipeCycles = 27,    -- Max 30s SpaceTime doubling cycles in Save Recipe Mode (27 = 810s)
}
