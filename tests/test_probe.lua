-- Offline tests for ForeverProbe and HunterProbe against tests/wowstub.lua.
-- Run: lua tests/test_probe.lua   (from the repo root)

package.path = "./tests/?.lua;" .. package.path
local Stub = require("wowstub")
Stub.echo = os.getenv("ECHO") == "1"

local passed, failed = 0, 0
local function check(cond, msg)
	if cond then
		passed = passed + 1
	else
		failed = failed + 1
		io.stderr:write("FAIL: " .. msg .. "\n")
	end
end
local function printedContains(s)
	for _, line in ipairs(Stub.printed) do
		if line:find(s, 1, true) then return true end
	end
	return false
end
local function logContains(s)
	for _, e in ipairs(ForeverProbeDB.log or {}) do
		if tostring(e.msg):find(s, 1, true) then return true end
	end
	return false
end

local FP_FILES = { "Log.lua", "Probe.lua" }

-- One full client session: files load with the DB global nil, then the client
-- sets the SavedVariables globals, then ADDON_LOADED, PLAYER_LOGIN, PLAYER_ENTERING_WORLD.
local function startSession(savedDb, savedCharDb, isReload)
	Stub.reset()
	_G.ForeverProbeDB, _G.ForeverProbeCharDB, _G.HunterProbeDB = nil, nil, nil
	local ns = Stub.loadAddon("addons/ForeverProbe", "ForeverProbe", FP_FILES)
	check(ns.sv.mainChunk == "nil", "DB global is nil at the main chunk")
	_G.ForeverProbeDB, _G.ForeverProbeCharDB = savedDb, savedCharDb
	Stub.fire("ADDON_LOADED", "ForeverProbe")
	Stub.fire("PLAYER_LOGIN")
	Stub.fire("PLAYER_ENTERING_WORLD", not isReload, isReload and true or false)
	Stub.time = Stub.time + 5
	Stub.runTimers()
	return ns
end

