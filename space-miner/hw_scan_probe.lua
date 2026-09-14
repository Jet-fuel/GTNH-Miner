-- =============================================================================
-- hw_scan_probe.lua -- one-shot sizing diagnostic for the hw node's ME scan
--
-- WHY THIS EXISTS
--
-- hw_telem reads drone and drill-part counts by asking the ME network for one
-- exact label at a time -- thirty-two queries a cycle. Every one of those costs
-- the server a conversion of the ENTIRE network into Lua tables, because
-- OpenComputers composes the call as allItems.map(convert).filter(predicate):
-- the filter is applied after the conversion, not before it. So the filter buys
-- memory, not speed, and the server cost tracks the NUMBER of calls.
--
-- One unfiltered pass per cycle would therefore be thirty-two times cheaper.
-- The reason hw_telem does not do that is that the resulting list does not fit
-- in the node's heap -- it returns nil, or takes the machine out with "not
-- enough memory", and that failure is not reliably catchable.
--
-- Between those two extremes sit two things this script measures, because
-- neither can be guessed from outside the game:
--
--   1. HOW BIG the full list actually is, in entries and in kilobytes. That
--      says whether any legitimate amount of RAM can hold it, or whether the
--      full pass is off the table no matter what is fitted.
--
--   2. WHETHER THE THIRTY-TWO LABELS SHARE INTERNAL ITEM NAMES. An OC filter
--      matches any field of the stack, not just the label -- including `name`,
--      the internal id. If all fourteen drones are one id with different damage
--      values, they are ONE query rather than fourteen, and the same may hold
--      for the drill tips and rods. That would cut the per-cycle call count
--      without costing any freshness, which rotating a subset of labels does.
--
--      The catch, and why this has to be measured: a grouped query returns
--      every stack in the network sharing that id. If the drill parts turn out
--      to live on a GregTech meta-item shared with thousands of other entries,
--      the group is as unusable as the full pass. The share counts below say
--      which case we are in.
--
-- REQUIREMENTS
--
-- This makes one unfiltered getItemsInNetwork() call, which is the call the hw
-- node cannot survive. Run it on a machine that CAN -- the hw node while it has
-- the memory fitted to manage it, or any other machine on the same controller.
-- It writes nothing and changes nothing.
--
--   hw_scan_probe
--   hw_scan_probe > /home/probe.txt      (to read it back at leisure)
-- =============================================================================

local component = require("component")
local computer  = require("computer")

local me = nil
for addr in component.list("me_controller")  do me = component.proxy(addr) break end
if not me then
  for addr in component.list("me_interface") do me = component.proxy(addr) break end
end
if not me then error("No ME Controller or Interface attached.") end

-- Same table hw_telem carries. Labels are version-independent here: drones are
-- matched by the roman numeral out of whatever spelling this pack uses, exactly
-- as hw_telem's full-scan path does, so this works without the broker.
local drillLookup = {
  ["Steel Drill Tip"] = true,              ["Steel Rod"] = true,
  ["Titanium Drill Tip"] = true,           ["Titanium Rod"] = true,
  ["Tungstensteel Drill Tip"] = true,      ["Tungstensteel Rod"] = true,
  ["Naquadah Drill Tip"] = true,           ["Naquadah Rod"] = true,
  ["Naquadah Alloy Drill Tip"] = true,     ["Naquadah Alloy Rod"] = true,
  ["Neutronium Drill Tip"] = true,         ["Neutronium Rod"] = true,
  ["Cosmic Neutronium Drill Tip"] = true,  ["Cosmic Neutronium Rod"] = true,
  ["Infinity Drill Tip"] = true,           ["Infinity Rod"] = true,
  ["Transcendent Metal Drill Tip"] = true, ["Transcendent Metal Rod"] = true,
}

local gc = type(collectgarbage) == "function" and collectgarbage or function() end

print("probing -- one full network pass, this may take a moment")
gc()
local totalMem  = computer.totalMemory()
local freeBefore = computer.freeMemory()

local t0 = computer.uptime()
local ok, items, why = pcall(me.getItemsInNetwork)
local elapsed = computer.uptime() - t0

if not ok then
  print("FAILED (threw): " .. tostring(items))
  print("This machine cannot hold the list either. Run it somewhere with more")
  print("memory, or the full pass is not available to this network at all.")
  return
elseif items == nil then
  print("FAILED (returned nil): " .. tostring(why or "no reason given"))
  return
end

local freeAfter = computer.freeMemory()
local entries   = #items

-- Which internal name does each target label live on, and how many entries in
-- the whole network share that name?
local targetName  = {}   -- label -> internal name
local shareCount  = {}   -- internal name -> entries in the network with that name
local groupLabels = {}   -- internal name -> how many of OUR labels use it
local foundDrones, foundDrills = 0, 0

for i = 1, entries do
  local it = items[i]
  local nm = it and it.name
  if nm then shareCount[nm] = (shareCount[nm] or 0) + 1 end
end

for i = 1, entries do
  local it = items[i]
  local label = it and it.label
  if label then
    local isDrone = label:match("^Mining Drone [Mm][Kk]%-([XVI]+)") ~= nil
    if isDrone or drillLookup[label] then
      if not targetName[label] then
        targetName[label] = it.name or "?"
        groupLabels[it.name or "?"] = (groupLabels[it.name or "?"] or 0) + 1
        if isDrone then foundDrones = foundDrones + 1 else foundDrills = foundDrills + 1 end
      end
    end
  end
end

items = nil
gc()

print("")
print("NETWORK")
print(string.format("  entries in one full pass : %d", entries))
print(string.format("  call took                : %.2f s of wall clock", elapsed))
print(string.format("  heap total               : %d k", math.floor(totalMem / 1024)))
print(string.format("  free before / after      : %d k / %d k",
  math.floor(freeBefore / 1024), math.floor(freeAfter / 1024)))
print(string.format("  => the list cost about   : %d k",
  math.floor((freeBefore - freeAfter) / 1024)))
print("  (that is what the list RETAINS. Peak during the call is higher, so a")
print("   machine needs comfortably more than this figure free, not exactly it.)")

print("")
print("TARGETS FOUND")
print(string.format("  drones %d of 14, drill parts %d of 18", foundDrones, foundDrills))
print("  (anything missing is simply not in the network right now)")

print("")
print("GROUPING -- one query per internal name instead of one per label")
local names = {}
for nm in pairs(groupLabels) do names[#names + 1] = nm end
table.sort(names, function(a, b) return (groupLabels[a] or 0) > (groupLabels[b] or 0) end)
for _, nm in ipairs(names) do
  print(string.format("  %-42s covers %2d of our labels, but a query for it",
    nm, groupLabels[nm]))
  print(string.format("  %-42s would return %d entries",
    "", shareCount[nm] or 0))
end

local groups, worstGroup = 0, 0
for _, nm in ipairs(names) do
  groups = groups + 1
  if (shareCount[nm] or 0) > worstGroup then worstGroup = shareCount[nm] or 0 end
end

print("")
print("CALLS PER CYCLE, BY STRATEGY")
print(string.format("  per label (what hw_telem does today) : 32"))
print(string.format("  by internal name                     : %d  (largest returns %d entries)",
  groups, worstGroup))
print(string.format("  one full pass                        : 1  (returns %d entries)", entries))
print("")
print("Grouping is worth doing if the largest group is a few hundred entries or")
print("fewer. If it is thousands, that group has to stay per-label or rotate.")
