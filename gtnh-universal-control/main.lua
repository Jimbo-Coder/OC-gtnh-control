-- /home/universal/main.lua
-- GTNH Universal Automation Controller (Toggle Bus + Bundled Redstone + SRTF Preemption)
-- Usage:
--   universal            (160x50 Touch GUI, or --worker fallback if headless)
--   universal --worker   (headless daemon)
--   universal --check    (read-only hardware, subnet, & SRTF dry-run)
--   universal --off      (immediately force all bundled redstone outputs OFF)
--   universal --update   (update code while preserving config.cfg)

local cliArgs = { ... }

local component = require("component")
local computer = require("computer")
local event = require("event")
local filesystem = require("filesystem")
local serialization = require("serialization")
local shell = require("shell")
local term = require("term")

local scriptDir = filesystem.path(shell.getRunningProgram() or "/home/universal/main.lua") or "/home/universal"
if scriptDir == "" then scriptDir = "/home/universal" end
if scriptDir:sub(-1) == "/" and #scriptDir > 1 then
    scriptDir = scriptDir:sub(1, -2)
end

local CONFIG_PATH = filesystem.concat(scriptDir, "config.cfg")
local BACKUP_CONFIG_PATH = "/home/config.universal.bak"

do
    local prevPath = package.path
    package.path = string.format("%s/?.lua;%s/?/init.lua;%s", scriptDir, scriptDir, prevPath)
    for _, modName in ipairs({ "lib.hardware", "lib.scheduler", "lib.ui" }) do
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
    print("GTNH Universal Control — Bundled Redstone + Toggle-Bus Scheduler")
    print("Usage:")
    print("  universal            Launch 160x50 Touch Control Center (or --worker if headless)")
    print("  universal --worker   Run headless scheduler daemon")
    print("  universal --check    Read-only hardware, subnet, & SRTF dry-run check")
    print("  universal --off      Immediately turn OFF all bundled redstone outputs")
    print("  universal --update   Update scripts cleanly while preserving config.cfg")
end

