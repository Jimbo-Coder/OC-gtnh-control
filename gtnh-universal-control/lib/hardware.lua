-- /home/universal/lib/hardware.lua
-- Multi-Channel Bundled Redstone (16/32 NCs), GTNH 2.9 Push Event Subscriptions,
-- Raw Delta Accounting, Built-in NC Filtering, Trunk Auto-Pairing, and Optional OC Mesh (port 4205).

local component = require("component")
local computer = require("computer")
local serialization = require("serialization")

local Hardware = {}

Hardware.MESH_PORT = 4205
Hardware.WAKE_MSG = "GTNH_WAKE"

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
Hardware._globalLastBundled = {}

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

local function getProxy(addr, compLib, proxyCache)
    if not addr or addr == "" then return nil end
    if proxyCache and proxyCache[addr] ~= nil then
        return proxyCache[addr]
    end
    local cl = compLib or component
    if not cl.proxy then return nil end
    local p = cl.proxy(addr)
    if p and proxyCache then
        proxyCache[addr] = p
    end
    return p
end

function Hardware.shortAddr(addr)
    if type(addr) ~= "string" or addr == "" then return "None" end
    return addr:sub(1, 8)
end

function Hardware.clearProxyCache(state)
    if state then
        state._proxies = {}
    end
end

-- Matches items natively registered in GTNH 2.9.0 AE2Compat BlockingModeIgnoreItemRegistry.
-- Non-registered NCs (GT++ shapes/molds, catalysts, petri dishes, data sticks) return false here
-- and are handled via Always-On NC Buffer + Toggle Bus / [Calibrate Idle NCs] baselines.
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

