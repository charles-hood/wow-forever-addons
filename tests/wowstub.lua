-- Minimal stand-in for the WoW client API, enough to load the probe addons
-- offline and drive them through their events and slash commands.
-- Lua 5.4/5.5 on the Mac; the addons themselves must stay 5.1-compatible.

local Stub = {}
_G.Stub = Stub

Stub.frames = {}
Stub.printed = {}
Stub.timers = {}
Stub.tickers = {}
Stub.combat = false
Stub.time = 1000.0
Stub.serverTime = 1760000000
Stub.rangeAnswers = { [75] = true, [2974] = false }   -- spellID -> IsSpellInRange answer
Stub.interact = { [1] = true, [2] = false, [3] = false, [4] = true }
Stub.cachedItems = { [835] = true, [1191] = true }       -- items the client has cached
Stub.itemInRange = { [835] = true, [1191] = true, [18904] = true }
Stub.unknownEvents = { UNIT_HEALTH_FREQUENT = true, LEARNED_SPELL_IN_TAB = true }
Stub.forbiddenEvents = { COMBAT_LOG_EVENT_UNFILTERED = true }   -- registering raises ADDON_ACTION_FORBIDDEN

-- a secret value sentinel; type() is patched so it reports "number"
Stub.SECRET = setmetatable({}, { __tostring = function() return "<SECRET SENTINEL>" end })
local rawtype = type
_G.type = function(v)
	if v == Stub.SECRET then return "number" end
	return rawtype(v)
end
_G.issecretvalue = function(v) return v == Stub.SECRET end
_G.issecrettable = function(v) return rawtype(v) == "table" and v.__secret == true end
_G.canaccessvalue = function(v) return v ~= Stub.SECRET end
_G.scrub = function(...) return ... end

_G.unpack = _G.unpack or table.unpack
_G.date = function(fmt, t) return os.date(fmt, t) end
_G.GetTime = function() return Stub.time end
_G.GetServerTime = function() return Stub.serverTime end
_G.InCombatLockdown = function() return Stub.combat end
_G.UnitAffectingCombat = function() return Stub.combat end
_G.debugstack = function() return "stack line 1\nstack line 2" end
_G.GetBuildInfo = function() return "1.60.1", "70170", "Oct 1 2026", 16001, "1.60.1", "Beta" end
_G.WOW_PROJECT_MAINLINE = 1
_G.WOW_PROJECT_CLASSIC = 2
_G.WOW_PROJECT_ID = 1
_G.LE_EXPANSION_LEVEL_CURRENT = 0
_G.GetClassicExpansionLevel = function() return 0 end
_G.GetLocale = function() return "enUS" end
_G.IsMacClient = function() return true end
_G.GetRealmName = function() return "Classic Beta PvE 2" end
_G.NUM_BAG_SLOTS = 4
_G.INVSLOT_AMMO = 0
_G.INVSLOT_RANGED = 18
_G.INVSLOT_MAINHAND = 16
_G.UIParent, _G.GameTooltip, _G.Minimap = {}, {}, {}
_G.Enum = {
	SecrecyLevel = { NeverSecret = 0, AlwaysSecret = 1, ContextuallySecret = 2 },
	PlayerSwingType = { MainHand = 0, OffHand = 1, Ranged = 2 },
	ItemClass = { Container = 1, Projectile = 6 },
	SpellBookSpellBank = { Player = 0, Pet = 1 },
	PowerType = { Mana = 0 },
	ItemQuality = { Poor = 0 },
}
_G.SlashCmdList = {}
_G.ReloadUI = function() error("protected") end
_G.CreateMacro = function() return 1 end
_G.CopyToClipboard = function() end

local cvars = { scriptErrors = "0", portal = "US" }
_G.GetCVar = function(k) return cvars[k] end
_G.SetCVar = function(k, v) cvars[k] = tostring(v) return true end
_G.C_CVar = { GetCVar = _G.GetCVar, RegisterCVar = function() end }

local errorHandler = function(msg) Stub.lastBlizzardError = msg end
_G.seterrorhandler = function(fn) errorHandler = fn end
_G.geterrorhandler = function() return errorHandler end

