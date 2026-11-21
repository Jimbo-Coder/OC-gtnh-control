-- GTNH 2.9 Space Pumping (Fox, samsonsin, San32)
local cliArgs = { ... }
for i = 1, #cliArgs do
  local a = tostring(cliArgs[i] or '')
  if a == '--update' or a == 'update' then
    local instPath = '/home/install_pump.lua'
    local src = nil
    local f = io.open(instPath, 'r')
    if f then src = f:read('*a'); f:close() end
    if not src then
      io.stderr:write('ERROR: /home/install_pump.lua not found. Re-run install.lua once to enable --update.\n')
      return
    end
    local chunk, err = load(src, '=' .. instPath)
    if not chunk then
      io.stderr:write('ERROR: Invalid /home/install_pump.lua: ' .. tostring(err) .. '\n')
      return
    end
    local extra = { '--update' }
    for j = i + 1, #cliArgs do extra[#extra + 1] = cliArgs[j] end
    return chunk(table.unpack(extra))
  end
end

local component = require('component')
local thread = require('thread')
local event = require('event')
local term = require('term')
local filesystem = require('filesystem')
local computer = require('computer')
local okSer, serialization = pcall(require, 'serialization')
local Common = (function()
  local ok, m = pcall(require, 'gtnh_common')
  if ok and type(m) == 'table' then return m end
  package.path = '/usr/lib/?.lua;/lib/?.lua;./common/?.lua;../common/?.lua;' .. tostring(package.path or '')
  return require('gtnh_common')
end)()
local pumps = {}
local refreshRequested = false
local reloadRequested = false
local wakeRequested = false
local rebootRequested = false
local updateUrlRequested = nil
local statusLogs = {}
local cachedMe = nil
local cachedModem = nil
local cachedTunnel = nil

local function getMeProxy()
  if cachedMe and cachedMe.getFluidsInNetwork then return cachedMe end
  for _, ctype in ipairs({ 'me_controller', 'me_interface', 'fluid_interface' }) do
    if component.isAvailable(ctype) and component[ctype] then
      cachedMe = component[ctype]
      return cachedMe
    end
    if component.list then
      for addr in component.list(ctype, true) do
        local p = component.proxy(addr)
        if p and p.getFluidsInNetwork then
          cachedMe = p
          return cachedMe
        end
      end
    end
  end
  return nil
end

local SELF_PATH = '/home/autoPump.lua'
local OVERRIDES_PATH = '/home/pump_overrides.lua'
local OVERRIDES_TMP = '/home/.pump_overrides.tmp'
local MESH_PORT = 4205
local TIER_NAMES = {'I', 'II', 'III'}

local pumpOverrides = {}
local mainnetAddr = nil
local mainnetViaTunnel = false
local meshAckSeen = false
local lastStateName = 'boot'
local lastCycleNum = 0
local lastHandledReqId = nil
local meshListenerId = nil

-- CTRL+C to stop the script at any time, or restart the computer.

-- ===================== CONFIG ======================
-- Only change the PRIORITY and TARGET values. Do not change the SETTING or RATE values.
-- Quantum = 270e9 || Digital Singularity = 4e18 || Artificial Universe = 9e18

