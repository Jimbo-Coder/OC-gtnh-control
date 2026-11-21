-- /home/bhc/lib/hardware.lua
-- Hardware & OC Mesh (:4205) layer for Pseudostable Black Hole Containment Field (BHC).
-- Verified against GTNH 2.9.0 MTEBlackHoleCompressor & MTEBlackHoleUtility.

local okComp, defaultComponent = pcall(require, "component")
if not okComp then defaultComponent = nil end
local Common = require("gtnh_common")
local okComputer, computer = pcall(require, "computer")
if not okComputer then computer = nil end
local serialization = require("serialization")

local Hardware = {}

Hardware.MESH_PORT = Common.MESH_PORT
Hardware.WAKE_MSG = Common.WAKE_MSG

Hardware.SIDES = { "down", "up", "north", "south", "west", "east" }
Hardware.SIDE_TO_NUM = {
    down = 0, bottom = 0,
    up = 1, top = 1,
    north = 2, back = 2,
    south = 3, front = 3,
    west = 4, right = 4,
    east = 5, left = 5,
}

-- Exact GTNH 2.9.0 item IDs (gregtech.common.items.IDMetaItem01, offset 32000)
Hardware.CATALYSTS = {
    pseudostable = { id = "pseudostable", label = "Black Hole Seed",            name = "gregtech:gt.metaitem.01", damage = 32418, baseStPerSec = 1,  canDecay = true,  mult = 1 },
    collapser    = { id = "collapser",    label = "Black Hole Collapser",       name = "gregtech:gt.metaitem.01", damage = 32419, baseStPerSec = 0,  canDecay = false, mult = 0 },
    superstable  = { id = "superstable",  label = "Superstable Black Hole Seed", name = "gregtech:gt.metaitem.01", damage = 32420, baseStPerSec = 0,  canDecay = false, mult = 4 },
    supermassive = { id = "supermassive", label = "Supermassive BH Seed",       name = "gregtech:gt.metaitem.01", damage = 32421, baseStPerSec = 64, canDecay = true,  mult = 4 },
}

Hardware.SPACETIME_FLUID = "molten.spacetime"
Hardware.VOLTAGE_V = { 32, 128, 512, 2048, 8192, 32768, 131072, 524288, 2097152, 8388608, 33554432, 134217728, 536870912, 2147483640 }
Hardware.TIER_NAMES = { "LV", "MV", "HV", "EV", "IV", "LuV", "ZPM", "UV", "UHV", "UEV", "UIV", "UMV", "UXV", "MAX" }

local function clockNow()
    if computer and type(computer.uptime) == "function" then
        local ok, v = pcall(computer.uptime)
        if ok and type(v) == "number" then return v end
    end
    return os.clock()
end

local function getProxy(compLib, state, addr)
    if type(addr) ~= "string" or addr == "" then return nil end
    local cl = compLib or defaultComponent or _G.component
    if not cl then return nil end
    if state then
        state._proxies = state._proxies or {}
        if state._proxies[addr] ~= nil then
            return state._proxies[addr] or nil
        end
    end
    local ok, p = pcall(cl.proxy, addr)
    if state then state._proxies[addr] = (ok and p) or false end
    return (ok and p) or nil
end

function Hardware.toSideNum(s)
    if type(s) == "number" then return math.max(0, math.min(5, math.floor(s))) end
    local key = tostring(s or ""):lower():match("^%s*(.-)%s*$")
    return Hardware.SIDE_TO_NUM[key] or 1
end

function Hardware.calcVoltageTier(maxEu)
    local eu = tonumber(maxEu) or 0
    if eu <= 8 then return 1 end
    for i = 1, #Hardware.VOLTAGE_V do
        if eu <= Hardware.VOLTAGE_V[i] then return i end
    end
    return 14
end

local function stripFmt(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("\194\167.", ""):gsub("\167.", ""):gsub("[\1-\31]", ""))
end

local function parseSensorNumber(raw)
    if type(raw) ~= "string" then return nil end
    local clean = raw:gsub(",", ""):match("^%s*(.-)%s*$")
    local n = clean:match("^([%+%-]?%d+%.?%d*)")
    return tonumber(n)
end

local function isBhcMachineName(name)
    local low = tostring(name or ""):lower()
    return low:find("blackhole", 1, true) ~= nil
        or low:find("black_hole", 1, true) ~= nil
        or low:find("black hole", 1, true) ~= nil
end

