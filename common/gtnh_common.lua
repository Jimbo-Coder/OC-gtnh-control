-- /usr/lib/gtnh_common.lua
-- Shared runtime infrastructure for OC-gtnh-control controllers, UIs, and hardware modules.
-- Strictly _G-safe (no undeclared global reads/writes) for Lua 5.3 + OpenComputers / JNLua.

local Common = {}

Common.MESH_PORT = 4205
Common.WAKE_MSG = "GTNH_WAKE"
Common.LOCAL_UPDATE_URL = "http://127.0.0.1:8765/oc-raw"
Common.GITHUB_UPDATE_URL = "https://raw.githubusercontent.com/Jimbo-Coder/OC-gtnh-control/main"

local function tryRequire(modName)
    local ok, mod = pcall(require, modName)
    if ok and mod ~= nil then return mod end
    return rawget(_G, modName)
end

local function getComputerLib()
    return tryRequire("computer")
end

local function getComponentLib()
    return tryRequire("component")
end

local function getUnicodeLib()
    return tryRequire("unicode")
end

local function wdNow()
    local compLib = getComputerLib()
    if type(compLib) == "table" and type(compLib.uptime) == "function" then
        local ok, v = pcall(compLib.uptime)
        if ok and tonumber(v) then return tonumber(v) end
    end
    local osLib = rawget(_G, "os")
    if type(osLib) == "table" and type(osLib.clock) == "function" then
        return tonumber(osLib.clock()) or 0
    end
    return 0
end

--- Build a predicate matching trimmed non-comment `/home/.shrc` command names.
function Common.makeShrcMatcher(namesList)
    local wanted = {}
    for _, name in ipairs(namesList or {}) do
        wanted[tostring(name)] = true
    end
    return function(line)
        if type(line) ~= "string" then return false end
        if line:match("^%s*#") then return false end
        local cmd = line:match("^%s*(%S+)")
        return cmd ~= nil and wanted[cmd] == true
    end
end

--- Arm idempotent idle-shell / Ctrl+C wake watchdog (`GTNH_WAKE` reboots after idle grace).
function Common.armShellReviveWatchdog(opts)
    opts = opts or {}
    if opts.enabled == false then
        Common.disarmShellReviveWatchdog()
        return false
    end
    local evLib = tryRequire("event")
    if type(evLib) ~= "table" or type(evLib.listen) ~= "function" then
        return false
    end
    local now = wdNow()
    local wd = rawget(_G, "__gtnhReviveWd")
    if type(wd) ~= "table" then
        wd = { armed = false, exitAt = now, lastKeyAt = now, hooked = false }
        rawset(_G, "__gtnhReviveWd", wd)
    end
    wd.exitAt = now
    wd.lastKeyAt = now
    wd.meshPort = tonumber(opts.meshPort) or Common.MESH_PORT
    wd.wakeMsg = tostring(opts.wakeMsg or Common.WAKE_MSG)
    wd.shrcPath = tostring(opts.shrcPath or "/home/.shrc")
    wd.holdPath = tostring(opts.holdPath or "/tmp/gtnh_hold")
    wd.idleSec = tonumber(opts.idleSec) or 30
    wd.isAutostartFn = opts.isAutostartFn
    wd.armed = true

    if not wd.hooked then
        wd.hooked = true
        evLib.listen("key_down", function()
            wd.lastKeyAt = wdNow()
        end)
        evLib.listen("modem_message", function(_, _, _, port, _, msgType)
            if not wd.armed then return end
            if msgType ~= (wd.wakeMsg or Common.WAKE_MSG) then return end
            if port ~= wd.meshPort and port ~= 0 then return end

            local matchFn = wd.isAutostartFn
            local autostartOn = false
            if type(matchFn) == "function" and io and io.open then
                local f = io.open(wd.shrcPath or "/home/.shrc", "r")
                if f then
                    local raw = f:read("*a") or ""
                    f:close()
                    for line in raw:gmatch("[^\r\n]+") do
                        if matchFn(line) then
                            autostartOn = true
                            break
                        end
                    end
                end
            end
            if not autostartOn then return end

            local holdPath = wd.holdPath or "/tmp/gtnh_hold"
            local holdExists = false
            local fs = tryRequire("filesystem")
            if type(fs) == "table" and type(fs.exists) == "function" then
                holdExists = (fs.exists(holdPath) == true)
            end
            if (not holdExists) and io and io.open then
                local hf = io.open(holdPath, "r")
                if hf then hf:close(); holdExists = true end
            end
            if holdExists then return end

            local cur = wdNow()
            local grace = tonumber(wd.idleSec) or 30
            if (cur - (wd.exitAt or cur)) < grace or (cur - (wd.lastKeyAt or cur)) < grace then
                return
            end

            wd.armed = false
            local compLib = getComputerLib()
            if type(compLib) == "table" and type(compLib.shutdown) == "function" then
                pcall(compLib.shutdown, true)
            end
        end)
    end
    return true
end

function Common.disarmShellReviveWatchdog()
    local wd = rawget(_G, "__gtnhReviveWd")
    if type(wd) == "table" then
        wd.armed = false
    end
