-- =============================================================================
-- Node ID: MEDINA-HWRelay
-- File:    hw_telem.lua
-- Purpose: Scans Space Elevator staging ME network for drill consumable
--          availability; broadcasts stock data to the broker, and auto-crafts
--          drill tips/rods back up to the par levels the broker publishes
--          (DRILL_PAR on port 2025).
--
--          Drones are NOT scanned. They are a durable asset -- you own them,
--          they move between the network and a bus, nothing consumes them --
--          so the broker holds the count as a declared setting and keeps the
--          ledger itself (settings.lua, droneStock.*). Tips and rods are
--          consumed, so they are the only thing here that has to be measured.
--
--          The broker owns the par policy; this node owns execution, because it
--          holds the ME controller proxy and the freshest counts. See
--          broadcastDrillPar() in broker-mk3.lua for the other half.
--
-- OpenComputers Sides Reference Matrix:
--   0 = Bottom / Down (-Y) | 1 = Top / Up (+Y) | 2 = North (-Z)
--   3 = South (+Z)         | 4 = West (-X)     | 5 = East (+X)
-- =============================================================================

local component     = require("component")
local serialization = require("serialization")
local term          = require("term")
local event         = require("event")
local computer      = require("computer")

if not component.isAvailable("modem")   then error("Missing network card.")    end
if not component.isAvailable("gpu")     then error("Requires GPU.")             end

local modem = component.modem
if not modem.isWireless or not modem.isWireless() then
  error("Node requires a T2 Wireless Network Card.")
end

-- Find and connect to ME Controller for direct inventory scanning
local me = nil
for addr, name in component.list("me_controller") do
  me = component.proxy(addr)
  break
end
if not me then error("Missing ME Controller (needed to read network inventory).") end

local gpu      = component.gpu
local nodeName = "MEDINA-HWRelay"


modem.setStrength(400)
-- Only 2025 is opened. modem.open() is what makes a port RECEIVE; broadcasting
-- needs nothing opened, which is why the dust and fluid nodes have always sent
-- on 2026 while opening only their command port.
--
-- This node used to open 2026 as well, labelled "telemetry: this node ->
-- broker" -- which is the misconception. The effect was that every DUST_UPDATE,
-- HW_UPDATE and FLUID_UPDATE broadcast in the fleet was queued as an event
-- here, woke the loop out of event.pull, and was thrown away on the port check
-- below. That is the irregular-cadence problem described in the header note:
-- the traffic waking this loop was traffic it had asked for by mistake.
--
-- Nothing is sent TO this node on 2026, so nothing is lost. If that ever
-- changes, open it deliberately and add a payloadType guard with it.
modem.open(2025)  -- commands from the broker aimed at this node (DRILL_PAR)
gpu.setResolution(80, 25)

-- Build exact-match lookup tables for drill names (item label → drill key).
-- Avoids substring matching that would catch non-consumable items like "Gold Rod".
local drillLookup = {
  ["Steel Drill Tip"]              = "steel",
  ["Steel Rod"]                    = "steel",
  ["Titanium Drill Tip"]           = "titanium",
  ["Titanium Rod"]                 = "titanium",
  ["Tungstensteel Drill Tip"]      = "tungstensteel",
  ["Tungstensteel Rod"]            = "tungstensteel",
  ["Naquadah Drill Tip"]           = "naquadah",
  ["Naquadah Rod"]                 = "naquadah",
  ["Naquadah Alloy Drill Tip"]     = "naquadahAlloy",
  ["Naquadah Alloy Rod"]           = "naquadahAlloy",
  ["Neutronium Drill Tip"]         = "neutronium",
  ["Neutronium Rod"]               = "neutronium",
  ["Cosmic Neutronium Drill Tip"]  = "cosmicNeutronium",
  ["Cosmic Neutronium Rod"]        = "cosmicNeutronium",
  ["Infinity Drill Tip"]           = "infinity",
  ["Infinity Rod"]                 = "infinity",
  ["Transcendent Metal Drill Tip"] = "transcendentMetal",
  ["Transcendent Metal Rod"]       = "transcendentMetal"
}

-- Display order for drills (lowest → highest tier)
local drillKeyOrder = {
  "steel","titanium","tungstensteel","naquadah",
  "naquadahAlloy","neutronium","cosmicNeutronium","infinity","transcendentMetal"
}

-- Drill display names (key → short name for display)
local drillDisplayNames = {
  steel="Steel", titanium="Titanium", tungstensteel="Tungstensteel",
  naquadah="Naquadah", naquadahAlloy="Naquadah Alloy", neutronium="Neutronium",
  cosmicNeutronium="Cosmic Neutronium", infinity="Infinity", transcendentMetal="Transcendent Metal"
}

-- =============================================================================
-- AUTO-CRAFT / PAR RESTOCK
--
-- The broker publishes par levels as ME labels (DRILL_PAR on 2025). Every scan
-- cycle we diff par against what the network actually holds and, for anything
-- short, ask the ME network to craft the difference.
--
-- Two things make this less trivial than the diff suggests:
--
--  1. An in-flight craft has not landed in the network yet, so the deficit stays
--     positive for as long as it runs. Without the `orders` guard below we would
--     re-issue the same request every cycle and bury the crafting CPUs.
--  2. This loop does not tick on a reliable period. event.pull(10, ...) returns
--     early on any modem traffic on an OPEN port, plus key presses. It used to
--     be far worse: this node also opened 2026, so all three telem nodes'
--     continuous broadcasts woke it. That open was unnecessary -- sending does
--     not require it -- and is gone, leaving only the broker's occasional
--     DRILL_PAR on 2025. Iterations are still not evenly spaced, so every rate
--     limit here remains wall-clock (computer.uptime()), never a loop counter.
-- =============================================================================

-- label -> { min, batch }, as last published by the broker. Empty until it
-- speaks, and an empty table means "order nothing" -- with no broker on the air
-- this node behaves exactly as it did before auto-crafting existed.
--
-- `min` is the floor that triggers a craft; `batch` is how much we then ask for.
-- They are separate on purpose: requesting the shortfall meant a material a
-- little under its floor produced a token request that tied up a crafting CPU
-- for almost nothing.
local par = {}

