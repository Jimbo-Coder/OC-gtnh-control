-- /home/gorge/main.lua
-- GTNH Forge of the Gods & Multi-Exoticizer Controller
-- Usage:
--   gorge            (160x50 Touch GUI, or --worker fallback if headless)
--   gorge --worker   (headless daemon)
--   gorge --check    (read-only hardware & batch preview dry-run)
--   gorge --off      (disarm, cancel active fake crafts, & reset patterns)
--   gorge --update   (update code while preserving config.cfg)

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

local scriptDir = resolveScriptDir("/home/gorge")

local CONFIG_PATH = filesystem.concat(scriptDir, "config.cfg")
local BACKUP_CONFIG_PATH = "/home/config.gorge.bak"
local INFLIGHT_PATH = filesystem.concat(scriptDir, "inflight.dat")
local BACKUP_INFLIGHT_PATH = "/home/inflight.gorge.bak"
local SHRC_PATH = "/home/.shrc"

do
    local prevPath = package.path
    package.path = string.format("%s/?.lua;%s/?/init.lua;%s", scriptDir, scriptDir, prevPath)
    for _, modName in ipairs({ "lib.plasmas", "lib.hardware", "lib.scheduler", "lib.ui" }) do
        package.loaded[modName] = nil
    end
end

local Hardware = require("lib.hardware")
local Scheduler = require("lib.scheduler")
local UI = require("lib.ui")

local function readWholeFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local function writeWholeFile(path, content)
    local parent = filesystem.path(path)
    if parent and parent ~= "" and not filesystem.exists(parent) then
        filesystem.makeDirectory(parent)
    end
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
    local ok = writeWholeFile(CONFIG_PATH, raw)
    if ok then
        writeWholeFile(BACKUP_CONFIG_PATH, raw)
    end
    return ok
end

local function persistInflight(state)
    if state and state._inflightDirty then
        Scheduler.saveInflight(INFLIGHT_PATH, state, BACKUP_INFLIGHT_PATH)
    end
end

local function isGorgeShrcLine(line)
    if line:match("^%s*#") then return false end
    return line:find("/home/gorge/main.lua", 1, true) ~= nil
        or line:find("/usr/bin/gorge", 1, true) ~= nil
        or line:match("^%s*gorge%s*$") ~= nil
        or line:match("^%s*gorge%s+") ~= nil
end

local function isAutostartEnabled()
    local raw = readWholeFile(SHRC_PATH)
    if type(raw) ~= "string" then return false end
    for line in raw:gmatch("[^\r\n]+") do
        if isGorgeShrcLine(line) then return true end
    end
    return false
end

