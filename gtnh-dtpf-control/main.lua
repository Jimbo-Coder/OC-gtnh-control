-- /home/dtpf/main.lua
-- Entrypoint for GTNH 2.9+ OpenComputers DTPF Automation Controller
-- Usage:
--   dtpf          Launch clickable 160x50 Control Center GUI (starts PAUSED on fresh config)
--   dtpf --check  Run read-only hardware, AE2 stock, and scheduler dry-run check
--   dtpf --help   Print usage help

local cliArgs = { ... }

local event = require("event")
local filesystem = require("filesystem")
local serialization = require("serialization")
local computer = require("computer")
local component = require("component")
local term = require("term")

-- Resolve script root directory cleanly across OpenOS wrapped `debug.getinfo` and direct Lua hosts
local function resolveScriptDir()
    local function checkCandidate(rawPath)
        if type(rawPath) ~= "string" or rawPath == "" then return nil end
        local dir = filesystem.path(filesystem.canonical(rawPath))
        if type(dir) ~= "string" or dir == "" then return nil end
        dir = dir:gsub("/+$", "")
        if dir == "" then dir = "/" end
        if filesystem.exists(filesystem.concat(dir, "lib/hardware.lua")) then
            return dir
        end
        return nil
    end

    if os and os.getenv then
        local envDir = checkCandidate(os.getenv("_"))
        if envDir then return envDir end
    end

    if debug and debug.getinfo then
        for level = 1, 5 do
            local ok, info = pcall(debug.getinfo, level, "S")
            if ok and type(info) == "table" and type(info.source) == "string" then
                local prefix = info.source:sub(1, 1)
                if prefix == "@" or prefix == "=" then
                    local infoDir = checkCandidate(info.source:sub(2))
                    if infoDir then return infoDir end
                end
            end
        end
    end

    if filesystem.exists("/home/dtpf/lib/hardware.lua") then
        return "/home/dtpf"
    end
    local pwd = (os and os.getenv and os.getenv("PWD")) or ""
    if pwd ~= "" then
        local pwdRepo = filesystem.concat(pwd, "gtnh-dtpf-control")
        if filesystem.exists(filesystem.concat(pwdRepo, "lib/hardware.lua")) then
            return pwdRepo
        end
        local pwdSub = filesystem.concat(pwd, "dtpf")
        if filesystem.exists(filesystem.concat(pwdSub, "lib/hardware.lua")) then
            return pwdSub
        end
        if filesystem.exists(filesystem.concat(pwd, "lib/hardware.lua")) then
            return pwd
        end
    end
    return "/home/dtpf"
end

local scriptDir = resolveScriptDir()
local searchPat = filesystem.concat(scriptDir, "?.lua")
local commonPat = "/usr/lib/?.lua"
local localCommonPat = filesystem.concat(scriptDir, "../common/?.lua")
if not package.path:find(searchPat, 1, true) then
    package.path = searchPat .. ";" .. package.path
end
if not package.path:find(commonPat, 1, true) then
    package.path = package.path .. ";" .. commonPat
end
if not package.path:find(localCommonPat, 1, true) then
    package.path = package.path .. ";" .. localCommonPat
end

for _, modName in ipairs({ "gtnh_common", "lib.hardware", "lib.scheduler", "lib.recipes_db", "lib.ui", "lib.web_bridge" }) do
    package.loaded[modName] = nil
end

local okCommon, Common = pcall(require, "gtnh_common")
if not okCommon then
    local instPath = filesystem.concat(scriptDir, "install.lua")
    local ch = loadfile and loadfile(instPath) or nil
    if not ch and io and io.open then
        local f = io.open(instPath, "r")
        if f then local src = f:read("*a"); f:close(); ch = load(src, "=" .. instPath) end
    end
    if ch then
        pcall(ch, "--update", "--yes", "--no-prompt")
        package.loaded["gtnh_common"] = nil
        okCommon, Common = pcall(require, "gtnh_common")
        if not okCommon then
            pcall(ch, "--local-bridge", "--update", "--yes", "--no-prompt")
            package.loaded["gtnh_common"] = nil
            okCommon, Common = pcall(require, "gtnh_common")
        end
    end
    if not okCommon then
        error("Missing /usr/lib/gtnh_common.lua: " .. tostring(Common))
    end
end
local Hardware = require("lib.hardware")
local Scheduler = require("lib.scheduler")
local RecipesDB = require("lib.recipes_db")
local UI = require("lib.ui")
local WebBridge = require("lib.web_bridge")

local CONFIG_PATH = filesystem.concat(scriptDir, "config.cfg")
local BACKUP_CONFIG_PATH = "/home/config.dtpf.bak"