-- How many crafts we may have in flight at once, published alongside par.
-- AE2 cancels a request outright when no CPU is free, so firing every shortfall
-- at a one-CPU network starts one craft and gets the rest rejected -- which is
-- indistinguishable from a broken pattern unless we simply do not ask.
local slots = 1

-- Is auto-crafting switched on at all? Published with par, because this node
-- cannot read config.lua.
--
-- Defaults TRUE for the absent-value case: an older broker sends no `enabled`
-- field, and reading that as "off" would silently stop restocking for anyone
-- who upgraded this file first. A broker that wants it off says so.
local restockEnabled = true

-- label -> shortfall, for materials below par that are waiting on a free slot.
-- Deliberately not in `orders`: nothing has been requested for these.
local queued = {}

-- label -> { want, state, status, since, baseStock }
--   state     = "crafting" | "nopattern" | "failed"
--   status    = the AE2 craft-status object, only present while "crafting"
--   since     = computer.uptime() when this state was entered
--   baseStock = network count at the moment the request was placed; the
--               reference point the settle gate below compares against
local orders = {}

-- How long a "crafting" order may sit before we assume its status object is
-- dead and allow a re-request. AE2 status objects do not survive every network
-- hiccup, and without this a single lost handle would wedge one material
-- permanently -- exactly the silent stall this feature exists to remove.
--
-- Only applies to a handle that has STOPPED ANSWERING -- see statusAlive. A
-- craft still reporting its state is left alone however long it takes.
local ORDER_TIMEOUT = 600

-- Minimum wall-clock gap before retrying a label that had no pattern or whose
-- request failed. A network with no pattern must not be probed every iteration.
local RETRY_INTERVAL = 60

-- After a craft reports done, wait until a scan actually observes the delivered
-- items before considering that label again.
--
-- Without this we double-order. `assets` is the snapshot taken at the top of the
-- iteration, so when a craft completes mid-cycle the order is retired while the
-- scan still shows the old, pre-delivery count -- and the ordering pass below
-- re-requests a deficit that has in fact just been filled.
--
-- The gate is "stock changed", not "N seconds elapsed", because this loop has no
-- reliable period to time against (see the header note: event.pull returns early
-- on any modem traffic, so cycles are irregular). Waiting on the real signal is
-- both simpler to reason about and correct at any cycle rate.
--
-- The baseline is the stock recorded when the request was PLACED, not when
-- completion was noticed. Those differ, and using the latter breaks partial
-- deliveries: if a craft yields less than asked and we notice completion a cycle
-- late, the count has already moved, and a "did it move since completion?" test
-- would sit and wait for a second delivery that is never coming.
--
-- SETTLE_MAX is only a backstop, for the case where a craft reports done but the
-- count never moves -- someone pulled the output, or the status lied. Without it
-- that label would never be ordered again.
local SETTLE_MAX = 120

-- label -> { stock = count when the order was placed, expires = uptime }
local settle = {}

-- Ask a craft-status object a yes/no question without letting a dead handle
-- take down the telemetry loop. Returns false if the call is unavailable or
-- throws, which is the safe answer for all three callers below: "not finished".
--
-- Called with `status` as an argument so this works whether the object wants
-- self (userdata with a metatable) or not (a plain table of closures, which is
-- what OC hands back today, and which simply ignores the extra argument).
local function statusSays(status, method)
  if type(status) ~= "table" and type(status) ~= "userdata" then return false end
  local ok, res = pcall(function() return status[method] and status[method](status) end)
  return ok and res == true
end

-- Does this handle still answer at all?
--
-- statusSays cannot tell "the craft says it is not done" from "the handle is
-- dead and threw" -- both come back false. The timeout below needs exactly that
-- difference. A craft that is merely TAKING a long time must not be retired,
-- because retiring it re-orders on top of a craft that is still running, and a
-- large batch of drill tips can easily outlast a ten minute timeout.
--
-- That duplicate used to be invisible: with every CPU busy AE2 rejected the
-- second request and it showed as one red line. Free up a CPU and the duplicate
-- is accepted instead, and the same batch gets crafted twice.
local function statusAlive(status)
  if type(status) ~= "table" and type(status) ~= "userdata" then return false end
  return (pcall(function() return status.isDone and status.isDone(status) end))
end

