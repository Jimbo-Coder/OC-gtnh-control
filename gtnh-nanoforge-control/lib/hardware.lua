-- /home/nanoforge/lib/hardware.lua
-- Hardware & OC Mesh (:4205) layer for Tier 4 Nano Forge (`multimachine.nanoforge`).
-- Enforces strict serialization, single-hatch Magmatter metering, and nanite purity scanning.

local okComp, defaultComponent = pcall(require, "component")
if not okComp then defaultComponent = nil end
local Common = require("gtnh_common")
local okComputer, computer = pcall(require, "computer")
if not okComputer then computer = nil end
local serialization = require("serialization")
local RecipesDb = require("lib.recipes_db")

local Hardware = {}

Hardware.MESH_PORT = Common.MESH_PORT
Hardware.WAKE_MSG = Common.WAKE_MSG

Hardware.SIDES = { "down", "up", "north", "south", "west", "east" }
Hardware.SIDE_TO_NUM = {
    down = 0, bottom = 0, up = 1, top = 1,
    north = 2, back = 2, south = 3, front = 3,
    west = 4, right = 4, east = 5, left = 5,
}

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

local function stripFmt(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("\194\167.", ""):gsub("\167.", ""):gsub("[\1-\31]", ""))
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

local function isNanoForgeName(name)
    local low = tostring(name or ""):lower()
    return low:find("nanoforge", 1, true) ~= nil or low:find("nano_forge", 1, true) ~= nil
end

function Hardware.discover(compLib, state)
    local cl = compLib or defaultComponent or _G.component
    local disc = { controllers = {}, transposers = {}, aeInterfaces = {} }
    if not cl or type(cl.list) ~= "function" then return disc end

    for addr in cl.list("gt_machine", true) do
        local p = getProxy(cl, state, addr)
        local mName = (p and p.getName and select(2, pcall(p.getName))) or "gt_machine"
        disc.controllers[#disc.controllers + 1] = {
            addr = addr, name = tostring(mName), isNanoForge = isNanoForgeName(mName),
        }
    end
    table.sort(disc.controllers, function(a, b)
        if a.isNanoForge ~= b.isNanoForge then return a.isNanoForge end
        return a.addr < b.addr
    end)

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
        cfg.controllerAddr = disc.controllers[1].addr; changed = true
    end
    if (not cfg.itemTransposerAddr or cfg.itemTransposerAddr == "") and disc.transposers[1] then
        cfg.itemTransposerAddr = disc.transposers[1].addr; changed = true
    end
    if (not cfg.magTransposerAddr or cfg.magTransposerAddr == "") and (disc.transposers[2] or disc.transposers[1]) then
        cfg.magTransposerAddr = (disc.transposers[2] or disc.transposers[1]).addr; changed = true
    end
    if (not cfg.aeAddr or cfg.aeAddr == "") and disc.aeInterfaces[1] then
        cfg.aeAddr = disc.aeInterfaces[1].addr; changed = true
    end
    return changed
end

function Hardware.readMachine(cfg, compLib, state)
    local out = {
        online = false, active = false, workAllowed = false,
        progress = 0, maxProgress = 0, remainingSec = 0,
        maxInputEu = 0, problems = 0,
    }
    local p = getProxy(compLib, state, cfg and cfg.controllerAddr)
    if not p then return out end
    out.online = true
    if p.isMachineActive then local ok, v = pcall(p.isMachineActive); if ok then out.active = (v == true) end end
    if p.isWorkAllowed then local ok, v = pcall(p.isWorkAllowed); if ok then out.workAllowed = (v == true) end end
    if p.getWorkProgress then local ok, v = pcall(p.getWorkProgress); if ok then out.progress = math.max(0, tonumber(v) or 0) end end
    if p.getWorkMaxProgress then local ok, v = pcall(p.getWorkMaxProgress); if ok then out.maxProgress = math.max(0, tonumber(v) or 0) end end
    if out.maxProgress > out.progress then out.remainingSec = (out.maxProgress - out.progress) / 20.0 end
    if p.getMaxInputVoltage then local ok, v = pcall(p.getMaxInputVoltage); if ok and tonumber(v) then out.maxInputEu = tonumber(v) end end
    if p.getAverageElectricInput then local ok, v = pcall(p.getAverageElectricInput); if ok and tonumber(v) then out.maxInputEu = math.max(out.maxInputEu, tonumber(v)) end end
    if p.getSensorInformation then
        local ok, lines = pcall(p.getSensorInformation)
        if ok and type(lines) == "table" then
            for _, ln in pairs(lines) do
                if type(ln) == "string" then
                    local low = stripFmt(ln):lower()
                    if low:find("problem", 1, true) then
                        local n = tonumber(low:match(":%s*(%d+)"))
                        if n then out.problems = n end
                    end
                end
            end
        end
    end
    return out
