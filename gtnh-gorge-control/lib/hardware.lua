-- /home/gorge/lib/hardware.lua
-- Self-healing hardware abstraction for Forge of the Gods & Multi-Exoticizer Rack:
--   - Dynamic 10-slot/Exoticizer Database partitioning (up to 8 modules on 1 Tier-3 Database)
--   - Dynamic Storage Cell drain (1..6 cells) through ME IO Port
--   - Bounded, non-hanging fake-pattern request & cancel
--   - Godforge controller (`gt_machine`) + LSC EU telemetry
--   - Zero-tick cached OC Mesh (`port 4205`: `GORGE_METRICS` / `GORGE_CMD`)

local component = require("component")
local okComp, computer = pcall(require, "computer")
if not okComp then computer = nil end
local serialization = require("serialization")
local Plasmas = require("lib.plasmas")

local Hardware = {}

Hardware.MESH_PORT = 4205
Hardware.SIDE_NAMES = {
    [0] = "Down",
    [1] = "Up",
    [2] = "North",
    [3] = "South",
    [4] = "West",
    [5] = "East",
}

local function stripColor(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("\194\167.", ""):gsub("\167.", ""):gsub("[\1-\31]", ""))
end

function Hardware.shortAddr(addr)
    if type(addr) ~= "string" or addr == "" then return "None" end
    return addr:sub(1, 8)
end

function Hardware.clearProxyCache(state)
    if state then
        state._proxies = {}
        state._meshModem = nil
        state._meshTunnel = nil
        state._meshTunnelAddr = nil
    end
end

local function getProxy(addr, compLib, state)
    if type(addr) ~= "string" or addr == "" then return nil, "unconfigured address" end
    local cache = state and state._proxies
    if cache and cache[addr] ~= nil then
        return cache[addr]
    end
    local cl = compLib or component
    if not cl.proxy then return nil, "no component API" end
    local p = cl.proxy(addr)
    if not p then return nil, "component offline (" .. Hardware.shortAddr(addr) .. ")" end
    if cache then cache[addr] = p end
    return p
end

-- Safe component call that evicts stale proxies and re-resolves once on failure.
local function callSafe(addr, method, compLib, state, ...)
    local p, errP = getProxy(addr, compLib, state)
    if not p then return false, errP end
    local fn = p[method]
    if type(fn) ~= "function" then
        return false, "missing method " .. tostring(method)
    end
    local ok, r1, r2, r3 = pcall(fn, ...)
    if ok then
        return true, r1, r2, r3
    end
    if state and state._proxies then
        state._proxies[addr] = nil
    end
    local p2 = getProxy(addr, compLib, state)
    if p2 and type(p2[method]) == "function" then
        local ok2, a1, a2, a3 = pcall(p2[method], ...)
        if ok2 then
            return true, a1, a2, a3
        end
        return false, tostring(a1)
    end
    return false, tostring(r1)
end

function Hardware.fakeRecipeName(exIdx, dbAddr)
    return string.format("Fake recipe G%d %s", tonumber(exIdx) or 1, Hardware.shortAddr(dbAddr or "000000"))
end

function Hardware.resolveDatabase(ex, compLib, state)
    if ex and type(ex.databaseAddress) == "string" and ex.databaseAddress ~= "" then
        local p = getProxy(ex.databaseAddress, compLib, state)
        if p then return p, ex.databaseAddress end
    end
    local cl = compLib or component
    if cl.list then
        local addr = cl.list("database", true)()
        if addr then
            local p = getProxy(addr, cl, state)
            if p then return p, addr end
        end
    end
    if cl.isAvailable and cl.isAvailable("database") and cl.database then
        return cl.database, cl.database.address
    end
    return nil, nil
end

