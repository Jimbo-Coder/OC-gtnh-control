-- Copy to /home/config.lua (created automatically by install.lua on fresh installs; preserved on updates).
local config = {
    -- InfluxDB (set enableItems/enableFluids/etc. to false if using purely as an in-game OC Mesh Hub)
    dbHostname = "http://127.0.0.1:8086",
    dbUseAuth = false,
    dbToken = "",
    dbEndpoint = "/write?db=",

    -- Items
    enableItems = true,
    itemDB = "mainnet",
    itemMeasurement = "items",
    itemInterval = 65,
    itemThreshold = 500,
    itemMaxExport = 1000,
    allItemsMode = 5, -- 5 = getItemsInNetworkById batched (safe for Tier 3 RAM)
    allItemsInterval = 1800,
    maxID = 12000,
    batchSize = 1000,
    slowRange = {250, 320},
    slowBatchSize = 5,

    -- Fluids
    enableFluids = true,
    fluidDB = "mainnet",
    fluidMeasurement = "fluids",
    fluidInterval = 55,
    fluidThreshold = 0,

    -- Essentia
    enableEssentia = true,
    essentiaDB = "mainnet",
    essentiaMeasurement = "essentia",
    essentiaInterval = 60,
    essentiaThreshold = 0,

    -- Energy (LSC + Wireless EU)
    enableEnergy = true,
    energyDB = "mainnet",
    energyMeasurement = "energy",
    energyInterval = 10,
    enableWireless = true,

    -- AE2 Energy
    enableEnergyAE2 = false,
    energyAE2DB = "mainnet",
    energyAE2Measurement = "ae2energy",
    energyAE2Interval = 10,
    energyAE2ExportAsEU = true,

    -- Crafting CPUs
    enableCpus = true,
    cpuDB = "mainnet",
    cpuMeasurement = "cpus",
    cpuInterval = 20,

    -- TPS
    enableTps = true,
    tpsDB = "mainnet",
    tpsMeasurement = "tps",
    tpsInterval = 5,
    detailedTps = true,

    -- AE2 Storage / Drives
    enableStorage = true,
    storageInterval = 60,

    -- Optional Out-of-Game Web Console TCP Bridge (set true only if running ae2_bridge.py)
    enableBridge = false,
    bridgeHost = "127.0.0.1",
    bridgePort = 8766,
    bridgeReconnectSec = 10,

    -- Optional In-Game OC Wireless / Wired Mesh (port 4205 -> DTPF, Space Pump, Universal, Gorge)
    enableMesh = true,
    meshPort = 4205,

    -- Misc
    enableLogging = true,
    enableDebug = false,
    enableResilience = true,
}

config.dbURL = config.dbHostname .. config.dbEndpoint
config.itemInterval = config.itemInterval * 72
config.fluidInterval = config.fluidInterval * 72
config.essentiaInterval = config.essentiaInterval * 72
config.energyInterval = config.energyInterval * 72
config.energyAE2Interval = config.energyAE2Interval * 72
config.cpuInterval = config.cpuInterval * 72
config.tpsInterval = config.tpsInterval * 72
config.storageInterval = (config.storageInterval or 60) * 72
config.allItemsInterval = config.allItemsInterval * 72
config.bridgeReconnectTicks = (config.bridgeReconnectSec or 10) * 72

return config