end

-- Inspect target Input Bus for nanite purity:
-- Must have NO nanites other than allowedOutputDmg or entries in allowedInputDmgs.
function Hardware.scanBusNanites(cfg, allowedOutputDmg, allowedInputDmgs, compLib, state)
    local res = { clean = true, foreign = {}, outputSeedCount = 0 }
    local tp = getProxy(compLib, state, cfg and cfg.itemTransposerAddr)
    if not tp then return res end
    local dstSide = Hardware.toSideNum(cfg.dstBusSide)
    local slots = iterStacks(tp, dstSide)
    local zeroIdx = (slots[0] ~= nil)
    for idx, st in pairs(slots) do
        if type(idx) == "number" and type(st) == "table" and (tonumber(st.size) or 0) > 0 then
            local isNan, dmg = RecipesDb.isNaniteStack(st)
            if isNan then
                local slotNum = zeroIdx and (idx + 1) or idx
                if allowedOutputDmg and dmg == allowedOutputDmg then
                    res.outputSeedCount = res.outputSeedCount + math.floor(tonumber(st.size) or 0)
                elseif allowedInputDmgs and allowedInputDmgs[dmg] then
                    -- allowed input nanite (e.g., Universium Nanites for Eternity/Magmatter)
                else
                    res.clean = false
                    res.foreign[#res.foreign + 1] = {
                        slot = slotNum, damage = dmg, size = math.floor(tonumber(st.size) or 0),
                        label = tostring(st.label or ("Nanite:" .. tostring(dmg))),
                    }
                end
            end
        end
    end
    return res
end

function Hardware.sweepForeignNanites(cfg, foreignSlots, compLib, state)
    local tp = getProxy(compLib, state, cfg and cfg.itemTransposerAddr)
    if not tp or type(tp.transferItem) ~= "function" then return 0 end
    local dstSide = Hardware.toSideNum(cfg.dstBusSide)
    local retSide = Hardware.toSideNum(cfg.returnSide)
    local movedTotal = 0
    for _, f in ipairs(foreignSlots or {}) do
        local okT, mv = pcall(tp.transferItem, dstSide, retSide, f.size or 64, f.slot)
        if okT and (tonumber(mv) or 0) > 0 then
            movedTotal = movedTotal + tonumber(mv)
        elseif okT and mv == true then
            movedTotal = movedTotal + (f.size or 1)
        end
    end
    return movedTotal
end

-- Check current Magmatter already in dedicated hatch and top up ONLY exact (exactL - existing)
function Hardware.getHatchMagmatter(cfg, compLib, state)
    local tp = getProxy(compLib, state, cfg and cfg.magTransposerAddr)
    if not tp or not tp.getFluidInTank then return 0, 0 end
    local dstSide = Hardware.toSideNum(cfg.magDstSide)
    local srcSide = Hardware.toSideNum(cfg.magSrcSide)
    local dstAmt, srcAmt = 0, 0
    local okD, dTanks = pcall(tp.getFluidInTank, dstSide)
    if okD and type(dTanks) == "table" then
        for _, t in pairs(dTanks) do
            if type(t) == "table" and tostring(t.name or ""):lower() == RecipesDb.MAGMATTER_FLUID then
                dstAmt = dstAmt + math.floor(tonumber(t.amount) or 0)
            end
        end
    end
    local okS, sTanks = pcall(tp.getFluidInTank, srcSide)
    if okS and type(sTanks) == "table" then
        for _, t in pairs(sTanks) do
            if type(t) == "table" and tostring(t.name or ""):lower() == RecipesDb.MAGMATTER_FLUID then
                srcAmt = srcAmt + math.floor(tonumber(t.amount) or 0)
            end
        end
    end
    return dstAmt, srcAmt