local function runCheck()
    local cfg, cfgSource = loadConfig()
    local state = Scheduler.newState()
    local disc = Scheduler.syncHardware(cfg, state)
    Scheduler.step(cfg, state, computer.uptime(), { dryRun = true })

    print("=== GTNH UNIVERSAL CONTROL READ-ONLY CHECK ===")
    print(string.format("Config File   : %s (%s)", CONFIG_PATH, cfgSource))
    print(string.format("Saved State   : %s | ExtLink: %s | IgnoreBuiltinNC: %s",
        cfg.armed and "ARMED" or "PAUSED (Safe)", cfg.extLinkMode or "auto", tostring(cfg.ignoreBuiltinNC ~= false)))
    print("")
    print(string.format("Redstone I/O  : %d discovered", #(disc.redstones or {})))
    for i, rs in ipairs(disc.redstones or {}) do
        print(string.format("  [%d] %s | Bundled=%s", i, rs.shortAddr, tostring(rs.bundled)))
    end
    print(string.format("Valid ME IFs  : %d full-block Dual/ME Interfaces", #(disc.interfaces or {})))
    for i, inf in ipairs(disc.interfaces or {}) do
        print(string.format("  [%d] %s (%s)", i, inf.shortAddr, inf.ctype))
    end
    if #(disc.partWarnings or {}) > 0 then
        print("Flat Part Interface Warnings:")
        for _, w in ipairs(disc.partWarnings) do
            print("  ! " .. w.message)
        end
    end
    print("")
    print(string.format("Pools (%d) & Active Queue (%d busy):", #cfg.pools, #(state.queue or {})))
    for _, q in ipairs(state.queue or {}) do
        print(string.format("  %s Color %02d (%s): %dI / %dL | ETA=%.1fs | Pri=%s",
            q.poolName, q.color, q.label, q.itemUnits, q.fluidUnits, q.etaSec or 0, tostring(q.priority)))
    end
    print("=== CHECK COMPLETE (NO REDSTONE MODIFIED) ===")
end

local function runWorker()
    local cfg = loadConfig()
    local state = Scheduler.newState()
    Scheduler.syncHardware(cfg, state)
    Hardware.zeroAllManagedPools(cfg)
    Hardware.openMeshPort(cfg)

    print("GTNH Universal Control worker started (" .. (cfg.armed and "ARMED" or "PAUSED") .. "). Ctrl+C to stop.")
    local running = true
    local lastRateSave = computer.uptime()

    local okLoop, errLoop = xpcall(function()
        while running do
            local now = computer.uptime()
            Scheduler.step(cfg, state, now)
            Hardware.pushMeshMetrics(cfg, state, now)
            if (now - lastRateSave) >= 60.0 then
                lastRateSave = now
                saveConfig(cfg)
            end

            local deadline = computer.uptime() + (tonumber(cfg.pollIntervalSec) or 0.5)
            while running and computer.uptime() < deadline do
                local timeout = math.max(0.05, deadline - computer.uptime())
                local ev, a0, a1, a2, a3, a4, a5, a6 = event.pull(timeout)
                if ev == "interrupted" then
                    running = false
                    break
                elseif ev == "modem_message" then
                    Hardware.handleMeshMessage(cfg, state, a0, a1, a2, a4, a5, a6)
                end
                if state._forcePollNow then
                    state._forcePollNow = false
                    break
                end
            end
        end
    end, debug.traceback)

    pcall(Hardware.zeroAllManagedPools, cfg)
    pcall(saveConfig, cfg)
    if not okLoop then
        io.stderr:write("Universal Control worker error:\n" .. tostring(errLoop) .. "\n")
    else
        print("Universal Control worker stopped cleanly (all bundled outputs OFF).")
    end
end

local function runGUI()
    local cfg = loadConfig()
    local state = Scheduler.newState()
    Scheduler.syncHardware(cfg, state)
    Hardware.zeroAllManagedPools(cfg)
    Hardware.openMeshPort(cfg)

    local disc = state.discovery or {}
    if (not disc.hasGpu) or (not disc.hasScreen) then
        runWorker()
        return
    end

    local savePending = false
    local saveDeadline = 0
    local lastPeriodicSave = computer.uptime()
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
        Scheduler.step(cfg, state, computer.uptime())
        ui:render()
        local nextPoll = computer.uptime() + (tonumber(cfg.pollIntervalSec) or 0.5)

        while ui.running do
            local dirty = false
            local now = computer.uptime()
            local forcePoll = (state._forcePollNow == true)
            local waitSec = forcePoll and 0.01 or math.max(0.05, nextPoll - now)
            if savePending then
                waitSec = math.min(waitSec, math.max(0.02, saveDeadline - now))
            end

            local ev, a0, a1, a2, a3, a4, a5, a6 = event.pull(waitSec)
            if ev == "interrupted" then
                savePending = true
                ui.running = false
                break
            elseif ev == "touch" then
                if ui:handleTouch(math.floor(tonumber(a1) or 0), math.floor(tonumber(a2) or 0), a3) then
                    dirty = true
                end
            elseif ev == "scroll" then
                ui:handleScroll(tonumber(a3) or 0)
                dirty = true
            elseif ev == "key_down" then
                ui:handleKeyDown(tonumber(a1) or 0, tonumber(a2) or 0)
                dirty = true
            elseif ev == "modem_message" then
                if Hardware.handleMeshMessage(cfg, state, a0, a1, a2, a4, a5, a6) then
                    dirty = true
                end
            end

            local curTime = computer.uptime()
            if ui.running and (state._forcePollNow == true or curTime >= nextPoll) then
                state._forcePollNow = false
                if ui.guidedDropActive and ui:stepGuidedDrop() then
                    dirty = true
                end
                Scheduler.step(cfg, state, curTime)
                Hardware.pushMeshMetrics(cfg, state, curTime)
                if (curTime - lastPeriodicSave) >= 60.0 then
                    lastPeriodicSave = curTime
                    saveConfig(cfg)
                end
                nextPoll = computer.uptime() + (tonumber(cfg.pollIntervalSec) or 0.5)
                dirty = true
            end

            if savePending and computer.uptime() >= saveDeadline then
                flushSave()
            end
            if dirty and ui.running then
                ui:render()
            end
        end
    end, debug.traceback)

    -- Always force all bundled outputs OFF before exiting or crashing!
    pcall(Hardware.zeroAllManagedPools, cfg)
    flushSave()
    pcall(saveConfig, cfg)
    if component.isAvailable("gpu") then
        pcall(component.gpu.setBackground, 0x000000)
        pcall(component.gpu.setForeground, 0xFFFFFF)
    end
    term.clear()
    if okLoop then
        print("GTNH Universal Control stopped cleanly (all bundled outputs OFF).")
    else
        io.stderr:write("GTNH Universal Control error:\n" .. tostring(errLoop) .. "\n")
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
            local c1 = Hardware.zeroAllManagedPools(cfg)
            local c2 = Hardware.zeroAllBundledSides()
            print(string.format("Forced all bundled redstone outputs OFF (%d managed side(s), %d redstone block(s)).", c1, c2))
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
