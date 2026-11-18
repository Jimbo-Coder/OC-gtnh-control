-- /home/universal/lib/hardware.lua
-- Bundled Redstone (Toggle Bus), AE2 Subnet Scanning, Built-in GTNH 2.9 NC Filtering,
-- 1-Click Auto-Scan Trunk Pairing, and Optional Wireless OC Mesh (port 4205) for GTNH Universal Control.

local component = require("component")
local computer = require("computer")
local serialization = require("serialization")

local Hardware = {}

Hardware.MESH_PORT = 4205

-- ProjectRed / OC Bundled Redstone color indices (0..15)
Hardware.COLORS = {
    [0]  = { id = 0,  name = "White",      short = "WHT", hex = 0xF0F6FC, fg = 0x0C1117 },
    [1]  = { id = 1,  name = "Orange",     short = "ORG", hex = 0xF0883E, fg = 0x0C1117 },
    [2]  = { id = 2,  name = "Magenta",    short = "MAG", hex = 0xDB61A2, fg = 0x0C1117 },
    [3]  = { id = 3,  name = "LightBlue",  short = "LBL", hex = 0x58A6FF, fg = 0x0C1117 },
    [4]  = { id = 4,  name = "Yellow",     short = "YEL", hex = 0xE3B341, fg = 0x0C1117 },
    [5]  = { id = 5,  name = "Lime",       short = "LIM", hex = 0x56D364, fg = 0x0C1117 },
    [6]  = { id = 6,  name = "Pink",       short = "PNK", hex = 0xF778BA, fg = 0x0C1117 },
    [7]  = { id = 7,  name = "Gray",       short = "GRY", hex = 0x6E7681, fg = 0xE6EDF3 },
    [8]  = { id = 8,  name = "Silver",     short = "SLV", hex = 0xB1BAC4, fg = 0x0C1117 },
    [9]  = { id = 9,  name = "Cyan",       short = "CYN", hex = 0x39C5CF, fg = 0x0C1117 },
    [10] = { id = 10, name = "Purple",     short = "PRP", hex = 0xBC8CFF, fg = 0x0C1117 },
    [11] = { id = 11, name = "Blue",       short = "BLU", hex = 0x1F6FEB, fg = 0xE6EDF3 },
    [12] = { id = 12, name = "Brown",      short = "BRN", hex = 0x8B5A2B, fg = 0xE6EDF3 },
    [13] = { id = 13, name = "Green",      short = "GRN", hex = 0x238636, fg = 0xE6EDF3 },
    [14] = { id = 14, name = "Red",        short = "RED", hex = 0xDA3633, fg = 0xE6EDF3 },
    [15] = { id = 15, name = "Black",      short = "BLK", hex = 0x21262D, fg = 0xE6EDF3 },
}

Hardware.SIDE_NAMES = {
    [0] = "Down",
    [1] = "Up",
    [2] = "North",
    [3] = "South",
    [4] = "West",
    [5] = "East",
}

local PRESS_DAMAGES = { [13] = true, [14] = true, [15] = true, [19] = true, [21] = true }
local EXACT_IGNORED_NAMES = {
    ["gregtech:gt.integrated_circuit"] = true,
    ["AWWayofTime:weakBloodOrb"] = true,
    ["AWWayofTime:apprenticeBloodOrb"] = true,
    ["AWWayofTime:magicianBloodOrb"] = true,
    ["AWWayofTime:masterBloodOrb"] = true,
    ["AWWayofTime:archmageBloodOrb"] = true,
    ["AWWayofTime:transcendentBloodOrb"] = true,
    ["Avaritia:Orb_Armok"] = true,
    ["ForbiddenMagic:EldritchOrb"] = true,
    ["BloodArsenal:transparent_orb"] = true,
    ["TwilightForest:item.trophy"] = true,
    ["ExtraUtilities:divisionSigil"] = true,
}

Hardware._lastMeshBeacon = -100
Hardware._lastMeshQueued = -1
Hardware._lastMeshArmed = nil
Hardware._mainnetMeshAddr = nil
Hardware._mainnetMeshViaTunnel = false