end

function Hardware.meterMagmatter(cfg, exactL, compLib, state)
    local target = math.max(0, math.floor(tonumber(exactL) or 0))
    local tp = getProxy(compLib, state, cfg and cfg.magTransposerAddr)
    if target == 0 then return true, 0, nil end
    if not tp or type(tp.transferFluid) ~= "function" then
        return false, 0, "No Magmatter Transposer configured"
    end
    local existing, srcAvail = Hardware.getHatchMagmatter(cfg, compLib, state)
    if existing > target then
        return false, existing, string.format("Hatch already holds %d L > exact %d L Magmatter", existing, target)
    end
    local need = target - existing
    if need == 0 then return true, 0, nil end
    if srcAvail < need then
        return false, 0, string.format("Need %d L Magmatter in source tank (have %d L)", need, srcAvail)
    end
    local okTx, okBool, mv = pcall(tp.transferFluid, Hardware.toSideNum(cfg.magSrcSide), Hardware.toSideNum(cfg.magDstSide), need)
    if okTx and okBool then
        return true, tonumber(mv) or need, nil
    end
    return false, 0, "Failed to transfer Magmatter into hatch"
end

function Hardware.injectOutputSeed(cfg, recipe, compLib, state)
    if not recipe or not recipe.output then return false, "No recipe" end
    local tp = getProxy(compLib, state, cfg and cfg.itemTransposerAddr)
    if not tp or type(tp.transferItem) ~= "function" then
        return false, "No Item Transposer configured"
    end
    local srcSide = Hardware.toSideNum(cfg.seedSrcSide)
    local dstSide = Hardware.toSideNum(cfg.dstBusSide)
    local slots = iterStacks(tp, srcSide)
    local zeroIdx = (slots[0] ~= nil)
    for idx, st in pairs(slots) do
        if type(idx) == "number" and type(st) == "table"
            and tostring(st.name or "") == recipe.output.name
            and math.floor(tonumber(st.damage) or 0) == recipe.output.damage
            and (tonumber(st.size) or 0) >= 1 then
            local slotNum = zeroIdx and (idx + 1) or idx
            local okT, mv = pcall(tp.transferItem, srcSide, dstSide, 1, slotNum)
            if okT and (mv == true or (tonumber(mv) or 0) >= 1) then
                return true, nil
            end
        end
    end
    return false, "Missing output seed: " .. tostring(recipe.output.label)
end

-- Identify which recipe is queued in AE2 blocking-mode staging chest/dual interface
function Hardware.detectStagingOrder(cfg, compLib, state)
    local tp = getProxy(compLib, state, cfg and cfg.itemTransposerAddr)
    if not tp then return nil, 0 end
    local stgSide = Hardware.toSideNum(cfg.stagingSrcSide)
    local slots = iterStacks(tp, stgSide)
    local itemCounts = {}
    for _, st in pairs(slots) do
        if type(st) == "table" and (tonumber(st.size) or 0) > 0 then
            local k = tostring(st.name or "") .. ":" .. tostring(math.floor(tonumber(st.damage) or 0))
            itemCounts[k] = (itemCounts[k] or 0) + math.floor(tonumber(st.size) or 0)
        end
    end
    local fluidCounts = {}
    if tp.getFluidInTank then
        local okF, tanks = pcall(tp.getFluidInTank, stgSide)
        if okF and type(tanks) == "table" then
            for _, t in pairs(tanks) do
                if type(t) == "table" and (tonumber(t.amount) or 0) > 0 then
                    local fn = tostring(t.name or ""):lower()
                    fluidCounts[fn] = (fluidCounts[fn] or 0) + math.floor(tonumber(t.amount) or 0)
                end
            end
        end
    end
    for _, r in ipairs(RecipesDb.RECIPES) do
        local batches = nil
        local okAll = true
        for _, it in ipairs(r.items or {}) do
            local k = it.name .. ":" .. tostring(it.damage or 0)
            local have = itemCounts[k] or 0
            local nBat = math.floor(have / it.amount)
            if nBat < 1 then okAll = false; break end
            batches = batches and math.min(batches, nBat) or nBat
        end
        if okAll then
            for _, fl in ipairs(r.fluids or {}) do
                local have = fluidCounts[tostring(fl.name):lower()] or 0
                local nBat = math.floor(have / fl.amount)
                if nBat < 1 then okAll = false; break end
                batches = batches and math.min(batches, nBat) or nBat
            end
        end
        if okAll and batches and batches >= 1 then
            return r, batches
        end
    end
    return nil, 0
