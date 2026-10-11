-- BuffReminder: a row of icons that appears out of combat when something you
-- would normally keep up is missing, and disappears when it is back. Nothing
-- is shown in combat, because on this client aura reads throw there.
--
-- Checks match buffs by name, so spell ranks do not matter, and each check is
-- gated on the player actually knowing the spell. Per-check on/off is saved.
--
-- Built on what ForeverProbe measured on build 70338: C_UnitAuras is readable
-- out of combat, C_Secrets.ShouldAurasBeSecret() flips exactly with combat, and
-- SavedVariables persist.

local ADDON, ns = ...

local ICON_SIZE, GAP, PAD = 32, 6, 6
local REEVAL_DELAY = 0.5

local DEFAULTS = {
	enabled = true,
	locked = true,
	scale = 1,
	debug = false,
	pos = nil,
	checks = {}, -- key -> false when the user switched a check off (true when switched on)
}

------------------------------------------------------------------------
-- secret-safe helpers
------------------------------------------------------------------------

local issecret = _G.issecretvalue or function() return false end

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
	print("|cff33ff99BuffReminder|r: " .. tostring(msg))
end

local db
local function dbg(fmt, ...)
	if db and db.debug and _G.ForeverProbe and _G.ForeverProbe.debug then
		_G.ForeverProbe.debug("BR", fmt, ...)
	end
end

------------------------------------------------------------------------
-- buff reading
------------------------------------------------------------------------

-- Returns a set of buff names on the player, or nil when they cannot be read.
local function playerBuffs()
	local secrets = _G.C_Secrets
	if secrets and call(secrets.ShouldAurasBeSecret) == true then
		return nil
	end
	local auras = _G.C_UnitAuras
	if not auras or type(auras.GetAuraDataByIndex) ~= "function" then
		return nil
	end
	local names = {}
	for i = 1, 60 do
		local ok, aura = pcall(auras.GetAuraDataByIndex, "player", i, "HELPFUL")
		if not ok then
			return nil
		end
		if aura == nil then
			break
		end
		local okn, name = pcall(function() return aura.name end)
		if okn and type(name) == "string" and not issecret(name) then
			names[name] = true
		end
	end
	return names
end

local function hasAny(list)
	return function(buffs)
		for _, n in ipairs(list) do
			if buffs[n] then
				return true
			end
		end
		return false
	end
end

