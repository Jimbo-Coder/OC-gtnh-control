-- /home/universal/main.lua
-- GTNH Universal Automation Controller (Multi-Channel Toggle Bus + Bundled Redstone + MLFQ Probe/Cache)
-- Usage:
--   universal            (160x50 Touch GUI, or --worker fallback if headless)
--   universal --worker   (headless daemon)
--   universal --check    (read-only hardware, subnet, & MLFQ schedule dry-run)
--   universal --off      (immediately force all bundled redstone outputs OFF)
--   universal --update   (update code while preserving config.cfg)

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

local scriptDir = resolveScriptDir("/home/universal")

local CONFIG_PATH = filesystem.concat(scriptDir, "config.cfg")
local BACKUP_CONFIG_PATH = "/home/config.universal.bak"
local RATES_CACHE_PATH = filesystem.concat(scriptDir, "rates.cache")
local BACKUP_RATES_PATH = "/home/rates.universal.bak"

do
    local prevPath = package.path
    package.path = string.format("%s/?.lua;%s/?/init.lua;%s", scriptDir, scriptDir, prevPath)
    for _, modName in ipairs({ "lib.hardware", "lib.policy", "lib.scheduler", "lib.ui" }) do
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

local function saveConfig(cfg, state)
    if state then
        Scheduler.exportPersistedRates(cfg, state)
    end
    local raw = serialization.serialize(cfg)
    local ok = writeWholeFile(CONFIG_PATH, raw)
    if ok then
        writeWholeFile(BACKUP_CONFIG_PATH, raw)
    end
    return ok
end

local function flushRatesIfDirty(state)
    if state and state._ratesDirty then
        Scheduler.saveRatesFile(RATES_CACHE_PATH, state, BACKUP_RATES_PATH)
    end
end

local function printHelp()
    print("GTNH Universal Control - Multi-Channel Bundled Toggle-Bus + MLFQ Scheduler")
    print("Usage:")
    print("  universal            Launch 160x50 Touch Control Center (or --worker if headless)")
    print("  universal --worker   Run headless scheduler daemon")
    print("  universal --check    Read-only hardware, subnet, & MLFQ dry-run check")
    print("  universal --off      Immediately turn OFF all bundled redstone outputs")
    print("  universal --update   Update scripts cleanly while preserving config.cfg")
end