local master = {
  -- Planet 2 -----------------------------------------------------------------------------
  ['Chlorobenzene'] =     {target=1e10,  priority=0,  setting={2,1},  rate=896000}, -- Gas 1
  -- Planet 3 -----------------------------------------------------------------------------
  ['Ender Goo'] =         {target=0e10,  priority=0,  setting={3,1},  rate=32000}, -- Gas 1
  ['Very Heavy Oil'] =    {target=0e10,  priority=0,  setting={3,2},  rate=1400000}, -- Gas 2
  ['Lava'] =              {target=1e9,  priority=0,  setting={3,3},  rate=1800000}, -- Gas 3
  ['Natural Gas'] =       {target=0e10,  priority=0,  setting={3,4},  rate=1400000}, -- Gas 4
  -- Planet 4 -----------------------------------------------------------------------------
  ['Sulfuric Acid'] =     {target=1e10,  priority=0,  setting={4,1},  rate=784000}, -- Gas 1
  ['Molten Iron'] =       {target=1e9,  priority=0,  setting={4,2},  rate=896000}, -- Gas 2
  ['Oil'] =               {target=1e9,  priority=0,  setting={4,3},  rate=1400000}, -- Gas 3
  ['Heavy Oil'] =         {target=1e9,  priority=0,  setting={4,4},  rate=1792000}, -- Gas 4
  ['Molten Lead'] =       {target=0e10,  priority=0,  setting={4,5},  rate=896000}, -- Gas 5
  ['Raw Oil'] =           {target=1e9,  priority=0,  setting={4,6},  rate=1400000}, -- Gas 6
  ['Light Oil'] =         {target=1e9,  priority=0,  setting={4,7},  rate=780000}, -- Gas 7
  ['Carbon Dioxide'] =    {target=1e9,  priority=0,  setting={4,8},  rate=1680000}, -- Gas 8
  -- Planet 5 -----------------------------------------------------------------------------
  ['Carbon Monoxide'] =   {target=1e9,  priority=0,  setting={5,1},  rate=4480000}, -- Gas 1
  ['Helium-3'] =          {target=1e9,  priority=0,  setting={5,2},  rate=2800000}, -- Gas 2
  ['Salt Water'] =        {target=1e9,  priority=1,  setting={5,3},  rate=2800000}, -- Gas 3
  ['Helium'] =            {target=1e11,  priority=0,  setting={5,4},  rate=1400000}, -- Gas 4
  ['Liquid Oxygen'] =     {target=0e10,  priority=0,  setting={5,5},  rate=896000}, -- Gas 5
  ['Neon'] =              {target=1e8,  priority=0,  setting={5,6},  rate=32000}, -- Gas 6
  ['Argon'] =             {target=1e8,  priority=0,  setting={5,7},  rate=32000}, -- Gas 7
  ['Krypton'] =           {target=1e8,  priority=0,  setting={5,8},  rate=8000}, -- Gas 8
  ['Methane'] =           {target=1e8,  priority=0,  setting={5,9},  rate=1792000}, -- Gas 9
  ['Hydrogen Sulfide'] =  {target=1e8,  priority=0,  setting={5,10},  rate=392000}, -- Gas 10
  ['Ethane'] =            {target=1e8,  priority=0,  setting={5,11},  rate=1194000}, -- Gas 11
  -- Planet 6 -----------------------------------------------------------------------------
  ['Deuterium'] =         {target=1e11,  priority=0,  setting={6,1},  rate=1568000}, -- Gas 1
  ['Tritium'] =           {target=1e11,  priority=0,  setting={6,2},  rate=240000}, -- Gas 2
  ['Ammonia'] =           {target=1e10,  priority=0,  setting={6,3},  rate=240000}, -- Gas 3
  ['Xenon'] =             {target=3e10,  priority=0,  setting={6,4},  rate=16000}, -- Gas 4
  ['Ethylene'] =          {target=1e9,  priority=0,  setting={6,5},  rate=1792000}, -- Gas 5
  -- Planet 7 -----------------------------------------------------------------------------
  ['Hydrofluoric Acid'] = {target=1e10,  priority=0,  setting={7,1},  rate=672000}, -- Gas 1
  ['Fluorine'] =          {target=1e10,  priority=0,  setting={7,2},  rate=1792000}, -- Gas 2
  ['Nitrogen'] =          {target=1e12,  priority=1,  setting={7,3},  rate=1792000}, -- Gas 3
  ['Oxygen'] =            {target=1e12,  priority=1,  setting={7,4},  rate=1729000}, -- Gas 4
  -- Planet 8 -----------------------------------------------------------------------------
  ['Hydrogen'] =          {target=1e12,  priority=1,  setting={8,1},  rate=1568000}, -- Gas 1
  ['Liquid Air'] =        {target=1e9,  priority=0,  setting={8,2},  rate=875000}, -- Gas 2
  ['Molten Copper'] =     {target=1e9,  priority=0,  setting={8,3},  rate=672000}, -- Gas 3
  ['Unknown Liquid'] =    {target=1e8,  priority=0,  setting={8,4},  rate=672000}, -- Gas 4
  ['Distilled Water'] =   {target=1e12,  priority=1,  setting={8,5},  rate=17920000}, -- Gas 5
  ['Radon'] =             {target=1e11,  priority=0,  setting={8,6},  rate=64000}, -- Gas 6
  ['Molten Tin'] =        {target=0e10,  priority=0,  setting={8,7},  rate=672000}} -- Gas 7

-- The % of the Target when Considered Complete (Default: 95%)
local threshold = 0.95
-- The Upper Limit on the Duration of an Iteration (Default: 30s)
local maxBatchSize = 30
-- Set false to run 100% standalone (ignores modem/tunnel telemetry & commands)
local enableMesh = true
-- The Text Color (Default: '\27[1;36m')
local color = '\27[1;36m'