------------------------------------------------------------------
-- A. cold start with a seeded file
------------------------------------------------------------------
local ns = startSession({ seeded = true, seededAt = "2026-10-10T20:00:00" }, { seeded = true }, false)
check(ns.svVerdict:find("^LOADED: the seed") ~= nil, "seeded cold start gives LOADED verdict, got: " .. tostring(ns.svVerdict))
check(ForeverProbeDB.sessions == 1, "session counter starts at 1")
check(ForeverProbeCharDB.sessions == 1, "per-character session counter starts at 1")
check(#ForeverProbeDB.history == 1 and ForeverProbeDB.history[1].verdict == ns.svVerdict, "history entry carries the verdict")
check(ForeverProbeDB.history[1].charVerdict == "per-character file: LOADED", "per-character verdict LOADED, got " .. tostring(ForeverProbeDB.history[1].charVerdict))
check(ForeverProbeDB.report.build.interface == "16001", "build facts collected")
check(ForeverProbeDB.report.build.isMainline == "true", "project id comparison recorded")
check(#ForeverProbeDB.report.api.surprises == 0, "no API surprises against the stub: " .. table.concat(ForeverProbeDB.report.api.surprises, "; "))
check(#ForeverProbeDB.report.events.missing == 2, "two unknown events detected")
check(#ForeverProbeDB.report.events.forbidden == 0, "automatic event test raises no forbidden action")
ns.handleSlash("events full")
check(#ForeverProbeDB.report.events.forbidden == 1 and ForeverProbeDB.report.events.forbidden[1] == "COMBAT_LOG_EVENT_UNFILTERED x2",
	"full event test pins the forbidden event, got " .. tostring(ForeverProbeDB.report.events.forbidden[1]))
check(logContains("during RegisterEvent COMBAT_LOG_EVENT_UNFILTERED"), "forbidden warning names the step in flight")
check(logContains("main chunk: ForeverProbeDB is nil"), "main-chunk line survived the pre-buffer flush")
check(ForeverProbeDB.report.secrets.login ~= nil, "login secrets snapshot taken after the timer")
check(ForeverProbeDB.report.secrets.login.units.player.UnitHealth == "100", "out of combat health is plain")
check(printedContains("SavedVariables LOADED"), "login banner printed the verdict")

-- error capture
local handler = geterrorhandler()
handler("Interface/AddOns/X/X.lua:12: attempt to call a nil value")
handler("Interface/AddOns/X/X.lua:12: attempt to call a nil value")
handler("other error")
check(ns.probe.errorCount() == 2, "two unique errors captured")
check(ForeverProbeDB.errors["other error"].count == 1 and ForeverProbeDB.errors["Interface/AddOns/X/X.lua:12: attempt to call a nil value"].count == 2, "error counts dedupe")
check(Stub.lastBlizzardError == "other error", "errors chain to the previous handler")

-- error classification and attribution for the porting report
local h = geterrorhandler()
h("Interface/AddOns/OldBags/Core.lua:88: attempt to call a nil value (global 'GetContainerItemInfo')")
h("Interface/AddOns/OldBags/Core.lua:12: Frame:RegisterEvent(): Attempt to register unknown event \"UNIT_HEALTH_FREQUENT\"")
h("Interface/AddOns/Meter/Threat.lua:650: attempt to perform boolean test on local 'isTanking' (a secret boolean value)")
h("Interface/AddOns/Meter/Threat.lua:20: attempt to call a nil value (field 'GetSpellInfo')")
h("some unattributed thing went wrong")
local e1 = ForeverProbeDB.errors["Interface/AddOns/OldBags/Core.lua:88: attempt to call a nil value (global 'GetContainerItemInfo')"]
check(e1 and e1.addon == "OldBags" and e1.kind == "missing-api" and e1.detail == "GetContainerItemInfo", "missing API call classified and attributed")
local e2 = ForeverProbeDB.errors["Interface/AddOns/OldBags/Core.lua:12: Frame:RegisterEvent(): Attempt to register unknown event \"UNIT_HEALTH_FREQUENT\""]
check(e2 and e2.kind == "unknown-event" and e2.detail == "UNIT_HEALTH_FREQUENT", "unknown event classified")
local e3 = ForeverProbeDB.errors["Interface/AddOns/Meter/Threat.lua:650: attempt to perform boolean test on local 'isTanking' (a secret boolean value)"]
check(e3 and e3.kind == "secret-value" and e3.detail == "boolean" and e3.addon == "Meter", "secret value error classified")
local e5 = ForeverProbeDB.errors["some unattributed thing went wrong"]
check(e5 and e5.addon == "unknown" and e5.kind == "other", "unattributed error falls back to unknown")
Stub.fire("ADDON_ACTION_FORBIDDEN", "Meter", "CastSpellByName()")
Stub.fire("ADDON_ACTION_FORBIDDEN", "Meter", "CastSpellByName()")
check(ForeverProbeDB.report.actions.Meter["ADDON_ACTION_FORBIDDEN CastSpellByName()"] == 2, "forbidden actions counted per addon")

-- tracer: nil-global lookups attributed by stack
_G.debugstack = function() return "Interface/AddOns/OldBags/Core.lua:40: in function <Interface/AddOns/OldBags/Core.lua:38>" end
check(ns.probe.setTrace(true), "tracer installs")
local _ = _G.GetItemInfoNope
local _ = _G.GetItemInfoNope
local _ = _G.UnitAuraNope
check(ForeverProbeDB.report.nilGlobals.OldBags.count == 3 and ForeverProbeDB.report.nilGlobals.OldBags.names.GetItemInfoNope.n == 2, "nil lookups counted per addon and name")
_G.debugstack = function() return "Interface/AddOns/Blizzard_UIParent/UIParent.lua:1: in main chunk" end
local _ = _G.SomeBlizzardCheck
check(ForeverProbeDB.report.nilGlobals.Blizzard_UIParent == nil, "Blizzard lookups not recorded")
ns.probe.setTrace(false)
check(getmetatable(_G) == nil, "tracer removed the metatable")
_G.debugstack = function() return "stack line 1\nstack line 2" end
local _ = _G.AfterTraceNope
check(ForeverProbeDB.report.nilGlobals.OldBags.count == 3, "no counting after the tracer is off")

-- the chat report runs and stores a per-addon structure
Stub.printed = {}
local okp, perr = pcall(ns.handleSlash, "port")
check(okp, "/fp port raised: " .. tostring(perr))
local port = ForeverProbeDB.report.port
check(port and port.addons.OldBags and #port.addons.OldBags.errors == 2 and port.addons.OldBags.nilGlobals.count == 3, "port report aggregates errors and nil globals per addon")
check(port.addons.Meter and port.addons.Meter.actions["ADDON_ACTION_FORBIDDEN CastSpellByName()"] == 2, "port report carries forbidden actions")
check(port.addons.ForeverProbe and port.addons.ForeverProbe.loaded == true, "port report carries load state from the addon list")
local joined = table.concat(Stub.printed, "\n")
check(joined:find("OldBags", 1, true) and joined:find("missing-api: GetContainerItemInfo x1", 1, true), "chat report names the missing API")
ns.handleSlash("errors clear")

-- combat snapshot with secret values must not throw
Stub.combat = true
Stub.fire("PLAYER_REGEN_DISABLED")
Stub.time = Stub.time + 2
Stub.runTimers()
local cs = ForeverProbeDB.report.secrets.combatStart
check(cs ~= nil and cs.combat == true, "combatStart snapshot exists")
check(cs.units.player.UnitHealth == "<secret number>", "secret health described, got " .. tostring(cs and cs.units.player.UnitHealth))
check(cs.auraRead:find("^ERR") ~= nil, "in-combat aura read recorded as an error, got " .. tostring(cs.auraRead))
check(cs.units.target.UnitName == "<secret number>" or cs.units.target.UnitName:find("secret"), "secret target name described")
Stub.combat = false
Stub.fire("PLAYER_REGEN_ENABLED")
Stub.runTimers()
check(ForeverProbeDB.report.secrets.combatEnd ~= nil, "combatEnd snapshot exists")

-- every slash command runs without raising
for _, cmd in ipairs({ "", "help", "status", "sv", "build", "api", "events", "secrets", "errors", "errors list", "errors 3",
	"watch PLAYER_XP_UPDATE", "watch UNIT_HEALTH_FREQUENT", "unwatch PLAYER_XP_UPDATE", "unwatch all", "log", "log 5",
	"port", "trace", "trace on", "trace off",
	"verbose 3", "verbose 1", "scripterrors on", "scripterrors off", "json", "bogus", "errors clear", "clear" }) do
	local ok, err = pcall(ns.handleSlash, cmd)
	check(ok, "/fp " .. cmd .. " raised: " .. tostring(err))
end
check(type(ForeverProbeDB.json) == "string" and #ForeverProbeDB.json > 100, "json export stored")
check(ForeverProbeDB.settings.watch.PLAYER_XP_UPDATE == nil, "unwatch cleared the setting")

-- event watch logs args with secrets described
ns.handleSlash("watch UNIT_COMBAT")
Stub.fire("UNIT_COMBAT", "target", "WOUND", "", Stub.SECRET, 1)
check(logContains("UNIT_COMBAT #1 (\"target\", \"WOUND\", \"\", <secret number>, 1)"), "watched event args logged with secrecy")

-- ring buffer
for i = 1, 3500 do ns.trace("T", "line %s", i) end
check(#ForeverProbeDB.log <= 3000 and #ForeverProbeDB.log >= 2500, "ring buffer trimmed, size " .. #ForeverProbeDB.log)
check(ns.fmt("%d items", "<secret>") == "%d items [<secret>]", "format fallback never raises")
check(ns.describe(Stub.SECRET) == "<secret number>", "describe secret")
check(ns.describe({ __secret = true }) == "<secret table>", "describe secret table")
check(ns.describe("x") == '"x"' and ns.describe(nil) == "nil" and ns.describe(true) == "true", "describe plain values")

-- logout writes the end of session
Stub.serverTime = Stub.serverTime + 600
Stub.fire("PLAYER_LOGOUT")
check(ForeverProbeDB.lastLogout == Stub.serverTime and ForeverProbeDB.history[1].ended == Stub.serverTime, "logout stamped")
check(ForeverProbeDB.seeded == nil, "seed cleared after it was seen")
local savedA, savedCharA = ForeverProbeDB, ForeverProbeCharDB

-- write it in WoW's SavedVariables format for the Python reader test
os.execute("mkdir -p tests/out")
Stub.writeSavedVariables("tests/out/ForeverProbe.lua", { ForeverProbeDB = savedA })

------------------------------------------------------------------
-- B. second cold start: the counter from A comes back
------------------------------------------------------------------
Stub.serverTime = Stub.serverTime + 3600
ns = startSession(savedA, savedCharA, false)
check(ns.svVerdict:find("^LOADED: session 2") ~= nil, "second cold start reports session 2, got: " .. tostring(ns.svVerdict))
check(#ForeverProbeDB.verdicts == 2, "verdict history has two entries")
check(#ForeverProbeDB.history == 2, "session history has two entries")
check(ForeverProbeDB.errorOrder ~= nil, "errors table carried over")

------------------------------------------------------------------
-- C. reload
------------------------------------------------------------------
ns = startSession(ForeverProbeDB, ForeverProbeCharDB, true)
check(ns.svVerdict:find("^RELOAD") ~= nil, "reload verdict, got: " .. tostring(ns.svVerdict))
check(ForeverProbeDB.history[#ForeverProbeDB.history].reload == true, "history marks reload")

------------------------------------------------------------------
-- D. cold start with nothing on disk
------------------------------------------------------------------
ns = startSession(nil, nil, false)
check(ns.svVerdict:find("^NOT LOADED") ~= nil, "nil DB on a cold start is NOT LOADED, got: " .. tostring(ns.svVerdict))
check(ForeverProbeDB.sessions == 1, "fresh DB created")
check(ForeverProbeDB.history[1].charVerdict == "per-character file: NOT LOADED", "per-character NOT LOADED")

------------------------------------------------------------------
-- E. HunterProbe on top of a live ForeverProbe
------------------------------------------------------------------
ns = startSession({ sessions = 3 }, { sessions = 3 }, false)
Stub.units.pet = true
local hp = Stub.loadAddon("addons/HunterProbe", "HunterProbe", { "HunterProbe.lua" })
Stub.fire("ADDON_LOADED", "HunterProbe")
Stub.fire("PLAYER_ENTERING_WORLD", true, false)
Stub.time = Stub.time + 5
Stub.runTimers()
check(HunterProbeDB.swing == true and HunterProbeDB.range == true, "hunter defaults")
check(logContains("range items cached: 20 30 | requested: 5 10 15 25 35 40"), "range items warmed at login")
check(logContains("range sampling on"), "range sampling starts at login")
check(logContains("swing logging on"), "swing logging enabled at login")
check(logContains("EnableRangeCheck 0:ok 2:ok"), "EnableRangeCheck called with (swingType, enable)")
check(logContains("auras(login)"), "login aura report logged")
for _, cmd in ipairs({ "", "status", "range", "ammo", "auras", "pet", "swing off", "swing on", "range on", "range off", "bogus" }) do
	local ok, err = pcall(hp.handleSlash, cmd)
	check(ok, "/hp " .. cmd .. " raised: " .. tostring(err))
end
check(HunterProbeDB.lastAmmo and HunterProbeDB.lastAmmo.total == 257, "bag projectile total summed, got " .. tostring(HunterProbeDB.lastAmmo and HunterProbeDB.lastAmmo.total))
check(HunterProbeDB.lastAmmo.count == "143", "ammo slot count read")
check(#HunterProbeDB.lastAmmo.quivers == 1, "quiver detected")
check(HunterProbeDB.lastRange and HunterProbeDB.lastRange.zone == "RANGED", "range classification RANGED, got " .. tostring(HunterProbeDB.lastRange and HunterProbeDB.lastRange.zone))
check(#HunterProbeDB.lastAuras.lines == 2, "two auras listed")
check(logContains("pet watch on (UNIT_HAPPINESS=true, PET_UI_UPDATE=true, UNIT_PET=true)"), "pet events registered at login")
check(logContains("pet(login): pet \"Kobold\" (\"Bear\", L12, dead=false): happiness/dmg%/loyaltyRate=3, 125, 10 | loyalty=\"Best Friend\""), "pet sample logged at login")
check(logContains("foods={Meat, Fish}"), "food types joined")
check(logContains("pet food: 1 of 4 bag items edible"), "edible bag item found")
check(HunterProbeDB.lastPet and HunterProbeDB.lastPet.happiness == "3, 125, 10", "pet sample stored")
Stub.pet.happiness = 2
Stub.fire("UNIT_HAPPINESS", "pet")
check(logContains("UNIT_HAPPINESS #1 unit=\"pet\" -> pet \"Kobold\""), "happiness event logged with a fresh sample")
check(logContains("happiness/dmg%/loyaltyRate=2, 125, 10"), "happiness change visible in the sample")
Stub.combat = true
Stub.secretPet = true
local okp, perr = pcall(hp.handleSlash, "pet")
check(okp, "/hp pet with secret answers does not raise: " .. tostring(perr))
check(logContains("happiness/dmg%/loyaltyRate=<secret number>, <secret number>, <secret number>"), "secret happiness described")
Stub.combat = false
Stub.secretPet = false
Stub.units.pet = nil
Stub.fire("UNIT_PET", "player")
check(logContains("UNIT_PET: pet: none"), "pet loss sampled")
Stub.units.pet = true

-- sampling logs transitions only
hp.handleSlash("range on")
Stub.tick(); Stub.tick()
Stub.rangeAnswers[75] = false
Stub.interact[3] = true
Stub.tick(); Stub.tick()
Stub.units.target = nil
Stub.tick()
Stub.units.target = true
hp.handleSlash("range off")
local changes = 0
for _, e in ipairs(ForeverProbeDB.log) do
	if tostring(e.msg):find("range change", 1, true) then changes = changes + 1 end
end
check(changes == 2, "two range transitions logged, got " .. changes)
check(logContains("zone=DEAD ZONE (i3 fallback)"), "dead zone via interact fallback while the 35 yd item is uncached")
Stub.cachedItems[18904] = true
hp.handleSlash("range on")
Stub.tick()
hp.handleSlash("range off")
check(logContains("zone=DEAD ZONE auto=false i3=true"), "dead zone via the 35 yd item once cached")
check(logContains("target lost"), "target loss logged")

-- combat with secret range answers must not throw
Stub.combat = true
Stub.secretRange = true
Stub.fire("PLAYER_REGEN_DISABLED")
Stub.time = Stub.time + 2
Stub.runTimers()
check(logContains("zone=UNKNOWN (<secret"), "secret range answer classified UNKNOWN without raising")
check(logContains("auras(combatStart)"), "combat aura report logged")
Stub.fire("PLAYER_SWING", 2.6, 0)
Stub.fire("PLAYER_SWING_RANGE_UPDATE", 0, Stub.SECRET, false)
check(logContains("PLAYER_SWING #1 duration=2.6 type=0"), "swing event logged")
check(logContains("isInRange=<secret number> checksRange=false"), "swing range update logged with secrecy")
Stub.combat = false
Stub.fire("PLAYER_REGEN_ENABLED")
Stub.runTimers()
Stub.ammo.count = 140
Stub.fire("BAG_UPDATE_DELAYED")
check(logContains("ammo count 143 -> 140"), "ammo change logged")
Stub.fire("PLAYER_EQUIPMENT_CHANGED", 0, true)
Stub.fire("PLAYER_TARGET_CHANGED")
check(logContains("target changed:"), "target change logged")

io.write(string.format("%d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
