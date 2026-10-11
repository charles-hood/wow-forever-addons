-- ForeverProbe/Probe.lua
-- What this measures, every session, without being asked:
--   1. SavedVariables lifecycle: is ForeverProbeDB nil at the main chunk, at
--      ADDON_LOADED, and does a seed or session counter come back on a cold start.
--   2. Build facts: GetBuildInfo, project constants, secret-value toolbox.
--   3. API presence for everything the planned addons will call.
--   4. Event presence (RegisterEvent throws on unknown events on this client).
--   5. Secret-value snapshots out of combat and in combat.
--   6. Lua errors, via seterrorhandler, chained to the previous handler.
-- Everything lands in ForeverProbeDB so scripts/read-probe.py can read it later.

local ADDON, ns = ...
local SRC = "FP"

-- 1. Main chunk observation. SavedVariables are loaded after the files run and
--    before ADDON_LOADED, so nil here is normal; it is recorded for the lifecycle trail.
ns.sv = {
	mainChunk = type(_G.ForeverProbeDB),
	mainChunkChar = type(_G.ForeverProbeCharDB),
}
ns.info("SV", "main chunk: ForeverProbeDB is %s, ForeverProbeCharDB is %s", ns.sv.mainChunk, ns.sv.mainChunkChar)

local DEFAULT_SETTINGS = {
	errors = true,     -- capture Lua errors
	verbose = 1,
	watch = {},        -- event names being logged
}

local probe = {}
ns.probe = probe

------------------------------------------------------------------------
-- helpers
------------------------------------------------------------------------

local function settings()
	local d = _G.ForeverProbeDB
	if type(d) ~= "table" then
		return DEFAULT_SETTINGS
	end
	if type(d.settings) ~= "table" then
		d.settings = {}
	end
	for k, v in pairs(DEFAULT_SETTINGS) do
		if d.settings[k] == nil then
			if type(v) == "table" then
				d.settings[k] = {}
			else
				d.settings[k] = v
			end
		end
	end
	return d.settings
end

local function report()
	local d = _G.ForeverProbeDB
	if type(d) ~= "table" then
		ns.scratchReport = ns.scratchReport or {}
		return ns.scratchReport
	end
	if type(d.report) ~= "table" then
		d.report = {}
	end
	return d.report
end

local function stamp(ts)
	if type(ts) ~= "number" or ts == 0 then
		return "never"
	end
	local ok, s = pcall(date, "%Y-%m-%d %H:%M:%S", ts)
	if ok then
		return s
	end
	return tostring(ts)
end

local function serverTime()
	local ok, t = pcall(GetServerTime)
	if ok and type(t) == "number" then
		return t
	end
	return 0
end

------------------------------------------------------------------------
-- 2. build facts
------------------------------------------------------------------------

