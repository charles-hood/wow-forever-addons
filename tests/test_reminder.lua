-- Offline tests for BuffReminder against tests/wowstub.lua.
-- Run: lua tests/test_reminder.lua   (from the repo root)

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

local function labels(f)
	local out = {}
	for _, c in ipairs(f.children) do
		if c.kind == "FontString" and c.shown and c.text ~= "" then
			out[#out + 1] = c.text
		end
	end
	return table.concat(out, ",")
end

local function startSession(savedDb, classFile, buffs, knownSpells)
	Stub.reset()
	Stub.units = { player = true }
	Stub.dead = {}
	Stub.auras = buffs or {}
	Stub.targetAuras = {}
	Stub.knownSpells = knownSpells or {}
	_G.UnitClass = function() return classFile, classFile, 1 end
	_G.BuffReminderDB = nil
	local ns = Stub.loadAddon("addons/BuffReminder", "BuffReminder", { "BuffReminder.lua" })
	_G.BuffReminderDB = savedDb
	Stub.fire("ADDON_LOADED", "BuffReminder")
	Stub.fire("PLAYER_LOGIN")
	Stub.fire("PLAYER_ENTERING_WORLD", true, false)
	Stub.runTimers()
	return ns, _G.BuffReminderFrame
end

local function settle()
	Stub.runTimers()
end

------------------------------------------------------------------
-- hunter with everything up
------------------------------------------------------------------
local hunterKnown = { [13165] = true, [883] = true, [1130] = true }
Stub.units.pet = true
local ns, f = startSession(nil, "HUNTER", { { name = "Aspect of the Hawk" } }, hunterKnown)
Stub.units.pet = true
Stub.fire("UNIT_PET", "player")
settle()
check(f ~= nil and not f:IsShown(), "hidden when aspect and pet are present")

-- aspect drops
Stub.auras = {}
Stub.fire("UNIT_AURA", "player")
settle()
check(f:IsShown() and labels(f) == "Aspect", "aspect missing shows one icon, got " .. labels(f))
check(f.children[2] and f.children[2].texture == 1, "icon texture taken from the spell")

-- pet gone too
Stub.units.pet = nil
Stub.fire("UNIT_PET", "player")
settle()
check(labels(f) == "Aspect,No pet", "aspect and pet missing, got " .. labels(f))
Stub.units.pet = true
Stub.dead.pet = true
Stub.fire("UNIT_PET", "player")
settle()
check(labels(f) == "Aspect,Pet dead", "dead pet labelled, got " .. labels(f))
Stub.dead.pet = nil

-- UNIT_AURA bursts coalesce into one evaluation
local before = #Stub.timers
Stub.fire("UNIT_AURA", "player")
Stub.fire("UNIT_AURA", "player")
Stub.fire("UNIT_AURA", "player")
check(#Stub.timers == before + 1, "three aura events schedule one evaluation")
settle()

-- combat hides, combat end re-evaluates after the delay
Stub.combat = true
Stub.fire("PLAYER_REGEN_DISABLED")
check(not f:IsShown(), "hidden on combat start")
Stub.fire("UNIT_AURA", "player")
local ok, err = pcall(settle)
check(ok and not f:IsShown(), "aura event in combat does not raise and stays hidden: " .. tostring(err))
Stub.combat = false
Stub.fire("PLAYER_REGEN_ENABLED")
check(not f:IsShown(), "still hidden until the post-combat delay")
settle()
check(f:IsShown() and labels(f) == "Aspect", "shown again after combat, got " .. labels(f))

-- secret auras gate
_G.C_Secrets.ShouldAurasBeSecret = function() return true end
ns.evaluate("gate")
check(not f:IsShown(), "hidden when auras are secret")
_G.C_Secrets.ShouldAurasBeSecret = function() return Stub.combat end
ns.evaluate("gate off")
check(f:IsShown(), "shown again when auras are readable")

-- dead player hides
Stub.dead.player = true
ns.evaluate("dead")
check(not f:IsShown(), "hidden while dead")
Stub.dead.player = nil

-- Hunter's Mark check is off by default, on by command, needs a live hostile target
Stub.auras = { { name = "Aspect of the Hawk" } }
ns.evaluate("mark setup")
check(not f:IsShown(), "nothing missing before the mark check")
Stub.units.target = true
Stub.fire("PLAYER_TARGET_CHANGED")
settle()
check(not f:IsShown(), "mark check off by default")
ns.handleSlash("on mark")
check(f:IsShown() and labels(f) == "Hunter's Mark", "mark missing on a hostile target, got " .. labels(f))
Stub.targetAuras = { { name = "Hunter's Mark" } }
Stub.fire("UNIT_AURA", "target")
settle()
check(not f:IsShown(), "mark present clears it")
Stub.units.target = nil
Stub.targetAuras = {}
ns.handleSlash("off mark")
check(BuffReminderDB.checks.mark == false, "check toggle saved")

-- unknown spell never nags
ns, f = startSession(nil, "HUNTER", {}, { [883] = true })
Stub.units.pet = true
Stub.fire("UNIT_PET", "player")
settle()
check(not f:IsShown(), "aspect not known yet: no nag")

-- slash commands
for _, cmd in ipairs({ "", "status", "test", "lock", "unlock", "reset", "scale 1.3", "scale 5", "debug on", "debug off", "on", "off", "on", "on bogus", "off aspect", "on aspect" }) do
	local okc, e = pcall(ns.handleSlash, cmd)
	check(okc, "/br " .. cmd .. " raised: " .. tostring(e))
end
ns.handleSlash("test")
check(f:IsShown() and labels(f) == "Pet", "test shows every active check, got " .. labels(f))
settle()
check(not f:IsShown(), "test mode ends after its timer")

------------------------------------------------------------------
-- other classes
------------------------------------------------------------------
ns, f = startSession(nil, "MAGE", {}, { [1459] = true, [168] = true })
check(labels(f) == "Arcane Intellect,Armor", "mage with nothing up, got " .. labels(f))
Stub.auras = { { name = "Arcane Brilliance" }, { name = "Ice Armor" } }
Stub.fire("UNIT_AURA", "player")
settle()
check(not f:IsShown(), "group buff and a higher armor satisfy the mage checks")

ns, f = startSession(nil, "DRUID", {}, { [1126] = true, [467] = true })
check(labels(f) == "Mark of the Wild", "druid: thorns is off by default, got " .. labels(f))

ns, f = startSession(nil, "PALADIN", { { name = "Blessing of Might" } }, { [19740] = true })
check(not f:IsShown(), "any blessing satisfies the paladin check")

ns, f = startSession(nil, "WARRIOR", {}, { [6673] = true })
check(not f:IsShown(), "warrior shout is off by default")
ns.handleSlash("on shout")
check(f:IsShown() and labels(f) == "Battle Shout", "warrior shout on request")

ns, f = startSession(nil, "ROGUE", {}, {})
check(not f:IsShown(), "no checks for a rogue, nothing shown")
local okr, er = pcall(ns.handleSlash, "status")
check(okr, "/br status for a rogue: " .. tostring(er))

-- saved settings come back
Stub.units.pet = true
ns, f = startSession({ scale = 1.3, locked = false, checks = { aspect = false } }, "HUNTER", {}, hunterKnown)
check(f.scale == 1.3, "saved scale applied")
check(labels(f) == "Pet" or labels(f) == "No pet", "aspect check stays off from saved settings, got " .. labels(f))

io.write(string.format("%d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
