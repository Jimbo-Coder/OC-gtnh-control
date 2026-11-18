-- Scaffolded configuration schema for future gtnh-gorge-control module.
return {
    armed = false,
    pollIntervalSec = 1.0,
    extLinkMode = "auto", -- "auto" | "off" (Standalone)

    godforge = {
        controllerAddr = nil, -- Optional Adapter / Wireless MFU UUID on Forge of the Gods controller
        onDemandEnable = false,
        minLscPct = 20,
    },

    -- Merge multiple Heliofusion Exoticizers into one OC Server Rack:
    exoticizers = {
        {
            id = 1,
            name = "Exoticizer #1",
            mode = "magmatter", -- "magmatter" | "gluon" | "auto"
            outputMeInterfaceAddress = nil,
            inputMeInterfaceAddress = nil,
            transposerAddress = nil,
            meIoPortSide = 5,   -- East
            meDriveSide = 4,    -- West
            redstoneIoAddress = nil,
            redstoneIoSide = 0, -- Down
        },
        {
            id = 2,
            name = "Exoticizer #2",
            mode = "gluon",
            outputMeInterfaceAddress = nil,
            inputMeInterfaceAddress = nil,
            transposerAddress = nil,
            meIoPortSide = 5,
            meDriveSide = 4,
            redstoneIoAddress = nil,
            redstoneIoSide = 0,
        },
    },
}