function Hardware.discover(compLib, state)
    local cl = compLib or component
    Hardware.clearProxyCache(state)
    local interfaces, transposers, redstones, databases, machines = {}, {}, {}, {}, {}
    local lscAddr = nil

    if cl.list then
        local seenIf = {}
        for _, ctype in ipairs({ "me_interface", "fluid_interface" }) do
            for addr in cl.list(ctype, true) do
                if not seenIf[addr] then
                    seenIf[addr] = true
                    local p = getProxy(addr, cl, state)
                    interfaces[#interfaces + 1] = {
                        address = addr,
                        shortAddr = Hardware.shortAddr(addr),
                        ctype = ctype,
                        hasNet = p ~= nil and (type(p.getItemsInNetwork) == "function"),
                        hasPatterns = p ~= nil and (type(p.setInterfacePatternInput) == "function"),
                        hasCpus = p ~= nil and (type(p.getCpus) == "function"),
                    }
                end
            end
        end
        table.sort(interfaces, function(a, b) return a.address < b.address end)

        for addr in cl.list("transposer", true) do
            transposers[#transposers + 1] = { address = addr, shortAddr = Hardware.shortAddr(addr) }
        end
        table.sort(transposers, function(a, b) return a.address < b.address end)

        for addr in cl.list("redstone", true) do
            local p = getProxy(addr, cl, state)
            redstones[#redstones + 1] = {
                address = addr,
                shortAddr = Hardware.shortAddr(addr),
                bundled = (p ~= nil and type(p.setBundledOutput) == "function"),
            }
        end
        table.sort(redstones, function(a, b) return a.address < b.address end)

        for addr in cl.list("database", true) do
            local p = getProxy(addr, cl, state)
            local slots = 9
            if p and p.get then
                if pcall(p.get, 81) then slots = 81
                elseif pcall(p.get, 27) then slots = 27
                end
            end
            databases[#databases + 1] = { address = addr, shortAddr = Hardware.shortAddr(addr), slots = slots }
        end
        table.sort(databases, function(a, b) return a.address < b.address end)

        for addr in cl.list("gt_machine", true) do
            local p = getProxy(addr, cl, state)
            local mName = ""
            if p and p.getName then
                local okN, resN = pcall(p.getName)
                if okN and resN then mName = tostring(resN) end
            end
            local lname = mName:lower()
            if lname:find("supercapacitor", 1, true) then
                lscAddr = lscAddr or addr
            else
                local role = "module"
                if lname:find("stellar_forge", 1, true)
                    or lname:find("godforge", 1, true)
                    or lname:find("forgeofgods", 1, true)
                    or lname:find("fog", 1, true) then
                    role = "godforge"
                elseif lname:find("exotic", 1, true) or lname:find("quark", 1, true) then
                    role = "exotic"
                end
                machines[#machines + 1] = {
                    address = addr,
                    shortAddr = Hardware.shortAddr(addr),
                    name = mName,
                    role = role,
                }
            end
        end
        for addr in cl.list("LSC", true) do
            lscAddr = addr
            break
        end
        table.sort(machines, function(a, b) return a.address < b.address end)
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

    return {
        interfaces = interfaces,
        transposers = transposers,
        redstones = redstones,
        databases = databases,
        machines = machines,
        lscAddr = lscAddr,
        hasModem = hasModem,
        hasWireless = hasWireless,
        hasTunnel = hasTunnel,
        hasGpu = cl.list and (cl.list("gpu", true)() ~= nil) or false,
        hasScreen = cl.list and (cl.list("screen", true)() ~= nil) or false,
    }
end

function Hardware.readRedstoneInput(ex, compLib, state)
    if not ex or not ex.redstoneIoAddress or ex.redstoneIoAddress == "" then
        return true, 0
    end
    local side = tonumber(ex.redstoneIoSide) or 0
    local ok, val = callSafe(ex.redstoneIoAddress, "getInput", compLib, state, side)
    if not ok then
        return false, 0, val
    end
    return true, tonumber(val) or 0
end

function Hardware.readOutputSubnet(ex, compLib, state)
    local addr = ex and ex.outputMeInterfaceAddress
    if not addr or addr == "" then
        return { ok = false, err = "Unbound Output ME Interface", outputs = {}, distinct = 0 }
    end
    local okI, items = callSafe(addr, "getItemsInNetwork", compLib, state, {})
    if not okI then
        return { ok = false, err = tostring(items), outputs = {}, distinct = 0 }
    end
    local okF, fluids = callSafe(addr, "getFluidsInNetwork", compLib, state)
    if not okF then
        return { ok = false, err = tostring(fluids), outputs = {}, distinct = 0 }
    end
    local parsed, distinct = Plasmas.parseOutputNetwork(items, fluids)
    return {
        ok = true,
        outputs = parsed,
        distinct = distinct,
    }
end

-- Encode either a real batch of plasmas (3 or 7 entries) or a safe idle self-loop (`batchInputs == nil`)
-- into slot 1 of `ex.inputMeInterfaceAddress`, using reserved 10-slot database slice `slotBase..slotBase+9`.
function Hardware.encodeExoticizerPattern(ex, idx, batchInputs, compLib, state)
    local inAddr = ex and ex.inputMeInterfaceAddress
    if not inAddr or inAddr == "" then
        return false, "Unbound Input ME Interface"
    end
    local db, dbAddr = Hardware.resolveDatabase(ex, compLib, state)
    if not db or not dbAddr then
        return false, "Missing Database Upgrade (Tier 3 recommended)"
    end
    local slotBase = ((math.max(1, math.floor(tonumber(idx) or 1)) - 1) * 10) + 1
    local nNeed = batchInputs and #batchInputs or 1
    if slotBase + nNeed > 81 then
        return false, string.format("Database slot overflow at Exoticizer #%d (slot %d > 81)", idx, slotBase + nNeed)
    end

    local fakeName = Hardware.fakeRecipeName(idx, dbAddr)
    local okSetPaper, paperRes = pcall(db.set, slotBase, "minecraft:paper", 0, string.format('{display:{Name:"%s"}}', fakeName))
    if not okSetPaper or paperRes == false then
        return false, "Failed setting marker paper in Database slot " .. tostring(slotBase)
    end

    local okPat, pat = callSafe(inAddr, "getInterfacePattern", compLib, state, 1)
    if not okPat then
        return false, tostring(pat)
    end
    if type(pat) ~= "table" then
        return false, "Place an encoded pattern into Input ME Interface slot 1"
    end

    if type(pat.outputs) == "table" then
        for k in pairs(pat.outputs) do
            callSafe(inAddr, "clearInterfacePatternOutput", compLib, state, 1, k)
        end
    end
    if type(pat.inputs) == "table" then
        for k in pairs(pat.inputs) do
            callSafe(inAddr, "clearInterfacePatternInput", compLib, state, 1, k)
        end
    end

    local okOut, outErr = callSafe(inAddr, "setInterfacePatternOutput", compLib, state, 1, dbAddr, slotBase, 1, 1)
    if not okOut then
        return false, "setInterfacePatternOutput failed: " .. tostring(outErr)
    end

    if not batchInputs or #batchInputs == 0 then
        local okIn0, inErr0 = callSafe(inAddr, "setInterfacePatternInput", compLib, state, 1, dbAddr, slotBase, 1, 1)
        if not okIn0 then
            return false, "setInterfacePatternInput idle placeholder failed: " .. tostring(inErr0)
        end
        return true, fakeName
    end

    for i = 1, #batchInputs do
        local inp = batchInputs[i]
        local dbSlot = slotBase + i
        local nbt = string.format('{Fluid:"%s"}', tostring(inp.fluid))
        local okDrop, dropRes = pcall(db.set, dbSlot, "ae2fc:fluid_drop", 0, nbt)
        if not okDrop or dropRes == false then
            return false, string.format("Database fluid_drop failed for %s (slot %d)", tostring(inp.fluid), dbSlot)
        end
        local amt = math.max(1, math.floor(tonumber(inp.amount) or 1))
        local okIn, inErr = callSafe(inAddr, "setInterfacePatternInput", compLib, state, 1, dbAddr, dbSlot, amt, i)
        if not okIn then
            return false, string.format("Pattern input %d (%s) failed: %s", i, tostring(inp.fluid), tostring(inErr))
        end
    end
    return true, fakeName
end

-- Dynamically drain all cells present in Output ME Drive through ME IO Port and return them cleanly.
function Hardware.clearOutputCells(ex, compLib, state, maxWaitSec, sleepFn)
    local tpAddr = ex and ex.transposerAddress
    if not tpAddr or tpAddr == "" then
        return false, 0, "Unbound Transposer"
    end
    local ioSide = tonumber(ex.meIoPortSide) or 5
    local driveSide = tonumber(ex.meDriveSide) or 4
    local waitLimit = (tonumber(maxWaitSec) ~= nil) and tonumber(maxWaitSec) or 8.0
    local doSleep = sleepFn or (os and os.sleep) or function() end

    local okSz, driveSize = callSafe(tpAddr, "getInventorySize", compLib, state, driveSide)
    if not okSz then
        return false, 0, tostring(driveSize)
    end
    driveSize = math.max(1, math.min(10, tonumber(driveSize) or 10))

    local cellCount = 0
    for s = 1, driveSize do
        local okS, cnt = callSafe(tpAddr, "getSlotStackSize", compLib, state, driveSide, s)
        if okS and (tonumber(cnt) or 0) > 0 then
            cellCount = cellCount + 1
        end
    end
    if cellCount == 0 then
        return true, 0, "ME Drive already empty"
    end

    local movedIn = 0
    for _ = 1, cellCount do
        local okM, mv = callSafe(tpAddr, "transferItem", compLib, state, driveSide, ioSide, 1)
        if okM and (tonumber(mv) or 0) > 0 then
            movedIn = movedIn + 1
        end
    end
    if movedIn == 0 then
        return false, 0, "Could not move any cell into ME IO Port"
    end

    local function countIoOutputCells()
        local n = 0
        for s = 7, 12 do
            local okC, cnt = callSafe(tpAddr, "getSlotStackSize", compLib, state, ioSide, s)
            if okC and (tonumber(cnt) or 0) > 0 then
                n = n + 1
            end
        end
        return n
    end

    local done = countIoOutputCells()
    local elapsed = 0.0
    while done < movedIn and elapsed < waitLimit do
        pcall(doSleep, 0.1)
        elapsed = elapsed + 0.1
        done = countIoOutputCells()
    end

    if done < movedIn and waitLimit > 0 then
        -- Best-effort recovery: return whatever cells are in IO Port back to ME Drive before reporting timeout.
        for _ = 1, movedIn do
            callSafe(tpAddr, "transferItem", compLib, state, ioSide, driveSide, 1)
        end
        return false, done, string.format("ME IO Port timeout (%d/%d cells drained)", done, movedIn)
    end

    local movedBack = 0
    for s = 7, 12 do
        local okC, cnt = callSafe(tpAddr, "getSlotStackSize", compLib, state, ioSide, s)
        if okC and (tonumber(cnt) or 0) > 0 then
            local okB, mvB = callSafe(tpAddr, "transferItem", compLib, state, ioSide, driveSide, 1, s)
            if not okB or (tonumber(mvB) or 0) <= 0 then
                okB, mvB = callSafe(tpAddr, "transferItem", compLib, state, ioSide, driveSide, 1)
            end
            if okB and (tonumber(mvB) or 0) > 0 then
                movedBack = movedBack + 1
            end
        end
    end
    if movedBack < movedIn then
        for _ = 1, (movedIn - movedBack) do
            local okB, mvB = callSafe(tpAddr, "transferItem", compLib, state, ioSide, driveSide, 1)
            if okB and (tonumber(mvB) or 0) > 0 then
                movedBack = movedBack + 1
            end
        end
    end
    return true, movedBack
end

function Hardware.getFreeCpusCount(ex, compLib, state)
    local inAddr = ex and ex.inputMeInterfaceAddress
    if not inAddr or inAddr == "" then return 0, 0, "Unbound Input ME Interface" end
    local ok, cpus = callSafe(inAddr, "getCpus", compLib, state)
    if not ok or type(cpus) ~= "table" then
        return 0, 0, tostring(cpus)
    end
    local total, free = 0, 0
    for i = 1, #cpus do
        local c = cpus[i]
        if type(c) == "table" and c.cpu then
            total = total + 1
            local okB, isBusy = pcall(c.cpu.isBusy)
            if okB and isBusy == false then
                free = free + 1
            end
        end
    end
    return free, total
end

function Hardware.hasActiveFakeCraft(ex, fakeName, compLib, state)
    local inAddr = ex and ex.inputMeInterfaceAddress
    if not inAddr or inAddr == "" then return false end
    local ok, cpus = callSafe(inAddr, "getCpus", compLib, state)
    if not ok or type(cpus) ~= "table" then return false end
    for i = 1, #cpus do
        local c = cpus[i]
        if type(c) == "table" and c.cpu then
            local okB, isBusy = pcall(c.cpu.isBusy)
            if okB and isBusy == true and c.cpu.finalOutput then
                local okO, out = pcall(c.cpu.finalOutput)
                if okO and type(out) == "table" and out.label == fakeName then
                    return true
                end
            end
        end
    end
    return false
end

function Hardware.requestFakeCraft(ex, fakeName, compLib, state, maxCompSec, sleepFn)
    local inAddr = ex and ex.inputMeInterfaceAddress
    if not inAddr or inAddr == "" then return false, "Unbound Input ME Interface" end
    local okL, list = callSafe(inAddr, "getCraftables", compLib, state, { label = fakeName })
    if not okL then
        return false, tostring(list)
    end
    local craftable = type(list) == "table" and list[1] or nil
    if not craftable or type(craftable.request) ~= "function" then
        return false, "Fake craftable not registered yet: " .. tostring(fakeName)
    end
    local okR, statusObj, reqErr = pcall(craftable.request, 1)
    if not okR or not statusObj then
        return false, tostring(reqErr or statusObj or "request() failed")
    end

    local doSleep = sleepFn or (os and os.sleep) or function() end
    local limit = (tonumber(maxCompSec) ~= nil) and tonumber(maxCompSec) or 3.0
    local elapsed = 0.0
    while statusObj.isComputing and elapsed < limit do
        local okC, cmp = pcall(statusObj.isComputing)
        if not okC or cmp ~= true then break end
        pcall(doSleep, 0.1)
        elapsed = elapsed + 0.1
    end
    if statusObj.hasFailed then
        local okF, failed, why = pcall(statusObj.hasFailed)
        if okF and failed == true then
            return false, tostring(why or "Missing plasma or CPU busy")
        end
    end
    return true, "requested"
end

function Hardware.cancelFakeCraft(ex, fakeName, compLib, state, maxWaitSec, sleepFn)
    local inAddr = ex and ex.inputMeInterfaceAddress
    if not inAddr or inAddr == "" then return false, 0, "Unbound Input ME Interface" end
    local doSleep = sleepFn or (os and os.sleep) or function() end
    local limit = (tonumber(maxWaitSec) ~= nil) and tonumber(maxWaitSec) or 2.0
    local elapsed = 0.0
    local canceled = 0

    while true do
        local ok, cpus = callSafe(inAddr, "getCpus", compLib, state)
        if not ok or type(cpus) ~= "table" then
            return false, canceled, tostring(cpus)
        end
        local waitingNull = false
        local activeMatch = false
        for i = 1, #cpus do
            local c = cpus[i]
            if type(c) == "table" and c.cpu then
                local okB, isBusy = pcall(c.cpu.isBusy)
                if okB and isBusy == true then
                    local okO, out = pcall(c.cpu.finalOutput)
                    if not okO or out == nil then
                        waitingNull = true
                    elseif type(out) == "table" and out.label == fakeName then
                        activeMatch = true
                        if c.cpu.cancel then
                            local okCan, resCan = pcall(c.cpu.cancel)
                            if okCan and resCan ~= false then
                                canceled = canceled + 1
                            end
                        end
                    end
                end
            end
        end
        if not activeMatch and not waitingNull then
            return true, canceled
        end
        if elapsed >= limit then
            return (canceled > 0) or not activeMatch, canceled, "cancel timed out"
        end
        pcall(doSleep, 0.1)
        elapsed = elapsed + 0.1
    end
end

-- Parse Forge of the Gods controller telemetry (`gt_machine`).
function Hardware.readGodforge(ctrlAddr, compLib, state)
    local out = {
        bound = (type(ctrlAddr) == "string" and ctrlAddr ~= ""),
        online = false,
        active = false,
        hasWork = false,
        workAllowed = true,
        rings = nil,
        connected = nil,
        upgrades = nil,
        progress = 0,
        maxProgress = 0,
        rawLines = {},
    }
    if not out.bound then return out end

    local okS, lines = callSafe(ctrlAddr, "getSensorInformation", compLib, state)
    if not okS then
        out.err = tostring(lines)
        return out
    end
    out.online = true

    local function readBool(method, def)
        local ok, v = callSafe(ctrlAddr, method, compLib, state)
        if ok and v ~= nil then return v == true end
        return def
    end
    local function readNum(method, def)
        local ok, v = callSafe(ctrlAddr, method, compLib, state)
        if ok and tonumber(v) ~= nil then return tonumber(v) end
        return def
    end

    out.active = readBool("isMachineActive", false)
    out.hasWork = readBool("hasWork", false)
    out.workAllowed = readBool("isWorkAllowed", true)
    out.progress = readNum("getWorkProgress", 0)
    out.maxProgress = readNum("getWorkMaxProgress", 0)

    if type(lines) == "table" then
        for i = 1, #lines do
            local clean = stripColor(tostring(lines[i] or ""))
            if clean ~= "" and #out.rawLines < 8 then
                out.rawLines[#out.rawLines + 1] = clean
            end
            local rings = clean:match("^tt%.infodata%.fog%.rings\\+([%d,]+)")
                or clean:match("Number of Rings:%s*([%d,]+)")
            if rings then
                out.rings = tonumber((rings:gsub(",", "")))
            end
            local conn = clean:match("^tt%.infodata%.fog%.connected\\+([%d,]+)")
                or clean:match("Connected Modules:%s*([%d,]+)")
            if conn then
                out.connected = tonumber((conn:gsub(",", "")))
            end
            local upg = clean:match("^tt%.infodata%.fog%.upgrades%.unlocked\\+([%d,]+)")
                or clean:match("Upgrades Unlocked:%s*([%d,]+)")
            if upg then
                out.upgrades = tonumber((upg:gsub(",", "")))
            end
        end
    end
    return out
end

function Hardware.setGodforgeWork(ctrlAddr, allow, compLib, state)
    if type(ctrlAddr) ~= "string" or ctrlAddr == "" then
        return false, "No Godforge controller bound"
    end
    local ok, err = callSafe(ctrlAddr, "setWorkAllowed", compLib, state, allow == true)
    return ok, err
end

function Hardware.readLscPct(lscAddr, compLib, state)
    if type(lscAddr) ~= "string" or lscAddr == "" then return nil end
    local okSt, sSt = callSafe(lscAddr, "getStoredEUString", compLib, state)
    local okMx, sMx = callSafe(lscAddr, "getEUCapacityString", compLib, state)
    if okSt and okMx and type(sSt) == "string" and type(sMx) == "string" then
        local cur = tonumber((sSt:gsub(",", "")))
        local mx = tonumber((sMx:gsub(",", "")))
        if cur and mx and mx > 0 then
            return (cur / mx) * 100.0
        end
    end
    local okInfo, lines = callSafe(lscAddr, "getSensorInformation", compLib, state)
    if okInfo and type(lines) == "table" then
        for i = 1, #lines do
            local clean = stripColor(tostring(lines[i] or ""))
            local pct = clean:match("used_capacity\\+([%d%.]+)")
                or clean:match("Used Capacity:%s*([%d%.]+)%%")
                or clean:match("%(([%d%.]+)%%%)")
            if pct and tonumber(pct) then
                return tonumber(pct)
            end
        end
    end
    return nil
end

-- ============================================================================
-- Zero-Tick Cached OC Mesh (`MESH_PORT = 4205`: `GORGE_METRICS` / `GORGE_CMD`)
-- ============================================================================

local function getMeshTransports(compLib, state)
    local cl = compLib or component
    if state and (state._meshModem ~= nil or state._meshTunnel ~= nil) then
        return state._meshModem, state._meshTunnel, state._meshTunnelAddr
    end
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
    if state then
        state._meshModem = modem or false
        state._meshTunnel = tunnel or false
        state._meshTunnelAddr = tAddr
    end
    return modem or nil, tunnel or nil, tAddr
end

function Hardware.openMeshPort(cfg, compLib, state)
    if cfg and cfg.extLinkMode == "off" then return nil, nil end
    return getMeshTransports(compLib, state)
end

local function sendMeshPacket(cl, state, targetAddr, viaTunnel, msgType, ...)
    local modem, tunnel = getMeshTransports(cl, state)
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
    local modem, tunnel = getMeshTransports(cl, state)
    if not modem and not tunnel then return false end

    nowSec = nowSec or 0
    local exStates = (state and state.exStates) or {}
    local kpis = (state and state.kpis) or {}
    local digest = string.format("%s:%d:%d:%d",
        tostring(cfg and cfg.armed == true),
        kpis.activeCount or 0, kpis.completedCycles or 0, kpis.errorCount or 0)
    if not force
        and digest == (state and state._lastMeshDigest)
        and (nowSec - (state and state._lastMeshAt or -100)) < 15 then
        return false
    end
    if state then
        state._lastMeshAt = nowSec
        state._lastMeshDigest = digest
    end

    local exOut = {}
    for i, ex in ipairs((cfg and cfg.exoticizers) or {}) do
        local es = exStates[ex.id or i] or {}
        exOut[i] = {
            id = ex.id or i,
            name = ex.name,
            mode = ex.mode,
            activeMode = es.activeMode or ex.mode,
            phase = es.phase or "IDLE",
            cycles = es.completedCycles or 0,
            lastError = es.lastError,
        }
    end

    local gf = (state and state.godforge) or {}
    local pkt = {
        armed = (cfg and cfg.armed == true),
        activeCount = kpis.activeCount or 0,
        completedCycles = kpis.completedCycles or 0,
        errorCount = kpis.errorCount or 0,
        lscPct = state and state.lscPct or nil,
        godforge = {
            bound = gf.bound == true,
            online = gf.online == true,
            active = gf.active == true,
            workAllowed = gf.workAllowed ~= false,
            rings = gf.rings,
            connected = gf.connected,
            upgrades = gf.upgrades,
        },
        exoticizers = exOut,
    }
    local viaTunnel = (state and state._mainnetMeshViaTunnel == true) or (not modem and tunnel ~= nil)
    sendMeshPacket(cl, state, state and state._mainnetMeshAddr, viaTunnel, "GORGE_METRICS", serialization.serialize(pkt))
    return true
end

function Hardware.handleMeshMessage(cfg, state, localAddr, sender, port, msgType, reqId, payload, compLib)
    if cfg and cfg.extLinkMode == "off" then return false end
    local cl = compLib or component
    local _, tunnel, tAddr = getMeshTransports(cl, state)
    local isMeshPort = (port == Hardware.MESH_PORT) or (port == 0 and tunnel and tAddr and localAddr == tAddr)
    if not isMeshPort or not sender then return false end

    if msgType == "MESH_MAINNET_HELLO" then
        if state then
            state._mainnetMeshAddr = sender
            state._mainnetMeshViaTunnel = (port == 0)
        end
        local up = (computer and computer.uptime and computer.uptime()) or 0
        Hardware.pushMeshMetrics(cfg, state, up, cl, true)
        return true
    elseif msgType == "GORGE_ACK" then
        if state then
            state._mainnetMeshAddr = sender
            state._mainnetMeshViaTunnel = (port == 0)
        end
        return true
    elseif msgType == "GORGE_CMD" then
        if state then
            state._mainnetMeshAddr = sender
            state._mainnetMeshViaTunnel = (port == 0)
        end
        local cmd = (type(payload) == "string") and serialization.unserialize(payload) or nil
        local reply = { ok = false, error = "Unknown GORGE_CMD" }
        if type(cmd) == "table" then
            if cmd.action == "pause" then
                cfg.armed = false
                reply = { ok = true, armed = false }
            elseif cmd.action == "resume" then
                cfg.armed = true
                if state then state._forcePollNow = true end
                reply = { ok = true, armed = true }
            elseif cmd.action == "poll_now" then
                if state then state._forcePollNow = true end
                reply = { ok = true }
            elseif cmd.action == "retry_errors" then
                if state and type(state.exStates) == "table" then
                    for _, es in pairs(state.exStates) do
                        if es.phase == "RETRY_WAIT" then
                            es.phase = "IDLE"
                            es.retryAt = 0
                            es.lastError = nil
                        end
                    end
                    state._forcePollNow = true
                end
                reply = { ok = true }
            elseif cmd.action == "set_mode" then
                local exId = tonumber(cmd.exoticizerId) or 1
                local m = tostring(cmd.mode or "")
                if m == "magmatter" or m == "gluon" or m == "auto" then
                    for _, ex in ipairs((cfg and cfg.exoticizers) or {}) do
                        if ex.id == exId then
                            ex.mode = m
                            if state then state._forcePollNow = true end
                            reply = { ok = true, exoticizerId = exId, mode = m }
                            break
                        end
                    end
                else
                    reply = { ok = false, error = "Invalid mode (magmatter|gluon|auto)" }
                end
            end
        end
        sendMeshPacket(cl, state, sender, (port == 0), "GORGE_REPLY", tostring(reqId or ""), serialization.serialize(reply))
        return true
    end
    return false
end

return Hardware
