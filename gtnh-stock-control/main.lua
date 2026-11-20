-- /home/stock/main.lua
-- GTNH Mainnet AE2 Stock Maintainer Control Center & Headless Daemon
-- Usage:
--   stock            (160x50 Touch GUI, or --worker fallback if headless)
--   stock --worker   (headless daemon with auto-restart supervisor)
--   stock --check    (read-only AE2 O(1) discovery & dry-run check)
--   stock --bench    (profile O(1) OC lookups vs legacy full scans & physical maintainers)
--   stock --import   (scan physical AE2FC ME Level Maintainers and import active slots)
--   stock --off      (disarm safely)
--   stock --update   (update scripts cleanly while preserving config.cfg)

local cliArgs = { ... }

local component = require("component")
local computer = require("computer")
local event = require("event")
local filesystem = require("filesystem")
local serialization = require("serialization")
local shell = require("shell")
local term = require("term")

local scriptDir = filesystem.path(shell.getRunningProgram() or "/home/stock/main.lua") or "/home/stock"
if scriptDir == "" then scriptDir = "/home/stock" end
if scriptDir:sub(-1) == "/" and #scriptDir > 1 then
    scriptDir = scriptDir:sub(1, -2)
end

local CONFIG_PATH = filesystem.concat(scriptDir, "config.cfg")
local BACKUP_CONFIG_PATH = "/home/config.stock.bak"
local SHRC_PATH = "/home/.shrc"

do
    local prevPath = package.path
    package.path = string.format("%s/?.lua;%s/?/init.lua;%s", scriptDir, scriptDir, prevPath)
    for _, modName in ipairs({ "lib.dtpf_catalog", "lib.hardware", "lib.scheduler", "lib.ui" }) do
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

local function isStockShrcLine(line)
    if line:match("^%s*#") then return false end
    return line:find("/home/stock/main.lua", 1, true) ~= nil
        or line:find("/usr/bin/stock", 1, true) ~= nil
        or line:match("^%s*stock%s*$") ~= nil
        or line:match("^%s*stock%s+") ~= nil
end

local function isAutostartEnabled()
    local raw = readWholeFile(SHRC_PATH)
    if type(raw) ~= "string" then return false end
    for line in raw:gmatch("[^\r\n]+") do
        if isStockShrcLine(line) then return true end
    end
    return false
end

