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
local shell = require("shell")
local term = require("term")

local scriptDir = filesystem.path(shell.getRunningProgram() or "/home/gorge/main.lua") or "/home/gorge"
if scriptDir == "" then scriptDir = "/home/gorge" end
if scriptDir:sub(-1) == "/" and #scriptDir > 1 then
    scriptDir = scriptDir:sub(1, -2)
end

local CONFIG_PATH = filesystem.concat(scriptDir, "config.cfg")
local BACKUP_CONFIG_PATH = "/home/config.gorge.bak"

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

local function printHelp()
    print("GTNH Gorge & Multi-Exoticizer Control")
    print("Usage:")
    print("  gorge            Launch 160x50 Touch Control Center (or --worker if headless)")
    print("  gorge --worker   Run headless scheduler daemon")
    print("  gorge --check    Read-only hardware, Godforge & Exoticizer batch dry-run check")
    print("  gorge --off      Disarm, cancel active fake crafts, and set idle patterns")
    print("  gorge --update   Update scripts cleanly while preserving config.cfg")
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

local function runWorker()
    local cfg = loadConfig()
    local state = Scheduler.newState()
    Scheduler.syncHardware(cfg, state)
    Hardware.openMeshPort(cfg, nil, state)

    print("GTNH Gorge Control worker started (" .. (cfg.armed and "ARMED" or "PAUSED") .. "). Ctrl+C to stop.")
    local running = true
    local lastSave = computer.uptime()

    local okLoop, errLoop = xpcall(function()
        while running do
            local now = computer.uptime()
            state._forcePollNow = false
            Scheduler.step(cfg, state, now)
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
                if stopReq then
                    running = false
                    break
                end
                if state._forcePollNow then
                    break
                end
            end
        end
    end, debug.traceback)

    pcall(saveConfig, cfg)
    if not okLoop then
        io.stderr:write("Gorge Control worker error:\n" .. tostring(errLoop) .. "\n")
    else
        print("Gorge Control worker stopped cleanly.")
    end
end

local function runGUI()
    local cfg = loadConfig()
    local state = Scheduler.newState()
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

    local ui = UI.new(cfg, state, scheduleSave)

    local okLoop, errLoop = xpcall(function()
        ui:render()
        local lastDigest = Scheduler.renderDigest(cfg, state)
        Scheduler.step(cfg, state, computer.uptime())
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
            if stopReq then
                savePending = true
                ui.running = false
                break
            end
            if evDirty then dirty = true end

            local curTime = computer.uptime()
            if ui.running and (state._forcePollNow == true or curTime >= nextPoll) then
                state._forcePollNow = false
                Scheduler.step(cfg, state, curTime)
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
    end, debug.traceback)

    flushSave()
    pcall(saveConfig, cfg)
    if component.isAvailable("gpu") then
        pcall(component.gpu.setBackground, 0x000000)
        pcall(component.gpu.setForeground, 0xFFFFFF)
    end
    term.clear()
    if okLoop then
        print("GTNH Gorge Control stopped cleanly.")
    else
        io.stderr:write("GTNH Gorge Control error:\n" .. tostring(errLoop) .. "\n")
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
        elseif a == "--off" or a == "off" then
            local cfg = loadConfig()
            cfg.armed = false
            local state = Scheduler.newState()
            Scheduler.syncHardware(cfg, state)
            local n = Scheduler.cancelAllFakeCrafts(cfg, state)
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