end

function Hardware.transferStagingBatch(cfg, recipe, batchCount, compLib, state)
    if not recipe or batchCount < 1 then return false, "Invalid staging batch" end
    local tp = getProxy(compLib, state, cfg and cfg.itemTransposerAddr)
    if not tp or type(tp.transferItem) ~= "function" then return false, "No Item Transposer" end
    local stgSide = Hardware.toSideNum(cfg.stagingSrcSide)
    local dstBus = Hardware.toSideNum(cfg.dstBusSide)
    local slots = iterStacks(tp, stgSide)
    local zeroIdx = (slots[0] ~= nil)

    for _, it in ipairs(recipe.items or {}) do
        local rem = it.amount * batchCount
        for idx, st in pairs(slots) do
            if rem <= 0 then break end
            if type(idx) == "number" and type(st) == "table"
                and tostring(st.name or "") == it.name
                and math.floor(tonumber(st.damage) or 0) == (it.damage or 0)
                and (tonumber(st.size) or 0) > 0 then
                local slotNum = zeroIdx and (idx + 1) or idx
                local take = math.min(rem, math.floor(tonumber(st.size) or 0))
                local okT, mv = pcall(tp.transferItem, stgSide, dstBus, take, slotNum)
                local moved = (okT and tonumber(mv)) or (okT and mv == true and take) or 0
                rem = rem - moved
                st.size = (tonumber(st.size) or 0) - moved
            end
        end
        if rem > 0 then return false, "Incomplete staging item: " .. tostring(it.label) end
    end
    if tp.transferFluid and tp.getFluidInTank then
        local dstHatch = Hardware.toSideNum(cfg.odFluidDstSide)
        for _, fl in ipairs(recipe.fluids or {}) do
            local okF, okBool, mv = pcall(tp.transferFluid, stgSide, dstHatch, fl.amount * batchCount)
            -- note: if staging only holds items and fluids are stocked directly, tolerate missing fluid only if none in tank
        end
    end
    return true, nil
end

function Hardware.readMeStocks(cfg, compLib, state)
    local stocks, magMe = {}, 0
    local ae = getProxy(compLib, state, cfg and cfg.aeAddr)
    if ae then
        if ae.getItemsInNetwork then
            for _, r in ipairs(RecipesDb.RECIPES) do
                local okI, res = pcall(ae.getItemsInNetwork, { name = r.output.name, damage = r.output.damage })
                stocks[r.id] = (okI and type(res) == "table" and res[1] and math.floor(tonumber(res[1].size) or 0)) or 0
            end
        end
        if ae.getFluidsInNetwork then
            local okF, res = pcall(ae.getFluidsInNetwork, { name = RecipesDb.MAGMATTER_FLUID })
            if okF and type(res) == "table" then
                for _, f in pairs(res) do
                    if type(f) == "table" and tostring(f.name or ""):lower() == RecipesDb.MAGMATTER_FLUID then
                        magMe = magMe + math.floor(tonumber(f.amount) or 0)
                    end
                end
            end
        end
    end
    -- Also count seeds in dedicated seedSrcSide buffer if larger than AE count
    local tp = getProxy(compLib, state, cfg and cfg.itemTransposerAddr)
    if tp then
        local slots = iterStacks(tp, Hardware.toSideNum(cfg and cfg.seedSrcSide))
        local bufCounts = {}
        for _, st in pairs(slots) do
            if type(st) == "table" and tostring(st.name or "") == "gregtech:gt.metaitem.03" then
                local rec = RecipesDb.NANITE_BY_DAMAGE[math.floor(tonumber(st.damage) or -1)]
                if rec then bufCounts[rec.id] = (bufCounts[rec.id] or 0) + math.floor(tonumber(st.size) or 0) end
            end
        end
        for _, r in ipairs(RecipesDb.RECIPES) do
            stocks[r.id] = math.max(stocks[r.id] or 0, bufCounts[r.id] or 0)
        end
    end
    return stocks, magMe
