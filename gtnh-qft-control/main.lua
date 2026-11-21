-- /home/qft/main.lua
-- GTNH Quantum Force Transformer Controller Daemon & Touch Control Center
-- Usage:
--   qft             (160x50 Touch GUI, or headless fallback)
--   qft --worker    (headless daemon)
--   qft --check     (read-only dry-run)
--   qft --off       (disarm QFTs cleanly)
--   qft --update    (update scripts while preserving config.cfg)

local cliArgs = { ... }

local component = require("component")
local computer = require("computer")
local event = require("event")
local filesystem = require("filesystem")
local serialization = require("serialization")
local term = require("term")

local function resolveScriptDir(defaultDir)
    local function checkCandidate(rawPath)
        if type(rawPath) ~= "string" or rawPath == "" then return nil end
        local canon = (filesystem.canonical and filesystem.canonical(rawPath)) or rawPath
        local dir = filesystem.path(canon)
        if type(dir) ~= "string" or dir == "" then return nil end
        dir = dir:gsub("/+$", "")
        if dir == "" then dir = "/" end
        if filesystem.exists(filesystem.concat(dir, "lib/hardware.lua"))
            or filesystem.exists(filesystem.concat(dir, "install.lua")) then
            return dir
        end
        return nil
    end
    if debug and debug.getinfo then
        for level = 1, 5 do
            local ok, info = pcall(debug.getinfo, level, "S")
            if ok and type(info) == "table" and type(info.source) == "string" then
                local pfx = info.source:sub(1, 1)
                if pfx == "@" or pfx == "=" then
                    local d = checkCandidate(info.source:sub(2))
                    if d then return d end
                end
            end
        end
    end
    if os and os.getenv then
        local d = checkCandidate(os.getenv("_"))
        if d then return d end
    end
    return defaultDir
end

local scriptDir = resolveScriptDir("/home/qft")

local CONFIG_PATH = filesystem.concat(scriptDir, "config.cfg")
local BACKUP_CONFIG_PATH = "/home/config.qft.bak"
local SHRC_PATH = "/home/.shrc"

do
    local prevPath = package.path
    package.path = string.format("%s/?.lua;%s/?/init.lua;%s", scriptDir, scriptDir, prevPath)
    for _, m in ipairs({ "lib.recipes_db", "lib.hardware", "lib.scheduler", "lib.ui" }) do
        package.loaded[m] = nil
    end
end

local Hardware = require("lib.hardware")
local Scheduler = require("lib.scheduler")
local UI = require("lib.ui")

local function readWholeFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local d = f:read("*a")
    f:close()
    return d
end

local function writeWholeFile(path, content)
    local parent = filesystem.path(path)
    if parent and parent ~= "" and not filesystem.exists(parent) then filesystem.makeDirectory(parent) end
    local f, err = io.open(path, "w")
    if not f then return false, err end
    f:write(content)
    f:close()
    return true
end

local function loadConfig()
    for _, path in ipairs({ CONFIG_PATH, BACKUP_CONFIG_PATH }) do
        local raw = readWholeFile(path)
        if type(raw) == "string" and #raw > 0 then
            local ok, tbl = pcall(serialization.unserialize, raw)
            if ok and type(tbl) == "table" then
                return Scheduler.normalizeConfig(tbl), (path == CONFIG_PATH) and "exists" or "restored"
            end
        end
    end
    return Scheduler.defaultConfig(), "defaults"
end

local function saveConfig(cfg)
    local raw = serialization.serialize(cfg)
    if writeWholeFile(CONFIG_PATH, raw) then
        writeWholeFile(BACKUP_CONFIG_PATH, raw)
        return true
    end
    return false
end

local function wdNow()
    if computer and computer.uptime then return computer.uptime() end
    return os.clock and os.clock() or 0
end

