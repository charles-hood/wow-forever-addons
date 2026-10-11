Title: Findings re-checked on build 1.60.1.70338 (macOS): several rows changed

Thanks for the kit. Its findings table was the starting point for a small set of
probe addons I ran on the Mac client this week, and the current build answers a
few rows differently from 70009. Everything below was measured in game on
build 1.60.1.70338 (client date Oct 9 2026), macOS 27, interface 16001, on a
level 16 hunter in open-world combat. The probe addons are at
https://github.com/charles-hood/wow-forever-addons (ForeverProbe and
HunterProbe, MIT); they log every measurement into SavedVariables, so any row
below can be re-run on another build in one session. Happy to share the raw
session logs if useful.

## Rows that changed

**SavedVariables are loaded again.** Three consecutive cold starts: the second
and third came up with the previous session's counter and logout timestamp, for
both the account-wide `## SavedVariables` table and the per-character
`## SavedVariablesPerCharacter` table. The main chunk still sees nil (normal);
the tables are present at ADDON_LOADED. The sv_bridge workaround should no
longer be needed on this build.

**`WOW_PROJECT_ID` is 18.** Not `WOW_PROJECT_MAINLINE` (1) and not
`WOW_PROJECT_CLASSIC` (2). Any addon keying "is this the modern engine" off a
project-id comparison guesses wrong in both directions. `issecretvalue ~= nil`
or the interface number are the safer tests.

**Player health and power are secret out of combat too.** Sampled three seconds
after PLAYER_ENTERING_WORLD with no target and no combat: `UnitHealth("player")`
and `UnitPower("player")` were secret, `UnitHealthMax` and `UnitPowerMax` were
plain. Same for the pet. For a creature target, `UnitHealth`, `UnitHealthMax`,
`UnitPower` and `UnitPowerMax` were secret before, during and after the fight (a
dead boar's values stayed secret). The table's "health is secret in combat"
row understates it: on 70338 current health is secret always, max values for
the player and pet are plain.

**Item range checks answer once the item is cached.** The table says three
LibRangeCheck items (20, 30, 35 yards) answer and the rest return nil. On 70338
every band I tried (5, 10, 15, 20, 25, 30, 35, 40 yard harm items from
LibRangeCheck-3.0) returned nil until the client had cached the item, then
returned plain true/false in combat. Calling `C_Item.RequestLoadItemDataByID`
for each item at login makes them all answer from the first sample. The nil
answers in the table are probably uncached items rather than closed checks.

**Registering `COMBAT_LOG_EVENT_UNFILTERED` is a forbidden action.** It raises
ADDON_ACTION_FORBIDDEN (the "blocked from an action only available to the
Blizzard UI" popup) twice during a RegisterEvent/UnregisterEvent pair, with
the function reported as UNKNOWN(). Removing that one registration from my
probe took the count from two to zero. Worth a line next to the restricted combat log
row, since an addon that registers it defensively will throw the popup at every
login.

**`C_SwingTimer.EnableRangeCheck` takes `(swingType, enable)`.** Calling it with
a single boolean errors with "bad argument #2 ... Usage:
C_SwingTimer.EnableRangeCheck(swingType, enable)". With the right arguments it
succeeds for swing types 0 and 2, after which PLAYER_SWING_RANGE_UPDATE fires
once per type at login with checksRange = false and never again, and
IsTargetWithinSwingRange stays nil. So the conclusion in the table (closed to
addons) holds; only the call shape differs.

## Rows confirmed on 70338

- Interface 16001, `_VERSION` "Lua 5.1", Retail API surface. Every removed
  global I checked is missing here too (`GetItemInfo`, `GetSpellInfo`,
  `UnitAura`, `UnitBuff`, `GetItemCount`, `GetAmmo`, `GetTalentInfo`,
  `CombatLogGetCurrentEventInfo`, `GetContainerItemInfo`, `GetContainerNumSlots`,
  `GetSpecialization`, `GetMerchantItemInfo`, `PixelUtil.SetStatusBarValue`,
  `loadstring_untainted`).
- RegisterEvent on an unknown event throws: `Frame:RegisterEvent(): Attempt to
  register unknown event "UNIT_HEALTH_FREQUENT"`, same for LEARNED_SPELL_IN_TAB.
- Auras: readable out of combat; in combat `C_UnitAuras.GetAuraDataByIndex`
  throws `Auras cannot be accessed when secret while tainted by '<addon>'`.
  `C_Secrets.ShouldAurasBeSecret()` flipped exactly with combat.
- Spell range checks are plain in combat. Raptor Strike (0-0 range) answers true
  at 20+ yards, as the table warns.
- PLAYER_SWING fires per auto attack: swingType 2 with the ranged speed for Auto
  Shot, swingType 0 with the melee speed in melee.

## New, in case it is useful for the table

- Dead zone, measured by walking a live mob from melee to range and back: Auto
  Shot (75) answers false inside the dead zone and beyond 35 yards, true
  between. "Auto Shot false and the 35-yard item true" is the dead zone; "Auto
  Shot false and the 35-yard item false" is out of range. CheckInteractDistance
  index 3 disagreed with Auto Shot for one sample near 10 yards, so it is only a
  fallback.
- Wing Clip (2974) behaves as a real 5-yard melee check: true in melee, false at
  range, flickering as the mob moves. Unlike Raptor Strike it is usable.
- `GetInventoryItemCount("player", 0)` returns the equipped ammo total and
  drops per shot, with BAG_UPDATE_DELAYED firing each time. The ammo item sits in
  inventory slot 0 as before.
- Character saves are under a numeric realm folder
  (`WTF/Account/<acct>/70/<character>/` for "Classic Beta PvE 2"), not under the
  realm display name.

Happy to turn any of this into a PR against the table if you would rather have
it that way, or to re-run a specific probe if you want a row double-checked.