local function safeCall(proxy, method, ...)
    if not proxy or type(proxy[method]) ~= "function" then
        return nil, "missing method " .. tostring(method)
    end
    local ok, a, b, c = pcall(proxy[method], ...)
    if not ok then
        return nil, tostring(a)
    end
    return a, b, c
end

function Hardware.shortAddr(addr)
    if type(addr) ~= "string" or addr == "" then return "None" end
    return addr:sub(1, 8)
end

-- Matches items natively registered in GTNH 2.9.0 AE2Compat BlockingModeIgnoreItemRegistry.
-- Non-registered NCs (GT++ shapes/molds, catalysts, petri dishes, data sticks) return false here
-- and are handled via Dual-Trunk NC isolation or [Calibrate Idle NCs] baselines.
function Hardware.isBuiltinIgnoredNC(stack)
    if type(stack) ~= "table" then return false end
    local name = tostring(stack.name or "")
    local dmg = tonumber(stack.damage) or 0
    local label = tostring(stack.label or "")

    if EXACT_IGNORED_NAMES[name] then
        return true
    end
    if name == "appliedenergistics2:item.ItemMultiMaterial" and PRESS_DAMAGES[dmg] then
        return true
    end
    local isLensSuffix = (label:sub(-4) == "Lens" or label:sub(-5) == "Lense")
    if name:find("^gregtech:gt%.metaitem") then
        if label:find("Mold", 1, true)
            or label:find("Extruder Shape", 1, true)
            or label:find("Slicer Blade", 1, true)
            or isLensSuffix then
            return true
        end
    end
    if (name:find("^bartworks:", 1, false) or name:find("^NewHorizonsCoreMod:", 1, false) or name:find("^miscutils:", 1, false))
        and isLensSuffix then
        return true
    end
    return false
end

function Hardware.stackKey(stack, isFluid)
    if type(stack) ~= "table" then return "" end
    local name = tostring(stack.name or "")
    if isFluid then
        return name
    end
    local dmg = math.floor(tonumber(stack.damage) or 0)
    return name .. ":" .. tostring(dmg)
end

function Hardware.discover(compLib)
    local cl = compLib or component
    local redstones = {}
    local interfaces = {}
    local partWarnings = {}

    if cl.list then
        for addr in cl.list("redstone", true) do
            local p = cl.proxy(addr)
            local bundled = (p ~= nil) and (type(p.setBundledOutput) == "function")
            redstones[#redstones + 1] = {
                address = addr,
                shortAddr = Hardware.shortAddr(addr),
                bundled = bundled,
            }
        end
        table.sort(redstones, function(a, b) return a.address < b.address end)

        local seenIface = {}
        for _, ctype in ipairs({ "me_interface", "me_controller" }) do
            for addr in cl.list(ctype, true) do
                if not seenIface[addr] then
                    seenIface[addr] = true
                    local p = cl.proxy(addr)
                    local hasNet = (p ~= nil) and (type(p.getItemsInNetwork) == "function")
                    if hasNet then
                        local x, y, z
                        if p.getCoordinates then
                            local okC, cx, cy, cz = pcall(p.getCoordinates)
                            if okC and type(cx) == "number" then
                                x, y, z = math.floor(cx), math.floor(cy), math.floor(cz)
                            end
                        end
                        interfaces[#interfaces + 1] = {
                            address = addr,
                            shortAddr = Hardware.shortAddr(addr),
                            ctype = ctype,
                            x = x,
                            y = y,
                            z = z,
                        }
                    else
                        partWarnings[#partWarnings + 1] = {
                            address = addr,
                            shortAddr = Hardware.shortAddr(addr),
                            ctype = ctype,
                            message = string.format(
                                "Flat cable-part %s (%s) lacks NetworkControl: replace with a full-block ME Dual Interface.",
                                ctype, Hardware.shortAddr(addr)
                            ),
                        }
                    end
                end
            end
        end
        table.sort(interfaces, function(a, b) return a.address < b.address end)
        table.sort(partWarnings, function(a, b) return a.address < b.address end)
    end

    local hasModem, hasWireless, hasTunnel = false, false, false
    if cl.list then
        for addr in cl.list("modem", true) do
            hasModem = true
            local m = cl.proxy(addr)
            if m and m.isWireless then
                local okW, rW = pcall(m.isWireless)
                if okW and rW == true then hasWireless = true end
            end
        end
        if cl.list("tunnel", true)() ~= nil then
            hasTunnel = true
        end
    end

    local hasGpu = cl.list and (cl.list("gpu", true)() ~= nil) or false
    local hasScreen = cl.list and (cl.list("screen", true)() ~= nil) or false

    return {
        redstones = redstones,
        interfaces = interfaces,
        partWarnings = partWarnings,
        hasModem = hasModem,
        hasWireless = hasWireless,
        hasTunnel = hasTunnel,
        hasGpu = hasGpu,
        hasScreen = hasScreen,
    }
