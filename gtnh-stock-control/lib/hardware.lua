-- /home/stock/lib/hardware.lua
-- Hardware abstraction & O(1) GTNH 2.9 AE2 interface for Mainnet Stock Maintainer:
--   - Deterministic Mainnet AE2 discovery (`me_controller` > `me_interface` / `fluid_interface`)
--   - O(1) stock & craftable lookups (`getItemInNetwork`, `getFluidInNetwork`, `getCraftable`)
--   - Optional Transposer drop-in slot reader (items & `ae2fc:fluid_drop` / cells)
--   - Optional physical AE2FC `level_maintainer` scanner/importer + slot disable helper
--   - Zero-tick cached OC Mesh (`port 4205`: `STOCK_METRICS`, `STOCK_CLAIMS`, `STOCK_CMD`/`STOCK_REPLY`, `DTPF_CLAIMS`)
--   - Live O(1) vs O(N) & physical maintainer profiler (`runBenchmark`)

local component = require("component")
local okComp, computer = pcall(require, "computer")
if not okComp then computer = nil end
local serialization = require("serialization")

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

local function clockNow()
    if computer and computer.uptime then
        return computer.uptime()
    elseif os and os.clock then
        return os.clock()
    end
    return 0
end

function Hardware.shortAddr(addr)
    if type(addr) ~= "string" or addr == "" then return "None" end
    return addr:sub(1, 8)
end

function Hardware.clearProxyCache(state)
    if not state then return end
    state._proxies = {}
    state._craftableCache = {}
    state._meshModem = nil
    state._meshTunnel = nil
    state._meshTunnelAddr = nil
end

local function getProxy(addr, compLib, state)
    if type(addr) ~= "string" or addr == "" then
        return nil, "unconfigured address"
    end
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

local function safeMethod(proxy, method, ...)
    if not proxy then return nil end
    local fn = proxy[method]
    if type(fn) ~= "function" then return nil end
    local ok, r1, r2 = pcall(fn, ...)
    if not ok then return nil, r1 end
    return r1, r2
end