-- (https://github.com/torch/sys/blob/master/colors.lua)
-- Cyan = '\27[1;36m' || Green = '\27[1;32m' || Red = '\27[0;31m' || Magenta = '\27[0;35m'

-- =================== END CONFIG ====================

local function logMsg(msg)
  local line = string.format('[%ds] %s', math.floor(computer.uptime()), msg)
  print('autoPump: ' .. msg)
  table.insert(statusLogs, line)
  if #statusLogs > 16 then table.remove(statusLogs, 1) end
end

local WAKE_MSG = Common.WAKE_MSG
local lastMainnetSeen = nil
local lastMainnetWakeAt = -1000
local meshStartedAt = nil
local mainnetWakeAttempts = 0

local function getMeshModem(forceRefresh)
  if not enableMesh then return nil, nil end
  if (not forceRefresh) and (cachedModem ~= nil or cachedTunnel ~= nil) then
    return cachedModem or nil, cachedTunnel or nil
  end
  local modem, tunnel = Common.getMeshTransports(component, {
    port = MESH_PORT,
    wakeMsg = WAKE_MSG,
    strength = 400,
  })
  cachedModem = modem or false
  cachedTunnel = tunnel or false
  return cachedModem or nil, cachedTunnel or nil
end

local function sendMeshPacket(targetAddr, viaTunnel, msgType, ...)
  local modem, tunnel = getMeshModem()
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

local function applyOverrides()
  for k, ov in pairs(pumpOverrides) do
    if master[k] and type(ov) == 'table' then
      if type(ov.target) == 'number' and ov.target >= 0 then
        master[k].target = ov.target
      end
      if type(ov.priority) == 'number' then
        master[k].priority = math.max(0, math.min(8, math.floor(ov.priority)))
      end
    end
  end
end

local function loadOverrides()
  if not okSer then return end
  pcall(function()
    if not filesystem.exists(OVERRIDES_PATH) then return end
    local f = io.open(OVERRIDES_PATH, 'r')
    if not f then return end
    local raw = f:read('*a')
    f:close()
    local tbl = raw and raw ~= '' and serialization.unserialize(raw) or nil
    if type(tbl) == 'table' then
      pumpOverrides = tbl
      applyOverrides()
    end
  end)
end

local function saveOverrides()
  if not okSer then return end
  pcall(function()
    local f = io.open(OVERRIDES_TMP, 'w')
    if not f then return end
    f:write(serialization.serialize(pumpOverrides))
    f:close()
    filesystem.remove(OVERRIDES_PATH)
    filesystem.rename(OVERRIDES_TMP, OVERRIDES_PATH)
  end)
end

local function buildStatusPayload(stateName, cycleNum)
  local pumpList = {}
  for idx, p in ipairs(pumps) do
    pumpList[#pumpList + 1] = {
      index = idx,
      address = p.address or '',
      name = p.name or '',
      tier = p.tier or 1,
      threads = p.threads or 1,
      mult = p.mult or 4,
      active = p.fluid ~= nil,
      fluid = p.fluid or '',
      batchSec = p.batchSec or 0,
      batchAmount = p.amount or 0,
      ratePerSec = p.ratePerSec or 0,
    }
  end
  local fluidMap = {}
  for k, f in pairs(master) do
    local meAmt = f.meAmount or 0
    local tot = f.amount or 0
    fluidMap[k] = {
      meAmount = meAmt,
      queued = math.max(0, tot - meAmt),
      total = tot,
      target = f.target,
      priority = f.priority,
    }
  end
  return {
    state = stateName,
    cycle = cycleNum or 0,
    uptime = math.floor(computer.uptime()),
    threshold = threshold,
    maxBatchSize = maxBatchSize,
    pumps = pumpList,
    fluids = fluidMap,
    logs = statusLogs,
  }
end

local function serializeMeshTable(tbl)
  local raw = serialization.serialize(tbl)
  if #raw > 6500 and type(tbl) == 'table' then
    local trimmed = {}
    for k, v in pairs(tbl) do trimmed[k] = v end
    if trimmed.logs then trimmed.logs = {} end
    if type(trimmed.status) == 'table' then
      local st = {}
      for k, v in pairs(trimmed.status) do st[k] = v end
      st.logs = {}
      trimmed.status = st
    end
    raw = serialization.serialize(trimmed)
  end
  return raw
end

local function writeStatus(stateName, cycleNum)
  if not enableMesh then return end
  pcall(function()
    lastStateName = stateName or lastStateName
    lastCycleNum = cycleNum or lastCycleNum
    local payload = buildStatusPayload(stateName, cycleNum)
    if okSer and (component.isAvailable('modem') or component.isAvailable('tunnel')) then
      sendMeshPacket(mainnetAddr, mainnetViaTunnel, 'PUMP_STATUS', serializeMeshTable(payload))
      local upNow = computer.uptime()
      meshStartedAt = meshStartedAt or upNow
      local peerSilent = (lastMainnetSeen and (upNow - lastMainnetSeen) >= 60)
        or ((not lastMainnetSeen) and (upNow - meshStartedAt) >= 60)
      if peerSilent and (upNow - lastMainnetWakeAt) >= 60 then
        lastMainnetWakeAt = upNow
        mainnetWakeAttempts = mainnetWakeAttempts + 1
        local wakeTarget = (mainnetAddr and mainnetWakeAttempts <= 2) and mainnetAddr or nil
        sendMeshPacket(wakeTarget, mainnetViaTunnel, WAKE_MSG)
      end
    end
  end)
end

local function reloadConfigFromDisk()
  local ok, err = pcall(function()
    local f = io.open(SELF_PATH, 'r')
    if not f then return end
    local src = f:read('*a')
    f:close()
    if not src or src == '' then return end
    local sPos = src:find('%-%- ===================== CONFIG')
    local ePos = src:find('%-%- =================== END CONFIG')
    local parsed
    if sPos and ePos and ePos > sPos then
      local cfgSrc = src:sub(sPos, ePos - 1) .. '\nreturn { master = master, threshold = threshold, maxBatchSize = maxBatchSize }'
      local fn, loadErr = load(cfgSrc, '@autoPump_cfg', 't', {})
      if not fn then error(loadErr) end
      parsed = fn()
    else
      local tblSrc = src:match('local%s+master%s*=%s*(%b{})')
      if tblSrc then
        local fn, loadErr = load('return ' .. tblSrc, '@autoPump_master', 't', {})
        if not fn then error(loadErr) end
        parsed = {
          master = fn(),
          threshold = tonumber(src:match('local%s+threshold%s*=%s*([%d%.]+)')),
          maxBatchSize = tonumber(src:match('local%s+maxBatchSize%s*=%s*(%d+)')),
        }
      end
    end
    if type(parsed) == 'table' and type(parsed.master) == 'table' then
      for k, entry in pairs(parsed.master) do
        if master[k] and type(entry) == 'table' then
          if type(entry.target) == 'number' then master[k].target = entry.target end
          if type(entry.priority) == 'number' then master[k].priority = entry.priority end
        end
      end
      if type(parsed.threshold) == 'number' and parsed.threshold > 0 and parsed.threshold <= 1 then
        threshold = parsed.threshold
      end
      if type(parsed.maxBatchSize) == 'number' and parsed.maxBatchSize >= 1 then
        maxBatchSize = parsed.maxBatchSize
      end
      applyOverrides()
      logMsg('Reloaded targets & priorities from autoPump.lua')
    end
  end)
  if not ok then
    logMsg('Config reload error: ' .. tostring(err))
  end
end

local function handleMeshMessage(localAddr, sender, port, msgType, reqId, rawPayload)
  if not enableMesh or not sender then return false end
  local isTunnel = component.isAvailable('tunnel') and component.tunnel and component.tunnel.address == localAddr and port == 0
  if port ~= MESH_PORT and not isTunnel then return false end

  if msgType == 'PUMP_ACK' then
    mainnetAddr = sender
    mainnetViaTunnel = isTunnel
    meshAckSeen = true
    lastMainnetSeen = computer.uptime()
    mainnetWakeAttempts = 0
    return true
  elseif msgType == 'MESH_MAINNET_HELLO' or msgType == WAKE_MSG then
    mainnetAddr = sender
    mainnetViaTunnel = isTunnel
    meshAckSeen = true
    lastMainnetSeen = computer.uptime()
    mainnetWakeAttempts = 0
    writeStatus(lastStateName, lastCycleNum)
    return true
  elseif msgType == 'PUMP_CMD' then
    mainnetAddr = sender
    mainnetViaTunnel = isTunnel
    meshAckSeen = true
    lastMainnetSeen = computer.uptime()
    mainnetWakeAttempts = 0
    if reqId ~= nil and tostring(reqId) ~= '' then
      if tostring(reqId) == lastHandledReqId then return true end
      lastHandledReqId = tostring(reqId)
    end
    local function replyCmd(tbl)
      if okSer then
        sendMeshPacket(sender, isTunnel, 'PUMP_REPLY', tostring(reqId or ''), serializeMeshTable(tbl))
      end
    end
    local cmd = okSer and type(rawPayload) == 'string' and serialization.unserialize(rawPayload) or nil
    if type(cmd) ~= 'table' then
      replyCmd({ ok = false, error = 'Invalid PUMP_CMD payload' })
      return true
    end
    local op = cmd.op
    if op == 'get_status' then
      replyCmd({ ok = true, status = buildStatusPayload(lastStateName, lastCycleNum) })
    elseif op == 'patch' then
      local lbl = tostring(cmd.label or '')
      local entry = master[lbl]
      if not entry then
        replyCmd({ ok = false, error = "Fluid '" .. lbl .. "' not found" })
        return true
      end
      if cmd.target ~= nil and tonumber(cmd.target) then
        entry.target = math.max(0, math.floor(tonumber(cmd.target)))
      end
      if cmd.priority ~= nil and tonumber(cmd.priority) then
        entry.priority = math.max(0, math.min(8, math.floor(tonumber(cmd.priority))))
      end
      pumpOverrides[lbl] = { target = entry.target, priority = entry.priority }
      saveOverrides()
      wakeRequested = true
      logMsg('Mesh patch: ' .. lbl .. ' -> tgt=' .. tostring(entry.target) .. ', prio=' .. tostring(entry.priority))
      replyCmd({ ok = true, status = buildStatusPayload(lastStateName, lastCycleNum) })
    elseif op == 'action' then
      local act = tostring(cmd.action or '')
      if act == 'wake' then
        wakeRequested = true
        logMsg('Wake / check requested via OC mesh')
      elseif act == 'refresh_pumps' then
        refreshRequested = true
      elseif act == 'reload' then
        reloadRequested = true
      elseif act == 'update_local' then
        local tx = Common.detectOtaTransport(component)
        if not tx.hasInternet and not tx.hasMesh then
          replyCmd({ ok = false, error = 'No Internet Card or OC Mesh modem/tunnel' })
          return true
        end
        local u = (type(cmd.url) == 'string' and cmd.url ~= '') and cmd.url or Common.LOCAL_UPDATE_URL
        if not Common.isAllowedOtaUrl(u) then
          replyCmd({ ok = false, error = 'Invalid update URL' })
          return true
        end
        updateUrlRequested = u
        rebootRequested = true
        wakeRequested = true
        logMsg('Remote update requested via OC mesh')
        replyCmd({ ok = true, updating = true, viaMesh = tx.viaMesh, url = u })
        return true
      elseif act == 'reboot' then
        rebootRequested = true
        wakeRequested = true
        logMsg('Reboot requested via OC mesh')
        replyCmd({ ok = true, rebooting = true })
        return true
      else
        replyCmd({ ok = false, error = 'Invalid action: ' .. act })
        return true
      end
      replyCmd({ ok = true, queuedAction = act, status = buildStatusPayload(lastStateName, lastCycleNum) })
    elseif op == 'update_local' then
      local tx = Common.detectOtaTransport(component)
      if not tx.hasInternet and not tx.hasMesh then
        replyCmd({ ok = false, error = 'No Internet Card or OC Mesh modem/tunnel' })
        return true
      end
      local u = (type(cmd.url) == 'string' and cmd.url ~= '') and cmd.url or Common.LOCAL_UPDATE_URL
      if not Common.isAllowedOtaUrl(u) then
        replyCmd({ ok = false, error = 'Invalid update URL' })
        return true
      end
      updateUrlRequested = u
      rebootRequested = true
      wakeRequested = true
      logMsg('Remote update requested via OC mesh')
      replyCmd({ ok = true, updating = true, viaMesh = tx.viaMesh, url = u })
    elseif op == 'reboot' then
      rebootRequested = true
      wakeRequested = true
      logMsg('Reboot requested via OC mesh')
      replyCmd({ ok = true, rebooting = true })
    else
      replyCmd({ ok = false, error = 'Unknown op: ' .. tostring(op) })
    end
    return true
  end
  return false
end

local function drainModemEvents()
  if not (event and event.pull) then return end
  for _ = 1, 8 do
    local ev, lAddr, sAddr, port, _, msgType, reqId, raw = event.pull(0, 'modem_message')
    if ev ~= 'modem_message' then break end
    if not meshListenerId then
      handleMeshMessage(lAddr, sAddr, port, msgType, reqId, raw)
    end
  end
end

local function meshSleep(totalSec)
  local rem = tonumber(totalSec) or 1
  while rem > 0 and not rebootRequested do
    drainModemEvents()
    local step = math.min(1, rem)
    os.sleep(step)
    rem = rem - step
    drainModemEvents()
  end
end

local function interruptibleSleep(totalSec)
  local now = computer.uptime()
  local deadline = now + totalSec
  local lastHbAt = now
  while now < deadline do
    if wakeRequested or reloadRequested or refreshRequested or rebootRequested then return true end
    if (now - lastHbAt) >= 90 then
      lastHbAt = now
      writeStatus(lastStateName, lastCycleNum)
    end
    local step = math.min(1.5, math.max(0.05, deadline - now))
    if event and event.pull then
      local ev, lAddr, sAddr, port, _, msgType, reqId, raw = event.pull(step, 'modem_message')
      if ev == 'modem_message' and not meshListenerId then
        handleMeshMessage(lAddr, sAddr, port, msgType, reqId, raw)
      end
    else
      os.sleep(step)
    end
    now = computer.uptime()
  end
  return wakeRequested or reloadRequested or refreshRequested or rebootRequested
end

local function findPumps()
  if not component.list then return end
  for address in component.list('gt_machine') do
    local module = component.proxy(address)
    local name = module and module.getName and module.getName()

    if name == "projectmodulepumpt1" then
      table.insert(pumps, {module=module, address=address, name=name, tier=1, threads=1, mult=4, priority=1, fluid=nil, amount=0, batchSec=0, ratePerSec=0})
    elseif name == "projectmodulepumpt2" then
      table.insert(pumps, {module=module, address=address, name=name, tier=2, threads=4, mult=16, priority=2, fluid=nil, amount=0, batchSec=0, ratePerSec=0})
    elseif name == "projectmodulepumpt3" then
      table.insert(pumps, {module=module, address=address, name=name, tier=3, threads=4, mult=256, priority=3, fluid=nil, amount=0, batchSec=0, ratePerSec=0})
    end
  end

  -- Sort Based on Priority
  table.sort(pumps, function(a, b) return a.priority > b.priority end)
end

local function updateFluids()
  local meProxy = getMeProxy()
  if not meProxy then error('ME controller/interface unavailable') end

  -- Reset Everything to Zero
  local lowFluids = {}
  for _, fluid in pairs(master) do
    fluid.amount = 0
    fluid.meAmount = 0
  end

  -- Update Fluids from ME Network
  for _, fluid in ipairs(meProxy.getFluidsInNetwork()) do
    if master[fluid.label] ~= nil then
      local sz = fluid.size or fluid.amount or 0
      master[fluid.label].meAmount = sz
      master[fluid.label].amount = sz
    end
  end

  -- Update Fluids from Pumps
  for _, pump in ipairs(pumps) do
    if pump.fluid ~= nil then master[pump.fluid].amount = master[pump.fluid].amount + pump.amount end
  end

  -- Identify Low Fluids
  for _, fluid in pairs(master) do
    if fluid.target > 0 and fluid.amount < threshold * fluid.target then table.insert(lowFluids, fluid) end
  end
  return lowFluids
end

-- Keep priority 0 demand-aware without changing the behavior of priorities 1+.
-- With a fractional exponent, priority 0 scores below priority 1 at the
-- same fill fraction but still distinguishes nearly empty from nearly full.
local function demandScore(fluid)
  local fill = math.min(1, math.max(0, fluid.amount / fluid.target))
  local exponent = fluid.priority == 0 and 0.5 or fluid.priority
  return 1 - fill ^ exponent
end

local function updatePumps(lowFluids)
  for idx, pump in ipairs(pumps) do

    -- Ensure Pump is Disabled
    pump.module.setWorkAllowed(false)
    while pump.module.isMachineActive() do meshSleep(2) end
    pump.fluid, pump.amount, pump.batchSec, pump.ratePerSec = nil, 0, 0, 0

    -- Sort Low Fluids based on Priority and % of Target
    table.sort(lowFluids, function(a, b)
      local sa, sb = demandScore(a), demandScore(b)
      if sa == sb then return a.label < b.label end
      return sa < sb
    end)

    local fluid = lowFluids[#lowFluids]
    if fluid ~= nil then

      -- Change Planet and Gas for all Threads
      for i=0, pump.threads-1 do
        pump.module.setParameter('recipe' .. i .. '.planetType', fluid.setting[1])
        pump.module.setParameter('recipe' .. i .. '.gasType', fluid.setting[2])
      end

      -- Change Batch Size based on Distance from Target
      local batchSize = math.min(maxBatchSize, math.ceil((fluid.target - fluid.amount) / (fluid.rate * pump.mult)))
      pump.module.setParameter('batch', batchSize)

      -- Preemptively Update Fluid Amount
      pump.fluid = fluid.label
      pump.batchSec = batchSize
      pump.ratePerSec = fluid.rate * pump.mult
      pump.amount = batchSize * pump.ratePerSec
      fluid.amount = fluid.amount + pump.amount
      logMsg(string.format('Running %s on Mk-%s #%d for %ds', fluid.label, TIER_NAMES[pump.tier] or '?', idx, batchSize))

      -- Remove Fluid if above Target Threshold
      if fluid.amount >= fluid.target * threshold then table.remove(lowFluids) end

      -- Run Once
      pump.module.setWorkAllowed(true)
      os.sleep(0.1)
      pump.module.setWorkAllowed(false)
    end
    -- Even when no fluids remain, continue through the remaining pumps
    -- so each old assignment is stopped and its accounting is cleared.
  end
end

local function parse(label)
  local fluid = master[label]
  if fluid.target == 0 then
    return string.format('[----------] %-20s', fluid.label)
  else
    local thresh = threshold * fluid.target
    local percent = fluid.amount >= thresh and 10
      or math.min(9, math.max(0, math.floor(10 * (fluid.amount / thresh))))
    return string.format('[%s%s] %-20s', color .. string.rep('■', percent) .. '\27[0m', string.rep('□', 10-percent), fluid.label)
  end
end

local function printDashboard()
  term.clear()
  print('\n┌─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐')
  print('│' .. color .. ' Space Elevator Fluid Levels (% of Target)' .. '\27[0m' .. string.rep(' ', 95) .. '│')
  print('├─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤')
  print(string.format('│ %s %s %s %s │', parse('Hydrogen'),      parse('Argon'),            parse('Oil'),             parse('Hydrogen Sulfide')))
  print(string.format('│ %s %s %s %s │', parse('Helium'),        parse('Radon'),            parse('Raw Oil'),         parse('Sulfuric Acid')))
  print(string.format('│ %s %s %s %s │', parse('Nitrogen'),      parse('Neon'),             parse('Light Oil'),       parse('Hydrofluoric Acid')))
  print(string.format('│ %s %s %s %s │', parse('Oxygen'),        parse('Krypton'),          parse('Heavy Oil'),       string.rep(' ', 33)))
  print(string.format('│ %s %s %s %s │', parse('Fluorine'),      parse('Xenon'),            parse('Very Heavy Oil'),  string.rep(' ', 33)))
  print(string.format('│ %s %s %s %s │', string.rep(' ', 33),    string.rep(' ', 33),       parse('Natural Gas'),     string.rep(' ', 33)))
  print(string.format('│ %s %s %s %s │', parse('Molten Iron'),   parse('Ammonia'),          parse('Distilled Water'), parse('Helium-3')))
  print(string.format('│ %s %s %s %s │', parse('Molten Copper'), parse('Ethylene'),         parse('Salt Water'),      parse('Deuterium')))
  print(string.format('│ %s %s %s %s │', parse('Molten Tin'),    parse('Ethane'),           parse('Chlorobenzene'),   parse('Tritium')))
  print(string.format('│ %s %s %s %s │', parse('Molten Lead'),   parse('Methane'),          parse('Unknown Liquid'),  string.rep(' ', 33)))
  print(string.format('│ %s %s %s %s │', string.rep(' ', 33),    string.rep(' ', 33),       string.rep(' ', 33),      string.rep(' ', 33)))
  print(string.format('│ %s %s %s %s │', parse('Liquid Air'),    parse('Carbon Monoxide'),  parse('Lava'),            string.rep(' ', 33)))
  print(string.format('│ %s %s %s %s │', parse('Liquid Oxygen'), parse('Carbon Dioxide'),   parse('Ender Goo'),       string.rep(' ', 33)))
  print('└─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘\n')
end

local keyHandler = thread.create(function()
  local keyboard = require('keyboard')
  while true do
    _, _, _, code, _ = event.pull('key_down')
    if code == keyboard.keys.p then printDashboard()
    elseif code == keyboard.keys.r then
      reloadRequested = true
    elseif code == keyboard.keys.u then
      -- Let the main scheduler refresh safely between allocation passes.
      refreshRequested = true
    end
  end
end)

-- ====================== MAIN =======================

local main = thread.create(function()
  local n = 1
  findPumps()
  for k, fluid in pairs(master) do fluid.label = k end
  loadOverrides()
  getMeshModem()
  if enableMesh and event and event.listen then
    local okL, lid = pcall(event.listen, 'modem_message', function(_, lAddr, sAddr, port, _, msgType, reqId, raw)
      handleMeshMessage(lAddr, sAddr, port, msgType, reqId, raw)
    end)
    if okL and lid then
      meshListenerId = lid
    end
  end

  -- THE LOOP
  while true do
    local okCycle, cycleErr = xpcall(function()
      drainModemEvents()
      if rebootRequested then return end
      wakeRequested = false
      if reloadRequested then
        reloadRequested = false
        reloadConfigFromDisk()
        n = 1
      end

      if refreshRequested then
        refreshRequested = false
        -- Finish tracked batches before replacing the pump list; otherwise
        -- their predicted production would disappear from accounting.
        for _, pump in ipairs(pumps) do
          pump.module.setWorkAllowed(false)
          while pump.module.isMachineActive() do meshSleep(2) end
        end
        pumps = {}
        findPumps()
        logMsg('Pump list refreshed (' .. #pumps .. ' found)')
      end

      -- A disconnected elevator should not cause a tight ME polling loop.
      if #pumps == 0 then
        logMsg('No pumps detected; retrying in 10 seconds')
        writeStatus('no_pumps', n)
        interruptibleSleep(10)
        findPumps()
      else
        -- Update Fluid Amounts
        local lowFluids = updateFluids()
        if next(lowFluids) ~= nil then
          if n % 5 == 1 then printDashboard() end

          -- Update Pump Settings
          updatePumps(lowFluids)
          writeStatus('pumping', n)
          n = n + 1

        elseif n > 0 then
          -- Reset Pump Settings
          for _, pump in ipairs(pumps) do
            pump.fluid, pump.amount, pump.batchSec, pump.ratePerSec = nil, 0, 0, 0
          end

          -- Nothing to Update, Sleep 3 Minutes
          printDashboard()
          print('autoPump: Sleeping...\n')
          writeStatus('sleeping', n)
          interruptibleSleep(180)
          n = 0

        else
          -- n == 0 and demand remains satisfied: keep status fresh across sleep cycles.
          writeStatus('sleeping', 0)
          interruptibleSleep(180)
        end
      end
    end, debug.traceback)
    if rebootRequested then
      if meshListenerId and event and event.ignore then
        pcall(event.ignore, 'modem_message', meshListenerId)
        meshListenerId = nil
      end
      for _, pump in ipairs(pumps) do
        pcall(pump.module.setWorkAllowed, false)
      end
      if updateUrlRequested then
        local updUrl = updateUrlRequested
        updateUrlRequested = nil
        local instPath = '/home/install_pump.lua'
        local chunk, loadErr = loadfile and loadfile(instPath) or nil, 'missing ' .. instPath
        if not chunk and io and io.open then
          local f = io.open(instPath, 'r')
          if f then
            local src = f:read('*a')
            f:close()
            chunk, loadErr = load(src, '=' .. instPath)
          end
        end
        if chunk then
          local tx = Common.detectOtaTransport(component)
          local updArgs = Common.buildInstallerArgs(updUrl, {
            viaMesh = tx.viaMesh,
            meshTarget = (mainnetAddr and not mainnetViaTunnel) and tostring(mainnetAddr) or nil,
          })
          local okU, okInst = pcall(chunk, table.unpack(updArgs))
          if okU and okInst ~= false then
            os.sleep(0.15)
            if computer.shutdown then pcall(computer.shutdown, true) end
            return
          else
            logMsg('Space Pump remote update failed: ' .. tostring(okInst))
            rebootRequested = false
          end
        else
          logMsg('Space Pump updater load failed: ' .. tostring(loadErr))
          rebootRequested = false
        end
      else
        os.sleep(0.15)
        if computer.shutdown then pcall(computer.shutdown, true) end
        return
      end
    end
    if not okCycle then
      logMsg('Pump fault (retrying in 5s): ' .. tostring(cycleErr):sub(1, 140))
      cachedMe = nil
      cachedModem = nil
      cachedTunnel = nil
      interruptibleSleep(5)
      pumps = {}
      findPumps()
    end
  end
end)

local isPumpShrcLine = Common.makeShrcMatcher({
  'pump', '/usr/bin/pump', '/usr/bin/pump.lua', '/home/autoPump.lua', 'autoPump.lua',
})

local function armShellReviveWatchdog()
  return Common.armShellReviveWatchdog({
    isAutostartFn = isPumpShrcLine,
    shrcPath = '/home/.shrc',
    meshPort = MESH_PORT,
    wakeMsg = WAKE_MSG,
  })
end

Common.disarmShellReviveWatchdog()

local cleanUp = thread.create(function()
    event.pull('interrupted')
    if meshListenerId and event and event.ignore then
      pcall(event.ignore, 'modem_message', meshListenerId)
      meshListenerId = nil
    end
    term.clear()
    print('Received Exit Command!')
    for _, pump in ipairs(pumps) do
      for _=1, pump.threads do pump.module.setWorkAllowed(false) end
    end
    main.kill()
    keyHandler.kill()
    armShellReviveWatchdog()
    os.exit(0)
end)

thread.waitForAny({main, keyHandler, cleanUp})
armShellReviveWatchdog()
os.exit(0)