end

--- Configure fuzzy Wake-on-LAN message only when not already set identically (false/"" disables).
function Common.configureWake(dev, wakeMsg)
    if not dev or type(dev.setWakeMessage) ~= "function" then return false end
    if wakeMsg == false or wakeMsg == "" then
        if type(dev.getWakeMessage) == "function" then
            local okWk, curWk = pcall(dev.getWakeMessage)
            if okWk and curWk ~= nil and curWk ~= "" then
                pcall(dev.setWakeMessage, "")
            end
        else
            pcall(dev.setWakeMessage, "")
        end
        return false
    end
    wakeMsg = tostring(wakeMsg or Common.WAKE_MSG)
    local needWake = true
    if type(dev.getWakeMessage) == "function" then
        local okWk, curWk, curFuzzy = pcall(dev.getWakeMessage)
        if okWk and curWk == wakeMsg and curFuzzy == true then
            needWake = false
        end
    end
    if needWake then
        pcall(dev.setWakeMessage, wakeMsg, true)
    end
    return true
end

--- Open mesh port, set wireless strength >= target, and configure wake without redundant calls.
function Common.configureModem(m, port, wakeMsg, strength)
    if not m then return false end
    port = tonumber(port) or Common.MESH_PORT
    strength = tonumber(strength) or 400
    local wk = (wakeMsg == false or wakeMsg == "") and "" or tostring(wakeMsg or Common.WAKE_MSG)

    local needOpen = true
    if type(m.isOpen) == "function" then
        local okO, isO = pcall(m.isOpen, port)
        if okO and isO == true then needOpen = false end
    end
    if needOpen and m.open then pcall(m.open, port) end

    local isW = false
    if m.isWireless then
        local okW, rW = pcall(m.isWireless)
        isW = okW and (rW == true)
    end
    if isW and m.setStrength then
        local needStr = true
        if type(m.getStrength) == "function" then
            local okG, curStr = pcall(m.getStrength)
            if okG and tonumber(curStr) and tonumber(curStr) >= strength then needStr = false end
        end
        if needStr then pcall(m.setStrength, strength) end
    end

    Common.configureWake(m, wk)
    return isW
end

--- Discover & configure best modem (prefers wireless) and optional tunnel linked card.
function Common.getMeshTransports(compLib, opts)
    opts = opts or {}
    local cl = compLib or getComponentLib()
    if not cl then return nil, nil, nil, nil end

    local port = tonumber(opts.port) or Common.MESH_PORT
    local wk = (opts.wakeMsg == false or opts.wakeMsg == "") and "" or tostring(opts.wakeMsg or Common.WAKE_MSG)
    local strength = tonumber(opts.strength) or 400
    local proxyFn = opts.proxyFn or function(c, addr)
        return c.proxy and c.proxy(addr) or nil
    end

    local firstModem, firstAddr, wirelessModem, wirelessAddr = nil, nil, nil, nil
    if cl.list then
        for addr in cl.list("modem", true) do
            local m = proxyFn(cl, addr)
            if m then
                local isW = Common.configureModem(m, port, wk, strength)
                if not firstModem then firstModem, firstAddr = m, addr end
                if isW and not wirelessModem then wirelessModem, wirelessAddr = m, addr end
            end
        end
    elseif cl.isAvailable and cl.isAvailable("modem") and cl.modem then
        local m = cl.modem
        local isW = Common.configureModem(m, port, wk, strength)
        firstModem, firstAddr = m, m.address or "modem"
        if isW then wirelessModem, wirelessAddr = m, firstAddr end
    end
    local modem = wirelessModem or firstModem
    local modemAddr = wirelessAddr or firstAddr

    local tunnel, tunnelAddr = nil, nil
    local ta = cl.list and cl.list("tunnel", true)() or nil
    if ta then
        tunnelAddr = ta
        tunnel = proxyFn(cl, ta)
    end
    if (not tunnel) and cl.isAvailable and cl.isAvailable("tunnel") and cl.tunnel then
        tunnel = cl.tunnel
        tunnelAddr = tunnelAddr or tunnel.address or "tunnel"
    end
    if tunnel then
        Common.configureWake(tunnel, wk)
    end

    return modem, tunnel, modemAddr, tunnelAddr
end

--- Unicode width-aware truncate/pad to exact cell width.
function Common.padOrTrunc(str, width, ellipsis)
    str = tostring(str or "")
    width = math.floor(tonumber(width) or 0)
    if width <= 0 then return "" end
    local uni = getUnicodeLib()
    local wlen = (uni and uni.wlen) or string.len
    local usub = (uni and uni.sub) or string.sub
    local len = wlen(str)
    if len > width then
        if width == 1 then return usub(str, 1, 1) end
        return usub(str, 1, width - 1) .. (ellipsis or "…")
    elseif len < width then
        return str .. string.rep(" ", width - len)
    end
    return str
end

--- Compute safe right-aligned starting column so `text` never overflows `totalW`.
function Common.fitRightX(totalW, text, minX)
    local uni = getUnicodeLib()
    local wlen = (uni and uni.wlen) or string.len
    local tw = math.floor(tonumber(totalW) or 160)
    return math.max(minX or 2, tw - wlen(tostring(text or "")))
