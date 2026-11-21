-- /home/bhc/main.lua
-- GTNH Black Hole Compressor Controller Daemon & Touch Control Center
-- Usage:
--   bhc             (160x50 Touch GUI, or headless fallback)
--   bhc --worker    (headless daemon)
--   bhc --check     (read-only dry-run)
--   bhc --off       (disarm BHC cleanly)
--   bhc --update    (update scripts while preserving config.cfg)

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

local scriptDir = resolveScriptDir("/home/bhc")
local CONFIG_PATH = filesystem.concat(scriptDir, "config.cfg")
local BACKUP_CONFIG_PATH = "/home/config.bhc.bak"
local SHRC_PATH = "/home/.shrc"

do
    local prevPath = package.path
    local commonPat = "/usr/lib/?.lua"
    local localCommonPat = filesystem.concat(scriptDir, "../common/?.lua")
    package.path = string.format("%s/?.lua;%s/?/init.lua;%s;%s;%s", scriptDir, scriptDir, commonPat, localCommonPat, prevPath)
    for _, m in ipairs({ "gtnh_common", "lib.hardware", "lib.scheduler", "lib.ui" }) do
        package.loaded[m] = nil
    end
end

local okCommon, Common = pcall(require, "gtnh_common")
if not okCommon then
    local instPath = filesystem.concat(scriptDir, "install.lua")
    local ch = loadfile and loadfile(instPath) or nil
    if not ch and io and io.open then
        local f = io.open(instPath, "r")
        if f then local src = f:read("*a"); f:close(); ch = load(src, "=" .. instPath) end
    end
    if ch then
        pcall(ch, "--update", "--yes", "--no-prompt")
        package.loaded["gtnh_common"] = nil
        okCommon, Common = pcall(require, "gtnh_common")
        if not okCommon then
            pcall(ch, "--local-bridge", "--update", "--yes", "--no-prompt")
            package.loaded["gtnh_common"] = nil
            okCommon, Common = pcall(require, "gtnh_common")
        end
    end
    if not okCommon then
        error("Missing /usr/lib/gtnh_common.lua: " .. tostring(Common))
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

local isBhcShrcLine = Common.makeShrcMatcher({
    "bhc", "/usr/bin/bhc", "/usr/bin/bhc.lua", "/home/bhc/main.lua",
})

local function armShellReviveWatchdog(cfg)
    return Common.armShellReviveWatchdog({
        isAutostartFn = isBhcShrcLine,
        shrcPath = SHRC_PATH,
        meshPort = tonumber(cfg and cfg.meshPort) or Common.MESH_PORT,
        wakeMsg = Common.WAKE_MSG,
        enabled = (cfg == nil or cfg.autoWake ~= false),
    })
end

local function disarmShellReviveWatchdog()
    Common.disarmShellReviveWatchdog()
end

local function handlePendingRebootOrUpdate(state)
    if not state or (not state._pendingReboot and not state._pendingUpdateUrl) then return false end
    if state._pendingUpdateUrl then
        local instPath = filesystem.concat(scriptDir, "install.lua")
        local chunk, loadErr = loadfile(instPath)
        if not chunk then
            io.stderr:write("Remote BHC update failed to load installer: " .. tostring(loadErr) .. "\n")
            state._pendingUpdateUrl = nil
            state._pendingReboot = nil
            return false
        end
        local tx = Common.detectOtaTransport(component)
        local updArgs = Common.buildInstallerArgs(state._pendingUpdateUrl, { viaMesh = tx.viaMesh })
        local okCall, instRes, instErr = pcall(chunk, table.unpack(updArgs))
        state._pendingUpdateUrl = nil
        if (not okCall) or instRes == false then
            io.stderr:write("Remote BHC update failed: " .. tostring(okCall and instErr or instRes) .. "\n")
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

local function isAutostartEnabled()
    local raw = readWholeFile(SHRC_PATH)
    if type(raw) ~= "string" then return false end
    for line in raw:gmatch("[^\r\n]+") do
        if isBhcShrcLine(line) then return true end
    end
    return false
end

