-- HunterHUD: one small frame with two signals for a hunter.
--   Range light   RANGED (green), DEAD ZONE (red), OUT OF RANGE (grey), plus a
--                 melee dot from Wing Clip. Driven by two range checks twice a second.
--   Ammo counter  the equipped ammo count, yellow under the warn threshold, red
--                 under the critical one, flashing once when it crosses.
--
-- Built on what HunterProbe measured on build 70338 (see CLAUDE.md): Auto Shot
-- answers false only inside the dead zone or beyond 35 yards; the 35 yard item
-- check separates those two; every input stays readable in combat.

local ADDON, ns = ...

local AUTO_SHOT, WING_CLIP, ITEM_35YD = 75, 2974, 18904
local AMMO_SLOT, RANGED_SLOT = 0, 18
local WEAPON_CLASS = 2
local NEEDS_AMMO = { [2] = true, [3] = true, [18] = true } -- bow, gun, crossbow
local TICK = 0.5

local DEFAULTS = {
	enabled = true,
	locked = true,
	scale = 1,
	warn = 200,
	crit = 50,
	debug = false,
	pos = nil, -- { point, x, y } relative to UIParent
}

local COLORS = {
	RANGED = { 0.25, 0.9, 0.35 },
	DEAD = { 1, 0.25, 0.25 },
	OUT = { 0.5, 0.5, 0.5 },
	NONE = { 0.25, 0.25, 0.25 },
	ammoOk = { 0.92, 0.92, 0.92 },
	ammoWarn = { 1, 0.85, 0.2 },
	ammoCrit = { 1, 0.3, 0.3 },
	ammoNone = { 0.5, 0.5, 0.5 },
}

local LABELS = { RANGED = "IN RANGE", DEAD = "DEAD ZONE", OUT = "OUT OF RANGE", NONE = "" }

local db
local isHunter = false
local ticker
local lastRange, lastAmmoState
local frame

------------------------------------------------------------------------
-- secret-safe helpers
------------------------------------------------------------------------

local issecret = _G.issecretvalue or function() return false end

-- pcall a function and return its first result, or nil if it failed or is secret
local function call(fn, ...)
	if type(fn) ~= "function" then
		return nil
	end
	local ok, r = pcall(fn, ...)
	if not ok or issecret(r) then
		return nil
	end
	return r
end

local function say(msg)
	print("|cff33ff99HunterHUD|r: " .. tostring(msg))
end

local function dbg(fmt, ...)
	if db and db.debug and _G.ForeverProbe and _G.ForeverProbe.debug then
		_G.ForeverProbe.debug("HH", fmt, ...)
	end
end

------------------------------------------------------------------------
-- measurements
------------------------------------------------------------------------

-- Returns "RANGED" | "DEAD" | "OUT" | "NONE", meleeFlag (true/false/nil)
local function rangeState()
	if call(UnitExists, "target") ~= true
		or call(UnitCanAttack, "player", "target") ~= true
		or call(UnitIsDead, "target") == true then
		return "NONE", nil
	end
	local spell = _G.C_Spell
	local auto = spell and call(spell.IsSpellInRange, AUTO_SHOT, "target")
	local melee = spell and call(spell.IsSpellInRange, WING_CLIP, "target")
	if auto == true then
		return "RANGED", melee
	end
	if auto == false then
		local item = _G.C_Item
		local within35 = item and call(item.IsItemInRange, ITEM_35YD, "target")
		if within35 == true then
			return "DEAD", melee
		end
		if within35 == false then
			return "OUT", melee
		end
		-- item not cached yet: fall back to the 9.9 yard interact check
		if call(CheckInteractDistance, "target", 3) == true then
			return "DEAD", melee
		end
		return "OUT", melee
	end
	return "NONE", melee
end

-- Returns needsAmmo (bool), count (number or nil)
local function ammoState()
	local rangedID = call(GetInventoryItemID, "player", RANGED_SLOT)
	if type(rangedID) ~= "number" then
		return false, nil
	end
	local item = _G.C_Item
	if not item or type(item.GetItemInfoInstant) ~= "function" then
		return false, nil
	end
	local ok, _, _, _, _, _, classID, subclassID = pcall(item.GetItemInfoInstant, rangedID)
	if not ok or issecret(classID) or issecret(subclassID) then
		return false, nil
	end
	if classID ~= WEAPON_CLASS or not NEEDS_AMMO[subclassID] then
		return false, nil
	end
	local count = call(GetInventoryItemCount, "player", AMMO_SLOT)
	if type(count) ~= "number" then
		count = 0
	end
	return true, count
end

------------------------------------------------------------------------
-- frame
------------------------------------------------------------------------

local function savePosition()
	local point, _, _, x, y = frame:GetPoint()
	if point then
		db.pos = { point, x, y }
	end
end