end

-- Drive a single active color (0..15) or nil (ALL OFF) on a Redstone I/O bundled side.
function Hardware.setPoolOutputs(rsAddr, side, activeColorOrNil, compLib)
    if not rsAddr or rsAddr == "" or side == nil then
        return false, "unconfigured redstone/side"
    end
    local cl = compLib or component
    local proxy = cl.proxy(rsAddr)
    if not proxy or type(proxy.setBundledOutput) ~= "function" then
        return false, "no bundled redstone proxy"
    end

    local tbl = {}
    for c = 0, 15 do
        tbl[c] = (activeColorOrNil == c) and 255 or 0
    end

    local ok = pcall(proxy.setBundledOutput, side, tbl)
    if ok then
        return true, nil
    end

    -- Fallback for mocks/drivers supporting (side, color, value) only: turn OFF before ON.
    for c = 0, 15 do
        if activeColorOrNil ~= c then
            pcall(proxy.setBundledOutput, side, c, 0)
        end
    end
    if activeColorOrNil ~= nil then
        local okOn, errOn = pcall(proxy.setBundledOutput, side, activeColorOrNil, 255)
        if not okOn then
            return false, tostring(errOn)
        end
    end
    return true, nil
end

function Hardware.zeroAllManagedPools(cfg, compLib)
    local cl = compLib or component
    local seen = {}
    local cleared = 0
    if cfg and type(cfg.pools) == "table" then
        for i = 1, #cfg.pools do
            local p = cfg.pools[i]
            if type(p) == "table" and p.rsAddr and p.side ~= nil then
                local k = tostring(p.rsAddr) .. ":" .. tostring(p.side)
                if not seen[k] then
                    seen[k] = true
                    if Hardware.setPoolOutputs(p.rsAddr, p.side, nil, cl) then
                        cleared = cleared + 1
                    end
                end
            end
        end
    end
    return cleared
end

function Hardware.zeroAllBundledSides(compLib)
    local cl = compLib or component
    if not cl.list then return 0 end
    local cleared = 0
    for addr in cl.list("redstone", true) do
        local p = cl.proxy(addr)
        if p and type(p.setBundledOutput) == "function" then
            for s = 0, 5 do
                Hardware.setPoolOutputs(addr, s, nil, cl)
            end
            cleared = cleared + 1
        end
    end
    return cleared
end