local function setAutostartEnabled(enable)
    local raw = readWholeFile(SHRC_PATH) or ""
    local lines = {}
    for line in raw:gmatch("[^\r\n]+") do
        if not isBhcShrcLine(line) then lines[#lines + 1] = line end
    end
    if enable then
        local hasDisplay = (component.list("screen", true)() ~= nil) and (component.list("gpu", true)() ~= nil)
        local cmd = filesystem.exists("/usr/bin/bhc.lua") and "bhc" or "/home/bhc/main.lua"
        if not hasDisplay then cmd = cmd .. " --worker" end
        lines[#lines + 1] = cmd
    end
    writeWholeFile(SHRC_PATH, (#lines > 0) and (table.concat(lines, "\n") .. "\n") or "")
    return enable
end

local function maybeHandleRedstoneEvent(cfg, state, evTbl)
    if evTbl[1] ~= "redstone_changed" then return false end
    local addr, side, oldV, newV = evTbl[2], tonumber(evTbl[3]) or -1, tonumber(evTbl[4]) or 0, tonumber(evTbl[5]) or 0
    if cfg.utilityRedstoneAddr ~= "" and addr ~= cfg.utilityRedstoneAddr then return false end
    if side ~= Hardware.toSideNum(cfg.utilitySide) then return false end
    state.lastUtilitySig = newV
    if cfg.utilityMode ~= "static" and oldV == 0 and newV > 0 then
        Scheduler.onUtilityPulse(cfg, state, computer.uptime(), { compLib = component })
        Scheduler.step(cfg, state, computer.uptime())
        return true
    elseif cfg.utilityMode == "static" then
        Scheduler.step(cfg, state, computer.uptime())
        return true
    end
    return false
end

local function runCheck()
    local cfg, src = loadConfig()
    local st = Scheduler.newState()
    local disc = Scheduler.syncHardware(cfg, st)
    Scheduler.step(cfg, st, computer.uptime(), nil, { dryRun = true })
    print("=== GTNH BHC CONTROL READ-ONLY CHECK ===")
    print(string.format("Config File : %s (%s)", CONFIG_PATH, src))
    print(string.format("Preset/Seed : %s / %s | Armed=%s | Utility=%s", tostring(cfg.preset), tostring(cfg.seedMode), tostring(cfg.armed), tostring(cfg.utilityMode)))
    print(string.format("Hardware    : BHC=%d RS=%d TP=%d AE=%d | Tier=%s (%dx)",
        #(disc.controllers or {}), #(disc.redstones or {}), #(disc.transposers or {}), #(disc.aeInterfaces or {}),
        tostring(st.machine.tierName), tonumber(st.machine.baseParallels) or 0))
end

local function runWorker()
    while true do
        disarmShellReviveWatchdog()
        local cfg = loadConfig()
        local state = Scheduler.newState()
        Scheduler.syncHardware(cfg, state)
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
                local deadline = computer.uptime() + (cfg.pollSec or 1)
                while running and computer.uptime() < deadline do
                    local evTbl = { event.pull(math.max(0.05, deadline - computer.uptime())) }
                    local evName = evTbl[1]
                    if evName == "interrupted" then
                        running = false; userExit = true; break
                    elseif evName == "redstone_changed" then
                        maybeHandleRedstoneEvent(cfg, state, evTbl)
                        Hardware.pushMeshMetrics(cfg, state, computer.uptime())
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
            print("BHC Control worker stopped cleanly.")
            armShellReviveWatchdog(cfg)
            return
        elseif not okLoop then io.stderr:write("BHC worker fault: " .. tostring(errLoop) .. "\n"); os.sleep(2)
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
        Hardware.openMeshPort(cfg, nil, state)
        if (not disc.hasGpu) and component.list("gpu", true)() == nil then runWorker(); return end
        if component.list("screen", true)() == nil then runWorker(); return end

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
            local nextPoll = computer.uptime() + (cfg.pollSec or 1)
            while ui.running do
                local evTbl = { event.pull(math.max(0.05, nextPoll - computer.uptime())) }
                local evName = evTbl[1]
                local dirty = false
                if evName == "interrupted" or state._pendingReboot then
                    userExit = true; ui.running = false; break
                elseif evName == "screen_resized" then
                    if ui and ui.syncDisplay and ui:syncDisplay(true) then dirty = true end
                elseif evName == "redstone_changed" then
                    if maybeHandleRedstoneEvent(cfg, state, evTbl) then dirty = true end
                elseif evName == "modem_message" then
                    if Hardware.handleMeshMessage(cfg, state, evTbl[2], evTbl[3], evTbl[4], evTbl[6], evTbl[7], evTbl[8], nil, rpcCall) then
                        dirty = true
                    end
                elseif evName == "touch" then
                    dirty = ui:handleTouch(math.floor(tonumber(evTbl[3]) or 0), math.floor(tonumber(evTbl[4]) or 0))
                elseif evName == "key_down" then
                    dirty = ui:handleKeyDown(tonumber(evTbl[3]) or 0, tonumber(evTbl[4]) or 0)
                end
                if ui.running and computer.uptime() >= nextPoll then
                    Scheduler.step(cfg, state, computer.uptime())
                    Hardware.pushMeshMetrics(cfg, state, computer.uptime())
                    nextPoll = computer.uptime() + (cfg.pollSec or 1)
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
            print("GTNH BHC Control stopped cleanly.")
            armShellReviveWatchdog(cfg)
            return
        else io.stderr:write("GTNH BHC Control fault: " .. tostring(errLoop) .. "\n"); os.sleep(2) end
    end
end

for i = 1, #cliArgs do
    local a = tostring(cliArgs[i])
    if a == "--help" or a == "-h" then
        print("GTNH BHC Control: bhc [--worker|--check|--off|--autostart on|off|--update]"); return
    elseif a == "--check" or a == "check" then runCheck(); return
    elseif a == "--off" or a == "off" then
        local cfg = loadConfig(); cfg.armed = false; saveConfig(cfg)
        print("BHC Control disarmed."); return
    elseif a == "--autostart" or a == "autostart" then
        local nxt = tostring(cliArgs[i + 1] or ""):lower()
        local en = (nxt == "on" or nxt == "true") and true or ((nxt == "off" or nxt == "false") and false or not isAutostartEnabled())
        setAutostartEnabled(en); print("BHC Autostart: " .. (en and "ON" or "OFF")); return
    elseif a == "--worker" or a == "worker" or a == "--headless" then runWorker(); return
    elseif a == "--update" or a == "update" then
        local chunk = assert(loadfile(filesystem.concat(scriptDir, "install.lua")))
        chunk("--update"); return
    end
end

runGUI()