local function applyPosition()
	frame:ClearAllPoints()
	if db.pos then
		frame:SetPoint(db.pos[1], UIParent, db.pos[1], db.pos[2], db.pos[3])
	else
		frame:SetPoint("CENTER", UIParent, "CENTER", 0, -180)
	end
	frame:SetScale(db.scale or 1)
end

local function buildFrame()
	frame = CreateFrame("Frame", "HunterHUDFrame", UIParent)
	frame:SetSize(170, 36)
	frame:SetFrameStrata("MEDIUM")
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", function(self)
		if not db.locked then
			self:StartMoving()
		end
	end)
	frame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		savePosition()
	end)

	frame.bg = frame:CreateTexture(nil, "BACKGROUND")
	frame.bg:SetAllPoints()
	frame.bg:SetColorTexture(0, 0, 0, 0.55)

	frame.light = frame:CreateTexture(nil, "ARTWORK")
	frame.light:SetSize(12, 26)
	frame.light:SetPoint("LEFT", frame, "LEFT", 6, 0)
	frame.light:SetColorTexture(COLORS.NONE[1], COLORS.NONE[2], COLORS.NONE[3], 1)

	frame.melee = frame:CreateTexture(nil, "OVERLAY")
	frame.melee:SetSize(6, 6)
	frame.melee:SetPoint("BOTTOMLEFT", frame.light, "BOTTOMRIGHT", 2, 0)
	frame.melee:SetColorTexture(1, 1, 1, 1)
	frame.melee:Hide()

	frame.rangeText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	frame.rangeText:SetPoint("LEFT", frame.light, "RIGHT", 10, 0)
	frame.rangeText:SetJustifyH("LEFT")
	frame.rangeText:SetText("")

	frame.ammoText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	frame.ammoText:SetPoint("RIGHT", frame, "RIGHT", -8, 0)
	frame.ammoText:SetJustifyH("RIGHT")
	frame.ammoText:SetText("")

	frame.flash = frame.ammoText:CreateAnimationGroup()
	local down = frame.flash:CreateAnimation("Alpha")
	down:SetFromAlpha(1)
	down:SetToAlpha(0.15)
	down:SetDuration(0.2)
	down:SetOrder(1)
	local up = frame.flash:CreateAnimation("Alpha")
	up:SetFromAlpha(0.15)
	up:SetToAlpha(1)
	up:SetDuration(0.2)
	up:SetOrder(2)
	frame.flash:SetLooping("REPEAT")
	frame:Hide()
end

local function flashAmmo()
	if frame.flash:IsPlaying() then
		return
	end
	frame.flash:Play()
	local timer = _G.C_Timer
	if timer and type(timer.After) == "function" then
		timer.After(1.6, function()
			frame.flash:Stop()
			frame.ammoText:SetAlpha(1)
		end)
	else
		frame.flash:Stop()
	end
end

------------------------------------------------------------------------
-- updates
------------------------------------------------------------------------

local function stopTicker()
	if ticker then
		pcall(function() ticker:Cancel() end)
		ticker = nil
	end
end

local function setRange(state, melee)
	local c = COLORS[state] or COLORS.NONE
	frame.light:SetColorTexture(c[1], c[2], c[3], 1)
	frame.rangeText:SetText(LABELS[state] or "")
	frame.rangeText:SetTextColor(c[1], c[2], c[3])
	if melee == true then
		frame.melee:Show()
	else
		frame.melee:Hide()
	end
	if state ~= lastRange then
		dbg("range %s -> %s (melee=%s)", tostring(lastRange), state, tostring(melee))
		lastRange = state
	end
end

local function updateRange()
	if not isHunter or not db.enabled then
		return
	end
	local state, melee = rangeState()
	setRange(state, melee)
	if state == "NONE" then
		stopTicker()
	end
end

local function startTicker()
	if ticker then
		return
	end
	local timer = _G.C_Timer
	if timer and type(timer.NewTicker) == "function" then
		ticker = timer.NewTicker(TICK, updateRange)
	end
end

local function updateAmmo(reason)
	if not isHunter or not db.enabled then
		return
	end
	local needs, count = ammoState()
	local state, text, c
	if not needs then
		state, text, c = "none", "--", COLORS.ammoNone
	elseif count <= 0 then
		state, text, c = "empty", "NO AMMO", COLORS.ammoCrit
	elseif count <= (db.crit or 0) then
		state, text, c = "crit", tostring(count), COLORS.ammoCrit
	elseif count <= (db.warn or 0) then
		state, text, c = "warn", tostring(count), COLORS.ammoWarn
	else
		state, text, c = "ok", tostring(count), COLORS.ammoOk
	end
	frame.ammoText:SetText(text)
	frame.ammoText:SetTextColor(c[1], c[2], c[3])
	if state ~= lastAmmoState then
		dbg("ammo %s -> %s (%s, %s)", tostring(lastAmmoState), state, tostring(count), reason or "")
		if lastAmmoState ~= nil and (state == "crit" or state == "empty") then
			flashAmmo()
			say(state == "empty" and "out of ammo" or ("ammo low: " .. tostring(count)))
		end
		lastAmmoState = state
	end