local function hasPrefix(prefix)
	return function(buffs)
		for n in pairs(buffs) do
			if n:sub(1, #prefix) == prefix then
				return true
			end
		end
		return false
	end
end

-- satisfied unless the pet is missing or dead; returns ok, label override
local function petOk()
	if call(UnitExists, "pet") ~= true then
		return false, "No pet"
	end
	if call(UnitIsDead, "pet") == true then
		return false, "Pet dead"
	end
	return true
end

-- Hunter's Mark on a live hostile target, out of combat (a pre-pull reminder)
local function markOk()
	if call(UnitExists, "target") ~= true
		or call(UnitCanAttack, "player", "target") ~= true
		or call(UnitIsDead, "target") == true then
		return true
	end
	local auras = _G.C_UnitAuras
	if not auras or type(auras.GetAuraDataBySpellName) ~= "function" then
		return true
	end
	local ok, aura = pcall(auras.GetAuraDataBySpellName, "target", "Hunter's Mark", "HARMFUL")
	if not ok then
		return true -- cannot read the target: do not nag
	end
	return aura ~= nil
end

------------------------------------------------------------------------
-- the checks
------------------------------------------------------------------------
-- test(buffs) returns true when nothing is missing. known: any of these spell
-- IDs in the spellbook enables the check. icon: spell whose icon is shown.
-- default = false means off until "/br on <key>".

ns.CHECKS = {
	{ key = "aspect", class = "HUNTER", label = "Aspect", known = { 13163, 13165 }, icon = 13165, test = hasPrefix("Aspect of the") },
	{ key = "pet", class = "HUNTER", label = "Pet", known = { 883 }, icon = 883, test = petOk },
	{ key = "mark", class = "HUNTER", label = "Hunter's Mark", known = { 1130 }, icon = 1130, test = markOk, default = false },
	{ key = "motw", class = "DRUID", label = "Mark of the Wild", known = { 1126 }, icon = 1126, test = hasAny({ "Mark of the Wild", "Gift of the Wild" }) },
	{ key = "thorns", class = "DRUID", label = "Thorns", known = { 467 }, icon = 467, test = hasAny({ "Thorns" }), default = false },
	{ key = "intellect", class = "MAGE", label = "Arcane Intellect", known = { 1459 }, icon = 1459, test = hasAny({ "Arcane Intellect", "Arcane Brilliance" }) },
	{ key = "armor", class = "MAGE", label = "Armor", known = { 168 }, icon = 168, test = hasAny({ "Frost Armor", "Ice Armor", "Mage Armor" }) },
	{ key = "fortitude", class = "PRIEST", label = "Fortitude", known = { 1243 }, icon = 1243, test = hasAny({ "Power Word: Fortitude", "Prayer of Fortitude" }) },
	{ key = "innerfire", class = "PRIEST", label = "Inner Fire", known = { 588 }, icon = 588, test = hasAny({ "Inner Fire" }) },
	{ key = "demonarmor", class = "WARLOCK", label = "Armor", known = { 687 }, icon = 687, test = hasAny({ "Demon Skin", "Demon Armor" }) },
	{ key = "pet", class = "WARLOCK", label = "Pet", known = { 688 }, icon = 688, test = petOk },
	{ key = "blessing", class = "PALADIN", label = "Blessing", known = { 19740 }, icon = 19740, test = hasPrefix("Blessing of") },
	{ key = "shield", class = "SHAMAN", label = "Lightning Shield", known = { 324 }, icon = 324, test = hasAny({ "Lightning Shield" }), default = false },
	{ key = "shout", class = "WARRIOR", label = "Battle Shout", known = { 6673 }, icon = 6673, test = hasAny({ "Battle Shout" }), default = false },
}

local classFile
local activeChecks = {} -- checks for this class whose spell is known
local known = {}        -- spellID -> bool

local function spellKnown(id)
	local book = _G.C_SpellBook
	if not book then
		return true
	end
	local bank = (_G.Enum and _G.Enum.SpellBookSpellBank and _G.Enum.SpellBookSpellBank.Player) or 0
	if type(book.IsSpellKnownOrInSpellBook) == "function" then
		local r = call(book.IsSpellKnownOrInSpellBook, id, bank, true)
		if r ~= nil then
			return r == true
		end
	end
	if type(book.IsSpellKnown) == "function" then
		local r = call(book.IsSpellKnown, id, bank)
		if r ~= nil then
			return r == true
		end
	end
	return true
end

local function checkEnabled(c)
	local v = db.checks[c.key]
	if v == nil then
		return c.default ~= false
	end
	return v == true
end

local function rebuildChecks()
	activeChecks = {}
	known = {}
	for _, c in ipairs(ns.CHECKS) do
		if c.class == classFile then
			local isKnown = false
			for _, id in ipairs(c.known) do
				if spellKnown(id) then
					isKnown = true
					break
				end
			end
			known[c.key] = isKnown
			if isKnown then
				activeChecks[#activeChecks + 1] = c
			end
		end
	end
	dbg("checks rebuilt for %s: %s active", tostring(classFile), #activeChecks)
end

------------------------------------------------------------------------
-- frame
------------------------------------------------------------------------

local frame
local slots = {}

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
		frame:SetPoint("CENTER", UIParent, "CENTER", 0, 140)
	end
	frame:SetScale(db.scale or 1)
end

local function buildFrame()
	frame = CreateFrame("Frame", "BuffReminderFrame", UIParent)
	frame:SetSize(ICON_SIZE + PAD * 2, ICON_SIZE + PAD * 2 + 12)
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
	frame.bg:SetColorTexture(0, 0, 0, 0.45)
	frame:Hide()
end

local function slot(i)
	if slots[i] then
		return slots[i]
	end
	local s = {}
	s.icon = frame:CreateTexture(nil, "ARTWORK")
	s.icon:SetSize(ICON_SIZE, ICON_SIZE)
	s.icon:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + (i - 1) * (ICON_SIZE + GAP), -PAD)
	s.label = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	s.label:SetPoint("TOP", s.icon, "BOTTOM", 0, -1)
	s.label:SetJustifyH("CENTER")
	slots[i] = s
	return s
end

local function render(missing)
	if #missing == 0 then
		frame:Hide()
		return
	end
	for i, m in ipairs(missing) do
		local s = slot(i)
		local tex = _G.C_Spell and call(_G.C_Spell.GetSpellTexture, m.check.icon)
		if tex then
			s.icon:SetTexture(tex)
		else
			s.icon:SetColorTexture(0.6, 0.6, 0.6, 1)
		end
		s.label:SetText(m.label)
		s.icon:Show()
		s.label:Show()
	end
	for i = #missing + 1, #slots do
		slots[i].icon:Hide()
		slots[i].label:Hide()
	end
	frame:SetSize(PAD * 2 + #missing * ICON_SIZE + (#missing - 1) * GAP, ICON_SIZE + PAD * 2 + 12)
	frame:Show()
end

------------------------------------------------------------------------
-- evaluation
------------------------------------------------------------------------

local lastSummary
local pending = false
local forceAll = false

local function evaluate(reason)
	if not db.enabled or #activeChecks == 0 then
		frame:Hide()
		return
	end
	if call(InCombatLockdown) == true or call(UnitIsDeadOrGhost, "player") == true then
		frame:Hide()
		return
	end
	local buffs = playerBuffs()
	if buffs == nil then
		frame:Hide()
		dbg("auras unreadable (%s); hidden", reason or "")
		return
	end
	local missing = {}
	for _, c in ipairs(activeChecks) do
		if forceAll or checkEnabled(c) then
			local ok, label = c.test(buffs)
			if forceAll or ok ~= true then
				missing[#missing + 1] = { check = c, label = label or c.label }
			end
		end
	end
	render(missing)
	local parts = {}
	for _, m in ipairs(missing) do
		parts[#parts + 1] = m.label
	end
	local summary = table.concat(parts, ", ")
	if summary ~= lastSummary then
		dbg("missing: %s (%s)", summary ~= "" and summary or "nothing", reason or "")
		lastSummary = summary
	end
end
ns.evaluate = evaluate

-- coalesce bursts of UNIT_AURA into one evaluation
local function scheduleEvaluate(reason)
	if pending then
		return
	end
	pending = true
	local timer = _G.C_Timer
	if timer and type(timer.After) == "function" then
		timer.After(REEVAL_DELAY, function()
			pending = false
			evaluate(reason)
		end)
	else
		pending = false
		evaluate(reason)
	end
end

------------------------------------------------------------------------
-- events
------------------------------------------------------------------------

local function initDb()
	if type(_G.BuffReminderDB) ~= "table" then
		_G.BuffReminderDB = {}
	end
	db = _G.BuffReminderDB
	for k, v in pairs(DEFAULTS) do
		if db[k] == nil then
			if type(v) == "table" then
				db[k] = {}
			else
				db[k] = v
			end
		end
	end
end

local events = CreateFrame("Frame")
for _, ev in ipairs({ "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_ENABLED",
	"PLAYER_REGEN_DISABLED", "UNIT_AURA", "UNIT_PET", "PLAYER_TARGET_CHANGED", "SPELLS_CHANGED",
	"PLAYER_DEAD", "PLAYER_ALIVE", "PLAYER_UNGHOST" }) do
	pcall(events.RegisterEvent, events, ev)
end

events:SetScript("OnEvent", function(_, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 == ADDON then
			initDb()
			buildFrame()
		end
	elseif event == "PLAYER_LOGIN" then
		local _, cf = UnitClass("player")
		classFile = cf
		rebuildChecks()
		applyPosition()
		scheduleEvaluate("login")
	elseif event == "PLAYER_ENTERING_WORLD" then
		scheduleEvaluate("entering world")
	elseif event == "PLAYER_REGEN_DISABLED" then
		frame:Hide()
	elseif event == "PLAYER_REGEN_ENABLED" then
		scheduleEvaluate("combat ended")
	elseif event == "UNIT_AURA" then
		if arg1 == "player" or arg1 == "target" or arg1 == "pet" then
			scheduleEvaluate("aura " .. tostring(arg1))
		end
	elseif event == "UNIT_PET" then
		if arg1 == "player" then
			scheduleEvaluate("pet")
		end
	elseif event == "PLAYER_TARGET_CHANGED" then
		scheduleEvaluate("target")
	elseif event == "SPELLS_CHANGED" then
		rebuildChecks()
		scheduleEvaluate("spells")
	elseif event == "PLAYER_DEAD" or event == "PLAYER_ALIVE" or event == "PLAYER_UNGHOST" then
		scheduleEvaluate(event)
	end
end)

------------------------------------------------------------------------
-- slash
------------------------------------------------------------------------

local function listChecks()
	if not classFile then
		say("not logged in yet")
		return
	end
	local any = false
	for _, c in ipairs(ns.CHECKS) do
		if c.class == classFile then
			any = true
			local state
			if not known[c.key] then
				state = "spell not known yet"
			elseif checkEnabled(c) then
				state = "on"
			else
				state = "off"
			end
			print(("  %-10s %-18s %s"):format(c.key, c.label, state))
		end
	end
	if not any then
		say("no checks defined for " .. tostring(classFile) .. " (edit ns.CHECKS in BuffReminder.lua)")
	end
end

local function status()
	say(("%s, %s, scale %s, debug %s"):format(db.enabled and "on" or "off",
		db.locked and "locked" or "unlocked (drag to move)", tostring(db.scale), db.debug and "on" or "off"))
	listChecks()
end

local function menu()
	say("commands:")
	print("  /br on | off            whole addon")
	print("  /br on KEY | off KEY    one check (keys listed below)")
	print("  /br test                show every check for five seconds, to place the frame")
	print("  /br lock | unlock | reset | scale 0.5..2 | debug on|off | status")
end

local function findCheck(key)
	for _, c in ipairs(ns.CHECKS) do
		if c.class == classFile and c.key == key then
			return c
		end
	end
end

local function handle(msg)
	local cmd, rest = string.match(msg or "", "^%s*(%S*)%s*(.-)%s*$")
	cmd = string.lower(cmd or "")
	rest = string.lower(rest or "")
	if cmd == "on" or cmd == "off" then
		if rest == "" then
			db.enabled = (cmd == "on")
			evaluate("toggle")
		else
			local c = findCheck(rest)
			if c then
				db.checks[c.key] = (cmd == "on")
				evaluate("check toggle")
			else
				say("no check called " .. rest .. " for this class")
			end
		end
		status()
	elseif cmd == "test" then
		forceAll = true
		evaluate("test")
		local timer = _G.C_Timer
		if timer and type(timer.After) == "function" then
			timer.After(5, function()
				forceAll = false
				evaluate("test over")
			end)
		else
			forceAll = false
		end
		say("showing every active check for five seconds")
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

SLASH_BUFFREMINDER1 = "/br"
SLASH_BUFFREMINDER2 = "/buffreminder"
SlashCmdList["BUFFREMINDER"] = handle
ns.handleSlash = handle
