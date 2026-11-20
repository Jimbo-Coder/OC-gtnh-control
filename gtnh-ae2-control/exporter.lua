local cliArgs = { ... }
package.path = package.path .. ";/home/?.lua"

local computer = require("computer")
local component = require("component")
local config = require("config")
local internet = require("internet")
local event = require("event")
local okSer, serialization = pcall(require, "serialization")
local okFs, filesystem = pcall(require, "filesystem")
local okTerm, term = pcall(require, "term")
local okUiMod, Ae2UI = pcall(require, "ae2_ui")

local forceHeadless = false
for i = 1, #cliArgs do
    local a = tostring(cliArgs[i] or "")
    if a == "--headless" or a == "headless" then
        forceHeadless = true
        break
    end
end

local OVERRIDES_PATH = "/home/config_overrides.lua"
local INTERVAL_KEYS = {
    "itemInterval", "fluidInterval", "essentiaInterval", "energyInterval",
    "energyAE2Interval", "cpuInterval", "tpsInterval", "allItemsInterval",
}
local TOGGLE_KEYS = {
    "enableItems", "enableFluids", "enableEssentia", "enableEnergy", "enableWireless",
    "enableEnergyAE2", "enableCpus", "enableTps", "detailedTps", "enableBridge",
    "enableMesh", "enableLogging", "enableDebug",
}

local baseConfigSnapshot = { toggles = {}, intervals = {}, exportPaused = (config.exportPaused == true) }
for _, k in ipairs(TOGGLE_KEYS) do
    baseConfigSnapshot.toggles[k] = (config[k] == true)
end
config._sec = type(config._sec) == "table" and config._sec or {}
for _, k in ipairs(INTERVAL_KEYS) do
    local ticks = tonumber(config[k]) or 0
    local sec = (config._sec[k] ~= nil) and tonumber(config._sec[k]) or math.floor((ticks / 72) + 0.5)
    config._sec[k] = sec
    baseConfigSnapshot.intervals[k] = ticks
end

local maxInt = 9223372036854775807
local AuthHeader = nil
local needExitFlag = false
local pendingSelfReboot = false
local lastItemScanSec = 0
local uiActive = false

local MESH_PORT = tonumber(config.meshPort) or 4205
local WAKE_MSG = "GTNH_WAKE"
local PUMP_STALE_SEC = 240
local PEER_STALE_SEC = 60
local dtpfMesh = { addr = nil, viaTunnel = false, lastSeen = -1000, status = nil, wasOnline = false, recoveryAttempts = 0, lastRecoveryAt = -1000 }
local pumpMesh = { addr = nil, viaTunnel = false, lastSeen = -1000, status = nil, statusUptime = -1000, wasOnline = false, recoveryAttempts = 0, lastRecoveryAt = -1000 }
local univMesh = { addr = nil, viaTunnel = false, lastSeen = -1000, status = nil, wasOnline = false, recoveryAttempts = 0, lastRecoveryAt = -1000 }
local gorgeMesh = { addr = nil, viaTunnel = false, lastSeen = -1000, status = nil, wasOnline = false, recoveryAttempts = 0, lastRecoveryAt = -1000 }
local stockMesh = { addr = nil, viaTunnel = false, lastSeen = -1000, status = nil, wasOnline = false, recoveryAttempts = 0, lastRecoveryAt = -1000 }
local pendingMaintJobs = {}
local meshReqSeq = 0
local lastWatchdogAt = -1000
local lastHealthInfluxAt = -1000

local hubState = {
    freeMem = 0,
    totalMem = 0,
    nowUptime = 0,
    bridgeConnected = false,
    meshModemOk = false,
    meshTunnelOk = false,
    lastScanDurSec = 0,
    lastItemsCount = 0,
    exporterPaused = (config.exportPaused == true),
    ae2 = { connected = false, avgInjection = 0, avgUsage = 0, maxStorage = 0, currStorage = 0, idleUsage = 0 },
    lsc = { online = false, pct = 0, net5s = 0, in5s = 0, out5s = 0, wirelessStr = "0", wirelessOn = true },
    tps = { online = false, mspt = 0, tps = 20, chunks = 0, dims = 0 },
    cpus = { list = {}, total = 0, busyCount = 0 },
    peers = { dtpf = dtpfMesh, pump = pumpMesh, univ = univMesh, gorge = gorgeMesh, stock = stockMesh },
    logs = {},
}

local function logMsg(tag, msg)
    local line = tostring(msg or "")
    local logs = hubState.logs
    logs[#logs + 1] = {
        t = (computer.uptime and computer.uptime()) or os.clock() or 0,
        tag = tag or "LOG",
        msg = line,
    }
    if #logs > 160 then
        table.remove(logs, 1)
    end
    if not uiActive and config.enableLogging then
        print(line)
    end
end

local function loadConfigOverrides()
    if not okSer or not io or not io.open then return end
    local okO, f = pcall(io.open, OVERRIDES_PATH, "r")
    if not okO or not f then return end
    local raw = f:read("*a")
    f:close()
    if type(raw) ~= "string" or raw == "" then return end
    local okU, ov = pcall(serialization.unserialize, raw)
    if not okU or type(ov) ~= "table" then return end
    if ov.exportPaused ~= nil then
        config.exportPaused = (ov.exportPaused == true)
        hubState.exporterPaused = config.exportPaused
    end
    if type(ov.toggles) == "table" then
        for _, k in ipairs(TOGGLE_KEYS) do
            if ov.toggles[k] ~= nil then
                config[k] = (ov.toggles[k] == true)
            end
        end
    end
    if type(ov.intervals) == "table" then
        for _, k in ipairs(INTERVAL_KEYS) do
            local sec = tonumber(ov.intervals[k])
            if sec and sec >= 1 then
                config._sec[k] = sec
                config[k] = sec * 72
            end
        end
    end
end

local function saveConfigOverrides()
    if not okSer or not io or not io.open then return false end
    local ov = {
        exportPaused = (config.exportPaused == true),
        toggles = {},
        intervals = {},
    }
    for _, k in ipairs(TOGGLE_KEYS) do
        ov.toggles[k] = (config[k] == true)
    end
    for _, k in ipairs(INTERVAL_KEYS) do
        ov.intervals[k] = tonumber(config._sec[k]) or math.floor(((tonumber(config[k]) or 0) / 72) + 0.5)
    end
    local okO, f = pcall(io.open, OVERRIDES_PATH, "w")
    if not okO or not f then return false end
    f:write(serialization.serialize(ov))
    f:close()
    return true
end

local function resetConfigOverrides()
    config.exportPaused = baseConfigSnapshot.exportPaused
    hubState.exporterPaused = config.exportPaused
    for _, k in ipairs(TOGGLE_KEYS) do
        config[k] = baseConfigSnapshot.toggles[k]
    end
    for _, k in ipairs(INTERVAL_KEYS) do
        local ticks = baseConfigSnapshot.intervals[k] or 0
        config[k] = ticks
        config._sec[k] = math.floor((ticks / 72) + 0.5)
    end
    if okFs and filesystem and filesystem.remove then
        pcall(filesystem.remove, OVERRIDES_PATH)
    elseif os and os.remove then
        pcall(os.remove, OVERRIDES_PATH)
    end
end

loadConfigOverrides()

local function uptimeNow()
    return (computer.uptime and computer.uptime()) or os.clock()
end

local function isMeshFresh(peer, maxAge)
    return peer and peer.addr ~= nil and (uptimeNow() - (peer.lastSeen or -1000)) < maxAge
end

local cachedMeshModem = nil
local cachedMeshTunnel = nil
local meshCacheInit = false

local function invalidateMeshCache()
    cachedMeshModem = nil
    cachedMeshTunnel = nil
    meshCacheInit = false
    hubState.meshModemOk = false
    hubState.meshTunnelOk = false
end

local function configureModemProxy(m)
    if not m then return end
    local needOpen = true
    if type(m.isOpen) == "function" then
        local okO, isO = pcall(m.isOpen, MESH_PORT)
        if okO and isO == true then needOpen = false end
    end
    if needOpen and m.open then pcall(m.open, MESH_PORT) end

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
            local okWk, curWk = pcall(m.getWakeMessage)
            if okWk and curWk == WAKE_MSG then needWake = false end
        end
        if needWake then pcall(m.setWakeMessage, WAKE_MSG, true) end
    end
    return isW
end

local function configureTunnelWake(t)
    if t and type(t.setWakeMessage) == "function" then
        local needWake = true
        if type(t.getWakeMessage) == "function" then
            local okWk, curWk = pcall(t.getWakeMessage)
            if okWk and curWk == WAKE_MSG then needWake = false end
        end
        if needWake then pcall(t.setWakeMessage, WAKE_MSG, true) end
    end
end

local function getMeshTransports()
    if config.enableMesh == false or not okSer then return nil, nil end
    if meshCacheInit then
        return cachedMeshModem, cachedMeshTunnel
    end
    local firstModem, wirelessModem = nil, nil
    if component.list then
        for addr in component.list("modem", true) do
            local m = component.proxy(addr)
            if m then
                local isW = configureModemProxy(m)
                if not firstModem then firstModem = m end
                if isW and not wirelessModem then wirelessModem = m end
            end
        end
    elseif component.isAvailable and component.isAvailable("modem") and component.modem then
        configureModemProxy(component.modem)
        firstModem = component.modem
    end
    local modem = wirelessModem or firstModem
    local tunnel = nil
    if component.isAvailable and component.isAvailable("tunnel") and component.tunnel then
        tunnel = component.tunnel
    elseif component.list then
        local tAddr = component.list("tunnel", true)()
        if tAddr then tunnel = component.proxy(tAddr) end
    end
    configureTunnelWake(tunnel)
    cachedMeshModem = modem
    cachedMeshTunnel = tunnel
    meshCacheInit = true
    hubState.meshModemOk = (modem ~= nil)
    hubState.meshTunnelOk = (tunnel ~= nil)
    return modem, tunnel
end

local function sendMeshPacket(targetAddr, viaTunnel, msgType, ...)
    local modem, tunnel = getMeshTransports()
    if viaTunnel and tunnel and tunnel.send then
        return pcall(tunnel.send, msgType, ...)
    elseif modem then
        if targetAddr and modem.send then
            return pcall(modem.send, targetAddr, MESH_PORT, msgType, ...)
        elseif modem.broadcast then
            return pcall(modem.broadcast, MESH_PORT, msgType, ...)
        end
    elseif tunnel and tunnel.send then
        return pcall(tunnel.send, msgType, ...)
    end
    return false
end

local function capInt(num)
    num = tonumber(num) or 0
    if num < 0 then return 0 end
    if num < maxInt then
        return math.floor(num)
    end
    return maxInt
end

local function capIntStr(numStr)
    local n = tonumber(numStr)
    if n == nil then return "0" end
    if n < 0 then return "0" end
    if n < maxInt then
        return string.format("%.0f", n)
    end
    return tostring(maxInt)
end

local function sanitize(s)
    s = tostring(s or "")
    s = string.gsub(s, "\\", "\\\\")
    s = string.gsub(s, " ", "\\ ")
    s = string.gsub(s, "=", "\\=")
    s = string.gsub(s, ",", "\\,")
    s = string.gsub(s, "\n", " ")
    return s
end

local function sanitizeFieldStr(s)
    s = tostring(s or "")
    s = string.gsub(s, "\\", "\\\\")
    s = string.gsub(s, "\"", "\\\"")
    s = string.gsub(s, "\n", " ")
    return s
end

local function stripColorCodes(s)
    if type(s) ~= "string" then return "" end
    -- Strip both UTF-8 section sign (§.) and Latin-1 section sign
    return (s:gsub("\194\167.", ""):gsub("\167.", ""))
end

local function essentiaName(label)
    for token in string.gmatch(tostring(label or ""), "[^%s]+") do
        return token
    end
    return tostring(label or "unknown")
end

-- Minimal JSON encoder/decoder (RFC 8259 subset sufficient for newline-delimited OC RPCs)
local json = {}

local ESCAPE_MAP = {
    ['"'] = '\\"',
    ['\\'] = '\\\\',
    ['\b'] = '\\b',
    ['\f'] = '\\f',
    ['\n'] = '\\n',
    ['\r'] = '\\r',
    ['\t'] = '\\t',
}

local function jsonEscape(s)
    return (s:gsub('[%z\1-\31"\\]', function(c)
        return ESCAPE_MAP[c] or string.format("\\u%04x", string.byte(c))
    end))
end

local function isArrayTable(t)
    local n = #t
    local count = 0
    for k in pairs(t) do
        if type(k) ~= "number" or k < 1 or k > n or math.floor(k) ~= k then
            return false
        end
        count = count + 1
    end
    return count == n
end