function probe.collectBuild()
	local b = { at = serverTime() }
	local ok, version, build, bdate, toc, localized, buildType = pcall(GetBuildInfo)
	if ok then
		b.version, b.build, b.date, b.interface, b.localizedVersion, b.buildType =
			ns.str(version), ns.str(build), ns.str(bdate), ns.str(toc), ns.str(localized), ns.str(buildType)
	else
		b.error = ns.str(version)
	end
	b.projectId = ns.describe(_G.WOW_PROJECT_ID)
	b.projectMainline = ns.describe(_G.WOW_PROJECT_MAINLINE)
	b.projectClassic = ns.describe(_G.WOW_PROJECT_CLASSIC)
	b.isMainline = ns.describe(_G.WOW_PROJECT_ID ~= nil and _G.WOW_PROJECT_ID == _G.WOW_PROJECT_MAINLINE)
	local okx, expansion = ns.call("GetClassicExpansionLevel")
	b.classicExpansionLevel = okx and ns.describe(expansion) or ns.str(expansion)
	b.leExpansionLevelCurrent = ns.describe(_G.LE_EXPANSION_LEVEL_CURRENT)
	b.hasIsSecretValue = _G.issecretvalue ~= nil
	local okr, restr = ns.call("C_Secrets.HasSecretRestrictions")
	b.hasSecretRestrictions = okr and ns.describe(restr) or ns.str(restr)
	local okl, locale = ns.call("GetLocale")
	b.locale = okl and ns.str(locale) or "?"
	local okm, mac = ns.call("IsMacClient")
	b.isMacClient = okm and ns.describe(mac) or "?"
	local okc, scriptErrors = ns.call("GetCVar", "scriptErrors")
	b.scriptErrorsCVar = okc and ns.str(scriptErrors) or "?"
	local okp, portal = ns.call("GetCVar", "portal")
	b.portal = okp and ns.str(portal) or "?"
	local okn, realm = ns.call("GetRealmName")
	b.realm = okn and ns.str(realm) or "?"
	local oku, pname = ns.call("UnitName", "player")
	b.player = oku and ns.describe(pname) or "?"
	local okcl, className, classFile, classId = ns.call("UnitClass", "player")
	if okcl then
		b.class = ns.str(className) .. "/" .. ns.str(classFile) .. "/" .. ns.str(classId)
	end
	local okv, lvl = ns.call("UnitLevel", "player")
	b.level = okv and ns.describe(lvl) or "?"
	local okmd, ver = ns.call("C_AddOns.GetAddOnMetadata", ADDON, "Version")
	b.probeVersion = okmd and ns.str(ver) or "?"
	b.luaVersion = ns.str(_G._VERSION)
	b.loadstringUntainted = ns.describe(_G.loadstring_untainted)

	-- which addons are present and loaded
	local addons = {}
	local okN, n = ns.call("C_AddOns.GetNumAddOns")
	if okN and type(n) == "number" then
		for i = 1, n do
			local oki, name, _, _, loadable, reason = ns.call("C_AddOns.GetAddOnInfo", i)
			local okL, loaded = ns.call("C_AddOns.IsAddOnLoaded", i)
			if oki then
				addons[#addons + 1] = {
					name = ns.str(name),
					loadable = loadable and true or false,
					reason = ns.str(reason),
					loaded = (okL and loaded) and true or false,
				}
			end
		end
	end
	b.addons = addons

	report().build = b
	ns.info(SRC, "build %s (%s) interface %s, project %s, issecretvalue=%s, %s addons (%s loaded)",
		b.version, b.build, b.interface, b.projectId, tostring(b.hasIsSecretValue), #addons, probe.countLoaded(addons))
	return b
end

function probe.countLoaded(addons)
	local c = 0
	for _, a in ipairs(addons or {}) do
		if a.loaded then
			c = c + 1
		end
	end
	return c
end

------------------------------------------------------------------------
-- 3. API presence
------------------------------------------------------------------------

-- "expect" is what the forever-addon-kit measured on build 70009. The probe reports
-- any disagreement so a client change shows up as a one-line diff.
probe.API = {
	-- core globals the probes and planned addons use
	{ "GetBuildInfo" }, { "GetTime" }, { "GetServerTime" }, { "date" },
	{ "issecretvalue" }, { "issecrettable" }, { "canaccessvalue" }, { "scrub" },
	{ "seterrorhandler" }, { "geterrorhandler" }, { "debugstack" },
	{ "CreateFrame" }, { "hooksecurefunc" }, { "InCombatLockdown" }, { "UnitAffectingCombat" },
	{ "UnitExists" }, { "UnitCanAttack" }, { "UnitIsDead" }, { "UnitGUID" }, { "UnitName" },
	{ "UnitHealth" }, { "UnitHealthMax" }, { "UnitPower" }, { "UnitPowerMax" }, { "UnitPowerType" },
	{ "UnitXP" }, { "UnitXPMax" }, { "GetXPExhaustion" }, { "IsResting" }, { "GetMoney" },
	{ "UnitClass" }, { "UnitLevel" }, { "UnitOnTaxi" }, { "CheckInteractDistance" },
	{ "GetInventoryItemID" }, { "GetInventoryItemCount" }, { "GetInventoryItemLink" }, { "UnitRangedDamage" },
	{ "CopyToClipboard" }, { "ReloadUI" }, { "GetCVar" }, { "SetCVar" }, { "CreateMacro" },
	-- namespaces
	{ "C_Secrets.ShouldAurasBeSecret" }, { "C_Secrets.ShouldSpellAuraBeSecret" },
	{ "C_Secrets.ShouldUnitHealthMaxBeSecret" }, { "C_Secrets.ShouldUnitPowerBeSecret" },
	{ "C_Secrets.HasSecretRestrictions" }, { "C_Secrets.ShouldSpellCooldownBeSecret" },
	{ "C_Secrets.GetSpellAuraSecrecy" }, { "C_Secrets.ShouldUnitThreatStateBeSecret" },
	{ "C_Spell.IsSpellInRange" }, { "C_Spell.GetSpellInfo" }, { "C_Spell.GetSpellName" },
	{ "C_Spell.GetSpellTexture" }, { "C_Spell.GetSpellCooldownDuration" },
	{ "C_Item.IsItemInRange" }, { "C_Item.GetItemInfoInstant" }, { "C_Item.GetItemInfo" }, { "C_Item.GetItemCount" },
	{ "C_Container.GetContainerItemInfo" }, { "C_Container.GetContainerNumSlots" }, { "C_Container.ContainerIDToInventoryID" },
	{ "C_UnitAuras.GetAuraDataByIndex" }, { "C_UnitAuras.GetPlayerAuraBySpellID" },
	{ "C_UnitAuras.GetAuraDataBySpellName" }, { "C_UnitAuras.GetAuraDuration" },
	{ "C_SpellBook.IsSpellKnown" }, { "C_SpellBook.IsSpellKnownOrInSpellBook" }, { "C_SpellBook.GetSpellBookItemInfo" },
	{ "C_SpellBook.GetNumSpellBookSkillLines" }, { "C_SpellBook.GetSpellBookSkillLineInfo" },
	{ "C_EncodingUtil.SerializeJSON" }, { "C_AddOns.GetAddOnMetadata" }, { "C_AddOns.GetNumAddOns" },
	{ "C_CVar.GetCVar" }, { "C_CVar.RegisterCVar" }, { "C_Timer.After" }, { "C_Timer.NewTicker" },
	{ "C_SwingTimer.IsTargetWithinSwingRange" }, { "C_SwingTimer.EnableRangeCheck" },
	{ "C_TradeSkillUI.GetRecipeCooldown" }, { "C_Traits.GetConfigInfo" }, { "C_ClassTalents.GetActiveConfigID" },
	{ "C_DateAndTime.GetServerTimeLocal" }, { "C_Map.GetBestMapForUnit" }, { "C_Map.GetPlayerMapPosition" },
	{ "C_TaxiMap.GetAllTaxiNodes" }, { "C_DamageMeter" }, { "C_RestrictedActions" },
	{ "Enum.SecrecyLevel" }, { "Enum.PlayerSwingType" }, { "Enum.ItemClass" }, { "Enum.SpellBookSpellBank" },
	{ "Enum.PowerType" }, { "Enum.ItemQuality" },
	-- FrameXML constants the planned addons will lean on
	{ "NUM_BAG_SLOTS" }, { "INVSLOT_AMMO" }, { "INVSLOT_RANGED" }, { "INVSLOT_MAINHAND" },
	{ "UIParent" }, { "GameTooltip" }, { "Minimap" }, { "SlashCmdList" },
	-- removed on this client according to the kit; "expect = false" means missing is the expected answer
	{ "GetItemInfo", expect = false }, { "GetSpellInfo", expect = false }, { "UnitAura", expect = false },
	{ "UnitBuff", expect = false }, { "GetItemCount", expect = false }, { "GetAmmo", expect = false },
	{ "GetTalentInfo", expect = false }, { "CombatLogGetCurrentEventInfo", expect = false },
	{ "GetContainerItemInfo", expect = false }, { "GetContainerNumSlots", expect = false },
	{ "GetSpecialization", expect = false }, { "GetMerchantItemInfo", expect = false },
	{ "PixelUtil.SetStatusBarValue", expect = false },
	{ "loadstring_untainted", expect = false }, -- nil after load on every client, by design
}

function probe.collectApi()
	local present, missing, surprises = {}, {}, {}
	for _, entry in ipairs(probe.API) do
		local path, expect = entry[1], entry.expect
		if expect == nil then
			expect = true
		end
		local v = ns.resolve(path)
		local okt, t = pcall(type, v)
		local found = okt and v ~= nil
		if found then
			present[#present + 1] = path .. ":" .. ns.str(t)
		else
			missing[#missing + 1] = path
		end
		if found ~= expect then
			surprises[#surprises + 1] = path .. (found and " (present, expected missing)" or " (MISSING, expected present)")
		end
	end
	report().api = { at = serverTime(), present = present, missing = missing, surprises = surprises }
	ns.info(SRC, "api: %s present, %s missing, %s surprises", #present, #missing, #surprises)
	for _, s in ipairs(surprises) do
		ns.warn(SRC, "api surprise: %s", s)
	end
	return present, missing, surprises
end

------------------------------------------------------------------------
-- 4. event presence
------------------------------------------------------------------------

probe.EVENTS = {
	"PLAYER_SWING", "PLAYER_SWING_RANGE_UPDATE", "PLAYER_XP_UPDATE", "BAG_UPDATE_DELAYED",
	"UNIT_COMBAT", "SPELLS_CHANGED", "UNIT_AURA", "ENCOUNTER_END", "BOSS_KILL", "TAXIMAP_OPENED",
	"UNIT_SPELLCAST_SUCCEEDED", "PLAYER_EQUIPMENT_CHANGED", "UNIT_INVENTORY_CHANGED", "PLAYER_LEVEL_UP",
	"UPDATE_EXHAUSTION", "PLAYER_MONEY", "MERCHANT_SHOW",
	"ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN", "LUA_WARNING", "SAVED_VARIABLES_TOO_LARGE",
	"PLAYER_CONTROL_LOST", "PLAYER_CONTROL_GAINED",
	-- expected to be missing on this client
	"UNIT_HEALTH_FREQUENT", "LEARNED_SPELL_IN_TAB",
}

-- Events whose registration is suspected of raising ADDON_ACTION_FORBIDDEN (the
-- "blocked from an action only available to the Blizzard UI" popup). Session 1 on
-- build 70338 showed two forbidden actions during the automatic test; the combat
-- log is the likely one. These run only on "/fp events full".
probe.EVENTS_RESTRICTED = { "COMBAT_LOG_EVENT_UNFILTERED" }

local eventTestFrame

-- ns.step names the action in flight so an ADDON_ACTION_FORBIDDEN that arrives
-- synchronously can be pinned to it.
function probe.testEvents(full)
	eventTestFrame = eventTestFrame or CreateFrame("Frame")
	local present, missing, forbidden = {}, {}, {}
	local list = {}
	for _, ev in ipairs(probe.EVENTS) do
		list[#list + 1] = ev
	end
	if full then
		for _, ev in ipairs(probe.EVENTS_RESTRICTED) do
			list[#list + 1] = ev
		end
	end
	for _, ev in ipairs(list) do
		ns.forbiddenSeen = 0
		ns.step = "RegisterEvent " .. ev
		local ok, err = pcall(eventTestFrame.RegisterEvent, eventTestFrame, ev)
		if ok then
			present[#present + 1] = ev
			ns.step = "UnregisterEvent " .. ev
			pcall(eventTestFrame.UnregisterEvent, eventTestFrame, ev)
		else
			missing[#missing + 1] = ev .. " (" .. ns.str(err) .. ")"
		end
		if ns.forbiddenSeen > 0 then
			forbidden[#forbidden + 1] = ev .. " x" .. ns.forbiddenSeen
		end
	end
	ns.step = nil
	report().events = { at = serverTime(), present = present, missing = missing, forbidden = forbidden }
	ns.info(SRC, "events: %s registrable, %s unknown%s, %s forbidden%s", #present, #missing,
		#missing > 0 and (": " .. table.concat(missing, ", ")) or "",
		#forbidden, #forbidden > 0 and (": " .. table.concat(forbidden, ", ")) or "")
	return present, missing, forbidden
end

------------------------------------------------------------------------
-- 5. secret-value snapshots
------------------------------------------------------------------------

local SNAP_UNITS = { "player", "target", "pet" }
local SNAP_FUNCS = { "UnitHealth", "UnitHealthMax", "UnitPower", "UnitPowerMax", "UnitName", "UnitLevel", "UnitGUID" }

local function callDescribe(path, ...)
	local ok, v = ns.call(path, ...)
	if ok == nil then
		return "missing"
	end
	if not ok then
		return "ERR " .. ns.str(v)
	end
	return ns.describe(v)
end

function probe.snapshotSecrets(reason)
	local okc, inCombat = pcall(InCombatLockdown)
	local snap = { reason = reason, at = serverTime(), combat = (okc and inCombat) and true or false, units = {} }
	for _, unit in ipairs(SNAP_UNITS) do
		local okE, exists = ns.call("UnitExists", unit)
		if okE and exists == true then
			local u = {}
			for _, fn in ipairs(SNAP_FUNCS) do
				u[fn] = callDescribe(fn, unit)
			end
			snap.units[unit] = u
		end
	end
	snap.shouldAurasBeSecret = callDescribe("C_Secrets.ShouldAurasBeSecret")
	snap.hasSecretRestrictions = callDescribe("C_Secrets.HasSecretRestrictions")
	snap.targetHealthMaxSecret = callDescribe("C_Secrets.ShouldUnitHealthMaxBeSecret", "target")
	snap.playerPowerSecret = callDescribe("C_Secrets.ShouldUnitPowerBeSecret", "player", 0)
	snap.targetThreatStateSecret = callDescribe("C_Secrets.ShouldUnitThreatStateBeSecret", "target", "player")

	-- reading one of our own buffs: the kit says this throws in combat
	local okA, aura = ns.call("C_UnitAuras.GetAuraDataByIndex", "player", 1, "HELPFUL")
	if okA == nil then
		snap.auraRead = "missing"
	elseif not okA then
		snap.auraRead = "ERR " .. ns.str(aura)
	elseif aura == nil then
		snap.auraRead = "ok: no aura in slot 1"
	else
		local okN, name = pcall(function() return aura.name end)
		snap.auraRead = "ok: " .. (okN and ns.describe(name) or ("ERR " .. ns.str(name)))
		snap.auraTableSecret = ns.issecrettable(aura)
	end

	report().secrets = report().secrets or {}
	report().secrets[reason] = snap
	local p = snap.units.player or {}
	local t = snap.units.target or {}
	ns.info(SRC, "secrets(%s, combat=%s): player hp=%s hpmax=%s power=%s | target hp=%s hpmax=%s name=%s | aurasSecret=%s auraRead=%s",
		reason, tostring(snap.combat), p.UnitHealth or "-", p.UnitHealthMax or "-", p.UnitPower or "-",
		t.UnitHealth or "-", t.UnitHealthMax or "-", t.UnitName or "-", snap.shouldAurasBeSecret, snap.auraRead)
	return snap
end

------------------------------------------------------------------------
-- 6. error capture
------------------------------------------------------------------------

local inHandler = false
local MAX_ERRORS = 100

local function recordError(msg)
	local d = _G.ForeverProbeDB
	local store = type(d) == "table" and d or ns
	store.errors = store.errors or {}
	store.errorOrder = store.errorOrder or {}
	local key = ns.str(msg)
	local e = store.errors[key]
	if e then
		e.count = e.count + 1
		e.last = serverTime()
		return e
	end
	if #store.errorOrder >= MAX_ERRORS then
		return nil
	end
	local oks, stack = pcall(debugstack, 3, 12, 0)
	e = { msg = key, count = 1, first = serverTime(), last = serverTime(), stack = oks and ns.str(stack) or nil }
	store.errors[key] = e
	store.errorOrder[#store.errorOrder + 1] = key
	return e
end

function probe.enableErrors()
	if ns.errorsHooked then
		return
	end
	local okg, orig = pcall(geterrorhandler)
	ns.origErrorHandler = okg and orig or nil
	local oks, err = pcall(seterrorhandler, function(msg)
		if inHandler then
			return
		end
		inHandler = true
		local e = recordError(msg)
		if e and e.count == 1 then
			ns.err("LUA", "%s", msg)
		end
		inHandler = false
		if ns.origErrorHandler then
			return ns.origErrorHandler(msg)
		end
	end)
	if oks then
		ns.errorsHooked = true
		ns.debug(SRC, "error handler installed (chained to previous: %s)", tostring(ns.origErrorHandler ~= nil))
	else
		ns.warn(SRC, "seterrorhandler failed: %s", err)
	end
end

function probe.disableErrors()
	if not ns.errorsHooked then
		return
	end
	if ns.origErrorHandler then
		pcall(seterrorhandler, ns.origErrorHandler)
	end
	ns.errorsHooked = false
	ns.debug(SRC, "error handler removed")
end

function probe.errorCount()
	local d = _G.ForeverProbeDB
	local store = type(d) == "table" and d or ns
	return store.errorOrder and #store.errorOrder or 0
end

function probe.listErrors(n)
	local d = _G.ForeverProbeDB
	local store = type(d) == "table" and d or ns
	local order = store.errorOrder or {}
	if #order == 0 then
		ns.print("no Lua errors captured this session")
		return
	end
	local from = math.max(1, #order - (n or 10) + 1)
	for i = from, #order do
		local e = store.errors[order[i]]
		if e then
			ns.print("#%s x%s %s", i, e.count, e.msg)
		end
	end
end

------------------------------------------------------------------------
-- event watch
------------------------------------------------------------------------

local watchFrame = CreateFrame("Frame")
local watchCounts = {}

watchFrame:SetScript("OnEvent", function(_, event, ...)
	local c = (watchCounts[event] or 0) + 1
	watchCounts[event] = c
	if c <= 50 or c % 100 == 0 then
		local n = select("#", ...)
		local parts = {}
		for i = 1, n do
			parts[i] = ns.describe((select(i, ...)))
		end
		ns.debug("EV", "%s #%s (%s)", event, c, table.concat(parts, ", "))
	end
end)

function probe.watch(event)
	if not event or event == "" then
		return false
	end
	event = string.upper(event)
	if ns.safeRegister(watchFrame, event, SRC) then
		local w = settings().watch
		w[event] = true
		ns.info(SRC, "watching %s", event)
		return true
	end
	return false
end

function probe.unwatch(event)
	local w = settings().watch
	if event == "all" or event == "ALL" then
		for ev in pairs(w) do
			pcall(watchFrame.UnregisterEvent, watchFrame, ev)
			w[ev] = nil
		end
		ns.info(SRC, "unwatched everything")
		return
	end
	event = string.upper(event or "")
	pcall(watchFrame.UnregisterEvent, watchFrame, event)
	w[event] = nil
	ns.info(SRC, "unwatched %s", event)
end

------------------------------------------------------------------------
-- SavedVariables lifecycle
------------------------------------------------------------------------

local function initDb()
	local sv = ns.sv
	sv.addonLoaded = type(_G.ForeverProbeDB)
	sv.addonLoadedChar = type(_G.ForeverProbeCharDB)
	if sv.addonLoaded == "table" then
		local d = _G.ForeverProbeDB
		sv.seeded = d.seeded and true or false
		sv.seededAt = d.seededAt
		sv.prevSessions = d.sessions
		sv.prevLastSeen = d.lastSeen
		sv.prevLogout = d.lastLogout
		sv.prevBuild = d.lastBuild
	else
		_G.ForeverProbeDB = {}
	end
	if sv.addonLoadedChar == "table" then
		local c = _G.ForeverProbeCharDB
		sv.charSeeded = c.seeded and true or false
		sv.charPrevSessions = c.sessions
	else
		_G.ForeverProbeCharDB = {}
	end

	local d = _G.ForeverProbeDB
	d.sessions = (type(d.sessions) == "number" and d.sessions or 0) + 1
	d.firstSeen = d.firstSeen or serverTime()
	d.lastSeen = serverTime()
	d.seedSeenAt = d.seedSeenAt or (sv.seeded and serverTime() or nil)
	d.history = d.history or {}
	local entry = { session = d.sessions, started = serverTime(), ended = nil, verdict = nil }
	d.history[#d.history + 1] = entry
	while #d.history > 50 do
		table.remove(d.history, 1)
	end
	ns.sessionEntry = entry

	local c = _G.ForeverProbeCharDB
	c.sessions = (type(c.sessions) == "number" and c.sessions or 0) + 1
	c.lastSeen = serverTime()

	ns.verbose = settings().verbose or 1
	local flushed = ns.flushPre()
	ns.info("SV", "ADDON_LOADED: ForeverProbeDB was %s (seeded=%s, prevSessions=%s, prevLogout=%s); ForeverProbeCharDB was %s (prevSessions=%s); session %s; %s early log lines kept",
		sv.addonLoaded, tostring(sv.seeded), sv.prevSessions or "nil", stamp(sv.prevLogout), sv.addonLoadedChar, sv.charPrevSessions or "nil", d.sessions, flushed)
end

function probe.verdict(isInitialLogin, isReloadingUi)
	local sv = ns.sv
	local text
	if isReloadingUi then
		text = "RELOAD: SavedVariables stay in memory across /reload, so this says nothing about disk. Log out fully, relaunch, and read the verdict then."
	elseif not isInitialLogin then
		text = "ZONING: not a login, no verdict."
	elseif sv.addonLoaded ~= "table" then
		text = "NOT LOADED: ForeverProbeDB was nil at ADDON_LOADED on a cold start. Either the client never read the file back, or no file existed yet (run scripts/seed-probe.sh before launching)."
	elseif sv.seeded then
		text = ("LOADED: the seed written by scripts/seed-probe.sh (%s) came back from disk on a cold start."):format(ns.str(sv.seededAt))
	elseif sv.prevSessions then
		text = ("LOADED: session %s on a cold start; the previous session ended %s."):format(
			ns.str(_G.ForeverProbeDB.sessions), stamp(sv.prevLogout))
	else
		text = "LOADED?: the table existed at ADDON_LOADED but carried neither a seed nor a session counter. Read the log."
	end
	local charText
	if isInitialLogin and not isReloadingUi then
		if sv.addonLoadedChar ~= "table" then
			charText = "per-character file: NOT LOADED"
		elseif sv.charSeeded or sv.charPrevSessions then
			charText = "per-character file: LOADED"
		else
			charText = "per-character file: LOADED?"
		end
	end
	ns.svVerdict = text
	if ns.sessionEntry then
		ns.sessionEntry.verdict = text
		ns.sessionEntry.charVerdict = charText
		ns.sessionEntry.reload = isReloadingUi and true or false
	end
	local d = _G.ForeverProbeDB
	if type(d) == "table" and isInitialLogin and not isReloadingUi then
		d.verdicts = d.verdicts or {}
		d.verdicts[#d.verdicts + 1] = { at = serverTime(), text = text, char = charText, build = report().build and report().build.build }
		while #d.verdicts > 50 do
			table.remove(d.verdicts, 1)
		end
	end
	ns.info("SV", "verdict: %s%s", text, charText and (" | " .. charText) or "")
	return text
end

------------------------------------------------------------------------
-- lifecycle events
------------------------------------------------------------------------

local frame = CreateFrame("Frame")
ns.safeRegister(frame, "ADDON_LOADED", SRC)
ns.safeRegister(frame, "PLAYER_LOGIN", SRC)
ns.safeRegister(frame, "PLAYER_ENTERING_WORLD", SRC)
ns.safeRegister(frame, "PLAYER_LOGOUT", SRC)
ns.safeRegister(frame, "PLAYER_REGEN_DISABLED", SRC)
ns.safeRegister(frame, "PLAYER_REGEN_ENABLED", SRC)
ns.safeRegister(frame, "ADDON_ACTION_BLOCKED", SRC)
ns.safeRegister(frame, "ADDON_ACTION_FORBIDDEN", SRC)
ns.safeRegister(frame, "LUA_WARNING", SRC)
ns.safeRegister(frame, "SAVED_VARIABLES_TOO_LARGE", SRC)

local function later(delay, fn)
	local ok = ns.call("C_Timer.After", delay, fn)
	if not ok then
		fn()
	end
end

frame:SetScript("OnEvent", function(_, event, arg1, arg2)
	if event == "ADDON_LOADED" then
		if arg1 == ADDON then
			initDb()
			if settings().errors then
				probe.enableErrors()
			end
			for ev in pairs(settings().watch) do
				ns.safeRegister(watchFrame, ev, SRC)
			end
		else
			ns.trace("SV", "ADDON_LOADED %s", arg1)
		end
	elseif event == "PLAYER_LOGIN" then
		ns.info("SV", "PLAYER_LOGIN: ForeverProbeDB is %s with %s sessions", type(_G.ForeverProbeDB), ns.str(type(_G.ForeverProbeDB) == "table" and _G.ForeverProbeDB.sessions or nil))
		probe.collectBuild()
		if type(_G.ForeverProbeDB) == "table" then
			_G.ForeverProbeDB.lastBuild = report().build and report().build.build
		end
		probe.collectApi()
		probe.testEvents()
	elseif event == "PLAYER_ENTERING_WORLD" then
		ns.info("SV", "PLAYER_ENTERING_WORLD: isInitialLogin=%s isReloadingUi=%s", tostring(arg1), tostring(arg2))
		local text = probe.verdict(arg1, arg2)
		if arg1 or arg2 then
			local b = report().build or {}
			ns.print("v%s on build %s, session %s. SavedVariables %s", b.probeVersion or "?", b.build or "?", ns.str(_G.ForeverProbeDB and _G.ForeverProbeDB.sessions), text)
			ns.print("type /fp for commands; /fp status for the summary")
			later(3, function() probe.snapshotSecrets("login") end)
		end
	elseif event == "PLAYER_LOGOUT" then
		local d = _G.ForeverProbeDB
		if type(d) == "table" then
			d.lastLogout = serverTime()
			if ns.sessionEntry then
				ns.sessionEntry.ended = serverTime()
			end
			d.seeded = nil -- the seed has done its job once it has been seen
		end
		ns.info("SV", "PLAYER_LOGOUT: writing %s log lines, %s errors", ns.logCount(), probe.errorCount())
	elseif event == "PLAYER_REGEN_DISABLED" then
		ns.debug(SRC, "combat started")
		later(1, function() probe.snapshotSecrets("combatStart") end)
	elseif event == "PLAYER_REGEN_ENABLED" then
		ns.debug(SRC, "combat ended")
		later(0.5, function() probe.snapshotSecrets("combatEnd") end)
	elseif event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
		ns.forbiddenSeen = (ns.forbiddenSeen or 0) + 1
		ns.warn(SRC, "%s: addon=%s function=%s during %s", event, arg1, arg2, ns.step or "(no probe step in flight)")
	elseif event == "LUA_WARNING" then
		ns.warn(SRC, "LUA_WARNING: %s", arg1)
	elseif event == "SAVED_VARIABLES_TOO_LARGE" then
		ns.err(SRC, "SAVED_VARIABLES_TOO_LARGE for %s", arg1)
	end
end)

------------------------------------------------------------------------
-- slash commands
------------------------------------------------------------------------

local function status()
	local d = _G.ForeverProbeDB
	local b = report().build or {}
	ns.print("build %s interface %s | session %s | verdict: %s", b.build or "?", b.interface or "?",
		ns.str(type(d) == "table" and d.sessions or nil), ns.svVerdict or "(not yet)")
	local api = report().api
	if api then
		ns.print("api: %s present, %s missing, %s surprises", #api.present, #api.missing, #api.surprises)
	end
	local ev = report().events
	if ev then
		ns.print("events: %s registrable, %s unknown", #ev.present, #ev.missing)
	end
	local w = {}
	for e in pairs(settings().watch) do
		w[#w + 1] = e
	end
	ns.print("errors: %s captured (capture %s) | verbose %s | log %s lines | watching: %s",
		probe.errorCount(), ns.errorsHooked and "on" or "off", ns.verbose, ns.logCount(),
		#w > 0 and table.concat(w, " ") or "nothing")
end

local function menu()
	ns.print("commands:")
	print("  /fp status            summary of this session")
	print("  /fp sv                SavedVariables lifecycle detail")
	print("  /fp build | api | events | secrets   re-run a collector now")
	print("  /fp events full       also try the events suspected of being forbidden")
	print("  /fp errors [list|clear|on|off]")
	print("  /fp watch EVENT | unwatch EVENT|all")
	print("  /fp log [n]           last n log lines (default 20)")
	print("  /fp verbose 0..3      chat verbosity (log keeps everything)")
	print("  /fp scripterrors on|off   the client's own error popups")
	print("  /fp json              serialize the report with C_EncodingUtil")
	print("  /fp clear             drop the log and errors; keep sessions")
	print("  /fp reset             wipe ForeverProbeDB entirely")
	print("  then /reload or log out so the file is written; read it with scripts/read-probe.py")
end

local function handle(msg)
	local cmd, rest = string.match(msg or "", "^%s*(%S*)%s*(.-)%s*$")
	cmd = string.lower(cmd or "")
	if cmd == "" or cmd == "help" then
		menu()
		status()
	elseif cmd == "status" then
		status()
	elseif cmd == "sv" then
		local sv = ns.sv
		ns.print("main chunk: %s / %s", sv.mainChunk, sv.mainChunkChar)
		ns.print("ADDON_LOADED: %s (seeded=%s at %s, prevSessions=%s, prevLogout=%s)", sv.addonLoaded, tostring(sv.seeded), ns.str(sv.seededAt), ns.str(sv.prevSessions), stamp(sv.prevLogout))
		ns.print("per-character: %s (seeded=%s, prevSessions=%s)", sv.addonLoadedChar, tostring(sv.charSeeded), ns.str(sv.charPrevSessions))
		ns.print("verdict: %s", ns.svVerdict or "(not yet)")
	elseif cmd == "build" then
		local b = probe.collectBuild()
		for _, k in ipairs({ "version", "build", "date", "interface", "buildType", "projectId", "projectMainline", "projectClassic", "classicExpansionLevel", "hasIsSecretValue", "hasSecretRestrictions", "locale", "isMacClient", "scriptErrorsCVar", "realm", "player", "class", "level", "luaVersion", "loadstringUntainted" }) do
			ns.print("%s = %s", k, b[k])
		end
	elseif cmd == "api" then
		local present, missing, surprises = probe.collectApi()
		ns.print("missing: %s", #missing > 0 and table.concat(missing, ", ") or "none")
		ns.print("surprises: %s", #surprises > 0 and table.concat(surprises, "; ") or "none")
		ns.print("%s present", #present)
	elseif cmd == "events" then
		probe.testEvents(string.lower(rest or "") == "full")
	elseif cmd == "secrets" then
		probe.snapshotSecrets("manual")
	elseif cmd == "errors" then
		local sub = string.lower(rest or "")
		if sub == "on" then
			settings().errors = true
			probe.enableErrors()
		elseif sub == "off" then
			settings().errors = false
			probe.disableErrors()
		elseif sub == "clear" then
			local d = _G.ForeverProbeDB
			local store = type(d) == "table" and d or ns
			store.errors, store.errorOrder = {}, {}
			ns.print("errors cleared")
		else
			probe.listErrors(tonumber(sub) or 10)
		end
	elseif cmd == "watch" then
		if not probe.watch(rest) then
			ns.print("usage: /fp watch EVENT_NAME")
		end
	elseif cmd == "unwatch" then
		probe.unwatch(rest ~= "" and rest or "all")
	elseif cmd == "log" then
		for _, e in ipairs(ns.tail(tonumber(rest) or 20)) do
			print(("  %s [%s:%s]%s %s"):format(ns.str(e.t), ns.str(e.src), ns.str(e.lvl), e.c and " (combat)" or "", ns.str(e.msg)))
		end
	elseif cmd == "verbose" then
		local n = tonumber(rest)
		if n then
			ns.verbose = n
			settings().verbose = n
		end
		ns.print("verbose %s", ns.verbose)
	elseif cmd == "scripterrors" then
		local v = (string.lower(rest) == "on") and "1" or "0"
		local ok, err = ns.call("SetCVar", "scriptErrors", v)
		ns.print("scriptErrors set to %s (%s)", v, ok and "ok" or ns.str(err))
	elseif cmd == "json" then
		local ok, out = ns.call("C_EncodingUtil.SerializeJSON", report())
		if ok and type(out) == "string" then
			local d = _G.ForeverProbeDB
			if type(d) == "table" then
				d.json = out
			end
			ns.print("report serialized: %s bytes stored in ForeverProbeDB.json", #out)
		else
			ns.print("SerializeJSON failed: %s", ns.str(out))
		end
	elseif cmd == "clear" then
		local d = _G.ForeverProbeDB
		if type(d) == "table" then
			d.log, d.errors, d.errorOrder = {}, {}, {}
		end
		ns.pre = {}
		ns.print("log and errors cleared")
	elseif cmd == "reset" then
		_G.ForeverProbeDB = {}
		_G.ForeverProbeCharDB = {}
		ns.pre = {}
		initDb()
		ns.print("ForeverProbeDB wiped; log out to write the empty file")
	else
		ns.print("unknown command %s", cmd)
		menu()
	end
end

SLASH_FOREVERPROBE1 = "/fp"
SLASH_FOREVERPROBE2 = "/foreverprobe"
SlashCmdList["FOREVERPROBE"] = handle
ns.handleSlash = handle