-- units
Stub.units = { player = true, target = true }
_G.UnitExists = function(u) return Stub.units[u] == true end
_G.UnitCanAttack = function(_, u) return u == "target" end
_G.UnitIsDead = function() return false end
_G.UnitGUID = function(u) return "Creature-0-1-2-3-" .. u end
_G.UnitName = function(u) if u == "player" then return "Testhunter" end return Stub.combat and Stub.SECRET or "Kobold" end
_G.UnitHealth = function() return Stub.combat and Stub.SECRET or 100 end
_G.UnitHealthMax = function(u) if u == "player" then return 120 end return Stub.combat and Stub.SECRET or 120 end
_G.UnitPower = function() return 50 end
_G.UnitPowerMax = function() return 80 end
_G.UnitPowerType = function() return 0 end
_G.UnitLevel = function() return 12 end
_G.UnitClass = function() return "Hunter", "HUNTER", 3 end
_G.UnitXP = function() return 1 end
_G.UnitXPMax = function() return 2 end
_G.GetXPExhaustion = function() return nil end
_G.IsResting = function() return true end
_G.GetMoney = function() return 12345 end
_G.UnitOnTaxi = function() return false end
_G.UnitRangedDamage = function() return 2.6, 10, 20 end
_G.CheckInteractDistance = function(_, i) return Stub.interact[i] end

-- inventory
Stub.ammo = { id = 2512, count = 143, link = "|Hitem:2512|h[Rough Arrow]|h" }
Stub.equipped = { [0] = 2512, [16] = 25, [18] = 2504 }
_G.GetInventoryItemID = function(_, slot) if slot == 0 then return Stub.ammo.id end return Stub.equipped[slot] end
_G.GetInventoryItemCount = function(_, slot) if slot == 0 then return Stub.ammo.count end return 1 end
_G.GetInventoryItemLink = function(_, slot) if slot == 0 then return Stub.ammo.link end return nil end
local itemClasses = { [2512] = { 6, 2 }, [2504] = { 2, 2 }, [25] = { 2, 7 }, [4496] = { 1, 0 }, [2101] = { 1, 2 },
	[2946] = { 2, 16 }, [2508] = { 2, 3 } } -- 2946 thrown, 2508 gun
_G.C_Item = {
	GetItemInfoInstant = function(id)
		local c = itemClasses[id]
		if not c then return nil end
		return id, "Type", "SubType", "INVTYPE", 1, c[1], c[2]
	end,
	IsItemInRange = function(id)
		if not Stub.cachedItems[id] then return nil end
		return Stub.itemInRange[id]
	end,
	IsItemDataCachedByID = function(id) return Stub.cachedItems[id] == true end,
	RequestLoadItemDataByID = function() end,
	GetItemInfo = function() end,
	GetItemCount = function() return 0 end,
}
Stub.bags = { [0] = { 16, { [1] = { 2512, 200 }, [2] = { 4496, 1 } } }, [1] = { 18, { [3] = { 2512, 57 } } } }
Stub.bagItems = { [1] = 2101 }
_G.C_Container = {
	GetContainerNumSlots = function(bag) local b = Stub.bags[bag]; return b and b[1] or 0 end,
	GetContainerItemInfo = function(bag, slot)
		local b = Stub.bags[bag]; local it = b and b[2][slot]
		if not it then return nil end
		return { itemID = it[1], stackCount = it[2], hyperlink = "|Hitem:" .. it[1] .. "|h" }
	end,
	ContainerIDToInventoryID = function(bag) return 19 + bag end,
}
_G.GetInventoryItemID = function(_, slot)
	if slot == 0 then return Stub.ammo.id end
	if slot >= 20 then return Stub.bagItems[slot - 19] end
	return Stub.equipped[slot]
end