end

--- Bind screen if needed, set GPU resolution + viewport, and sync `uiObj.w/h` + buffers.
function Common.syncDisplay(uiObj, opts)
    opts = opts or {}
    local gpu = uiObj and uiObj.gpu
    if not gpu then return false end

    local cl = opts.comp or uiObj.comp or getComponentLib()
    if gpu.getScreen and gpu.bind and cl and cl.list then
        local okS, curScr = pcall(gpu.getScreen)
        if okS and not curScr then
            local sAddr = cl.list("screen", true)()
            if sAddr then pcall(gpu.bind, sAddr) end
        end
    end

    local minW = tonumber(opts.minW) or 40
    local maxW = tonumber(opts.maxW) or 160
    local minH = tonumber(opts.minH) or 16
    local maxH = tonumber(opts.maxH) or 50

    local tw, th = maxW, maxH
    if gpu.maxResolution then
        local okM, mw, mh = pcall(gpu.maxResolution)
        if okM and mw and mh then
            tw = math.max(minW, math.min(maxW, math.floor(tonumber(mw) or maxW)))
            th = math.max(minH, math.min(maxH, math.floor(tonumber(mh) or maxH)))
        end
    end
    if gpu.setResolution then pcall(gpu.setResolution, tw, th) end
    if gpu.setViewport then pcall(gpu.setViewport, tw, th) end

    local aw, ah = tw, th
    if gpu.getViewport then
        local okV, vw, vh = pcall(gpu.getViewport)
        if okV and tonumber(vw) and tonumber(vh) then
            aw, ah = math.floor(tonumber(vw)), math.floor(tonumber(vh))
        end
    elseif gpu.getResolution then
        local okR, rw, rh = pcall(gpu.getResolution)
        if okR and tonumber(rw) and tonumber(rh) then
            aw, ah = math.floor(tonumber(rw)), math.floor(tonumber(rh))
        end
    end
    aw = math.max(minW, math.min(maxW, aw))
    ah = math.max(minH, math.min(maxH, ah))

    if aw ~= uiObj.w or ah ~= uiObj.h or opts.forceRedraw then
        uiObj.w = aw
        uiObj.h = ah
        if type(opts.onResize) == "function" then
            opts.onResize(aw, ah)
        end
        return true
    end
    return false
end

--- Recover automatically if GPU viewport drifted away from `uiObj.w`/`uiObj.h`.
function Common.checkViewportDrift(uiObj, syncFn, renderFn, opts)
    opts = opts or {}
    local gpu = uiObj and uiObj.gpu
    if not gpu or uiObj._syncingDisplay or not gpu.getViewport then return false end
    local minW = tonumber(opts.minW) or 40
    local maxW = tonumber(opts.maxW) or 160
    local minH = tonumber(opts.minH) or 16
    local maxH = tonumber(opts.maxH) or 50
    local okV, vw, vh = pcall(gpu.getViewport)
    if not (okV and tonumber(vw) and tonumber(vh)) then return false end
    vw = math.max(minW, math.min(maxW, math.floor(tonumber(vw))))
    vh = math.max(minH, math.min(maxH, math.floor(tonumber(vh))))
    if vw ~= uiObj.w or vh ~= uiObj.h then
        uiObj._syncingDisplay = true
        local changed = syncFn and syncFn(true)
        if changed and type(renderFn) == "function" then
            pcall(renderFn)
        end
        uiObj._syncingDisplay = false
        if changed then return true end
    end
    return false
end

function Common.isAllowedOtaUrl(url)
    if type(url) ~= "string" then return false end
    if url:find("[%s%c]") then return false end
    return url:match("^https?://[%w%.%-_:]+") ~= nil
end

function Common.detectOtaTransport(compLib)
    local cl = compLib or getComponentLib()
    local hasInternet, hasMesh = false, false
    if cl then
        hasInternet = ((cl.isAvailable and cl.isAvailable("internet")) or false)
            or ((cl.list and cl.list("internet", true)() ~= nil) or false)
        hasMesh = ((cl.isAvailable and (cl.isAvailable("modem") or cl.isAvailable("tunnel"))) or false)
            or ((cl.list and ((cl.list("modem", true)() ~= nil) or (cl.list("tunnel", true)() ~= nil))) or false)
    end
    return {
        hasInternet = hasInternet == true,
        hasMesh = hasMesh == true,
        viaMesh = (not hasInternet) and (hasMesh == true),
    }
end

function Common.buildInstallerArgs(url, opts)
    opts = opts or {}
    local args = { "--update", "--yes", "--no-prompt" }
    if url and url ~= "" then
        args[#args + 1] = "--url"
        args[#args + 1] = tostring(url)
    end
    if opts.viaMesh then
        args[#args + 1] = "--mesh-relay"
        if opts.meshTarget and tostring(opts.meshTarget) ~= "" then
            args[#args + 1] = "--mesh-target"
            args[#args + 1] = tostring(opts.meshTarget)
        end
    end
    return args
end

return Common