local function dispatchEvent(cfg, state, evTbl, nowSec, ui)
    local evName = evTbl[1]
    if not evName then return false, false end

    if evName == "interrupted" then
        return false, true
    elseif evName == "network_item_changed" or evName == "network_fluid_changed" then
        local deltas = {}
        for i = 3, #evTbl do
            if type(evTbl[i]) == "table" then
                deltas[#deltas + 1] = evTbl[i]
            end
        end
        local changed = Scheduler.handleNetworkEvent(cfg, state, evName, evTbl[2], deltas, nowSec)
        if ui and ui.guidedDropActive then
            state._forcePollNow = true
            changed = true
        end
        return changed, false
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
    Scheduler.loadRatesFile(RATES_CACHE_PATH, state, cfg.maxRecipeCache, BACKUP_RATES_PATH)
    local disc = Scheduler.syncHardware(cfg, state)
    Scheduler.step(cfg, state, computer.uptime(), { dryRun = true, forceFullScan = true })

    print("=== GTNH UNIVERSAL CONTROL READ-ONLY CHECK ===")
    print(string.format("Config File   : %s (%s)", CONFIG_PATH, cfgSource))
    print(string.format("Saved State   : %s | ExtLink: %s | Subscribed: %s | IgnoreBuiltinNC: %s",
        cfg.armed and "ARMED" or "PAUSED (Safe)", cfg.extLinkMode or "auto",
        tostring(state._allSubscribed == true), tostring(cfg.ignoreBuiltinNC ~= false)))
    print("")
    print(string.format("Redstone I/O  : %d discovered", #(disc.redstones or {})))
    for i, rs in ipairs(disc.redstones or {}) do
        print(string.format("  [%d] %s | Bundled=%s", i, rs.shortAddr, tostring(rs.bundled)))
    end
    print(string.format("Valid ME IFs  : %d full-block Dual/ME Interfaces", #(disc.interfaces or {})))
    for i, inf in ipairs(disc.interfaces or {}) do
        print(string.format("  [%d] %s (%s, eventSub=%s)", i, inf.shortAddr, inf.ctype, tostring(inf.hasEventSub == true)))
    end
    if #(disc.partWarnings or {}) > 0 then
        print("Flat Part Interface Warnings:")
        for _, w in ipairs(disc.partWarnings) do
            print("  ! " .. w.message)
        end
    end
    print("")
    print(string.format("Pools (%d) & Active Queue (%d busy):", #cfg.pools, #(state.queue or {})))
    for _, p in ipairs(cfg.pools) do
        print(string.format("  Pool %d (%s): mode=%s slices=%d channels=%d",
            p.id, p.name, tostring(p.mode or "mlfq"), tonumber(p.numSlices) or 16, #(p.channels or {})))
    end
    for _, q in ipairs(state.queue or {}) do
        print(string.format("  %s NC %02d (%s) [%s]: %dI / %dL | ETA=%.1fs | Pri=%s",
            q.poolName, q.color, q.label, tostring(q.tier or "BULK"), q.itemUnits, q.fluidUnits, q.etaSec or 0, tostring(q.priority)))
    end
    print("=== CHECK COMPLETE (NO REDSTONE MODIFIED) ===")
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
            print("Universal Control updating from " .. updUrl .. "...")
            local okU, okInst = pcall(chunk, "--url", updUrl, "--update", "--yes")
            if okU and okInst ~= false then
                pcall(os.sleep, 0.15)
                if computer.shutdown then pcall(computer.shutdown, true) end
                return true
            end
            io.stderr:write("Universal Control remote update failed: " .. tostring(okInst) .. "\n")
            return false
        end
        io.stderr:write("Universal Control updater load failed: " .. tostring(loadErr) .. "\n")
        return false
    elseif state._pendingReboot then
        print("Universal Control rebooting per remote request (all bundled outputs OFF).")
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
        Scheduler.loadRatesFile(RATES_CACHE_PATH, state, cfg.maxRecipeCache, BACKUP_RATES_PATH)
        Scheduler.syncHardware(cfg, state)
        Hardware.zeroAllManagedPools(cfg, nil, state)
        Hardware.openMeshPort(cfg)

        print("GTNH Universal Control worker started (" .. (cfg.armed and "ARMED" or "PAUSED") .. "). Ctrl+C to stop.")
        local running = true
        local userExit = false
        local lastRateSave = computer.uptime()

        local okLoop, errLoop = xpcall(function()
            while running do
                local now = computer.uptime()
                state._forcePollNow = false
                Scheduler.step(cfg, state, now)
                Hardware.pushMeshMetrics(cfg, state, now)
                if (now - lastRateSave) >= 60.0 then
                    lastRateSave = now
                    saveConfig(cfg, state)
                    flushRatesIfDirty(state)
                end

                local deadline = computer.uptime() + Scheduler.nextWakeupDelay(cfg, state, computer.uptime())
                while running and computer.uptime() < deadline do
                    local cur = computer.uptime()
                    local timeout = math.max(0.05, math.min(deadline - cur, Scheduler.nextWakeupDelay(cfg, state, cur)))
                    local evTbl = { event.pull(timeout) }
                    local _, stopReq = dispatchEvent(cfg, state, evTbl, computer.uptime(), nil)
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

        pcall(Hardware.setGuidedSubscriptions, nil, false, nil, state)
        pcall(Hardware.zeroAllManagedPools, cfg, nil, state)
        pcall(saveConfig, cfg, state)
        pcall(flushRatesIfDirty, state)
        if state._pendingReboot or state._pendingUpdateUrl then
            if handlePendingRebootOrUpdate(state) then return end
            userExit = false
            okLoop = false
            errLoop = "remote update aborted"
        end
        if userExit or okLoop then
            print("Universal Control worker stopped cleanly (all bundled outputs OFF).")
            return
        else
            io.stderr:write("Universal Control worker error (restarting in 2s):\n" .. tostring(errLoop) .. "\n")
            os.sleep(2)
        end
    end
end

local function runGUI()
    while true do
        local cfg = loadConfig()
        local state = Scheduler.newState()
        Scheduler.loadRatesFile(RATES_CACHE_PATH, state, cfg.maxRecipeCache, BACKUP_RATES_PATH)
        Scheduler.syncHardware(cfg, state)
        Hardware.zeroAllManagedPools(cfg, nil, state)
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
                saveConfig(cfg, state)
                flushRatesIfDirty(state)
            end
        end

        local ui = UI.new(cfg, state, scheduleSave)
        local userExit = false

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
                local wakeDelay = Scheduler.nextWakeupDelay(cfg, state, now)
                local waitSec = math.max(0.05, math.min(nextPoll - now, wakeDelay))
                if ui.guidedDropActive then
                    waitSec = math.min(waitSec, 0.25)
                end
                if state._forcePollNow then
                    waitSec = 0.01
                end
                if savePending then
                    waitSec = math.min(waitSec, math.max(0.02, saveDeadline - now))
                end

                local evTbl = { event.pull(waitSec) }
                local evDirty, stopReq = dispatchEvent(cfg, state, evTbl, computer.uptime(), ui)
                if stopReq or state._pendingReboot then
                    savePending = true
                    userExit = true
                    ui.running = false
                    break
                end
                if evDirty then
                    dirty = true
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
                        saveConfig(cfg, state)
                        flushRatesIfDirty(state)
                    end
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

        -- Always force all bundled outputs OFF and clear temporary Guided Drop subscriptions!
        pcall(Hardware.setGuidedSubscriptions, nil, false, nil, state)
        pcall(Hardware.zeroAllManagedPools, cfg, nil, state)
        flushSave()
        pcall(saveConfig, cfg, state)
        pcall(flushRatesIfDirty, state)
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
            print("GTNH Universal Control stopped cleanly (all bundled outputs OFF).")
            return
        else
            io.stderr:write("GTNH Universal Control error (restarting in 2s):\n" .. tostring(errLoop) .. "\n")
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
