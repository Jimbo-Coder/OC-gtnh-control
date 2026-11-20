-- /home/dtpf/lib/hardware.lua
-- Hardware abstraction for GTNH 2.9+ OpenComputers DTPF Controller
-- Supports:
--   1. DTPF Controllers via DriverDTPF (`dtpf`) and/or Computronics (`gt_machine`)
--   2. Passive Channels via:
--      a) Subnet Storage Bus pairs (`me_storagebus` + `fluid_storagebus` on separate cable blocks)
--      b) Per-hatch MFU pairs (`me_inputhatch` + `me_inputbus`)
--   3. AE2 Stock & On-Demand Subnet monitoring via `me_interface`, adapted `fluid_interface` (ME Dual Interface), or `me_controller`

local component = require("component")
local event = require("event")
local serialization = require("serialization")
local okComp, computer = pcall(require, "computer")
if not okComp then computer = nil end

local Hardware = {}

Hardware.CLUSTER_PORT = 4104
Hardware.MESH_PORT = 4205
local MAX_DTPF_CHUNK = 6
local RPC_SEQ = 0

Hardware._workers = {}
Hardware._remoteDtpfStatus = {}
Hardware._remoteOwner = {}
Hardware._mainnetMeshAddr = nil
Hardware._lastMeshBeacon = -100
Hardware._localMaintPending = {}

local GT_TIER_NAMES = { "ULV", "LV", "MV", "HV", "EV", "IV", "LuV", "ZPM", "UV", "UHV", "UEV", "UIV", "UMV", "UXV", "MAX" }
local GT_TIER_V = { 8, 32, 128, 512, 2048, 8192, 32768, 131072, 524288, 2097152, 8388608, 33554432, 134217728, 536870912, 2147483640 }
local SI_MULT = { k = 1e3, K = 1e3, M = 1e6, G = 1e9, B = 1e9, T = 1e12, P = 1e15, E = 1e18 }

function Hardware.resetClusterState()
    Hardware._workers = {}
    Hardware._remoteDtpfStatus = {}
    Hardware._remoteOwner = {}
    Hardware._lastMainnetSeen = nil
    Hardware._lastMainnetWakeAt = -1000
    Hardware._lastClaimsRaw = nil
    Hardware._lastClaimsSig = nil
    Hardware._lastClaimsSent = -100
end

function Hardware.getWorkerCount()
    local n = 0
    for _ in pairs(Hardware._workers) do
        n = n + 1
    end
    return n
end

local CATALYST_FLUID_SET = {
    exciteddtcc = true,
    exciteddtpc = true,
    exciteddtrc = true,
    exciteddtec = true,
    exciteddtsc = true,
}

local FLUID_SENTINELS = {
    "ic2pahoehoelava",
    "ic2hotwater",
    "ic2weedex",
    "lava",
    "milk",
    "short.mead",
}

local ITEM_SENTINELS = {
    "minecraft:fire",
    "minecraft:bedrock",
    "minecraft:command_block",
}

local ITEM_SENTINEL_SET = {}
for i = 1, #ITEM_SENTINELS do
    ITEM_SENTINEL_SET[ITEM_SENTINELS[i]] = true
end

local function safeCall(proxy, method, ...)
    if not proxy or not proxy[method] then
        return nil, "missing method " .. tostring(method)
    end
    local ok, r1, r2, r3 = pcall(proxy[method], ...)
    if not ok then
        return nil, tostring(r1)
    end
    return r1, r2, r3
end

local function stripFormatting(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("\194\167.", ""):gsub("\167.", ""):gsub("[\1-\31]", ""))
end

