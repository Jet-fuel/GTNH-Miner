-- =============================================================================
-- MEDINA SIDE DETECTOR  (v1.0)
-- Auto-detects interfaceSide and inputBusSide for a module and writes them into
-- /home/job_node_config.lua.
--
-- detect_module.lua says sides "CANNOT be auto-detected". That's true if you only
-- look at the transposer passively -- getInventoryName() gives you block names
-- that vary by pack version, so matching on them is a guess. But we don't have to
-- guess, because we have an active signal:
--
--   THE PROBE: ask the ME Interface to stock one known item, then scan all six
--   transposer faces for that item's label. The face it appears on IS the
--   interface side, by definition. No name matching, no pack-version assumptions.
--
-- Once the interface side is known, the input bus is the other face with an
-- inventory on it (the documented build puts the transposer between exactly two
-- inventories). If more than one candidate remains, the script shows them and
-- asks -- it does not guess.
--
-- Finally it does a real round-trip: moves the probe item interface -> bus,
-- confirms it landed, and moves it back. That exercises the exact transferItem()
-- call that loader.lua step 5 performs, so a pass here means the loader will work.
--
-- OPTIONALLY, for stockingMode = filter, it also finds each module's stocking
-- bus component (busAddr): it sets the probe item as a filter on each unclaimed
-- me_inputbus and watches which one shows up on this module's bus face. An
-- adapter touching the bus and an adapter holding an MFU bound to it look the
-- same to this probe. If nothing shows, it lists the buses and asks.
--
-- USAGE:  detect_sides            (prompts for which module)
--         detect_sides 3          (fixes module 3)
--         detect_sides all        (walks every module in turn)
-- =============================================================================

local component = require("component")
local computer  = require("computer")

local CONFIG_PATH = "/home/job_node_config.lua"
local SIDE_NAMES  = { [0]="down", [1]="up", [2]="north", [3]="south", [4]="west", [5]="east" }

-- How long to wait for the ME network to deliver the probe item, and how long
-- for the buffer to drain again on cleanup. Generous: a laggy server is not an
-- error, it's just slow.
local PROBE_TIMEOUT = 10
local DRAIN_TIMEOUT = 10
local POLL_INTERVAL = 0.2

-- The interface config slot we borrow for probing. loader.lua uses 1/2/3 for
-- drone/tip/rod, so 9 stays clear of a real load.
local PROBE_CFG_SLOT = 9

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function sideLabel(side)
  return string.format("%d (%s)", side, SIDE_NAMES[side])
end

local function getProxy(addr, label)
  local full = component.get(addr)
  if not full then error(label .. ": component '" .. tostring(addr) .. "' not found") end
  return component.proxy(full)
end

-- Poll a predicate until truthy or timeout. Returns the predicate's value.
-- computer.uptime() is the same clock scheduler.lua uses -- real seconds since
-- boot. No mixing with world ticks.
local function pollUntil(fn, timeout)
  local deadline = computer.uptime() + timeout
  while true do
    local a, b = fn()
    if a then return a, b end
    if computer.uptime() >= deadline then return nil end
    os.sleep(POLL_INTERVAL)
  end
end