local function setAutostartEnabled(enable)
    local raw = readWholeFile(SHRC_PATH) or ""
    local lines = {}
    for line in raw:gmatch("[^\r\n]+") do
        if not isGorgeShrcLine(line) then
            lines[#lines + 1] = line
        end
    end
    if enable then
        local hasDisplay = (component.list("screen", true)() ~= nil) and (component.list("gpu", true)() ~= nil)
        local cmd = filesystem.exists("/usr/bin/gorge.lua") and "gorge" or "/home/gorge/main.lua"
        if not hasDisplay then cmd = cmd .. " --worker" end
        lines[#lines + 1] = cmd
    end
    local body = (#lines > 0) and (table.concat(lines, "\n") .. "\n") or ""
    writeWholeFile(SHRC_PATH, body)
    return enable
end

local function printHelp()
    print("GTNH Gorge & Multi-Exoticizer Control")
    print("Usage:")
    print("  gorge                  Launch 160x50 Touch Control Center (or --worker if headless)")
    print("  gorge --worker         Run headless scheduler daemon (auto-restarts on fault)")
    print("  gorge --check          Read-only hardware, Godforge & Exoticizer batch dry-run check")
    print("  gorge --unstick        Recover stranded IO Port cells, cancel fake crafts & reset patterns")
    print("  gorge --autostart on|off  Enable or disable boot autostart in /home/.shrc")
    print("  gorge --off            Disarm, cancel active fake crafts, and set idle patterns")
    print("  gorge --update         Update scripts cleanly while preserving config.cfg")
end

local function dispatchEvent(cfg, state, evTbl, ui)
    local evName = evTbl[1]
    if not evName then return false, false end

    if evName == "interrupted" then
        return false, true
    elseif evName == "modem_message" then
        local handled = Hardware.handleMeshMessage(cfg, state, evTbl[2], evTbl[3], evTbl[4], evTbl[6], evTbl[7], evTbl[8])
        return handled, false
    elseif ui then
        if evName == "touch" then
            return ui:handleTouch(math.floor(tonumber(evTbl[3]) or 0), math.floor(tonumber(evTbl[4]) or 0), evTbl[5]), false
        elseif evName == "scroll" then
            ui:handleScroll(tonumber(evTbl[5]) or 0)
            return true, false
        elseif evName == "key_down" then
            ui:handleKeyDown(tonumber(evTbl[3]) or 0, tonumber(evTbl[4]) or 0)
            return true, false
        end
    end
    return false, false
end

local function runCheck()
    local cfg, cfgSource = loadConfig()
    local state = Scheduler.newState()
    local disc = Scheduler.syncHardware(cfg, state)
    Scheduler.step(cfg, state, computer.uptime(), { dryRun = true })

    local gf = state.godforge or {}
    print("=== GTNH GORGE & EXOTICIZER READ-ONLY CHECK ===")
    print(string.format("Config File   : %s (%s)", CONFIG_PATH, cfgSource))
    print(string.format("Saved State   : %s | ExtLink: %s | LSC: %s",
        cfg.armed and "ARMED" or "PAUSED (Safe)", cfg.extLinkMode or "auto",
        state.lscPct and string.format("%.1f%%", state.lscPct) or "--"))
    print(string.format("Godforge Ctrl : %s (Online=%s Active=%s WorkAllowed=%s Rings=%s Conn=%s)",
        Hardware.shortAddr(cfg.godforge.controllerAddr), tostring(gf.online), tostring(gf.active),
        tostring(gf.workAllowed), tostring(gf.rings or "-"), tostring(gf.connected or "-")))
    print(string.format("Hardware      : IF=%d TP=%d RS=%d DB=%d GT=%d",
        #(disc.interfaces or {}), #(disc.transposers or {}), #(disc.redstones or {}),
        #(disc.databases or {}), #(disc.machines or {})))
    print("")
    for i, ex in ipairs(cfg.exoticizers or {}) do
        local es = state.exStates and state.exStates[ex.id or i] or {}
        print(string.format("  [%d] %-14s Mode=%-9s Eff=%-9s RS=%d Outputs=%d Cycles=%d (%s)",
            i, ex.name, ex.mode, es.activeMode or ex.mode, es.rsSignal or 0, es.distinctOutputs or 0,
            es.completedCycles or 0, es.phase or "IDLE"))
    end
    print("=== CHECK COMPLETE (NO PATTERNS OR WORK MODIFIED) ===")
end

local function handlePendingRebootOrUpdate(state)
    if state._pendingUpdateUrl then
        local updUrl = state._pendingUpdateUrl
        state._pendingUpdateUrl = nil
        local instPath = filesystem.concat(scriptDir, "install.lua")
        local f = io.open(instPath, "r")
        local chunk, loadErr
        if f then
            local src = f:read("*a")
            f:close()
            chunk, loadErr = load(src or "", "=" .. instPath)
        else
            loadErr = "missing " .. tostring(instPath)
        end
        if chunk then
            print("Gorge Control updating from " .. updUrl .. "...")
            local okU, okInst = pcall(chunk, "--url", updUrl, "--update", "--yes")
            if okU and okInst ~= false then
                pcall(os.sleep, 0.15)
                if computer.shutdown then pcall(computer.shutdown, true) end
                return true
            end
            io.stderr:write("Gorge Control remote update failed: " .. tostring(okInst) .. "\n")
            return false
        end
        io.stderr:write("Gorge Control updater load failed: " .. tostring(loadErr) .. "\n")
        return false
    elseif state._pendingReboot then
        print("GTNH Gorge Control rebooting per remote request...")
        pcall(os.sleep, 0.15)
        if computer.shutdown then pcall(computer.shutdown, true) end
        return true
    end
    return false
end

local function runWorker()
    while true do
        local cfg = loadConfig()
        local state = Scheduler.newState()
        Scheduler.loadInflight(INFLIGHT_PATH, state, BACKUP_INFLIGHT_PATH)
        Scheduler.syncHardware(cfg, state)
        Hardware.openMeshPort(cfg, nil, state)

        print("GTNH Gorge Control worker started (" .. (cfg.armed and "ARMED" or "PAUSED") .. "). Ctrl+C to stop.")
        local running = true
        local userExit = false
        local lastSave = computer.uptime()

        local okLoop, errLoop = xpcall(function()
            while running do
                local now = computer.uptime()
                state._forcePollNow = false
                Scheduler.step(cfg, state, now)
                persistInflight(state)
                Hardware.pushMeshMetrics(cfg, state, now)
                if (now - lastSave) >= 60.0 then
                    lastSave = now
                    saveConfig(cfg)
                end

                local deadline = computer.uptime() + Scheduler.nextWakeupDelay(cfg, state, computer.uptime())
                while running and computer.uptime() < deadline do
                    local timeout = math.max(0.05, deadline - computer.uptime())
                    local evTbl = { event.pull(timeout) }
                    local _, stopReq = dispatchEvent(cfg, state, evTbl, nil)
                    if stopReq or state._pendingReboot then
                        running = false
                        userExit = true
                        break
                    end
                    if state._forcePollNow then
                        break
                    end
                end
            end
        end, debug.traceback)

        pcall(saveConfig, cfg)
        pcall(persistInflight, state)
        if state._pendingReboot or state._pendingUpdateUrl then
            if handlePendingRebootOrUpdate(state) then return end
            userExit = false
            okLoop = false
            errLoop = "remote update aborted"
        end
        if userExit then
            print("Gorge Control worker stopped cleanly.")
            return
        elseif not okLoop then
            io.stderr:write("Gorge Control worker fault (restarting in 2s):\n" .. tostring(errLoop) .. "\n")
            os.sleep(2)
        else
            return
        end
    end
end

local function runGUI()
    while true do
        local cfg = loadConfig()
        local state = Scheduler.newState()
        Scheduler.loadInflight(INFLIGHT_PATH, state, BACKUP_INFLIGHT_PATH)
        Scheduler.syncHardware(cfg, state)
        Hardware.openMeshPort(cfg, nil, state)

        local disc = state.discovery or {}
        if (not disc.hasGpu) or (not disc.hasScreen) then
            runWorker()
            return
        end

        local savePending = false
        local saveDeadline = 0
        local function scheduleSave(c)
            savePending = true
            saveDeadline = computer.uptime() + 0.35
            cfg = c or cfg
        end
        local function flushSave()
            if savePending then
                savePending = false
                saveConfig(cfg)
            end
        end

        local extras = {
            isAutostartEnabled = isAutostartEnabled,
            toggleAutostart = function()
                return setAutostartEnabled(not isAutostartEnabled())
            end,
        }
        local ui = UI.new(cfg, state, scheduleSave, nil, extras)
        local userExit = false

        local okLoop, errLoop = xpcall(function()
            ui:render()
            local lastDigest = Scheduler.renderDigest(cfg, state)
            Scheduler.step(cfg, state, computer.uptime())
            persistInflight(state)
            local bootDigest = Scheduler.renderDigest(cfg, state)
            if bootDigest ~= lastDigest then
                ui:render()
                lastDigest = bootDigest
            end
            local nextPoll = computer.uptime() + Scheduler.nextWakeupDelay(cfg, state, computer.uptime())

            while ui.running do
                local dirty = false
                local now = computer.uptime()
                local waitSec = math.max(0.05, math.min(nextPoll - now, Scheduler.nextWakeupDelay(cfg, state, now)))
                if state._forcePollNow then waitSec = 0.01 end
                if savePending then waitSec = math.min(waitSec, math.max(0.02, saveDeadline - now)) end

                local evTbl = { event.pull(waitSec) }
                local evDirty, stopReq = dispatchEvent(cfg, state, evTbl, ui)
                if stopReq or state._pendingReboot then
                    savePending = true
                    userExit = true
                    ui.running = false
                    break
                end
                if evDirty then dirty = true end

                local curTime = computer.uptime()
                if ui.running and (state._forcePollNow == true or curTime >= nextPoll) then
                    state._forcePollNow = false
                    Scheduler.step(cfg, state, curTime)
                    persistInflight(state)
                    Hardware.pushMeshMetrics(cfg, state, curTime)
                    nextPoll = computer.uptime() + Scheduler.nextWakeupDelay(cfg, state, computer.uptime())
                    local curDigest = Scheduler.renderDigest(cfg, state)
                    if curDigest ~= lastDigest then
                        dirty = true
                    end
                end

                if savePending and computer.uptime() >= saveDeadline then
                    flushSave()
                end
                if dirty and ui.running then
                    ui:render()
                    lastDigest = Scheduler.renderDigest(cfg, state)
                end
            end
            if not ui.running then
                userExit = true
            end
        end, debug.traceback)

        flushSave()
        pcall(saveConfig, cfg)
        pcall(persistInflight, state)
        if component.isAvailable("gpu") then
            pcall(component.gpu.setBackground, 0x000000)
            pcall(component.gpu.setForeground, 0xFFFFFF)
        end
        term.clear()
        if state._pendingReboot or state._pendingUpdateUrl then
            if handlePendingRebootOrUpdate(state) then return end
            userExit = false
            okLoop = false
            errLoop = "remote update aborted"
        end
        if userExit or okLoop then
            print("GTNH Gorge Control stopped cleanly.")
            return
        else
            io.stderr:write("GTNH Gorge Control fault (restarting in 2s):\n" .. tostring(errLoop) .. "\n")
            os.sleep(2)
        end
    end
end

local function main(args)
    for i = 1, #(args or {}) do
        local a = tostring(args[i])
        if a == "--help" or a == "-h" then
            printHelp()
            return
        elseif a == "--check" or a == "check" then
            runCheck()
            return
        elseif a == "--unstick" or a == "unstick" then
            local cfg = loadConfig()
            local state = Scheduler.newState()
            Scheduler.loadInflight(INFLIGHT_PATH, state, BACKUP_INFLIGHT_PATH)
            Scheduler.syncHardware(cfg, state)
            local rec, can = Scheduler.unstickExoticizer(cfg, state, nil, nil, "manual")
            persistInflight(state)
            print(string.format("Gorge Control unstuck all (%d cell(s) recovered, %d craft(s) canceled, patterns reset).", rec, can))
            return
        elseif a == "--autostart" or a == "autostart" then
            local argNext = tostring(args[i + 1] or ""):lower()
            local enable = (argNext == "on" or argNext == "true" or argNext == "1") and true
                or ((argNext == "off" or argNext == "false" or argNext == "0") and false or (not isAutostartEnabled()))
            setAutostartEnabled(enable)
            print(string.format("Gorge Control boot autostart (/home/.shrc): %s", enable and "ENABLED" or "DISABLED"))
            return
        elseif a == "--off" or a == "off" then
            local cfg = loadConfig()
            cfg.armed = false
            local state = Scheduler.newState()
            Scheduler.syncHardware(cfg, state)
            local n = Scheduler.cancelAllFakeCrafts(cfg, state)
            persistInflight(state)
            saveConfig(cfg)
            print(string.format("Gorge Control disarmed (%d fake craft(s) canceled, slot-1 patterns reset).", n))
            return
        elseif a == "--worker" or a == "worker" then
            runWorker()
            return
        elseif a == "--update" or a == "update" then
            local instPath = filesystem.concat(scriptDir, "install.lua")
            local f = io.open(instPath, "r")
            if not f then
                io.stderr:write("ERROR: install.lua not found at " .. tostring(instPath) .. "\n")
                return
            end
            local src = f:read("*a")
            f:close()
            local chunk, err = load(src or "", "=" .. instPath)
            if not chunk then
                io.stderr:write("ERROR: Failed to load install.lua: " .. tostring(err) .. "\n")
                return
            end
            local extra = { "--update" }
            for j = i + 1, #args do extra[#extra + 1] = args[j] end
            chunk(table.unpack(extra))
            return
        end
    end
    runGUI()
end

main(cliArgs)
