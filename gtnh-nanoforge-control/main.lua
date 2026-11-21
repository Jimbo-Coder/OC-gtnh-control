-- /home/nanoforge/main.lua
-- GTNH Tier 4 Nano Forge Controller Daemon & Touch Control Center
-- Usage:
--   nanoforge             (160x50 Touch GUI, or headless fallback)
--   nanoforge --worker    (headless daemon)
--   nanoforge --check     (read-only dry-run)
--   nanoforge --off       (disarm cleanly)
--   nanoforge --update    (update scripts while preserving config.cfg)

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

local scriptDir = resolveScriptDir("/home/nanoforge")
local CONFIG_PATH = filesystem.concat(scriptDir, "config.cfg")
local BACKUP_CONFIG_PATH = "/home/config.nanoforge.bak"
local SHRC_PATH = "/home/.shrc"

do
    local prevPath = package.path
    local commonPat = "/usr/lib/?.lua"
    local localCommonPat = filesystem.concat(scriptDir, "../common/?.lua")
    package.path = string.format("%s/?.lua;%s/?/init.lua;%s;%s;%s", scriptDir, scriptDir, commonPat, localCommonPat, prevPath)
    for _, m in ipairs({ "gtnh_common", "lib.recipes_db", "lib.hardware", "lib.scheduler", "lib.ui" }) do
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

local isNanoShrcLine = Common.makeShrcMatcher({
    "nanoforge", "/usr/bin/nanoforge", "/usr/bin/nanoforge.lua", "/home/nanoforge/main.lua",
})

local function armShellReviveWatchdog(cfg)
    return Common.armShellReviveWatchdog({
        isAutostartFn = isNanoShrcLine,
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
            io.stderr:write("Remote Nano Forge update failed to load installer: " .. tostring(loadErr) .. "\n")
            state._pendingUpdateUrl = nil
            state._pendingReboot = nil
            return false
        end
        local tx = Common.detectOtaTransport(component)
        local updArgs = Common.buildInstallerArgs(state._pendingUpdateUrl, { viaMesh = tx.viaMesh })
        local okCall, instRes, instErr = pcall(chunk, table.unpack(updArgs))
        state._pendingUpdateUrl = nil
        if (not okCall) or instRes == false then
            io.stderr:write("Remote Nano Forge update failed: " .. tostring(okCall and instErr or instRes) .. "\n")
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
        if isNanoShrcLine(line) then return true end
    end
    return false
end

local function setAutostartEnabled(enable)
    local raw = readWholeFile(SHRC_PATH) or ""
    local lines = {}
    for line in raw:gmatch("[^\r\n]+") do
        if not isNanoShrcLine(line) then lines[#lines + 1] = line end
    end
    if enable then
        local hasDisplay = (component.list("screen", true)() ~= nil) and (component.list("gpu", true)() ~= nil)
        local cmd = filesystem.exists("/usr/bin/nanoforge.lua") and "nanoforge" or "/home/nanoforge/main.lua"
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
    print("=== GTNH TIER 4 NANO FORGE READ-ONLY CHECK ===")
    print(string.format("Config File : %s (%s)", CONFIG_PATH, src))
    print(string.format("Tier/Mode   : T%d / %s | Armed=%s | MagAvail=%d L",
        tonumber(cfg.forgeTier) or 4, tostring(cfg.mode), tostring(cfg.armed), tonumber(st.magAvailableL) or 0))
    print(string.format("Hardware    : NanoForge=%d TP=%d AE=%d | BusClean=%s",
        #(disc.controllers or {}), #(disc.transposers or {}), #(disc.aeInterfaces or {}),
        tostring(st.busScan and st.busScan.clean ~= false)))
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
                local deadline = computer.uptime() + (cfg.pollSec or 2)
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
            print("Nano Forge worker stopped cleanly.")
            armShellReviveWatchdog(cfg)
            return
        elseif not okLoop then io.stderr:write("Nano Forge worker fault: " .. tostring(errLoop) .. "\n"); os.sleep(2)
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
        Scheduler.syncHardware(cfg, state)
        Hardware.openMeshPort(cfg, nil, state)
        if component.list("gpu", true)() == nil then runWorker(); return end
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
            local nextPoll = computer.uptime() + (cfg.pollSec or 2)
            while ui.running do
                local evTbl = { event.pull(math.max(0.05, nextPoll - computer.uptime())) }
                local evName = evTbl[1]
                local dirty = false
                if evName == "interrupted" or state._pendingReboot then
                    userExit = true; ui.running = false; break
                elseif evName == "screen_resized" then
                    if ui and ui.syncDisplay and ui:syncDisplay(true) then dirty = true end
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
                    nextPoll = computer.uptime() + (cfg.pollSec or 2)
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
            print("GTNH Nano Forge Control stopped cleanly.")
            armShellReviveWatchdog(cfg)
            return
        else io.stderr:write("GTNH Nano Forge Control fault: " .. tostring(errLoop) .. "\n"); os.sleep(2) end
    end
end

for i = 1, #cliArgs do
    local a = tostring(cliArgs[i])
    if a == "--help" or a == "-h" then
        print("GTNH Nano Forge Control: nanoforge [--worker|--check|--off|--autostart on|off|--update]"); return
    elseif a == "--check" or a == "check" then runCheck(); return
    elseif a == "--off" or a == "off" then
        local cfg = loadConfig(); cfg.armed = false; saveConfig(cfg)
        print("Nano Forge Control disarmed."); return
    elseif a == "--autostart" or a == "autostart" then
        local nxt = tostring(cliArgs[i + 1] or ""):lower()
        local en = (nxt == "on" or nxt == "true") and true or ((nxt == "off" or nxt == "false") and false or not isAutostartEnabled())
        setAutostartEnabled(en); print("Nano Forge Autostart: " .. (en and "ON" or "OFF")); return
    elseif a == "--worker" or a == "worker" or a == "--headless" then runWorker(); return
    elseif a == "--update" or a == "update" then
        local chunk = assert(loadfile(filesystem.concat(scriptDir, "install.lua")))
        chunk("--update"); return
    end
end

runGUI()