-- spells and auras
_G.C_Spell = {
	IsSpellInRange = function(id)
		if Stub.combat and Stub.secretRange then return Stub.SECRET end
		return Stub.rangeAnswers[id]
	end,
	GetSpellInfo = function(id) return { name = "Spell" .. id, spellID = id } end,
	GetSpellName = function(id) return "Spell" .. id end,
	GetSpellTexture = function() return 1 end,
	GetSpellCooldownDuration = function() return {} end,
}
_G.C_SpellBook = {
	IsSpellKnown = function(id) return id == 75 or id == 2973 end,
	IsSpellKnownOrInSpellBook = function(id) return id == 75 or id == 2973 or id == 1130 end,
	GetSpellBookItemInfo = function() end,
	GetNumSpellBookSkillLines = function() return 2 end,
	GetSpellBookSkillLineInfo = function() end,
}
Stub.auras = { { name = "Aspect of the Hawk", spellId = 13165, duration = 0, expirationTime = 0 }, { name = "Mark of the Wild", spellId = 1126, duration = 1800, expirationTime = 2500 } }
_G.C_UnitAuras = {
	GetAuraDataByIndex = function(_, i)
		if Stub.combat then error("attempt to access a secret aura") end
		return Stub.auras[i]
	end,
	GetPlayerAuraBySpellID = function(id) for _, a in ipairs(Stub.auras) do if a.spellId == id then return a end end return nil end,
	GetAuraDataBySpellName = function() end,
	GetAuraDuration = function() return {} end,
}
_G.C_Secrets = {
	ShouldAurasBeSecret = function() return Stub.combat end,
	ShouldSpellAuraBeSecret = function(id) return id ~= 1130 end,
	ShouldUnitHealthMaxBeSecret = function(u) return u ~= "player" end,
	ShouldUnitPowerBeSecret = function() return false end,
	HasSecretRestrictions = function() return true end,
	ShouldSpellCooldownBeSecret = function() return false end,
	GetSpellAuraSecrecy = function() return 2 end,
	ShouldUnitThreatStateBeSecret = function() return true end,
}
_G.C_SwingTimer = {
	IsTargetWithinSwingRange = function() return nil end,
	EnableRangeCheck = function(swingType, enable)
		if type(swingType) ~= "number" or type(enable) ~= "boolean" then
			error("bad argument #2 to '?' (Usage: C_SwingTimer.EnableRangeCheck(swingType, enable))")
		end
	end,
}
_G.C_TradeSkillUI = { GetRecipeCooldown = function() end }
_G.C_Traits = { GetConfigInfo = function() end }
_G.C_ClassTalents = { GetActiveConfigID = function() end }
_G.C_DateAndTime = { GetServerTimeLocal = function() return Stub.serverTime end }
_G.C_Map = { GetBestMapForUnit = function() return 1 end, GetPlayerMapPosition = function() end }
_G.C_TaxiMap = { GetAllTaxiNodes = function() return {} end }
_G.C_DamageMeter = {}
_G.C_RestrictedActions = {}
_G.C_AddOns = {
	GetAddOnMetadata = function(_, k) if k == "Version" then return "0.1.0" end end,
	GetNumAddOns = function() return 2 end,
	GetAddOnInfo = function(i) return ({ "ForeverProbe", "HunterProbe" })[i], "t", "n", true, nil, "INSECURE" end,
	IsAddOnLoaded = function() return true end,
}
-- a tiny JSON serializer standing in for C_EncodingUtil.SerializeJSON
local function tojson(v, depth)
	depth = depth or 0
	if depth > 20 then return '"..."' end
	local t = rawtype(v)
	if t == "table" then
		local isArr = #v > 0
		local parts = {}
		if isArr then
			for _, x in ipairs(v) do parts[#parts + 1] = tojson(x, depth + 1) end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		for k, x in pairs(v) do parts[#parts + 1] = string.format("%q:%s", tostring(k), tojson(x, depth + 1)) end
		return "{" .. table.concat(parts, ",") .. "}"
	elseif t == "string" then
		return string.format("%q", v)
	else
		return tostring(v)
	end
end
_G.C_EncodingUtil = { SerializeJSON = function(v) return tojson(v) end }

-- timers
_G.C_Timer = {
	After = function(delay, fn) Stub.timers[#Stub.timers + 1] = { at = Stub.time + delay, fn = fn } end,
	NewTicker = function(interval, fn)
		local t = { interval = interval, fn = fn, cancelled = false }
		function t:Cancel() self.cancelled = true end
		Stub.tickers[#Stub.tickers + 1] = t
		return t
	end,
}
function Stub.runTimers()
	local due = Stub.timers
	Stub.timers = {}
	for _, t in ipairs(due) do t.fn() end
end
function Stub.tick()
	for _, t in ipairs(Stub.tickers) do
		if not t.cancelled then t.fn() end
	end
end

-- frames, textures, font strings and animations: enough widget surface for the HUD
_G.GameFontNormal, _G.GameFontNormalLarge, _G.GameFontHighlight = {}, {}, {}

local function newWidget(kind)
	local w = { kind = kind, events = {}, scripts = {}, points = {}, shown = true, text = "", children = {}, alpha = 1, scale = 1 }
	function w:RegisterEvent(ev)
		if Stub.unknownEvents[ev] then error("Attempt to register unknown event \"" .. ev .. "\"") end
		if Stub.forbiddenEvents[ev] then Stub.fire("ADDON_ACTION_FORBIDDEN", "ForeverProbe", "UNKNOWN()") end
		self.events[ev] = true
	end
	function w:UnregisterEvent(ev)
		if Stub.forbiddenEvents[ev] then Stub.fire("ADDON_ACTION_FORBIDDEN", "ForeverProbe", "UNKNOWN()") end
		self.events[ev] = nil
	end
	function w:SetScript(k, fn) self.scripts[k] = fn end
	function w:GetScript(k) return self.scripts[k] end
	function w:SetSize(a, b) self.width, self.height = a, b end
	function w:SetPoint(...) self.points[#self.points + 1] = { ... } end
	function w:ClearAllPoints() self.points = {} end
	function w:SetAllPoints() end
	function w:GetPoint() local p = self.points[1]; if p then return p[1], p[2], p[3], p[4], p[5] end end
	function w:Show() self.shown = true end
	function w:Hide() self.shown = false end
	function w:IsShown() return self.shown end
	function w:SetScale(s) self.scale = s end
	function w:SetAlpha(a) self.alpha = a end
	function w:SetMovable() end
	function w:EnableMouse() end
	function w:RegisterForDrag() end
	function w:SetFrameStrata() end
	function w:SetClampedToScreen() end
	function w:StartMoving() self.moving = true end
	function w:StopMovingOrSizing() self.moving = false; self.points = { { "TOPLEFT", _G.UIParent, "TOPLEFT", 40, -60 } } end
	function w:SetColorTexture(r, g, b, a) self.color = { r, g, b, a } end
	function w:SetVertexColor(r, g, b, a) self.color = { r, g, b, a } end
	function w:SetText(t) self.text = t end
	function w:GetText() return self.text end
	function w:SetTextColor(r, g, b) self.color = { r, g, b } end
	function w:SetJustifyH() end
	function w:SetFontObject() end
	function w:SetFont() end
	function w:CreateTexture() local t = newWidget("Texture"); self.children[#self.children + 1] = t; return t end
	function w:CreateFontString() local t = newWidget("FontString"); self.children[#self.children + 1] = t; return t end
	function w:CreateAnimationGroup()
		local g = { playing = false, plays = 0 }
		function g:CreateAnimation()
			local a = {}
			for _, m in ipairs({ "SetFromAlpha", "SetToAlpha", "SetDuration", "SetOrder", "SetSmoothing" }) do a[m] = function() end end
			return a
		end
		function g:SetLooping() end
		function g:Play() self.playing = true; self.plays = self.plays + 1 end
		function g:Stop() self.playing = false end
		function g:IsPlaying() return self.playing end
		function g:SetScript() end
		return g
	end
	return w
end

_G.CreateFrame = function(kind, name)
	local f = newWidget(kind or "Frame")
	if name then _G[name] = f end
	Stub.frames[#Stub.frames + 1] = f
	return f
end
function Stub.fire(event, ...)
	for _, f in ipairs(Stub.frames) do
		if f.events[event] and f.scripts.OnEvent then
			f.scripts.OnEvent(f, event, ...)
		end
	end
end
_G.hooksecurefunc = function() end

-- print capture
local rawprint = print
_G.print = function(...)
	local parts = {}
	for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
	local line = table.concat(parts, " ")
	Stub.printed[#Stub.printed + 1] = line
	if Stub.echo then rawprint(line) end
end

function Stub.reset()
	Stub.frames, Stub.printed, Stub.timers, Stub.tickers = {}, {}, {}, {}
	Stub.combat = false
	Stub.secretRange = false
end

-- load an addon the way the client does: each file gets (addonName, namespace)
function Stub.loadAddon(dir, name, files)
	local ns = {}
	for _, file in ipairs(files) do
		local chunk, err = loadfile(dir .. "/" .. file)
		assert(chunk, err)
		chunk(name, ns)
	end
	return ns
end

-- serialize a table the way WoW writes SavedVariables, so read-probe.py can be tested
local function wowSerialize(v, indent, out)
	local t = rawtype(v)
	if t == "table" then
		out[#out + 1] = "{\n"
		local keys = {}
		for k in pairs(v) do keys[#keys + 1] = k end
		table.sort(keys, function(a, b)
			if rawtype(a) == rawtype(b) then return a < b end
			return rawtype(a) == "number"
		end)
		for _, k in ipairs(keys) do
			out[#out + 1] = indent .. "\t["
			if rawtype(k) == "string" then out[#out + 1] = string.format("%q", k) else out[#out + 1] = tostring(k) end
			out[#out + 1] = "] = "
			wowSerialize(v[k], indent .. "\t", out)
			out[#out + 1] = (rawtype(k) == "number") and (", -- [" .. k .. "]\n") or ",\n"
		end
		out[#out + 1] = indent .. "}"
	elseif t == "string" then
		out[#out + 1] = string.format("%q", v):gsub("\\\n", "\\n")
	else
		out[#out + 1] = tostring(v)
	end
end
function Stub.writeSavedVariables(path, globals)
	local out = {}
	for name, v in pairs(globals) do
		out[#out + 1] = "\n" .. name .. " = "
		wowSerialize(v, "", out)
		out[#out + 1] = "\n"
	end
	local f = assert(io.open(path, "w"))
	f:write(table.concat(out))
	f:close()
end

return Stub