-- Every transposer face that has an inventory behind it: { side, size, name }.
local function scanInventories(transposer)
  local found = {}
  for side = 0, 5 do
    local ok, size = pcall(transposer.getInventorySize, side)
    if ok and size and size > 0 then
      local _, name = pcall(transposer.getInventoryName, side)
      found[#found + 1] = { side = side, size = size, name = name or "?" }
    end
  end
  return found
end

-- Search every face for a slot holding `label`. Returns side, slot.
local function findLabel(transposer, label)
  for side = 0, 5 do
    local ok, size = pcall(transposer.getInventorySize, side)
    if ok and size and size > 0 then
      for s = 1, size do
        local ok2, stack = pcall(transposer.getStackInSlot, side, s)
        if ok2 and stack and stack.label == label then return side, s end
      end
    end
  end
  return nil
end

local function ask(prompt, default)
  io.write(prompt)
  local answer = io.read()
  if not answer or answer == "" then return default end
  return answer
end

-- ---------------------------------------------------------------------------
-- Stocking bus helpers (stockingMode = filter)
--
-- The bus is reached through an adapter touching it or an adapter holding an
-- MFU bound to it. OpenComputers presents both as the same me_inputbus
-- component, so the probe below does not care which one was built.
-- ---------------------------------------------------------------------------

-- Bus filter slot the probe borrows. The broker only sets filters while a
-- module runs and clears them when it stops, so this is free during detection.
local PROBE_BUS_SLOT    = 1
local BUS_PROBE_TIMEOUT = 5

-- How many of `label` sit on one transposer face.
local function sideTotal(transposer, side, label)
  local ok, size = pcall(transposer.getInventorySize, side)
  if not ok or not size then return 0 end
  local total = 0
  for s = 1, size do
    local ok2, st = pcall(transposer.getStackInSlot, side, s)
    if ok2 and st and st.label == label then total = total + (st.size or 0) end
  end
  return total
end

-- Move every stack of `label` from one face to another. Used to hand back
-- whatever a bus pulled during its probe.
local function moveAll(transposer, from, to, label)
  local ok, size = pcall(transposer.getInventorySize, from)
  if not ok or not size then return end
  for s = 1, size do
    local ok2, st = pcall(transposer.getStackInSlot, from, s)
    if ok2 and st and st.label == label then
      pcall(transposer.transferItem, from, to, st.size, s)
    end
  end
end

-- ---------------------------------------------------------------------------
-- Load configs
-- ---------------------------------------------------------------------------

local okCfg, nodeConf = pcall(dofile, CONFIG_PATH)
if not okCfg or type(nodeConf) ~= "table" then
  error("Cannot read " .. CONFIG_PATH .. " -- run detect_module.lua first.")
end
if not nodeConf.modules or #nodeConf.modules == 0 then
  error("No modules in " .. CONFIG_PATH .. " -- run detect_module.lua first.")
end
if not nodeConf.dbAddr or nodeConf.dbAddr == "" then
  error("dbAddr not set in " .. CONFIG_PATH)
end

-- config.lua only supplies a sensible default probe item; it isn't required.
-- It is also the only thing that knows the drone spelling for this pack, so the
-- hardcoded fallback below is the 2.8 one and will be wrong on 2.9 -- which
-- costs a retype at the prompt, not a wrong answer.
--
-- The probe has to be an item you ACTUALLY HOLD -- it gets borrowed from the ME
-- network and put back. This used to take the first drone out of pairs(), whose
-- order is arbitrary, so it could just as easily suggest MK-XIV (MAX) as MK-I.
-- Prefer the lowest tier, which is the one you are most likely to own, and walk
-- droneKeyOrder backwards (it runs highest to lowest) so the fallback is
-- deterministic too.
-- The literal is a last resort for a machine with no config.lua at all, and is
-- the CURRENT pack's spelling -- there is nothing here to derive the right one
-- from. On an older pack it will be wrong, which costs a retype at the prompt.
local okMain, mainConf = pcall(dofile, "/home/config.lua")
local defaultProbe = "Mining Drone Mk-I (LV)"
if okMain and type(mainConf) == "table" and type(mainConf.drones) == "table" then
  defaultProbe = mainConf.drones.lv or defaultProbe
  if not mainConf.drones.lv and type(mainConf.droneKeyOrder) == "table" then
    for i = #mainConf.droneKeyOrder, 1, -1 do
      local name = mainConf.drones[mainConf.droneKeyOrder[i]]
      if name then defaultProbe = name; break end
    end
  end
end

local db     = getProxy(nodeConf.dbAddr, "database")
local dbAddr = component.get(nodeConf.dbAddr)

-- Probe fingerprints go in the first slot past every module's 3-slot partition,
-- so we can never clobber a real load's drone/tip/rod.
local PROBE_DB_SLOT = #nodeConf.modules * 3 + 1

-- ---------------------------------------------------------------------------
-- Find one module's stocking bus
--
-- THE PROBE: set the probe item as a filter on each candidate bus in turn and
-- watch THIS module's bus face on its transposer. The bus whose face shows the
-- item is this module's bus, by definition -- the same active-signal idea as
-- the interface probe, with no reliance on addresses or block names.
-- ---------------------------------------------------------------------------

-- Set in main: whether to look for buses at all. Off by default, since only
-- stockingMode = filter uses them.
local wantBus = false

-- Every me_inputbus reachable from here that no OTHER module already claims.
local function unclaimedBuses(index)
  local claimed = {}
  for j, m in ipairs(nodeConf.modules) do
    if j ~= index and m.busAddr then
      local full = component.get(m.busAddr)
      if full then claimed[full] = true end
    end
  end
  local list = {}
  for addr in component.list("me_inputbus") do
    if not claimed[addr] then list[#list + 1] = addr end
  end
  table.sort(list)
  return list
end

-- When the probe cannot decide: list the candidates and let the operator pick.
-- The default keeps whatever the config already says, or skips.
local function pickBusByHand(cands, current)
  local def = 0
  for i, a in ipairs(cands) do
    local mark = ""
    if current and a:sub(1, #current) == current then def, mark = i, "  (current)" end
    print(string.format("    [%d] %s%s", i, a, mark))
  end
  local pick = tonumber(ask("  Which is this module's bus? [" .. def .. " = " ..
    (def == 0 and "skip" or "keep current") .. "]: ", tostring(def)))
  return pick and cands[pick] or nil
end

local function detectBus(index, mc, transposer, iface, ifaceSide, busSide, probeLabel)
  print("\n  Looking for this module's stocking bus (me_inputbus)...")
  local cands = unclaimedBuses(index)
  if #cands == 0 then
    print("  None reachable. Filter mode needs an adapter touching the stocking bus,")
    print("  or an adapter holding an MFU bound to it, on this computer's network.")
    return nil
  end

  -- A filter needs the item's full record, which the interface returns for a label.
  local okL, list = pcall(iface.getItemsInNetwork, { label = probeLabel })
  local detail = okL and type(list) == "table" and list[1] or nil
  if not detail then
    print("  Could not look up '" .. probeLabel .. "' through the interface" ..
          (okL and "" or (": " .. tostring(list))) .. ", so the buses cannot be probed.")
    return pickBusByHand(cands, mc.busAddr)
  end

  -- If the item is already on the bus face (the probe item is the drone sitting
  -- in slot 1, say), its arrival cannot be told from what was there before.
  if sideTotal(transposer, busSide, probeLabel) > 0 then
    print("  '" .. probeLabel .. "' is already in this bus, so the probe cannot see it")
    print("  arrive. Re-run with a probe item that is not in the bus, or pick:")
    return pickBusByHand(cands, mc.busAddr)
  end

  for _, addr in ipairs(cands) do
    local bus = component.proxy(addr)
    io.write("    " .. addr:sub(1, 8) .. "...  ")
    local okSet = pcall(bus.setConfiguration, PROBE_BUS_SLOT, detail)
    local hit = okSet and pollUntil(function()
      return sideTotal(transposer, busSide, probeLabel) > 0
    end, BUS_PROBE_TIMEOUT)
    -- Clear first, then hand back whatever the bus pulled.
    pcall(bus.setConfiguration, PROBE_BUS_SLOT)
    moveAll(transposer, busSide, ifaceSide, probeLabel)
    if hit then
      print("this module's bus")
      return addr
    end
    print(okSet and "not this one" or "refused the filter")
  end

  print("  No bus showed the item on this module's face within " ..
        BUS_PROBE_TIMEOUT .. "s each.")
  print("  A regular stocking bus only pulls while its machine runs -- start the")
  print("  module and re-run, or pick by hand:")
  return pickBusByHand(cands, mc.busAddr)
end

-- ---------------------------------------------------------------------------
-- Detect one module
-- ---------------------------------------------------------------------------

local function detectModule(index, probeLabel)
  local mc = nodeConf.modules[index]
  print("\n=== MODULE " .. index .. " (" .. tostring(mc.tier) .. ") ===")
  print("  current: interfaceSide = " .. tostring(mc.interfaceSide) ..
        ", inputBusSide = " .. tostring(mc.inputBusSide))

  local transposer = getProxy(mc.transposerAddr, "M" .. index .. " transposer")
  local iface      = getProxy(mc.ifaceAddr,      "M" .. index .. " iface")

  -- --- Pass 1: what is physically touching this transposer? -----------------
  local invs = scanInventories(transposer)
  print("\n  Inventories on this transposer:")
  if #invs == 0 then
    print("    (none)")
    print("\n  FAIL: this transposer touches no inventories at all. Either the")
    print("  transposerAddr in the config is the wrong transposer, or the block")
    print("  is not physically adjacent to the ME Interface and Input Bus.")
    return nil
  end
  for _, inv in ipairs(invs) do
    print(string.format("    side %-10s  %2d slots  %s", sideLabel(inv.side), inv.size, inv.name))
  end

  -- --- Pass 2: probe for the interface side ---------------------------------
  print("\n  Probing for the ME Interface with: " .. probeLabel)

  db.clear(PROBE_DB_SLOT)
  local stored = iface.store({ label = probeLabel }, dbAddr, PROBE_DB_SLOT)

  -- store() is a hint; the read-back is the truth (same rule loader.lua follows).
  local confirmed = pollUntil(function()
    local stack = db.get(PROBE_DB_SLOT)
    return stack ~= nil and stack.label == probeLabel
  end, PROBE_TIMEOUT)

  if not confirmed then
    print("\n  FAIL: could not fingerprint '" .. probeLabel .. "' (store returned " ..
          tostring(stored) .. ").")
    print("  That item is probably not in the ME network, or the label is spelled")
    print("  differently in-game. Re-run and pass a label you know is in stock.")
    db.clear(PROBE_DB_SLOT)
    return nil
  end

  iface.setInterfaceConfiguration(PROBE_CFG_SLOT, dbAddr, PROBE_DB_SLOT, 1)

  local ifaceSide, ifaceSlot = pollUntil(function()
    return findLabel(transposer, probeLabel)
  end, PROBE_TIMEOUT)

  local function cleanup()
    iface.setInterfaceConfiguration(PROBE_CFG_SLOT)
    db.clear(PROBE_DB_SLOT)
    pollUntil(function()
      return findLabel(transposer, probeLabel) == nil
    end, DRAIN_TIMEOUT)
  end

  if not ifaceSide then
    print("\n  FAIL: the interface accepted the fingerprint but the item never")
    print("  appeared on any transposer face within " .. PROBE_TIMEOUT .. "s.")
    print("  Most likely the transposer is not actually adjacent to THIS module's")
    print("  ME Interface -- check that transposerAddr and ifaceAddr belong to the")
    print("  same physical module.")
    cleanup()
    return nil
  end

  print("  -> interfaceSide = " .. sideLabel(ifaceSide) ..
        "  (probe item landed in slot " .. ifaceSlot .. ")")

  -- --- Pass 3: the input bus is the other inventory -------------------------
  local candidates = {}
  for _, inv in ipairs(invs) do
    if inv.side ~= ifaceSide then candidates[#candidates + 1] = inv end
  end

  local busSide
  if #candidates == 0 then
    print("\n  FAIL: the interface is the only inventory on this transposer.")
    print("  The Input Bus is not adjacent to it -- this is a physical build")
    print("  problem, not a config one. The transposer must touch both.")
    cleanup()
    return nil
  elseif #candidates == 1 then
    busSide = candidates[1].side
    print("  -> inputBusSide  = " .. sideLabel(busSide) ..
          "  (only other inventory: " .. candidates[1].name .. ")")
  else
    print("\n  " .. #candidates .. " possible input buses. Which one is this")
    print("  module's Input Bus?")
    for i, c in ipairs(candidates) do
      print(string.format("    [%d] side %-10s  %2d slots  %s",
            i, sideLabel(c.side), c.size, c.name))
    end
    local pick = tonumber(ask("  choose [1]: ", "1")) or 1
    if not candidates[pick] then pick = 1 end
    busSide = candidates[pick].side
  end

  -- --- Pass 4: round-trip the probe item, exactly like loader.lua step 5 ----
  print("\n  Verifying: moving the probe item interface -> bus and back...")

  -- Re-find the item rather than trusting ifaceSlot from the probe: the ME
  -- Interface reshuffles its buffer slots between calls. This is the same
  -- move-by-identity rule loader.lua learned the hard way (see its step 5).
  local _, src = findLabel(transposer, probeLabel)
  if not src then
    print("\n  FAIL: the probe item left the interface buffer before the transfer.")
    print("  Re-run -- if this repeats, the ME network is pulling it back faster")
    print("  than the check completes.")
    cleanup()
    return nil
  end

  local moved = transposer.transferItem(ifaceSide, busSide, 1, src, 1)

  if (moved or 0) < 1 then
    print("\n  FAIL: transferItem(" .. ifaceSide .. " -> " .. busSide ..
          ") moved " .. tostring(moved) .. "/1.")
    print("  The bus refused the item. If the Input Bus is full, empty it and")
    print("  re-run. If it has slot locking / a filter set, clear that -- the")
    print("  loader writes to bus slots 1, 2 and 3 by position.")
    cleanup()
    return nil
  end

  local landed = transposer.getStackInSlot(busSide, 1)
  if not landed or landed.label ~= probeLabel then
    print("\n  FAIL: transfer reported success but bus slot 1 holds " ..
          (landed and landed.label or "nothing") .. ".")
    cleanup()
    return nil
  end

  transposer.transferItem(busSide, ifaceSide, 1, 1)
  print("  -> round trip OK. These sides will work for the loader.")

  cleanup()

  -- --- Pass 5 (optional): which stocking bus is this module's? -------------
  local busAddr
  if wantBus then
    busAddr = detectBus(index, mc, transposer, iface, ifaceSide, busSide, probeLabel)
  end

  return { interfaceSide = ifaceSide, inputBusSide = busSide, busAddr = busAddr }
end

-- ---------------------------------------------------------------------------
-- Write the config back (same format detect_module.lua writes)
-- ---------------------------------------------------------------------------

local function writeConfig()
  local f, err = io.open(CONFIG_PATH, "w")
  if not f then error("Cannot open " .. CONFIG_PATH .. " for writing: " .. tostring(err)) end
  f:write("return {\n")
  f:write("  nodeId = \"" .. nodeConf.nodeId .. "\",\n")
  f:write("  dbAddr = \"" .. nodeConf.dbAddr .. "\",\n")
  f:write("  modules = {\n")
  for i, mod in ipairs(nodeConf.modules) do
    f:write("    [" .. i .. "] = {\n")
    f:write("      tier           = \"" .. mod.tier .. "\",\n")
    f:write("      moduleAddr     = \"" .. mod.moduleAddr .. "\",\n")
    f:write("      ifaceAddr      = \"" .. mod.ifaceAddr .. "\",\n")
    f:write("      transposerAddr = \"" .. mod.transposerAddr .. "\",\n")
    f:write("      interfaceSide  = " .. mod.interfaceSide .. ",\n")
    f:write("      inputBusSide   = " .. mod.inputBusSide .. ",\n")
    f:write("      distanceParam  = " .. mod.distanceParam .. ",\n")
    -- pinnedAsteroid is optional and hand-set. Emit it only when present,
    -- so re-running this script never silently drops a module's pin.
    if mod.pinnedAsteroid then
      f:write("      pinnedAsteroid = \"" .. mod.pinnedAsteroid .. "\",\n")
    end
    -- busAddr is hand-set too (stockingMode = filter). Same rule as the pin.
    if mod.busAddr then
      f:write("      busAddr        = \"" .. mod.busAddr .. "\",\n")
    end
    f:write("    },\n")
  end
  f:write("  }\n")
  f:write("}\n")
  f:close()
end

-- ---------------------------------------------------------------------------
-- Main
-- ---------------------------------------------------------------------------

local arg1 = ...
local targets = {}

if arg1 == "all" then
  for i = 1, #nodeConf.modules do targets[#targets + 1] = i end
elseif tonumber(arg1) then
  targets = { tonumber(arg1) }
else
  print("Modules in " .. CONFIG_PATH .. ":")
  for i, m in ipairs(nodeConf.modules) do
    print(string.format("  [%d] %s  iface=%s bus=%s",
          i, m.tier, tostring(m.interfaceSide), tostring(m.inputBusSide)))
  end
  local pick = ask("\nWhich module? (number, or 'all'): ", "all")
  if pick == "all" then
    for i = 1, #nodeConf.modules do targets[#targets + 1] = i end
  else
    targets = { tonumber(pick) }
  end
end

for _, i in ipairs(targets) do
  if not nodeConf.modules[i] then error("No module " .. tostring(i) .. " in config.") end
end

print("\nThe probe needs ONE item that is currently in your ME network.")
print("It is borrowed for a few seconds and put straight back.")
local probeLabel = ask("Probe item label [" .. tostring(defaultProbe) .. "]: ", defaultProbe)
if not probeLabel then error("No probe item given and no default found in config.lua.") end

wantBus = ask("Also find each module's stocking bus (only for stockingMode = filter)? [y/N]: ",
              "n"):lower():sub(1, 1) == "y"

local results = {}
for _, i in ipairs(targets) do
  results[i] = detectModule(i, probeLabel)
end

-- --- Summary + confirm -------------------------------------------------------
print("\n=== RESULTS ===")
local anyChange = false
for _, i in ipairs(targets) do
  local r = results[i]
  if not r then
    print("  M" .. i .. ": FAILED (left unchanged)")
  else
    local old = nodeConf.modules[i]
    -- A bus that was not found leaves the old busAddr alone, so it never counts
    -- as a change.
    local busChanged = r.busAddr ~= nil and r.busAddr ~= old.busAddr
    local changed = (old.interfaceSide ~= r.interfaceSide) or (old.inputBusSide ~= r.inputBusSide)
                    or busChanged
    print(string.format("  M%d: interfaceSide %s -> %d, inputBusSide %s -> %d%s",
          i, tostring(old.interfaceSide), r.interfaceSide,
          tostring(old.inputBusSide), r.inputBusSide,
          changed and "  [CHANGED]" or "  (already correct)"))
    if wantBus then
      print(string.format("       busAddr %s -> %s", tostring(old.busAddr),
            r.busAddr and r.busAddr or "(not found, unchanged)"))
    end
    if changed then anyChange = true end
  end
end

if not anyChange then
  print("\nNothing to write -- every detected module already had the right sides.")
  print("If loads are still failing, the sides are not the cause. Check the")
  print("broker's error line: it names which step failed.")
  return
end

local answer = ask("\nWrite these to " .. CONFIG_PATH .. "? [y/N]: ", "n")
if answer:lower():sub(1, 1) ~= "y" then
  print("Aborted. No changes written.")
  return
end

for _, i in ipairs(targets) do
  if results[i] then
    nodeConf.modules[i].interfaceSide = results[i].interfaceSide
    nodeConf.modules[i].inputBusSide  = results[i].inputBusSide
    if results[i].busAddr then nodeConf.modules[i].busAddr = results[i].busAddr end
  end
end
writeConfig()

print("\nWritten. Restart broker-mk3 to pick up the corrected sides.")