function Hardware.buildIngredientSig(activeItems, activeFluids)
    local parts = {}
    if type(activeItems) == "table" then
        for i = 1, #activeItems do
            parts[#parts + 1] = "i:" .. tostring(activeItems[i].key or "")
        end
    end
    if type(activeFluids) == "table" then
        for i = 1, #activeFluids do
            parts[#parts + 1] = "f:" .. tostring(activeFluids[i].key or "")
        end
    end
    if #parts == 0 then return "" end
    table.sort(parts)
    if #parts > 24 then
        local trimmed = {}
        for i = 1, 24 do trimmed[i] = parts[i] end
        return table.concat(trimmed, "|")
    end
    return table.concat(parts, "|")
end

-- Resolve exact (rsAddr, side, color) signal wire for a given (pool, chIdx, ncIdx).
-- Follows: 1 Bundled Cable per Channel per 16-NC Bank (Same Color = Same NC Everywhere),
-- with optional sparse per-(chIdx, ncIdx) override.
function Hardware.resolveSignal(pool, chIdx, ncIdx)
    if type(pool) ~= "table" or ncIdx == nil or ncIdx < 0 then return nil end
    local ch = pool.channels and pool.channels[chIdx or 1]
    if ch and type(ch.overrides) == "table" then
        local ov = ch.overrides[ncIdx]
        if type(ov) == "table" and ov.rsAddr and ov.rsAddr ~= "" and ov.side ~= nil and ov.color ~= nil then
            return ov.rsAddr, math.floor(tonumber(ov.side)), math.floor(tonumber(ov.color)) % 16
        end
    end

    local bankIdx = math.floor(ncIdx / 16) + 1
    local color = ncIdx % 16
    local bank = ch and ch.banks and ch.banks[bankIdx]
    local rsAddr = bank and bank.rsAddr
    local side = bank and bank.side

    if (not rsAddr or rsAddr == "") and (chIdx == nil or chIdx == 1) and bankIdx == 1 then
        rsAddr = pool.rsAddr
        if side == nil then side = pool.side end
    end
    if not rsAddr or rsAddr == "" or side == nil then
        return nil
    end
    return rsAddr, math.floor(tonumber(side)), color
end

-- Enumerate all managed (rsAddr, side) wires across every channel, bank, and override in cfg.
function Hardware.listManagedWires(cfg)
    local wires = {}
    local seen = {}
    local function addWire(rsAddr, side)
        if type(rsAddr) == "string" and rsAddr ~= "" and side ~= nil then
            local s = math.floor(tonumber(side))
            local k = rsAddr .. ":" .. tostring(s)
            if not seen[k] then
                seen[k] = true
                wires[#wires + 1] = { rsAddr = rsAddr, side = s, key = k }
            end
        end
    end

    for _, pool in ipairs((cfg and cfg.pools) or {}) do
        addWire(pool.rsAddr, pool.side)
        for _, ch in ipairs(pool.channels or {}) do
            for _, bank in ipairs(ch.banks or {}) do
                addWire(bank.rsAddr, bank.side)
            end
            if type(ch.overrides) == "table" then
                for _, ov in pairs(ch.overrides) do
                    if type(ov) == "table" then
                        addWire(ov.rsAddr, ov.side)
                    end
                end
            end
        end
    end
    return wires
end

function Hardware.discover(compLib, state)
    local cl = compLib or component
    Hardware.clearProxyCache(state)
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
        for _, ctype in ipairs({ "me_interface", "fluid_interface", "me_controller" }) do
            for addr in cl.list(ctype, true) do
                if not seenIface[addr] then
                    seenIface[addr] = true
                    local p = cl.proxy(addr)
                    local hasNet = (p ~= nil) and (type(p.getItemsInNetwork) == "function")
                    if hasNet then
                        local hasSub = (type(p.setItemEventSubscription) == "function")
                        interfaces[#interfaces + 1] = {
                            address = addr,
                            shortAddr = Hardware.shortAddr(addr),
                            ctype = ctype,
                            isMainnet = (ctype == "me_controller"),
                            hasEventSub = hasSub,
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

local function isSideAlreadyOff(proxy, side)
    if not proxy or type(proxy.getBundledOutput) ~= "function" then return false end
    local ok, tbl = pcall(proxy.getBundledOutput, side)
    if not ok or type(tbl) ~= "table" then return false end
    if tbl[0] == nil and tbl[15] == nil then return false end
    for c = 0, 15 do
        if (tonumber(tbl[c]) or 0) ~= 0 then
            return false
        end
    end
    return true
end

local function writeSingleSideOutput(proxy, side, activeColorOrNil)
    if activeColorOrNil == nil and isSideAlreadyOff(proxy, side) then
        return true, nil
    end
    local tbl = {}
    for c = 0, 15 do
        tbl[c] = (activeColorOrNil == c) and 255 or 0
    end
    local ok = pcall(proxy.setBundledOutput, side, tbl)
    if ok then
        return true, nil
    end

    -- Fallback for drivers supporting (side, color, value) only: turn OFF before ON.
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

-- Drive a single active color (0..15) or nil (ALL OFF) on a Redstone I/O bundled side.
function Hardware.setPoolOutputs(rsAddr, side, activeColorOrNil, compLib, state)
    if not rsAddr or rsAddr == "" or side == nil then
        return false, "unconfigured redstone/side"
    end
    local proxy = getProxy(rsAddr, compLib, state and state._proxies)
    if not proxy or type(proxy.setBundledOutput) ~= "function" then
        return false, "no bundled redstone proxy"
    end
    side = math.floor(tonumber(side))
    local ok, err = writeSingleSideOutput(proxy, side, activeColorOrNil)
    if ok then
        local cache = (state and state._lastBundled) or Hardware._globalLastBundled
        cache[rsAddr] = cache[rsAddr] or {}
        cache[rsAddr][side] = (activeColorOrNil == nil) and -1 or activeColorOrNil
    end
    return ok, err
end

-- Atomically flush only dirty (rsAddr, side) wires in `wireTargets` ({ [rsAddr] = { [side] = colorOrNil } }).
-- Returns ok, err, numWrites.
function Hardware.flushWireTargets(wireTargets, compLib, state, forceWrite)
    local cache = (state and state._lastBundled) or Hardware._globalLastBundled
    local pCache = state and state._proxies
    local writes = 0

    for rsAddr, sidesMap in pairs(wireTargets) do
        local proxy = getProxy(rsAddr, compLib, pCache)
        if not proxy or type(proxy.setBundledOutput) ~= "function" then
            return false, "no bundled redstone proxy (" .. Hardware.shortAddr(rsAddr) .. ")", writes
        end
        cache[rsAddr] = cache[rsAddr] or {}
        local rsCache = cache[rsAddr]

        local dirtySides = {}
        for side, targetVal in pairs(sidesMap) do
            local norm = (type(targetVal) == "number") and targetVal or -1
            if forceWrite or rsCache[side] ~= norm then
                dirtySides[#dirtySides + 1] = { side = side, norm = norm, colorOrNil = (norm >= 0) and norm or nil }
            end
        end

        if #dirtySides > 0 then
            -- Always turn OFF leaving sides (norm == -1) before turning ON entering sides (norm >= 0).
            -- Uses world-relative (side, colorTbl) calls so wrenched/rotated Redstone I/O blocks match SIDE_NAMES.
            table.sort(dirtySides, function(a, b)
                if a.norm ~= b.norm then return a.norm < b.norm end
                return a.side < b.side
            end)
            for _, ds in ipairs(dirtySides) do
                local okOne, errOne = writeSingleSideOutput(proxy, ds.side, ds.colorOrNil)
                if not okOne then
                    return false, errOne, writes
                end
                rsCache[ds.side] = ds.norm
                writes = writes + 1
            end
        end
    end
    return true, nil, writes
end

function Hardware.invalidateRedstoneCache(state)
    if state then
        state._lastBundled = {}
    end
    Hardware._globalLastBundled = {}
end

function Hardware.zeroAllManagedPools(cfg, compLib, state)
    local wires = Hardware.listManagedWires(cfg)
    local seen = {}
    local cleared = 0
    local targets = {}
    for _, w in ipairs(wires) do
        targets[w.rsAddr] = targets[w.rsAddr] or {}
        targets[w.rsAddr][w.side] = false
        if not seen[w.key] then
            seen[w.key] = true
            cleared = cleared + 1
        end
    end
    if next(targets) ~= nil then
        Hardware.flushWireTargets(targets, compLib, state, true)
    end
    return cleared
end

function Hardware.zeroAllBundledSides(compLib, state)
    local cl = compLib or component
    if not cl.list then return 0 end
    local cleared = 0
    for addr in cl.list("redstone", true) do
        local p = cl.proxy(addr)
        if p and type(p.setBundledOutput) == "function" then
            for s = 0, 5 do
                Hardware.setPoolOutputs(addr, s, nil, cl, state)
            end
            cleared = cleared + 1
        end
    end
    return cleared
end

-- Aggregate stats directly from raw maps ({ [itemKey] = qty }, meta, fluids).
-- Used identically by both full scans and incremental GTNH 2.9 event deltas.
function Hardware.computeStatsFromMaps(rawItemsMap, rawItemsMeta, rawFluidsMap, rawFluidLabels, slice, opts)
    opts = opts or {}
    local ignoreBuiltin = (opts.ignoreBuiltinNC ~= false)
    local baseItems = (slice and slice.baselineItems) or {}
    local baseFluids = (slice and slice.baselineFluids) or {}

    local itemUnits = 0
    local activeItemTypes = 0
    local topLabel, topScore = nil, 0
    local activeItems = {}
    for key, total in pairs(rawItemsMap or {}) do
        local meta = rawItemsMeta and rawItemsMeta[key]
        local skipped = ignoreBuiltin and meta and Hardware.isBuiltinIgnoredNC(meta)
        if total > 0 and not skipped then
            local base = math.max(0, math.floor(tonumber(baseItems[key]) or 0))
            local rem = total - base
            if rem > 0 then
                activeItemTypes = activeItemTypes + 1
                itemUnits = itemUnits + rem
                local lbl = (meta and meta.label and meta.label ~= "") and meta.label or key
                activeItems[#activeItems + 1] = { key = key, label = lbl, qty = rem }
                if rem > topScore then
                    topScore = rem
                    topLabel = lbl
                end
            end
        end
    end

    local fluidUnits = 0
    local activeFluidTypes = 0
    local activeFluids = {}
    for key, total in pairs(rawFluidsMap or {}) do
        if total > 0 then
            local base = math.max(0, math.floor(tonumber(baseFluids[key]) or 0))
            local rem = total - base
            if rem > 0 then
                activeFluidTypes = activeFluidTypes + 1
                fluidUnits = fluidUnits + rem
                local lbl = (rawFluidLabels and rawFluidLabels[key] and rawFluidLabels[key] ~= "") and rawFluidLabels[key] or key
                local eqUnits = rem / 1000.0
                activeFluids[#activeFluids + 1] = { key = key, label = lbl, qty = rem }
                if eqUnits > topScore then
                    topScore = eqUnits
                    topLabel = lbl
                end
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
        ingredientSig = Hardware.buildIngredientSig(activeItems, activeFluids),
    }
end

local function populateMapsFromLists(rawItems, rawFluids)
    local itemsMap, itemsMeta = {}, {}
    if type(rawItems) == "table" then
        for i = 1, #rawItems do
            local st = rawItems[i]
            if type(st) == "table" and st.name then
                local qty = math.floor(tonumber(st.size or st.amount) or 0)
                if qty > 0 then
                    local key = Hardware.stackKey(st, false)
                    itemsMap[key] = (itemsMap[key] or 0) + qty
                    local prev = itemsMeta[key]
                    itemsMeta[key] = {
                        name = st.name,
                        damage = st.damage,
                        label = (st.label and st.label ~= "") and st.label or (prev and prev.label) or "",
                    }
                end
            end
        end
    end

    local fluidsMap, fluidLabels = {}, {}
    if type(rawFluids) == "table" then
        for i = 1, #rawFluids do
            local fl = rawFluids[i]
            if type(fl) == "table" and fl.name then
                local qty = math.floor(tonumber(fl.amount or fl.size) or 0)
                if qty > 0 then
                    local key = Hardware.stackKey(fl, true)
                    fluidsMap[key] = (fluidsMap[key] or 0) + qty
                    if fl.label and fl.label ~= "" then
                        fluidLabels[key] = fl.label
                    end
                end
            end
        end
    end

    return itemsMap, itemsMeta, fluidsMap, fluidLabels
end

function Hardware.scanSubnet(addr, slice, opts, compLib)
    opts = opts or {}
    if not addr or addr == "" then
        return { ok = false, itemUnits = 0, fluidUnits = 0, workScore = 0, activeItemTypes = 0, activeFluidTypes = 0, topLabel = "", ingredientSig = "", err = "Unbound" }
    end
    local proxy = getProxy(addr, compLib, opts.proxyCache)
    if not proxy then
        return { ok = false, itemUnits = 0, fluidUnits = 0, workScore = 0, activeItemTypes = 0, activeFluidTypes = 0, topLabel = "", ingredientSig = "", err = "Component offline" }
    end
    if type(proxy.getItemsInNetwork) ~= "function" then
        return { ok = false, itemUnits = 0, fluidUnits = 0, workScore = 0, activeItemTypes = 0, activeFluidTypes = 0, topLabel = "", ingredientSig = "", err = "Flat part interface (no NetworkControl)" }
    end

    local rawItems, errI = safeCall(proxy, "getItemsInNetwork")
    if rawItems == nil then
        return { ok = false, itemUnits = 0, fluidUnits = 0, workScore = 0, activeItemTypes = 0, activeFluidTypes = 0, topLabel = "", ingredientSig = "", err = errI or "getItemsInNetwork failed" }
    end
    local rawFluids = {}
    if type(proxy.getFluidsInNetwork) == "function" then
        local fl = safeCall(proxy, "getFluidsInNetwork")
        if type(fl) == "table" then
            rawFluids = fl
        end
    end

    local itemsMap, itemsMeta, fluidsMap, fluidLabels = populateMapsFromLists(rawItems, rawFluids)
    local agg = Hardware.computeStatsFromMaps(itemsMap, itemsMeta, fluidsMap, fluidLabels, slice, opts)
    agg.ok = true
    agg.rawItemCount = #rawItems
    agg.rawFluidCount = #rawFluids
    agg.rawItems = rawItems
    agg.rawFluids = rawFluids
    agg.itemsMap = itemsMap
    agg.itemsMeta = itemsMeta
    agg.fluidsMap = fluidsMap
    agg.fluidLabels = fluidLabels
    return agg
end

-- Apply incremental GTNH 2.9 storage event deltas (`network_item_changed` / `network_fluid_changed`)
-- directly into `sState._rawItems` / `_rawFluids` in O(k) pure Lua with 0 server-thread calls.
function Hardware.applyDeltas(sState, isFluid, deltas)
    if type(sState) ~= "table" or type(deltas) ~= "table" then return 0 end
    sState._rawItems = sState._rawItems or {}
    sState._rawItemsMeta = sState._rawItemsMeta or {}
    sState._rawFluids = sState._rawFluids or {}
    sState._rawFluidLabels = sState._rawFluidLabels or {}

    local applied = 0
    for i = 1, #deltas do
        local d = deltas[i]
        if type(d) == "table" and d.name then
            if isFluid then
                local delta = tonumber(d.amount or d.size) or 0
                if delta ~= 0 then
                    local key = Hardware.stackKey(d, true)
                    local newQty = math.max(0, (sState._rawFluids[key] or 0) + delta)
                    if newQty <= 0 then
                        sState._rawFluids[key] = nil
                        sState._rawFluidLabels[key] = nil
                    else
                        sState._rawFluids[key] = newQty
                        if d.label and d.label ~= "" then
                            sState._rawFluidLabels[key] = d.label
                        end
                    end
                    applied = applied + 1
                end
            else
                local delta = tonumber(d.size or d.amount) or 0
                if delta ~= 0 then
                    local key = Hardware.stackKey(d, false)
                    local newQty = math.max(0, (sState._rawItems[key] or 0) + delta)
                    if newQty <= 0 then
                        sState._rawItems[key] = nil
                        sState._rawItemsMeta[key] = nil
                    else
                        local prev = sState._rawItemsMeta[key]
                        sState._rawItems[key] = newQty
                        sState._rawItemsMeta[key] = {
                            name = d.name,
                            damage = d.damage,
                            label = (d.label and d.label ~= "") and d.label or (prev and prev.label) or "",
                        }
                    end
                    applied = applied + 1
                end
            end
        end
    end
    return applied
end

local function ensureAddrSubscribed(proxy, addr, subCache)
    if not proxy or type(proxy.setItemEventSubscription) ~= "function" then
        return false
    end
    local alreadyItem = false
    if type(proxy.isItemEventSubscription) == "function" then
        local okC, curI = pcall(proxy.isItemEventSubscription)
        alreadyItem = okC and (curI == true)
    elseif subCache and subCache[addr] then
        alreadyItem = true
    end
    local hasSub = alreadyItem
    if not alreadyItem then
        local okI = pcall(proxy.setItemEventSubscription, true)
        if okI then
            hasSub = true
        end
    end
    if type(proxy.setFluidEventSubscription) == "function" then
        local alreadyFluid = false
        if type(proxy.isFluidEventSubscription) == "function" then
            local okF, curF = pcall(proxy.isFluidEventSubscription)
            alreadyFluid = okF and (curF == true)
        elseif subCache and subCache[addr] then
            alreadyFluid = true
        end
        if not alreadyFluid then
            pcall(proxy.setFluidEventSubscription, true)
        end
    end
    return hasSub
end

local function unsubscribeAddr(proxy)
    if not proxy then return end
    if type(proxy.setItemEventSubscription) == "function" then
        local needOff = true
        if type(proxy.isItemEventSubscription) == "function" then
            local okC, curI = pcall(proxy.isItemEventSubscription)
            if okC and curI == false then needOff = false end
        end
        if needOff then pcall(proxy.setItemEventSubscription, false) end
    end
    if type(proxy.setFluidEventSubscription) == "function" then
        local needOff = true
        if type(proxy.isFluidEventSubscription) == "function" then
            local okF, curF = pcall(proxy.isFluidEventSubscription)
            if okF and curF == false then needOff = false end
        end
        if needOff then pcall(proxy.setFluidEventSubscription, false) end
    end
end

-- Subscribe bound me_interface/fluid_interface blocks to GTNH 2.9 push events and rebuild lookup index.
function Hardware.syncSubscriptions(cfg, state, compLib)
    if not state then return false end
    local addrToSlices = {}
    local proxyCache = state._proxies
    local subCache = state._subbedAddrs or {}
    state._subbedAddrs = subCache
    local guidedCache = state._guidedSubAddrs or {}
    local boundSet = {}
    local allSub = true
    local anyBound = false

    for _, pool in ipairs((cfg and cfg.pools) or {}) do
        local numSlices = tonumber(pool.numSlices) or 16
        for ncIdx = 0, numSlices - 1 do
            local slice = pool.slices and pool.slices[ncIdx]
            local sKey = tostring(pool.id) .. ":" .. tostring(ncIdx)
            local sState = state.sliceStates and state.sliceStates[sKey]
            if slice and slice.ifaceAddr and slice.ifaceAddr ~= "" then
                anyBound = true
                local addr = slice.ifaceAddr
                boundSet[addr] = true
                addrToSlices[addr] = addrToSlices[addr] or {}
                addrToSlices[addr][#addrToSlices[addr] + 1] = { poolId = pool.id, ncIdx = ncIdx, slice = slice }

                local proxy = getProxy(addr, compLib, proxyCache)
                local hasSub = ensureAddrSubscribed(proxy, addr, subCache)
                if hasSub then
                    subCache[addr] = true
                end
                if sState then
                    sState._hasEventSub = hasSub
                end
                if not hasSub and pool.enabled ~= false and slice.enabled ~= false and slice.priority ~= "off" then
                    allSub = false
                end
            elseif sState then
                sState._hasEventSub = false
            end
        end
    end

    for addr in pairs(subCache) do
        if not boundSet[addr] then
            if not guidedCache[addr] then
                local proxy = getProxy(addr, compLib, proxyCache)
                unsubscribeAddr(proxy)
            end
            subCache[addr] = nil
        end
    end

    state._addrToSlices = addrToSlices
    state._allSubscribed = anyBound and allSub
    return state._allSubscribed
end

function Hardware.setGuidedSubscriptions(addrs, enable, compLib, state)
    if not state then return 0 end
    local proxyCache = state._proxies
    local subCache = state._subbedAddrs or {}
    local guidedCache = state._guidedSubAddrs or {}
    state._guidedSubAddrs = guidedCache
    local changed = 0

    if enable then
        for i = 1, #(addrs or {}) do
            local addr = addrs[i]
            if type(addr) == "string" and addr ~= "" then
                local proxy = getProxy(addr, compLib, proxyCache)
                if ensureAddrSubscribed(proxy, addr, guidedCache) then
                    guidedCache[addr] = true
                    changed = changed + 1
                end
            end
        end
    else
        for addr in pairs(guidedCache) do
            if not subCache[addr] then
                local proxy = getProxy(addr, compLib, proxyCache)
                unsubscribeAddr(proxy)
                changed = changed + 1
            end
            guidedCache[addr] = nil
        end
    end
    return changed
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

function Hardware.suggestNcLabel(meta)
    if type(meta) ~= "table" then return nil end
    local name = tostring(meta.name or "")
    local label = tostring(meta.label or "")
    if name == "gregtech:gt.integrated_circuit"
        or name:find("integrated_circuit", 1, true)
        or label:find("Programmed Circuit", 1, true) then
        return "Circuit #" .. tostring(math.floor(tonumber(meta.damage) or 0))
    end
    local lowerLbl = label:lower()
    if label ~= "" and (Hardware.isBuiltinIgnoredNC(meta)
        or lowerLbl:find("catalyst", 1, true)
        or lowerLbl:find("shape", 1, true)
        or lowerLbl:find("mold", 1, true)) then
        return label
    end
    return nil
end

function Hardware.snapshotInterfaces(addrs, compLib)
    local snaps = {}
    for i = 1, #(addrs or {}) do
        local addr = addrs[i]
        local res = Hardware.scanSubnet(addr, nil, { ignoreBuiltinNC = false }, compLib)
        if res.ok then
            snaps[addr] = {
                items = res.itemsMap or {},
                itemsMeta = res.itemsMeta or {},
                fluids = res.fluidsMap or {},
            }
        end
    end
    return snaps
end

local function hasChangedStock(beforeMap, afterMap, metaMap, beforeMetaMap)
    for k, afterQty in pairs(afterMap) do
        if afterQty > (beforeMap[k] or 0) then
            return true, k, (metaMap and metaMap[k]) or (beforeMetaMap and beforeMetaMap[k])
        end
    end
    for k, beforeQty in pairs(beforeMap) do
        if beforeQty > (afterMap[k] or 0) then
            return true, k, (beforeMetaMap and beforeMetaMap[k]) or (metaMap and metaMap[k])
        end
    end
    return false, nil, nil
end

function Hardware.detectChangedInterface(addrs, prevSnaps, compLib)
    for i = 1, #(addrs or {}) do
        local addr = addrs[i]
        local prev = prevSnaps and prevSnaps[addr]
        if prev then
            local res = Hardware.scanSubnet(addr, nil, { ignoreBuiltinNC = false }, compLib)
            if res.ok then
                local it, itMeta, fl = res.itemsMap or {}, res.itemsMeta or {}, res.fluidsMap or {}
                local okI, keyI, hitMeta = hasChangedStock(prev.items, it, itMeta, prev.itemsMeta)
                if okI then return addr, keyI, hitMeta, it, fl end
                local okF, keyF = hasChangedStock(prev.fluids, fl)
                if okF then return addr, keyF, nil, it, fl end
            end
        end
    end
    return nil
end

-- 1-Click Trunk Auto-Pair:
-- Place 1 marker item (e.g. Cobblestone in Chest + Storage Bus) on the Machine Trunk for Channel `chIdx`.
-- Sweeps NC indices 0..numSlices-1 on that channel; whichever subnet suddenly sees the marker is bound!
function Hardware.autoScanTrunkPool(pool, candidateAddrs, opts, compLib)
    opts = opts or {}
    local cl = compLib or component
    local chIdx = math.max(1, math.floor(tonumber(opts.channelIdx) or 1))
    local maxNc = (tonumber(pool and pool.numSlices) or 16) - 1

    if not pool or not Hardware.resolveSignal(pool, chIdx, 0) then
        return { ok = false, boundCount = 0, bindings = {}, error = "Configure Channel " .. tostring(chIdx) .. " Redstone I/O & Side first." }
    end
    local sleepFn = opts.sleepFn or (os and os.sleep) or function() end
    local pulseSec = tonumber(opts.pulseSec) or 0.25

    -- Force all wires of this pool OFF first
    local clearWires = {}
    for nc = 0, maxNc do
        local rsA, s = Hardware.resolveSignal(pool, chIdx, nc)
        if rsA and s ~= nil then
            clearWires[rsA] = clearWires[rsA] or {}
            clearWires[rsA][s] = false
        end
    end
    Hardware.flushWireTargets(clearWires, cl, nil, true)
    pcall(sleepFn, pulseSec)

    local baseline = Hardware.snapshotInterfaces(candidateAddrs, cl)
    local bindings = {}
    local alreadyUsed = {}
    for nc = 0, maxNc do
        local s = pool.slices and pool.slices[nc]
        if s and s.ifaceAddr and s.ifaceAddr ~= "" and opts.overwriteExisting ~= true then
            alreadyUsed[s.ifaceAddr] = nc
        end
    end

    local okSweep, sweepErr = pcall(function()
        for nc = 0, maxNc do
            local slice = pool.slices and pool.slices[nc]
            local rsAddr, side, color = Hardware.resolveSignal(pool, chIdx, nc)
            if slice and rsAddr and side ~= nil and (opts.overwriteExisting == true or not slice.ifaceAddr or slice.ifaceAddr == "") then
                Hardware.setPoolOutputs(rsAddr, side, color, cl)
                sleepFn(pulseSec)
                local remaining = {}
                for i = 1, #candidateAddrs do
                    local a = candidateAddrs[i]
                    if not alreadyUsed[a] then
                        remaining[#remaining + 1] = a
                    end
                end
                local hitAddr, hitKey = Hardware.detectChangedInterface(remaining, baseline, cl)
                Hardware.setPoolOutputs(rsAddr, side, nil, cl)
                if hitAddr then
                    slice.ifaceAddr = hitAddr
                    alreadyUsed[hitAddr] = nc
                    bindings[#bindings + 1] = { color = nc, ncIdx = nc, channelIdx = chIdx, address = hitAddr, marker = hitKey }
                end
            end
        end
    end)

    Hardware.flushWireTargets(clearWires, cl, nil, true)
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
                local needOpen = true
                if type(m.isOpen) == "function" then
                    local okO, isO = pcall(m.isOpen, Hardware.MESH_PORT)
                    if okO and isO == true then needOpen = false end
                end
                if needOpen and m.open then pcall(m.open, Hardware.MESH_PORT) end

                local isW = false
                if m.isWireless then
                    local okW, rW = pcall(m.isWireless)
                    isW = okW and (rW == true)
                end
                if isW and m.setStrength then
                    local needStr = true
                    if type(m.getStrength) == "function" then
                        local okG, curStr = pcall(m.getStrength)
                        if okG and tonumber(curStr) and tonumber(curStr) >= 400 then needStr = false end
                    end
                    if needStr then pcall(m.setStrength, 400) end
                end
                if type(m.setWakeMessage) == "function" then
                    local needWake = true
                    if type(m.getWakeMessage) == "function" then
                        local okWk, curWk, curFuzzy = pcall(m.getWakeMessage)
                        if okWk and curWk == Hardware.WAKE_MSG and curFuzzy == true then needWake = false end
                    end
                    if needWake then pcall(m.setWakeMessage, Hardware.WAKE_MSG, true) end
                end
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
        if tunnel and type(tunnel.setWakeMessage) == "function" then
            local needWake = true
            if type(tunnel.getWakeMessage) == "function" then
                local okWk, curWk, curFuzzy = pcall(tunnel.getWakeMessage)
                if okWk and curWk == Hardware.WAKE_MSG and curFuzzy == true then needWake = false end
            end
            if needWake then pcall(tunnel.setWakeMessage, Hardware.WAKE_MSG, true) end
        end
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
        local chOut = {}
        for chIdx, ch in ipairs(p.channels or {}) do
            local cs = pst.channels and pst.channels[chIdx] or {}
            chOut[#chOut + 1] = {
                id = chIdx,
                name = ch.name,
                gtDye = ch.gtDye,
                gtColor = ch.gtColor,
                phase = cs.phase or "IDLE",
                activeNc = cs.activeNc,
                activeLabel = cs.activeLabel or "",
                etaSec = cs.activeEtaSec,
            }
        end
        poolsOut[pi] = {
            id = p.id,
            name = p.name,
            mode = p.mode or "mlfq",
            phase = pst.phase or "IDLE",
            activeColor = pst.activeColor,
            activeLabel = pst.activeLabel or "",
            etaSec = pst.activeEtaSec,
            channels = chOut,
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
    Hardware._meshStartedAt = Hardware._meshStartedAt or nowSec
    local peerSilent = (Hardware._lastMainnetSeen and (nowSec - Hardware._lastMainnetSeen) >= 60)
        or ((not Hardware._lastMainnetSeen) and (nowSec - Hardware._meshStartedAt) >= 60)
    if peerSilent and (nowSec - (Hardware._lastReverseWake or -1000)) >= 60 then
        Hardware._lastReverseWake = nowSec
        Hardware._mainnetWakeAttempts = (Hardware._mainnetWakeAttempts or 0) + 1
        local wakeTarget = (Hardware._mainnetMeshAddr and Hardware._mainnetWakeAttempts <= 2) and Hardware._mainnetMeshAddr or nil
        sendMeshPacket(cl, wakeTarget, viaTunnel, Hardware.WAKE_MSG)
    end
    return true
end

function Hardware.handleMeshMessage(cfg, state, localAddr, sender, port, msgType, reqId, payload, compLib)
    if cfg and cfg.extLinkMode == "off" then return false end
    local cl = compLib or component
    local modem, tunnel, tAddr = getMeshTransports(cl)
    local isMeshPort = (port == Hardware.MESH_PORT) or (port == 0 and tunnel and tAddr and localAddr == tAddr)
    if not isMeshPort or not sender then return false end

    local upNow = (computer and computer.uptime and computer.uptime()) or 0
    if msgType == "MESH_MAINNET_HELLO" or msgType == Hardware.WAKE_MSG then
        Hardware._mainnetMeshAddr = sender
        Hardware._mainnetMeshViaTunnel = (port == 0)
        Hardware._lastMainnetSeen = upNow
        Hardware._mainnetWakeAttempts = 0
        Hardware.pushMeshMetrics(cfg, state, upNow, cl, true)
        return true
    elseif msgType == "UNIV_ACK" then
        Hardware._mainnetMeshAddr = sender
        Hardware._mainnetMeshViaTunnel = (port == 0)
        Hardware._lastMainnetSeen = upNow
        Hardware._mainnetWakeAttempts = 0
        return true
    elseif msgType == "UNIV_CMD" then
        Hardware._mainnetMeshAddr = sender
        Hardware._mainnetMeshViaTunnel = (port == 0)
        Hardware._lastMainnetSeen = upNow
        Hardware._mainnetWakeAttempts = 0
        local cmd = (type(payload) == "string") and serialization.unserialize(payload) or nil
        local reply = { ok = false, error = "Unknown command" }
        if type(cmd) == "table" then
            if cmd.action == "pause" then
                cfg.armed = false
                Hardware.zeroAllManagedPools(cfg, cl, state)
                reply = { ok = true, armed = false }
            elseif cmd.action == "resume" then
                cfg.armed = true
                if state then state._forcePollNow = true end
                reply = { ok = true, armed = true }
            elseif cmd.action == "poll_now" then
                if state then
                    state._forcePollNow = true
                    state._forceFullScan = true
                end
                reply = { ok = true }
            elseif cmd.action == "force_slice" then
                local pId = tonumber(cmd.poolId) or 1
                local col = tonumber(cmd.color)
                if col ~= nil and col >= 0 and col <= 31 and state then
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
            elseif cmd.action == "update_local" then
                local hasInet = cl and ((cl.isAvailable and cl.isAvailable("internet")) or (cl.list and cl.list("internet", true)() ~= nil))
                local hasMesh = cl and ((cl.isAvailable and (cl.isAvailable("modem") or cl.isAvailable("tunnel")))
                    or (cl.list and (cl.list("modem", true)() ~= nil or cl.list("tunnel", true)() ~= nil)))
                if not hasInet and not hasMesh then
                    reply = { ok = false, error = "No Internet Card or OC Mesh modem/tunnel" }
                else
                    local u = (type(cmd.url) == "string" and cmd.url ~= "") and cmd.url or "http://127.0.0.1:8765/oc-raw"
                    if not u:match("^https?://[%w%.%-_:]+") then
                        reply = { ok = false, error = "Invalid update URL" }
                    else
                        if state then
                            state._pendingUpdateUrl = u
                            state._pendingReboot = true
                            state._forcePollNow = true
                        end
                        reply = { ok = true, updating = true, viaMesh = (not hasInet), url = u }
                    end
                end
            elseif cmd.action == "reboot" then
                if state then
                    state._pendingReboot = true
                    state._forcePollNow = true
                end
                reply = { ok = true, rebooting = true }
            end
        end
        sendMeshPacket(cl, sender, (port == 0), "UNIV_REPLY", tostring(reqId or ""), serialization.serialize(reply))
        return true
    end
    return false
end

return Hardware
