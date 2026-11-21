-- /home/qft/lib/hardware.lua
-- GTNH Quantum Force Transformer (QFT) Hardware Layer:
--   - Supports 1-block (Controller only), 2-block (Controller + Stocking Input Bus),
--     or 3-block (Controller + Stocking Input Bus + Stocking Input Hatch) per QFT
--   - CRITICAL SAFETY GUARD: Never removes Neptunium/Fermium plasma or changes focus
--     circuit while the QFT is actively running (waits for idle first to prevent cycle voiding)
--   - Optional local AE2 O(1) stock query & craft fallback + OC Mesh :4205 client

local okComp, defaultComponent = pcall(require, "component")
if not okComp then defaultComponent = nil end
local Common = require("gtnh_common")
local okComputer, computer = pcall(require, "computer")
if not okComputer then computer = nil end
local serialization = require("serialization")
local RecipesDb = require("lib.recipes_db")

local Hardware = {}

Hardware.MESH_PORT = 4205
Hardware.WAKE_MSG = "GTNH_WAKE"

local GT_TIER_NAMES = { "ULV", "LV", "MV", "HV", "EV", "IV", "LuV", "ZPM", "UV", "UHV", "UEV", "UIV", "UMV", "UXV", "MAX" }
local GT_TIER_V = { 8, 32, 128, 512, 2048, 8192, 32768, 131072, 524288, 2097152, 8388608, 33554432, 134217728, 536870912, 2147483640 }
local SI_MULT = { k = 1e3, K = 1e3, M = 1e6, G = 1e9, B = 1e9, T = 1e12, P = 1e15, E = 1e18 }

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