local function armShellReviveWatchdog(cfg)
    local okEv, evLib = pcall(require, "event")
    if not okEv or type(evLib) ~= "table" or type(evLib.listen) ~= "function" then
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
    wd.meshPort = tonumber(cfg and cfg.meshPort) or 4205
    wd.armed = true
    if not wd.hooked then
        wd.hooked = true
        evLib.listen("key_down", function()
            wd.lastKeyAt = wdNow()
        end)
        evLib.listen("modem_message", function(_, _, _, port, _, msgType)
            if not wd.armed then return end
            if msgType ~= "GTNH_WAKE" then return end
            if port ~= wd.meshPort and port ~= 0 then return end
            local sh = readWholeFile(SHRC_PATH) or ""
            local autostartOn = false
            for line in sh:gmatch("[^\r\n]+") do
                if not line:match("^%s*#") and (line:find("qft", 1, true) ~= nil) then
                    local cmd = line:match("^%s*(%S+)") or ""
                    if cmd == "qft" or cmd == "/usr/bin/qft" or cmd == "/usr/bin/qft.lua" or cmd == "/home/qft/main.lua" then
                        autostartOn = true
                        break
                    end
                end
            end
            if not autostartOn then return end
            local holdExists = (filesystem and filesystem.exists and filesystem.exists("/tmp/gtnh_hold")) == true
            if not holdExists and io and io.open then
                local f = io.open("/tmp/gtnh_hold", "r")
                if f then f:close(); holdExists = true end
            end
            if holdExists then return end
            local cur = wdNow()
            if (cur - (wd.exitAt or cur)) < 30 or (cur - (wd.lastKeyAt or cur)) < 30 then
                return
            end
            wd.armed = false
            if computer and computer.shutdown then pcall(computer.shutdown, true) end
        end)
    end
    return true
end

local function disarmShellReviveWatchdog()
    local wd = rawget(_G, "__gtnhReviveWd")
    if type(wd) == "table" then wd.armed = false end
end