-- Derive the label list from drillLookup rather than hardcoding a third copy of
-- these names (config.drills is the second). drillLookup already enumerates
-- every tip and rod label; we only need it in a stable order.
local drillLabels = {}   -- every tip/rod label the broker could name
for label in pairs(drillLookup) do drillLabels[#drillLabels + 1] = label end
table.sort(drillLabels)  -- deterministic display order

-- How many of `label` does the network hold right now, per this cycle's scan?
local function stockOf(assets, label)
  local key = drillLookup[label]
  if not key then return nil end
  if string.find(label, "Drill Tip", 1, true) then
    return assets.drillTips[key] or 0
  end
  return assets.drillRods[key] or 0
end

-- Not every ME controller build exposes the crafting API (verify_items.lua
-- guards the same call for the same reason). Check once at startup rather than
-- discovering it via a pcall failure on every label, every cycle.
local canCraft = (me.getCraftables ~= nil)

-- Pick the craftable that actually IS `label` out of what getCraftables handed
-- back, rather than trusting the first entry.
--
-- The filter is a hint, not a guarantee: with a Pattern Repeater joining another
-- network's patterns to this one, an unhonoured filter returns every craftable
-- in both networks -- and craftables[1] is then some unrelated item that we
-- would happily order thousands of. Matching on the stack's own label costs one
-- pass over a list we already have.
local function pickCraftable(craftables, label)
  for i = 1, #craftables do
    local c = craftables[i]
    local ok, stack = pcall(function() return c.getItemStack and c.getItemStack() end)
    if ok and type(stack) == "table" and stack.label == label then return c end
  end
  -- No entry exposed a label to check against. A single result came back from a
  -- query for this label and there is nothing to confuse it with, so use it;
  -- anything ambiguous is treated as "no pattern" instead of guessed at.
  if #craftables == 1 then return craftables[1] end
  return nil
end

-- Place one crafting request. Returns the new order state.
local function requestCraft(label, amount)
  if not canCraft then
    return { state = "failed", want = amount, since = computer.uptime() }
  end
  local ok, craftables = pcall(me.getCraftables, { label = label })
  if not ok or type(craftables) ~= "table" or #craftables == 0 then
    -- No pattern in this network. Not an error we can fix from here -- it is
    -- surfaced on both dashboards so someone adds the pattern.
    return { state = "nopattern", want = amount, since = computer.uptime() }
  end

  local craftable = pickCraftable(craftables, label)
  craftables = nil
  if not craftable then
    return { state = "nopattern", want = amount, since = computer.uptime() }
  end

  local okReq, status = pcall(function() return craftable.request(amount) end)
  if not okReq or not status then
    return { state = "failed", want = amount, since = computer.uptime() }
  end
  -- AE2 can reject immediately (no CPU free, missing ingredients). That reads
  -- as an already-failed status rather than a thrown error.
  if statusSays(status, "isCanceled") or statusSays(status, "isFailed") then
    return { state = "failed", want = amount, since = computer.uptime() }
  end

  return { state = "crafting", want = amount, status = status, since = computer.uptime() }
end

-- Place an order and stamp it with the stock we saw at that instant, so the
-- settle gate has a fixed reference point to compare later scans against.
local function placeOrder(label, have, amount)
  local o = requestCraft(label, amount)
  o.baseStock = have
  return o
end

-- One pass: retire finished orders, then order anything still below par.
--
-- RETIRING HAPPENS WHETHER OR NOT AUTO-CRAFTING IS ON. Switching it off must not
-- strand the crafts already in flight: AE2 will still deliver them, and an order
-- nobody ever retires would sit on both dashboards reading "crafting" forever.
-- So the first half always runs and the array drains honestly; only the second
-- half -- deciding to ask for more -- is gated.
local function stepOrders(assets)
  local now = computer.uptime()

  -- Retire first, so a craft that just landed frees its label for a re-order in
  -- this same pass instead of waiting a full cycle.
  for label, o in pairs(orders) do
    if o.state == "crafting" then
      if statusSays(o.status, "isDone") then
        orders[label] = nil
        settle[label] = { stock = o.baseStock, expires = now + SETTLE_MAX }
      elseif statusSays(o.status, "isCanceled") or statusSays(o.status, "isFailed") then
        -- Nothing was delivered, so no settle window: re-order immediately if
        -- the deficit is still real.
        orders[label] = nil
      elseif (now - o.since) > ORDER_TIMEOUT and not statusAlive(o.status) then
        -- Presumed-dead handle, which is the case the timeout was written for:
        -- AE2 status objects do not survive every network hiccup, and without
        -- this one lost handle would wedge a material permanently.
        --
        -- The aliveness check is what keeps it from ALSO retiring healthy but
        -- slow crafts. Time alone was never evidence a craft had died.
        orders[label] = nil
      end
    elseif (now - o.since) > RETRY_INTERVAL then
      -- "nopattern"/"failed" are advisory, not sticky. Clearing them here lets
      -- the ordering pass below re-evaluate, which is how adding a pattern in
      -- game resolves the warning without restarting this node.
      orders[label] = nil
    end
  end

  if not restockEnabled then
    -- Nothing new is ordered, and nothing is reported as waiting to be: the
    -- queue is a statement about work we intend to do.
    queued = {}
    return
  end

  -- Collect every shortfall first, then spend the available slots on the worst
  -- ones. Deciding in label order would let an alphabetically early material
  -- monopolise the only CPU while something nearly empty waits.
  local short = {}
  for _, label in ipairs(drillLabels) do
    local have = stockOf(assets, label)

    local s = settle[label]
    if s and (have ~= s.stock or now > s.expires) then
      settle[label] = nil
      s = nil
    end

    local target = par[label]
    local floor  = target and target.min or 0
    if target and floor > 0 and not orders[label] and not s and have and have < floor then
      short[#short + 1] = {
        label = label,
        have  = have,
        -- A whole batch, not the shortfall. Overshooting the floor is the
        -- intended trade -- see the config.drillPar comment.
        need  = target.batch or floor,
        ratio = have / floor,
      }
    end
  end

  -- Emptiest first; label as a tie-break so the order is stable frame to frame.
  table.sort(short, function(a, b)
    if a.ratio ~= b.ratio then return a.ratio < b.ratio end
    return a.label < b.label
  end)

  local inFlight = 0
  for _, o in pairs(orders) do
    if o.state == "crafting" then inFlight = inFlight + 1 end
  end

  queued = {}
  for _, item in ipairs(short) do
    if inFlight < slots then
      local o = placeOrder(item.label, item.have, item.need)
      orders[item.label] = o
      -- Only a live craft consumes a slot. A nopattern/failed result did not
      -- occupy a CPU, so it must not block the next material from trying.
      if o.state == "crafting" then inFlight = inFlight + 1 end
    else
      queued[item.label] = item.need
    end
  end
end

local function drawStaticFrame()
  term.clear()
  gpu.setForeground(0x00FF00)
  print("================================================================================")
  print(" MEDINA RELAY NETWORK  |  NODE: " .. nodeName)
  print("================================================================================")
  gpu.setForeground(0xFFFFFF)
  term.setCursor(2, 5)  io.write("DRILL KIT AVAILABILITY")
  term.setCursor(40, 5) io.write("RESTOCK (auto-craft to par)")
  term.setCursor(2, 6)  io.write(string.rep("-", 76))

  gpu.setForeground(0x555555)
  term.setCursor(2, 22) io.write(string.rep("=", 76))
  term.setCursor(2, 23) io.write("  Wireless Signal Range: " .. tostring(modem.getStrength()) .. " blocks")
  term.setCursor(2, 24) io.write("  Network Port: 2026")
end

-- OpenComputers' sandbox does not hand the Lua `collectgarbage` global to the
-- script -- the host decides when to collect -- so calling it directly kills
-- the node with "attempt to call a nil value". Bind it where it exists and
-- no-op where it does not: every call below is a hint that now is a good
-- moment, never something the logic depends on.
local gc = type(collectgarbage) == "function" and collectgarbage or function() end

-- =============================================================================
-- NETWORK SCAN
--
-- Two ways to read the network, and the reason to prefer one is not the one
-- this section used to give.
--
-- me.getItemsInNetwork() with no filter materialises EVERY stack in the network
-- as its own Lua table, in one allocation. That was fine on a standalone
-- staging network, but a Pattern Repeater grafts another network's contents
-- onto this one and the list grows with it -- tens of thousands of entries,
-- each a table of label/name/damage/size/nbt. When this machine's heap was a
-- couple of hundred kilobytes the list no longer fit, and the node died with
-- "not enough memory" before it could read a single count.
--
-- Asking for the 32 labels one at a time fixed that, because a filtered query
-- hands back a handful of entries instead of the whole network. What it did NOT
-- fix -- and what this section left a reader to assume -- is the cost to the
-- server. A spark profile of the live world settles it. OC composes the call as
--
--   allItems.map(convert).filter(predicate)
--
-- so every stack in the network is converted into a Lua table, localised
-- display name and all, BEFORE the label filter is consulted; and .toArray
-- traverses that view twice. A filtered query costs the server exactly what an
-- unfiltered one costs. The filter only shrinks what crosses into Lua.
--
-- Thirty-two of them is thirty-two whole-network conversions to learn
-- thirty-two numbers. The profile put that at 61.2 seconds of a nineteen-minute
-- capture -- 13% of everything the server did, all of it this node. Each call
-- is synchronized, so it occupies one server tick: thirty-two back to back is a
-- burst of heavy ticks every cycle, which is what MSPT was seen oscillating
-- against. The dust node, one query against a small subnet, cost 0.14s over the
-- same capture.
--
-- Knowing that, the obvious move is one full pass per cycle instead of
-- thirty-two filtered ones. That was tried on this machine, with its RAM
-- upgraded, and it does not work: the first pass came back nil ("returned
-- nothing") and a later one took the node out with "not enough memory". The
-- merged network is simply larger than this heap can hold in one list, which is
-- the same wall that produced the per-label design in the first place.
--
-- The important part of that failure is that it is NOT recoverable in code. A
-- Lua out-of-memory here does not reliably surface as an error you can pcall
-- and retry differently -- it can stop the machine outright. So the full pass
-- cannot be attempted speculatively and demoted on failure: by the time you
-- learn it does not fit, the node is gone. Nor can a free-memory check predict
-- it; there was headroom by that measure immediately before the pass that died.
--
-- So the full pass is off the table, and what replaces it is asking FEWER
-- TIMES rather than asking differently. Two changes do that.
--
-- The first is that drones left this file entirely. They are a durable asset --
-- you own them, they move between the network and a bus, nothing consumes them
-- -- so the broker holds the count as a declared setting and keeps its own
-- ledger. Fourteen of the thirty-two labels were drones, and measuring a number
-- somebody already knows is the cheapest kind of work to delete.
--
-- The second is grouping the eighteen that are left.
--
-- An OC filter matches any field of a stack, not just `label` -- including
-- `name`, the internal item id. The eighteen tip and rod labels do not have
-- eighteen ids: measured on this network with hw_scan_probe.lua, they sit on
-- two, and querying by id returns every stack sharing it --
--
--   gregtech:gt.metaitem.01   9 of our labels, 1391 entries come back
--   gregtech:gt.metaitem.02   8 of our labels,  307 entries come back
--
-- -- against 5873 entries for the whole network. So two queries do the work of
-- eighteen, at a fraction of the memory the full pass needed, and since cost
-- tracks the NUMBER of calls that is the entire saving.
--
-- The ids are learned rather than written down. Nothing in this fleet records
-- them, a pack update could move them, and the answer is already sitting in the
-- result of a per-label query. So the first scan after boot is the old
-- per-label pass, every label's id is read off its own result, and every scan
-- after that is grouped. A label the network does not currently hold has no id
-- to learn, so it stays per-label until it appears -- which costs one query and
-- fixes itself.
--
-- A group is only worth having while this machine can afford it. The id is
-- shared with every other item of its type, so on another network
-- gt.metaitem.01 could be most of the ME system, and this node's whole problem
-- is memory.
--
-- What "afford" means is measured, not counted. The first version of this
-- judged a group by how many entries it returned, against a fixed ceiling --
-- which is a proxy for memory and a poor one, because entry size depends on the
-- stacks and the ceiling has no idea how much RAM is fitted. It dropped a group
-- that fit comfortably. So each group now records what it actually COST, taken
-- while the list is still held, and is used again only while there is
-- GROUP_HEADROOM times that much free. The entry ceiling stays as a backstop
-- for something pathological, set high enough not to be the thing deciding.
--
-- And dropping a group is no longer permanent. It used to be, on the reasoning
-- that a network only grows -- but the heap does not: fit another stick of RAM
-- and the group that was unaffordable this morning is affordable now. A dropped
-- group is retried after GROUP_RETRY_AFTER seconds, and only when there is
-- room for what it cost last time, so the node heals itself instead of sitting
-- on the expensive path until somebody notices and restarts it.
--
-- Two further things that were costing us for nothing:
--
--   1. The queries are spaced across the interval rather than fired back to
--      back. With two of them this matters far less than it did with
--      thirty-two, but it costs nothing and it still holds when a group is
--      abandoned and the count goes back up.
--   2. The scan is gated on the wall clock (see the main loop), so an early
--      wake no longer buys a whole extra scan. That one was worth more than it
--      looks: the loop wakes on any traffic, and every wake used to rescan.
--
-- Where that leaves us: thirty-two whole-network conversions every ten seconds
-- have become two. The one lever left is the size of the network behind the
-- handle -- the dust node runs the identical query against a small subnet and
-- cost 0.14s across the same capture that caught this node at 61.16s -- and it
-- is not available here. This node has to be able to REQUEST crafts from the
-- main network, so it needs to see all of it; a filtered view would buy cheap
-- scans and lose the auto-crafting that is half of what this node is for.
-- =============================================================================

-- Every label worth asking about, and where its count belongs in `assets`.
-- Built from drillLookup so there is still exactly one list of names.
--
-- Static now that drones are gone. It used to be rebuilt whenever the broker
-- told us which drone spelling this pack uses; nothing here depends on a pack
-- version any more, because a drill tip has been called a drill tip throughout.
local scanTargets  = {}
local targetByLabel = {}
for _, label in ipairs(drillLabels) do
  local bucket = string.find(label, "Drill Tip", 1, true) and "drillTips" or "drillRods"
  local t = { label = label, bucket = bucket, key = drillLookup[label] }
  scanTargets[#scanTargets + 1] = t
  targetByLabel[label] = t
end

-- Seconds between scans. Was a bare literal in the event.pull at the bottom of
-- this file, which left the one cadence here with nothing naming it.
local SCAN_INTERVAL = 10

-- More entries than any single label could plausibly occupy. A filtered query
-- that comes back bigger than this was not filtered at all.
local FILTER_SANE_MAX = 64

-- Backstop only. A group returning more entries than this is treated as
-- pathological -- effectively the full pass wearing a filter -- regardless of
-- what it cost. The measured group here was 1391 entries; this is deliberately
-- far above that, because the memory test below is what should be deciding and
-- a count that fits the heap is not a problem however large it looks.
local GROUP_MAX_ENTRIES = 5000

-- How much free heap a group needs, as a multiple of what it cost last time, to
-- be used again. 1.5 means "what it cost, plus half again to grow into".
--
-- Not 2. Two sounds safer and is not: a group costing 900k on a heap with 1759k
-- free fails a 2x test by forty kilobytes and gets dropped, which is a tenfold
-- increase in server cost to avoid a risk that was not there. The thing being
-- guarded against is the result no longer FITTING, and fitting needs one times
-- the cost, not two -- the half is the margin for the network growing between
-- one ten-second scan and the next.
local GROUP_HEADROOM = 1.5

-- Seconds before a dropped group is tried again. Cheap: one query per group per
-- five minutes, and it is what lets a RAM upgrade take effect without a restart.
local GROUP_RETRY_AFTER = 300

-- Total network count for one exact label, or nil if the query failed.
-- Returns the network total, and the internal item id the label turned out to
-- live on. That second value is what makes the grouped queries below possible:
-- it cannot be hardcoded (nothing in this fleet records it, and a pack update
-- could move it) so it is read off the answer to a question we were asking
-- anyway.
local function countLabel(label)
  local ok, items = pcall(me.getItemsInNetwork, { label = label })
  if not ok or type(items) ~= "table" then return nil end
  local total, name = 0, nil
  for i = 1, #items do
    local it = items[i]
    -- Re-check the label rather than trusting the filter. It is compared field
    -- by field on the Java side and a loose or ignored match would otherwise
    -- fold unrelated items into this count; an exact test costs one comparison.
    if type(it) == "table" and it.label == label then
      total = total + (it.size or 0)
      name  = name or it.name
    end
  end
  return total, name
end

-- Is the filter actually honoured here? Decided once, at startup, because the
-- answer decides which path is safe and the unsafe one can kill the node -- so
-- it has to be known before the first scan, not discovered by surviving one.
--
-- If it is not honoured, a filtered call returns the whole network anyway, and
-- 32 of those a cycle would be far worse than the single full pass they were
-- meant to replace. So probe once and take the full pass in that case.
--
-- The probe costs one whole-network conversion at boot. That is a real cost and
-- it buys the one fact this file cannot work without.
local useFilter = false
do
  local ok, items = pcall(me.getItemsInNetwork, { label = drillLabels[1] })
  useFilter = ok and type(items) == "table" and #items <= FILTER_SANE_MAX
  items = nil
  gc()
end

-- Why the counts look the way they do, for the status line. A failed query and
-- an empty network are indistinguishable on the board otherwise. `mode` is also
-- the only place the expensive path is visible from outside this node.
local scanState = { ok = true, mode = useFilter and "filtered" or "full", err = nil }

local function newAssets()
  return { drillTips = {}, drillRods = {} }
end

-- One small query per target, spaced out. Returns nil if any of them failed: a
-- partial scan reads as "the network is empty", and ordering against that would
-- fire a craft for every material at once.
--
-- The spacing is the point of this function's shape. Each query costs the server
-- a whole-network conversion whether it is filtered or not, so firing them back
-- to back puts that many consecutive ticks over budget. Spacing them changes
-- nothing about the total -- this is still the expensive path -- but it lands
-- the cost as isolated ticks, which is what a tick-rate readout reacts to.
--
-- Computed per scan, not once at load: rebuildDroneLabels() replaces
-- scanTargets whenever the broker sends a different drone marker.
--
-- NOT os.sleep(). OpenOS implements that as event.pull with the result thrown
-- away, so sleeping through most of every cycle would make this node deaf to
-- the broker -- a DRILL_PAR or HW_QUERY arriving mid-scan would simply vanish.
-- Pull instead, and hand anything that turns up to the main loop to answer once
-- the scan is done.
local deferredEvent = nil

-- What we have learned about where our labels live.
--   labelName : label -> internal id
--   groupIds  : the ids we know about, in discovery order
--   groupBad  : ids abandoned for being too large to be worth a grouped query
local labelName  = {}
local groupIds   = {}
local groupBad   = {}
local groupCost  = {}   -- id -> bytes the last result cost
local groupRetry = {}   -- id -> uptime after which to reconsider it

local function learnName(label, id)
  if not id or labelName[label] then return end
  labelName[label] = id
  for _, known in ipairs(groupIds) do
    if known == id then return end
  end
  groupIds[#groupIds + 1] = id
end

-- Every tracked label sharing one internal id, in a single query. Returns a
-- label -> count table, or nil if the query failed or the group turned out to
-- be too big to keep using.
-- Stop using a group, but leave the door open: record what it cost and when to
-- reconsider, so a heap that grows later can take it back.
local function dropGroup(id, cost)
  groupBad[id]   = true
  groupCost[id]  = cost or groupCost[id]
  groupRetry[id] = computer.uptime() + GROUP_RETRY_AFTER
end

local function countGroup(id)
  gc()
  local freeBefore = computer.freeMemory()

  local ok, items = pcall(me.getItemsInNetwork, { name = id })
  if not ok or type(items) ~= "table" then return nil end

  -- What the result actually cost, taken while the list is still held. This is
  -- the number the group is judged on; an entry count cannot stand in for it,
  -- because entry size depends on the stacks and the heap size is not a
  -- constant of this file.
  local n    = #items
  local cost = freeBefore - computer.freeMemory()
  if cost < 0 then cost = 0 end

  if n > GROUP_MAX_ENTRIES then
    items = nil
    gc()
    dropGroup(id, cost)
    return nil
  end

  local counts = {}
  for i = 1, n do
    local it = items[i]
    -- Only our labels. The id is shared with everything of its type, so the
    -- result is mostly things we do not track, and the label test is what
    -- separates them -- the same reason countLabel re-checks its own filter.
    if type(it) == "table" and it.label and targetByLabel[it.label] then
      counts[it.label] = (counts[it.label] or 0) + (it.size or 0)
    end
  end

  items = nil
  gc()
  groupCost[id] = cost

  -- Affordable while there is room to do it again with margin. Measured against
  -- the heap we have, not against a fraction someone guessed at.
  if computer.freeMemory() < cost * GROUP_HEADROOM then
    dropGroup(id, cost)
  end
  return counts
end

local function scanFiltered()
  local assets = newAssets()

  -- Plan the cycle first, so the pacing below knows how many calls it is
  -- spreading. One call per usable group, plus one for every label that cannot
  -- be placed in a group yet -- which on the first scan after boot is all of
  -- them, and is how the ids get learned in the first place.
  local groupCalls, labelCalls = {}, {}
  for _, id in ipairs(groupIds) do
    if groupBad[id]
       and computer.uptime() >= (groupRetry[id] or 0)
       and computer.freeMemory() > (groupCost[id] or 0) * GROUP_HEADROOM then
      -- Conditions have changed since it was dropped -- more RAM fitted, or
      -- whatever else was holding the heap has gone. Take it back; if it is
      -- still too expensive, countGroup drops it again and sets a new retry.
      groupBad[id] = nil
    end
    if not groupBad[id] then groupCalls[#groupCalls + 1] = id end
  end
  for _, t in ipairs(scanTargets) do
    local id = labelName[t.label]
    if not id or groupBad[id] then labelCalls[#labelCalls + 1] = t end
  end

  local calls = #groupCalls + #labelCalls
  -- Floor of one tick: a synchronized call cannot go faster than that anyway.
  local spacing = math.max(0.05, (SCAN_INTERVAL * 0.6) / math.max(1, calls))
  local made = 0
  local function pace()
    made = made + 1
    if made > 1 then
      local ev = { event.pull(spacing) }
      if ev[1] and not deferredEvent then deferredEvent = ev end
    end
  end

  for _, id in ipairs(groupCalls) do
    pace()
    local counts = countGroup(id)
    if not counts then
      -- Either the query failed or the group was just abandoned. Both end the
      -- cycle rather than returning what we have: the labels behind this id
      -- would read as zero stock, and ordering against that fires a craft for
      -- every material at once. An abandoned group is picked up label by label
      -- on the next scan.
      scanState = { ok = false, mode = "grouped",
                    err = groupBad[id] and ("group too large: " .. id)
                                        or ("group query failed: " .. id) }
      return nil
    end
    for label, n in pairs(counts) do
      local t = targetByLabel[label]
      if t and n > 0 then assets[t.bucket][t.key] = (assets[t.bucket][t.key] or 0) + n end
    end
  end

  for _, t in ipairs(labelCalls) do
    pace()
    local n, id = countLabel(t.label)
    if not n then
      scanState = { ok = false, mode = "per-label", err = "query failed: " .. t.label }
      return nil
    end
    learnName(t.label, id)
    if n > 0 then assets[t.bucket][t.key] = (assets[t.bucket][t.key] or 0) + n end
  end

  scanState = { ok = true, err = nil,
                mode = string.format("%dq", calls) }
  return assets
end

-- Fallback for a device that ignores the filter: the original whole-network
-- pass, which is what runs out of memory on a repeated network. Collect first
-- so the previous cycle's garbage is not still holding the heap when the list
-- lands, and treat the failure as a failed scan instead of letting it kill the
-- node -- a dashboard reporting "SCAN FAILED" is far more use than a dead one.
local function scanFull()
  gc()
  local assets = newAssets()

  -- `why` is the third value on purpose: a nil return is not a throw, so the
  -- reason arrives alongside the nil rather than in pcall's error slot. This
  -- used to be dropped, and "returned nothing" on the status line was the whole
  -- of what a failure told you. dust_telem.lua has read the third value since
  -- it was written.
  local success, itemList, why = pcall(me.getItemsInNetwork)
  if not success or not itemList then
    scanState = { ok = false, mode = "full",
                  err = success and ("returned nil: " .. (why or "no reason given"))
                                 or tostring(itemList) }
    return nil
  end

  for _, item in ipairs(itemList) do
    if item.label and drillLookup[item.label] then
      local key = drillLookup[item.label]
      if string.find(item.label, "Drill Tip", 1, true) then
        assets.drillTips[key] = (assets.drillTips[key] or 0) + item.size
      elseif string.find(item.label, "Rod", 1, true) then
        assets.drillRods[key] = (assets.drillRods[key] or 0) + item.size
      end
    end
  end

  -- Drop the list before anything else allocates against it.
  itemList = nil
  gc()
  scanState = { ok = true, mode = "full", err = nil }
  return assets
end

-- Reads items directly from ME network via controller.
-- nil means "this cycle's numbers are not trustworthy" -- the caller keeps the
-- previous snapshot rather than acting on a blank one.
local function scanAssets()
  if useFilter then return scanFiltered() end
  return scanFull()
end

local function updateDashboard(assets)
  -- Drill column, now on the LEFT (rows 7-15). It used to sit at x=40 because
  -- the drone list owned the left half; with drones gone this is the only stock
  -- this node measures, so it takes the main column and the restock queue gets
  -- the whole of the right.
  --
  -- The old "[ NO FLEET -- MASKED ]" state went with it. It hid kit counts when
  -- the network held no drones, on the reasoning that kits are useless without
  -- something to put them in -- but this node no longer knows whether a fleet
  -- exists, the broker does, and hiding a measurement because of a fact we can
  -- no longer see would be guessing.
  for i, key in ipairs(drillKeyOrder) do
    local tips = assets.drillTips[key] or 0
    local rods = assets.drillRods[key] or 0
    local kits = math.min(tips, rods)
    local displayName = drillDisplayNames[key]
    local row = 6 + i
    term.setCursor(2, row)
    gpu.fill(2, row, 36, 1, " ")
    gpu.setForeground(kits > 0 and 0xFF00FF or 0x555555)
    -- Display kits with individual tip and rod counts
    io.write(string.format("  %-15s: %d (%d|%d)", displayName, kits, tips, rods))
  end

  -- Restock queue: right column (x=40, width 38), rows 17-21.
  --
  -- Right half only (x=40+). The drill loop above clears x=2..37 on rows 7-15
  -- every repaint, so a full-width block here would be partly erased.
  local QX, QW = 40, 38

  -- Failures first: they are the entries a human has to act on, so if there are
  -- more orders than rows, the benign "crafting" lines are the ones to lose.
  -- state -> sort rank and colour. Failures first (a human has to act on them),
  -- then live crafts, then things merely waiting on a slot. If there are more
  -- entries than rows, the ones that get cut are the ones nobody needs to see.
  local RANK  = { nopattern = 0, failed = 0, crafting = 1, queued = 2 }
  local COLOR = { nopattern = 0xFF4444, failed = 0xFF4444,
                  crafting  = 0xFFAA00, queued = 0x555555 }

  local view = {}
  for _, label in ipairs(drillLabels) do
    local o = orders[label]
    if o then
      view[#view + 1] = { label = label, state = o.state, want = o.want }
    elseif queued[label] then
      view[#view + 1] = { label = label, state = "queued", want = queued[label] }
    end
  end
  table.sort(view, function(a, b)
    local ra, rb = RANK[a.state] or 3, RANK[b.state] or 3
    if ra ~= rb then return ra < rb end
    return a.label < b.label
  end)
  local pending = view

  -- Rows 7-21 on the right, where it used to be 17-21 under the drill column.
  -- Fifteen rows instead of five, so the "...and N more" line is a good deal
  -- harder to reach.
  local qRow, QLAST = 7, 21
  local WORD = { nopattern = "NO PATTERN", failed = "REJECTED", queued = "queued" }
  for i, e in ipairs(pending) do
    if qRow > QLAST then break end
    gpu.fill(QX, qRow, QW, 1, " ")
    term.setCursor(QX, qRow)
    -- More entries than rows: spend the last line on a count rather than
    -- showing one more and silently hiding the rest.
    if qRow == QLAST and #pending > i then
      gpu.setForeground(0x555555)
      io.write(string.format("  ...and %d more", #pending - i + 1))
    else
      local short = e.label:gsub(" Drill Tip$", " TIP"):gsub(" Rod$", " ROD")
      gpu.setForeground(COLOR[e.state] or 0xFF4444)
      if e.state == "crafting" then
        io.write(string.format("  %-22s x%d", short, e.want or 0))
      elseif e.state == "queued" then
        io.write(string.format("  %-22s queued x%d", short, e.want or 0))
      else
        io.write(string.format("  %-22s %s", short, WORD[e.state] or "FAILED"))
      end
    end
    qRow = qRow + 1
  end

  if #pending == 0 then
    gpu.fill(QX, qRow, QW, 1, " ")
    term.setCursor(QX, qRow)
    gpu.setForeground(0x555555)
    -- Distinguish "at par" from "no par received": a broker that is down or on
    -- a stale config would otherwise look identical to a fully stocked network.
    -- Three states, not two. "Awaiting par" used to cover both a broker that
    -- has never spoken and a broker that deliberately told us to order nothing,
    -- which reads as a fault when it is a choice.
    if not restockEnabled then
      io.write("  Auto-craft off (broker).")
    elseif next(par) then
      io.write("  All at par.")
    else
      io.write("  Awaiting par from broker...")
    end
    qRow = qRow + 1
  end
  for r = qRow, QLAST do gpu.fill(QX, r, QW, 1, " ") end

  -- Scan health, bottom of the LEFT column. The drill list stops at row 15, so
  -- row 21 is clear on the left, and the restock block owns the right half of
  -- it. Free memory is on show because this node's failure
  -- mode is running out of it -- a repeated network can grow the item list
  -- without anything else on screen changing.
  gpu.fill(2, 21, 36, 1, " ")
  term.setCursor(2, 21)
  if scanState.ok then
    gpu.setForeground(0x555555)
    -- Flag dropped groups. The query count alone says something is wrong --
    -- 11q where 3q is normal -- but not what, and this is the only place the
    -- difference between "a label is missing" and "a group stopped fitting" is
    -- visible from outside.
    local dropped = 0
    for _ in pairs(groupBad) do dropped = dropped + 1 end
    if dropped > 0 then
      io.write(string.format("  scan %s -%dgrp  free %dk",
        scanState.mode, dropped, math.floor(computer.freeMemory() / 1024)))
    else
      io.write(string.format("  scan %s  free %dk",
        scanState.mode, math.floor(computer.freeMemory() / 1024)))
    end
  else
    gpu.setForeground(0xFF4444)
    io.write(string.sub("  SCAN FAILED: " .. (scanState.err or "?"), 1, 36))
  end

  gpu.setForeground(0x555555)
  term.setCursor(55, 2)
  io.write("LAST_SYNC: " .. os.date("%X"))
end

drawStaticFrame()

local lastAssets = { drillTips={}, drillRods={} }

-- Helper to build payload from assets
-- EVERY KEY, INCLUDING THE ZEROES.
--
-- These used to be sent only when non-zero, which sounds like a harmless
-- economy and is not: the broker MERGES this table into its own, so a tier that
-- stops being sent keeps its last value forever. The moment the last LuV drone
-- left the network the broker went on believing there were seven, handed the
-- surplus module a job it could never load, and repeated that until it was
-- restarted.
--
-- A zero is a fact about the network and has to travel like one. dust_telem
-- (stocks[name] or 0 over the whole watchlist) and fluid_telem (PLASMA_ORDER
-- seeded to 0) have always sent theirs; this node was the odd one out.
local function buildPayload(assets)
  -- No `drones` key at all. The broker guards on type(data.drones) == "table"
  -- before reading it, so an absent one leaves its declared ledger alone --
  -- which is the point: that ledger is now the source of truth and telemetry
  -- has no business overwriting it. broker-mk3.lua reads brokerState.drones in
  -- exactly one place, to offer a hint when NO drones are declared, and that
  -- hint simply stops appearing.
  local payload = { drills={} }
  for _, key in ipairs(drillKeyOrder) do
    local tips = assets.drillTips[key] or 0
    local rods = assets.drillRods[key] or 0
    payload.drills[key] = { kits = math.min(tips, rods), tips = tips, rods = rods }
  end
  -- Ride the existing HW_UPDATE rather than opening a second channel: the broker
  -- already parses this message, so restock state costs no new listener. Only
  -- outstanding orders are included, so in the steady state (everything at par)
  -- this field is absent and the packet is exactly the size it always was.
  local crafting, any = {}, false
  for label, o in pairs(orders) do
    crafting[label] = { want = o.want, state = o.state }
    any = true
  end
  for label, need in pairs(queued) do
    crafting[label] = { want = need, state = "queued" }
    any = true
  end
  if any then payload.crafting = crafting end
  return payload
end

-- When the last scan STARTED. Seeded so the first pass through the loop scans
-- immediately.
local lastScan = -SCAN_INTERVAL

while true do
  -- Only rescan once the interval has genuinely elapsed.
  --
  -- The header note above is right that this loop wakes irregularly, and right
  -- that closing port 2026 removed most of the traffic that was waking it. What
  -- it did not say is that the scan ran on every one of those wakes -- so a
  -- DRILL_PAR push or a key press did not merely wake the loop, it bought
  -- another whole-network read. The ten seconds was a floor, not a period.
  --
  -- The rest of the body stays where it was and still runs on every wake: the
  -- dashboard should repaint and the message should be answered promptly. Only
  -- the scan and the ordering that depends on it are gated.
  --
  -- Timed from scan START so a slow scan does not add itself to the period.
  if computer.uptime() - lastScan >= SCAN_INTERVAL then
    lastScan = computer.uptime()

    -- Scan the ME network for current inventory. A failed scan keeps the
    -- previous snapshot and skips ordering: a half-read network looks like an
    -- empty one, and ordering against that would fire a craft for every
    -- material at once.
    local assets = scanAssets()
    if assets then
      lastAssets = assets
      -- Order before drawing and before building the payload, so both reflect
      -- this cycle's decisions rather than lagging one iteration behind.
      stepOrders(lastAssets)
    end
  end
  updateDashboard(lastAssets)

  -- Build and broadcast periodic HW_UPDATE
  local payload = buildPayload(lastAssets)
  modem.broadcast(2026, serialization.serialize({
    protocol    = "MEDINA_TELEMETRY",
    sender      = nodeName,
    payloadType = "HW_UPDATE",
    data        = payload
  }))

  -- Hand the cycle's garbage back before parking in event.pull. The scan and
  -- the serialized packet are the two large allocations here, and collecting
  -- them while we are idle anyway keeps the heap floor steady instead of
  -- letting it drift up until an unlucky cycle has nowhere to allocate.
  payload = nil
  gc()

  -- Listen for Ctrl+C or broker commands (10s timeout).
  --
  -- No name filter. event.pull(timeout, name, ...) matches `name` against the
  -- SIGNAL NAME and every argument after it against the signal's PARAMETERS --
  -- it is not an either/or list. The old call here was
  --   event.pull(10, "key_down", "modem_message")
  -- which asks for a key_down whose first parameter is the string
  -- "modem_message", and therefore never matched anything. This node could not
  -- receive a modem message at all, which is why HW_QUERY never worked and why
  -- Ctrl+C did not quit. dust_telem.lua:212 has it right with a single filter.
  --
  -- Pulling everything (like broker-mk3.lua does) keeps both branches working.
  -- Unrelated signals just wake the loop early, which is harmless: the body is
  -- idempotent and every rate limit here is wall-clock, not per-iteration.
  local ev
  if deferredEvent then
    -- Something arrived while a spaced-out fallback scan was running. Answer it
    -- now rather than pulling for a fresh one and leaving it unanswered.
    ev = deferredEvent
    deferredEvent = nil
  else
    -- Wait out what is LEFT of the interval, not a fresh copy of it. On the
    -- fallback path the scan itself blocks for most of a cycle, and a flat
    -- SCAN_INTERVAL here would add itself on top and stretch the period to
    -- nearly twice what it says. The floor keeps this a yield, not a spin.
    local remaining = SCAN_INTERVAL - (computer.uptime() - lastScan)
    if remaining < 0.5 then remaining = 0.5 end
    ev = { event.pull(remaining) }
  end
  if ev[1] == "key_down" and ev[3] == 3 then -- Ctrl+C
    term.clear()
    os.exit()
  elseif ev[1] == "modem_message" then
    -- Query received on port 2025
    local _, _, senderAddr, port, _, rawMsg = table.unpack(ev)
    -- Belt and braces now that 2026 is not opened: nothing else should reach
    -- this node, and the two payload types that do are both wanted, so there is
    -- no string guard here of the kind dust_telem and fluid_telem carry. The
    -- port check already does that job, more cheaply and more exactly.
    if port == 2025 then
      local ok, msg = pcall(serialization.unserialize, rawMsg)
      if ok and msg and msg.protocol == "MEDINA_COMMAND" then
        if msg.payloadType == "HW_QUERY" then
          -- Respond immediately with current inventory. Named apart from the
          -- broadcast `payload` above rather than shadowing it: they are two
          -- different messages and the loop reuses that one across iterations.
          local reply = buildPayload(lastAssets)
          modem.send(senderAddr, 2025, serialization.serialize({
            protocol    = "MEDINA_TELEMETRY",
            sender      = nodeName,
            payloadType = "HW_QUERY_RESPONSE",
            data        = reply
          }))
        elseif msg.payloadType == "DRILL_PAR" and type(msg.data) == "table"
               and type(msg.data.par) == "table" then
          -- data.par is label -> { min, batch }.
          -- Replace, do not merge: the broker sends the complete par table, so
          -- a material it stopped publishing -- because you removed it from
          -- config.drillPar, or because you no longer hold a drone that uses
          -- it -- actually stops being ordered.
          par = msg.data.par
          -- Absent means an older broker, which is the enabled case.
          restockEnabled = msg.data.enabled ~= false
          -- Absent-value fallback, not the shipped default (config sets 2).
          -- A broker that does not tell us the CPU count gets the conservative
          -- answer: too few slots is slow, too many is rejected requests.
          slots = tonumber(msg.data.slots) or 1
          if slots < 1 then slots = 1 end
          -- msg.data.droneMark / droneSuffix are ignored. The broker still
          -- sends them, and they used to pick which spelling of the drone
          -- label to ask the network for. Nothing here asks about drones any
          -- more, so the whole pack-version question stops applying to this
          -- node: a drill tip is called a drill tip on every version.
        end
      end
    end
  end
end