end

local function refreshVisibility()
	if isHunter and db.enabled then
		frame:Show()
		applyPosition()
		updateAmmo("refresh")
		updateRange()
	else
		frame:Hide()
		stopTicker()
	end
end

------------------------------------------------------------------------
-- events
------------------------------------------------------------------------

local function initDb()
	if type(_G.HunterHUDDB) ~= "table" then
		_G.HunterHUDDB = {}
	end
	db = _G.HunterHUDDB
	for k, v in pairs(DEFAULTS) do
		if db[k] == nil then
			db[k] = v
		end
	end
end

local events = CreateFrame("Frame")
for _, ev in ipairs({ "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "PLAYER_TARGET_CHANGED",
	"BAG_UPDATE_DELAYED", "PLAYER_EQUIPMENT_CHANGED", "PLAYER_REGEN_DISABLED" }) do
	pcall(events.RegisterEvent, events, ev)
end

events:SetScript("OnEvent", function(_, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 == ADDON then
			initDb()
			buildFrame()
		end
	elseif event == "PLAYER_LOGIN" then
		local _, classFile = UnitClass("player")
		isHunter = (classFile == "HUNTER")
		if not isHunter then
			dbg("not a hunter (%s); staying hidden", tostring(classFile))
			return
		end
		local item = _G.C_Item
		if item and type(item.RequestLoadItemDataByID) == "function" then
			pcall(item.RequestLoadItemDataByID, ITEM_35YD)
		end
		refreshVisibility()
	elseif event == "PLAYER_ENTERING_WORLD" then
		if isHunter then
			refreshVisibility()
		end
	elseif event == "PLAYER_TARGET_CHANGED" then
		if isHunter and db.enabled then
			updateRange()
			if lastRange ~= "NONE" then
				startTicker()
			end
		end
	elseif event == "PLAYER_REGEN_DISABLED" then
		if isHunter and db.enabled then
			updateRange()
			if lastRange ~= "NONE" then
				startTicker()
			end
		end
	elseif event == "BAG_UPDATE_DELAYED" then
		updateAmmo("bags")
	elseif event == "PLAYER_EQUIPMENT_CHANGED" then
		if arg1 == AMMO_SLOT or arg1 == RANGED_SLOT then
			updateAmmo("equipment")
		end
	end
end)

------------------------------------------------------------------------
-- slash
------------------------------------------------------------------------

local function status()
	say(("%s, %s, scale %s, warn under %s, critical under %s, debug %s"):format(
		db.enabled and "on" or "off", db.locked and "locked" or "unlocked (drag to move)",
		tostring(db.scale), tostring(db.warn), tostring(db.crit), db.debug and "on" or "off"))
	if not isHunter then
		say("this character is not a hunter, so the frame stays hidden")
	end
end

local function menu()
	say("commands:")
	print("  /hh on | off          show or hide")
	print("  /hh lock | unlock     unlock, then drag the frame; lock when placed")
	print("  /hh reset             put the frame back at the default spot")
	print("  /hh scale 0.5..2")
	print("  /hh warn N            ammo turns yellow at or under N (default 200)")
	print("  /hh crit N            ammo turns red and flashes at or under N (default 50)")
	print("  /hh debug on | off    log state changes through ForeverProbe when it is loaded")
	print("  /hh status")
end

local function handle(msg)
	local cmd, rest = string.match(msg or "", "^%s*(%S*)%s*(.-)%s*$")
	cmd = string.lower(cmd or "")
	rest = string.lower(rest or "")
	if cmd == "on" then
		db.enabled = true
		refreshVisibility()
		status()
	elseif cmd == "off" then
		db.enabled = false
		refreshVisibility()
		status()
	elseif cmd == "lock" then
		db.locked = true
		status()
	elseif cmd == "unlock" then
		db.locked = false
		status()
	elseif cmd == "reset" then
		db.pos = nil
		db.scale = 1
		applyPosition()
		status()
	elseif cmd == "scale" then
		local n = tonumber(rest)
		if n and n >= 0.5 and n <= 2 then
			db.scale = n
			applyPosition()
		else
			say("scale must be between 0.5 and 2")
		end
		status()
	elseif cmd == "warn" or cmd == "crit" then
		local n = tonumber(rest)
		if n and n >= 0 then
			db[cmd] = math.floor(n)
			lastAmmoState = nil
			updateAmmo("threshold")
		else
			say("give a number: /hh " .. cmd .. " N")
		end
		status()
	elseif cmd == "debug" then
		db.debug = (rest == "on")
		status()
	elseif cmd == "status" then
		status()
	else
		menu()
		status()
	end
end

SLASH_HUNTERHUD1 = "/hh"
SLASH_HUNTERHUD2 = "/hunterhud"
SlashCmdList["HUNTERHUD"] = handle
ns.handleSlash = handle
ns.rangeState = rangeState
ns.ammoState = ammoState