local function handlePendingRebootOrUpdate(state)
    if not state or (not state._pendingReboot and not state._pendingUpdateUrl) then return false end
    if state._pendingUpdateUrl then
        local instPath = filesystem.concat(scriptDir, "install.lua")
        local chunk, loadErr = loadfile(instPath)
        if not chunk then
            io.stderr:write("Remote QFT update failed to load installer: " .. tostring(loadErr) .. "\n")
            state._pendingUpdateUrl = nil
            state._pendingReboot = nil
            return false
        end
        local hasInet = (component.isAvailable and component.isAvailable("internet"))
            or (component.list and component.list("internet", true)() ~= nil)
        local updArgs = { "--url", state._pendingUpdateUrl, "--update", "--yes" }
        if not hasInet then updArgs[#updArgs + 1] = "--mesh-relay" end
        local okCall, instRes, instErr = pcall(chunk, table.unpack(updArgs))
        state._pendingUpdateUrl = nil
        if (not okCall) or instRes == false then
            io.stderr:write("Remote QFT update failed: " .. tostring(okCall and instErr or instRes) .. "\n")
            state._pendingReboot = nil
            return false
        end
    end
    if state._pendingReboot then
        state._pendingReboot = nil
        if computer and computer.shutdown then computer.shutdown(true) end
        return true
    end
    return false
end

local function isQftShrcLine(line)
    if line:match("^%s*#") then return false end
    return line:find("/home/qft/main.lua", 1, true) ~= nil
        or line:find("/usr/bin/qft", 1, true) ~= nil
        or line:match("^%s*qft%s*$") ~= nil
        or line:match("^%s*qft%s+") ~= nil
end

local function isAutostartEnabled()
    local raw = readWholeFile(SHRC_PATH)
    if type(raw) ~= "string" then return false end
    for line in raw:gmatch("[^\r\n]+") do
        if isQftShrcLine(line) then return true end
    end
    return false
end

local function setAutostartEnabled(enable)
    local raw = readWholeFile(SHRC_PATH) or ""
    local lines = {}
    for line in raw:gmatch("[^\r\n]+") do
        if not isQftShrcLine(line) then lines[#lines + 1] = line end
    end
    if enable then
        local hasDisplay = (component.list("screen", true)() ~= nil) and (component.list("gpu", true)() ~= nil)
        local cmd = filesystem.exists("/usr/bin/qft.lua") and "qft" or "/home/qft/main.lua"
        if not hasDisplay then cmd = cmd .. " --worker" end
        lines[#lines + 1] = cmd
    end
    writeWholeFile(SHRC_PATH, (#lines > 0) and (table.concat(lines, "\n") .. "\n") or "")
    return enable
end

local function runCheck()
    local cfg, src = loadConfig()
    local st = Scheduler.newState()
    local disc = Scheduler.syncHardware(cfg, st)
    Scheduler.step(cfg, st, computer.uptime(), nil, { dryRun = true })
    print("=== GTNH QFT CONTROL READ-ONLY CHECK ===")
    print(string.format("Config File : %s (%s)", CONFIG_PATH, src))
    print(string.format("Units       : %d | Armed=%s | LocalRules=%d", #(cfg.units or {}), tostring(cfg.armed), #(cfg.localRules or {})))
    print(string.format("Hardware    : QFT=%d Bus=%d Hatch=%d AE=%d", #(disc.controllers or {}), #(disc.inputBuses or {}), #(disc.inputHatches or {}), #(disc.aeInterfaces or {})))
end

local function runWorker()
    while true do
        disarmShellReviveWatchdog()
        local cfg = loadConfig()
        local state = Scheduler.newState()
        local disc = Scheduler.syncHardware(cfg, state)
        if #(cfg.units or {}) == 0 and #(disc.controllers or {}) > 0 then
            Scheduler.autoBindDiscoveredUnits(cfg, disc)
            saveConfig(cfg)
        end
        Hardware.openMeshPort(cfg, nil, state)
        local userExit = false
        local function rpcCall(cmd)
            return Scheduler.executeRpcTable(cfg, state, cmd, nil, function(c) saveConfig(c) end)
        end
        local okLoop, errLoop = xpcall(function()
            local running = true
            while running do
                Scheduler.step(cfg, state, computer.uptime())
                Hardware.pushMeshMetrics(cfg, state, computer.uptime())
                local deadline = computer.uptime() + (cfg.pollSec or 5)
                while running and computer.uptime() < deadline do
                    local evTbl = { event.pull(math.max(0.05, deadline - computer.uptime())) }
                    local evName = evTbl[1]
                    if evName == "interrupted" then
                        running = false; userExit = true; break
                    elseif evName == "modem_message" then
                        Hardware.handleMeshMessage(cfg, state, evTbl[2], evTbl[3], evTbl[4], evTbl[6], evTbl[7], evTbl[8], nil, rpcCall)
                    elseif state._pendingReboot then
                        running = false; userExit = true; break
                    end
                end
            end
        end, debug.traceback)
        pcall(saveConfig, cfg)
        if state._pendingReboot or state._pendingUpdateUrl then
            if handlePendingRebootOrUpdate(state) then return end
            userExit = false; okLoop = false; errLoop = "remote update aborted"
        end
        if userExit then
            print("QFT Control worker stopped cleanly.")
            armShellReviveWatchdog(cfg)
            return
        elseif not okLoop then io.stderr:write("QFT worker fault: " .. tostring(errLoop) .. "\n"); os.sleep(2)
        else
            armShellReviveWatchdog(cfg)
            return
        end
    end
end

local function runGUI()
    while true do
        disarmShellReviveWatchdog()
        local cfg = loadConfig()
        local state = Scheduler.newState()
        local disc = Scheduler.syncHardware(cfg, state)
        if #(cfg.units or {}) == 0 and #(disc.controllers or {}) > 0 then
            Scheduler.autoBindDiscoveredUnits(cfg, disc)
            saveConfig(cfg)
        end
        Hardware.openMeshPort(cfg, nil, state)
        if (not disc.hasGpu) or (not disc.hasScreen) then runWorker(); return end

        local ui = UI.new(cfg, state, saveConfig, nil, {
            isAutostartEnabled = isAutostartEnabled,
            toggleAutostart = function() return setAutostartEnabled(not isAutostartEnabled()) end,
        })
        local function rpcCall(cmd)
            return Scheduler.executeRpcTable(cfg, state, cmd, nil, function(c) saveConfig(c) end)
        end
        local userExit = false
        local okLoop, errLoop = xpcall(function()
            Scheduler.step(cfg, state, computer.uptime())
            ui:render()
            local lastDigest = Scheduler.renderDigest(cfg, state)
            local nextPoll = computer.uptime() + (cfg.pollSec or 5)
            while ui.running do
                local evTbl = { event.pull(math.max(0.05, nextPoll - computer.uptime())) }
                local evName = evTbl[1]
                local dirty = false
                if evName == "interrupted" or state._pendingReboot then
                    userExit = true; ui.running = false; break
                elseif evName == "modem_message" then
                    if Hardware.handleMeshMessage(cfg, state, evTbl[2], evTbl[3], evTbl[4], evTbl[6], evTbl[7], evTbl[8], nil, rpcCall) then
                        dirty = true
                    end
                elseif evName == "touch" then
                    ui:handleTouch(math.floor(tonumber(evTbl[3]) or 0), math.floor(tonumber(evTbl[4]) or 0))
                elseif evName == "scroll" then
                    ui:handleScroll(tonumber(evTbl[5]) or 0)
                elseif evName == "key_down" then
                    ui:handleKeyDown(tonumber(evTbl[3]) or 0, tonumber(evTbl[4]) or 0)
                end
                if ui.running and computer.uptime() >= nextPoll then
                    Scheduler.step(cfg, state, computer.uptime())
                    Hardware.pushMeshMetrics(cfg, state, computer.uptime())
                    nextPoll = computer.uptime() + (cfg.pollSec or 5)
                    local curDigest = Scheduler.renderDigest(cfg, state)
                    if curDigest ~= lastDigest then dirty = true; lastDigest = curDigest end
                end
                if dirty and ui.running then ui:render() end
            end
            if not ui.running then userExit = true end
        end, debug.traceback)
        pcall(saveConfig, cfg)
        term.clear()
        if state._pendingReboot or state._pendingUpdateUrl then
            if handlePendingRebootOrUpdate(state) then return end
            userExit = false; okLoop = false; errLoop = "remote update aborted"
        end
        if userExit or okLoop then
            print("GTNH QFT Control stopped cleanly.")
            armShellReviveWatchdog(cfg)
            return
        else io.stderr:write("GTNH QFT Control fault: " .. tostring(errLoop) .. "\n"); os.sleep(2) end
    end
end

for i = 1, #cliArgs do
    local a = tostring(cliArgs[i])
    if a == "--help" or a == "-h" then
        print("GTNH QFT Control: qft [--worker|--check|--off|--autostart on|off|--update]"); return
    elseif a == "--check" or a == "check" then runCheck(); return
    elseif a == "--off" or a == "off" then
        local cfg = loadConfig(); cfg.armed = false; saveConfig(cfg)
        local st = Scheduler.newState(); Scheduler.syncHardware(cfg, st); Scheduler.step(cfg, st, computer.uptime())
        print("QFT Control disarmed."); return
    elseif a == "--autostart" or a == "autostart" then
        local nxt = tostring(cliArgs[i + 1] or ""):lower()
        local en = (nxt == "on" or nxt == "true") and true or ((nxt == "off" or nxt == "false") and false or not isAutostartEnabled())
        setAutostartEnabled(en); print("QFT Autostart: " .. (en and "ON" or "OFF")); return
    elseif a == "--worker" or a == "worker" or a == "--headless" then runWorker(); return
    elseif a == "--update" or a == "update" then
        local chunk = assert(loadfile(filesystem.concat(scriptDir, "install.lua")))
        chunk("--update"); return
    end
end
runGUI()