function json.encode(v)
    local tp = type(v)
    if v == nil then
        return "null"
    elseif tp == "boolean" then
        return v and "true" or "false"
    elseif tp == "number" then
        if v ~= v or v == math.huge or v == -math.huge then
            return "null"
        elseif math.floor(v) == v and math.abs(v) < 9e15 then
            return string.format("%.0f", v)
        else
            return string.format("%.14g", v)
        end
    elseif tp == "string" then
        return '"' .. jsonEscape(v) .. '"'
    elseif tp == "table" then
        local parts = {}
        if isArrayTable(v) then
            for i = 1, #v do
                parts[i] = json.encode(v[i])
            end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            for k, val in pairs(v) do
                if type(k) == "string" or type(k) == "number" then
                    parts[#parts + 1] = '"' .. jsonEscape(tostring(k)) .. '":' .. json.encode(val)
                end
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    else
        return '"' .. jsonEscape(tostring(v)) .. '"'
    end
end

function json.decode(str)
    if type(str) ~= "string" then return nil, "expected string" end
    local pos = 1
    local len = #str

    local function skipWs()
        while pos <= len do
            local b = str:byte(pos)
            if b == 32 or b == 9 or b == 10 or b == 13 then
                pos = pos + 1
            else
                break
            end
        end
    end

    local parseValue

    local function parseString()
        pos = pos + 1 -- skip opening quote
        local parts = {}
        while pos <= len do
            local c = str:sub(pos, pos)
            if c == '"' then
                pos = pos + 1
                return table.concat(parts)
            elseif c == "\\" then
                pos = pos + 1
                local esc = str:sub(pos, pos)
                pos = pos + 1
                if esc == '"' or esc == "\\" or esc == "/" then parts[#parts + 1] = esc
                elseif esc == "b" then parts[#parts + 1] = "\b"
                elseif esc == "f" then parts[#parts + 1] = "\f"
                elseif esc == "n" then parts[#parts + 1] = "\n"
                elseif esc == "r" then parts[#parts + 1] = "\r"
                elseif esc == "t" then parts[#parts + 1] = "\t"
                elseif esc == "u" then
                    local hex = str:sub(pos, pos + 3)
                    pos = pos + 4
                    local cp = tonumber(hex, 16)
                    if cp then parts[#parts + 1] = utf8.char(cp) end
                end
            else
                local nextQ = str:find('[\\"]', pos)
                if not nextQ then error("unterminated json string") end
                parts[#parts + 1] = str:sub(pos, nextQ - 1)
                pos = nextQ
            end
        end
        error("unterminated json string")
    end

    local function parseNumber()
        local s = str:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", pos)
        if not s or s == "" then error("invalid json number at " .. pos) end
        pos = pos + #s
        return tonumber(s)
    end

    local function parseArray()
        pos = pos + 1
        local arr = {}
        skipWs()
        if str:sub(pos, pos) == "]" then pos = pos + 1; return arr end
        while pos <= len do
            arr[#arr + 1] = parseValue()
            skipWs()
            local ch = str:sub(pos, pos)
            if ch == "," then pos = pos + 1
            elseif ch == "]" then pos = pos + 1; return arr
            else error("expected ',' or ']' at " .. pos)
            end
        end
        error("unterminated array")
    end

    local function parseObject()
        pos = pos + 1
        local obj = {}
        skipWs()
        if str:sub(pos, pos) == "}" then pos = pos + 1; return obj end
        while pos <= len do
            skipWs()
            if str:sub(pos, pos) ~= '"' then error("expected string key at " .. pos) end
            local k = parseString()
            skipWs()
            if str:sub(pos, pos) ~= ":" then error("expected ':' at " .. pos) end
            pos = pos + 1
            obj[k] = parseValue()
            skipWs()
            local ch = str:sub(pos, pos)
            if ch == "," then pos = pos + 1
            elseif ch == "}" then pos = pos + 1; return obj
            else error("expected ',' or '}' at " .. pos)
            end
        end
        error("unterminated object")
    end

    parseValue = function()
        skipWs()
        local ch = str:sub(pos, pos)
        if ch == '"' then return parseString()
        elseif ch == "{" then return parseObject()
        elseif ch == "[" then return parseArray()
        elseif str:sub(pos, pos + 3) == "true" then pos = pos + 4; return true
        elseif str:sub(pos, pos + 4) == "false" then pos = pos + 5; return false
        elseif str:sub(pos, pos + 3) == "null" then pos = pos + 4; return nil
        else return parseNumber()
        end
    end

    local ok, val = pcall(parseValue)
    if not ok then return nil, val end
    return val
end

local function postInflux(url, body)
    if config.exportPaused then return true end
    if not body or body == "" then return true end
    local ok, req = pcall(internet.request, url, body, AuthHeader)
    if not ok or not req then
        logMsg("ERR", "[Influx] Request error: " .. tostring(req))
        return false
    end
    local drainOk, err = pcall(function()
        if type(req) == "function" or (type(req) == "table" and getmetatable(req) and getmetatable(req).__call) then
            for _ in req do end
        end
        if type(req) == "table" and req.close then
            pcall(req.close)
        end
    end)
    if not drainOk then
        logMsg("ERR", "[Influx] Response error: " .. tostring(err))
    end
    return drainOk
end

local function flushBatch(dbUrl, lines)
    if #lines == 0 then return end
    if config.exportPaused then return end
    local payload = table.concat(lines, "\n") .. "\n"
    if config.enableDebug then
        logMsg("DBG", payload)
    end
    postInflux(dbUrl, payload)
end

-- Parse plain integer/float, commas, `2.42x10^21`, or GTNH SI suffixes (`1.23M`)
local SI_MULT = {
    k = 1e3, K = 1e3, M = 1e6, G = 1e9, T = 1e12, P = 1e15, E = 1e18, Z = 1e21, Y = 1e24
}

local function parseEuToken(raw)
    if type(raw) ~= "string" then return nil, nil, nil, nil end
    local clean = stripColorCodes(raw):gsub(",", ""):match("^%s*(.-)%s*$")
    if clean == "" then return nil, nil, nil, nil end

    -- 1. Scientific notation e.g. `2.42x10^21`
    local baseS, expS = clean:match("([%d%.]+)%s*[xX*]%s*10%^([%+%-]?%d+)")
    if baseS and expS then
        local f = tonumber(baseS .. "e" .. expS)
        return f, tonumber(baseS), tonumber(expS), nil
    end

    -- 2. Standard E notation e.g. `2.42e21`
    local eNum = clean:match("([%+%-]?%d+%.?%d*[eE][%+%-]?%d+)")
    if eNum then
        local b, ex = eNum:match("^([%+%-]?%d+%.?%d*)[eE]([%+%-]?%d+)$")
        return tonumber(eNum), tonumber(b), tonumber(ex), nil
    end

    -- 3. Number with optional SI suffix (`k/M/G/T/P/E`) followed by optional unit
    local numS, suf = clean:match("^([%+%-]?%d+%.?%d*)%s*([kKMGTPERYZ]?)")
    if numS and numS ~= "" then
        local f = tonumber(numS)
        local mult = (suf and suf ~= "" and SI_MULT[suf]) or 1
        local val = f and (f * mult) or nil
        local rawInt = (suf == "" or suf == nil) and numS:match("^%d+$") or nil
        return val, nil, nil, rawInt
    end

    return nil, nil, nil, nil
end

local function parseLscSensor(sensorData, lscProxy)
    local r = {
        exactStoredStr = nil,
        exactMaxStr = nil,
        currentF = nil,
        maxF = nil,
        fillPct = nil,
        passiveLoss = nil,
        inTick = nil,
        outTick = nil,
        input5s = nil,
        output5s = nil,
        input5m = nil,
        output5m = nil,
        input1h = nil,
        output1h = nil,
        wirelessEnabled = nil,
        exactWirelessStr = nil,
        wirelessF = nil,
        wirelessBase = nil,
        wirelessExp = nil,
    }

    if lscProxy then
        if lscProxy.getStoredEUString then
            local ok, s = pcall(lscProxy.getStoredEUString)
            if ok and type(s) == "string" and s:match("^%d+$") then
                r.exactStoredStr = s
                r.currentF = tonumber(s)
            end
        end
        if lscProxy.getEUCapacityString then
            local ok, s = pcall(lscProxy.getEUCapacityString)
            if ok and type(s) == "string" and s:match("^%d+$") then
                r.exactMaxStr = s
                r.maxF = tonumber(s)
            end
        end
    end

    if type(sensorData) == "table" then
        for i = 1, #sensorData do
            local rawLine = sensorData[i]
            if type(rawLine) == "string" then
                if rawLine:find("kekztech%.infodata%.", 1, false) then
                    if rawLine:find("wireless_mode.enabled", 1, true) then
                        r.wirelessEnabled = true
                    elseif rawLine:find("wireless_mode.disabled", 1, true) then
                        r.wirelessEnabled = false
                    else
                        -- Encoded GTNH 2.9 format: key\\arg1[\\arg2]
                        local key, rest = rawLine:match("^(.-)\\\\(.*)$")
                        if key and rest then
                            local arg1 = rest:match("^(.-)\\\\") or rest
                            local val, base, exp, exactInt = parseEuToken(arg1)
                            if key:find("eu_stored", 1, true) then
                                if exactInt and not r.exactStoredStr then r.exactStoredStr = exactInt end
                                if val and not r.currentF then r.currentF = val end
                            elseif key:find("total_capacity", 1, true) then
                                if exactInt and not r.exactMaxStr then r.exactMaxStr = exactInt end
                                if val and not r.maxF then r.maxF = val end
                            elseif key:find("used_capacity", 1, true) then
                                if val then r.fillPct = val end
                            elseif key:find("passive_loss", 1, true) then
                                if val then r.passiveLoss = val end
                            elseif key:find("lapotronic_super_capacitor.eu_in", 1, true) then
                                if val then r.inTick = val end
                            elseif key:find("lapotronic_super_capacitor.eu_out", 1, true) then
                                if val then r.outTick = val end
                            elseif key:find("avg_eu_in.sec", 1, true) then
                                if val then r.input5s = val end
                            elseif key:find("avg_eu_out.sec", 1, true) then
                                if val then r.output5s = val end
                            elseif key:find("avg_eu_in.min5", 1, true) then
                                if val then r.input5m = val end
                            elseif key:find("avg_eu_out.min5", 1, true) then
                                if val then r.output5m = val end
                            elseif key:find("avg_eu_in.hour1", 1, true) then
                                if val then r.input1h = val end
                            elseif key:find("avg_eu_out.hour1", 1, true) then
                                if val then r.output1h = val end
                            elseif key:find("wireless_eu", 1, true) then
                                if exactInt and not r.exactWirelessStr then r.exactWirelessStr = exactInt end
                                if base and exp then
                                    r.wirelessBase = base
                                    r.wirelessExp = exp
                                end
                                if val and not r.wirelessF then r.wirelessF = val end
                            end
                        end
                    end
                else
                    -- Localized / 2.8 English format
                    local clean = stripColorCodes(rawLine)
                    local tail = clean:match(":%s*(.+)$") or ""
                    local val, base, exp, exactInt = parseEuToken(tail)
                    if clean:find("^EU Stored:") then
                        if exactInt and not r.exactStoredStr then r.exactStoredStr = exactInt end
                        if val and not r.currentF then r.currentF = val end
                    elseif clean:find("^Total Capacity:") then
                        if exactInt and not r.exactMaxStr then r.exactMaxStr = exactInt end
                        if val and not r.maxF then r.maxF = val end
                    elseif clean:find("^Used Capacity:") then
                        if val then r.fillPct = val end
                    elseif clean:find("^Passive Loss:") then
                        if val then r.passiveLoss = val end
                    elseif clean:find("^EU IN:") then
                        if val then r.inTick = val end
                    elseif clean:find("^EU OUT:") then
                        if val then r.outTick = val end
                    elseif clean:find("^Avg EU IN:.*last %d+ seconds") then
                        if val then r.input5s = val end
                    elseif clean:find("^Avg EU OUT:.*last %d+ seconds") then
                        if val then r.output5s = val end
                    elseif clean:find("^Avg EU IN:.*5 minutes") then
                        if val then r.input5m = val end
                    elseif clean:find("^Avg EU OUT:.*5 minutes") then
                        if val then r.output5m = val end
                    elseif clean:find("^Avg EU IN:.*1 hour") then
                        if val then r.input1h = val end
                    elseif clean:find("^Avg EU OUT:.*1 hour") then
                        if val then r.output1h = val end
                    elseif clean:find("^Wireless mode:") then
                        r.wirelessEnabled = clean:find("enabled", 1, true) ~= nil
                    elseif clean:find("^Total wireless EU:") then
                        if exactInt and not r.exactWirelessStr then r.exactWirelessStr = exactInt end
                        if base and exp then
                            r.wirelessBase = base
                            r.wirelessExp = exp
                        end
                        if val and not r.wirelessF then r.wirelessF = val end
                    end
                end
            end
        end
    end

    if not r.fillPct and r.currentF and r.maxF and r.maxF > 0 then
        r.fillPct = (r.currentF / r.maxF) * 100.0
    end
    return r
end

local function exportItems(interface)
    local itemIter = interface.allItems()
    local lines = {}
    while true do
        local currItem = itemIter()
        if currItem == nil then break end
        if (currItem.size or 0) >= config.itemThreshold and currItem.label and currItem.label:find("^drop of") == nil then
            lines[#lines + 1] = config.itemMeasurement .. ",item=" .. sanitize(currItem.label) .. " amount=" .. capInt(currItem.size) .. "i"
            if #lines >= config.itemMaxExport then
                flushBatch(config.dbURL .. config.itemDB, lines)
                lines = {}
            end
        end
    end
    flushBatch(config.dbURL .. config.itemDB, lines)
end

local function exportItemsIds(interface, allItemIds)
    local lines = {}
    for id in pairs(allItemIds) do
        local currReturn = interface.getItemsInNetworkById({id})
        if currReturn then
            for _, item in pairs(currReturn) do
                if (item.size or 0) >= config.itemThreshold and item.label and item.label:find("^drop of") == nil then
                    lines[#lines + 1] = config.itemMeasurement .. ",item=" .. sanitize(item.label) .. " amount=" .. capInt(item.size) .. "i"
                    if #lines >= config.itemMaxExport then
                        flushBatch(config.dbURL .. config.itemDB, lines)
                        lines = {}
                    end
                end
            end
        end
    end
    flushBatch(config.dbURL .. config.itemDB, lines)
end

local function arrayOfRange(start, finish)
    local out = {}
    local idx = 1
    for curr = start, finish do
        out[idx] = curr
        idx = idx + 1
    end
    return out
end

local function exportItemsNumeric(interface, onStep)
    local tScan0 = os.time()
    local lines = {}
    local maxID = config.maxID
    local batchSize = config.batchSize
    local slowRange = config.slowRange
    local currID = 0
    local itemCount = 0
    while currID <= maxID do
        local range
        if (currID + batchSize < slowRange[1]) or (currID > slowRange[2]) then
            range = arrayOfRange(currID, currID + batchSize)
            currID = currID + batchSize
        elseif currID < slowRange[1] then
            range = arrayOfRange(currID, slowRange[1] - 1)
            currID = slowRange[1]
        else
            local slowBatchSize = config.slowBatchSize
            range = arrayOfRange(currID, currID + slowBatchSize)
            currID = currID + slowBatchSize
        end
        local ok, currReturn = pcall(interface.getItemsInNetworkById, range)
        if ok and currReturn then
            for _, item in pairs(currReturn) do
                itemCount = itemCount + 1
                if (item.size or 0) >= config.itemThreshold and item.label and item.label:find("^drop of") == nil then
                    lines[#lines + 1] = config.itemMeasurement .. ",item=" .. sanitize(item.label) .. " amount=" .. capInt(item.size) .. "i"
                    if #lines >= config.itemMaxExport then
                        flushBatch(config.dbURL .. config.itemDB, lines)
                        lines = {}
                    end
                end
            end
        end
        if onStep then
            onStep()
        end
    end
    flushBatch(config.dbURL .. config.itemDB, lines)
    lastItemScanSec = math.floor(((os.time() - tScan0) / 72) * 100 + 0.5) / 100
    hubState.lastScanDurSec = lastItemScanSec
    hubState.lastItemsCount = itemCount
end

local function exportItemsInfMem(interface)
    local itemList = interface.getItemsInNetwork()
    local lines = {}
    for _, item in pairs(itemList) do
        if (item.size or 0) >= config.itemThreshold and item.label and item.label:find("^drop of") == nil then
            lines[#lines + 1] = config.itemMeasurement .. ",item=" .. sanitize(item.label) .. " amount=" .. capInt(item.size) .. "i"
            if #lines >= config.itemMaxExport then
                flushBatch(config.dbURL .. config.itemDB, lines)
                lines = {}
            end
        end
    end
    flushBatch(config.dbURL .. config.itemDB, lines)
end

local function exportEssentia(interface)
    if not interface.getEssentiaInNetwork then return end
    local ok, essentiaList = pcall(interface.getEssentiaInNetwork)
    if not ok or type(essentiaList) ~= "table" then return end
    local lines = {}
    for _, ess in pairs(essentiaList) do
        if (ess.amount or 0) >= config.essentiaThreshold and ess.label then
            lines[#lines + 1] = config.essentiaMeasurement .. ",aspect=" .. sanitize(essentiaName(ess.label)) .. " amount=" .. capInt(ess.amount) .. "i"
        end
    end
    flushBatch(config.dbURL .. config.essentiaDB, lines)
end

local function exportFluids(interface)
    if not interface.getFluidsInNetwork then return end
    local ok, fluids = pcall(interface.getFluidsInNetwork)
    if not ok or type(fluids) ~= "table" then return end
    local lines = {}
    for _, fluid in pairs(fluids) do
        if (fluid.amount or 0) >= config.fluidThreshold and fluid.label then
            lines[#lines + 1] = config.fluidMeasurement .. ",fluid=" .. sanitize(fluid.label) .. " amount=" .. capInt(fluid.amount) .. "i"
        end
    end
    flushBatch(config.dbURL .. config.fluidDB, lines)
end

local function formatFloatField(v)
    if v == nil then return nil end
    return string.format("%.15g", v)
end

local function exportEnergy(lsc, lscProxy, skipPost)
    local sensorData = lsc and lsc.getSensorInformation and lsc.getSensorInformation() or {}
    local e = parseLscSensor(sensorData, lscProxy)

    local i5s = e.input5s or 0
    local o5s = e.output5s or 0
    local i5m = e.input5m or 0
    local o5m = e.output5m or 0
    local i1h = e.input1h or 0
    local o1h = e.output1h or 0
    local wStr = e.exactWirelessStr or (e.wirelessF and string.format("%.0f", e.wirelessF)) or "0"

    hubState.lsc = {
        online = (e.fillPct ~= nil or e.currentF ~= nil or e.input5s ~= nil or e.wirelessF ~= nil or e.exactWirelessStr ~= nil),
        pct = tonumber(e.fillPct) or 0,
        in5s = i5s,
        out5s = o5s,
        net5s = i5s - o5s,
        wirelessStr = wStr,
        wirelessOn = (e.wirelessEnabled ~= false),
    }

    if skipPost or not config.enableEnergy then return end

    local fields = {}
    local function addField(k, v)
        if v ~= nil then fields[#fields + 1] = k .. "=" .. v end
    end

    if e.exactStoredStr then
        addField("currentf", e.exactStoredStr)
    elseif e.currentF then
        addField("currentf", formatFloatField(e.currentF))
    end
    if e.exactMaxStr then
        addField("maxf", e.exactMaxStr)
    elseif e.maxF then
        addField("maxf", formatFloatField(e.maxF))
    end
    if e.fillPct then
        addField("fill_pct", string.format("%.4f", e.fillPct))
    end
    if e.passiveLoss then
        addField("passive_loss", formatFloatField(e.passiveLoss))
    end

    -- Legacy integer fields must keep `i` suffix so InfluxDB v1 shard types stay consistent
    addField("input5s", capIntStr(i5s) .. "i")
    addField("output5s", capIntStr(o5s) .. "i")
    addField("input5m", capIntStr(i5m) .. "i")
    addField("output5m", capIntStr(o5m) .. "i")
    addField("input1h", capIntStr(i1h) .. "i")
    addField("output1h", capIntStr(o1h) .. "i")

    -- Unclamped float flow + computed net fields
    if e.inTick then addField("in_tick", formatFloatField(e.inTick)) end
    if e.outTick then addField("out_tick", formatFloatField(e.outTick)) end
    if e.inTick and e.outTick then addField("net_tick", formatFloatField(e.inTick - e.outTick)) end
    if e.input5s ~= nil then addField("in_5s", formatFloatField(i5s)) end
    if e.output5s ~= nil then addField("out_5s", formatFloatField(o5s)) end
    if e.input5s ~= nil and e.output5s ~= nil then addField("net_5s", formatFloatField(i5s - o5s)) end
    if e.input5m ~= nil then addField("in_5m", formatFloatField(i5m)) end
    if e.output5m ~= nil then addField("out_5m", formatFloatField(o5m)) end
    if e.input5m ~= nil and e.output5m ~= nil then addField("net_5m", formatFloatField(i5m - o5m)) end
    if e.input1h ~= nil then addField("in_1h", formatFloatField(i1h)) end
    if e.output1h ~= nil then addField("out_1h", formatFloatField(o1h)) end
    if e.input1h ~= nil and e.output1h ~= nil then addField("net_1h", formatFloatField(i1h - o1h)) end

    if config.enableWireless then
        local wFloat = e.exactWirelessStr or formatFloatField(e.wirelessF or 0)
        local wBase = e.wirelessBase or 0
        local wExp = e.wirelessExp or 0
        addField("wirelesseu", '"' .. sanitizeFieldStr(wStr) .. '"')
        addField("wirelessbase", formatFloatField(wBase))
        addField("wirelessexp", capInt(wExp) .. "i")
        addField("wirelessf", wFloat)
        if e.wirelessEnabled ~= nil then
            addField("wireless_on", e.wirelessEnabled and "true" or "false")
        end
    end

    if #fields == 0 then return end
    local postString = config.energyMeasurement .. " " .. table.concat(fields, ",") .. "\n"
    if config.enableDebug then
        logMsg("DBG", postString)
    end
    postInflux(config.dbURL .. config.energyDB, postString)
end

local function refreshCpuHubState(interface)
    if not interface or not interface.getCpus then return nil end
    local ok, cpus = pcall(interface.getCpus)
    if not ok or type(cpus) ~= "table" then return nil end
    local list = {}
    local busyCount = 0
    local lines = {}
    for _, cpu in pairs(cpus) do
        if cpu.name and #cpu.name > 0 then
            local craftingItem = "N/A"
            local craftingCount = 0
            if cpu.cpu and cpu.cpu.finalOutput then
                local okOut, output = pcall(cpu.cpu.finalOutput)
                if okOut and type(output) == "table" and output.label then
                    craftingItem = tostring(output.label)
                    craftingCount = capInt(output.size or output.amount or 0)
                end
            end
            local isBusy = (cpu.busy == true)
            if isBusy then busyCount = busyCount + 1 end
            list[#list + 1] = {
                name = cpu.name,
                storage = math.floor(tonumber(cpu.storage or 0) or 0),
                coprocessors = math.floor(tonumber(cpu.coprocessors or 0) or 0),
                busy = isBusy,
                craftingItem = craftingItem,
                craftingCount = craftingCount,
            }
            lines[#lines + 1] = string.format(
                '%s,cpuname=%s storage=%di,coprocessors=%di,busy=%s,craftingItem="%s",craftingCount=%di',
                config.cpuMeasurement,
                sanitize(cpu.name),
                capInt(cpu.storage or 0),
                capInt(cpu.coprocessors or 0),
                tostring(isBusy),
                sanitizeFieldStr(craftingItem),
                craftingCount
            )
        end
    end
    table.sort(list, function(a, b)
        if a.busy ~= b.busy then return a.busy end
        return tostring(a.name) < tostring(b.name)
    end)
    hubState.cpus = { list = list, total = #list, busyCount = busyCount }
    return lines
end

local function exportCpus(interface, skipPost)
    local lines = refreshCpuHubState(interface)
    if not lines or skipPost or not config.enableCpus then return end
    flushBatch(config.dbURL .. config.cpuDB, lines)
end

local function updateItemIds(arr, interface)
    local itemIter = interface.allItems()
    while true do
        local currItem = itemIter()
        if currItem == nil then break end
        if (currItem.size or 0) >= config.itemThreshold and currItem.label and currItem.label:find("^drop of") == nil and currItem.name then
            arr[currItem.name] = true
        end
    end
end

local function exportEnergyAE2(interface, skipPost)
    if not interface or not interface.getAvgPowerUsage then return end
    local divisor = config.energyAE2ExportAsEU and 2 or 1
    local avgInjection = (interface.getAvgPowerInjection() or 0) / divisor
    local avgUsage = (interface.getAvgPowerUsage() or 0) / divisor
    local maxStorage = (interface.getMaxStoredPower() or 0) / divisor
    local currStorage = (interface.getStoredPower() or 0) / divisor
    local idleUsage = (interface.getIdlePowerUsage() or 0) / divisor
    hubState.ae2 = {
        connected = true,
        avgInjection = avgInjection,
        avgUsage = avgUsage,
        maxStorage = maxStorage,
        currStorage = currStorage,
        idleUsage = idleUsage,
    }
    if skipPost or not config.enableEnergyAE2 then return end
    local postString = string.format(
        "%s injection=%s,usage=%s,max=%s,curr=%s,idle=%s\n",
        config.energyAE2Measurement,
        formatFloatField(avgInjection),
        formatFloatField(avgUsage),
        formatFloatField(maxStorage),
        formatFloatField(currStorage),
        formatFloatField(idleUsage)
    )
    if config.enableDebug then
        logMsg("DBG", postString)
    end
    postInflux(config.dbURL .. config.energyAE2DB, postString)
end

local function exportTps(tpsCard, skipPost)
    if not tpsCard or not tpsCard.getOverallTickTime then return end
    local overallMspt = tpsCard.getOverallTickTime()
    local overallChunks = tpsCard.getOverallChunksLoaded()
    local overallDims = tpsCard.getOverallDimsLoaded()
    local tpsVal = math.min(20.0, 1000.0 / math.max(50.0, tonumber(overallMspt) or 50.0))
    hubState.tps = {
        online = true,
        mspt = tonumber(overallMspt) or 0,
        tps = tpsVal,
        chunks = tonumber(overallChunks) or 0,
        dims = tonumber(overallDims) or 0,
    }
    if skipPost or not config.enableTps then return end
    local lines = {
        string.format('%s,dimension="overall" mspt=%s,chunks=%s,dims=%s',
            config.tpsMeasurement, formatFloatField(overallMspt), formatFloatField(overallChunks), formatFloatField(overallDims))
    }
    if config.detailedTps then
        local allTickTimes = tpsCard.getAllTickTimes()
        if type(allTickTimes) == "table" then
            for id, ms in pairs(allTickTimes) do
                lines[#lines + 1] = string.format('%s,dimension="%s" mspt=%s',
                    config.tpsMeasurement, sanitizeFieldStr(tostring(id)), formatFloatField(ms))
            end
        end
    end
    flushBatch(config.dbURL .. config.tpsDB, lines)
end

-- Select Mainnet AE2 endpoint deterministically: prefer me_controller, else interface with most CPUs/fluids
local function findMainnetAE2()
    local best, bestScore = nil, -1
    local candidates = {}
    for addr, ctype in component.list("me_controller", true) do
        candidates[#candidates + 1] = { addr = addr, ctype = ctype, bonus = 1000000 }
    end
    for addr, ctype in component.list("me_interface", true) do
        candidates[#candidates + 1] = { addr = addr, ctype = ctype, bonus = 0 }
    end
    for addr, ctype in component.list("fluid_interface", true) do
        candidates[#candidates + 1] = { addr = addr, ctype = ctype, bonus = 0 }
    end
    for _, cand in ipairs(candidates) do
        local p = component.proxy(cand.addr)
        if p and p.getCpus then
            local okC, cpus = pcall(p.getCpus)
            local nCpus = (okC and type(cpus) == "table") and #cpus or 0
            local nFluids = 0
            if #candidates > 1 and p.getFluidsInNetwork then
                local okF, fl = pcall(p.getFluidsInNetwork)
                if okF and type(fl) == "table" then nFluids = #fl end
            end
            local score = cand.bonus + nCpus * 1000 + nFluids
            if score > bestScore then
                bestScore = score
                best = p
            end
        end
    end
    return best
end

-- Remote AE2 Bridge helpers (invoked ONLY on incoming TCP command from Mac mini)
local function summarizeStacks(arr, limit)
    local out = {}
    local totalSize = 0
    local typeCount = 0
    if type(arr) ~= "table" then return out, 0, 0 end
    local maxShow = limit or 12
    for i = 1, #arr do
        local s = arr[i]
        if type(s) == "table" then
            local sz = math.floor(tonumber(s.size or s.amount or 0) or 0)
            totalSize = totalSize + sz
            typeCount = typeCount + 1
            if #out < maxShow then
                out[#out + 1] = {
                    label = s.label or s.name or "Unknown",
                    size = sz,
                    name = s.name,
                }
            end
        end
    end
    return out, totalSize, typeCount
end

local function collectCpusSnapshot(interface)
    local ok, raw = pcall(interface.getCpus)
    if not ok or type(raw) ~= "table" then
        return nil, tostring(raw)
    end
    local out = {}
    for _, cpu in ipairs(raw) do
        if cpu.name and #cpu.name > 0 then
            local entry = {
                name = cpu.name,
                storage = math.floor(tonumber(cpu.storage or 0) or 0),
                coprocessors = math.floor(tonumber(cpu.coprocessors or 0) or 0),
                busy = (cpu.busy == true),
            }
            if entry.busy and cpu.cpu then
                if cpu.cpu.isActive then
                    local okIsAct, isAct = pcall(cpu.cpu.isActive)
                    if okIsAct then entry.isActive = (isAct == true) end
                end
                local okOut, fin = pcall(cpu.cpu.finalOutput)
                if okOut and type(fin) == "table" and fin.label then
                    entry.finalOutput = {
                        label = fin.label,
                        name = fin.name,
                        size = math.floor(tonumber(fin.size or fin.amount or 0) or 0),
                    }
                end
                if cpu.cpu.activeItems then
                    local okAct, act = pcall(cpu.cpu.activeItems)
                    if okAct then
                        entry.active, entry.activeTotal, entry.activeTypes = summarizeStacks(act, 10)
                    end
                end
                if cpu.cpu.pendingItems then
                    local okPend, pend = pcall(cpu.cpu.pendingItems)
                    if okPend then
                        entry.pending, entry.pendingTotal, entry.pendingTypes = summarizeStacks(pend, 10)
                    end
                end
                if cpu.cpu.storedItems then
                    local okSto, sto = pcall(cpu.cpu.storedItems)
                    if okSto then
                        entry.stored, entry.storedTotal, entry.storedTypes = summarizeStacks(sto, 6)
                    end
                end
            end
            out[#out + 1] = entry
        end
    end
    return out
end

local function resolveCraftable(interface, cmd)
    local cType = (cmd.type == "fluid") and "fluid" or "item"
    local hasTag = (cmd.hasTag == true)

    -- Fast O(1) lookup for fluids and non-NBT items
    if interface.getCraftable and cmd.name and (cType == "fluid" or not hasTag) then
        local detail = { name = cmd.name }
        if cType == "item" then
            detail.damage = tonumber(cmd.damage) or 0
        end
        local ok, res = pcall(interface.getCraftable, detail, cType)
        if ok and res ~= nil then
            return res
        end
    end

    -- Fallback for NBT-tagged items or label-only lookup
    local filter = {}
    if cmd.label and cmd.label ~= "" then filter.label = cmd.label end
    if cmd.name and cmd.name ~= "" then filter.name = cmd.name end
    if cType == "item" and cmd.damage ~= nil then filter.damage = tonumber(cmd.damage) end

    local okL, list = pcall(interface.getCraftables, filter)
    if not okL or type(list) ~= "table" or #list == 0 then
        return nil
    end
    for i = 1, #list do
        local c = list[i]
        local okS, st = pcall(c.getStack)
        if okS and type(st) == "table" then
            local stType = (st.maxSize == nil) and "fluid" or "item"
            if stType == cType and (not cmd.name or st.name == cmd.name) and (not cmd.label or st.label == cmd.label) then
                return c
            end
        end
    end
    return list[1]
end

local function inspectMainnetForMaint(interface, itemsReq)
    if not interface then
        return { ok = false, error = "No AE2 interface connected" }
    end
    local okC, cpusRaw = pcall(interface.getCpus)
    if not okC or type(cpusRaw) ~= "table" then
        return { ok = false, error = "getCpus failed" }
    end
    local totalCpus, freeCpus = 0, 0
    local busyByKey, busyByLabel = {}, {}
    for i = 1, #cpusRaw do
        local cpu = cpusRaw[i]
        if type(cpu) == "table" and cpu.name and cpu.name ~= "" then
            totalCpus = totalCpus + 1
            if cpu.busy == true then
                if cpu.cpu and cpu.cpu.finalOutput then
                    local okF, fin = pcall(cpu.cpu.finalOutput)
                    if okF and type(fin) == "table" then
                        if fin.label and fin.label ~= "" then
                            busyByLabel[fin.label] = busyByLabel[fin.label] or cpu.name
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
    local fluidAmt = nil
    local function getFluidFallback()
        if fluidAmt then return fluidAmt end
        fluidAmt = {}
        if interface.getFluidsInNetwork then
            local okFl, fl = pcall(interface.getFluidsInNetwork)
            if okFl and type(fl) == "table" then
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
    for i = 1, #reqs do
        local req = reqs[i]
        if type(req) == "table" and req.id then
            local qty = 0
            if req.type == "fluid" then
                if interface.getFluidInNetwork and req.name and req.name ~= "" then
                    local okFl, st = pcall(interface.getFluidInNetwork, req.name)
                    if okFl and type(st) == "table" then
                        qty = math.floor(tonumber(st.amount or st.size) or 0)
                    end
                else
                    qty = getFluidFallback()[req.name or ""] or 0
                end
            elseif req.name and req.name ~= "" then
                local dmg = tonumber(req.damage) or 0
                if interface.getItemInNetwork and req.hasTag ~= true then
                    local okIt, st = pcall(interface.getItemInNetwork, { name = req.name, damage = dmg })
                    if okIt and type(st) == "table" then
                        qty = math.floor(tonumber(st.size or st.amount) or 0)
                    end
                elseif interface.getItemsInNetwork then
                    local okIl, il = pcall(interface.getItemsInNetwork, { name = req.name, damage = dmg })
                    if okIl and type(il) == "table" then
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
    for k, obj in pairs(pendingMaintJobs) do
        if obj and obj.isComputing then
            local okCmp, comp = pcall(obj.isComputing)
            if not okCmp or comp ~= true then
                pendingMaintJobs[k] = nil
                if obj.hasFailed then
                    local okFail, hasF, failWhy = pcall(obj.hasFailed)
                    if okFail and hasF == true then
                        failed[k] = tostring(failWhy or "Missing resources or CPU busy")
                    end
                end
            end
        else
            pendingMaintJobs[k] = nil
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

local function formatPeerBrief(name, tbl)
    local st = tbl and tbl.status
    if type(st) ~= "table" then
        return (tbl and (tbl.lastSeen or -1000) > 0) and "Connected" or "Standby"
    end
    if name == "dtpf" then
        local units = type(st.units) == "table" and st.units or {}
        local onN, minD = 0, nil
        for i = 1, #units do
            local u = units[i]
            if type(u) == "table" and u.online and u.enabled ~= false then
                onN = onN + 1
                local d = tonumber(u.discountPct) or 0
                if not minD or d < minD then minD = d end
            end
        end
        return string.format("%s · %d/%d%s", st.armed and "ARM" or "OFF", onN, #units,
            minD and string.format(" · %.0f%%", minD) or "")
    elseif name == "stock" then
        local errN = tonumber(st.errorCount) or 0
        local lowN = tonumber(st.lowCount) or 0
        local enN = tonumber(st.enabledRules) or 0
        if errN > 0 then
            return string.format("%s · %dr · %d err", st.armed and "ARM" or "OFF", enN, errN)
        elseif lowN > 0 then
            return string.format("%s · %dr · %d low", st.armed and "ARM" or "OFF", enN, lowN)
        end
        return string.format("%s · %dr · ok", st.armed and "ARM" or "OFF", enN)
    elseif name == "pump" then
        local pumps = type(st.pumps) == "table" and st.pumps or {}
        local act = 0
        for _, p in ipairs(pumps) do if type(p) == "table" and p.active then act = act + 1 end end
        local low = 0
        local thr = tonumber(st.threshold) or 0.95
        for _, fl in pairs(type(st.fluids) == "table" and st.fluids or {}) do
            if type(fl) == "table" and (tonumber(fl.target) or 0) > 0 then
                local tot = tonumber(fl.total) or ((tonumber(fl.meAmount) or 0) + (tonumber(fl.queued) or 0))
                if tot < thr * tonumber(fl.target) then low = low + 1 end
            end
        end
        return (act > 0) and string.format("%d/%d on · %d low", act, #pumps, low)
            or string.format("%s · %d low", tostring(st.state or "idle"), low)
    elseif name == "gorge" then
        return string.format("%s · %d ex · %.0f%%", st.armed and "ARM" or "OFF",
            tonumber(st.activeCount) or 0, tonumber(st.lscPct) or 0)
    elseif name == "univ" then
        return string.format("%s · %dp · %dq", st.armed and "ARM" or "OFF",
            tonumber(st.activePools) or 0, tonumber(st.queuedSlices) or 0)
    end
    return "Online"
end

local function buildMeshHealth(now)
    now = now or uptimeNow()
    local specs = {
        dtpf = { tbl = dtpfMesh, stale = PEER_STALE_SEC },
        stock = { tbl = stockMesh, stale = PEER_STALE_SEC },
        pump = { tbl = pumpMesh, stale = PUMP_STALE_SEC },
        gorge = { tbl = gorgeMesh, stale = PEER_STALE_SEC },
        univ = { tbl = univMesh, stale = PEER_STALE_SEC },
    }
    local out = {}
    for k, sp in pairs(specs) do
        local p = sp.tbl
        local seen = (p.lastSeen or -1000) > 0
        out[k] = {
            online = isMeshFresh(p, sp.stale),
            seen = seen,
            ageSec = seen and math.max(0, math.floor((now - p.lastSeen) + 0.5)) or nil,
            recoveries = math.floor(tonumber(p.recoveryAttempts) or 0),
            brief = formatPeerBrief(k, p),
        }
    end
    return out
end

local function emitMeshHelloIfOnline(writeLineFn)
    if writeLineFn and json and json.encode then
        local now = uptimeNow()
        pcall(writeLineFn, json.encode({
            op = "mesh_hello",
            meshDtpf = isMeshFresh(dtpfMesh, PEER_STALE_SEC),
            meshPump = isMeshFresh(pumpMesh, PUMP_STALE_SEC),
            meshUniv = isMeshFresh(univMesh, PEER_STALE_SEC),
            meshGorge = isMeshFresh(gorgeMesh, PEER_STALE_SEC),
            meshStock = isMeshFresh(stockMesh, PEER_STALE_SEC),
            meshHealth = buildMeshHealth(now),
        }))
    end
end

local function checkMeshWatchdog(upNow, dbUrl, writeLineFn)
    if config.enableMesh == false or not okSer then return end
    local peers = {
        { name = "dtpf", tbl = dtpfMesh, stale = PEER_STALE_SEC },
        { name = "stock", tbl = stockMesh, stale = PEER_STALE_SEC },
        { name = "pump", tbl = pumpMesh, stale = PUMP_STALE_SEC },
        { name = "gorge", tbl = gorgeMesh, stale = PEER_STALE_SEC },
        { name = "univ", tbl = univMesh, stale = PEER_STALE_SEC },
    }
    local changed = false
    local onlinePeers, totalRecoveries = 0, 0
    local flags = {}
    for i = 1, #peers do
        local p = peers[i]
        local t = p.tbl
        local online = isMeshFresh(t, p.stale)
        flags[p.name] = online and 1 or 0
        if online then onlinePeers = onlinePeers + 1 end
        totalRecoveries = totalRecoveries + (tonumber(t.recoveryAttempts) or 0)
        if online ~= (t.wasOnline == true) then
            t.wasOnline = online
            changed = true
            if online and (t.recoveryAttempts or 0) > 0 then
                logMsg("MESH", string.format("[WATCHDOG] %s recovered after %d wake attempt(s).", p.name, t.recoveryAttempts))
            elseif (not online) and (t.lastSeen or -1000) > 0 then
                logMsg("ERR", string.format("[WATCHDOG] %s heartbeat stale (>%ds).", p.name, p.stale))
            end
        end
        if (not online) and (t.lastSeen or -1000) > 0 and (upNow - (t.lastRecoveryAt or -1000)) >= 60 then
            t.recoveryAttempts = (t.recoveryAttempts or 0) + 1
            totalRecoveries = totalRecoveries + 1
            t.lastRecoveryAt = upNow
            changed = true
            sendMeshPacket(t.addr, t.viaTunnel, WAKE_MSG, p.name)
            sendMeshPacket(nil, false, "MESH_MAINNET_HELLO", "watchdog")
            logMsg("ERR", string.format("[WATCHDOG] Sent %s + HELLO to stale peer %s (#%d).", WAKE_MSG, p.name, t.recoveryAttempts))
        end
    end
    if changed then
        emitMeshHelloIfOnline(writeLineFn)
        uiDirty = true
    end
    if dbUrl and (changed or (upNow - lastHealthInfluxAt) >= 30) then
        lastHealthInfluxAt = upNow
        local freeKB = math.floor((computer.freeMemory and computer.freeMemory() or 0) / 1024)
        local line = string.format(
            "oc_health ae2_ok=1i,dtpf_ok=%di,stock_ok=%di,pump_ok=%di,gorge_ok=%di,univ_ok=%di,online_peers=%di,recoveries=%di,free_mem_kb=%di",
            flags.dtpf or 0, flags.stock or 0, flags.pump or 0, flags.gorge or 0, flags.univ or 0,
            onlinePeers, totalRecoveries, freeKB
        )
        postInflux(dbUrl, line .. "\n")
    end
end

local function handleMeshModemEvent(interface, writeLineFn, localAddr, sender, port, msgType, arg1, arg2)
    if not sender or config.enableMesh == false or not okSer then return false end
    local modem, tunnel = getMeshTransports()
    local isTunnel = (port == 0 and tunnel ~= nil)
    if port ~= MESH_PORT and not isTunnel then return false end
    local now = uptimeNow()
    local dbUrl = config.dbURL .. (config.itemDB or "mainnet")

    if msgType == WAKE_MSG then
        sendMeshPacket(sender, isTunnel, "MESH_MAINNET_HELLO", "wake_ack")
        return true
    elseif msgType == "PUMP_STATUS" and type(arg1) == "string" then
        local okU, st = pcall(serialization.unserialize, arg1)
        if not okU or type(st) ~= "table" then return true end
        local wasFresh = isMeshFresh(pumpMesh, PUMP_STALE_SEC)
        pumpMesh.addr = sender
        pumpMesh.viaTunnel = isTunnel
        pumpMesh.lastSeen = now
        pumpMesh.status = st
        pumpMesh.statusUptime = now
        sendMeshPacket(sender, isTunnel, "PUMP_ACK", "ok")
        if not wasFresh then
            logMsg("MESH", "Space Pump Array connected on OC Mesh.")
            emitMeshHelloIfOnline(writeLineFn)
        end

        local pumpsActive, pumpsTotal, totalMult = 0, 0, 0
        for _, p in ipairs(type(st.pumps) == "table" and st.pumps or {}) do
            if type(p) == "table" then
                pumpsTotal = pumpsTotal + 1
                if p.active then pumpsActive = pumpsActive + 1 end
                totalMult = totalMult + math.floor(tonumber(p.mult) or 0)
            end
        end
        local fluidsOk, fluidsLow = 0, 0
        local thresh = tonumber(st.threshold) or 0.95
        for _, fl in pairs(type(st.fluids) == "table" and st.fluids or {}) do
            if type(fl) == "table" and (tonumber(fl.target) or 0) > 0 then
                local eff = tonumber(fl.total) or ((tonumber(fl.meAmount) or 0) + (tonumber(fl.queued) or 0))
                if eff < (thresh * tonumber(fl.target)) then
                    fluidsLow = fluidsLow + 1
                else
                    fluidsOk = fluidsOk + 1
                end
            end
        end
        local line = string.format(
            "space_pump pumps_active=%di,pumps_total=%di,fluids_ok=%di,fluids_low=%di,total_mult=%di",
            pumpsActive, pumpsTotal, fluidsOk, fluidsLow, totalMult
        )
        postInflux(dbUrl, line .. "\n")
        return true

    elseif msgType == "DTPF_METRICS" and type(arg1) == "string" then
        local okU, pkt = pcall(serialization.unserialize, arg1)
        if not okU or type(pkt) ~= "table" then return true end
        local wasFresh = isMeshFresh(dtpfMesh, 60)
        dtpfMesh.addr = sender
        dtpfMesh.viaTunnel = isTunnel
        dtpfMesh.lastSeen = now
        dtpfMesh.status = pkt
        sendMeshPacket(sender, isTunnel, "DTPF_ACK", "ok")
        if not wasFresh then
            logMsg("MESH", "DTPF Fleet connected on OC Mesh.")
            emitMeshHelloIfOnline(writeLineFn)
        end

        local units = type(pkt.units) == "table" and pkt.units or {}
        local onlineN, activeN, convN = 0, 0, 0
        local minDisc, sumDisc, onlineDiscN = nil, 0, 0
        for i = 1, #units do
            local u = units[i]
            if type(u) == "table" then
                if u.online and u.enabled ~= false then
                    onlineN = onlineN + 1
                    local d = tonumber(u.discountPct) or 0
                    sumDisc = sumDisc + d
                    onlineDiscN = onlineDiscN + 1
                    if not minDisc or d < minDisc then minDisc = d end
                end
                if u.active then activeN = activeN + 1 end
                if u.wantConv then convN = convN + 1 end
            end
        end
        local avgDisc = (onlineDiscN > 0) and (sumDisc / onlineDiscN) or 0
        local lines = {}
        lines[1] = string.format(
            "dtpf_fleet armed=%di,online=%di,active=%di,conv_active=%di,od_active=%di,min_discount=%.2f,avg_discount=%.2f,dtr_stock=%si,direct_eut=%.1f,cat_eut=%.1f,total_eut=%.1f",
            pkt.armed and 1 or 0, onlineN, activeN, convN, pkt.odActive and 1 or 0,
            minDisc or 0, avgDisc, tostring(capInt(pkt.dtrStock)),
            tonumber(pkt.directEut) or 0, tonumber(pkt.catEut) or 0, tonumber(pkt.totalEut) or 0
        )
        for i = 1, #units do
            local u = units[i]
            if type(u) == "table" then
                local dEut = tonumber(u.directEut) or 0
                local cEut = tonumber(u.catEut) or 0
                local tEut = dEut + cEut
                local mEu = tonumber(u.maxInputEu) or 0
                local extra = ""
                if mEu > 0 then
                    extra = extra .. string.format(",max_eut=%.1f", mEu)
                end
                if type(u.hatchLabel) == "string" and u.hatchLabel ~= "" then
                    extra = extra .. ',hatch="' .. sanitizeFieldStr(u.hatchLabel) .. '"'
                end
                lines[#lines + 1] = string.format(
                    'dtpf_unit,unit=%s online=%di,active=%di,conv=%di,discount=%.2f,coil_heat=%si,recipe="%s",eut=%.1f,direct_eut=%.1f,cat_eut=%.1f%s',
                    sanitize(u.name or ("DTPF #" .. i)),
                    u.online and 1 or 0, u.active and 1 or 0, u.wantConv and 1 or 0,
                    tonumber(u.discountPct) or 0, tostring(capInt(u.coilHeat)),
                    sanitizeFieldStr(u.familyId or "idle"), tEut, dEut, cEut, extra
                )
            end
        end
        flushBatch(dbUrl, lines)
        return true

    elseif msgType == "UNIV_METRICS" and type(arg1) == "string" then
        local okU, pkt = pcall(serialization.unserialize, arg1)
        if not okU or type(pkt) ~= "table" then return true end
        local wasFresh = isMeshFresh(univMesh, 60)
        univMesh.addr = sender
        univMesh.viaTunnel = isTunnel
        univMesh.lastSeen = now
        univMesh.status = pkt
        sendMeshPacket(sender, isTunnel, "UNIV_ACK", "ok")
        if not wasFresh then
            logMsg("MESH", "Universal RS Controller connected on OC Mesh.")
            emitMeshHelloIfOnline(writeLineFn)
        end
        local line = string.format(
            "universal_control armed=%di,active_pools=%di,queued=%di,stalled=%di,completed=%di,preemptions=%di",
            pkt.armed and 1 or 0, math.floor(tonumber(pkt.activePools) or 0),
            math.floor(tonumber(pkt.queuedSlices) or 0), math.floor(tonumber(pkt.stalledCount) or 0),
            math.floor(tonumber(pkt.completedBatches) or 0), math.floor(tonumber(pkt.preemptions) or 0)
        )
        postInflux(dbUrl, line .. "\n")
        return true

    elseif msgType == "GORGE_METRICS" and type(arg1) == "string" then
        local okU, pkt = pcall(serialization.unserialize, arg1)
        if not okU or type(pkt) ~= "table" then return true end
        local wasFresh = isMeshFresh(gorgeMesh, 60)
        gorgeMesh.addr = sender
        gorgeMesh.viaTunnel = isTunnel
        gorgeMesh.lastSeen = now
        gorgeMesh.status = pkt
        sendMeshPacket(sender, isTunnel, "GORGE_ACK", "ok")
        if not wasFresh then
            logMsg("MESH", "Gorge & Exoticizer Rack connected on OC Mesh.")
            emitMeshHelloIfOnline(writeLineFn)
        end
        local gf = type(pkt.godforge) == "table" and pkt.godforge or {}
        local lscExtra = (pkt.lscPct ~= nil) and string.format(",lsc_pct=%.2f", tonumber(pkt.lscPct) or 0) or ""
        local line = string.format(
            "godforge_control armed=%di,active_exoticizers=%di,completed_cycles=%di,errors=%di,gf_online=%di,gf_active=%di,gf_work_allowed=%di,gf_rings=%di,gf_connected=%di,gf_upgrades=%di%s",
            pkt.armed and 1 or 0,
            math.floor(tonumber(pkt.activeCount) or 0),
            math.floor(tonumber(pkt.completedCycles) or 0),
            math.floor(tonumber(pkt.errorCount) or 0),
            gf.online and 1 or 0,
            gf.active and 1 or 0,
            (gf.workAllowed ~= false) and 1 or 0,
            math.floor(tonumber(gf.rings) or 0),
            math.floor(tonumber(gf.connected) or 0),
            math.floor(tonumber(gf.upgrades) or 0),
            lscExtra
        )
        postInflux(dbUrl, line .. "\n")
        return true

    elseif msgType == "STOCK_METRICS" and type(arg1) == "string" then
        local okU, pkt = pcall(serialization.unserialize, arg1)
        if not okU or type(pkt) ~= "table" then return true end
        local wasFresh = isMeshFresh(stockMesh, 60)
        stockMesh.addr = sender
        stockMesh.viaTunnel = isTunnel
        stockMesh.lastSeen = now
        stockMesh.status = pkt
        sendMeshPacket(sender, isTunnel, "STOCK_ACK", "ok")
        if not wasFresh then
            logMsg("MESH", "Stock Maintainer connected on OC Mesh.")
            emitMeshHelloIfOnline(writeLineFn)
        end
        local pf = type(pkt.perf) == "table" and pkt.perf or {}
        local line = string.format(
            "stock_maintainer armed=%di,total_rules=%di,enabled_rules=%di,ok_count=%di,low_count=%di,crafting_count=%di,error_count=%di,warn_count=%di,cycle_ms=%.2f,ae_calls_s=%.2f,blocks_saved=%di",
            pkt.armed and 1 or 0,
            math.floor(tonumber(pkt.totalRules) or 0),
            math.floor(tonumber(pkt.enabledRules) or 0),
            math.floor(tonumber(pkt.okCount) or 0),
            math.floor(tonumber(pkt.lowCount) or 0),
            math.floor(tonumber(pkt.craftingCount) or 0),
            math.floor(tonumber(pkt.errorCount) or 0),
            math.floor(tonumber(pkt.warnCount) or 0),
            tonumber(pf.lastCycleMs) or 0,
            tonumber(pf.aeCallsPerSec) or 0,
            math.floor(tonumber(pf.equivBlocksSaved) or 0)
        )
        postInflux(dbUrl, line .. "\n")
        return true

    elseif msgType == "STOCK_CLAIMS" and type(arg1) == "string" then
        if dtpfMesh.addr and (sender ~= dtpfMesh.addr or isTunnel ~= dtpfMesh.viaTunnel) then
            sendMeshPacket(dtpfMesh.addr, dtpfMesh.viaTunnel, "STOCK_CLAIMS", arg1)
        end
        return true

    elseif msgType == "DTPF_CLAIMS" and type(arg1) == "string" then
        if stockMesh.addr and (sender ~= stockMesh.addr or isTunnel ~= stockMesh.viaTunnel) then
            sendMeshPacket(stockMesh.addr, stockMesh.viaTunnel, "DTPF_CLAIMS", arg1)
        end
        return true

    elseif msgType == "DTPF_HANDOFF" and type(arg1) == "string" then
        if dtpfMesh.addr and (sender ~= dtpfMesh.addr or isTunnel ~= dtpfMesh.viaTunnel) then
            sendMeshPacket(dtpfMesh.addr, dtpfMesh.viaTunnel, "DTPF_HANDOFF", arg1, arg2)
        end
        return true

    elseif msgType == "DTPF_HANDOFF_ACK" and type(arg1) == "string" then
        if stockMesh.addr and (sender ~= stockMesh.addr or isTunnel ~= stockMesh.viaTunnel) then
            sendMeshPacket(stockMesh.addr, stockMesh.viaTunnel, "DTPF_HANDOFF_ACK", arg1, arg2)
        end
        return true

    elseif msgType == "MESH_MAINT_SYNC" then
        local wasFresh = isMeshFresh(dtpfMesh, 60)
        dtpfMesh.addr = sender
        dtpfMesh.viaTunnel = isTunnel
        dtpfMesh.lastSeen = now
        if not wasFresh then emitMeshHelloIfOnline(writeLineFn) end
        local okU, req = pcall(serialization.unserialize, tostring(arg2 or ""))
        local res = inspectMainnetForMaint(interface, okU and type(req) == "table" and req.items or {})
        sendMeshPacket(sender, isTunnel, "MESH_MAINT_ACK", tostring(arg1 or ""), serialization.serialize(res))
        return true

    elseif msgType == "MESH_CRAFT" then
        local wasFresh = isMeshFresh(dtpfMesh, 60)
        dtpfMesh.addr = sender
        dtpfMesh.viaTunnel = isTunnel
        dtpfMesh.lastSeen = now
        if not wasFresh then emitMeshHelloIfOnline(writeLineFn) end
        local okU, req = pcall(serialization.unserialize, tostring(arg2 or ""))
        local res
        if not okU or type(req) ~= "table" then
            res = { ok = false, error = "Invalid MESH_CRAFT payload" }
        elseif not interface then
            res = { ok = false, error = "No AE2 interface connected" }
        else
            local craftCmd = {
                name = req.name,
                damage = tonumber(req.damage) or 0,
                label = req.label,
                type = req.type or "item",
                hasTag = (req.hasTag == true),
            }
            local craftable = resolveCraftable(interface, craftCmd)
            if not craftable or not craftable.request then
                res = { ok = false, error = "Pattern not found in Mainnet AE2" }
            else
                local amt = math.max(1, math.floor(tonumber(req.amount) or 1))
                local okReq, statusObj, reqErr = pcall(craftable.request, amt, true, nil)
                if not okReq or not statusObj then
                    res = { ok = false, error = tostring(reqErr or statusObj or "request() failed") }
                else
                    for _ = 1, 2 do
                        if not statusObj.isComputing then break end
                        local okC, cmp = pcall(statusObj.isComputing)
                        if not okC or cmp ~= true then break end
                        pcall(os.sleep, 0.05)
                    end
                    local stillComp = false
                    if statusObj.isComputing then
                        local okC, cRes = pcall(statusObj.isComputing)
                        stillComp = okC and (cRes == true)
                    end
                    if stillComp then
                        if req.id then pendingMaintJobs[req.id] = statusObj end
                        res = { ok = true, status = "computing" }
                    else
                        local failed, failReason = false, nil
                        if statusObj.hasFailed then
                            local okF, fRes, fWhy = pcall(statusObj.hasFailed)
                            if okF and fRes then
                                failed = true
                                failReason = fWhy
                            end
                        end
                        if failed then
                            res = { ok = false, error = tostring(failReason or "Missing resources or CPU busy") }
                        else
                            res = { ok = true, status = "started" }
                        end
                    end
                end
            end
        end
        sendMeshPacket(sender, isTunnel, "MESH_CRAFT_ACK", tostring(arg1 or ""), serialization.serialize(res))
        return true
    end
    return false
end

local function callMeshRpc(interface, writeLineFn, peer, msgType, payloadTbl, replyType, timeoutSec)
    if config.enableMesh == false or not okSer then
        return { ok = false, error = "OC mesh disabled or serialization missing" }
    end
    local modem, tunnel = getMeshTransports()
    if not modem and not tunnel then
        return { ok = false, error = "No Wireless Modem or Linked Card in Mainnet OC" }
    end
    meshReqSeq = meshReqSeq + 1
    local reqId = "m" .. tostring(meshReqSeq)
    local raw = serialization.serialize(payloadTbl or {})
    local okSend = sendMeshPacket(peer and peer.addr, peer and peer.viaTunnel, msgType, reqId, raw)
    if not okSend then
        return { ok = false, error = "Failed to send OC mesh packet" }
    end

    local deadline = uptimeNow() + (timeoutSec or 5.0)
    local slices, expectedTotal, gotSlices = {}, nil, 0
    while uptimeNow() < deadline do
        local waitSec = math.min(0.25, math.max(0.05, deadline - uptimeNow()))
        local evName, lAddr, sAddr, port, _, mType, a1, a2, a3, a4 = event.pull(waitSec)
        if evName == "interrupted" or (evName == "key_up" and sAddr == 113) then
            needExitFlag = true
            break
        elseif evName == "modem_message" then
            local isTunnel = (port == 0 and tunnel ~= nil)
            if (port == MESH_PORT or isTunnel) and mType == replyType and tostring(a1) == reqId then
                if peer then
                    local freshWindow = (replyType == "PUMP_REPLY") and 180 or 60
                    local wasFresh = isMeshFresh(peer, freshWindow)
                    peer.addr = sAddr
                    peer.viaTunnel = isTunnel
                    peer.lastSeen = uptimeNow()
                    if not wasFresh then
                        emitMeshHelloIfOnline(writeLineFn)
                    end
                end
                if replyType == "DTPF_REPLY" or replyType == "STOCK_REPLY" then
                    local idx = tonumber(a2) or 1
                    local total = tonumber(a3) or 1
                    if not slices[idx] then gotSlices = gotSlices + 1 end
                    slices[idx] = tostring(a4 or "")
                    expectedTotal = total
                    if gotSlices >= expectedTotal then
                        local okU, tbl = pcall(serialization.unserialize, table.concat(slices, "", 1, expectedTotal))
                        if okU and type(tbl) == "table" then return tbl end
                        return { ok = false, error = "Failed to decode " .. tostring(replyType) }
                    end
                else
                    local okU, tbl = pcall(serialization.unserialize, tostring(a2 or ""))
                    if okU and type(tbl) == "table" then return tbl end
                    return { ok = false, error = "Failed to decode " .. tostring(replyType) }
                end
            else
                handleMeshModemEvent(interface, writeLineFn, lAddr, sAddr, port, mType, a1, a2)
            end
        end
    end
    return { ok = false, error = "OC mesh RPC timeout (" .. tostring(msgType) .. ")" }
end

local function handleBridgeCommand(sockWriteLine, interface, cmd)
    local cmdId = cmd.id
    local op = cmd.op

    local function reply(tbl)
        tbl.id = cmdId
        return sockWriteLine(json.encode(tbl))
    end

    if op == "ping" then
        return reply({
            ok = true,
            freeMem = computer.freeMemory and computer.freeMemory() or 0,
            totalMem = computer.totalMemory and computer.totalMemory() or 0,
            uptime = computer.uptime and computer.uptime() or 0,
            lastItemScanSec = lastItemScanSec,
            meshDtpf = isMeshFresh(dtpfMesh, 60),
            meshPump = isMeshFresh(pumpMesh, 180),
            meshUniv = isMeshFresh(univMesh, 60),
            meshGorge = isMeshFresh(gorgeMesh, 60),
            meshStock = isMeshFresh(stockMesh, 60),
        })
    elseif op == "cpus" then
        if not interface then
            return reply({ ok = false, error = "No AE2 interface connected" })
        end
        local cpus, err = collectCpusSnapshot(interface)
        if not cpus then
            return reply({ ok = false, error = err or "failed to read CPUs" })
        end
        return reply({
            ok = true,
            cpus = cpus,
            freeMem = computer.freeMemory and computer.freeMemory() or 0,
            totalMem = computer.totalMemory and computer.totalMemory() or 0,
            lastItemScanSec = lastItemScanSec,
            meshDtpf = isMeshFresh(dtpfMesh, 60),
            meshPump = isMeshFresh(pumpMesh, 180),
            meshUniv = isMeshFresh(univMesh, 60),
            meshGorge = isMeshFresh(gorgeMesh, 60),
            meshStock = isMeshFresh(stockMesh, 60),
        })
    elseif op == "item_stocks" then
        if not interface then
            return reply({ ok = false, error = "No AE2 interface connected" })
        end
        local reqList = type(cmd.items) == "table" and cmd.items or {}
        local fluidByLabel = nil
        local function getFluidByLabel()
            if fluidByLabel then return fluidByLabel end
            fluidByLabel = {}
            if interface.getFluidsInNetwork then
                local okF, fl = pcall(interface.getFluidsInNetwork)
                if okF and type(fl) == "table" then
                    for _, f in ipairs(fl) do
                        if type(f) == "table" and f.label then
                            fluidByLabel[f.label] = (fluidByLabel[f.label] or 0) + math.floor(tonumber(f.amount or f.size or 0) or 0)
                        end
                    end
                end
            end
            return fluidByLabel
        end
        local out = {}
        for i = 1, math.min(#reqList, 16) do
            local reqIt = reqList[i]
            if type(reqIt) == "table" then
                local qty = 0
                local rType = (reqIt.type == "fluid") and "fluid" or "item"
                if rType == "fluid" then
                    if interface.getFluidInNetwork and reqIt.name and reqIt.name ~= "" then
                        local okF, st = pcall(interface.getFluidInNetwork, reqIt.name)
                        if okF and type(st) == "table" then
                            qty = math.floor(tonumber(st.amount or st.size or 0) or 0)
                        end
                    else
                        qty = getFluidByLabel()[reqIt.label or ""] or 0
                    end
                elseif reqIt.name and reqIt.name ~= "" then
                    local dmg = tonumber(reqIt.damage) or 0
                    if interface.getItemInNetwork and reqIt.hasTag ~= true then
                        local okI, st = pcall(interface.getItemInNetwork, { name = reqIt.name, damage = dmg })
                        if okI and type(st) == "table" then
                            qty = math.floor(tonumber(st.size or st.amount or 0) or 0)
                        end
                    elseif interface.getItemsInNetwork then
                        local okI, list = pcall(interface.getItemsInNetwork, { name = reqIt.name, damage = dmg })
                        if okI and type(list) == "table" then
                            for _, st in ipairs(list) do
                                if type(st) == "table" and (not reqIt.label or reqIt.label == "" or st.label == reqIt.label) then
                                    qty = qty + math.floor(tonumber(st.size or 0) or 0)
                                end
                            end
                        end
                    end
                end
                out[#out + 1] = {
                    name = reqIt.name or "",
                    damage = tonumber(reqIt.damage) or 0,
                    label = reqIt.label or "",
                    type = rType,
                    stock = qty,
                }
            end
        end
        return reply({ ok = true, stocks = out })
    elseif op == "craftables" then
        if not interface then
            return reply({ ok = false, error = "No AE2 interface connected" })
        end
        local batch = {}
        local totalCount = 0
        local function pushCraftableEntry(entry)
            totalCount = totalCount + 1
            batch[#batch + 1] = entry
            if #batch >= 300 then
                sockWriteLine(json.encode({ id = cmdId, op = "craftables_chunk", items = batch }))
                batch = {}
            end
        end

        if interface.getItemsInNetwork then
            local seenFluidLabels = {}
            if interface.getFluidsInNetwork then
                local okF, fluids = pcall(interface.getFluidsInNetwork)
                if okF and type(fluids) == "table" then
                    for _, f in ipairs(fluids) do
                        if type(f) == "table" and f.isCraftable == true then
                            local lbl = f.label or f.name or "Unknown"
                            seenFluidLabels[lbl] = true
                            pushCraftableEntry({
                                label = lbl,
                                name = f.name or "",
                                damage = 0,
                                type = "fluid",
                                stock = math.floor(tonumber(f.amount or f.size or 0) or 0),
                                hasTag = false,
                            })
                        end
                    end
                end
            end
            local okI, items = pcall(interface.getItemsInNetwork, { isCraftable = true })
            if not okI or type(items) ~= "table" then
                return reply({ ok = false, error = "getItemsInNetwork failed: " .. tostring(items) })
            end
            for i = 1, #items do
                local st = items[i]
                items[i] = nil
                if type(st) == "table" then
                    local skip = false
                    if st.name == "ae2fc:fluid_drop" then
                        local dropFluid = tostring(st.label or ""):gsub("^drop of ", "")
                        if seenFluidLabels[dropFluid] then
                            skip = true
                        end
                    end
                    if not skip then
                        pushCraftableEntry({
                            label = st.label or st.name or "Unknown",
                            name = st.name or "",
                            damage = math.floor(tonumber(st.damage or 0) or 0),
                            type = "item",
                            stock = math.floor(tonumber(st.size or 0) or 0),
                            hasTag = (st.hasTag == true),
                        })
                    end
                end
            end
            if #batch > 0 then
                sockWriteLine(json.encode({ id = cmdId, op = "craftables_chunk", items = batch }))
            end
            return reply({ ok = true, total = totalCount })
        else
            local okList, list = pcall(interface.getCraftables)
            if not okList or type(list) ~= "table" then
                return reply({ ok = false, error = "getCraftables failed: " .. tostring(list) })
            end
            local total = #list
            for i = 1, total do
                local c = list[i]
                list[i] = nil -- allow GC as we stream chunks
                if c and c.getStack then
                    local okS, st = pcall(c.getStack)
                    if okS and type(st) == "table" then
                        local isFluid = (st.maxSize == nil)
                        batch[#batch + 1] = {
                            label = st.label or st.name or "Unknown",
                            name = st.name or "",
                            damage = isFluid and 0 or math.floor(tonumber(st.damage or 0) or 0),
                            type = isFluid and "fluid" or "item",
                            perCraft = math.floor(tonumber(st.size or st.amount or 1) or 1),
                            hasTag = (st.hasTag == true),
                        }
                    end
                end
                if #batch >= 60 then
                    sockWriteLine(json.encode({ id = cmdId, op = "craftables_chunk", items = batch }))
                    batch = {}
                end
                if (i % 200) == 0 then
                    os.sleep(0)
                end
            end
            if #batch > 0 then
                sockWriteLine(json.encode({ id = cmdId, op = "craftables_chunk", items = batch }))
            end
            return reply({ ok = true, total = total })
        end
    elseif op == "craft" then
        if not interface then
            return reply({ ok = false, error = "No AE2 interface connected" })
        end
        local amount = tonumber(cmd.amount) or 0
        if amount <= 0 then
            return reply({ ok = false, error = "Invalid craft amount" })
        end
        local craftable = resolveCraftable(interface, cmd)
        if not craftable then
            return reply({ ok = false, error = "Craftable not found in AE2 network" })
        end
        local cpuName = cmd.cpuName
        if not cpuName or cpuName == "" or cpuName == "auto" then
            cpuName = nil
        end
        local prioritizePower = (cmd.prioritizePower ~= false)
        local okReq, statusObj, reqErr = pcall(craftable.request, amount, prioritizePower, cpuName)
        if not okReq or not statusObj then
            return reply({ ok = false, error = tostring(reqErr or statusObj or "request() failed") })
        end

        local deadline = (computer.uptime and computer.uptime() or 0) + 4.0
        while statusObj.isComputing do
            local okComp, computing = pcall(statusObj.isComputing)
            if not okComp or not computing then break end
            if (computer.uptime and computer.uptime() or 0) >= deadline then
                return reply({ ok = true, status = "computing", cpus = collectCpusSnapshot(interface) })
            end
            os.sleep(0.1)
        end

        local okFail, failed, failReason = pcall(statusObj.hasFailed)
        if okFail and failed then
            return reply({ ok = false, error = tostring(failReason or "Missing resources or CPU busy") })
        end
        if config.enableCpus then
            pcall(exportCpus, interface)
        end
        return reply({ ok = true, status = "started", cpus = collectCpusSnapshot(interface) })
    elseif op == "cancel" then
        if not interface then
            return reply({ ok = false, error = "No AE2 interface connected" })
        end
        local targetCpu = tostring(cmd.cpuName or "")
        local cpus = interface.getCpus and interface.getCpus() or {}
        for _, cpu in ipairs(cpus) do
            if cpu.name == targetCpu and cpu.cpu and cpu.cpu.cancel then
                local okCan, cancelled = pcall(cpu.cpu.cancel)
                refreshCpuHubState(interface)
                if config.enableCpus then
                    pcall(exportCpus, interface, config.exportPaused)
                end
                if okCan and cancelled then
                    logMsg("OUT", "Canceled crafting CPU " .. targetCpu .. " (via bridge)")
                    return reply({ ok = true, canceled = true, cpus = collectCpusSnapshot(interface) })
                end
                return reply({ ok = false, error = "CPU is not currently busy" })
            end
        end
        return reply({ ok = false, error = "CPU not found: " .. targetCpu })
    elseif op == "dtpf_state" or op == "dtpf_patch" or op == "dtpf_action" or op == "dtpf_reboot" then
        local dtpfOp = (op == "dtpf_reboot") and "reboot" or op
        local res = callMeshRpc(interface, sockWriteLine, dtpfMesh, "DTPF_CMD", {
            id = cmdId,
            op = dtpfOp,
            patch = cmd.patch,
            action = cmd.action,
        }, "DTPF_REPLY", 8.0)
        if type(res) == "table" then
            res.meshRouted = true
            return reply(res)
        end
        return reply({ ok = false, error = "Empty DTPF mesh response" })
    elseif op == "pump_state" then
        if pumpMesh.status and not cmd.force and (uptimeNow() - (pumpMesh.statusUptime or -1000)) < 190 then
            return reply({
                ok = true,
                meshRouted = true,
                ageSec = math.max(0, math.floor((uptimeNow() - pumpMesh.statusUptime) * 10) / 10),
                status = pumpMesh.status,
            })
        end
        local res = callMeshRpc(interface, sockWriteLine, pumpMesh, "PUMP_CMD", { op = "get_status" }, "PUMP_REPLY", 7.0)
        if type(res) == "table" and type(res.status) == "table" then
            pumpMesh.status = res.status
            pumpMesh.statusUptime = uptimeNow()
            res.meshRouted = true
            res.ageSec = 0
        end
        return reply(res)
    elseif op == "pump_patch" or op == "pump_action" or op == "pump_reboot" then
        local pumpCmd
        if op == "pump_patch" then
            pumpCmd = { op = "patch", label = cmd.label, target = cmd.target, priority = cmd.priority }
        elseif op == "pump_action" then
            pumpCmd = { op = "action", action = cmd.action }
        else
            pumpCmd = { op = "reboot" }
        end
        local res = callMeshRpc(interface, sockWriteLine, pumpMesh, "PUMP_CMD", pumpCmd, "PUMP_REPLY", 7.0)
        if type(res) == "table" then
            if type(res.status) == "table" then
                pumpMesh.status = res.status
                pumpMesh.statusUptime = uptimeNow()
                res.ageSec = 0
            end
            res.meshRouted = true
        end
        return reply(res)
    elseif op == "univ_state" then
        if univMesh.status and not cmd.force and isMeshFresh(univMesh, 60) then
            return reply({
                ok = true,
                meshRouted = true,
                ageSec = math.max(0, math.floor((uptimeNow() - (univMesh.lastSeen or 0)) * 10) / 10),
                status = univMesh.status,
            })
        end
        local res = callMeshRpc(interface, sockWriteLine, univMesh, "UNIV_CMD", { action = "poll_now" }, "UNIV_REPLY", 5.0)
        if type(res) == "table" then
            res.meshRouted = true
            if univMesh.status and not res.status then res.status = univMesh.status end
            return reply(res)
        end
        return reply({ ok = false, error = "Empty Universal mesh response" })
    elseif op == "univ_action" or op == "univ_reboot" then
        local uAct = (op == "univ_reboot") and "reboot" or cmd.action
        local res = callMeshRpc(interface, sockWriteLine, univMesh, "UNIV_CMD", {
            action = uAct,
            poolId = cmd.poolId or cmd.poolIdx,
            color = cmd.color,
        }, "UNIV_REPLY", 5.0)
        if type(res) == "table" then
            res.meshRouted = true
            return reply(res)
        end
        return reply({ ok = false, error = "Empty Universal mesh response" })
    elseif op == "gorge_state" then
        if gorgeMesh.status and not cmd.force and isMeshFresh(gorgeMesh, 60) then
            return reply({
                ok = true,
                meshRouted = true,
                ageSec = math.max(0, math.floor((uptimeNow() - (gorgeMesh.lastSeen or 0)) * 10) / 10),
                status = gorgeMesh.status,
            })
        end
        local res = callMeshRpc(interface, sockWriteLine, gorgeMesh, "GORGE_CMD", { action = "poll_now" }, "GORGE_REPLY", 5.0)
        if type(res) == "table" then
            res.meshRouted = true
            if gorgeMesh.status and not res.status then res.status = gorgeMesh.status end
            return reply(res)
        end
        return reply({ ok = false, error = "Empty Gorge mesh response" })
    elseif op == "gorge_action" or op == "gorge_reboot" then
        local gAct = (op == "gorge_reboot") and "reboot" or cmd.action
        local res = callMeshRpc(interface, sockWriteLine, gorgeMesh, "GORGE_CMD", {
            action = gAct,
            exoticizerId = cmd.exoticizerId,
            mode = cmd.mode,
        }, "GORGE_REPLY", 5.0)
        if type(res) == "table" then
            res.meshRouted = true
            return reply(res)
        end
        return reply({ ok = false, error = "Empty Gorge mesh response" })
    elseif op == "stock_state" or op == "stock_patch" or op == "stock_action" or op == "stock_reboot" then
        local stockOp = (op == "stock_reboot") and "stock_action" or op
        local stockAct = (op == "stock_reboot") and "reboot" or cmd.action
        local res = callMeshRpc(interface, sockWriteLine, stockMesh, "STOCK_CMD", {
            id = cmdId,
            op = stockOp,
            patch = cmd.patch,
            action = stockAct,
        }, "STOCK_REPLY", 8.0)
        if type(res) == "table" then
            res.meshRouted = true
            return reply(res)
        end
        return reply({ ok = false, error = "Empty Stock Maintainer mesh response" })
    elseif op == "mesh_recover" then
        local targetRole = tostring(cmd.role or "all"):lower()
        local peerMap = { dtpf = dtpfMesh, stock = stockMesh, pump = pumpMesh, gorge = gorgeMesh, univ = univMesh }
        local woken = {}
        local now = uptimeNow()
        for rName, pTbl in pairs(peerMap) do
            if targetRole == "all" or targetRole == rName then
                pTbl.recoveryAttempts = (pTbl.recoveryAttempts or 0) + 1
                pTbl.lastRecoveryAt = now
                sendMeshPacket(pTbl.addr, pTbl.viaTunnel, WAKE_MSG, rName)
                woken[#woken + 1] = rName
            end
        end
        sendMeshPacket(nil, false, "MESH_MAINNET_HELLO", "recover")
        table.sort(woken)
        emitMeshHelloIfOnline(sockWriteLine)
        return reply({ ok = true, woken = woken, meshHealth = buildMeshHealth(now) })
    elseif op == "reboot" then
        reply({ ok = true, rebooting = true })
        pcall(os.sleep, 0.05)
        if computer.shutdown then
            pcall(computer.shutdown, true)
        end
        return true
    else
        return reply({ ok = false, error = "Unknown op: " .. tostring(op) })
    end
end

local function main()
    needExitFlag = false
    uiActive = false
    local startTime = os.time()
    local lastFluidTime = startTime
    local lastItemTime = startTime
    local lastEssentiaTime = startTime
    local lastEnergyTime = startTime
    local lastEnergyAE2Time = startTime
    local lastCpuTime = startTime
    local lastTpsTime = startTime
    local lastAllItemsTime = (config.allItemsInterval == nil) and startTime or (startTime - config.allItemsInterval)

    local wantGui = (not forceHeadless) and okUiMod and type(Ae2UI) == "table"
        and component.isAvailable and component.isAvailable("gpu") and component.isAvailable("screen")

    local interface = nil
    local lsc = nil
    local lscProxy = nil
    local tpsCard = nil

    local function discoverHardware(forceAll)
        if not interface and (forceAll or config.enableCpus or config.enableEssentia or config.enableFluids or config.enableItems or config.enableEnergyAE2 or config.enableBridge) then
            interface = findMainnetAE2()
        end
        if (not lsc and not lscProxy) and (forceAll or config.enableEnergy) then
            for addr in component.list("gt_machine", true) do
                local mod = component.proxy(addr)
                if mod and mod.getName and mod.getName() == "multimachine.supercapacitor" then
                    lsc = mod
                    break
                end
            end
            for addr in component.list("LSC", true) do
                lscProxy = component.proxy(addr)
                break
            end
        end
        if not tpsCard and (forceAll or config.enableTps) then
            tpsCard = component.tps_card
        end
    end

    discoverHardware(wantGui)
    do
        local m, t = getMeshTransports()
        if m or t then
            sendMeshPacket(nil, false, "MESH_MAINNET_HELLO", "boot")
        end
    end

    local allItemIds = {}
    if config.allItemsMode == 2 then
        allItemIds = require("items")
    end

    -- Persistent outbound TCP client to localhost Python bridge (0 idle cost)
    local sock = nil
    local sockReady = false
    local rxBuf = ""
    local lastConnectTry = -100
    local connectStartUptime = 0
    local reconnectSec = tonumber(config.bridgeReconnectSec) or 10

    local function closeBridgeSocket()
        if sock then
            pcall(sock.close)
        end
        sock = nil
        sockReady = false
        hubState.bridgeConnected = false
        rxBuf = ""
        connectStartUptime = 0
    end

    local function writeBridgeLine(line)
        if not sock or not sockReady then return false end
        local data = line .. "\n"
        while #data > 0 do
            local okW, written, err = pcall(sock.write, data)
            if not okW or not written then
                logMsg("WRN", "[Bridge] Write closed: " .. tostring(err or written))
                closeBridgeSocket()
                return false
            end
            if written == 0 then
                os.sleep(0)
            else
                data = data:sub(written + 1)
            end
        end
        return true
    end

    local function ensureBridgeConnected(now)
        if not config.enableBridge then
            if sock then closeBridgeSocket() end
            return
        end
        if not component.isAvailable("internet") then return end
        local rawInet = component.internet
        if not rawInet or not rawInet.connect then return end

        if not sock then
            if (now - lastConnectTry) < reconnectSec then
                return
            end
            lastConnectTry = now
            local targetEndpoint = tostring(config.bridgeHost or "127.0.0.1") .. ":" .. tostring(config.bridgePort or 8766)
            local okC, s, err = pcall(rawInet.connect, targetEndpoint)
            if okC and s then
                sock = s
                sockReady = false
                rxBuf = ""
                connectStartUptime = now
            else
                logMsg("WRN", "[Bridge] Connect failed: " .. tostring(err or s))
                sock = nil
            end
        end

        if sock and not sockReady then
            local okF, ready = pcall(sock.finishConnect)
            local timedOut = (now - connectStartUptime) > 8.0
            if (not okF) or (ready == nil) or timedOut then
                closeBridgeSocket()
            elseif ready == true then
                sockReady = true
                hubState.bridgeConnected = true
                logMsg("OUT", "[Bridge] Connected to Web Bridge.")
                writeBridgeLine(json.encode({
                    op = "hello",
                    version = 2,
                    hasInterface = (interface ~= nil),
                    freeMem = computer.freeMemory and computer.freeMemory() or 0,
                    totalMem = computer.totalMemory and computer.totalMemory() or 0,
                    lastItemScanSec = lastItemScanSec,
                    meshDtpf = isMeshFresh(dtpfMesh, 60),
                    meshPump = isMeshFresh(pumpMesh, 180),
                    meshUniv = isMeshFresh(univMesh, 60),
                    meshGorge = isMeshFresh(gorgeMesh, 60),
                    meshStock = isMeshFresh(stockMesh, 60),
                }))
            end
        end
    end

    local function drainBridgeIncoming()
        if not sock or not sockReady then return end
        while true do
            local okR, chunk = pcall(sock.read, 8192)
            if not okR or chunk == nil then
                closeBridgeSocket()
                return
            end
            if chunk == "" then
                break
            end
            rxBuf = rxBuf .. chunk
            while true do
                local nl = rxBuf:find("\n", 1, true)
                if not nl then break end
                local rawLine = rxBuf:sub(1, nl - 1):gsub("\r$", "")
                rxBuf = rxBuf:sub(nl + 1)
                if rawLine ~= "" then
                    local cmd = json.decode(rawLine)
                    if type(cmd) == "table" and cmd.op then
                        local okH, errH = pcall(handleBridgeCommand, writeBridgeLine, interface, cmd)
                        if not okH then
                            logMsg("ERR", "[Bridge] Command error (" .. tostring(cmd.op) .. "): " .. tostring(errH))
                        end
                    end
                end
            end
        end
    end

    local ui = nil
    local uiDirty = false

    local function refreshLocalTelemetryForUi(doPost)
        local skip = (not doPost) or (config.exportPaused == true)
        if interface then
            refreshCpuHubState(interface)
            exportEnergyAE2(interface, skip)
        end
        if lsc or lscProxy then
            exportEnergy(lsc, lscProxy, skip)
        end
        if tpsCard then
            exportTps(tpsCard, skip)
        end
    end

    if wantGui then
        local uiCallbacks = {
            onTogglePauseExport = function()
                config.exportPaused = not (config.exportPaused == true)
                hubState.exporterPaused = config.exportPaused
                saveConfigOverrides()
                logMsg("OUT", config.exportPaused and "InfluxDB exports PAUSED via GUI." or "InfluxDB exports RESUMED via GUI.")
                return config.exportPaused and "Exports PAUSED (mesh & UI stay live)." or "Exports RESUMED."
            end,
            onScanNow = function()
                hubState._forceScanNow = true
                discoverHardware(true)
                refreshLocalTelemetryForUi(true)
                uiDirty = true
            end,
            onMeshPing = function()
                invalidateMeshCache()
                local m, t = getMeshTransports()
                if m or t then
                    sendMeshPacket(nil, false, "MESH_MAINNET_HELLO", "gui_ping")
                    logMsg("MESH", "Broadcast MESH_MAINNET_HELLO beacon from UI.")
                else
                    logMsg("WRN", "No Wireless Modem or Linked Card available.")
                end
            end,
            onMeshRecover = function(targetRole)
                local role = tostring(targetRole or "all"):lower()
                local peerMap = { dtpf = dtpfMesh, stock = stockMesh, pump = pumpMesh, gorge = gorgeMesh, univ = univMesh }
                local now = uptimeNow()
                local woken = {}
                for rName, pTbl in pairs(peerMap) do
                    if role == "all" or role == rName then
                        pTbl.recoveryAttempts = (pTbl.recoveryAttempts or 0) + 1
                        pTbl.lastRecoveryAt = now
                        sendMeshPacket(pTbl.addr, pTbl.viaTunnel, WAKE_MSG, rName)
                        woken[#woken + 1] = rName
                    end
                end
                sendMeshPacket(nil, false, "MESH_MAINNET_HELLO", "gui_recover")
                emitMeshHelloIfOnline(writeBridgeLine)
                logMsg("MESH", "Sent " .. WAKE_MSG .. " recovery signal to: " .. table.concat(woken, ","))
                return "Sent " .. WAKE_MSG .. " to " .. table.concat(woken, ", ")
            end,
            onCancelCpu = function(targetName)
                if not interface or not interface.getCpus then
                    return false, "No AE2 interface bound."
                end
                local cpus = interface.getCpus() or {}
                for _, cpu in ipairs(cpus) do
                    if cpu.name == targetName and cpu.cpu and cpu.cpu.cancel then
                        local okCan, canceled = pcall(cpu.cpu.cancel)
                        refreshCpuHubState(interface)
                        if okCan and canceled then
                            logMsg("OUT", "Canceled crafting job on " .. tostring(targetName))
                            return true, "Canceled crafting job on " .. tostring(targetName)
                        end
                        return false, "CPU is no longer busy."
                    end
                end
                return false, "CPU not found: " .. tostring(targetName)
            end,
            onPeerAction = function(peerKey, action, extra)
                extra = extra or {}
                if peerKey == "ae2" and action == "reboot" then
                    pcall(saveConfigOverrides)
                    logMsg("OUT", "Main Brain AE2 reboot requested via GUI.")
                    pendingSelfReboot = true
                    needExitFlag = true
                    if ui then ui.running = false end
                    return "Rebooting AE2 Main Brain..."
                elseif peerKey == "dtpf" then
                    local payload
                    if action == "pause" then
                        payload = { op = "dtpf_patch", patch = { armed = false } }
                    elseif action == "resume" then
                        payload = { op = "dtpf_patch", patch = { armed = true } }
                    elseif action == "reboot" then
                        payload = { op = "reboot" }
                    elseif action == "maint_sync" or action == "flush_od" or action == "lock_autopull" or action == "poll" then
                        payload = { op = "dtpf_action", action = (action == "poll") and "poll_now" or action }
                    else
                        payload = { op = "dtpf_action", action = tostring(action) }
                    end
                    local res = callMeshRpc(interface, writeBridgeLine, dtpfMesh, "DTPF_CMD", payload, "DTPF_REPLY", 2.5)
                    if type(res) == "table" and res.ok then
                        if type(res.units) == "table" then dtpfMesh.status = res end
                        logMsg("MESH", "DTPF action '" .. tostring(action) .. "' acknowledged.")
                        return (action == "reboot") and "DTPF: reboot triggered." or ("DTPF: " .. tostring(action) .. " OK.")
                    end
                    return "DTPF: " .. tostring(type(res) == "table" and res.error or "No response")
                elseif peerKey == "pump" then
                    if action == "pause" or action == "resume" then
                        return "Space Pump runs on stock targets; use [Wake / Poll] or [Refresh Pumps]."
                    end
                    local pumpCmd
                    local pumpAct = tostring(action)
                    if action == "reboot" then
                        pumpCmd = { op = "reboot" }
                    else
                        pumpAct = (action == "refresh_pumps" or action == "reload") and action or "wake"
                        pumpCmd = { op = "action", action = pumpAct }
                    end
                    local res = callMeshRpc(interface, writeBridgeLine, pumpMesh, "PUMP_CMD", pumpCmd, "PUMP_REPLY", 2.5)
                    if type(res) == "table" and res.ok then
                        if type(res.status) == "table" then
                            pumpMesh.status = res.status
                            pumpMesh.statusUptime = uptimeNow()
                        end
                        logMsg("MESH", "Space Pump '" .. pumpAct .. "' OK.")
                        return (action == "reboot") and "Space Pump: reboot triggered." or ("Space Pump: " .. pumpAct .. " OK.")
                    end
                    return "Space Pump: " .. tostring(type(res) == "table" and res.error or "No response")
                elseif peerKey == "univ" then
                    local act = (action == "poll") and "poll_now" or tostring(action)
                    local res = callMeshRpc(interface, writeBridgeLine, univMesh, "UNIV_CMD", { action = act }, "UNIV_REPLY", 2.5)
                    if type(res) == "table" and res.ok then
                        if res.armed ~= nil and type(univMesh.status) == "table" then univMesh.status.armed = res.armed end
                        logMsg("MESH", "Universal action '" .. act .. "' OK.")
                        return (action == "reboot") and "Universal: reboot triggered." or ("Universal: " .. act .. " OK.")
                    end
                    return "Universal: " .. tostring(type(res) == "table" and res.error or "No response")
                elseif peerKey == "gorge" then
                    local act = (action == "poll") and "poll_now" or tostring(action)
                    local cmdTbl = { action = act, exoticizerId = extra.exoticizerId, mode = extra.mode }
                    local res = callMeshRpc(interface, writeBridgeLine, gorgeMesh, "GORGE_CMD", cmdTbl, "GORGE_REPLY", 2.5)
                    if type(res) == "table" and res.ok then
                        if type(gorgeMesh.status) == "table" then
                            if res.armed ~= nil then gorgeMesh.status.armed = res.armed end
                            if action == "set_mode" and extra.exoticizerId and extra.mode then
                                for _, ex in ipairs(gorgeMesh.status.exoticizers or {}) do
                                    if ex.id == extra.exoticizerId then ex.mode = extra.mode break end
                                end
                            end
                        end
                        logMsg("MESH", "Gorge action '" .. act .. "' OK.")
                        return (action == "reboot") and "Gorge: reboot triggered." or ("Gorge: " .. act .. " OK.")
                    end
                    return "Gorge: " .. tostring(type(res) == "table" and res.error or "No response")
                elseif peerKey == "stock" then
                    local stockCmd
                    if action == "pause" then
                        stockCmd = { op = "stock_action", action = "pause" }
                    elseif action == "resume" then
                        stockCmd = { op = "stock_action", action = "arm" }
                    elseif action == "poll" then
                        stockCmd = { op = "stock_action", action = "poll_now" }
                    else
                        stockCmd = { op = "stock_action", action = tostring(action) }
                    end
                    local res = callMeshRpc(interface, writeBridgeLine, stockMesh, "STOCK_CMD", stockCmd, "STOCK_REPLY", 3.5)
                    if type(res) == "table" and res.ok then
                        if type(stockMesh.status) == "table" and res.armed ~= nil then
                            stockMesh.status.armed = res.armed
                        end
                        logMsg("MESH", "Stock Maintainer action '" .. tostring(action) .. "' OK.")
                        return (action == "reboot") and "Stock: reboot triggered." or ("Stock: " .. tostring(action) .. " OK.")
                    end
                    return "Stock: " .. tostring(type(res) == "table" and res.error or "No response")
                end
                return "Unknown peer."
            end,
            onConfigChanged = function(kind, key, val)
                if kind == "toggle" then
                    config[key] = (val == true)
                    if key == "enableMesh" then
                        invalidateMeshCache()
                        if config.enableMesh then getMeshTransports() end
                    elseif key == "enableBridge" and not config.enableBridge then
                        closeBridgeSocket()
                    else
                        discoverHardware(false)
                    end
                elseif kind == "interval" then
                    local sec = math.max(1, math.floor(tonumber(val) or 1))
                    config._sec[key] = sec
                    config[key] = sec * 72
                end
                saveConfigOverrides()
            end,
            onResetOverrides = function()
                resetConfigOverrides()
                invalidateMeshCache()
                if config.enableMesh ~= false then getMeshTransports() end
                if not config.enableBridge then closeBridgeSocket() end
                uiDirty = true
                logMsg("OUT", "Reset overrides -> restored /home/config.lua defaults.")
                return "Reset overrides to /home/config.lua defaults."
            end,
        }
        ui = Ae2UI.new(config, hubState, uiCallbacks)
        uiActive = true
    end

    local function drainUiEvents()
        if not ui then return end
        for _ = 1, 8 do
            local evName, a1, a2, a3, a4 = event.pull(0, "touch")
            if not evName then break end
            if ui:handleTouch(math.floor(tonumber(a2) or 0), math.floor(tonumber(a3) or 0), a4) then
                uiDirty = true
            end
        end
        for _ = 1, 4 do
            local evName, _, _, _, dir = event.pull(0, "scroll")
            if not evName then break end
            ui:handleScroll(tonumber(dir) or 0)
            uiDirty = true
        end
        for _ = 1, 4 do
            local evName, _, ch, cd = event.pull(0, "key_down")
            if not evName then break end
            ui:handleKeyDown(tonumber(ch) or 0, tonumber(cd) or 0)
            uiDirty = true
        end
        if not ui.running then
            needExitFlag = true
        end
    end

    local function drainMeshIncoming()
        if config.enableMesh == false then return end
        for _ = 1, 8 do
            local evName, lAddr, sAddr, port, _, msgType, a1, a2 = event.pull(0, "modem_message")
            if not evName then break end
            if evName == "modem_message" then
                if handleMeshModemEvent(interface, writeBridgeLine, lAddr, sAddr, port, msgType, a1, a2) then
                    uiDirty = true
                end
            else
                if evName == "interrupted" or (evName == "key_up" and sAddr == 113) then
                    needExitFlag = true
                end
                break
            end
        end
    end

    local function stepBackgroundIo()
        drainMeshIncoming()
        drainBridgeIncoming()
        drainUiEvents()
    end

    local function pollAndWait()
        local waitSec = ui and 0.5 or 1.0
        local evName, lAddr, sAddr, port, a4, msgType, a1, a2 = event.pull(waitSec)
        if evName == "interrupted" then
            needExitFlag = true
        elseif not ui and evName == "key_up" and sAddr == 113 then
            needExitFlag = true
        elseif evName == "internet_ready" then
            drainBridgeIncoming()
        elseif evName == "modem_message" then
            if handleMeshModemEvent(interface, writeBridgeLine, lAddr, sAddr, port, msgType, a1, a2) then
                uiDirty = true
            end
        elseif ui then
            if evName == "touch" then
                if ui:handleTouch(math.floor(tonumber(sAddr) or 0), math.floor(tonumber(port) or 0), a4) then
                    uiDirty = true
                end
            elseif evName == "scroll" then
                ui:handleScroll(tonumber(a4) or 0)
                uiDirty = true
            elseif evName == "key_down" then
                ui:handleKeyDown(tonumber(sAddr) or 0, tonumber(port) or 0)
                uiDirty = true
            end
            if not ui.running then
                needExitFlag = true
            end
        end
    end

    if ui then
        hubState.nowUptime = uptimeNow()
        hubState.freeMem = computer.freeMemory and computer.freeMemory() or 0
        hubState.totalMem = computer.totalMemory and computer.totalMemory() or 0
        refreshLocalTelemetryForUi(false)
        ui:render()
    end

    local lastMeshBeaconUptime = uptimeNow()
    local lastUiTelemetryAt = uptimeNow()
    local lastUiRenderAt = uptimeNow()

    local okLoop, loopErr = xpcall(function()
        while not needExitFlag do
            local upNow = uptimeNow()
            hubState.nowUptime = upNow
            hubState.freeMem = computer.freeMemory and computer.freeMemory() or 0
            hubState.totalMem = computer.totalMemory and computer.totalMemory() or 0
            hubState.exporterPaused = (config.exportPaused == true)

            ensureBridgeConnected(upNow)
            drainBridgeIncoming()

            if hubState._forceScanNow then
                hubState._forceScanNow = false
                if not config.exportPaused then
                    lastFluidTime = 0
                    lastItemTime = 0
                    lastEssentiaTime = 0
                    lastEnergyTime = 0
                    lastEnergyAE2Time = 0
                    lastCpuTime = 0
                    lastTpsTime = 0
                else
                    refreshLocalTelemetryForUi(false)
                end
                uiDirty = true
            end

            if config.enableMesh ~= false and (upNow - lastMeshBeaconUptime) >= 20
                and (not isMeshFresh(dtpfMesh, PEER_STALE_SEC) or not isMeshFresh(pumpMesh, PUMP_STALE_SEC)
                     or not isMeshFresh(univMesh, PEER_STALE_SEC) or not isMeshFresh(gorgeMesh, PEER_STALE_SEC)
                     or not isMeshFresh(stockMesh, PEER_STALE_SEC)) then
                lastMeshBeaconUptime = upNow
                local m, t = getMeshTransports()
                if m or t then
                    sendMeshPacket(nil, false, "MESH_MAINNET_HELLO", "beacon")
                end
            end
            if config.enableMesh ~= false and (upNow - lastWatchdogAt) >= 15 then
                lastWatchdogAt = upNow
                local wdDbUrl = (not config.exportPaused and config.dbURL) and (config.dbURL .. (config.itemDB or "mainnet")) or nil
                checkMeshWatchdog(upNow, wdDbUrl, writeBridgeLine)
            end

            if (not config.exportPaused) and config.enableItems and interface and (config.allItemsMode == 1 or config.allItemsMode == 3) and os.time() > lastAllItemsTime + config.allItemsInterval then
                if config.allItemsMode == 1 then
                    allItemIds = {}
                end
                updateItemIds(allItemIds, interface)
                lastAllItemsTime = os.time()
                logMsg("OUT", "[" .. os.time() .. "] Set item IDs; free RAM: " .. computer.freeMemory() .. " bytes")
            end
            if (not config.exportPaused) and config.enableItems and interface and os.time() > lastItemTime + config.itemInterval then
                if config.allItemsMode == 4 then
                    exportItemsInfMem(interface)
                elseif config.allItemsMode == 5 then
                    local startTimeAI5 = os.time()
                    exportItemsNumeric(interface, stepBackgroundIo)
                    logMsg("OUT", "allItems mode 5 took " .. (os.time() - startTimeAI5) / 72 .. " seconds to run.")
                elseif (config.allItemsMode ~= nil and config.allItemsMode > 0) then
                    exportItemsIds(interface, allItemIds)
                else
                    exportItems(interface)
                end
                lastItemTime = os.time()
                logMsg("OUT", "[" .. os.time() .. "] Exported items; free RAM: " .. computer.freeMemory() .. " bytes")
                stepBackgroundIo()
            end
            if (not config.exportPaused) and config.enableFluids and interface and os.time() > lastFluidTime + config.fluidInterval then
                exportFluids(interface)
                lastFluidTime = os.time()
                logMsg("OUT", "[" .. os.time() .. "] Exported fluids; free RAM: " .. computer.freeMemory() .. " bytes")
                stepBackgroundIo()
            end
            if (not config.exportPaused) and config.enableEssentia and interface and os.time() > lastEssentiaTime + config.essentiaInterval then
                exportEssentia(interface)
                lastEssentiaTime = os.time()
                logMsg("OUT", "[" .. os.time() .. "] Exported essentia; free RAM: " .. computer.freeMemory() .. " bytes")
                stepBackgroundIo()
            end
            if config.enableEnergy and (lsc or lscProxy) and os.time() > lastEnergyTime + config.energyInterval then
                exportEnergy(lsc, lscProxy, config.exportPaused == true)
                lastEnergyTime = os.time()
                if not config.exportPaused then
                    logMsg("OUT", "[" .. os.time() .. "] Exported energy; free RAM: " .. computer.freeMemory() .. " bytes")
                end
                stepBackgroundIo()
                uiDirty = true
            end
            if config.enableEnergyAE2 and interface and os.time() > lastEnergyAE2Time + config.energyAE2Interval then
                exportEnergyAE2(interface, config.exportPaused == true)
                lastEnergyAE2Time = os.time()
                if not config.exportPaused then
                    logMsg("OUT", "[" .. os.time() .. "] Exported AE2 energy; free RAM: " .. computer.freeMemory() .. " bytes")
                end
                stepBackgroundIo()
                uiDirty = true
            end
            if config.enableCpus and interface and os.time() > lastCpuTime + config.cpuInterval then
                exportCpus(interface, config.exportPaused == true)
                lastCpuTime = os.time()
                if not config.exportPaused then
                    logMsg("OUT", "[" .. os.time() .. "] Exported CPUs; free RAM: " .. computer.freeMemory() .. " bytes")
                end
                stepBackgroundIo()
                uiDirty = true
            end
            if config.enableTps and tpsCard and os.time() > lastTpsTime + config.tpsInterval then
                exportTps(tpsCard, config.exportPaused == true)
                lastTpsTime = os.time()
                if not config.exportPaused then
                    logMsg("OUT", "[" .. os.time() .. "] Exported TPS; free RAM: " .. computer.freeMemory() .. " bytes")
                end
                uiDirty = true
            end

            if ui and (uptimeNow() - lastUiTelemetryAt) >= 2.0 then
                lastUiTelemetryAt = uptimeNow()
                refreshLocalTelemetryForUi(false)
                uiDirty = true
            end

            if ui and not needExitFlag and (uiDirty or (uptimeNow() - lastUiRenderAt) >= 1.5) then
                uiDirty = false
                lastUiRenderAt = uptimeNow()
                ui:render()
            end

            if not needExitFlag then
                pollAndWait()
            end
        end
    end, debug.traceback)

    closeBridgeSocket()
    if ui then
        uiActive = false
        if component.isAvailable and component.isAvailable("gpu") and component.gpu then
            pcall(component.gpu.setBackground, 0x000000)
            pcall(component.gpu.setForeground, 0xFFFFFF)
        end
        if okTerm and term and term.clear then
            pcall(term.clear)
        end
    end
    if not okLoop then
        error(loopErr, 0)
    end
    if pendingSelfReboot then
        pendingSelfReboot = false
        pcall(os.sleep, 0.1)
        if computer.shutdown then
            pcall(computer.shutdown, true)
        end
    end
end

if config.dbUseAuth then
    AuthHeader = { Authorization = "Token " .. config.dbToken }
end

if config.enableResilience then
    while not needExitFlag do
        print("Exporter running...")
        local ok, msg = pcall(main)
        if not ok then
            print("[Exporter Error] " .. tostring(msg))
            if not needExitFlag then os.sleep(2) end
        end
    end
else
    main()
end