local function collectSensorLines(lines)
    if type(lines) ~= "table" then return {} end
    local ordered = {}
    local n = #lines
    if n > 0 then
        if type(lines[0]) == "string" then
            ordered[#ordered + 1] = lines[0]
        end
        for i = 1, n do
            if type(lines[i]) == "string" then
                ordered[#ordered + 1] = lines[i]
            end
        end
        return ordered
    end
    local numKeys = {}
    for k, v in pairs(lines) do
        if type(k) == "number" and type(v) == "string" then
            numKeys[#numKeys + 1] = k
        end
    end
    table.sort(numKeys)
    for i = 1, #numKeys do
        ordered[#ordered + 1] = lines[numKeys[i]]
    end
    return ordered
end

local function readCoords(proxy)
    if not proxy or not proxy.getCoordinates then return nil, nil, nil end
    local ok, a, b, c = pcall(proxy.getCoordinates)
    if not ok or a == nil then return nil, nil, nil end
    if type(a) == "table" then
        return tonumber(a[1] or a.x), tonumber(a[2] or a.y), tonumber(a[3] or a.z)
    end
    return tonumber(a), tonumber(b), tonumber(c)
end

local function parseSensorNumber(raw)
    if type(raw) ~= "string" then return nil end
    local clean = raw:gsub(",", ""):match("^%s*(.-)%s*$")
    if clean == "" then return nil end
    local baseS, expS = clean:match("([%d%.]+)%s*[xX*]%s*10%^([%+%-]?%d+)")
    if baseS and expS then
        return tonumber(baseS .. "e" .. expS)
    end
    local eNum = clean:match("([%+%-]?%d+%.?%d*[eE][%+%-]?%d+)")
    if eNum then
        return tonumber(eNum)
    end
    local numS, suf = clean:match("^([%+%-]?%d+%.?%d*)%s*([kKMGBTPPE]?)")
    if numS and numS ~= "" then
        local f = tonumber(numS)
        local mult = (suf and suf ~= "" and SI_MULT[suf]) or 1
        return f and (f * mult) or nil
    end
    return nil
end

local function fmtCommaInt(n)
    local s = tostring(math.floor(tonumber(n) or 0))
    return (s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

local function deriveHatchFromMaxEu(maxEu)
    maxEu = tonumber(maxEu) or 0
    if maxEu <= 0 then return nil, nil end
    for i = #GT_TIER_NAMES, 1, -1 do
        local v = GT_TIER_V[i]
        if maxEu >= v and (maxEu % v) == 0 then
            return math.floor(maxEu / v), GT_TIER_NAMES[i]
        end
    end
    for i = #GT_TIER_NAMES, 1, -1 do
        local v = GT_TIER_V[i]
        if maxEu >= v then
            return math.floor(maxEu / v + 0.5), GT_TIER_NAMES[i]
        end
    end
    return nil, nil
end

local function formatHatchLabel(amps, tier)
    if not amps or not tier or amps <= 0 then return nil end
    return fmtCommaInt(amps) .. "A " .. tostring(tier)
end

-- Parse MTEPlasmaForge sensor lines (both GTNH 2.9.0 encoded `\` lines and decoded English lines)
function Hardware.parseDTPFSensor(lines)
    local info = {
        coilHeat = nil,
        discountPct = nil,
        runningTicks = nil,
        extraCatalystNeeded = nil,
        convergenceActive = nil,
        convergenceAchieved = nil,
        maxInputEu = nil,
        hatchAmps = nil,
        hatchTier = nil,
        hatchLabel = nil,
        liveEut = nil,
        rawLines = {},
    }
    if type(lines) ~= "table" then return info end

    local lineList = collectSensorLines(lines)
    for i = 1, #lineList do
        local clean = stripFormatting(lineList[i])
        if #info.rawLines < 6 then
            info.rawLines[#info.rawLines + 1] = clean
        end

        -- Coil heat (GTNH 2.9.0 IGregTechDeviceInformation.encode separates args with two backslashes `\\`)
        if not info.coilHeat then
            local encHeat = clean:match("GT5U%.EBF%.heat[^\\]*\\+([^\\]+)")
                or clean:match("GTPP%.EBF%.heat[^\\]*\\+([^\\]+)")
                or clean:match("[Hh]eat [Cc]apacity:?[^%d]*(.+)")
            local heatDigits = encHeat and encHeat:gsub("[^%d]", "") or nil
            local hVal = (heatDigits and heatDigits ~= "") and tonumber(heatDigits) or nil
            if hVal and hVal > 0 then
                info.coilHeat = hVal
            end
        end

        -- Max Energy Input + Hatch Amps/Tier (`mei_amp` or `mei`)
        if not info.maxInputEu then
            local mEu, mAmp, mTier = clean:match("^GT5U%.multiblock%.scanner%.mei_amp\\+([^\\]+)\\+([^\\]+)\\+([^\\]+)")
            if mEu then
                info.maxInputEu = parseSensorNumber(mEu)
                info.hatchAmps = parseSensorNumber(mAmp)
                info.hatchTier = (mTier and mTier:match("([%a]+)")) or nil
            else
                local mEuOnly = clean:match("^GT5U%.multiblock%.scanner%.mei\\+([^\\]+)")
                if mEuOnly then
                    info.maxInputEu = parseSensorNumber(mEuOnly)
                else
                    local dEu, dAmp, dTier = clean:match("Max Energy Input:%s*([^%(]+)%s*EU/t%s*%(([%d,%.]+)A%s*([%a]+)%s*%)")
                    if dEu then
                        info.maxInputEu = parseSensorNumber(dEu)
                        info.hatchAmps = parseSensorNumber(dAmp)
                        info.hatchTier = dTier
                    else
                        local dEuOnly = clean:match("Max Energy Input:%s*(.-)%s*EU/t")
                        if dEuOnly then
                            info.maxInputEu = parseSensorNumber(dEuOnly)
                        end
                    end
                end
            end
        end

        -- Live actual energy usage (`Currently uses: ... EU/t`)
        if not info.liveEut then
            local uRaw = clean:match("^GT5U%.multiblock%.scanner%.usage\\+([^\\]+)")
                or clean:match("[Cc]urrently uses:%s*(.-)%s*EU/t")
                or clean:match("[Pp]robably uses:%s*(.-)%s*EU/t")
            if uRaw then
                info.liveEut = parseSensorNumber(uRaw)
            end
        end

        -- Encoded ticks / fuel discount / extra catalyst needed
        local f1, f2, rest = clean:match("^GT5U%.infodata%.plasma_forge%.ticks_run_fuel_discount\\+([^\\]+)\\+([^\\]+)(.*)$")
        if f1 then
            local tNum = f1:match("([%d,]+)")
            if tNum then info.runningTicks = tonumber((tNum:gsub(",", ""))) end
            local dNum = f2:match("([%d%.]+)")
            if dNum then info.discountPct = tonumber(dNum) end
            if rest and rest:sub(1, 1) == "\\" then
                local f3 = rest:match("^\\+([^\\]*)")
                local exNum = f3 and f3:match("([%d,%.]+)")
                if exNum then info.extraCatalystNeeded = tonumber((exNum:gsub(",", ""))) end
            end
        else
            -- Decoded English fallbacks
            local ticks, disc = clean:match("Ticks run:%s*([%d,]+).*Fuel Discount:%s*([%d%.]+)")
            if ticks then
                info.runningTicks = tonumber((ticks:gsub(",", "")))
                info.discountPct = tonumber(disc)
            end
            local pctOnly = clean:match("Fuel Discount:%s*([%d%.]+)%%")
            if pctOnly then
                info.discountPct = tonumber(pctOnly)
            end
            local exOnly = clean:match("Extra [Cc]atalyst[^%d]*([%d,%.]+)")
            if exOnly then
                info.extraCatalystNeeded = tonumber((exOnly:gsub(",", "")))
            end
        end

        -- Encoded & decoded convergence status
        local convTail = clean:match("^GT5U%.infodata%.plasma_forge%.convergence\\+(.+)$")
        if not convTail and clean:find("Convergence:", 1, true) then
            convTail = clean
        end
        if convTail then
            info.convergenceActive = (convTail:find("Active", 1, true) ~= nil and convTail:find("Inactive", 1, true) == nil)
            info.convergenceAchieved = (convTail:find("achieved", 1, true) ~= nil)
        end
    end

    if info.maxInputEu and (not info.hatchAmps or not info.hatchTier) then
        local da, dt = deriveHatchFromMaxEu(info.maxInputEu)
        info.hatchAmps = info.hatchAmps or da
        info.hatchTier = info.hatchTier or dt
    end
    if info.hatchAmps and info.hatchTier then
        info.hatchLabel = formatHatchLabel(info.hatchAmps, info.hatchTier)
    end

    return info
end

-- Discover local DTPF controllers (`dtpf` and `gt_machine`), merged by address or coordinates,
-- and sorted deterministically by room order (z, x, y, address).
function Hardware.discoverLocalDTPFs(compLib)
    local cl = compLib or component
    local byAddr = {}
    local byCoordKey = {}

    local function coordKey(x, y, z)
        if x and y and z then
            return string.format("%d:%d:%d", math.floor(x), math.floor(y), math.floor(z))
        end
        return nil
    end

    for addr in cl.list("dtpf", true) do
        local p = cl.proxy(addr)
        local x, y, z = readCoords(p)
        local entry = {
            address = addr,
            dtpfProxy = p,
            gtProxy = p,
            x = x,
            y = y,
            z = z,
        }
        byAddr[addr] = entry
        local ck = coordKey(x, y, z)
        if ck then byCoordKey[ck] = entry end
    end

    for addr in cl.list("gt_machine", true) do
        local p = cl.proxy(addr)
        local isPlasmaForge = false
        if p and (p.isConvergenceEnabled or p.getConvergenceStatus) then
            isPlasmaForge = true
        elseif p then
            local name = safeCall(p, "getName")
            if type(name) == "string" and (name:lower():find("plasma") or name:lower():find("dtpf")) then
                isPlasmaForge = true
            else
                local sensor = safeCall(p, "getSensorInformation")
                if type(sensor) == "table" then
                    for i = 1, #sensor do
                        local s = tostring(sensor[i])
                        if s:find("Fuel Discount", 1, true)
                            or s:find("Convergence", 1, true)
                            or s:find("plasma_forge", 1, true) then
                            isPlasmaForge = true
                            break
                        end
                    end
                end
            end
        end

        if isPlasmaForge then
            local x, y, z = readCoords(p)
            local ck = coordKey(x, y, z)
            local entry = byAddr[addr] or (ck and byCoordKey[ck])
            if not entry then
                entry = { address = addr, x = x, y = y, z = z }
                byAddr[addr] = entry
                if ck then byCoordKey[ck] = entry end
            else
                if not entry.x and x then
                    entry.x, entry.y, entry.z = x, y, z
                end
            end
            entry.gtProxy = p
            if p and (p.isConvergenceEnabled or p.getConvergenceStatus) then
                entry.dtpfProxy = entry.dtpfProxy or p
            end
        end
    end

    local list = {}
    for _, v in pairs(byAddr) do
        list[#list + 1] = v
    end
    table.sort(list, function(a, b)
        local za, zb = a.z or math.huge, b.z or math.huge
        if za ~= zb then return za < zb end
        local xa, xb = a.x or math.huge, b.x or math.huge
        if xa ~= xb then return xa < xb end
        local ya, yb = a.y or math.huge, b.y or math.huge
        if ya ~= yb then return ya < yb end
        return a.address < b.address
    end)
    return list
end

-- Read unified status from a local DTPF entry
function Hardware.getLocalDTPFStatus(entry, opts)
    local gp = entry.gtProxy or entry.dtpfProxy
    local dp = entry.dtpfProxy or entry.gtProxy

    if entry.x == nil and (gp or dp) then
        local x, y, z = readCoords(gp or dp)
        if x ~= nil then
            entry.x, entry.y, entry.z = x, y, z
        end
    end

    local status = {
        address = entry.address,
        online = gp ~= nil or dp ~= nil,
        supportsConvControl = (dp ~= nil) and ((dp.setConvergenceEnabled ~= nil) or (dp.setConvergenceStatus ~= nil)),
        x = entry.x,
        y = entry.y,
        z = entry.z,
        active = false,
        machineActive = false,
        hasWork = false,
        workAllowed = true,
        progress = 0,
        maxProgress = 0,
        discountPct = 0,
        runningTicks = 0,
        coilHeat = nil,
        extraCatalystNeeded = 0,
        convergenceEnabled = false,
        convergenceAchieved = false,
        catalystTier = 4,
        maxInputEu = nil,
        hatchAmps = nil,
        hatchTier = nil,
        hatchLabel = nil,
        liveEut = 0,
    }
    if not status.online then return status end

    local gotConvFromSensor = false
    if gp then
        local wa = safeCall(gp, "isWorkAllowed")
        if wa ~= nil then status.workAllowed = wa end
        if gp.getWorkMaxProgress then
            local mp = safeCall(gp, "getWorkMaxProgress")
            if mp ~= nil then status.maxProgress = mp end
            if (status.maxProgress or 0) > 0 then
                status.machineActive = true
                status.hasWork = true
                local pr = safeCall(gp, "getWorkProgress")
                if pr ~= nil then status.progress = pr end
            else
                status.machineActive = false
                status.hasWork = false
                status.progress = 0
            end
        else
            local ma = safeCall(gp, "isMachineActive")
            if ma ~= nil then status.machineActive = ma end
            local hw = safeCall(gp, "hasWork")
            if hw ~= nil then status.hasWork = hw end
            local pr = safeCall(gp, "getWorkProgress")
            if pr ~= nil then status.progress = pr end
        end
        status.active = status.machineActive or status.hasWork or (status.maxProgress > 0)

        local useSensorCache = (type(opts) == "table") and (opts.allowSensorCache == true)
        local stateChanged = (entry._prevActiveForSensor ~= status.active)
            or (entry._prevConvForSensor ~= status.convergenceEnabled)
        entry._prevActiveForSensor = status.active
        entry._prevConvForSensor = status.convergenceEnabled
        entry._sensorPollTick = ((entry._sensorPollTick or 0) + 1) % 5
        local refreshSensor = (not useSensorCache)
            or (entry._lastSensorParsed == nil)
            or stateChanged
            or (entry._sensorPollTick == 1)

        local parsed, sensorErr
        if refreshSensor then
            local sensor
            sensor, sensorErr = safeCall(gp, "getSensorInformation")
            if type(sensor) == "table" then
                parsed = Hardware.parseDTPFSensor(sensor)
                entry._lastSensorParsed = parsed
            end
        else
            parsed = entry._lastSensorParsed
        end

        if type(parsed) == "table" then
            if parsed.discountPct ~= nil then status.discountPct = parsed.discountPct end
            if parsed.runningTicks ~= nil then status.runningTicks = parsed.runningTicks end
            if parsed.coilHeat ~= nil then
                status.coilHeat = parsed.coilHeat
                entry._cachedCoilHeat = parsed.coilHeat
            elseif entry._cachedCoilHeat ~= nil then
                status.coilHeat = entry._cachedCoilHeat
            end
            if parsed.extraCatalystNeeded ~= nil then status.extraCatalystNeeded = parsed.extraCatalystNeeded end
            if parsed.convergenceAchieved ~= nil then status.convergenceAchieved = parsed.convergenceAchieved end
            if parsed.convergenceActive ~= nil then
                status.convergenceEnabled = parsed.convergenceActive
                gotConvFromSensor = true
            end
            if parsed.maxInputEu ~= nil and parsed.maxInputEu > 0 then
                status.maxInputEu = parsed.maxInputEu
                status.hatchAmps = parsed.hatchAmps
                status.hatchTier = parsed.hatchTier
                status.hatchLabel = parsed.hatchLabel
                entry._cachedHatch = {
                    maxInputEu = parsed.maxInputEu,
                    hatchAmps = parsed.hatchAmps,
                    hatchTier = parsed.hatchTier,
                    hatchLabel = parsed.hatchLabel,
                }
            elseif entry._cachedHatch then
                status.maxInputEu = entry._cachedHatch.maxInputEu
                status.hatchAmps = entry._cachedHatch.hatchAmps
                status.hatchTier = entry._cachedHatch.hatchTier
                status.hatchLabel = entry._cachedHatch.hatchLabel
            end
            if not status.active then
                entry._lastLiveEut = 0
                status.liveEut = 0
            elseif parsed.liveEut ~= nil and parsed.liveEut > 0 then
                entry._lastLiveEut = parsed.liveEut
                status.liveEut = parsed.liveEut
            else
                status.liveEut = entry._lastLiveEut or 0
            end
            if #parsed.rawLines > 0 then
                local sample = {}
                local limit = (status.coilHeat == nil) and math.min(16, #parsed.rawLines) or math.min(4, #parsed.rawLines)
                for si = 1, limit do
                    sample[#sample + 1] = parsed.rawLines[si]
                end
                status.rawSensorSample = table.concat(sample, " | ")
            else
                status.rawSensorSample = "<empty>"
            end
        else
            if entry._cachedCoilHeat ~= nil then
                status.coilHeat = entry._cachedCoilHeat
            end
            if entry._cachedHatch then
                status.maxInputEu = entry._cachedHatch.maxInputEu
                status.hatchAmps = entry._cachedHatch.hatchAmps
                status.hatchTier = entry._cachedHatch.hatchTier
                status.hatchLabel = entry._cachedHatch.hatchLabel
            end
            status.liveEut = status.active and (entry._lastLiveEut or 0) or 0
            status.rawSensorSample = "<nil:" .. tostring(sensorErr or "nil") .. ">"
        end
    end

    if dp then
        if not gotConvFromSensor then
            local ce = safeCall(dp, "isConvergenceEnabled")
            if ce == nil then
                ce = safeCall(dp, "getConvergenceStatus")
            end
            if ce ~= nil then status.convergenceEnabled = ce end
        end
        if entry._cachedCatTier ~= nil then
            status.catalystTier = entry._cachedCatTier
        else
            local ct = safeCall(dp, "getConvergenceCatalystType")
            if ct ~= nil then
                status.catalystTier = ct
                entry._cachedCatTier = ct
            end
        end
    end

    return status
end

function Hardware.setLocalDTPFConvergence(entry, enabled, catalystTierIndex)
    local dp = entry.dtpfProxy or entry.gtProxy
    if not dp then return false, "no dtpf proxy" end
    if not (dp.setConvergenceEnabled or dp.setConvergenceStatus) then
        return false, "setConvergenceEnabled unavailable"
    end
    entry._lastSensorParsed = nil
    if catalystTierIndex and dp.setConvergenceCatalystType then
        local t = math.max(1, math.min(5, math.floor(catalystTierIndex)))
        safeCall(dp, "setConvergenceCatalystType", t)
        entry._cachedCatTier = t
    end
    local val = enabled and true or false
    if dp.setConvergenceEnabled then
        local ok, err = safeCall(dp, "setConvergenceEnabled", val)
        return ok ~= nil, err
    elseif dp.setConvergenceStatus then
        local ok, err = safeCall(dp, "setConvergenceStatus", val)
        return ok ~= nil, err
    end
    return false, "setConvergenceEnabled unavailable"
end

function Hardware.setLocalDTPFWorkAllowed(entry, allowed)
    local gp = entry.gtProxy or entry.dtpfProxy
    if not gp or not gp.setWorkAllowed then return false end
    safeCall(gp, "setWorkAllowed", allowed and true or false)
    return true
end

local function scanEndpointCoords(compLib, compType)
    local cl = compLib or component
    local addrs, coords = {}, {}
    for addr in cl.list(compType, true) do
        addrs[#addrs + 1] = addr
        local x, y, z = readCoords(cl.proxy(addr))
        if x and y and z then
            coords[addr] = { x = x, y = y, z = z }
        end
    end
    table.sort(addrs, function(a, b)
        local ca, cb = coords[a], coords[b]
        if ca and cb then
            if ca.z ~= cb.z then return ca.z < cb.z end
            if ca.x ~= cb.x then return ca.x < cb.x end
            if ca.y ~= cb.y then return ca.y < cb.y end
        elseif ca ~= nil or cb ~= nil then
            return ca ~= nil
        end
        return a < b
    end)
    return addrs, coords
end

-- Pick the closest unused address to refPos (by squared 3D distance), falling back to list order
function Hardware.pickNearestAddress(refPos, candidates, coordsMap, usedSet)
    candidates = candidates or {}
    usedSet = usedSet or {}
    if refPos and refPos.x and refPos.z and coordsMap then
        local bestAddr, bestDist = nil, math.huge
        for i = 1, #candidates do
            local addr = candidates[i]
            local c = coordsMap[addr]
            if addr and not usedSet[addr] and c and c.x and c.z then
                local dx = c.x - refPos.x
                local dy = (c.y or refPos.y or 0) - (refPos.y or c.y or 0)
                local dz = c.z - refPos.z
                local d2 = dx * dx + dy * dy + dz * dz
                if d2 < bestDist then
                    bestDist = d2
                    bestAddr = addr
                end
            end
        end
        if bestAddr then
            usedSet[bestAddr] = true
            return bestAddr
        end
    end
    for i = 1, #candidates do
        local addr = candidates[i]
        if addr and not usedSet[addr] then
            usedSet[addr] = true
            return addr
        end
    end
    return nil
end

-- Discover local passive endpoints and record any Storage Bus collision warnings
function Hardware.discoverLocalPassiveEndpoints(compLib)
    local cl = compLib or component
    local hatches, hatchCoords = scanEndpointCoords(cl, "me_inputhatch")
    local buses, busCoords = scanEndpointCoords(cl, "me_inputbus")

    local itemStorageBuses = {}
    for addr in cl.list("me_storagebus", true) do
        local p = cl.proxy(addr)
        local validSides = {}
        for s = 0, 5 do
            local sz = safeCall(p, "getStorageSlotSize", s)
            if type(sz) == "number" and sz > 0 then
                validSides[#validSides + 1] = { side = s, slots = sz }
            end
        end
        itemStorageBuses[#itemStorageBuses + 1] = { address = addr, sides = validSides }
    end
    table.sort(itemStorageBuses, function(a, b) return a.address < b.address end)

    local fluidStorageBuses = {}
    for addr in cl.list("fluid_storagebus", true) do
        local p = cl.proxy(addr)
        local validSides = {}
        for s = 0, 5 do
            local sz = safeCall(p, "getStorageSlotSize", s)
            if type(sz) == "number" and sz > 0 then
                validSides[#validSides + 1] = { side = s, slots = sz }
            end
        end
        fluidStorageBuses[#fluidStorageBuses + 1] = { address = addr, sides = validSides }
    end
    table.sort(fluidStorageBuses, function(a, b) return a.address < b.address end)

    local autoPullOnCount = 0
    for _, list in ipairs({ hatches, buses }) do
        for i = 1, #list do
            local p = cl.proxy(list[i])
            if p and safeCall(p, "getAutoPull") == true then
                autoPullOnCount = autoPullOnCount + 1
            end
        end
    end

    local warnings = {}
    if (#fluidStorageBuses + #itemStorageBuses) > 0 and (#fluidStorageBuses ~= #itemStorageBuses) then
        warnings[#warnings + 1] = string.format(
            "StorageBus mismatch (%d fluid vs %d item): do NOT place ME Fluid Storage Bus and ME Storage Bus on the SAME AE2 cable block (fluid_storagebus priority=2 shadows me_storagebus). Place them on 2 separate cable blocks touching the Adapter.",
            #fluidStorageBuses, #itemStorageBuses
        )
    end
    if autoPullOnCount > 0 then
        warnings[#warnings + 1] = string.format(
            "%d passive Hatch/Bus endpoint(s) still have autoPull=ON! Launch GUI or run `main.lua --lock` BEFORE connecting unfiltered Main Net so Main Net does not dump into them.",
            autoPullOnCount
        )
    end

    return {
        hatches = hatches,
        buses = buses,
        hatchCoords = hatchCoords,
        busCoords = busCoords,
        itemStorageBuses = itemStorageBuses,
        fluidStorageBuses = fluidStorageBuses,
        autoPullOnCount = autoPullOnCount,
        warnings = warnings,
    }
end

-- Disable AE2 autoPull across all local passive ME Input Hatches & Buses
function Hardware.lockLocalPassiveAutoPull(compLib)
    local cl = compLib or component
    local changed, total = 0, 0
    for _, ctype in ipairs({ "me_inputhatch", "me_inputbus" }) do
        for addr in cl.list(ctype, true) do
            local p = cl.proxy(addr)
            if p then
                total = total + 1
                if safeCall(p, "getAutoPull") == true then
                    changed = changed + 1
                end
                safeCall(p, "setAutoPull", false)
            end
        end
    end
    return changed, total
end

local function writeZeroStockFluidSentinel(fp, side, stockFluids)
    local pass1 = {}
    local pass2 = {}
    for i = 1, #FLUID_SENTINELS do
        local cand = FLUID_SENTINELS[i]
        if not stockFluids or (stockFluids[cand] or 0) == 0 then
            pass1[#pass1 + 1] = cand
        else
            pass2[#pass2 + 1] = cand
        end
    end
    for _, list in ipairs({ pass1, pass2 }) do
        for i = 1, #list do
            local cand = list[i]
            local ok = safeCall(fp, "setStorageConfiguration", side, 1, {
                name = cand,
                amount = 1000,
                size = 1000,
            })
            if ok == true then
                return cand
            end
        end
    end
    return nil
end

local function writeZeroStockItemSentinel(ip, side, stockItems)
    local pass1 = {}
    local pass2 = {}
    for i = 1, #ITEM_SENTINELS do
        local cand = ITEM_SENTINELS[i]
        if not stockItems or (stockItems[cand .. ":0"] or 0) == 0 then
            pass1[#pass1 + 1] = cand
        else
            pass2[#pass2 + 1] = cand
        end
    end
    for _, list in ipairs({ pass1, pass2 }) do
        for i = 1, #list do
            local cand = list[i]
            local ok = safeCall(ip, "setStorageConfiguration", side, 1, {
                name = cand,
                damage = 0,
                size = 1,
            })
            if ok == true then
                return cand
            end
        end
    end
    return nil
end

-- Record shallow copies of configured fluid & item slots on channel metadata
local function storeChannelSlotSnapshot(channel, fluids, items)
    if not channel then return end
    local fCopy = {}
    for i = 1, #(fluids or {}) do
        local f = fluids[i]
        fCopy[i] = { name = f.name, amount = f.amount or 144000 }
    end
    local iCopy = {}
    for i = 1, #(items or {}) do
        local it = items[i]
        iCopy[i] = { name = it.name, damage = it.damage or 0, amount = it.amount or 1 }
    end
    channel.lastFluids = fCopy
    channel.lastItems = iCopy
end

-- Configure a local Passive Channel with exact recipe fluids & items (using 0-stock sentinels for empty StorageBus slots)
function Hardware.applyLocalChannelFluidsAndItems(channel, fluids, items, stock, compLib)
    local cl = compLib or component
    fluids = fluids or {}
    items = items or {}
    storeChannelSlotSnapshot(channel, fluids, items)

    if channel.mode == "storage_bus" then
        if channel.fluidStorageAddr then
            local fp = cl.proxy(channel.fluidStorageAddr)
            local side = channel.fluidStorageSide or 0
            local maxClear = math.max(#fluids, channel.lastFluidSlots or 16, 1)
            if fp then
                if #fluids == 0 then
                    channel.fluidSentinel = writeZeroStockFluidSentinel(fp, side, stock and stock.fluids or nil)
                    for slot = 2, maxClear do
                        safeCall(fp, "setStorageConfiguration", side, slot)
                    end
                    channel.lastFluidSlots = 1
                else
                    channel.fluidSentinel = nil
                    for slot = 1, #fluids do
                        local amt = math.max(1000, fluids[slot].amount or 144000)
                        safeCall(fp, "setStorageConfiguration", side, slot, {
                            name = fluids[slot].name,
                            amount = amt,
                            size = amt,
                        })
                    end
                    for slot = #fluids + 1, maxClear do
                        safeCall(fp, "setStorageConfiguration", side, slot)
                    end
                    channel.lastFluidSlots = #fluids
                end
            end
        end

        if channel.itemStorageAddr then
            local ip = cl.proxy(channel.itemStorageAddr)
            local side = channel.itemStorageSide or 0
            local maxClear = math.max(#items, channel.lastItemSlots or 16, 1)
            if ip then
                if #items == 0 then
                    channel.itemSentinel = writeZeroStockItemSentinel(ip, side, stock and stock.items or nil)
                    for slot = 2, maxClear do
                        safeCall(ip, "setStorageConfiguration", side, slot)
                    end
                    channel.lastItemSlots = 1
                else
                    channel.itemSentinel = nil
                    for slot = 1, #items do
                        safeCall(ip, "setStorageConfiguration", side, slot, {
                            name = items[slot].name,
                            damage = items[slot].damage or 0,
                            size = 1,
                        })
                    end
                    for slot = #items + 1, maxClear do
                        safeCall(ip, "setStorageConfiguration", side, slot)
                    end
                    channel.lastItemSlots = #items
                end
            end
        end
        return true
    else
        -- MFU Hatch + Bus mode (`me_inputhatch` + `me_inputbus`)
        if channel.hatchAddr then
            local hp = cl.proxy(channel.hatchAddr)
            if hp then
                safeCall(hp, "setAutoPull", false)
                local maxSlots = safeCall(hp, "getSlotSize") or 16
                local maxClear = math.min(maxSlots, math.max(#fluids, channel.lastFluidSlots or 16))
                for slot = 1, math.min(#fluids, maxSlots) do
                    local amt = math.max(144, fluids[slot].amount or 144000)
                    safeCall(hp, "setConfiguration", slot, {
                        name = fluids[slot].name,
                        amount = amt,
                        size = amt,
                    })
                end
                for slot = #fluids + 1, maxClear do
                    safeCall(hp, "setConfiguration", slot)
                end
                channel.lastFluidSlots = #fluids
            end
        end

        if channel.busAddr then
            local bp = cl.proxy(channel.busAddr)
            if bp then
                safeCall(bp, "setAutoPull", false)
                local maxSlots = safeCall(bp, "getSlotSize") or 16
                local maxClear = math.min(maxSlots, math.max(#items, channel.lastItemSlots or 16))
                for slot = 1, math.min(#items, maxSlots) do
                    safeCall(bp, "setConfiguration", slot, {
                        name = items[slot].name,
                        damage = items[slot].damage or 0,
                        size = math.max(1, items[slot].amount or 1),
                    })
                end
                for slot = #items + 1, maxClear do
                    safeCall(bp, "setConfiguration", slot)
                end
                channel.lastItemSlots = #items
            end
        end
        return true
    end
end

-- Apply a full recipe modifier + tier + catalyst to a Passive Channel
-- opts: { skipNonConsumed = bool (default true), stock = table, catalystAmount = number }
function Hardware.applyRecipeToChannel(channel, sigKey, tierData, catalystFluidName, opts)
    opts = opts or {}
    local skipNC = (opts.skipNonConsumed ~= false)
    local sig = string.format("%s@%s@%s",
        tostring(sigKey or "none"),
        tostring(catalystFluidName or "none"),
        skipNC and "nc0" or "nc1"
    )
    if channel.activeKey == sig then
        return true, false
    end

    local fluids = {}
    if catalystFluidName and catalystFluidName ~= "" then
        local catAmt = opts.catalystAmount or (tierData and tierData.catalystAmount) or 1000
        fluids[#fluids + 1] = { name = catalystFluidName, amount = math.max(144000, catAmt * 4) }
    end
    if tierData and tierData.fluidsIn then
        for i = 1, #tierData.fluidsIn do
            local f = tierData.fluidsIn[i]
            fluids[#fluids + 1] = { name = f.name, amount = math.max(144000, (f.amount or 144) * 4) }
        end
    end

    local items = {}
    if tierData and tierData.itemsIn then
        for i = 1, #tierData.itemsIn do
            local it = tierData.itemsIn[i]
            local isNC = (it.nonConsumed == true) or ((it.amount or 0) == 0)
            if not (skipNC and isNC) then
                local stockSize = (it.amount and it.amount > 0) and math.min(64, it.amount) or 1
                items[#items + 1] = { name = it.name, damage = it.damage or 0, amount = stockSize }
            end
        end
    end

    Hardware.applyChannelFluidsAndItems(channel, fluids, items, opts.stock)
    channel.activeKey = sig
    return true, true
end

function Hardware.clearChannel(channel, stock)
    if channel.activeKey == "IDLE_CLEARED" then
        return true, false
    end
    Hardware.applyChannelFluidsAndItems(channel, {}, {}, stock)
    channel.activeKey = "IDLE_CLEARED"
    return true, true
end

function Hardware.setChannelOnDemandHold(channel, _, stock)
    return Hardware.clearChannel(channel, stock)
end

-- Discover AE2 networks (`me_interface`, adapted `fluid_interface` ME Dual Interface, and `me_controller`)
function Hardware.discoverAENetworks()
    local nets = {}
    local seen = {}
    for _, ctype in ipairs({ "me_interface", "fluid_interface", "me_controller" }) do
        for addr in component.list(ctype, true) do
            if not seen[addr] then
                seen[addr] = true
                local p = component.proxy(addr)
                if p and (p.getFluidsInNetwork or p.getItemsInNetwork) then
                    local fluids = safeCall(p, "getFluidsInNetwork") or {}
                    local items = safeCall(p, "getItemsInNetwork") or {}
                    local x, y, z = readCoords(p)
                    nets[#nets + 1] = {
                        address = addr,
                        type = ctype,
                        proxy = p,
                        x = x,
                        y = y,
                        z = z,
                        fluidTypes = type(fluids) == "table" and #fluids or 0,
                        itemTypes = type(items) == "table" and #items or 0,
                    }
                end
            end
        end
    end
    table.sort(nets, function(a, b)
        local sa = (a.fluidTypes or 0) + (a.itemTypes or 0)
        local sb = (b.fluidTypes or 0) + (b.itemTypes or 0)
        if sa ~= sb then return sa > sb end
        return a.address < b.address
    end)
    return nets
end

-- Poll fluid and (unless opts.skipItems) item stock from the Stock AE2 network proxy
function Hardware.pollNetworkStock(aeProxy, opts)
    local prev = opts and opts.prevStock or nil
    local skipItems = (opts and opts.skipItems == true) and (prev ~= nil)
    local stock = {
        fluids = {},
        items = skipItems and prev.items or {},
        fluidLabels = {},
        itemLabels = skipItems and prev.itemLabels or {},
    }
    if not aeProxy then return stock end

    local flist = safeCall(aeProxy, "getFluidsInNetwork")
    if type(flist) == "table" then
        for i = 1, #flist do
            local f = flist[i]
            if type(f) == "table" and f.name then
                local amt = tonumber(f.amount or f.size) or 0
                stock.fluids[f.name] = (stock.fluids[f.name] or 0) + amt
                if f.label then stock.fluidLabels[f.name] = f.label end
            end
        end
    end

    local wantedItems = (type(opts) == "table") and opts.wantedItemNames or nil
    if not skipItems then
        local ilist = safeCall(aeProxy, "getItemsInNetwork")
        if type(ilist) == "table" then
            for i = 1, #ilist do
                local it = ilist[i]
                if type(it) == "table" and it.name then
                    if (not wantedItems) or wantedItems[it.name] or ITEM_SENTINEL_SET[it.name] then
                        local dmg = tonumber(it.damage) or 0
                        local key = it.name .. ":" .. tostring(dmg)
                        local amt = tonumber(it.size or it.amount) or 0
                        stock.items[key] = (stock.items[key] or 0) + amt
                        if it.label then stock.itemLabels[key] = it.label end
                    end
                end
            end
        end
    end

    return stock
end

-- Inspect On-Demand Subnet (`Color 1`) to see if a craft is active and whether it includes its own catalyst
function Hardware.pollOnDemandSubnet(odProxy)
    local state = {
        hasWork = false,
        hasPatternedCatalyst = false,
        patternedCatalystName = nil,
        fluidCount = 0,
        itemCount = 0,
        summary = "Idle",
        fluids = {},
        items = {},
        evacItems = {},
        catalysts = {},
        totalCatalyst = 0,
    }
    if not odProxy then return state end

    local parts = {}
    local evacMap = {}
    local flist = safeCall(odProxy, "getFluidsInNetwork")
    if type(flist) == "table" then
        for i = 1, #flist do
            local f = flist[i]
            local amt = type(f) == "table" and (tonumber(f.amount or f.size) or 0) or 0
            if type(f) == "table" and f.name and amt > 0 then
                if CATALYST_FLUID_SET[f.name] then
                    state.hasPatternedCatalyst = true
                    state.catalysts[f.name] = (state.catalysts[f.name] or 0) + amt
                    state.totalCatalyst = state.totalCatalyst + amt
                else
                    state.hasWork = true
                    if not state.fluids[f.name] then
                        state.fluidCount = state.fluidCount + 1
                        if #parts < 3 then
                            parts[#parts + 1] = f.label or f.name
                        end
                    end
                    state.fluids[f.name] = (state.fluids[f.name] or 0) + amt
                end
            end
        end
    end

    local bestCatAmt = -1
    for k, amt in pairs(state.catalysts) do
        if amt > bestCatAmt or (amt == bestCatAmt and k < tostring(state.patternedCatalystName)) then
            bestCatAmt = amt
            state.patternedCatalystName = k
        end
    end

    local ilist = safeCall(odProxy, "getItemsInNetwork")
    if type(ilist) == "table" then
        for i = 1, #ilist do
            local it = ilist[i]
            local amt = type(it) == "table" and (tonumber(it.size or it.amount) or 0) or 0
            if type(it) == "table" and it.name and amt > 0 then
                local isCatDrop = false
                if it.name == "ae2fc:fluid_drop" and type(it.label) == "string" and it.label:lower():find("excited") then
                    isCatDrop = true
                end
                if not isCatDrop then
                    state.hasWork = true
                    local dmg = tonumber(it.damage) or 0
                    local key = it.name .. ":" .. tostring(dmg)
                    if not state.items[key] then
                        state.itemCount = state.itemCount + 1
                        if #parts < 3 then
                            parts[#parts + 1] = it.label or it.name
                        end
                    end
                    state.items[key] = (state.items[key] or 0) + amt
                    if it.name ~= "ae2fc:fluid_drop" then
                        local evacKey = key .. (it.tag ~= nil and ("#" .. tostring(it.tag)) or "")
                        local rec = evacMap[evacKey]
                        if not rec then
                            rec = {
                                key = evacKey,
                                name = it.name,
                                damage = dmg,
                                amount = amt,
                                maxSize = math.max(1, math.min(64, math.floor(tonumber(it.maxSize) or 64))),
                                tag = it.tag,
                                label = it.label or it.name,
                            }
                            evacMap[evacKey] = rec
                            state.evacItems[#state.evacItems + 1] = rec
                        else
                            rec.amount = rec.amount + amt
                        end
                    end
                end
            end
        end
    end

    if #state.evacItems > 1 then
        table.sort(state.evacItems, function(a, b)
            if a.amount ~= b.amount then return a.amount > b.amount end
            return a.key < b.key
        end)
    end

    if state.hasWork then
        state.summary = table.concat(parts, " + ")
        if state.fluidCount + state.itemCount > #parts then
            state.summary = state.summary .. string.format(" (+%d)", (state.fluidCount + state.itemCount) - #parts)
        end
    end
    return state
end

-- ============================================================================
-- Multi-Server OC Rack Cluster Networking (Master + `--worker` Servers)
-- ============================================================================

local function nextReqId()
    RPC_SEQ = RPC_SEQ + 1
    return tostring(RPC_SEQ)
end

local function getPrimaryModem()
    local addr = component.list("modem", true)()
    if not addr then return nil, nil end
    local m = component.proxy(addr)
    if m and m.open then
        pcall(m.open, Hardware.CLUSTER_PORT)
    end
    return m, addr
end

local function cloneStatusForWire(st)
    return {
        address = st.address,
        online = st.online,
        supportsConvControl = st.supportsConvControl,
        x = st.x,
        y = st.y,
        z = st.z,
        active = st.active,
        machineActive = st.machineActive,
        hasWork = st.hasWork,
        workAllowed = st.workAllowed,
        progress = st.progress,
        maxProgress = st.maxProgress,
        discountPct = st.discountPct,
        runningTicks = st.runningTicks,
        coilHeat = st.coilHeat,
        extraCatalystNeeded = st.extraCatalystNeeded,
        convergenceEnabled = st.convergenceEnabled,
        convergenceAchieved = st.convergenceAchieved,
        catalystTier = st.catalystTier,
        maxInputEu = st.maxInputEu,
        hatchAmps = st.hatchAmps,
        hatchTier = st.hatchTier,
        hatchLabel = st.hatchLabel,
        liveEut = st.liveEut,
    }
end

local function extractSentinelStock(stock)
    if not stock then return nil end
    local sf, si = {}, {}
    if stock.fluids then
        for i = 1, #FLUID_SENTINELS do
            local k = FLUID_SENTINELS[i]
            if (stock.fluids[k] or 0) > 0 then sf[k] = stock.fluids[k] end
        end
    end
    if stock.items then
        for i = 1, #ITEM_SENTINELS do
            local k = ITEM_SENTINELS[i] .. ":0"
            if (stock.items[k] or 0) > 0 then si[k] = stock.items[k] end
        end
    end
    return { fluids = sf, items = si }
end

local function sortCoordsAddresses(addrs, coords)
    table.sort(addrs, function(a, b)
        local ca, cb = coords[a], coords[b]
        if ca and cb then
            if ca.z ~= cb.z then return ca.z < cb.z end
            if ca.x ~= cb.x then return ca.x < cb.x end
            if ca.y ~= cb.y then return ca.y < cb.y end
        elseif ca ~= nil or cb ~= nil then
            return ca ~= nil
        end
        return a < b
    end)
end

-- Create an in-process or daemon RPC handler bound to `compLib` (`component` on real worker)
function Hardware.createWorkerResponder(compLib)
    local cl = compLib or component
    local localDtpfs = {}
    local dtpfByAddr = {}

    local function refreshLocalDtpfs()
        localDtpfs = Hardware.discoverLocalDTPFs(cl)
        dtpfByAddr = {}
        for i = 1, #localDtpfs do
            dtpfByAddr[localDtpfs[i].address] = localDtpfs[i]
        end
    end

    local function sendChunks(modemProxy, sender, msgType, reqId, statusList, epPayload)
        local chunks = {}
        local startIdx = 1
        if epPayload then
            local epCount = #(epPayload.hatches or {}) + #(epPayload.buses or {})
                + #(epPayload.itemStorageBuses or {}) + #(epPayload.fluidStorageBuses or {})
            if epCount > 12 or #statusList == 0 then
                chunks[#chunks + 1] = { ep = epPayload, dtpfs = {} }
            else
                local firstSlice = {}
                local n = math.min(#statusList, MAX_DTPF_CHUNK)
                for i = 1, n do firstSlice[i] = statusList[i] end
                chunks[#chunks + 1] = { ep = epPayload, dtpfs = firstSlice }
                startIdx = n + 1
            end
        end
        for _ = 1, 64 do
            if startIdx > #statusList and #chunks > 0 then break end
            local slice = {}
            for i = startIdx, math.min(#statusList, startIdx + MAX_DTPF_CHUNK - 1) do
                slice[#slice + 1] = statusList[i]
            end
            chunks[#chunks + 1] = { dtpfs = slice }
            startIdx = startIdx + MAX_DTPF_CHUNK
        end
        local total = #chunks
        for idx = 1, total do
            modemProxy.send(
                sender,
                Hardware.CLUSTER_PORT,
                msgType,
                tostring(reqId),
                idx,
                total,
                serialization.serialize(chunks[idx])
            )
        end
    end

    local function buildStatuses()
        local list = {}
        for i = 1, #localDtpfs do
            list[i] = cloneStatusForWire(Hardware.getLocalDTPFStatus(localDtpfs[i]))
        end
        return list
    end

    local responder = {}
    function responder.handleMessage(modemProxy, sender, port, msgType, reqId, payload)
        if port ~= Hardware.CLUSTER_PORT or not modemProxy then return false end

        if msgType == "DTPF_PING" then
            refreshLocalDtpfs()
            local ep = Hardware.discoverLocalPassiveEndpoints(cl)
            local compactEp = {
                hatches = ep.hatches,
                buses = ep.buses,
                hatchCoords = ep.hatchCoords,
                busCoords = ep.busCoords,
                itemStorageBuses = ep.itemStorageBuses,
                fluidStorageBuses = ep.fluidStorageBuses,
                autoPullOnCount = ep.autoPullOnCount,
            }
            sendChunks(modemProxy, sender, "DTPF_PONG", reqId, buildStatuses(), compactEp)
            return true
        elseif msgType == "DTPF_POLL" then
            if #localDtpfs == 0 then refreshLocalDtpfs() end
            sendChunks(modemProxy, sender, "DTPF_SNAP", reqId, buildStatuses(), nil)
            return true
        elseif msgType == "DTPF_EXEC" then
            local cmd = (type(payload) == "string") and serialization.unserialize(payload) or nil
            local ackTbl = { ok = false }
            if type(cmd) == "table" then
                if cmd.op == "work" then
                    if not dtpfByAddr[cmd.addr] then refreshLocalDtpfs() end
                    local entry = dtpfByAddr[cmd.addr]
                    if entry then
                        ackTbl.ok = Hardware.setLocalDTPFWorkAllowed(entry, cmd.ok)
                    end
                elseif cmd.op == "conv" then
                    if not dtpfByAddr[cmd.addr] then refreshLocalDtpfs() end
                    local entry = dtpfByAddr[cmd.addr]
                    if entry then
                        ackTbl.ok = Hardware.setLocalDTPFConvergence(entry, cmd.en, cmd.tier)
                    end
                elseif cmd.op == "lock_autopull" then
                    local chg, tot = Hardware.lockLocalPassiveAutoPull(cl)
                    ackTbl.ok = true
                    ackTbl.changed = chg
                    ackTbl.total = tot
                elseif cmd.op == "channel" and type(cmd.ch) == "table" then
                    ackTbl.ok = Hardware.applyLocalChannelFluidsAndItems(cmd.ch, cmd.fluids, cmd.items, cmd.stock, cl)
                    ackTbl.fluidSentinel = cmd.ch.fluidSentinel
                    ackTbl.itemSentinel = cmd.ch.itemSentinel
                end
            end
            modemProxy.send(
                sender,
                Hardware.CLUSTER_PORT,
                "DTPF_ACK",
                tostring(reqId),
                1,
                1,
                serialization.serialize(ackTbl)
            )
            return true
        end
        return false
    end

    return responder
end

-- Headless worker loop for additional Tier 3 Servers in an OC Rack (`main.lua --worker`)
function Hardware.runWorkerDaemon()
    local modem, mAddr = getPrimaryModem()
    if not modem then
        io.stderr:write("ERROR: main.lua --worker requires a Network Card (modem) installed in this Server.\n")
        return false
    end
    local dtpfs = Hardware.discoverLocalDTPFs(component)
    local ep = Hardware.discoverLocalPassiveEndpoints(component)
    local responder = Hardware.createWorkerResponder(component)

    print("=== DTPF RACK WORKER DAEMON ACTIVE ===")
    print(string.format("Modem Addr   : %s | Cluster Port: %d", tostring(mAddr):sub(1, 8), Hardware.CLUSTER_PORT))
    print(string.format("Local Hardware: %d DTPFs | %d Hatches | %d Buses | %d FluidSB + %d ItemSB",
        #dtpfs, #ep.hatches, #ep.buses, #ep.fluidStorageBuses, #ep.itemStorageBuses))
    print("Waiting for Master DTPF Controller commands... (Ctrl+C to stop)")

    while true do
        local ev, _, sender, port, _, msgType, reqId, p1 = event.pull(2.0)
        if ev == "interrupted" then
            break
        elseif ev == "modem_message" and port == Hardware.CLUSTER_PORT then
            local ok, err = pcall(responder.handleMessage, modem, sender, port, msgType, reqId, p1)
            if not ok then
                io.stderr:write("Worker RPC error: " .. tostring(err) .. "\n")
            end
        end
    end
    pcall(modem.close, Hardware.CLUSTER_PORT)
    print("DTPF Rack Worker daemon stopped cleanly.")
    return true
end

local function collectChunkedReplies(expectedMsg, reqId, timeout, expectWorkers)
    local collected = {}
    local completedCount = 0
    local expectedCount = 0
    if expectWorkers then
        for _ in pairs(expectWorkers) do expectedCount = expectedCount + 1 end
    end

    for _ = 1, 64 do
        local ev, _, sender, port, _, msgType, rId, idx, total, raw = event.pull(timeout or 0.12, "modem_message")
        if not ev then break end
        if port == Hardware.CLUSTER_PORT and msgType == expectedMsg and tostring(rId) == reqId and sender and type(raw) == "string" then
            local ok, tbl = pcall(serialization.unserialize, raw)
            if ok and type(tbl) == "table" then
                local rec = collected[sender]
                if not rec then
                    rec = { chunks = {}, total = tonumber(total) or 1, got = 0 }
                    collected[sender] = rec
                end
                local cIdx = tonumber(idx) or 1
                if not rec.chunks[cIdx] then
                    rec.chunks[cIdx] = tbl
                    rec.got = rec.got + 1
                    if rec.got >= rec.total and not rec.done then
                        rec.done = true
                        completedCount = completedCount + 1
                    end
                end
                if expectWorkers and completedCount >= expectedCount then
                    break
                end
            end
        end
    end
    return collected
end

local function sendWorkerExec(workerAddr, cmdTbl)
    local modem = getPrimaryModem()
    if not modem then return nil end
    local reqId = nextReqId()
    modem.send(workerAddr, Hardware.CLUSTER_PORT, "DTPF_EXEC", reqId, serialization.serialize(cmdTbl))
    for _ = 1, 16 do
        local ev, _, sender, port, _, msgType, rId, _, _, raw = event.pull(0.05, "modem_message")
        if not ev then break end
        if port == Hardware.CLUSTER_PORT and msgType == "DTPF_ACK" and sender == workerAddr and tostring(rId) == reqId then
            if type(raw) == "string" then
                local ok, ack = pcall(serialization.unserialize, raw)
                if ok and type(ack) == "table" then return ack end
            end
            return { ok = true }
        end
    end
    return { ok = true }
end

function Hardware.discoverWorkers(timeout)
    local modem = getPrimaryModem()
    if not modem then
        Hardware.resetClusterState()
        return 0
    end
    Hardware.resetClusterState()

    local reqId = nextReqId()
    modem.broadcast(Hardware.CLUSTER_PORT, "DTPF_PING", reqId)
    local replies = collectChunkedReplies("DTPF_PONG", reqId, timeout or 0.12, nil)

    for sender, rec in pairs(replies) do
        local wEp = {
            hatches = {}, buses = {}, hatchCoords = {}, busCoords = {},
            itemStorageBuses = {}, fluidStorageBuses = {},
        }
        local wDtpfs = {}
        for idx = 1, math.max(rec.total, #rec.chunks) do
            local chunk = rec.chunks[idx]
            if chunk then
                if chunk.ep then
                    wEp.hatches = chunk.ep.hatches or wEp.hatches
                    wEp.buses = chunk.ep.buses or wEp.buses
                    wEp.hatchCoords = chunk.ep.hatchCoords or wEp.hatchCoords
                    wEp.busCoords = chunk.ep.busCoords or wEp.busCoords
                    wEp.itemStorageBuses = chunk.ep.itemStorageBuses or wEp.itemStorageBuses
                    wEp.fluidStorageBuses = chunk.ep.fluidStorageBuses or wEp.fluidStorageBuses
                end
                for _, st in ipairs(chunk.dtpfs or {}) do
                    wDtpfs[#wDtpfs + 1] = st
                    Hardware._remoteDtpfStatus[st.address] = st
                    Hardware._remoteOwner[st.address] = sender
                end
            end
        end
        for _, a in ipairs(wEp.hatches) do Hardware._remoteOwner[a] = sender end
        for _, a in ipairs(wEp.buses) do Hardware._remoteOwner[a] = sender end
        for _, sb in ipairs(wEp.itemStorageBuses) do
            if sb.address then Hardware._remoteOwner[sb.address] = sender end
        end
        for _, sb in ipairs(wEp.fluidStorageBuses) do
            if sb.address then Hardware._remoteOwner[sb.address] = sender end
        end
        Hardware._workers[sender] = {
            dtpfs = wDtpfs,
            endpoints = wEp,
            missedPolls = 0,
        }
    end
    return Hardware.getWorkerCount()
end

function Hardware.pollWorkers(timeout)
    if next(Hardware._workers) == nil then return 0 end
    local modem = getPrimaryModem()
    if not modem then return 0 end

    local reqId = nextReqId()
    local expected = {}
    for wAddr in pairs(Hardware._workers) do
        expected[wAddr] = true
        modem.send(wAddr, Hardware.CLUSTER_PORT, "DTPF_POLL", reqId)
    end
    local replies = collectChunkedReplies("DTPF_SNAP", reqId, timeout or 0.10, expected)

    local alive = 0
    for wAddr, wData in pairs(Hardware._workers) do
        local rec = replies[wAddr]
        if rec then
            wData.missedPolls = 0
            alive = alive + 1
            for idx = 1, math.max(rec.total, #rec.chunks) do
                local chunk = rec.chunks[idx]
                if chunk and chunk.dtpfs then
                    for _, st in ipairs(chunk.dtpfs) do
                        Hardware._remoteDtpfStatus[st.address] = st
                    end
                end
            end
        else
            wData.missedPolls = (wData.missedPolls or 0) + 1
            if wData.missedPolls >= 3 then
                for _, d in ipairs(wData.dtpfs or {}) do
                    local st = Hardware._remoteDtpfStatus[d.address]
                    if st then st.online = false end
                end
            end
        end
    end
    return alive
end

-- Unified cluster-aware APIs used by Scheduler & UI
function Hardware.discoverDTPFs()
    local byAddr = {}
    local localList = Hardware.discoverLocalDTPFs(component)
    for i = 1, #localList do
        byAddr[localList[i].address] = localList[i]
    end
    for wAddr, wData in pairs(Hardware._workers) do
        for _, st in ipairs(wData.dtpfs or {}) do
            if not byAddr[st.address] then
                byAddr[st.address] = {
                    address = st.address,
                    x = st.x,
                    y = st.y,
                    z = st.z,
                    isRemote = true,
                    workerAddr = wAddr,
                }
            end
        end
    end
    local merged = {}
    for _, v in pairs(byAddr) do merged[#merged + 1] = v end
    table.sort(merged, function(a, b)
        local za, zb = a.z or math.huge, b.z or math.huge
        if za ~= zb then return za < zb end
        local xa, xb = a.x or math.huge, b.x or math.huge
        if xa ~= xb then return xa < xb end
        local ya, yb = a.y or math.huge, b.y or math.huge
        if ya ~= yb then return ya < yb end
        return a.address < b.address
    end)
    return merged
end

function Hardware.discoverPassiveEndpoints()
    local ep = Hardware.discoverLocalPassiveEndpoints(component)
    if next(Hardware._workers) == nil then
        return ep
    end

    local hSeen, bSeen, iSeen, fSeen = {}, {}, {}, {}
    for _, a in ipairs(ep.hatches) do hSeen[a] = true end
    for _, a in ipairs(ep.buses) do bSeen[a] = true end
    for _, s in ipairs(ep.itemStorageBuses) do iSeen[s.address] = true end
    for _, s in ipairs(ep.fluidStorageBuses) do fSeen[s.address] = true end

    local autoPullOnTotal = ep.autoPullOnCount or 0
    for _, wData in pairs(Hardware._workers) do
        local wep = wData.endpoints or {}
        autoPullOnTotal = autoPullOnTotal + (wep.autoPullOnCount or 0)
        for _, a in ipairs(wep.hatches or {}) do
            if not hSeen[a] then
                hSeen[a] = true
                ep.hatches[#ep.hatches + 1] = a
            end
            if wep.hatchCoords and wep.hatchCoords[a] then
                ep.hatchCoords[a] = wep.hatchCoords[a]
            end
        end
        for _, a in ipairs(wep.buses or {}) do
            if not bSeen[a] then
                bSeen[a] = true
                ep.buses[#ep.buses + 1] = a
            end
            if wep.busCoords and wep.busCoords[a] then
                ep.busCoords[a] = wep.busCoords[a]
            end
        end
        for _, s in ipairs(wep.itemStorageBuses or {}) do
            if s.address and not iSeen[s.address] then
                iSeen[s.address] = true
                ep.itemStorageBuses[#ep.itemStorageBuses + 1] = s
            end
        end
        for _, s in ipairs(wep.fluidStorageBuses or {}) do
            if s.address and not fSeen[s.address] then
                fSeen[s.address] = true
                ep.fluidStorageBuses[#ep.fluidStorageBuses + 1] = s
            end
        end
    end

    sortCoordsAddresses(ep.hatches, ep.hatchCoords)
    sortCoordsAddresses(ep.buses, ep.busCoords)
    table.sort(ep.itemStorageBuses, function(a, b) return a.address < b.address end)
    table.sort(ep.fluidStorageBuses, function(a, b) return a.address < b.address end)

    ep.autoPullOnCount = autoPullOnTotal
    ep.warnings = {}
    if (#ep.fluidStorageBuses + #ep.itemStorageBuses) > 0 and (#ep.fluidStorageBuses ~= #ep.itemStorageBuses) then
        ep.warnings[#ep.warnings + 1] = string.format(
            "StorageBus mismatch (%d fluid vs %d item): do NOT place ME Fluid Storage Bus and ME Storage Bus on the SAME AE2 cable block (fluid_storagebus priority=2 shadows me_storagebus). Place them on 2 separate cable blocks touching the Adapter.",
            #ep.fluidStorageBuses, #ep.itemStorageBuses
        )
    end
    if autoPullOnTotal > 0 then
        ep.warnings[#ep.warnings + 1] = string.format(
            "%d passive Hatch/Bus endpoint(s) still have autoPull=ON! Launch GUI or run `main.lua --lock` BEFORE connecting unfiltered Main Net so Main Net does not dump into them.",
            autoPullOnTotal
        )
    end
    return ep
end

function Hardware.lockAllPassiveAutoPull()
    local changed, total = Hardware.lockLocalPassiveAutoPull(component)
    for wAddr, _ in pairs(Hardware._workers) do
        local ack = sendWorkerExec(wAddr, { op = "lock_autopull" })
        if ack then
            changed = changed + (tonumber(ack.changed) or 0)
            total = total + (tonumber(ack.total) or 0)
        end
    end
    return changed, total
end

function Hardware.getDTPFStatus(entry, opts)
    local wAddr = entry.workerAddr or Hardware._remoteOwner[entry.address]
    if entry.isRemote or wAddr then
        local cached = Hardware._remoteDtpfStatus[entry.address]
        if cached then
            local copy = cloneStatusForWire(cached)
            copy.isRemote = true
            return copy
        end
        return {
            address = entry.address,
            online = false,
            supportsConvControl = false,
            x = entry.x,
            y = entry.y,
            z = entry.z,
            isRemote = true,
            workAllowed = true,
            discountPct = 0,
            catalystTier = 4,
        }
    end
    return Hardware.getLocalDTPFStatus(entry, opts)
end

function Hardware.setDTPFConvergence(entry, enabled, catalystTierIndex)
    local wAddr = entry.workerAddr or Hardware._remoteOwner[entry.address]
    if entry.isRemote or wAddr then
        if not wAddr then return false, "missing worker owner" end
        local val = enabled and true or false
        local ack = sendWorkerExec(wAddr, { op = "conv", addr = entry.address, en = val, tier = catalystTierIndex })
        local cached = Hardware._remoteDtpfStatus[entry.address]
        if cached then
            cached.convergenceEnabled = val
            if catalystTierIndex then cached.catalystTier = catalystTierIndex end
        end
        return ack and ack.ok or false
    end
    return Hardware.setLocalDTPFConvergence(entry, enabled, catalystTierIndex)
end

function Hardware.setDTPFWorkAllowed(entry, allowed)
    local wAddr = entry.workerAddr or Hardware._remoteOwner[entry.address]
    if entry.isRemote or wAddr then
        if not wAddr then return false end
        local val = allowed and true or false
        local ack = sendWorkerExec(wAddr, { op = "work", addr = entry.address, ok = val })
        local cached = Hardware._remoteDtpfStatus[entry.address]
        if cached then cached.workAllowed = val end
        return ack and ack.ok or false
    end
    return Hardware.setLocalDTPFWorkAllowed(entry, allowed)
end

function Hardware.applyChannelFluidsAndItems(channel, fluids, items, stock)
    fluids = fluids or {}
    items = items or {}
    storeChannelSlotSnapshot(channel, fluids, items)
    local hOwner = channel.hatchAddr and Hardware._remoteOwner[channel.hatchAddr] or nil
    local bOwner = channel.busAddr and Hardware._remoteOwner[channel.busAddr] or nil
    local fOwner = channel.fluidStorageAddr and Hardware._remoteOwner[channel.fluidStorageAddr] or nil
    local iOwner = channel.itemStorageAddr and Hardware._remoteOwner[channel.itemStorageAddr] or nil

    if not hOwner and not bOwner and not fOwner and not iOwner then
        return Hardware.applyLocalChannelFluidsAndItems(channel, fluids, items, stock, component)
    end

    local localCh = {}
    local hasLocal = false
    local remoteByWorker = {}
    local function routeField(addrField, sideField, owner)
        local addr = channel[addrField]
        if not addr then return end
        if owner then
            local rch = remoteByWorker[owner]
            if not rch then
                rch = {
                    id = channel.id,
                    mode = channel.mode,
                    lastFluidSlots = channel.lastFluidSlots,
                    lastItemSlots = channel.lastItemSlots,
                }
                remoteByWorker[owner] = rch
            end
            rch[addrField] = addr
            if sideField then rch[sideField] = channel[sideField] end
        else
            localCh.mode = channel.mode
            localCh.lastFluidSlots = channel.lastFluidSlots
            localCh.lastItemSlots = channel.lastItemSlots
            localCh[addrField] = addr
            if sideField then localCh[sideField] = channel[sideField] end
            hasLocal = true
        end
    end

    if channel.mode == "storage_bus" then
        routeField("fluidStorageAddr", "fluidStorageSide", fOwner)
        routeField("itemStorageAddr", "itemStorageSide", iOwner)
    else
        routeField("hatchAddr", nil, hOwner)
        routeField("busAddr", nil, bOwner)
    end

    if hasLocal then
        Hardware.applyLocalChannelFluidsAndItems(localCh, fluids, items, stock, component)
        if localCh.fluidSentinel ~= nil then channel.fluidSentinel = localCh.fluidSentinel end
        if localCh.itemSentinel ~= nil then channel.itemSentinel = localCh.itemSentinel end
    end

    local miniStock = (channel.mode == "storage_bus") and extractSentinelStock(stock) or nil
    for wAddr, rch in pairs(remoteByWorker) do
        local ack = sendWorkerExec(wAddr, {
            op = "channel",
            ch = rch,
            fluids = fluids,
            items = items,
            stock = miniStock,
        })
        if ack then
            if rch.fluidStorageAddr then channel.fluidSentinel = ack.fluidSentinel end
            if rch.itemStorageAddr then channel.itemSentinel = ack.itemSentinel end
        end
    end

    channel.lastFluidSlots = #fluids
    channel.lastItemSlots = #items
    if #fluids > 0 then channel.fluidSentinel = nil end
    if #items > 0 then channel.itemSentinel = nil end
    return true
end

-- ============================================================================
-- 2-Way OC Transposer + Dual Interface Catalyst Bridge Helpers
-- ============================================================================

function Hardware.discoverTransposers(compLib)
    local cl = compLib or component
    local out = {}
    for addr in cl.list("transposer", true) do
        local p = cl.proxy(addr)
        local tankSides, filledSide, maxFill = {}, nil, 0
        if p and p.getFluidInTank then
            for side = 0, 5 do
                local tanks = safeCall(p, "getFluidInTank", side)
                if type(tanks) == "table" and #tanks > 0 then
                    tankSides[#tankSides + 1] = side
                    local sum = 0
                    for t = 1, #tanks do
                        sum = sum + (tonumber(tanks[t] and tanks[t].amount) or 0)
                    end
                    if sum > maxFill then
                        maxFill = sum
                        filledSide = side
                    end
                end
            end
        end
        out[#out + 1] = {
            address = addr,
            tankSides = tankSides,
            filledSide = filledSide,
        }
    end
    table.sort(out, function(a, b) return a.address < b.address end)
    return out
end

function Hardware.setDualInterfaceFluidSlot(ifAddr, slot, fluidName, compLib)
    local cl = compLib or component
    local p = ifAddr and cl.proxy(ifAddr) or nil
    if not p then return false end
    local slotIdx = slot or 1
    if type(fluidName) == "string" and fluidName ~= "" then
        local ok = safeCall(p, "setFluidInterfaceConfiguration", slotIdx, {
            name = fluidName,
            amount = 1000,
            size = 1000,
        })
        return ok == true
    end
    local ok = safeCall(p, "setFluidInterfaceConfiguration", slotIdx)
    return ok == true
end

function Hardware.getTransposerTankLevel(tpAddr, side, tankNum, compLib)
    local cl = compLib or component
    local tp = tpAddr and cl.proxy(tpAddr) or nil
    if not tp then return 0 end
    local lvl = safeCall(tp, "getTankLevel", side, tankNum or 1)
    if type(lvl) == "number" then
        return math.max(0, math.floor(lvl))
    end
    local info = safeCall(tp, "getFluidInTank", side, tankNum or 1)
    if type(info) == "table" then
        if info.amount ~= nil then
            return math.max(0, math.floor(tonumber(info.amount) or 0))
        end
        if type(info[1]) == "table" and info[1].amount ~= nil then
            return math.max(0, math.floor(tonumber(info[1].amount) or 0))
        end
    end
    return 0
end

function Hardware.transferViaTransposer(tpAddr, srcSide, dstSide, maxLiters, compLib)
    local cl = compLib or component
    local tp = tpAddr and cl.proxy(tpAddr) or nil
    if not tp then return false, 0 end
    local ok, moved = safeCall(tp, "transferFluid", srcSide, dstSide, math.max(1, math.floor(tonumber(maxLiters) or 1000)))
    return (ok == true), math.max(0, math.floor(tonumber(moved) or 0))
end

function Hardware.setDualInterfaceItemSlot(ifAddr, slot, itemSpec, compLib)
    local cl = compLib or component
    local p = ifAddr and cl.proxy(ifAddr) or nil
    if not p then return false end
    local slotIdx = slot or 1
    if type(itemSpec) == "table" and type(itemSpec.name) == "string" and itemSpec.name ~= "" then
        local ok = safeCall(p, "setInterfaceConfiguration", slotIdx, {
            name = itemSpec.name,
            damage = math.floor(tonumber(itemSpec.damage) or 0),
            size = math.max(1, math.min(64, math.floor(tonumber(itemSpec.size) or 64))),
            tag = itemSpec.tag,
        })
        return ok == true
    end
    local ok = safeCall(p, "setInterfaceConfiguration", slotIdx)
    return ok == true
end

function Hardware.getTransposerSlotCount(tpAddr, side, slot, compLib)
    local cl = compLib or component
    local tp = tpAddr and cl.proxy(tpAddr) or nil
    if not tp then return 0 end
    local slotIdx = slot or 1
    local cnt = safeCall(tp, "getSlotStackSize", side, slotIdx)
    if type(cnt) == "number" then
        return math.max(0, math.floor(cnt))
    end
    local stack = safeCall(tp, "getStackInSlot", side, slotIdx)
    if type(stack) == "table" then
        return math.max(0, math.floor(tonumber(stack.size or stack.amount) or 0))
    end
    return 0
end

function Hardware.transferItemViaTransposer(tpAddr, srcSide, dstSide, maxItems, srcSlot, sinkSlot, compLib)
    local cl = compLib or component
    local tp = tpAddr and cl.proxy(tpAddr) or nil
    if not tp then return false, 0 end
    local cnt = math.max(1, math.floor(tonumber(maxItems) or 64))
    local r1, r2
    if srcSlot ~= nil and sinkSlot ~= nil then
        r1, r2 = safeCall(tp, "transferItem", srcSide, dstSide, cnt, math.max(1, math.floor(tonumber(srcSlot))), math.max(1, math.floor(tonumber(sinkSlot))))
    elseif srcSlot ~= nil then
        r1, r2 = safeCall(tp, "transferItem", srcSide, dstSide, cnt, math.max(1, math.floor(tonumber(srcSlot))))
    else
        r1, r2 = safeCall(tp, "transferItem", srcSide, dstSide, cnt)
    end
    -- OpenComputers Transposer.transferItem returns a single integer moved count,
    -- while some harnesses may return (true, count).
    if type(r1) == "number" then
        return true, math.max(0, math.floor(r1))
    elseif r1 == true then
        return true, math.max(0, math.floor(tonumber(r2) or 0))
    end
    return false, 0
end

-- ============================================================================
-- Mainnet AE2 Maintainer & In-Game OC Mesh (`MESH_PORT = 4205`) Helpers
-- ============================================================================

local function configureMeshWake(m, wakeMsg)
    if m and type(m.setWakeMessage) == "function" then
        local needWake = true
        if type(m.getWakeMessage) == "function" then
            local okWk, curWk = pcall(m.getWakeMessage)
            if okWk and curWk == wakeMsg then needWake = false end
        end
        if needWake then pcall(m.setWakeMessage, wakeMsg, true) end
    end
end

local function getMeshTransports(compLib)
    Hardware.WAKE_MSG = Hardware.WAKE_MSG or "GTNH_WAKE"
    local cl = compLib or component
    local firstModem, firstAddr, wModem, wAddr = nil, nil, nil, nil
    if cl.list then
        for addr in cl.list("modem", true) do
            local m = cl.proxy(addr)
            if m then
                if m.open then pcall(m.open, Hardware.MESH_PORT) end
                local isW = false
                if m.isWireless then
                    local okW, rW = pcall(m.isWireless)
                    isW = okW and (rW == true)
                end
                if isW and m.setStrength then pcall(m.setStrength, 400) end
                configureMeshWake(m, Hardware.WAKE_MSG)
                if not firstModem then firstModem, firstAddr = m, addr end
                if isW and not wModem then wModem, wAddr = m, addr end
            end
        end
    elseif cl.isAvailable and cl.isAvailable("modem") and cl.modem then
        local m = cl.modem
        if m.open then pcall(m.open, Hardware.MESH_PORT) end
        local isW = false
        if m.isWireless then
            local okW, rW = pcall(m.isWireless)
            isW = okW and (rW == true)
        end
        if isW and m.setStrength then pcall(m.setStrength, 400) end
        configureMeshWake(m, Hardware.WAKE_MSG)
        firstModem, firstAddr = m, m.address or "modem"
    end
    local modem, mAddr = wModem or firstModem, wAddr or firstAddr
    local tunnel, tAddr = nil, nil
    local ta = cl.list and cl.list("tunnel", true)() or nil
    if ta then
        tunnel, tAddr = cl.proxy(ta), ta
        configureMeshWake(tunnel, Hardware.WAKE_MSG)
    end
    return modem, mAddr, tunnel, tAddr
end

function Hardware.hasMeshPeer()
    return Hardware._mainnetMeshAddr ~= nil
end

function Hardware.openMeshPort(compLib)
    local modem, _, tunnel = getMeshTransports(compLib)
    return modem, tunnel
end

local function sendMeshPacket(compLib, targetAddr, viaTunnel, msgType, ...)
    local modem, _, tunnel = getMeshTransports(compLib)
    if viaTunnel and tunnel and tunnel.send then
        return pcall(tunnel.send, msgType, ...)
    elseif modem then
        if targetAddr and modem.send then
            return pcall(modem.send, targetAddr, Hardware.MESH_PORT, msgType, ...)
        elseif modem.broadcast then
            return pcall(modem.broadcast, Hardware.MESH_PORT, msgType, ...)
        end
    elseif tunnel and tunnel.send then
        return pcall(tunnel.send, msgType, ...)
    end
    return false
end

function Hardware.findLocalMainnetProxy(cfg, compLib)
    local cl = compLib or component
    local explicit = cfg and cfg.mainnetAddr
    if explicit == "none" then
        return nil, nil, "disabled"
    end
    if type(explicit) == "string" and explicit ~= "" and explicit ~= "auto" then
        local p = cl.proxy(explicit)
        if p and p.getCpus and (p.getCraftables or p.getCraftable) then
            return p, explicit, "adapter"
        end
        return nil, nil, "missing"
    end

    local best, bestAddr, bestScore = nil, nil, -1
    local seen = {}
    for _, spec in ipairs({ { "me_controller", 1000000 }, { "me_interface", 0 }, { "fluid_interface", 0 } }) do
        local ctype, bonus = spec[1], spec[2]
        if cl.list then
            for addr in cl.list(ctype, true) do
                if not seen[addr] then
                    seen[addr] = true
                    local p = cl.proxy(addr)
                    if p and p.getCpus and (p.getCraftables or p.getCraftable) then
                        local cpus = safeCall(p, "getCpus")
                        local nCpus = (type(cpus) == "table") and #cpus or 0
                        if nCpus > 0 then
                            local fl = safeCall(p, "getFluidsInNetwork")
                            local nFl = (type(fl) == "table") and #fl or 0
                            local score = bonus + nCpus * 1000 + nFl
                            if score > bestScore then
                                bestScore, best, bestAddr = score, p, addr
                            end
                        end
                    end
                end
            end
        end
    end
    return best, bestAddr, best and "adapter" or nil
end

local function inspectMainnetCpusAndStocks(proxy, itemsReq)
    local cpusRaw = safeCall(proxy, "getCpus")
    if type(cpusRaw) ~= "table" then
        return nil, "getCpus failed"
    end
    local totalCpus, freeCpus = 0, 0
    local busyByKey, busyByLabel = {}, {}
    for i = 1, #cpusRaw do
        local cpu = cpusRaw[i]
        if type(cpu) == "table" and cpu.name and cpu.name ~= "" then
            totalCpus = totalCpus + 1
            if cpu.busy == true then
                if cpu.cpu and cpu.cpu.finalOutput then
                    local fin = safeCall(cpu.cpu, "finalOutput")
                    if type(fin) == "table" then
                        if fin.label and fin.label ~= "" then
                            busyByLabel[fin.label] = busyByLabel[fin.label] or cpu.name
                        end
                        if fin.name == "ae2fc:fluid_drop" or type(fin.fluid) == "table" then
                            local fl = type(fin.fluid) == "table" and fin.fluid or nil
                            local dLbl = tostring((fl and fl.label) or fin.label or ""):gsub("^drop of ", "")
                            if dLbl ~= "" then busyByLabel[dLbl] = busyByLabel[dLbl] or cpu.name end
                            if fl and fl.name and fl.name ~= "" then
                                busyByKey["fluid:" .. fl.name .. ":0"] = busyByKey["fluid:" .. fl.name .. ":0"] or cpu.name
                            end
                        end
                        if fin.name and fin.name ~= "" then
                            local fType = (fin.maxSize == nil) and "fluid" or "item"
                            local k = fType .. ":" .. fin.name .. ":" .. tostring(fType == "item" and (tonumber(fin.damage) or 0) or 0)
                            busyByKey[k] = busyByKey[k] or cpu.name
                        end
                    end
                end
            else
                freeCpus = freeCpus + 1
            end
        end
    end

    local stocks = {}
    local reqs = itemsReq or {}
    local needFluidFallback = false
    if not proxy.getFluidInNetwork then
        for i = 1, #reqs do
            if reqs[i].type == "fluid" then needFluidFallback = true break end
        end
    end
    local fluidAmt = nil
    local function getFluidMap()
        if fluidAmt then return fluidAmt end
        fluidAmt = {}
        if proxy.getFluidsInNetwork then
            local fl = safeCall(proxy, "getFluidsInNetwork")
            if type(fl) == "table" then
                for i = 1, #fl do
                    local f = fl[i]
                    if type(f) == "table" and f.name then
                        fluidAmt[f.name] = (fluidAmt[f.name] or 0) + math.floor(tonumber(f.amount or f.size) or 0)
                    end
                end
            end
        end
        return fluidAmt
    end
    if needFluidFallback then getFluidMap() end

    for i = 1, #reqs do
        local req = reqs[i]
        if type(req) == "table" and req.id then
            local qty = 0
            if req.type == "fluid" then
                if proxy.getFluidInNetwork and req.name and req.name ~= "" then
                    local st = safeCall(proxy, "getFluidInNetwork", req.name)
                    if type(st) == "table" then
                        qty = math.floor(tonumber(st.amount or st.size) or 0)
                    else
                        qty = 0
                    end
                else
                    qty = getFluidMap()[req.name or ""] or 0
                end
            elseif req.name and req.name ~= "" then
                local dmg = tonumber(req.damage) or 0
                if proxy.getItemInNetwork and req.hasTag ~= true then
                    -- Table-form O(1) AE2 lookup (avoids empty-NBT tag mismatch on string-form calls)
                    local st = safeCall(proxy, "getItemInNetwork", { name = req.name, damage = dmg })
                    if type(st) == "table" and (not req.label or req.label == "" or st.label == req.label) then
                        qty = math.floor(tonumber(st.size or st.amount) or 0)
                    else
                        qty = 0
                    end
                elseif proxy.getItemsInNetwork then
                    local il = safeCall(proxy, "getItemsInNetwork", { name = req.name, damage = dmg })
                    if type(il) == "table" then
                        for j = 1, #il do
                            local st = il[j]
                            if type(st) == "table" and (not req.label or req.label == "" or st.label == req.label) then
                                qty = qty + math.floor(tonumber(st.size or st.amount) or 0)
                            end
                        end
                    end
                end
            end
            stocks[req.id] = qty
        end
    end

    local failed = {}
    for k, obj in pairs(Hardware._localMaintPending) do
        if obj and obj.isComputing then
            local comp = safeCall(obj, "isComputing")
            if comp ~= true then
                Hardware._localMaintPending[k] = nil
                local hasF, failWhy = safeCall(obj, "hasFailed")
                if hasF == true then
                    failed[k] = tostring(failWhy or "Missing resources or CPU busy")
                end
            end
        else
            Hardware._localMaintPending[k] = nil
        end
    end

    return {
        ok = true,
        totalCpus = totalCpus,
        freeCpus = freeCpus,
        busyByKey = busyByKey,
        busyByLabel = busyByLabel,
        stocks = stocks,
        failed = failed,
    }
end

local function resolveMainnetCraftable(proxy, rule)
    local cType = (rule.type == "fluid") and "fluid" or "item"
    if proxy.getCraftable and rule.name and rule.name ~= "" then
        local detail = { name = rule.name }
        if cType == "item" then
            detail.damage = tonumber(rule.damage) or 0
        end
        local res = safeCall(proxy, "getCraftable", detail, cType)
        if res ~= nil then return res end
    end
    if proxy.getCraftables then
        local filter = {}
        if rule.label and rule.label ~= "" then filter.label = rule.label end
        if rule.name and rule.name ~= "" then filter.name = rule.name end
        if cType == "item" and rule.damage ~= nil then filter.damage = tonumber(rule.damage) end
        local list = safeCall(proxy, "getCraftables", filter)
        if type(list) == "table" and #list > 0 then
            return list[1]
        end
    end
    return nil
end

local function meshUptime()
    return (computer and computer.uptime and computer.uptime()) or 0
end

local function awaitMeshAck(tunnel, tAddr, reqId, ackType, timeoutSec, maxPulls, stepSec)
    local t0 = meshUptime()
    local deadline = t0 + timeoutSec
    for _ = 1, maxPulls do
        local rem = deadline - meshUptime()
        if rem <= 0 then break end
        local ev, _, sender, port, _, msgType, rId, raw = event.pull(math.min(stepSec, math.max(0.05, rem)), "modem_message")
        if not ev then
            -- Exit immediately if host clock does not advance during event.pull (e.g. offline test mocks).
            if meshUptime() <= t0 then break end
        elseif (port == Hardware.MESH_PORT or (port == 0 and tunnel and tAddr))
            and msgType == ackType and tostring(rId) == reqId and type(raw) == "string" then
            local okU, tbl = pcall(serialization.unserialize, raw)
            if okU and type(tbl) == "table" then
                Hardware._mainnetMeshAddr = sender
                Hardware._mainnetMeshViaTunnel = (port == 0)
                Hardware._lastMainnetSeen = meshUptime()
                return tbl, sender, port
            end
        end
    end
    return nil
end

function Hardware.queryMainnetMaintenance(cfg, itemsReq, compLib)
    local cl = compLib or component
    local proxy, pAddr = Hardware.findLocalMainnetProxy(cfg, cl)
    if proxy then
        local res, err = inspectMainnetCpusAndStocks(proxy, itemsReq)
        if res then
            res.link = "adapter"
            res.addr = pAddr
            return res
        end
        return { ok = false, link = "adapter", error = err }
    end

    if cfg and cfg.mainnetAddr == "none" then
        return { ok = false, link = "none", error = "Mainnet link disabled" }
    end
    if cfg and cfg.extLinkMode == "off" then
        return { ok = false, link = "none", error = "Standalone mode (Ext Link OFF)" }
    end

    local modem, _, tunnel, tAddr = getMeshTransports(cl)
    if not modem and not tunnel then
        return { ok = false, link = "none", error = "No Mainnet Adapter or Wireless/Linked Card" }
    end

    local reqId = nextReqId()
    local payload = serialization.serialize({ items = itemsReq or {} })
    local viaTunnel = (Hardware._mainnetMeshViaTunnel == true) or (not modem and tunnel ~= nil)
    local tStart = meshUptime()
    sendMeshPacket(cl, Hardware._mainnetMeshAddr, viaTunnel, "MESH_MAINT_SYNC", reqId, payload)

    local tbl, sender, port = awaitMeshAck(tunnel, tAddr, reqId, "MESH_MAINT_ACK", 2.2, 12, 0.35)
    if not tbl and meshUptime() > tStart then
        -- Fallback to broadcast once in case cached Mainnet modem address changed or was briefly starved by scan I/O.
        sendMeshPacket(cl, nil, viaTunnel, "MESH_MAINT_SYNC", reqId, payload)
        tbl, sender, port = awaitMeshAck(tunnel, tAddr, reqId, "MESH_MAINT_ACK", 2.5, 14, 0.35)
    end
    if tbl then
        tbl.link = (port == 0) and "tunnel" or "modem"
        tbl.addr = sender
        return tbl
    end
    return { ok = false, link = "none", error = "Awaiting Mainnet OC response on port " .. tostring(Hardware.MESH_PORT) }
end

function Hardware.requestMainnetCraft(cfg, rule, amount, compLib)
    local cl = compLib or component
    amount = math.max(1, math.floor(tonumber(amount) or 1))
    local proxy = Hardware.findLocalMainnetProxy(cfg, cl)
    if proxy then
        local craftable = resolveMainnetCraftable(proxy, rule)
        if not craftable or not craftable.request then
            return { ok = false, error = "Pattern not found in Mainnet AE2" }
        end
        local okReq, statusObj, reqErr = pcall(craftable.request, amount, true, nil)
        if not okReq or not statusObj then
            return { ok = false, error = tostring(reqErr or statusObj or "request() failed") }
        end
        for _ = 1, 2 do
            local comp = statusObj.isComputing and safeCall(statusObj, "isComputing") or false
            if comp ~= true then break end
            if os and os.sleep then pcall(os.sleep, 0.05) end
        end
        if statusObj.isComputing and safeCall(statusObj, "isComputing") == true then
            if rule.id then
                Hardware._localMaintPending[rule.id] = statusObj
            end
            return { ok = true, status = "computing" }
        end
        local failed, failReason = safeCall(statusObj, "hasFailed")
        if failed == true then
            return { ok = false, error = tostring(failReason or "Missing resources or CPU busy") }
        end
        return { ok = true, status = "started" }
    end

    local modem, _, tunnel, tAddr = getMeshTransports(cl)
    if not modem and not tunnel then
        return { ok = false, error = "No Mainnet Adapter or OC Modem" }
    end
    local reqId = nextReqId()
    local payload = serialization.serialize({
        id = rule.id,
        type = rule.type,
        name = rule.name,
        damage = rule.damage or 0,
        label = rule.label,
        amount = amount,
    })
    local viaTunnel = (Hardware._mainnetMeshViaTunnel == true) or (not modem and tunnel ~= nil)
    sendMeshPacket(cl, Hardware._mainnetMeshAddr, viaTunnel, "MESH_CRAFT", reqId, payload)
    local tbl = awaitMeshAck(tunnel, tAddr, reqId, "MESH_CRAFT_ACK", 4.0, 20, 0.45)
    if tbl then
        return tbl
    end
    return { ok = false, error = "Mainnet OC craft timeout" }
end

function Hardware.pushMeshMetrics(cfg, runtimeState, nowSec, compLib, force)
    if cfg and cfg.extLinkMode == "off" then return false end
    local cl = compLib or component
    local modem, _, tunnel = getMeshTransports(cl)
    if not modem and not tunnel then return false end
    nowSec = nowSec or 0
    local curArmed = (cfg and cfg.armed == true)
    local curOd = (runtimeState and runtimeState.onDemand and runtimeState.onDemand.hasWork == true)
    if not force
        and curArmed == Hardware._lastMeshArmed
        and curOd == Hardware._lastMeshOd
        and (nowSec - (Hardware._lastMeshBeacon or -100)) < 15 then
        return false
    end
    Hardware._lastMeshBeacon = nowSec
    Hardware._lastMeshArmed = curArmed
    Hardware._lastMeshOd = curOd

    local pwr = (runtimeState and runtimeState.powerSummary) or {}
    local od = (runtimeState and runtimeState.onDemand) or {}
    local stockFluids = (runtimeState and runtimeState.stock and runtimeState.stock.fluids) or {}
    local units = {}
    for i = 1, #((cfg and cfg.dtpfs) or {}) do
        local d = cfg.dtpfs[i]
        local st = (runtimeState and runtimeState.dtpfStatus and runtimeState.dtpfStatus[i]) or {}
        units[i] = {
            name = d.name or ("DTPF #" .. i),
            online = st.online == true,
            enabled = d.enabled ~= false,
            active = st.active == true,
            wantConv = (st.wantConv == true) or (st.convergenceEnabled == true),
            discountPct = tonumber(st.discountPct) or 0,
            coilHeat = tonumber(st.coilHeat) or 0,
            familyId = st.familyId or "idle",
            directEut = math.floor(tonumber(st.directEut) or 0),
            catEut = math.floor(tonumber(st.catEut) or 0),
            maxInputEu = math.floor(tonumber(st.maxInputEu) or 0),
            hatchLabel = st.hatchLabel or "",
        }
    end
    local pkt = {
        armed = (cfg and cfg.armed == true),
        odActive = (od.hasWork == true),
        dtrStock = math.floor(tonumber(stockFluids["dimensionallytranscendentresidue"]) or 0),
        directEut = math.floor(tonumber(pwr.directEut) or 0),
        catEut = math.floor(tonumber(pwr.catEut) or 0),
        totalEut = math.floor(tonumber(pwr.totalEut) or 0),
        units = units,
    }
    local raw = serialization.serialize(pkt)
    if #raw > 6000 then
        for i = 1, #pkt.units do
            pkt.units[i].hatchLabel = nil
            pkt.units[i].familyId = tostring(pkt.units[i].familyId):sub(1, 18)
        end
        raw = serialization.serialize(pkt)
    end
    local viaTunnel = (Hardware._mainnetMeshViaTunnel == true) or (not modem and tunnel ~= nil)
    sendMeshPacket(cl, Hardware._mainnetMeshAddr, viaTunnel, "DTPF_METRICS", raw)

    local claims = runtimeState and runtimeState._dtpfClaims
    if type(claims) == "table" then
        local mInfo = (type(claims.maintInfo) == "table") and claims.maintInfo or nil
        local pInfo = (type(claims.passiveInfo) == "table") and claims.passiveInfo or nil
        local mSigs, pSigs = {}, {}
        if mInfo then
            for k, v in pairs(mInfo) do
                if type(v) == "table" then
                    mSigs[#mSigs + 1] = tostring(k) .. "=" .. tostring(v.tgt or 0) .. ":" .. tostring(v.m or "")
                end
            end
            table.sort(mSigs)
        end
        if pInfo then
            for k, v in pairs(pInfo) do
                if type(v) == "table" then
                    pSigs[#pSigs + 1] = tostring(k) .. "=" .. tostring(v.tgt or 0) .. ":" .. tostring(v.fv == true)
                end
            end
            table.sort(pSigs)
        end
        local sigRaw = serialization.serialize({
            armed = (cfg and cfg.armed == true),
            maintEnabled = (cfg and cfg.maintEnabled == true),
            maintKeys = claims.maintKeys or {},
            passiveKeys = claims.passiveKeys or {},
            mSigs = mSigs,
            pSigs = pSigs,
        })
        if force or Hardware._lastClaimsRaw == nil or sigRaw ~= Hardware._lastClaimsSig or (nowSec - (Hardware._lastClaimsSent or -100)) >= 15 then
            local cPkt = {
                armed = (cfg and cfg.armed == true),
                maintEnabled = (cfg and cfg.maintEnabled == true),
                maintKeys = claims.maintKeys or {},
                passiveKeys = claims.passiveKeys or {},
                maintInfo = mInfo,
                passiveInfo = pInfo,
            }
            local cRaw = serialization.serialize(cPkt)
            if #cRaw > 5500 then
                local function stripMapLabels(src)
                    if type(src) ~= "table" then return nil end
                    local out = {}
                    for k, v in pairs(src) do
                        if type(v) == "table" then
                            local copy = {}
                            for fk, fv in pairs(v) do
                                if fk ~= "l" and fk ~= "st" then copy[fk] = fv end
                            end
                            out[k] = copy
                        end
                    end
                    return out
                end
                cPkt.maintInfo = stripMapLabels(mInfo)
                cPkt.passiveInfo = stripMapLabels(pInfo)
                cRaw = serialization.serialize(cPkt)
            end
            if #cRaw > 5500 then
                cPkt.maintInfo = nil
                cPkt.passiveInfo = nil
                cRaw = serialization.serialize(cPkt)
            end
            Hardware._lastClaimsRaw = cRaw
            Hardware._lastClaimsSig = sigRaw
            Hardware._lastClaimsSent = nowSec
            if #cRaw <= 5500 then
                sendMeshPacket(cl, nil, viaTunnel, "DTPF_CLAIMS", cRaw)
            end
        end
    end
    if Hardware._lastMainnetSeen and (nowSec - Hardware._lastMainnetSeen) >= 90 and (nowSec - (Hardware._lastMainnetWakeAt or -1000)) >= 60 then
        Hardware._lastMainnetWakeAt = nowSec
        sendMeshPacket(cl, Hardware._mainnetMeshAddr, viaTunnel, Hardware.WAKE_MSG or "GTNH_WAKE", "dtpf")
    end
    return true
end

local function decodeClaimKeys(list)
    local out = {}
    if type(list) ~= "table" then return out end
    for i = 1, #list do
        local s = tostring(list[i] or "")
        if s ~= "" then
            if s:sub(1, 2) == "f:" then
                out["fluid:" .. s:sub(3) .. ":0"] = true
            elseif s:sub(1, 2) == "i:" then
                out["item:" .. s:sub(3)] = true
            else
                out[s] = true
            end
        end
    end
    return out
end

function Hardware.handleMeshMessage(webBridge, localAddr, sender, port, msgType, reqId, payload, compLib)
    if webBridge and webBridge.cfg and webBridge.cfg.extLinkMode == "off" then return false end
    local cl = compLib or component
    local modem, _, tunnel, tAddr = getMeshTransports(cl)
    local isMeshPort = (port == Hardware.MESH_PORT) or (port == 0 and tunnel and tAddr and localAddr == tAddr)
    if not isMeshPort or not sender then return false end

    if msgType == "MESH_MAINNET_HELLO" or msgType == "STOCK_HELLO" or msgType == (Hardware.WAKE_MSG or "GTNH_WAKE") then
        local up = (computer and computer.uptime and computer.uptime()) or (_G.computer and _G.computer.uptime and _G.computer.uptime()) or 0
        if msgType == "MESH_MAINNET_HELLO" or msgType == (Hardware.WAKE_MSG or "GTNH_WAKE") then
            Hardware._mainnetMeshAddr = sender
            Hardware._mainnetMeshViaTunnel = (port == 0)
            Hardware._lastMainnetSeen = up
        end
        Hardware.pushMeshMetrics(webBridge and webBridge.cfg, webBridge and webBridge.state, up, cl, true)
        return true
    elseif msgType == "STOCK_CLAIMS" then
        local rawStr = (type(reqId) == "string" and reqId:sub(1, 1) == "{" and (payload == nil or payload == "")) and reqId or payload
        local okU, pkt = pcall(serialization.unserialize, tostring(rawStr or ""))
        if okU and type(pkt) == "table" and webBridge and webBridge.state then
            local up = (computer and computer.uptime and computer.uptime()) or (_G.computer and _G.computer.uptime and _G.computer.uptime()) or 0
            webBridge.state.stockPeer = {
                addr = sender,
                viaTunnel = (port == 0),
                lastSeen = up,
                armed = (pkt.armed == true),
                keys = decodeClaimKeys(pkt.keys),
            }
            return true
        end
        return false
    elseif msgType == "DTPF_ACK" then
        Hardware._mainnetMeshAddr = sender
        Hardware._mainnetMeshViaTunnel = (port == 0)
        Hardware._lastMainnetSeen = (computer and computer.uptime and computer.uptime()) or (_G.computer and _G.computer.uptime and _G.computer.uptime()) or 0
        return true
    elseif msgType == "DTPF_CMD" then
        Hardware._mainnetMeshAddr = sender
        Hardware._mainnetMeshViaTunnel = (port == 0)
        Hardware._lastMainnetSeen = (computer and computer.uptime and computer.uptime()) or (_G.computer and _G.computer.uptime and _G.computer.uptime()) or 0
        local cmd = (type(payload) == "string") and serialization.unserialize(payload) or nil
        local resTbl
        if type(cmd) == "table" and webBridge and webBridge.executeRpcTable then
            resTbl = webBridge:executeRpcTable(cmd)
        else
            resTbl = { ok = false, error = "Invalid DTPF_CMD payload" }
        end
        local raw = serialization.serialize(resTbl)
        local CHUNK = 5500
        local total = math.max(1, math.ceil(#raw / CHUNK))
        local viaTunnel = (port == 0)
        for idx = 1, total do
            local slice = raw:sub((idx - 1) * CHUNK + 1, idx * CHUNK)
            sendMeshPacket(cl, sender, viaTunnel, "DTPF_REPLY", tostring(reqId or ""), idx, total, slice)
        end
        return true
    elseif msgType == "DTPF_HANDOFF" then
        local okU, pkt = pcall(serialization.unserialize, tostring(payload or ""))
        local acceptedIds, passiveCnt, maintCnt = {}, 0, 0
        if okU and type(pkt) == "table" and webBridge and webBridge.applyPatch then
            for _, it in ipairs(pkt.items or {}) do
                if type(it) == "table" then
                    if it.kind == "passive" and it.familyId then
                        local okP = webBridge:applyPatch({
                            familyId = it.familyId,
                            enabled = true,
                            target = tonumber(it.target) or nil,
                        })
                        if okP then
                            acceptedIds[#acceptedIds + 1] = it.ruleId
                            passiveCnt = passiveCnt + 1
                        end
                    elseif it.name and it.name ~= "" then
                        local okP = webBridge:applyPatch({
                            maintEnabled = true,
                            maintRule = {
                                type = it.type or "item",
                                name = it.name,
                                damage = tonumber(it.damage) or 0,
                                label = it.label or it.name,
                                target = tonumber(it.target) or 64,
                                lowThreshold = it.lowThreshold,
                                batch = tonumber(it.batch) or 1,
                                mode = it.mode or "auto",
                            },
                        })
                        if okP then
                            acceptedIds[#acceptedIds + 1] = it.ruleId
                            maintCnt = maintCnt + 1
                        end
                    end
                end
            end
        end
        local viaTunnel = (port == 0)
        local ackRaw = serialization.serialize({
            ok = (#acceptedIds > 0),
            acceptedIds = acceptedIds,
            passiveCount = passiveCnt,
            maintCount = maintCnt,
            remove = (type(pkt) == "table" and pkt.remove == true),
        })
        sendMeshPacket(cl, sender, viaTunnel, "DTPF_HANDOFF_ACK", tostring(reqId or ""), ackRaw)
        return true
    end
    return false
end

return Hardware
