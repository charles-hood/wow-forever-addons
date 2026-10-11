-- HunterProbe/HunterProbe.lua
-- Measures what the planned hunter addon (dead-zone indicator plus ammo check)
-- needs from this client, and logs it through ForeverProbe so it can be read
-- from disk afterwards.
--
--   /hp range        one-shot range report for the current target
--   /hp range on     sample range checks twice a second and log every change
--   /hp ammo         what is in the ammo slot, quivers, and projectile stacks in bags
--   /hp auras        the player's buffs with per-field secrecy
--   /hp swing on     log PLAYER_SWING and PLAYER_SWING_RANGE_UPDATE

local ADDON, ns = ...
local FP = _G.ForeverProbe
local SRC = "HP"

if not FP then
	print("|cffff5555HunterProbe|r: ForeverProbe is not loaded; nothing to do.")
	return
end

local info = function(...) return FP.info(SRC, ...) end
local debug = function(...) return FP.debug(SRC, ...) end
local warn = function(...) return FP.warn(SRC, ...) end
local str, describe, call = FP.str, FP.describe, FP.call

local function say(msg, ...)
	print("|cff33ff99HunterProbe|r: " .. FP.fmt(msg, ...))
end

-- Vanilla-era hunter spell IDs (rank 1). Auto Shot is the ranged check that
-- matters for the dead zone; Raptor Strike is a 0-0 range melee ability, which
-- the kit says answers "in range" at any distance.
local SPELLS = {
	{ id = 75,   name = "Auto Shot",       note = "ranged 8-35 on Forever" },
	{ id = 3044, name = "Arcane Shot",     note = "ranged" },
	{ id = 1978, name = "Serpent Sting",   note = "ranged" },
	{ id = 1130, name = "Hunter's Mark",   note = "100 yd" },
	{ id = 2973, name = "Raptor Strike",   note = "melee 0-0" },
	{ id = 2974, name = "Wing Clip",       note = "melee 0-0" },
	{ id = 2764, name = "Throw",           note = "thrown 30 yd" },
	{ id = 5019, name = "Shoot",           note = "wand 30 yd" },
}

-- Harm items from LibRangeCheck-3.0 (WeakAuras), one per yard band. The client
-- answers nil for items it will not range-check; the probe records which answer.
local ITEMS = {
	{ yd = 5,  id = 8149,  name = "Voodoo Charm" },
	{ yd = 10, id = 17626, name = "Frostwolf Muzzle" },
	{ yd = 15, id = 4559,  name = "CHU's QUEST ITEM" },
	{ yd = 20, id = 1191,  name = "Bag of Marbles" },
	{ yd = 25, id = 13289, name = "Egan's Blaster" },
	{ yd = 30, id = 835,   name = "Large Rope Net" },
	{ yd = 35, id = 18904, name = "Zorbin's Ultra-Shrinker" },
	{ yd = 40, id = 4945,  name = "Faintly Glowing Skull" },
}

-- CheckInteractDistance indexes: 1 inspect 28 yd, 2 trade 11.11 yd, 3 duel 9.9 yd, 4 follow 28 yd
local INTERACT = { 1, 2, 3, 4 }

local AMMO_SLOT = _G.INVSLOT_AMMO or 0
local PROJECTILE_CLASS = 6      -- Enum.ItemClass.Projectile
local CONTAINER_CLASS = 1       -- Enum.ItemClass.Container (subclass 2 quiver, 3 ammo pouch)

local DEFAULTS = { range = true, swing = true }

local function settings()
	if type(_G.HunterProbeDB) ~= "table" then
		_G.HunterProbeDB = {}
	end
	local d = _G.HunterProbeDB
	for k, v in pairs(DEFAULTS) do
		if d[k] == nil then
			d[k] = v
		end
	end
	return d
end

local function playerBank()
	local e = _G.Enum and _G.Enum.SpellBookSpellBank
	return e and e.Player or 0
end

------------------------------------------------------------------------
-- range
------------------------------------------------------------------------