local function parseConfigRaw(raw)
    if type(raw) ~= "string" or raw == "" then return nil end
    local env = { math = { huge = math.huge } }
    local chunk = load("return " .. raw, "=config.cfg", "t", env)
    if not chunk then
        chunk = load(raw, "=config.cfg", "t", env)
    end
    if chunk then
        local ok, data = pcall(chunk)
        if ok and type(data) == "table" then
            return Scheduler.ensureConfig(data)
        end
    end
    local okS, dataS = pcall(serialization.unserialize, raw)
    if okS and type(dataS) == "table" then
        return Scheduler.ensureConfig(dataS)
    end
    return nil
end

local function loadConfig()
    local f = io.open(CONFIG_PATH, "r")
    if f then
        local raw = f:read("*a")
        f:close()
        local parsed = parseConfigRaw(raw)
        if parsed then
            return parsed, true
        end
    elseif CONFIG_PATH == "/home/dtpf/config.cfg" then
        local bf = io.open(BACKUP_CONFIG_PATH, "r")
        if bf then
            local braw = bf:read("*a")
            bf:close()
            local parsed = parseConfigRaw(braw)
            if parsed then
                pcall(function()
                    filesystem.makeDirectory("/home/dtpf")
                    local rf = io.open(CONFIG_PATH, "w")
                    if rf then rf:write(braw); rf:close() end
                end)
                return parsed, true
            end
        end
    end
    return Scheduler.ensureConfig({}), false
end

local function fmtLuaAtom(v)
    local t = type(v)
    if t == "string" then
        return (string.format("%q", v):gsub("\\\n", "\\n"))
    elseif t == "boolean" then
        return v and "true" or "false"
    elseif t == "number" then
        if v == math.huge then return "math.huge" end
        if v == -math.huge then return "-math.huge" end
        if v == math.floor(v) then
            return string.format("%d", v)
        end
        return tostring(v)
    end
    return "nil"
end