local function setAutostartEnabled(enable)
    local raw = readWholeFile(SHRC_PATH) or ""
    local lines = {}
    for line in raw:gmatch("[^\r\n]+") do
        if not isStockShrcLine(line) then
            lines[#lines + 1] = line
        end
    end
    if enable then
        local hasDisplay = (component.list("screen", true)() ~= nil) and (component.list("gpu", true)() ~= nil)
        local cmd = filesystem.exists("/usr/bin/stock.lua") and "stock" or "/home/stock/main.lua"
        if not hasDisplay then cmd = cmd .. " --worker" end
        lines[#lines + 1] = cmd
    end
    local body = (#lines > 0) and (table.concat(lines, "\n") .. "\n") or ""
    writeWholeFile(SHRC_PATH, body)
    return enable
end

local function printHelp()
    print("GTNH Mainnet AE2 Stock Maintainer (gtnh-stock-control)")
    print("Usage:")
    print("  stock                  Launch 160x50 Touch Control Center (or --worker if headless)")
    print("  stock --worker         Run headless background daemon (auto-restarts on fault)")
    print("  stock --check          Read-only AE2 O(1) discovery & dry-run check")
    print("  stock --bench          Profile O(1) lookups vs legacy scans & physical maintainers")
    print("  stock --import         Import active slots from attached physical ME Level Maintainers")
    print("  stock --autostart on|off  Enable or disable boot autostart in /home/.shrc")
    print("  stock --off            Disarm safely without modifying rules")
    print("  stock --update         Update scripts cleanly while preserving config.cfg")
end

local function makeRpcDispatcher(cfg, state)
    return function(cmd)
        return Scheduler.executeRpcTable(cfg, state, cmd, nil, function(c)
            saveConfig(c)
        end)
    end
end

local function dispatchEvent(cfg, state, evTbl, ui, rpcFn)
    local evName = evTbl[1]
    if not evName then return false, false end
    if evName == "interrupted" then
        return false, true
    elseif evName == "modem_message" then
        local handled = Hardware.handleMeshMessage(cfg, state, evTbl[2], evTbl[3], evTbl[4], evTbl[6], evTbl[7], evTbl[8], nil, rpcFn)
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
    local cfg, src = loadConfig()
    local state = Scheduler.newState()
    local disc = Scheduler.syncHardware(cfg, state)
    Scheduler.step(cfg, state, computer.uptime(), nil, { forceFull = true })
    local k = state.kpis
    local p = state.perf

    print("=== GTNH STOCK MAINTAINER READ-ONLY CHECK ===")
    print(string.format("Config File   : %s (%s)", CONFIG_PATH, src))
    print(string.format("Saved State   : %s | ExtLink: %s | DTPF Warn: %s",
        cfg.armed and "ARMED" or "PAUSED (Safe)", cfg.extLinkMode or "auto", cfg.dtpfWarnMode or "warn"))
    print(string.format("Mainnet AE2   : %s (%s) | O(1): item=%s fluid=%s craft=%s",
        tostring(disc.aeType or "none"), Hardware.shortAddr(disc.aeAddr),
        tostring(disc.hasO1Item), tostring(disc.hasO1Fluid), tostring(disc.hasO1Craftable)))
    print(string.format("Attached HW   : Transposers=%d | Physical Level Maintainers=%d",
        #(disc.transposers or {}), #(disc.maintainers or {})))
    print(string.format("Rules Summary : %d total (%d enabled) | OK=%d Low=%d Craft=%d Err=%d Warn=%d",
        k.total or 0, k.enabled or 0, k.ok or 0, k.low or 0, k.crafting or 0, k.errors or 0, k.warnings or 0))
    print(string.format("Perf / Saving : %.2fms (%d AE calls) | Replaces %d physical blocks (%d AE channels)",
        p.lastCycleMs or 0, p.aeCallsLast or 0, p.equivBlocksSaved or 0, p.equivChannelsSaved or 0))
    print("=== CHECK COMPLETE ===")
end

local function runBench()
    local cfg = loadConfig()
    local state = Scheduler.newState()
    Scheduler.syncHardware(cfg, state)
    local b = Hardware.runBenchmark(cfg, state)

    print("=== GTNH STOCK MAINTAINER BENCHMARK ===")
    print(string.format("AE2 Bound       : %s (%s)", tostring(b.aeBound), Hardware.shortAddr(b.aeAddr)))
    print(string.format("O(1) APIs       : Item=%s Fluid=%s Craftable=%s",
        tostring(b.hasO1Item), tostring(b.hasO1Fluid), tostring(b.hasO1Craftable)))
    print(string.format("O(1) Query (%2d) : %.3f ms total (%.3f ms/rule)", b.sampleCalls or 0, b.o1TotalMs or 0, b.o1AvgMs or 0))
    print(string.format("getCpus()       : %.3f ms", b.cpuMs or 0))
    if b.legacyFluidMs then
        print(string.format("getFluidsInNet(): %.3f ms (full scan)", b.legacyFluidMs))
    end
    if b.legacyItemFilterMs then
        print(string.format("getItemsInNet() : %.3f ms (filtered scan)", b.legacyItemFilterMs))
    end
    print(string.format("Memory          : %.1f KB Lua heap | %.1f KB free / %.1f KB total",
        b.luaHeapKB or 0, b.freeMemKB or 0, b.totalMemKB or 0))
    print(string.format("Physical Equiv  : %d rules replaces >=%d TileLevelMaintainer blocks & %d AE channels",
        b.enabledRules or 0, b.equivPhysicalBlocks or 0, b.equivChannelsSaved or 0))
    print("=== BENCHMARK COMPLETE ===")
end

local function runImport()
    local cfg = loadConfig()
    local state = Scheduler.newState()
    Scheduler.syncHardware(cfg, state)
    local slots, nBlocks = Hardware.scanPhysicalMaintainers(nil, state)
    local res = Scheduler.importPhysicalSlots(cfg, slots, {
        includeDisabled = false,
        disablePhysical = (cfg.disablePhysicalAfterImport == true),
        disableFn = function(a, s) return Hardware.disablePhysicalMaintainerSlot(a, s, nil, state) end,
    })
    saveConfig(cfg)
    print(string.format("Scanned %d physical maintainer block(s) (%d slots): added=%d updated=%d skipped=%d disabled=%d",
        nBlocks, #slots, res.added, res.updated, res.skipped, res.disabled))
end

local function runWorker()
    while true do
        local cfg = loadConfig()
        local state = Scheduler.newState()
        Scheduler.syncHardware(cfg, state)
        Hardware.openMeshPort(cfg, nil, state)
        local rpcFn = makeRpcDispatcher(cfg, state)

        print("GTNH Stock Maintainer worker started (" .. (cfg.armed and "ARMED" or "PAUSED") .. "). Ctrl+C to stop.")
        local running = true
        local userExit = false
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
                    local _, stopReq = dispatchEvent(cfg, state, evTbl, nil, rpcFn)
                    if stopReq or state._pendingReboot then
                        running = false
                        userExit = true
                        break
                    end
                    if state._forcePollNow then break end
                end
            end
        end, debug.traceback)

        pcall(saveConfig, cfg)
        if state._pendingReboot then
            print("GTNH Stock Maintainer rebooting per remote request...")
            pcall(os.sleep, 0.15)
            if computer.shutdown then pcall(computer.shutdown, true) end
            return
        elseif userExit then
            print("GTNH Stock Maintainer worker stopped cleanly.")
            return
        elseif not okLoop then
            io.stderr:write("Stock Maintainer worker fault (restarting in 2s):\n" .. tostring(errLoop) .. "\n")
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
        Scheduler.syncHardware(cfg, state)
        Hardware.openMeshPort(cfg, nil, state)
        local rpcFn = makeRpcDispatcher(cfg, state)

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
            Hardware.pushMeshMetrics(cfg, state, computer.uptime(), nil, true)
            if Scheduler.renderDigest(cfg, state) ~= lastDigest then
                ui:render()
                lastDigest = Scheduler.renderDigest(cfg, state)
            end
            local nextPoll = computer.uptime() + Scheduler.nextWakeupDelay(cfg, state, computer.uptime())

            while ui.running do
                local dirty = false
                local now = computer.uptime()
                local waitSec = math.max(0.05, math.min(nextPoll - now, Scheduler.nextWakeupDelay(cfg, state, now)))
                if state._forcePollNow then waitSec = 0.01 end
                if savePending then waitSec = math.min(waitSec, math.max(0.02, saveDeadline - now)) end

                local evTbl = { event.pull(waitSec) }
                local evDirty, stopReq = dispatchEvent(cfg, state, evTbl, ui, rpcFn)
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
                    Hardware.pushMeshMetrics(cfg, state, curTime)
                    nextPoll = computer.uptime() + Scheduler.nextWakeupDelay(cfg, state, computer.uptime())
                    if Scheduler.renderDigest(cfg, state) ~= lastDigest then
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
            if not ui.running then userExit = true end
        end, debug.traceback)

        flushSave()
        pcall(saveConfig, cfg)
        if component.isAvailable("gpu") then
            pcall(component.gpu.setBackground, 0x000000)
            pcall(component.gpu.setForeground, 0xFFFFFF)
        end
        term.clear()
        if state._pendingReboot then
            print("GTNH Stock Maintainer rebooting per remote request...")
            pcall(os.sleep, 0.15)
            if computer.shutdown then pcall(computer.shutdown, true) end
            return
        elseif userExit or okLoop then
            print("GTNH Stock Maintainer stopped cleanly.")
            return
        else
            io.stderr:write("GTNH Stock Maintainer fault (restarting in 2s):\n" .. tostring(errLoop) .. "\n")
            os.sleep(2)
        end
    end
end

local function main(args)
    for i = 1, #(args or {}) do
        local a = tostring(args[i])
        if a == "--help" or a == "-h" then printHelp(); return
        elseif a == "--check" or a == "check" then runCheck(); return
        elseif a == "--bench" or a == "bench" then runBench(); return
        elseif a == "--import" or a == "import" then runImport(); return
        elseif a == "--autostart" or a == "autostart" then
            local argNext = tostring(args[i + 1] or ""):lower()
            local enable = (argNext == "on" or argNext == "true" or argNext == "1") and true
                or ((argNext == "off" or argNext == "false" or argNext == "0") and false or (not isAutostartEnabled()))
            setAutostartEnabled(enable)
            print(string.format("Stock Maintainer boot autostart (/home/.shrc): %s", enable and "ENABLED" or "DISABLED"))
            return
        elseif a == "--off" or a == "off" then
            local cfg = loadConfig()
            cfg.armed = false
            saveConfig(cfg)
            print("Stock Maintainer disarmed.")
            return
        elseif a == "--worker" or a == "worker" then runWorker(); return
        elseif a == "--update" or a == "update" then
            local instPath = filesystem.concat(scriptDir, "install.lua")
            local src = readWholeFile(instPath)
            if not src then io.stderr:write("ERROR: install.lua not found.\n"); return end
            local chunk, err = load(src, "=" .. instPath)
            if not chunk then io.stderr:write("ERROR: " .. tostring(err) .. "\n"); return end
            local extra = { "--update" }
            for j = i + 1, #args do extra[#extra + 1] = args[j] end
            chunk(table.unpack(extra))
            return
        end
    end
    runGUI()
end

main(cliArgs)