-- Session 2 (build 70338) showed C_Item.IsItemInRange answering nil for every
-- band until the items had been seen once, then plain true/false. Ask the client
-- to cache them at login and report which are cached.
local function warmItems()
	local cached, requested = {}, {}
	for _, it in ipairs(ITEMS) do
		local okC, isCached = call("C_Item.IsItemDataCachedByID", it.id)
		if okC and isCached == true then
			cached[#cached + 1] = tostring(it.yd)
		else
			call("C_Item.RequestLoadItemDataByID", it.id)
			requested[#requested + 1] = tostring(it.yd)
		end
	end
	info("range items cached: %s | requested: %s", table.concat(cached, " "), table.concat(requested, " "))
end

local function spellKnown(id)
	local ok, known = call("C_SpellBook.IsSpellKnownOrInSpellBook", id, playerBank(), true)
	if ok == nil then
		ok, known = call("C_SpellBook.IsSpellKnown", id, playerBank())
	end
	if ok then
		return describe(known)
	end
	return "ERR " .. str(known)
end

-- Returns a table of named answers and a compact signature string for change detection.
local function sampleRange(unit)
	unit = unit or "target"
	local out, sig = {}, {}
	local okE, exists = call("UnitExists", unit)
	out.exists = okE and describe(exists) or ("ERR " .. str(exists))
	if not (okE and exists == true) then
		return out, "no-target"
	end
	local okA, canAttack = call("UnitCanAttack", "player", unit)
	out.canAttack = okA and describe(canAttack) or ("ERR " .. str(canAttack))
	local okD, dead = call("UnitIsDead", unit)
	out.dead = okD and describe(dead) or ("ERR " .. str(dead))
	local okC, combat = call("InCombatLockdown")
	out.combat = okC and describe(combat) or "?"

	for _, s in ipairs(SPELLS) do
		local ok, r = call("C_Spell.IsSpellInRange", s.id, unit)
		local v
		if ok == nil then
			v = "missing"
		elseif not ok then
			v = "ERR " .. str(r)
		else
			v = describe(r)
		end
		out["spell:" .. s.name] = v
		sig[#sig + 1] = s.id .. "=" .. v
	end
	for _, i in ipairs(INTERACT) do
		local ok, r = call("CheckInteractDistance", unit, i)
		local v = (ok == nil) and "missing" or (ok and describe(r) or ("ERR " .. str(r)))
		out["interact:" .. i] = v
		sig[#sig + 1] = "i" .. i .. "=" .. v
	end
	for _, it in ipairs(ITEMS) do
		local ok, r = call("C_Item.IsItemInRange", it.id, unit)
		local v = (ok == nil) and "missing" or (ok and describe(r) or ("ERR " .. str(r)))
		out["item:" .. it.yd] = v
		sig[#sig + 1] = "y" .. it.yd .. "=" .. v
	end
	-- the kit says this one is closed to addons (nil); record it anyway
	local okS, swing = call("C_SwingTimer.IsTargetWithinSwingRange", 0)
	out.swingRange = (okS == nil) and "missing" or (okS and describe(swing) or ("ERR " .. str(swing)))
	sig[#sig + 1] = "sw=" .. out.swingRange

	-- The classification the hunter addon will make. Session 3 (build 70338) showed
	-- Auto Shot false only inside the dead zone or beyond 35 yards, with a one-sample
	-- band near 10 yards where Auto Shot and interact 3 disagreed. So "within 35 yards"
	-- (Zorbin's Ultra-Shrinker, 18904) is the dead-zone discriminator; interact 3 is
	-- only the fallback while the item is not cached. Wing Clip (5 yd) answers true in
	-- melee and flickers as the mob moves, which is fine for a melee light.
	local auto = out["spell:Auto Shot"]
	local clip = out["spell:Wing Clip"]
	local near = out["interact:3"]
	local within35 = out["item:35"]
	if auto == "true" then
		out.zone = "RANGED"
	elseif auto == "false" and within35 == "true" then
		out.zone = "DEAD ZONE"
	elseif auto == "false" and within35 == "false" then
		out.zone = "OUT OF RANGE"
	elseif auto == "false" and near == "true" then
		out.zone = "DEAD ZONE (i3 fallback)"
	elseif auto == "false" then
		out.zone = "OUT OF RANGE (i3 fallback)"
	else
		out.zone = "UNKNOWN (" .. str(auto) .. ")"
	end
	out.melee = clip
	sig[#sig + 1] = "melee=" .. clip
	sig[#sig + 1] = "zone=" .. out.zone
	return out, table.concat(sig, " ")
end

local function reportRange()
	local out, sig = sampleRange("target")
	say("range report (target exists=%s, canAttack=%s, dead=%s, combat=%s)", out.exists, out.canAttack or "-", out.dead or "-", out.combat or "-")
	if sig == "no-target" then
		info("range: no target")
		return
	end
	for _, s in ipairs(SPELLS) do
		say("  %s (%s): known=%s inRange=%s", s.name, s.note, spellKnown(s.id), out["spell:" .. s.name])
	end
	say("  interact 1..4: %s %s %s %s", out["interact:1"], out["interact:2"], out["interact:3"], out["interact:4"])
	local parts = {}
	for _, it in ipairs(ITEMS) do
		parts[#parts + 1] = it.yd .. "yd=" .. out["item:" .. it.yd]
	end
	say("  items: %s", table.concat(parts, " "))
	say("  swing range: %s  =>  %s", out.swingRange, out.zone)
	info("range report: %s", sig)
	local d = settings()
	d.lastRange = { at = GetServerTime(), sig = sig, zone = out.zone }
end

local rangeTicker
local lastSig
local sampleCount = 0

local function rangeTick()
	local okE, exists = call("UnitExists", "target")
	if not (okE and exists == true) then
		if lastSig ~= "no-target" then
			debug("range: target lost after %s samples", sampleCount)
			lastSig = "no-target"
		end
		return
	end
	local okA, canAttack = call("UnitCanAttack", "player", "target")
	local okD, dead = call("UnitIsDead", "target")
	if not (okA and canAttack == true) or (okD and dead == true) then
		if lastSig ~= "not-hostile" then
			debug("range: target is not a live hostile, sampling paused")
			lastSig = "not-hostile"
		end
		return
	end
	sampleCount = sampleCount + 1
	local out, sig = sampleRange("target")
	if sig ~= lastSig then
		info("range change #%s: zone=%s auto=%s i3=%s | %s", sampleCount, out.zone, out["spell:Auto Shot"], out["interact:3"], sig)
		lastSig = sig
	end
end

local function setRangeSampling(on)
	settings().range = on
	if on then
		if rangeTicker then
			return
		end
		local ok, t = call("C_Timer.NewTicker", 0.5, rangeTick)
		if ok and t then
			rangeTicker = t
			info("range sampling on (every 0.5 s, logging changes only)")
		else
			warn("C_Timer.NewTicker unavailable: %s", str(t))
		end
	else
		if rangeTicker then
			pcall(function() rangeTicker:Cancel() end)
			rangeTicker = nil
		end
		info("range sampling off after %s samples", sampleCount)
	end
end

------------------------------------------------------------------------
-- ammo
------------------------------------------------------------------------

local function itemClass(itemID)
	local ok, _, itemType, itemSubType, equipLoc, _, classID, subclassID = call("C_Item.GetItemInfoInstant", itemID)
	if not ok then
		return nil
	end
	return classID, subclassID, str(itemType), str(itemSubType), str(equipLoc)
end

local function reportAmmo()
	local d = settings()
	local a = { at = GetServerTime() }
	local okI, id = call("GetInventoryItemID", "player", AMMO_SLOT)
	local okC, count = call("GetInventoryItemCount", "player", AMMO_SLOT)
	local okL, link = call("GetInventoryItemLink", "player", AMMO_SLOT)
	a.slot = AMMO_SLOT
	a.id = okI and describe(id) or ("ERR " .. str(id))
	a.count = okC and describe(count) or ("ERR " .. str(count))
	a.link = okL and str(link) or ("ERR " .. str(link))
	say("ammo slot %s: id=%s count=%s link=%s", AMMO_SLOT, a.id, a.count, a.link)
	if okI and type(id) == "number" then
		local classID, subclassID, itemType, itemSubType = itemClass(id)
		a.class = str(classID) .. "/" .. str(subclassID) .. " " .. str(itemType) .. "/" .. str(itemSubType)
		say("  class %s (projectile class is %s)", a.class, PROJECTILE_CLASS)
	end

	-- any other equipped slot holding a projectile or a quiver, in case slot 0 is not it
	local found = {}
	for slot = 0, 19 do
		local ok, sid = call("GetInventoryItemID", "player", slot)
		if ok and type(sid) == "number" then
			local classID, subclassID = itemClass(sid)
			if classID == PROJECTILE_CLASS or (classID == CONTAINER_CLASS and (subclassID == 2 or subclassID == 3)) then
				found[#found + 1] = ("slot %s item %s class %s/%s"):format(slot, sid, str(classID), str(subclassID))
			end
		end
	end
	a.equipped = found
	say("  equipped projectile/quiver items: %s", #found > 0 and table.concat(found, "; ") or "none")

	-- bags: projectile stacks and quiver bags
	local numBags = _G.NUM_BAG_SLOTS or 4
	local stacks, total, quivers = {}, 0, {}
	for bag = 0, numBags do
		local okN, slots = call("C_Container.GetContainerNumSlots", bag)
		if okN and type(slots) == "number" and slots > 0 then
			if bag > 0 then
				local okInv, invSlot = call("C_Container.ContainerIDToInventoryID", bag)
				if okInv and type(invSlot) == "number" then
					local okB, bagItem = call("GetInventoryItemID", "player", invSlot)
					if okB and type(bagItem) == "number" then
						local classID, subclassID = itemClass(bagItem)
						if classID == CONTAINER_CLASS and (subclassID == 2 or subclassID == 3) then
							quivers[#quivers + 1] = ("bag %s item %s subclass %s (%s slots)"):format(bag, bagItem, str(subclassID), slots)
						end
					end
				end
			end
			for slot = 1, slots do
				local okS, cinfo = call("C_Container.GetContainerItemInfo", bag, slot)
				if okS and type(cinfo) == "table" then
					local okR, itemID, stack = pcall(function() return cinfo.itemID, cinfo.stackCount end)
					if okR and type(itemID) == "number" then
						local classID = itemClass(itemID)
						if classID == PROJECTILE_CLASS then
							local n = (type(stack) == "number" and not FP.issecret(stack)) and stack or 0
							stacks[#stacks + 1] = ("bag %s slot %s item %s x%s"):format(bag, slot, itemID, describe(stack))
							total = total + n
						end
					end
				end
			end
		end
	end
	a.quivers, a.stacks, a.total = quivers, stacks, total
	say("  quivers/pouches: %s", #quivers > 0 and table.concat(quivers, "; ") or "none")
	say("  projectile stacks in bags: %s (total %s)", #stacks > 0 and table.concat(stacks, "; ") or "none", total)

	local okR, speed, minD, maxD = call("UnitRangedDamage", "player")
	a.ranged = okR and (describe(speed) .. " " .. describe(minD) .. "-" .. describe(maxD)) or ("ERR " .. str(speed))
	say("  UnitRangedDamage: %s", a.ranged)
	info("ammo: slot %s id=%s count=%s bagsTotal=%s quivers=%s", AMMO_SLOT, a.id, a.count, total, #quivers)
	d.lastAmmo = a
end

------------------------------------------------------------------------
-- auras
------------------------------------------------------------------------

local WATCH_AURAS = {
	{ id = 13165, name = "Aspect of the Hawk" },
	{ id = 13163, name = "Aspect of the Monkey" },
	{ id = 5118,  name = "Aspect of the Cheetah" },
	{ id = 3045,  name = "Rapid Fire" },
	{ id = 1130,  name = "Hunter's Mark" },
}

local function reportAuras(reason)
	reason = reason or "manual"
	local okG, general = call("C_Secrets.ShouldAurasBeSecret")
	say("auras (%s): ShouldAurasBeSecret=%s", reason, okG and describe(general) or ("ERR " .. str(general)))
	local lines = {}
	for i = 1, 40 do
		local ok, aura = call("C_UnitAuras.GetAuraDataByIndex", "player", i, "HELPFUL")
		if ok == nil then
			lines[#lines + 1] = "GetAuraDataByIndex missing"
			break
		elseif not ok then
			lines[#lines + 1] = ("#%s ERR %s"):format(i, str(aura))
			break
		elseif aura == nil then
			break
		else
			local okF, name, spellId, dur, exp = pcall(function() return aura.name, aura.spellId, aura.duration, aura.expirationTime end)
			if okF then
				lines[#lines + 1] = ("#%s %s id=%s dur=%s exp=%s%s"):format(i, describe(name), describe(spellId), describe(dur), describe(exp),
					FP.issecrettable(aura) and " [secret table]" or "")
			else
				lines[#lines + 1] = ("#%s fields ERR %s"):format(i, str(name))
			end
		end
	end
	for _, l in ipairs(lines) do
		say("  %s", l)
	end
	for _, w in ipairs(WATCH_AURAS) do
		local okS, secret = call("C_Secrets.ShouldSpellAuraBeSecret", w.id)
		local okP, aura = call("C_UnitAuras.GetPlayerAuraBySpellID", w.id)
		local have
		if okP == nil then
			have = "missing"
		elseif not okP then
			have = "ERR " .. str(aura)
		else
			have = aura and "present" or "absent"
		end
		say("  %s (%s): secretInCombat=%s now=%s", w.name, w.id, okS and describe(secret) or ("ERR " .. str(secret)), have)
	end
	info("auras(%s): %s buffs listed; %s", reason, #lines, lines[1] or "none")
	settings().lastAuras = { at = GetServerTime(), reason = reason, lines = lines }
end

------------------------------------------------------------------------
-- swing events
------------------------------------------------------------------------

local swingFrame = CreateFrame("Frame")
local swingCount, swingRangeCount = 0, 0

swingFrame:SetScript("OnEvent", function(_, event, a1, a2, a3)
	if event == "PLAYER_SWING" then
		swingCount = swingCount + 1
		if swingCount <= 100 or swingCount % 25 == 0 then
			local okS, inRange = call("C_SwingTimer.IsTargetWithinSwingRange", a2)
			debug("PLAYER_SWING #%s duration=%s type=%s | IsTargetWithinSwingRange=%s", swingCount, describe(a1), describe(a2),
				okS == nil and "missing" or (okS and describe(inRange) or ("ERR " .. str(inRange))))
		end
	elseif event == "PLAYER_SWING_RANGE_UPDATE" then
		swingRangeCount = swingRangeCount + 1
		if swingRangeCount <= 100 or swingRangeCount % 25 == 0 then
			debug("PLAYER_SWING_RANGE_UPDATE #%s type=%s isInRange=%s checksRange=%s", swingRangeCount, describe(a1), describe(a2), describe(a3))
		end
	end
end)

local function setSwing(on)
	settings().swing = on
	if on then
		local okA = FP.safeRegister(swingFrame, "PLAYER_SWING", SRC)
		local okB = FP.safeRegister(swingFrame, "PLAYER_SWING_RANGE_UPDATE", SRC)
		-- signature on build 70338 is (swingType, enable). Only ever enable: the flag is
		-- shared with Blizzard's own swing bars. 0 = MainHand, 2 = Ranged.
		local results = {}
		for _, swingType in ipairs({ 0, 2 }) do
			local okE, err = call("C_SwingTimer.EnableRangeCheck", swingType, true)
			results[#results + 1] = swingType .. ":" .. (okE == nil and "missing" or (okE and "ok" or ("ERR " .. str(err))))
		end
		info("swing logging on (PLAYER_SWING=%s, RANGE_UPDATE=%s, EnableRangeCheck %s)", tostring(okA), tostring(okB), table.concat(results, " "))
	else
		pcall(swingFrame.UnregisterEvent, swingFrame, "PLAYER_SWING")
		pcall(swingFrame.UnregisterEvent, swingFrame, "PLAYER_SWING_RANGE_UPDATE")
		info("swing logging off (%s swings, %s range updates seen)", swingCount, swingRangeCount)
	end
end

------------------------------------------------------------------------
-- lifecycle
------------------------------------------------------------------------

local frame = CreateFrame("Frame")
FP.safeRegister(frame, "ADDON_LOADED", SRC)
FP.safeRegister(frame, "PLAYER_ENTERING_WORLD", SRC)
FP.safeRegister(frame, "PLAYER_REGEN_DISABLED", SRC)
FP.safeRegister(frame, "PLAYER_REGEN_ENABLED", SRC)
FP.safeRegister(frame, "PLAYER_TARGET_CHANGED", SRC)
FP.safeRegister(frame, "PLAYER_EQUIPMENT_CHANGED", SRC)
FP.safeRegister(frame, "BAG_UPDATE_DELAYED", SRC)

local lastAmmoCount
local function ammoTick(reason)
	local ok, count = call("GetInventoryItemCount", "player", AMMO_SLOT)
	local v = ok and describe(count) or ("ERR " .. str(count))
	if v ~= lastAmmoCount then
		debug("ammo count %s -> %s (%s)", str(lastAmmoCount), v, reason)
		lastAmmoCount = v
	end
end

local function later(delay, fn)
	local ok = call("C_Timer.After", delay, fn)
	if not ok then
		fn()
	end
end

frame:SetScript("OnEvent", function(_, event, a1, a2)
	if event == "ADDON_LOADED" and a1 == ADDON then
		local d = settings()
		info("loaded; HunterProbeDB had range=%s swing=%s", tostring(d.range), tostring(d.swing))
	elseif event == "PLAYER_ENTERING_WORLD" and (a1 or a2) then
		local okC, _, classFile = call("UnitClass", "player")
		local cls = okC and str(classFile) or "?"
		if cls ~= "HUNTER" then
			say("player class is %s, not HUNTER; range and ammo answers will mostly be nil. Commands still work.", cls)
		end
		local d = settings()
		warmItems()
		if d.swing then
			setSwing(true)
		end
		if d.range then
			setRangeSampling(true)
		end
		later(4, function()
			reportAuras("login")
			ammoTick("login")
		end)
		say("type /hp for commands")
	elseif event == "PLAYER_REGEN_DISABLED" then
		later(1, function()
			reportAuras("combatStart")
			local out, sig = sampleRange("target")
			info("combatStart range: zone=%s | %s", out.zone or "-", sig)
		end)
	elseif event == "PLAYER_REGEN_ENABLED" then
		later(0.5, function()
			reportAuras("combatEnd")
			ammoTick("combatEnd")
		end)
	elseif event == "PLAYER_TARGET_CHANGED" then
		lastSig = nil
		local okE, exists = call("UnitExists", "target")
		if okE and exists == true then
			local out, sig = sampleRange("target")
			debug("target changed: zone=%s | %s", out.zone or "-", sig)
		end
	elseif event == "PLAYER_EQUIPMENT_CHANGED" then
		if a1 == AMMO_SLOT then
			ammoTick("equipment slot " .. str(a1) .. " hasCurrent=" .. str(a2))
		end
	elseif event == "BAG_UPDATE_DELAYED" then
		ammoTick("bag update")
	end
end)

------------------------------------------------------------------------
-- slash
------------------------------------------------------------------------

local function menu()
	say("commands:")
	print("  /hp range            one-shot range report for the target")
	print("  /hp range on|off     sample every 0.5 s, log changes")
	print("  /hp ammo             ammo slot, quivers, projectile stacks")
	print("  /hp auras            player buffs with secrecy per field")
	print("  /hp swing on|off     log the swing events")
	print("  /hp status")
end

local function handle(msg)
	local cmd, rest = string.match(msg or "", "^%s*(%S*)%s*(.-)%s*$")
	cmd = string.lower(cmd or "")
	rest = string.lower(rest or "")
	if cmd == "range" then
		if rest == "on" then
			setRangeSampling(true)
		elseif rest == "off" then
			setRangeSampling(false)
		else
			reportRange()
		end
	elseif cmd == "ammo" then
		reportAmmo()
	elseif cmd == "auras" then
		reportAuras("manual")
	elseif cmd == "swing" then
		setSwing(rest ~= "off")
	elseif cmd == "status" then
		local d = settings()
		say("range sampling %s (%s samples), swing logging %s (%s swings, %s range updates), ammo count %s",
			d.range and "on" or "off", sampleCount, d.swing and "on" or "off", swingCount, swingRangeCount, str(lastAmmoCount))
	else
		menu()
	end
end

SLASH_HUNTERPROBE1 = "/hp"
SLASH_HUNTERPROBE2 = "/hunterprobe"
SlashCmdList["HUNTERPROBE"] = handle
ns.handleSlash = handle