-- Parse QFT multiblock sensor lines (both GTNH 2.9.0 encoded `\` keys and decoded English)
function Hardware.parseQftSensor(lines)
    local info = {
        maxInputEu = nil,
        hatchAmps = nil,
        hatchTier = nil,
        hatchLabel = nil,
        liveEut = nil,
        problems = 0,
    }
    if type(lines) ~= "table" then return info end
    local lineList = collectSensorLines(lines)
    for i = 1, #lineList do
        local clean = stripFormatting(lineList[i])
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
        if not info.liveEut then
            local uRaw = clean:match("^GT5U%.multiblock%.scanner%.usage\\+([^\\]+)")
                or clean:match("[Cc]urrently uses:%s*(.-)%s*EU/t")
                or clean:match("[Pp]robably uses:%s*(.-)%s*EU/t")
            if uRaw then
                info.liveEut = parseSensorNumber(uRaw)
            end
        end
        local ep = clean:match("^GT5U%.multiblock%.scanner%.problems\\+([^\\]+)")
        if ep then
            local np = parseSensorNumber(ep)
            if np then info.problems = math.floor(np) end
        else
            local dp = clean:match("Problems:%s*(%d+)")
            if dp then info.problems = tonumber(dp) or 0 end
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

local function clockNow()
    if computer and computer.uptime then return computer.uptime()
    elseif _G.computer and _G.computer.uptime then return _G.computer.uptime()
    elseif os and os.clock then return os.clock() end
    return 0
end

Hardware.now = clockNow

function Hardware.shortAddr(addr)
    if type(addr) ~= "string" or addr == "" then return "--" end
    return (#addr > 8) and addr:sub(1, 8) or addr
end

local function listAll(compLib, ctype)
    local out = {}
    if not compLib or not compLib.list then return out end
    local iter = compLib.list(ctype, true)
    if type(iter) == "function" then
        for addr in iter do out[#out + 1] = addr end
    elseif type(iter) == "table" then
        for addr in pairs(iter) do out[#out + 1] = addr end
    end
    table.sort(out)
    return out
end

local function getProxy(compLib, state, addr)
    if type(addr) ~= "string" or addr == "" then return nil end
    local proxies = state and state._proxies
    if proxies and proxies[addr] then return proxies[addr] end
    if not compLib or not compLib.proxy then return nil end
    local ok, p = pcall(compLib.proxy, addr)
    if ok and p then
        if proxies then proxies[addr] = p end
        return p
    end
    return nil
end

local function isQftName(name)
    local low = tostring(name or ""):lower()
    if low == "" then return false end
    return low:find("quantumforce", 1, true) ~= nil
        or low:find("quantum_force", 1, true) ~= nil
        or (low:find("force", 1, true) ~= nil and low:find("transformer", 1, true) ~= nil)
end

local function isQftSensor(info)
    if type(info) ~= "table" then return false end
    for _, line in ipairs(info) do
        local low = tostring(line or ""):lower()
        if low:find("quantum force", 1, true) or low:find("focusing tier", 1, true) then
            return true
        end
    end
    return false
end

function Hardware.discover(cfg, compLib, state)
    local cl = compLib or defaultComponent or _G.component
    if state then
        state._proxies = {}
    end
    local disc = {
        controllers = {},
        otherMachines = {},
        inputBuses = {},
        inputHatches = {},
        aeInterfaces = {},
        hasGpu = (#listAll(cl, "gpu") > 0),
        hasScreen = (#listAll(cl, "screen") > 0),
        hasModem = (#listAll(cl, "modem") > 0),
        hasTunnel = (#listAll(cl, "tunnel") > 0),
        hasInternet = (#listAll(cl, "internet") > 0),
    }

    for _, addr in ipairs(listAll(cl, "gt_machine")) do
        local p = getProxy(cl, state, addr)
        local mName = "gt_machine"
        local matched = false
        local sensorTbl = nil
        if p then
            if p.getName then
                local okN, n = pcall(p.getName)
                if okN and n then
                    mName = tostring(n)
                    if isQftName(mName) then matched = true end
                end
            end
            if p.getSensorInformation then
                local okS, s = pcall(p.getSensorInformation)
                if okS and type(s) == "table" then
                    sensorTbl = s
                    if (not matched) and isQftSensor(s) then matched = true end
                end
            end
        end
        local x, y, z = readCoords(p)
        local parsed = sensorTbl and Hardware.parseQftSensor(sensorTbl) or nil
        local rec = {
            addr = addr,
            short = Hardware.shortAddr(addr),
            name = mName,
            coords = (x and y and z) and { x = x, y = y, z = z } or nil,
            hatchLabel = parsed and parsed.hatchLabel or nil,
            maxInputEu = parsed and parsed.maxInputEu or nil,
            problems = parsed and parsed.problems or 0,
        }
        if matched then
            disc.controllers[#disc.controllers + 1] = rec
        else
            disc.otherMachines[#disc.otherMachines + 1] = rec
        end
    end
    table.sort(disc.controllers, function(a, b)
        local ac, bc = a.coords, b.coords
        if ac and bc then
            if ac.z ~= bc.z then return ac.z < bc.z end
            if ac.x ~= bc.x then return ac.x < bc.x end
            if ac.y ~= bc.y then return ac.y < bc.y end
        elseif ac or bc then
            return ac ~= nil
        end
        return tostring(a.addr) < tostring(b.addr)
    end)

    for _, addr in ipairs(listAll(cl, "me_inputbus")) do
        local p = getProxy(cl, state, addr)
        local cir = nil
        if p and p.getCircuitConfiguration then
            local okC, c = pcall(p.getCircuitConfiguration)
            if okC then cir = tonumber(c) end
        end
        disc.inputBuses[#disc.inputBuses + 1] = {
            addr = addr,
            short = Hardware.shortAddr(addr),
            circuit = cir,
        }
    end

    for _, addr in ipairs(listAll(cl, "me_inputhatch")) do
        local p = getProxy(cl, state, addr)
        local slots = 0
        if p and p.getSlotSize then
            local okS, s = pcall(p.getSlotSize)
            if okS and tonumber(s) then slots = math.floor(tonumber(s)) end
        end
        disc.inputHatches[#disc.inputHatches + 1] = {
            addr = addr,
            short = Hardware.shortAddr(addr),
            slots = slots,
        }
    end

    for _, ctype in ipairs({ "me_controller", "me_interface" }) do
        for _, addr in ipairs(listAll(cl, ctype)) do
            disc.aeInterfaces[#disc.aeInterfaces + 1] = { addr = addr, ctype = ctype }
        end
    end

    if state then
        state.discovery = disc
    end
    return disc
end

function Hardware.getLocalAeProxy(cfg, compLib, state)
    local cl = compLib or defaultComponent or _G.component
    local aeAddr = cfg and cfg.aeAddr or "auto"
    if aeAddr ~= "" and aeAddr ~= "auto" then
        local p = getProxy(cl, state, aeAddr)
        if p then return p, aeAddr end
    end
    for _, ctype in ipairs({ "me_controller", "me_interface" }) do
        for _, addr in ipairs(listAll(cl, ctype)) do
            local p = getProxy(cl, state, addr)
            if p then return p, addr end
        end
    end
    return nil, nil
end

function Hardware.queryStock(ae, rType, name, damage, counter)
    if not ae or type(name) ~= "string" or name == "" then return nil, false end
    if rType == "fluid" then
        if ae.getFluidInNetwork then
            if counter then counter.aeCalls = (counter.aeCalls or 0) + 1 end
            local ok, res = pcall(ae.getFluidInNetwork, name)
            if ok then
                if type(res) == "table" then
                    return tonumber(res.amount) or 0, true
                elseif type(res) == "number" then
                    return res, true
                end
                return 0, true
            end
        end
        return nil, false
    end
    if ae.getItemInNetwork then
        if counter then counter.aeCalls = (counter.aeCalls or 0) + 1 end
        local dmg = math.max(0, math.floor(tonumber(damage) or 0))
        local ok, st = pcall(ae.getItemInNetwork, name, dmg)
        if ok then
            if type(st) == "table" then
                return tonumber(st.size) or 0, true
            elseif type(st) == "number" then
                return st, true
            end
            return 0, true
        end
    end
    return nil, false
end

function Hardware.inspectLocalCpus(ae, counter)
    if not ae or not ae.getCpus then
        return { ok = false, total = 0, free = 0, busyByKey = {}, busyByLabel = {}, freeList = {}, error = "No local AE2" }
    end
    if counter then counter.aeCalls = (counter.aeCalls or 0) + 1 end
    local ok, list = pcall(ae.getCpus)
    if not ok or type(list) ~= "table" then
        return { ok = false, total = 0, free = 0, busyByKey = {}, busyByLabel = {}, freeList = {}, error = "getCpus failed" }
    end
    local total, free = 0, 0
    local busyList, freeList = {}, {}
    for i = 1, #list do
        local c = list[i]
        if type(c) == "table" then
            total = total + 1
            if c.busy then
                busyList[#busyList + 1] = c
            else
                free = free + 1
                freeList[#freeList + 1] = { name = tostring(c.name or ("CPU-" .. total)) }
            end
        end
    end
    local busyByKey, busyByLabel = {}, {}
    for _, c in ipairs(busyList) do
        local outFn = c.cpu and c.cpu.finalOutput
        if type(outFn) == "function" then
            if counter then counter.aeCalls = (counter.aeCalls or 0) + 1 end
            local okOut, fin = pcall(outFn)
            if okOut and type(fin) == "table" then
                local cpuName = tostring(c.name or "Busy")
                if fin.name == "ae2fc:fluid_drop" and type(fin.fluid) == "table" and fin.fluid.name then
                    busyByKey["fluid:" .. tostring(fin.fluid.name) .. ":0"] = cpuName
                elseif fin.name then
                    busyByKey[string.format("item:%s:%d", tostring(fin.name), math.floor(tonumber(fin.damage) or 0))] = cpuName
                end
                if fin.label then
                    busyByLabel[tostring(fin.label)] = cpuName
                end
            end
        end
    end
    return { ok = true, total = total, free = free, busyByKey = busyByKey, busyByLabel = busyByLabel, freeList = freeList }
end

function Hardware.requestLocalCraft(ae, rule, amount, counter)
    if not ae or not ae.getCraftables then return { ok = false, error = "No AE2 interface" } end
    local isFl = (rule.type == "fluid")
    local filter = isFl
        and { name = "ae2fc:fluid_drop", fluid = { name = rule.name } }
        or { name = rule.name, damage = math.max(0, math.floor(tonumber(rule.damage) or 0)) }
    if counter then counter.aeCalls = (counter.aeCalls or 0) + 1 end
    local okC, list = pcall(ae.getCraftables, filter)
    local handle = (okC and type(list) == "table") and list[1] or nil
    if (not handle) and isFl then
        if counter then counter.aeCalls = (counter.aeCalls or 0) + 1 end
        local okC2, list2 = pcall(ae.getCraftables, { name = "ae2fc:fluid_drop" })
        if okC2 and type(list2) == "table" then
            for _, cand in ipairs(list2) do
                if cand and cand.getItemStack then
                    local okS, st = pcall(cand.getItemStack)
                    if okS and type(st) == "table" and type(st.fluid) == "table" and st.fluid.name == rule.name then
                        handle = cand
                        break
                    end
                end
            end
        end
    end
    if not handle or not handle.request then
        return { ok = false, error = "No AE2 pattern" }
    end
    if counter then counter.aeCalls = (counter.aeCalls or 0) + 1 end
    local amt = math.max(1, math.floor(tonumber(amount) or 1))
    local okR, statusObj, rErr = pcall(handle.request, amt, true, nil)
    if not okR or not statusObj then
        return { ok = false, error = tostring(rErr or statusObj or "request failed") }
    end
    local failed = false
    if statusObj.hasFailed then
        local okF, isF = pcall(statusObj.hasFailed)
        if okF and isF then failed = true end
    end
    if failed then
        local msg = "Missing resources / busy"
        if statusObj.getErrorMessage then
            local okE, eTxt = pcall(statusObj.getErrorMessage)
            if okE and type(eTxt) == "string" and eTxt ~= "" then msg = eTxt end
        end
        return { ok = false, error = msg }
    end
    return { ok = true, status = "crafting", statusObj = statusObj }
end

local function inspectHatchPlasmas(hatchProxy)
    local slotSize = 16
    if hatchProxy.getSlotSize then
        local okS, sz = pcall(hatchProxy.getSlotSize)
        if okS and tonumber(sz) and tonumber(sz) >= 2 then
            slotSize = math.floor(tonumber(sz))
        end
    end
    local npName = RecipesDb.PLASMAS.neptunium.name
    local fmName = RecipesDb.PLASMAS.fermium.name
    local npSlots, fmSlots = {}, {}
    local freeSlots = {}
    for s = 1, slotSize do
        local okG, cfg = pcall(hatchProxy.getConfiguration, s)
        if okG and type(cfg) == "table" and cfg.name then
            local fn = tostring(cfg.name):lower()
            if fn == npName then
                npSlots[#npSlots + 1] = s
            elseif fn == fmName then
                fmSlots[#fmSlots + 1] = s
            end
        elseif okG then
            freeSlots[#freeSlots + 1] = s
        end
    end
    local autoPull = false
    if hatchProxy.isAutoPull then
        local okA, ap = pcall(hatchProxy.isAutoPull)
        if okA then autoPull = (ap == true) end
    end
    return {
        slotSize = slotSize,
        autoPull = autoPull,
        hasNeptunium = (#npSlots > 0),
        hasFermium = (#fmSlots > 0),
        npSlots = npSlots,
        fmSlots = fmSlots,
        npTargetSlot = npSlots[1] or math.max(1, slotSize - 1),
        fmTargetSlot = fmSlots[1] or slotSize,
        freeSlots = freeSlots,
    }
end

function Hardware.readUnit(unit, compLib, state)
    local cl = compLib or defaultComponent or _G.component
    local res = {
        online = false,
        active = false,
        workAllowed = false,
        progress = 0,
        maxProgress = 0,
        focusCircuit = nil,
        hasBus = false,
        hasHatch = false,
        hasNeptunium = false,
        hasFermium = false,
        hatchInfo = nil,
        maxInputEu = nil,
        hatchAmps = nil,
        hatchTier = nil,
        hatchLabel = nil,
        liveEut = nil,
        coords = nil,
        problems = 0,
    }

    local ctrl = getProxy(cl, state, unit.controllerAddr)
    if ctrl then
        res.online = true
        local x, y, z = readCoords(ctrl)
        if x and y and z then res.coords = { x = x, y = y, z = z } end
        if ctrl.isMachineActive then
            local okA, a = pcall(ctrl.isMachineActive)
            if okA then res.active = (a == true) end
        end
        if ctrl.isWorkAllowed then
            local okW, w = pcall(ctrl.isWorkAllowed)
            if okW then res.workAllowed = (w ~= false) end
        end
        if ctrl.getWorkProgress then
            local okP, p = pcall(ctrl.getWorkProgress)
            if okP and tonumber(p) then res.progress = math.floor(tonumber(p)) end
        end
        if ctrl.getWorkMaxProgress then
            local okM, m = pcall(ctrl.getWorkMaxProgress)
            if okM and tonumber(m) then res.maxProgress = math.floor(tonumber(m)) end
        end
        if ctrl.getSensorInformation then
            local okS, s = pcall(ctrl.getSensorInformation)
            if okS and type(s) == "table" then
                local parsed = Hardware.parseQftSensor(s)
                res.maxInputEu = parsed.maxInputEu
                res.hatchAmps = parsed.hatchAmps
                res.hatchTier = parsed.hatchTier
                res.hatchLabel = parsed.hatchLabel
                res.liveEut = parsed.liveEut
                res.problems = parsed.problems or 0
            end
        end
    end

    local bus = getProxy(cl, state, unit.busAddr)
    if bus then
        res.hasBus = true
        if bus.getCircuitConfiguration then
            local okC, cir = pcall(bus.getCircuitConfiguration)
            if okC and tonumber(cir) then
                res.focusCircuit = math.floor(tonumber(cir))
            end
        end
    end

    local hatch = getProxy(cl, state, unit.hatchAddr)
    if hatch then
        res.hasHatch = true
        local hInfo = inspectHatchPlasmas(hatch)
        res.hatchInfo = hInfo
        res.hasNeptunium = hInfo.hasNeptunium
        res.hasFermium = hInfo.hasFermium
    end
    return res
end

-- Plasma-Voiding Safe Controller Mutation:
-- GTNH nulls QFT outputs if Neptunium/Fermium plasma disappears while isMachineActive() == true.
-- So whenever focusCircuit OR plasma hatch config must change while active == true, we pause
-- setWorkAllowed(false) ONLY, wait for active == false on a subsequent tick, apply bus/hatch changes,
-- then restore setWorkAllowed(desired.workAllowed).
function Hardware.applyUnitControl(unit, live, desired, compLib, state)
    local cl = compLib or defaultComponent or _G.component
    local ctrl = getProxy(cl, state, unit.controllerAddr)
    if not ctrl then
        return { ok = false, action = "offline" }
    end

    local needBusChange = false
    local bus = nil
    if live.hasBus and desired.focusCircuit ~= nil then
        bus = getProxy(cl, state, unit.busAddr)
        if bus and bus.setCircuitConfiguration and live.focusCircuit ~= desired.focusCircuit then
            needBusChange = true
        end
    end

    local needNpChange, needFmChange = false, false
    local hatch = nil
    local hInfo = live.hatchInfo
    if live.hasHatch and hInfo then
        hatch = getProxy(cl, state, unit.hatchAddr)
        if hatch and hatch.setConfiguration then
            if desired.wantNeptunium ~= nil and (live.hasNeptunium ~= desired.wantNeptunium) then
                needNpChange = true
            end
            if desired.wantFermium ~= nil and (live.hasFermium ~= desired.wantFermium) then
                needFmChange = true
            end
        end
    end

    local needReconfig = needBusChange or needNpChange or needFmChange
    if needReconfig and live.active then
        if ctrl.setWorkAllowed and live.workAllowed ~= false then
            pcall(ctrl.setWorkAllowed, false)
        end
        return { ok = true, reconfiguring = true, waitingIdle = true, action = "wait_idle" }
    end

    if needReconfig and (not live.active) then
        if needBusChange and bus then
            pcall(bus.setCircuitConfiguration, math.max(0, math.floor(desired.focusCircuit)))
        end
        if needNpChange and hatch and hInfo then
            if desired.wantNeptunium then
                local slot = hInfo.npTargetSlot
                if hInfo.hasFermium and hInfo.fmSlots[1] == slot then
                    slot = (hInfo.freeSlots and hInfo.freeSlots[1]) or math.max(1, hInfo.slotSize - 1)
                end
                pcall(hatch.setConfiguration, slot, { name = RecipesDb.PLASMAS.neptunium.name, amount = 1000 })
            else
                for _, s in ipairs(hInfo.npSlots or {}) do
                    pcall(hatch.setConfiguration, s)
                end
            end
        end
        if needFmChange and hatch and hInfo then
            if desired.wantFermium then
                local slot = hInfo.fmTargetSlot
                if (hInfo.hasNeptunium or desired.wantNeptunium) and slot == hInfo.npTargetSlot then
                    slot = (hInfo.freeSlots and hInfo.freeSlots[1]) or hInfo.slotSize
                end
                pcall(hatch.setConfiguration, slot, { name = RecipesDb.PLASMAS.fermium.name, amount = 1000 })
            else
                for _, s in ipairs(hInfo.fmSlots or {}) do
                    pcall(hatch.setConfiguration, s)
                end
            end
        end
        if ctrl.setWorkAllowed then
            pcall(ctrl.setWorkAllowed, desired.workAllowed == true)
        end
        return { ok = true, reconfiguring = false, appliedReconfig = true, action = "reconfigured" }
    end

    if ctrl.setWorkAllowed and (live.workAllowed ~= (desired.workAllowed == true)) then
        pcall(ctrl.setWorkAllowed, desired.workAllowed == true)
        return { ok = true, reconfiguring = false, action = desired.workAllowed and "enabled" or "paused" }
    end
    return { ok = true, reconfiguring = false, action = "steady" }
end

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
    local modem, tunnel, _, tAddr = Common.getMeshTransports(cl, {
        port = Hardware.MESH_PORT,
        wakeMsg = (aw == false) and false or Hardware.WAKE_MSG,
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
    local cl = compLib or defaultComponent or _G.component
    local modem, tunnel = getMeshTransports(cl, state, cfg)
    return (modem ~= nil) or (tunnel ~= nil)
end

function Hardware.pushRulesToStock(cfg, state, payload, compLib)
    if cfg and cfg.extLinkMode == "off" then
        return false, "ExtLink disabled"
    end
    if type(payload) ~= "table" then
        return false, "Invalid push payload"
    end
    local cl = compLib or defaultComponent or _G.component
    local modem, tunnel = getMeshTransports(cl, state, cfg)
    if not modem and not tunnel then
        return false, "No Wireless Modem or Linked Card"
    end
    local raw = serialization.serialize(payload)
    if #raw > 5800 then
        return false, "Push batch exceeds 5800B MTU"
    end
    state._pushSeq = (state._pushSeq or 0) + 1
    local reqId = "qp" .. tostring(state._pushSeq)
    local targetAddr = (state._mainnetMeshAddr) or (state.stockPeer and state.stockPeer.addr) or nil
    local viaTunnel = (state._mainnetMeshViaTunnel == true) or (not modem and tunnel ~= nil)
    local ok = sendMeshPacket(cl, state, targetAddr, viaTunnel, "STOCK_PUSH_RULES", reqId, raw)
    if ok then
        state._lastStockPushReqId = reqId
        state._lastStockPushAt = clockNow()
        return true, reqId
    end
    return false, "Failed to transmit STOCK_PUSH_RULES"
end

function Hardware.pushMeshMetrics(cfg, state, nowSec, compLib, force)
    if cfg and cfg.extLinkMode == "off" then return false end
    local cl = compLib or defaultComponent or _G.component
    local modem, tunnel = getMeshTransports(cl, state, cfg)
    if not modem and not tunnel then return false end

    nowSec = nowSec or clockNow()
    local st = state or {}
    local unitsOut = {}
    local running, reconf, problems, errs = 0, 0, 0, 0
    for _, uSt in ipairs(st.unitStatuses or {}) do
        if uSt.active then running = running + 1 end
        if uSt.reconfiguring then reconf = reconf + 1 end
        if (tonumber(uSt.problems) or 0) > 0 then problems = problems + 1 end
        if not uSt.online and uSt.enabled ~= false then errs = errs + 1 end
        unitsOut[#unitsOut + 1] = {
            id = uSt.id,
            label = uSt.label,
            recipeId = uSt.recipeId,
            recipeName = uSt.recipeName,
            catalystLabel = uSt.catalystLabel or "",
            tier = uSt.tier,
            online = uSt.online == true,
            active = uSt.active == true,
            reconfiguring = uSt.reconfiguring == true,
            focusCircuit = uSt.focusCircuit,
            hasNeptunium = uSt.hasNeptunium == true,
            hasFermium = uSt.hasFermium == true,
            hatchLabel = uSt.hatchLabel or "",
            maxInputEu = math.floor(tonumber(uSt.maxInputEu) or 0),
            state = uSt.state or "IDLE",
        }
    end
    local maintMode = st.maintMode or { mode = "offline", label = "OFFLINE" }
    local diag = st.hwDiag or {}
    local diagErr = #(diag.errors or {})
    local diagWrn = #(diag.warnings or {})
    local pkt = {
        armed = (cfg and cfg.armed == true),
        autoWake = (not cfg or cfg.autoWake ~= false),
        unitCount = #(unitsOut),
        activeCount = running,
        reconfigCount = reconf,
        problemCount = problems,
        errorCount = errs,
        diagErrors = diagErr,
        diagWarnings = diagWrn,
        maintMode = maintMode.mode,
        maintLabel = maintMode.label,
        localRulesCount = #(cfg and cfg.localRules or {}),
        units = unitsOut,
    }
    local digest = string.format("%s:%d:%d:%d:%s:%d:%d",
        tostring(pkt.armed), pkt.activeCount, pkt.reconfigCount, pkt.problemCount, tostring(pkt.maintMode), diagErr, diagWrn)
    if not force and digest == st._lastMeshDigest and (nowSec - (st._lastMeshAt or -100)) < 15 then
        return false
    end
    st._lastMeshAt = nowSec
    st._lastMeshDigest = digest

    local raw = serialization.serialize(pkt)
    if #raw > 5800 then
        for _, uo in ipairs(pkt.units) do
            uo.hatchLabel = nil
            uo.catalystLabel = nil
        end
        raw = serialization.serialize(pkt)
    end
    if #raw > 5800 then
        pkt.units = {}
        raw = serialization.serialize(pkt)
    end
    local viaTunnel = (st._mainnetMeshViaTunnel == true) or (not modem and tunnel ~= nil)
    sendMeshPacket(cl, st, st._mainnetMeshAddr, viaTunnel, "QFT_METRICS", raw)

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

local function decodeClaimKeys(list)
    local out = {}
    if type(list) ~= "table" then return out end
    for i = 1, #list do
        local s = tostring(list[i] or "")
        if s:sub(1, 2) == "f:" then
            out["fluid:" .. s:sub(3) .. ":0"] = true
        elseif s:sub(1, 2) == "i:" then
            out["item:" .. s:sub(3)] = true
        elseif s ~= "" then
            out[s] = true
        end
    end
    return out
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
    elseif msgType == "QFT_ACK" then
        if state then
            state._mainnetMeshAddr = sender
            state._mainnetMeshViaTunnel = (port == 0)
            state._lastMainnetSeen = clockNow()
            state._mainnetWakeAttempts = 0
        end
        return true
    elseif msgType == "STOCK_CLAIMS" then
        local rawStr = (type(reqId) == "string" and reqId:sub(1, 1) == "{" and (payload == nil or payload == "")) and reqId or payload
        local okU, pkt = pcall(serialization.unserialize, tostring(rawStr or ""))
        if okU and type(pkt) == "table" and state then
            local wasOnline = state.stockPeer and state.stockPeer.armed == true
            state.stockPeer = {
                addr = sender,
                viaTunnel = (port == 0),
                lastSeen = clockNow(),
                armed = (pkt.armed == true),
                keys = decodeClaimKeys(pkt.keys),
            }
            if state.stockPeer.armed and not wasOnline then
                state._syncPendingToMainnet = true
            end
            return true
        end
        return false
    elseif msgType == "STOCK_PUSH_ACK" then
        local rawStr = (type(reqId) == "string" and reqId:sub(1, 1) == "{" and (payload == nil or payload == "")) and reqId or payload
        local okU, ack = pcall(serialization.unserialize, tostring(rawStr or ""))
        if okU and type(ack) == "table" and state then
            state._lastPushAck = ack
            if ack.ok and ack.tag and type(cfg and cfg.localRules) == "table" then
                for _, lr in ipairs(cfg.localRules) do
                    if type(lr.tags) == "table" then
                        for _, t in ipairs(lr.tags) do
                            if t == ack.tag then
                                lr.syncedToMainnet = true
                            end
                        end
                    end
                end
            end
            return true
        end
        return false
    elseif msgType == "QFT_CMD" then
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
            resTbl = { ok = false, error = "Invalid QFT_CMD payload" }
        end
        local raw = serialization.serialize(resTbl)
        local CHUNK = 5500
        local total = math.max(1, math.ceil(#raw / CHUNK))
        local viaTunnel = (port == 0)
        for idx = 1, total do
            local slice = raw:sub((idx - 1) * CHUNK + 1, idx * CHUNK)
            sendMeshPacket(cl, state, sender, viaTunnel, "QFT_REPLY", tostring(reqId or ""), idx, total, slice)
        end
        return true
    end
    return false
end

return Hardware