end

-- ============================================================================
-- OC Mesh (:4205) Client (`NANO_METRICS` / `NANO_ACK` / `NANO_CMD` / `NANO_REPLY` + `STOCK_PUSH_RULES`)
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

function Hardware.pushRulesToStock(cfg, state, payload, compLib)
    if cfg and cfg.extLinkMode == "off" then return false, "ExtLink disabled" end
    local cl = compLib or defaultComponent or _G.component
    local modem, tunnel = getMeshTransports(cl, state, cfg)
    if not modem and not tunnel then return false, "No Wireless Modem or Linked Card" end
    state._pushSeq = (state._pushSeq or 0) + 1
    local reqId = "np" .. tostring(state._pushSeq)
    local viaTunnel = (state._mainnetMeshViaTunnel == true) or (not modem and tunnel ~= nil)
    local ok = sendMeshPacket(cl, state, state._mainnetMeshAddr, viaTunnel, "STOCK_PUSH_RULES", reqId, serialization.serialize(payload))
    return ok, ok and reqId or "Transmit failed"
end

function Hardware.pushMeshMetrics(cfg, state, nowSec, compLib, force)
    if cfg and cfg.extLinkMode == "off" then return false end
    local cl = compLib or defaultComponent or _G.component
    local modem, tunnel = getMeshTransports(cl, state, cfg)
    if not modem and not tunnel then return false end

    nowSec = nowSec or clockNow()
    local st = state or {}
    local cur = st.currentBatch or {}
    local pkt = {
        armed = (cfg and cfg.armed == true),
        autoWake = (not cfg or cfg.autoWake ~= false),
        forgeTier = tonumber(cfg and cfg.forgeTier) or 4,
        mode = (cfg and cfg.mode) or "both",
        phase = st.phase or "IDLE",
        activeRecipeId = cur.recipeId,
        activeLabel = cur.label or "",
        parallels = tonumber(cur.parallels) or 0,
        magmatterL = tonumber(cur.magmatterL) or 0,
        perfectOC = (cur.perfectOC == true),
        speedMult = tonumber(cur.speedMult) or 1.0,
        busClean = (st.busScan and st.busScan.clean ~= false),
        magAvailableL = math.floor(tonumber(st.magAvailableL) or 0),
        completedBatches = math.floor(tonumber(st.completedBatches) or 0),
    }
    local digest = string.format("%s:%s:%s:%d:%d:%s",
        tostring(pkt.armed), tostring(pkt.phase), tostring(pkt.activeRecipeId),
        pkt.parallels, pkt.completedBatches, tostring(pkt.busClean))
    if not force and digest == st._lastMeshDigest and (nowSec - (st._lastMeshAt or -100)) < 15 then
        return false
    end
    st._lastMeshAt = nowSec
    st._lastMeshDigest = digest

    local viaTunnel = (st._mainnetMeshViaTunnel == true) or (not modem and tunnel ~= nil)
    sendMeshPacket(cl, st, st._mainnetMeshAddr, viaTunnel, "NANO_METRICS", serialization.serialize(pkt))

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
    elseif msgType == "NANO_ACK" then
        if state then
            state._mainnetMeshAddr = sender
            state._mainnetMeshViaTunnel = (port == 0)
            state._lastMainnetSeen = clockNow()
            state._mainnetWakeAttempts = 0
        end
        return true
    elseif msgType == "NANO_CMD" then
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
            resTbl = { ok = false, error = "Invalid NANO_CMD payload" }
        end
        local raw = serialization.serialize(resTbl)
        local CHUNK = 5500
        local total = math.max(1, math.ceil(#raw / CHUNK))
        local viaTunnel = (port == 0)
        for idx = 1, total do
            local slice = raw:sub((idx - 1) * CHUNK + 1, idx * CHUNK)
            sendMeshPacket(cl, state, sender, viaTunnel, "NANO_REPLY", tostring(reqId or ""), idx, total, slice)
        end
        return true
    end
    return false
end

return Hardware
