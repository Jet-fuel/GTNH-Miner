-- =============================================================================
-- detect_module.lua
-- Finds a newly-added Mining Module, works out how it is wired, and writes it
-- into /home/job_node_config.lua. No questions asked.
--
-- WORKFLOW (one module at a time):
--   1. Physically add the new module's components:
--        - gt_machine  adapter  (controls the Mining Module)
--        - me_interface adapter (the module's ME Interface)
--        - transposer           (moves items interface buffer -> input bus)
--      and, only for stockingMode = filter, the stocking bus: an adapter
--      touching it, or an adapter holding an MFU bound to it (me_inputbus).
--   2. Run:  detect_module
--   3. Repeat for the next module.
--
--   detect_module fix        re-detect every module already in the config
--   detect_module fix 3      re-detect module 3 only
--
-- WHAT IT WORKS OUT, AND HOW
--
--   Addresses   the components NOT already in the config. Exactly one new one
--               of each core type, or it stops -- a stray cable or a double-add
--               can never silently produce a garbage config. The bus is
--               optional and never stops the run.
--   Tier        read from the module controller's own text.
--   Sides       by an active probe, not by block names (which vary by pack):
--               the interface is asked to stock one item, and the transposer
--               face whose count of it GOES UP is the interface side. Counting
--               the rise rather than looking for the item means a bus already
--               holding tips cannot be mistaken for the interface.
--   Bus         each unclaimed me_inputbus is given the item as a filter; the
--               face that goes up is the input bus side, and that bus is this
--               module's busAddr. An adapter and an MFU look the same here.
--               With no bus component, the input bus is the one other face.
--   Verified    a real round trip: one item interface -> bus -> back, the same
--               transferItem() the loader performs.
--
-- The probe item is chosen automatically: the first drill tip or rod from
-- config.lua that the ME network actually holds. It is borrowed for a few
-- seconds and put back.
--
-- Nothing is written unless every step succeeded. A regular stocking bus only
-- pulls while its machine runs, so if the bus is not found on a stopped module,
-- start it and run `detect_module fix`.
-- =============================================================================

local component = require("component")
local computer  = require("computer")
local fsExists  = require("filesystem").exists

local CONFIG_PATH = "/home/job_node_config.lua"
local SIDE_NAMES  = { [0]="down", [1]="up", [2]="north", [3]="south", [4]="west", [5]="east" }

-- Component type strings as OpenComputers reports them.
local TYPE_MACHINE    = "gt_machine"
local TYPE_INTERFACE  = "me_interface"
local TYPE_TRANSPOSER = "transposer"
local TYPE_DATABASE   = "database"
local TYPE_BUS        = "me_inputbus"

-- How long to wait for the ME network to deliver, and to take items back.
-- Generous: a laggy server is not an error, it is just slow.
local PROBE_TIMEOUT     = 10
local DRAIN_TIMEOUT     = 10
local BUS_PROBE_TIMEOUT = 5
local POLL_INTERVAL     = 0.2

-- The interface config slot borrowed for probing. loader.lua uses 1-8, so 9
-- stays clear of a real load. Bus filter slot 1 is free during detection: the
-- broker only sets filters while a module runs and clears them when it stops.
local PROBE_CFG_SLOT = 9
local PROBE_BUS_SLOT = 1

local DEFAULT_NODE_ID = "MEDINA-Ring-1"

print("=== DETECT MODULE ===")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function sideLabel(side)
  return string.format("%d (%s)", side, SIDE_NAMES[side])
end

local function proxyOf(addr, what)
  local full = component.get(addr)
  if not full then error(what .. ": component '" .. tostring(addr) .. "' not found") end
  return component.proxy(full)
end

-- Poll until fn returns a truthy value, or time out. Returns that value.
-- computer.uptime() is the same clock scheduler.lua uses.
local function pollUntil(fn, timeout)
  local deadline = computer.uptime() + timeout
  while true do
    local v = fn()
    if v then return v end
    if computer.uptime() >= deadline then return nil end
    os.sleep(POLL_INTERVAL)
  end
end

-- Every transposer face with an inventory behind it: { side, size, name }.
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

-- How many of `label` each face holds: side -> count.
local function faceTotals(transposer, invs, label)
  local totals = {}
  for _, inv in ipairs(invs) do
    local total = 0
    for s = 1, inv.size do
      local ok, st = pcall(transposer.getStackInSlot, inv.side, s)
      if ok and st and st.label == label then total = total + (st.size or 0) end
    end
    totals[inv.side] = total
  end
  return totals
end

-- The face whose count of `label` has risen since `before`, or nil.
local function grownFace(transposer, invs, label, before)
  local now = faceTotals(transposer, invs, label)
  for _, inv in ipairs(invs) do
    if now[inv.side] > (before[inv.side] or 0) then return inv.side end
  end
  return nil
end

-- First slot on one face holding `label`, or nil.
local function slotOf(transposer, side, size, label)
  for s = 1, size do
    local ok, st = pcall(transposer.getStackInSlot, side, s)
    if ok and st and st.label == label then return s end
  end
  return nil
end

-- Move `count` of `label` from one face to another, a slot at a time.
local function moveCount(transposer, from, fromSize, to, label, count)
  for s = 1, fromSize do
    if count <= 0 then return end
    local ok, st = pcall(transposer.getStackInSlot, from, s)
    if ok and st and st.label == label then
      local okT, moved = pcall(transposer.transferItem, from, to, math.min(count, st.size), s)
      if okT and moved then count = count - moved end
    end
  end
end

local function sizeOf(invs, side)
  for _, inv in ipairs(invs) do
    if inv.side == side then return inv.size end
  end
  return 0
end

-- ---------------------------------------------------------------------------
-- Load the config, or bootstrap a fresh one.
-- ---------------------------------------------------------------------------
local config
if fsExists(CONFIG_PATH) then config = dofile(CONFIG_PATH) end
if not config or type(config) ~= "table" then
  config = { nodeId = "", dbAddr = "", modules = {} }
end
config.modules = config.modules or {}

-- The shared database. Exactly one is expected on this computer; with more, the
-- right one cannot be guessed, so that is the one thing left to set by hand.
if not config.dbAddr or config.dbAddr == "" or config.dbAddr:find("REPLACE", 1, true) then
  local dbs = {}
  for addr, ctype in component.list() do
    if ctype:find(TYPE_DATABASE, 1, true) then dbs[#dbs + 1] = addr end
  end
  if #dbs == 1 then
    config.dbAddr = dbs[1]
    print("Auto-detected shared database: " .. config.dbAddr)
  elseif #dbs == 0 then
    error("No 'database' component found. Attach an OC Database upgrade/component.")
  else
    print("Multiple databases found -- set dbAddr in " .. CONFIG_PATH .. " to one of:")
    for _, a in ipairs(dbs) do print("  " .. a) end
    error("Set config.dbAddr manually when more than one database exists.")
  end
end

-- A node name is only cosmetic on a single-node setup. Multi-node fleets need
-- unique names; edit nodeId in the config if you run more than one.
if not config.nodeId or config.nodeId == "" then
  config.nodeId = DEFAULT_NODE_ID
  print("Node name set to " .. DEFAULT_NODE_ID .. " (edit nodeId in the config to change it)")
end

local db     = proxyOf(config.dbAddr, "database")
local dbAddr = component.get(config.dbAddr)

-- Prune placeholder / stale module entries. The example config (or a half-edited
-- one) can carry "REPLACE-..." addresses or components that no longer exist;
-- those must not count, or the first real module would be added as M2.
local liveAddrs = {}
for addr in component.list() do liveAddrs[addr] = true end

-- Config addresses may be stored short (8 chars) or as a full UUID, so match on
-- the shorter one being a genuine prefix of the longer.
local function samePrefix(a, b)
  local n = math.min(#a, #b)
  return a:sub(1, n) == b:sub(1, n)
end

local function isLiveAddr(a)
  if not a or a == "" or a:find("REPLACE", 1, true) then return false end
  for live in pairs(liveAddrs) do
    if samePrefix(a, live) then return true end
  end
  return false
end

do
  local valid, pruned = {}, 0
  for _, mod in ipairs(config.modules) do
    if isLiveAddr(mod.moduleAddr) and isLiveAddr(mod.ifaceAddr) and isLiveAddr(mod.transposerAddr) then
      valid[#valid + 1] = mod
    else
      pruned = pruned + 1
    end
  end
  config.modules = valid
  if pruned > 0 then
    print("Dropped " .. pruned .. " placeholder/stale module entr" ..
          (pruned == 1 and "y" or "ies") .. " (addresses not live components).")
  end
end

-- Probe fingerprints go in the first database slot past every module's 3-slot
-- partition. In add mode that is the new module's first slot, unused until it
-- loads; either way a real load's drone/tip/rod is never clobbered.
local PROBE_DB_SLOT = #config.modules * 3 + 1

-- ---------------------------------------------------------------------------
-- Probe item: the first drill consumable from config.lua the network holds.
-- Tips and rods are cheap and nearly always stocked; drones are left out
-- because one usually sits in a bus already.
-- ---------------------------------------------------------------------------
local DRILL_ORDER = { "steel", "titanium", "tungstensteel", "naquadah", "naquadahAlloy",
                      "neutronium", "cosmicNeutronium", "infinity", "transcendentMetal" }

local function probeCandidates()
  local labels = {}
  local ok, main = pcall(dofile, "/home/config.lua")
  if ok and type(main) == "table" and type(main.drills) == "table" then
    for _, key in ipairs(DRILL_ORDER) do
      local d = main.drills[key]
      if d then
        labels[#labels + 1] = d.tip
        labels[#labels + 1] = d.rod
      end
    end
  end
  if #labels == 0 then labels = { "Steel Drill Tip", "Steel Rod" } end
  return labels
end

-- One filtered network query per label, stopping at the first in stock --
-- normally the very first.
local function pickProbe(iface)
  local tried = probeCandidates()
  for _, label in ipairs(tried) do
    local ok, list = pcall(iface.getItemsInNetwork, { label = label })
    if ok and type(list) == "table" and list[1] and (list[1].size or 0) >= 1 then
      return label, list[1]
    end
  end
  return nil, nil, tried
end

-- ---------------------------------------------------------------------------
-- Probe one module's wiring. `entry` needs ifaceAddr and transposerAddr.
-- `claimed` is the set of bus addresses other modules already own.
-- Returns { interfaceSide, inputBusSide, busAddr, busNote } or nil, reason.
-- ---------------------------------------------------------------------------
local function probeModule(entry, claimed)
  local transposer = proxyOf(entry.transposerAddr, "transposer")
  local iface      = proxyOf(entry.ifaceAddr, "ME Interface")

  local invs = scanInventories(transposer)
  print("  Inventories on this transposer:")
  for _, inv in ipairs(invs) do
    print(string.format("    side %-10s  %2d slots  %s", sideLabel(inv.side), inv.size, inv.name))
  end
  if #invs < 2 then
    return nil, "the transposer touches " .. #invs .. " inventor" .. (#invs == 1 and "y" or "ies") ..
                "; it must touch both the ME Interface and the input bus"
  end

  local probeLabel, detail, tried = pickProbe(iface)
  if not probeLabel then
    return nil, "none of these are in the ME network to probe with: " .. table.concat(tried, ", ")
  end
  print("  Probe item: " .. probeLabel)

  -- --- Interface side: the face that rises when the interface stocks one ----
  db.clear(PROBE_DB_SLOT)
  iface.store({ label = probeLabel }, dbAddr, PROBE_DB_SLOT)
  -- store() is a hint; the read-back is the truth (same rule loader.lua follows).
  local fingerprinted = pollUntil(function()
    local st = db.get(PROBE_DB_SLOT)
    return st ~= nil and st.label == probeLabel
  end, PROBE_TIMEOUT)
  if not fingerprinted then
    db.clear(PROBE_DB_SLOT)
    return nil, "could not fingerprint '" .. probeLabel .. "' into the database"
  end

  local function stock()   iface.setInterfaceConfiguration(PROBE_CFG_SLOT, dbAddr, PROBE_DB_SLOT, 1) end
  local function unstock() iface.setInterfaceConfiguration(PROBE_CFG_SLOT) end

  local before = faceTotals(transposer, invs, probeLabel)
  stock()
  local ifaceSide = pollUntil(function()
    return grownFace(transposer, invs, probeLabel, before)
  end, PROBE_TIMEOUT)
  unstock()
  if not ifaceSide then
    db.clear(PROBE_DB_SLOT)
    return nil, "the interface never delivered to any face of this transposer -- " ..
                "transposerAddr and ifaceAddr may belong to different modules"
  end
  print("  -> interfaceSide = " .. sideLabel(ifaceSide))
  pollUntil(function()
    return faceTotals(transposer, invs, probeLabel)[ifaceSide] <= (before[ifaceSide] or 0)
  end, DRAIN_TIMEOUT)

  local others = {}
  for _, inv in ipairs(invs) do
    if inv.side ~= ifaceSide then others[#others + 1] = inv end
  end

  -- --- Bus: give each unclaimed stocking bus the filter, see which face rises
  local busSide, busAddr, busNote
  local cands = {}
  for addr in component.list(TYPE_BUS) do
    if not claimed[addr] then cands[#cands + 1] = addr end
  end
  table.sort(cands)

  if #cands == 0 then
    busNote = "no unclaimed " .. TYPE_BUS .. " reachable (only needed for stockingMode = filter)"
  else
    for _, addr in ipairs(cands) do
      local bus = component.proxy(addr)
      local beforeBus = faceTotals(transposer, others, probeLabel)
      local okSet = pcall(bus.setConfiguration, PROBE_BUS_SLOT, detail)
      local side = okSet and pollUntil(function()
        return grownFace(transposer, others, probeLabel, beforeBus)
      end, BUS_PROBE_TIMEOUT)
      pcall(bus.setConfiguration, PROBE_BUS_SLOT)
      if side then
        -- Hand back whatever the bus pulled beyond what it held before.
        local extra = faceTotals(transposer, others, probeLabel)[side] - (beforeBus[side] or 0)
        if extra > 0 then
          moveCount(transposer, side, sizeOf(invs, side), ifaceSide, probeLabel, extra)
        end
        busSide, busAddr = side, addr
        print("  -> busAddr       = " .. addr)
        break
      end
    end
    if not busAddr then
      busNote = "no stocking bus showed the item here; a regular stocking bus only pulls " ..
                "while its machine runs -- start the module and run `detect_module fix`"
    end
  end

  -- --- Input bus side: from the bus probe, or the only other face ----------
  if not busSide then
    if #others == 1 then
      busSide = others[1].side
    else
      db.clear(PROBE_DB_SLOT)
      return nil, #others .. " inventories besides the interface, and no stocking bus " ..
                  "answered to say which is the input bus -- the transposer should touch " ..
                  "only the interface and the bus"
    end
  end
  print("  -> inputBusSide  = " .. sideLabel(busSide))

  -- --- Verify: one item interface -> bus -> back, as the loader does -------
  before = faceTotals(transposer, invs, probeLabel)
  stock()
  local arrived = pollUntil(function()
    return faceTotals(transposer, invs, probeLabel)[ifaceSide] > (before[ifaceSide] or 0)
  end, PROBE_TIMEOUT)
  local verified, why = false, "the interface did not deliver the probe item a second time"
  if arrived then
    -- Re-find the slot rather than trusting an earlier one: the ME Interface
    -- reshuffles its buffer between calls (loader.lua step 5 learned this).
    local src = slotOf(transposer, ifaceSide, sizeOf(invs, ifaceSide), probeLabel)
    local busBefore = faceTotals(transposer, invs, probeLabel)[busSide]
    local okT, moved = pcall(transposer.transferItem, ifaceSide, busSide, 1, src)
    if okT and (moved or 0) >= 1
       and faceTotals(transposer, invs, probeLabel)[busSide] > busBefore then
      moveCount(transposer, busSide, sizeOf(invs, busSide), ifaceSide, probeLabel, 1)
      verified = true
    else
      why = "the bus refused the item (full, or a slot lock / filter set on it)"
    end
  end
  unstock()
  db.clear(PROBE_DB_SLOT)
  pollUntil(function()
    return faceTotals(transposer, invs, probeLabel)[ifaceSide] <= (before[ifaceSide] or 0)
  end, DRAIN_TIMEOUT)
  if not verified then return nil, why end
  print("  -> round trip OK")

  return { interfaceSide = ifaceSide, inputBusSide = busSide,
           busAddr = busAddr, busNote = busNote }
end

-- Bus addresses owned by every module except `skip`, as full addresses.
local function claimedBuses(skip)
  local claimed = {}
  for i, m in ipairs(config.modules) do
    if i ~= skip and m.busAddr then
      local full = component.get(m.busAddr)
      if full then claimed[full] = true end
    end
  end
  return claimed
end

-- ---------------------------------------------------------------------------
-- Write the config. The one writer: every optional key is preserved here.
-- ---------------------------------------------------------------------------
local function writeConfig()
  local f, err = io.open(CONFIG_PATH, "w")
  if not f then error("Cannot open " .. CONFIG_PATH .. " for writing: " .. tostring(err)) end
  f:write("return {\n")
  f:write("  nodeId = \"" .. config.nodeId .. "\",\n")
  f:write("  dbAddr = \"" .. config.dbAddr .. "\",\n")
  f:write("  modules = {\n")
  for i, mod in ipairs(config.modules) do
    f:write("    [" .. i .. "] = {\n")
    f:write("      tier           = \"" .. mod.tier .. "\",\n")
    f:write("      moduleAddr     = \"" .. mod.moduleAddr .. "\",\n")
    f:write("      ifaceAddr      = \"" .. mod.ifaceAddr .. "\",\n")
    f:write("      transposerAddr = \"" .. mod.transposerAddr .. "\",\n")
    f:write("      interfaceSide  = " .. mod.interfaceSide .. ",\n")
    f:write("      inputBusSide   = " .. mod.inputBusSide .. ",\n")
    f:write("      distanceParam  = " .. mod.distanceParam .. ",\n")
    -- Optional keys are emitted only when present, so a re-run never silently
    -- drops a hand-set pin or a detected bus.
    if mod.pinnedAsteroid then
      f:write("      pinnedAsteroid = \"" .. mod.pinnedAsteroid .. "\",\n")
    end
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
-- FIX MODE: re-detect modules already in the config.
-- ---------------------------------------------------------------------------
local mode, which = ...
if mode == "fix" then
  local targets = {}
  if tonumber(which) then
    targets = { tonumber(which) }
  else
    for i = 1, #config.modules do targets[#targets + 1] = i end
  end
  if #targets == 0 then
    print("No modules in the config yet -- run detect_module to add one.")
    return
  end

  local anyChange = false
  for _, i in ipairs(targets) do
    local mc = config.modules[i]
    if not mc then error("No module " .. tostring(i) .. " in the config.") end
    print("\n=== MODULE " .. i .. " (" .. tostring(mc.tier) .. ") ===")
    local r, err = probeModule(mc, claimedBuses(i))
    if not r then
      print("  FAILED, left unchanged: " .. err)
    else
      if r.busNote then print("  bus: " .. r.busNote) end
      -- A bus that was not found leaves the old busAddr alone.
      local newBus = r.busAddr or mc.busAddr
      local changed = mc.interfaceSide ~= r.interfaceSide or mc.inputBusSide ~= r.inputBusSide
                      or mc.busAddr ~= newBus
      mc.interfaceSide, mc.inputBusSide, mc.busAddr = r.interfaceSide, r.inputBusSide, newBus
      print(changed and "  [CHANGED]" or "  (already correct)")
      if changed then anyChange = true end
    end
  end

  if anyChange then
    writeConfig()
    print("\nWritten to " .. CONFIG_PATH .. ". Restart broker-mk3 to pick it up.")
  else
    print("\nNothing to write.")
  end
  return
end

-- ---------------------------------------------------------------------------
-- ADD MODE: find the new components.
-- ---------------------------------------------------------------------------
local existingCount = #config.modules
print("Existing valid modules in config: " .. existingCount)

-- Every address the config already references, plus the shared database.
local known = {}
for _, mod in ipairs(config.modules) do
  for _, a in ipairs({ mod.moduleAddr, mod.ifaceAddr, mod.transposerAddr, mod.busAddr }) do
    if a then known[#known + 1] = a end
  end
end
known[#known + 1] = config.dbAddr

local function isKnown(fullAddr)
  for _, a in ipairs(known) do
    if samePrefix(fullAddr, a) then return true end
  end
  return false
end

-- Substring-match the type so a slightly different type string on some
-- install still buckets correctly, and print every type seen so a mismatch
-- is readable rather than a silent empty result.
local newMachines, newInterfaces, newTransposers = {}, {}, {}
local seenTypes = {}
for addr, ctype in component.list() do
  seenTypes[ctype] = (seenTypes[ctype] or 0) + 1
  if not isKnown(addr) then
    if     ctype:find(TYPE_MACHINE,    1, true) then newMachines[#newMachines + 1]       = addr
    elseif ctype:find(TYPE_INTERFACE,  1, true) then newInterfaces[#newInterfaces + 1]   = addr
    elseif ctype:find(TYPE_TRANSPOSER, 1, true) then newTransposers[#newTransposers + 1] = addr
    end
  end
end

print("\nComponent types present on this computer:")
for t, n in pairs(seenTypes) do print(string.format("  %-22s x%d", t, n)) end
print(string.format("\nNew (unconfigured): %d %s, %d %s, %d %s",
  #newMachines, TYPE_MACHINE, #newInterfaces, TYPE_INTERFACE, #newTransposers, TYPE_TRANSPOSER))

if not (#newMachines == 1 and #newInterfaces == 1 and #newTransposers == 1) then
  print("\n[STOP] Expected exactly one new component of each type.")
  print("Add ONE module at a time, and check for loose adapters/cables.")
  for _, pair in ipairs({ { "gt_machine", newMachines }, { "me_interface", newInterfaces },
                          { "transposer", newTransposers } }) do
    if #pair[2] > 0 then
      print("  new " .. pair[1] .. ":")
      for _, a in ipairs(pair[2]) do print("    " .. a) end
    end
  end
  if #newMachines == 0 and #newInterfaces == 0 and #newTransposers == 0 then
    print("\n(Nothing new detected. If every module is already configured and you want")
    print(" to re-check their wiring, run: detect_module fix)")
  end
  return
end

-- ---------------------------------------------------------------------------
-- Tier: read from the module controller. Nothing in GT guarantees WHERE, so
-- every string the adapter hands back is scraped for an MK marker. Roman first,
-- longest-first so "MK-III" cannot match the "MK-I" prefix.
-- ---------------------------------------------------------------------------
local TIER_BY_NUM = { "MK-I", "MK-II", "MK-III" }

local function tierFromText(text)
  local up = text:upper()
  for _, roman in ipairs({ "III", "II", "I" }) do
    if up:find("MK[%s%-_]?" .. roman .. "%f[^IV]") then return "MK-" .. roman end
  end
  local n = up:match("MK[%s%-_]?([123])") or up:match("TIER[%s:]+([123])")
  if n then return TIER_BY_NUM[tonumber(n)] end
  return nil
end

local function machineStrings(addr)
  local proxy = component.proxy(addr)
  local out = {}
  local function collect(v)
    if type(v) == "string" then
      out[#out + 1] = v
    elseif type(v) == "table" then
      for _, inner in pairs(v) do collect(inner) end
    end
  end
  -- getParameters is GTNH 2.9's introspection call and getParametersInfo is
  -- 2.8's; a module has one or the other, and the pcall tolerates the missing one.
  for _, call in ipairs({ "getName", "getSensorInformation",
                          "getParameters", "getParametersInfo" }) do
    local okCall, res = pcall(function() return proxy[call] and proxy[call]() end)
    if okCall then collect(res) end
  end
  return out
end

-- Which parameter API this controller speaks: the same check module_api.lua
-- makes at boot, reported so it is visible whether distanceParam matters.
local function dialectOf(addr)
  local proxy = component.proxy(addr)
  local ok29, has29 = pcall(function() return proxy.setParameter  ~= nil end)
  if ok29 and has29 then return "GTNH 2.9 (named parameters)" end
  local ok28, has28 = pcall(function() return proxy.setParameters ~= nil end)
  if ok28 and has28 then return "GTNH 2.8 (indexed parameters)" end
  return nil
end

local newIndex = existingCount + 1
local template = config.modules[existingCount]

local tier, tierEvidence
for _, s in ipairs(machineStrings(newMachines[1])) do
  tier = tierFromText(s)
  if tier then tierEvidence = s break end
end
local dialect = dialectOf(newMachines[1])

print("\n=== NEW MODULE " .. newIndex .. " ===")
print("  moduleAddr     = " .. newMachines[1])
print("  module API     = " .. (dialect or "? -- neither setParameter nor setParameters"))
print("  ifaceAddr      = " .. newInterfaces[1])
print("  transposerAddr = " .. newTransposers[1])
if tier then
  print("  tier           = " .. tier .. "  (read from the module: \"" ..
        tierEvidence:gsub("§.", "") .. "\")")
else
  tier = template and template.tier or "MK-I"
  print("  tier           = " .. tier .. "  (WARNING: the module did not report one; " ..
        "using " .. (template and ("M" .. existingCount .. "'s") or "the default") ..
        " -- correct it in the config if wrong)")
end

local entry = {
  tier           = tier,
  moduleAddr     = newMachines[1],
  ifaceAddr      = newInterfaces[1],
  transposerAddr = newTransposers[1],
  distanceParam  = template and template.distanceParam or 0,
}

print("\nProbing the wiring...")
local r, err = probeModule(entry, claimedBuses(nil))
if not r then
  print("\n[STOP] " .. err)
  print("Nothing written. Fix the cause and run detect_module again.")
  return
end
if r.busNote then print("  bus: " .. r.busNote) end

entry.interfaceSide = r.interfaceSide
entry.inputBusSide  = r.inputBusSide
entry.busAddr       = r.busAddr

config.modules[newIndex] = entry
writeConfig()

print("\n=== MODULE " .. newIndex .. " WRITTEN ===")
print("  tier           = " .. entry.tier)
print("  interfaceSide  = " .. sideLabel(entry.interfaceSide))
print("  inputBusSide   = " .. sideLabel(entry.inputBusSide))
print("  busAddr        = " .. (entry.busAddr or "(none)"))
print("  distanceParam  = " .. entry.distanceParam ..
      (dialect and dialect:find("2%.9") and "   (ignored on GTNH 2.9)" or ""))
print("Total modules now: " .. #config.modules .. ". Restart broker-mk3 to pick it up.")