local function aggregateStacks(rawItems, rawFluids, slice, opts)
    opts = opts or {}
    local ignoreBuiltin = (opts.ignoreBuiltinNC ~= false)
    local baseItems = (slice and slice.baselineItems) or {}
    local baseFluids = (slice and slice.baselineFluids) or {}

    local itemTotals = {}
    local itemLabels = {}
    if type(rawItems) == "table" then
        for i = 1, #rawItems do
            local st = rawItems[i]
            if type(st) == "table" and st.name then
                local qty = math.floor(tonumber(st.size or st.amount) or 0)
                if qty > 0 and (not (ignoreBuiltin and Hardware.isBuiltinIgnoredNC(st))) then
                    local key = Hardware.stackKey(st, false)
                    itemTotals[key] = (itemTotals[key] or 0) + qty
                    if st.label and st.label ~= "" then
                        itemLabels[key] = st.label
                    end
                end
            end
        end
    end

    local fluidTotals = {}
    local fluidLabels = {}
    if type(rawFluids) == "table" then
        for i = 1, #rawFluids do
            local fl = rawFluids[i]
            if type(fl) == "table" and fl.name then
                local qty = math.floor(tonumber(fl.amount or fl.size) or 0)
                if qty > 0 then
                    local key = Hardware.stackKey(fl, true)
                    fluidTotals[key] = (fluidTotals[key] or 0) + qty
                    if fl.label and fl.label ~= "" then
                        fluidLabels[key] = fl.label
                    end
                end
            end
        end
    end

    local itemUnits = 0
    local activeItemTypes = 0
    local topLabel, topScore = nil, 0
    local activeItems = {}
    for key, total in pairs(itemTotals) do
        local base = math.max(0, math.floor(tonumber(baseItems[key]) or 0))
        local rem = total - base
        if rem > 0 then
            activeItemTypes = activeItemTypes + 1
            itemUnits = itemUnits + rem
            local lbl = itemLabels[key] or key
            activeItems[#activeItems + 1] = { key = key, label = lbl, qty = rem }
            if rem > topScore then
                topScore = rem
                topLabel = lbl
            end
        end
    end

    local fluidUnits = 0
    local activeFluidTypes = 0
    local activeFluids = {}
    for key, total in pairs(fluidTotals) do
        local base = math.max(0, math.floor(tonumber(baseFluids[key]) or 0))
        local rem = total - base
        if rem > 0 then
            activeFluidTypes = activeFluidTypes + 1
            fluidUnits = fluidUnits + rem
            local lbl = fluidLabels[key] or key
            local eqUnits = rem / 1000.0
            activeFluids[#activeFluids + 1] = { key = key, label = lbl, qty = rem }
            if eqUnits > topScore then
                topScore = eqUnits
                topLabel = lbl
            end
        end
    end

    table.sort(activeItems, function(a, b) return a.qty > b.qty end)
    table.sort(activeFluids, function(a, b) return a.qty > b.qty end)

    return {
        itemUnits = itemUnits,
        fluidUnits = fluidUnits,
        workScore = itemUnits + (fluidUnits / 1000.0),
        activeItemTypes = activeItemTypes,
        activeFluidTypes = activeFluidTypes,
        topLabel = topLabel or "",
        activeItems = activeItems,
        activeFluids = activeFluids,
    }
end

function Hardware.scanSubnet(addr, slice, opts, compLib)
    if not addr or addr == "" then
        return { ok = false, itemUnits = 0, fluidUnits = 0, workScore = 0, activeItemTypes = 0, activeFluidTypes = 0, topLabel = "", err = "Unbound" }
    end
    local cl = compLib or component
    local proxy = cl.proxy(addr)
    if not proxy then
        return { ok = false, itemUnits = 0, fluidUnits = 0, workScore = 0, activeItemTypes = 0, activeFluidTypes = 0, topLabel = "", err = "Component offline" }
    end
    if type(proxy.getItemsInNetwork) ~= "function" then
        return { ok = false, itemUnits = 0, fluidUnits = 0, workScore = 0, activeItemTypes = 0, activeFluidTypes = 0, topLabel = "", err = "Flat part interface (no NetworkControl)" }
    end

    local rawItems, errI = safeCall(proxy, "getItemsInNetwork")
    if rawItems == nil then
        return { ok = false, itemUnits = 0, fluidUnits = 0, workScore = 0, activeItemTypes = 0, activeFluidTypes = 0, topLabel = "", err = errI or "getItemsInNetwork failed" }
    end
    local rawFluids = {}
    if type(proxy.getFluidsInNetwork) == "function" then
        local fl = safeCall(proxy, "getFluidsInNetwork")
        if type(fl) == "table" then
            rawFluids = fl
        end
    end

    local agg = aggregateStacks(rawItems, rawFluids, slice, opts)
    agg.ok = true
    agg.rawItemCount = #rawItems
    agg.rawFluidCount = #rawFluids
    agg.rawItems = rawItems
    agg.rawFluids = rawFluids
    return agg
end

-- Snapshots all current items (excluding built-in NCs) & fluids on a slice as its permanent idle NC baseline.
function Hardware.calibrateBaseline(slice, opts, compLib)
    if type(slice) ~= "table" or not slice.ifaceAddr or slice.ifaceAddr == "" then
        return false, "Unbound slice"
    end
    local blankSlice = { baselineItems = {}, baselineFluids = {} }
    local res = Hardware.scanSubnet(slice.ifaceAddr, blankSlice, opts, compLib)
    if not res.ok then
        return false, res.err or "scan failed"
    end
    local bItems, bFluids = {}, {}
    local nI, nF = 0, 0
    for _, it in ipairs(res.activeItems or {}) do
        if it.qty > 0 then
            bItems[it.key] = it.qty
            nI = nI + 1
        end
    end
    for _, fl in ipairs(res.activeFluids or {}) do
        if fl.qty > 0 then
            bFluids[fl.key] = fl.qty
            nF = nF + 1
        end
    end
    slice.baselineItems = bItems
    slice.baselineFluids = bFluids
    return true, nI, nF
end

local function buildCountMaps(scanRes)
    local items, fluids = {}, {}
    if scanRes and scanRes.rawItems then
        for i = 1, #scanRes.rawItems do
            local st = scanRes.rawItems[i]
            if type(st) == "table" and st.name then
                local k = Hardware.stackKey(st, false)
                items[k] = (items[k] or 0) + math.floor(tonumber(st.size or st.amount) or 0)
            end
        end
    end
    if scanRes and scanRes.rawFluids then
        for i = 1, #scanRes.rawFluids do
            local fl = scanRes.rawFluids[i]
            if type(fl) == "table" and fl.name then
                local k = Hardware.stackKey(fl, true)
                fluids[k] = (fluids[k] or 0) + math.floor(tonumber(fl.amount or fl.size) or 0)
            end
        end
    end
    return items, fluids
end

local function hasIncreasedStock(beforeMap, afterMap)
    for k, afterQty in pairs(afterMap) do
        if afterQty > (beforeMap[k] or 0) then
            return true, k
        end
    end
    return false, nil
end

function Hardware.snapshotInterfaces(addrs, compLib)
    local snaps = {}
    for i = 1, #(addrs or {}) do
        local addr = addrs[i]
        local res = Hardware.scanSubnet(addr, nil, { ignoreBuiltinNC = false }, compLib)
        if res.ok then
            local it, fl = buildCountMaps(res)
            snaps[addr] = { items = it, fluids = fl }
        end
    end
    return snaps
end

function Hardware.detectChangedInterface(addrs, prevSnaps, compLib)
    for i = 1, #(addrs or {}) do
        local addr = addrs[i]
        local prev = prevSnaps and prevSnaps[addr]
        if prev then
            local res = Hardware.scanSubnet(addr, nil, { ignoreBuiltinNC = false }, compLib)
            if res.ok then
                local it, fl = buildCountMaps(res)
                local okI, keyI = hasIncreasedStock(prev.items, it)
                if okI then return addr, keyI, it, fl end
                local okF, keyF = hasIncreasedStock(prev.fluids, fl)
                if okF then return addr, keyF, it, fl end
            end
        end
    end
    return nil
end

-- 1-Click Trunk Auto-Pair:
-- Place 1 marker item (or marker Storage Bus on a chest with cobblestone) on the shared Machine Trunk.
-- Sweeps Bundled Colors 0..15 one by one; whichever subnet suddenly sees the marker is bound to that Color!
function Hardware.autoScanTrunkPool(pool, candidateAddrs, opts, compLib)
    opts = opts or {}
    local cl = compLib or component
    if not pool or not pool.rsAddr or pool.side == nil then
        return { ok = false, boundCount = 0, bindings = {}, error = "Configure Redstone I/O and Bundled Side first." }
    end
    local sleepFn = opts.sleepFn or (os and os.sleep) or function() end
    local pulseSec = tonumber(opts.pulseSec) or 0.25

    Hardware.setPoolOutputs(pool.rsAddr, pool.side, nil, cl)
    pcall(sleepFn, pulseSec)

    local baseline = Hardware.snapshotInterfaces(candidateAddrs, cl)
    local bindings = {}
    local alreadyUsed = {}
    for c = 0, 15 do
        local s = pool.slices and pool.slices[c]
        if s and s.ifaceAddr and s.ifaceAddr ~= "" and opts.overwriteExisting ~= true then
            alreadyUsed[s.ifaceAddr] = c
        end
    end

    local okSweep, sweepErr = pcall(function()
        for color = 0, 15 do
            local slice = pool.slices and pool.slices[color]
            if slice and (opts.overwriteExisting == true or not slice.ifaceAddr or slice.ifaceAddr == "") then
                Hardware.setPoolOutputs(pool.rsAddr, pool.side, color, cl)
                sleepFn(pulseSec)
                local remaining = {}
                for i = 1, #candidateAddrs do
                    local a = candidateAddrs[i]
                    if not alreadyUsed[a] then
                        remaining[#remaining + 1] = a
                    end
                end
                local hitAddr, hitKey = Hardware.detectChangedInterface(remaining, baseline, cl)
                Hardware.setPoolOutputs(pool.rsAddr, pool.side, nil, cl)
                if hitAddr then
                    slice.ifaceAddr = hitAddr
                    alreadyUsed[hitAddr] = color
                    bindings[#bindings + 1] = { color = color, address = hitAddr, marker = hitKey }
                end
            end
        end
    end)

    Hardware.setPoolOutputs(pool.rsAddr, pool.side, nil, cl)
    if not okSweep then
        return { ok = false, boundCount = #bindings, bindings = bindings, error = tostring(sweepErr) }
    end
    return { ok = true, boundCount = #bindings, bindings = bindings }
end

-- ============================================================================
-- Optional Wireless / Wired OC Mesh (`MESH_PORT = 4205`) Integration
-- ============================================================================

local function getMeshTransports(compLib)
    local cl = compLib or component
    local firstModem, wModem = nil, nil
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
                if not firstModem then firstModem = m end
                if isW and not wModem then wModem = m end
            end
        end
    end
    local modem = wModem or firstModem
    local tunnel, tAddr = nil, nil
    local ta = cl.list and cl.list("tunnel", true)() or nil
    if ta then
        tunnel, tAddr = cl.proxy(ta), ta
    end
    return modem, tunnel, tAddr
end

function Hardware.openMeshPort(cfg, compLib)
    if cfg and cfg.extLinkMode == "off" then return nil, nil end
    local modem, tunnel = getMeshTransports(compLib)
    return modem, tunnel
end

local function sendMeshPacket(cl, targetAddr, viaTunnel, msgType, ...)
    local modem, tunnel = getMeshTransports(cl)
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

function Hardware.pushMeshMetrics(cfg, state, nowSec, compLib, force)
    if cfg and cfg.extLinkMode == "off" then return false end
    local cl = compLib or component
    local modem, tunnel = getMeshTransports(cl)
    if not modem and not tunnel then return false end

    nowSec = nowSec or 0
    local kpis = (state and state.kpis) or {}
    local curArmed = (cfg and cfg.armed == true)
    local curQueued = tonumber(kpis.queuedSlices) or 0
    if not force
        and curArmed == Hardware._lastMeshArmed
        and curQueued == Hardware._lastMeshQueued
        and (nowSec - (Hardware._lastMeshBeacon or -100)) < 15 then
        return false
    end

    Hardware._lastMeshBeacon = nowSec
    Hardware._lastMeshArmed = curArmed
    Hardware._lastMeshQueued = curQueued

    local poolsOut = {}
    for pi = 1, #((cfg and cfg.pools) or {}) do
        local p = cfg.pools[pi]
        local pst = state and state.poolStates and state.poolStates[p.id] or {}
        poolsOut[pi] = {
            id = p.id,
            name = p.name,
            phase = pst.phase or "IDLE",
            activeColor = pst.activeColor,
            activeLabel = pst.activeLabel or "",
            etaSec = pst.activeEtaSec,
        }
    end

    local pkt = {
        armed = curArmed,
        activePools = kpis.activePools or 0,
        queuedSlices = curQueued,
        stalledCount = kpis.stalledCount or 0,
        completedBatches = kpis.completedBatches or 0,
        preemptions = kpis.preemptions or 0,
        pools = poolsOut,
    }
    local raw = serialization.serialize(pkt)
    if #raw > 5800 then
        pkt.pools = {}
        raw = serialization.serialize(pkt)
    end
    local viaTunnel = (Hardware._mainnetMeshViaTunnel == true) or (not modem and tunnel ~= nil)
    sendMeshPacket(cl, Hardware._mainnetMeshAddr, viaTunnel, "UNIV_METRICS", raw)
    return true
end

function Hardware.handleMeshMessage(cfg, state, localAddr, sender, port, msgType, reqId, payload, compLib)
    if cfg and cfg.extLinkMode == "off" then return false end
    local cl = compLib or component
    local modem, tunnel, tAddr = getMeshTransports(cl)
    local isMeshPort = (port == Hardware.MESH_PORT) or (port == 0 and tunnel and tAddr and localAddr == tAddr)
    if not isMeshPort or not sender then return false end

    if msgType == "MESH_MAINNET_HELLO" then
        Hardware._mainnetMeshAddr = sender
        Hardware._mainnetMeshViaTunnel = (port == 0)
        local up = (computer and computer.uptime and computer.uptime()) or 0
        Hardware.pushMeshMetrics(cfg, state, up, cl, true)
        return true
    elseif msgType == "UNIV_ACK" then
        Hardware._mainnetMeshAddr = sender
        Hardware._mainnetMeshViaTunnel = (port == 0)
        return true
    elseif msgType == "UNIV_CMD" then
        Hardware._mainnetMeshAddr = sender
        Hardware._mainnetMeshViaTunnel = (port == 0)
        local cmd = (type(payload) == "string") and serialization.unserialize(payload) or nil
        local reply = { ok = false, error = "Unknown command" }
        if type(cmd) == "table" then
            if cmd.action == "pause" then
                cfg.armed = false
                Hardware.zeroAllManagedPools(cfg, cl)
                reply = { ok = true, armed = false }
            elseif cmd.action == "resume" then
                cfg.armed = true
                reply = { ok = true, armed = true }
            elseif cmd.action == "poll_now" then
                if state then state._forcePollNow = true end
                reply = { ok = true }
            elseif cmd.action == "force_slice" then
                local pId = tonumber(cmd.poolId) or 1
                local col = tonumber(cmd.color)
                if col ~= nil and col >= 0 and col <= 15 and state then
                    state.forceColorByPool = state.forceColorByPool or {}
                    state.forceColorByPool[pId] = math.floor(col)
                    state._forcePollNow = true
                    reply = { ok = true, poolId = pId, color = math.floor(col) }
                else
                    reply = { ok = false, error = "Invalid poolId/color" }
                end
            elseif cmd.action == "clear_stalls" then
                if state and type(state.sliceStates) == "table" then
                    for _, ss in pairs(state.sliceStates) do
                        ss.stalledUntil = 0
                        ss.stalledReason = nil
                        ss.lastStallWork = nil
                    end
                    state._forcePollNow = true
                end
                reply = { ok = true }
            end
        end
        sendMeshPacket(cl, sender, (port == 0), "UNIV_REPLY", tostring(reqId or ""), serialization.serialize(reply))
        return true
    end
    return false
end

return Hardware