function Hardware.discover(cfg, compLib, state)
    local cl = compLib or component
    Hardware.clearProxyCache(state)

    local bestAe, bestAeAddr, bestAeType, bestScore = nil, nil, nil, -1
    local explicitAe = cfg and cfg.aeAddr
    local aeCandidates = {}
    local seenAe = {}

    for _, spec in ipairs({ { "me_controller", 1000000 }, { "me_interface", 0 }, { "fluid_interface", 0 } }) do
        local ctype, bonus = spec[1], spec[2]
        if cl.list then
            for addr in cl.list(ctype, true) do
                if not seenAe[addr] then
                    seenAe[addr] = true
                    local p = cl.proxy(addr)
                    if p and (p.getCpus or p.getItemInNetwork or p.getItemsInNetwork) then
                        local cpus = safeMethod(p, "getCpus")
                        local nCpus = (type(cpus) == "table") and #cpus or 0
                        local score = bonus + nCpus * 1000
                        aeCandidates[#aeCandidates + 1] = {
                            addr = addr,
                            ctype = ctype,
                            cpus = nCpus,
                            score = score,
                            proxy = p,
                        }
                    end
                end
            end
        end
    end
    for i = 1, #aeCandidates do
        local c = aeCandidates[i]
        local sc = c.score
        if (#aeCandidates > 1) and (not explicitAe or explicitAe == "auto") and c.proxy then
            local fl = safeMethod(c.proxy, "getFluidsInNetwork")
            local nFl = (type(fl) == "table") and #fl or 0
            sc = sc + nFl
            c.score = sc
        end
        if explicitAe and explicitAe ~= "auto" and explicitAe == c.addr then
            bestAe, bestAeAddr, bestAeType, bestScore = c.proxy, c.addr, c.ctype, math.huge
        elseif (not explicitAe or explicitAe == "auto") and sc > bestScore then
            bestAe, bestAeAddr, bestAeType, bestScore = c.proxy, c.addr, c.ctype, sc
        end
        c.proxy = nil
    end
    if not bestAe and explicitAe and explicitAe ~= "auto" then
        local p = cl.proxy(explicitAe)
        if p then
            bestAe, bestAeAddr, bestAeType = p, explicitAe, "custom"
        end
    end
    if not bestAe and cl.isAvailable then
        for _, ctype in ipairs({ "me_controller", "me_interface", "fluid_interface" }) do
            if cl.isAvailable(ctype) and cl[ctype] then
                bestAe = cl[ctype]
                bestAeAddr = bestAe.address or ctype
                bestAeType = ctype
                break
            end
        end
    end

    local transposers = {}
    if cl.list then
        for addr in cl.list("transposer", true) do
            transposers[#transposers + 1] = addr
        end
    elseif cl.isAvailable and cl.isAvailable("transposer") and cl.transposer then
        transposers[1] = cl.transposer.address or "transposer"
    end
    table.sort(transposers)

    local maintainers = {}
    if cl.list then
        for addr in cl.list("level_maintainer", true) do
            maintainers[#maintainers + 1] = addr
        end
    end
    table.sort(maintainers)

    local disc = {
        aeAddr = bestAeAddr,
        aeType = bestAeType,
        aeCandidates = aeCandidates,
        hasO1Item = (bestAe ~= nil and type(bestAe.getItemInNetwork) == "function"),
        hasO1Fluid = (bestAe ~= nil and type(bestAe.getFluidInNetwork) == "function"),
        hasO1Craftable = (bestAe ~= nil and type(bestAe.getCraftable) == "function"),
        transposers = transposers,
        maintainers = maintainers,
        hasGpu = (cl.isAvailable and cl.isAvailable("gpu")) or (cl.list and cl.list("gpu", true)() ~= nil) or false,
        hasScreen = (cl.isAvailable and cl.isAvailable("screen")) or (cl.list and cl.list("screen", true)() ~= nil) or false,
        hasModem = (cl.isAvailable and cl.isAvailable("modem")) or (cl.list and cl.list("modem", true)() ~= nil) or false,
        hasTunnel = (cl.isAvailable and cl.isAvailable("tunnel")) or (cl.list and cl.list("tunnel", true)() ~= nil) or false,
    }
    if state then
        state.discovery = disc
        if bestAe and bestAeAddr then
            state._proxies = state._proxies or {}
            state._proxies[bestAeAddr] = bestAe
        end
    end
    return disc, bestAe
end

function Hardware.getAeProxy(cfg, compLib, state)
    local aeAddr = state and state.discovery and state.discovery.aeAddr
    if aeAddr then
        local p = getProxy(aeAddr, compLib, state)
        if p then return p, aeAddr end
    end
    local disc, p = Hardware.discover(cfg, compLib, state)
    return p, disc and disc.aeAddr or nil
end

local function unwrapFluidDropOutput(fin)
    if type(fin) ~= "table" then return nil, nil end
    if fin.name == "ae2fc:fluid_drop" or type(fin.fluid) == "table" then
        local fl = type(fin.fluid) == "table" and fin.fluid or nil
        local lbl = tostring((fl and fl.label) or fin.label or ""):gsub("^drop of ", "")
        local fname = (fl and type(fl.name) == "string" and fl.name ~= "") and fl.name or nil
        return lbl, fname
    end
    return nil, nil
end

function Hardware.fetchBusyCpuOutputs(cpuSnap, counter)
    if not cpuSnap or cpuSnap._outputsFetched then
        return cpuSnap
    end
    local busyByKey = cpuSnap.busyByKey or {}
    local busyByLabel = cpuSnap.busyByLabel or {}
    local cpus = cpuSnap.cpus or {}
    for _, ref in ipairs(cpuSnap._busyRefs or {}) do
        if ref and ref.cpu and ref.cpu.finalOutput then
            if counter then counter.aeCalls = (counter.aeCalls or 0) + 1 end
            local okF, fin = pcall(ref.cpu.finalOutput)
            if okF and type(fin) == "table" then
                local dropLbl, dropFname = unwrapFluidDropOutput(fin)
                local outLabel = (dropLbl and dropLbl ~= "") and dropLbl or fin.label
                local outCount = math.floor(tonumber(fin.size or fin.amount) or 0)
                local outKey = nil
                if fin.label and fin.label ~= "" then
                    busyByLabel[fin.label] = busyByLabel[fin.label] or ref.name
                end
                if dropLbl and dropLbl ~= "" then
                    busyByLabel[dropLbl] = busyByLabel[dropLbl] or ref.name
                end
                if dropFname then
                    outKey = "fluid:" .. dropFname .. ":0"
                    busyByKey[outKey] = busyByKey[outKey] or ref.name
                end
                if fin.name and fin.name ~= "" then
                    local fType = (fin.maxSize == nil) and "fluid" or "item"
                    local dmg = (fType == "item") and math.floor(tonumber(fin.damage) or 0) or 0
                    local k = fType .. ":" .. fin.name .. ":" .. tostring(dmg)
                    busyByKey[k] = busyByKey[k] or ref.name
                    if not outKey then outKey = k end
                end
                if ref.idx and cpus[ref.idx] then
                    cpus[ref.idx].outputLabel = outLabel
                    cpus[ref.idx].outputKey = outKey
                    cpus[ref.idx].outputCount = outCount
                end
            end
        end
    end
    cpuSnap.busyByKey = busyByKey
    cpuSnap.busyByLabel = busyByLabel
    cpuSnap._outputsFetched = true
    return cpuSnap
end

function Hardware.inspectCpus(proxy, counter, opts)
    if not proxy or type(proxy.getCpus) ~= "function" then
        return { ok = false, error = "No AE2 CPU interface" }
    end
    if counter then counter.aeCalls = (counter.aeCalls or 0) + 1 end
    local ok, raw = pcall(proxy.getCpus)
    if not ok or type(raw) ~= "table" then
        return { ok = false, error = tostring(raw or "getCpus failed") }
    end
    local totalCpus, freeCpus = 0, 0
    local busyRefs = {}
    local freeList = {}
    local cpusOut = {}

    for i = 1, #raw do
        local c = raw[i]
        if type(c) == "table" and c.name and c.name ~= "" then
            totalCpus = totalCpus + 1
            local isBusy = (c.busy == true)
            if not isBusy then
                freeCpus = freeCpus + 1
                freeList[#freeList + 1] = {
                    name = c.name,
                    storage = math.floor(tonumber(c.storage or c.storages) or 0),
                    coprocessors = math.floor(tonumber(c.coprocessors) or 0),
                }
            end
            cpusOut[#cpusOut + 1] = {
                name = c.name,
                busy = isBusy,
                storage = math.floor(tonumber(c.storage or c.storages) or 0),
                coprocessors = math.floor(tonumber(c.coprocessors) or 0),
                outputLabel = nil,
                outputKey = nil,
                outputCount = 0,
            }
            if isBusy and c.cpu and c.cpu.finalOutput then
                busyRefs[#busyRefs + 1] = { idx = #cpusOut, name = c.name, cpu = c.cpu }
            end
        end
    end

    local snap = {
        ok = true,
        totalCpus = totalCpus,
        freeCpus = freeCpus,
        busyByKey = {},
        busyByLabel = {},
        freeList = freeList,
        cpus = cpusOut,
        _busyRefs = busyRefs,
        _outputsFetched = (#busyRefs == 0),
    }
    if opts and opts.fetchOutputs == true then
        Hardware.fetchBusyCpuOutputs(snap, counter)
    end
    return snap
end

function Hardware.fetchFluidStockMap(proxy, counter)
    if not proxy or type(proxy.getFluidsInNetwork) ~= "function" then
        return nil
    end
    if counter then counter.aeCalls = (counter.aeCalls or 0) + 1 end
    local ok, fl = pcall(proxy.getFluidsInNetwork)
    if not ok or type(fl) ~= "table" then
        return nil
    end
    local m = {}
    for i = 1, #fl do
        local f = fl[i]
        if type(f) == "table" and f.name then
            m[f.name] = (m[f.name] or 0) + math.floor(tonumber(f.amount or f.size) or 0)
        end
    end
    return { map = m }
end

function Hardware.queryRuleStock(proxy, rule, fluidFallbackRef, counter)
    if not proxy or not rule then return 0, false end
    local rType = (rule.type == "fluid") and "fluid" or "item"

    if rType == "fluid" then
        if fluidFallbackRef and fluidFallbackRef.map then
            return fluidFallbackRef.map[rule.name or ""] or 0, true
        end
        if type(proxy.getFluidInNetwork) == "function" and rule.name and rule.name ~= "" then
            if counter then counter.aeCalls = (counter.aeCalls or 0) + 1 end
            local ok, st = pcall(proxy.getFluidInNetwork, rule.name)
            if ok then
                if type(st) == "table" then
                    return math.floor(tonumber(st.amount or st.size) or 0), true
                end
                return 0, true
            end
        end
        if fluidFallbackRef then
            if not fluidFallbackRef.map then
                local fetched = Hardware.fetchFluidStockMap(proxy, counter)
                if fetched and fetched.map then
                    fluidFallbackRef.map = fetched.map
                end
            end
            if fluidFallbackRef.map then
                return fluidFallbackRef.map[rule.name or ""] or 0, true
            end
        end
        return 0, false
    end

    -- Item stock lookup: prefer O(1) getItemInNetwork
    local dmg = math.max(0, math.floor(tonumber(rule.damage) or 0))
    if type(proxy.getItemInNetwork) == "function" and rule.name and rule.name ~= "" then
        if rule.hasTag == true and type(rule.snbt) == "string" and rule.snbt ~= "" then
            if counter then counter.aeCalls = (counter.aeCalls or 0) + 1 end
            local ok, st = pcall(proxy.getItemInNetwork, rule.name, dmg, rule.snbt)
            if ok then
                if type(st) == "table" then
                    return math.floor(tonumber(st.size or st.amount) or 0), true
                end
                return 0, true
            end
        elseif rule.hasTag ~= true then
            -- Table-form avoids empty-NBT injection in NetworkControl.scala string form
            if counter then counter.aeCalls = (counter.aeCalls or 0) + 1 end
            local ok, st = pcall(proxy.getItemInNetwork, { name = rule.name, damage = dmg })
            if ok then
                if type(st) == "table" then
                    return math.floor(tonumber(st.size or st.amount) or 0), true
                end
                return 0, true
            end
        end
    end

    if type(proxy.getItemsInNetwork) == "function" and rule.name and rule.name ~= "" then
        if counter then counter.aeCalls = (counter.aeCalls or 0) + 1 end
        local ok, il = pcall(proxy.getItemsInNetwork, { name = rule.name, damage = dmg })
        if ok and type(il) == "table" then
            local qty = 0
            for i = 1, #il do
                local st = il[i]
                if type(st) == "table" and (not rule.label or rule.label == "" or st.label == rule.label) then
                    qty = qty + math.floor(tonumber(st.size or st.amount) or 0)
                end
            end
            return qty, true
        end
    end
    return 0, false
end

function Hardware.resolveCraftable(proxy, rule, counter, state)
    if not proxy or not rule then return nil, nil end
    local cType = (rule.type == "fluid") and "fluid" or "item"
    local hasTag = (rule.hasTag == true)
    local dmg = (cType == "item") and math.max(0, math.floor(tonumber(rule.damage) or 0)) or 0
    local ck = cType .. ":" .. tostring(rule.name or "") .. ":" .. tostring(dmg)
        .. (hasTag and (":" .. tostring(rule.label or "")) or "")

    if state and state._craftableCache and state._craftableCache[ck] then
        return state._craftableCache[ck], ck
    end

    local found = nil
    if type(proxy.getCraftable) == "function" and rule.name and rule.name ~= "" and (cType == "fluid" or not hasTag) then
        if counter then counter.aeCalls = (counter.aeCalls or 0) + 1 end
        local detail = { name = rule.name }
        if cType == "item" then
            detail.damage = dmg
        end
        local ok, res = pcall(proxy.getCraftable, detail, cType)
        if ok and res ~= nil then
            found = res
        end
    end

    if not found and type(proxy.getCraftables) == "function" then
        if counter then counter.aeCalls = (counter.aeCalls or 0) + 1 end
        local filter = {}
        if rule.label and rule.label ~= "" then filter.label = rule.label end
        if rule.name and rule.name ~= "" then filter.name = rule.name end
        if cType == "item" and rule.damage ~= nil then filter.damage = dmg end
        local ok, list = pcall(proxy.getCraftables, filter)
        if ok and type(list) == "table" and #list > 0 then
            for i = 1, #list do
                local c = list[i]
                local fn = c and (c.getStack or c.getItemStack)
                if type(fn) == "function" then
                    local okS, st = pcall(fn)
                    if okS and type(st) == "table" then
                        local stType = (st.maxSize == nil) and "fluid" or "item"
                        if stType == cType and (not rule.name or st.name == rule.name) and (not rule.label or st.label == rule.label) then
                            found = c
                            break
                        end
                    end
                end
            end
            if not found then
                found = list[1]
            end
        end
    end

    if found and state then
        state._craftableCache = state._craftableCache or {}
        state._craftableCache[ck] = found
    end
    return found, ck
end

function Hardware.selectCpuName(freeList, filterStr)
    if type(filterStr) ~= "string" or filterStr == "" or filterStr == "auto" then
        return nil
    end
    if type(freeList) ~= "table" or #freeList == 0 then
        return nil, "no matching free CPU (" .. filterStr .. ")"
    end
    local needle = filterStr:lower()
    local best = nil
    for i = 1, #freeList do
        local c = freeList[i]
        if c and type(c.name) == "string" and c.name:lower():find(needle, 1, true) then
            if not best or (c.storage or 0) < (best.storage or 0) then
                best = c
            end
        end
    end
    if best then return best.name end
    return nil, "CPU '" .. filterStr .. "' busy/missing"
end

function Hardware.requestCraft(proxy, rule, amount, prioritizePower, cpuName, counter, state)
    if not proxy then return { ok = false, error = "No AE2 connection" } end
    local craftable, ck = Hardware.resolveCraftable(proxy, rule, counter, state)
    if not craftable or type(craftable.request) ~= "function" then
        return { ok = false, error = "Pattern not found in AE2" }
    end
    local amt = math.max(1, math.floor(tonumber(amount) or 1))
    local prioPwr = (prioritizePower ~= false)
    local targetCpu = (type(cpuName) == "string" and cpuName ~= "" and cpuName ~= "auto") and cpuName or nil
    if counter then counter.aeCalls = (counter.aeCalls or 0) + 1 end
    local okReq, statusObj, reqErr = pcall(craftable.request, amt, prioPwr, targetCpu)
    if (not okReq or not statusObj) and state and state._craftableCache and ck and state._craftableCache[ck] then
        local errLower = tostring(reqErr or statusObj or ""):lower()
        if (not okReq) or errLower:find("no controller", 1, true) or errLower:find("invalid", 1, true) or errLower:find("broken", 1, true) then
            state._craftableCache[ck] = nil
            craftable, ck = Hardware.resolveCraftable(proxy, rule, counter, state)
            if craftable and type(craftable.request) == "function" then
                if counter then counter.aeCalls = (counter.aeCalls or 0) + 1 end
                okReq, statusObj, reqErr = pcall(craftable.request, amt, prioPwr, targetCpu)
            end
        end
    end
    if not okReq or not statusObj then
        return { ok = false, error = tostring(reqErr or statusObj or "request() failed") }
    end

    for _ = 1, 2 do
        if type(statusObj.isComputing) ~= "function" then break end
        local okC, comp = pcall(statusObj.isComputing)
        if not okC or comp ~= true then break end
        if os and os.sleep then pcall(os.sleep, 0.02) end
    end

    local stillComp = false
    if type(statusObj.isComputing) == "function" then
        local okC, comp = pcall(statusObj.isComputing)
        stillComp = okC and (comp == true)
    end
    if stillComp then
        return { ok = true, status = "computing", statusObj = statusObj }
    end

    if type(statusObj.hasFailed) == "function" then
        local okF, hasF, failWhy = pcall(statusObj.hasFailed)
        if okF and hasF == true then
            return { ok = false, error = tostring(failWhy or "Missing resources or CPU busy") }
        end
    end
    if type(statusObj.isCanceled) == "function" then
        local okCan, isC, cWhy = pcall(statusObj.isCanceled)
        if okCan and isC == true then
            return { ok = false, error = tostring(cWhy or "Craft canceled") }
        end
    end
    return { ok = true, status = "started", statusObj = statusObj }
end

function Hardware.pollPendingStatuses(pendingMap, counter)
    local out = { computing = {}, running = {}, done = {}, failed = {} }
    if type(pendingMap) ~= "table" then return out end
    for id, obj in pairs(pendingMap) do
        if type(obj) == "table" or type(obj) == "userdata" then
            local comp = false
            if type(obj.isComputing) == "function" then
                local okC, c = pcall(obj.isComputing)
                comp = okC and (c == true)
            end
            if comp then
                out.computing[id] = true
            else
                local failed, failWhy = false, nil
                if type(obj.hasFailed) == "function" then
                    local okF, f, why = pcall(obj.hasFailed)
                    if okF and f == true then
                        failed = true
                        failWhy = why or "Missing resources or CPU busy"
                    end
                end
                if not failed and type(obj.isCanceled) == "function" then
                    local okCan, c, cWhy = pcall(obj.isCanceled)
                    if okCan and c == true then
                        failed = true
                        failWhy = cWhy or "Craft canceled"
                    end
                end
                if failed then
                    out.failed[id] = tostring(failWhy)
                    pendingMap[id] = nil
                elseif type(obj.isDone) == "function" then
                    local okD, d = pcall(obj.isDone)
                    if okD and d == true then
                        out.done[id] = true
                        pendingMap[id] = nil
                    elseif okD then
                        out.running[id] = true
                    else
                        pendingMap[id] = nil
                    end
                else
                    pendingMap[id] = nil
                end
            end
        else
            pendingMap[id] = nil
        end
    end
    return out
end

function Hardware.readDropSlot(cfg, compLib, state)
    local cl = compLib or component
    local disc = (state and state.discovery) or Hardware.discover(cfg, cl, state)
    local tpAddr = cfg and cfg.dropTransposerAddr
    if not tpAddr or tpAddr == "auto" then
        tpAddr = disc and disc.transposers and disc.transposers[1]
        if not tpAddr then
            disc = Hardware.discover(cfg, cl, state)
            tpAddr = disc and disc.transposers and disc.transposers[1]
        end
    end
    if not tpAddr then
        return { found = false, hasTransposer = false, reason = "No Transposer attached" }
    end

    local sideOrder = {}
    local prefSide = tonumber(cfg and cfg.dropSide)
    if prefSide and prefSide >= 0 and prefSide <= 5 then
        sideOrder[1] = prefSide
    else
        sideOrder = { 1, 0, 2, 3, 4, 5 }
    end

    local foundStack, foundSide = nil, nil
    for _, side in ipairs(sideOrder) do
        local okSz, invSize = callSafe(tpAddr, "getInventorySize", cl, state, side)
        if okSz and tonumber(invSize) and tonumber(invSize) > 0 then
            for slot = 1, math.min(27, math.floor(tonumber(invSize))) do
                local okSt, st = callSafe(tpAddr, "getStackInSlot", cl, state, side, slot)
                if okSt and type(st) == "table" and st.name and st.name ~= "" then
                    foundStack, foundSide = st, side
                    break
                end
            end
            if foundStack then break end
            local okFl, fl = callSafe(tpAddr, "getFluidInTank", cl, state, side, 1)
            if okFl and type(fl) == "table" and fl.name and fl.name ~= "" then
                foundStack = {
                    _isFluidTank = true,
                    name = fl.name,
                    label = fl.label or fl.name,
                    amount = fl.amount or 0,
                }
                foundSide = side
                break
            end
        end
    end

    if not foundStack then
        return {
            found = false,
            hasTransposer = true,
            transposerAddr = tpAddr,
            reason = "Drop an item, AE2FC fluid drop, or tank next to Transposer",
        }
    end

    local entry
    if foundStack._isFluidTank then
        entry = {
            type = "fluid",
            name = foundStack.name,
            damage = 0,
            label = tostring(foundStack.label or foundStack.name),
            hasTag = false,
        }
    elseif foundStack.name == "ae2fc:fluid_drop" or foundStack.fluid ~= nil then
        local fl = type(foundStack.fluid) == "table" and foundStack.fluid or nil
        local rawLabel = tostring((fl and fl.label) or foundStack.label or foundStack.name):gsub("^drop of ", "")
        local flName = (fl and fl.name) or rawLabel:lower():gsub("%s+", "")
        -- Resolve exact fluid name from AE2 network if only label was on drop
        local ae = Hardware.getAeProxy(cfg, cl, state)
        if (not fl or not fl.name) and ae and type(ae.getFluidsInNetwork) == "function" then
            local okF, list = pcall(ae.getFluidsInNetwork)
            if okF and type(list) == "table" then
                for i = 1, #list do
                    local f = list[i]
                    if type(f) == "table" and f.label == rawLabel and f.name then
                        flName = f.name
                        break
                    end
                end
            end
        end
        entry = {
            type = "fluid",
            name = flName,
            damage = 0,
            label = rawLabel,
            hasTag = false,
        }
    else
        entry = {
            type = "item",
            name = foundStack.name,
            damage = math.max(0, math.floor(tonumber(foundStack.damage) or 0)),
            label = tostring(foundStack.label or foundStack.name),
            hasTag = (foundStack.hasTag == true),
        }
    end

    local ae = Hardware.getAeProxy(cfg, cl, state)
    local stock, known, craftable = 0, false, false
    if ae then
        stock, known = Hardware.queryRuleStock(ae, entry, {}, nil)
        craftable = Hardware.resolveCraftable(ae, entry, nil) ~= nil
    end

    entry.found = true
    entry.hasTransposer = true
    entry.transposerAddr = tpAddr
    entry.side = foundSide
    entry.stock = stock
    entry.stockKnown = known
    entry.craftable = craftable
    return entry
end

function Hardware.scanPhysicalMaintainers(compLib, state, cfg)
    local cl = compLib or component
    local slots = {}
    local addrs = {}
    if cl.list then
        for addr in cl.list("level_maintainer", true) do
            addrs[#addrs + 1] = addr
        end
    end
    table.sort(addrs)

    local needFluidResolve = false
    for _, addr in ipairs(addrs) do
        for sIdx = 1, 5 do
            local ok, info = callSafe(addr, "getSlot", cl, state, sIdx)
            if ok and type(info) == "table" then
                local isFl = (info.isFluid == true) or (info.name == "ae2fc:fluid_drop") or (info.fluid ~= nil)
                local fl = type(info.fluid) == "table" and info.fluid or nil
                local hasExactFluid = isFl and (fl ~= nil) and (type(fl.name) == "string") and (fl.name ~= "")
                local rawLbl = isFl
                    and tostring((fl and fl.label) or info.label or info.name or ""):gsub("^drop of ", "")
                    or tostring(info.label or info.name or "")
                local rawName = isFl
                    and ((hasExactFluid and fl.name) or rawLbl)
                    or tostring(info.name or "")
                if rawName ~= "" then
                    if isFl and not hasExactFluid then needFluidResolve = true end
                    slots[#slots + 1] = {
                        addr = addr,
                        slot = sIdx,
                        type = isFl and "fluid" or "item",
                        name = rawName,
                        damage = isFl and 0 or math.max(0, math.floor(tonumber(info.damage) or 0)),
                        label = rawLbl,
                        hasTag = (not isFl) and (info.hasTag == true) or false,
                        target = math.max(1, math.floor(tonumber(info.quantity) or 1)),
                        batch = math.max(1, math.floor(tonumber(info.batch) or 1)),
                        enabled = (info.isEnable == true),
                        done = (info.isDone == true),
                        _unresolvedFluid = (isFl and not hasExactFluid),
                    }
                end
            end
        end
    end
    if needFluidResolve then
        local ae = Hardware.getAeProxy(cfg, cl, state)
        if ae and type(ae.getFluidsInNetwork) == "function" then
            local okF, flList = pcall(ae.getFluidsInNetwork)
            if okF and type(flList) == "table" then
                local byLabel, byLower = {}, {}
                for i = 1, #flList do
                    local f = flList[i]
                    if type(f) == "table" and f.name and f.name ~= "" and f.label and f.label ~= "" then
                        byLabel[f.label] = byLabel[f.label] or f.name
                        byLower[f.label:lower()] = byLower[f.label:lower()] or f.name
                    end
                end
                for i = 1, #slots do
                    local s = slots[i]
                    if s._unresolvedFluid then
                        s.name = byLabel[s.label] or byLower[s.label:lower()] or s.name
                    end
                end
            end
        end
        for i = 1, #slots do slots[i]._unresolvedFluid = nil end
    end
    return slots, #addrs
end

function Hardware.disablePhysicalMaintainerSlot(addr, slotIdx, compLib, state)
    local cl = compLib or component
    local ok, res = callSafe(addr, "setEnable", cl, state, slotIdx, false)
    return ok and (res == true)
end

function Hardware.runBenchmark(cfg, state, compLib)
    local cl = compLib or component
    local ae, aeAddr = Hardware.getAeProxy(cfg, cl, state)
    local rules = (cfg and cfg.rules) or {}
    local sampleN = math.min(20, math.max(5, #rules))

    local gcFn = rawget(_G, "collectgarbage")
    local freeBefore = (computer and computer.freeMemory and computer.freeMemory()) or 0
    local totalMem = (computer and computer.totalMemory and computer.totalMemory()) or 0
    local luaKbBefore = (type(gcFn) == "function") and gcFn("count") or 0

    local o1Calls, o1Ms, legacyFluidMs, legacyItemMs, cpuMs = 0, 0, nil, nil, 0
    if ae then
        local t0 = clockNow()
        Hardware.inspectCpus(ae, nil)
        cpuMs = (clockNow() - t0) * 1000.0

        local t1 = clockNow()
        for i = 1, sampleN do
            local r = rules[i] or { type = (i % 3 == 0) and "fluid" or "item", name = "minecraft:iron_ingot", damage = 0 }
            Hardware.queryRuleStock(ae, r, {}, nil)
            o1Calls = o1Calls + 1
        end
        o1Ms = (clockNow() - t1) * 1000.0

        if type(ae.getFluidsInNetwork) == "function" then
            local tf0 = clockNow()
            pcall(ae.getFluidsInNetwork)
            legacyFluidMs = (clockNow() - tf0) * 1000.0
        end
        if type(ae.getItemsInNetwork) == "function" then
            local ti0 = clockNow()
            pcall(ae.getItemsInNetwork, { name = "minecraft:iron_ingot", damage = 0 })
            legacyItemMs = (clockNow() - ti0) * 1000.0
        end
    end

    local luaKbAfter = (type(gcFn) == "function") and gcFn("count")
        or math.max(0, (totalMem - freeBefore) / 1024)
    local physMaintCount = state and state.discovery and #(state.discovery.maintainers or {}) or 0
    local enabledCount = 0
    for i = 1, #rules do
        if rules[i] and rules[i].enabled ~= false and rules[i].mode ~= "off" then
            enabledCount = enabledCount + 1
        end
    end
    local equivBlocks = math.max(physMaintCount, math.ceil(math.max(1, enabledCount) / 5))

    local res = {
        at = clockNow(),
        aeBound = (ae ~= nil),
        aeAddr = aeAddr,
        hasO1Item = state and state.discovery and state.discovery.hasO1Item == true,
        hasO1Fluid = state and state.discovery and state.discovery.hasO1Fluid == true,
        hasO1Craftable = state and state.discovery and state.discovery.hasO1Craftable == true,
        sampleCalls = o1Calls,
        o1TotalMs = o1Ms,
        o1AvgMs = (o1Calls > 0) and (o1Ms / o1Calls) or 0,
        cpuMs = cpuMs,
        legacyFluidMs = legacyFluidMs,
        legacyItemFilterMs = legacyItemMs,
        luaHeapKB = luaKbAfter,
        freeMemKB = freeBefore / 1024,
        totalMemKB = totalMem / 1024,
        enabledRules = enabledCount,
        equivPhysicalBlocks = equivBlocks,
        equivChannelsSaved = equivBlocks,
        physicalConnected = physMaintCount,
    }
    if state then
        state.lastBenchmark = res
    end
    return res
end

Hardware.WAKE_MSG = "GTNH_WAKE"

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

local function getMeshTransports(compLib, state)
    local cl = compLib or component
    if state and (state._meshModem ~= nil or state._meshTunnel ~= nil) then
        return state._meshModem or nil, state._meshTunnel or nil, state._meshTunnelAddr
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
                configureMeshWake(m, Hardware.WAKE_MSG)
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
        configureMeshWake(tunnel, Hardware.WAKE_MSG)
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

local function makeCompactClaims(cfg, state)
    local dtpfPeer = state and state.dtpfPeer
    local mKeys = type(dtpfPeer) == "table" and type(dtpfPeer.maintKeys) == "table" and dtpfPeer.maintKeys or {}
    local pKeys = type(dtpfPeer) == "table" and type(dtpfPeer.passiveKeys) == "table" and dtpfPeer.passiveKeys or {}
    local prioEntries, restEntries = {}, {}
    local seen = {}
    for _, r in ipairs((cfg and cfg.rules) or {}) do
        if r and r.enabled ~= false and r.mode ~= "off" and r.name and r.name ~= "" then
            local tp = (r.type == "fluid") and "fluid" or "item"
            local dmg = (tp == "fluid") and 0 or math.floor(tonumber(r.damage) or 0)
            local ck = (tp == "fluid") and ("f:" .. r.name) or ("i:" .. r.name .. ":" .. tostring(dmg))
            if not seen[ck] then
                seen[ck] = true
                local fullKey = tp .. ":" .. r.name .. ":" .. tostring(dmg)
                if mKeys[fullKey] or pKeys[fullKey] then
                    prioEntries[#prioEntries + 1] = ck
                else
                    restEntries[#restEntries + 1] = ck
                end
            end
        end
    end
    local keys = {}
    for i = 1, #prioEntries do
        keys[#keys + 1] = prioEntries[i]
        if #keys >= 220 then break end
    end
    for i = 1, #restEntries do
        if #keys >= 220 then break end
        keys[#keys + 1] = restEntries[i]
    end
    return { armed = (cfg and cfg.armed == true), keys = keys }
end

function Hardware.pushMeshMetrics(cfg, state, nowSec, compLib, force)
    if cfg and cfg.extLinkMode == "off" then return false end
    local cl = compLib or component
    local modem, tunnel = getMeshTransports(cl, state)
    if not modem and not tunnel then return false end

    nowSec = nowSec or clockNow()
    local st = state or {}
    local kpis = st.kpis or {}
    local perf = st.perf or {}

    local digest = string.format("%s:%d:%d:%d:%d:%d",
        tostring(cfg and cfg.armed == true),
        kpis.enabled or 0, kpis.low or 0, kpis.crafting or 0, kpis.errors or 0, kpis.warnings or 0)
    if not force and digest == st._lastMeshDigest and (nowSec - (st._lastMeshAt or -100)) < 15 then
        return false
    end
    st._lastMeshAt = nowSec
    st._lastMeshDigest = digest

    -- Build compact top-20 preview using 4 priority buckets (avoids sorting full rule list)
    local rList = st.ruleStatuses or {}
    local bErr, bWarn, bAct, bOk = {}, {}, {}, {}
    for i = 1, #rList do
        local rs = rList[i]
        if rs.state == "ERR" then bErr[#bErr + 1] = rs
        elseif rs.warn then bWarn[#bWarn + 1] = rs
        elseif rs.state == "CRAFT" or rs.state == "LOW" then bAct[#bAct + 1] = rs
        else bOk[#bOk + 1] = rs
        end
    end
    local preview = {}
    for _, b in ipairs({ bErr, bWarn, bAct, bOk }) do
        local rem = 20 - #preview
        if rem <= 0 then break end
        if #b > 0 then
            if #b > rem then
                table.sort(b, function(x, y) return tostring(x.label or "") < tostring(y.label or "") end)
            end
            for i = 1, math.min(rem, #b) do
                local rs = b[i]
                preview[#preview + 1] = {
                    id = rs.id,
                    label = rs.label,
                    type = rs.type,
                    stock = rs.stock,
                    target = rs.target,
                    state = rs.state,
                    cpu = rs.cpu,
                    warn = rs.warn,
                    err = rs.error,
                }
            end
        end
    end

    local pkt = {
        armed = (cfg and cfg.armed == true),
        totalRules = kpis.total or 0,
        enabledRules = kpis.enabled or 0,
        okCount = kpis.ok or 0,
        lowCount = kpis.low or 0,
        craftingCount = kpis.crafting or 0,
        errorCount = kpis.errors or 0,
        warnCount = kpis.warnings or 0,
        freeCpus = kpis.freeCpus or 0,
        totalCpus = kpis.totalCpus or 0,
        freeReserve = tonumber(cfg and cfg.freeCpusReserve) or 2,
        dtpfPeerOnline = (st.dtpfPeer ~= nil and (nowSec - (st.dtpfPeer.lastSeen or -1000)) < 60),
        perf = {
            lastCycleMs = perf.lastCycleMs or 0,
            avgCycleMs = perf.avgCycleMs or 0,
            aeCallsPerSec = perf.aeCallsPerSec or 0,
            freeMemKB = perf.freeMemKB or 0,
            equivBlocksSaved = perf.equivBlocksSaved or 0,
            o1Mode = perf.o1Mode == true,
        },
        rulesPreview = preview,
    }
    local raw = serialization.serialize(pkt)
    if #raw > 5800 then
        pkt.rulesPreview = {}
        raw = serialization.serialize(pkt)
    end
    local viaTunnel = (st._mainnetMeshViaTunnel == true) or (not modem and tunnel ~= nil)
    sendMeshPacket(cl, st, st._mainnetMeshAddr, viaTunnel, "STOCK_METRICS", raw)

    local claimsTbl = makeCompactClaims(cfg, st)
    local claimsRaw = serialization.serialize(claimsTbl)
    while #claimsRaw > 5500 and #claimsTbl.keys > 0 do
        local keepN = math.max(0, #claimsTbl.keys - math.max(1, math.floor(#claimsTbl.keys * 0.2)))
        for i = #claimsTbl.keys, keepN + 1, -1 do claimsTbl.keys[i] = nil end
        claimsRaw = serialization.serialize(claimsTbl)
    end
    if force or claimsRaw ~= st._lastClaimsRaw or (nowSec - (st._lastClaimsAt or -100)) >= 15 then
        st._lastClaimsRaw = claimsRaw
        st._lastClaimsAt = nowSec
        if #claimsRaw <= 5500 then
            sendMeshPacket(cl, st, nil, viaTunnel, "STOCK_CLAIMS", claimsRaw)
        end
    end
    if st._lastMainnetSeen and (nowSec - st._lastMainnetSeen) >= 90 and (nowSec - (st._lastMainnetWakeAt or -1000)) >= 60 then
        st._lastMainnetWakeAt = nowSec
        sendMeshPacket(cl, st, st._mainnetMeshAddr, viaTunnel, Hardware.WAKE_MSG, "stock")
    end
    return true
end

local function keySetFromList(list)
    local out = {}
    if type(list) ~= "table" then return out end
    for i = 1, #list do
        local s = tostring(list[i] or "")
        if s ~= "" then out[s] = true end
    end
    return out
end

function Hardware.sendDtpfHandoff(cfg, state, items, compLib, opts)
    if cfg and cfg.extLinkMode == "off" then
        return false, "ExtLink is Standalone (OFF)"
    end
    if type(items) ~= "table" or #items == 0 then
        return false, "No items to hand off"
    end
    local cl = compLib or component
    local modem, tunnel = getMeshTransports(cl, state)
    if not modem and not tunnel then
        return false, "No Wireless Modem or Linked Card attached"
    end
    if state then
        state._handoffSeq = (state._handoffSeq or 0) + 1
    end
    local reqId = "dh" .. tostring((state and state._handoffSeq) or 1)
    local raw = serialization.serialize({
        items = items,
        remove = (opts and opts.remove == true),
    })
    if #raw > 5800 then
        return false, "Handoff batch too large (" .. tostring(#raw) .. " bytes)"
    end
    local dtpfAddr = (state and state.dtpfPeer and state.dtpfPeer.addr) or nil
    local viaTunnel = dtpfAddr and (state.dtpfPeer.viaTunnel == true) or ((state and state._mainnetMeshViaTunnel == true) or (not modem and tunnel ~= nil))
    local targetAddr = dtpfAddr or (state and state._mainnetMeshAddr) or nil
    local ok = sendMeshPacket(cl, state, targetAddr, viaTunnel, "DTPF_HANDOFF", reqId, raw)
    if ok then return true, reqId end
    return false, "Failed to transmit DTPF_HANDOFF"
end

function Hardware.handleMeshMessage(cfg, state, localAddr, sender, port, msgType, reqId, payload, compLib, rpcHandler)
    if cfg and cfg.extLinkMode == "off" then return false end
    local cl = compLib or component
    local _, tunnel, tAddr = getMeshTransports(cl, state)
    local isMeshPort = (port == Hardware.MESH_PORT) or (port == 0 and tunnel and tAddr and localAddr == tAddr)
    if not isMeshPort or not sender then return false end

    if msgType == "MESH_MAINNET_HELLO" or msgType == Hardware.WAKE_MSG then
        if state then
            state._mainnetMeshAddr = sender
            state._mainnetMeshViaTunnel = (port == 0)
            state._lastMainnetSeen = clockNow()
        end
        Hardware.pushMeshMetrics(cfg, state, clockNow(), cl, true)
        return true
    elseif msgType == "STOCK_ACK" then
        if state then
            state._mainnetMeshAddr = sender
            state._mainnetMeshViaTunnel = (port == 0)
            state._lastMainnetSeen = clockNow()
        end
        return true
    elseif msgType == "DTPF_CLAIMS" then
        local rawStr = (type(reqId) == "string" and reqId:sub(1, 1) == "{" and (payload == nil or payload == "")) and reqId or payload
        local okU, pkt = pcall(serialization.unserialize, tostring(rawStr or ""))
        if okU and type(pkt) == "table" and state then
            state.dtpfPeer = {
                addr = sender,
                viaTunnel = (port == 0),
                lastSeen = clockNow(),
                armed = (pkt.armed == true),
                maintEnabled = (pkt.maintEnabled == true),
                maintKeys = keySetFromList(pkt.maintKeys),
                passiveKeys = keySetFromList(pkt.passiveKeys),
                maintInfo = (type(pkt.maintInfo) == "table") and pkt.maintInfo or {},
                passiveInfo = (type(pkt.passiveInfo) == "table") and pkt.passiveInfo or {},
            }
            return true
        end
        return false
    elseif msgType == "DTPF_METRICS" then
        if state then
            if not state.dtpfPeer then
                state.dtpfPeer = { maintKeys = {}, passiveKeys = {} }
            end
            state.dtpfPeer.addr = sender
            state.dtpfPeer.lastSeen = clockNow()
        end
        return true
    elseif msgType == "STOCK_CMD" then
        if state then
            state._mainnetMeshAddr = sender
            state._mainnetMeshViaTunnel = (port == 0)
            state._lastMainnetSeen = clockNow()
        end
        local cmd = (type(payload) == "string") and serialization.unserialize(payload) or nil
        local resTbl
        if type(cmd) == "table" and type(rpcHandler) == "function" then
            resTbl = rpcHandler(cmd)
        else
            resTbl = { ok = false, error = "Invalid STOCK_CMD payload" }
        end
        local raw = serialization.serialize(resTbl)
        local CHUNK = 5500
        local total = math.max(1, math.ceil(#raw / CHUNK))
        local viaTunnel = (port == 0)
        for idx = 1, total do
            local slice = raw:sub((idx - 1) * CHUNK + 1, idx * CHUNK)
            sendMeshPacket(cl, state, sender, viaTunnel, "STOCK_REPLY", tostring(reqId or ""), idx, total, slice)
        end
        return true
    elseif msgType == "DTPF_HANDOFF_ACK" then
        local rawStr = (type(reqId) == "string" and reqId:sub(1, 1) == "{" and (payload == nil or payload == "")) and reqId or payload
        local okU, ack = pcall(serialization.unserialize, tostring(rawStr or ""))
        if okU and type(ack) == "table" then
            if state then
                state._lastHandoffAck = ack
            end
            if type(rpcHandler) == "function" then
                rpcHandler({ op = "_dtpf_handoff_ack", ack = ack })
            end
            return true
        end
        return false
    end
    return false
end

return Hardware