local function saveConfig(cfg)
    Scheduler.syncSubnetsStruct(cfg)

    local channels = cfg.channels or {}
    local chById = {}
    for i = 1, #channels do
        chById[channels[i].id] = channels[i]
    end

    -- Omit redundant top-level `channels` section when every DTPF maps 1:1 to a `hatch_pair` channel
    local dtpfs = cfg.dtpfs or {}
    local is1to1Mfu = (#dtpfs > 0) and (#channels == #dtpfs)
    if is1to1Mfu then
        local seenCh = {}
        for i = 1, #dtpfs do
            local d = dtpfs[i]
            local ch = chById[d.channelId]
            if not ch or ch.mode ~= "hatch_pair" or ch.id ~= ("ch" .. tostring(i)) or seenCh[ch.id] then
                is1to1Mfu = false
                break
            end
            seenCh[ch.id] = true
        end
    end

    local lines = {}
    local function add(s) lines[#lines + 1] = s end
    local function addKV(indent, key, val)
        if val ~= nil then
            add(string.format("%s%s = %s,", indent, key, fmtLuaAtom(val)))
        end
    end

    add("-- GTNH 2.9.0 DTPF Automation Controller Configuration")
    add("-- Organized by Subnets (Passive / On-Demand / Transposer) and per-DTPF hardware triplets.")
    add("{")
    add("  -- 1. SUBNETS & TRANSPOSER CATALYST BRIDGE")
    add("  -- passive.transposerSide : side facing Passive/Stock Dual IF (1 = UP)")
    add("  -- onDemand.transposerSide: side facing On-Demand Dual IF     (0 = DOWN)")
    add("  subnets = {")
    add("    passive = {")
    addKV("      ", "interfaceAddr", cfg.stockNetAddr)
    addKV("      ", "transposerSide", cfg.stockTransposerSide or 1)
    add("    },")
    add("    onDemand = {")
    addKV("      ", "interfaceAddr", cfg.onDemandNetAddr)
    addKV("      ", "transposerSide", cfg.odTransposerSide or 0)
    add("    },")
    add("    transposer = {")
    addKV("      ", "address", cfg.transposerAddr)
    addKV("      ", "enabled", (cfg.transposerEnabled ~= false))
    addKV("      ", "chunkLiters", cfg.transposerChunkLiters or 5120)
    addKV("      ", "autoFlushPolls", cfg.odAutoFlushPolls or 0)
    add("    },")
    add("  },")
    add("")

    add("  -- 2. PER-DTPF HARDWARE ADDRESSES & OVERRIDES")
    add("  dtpfs = {")
    for i = 1, #dtpfs do
        local d = dtpfs[i]
        local ch = chById[d.channelId]
        add(string.format("    [%d] = {", i))
        addKV("      ", "name", d.name or ("DTPF #" .. i))
        if d.x ~= nil or d.y ~= nil or d.z ~= nil then
            add(string.format("      coords = { x = %s, y = %s, z = %s },",
                fmtLuaAtom(d.x or 0), fmtLuaAtom(d.y or 0), fmtLuaAtom(d.z or 0)))
        end
        addKV("      ", "address", d.address)
        if is1to1Mfu and ch then
            addKV("      ", "passiveHatchAddr", ch.hatchAddr)
            addKV("      ", "passiveBusAddr", ch.busAddr)
        end
        addKV("      ", "channelId", d.channelId or "ch1")
        addKV("      ", "enabled", (d.enabled ~= false))
        addKV("      ", "roleOverride", d.roleOverride or "auto")
        addKV("      ", "convOverride", d.convOverride or "global")
        addKV("      ", "catOverride", d.catOverride or 0)
        if d.pinnedFamilyId then
            addKV("      ", "pinnedFamilyId", d.pinnedFamilyId)
        end
        addKV("      ", "odNetAddr", d.odNetAddr or "global")
        if is1to1Mfu and ch then
            addKV("      ", "shareOnDemand", (ch.shareOnDemand ~= false))
            if ch.enabled == false then
                addKV("      ", "channelEnabled", false)
            end
        end
        add("    },")
    end
    add("  },")

    if not is1to1Mfu and #channels > 0 then
        add("")
        add("  -- PASSIVE CHANNELS (Shared or StorageBus Mode)")
        add("  channels = {")
        for i = 1, #channels do
            local ch = channels[i]
            add(string.format("    [%d] = {", i))
            addKV("      ", "id", ch.id)
            addKV("      ", "name", ch.name)
            addKV("      ", "mode", ch.mode)
            addKV("      ", "hatchAddr", ch.hatchAddr)
            addKV("      ", "busAddr", ch.busAddr)
            addKV("      ", "itemStorageAddr", ch.itemStorageAddr)
            addKV("      ", "itemStorageSide", ch.itemStorageSide)
            addKV("      ", "fluidStorageAddr", ch.fluidStorageAddr)
            addKV("      ", "fluidStorageSide", ch.fluidStorageSide)
            addKV("      ", "shareOnDemand", (ch.shareOnDemand ~= false))
            addKV("      ", "enabled", (ch.enabled ~= false))
            add("    },")
        end
        add("  },")
    end

    add("")
    add("  -- 3. GLOBAL POLICY & RESERVE FLOORS")
    addKV("  ", "armed", (cfg.armed == true))
    addKV("  ", "pollInterval", cfg.pollInterval or 2.0)
    addKV("  ", "globalConvMode", cfg.globalConvMode or "auto")
    addKV("  ", "fallbackConvMode", cfg.fallbackConvMode or "global")
    addKV("  ", "onDemandConvMode", cfg.onDemandConvMode or "auto_safe")
    addKV("  ", "pausePassivesOnOD", (cfg.pausePassivesOnOD ~= false))
    addKV("  ", "odAutoFlushPolls", cfg.odAutoFlushPolls or 0)
    addKV("  ", "defaultCatalystTier", cfg.defaultCatalystTier or 4)
    addKV("  ", "catalystAutoFallback", (cfg.catalystAutoFallback ~= false))
    addKV("  ", "uniformNcSubnet", (cfg.uniformNcSubnet ~= false))
    addKV("  ", "dtrReserveFloor", cfg.dtrReserveFloor or 10000000)
    add("  catalystFloors = {")
    for i = 1, #RecipesDB.CATALYST_TIERS do
        local code = RecipesDB.CATALYST_TIERS[i].code
        local fl = cfg.catalystFloors and cfg.catalystFloors[code]
        addKV("    ", code, fl or 100000)
    end
    add("  },")
    addKV("  ", "fallbackEnabled", (cfg.fallbackEnabled ~= false))
    addKV("  ", "fallbackFamilyId", cfg.fallbackFamilyId or "molten_infinity")
    addKV("  ", "allowParallelSameRecipe", (cfg.allowParallelSameRecipe == true))
    addKV("  ", "powerAwareAssign", (cfg.powerAwareAssign ~= false))
    addKV("  ", "maintEnabled", (cfg.maintEnabled == true))
    addKV("  ", "maintFreeCpus", tonumber(cfg.maintFreeCpus) or 2)
    addKV("  ", "maintPollSec", tonumber(cfg.maintPollSec) or 15)
    addKV("  ", "maintConflictMode", cfg.maintConflictMode or "defer")
    addKV("  ", "maintMaxDispatch", tonumber(cfg.maintMaxDispatch) or 2)
    addKV("  ", "mainnetAddr", cfg.mainnetAddr or "auto")
    addKV("  ", "uiAnimations", (cfg.uiAnimations ~= false))
    addKV("  ", "coilDisplayMode", (cfg.coilDisplayMode == "temp") and "temp" or "name")
    addKV("  ", "logLevel", cfg.logLevel or "normal")
    if cfg.authorName and cfg.authorName ~= "StankCIty" then
        addKV("  ", "authorName", cfg.authorName)
    end

    add("")
    add("  -- 4. PASSIVE RECIPE QUEUE (27 FAMILIES, ORDERED BY PRIORITY)")
    add("  recipes = {")
    local recList = {}
    for i = 1, #RecipesDB.FAMILIES do
        local fid = RecipesDB.FAMILIES[i].id
        local rc = (cfg.recipes and cfg.recipes[fid]) or {}
        recList[#recList + 1] = { id = fid, rc = rc, prio = tonumber(rc.priority) or i }
    end
    table.sort(recList, function(a, b)
        if a.prio ~= b.prio then return a.prio < b.prio end
        return a.id < b.id
    end)
    for i = 1, #recList do
        local fid = recList[i].id
        local rc = recList[i].rc
        local maxCapPart = ((tonumber(rc.maxDtpfs) or 0) > 0)
            and (", maxDtpfs = " .. tostring(math.floor(tonumber(rc.maxDtpfs))))
            or ""
        add(string.format(
            "    %s = { enabled = %s, forever = %s, priority = %s, target = %s, modifierIndex = %s, catalystTier = %s, outputIndex = %s, convMode = %s, guardKey = %s, guardMin = %s%s },",
            fid,
            fmtLuaAtom(rc.enabled == true),
            fmtLuaAtom(rc.forever == true),
            fmtLuaAtom(rc.priority or i),
            fmtLuaAtom(rc.target or 1),
            fmtLuaAtom(rc.modifierIndex or rc.variantIndex or 1),
            fmtLuaAtom(rc.catalystTier or 0),
            fmtLuaAtom(rc.outputIndex or 1),
            fmtLuaAtom(rc.convMode or "global"),
            fmtLuaAtom(rc.guardKey or "none"),
            fmtLuaAtom(rc.guardMin or 0),
            maxCapPart
        ))
    end
    add("  },")
    if type(cfg.maintRules) == "table" then
        add("  maintRules = {")
        for _, r in ipairs(cfg.maintRules) do
            if type(r) == "table" and type(r.name) == "string" then
                local lowPart = (tonumber(r.lowThreshold) ~= nil)
                    and (", lowThreshold = " .. tostring(math.floor(tonumber(r.lowThreshold))))
                    or ""
                add(string.format(
                    "    { id = %q, type = %q, name = %q, damage = %d, label = %q, target = %d%s, batch = %d, mode = %q },",
                    tostring(r.id or r.name),
                    (r.type == "fluid") and "fluid" or "item",
                    tostring(r.name),
                    math.floor(tonumber(r.damage) or 0),
                    tostring(r.label or r.name),
                    math.floor(tonumber(r.target) or 0),
                    lowPart,
                    math.floor(tonumber(r.batch) or 1000),
                    tostring(r.mode or "auto")
                ))
            end
        end
        add("  },")
    end
    add("}")

    local body = table.concat(lines, "\n") .. "\n"
    local f = io.open(CONFIG_PATH, "w")
    if f then
        f:write(body)
        f:close()
        if CONFIG_PATH == "/home/dtpf/config.cfg" then
            pcall(function()
                local bf = io.open(BACKUP_CONFIG_PATH, "w")
                if bf then
                    bf:write(body)
                    bf:close()
                end
            end)
        end
        return true
    end
    return false
end

local function printHelp()
    print("GTNH 2.9+ DTPF Automation Controller")
    print("Usage:")
    print("  dtpf           Launch interactive Control Center GUI (auto-saves config.cfg)")
    print("  dtpf --check   Run 100% read-only hardware, AE2 stock & dry-run diagnostic")
    print("  dtpf --lock    Set autoPull=OFF across all passive ME Hatches/Buses and exit")
    print("  dtpf --update  Download latest scripts from GitHub via Internet Card (preserves config.cfg)")
    print("  dtpf --worker  Run headless OC Rack Worker daemon on extra Server(s) (scales to 78+ DTPFs)")
    print("  dtpf --help    Show this help text")
end

local function runCheck()
    local cfg, cfgLoaded = loadConfig()
    local savedArmed = cfg.armed
    cfg.armed = false -- Force read-only mode regardless of saved config

    local nets, ep = Scheduler.syncHardware(cfg)
    local runtimeState = {}
    Scheduler.step(cfg, runtimeState)

    print("=== DTPF AUTOMATION READ-ONLY CHECK ===")
    print(string.format("Config File   : %s (%s)", CONFIG_PATH, cfgLoaded and "exists" or "defaults"))
    print(string.format("Saved State   : %s | Uniform NC Subnet: %s | Log Verbosity: %s",
        savedArmed and "ARMED" or "PAUSED (Safe)", tostring(cfg.uniformNcSubnet), tostring(cfg.logLevel or "normal")))
    print(string.format("Global Policy : Conv=%s | OD=%s | DefaultCat=T%d | AutoFallback=%s | DTRFloor=%s",
        tostring(cfg.globalConvMode),
        tostring(cfg.onDemandConvMode),
        tonumber(cfg.defaultCatalystTier) or 4,
        tostring(cfg.catalystAutoFallback),
        UI.formatNumber(cfg.dtrReserveFloor or 0, true)))
    if (runtimeState.workerCount or 0) > 0 then
        print(string.format("Rack Workers  : %d online (Port %d)", runtimeState.workerCount, Hardware.CLUSTER_PORT))
    end

    print("")
    print("--- [1] RAW INPUTS ---")
    print(string.format("DTPF Controllers (%d discovered):", #cfg.dtpfs))
    for i = 1, #cfg.dtpfs do
        local d = cfg.dtpfs[i]
        local st = runtimeState.dtpfStatus[i] or {}
        print(string.format("  [%d] %s (%s) @ (%s,%s,%s) | Online=%s Work=%s Disc=%.0f%% Coil=%sK Conv=%s",
            i, tostring(d.name), tostring(d.address):sub(1, 8),
            tostring(d.x or "?"), tostring(d.y or "?"), tostring(d.z or "?"),
            tostring(st.online), tostring(st.workAllowed), st.discountPct or 0,
            tostring(st.coilHeat or "?"), tostring(st.convergenceEnabled)))
    end

    print(string.format("AE2 Networks (%d discovered):", #(nets or {})))
    local odOwnerByAddr = {}
    for i = 1, #cfg.dtpfs do
        local d = cfg.dtpfs[i]
        if d.odNetAddr and d.odNetAddr ~= "global" and d.odNetAddr ~= "none" then
            odOwnerByAddr[d.odNetAddr] = odOwnerByAddr[d.odNetAddr]
                and (odOwnerByAddr[d.odNetAddr] .. ",#" .. i)
                or ("#" .. i)
        end
    end
    for i = 1, #(nets or {}) do
        local n = nets[i]
        local role = (n.address == cfg.stockNetAddr and "[STOCK]")
            or (odOwnerByAddr[n.address] and ("[OD " .. odOwnerByAddr[n.address] .. "]"))
            or (n.address == cfg.onDemandNetAddr and "[ON-DEMAND]")
            or "[OTHER]"
        print(string.format("  %s %s (%s): %d items, %d fluids",
            role, n.address:sub(1, 10), tostring(n.type), n.itemTypes or 0, n.fluidTypes or 0))
    end
    local od = runtimeState.onDemand or {}
    print(string.format("  On-Demand Live: hasWork=%s | stalled=%s | hasPatternedCatalyst=%s | summary=%s",
        tostring(od.hasWork), tostring(od.stalled == true), tostring(od.hasPatternedCatalyst), tostring(od.summary)))
    if od.stalled and od.stallReason then
        print("    ! OD Stall Reason: " .. tostring(od.stallReason))
    end

    print("")
    print("--- [2] SCHEDULER DECISIONS ---")
    print("Active Passive Priority Queue (<Tgt and 24/7):")
    if cfg.fallbackEnabled then
        local fbId = cfg.fallbackFamilyId
        local fbSt = runtimeState.recipeStatus[fbId] or {}
        print(string.format("  * Global Fallback (%s): ON -> %s", tostring(fbId), tostring(fbSt.stateStr)))
    end
    if runtimeState.coverageWarning then
        local cw = runtimeState.coverageWarning
        print(string.format("  ! 24/7 Discount Warning: %s - %s", tostring(cw.summary), tostring(cw.reason)))
    end
    local qEnabled = {}
    for i = 1, #RecipesDB.FAMILIES do
        local fam = RecipesDB.FAMILIES[i]
        local rc = cfg.recipes[fam.id]
        if rc and rc.enabled then
            qEnabled[#qEnabled + 1] = { fam = fam, rc = rc }
        end
    end
    table.sort(qEnabled, function(a, b) return (a.rc.priority or 999) < (b.rc.priority or 999) end)
    for idx = 1, #qEnabled do
        local fam, rc = qEnabled[idx].fam, qEnabled[idx].rc
        local st = runtimeState.recipeStatus[fam.id] or {}
        local isFluid = st.trackedOutput and (st.trackedOutput.isFluid or st.trackedOutput.type == "fluid")
        local modeTag = rc.forever and "[24/7]" or "[<Tgt]"
        print(string.format("  #%02d %s %-24s %s / %s -> %s",
            rc.priority or idx, modeTag, fam.name,
            UI.formatNumber(st.currentStock or 0, isFluid),
            rc.forever and "24/7" or UI.formatNumber(rc.target or 1, isFluid),
            tostring(st.stateStr)))
    end

    print("")
    print("--- [3] DRY-RUN OUTPUTS ---")
    print(string.format("Passive Channels (%d):", #cfg.channels))
    for i = 1, #cfg.channels do
        local ch = cfg.channels[i]
        local chSt = runtimeState.channelStatus[ch.id] or {}
        print(string.format("  %s (%s): Preview=[%s] %s",
            ch.id, tostring(ch.mode), tostring(chSt.mode), tostring(chSt.label)))
    end
    local function fmtCheckEu(v)
        v = tonumber(v) or 0
        if v >= 1e12 then return string.format("%.2fT", v / 1e12) end
        if v >= 1e9 then return string.format("%.2fB", v / 1e9) end
        if v >= 1e6 then return string.format("%.1fM", v / 1e6) end
        if v >= 1e3 then return string.format("%.1fk", v / 1e3) end
        return tostring(math.floor(v))
    end
    for i = 1, #cfg.dtpfs do
        local d = cfg.dtpfs[i]
        local st = runtimeState.dtpfStatus[i] or {}
        local hatchStr = st.hatchLabel and (" [" .. tostring(st.hatchLabel) .. "]") or ""
        local eutStr = (tonumber(st.totalEut) or 0) > 0
            and (" " .. (st.eutIsEstimate ~= false and "~" or "") .. fmtCheckEu(st.totalEut) .. " EU/t")
            or ""
        print(string.format("  [%d] %s%s: allowWork=%s wantConv=%s wantCat=T%d -> %s%s",
            i, tostring(d.name), hatchStr, tostring(st.shouldAllowWork == true), tostring(st.wantConv == true),
            tonumber(st.wantCatTier) or 4, tostring(st.jobLabel), eutStr))
    end
    local ps = runtimeState.powerSummary or {}
    print(string.format("Fleet Power: total=%s EU/t (direct=%s, cat=%s) powerAware=%s",
        fmtCheckEu(ps.totalEut), fmtCheckEu(ps.directEut), fmtCheckEu(ps.catEut),
        tostring(cfg.powerAwareAssign ~= false)))
    local ms = runtimeState.maintStatus or {}
    print(string.format("Level Maintainer: enabled=%s link=%s freeCpus=%s/%s active=%d crafting=%d low=%d",
        tostring(ms.enabled == true), tostring(ms.link or "none"),
        tostring(ms.freeCpus or "?"), tostring(ms.totalCpus or "?"),
        tonumber(ms.activeCount) or 0, tonumber(ms.craftingCount) or 0, tonumber(ms.lowCount) or 0))
    local autoFlushPolls = math.max(0, math.floor(tonumber(cfg.odAutoFlushPolls) or 0))
    local autoFlushStr = (autoFlushPolls > 0)
        and string.format("%ds(%dp)", math.floor(autoFlushPolls * (tonumber(cfg.pollInterval) or 2.0)), autoFlushPolls)
        or "OFF"
    print(string.format("  Catalyst Bridge: tp=%s (P:%s <-> OD:%s) | AutoFlush=%s | %s",
        cfg.transposerAddr and cfg.transposerAddr:sub(1, 10) or "None",
        tostring(cfg.stockTransposerSide or 1),
        tostring(cfg.odTransposerSide or 0),
        autoFlushStr,
        tostring(runtimeState.odBridgeStatus or "Disabled")))
    for i = 1, #((ep and ep.warnings) or {}) do
        print("  ! WARNING: " .. tostring(ep.warnings[i]))
    end
    print("=== CHECK COMPLETE (NO HARDWARE MODIFIED) ===")
end

local function runGUI()
    local cfg = loadConfig()
    Scheduler.syncHardware(cfg)
    local lockedCnt = Hardware.lockAllPassiveAutoPull()

    local runtimeState = {}
    local okInit, errInit = pcall(Scheduler.step, cfg, runtimeState)

    local savePending = false
    local saveDeadline = 0
    local function scheduleSave()
        savePending = true
        saveDeadline = computer.uptime() + 0.4
    end
    local function flushPendingSave()
        if savePending then
            savePending = false
            saveConfig(cfg)
        end
    end

    local ui = UI.new(cfg, runtimeState, scheduleSave)
    local webBridge = WebBridge.new(cfg, runtimeState, ui, scheduleSave, Scheduler, Hardware)
    if (cfg.extLinkMode ~= "off") and Hardware.openMeshPort then pcall(Hardware.openMeshPort) end
    webBridge:step(computer.uptime())
    if not okInit then
        ui.statusMsg = "Scheduler init error: " .. tostring(errInit)
    elseif lockedCnt and lockedCnt > 0 then
        ui.statusMsg = string.format("Safety lock: disabled autoPull on %d passive Hatch/Bus endpoint(s).", lockedCnt)
    end

    local function runLoop()
        ui:render()
        local ANIM_INTERVAL = 0.5
        local interval = math.max(0.5, tonumber(cfg.pollInterval) or 3.0)
        local nextPoll = computer.uptime() + interval
        local nextAnim = computer.uptime() + ANIM_INTERVAL

        local function handleInputEvent(evName, a0, a1, a2, a3, a4, a5, a6)
            if evName == "interrupted" then
                savePending = true
                ui.running = false
                return true, false
            elseif evName == "internet_ready" then
                return webBridge:drain(), false
            elseif evName == "modem_message" then
                if Hardware.handleMeshMessage and Hardware.handleMeshMessage(webBridge, a0, a1, a2, a4, a5, a6) then
                    return true, false
                end
                return false, false
            elseif evName == "screen_resized" then
                if ui and ui.syncDisplay then ui:syncDisplay(true) end
                return true, false
            elseif evName == "touch" then
                ui:handleTouch(math.floor(tonumber(a1) or 0), math.floor(tonumber(a2) or 0), a3)
                return true, false
            elseif evName == "scroll" then
                ui:handleScroll(tonumber(a3) or 0, math.floor(tonumber(a1) or 0), math.floor(tonumber(a2) or 0))
                return true, true
            elseif evName == "key_down" then
                local wasPrompt = (ui.promptActive == true)
                local code = tonumber(a2) or 0
                ui:handleKeyDown(tonumber(a1) or 0, code)
                local canCoalesce = (wasPrompt and ui.promptActive)
                    or (code == 200 or code == 208 or code == 203 or code == 205)
                return true, canCoalesce
            end
            return false, false
        end

        local MAX_EVENTS_PER_TICK = 32
        while ui.running do
            local dirty = false
            local now = computer.uptime()
            local animActive = (cfg.uiAnimations ~= false)
                and (cfg.armed == true)
                and (not ui.promptActive)
                and (not ui.passiveModalActive)
                and (not ui.logModalActive)
            local forcePoll = (runtimeState._forcePollNow == true)
            local timeout = forcePoll and 0.01 or math.max(0.05, nextPoll - now)
            if (not forcePoll) and animActive then
                timeout = math.min(timeout, math.max(0.05, nextAnim - now))
            end
            if (not forcePoll) and savePending then
                timeout = math.min(timeout, math.max(0.02, saveDeadline - now))
            end
            local ev, a0, a1, a2, a3, a4, a5, a6 = event.pull(timeout)

            if ev then
                for _ = 1, MAX_EVENTS_PER_TICK do
                    if not ev or not ui.running then break end
                    local handled, coalesced = handleInputEvent(ev, a0, a1, a2, a3, a4, a5, a6)
                    if handled then dirty = true end
                    if not coalesced then break end
                    ev, a0, a1, a2, a3, a4, a5, a6 = event.pull(0)
                end

                if ui.running and not ui.promptActive and ui:consumeConfigDirty() then
                    local ok, err = pcall(Scheduler.step, cfg, runtimeState, { cachedOnly = true, interactive = true })
                    if not ok then ui.statusMsg = "Scheduler error: " .. tostring(err) end
                end
            end

            if ui.running and (runtimeState._forcePollNow == true or computer.uptime() >= nextPoll) then
                runtimeState._forcePollNow = false
                local ok, err = pcall(Scheduler.step, cfg, runtimeState, { allowStockCache = true, allowSensorCache = true })
                if not ok then
                    ui.statusMsg = "Scheduler error: " .. tostring(err)
                else
                    ui.animNow = nil
                end
                webBridge:step(computer.uptime())
                if Hardware.pushMeshMetrics then
                    pcall(Hardware.pushMeshMetrics, cfg, runtimeState, computer.uptime())
                end
                if webBridge:drain() then
                    dirty = true
                end
                if runtimeState._pendingReboot then
                    savePending = true
                    ui.running = false
                end
                interval = math.max(0.5, tonumber(cfg.pollInterval) or 3.0)
                local nowDone = computer.uptime()
                nextPoll = nowDone + interval
                nextAnim = nowDone + ANIM_INTERVAL
                dirty = true
            end

            local nowAfter = computer.uptime()
            if ui.running and animActive and nowAfter >= nextAnim then
                if not dirty then
                    ui:advanceAnim(nowAfter)
                    dirty = true
                end
                nextAnim = nowAfter + ANIM_INTERVAL
            elseif not animActive then
                nextAnim = nowAfter + ANIM_INTERVAL
            end

            if dirty and ui.running then
                ui:render()
            end

            if savePending and computer.uptime() >= saveDeadline then
                flushPendingSave()
            end
        end

        flushPendingSave()
    end

    local isDtpfShrcLine = Common.makeShrcMatcher({
        "dtpf", "/usr/bin/dtpf", "/usr/bin/dtpf.lua", "/home/dtpf/main.lua",
    })

    local function armShellReviveWatchdog(meshPort)
        return Common.armShellReviveWatchdog({
            isAutostartFn = isDtpfShrcLine,
            shrcPath = "/home/.shrc",
            meshPort = tonumber(meshPort) or Common.MESH_PORT,
            wakeMsg = Common.WAKE_MSG,
        })
    end

    Common.disarmShellReviveWatchdog()

    local consecutiveFaults = 0
    while true do
        local okLoop, errLoop = xpcall(runLoop, debug.traceback)
        flushPendingSave()
        if okLoop or runtimeState._pendingReboot then
            webBridge:close()
            if component.isAvailable("gpu") then
                component.gpu.setBackground(0x000000)
                component.gpu.setForeground(0xFFFFFF)
            end
            term.clear()
            if okLoop then
                print("DTPF Automation Controller stopped cleanly.")
            else
                io.stderr:write("DTPF Automation Controller error:\n" .. tostring(errLoop) .. "\n")
            end
            if runtimeState._pendingUpdateUrl then
                local updUrl = runtimeState._pendingUpdateUrl
                runtimeState._pendingUpdateUrl = nil
                local instPath = filesystem.concat(scriptDir, "install.lua")
                local f = io.open(instPath, "r")
                local chunk, loadErr
                if f then
                    local src = f:read("*a")
                    f:close()
                    chunk, loadErr = load(src or "", "=" .. instPath)
                else
                    loadErr = "missing " .. tostring(instPath)
                end
                if chunk then
                    local tx = Common.detectOtaTransport(component)
                    local updArgs = Common.buildInstallerArgs(updUrl, { viaMesh = tx.viaMesh })
                    local okU, okInst = pcall(chunk, table.unpack(updArgs))
                    if okU and okInst ~= false and computer.shutdown then
                        pcall(computer.shutdown, true)
                    else
                        io.stderr:write("DTPF remote update failed: " .. tostring(okInst) .. "\n")
                    end
                else
                    io.stderr:write("DTPF updater load failed: " .. tostring(loadErr) .. "\n")
                end
            elseif runtimeState._pendingReboot and computer.shutdown then
                pcall(computer.shutdown, true)
            end
            armShellReviveWatchdog(cfg and cfg.meshPort)
            break
        end
        consecutiveFaults = consecutiveFaults + 1
        io.stderr:write(string.format("DTPF Automation Controller fault #%d (restarting cleanly):\n%s\n",
            consecutiveFaults, tostring(errLoop)))
        local ev = event.pull(math.min(15, 2 + consecutiveFaults * 2), "interrupted")
        if ev == "interrupted" then
            webBridge:close()
            if component.isAvailable("gpu") then
                component.gpu.setBackground(0x000000)
                component.gpu.setForeground(0xFFFFFF)
            end
            term.clear()
            print("DTPF Automation Controller interrupted during recovery.")
            armShellReviveWatchdog(cfg and cfg.meshPort)
            break
        end
        ui.running = true
        if webBridge and webBridge.ensureStarted then pcall(webBridge.ensureStarted, webBridge) end
    end
end

local function main(args)
    for i = 1, #(args or {}) do
        local a = tostring(args[i])
        if a == "--help" or a == "-h" then
            printHelp()
            return
        elseif a == "--worker" or a == "worker" then
            Hardware.runWorkerDaemon()
            return
        elseif a == "--check" or a == "check" then
            runCheck()
            return
        elseif a == "--lock" or a == "lock" then
            Hardware.discoverWorkers()
            local changed, total = Hardware.lockAllPassiveAutoPull()
            print(string.format("Locked autoPull=OFF on %d/%d passive ME Hatches/Buses.", changed or 0, total or 0))
            return
        elseif a == "--update" or a == "update" then
            local instPath = filesystem.concat(scriptDir, "install.lua")
            local f = io.open(instPath, "r")
            if not f then
                io.stderr:write("ERROR: install.lua not found at " .. tostring(instPath) .. "\n")
                return
            end
            local src = f:read("*a")
            f:close()
            local chunk, err = load(src or "", "=" .. instPath)
            if not chunk then
                io.stderr:write("ERROR: Failed to load install.lua: " .. tostring(err) .. "\n")
                return
            end
            local extra = { "--update" }
            for j = i + 1, #args do extra[#extra + 1] = args[j] end
            chunk(table.unpack(extra))
            return
        end
    end
    runGUI()
end

main(cliArgs)