function Hardware.discover(compLib, state)
    local cl = compLib or defaultComponent or _G.component
    local disc = {
        controllers = {},
        redstones = {},
        transposers = {},
        aeInterfaces = {},
    }
    if not cl or type(cl.list) ~= "function" then return disc end

    for addr in cl.list("gt_machine", true) do
        local p = getProxy(cl, state, addr)
        local mName = (p and p.getName and select(2, pcall(p.getName))) or "gt_machine"
        local entry = {
            addr = addr,
            name = tostring(mName),
            isBhc = isBhcMachineName(mName),
        }
        disc.controllers[#disc.controllers + 1] = entry
    end
    table.sort(disc.controllers, function(a, b)
        if a.isBhc ~= b.isBhc then return a.isBhc end
        return a.addr < b.addr
    end)

    for addr in cl.list("redstone", true) do
        disc.redstones[#disc.redstones + 1] = { addr = addr }
    end
    table.sort(disc.redstones, function(a, b) return a.addr < b.addr end)

    for addr in cl.list("transposer", true) do
        disc.transposers[#disc.transposers + 1] = { addr = addr }
    end
    table.sort(disc.transposers, function(a, b) return a.addr < b.addr end)

    for _, tp in ipairs({ "me_interface", "me_controller" }) do
        for addr in cl.list(tp, true) do
            disc.aeInterfaces[#disc.aeInterfaces + 1] = { addr = addr, ctype = tp }
        end
    end
    table.sort(disc.aeInterfaces, function(a, b) return a.addr < b.addr end)
    return disc
end

function Hardware.autoBind(cfg, disc)
    if not cfg or not disc then return false end
    local changed = false
    if (not cfg.controllerAddr or cfg.controllerAddr == "") and disc.controllers[1] then
        cfg.controllerAddr = disc.controllers[1].addr
        changed = true
    end
    if (not cfg.utilityRedstoneAddr or cfg.utilityRedstoneAddr == "") and disc.redstones[1] then
        cfg.utilityRedstoneAddr = disc.redstones[1].addr
        changed = true
    end
    if (not cfg.spacetimeRedstoneAddr or cfg.spacetimeRedstoneAddr == "") and disc.redstones[1] then
        cfg.spacetimeRedstoneAddr = disc.redstones[1].addr
        changed = true
    end
    if (not cfg.inputGateRedstoneAddr or cfg.inputGateRedstoneAddr == "") and disc.redstones[1] then
        cfg.inputGateRedstoneAddr = disc.redstones[1].addr
        changed = true
    end
    if (not cfg.catalystTransposerAddr or cfg.catalystTransposerAddr == "") and disc.transposers[1] then
        cfg.catalystTransposerAddr = disc.transposers[1].addr
        changed = true
    end
    if (not cfg.stTransposerAddr or cfg.stTransposerAddr == "") and (disc.transposers[2] or disc.transposers[1]) then
        cfg.stTransposerAddr = (disc.transposers[2] or disc.transposers[1]).addr
        changed = true
    end
    if (not cfg.aeAddr or cfg.aeAddr == "") and disc.aeInterfaces[1] then
        cfg.aeAddr = disc.aeInterfaces[1].addr
        changed = true
    end
    return changed
end

function Hardware.readMachine(cfg, compLib, state)
    local out = {
        online = false,
        active = false,
        workAllowed = false,
        progress = 0,
        maxProgress = 0,
        remainingSec = 0,
        maxInputEu = 0,
        voltageTier = 8,
        tierName = "UV",
        baseParallels = 64,
        problems = 0,
        euStored = 0,
        euMax = 0,
    }
    local p = getProxy(compLib, state, cfg and cfg.controllerAddr)
    if not p then return out end
    out.online = true
    if p.isMachineActive then
        local ok, v = pcall(p.isMachineActive)
        if ok then out.active = (v == true) end
    end
    if p.isWorkAllowed then
        local ok, v = pcall(p.isWorkAllowed)
        if ok then out.workAllowed = (v == true) end
    end
    if p.getWorkProgress then
        local ok, v = pcall(p.getWorkProgress)
        if ok then out.progress = math.max(0, tonumber(v) or 0) end
    end
    if p.getWorkMaxProgress then
        local ok, v = pcall(p.getWorkMaxProgress)
        if ok then out.maxProgress = math.max(0, tonumber(v) or 0) end
    end
    if out.maxProgress > out.progress then
        out.remainingSec = (out.maxProgress - out.progress) / 20.0
    end
    if p.getEUStored then
        local ok, v = pcall(p.getEUStored)
        if ok then out.euStored = tonumber(v) or 0 end
    end
    if p.getEUMaxStored then
        local ok, v = pcall(p.getEUMaxStored)
        if ok then out.euMax = tonumber(v) or 0 end
    end
    local maxIn = 0
    if p.getMaxInputVoltage then
        local ok, v = pcall(p.getMaxInputVoltage)
        if ok and tonumber(v) then maxIn = math.max(maxIn, tonumber(v)) end
    end
    if p.getAverageElectricInput then
        local ok, v = pcall(p.getAverageElectricInput)
        if ok and tonumber(v) then maxIn = math.max(maxIn, tonumber(v)) end
    end
    if p.getSensorInformation then
        local ok, lines = pcall(p.getSensorInformation)
        if ok and type(lines) == "table" then
            for _, ln in pairs(lines) do
                if type(ln) == "string" then
                    local clean = stripFmt(ln)
                    local low = clean:lower()
                    if low:find("problem", 1, true) then
                        local n = parseSensorNumber(clean:match(":%s*(.+)$") or clean)
                        if n then out.problems = math.max(0, math.floor(n)) end
                    elseif low:find("max input", 1, true) or low:find("eu/t", 1, true) then
                        local n = parseSensorNumber(clean:match(":%s*(.+)$") or "")
                        if n and n > maxIn then maxIn = n end
                    end
                end
            end
        end
    end
    if tonumber(cfg and cfg.manualMaxEuOverride) and tonumber(cfg.manualMaxEuOverride) > 0 then
        maxIn = tonumber(cfg.manualMaxEuOverride)
    end
    out.maxInputEu = maxIn
    out.voltageTier = Hardware.calcVoltageTier(maxIn > 0 and maxIn or Hardware.VOLTAGE_V[8])
    out.tierName = Hardware.TIER_NAMES[out.voltageTier] or "UV"
    out.baseParallels = 8 * out.voltageTier
    return out
end

function Hardware.readUtilitySignal(cfg, compLib, state)
    local rs = getProxy(compLib, state, cfg and cfg.utilityRedstoneAddr)
    if not rs or type(rs.getInput) ~= "function" then return nil end
    local ok, val = pcall(rs.getInput, Hardware.toSideNum(cfg.utilitySide))
    if not ok then return nil end
    if type(val) == "table" then val = val[Hardware.toSideNum(cfg.utilitySide)] end
    return tonumber(val) or 0
end

function Hardware.setSpacetimeValve(cfg, enabled, compLib, state)
    local rs = getProxy(compLib, state, cfg and cfg.spacetimeRedstoneAddr)
    if not rs or type(rs.setOutput) ~= "function" then return false end
    local lvl = enabled and 15 or 0
    if cfg and cfg.spacetimeRedstoneInvert then lvl = enabled and 0 or 15 end
    local ok = pcall(rs.setOutput, Hardware.toSideNum(cfg.spacetimeRedstoneSide), lvl)
    return ok == true
end

function Hardware.transferSpacetime(cfg, liters, compLib, state)
    local amt = math.floor(tonumber(liters) or 0)
    if amt <= 0 then return 0, "Zero requested" end
    local tp = getProxy(compLib, state, cfg and cfg.stTransposerAddr)
    if not tp or type(tp.transferFluid) ~= "function" then
        return 0, "No SpaceTime Transposer configured"
    end
    local srcSide = Hardware.toSideNum(cfg.stSrcSide)
    local dstSide = Hardware.toSideNum(cfg.stDstSide)
    local avail = 0
    if tp.getFluidInTank then
        local okT, tanks = pcall(tp.getFluidInTank, srcSide)
        if okT and type(tanks) == "table" then
            for _, t in pairs(tanks) do
                if type(t) == "table" and tostring(t.name or ""):lower() == Hardware.SPACETIME_FLUID then
                    avail = avail + (tonumber(t.amount) or 0)
                end
            end
        end
    end
    if avail < amt then return 0, "Insufficient molten.spacetime in tank" end
    local okTx, okBool, moved = pcall(tp.transferFluid, srcSide, dstSide, amt)
    if okTx and okBool then
        return tonumber(moved) or amt, nil
    end
    return 0, "Fluid transfer failed"
end

function Hardware.setInputGate(cfg, allowInputs, compLib, state)
    local did = false
    local rs = getProxy(compLib, state, cfg and cfg.inputGateRedstoneAddr)
    if rs and type(rs.setOutput) == "function" then
        local lvl = allowInputs and 15 or 0
        if cfg and cfg.inputGateInvert then lvl = allowInputs and 0 or 15 end
        local ok = pcall(rs.setOutput, Hardware.toSideNum(cfg.inputGateSide), lvl)
        did = ok == true
    end
    return did
end

function Hardware.setWorkAllowed(cfg, allow, compLib, state)
    local p = getProxy(compLib, state, cfg and cfg.controllerAddr)
    if not p or type(p.setWorkAllowed) ~= "function" then return false end
    local ok = pcall(p.setWorkAllowed, allow == true)
    return ok == true
end

local function matchStackSpec(st, spec)
    if type(st) ~= "table" or not spec then return false end
    local n = tostring(st.name or "")
    local d = math.floor(tonumber(st.damage) or 0)
    return n == spec.name and d == spec.damage
end

local function iterStacks(tp, sideNum)
    if not tp then return {} end
    local slots = {}
    if tp.getAllStacks then
        local okA, it = pcall(tp.getAllStacks, sideNum)
        if okA and type(it) == "table" then
            if type(it.getAll) == "function" then
                local okG, all = pcall(it.getAll)
                if okG and type(all) == "table" then slots = all end
            else
                slots = it
            end
        end
    elseif tp.getInventorySize and tp.getStackInSlot then
        local okS, sz = pcall(tp.getInventorySize, sideNum)
        if okS and tonumber(sz) then
            for s = 1, math.floor(tonumber(sz)) do
                local okI, st = pcall(tp.getStackInSlot, sideNum, s)
                if okI and type(st) == "table" then slots[s - 1] = st end
            end
        end
    end
    return slots
end

function Hardware.injectCatalyst(cfg, kind, compLib, state)
    local spec = Hardware.CATALYSTS[kind]
    if not spec then return false, "Unknown catalyst kind: " .. tostring(kind) end
    local tp = getProxy(compLib, state, cfg and cfg.catalystTransposerAddr)
    if not tp or type(tp.transferItem) ~= "function" then
        return false, "No Catalyst Transposer configured"
    end
    local srcSide = Hardware.toSideNum(cfg.catalystSrcSide)
    local dstSide = Hardware.toSideNum(cfg.catalystDstSide)
    local slots = iterStacks(tp, srcSide)
    for idx, st in pairs(slots) do
        if type(idx) == "number" and matchStackSpec(st, spec) and (tonumber(st.size) or 0) >= 1 then
            local slotNum = (slots[0] ~= nil) and (idx + 1) or idx
            local okT, moved = pcall(tp.transferItem, srcSide, dstSide, 1, slotNum)
            if okT and (moved == true or (tonumber(moved) or 0) >= 1) then
                return true, nil
            end
        end
    end
    return false, "Missing " .. spec.label .. " in buffer"
end

function Hardware.scanStock(cfg, compLib, state)
    local stock = {
        pseudostable = 0,
        supermassive = 0,
        superstable = 0,
        collapser = 0,
        spacetimeTankL = 0,
        spacetimeMeL = 0,
        workWaiting = false,
    }
    local tpCat = getProxy(compLib, state, cfg and cfg.catalystTransposerAddr)
    if tpCat then
        local slots = iterStacks(tpCat, Hardware.toSideNum(cfg.catalystSrcSide))
        for _, st in pairs(slots) do
            if type(st) == "table" and (tonumber(st.size) or 0) > 0 then
                for k, spec in pairs(Hardware.CATALYSTS) do
                    if matchStackSpec(st, spec) then
                        stock[k] = stock[k] + math.floor(tonumber(st.size) or 0)
                    end
                end
            end
        end
    end

    local tpSt = getProxy(compLib, state, cfg and cfg.stTransposerAddr)
    if tpSt and tpSt.getFluidInTank then
        local okT, tanks = pcall(tpSt.getFluidInTank, Hardware.toSideNum(cfg.stSrcSide))
        if okT and type(tanks) == "table" then
            for _, t in pairs(tanks) do
                if type(t) == "table" and tostring(t.name or ""):lower() == Hardware.SPACETIME_FLUID then
                    stock.spacetimeTankL = stock.spacetimeTankL + math.floor(tonumber(t.amount) or 0)
                end
            end
        end
    end

    local tpWork = getProxy(compLib, state, cfg and cfg.workSensorTransposerAddr)
    if tpWork then
        local wSide = Hardware.toSideNum(cfg.workSensorSide)
        local slots = iterStacks(tpWork, wSide)
        for _, st in pairs(slots) do
            if type(st) == "table" and (tonumber(st.size) or 0) > 0 then
                stock.workWaiting = true
                break
            end
        end
        if (not stock.workWaiting) and tpWork.getFluidInTank then
            local okF, fls = pcall(tpWork.getFluidInTank, wSide)
            if okF and type(fls) == "table" then
                for _, t in pairs(fls) do
                    if type(t) == "table" and (tonumber(t.amount) or 0) > 0 then
                        stock.workWaiting = true
                        break
                    end
                end
            end
        end
    end

    local ae = getProxy(compLib, state, cfg and cfg.aeAddr)
    if ae then
        if ae.getItemsInNetwork then
            for k, spec in pairs(Hardware.CATALYSTS) do
                local okI, res = pcall(ae.getItemsInNetwork, { name = spec.name, damage = spec.damage })
                if okI and type(res) == "table" and res[1] and tonumber(res[1].size) then
                    stock[k] = math.max(stock[k], math.floor(tonumber(res[1].size) or 0))
                end
            end
        end
        if ae.getFluidsInNetwork then
            local okF, res = pcall(ae.getFluidsInNetwork, { name = Hardware.SPACETIME_FLUID })
            if okF and type(res) == "table" then
                for _, f in pairs(res) do
                    if type(f) == "table" and tostring(f.name or ""):lower() == Hardware.SPACETIME_FLUID then
                        stock.spacetimeMeL = stock.spacetimeMeL + math.floor(tonumber(f.amount) or 0)
                    end
                end
            end
        end
    end
    return stock
end

-- ============================================================================
-- OC Mesh (:4205) Client (`BHC_METRICS` / `BHC_ACK` / `BHC_CMD` / `BHC_REPLY`)
-- ============================================================================

local function getMeshTransports(compLib, state, cfg)
    local cl = compLib or defaultComponent or _G.component
    if not cl then return nil, nil, nil end
    local aw = Hardware._autoWakeEnabled
    if state and state._autoWakeEnabled ~= nil then aw = state._autoWakeEnabled end
    if cfg ~= nil then
        aw = (cfg.autoWake ~= false)
        Hardware._autoWakeEnabled = aw
        if state then state._autoWakeEnabled = aw end
    end
    local wakeArg = Hardware.WAKE_MSG
    if aw == false then wakeArg = false end
    local modem, tunnel, _, tAddr = Common.getMeshTransports(cl, {
        port = Hardware.MESH_PORT,
        wakeMsg = wakeArg,
        strength = 400,
        proxyFn = function(c, addr)
            return getProxy(c, state, addr)
        end,
    })
    return modem, tunnel, tAddr
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

function Hardware.openMeshPort(cfg, compLib, state)
    if cfg and cfg.extLinkMode == "off" then return false end
    local modem, tunnel = getMeshTransports(compLib or defaultComponent or _G.component, state, cfg)
    return (modem ~= nil) or (tunnel ~= nil)
end

function Hardware.pushMeshMetrics(cfg, state, nowSec, compLib, force)
    if cfg and cfg.extLinkMode == "off" then return false end
    local cl = compLib or defaultComponent or _G.component
    local modem, tunnel = getMeshTransports(cl, state, cfg)
    if not modem and not tunnel then return false end

    nowSec = nowSec or clockNow()
    local st = state or {}
    local m = st.machine or {}
    local stk = st.stock or {}
    local pkt = {
        armed = (cfg and cfg.armed == true),
        autoWake = (not cfg or cfg.autoWake ~= false),
        phase = st.phase or "CLOSED",
        seedMode = (cfg and cfg.seedMode) or "pseudostable",
        preset = (cfg and cfg.preset) or "balanced",
        saveRecipeMode = (not cfg or cfg.saveRecipeMode ~= false),
        savingRecipe = (st.savingRecipe == true),
        stability = math.floor((tonumber(st.estStability) or 100) * 10 + 0.5) / 10,
        heldSec = math.floor(tonumber(st.heldSec) or 0),
        costMod = math.floor(tonumber(st.costMod) or 0),
        stHalting = (st.haltingDecay == true),
        voltageTier = tonumber(m.voltageTier) or 8,
        tierName = m.tierName or "UV",
        parallels = tonumber(st.effectiveParallels) or 0,
        active = (m.active == true),
        keepOpen = (cfg and cfg.keepOpen == true),
        cyclesCompleted = math.floor(tonumber(st.cyclesCompleted) or 0),
        spacetimeStockL = math.floor(math.max(tonumber(stk.spacetimeTankL) or 0, tonumber(stk.spacetimeMeL) or 0)),
        collapsers = math.floor(tonumber(stk.collapser) or 0),
        seeds = math.floor(tonumber(stk[cfg and cfg.seedMode or "pseudostable"]) or 0),
    }
    local digest = string.format("%s:%s:%s:%s:%.0f:%d:%d:%s",
        tostring(pkt.armed), tostring(pkt.phase), tostring(pkt.stHalting), tostring(pkt.savingRecipe),
        pkt.stability, pkt.costMod, pkt.parallels, tostring(pkt.active))
    if not force and digest == st._lastMeshDigest and (nowSec - (st._lastMeshAt or -100)) < 15 then
        return false
    end
    st._lastMeshAt = nowSec
    st._lastMeshDigest = digest

    local viaTunnel = (st._mainnetMeshViaTunnel == true) or (not modem and tunnel ~= nil)
    sendMeshPacket(cl, st, st._mainnetMeshAddr, viaTunnel, "BHC_METRICS", serialization.serialize(pkt))

    st._meshStartedAt = st._meshStartedAt or nowSec
    local peerSilent = (st._lastMainnetSeen and (nowSec - st._lastMainnetSeen) >= 60)
        or ((not st._lastMainnetSeen) and (nowSec - st._meshStartedAt) >= 60)
    if (not cfg or cfg.autoWake ~= false) and peerSilent and (nowSec - (st._lastMainnetWakeAt or -1000)) >= 60 then
        st._lastMainnetWakeAt = nowSec
        st._mainnetWakeAttempts = (st._mainnetWakeAttempts or 0) + 1
        local wakeTarget = (st._mainnetMeshAddr and st._mainnetWakeAttempts <= 2) and st._mainnetMeshAddr or nil
        sendMeshPacket(cl, st, wakeTarget, viaTunnel, Hardware.WAKE_MSG)
    end
    return true
end

function Hardware.handleMeshMessage(cfg, state, localAddr, sender, port, msgType, reqId, payload, compLib, rpcHandler)
    if cfg and cfg.extLinkMode == "off" then return false end
    local cl = compLib or defaultComponent or _G.component
    local _, tunnel, tAddr = getMeshTransports(cl, state, cfg)
    local isMeshPort = (port == Hardware.MESH_PORT) or (port == 0 and tunnel and tAddr and localAddr == tAddr)
    if not isMeshPort or not sender then return false end

    if msgType == "MESH_MAINNET_HELLO" or msgType == Hardware.WAKE_MSG then
        if state then
            state._mainnetMeshAddr = sender
            state._mainnetMeshViaTunnel = (port == 0)
            state._lastMainnetSeen = clockNow()
            state._mainnetWakeAttempts = 0
        end
        Hardware.pushMeshMetrics(cfg, state, clockNow(), cl, true)
        return true
    elseif msgType == "BHC_ACK" then
        if state then
            state._mainnetMeshAddr = sender
            state._mainnetMeshViaTunnel = (port == 0)
            state._lastMainnetSeen = clockNow()
            state._mainnetWakeAttempts = 0
        end
        return true
    elseif msgType == "BHC_CMD" then
        if state then
            state._mainnetMeshAddr = sender
            state._mainnetMeshViaTunnel = (port == 0)
            state._lastMainnetSeen = clockNow()
            state._mainnetWakeAttempts = 0
        end
        local rawStr = (type(reqId) == "string" and reqId:sub(1, 1) == "{" and (payload == nil or payload == "")) and reqId or payload
        local okU, cmd = pcall(serialization.unserialize, tostring(rawStr or ""))
        local resTbl
        if okU and type(cmd) == "table" and type(rpcHandler) == "function" then
            resTbl = rpcHandler(cmd)
        else
            resTbl = { ok = false, error = "Invalid BHC_CMD payload" }
        end
        local raw = serialization.serialize(resTbl)
        local CHUNK = 5500
        local total = math.max(1, math.ceil(#raw / CHUNK))
        local viaTunnel = (port == 0)
        for idx = 1, total do
            local slice = raw:sub((idx - 1) * CHUNK + 1, idx * CHUNK)
            sendMeshPacket(cl, state, sender, viaTunnel, "BHC_REPLY", tostring(reqId or ""), idx, total, slice)
        end
        return true
    end
    return false
end

return Hardware
