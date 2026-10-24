# WoW: Forever addons, client probes, and a Mac dev loop

Lua addons for the World of Warcraft: Forever beta (interface 16001, the Retail
12.x engine with secret values), plus probe addons that measure what the live
client actually allows: SavedVariables, secret values in and out of combat,
range checks, pet happiness, forbidden actions, and a per-addon porting report
for any third-party addon you drop in. Developed on macOS against the
client at `/Applications/World of Warcraft/_classic_beta_`, with an offline
test harness so addons can be checked without launching the game.

Measured client facts are in [CLAUDE.md](CLAUDE.md) under "Measured on this
Mac". Addons: **HunterHUD** (dead zone and range light, ammo counter),
**BuffReminder** (missing self-buffs, pet, pet food, Aspect), **ForeverProbe**
and **HunterProbe** (the measurement tools).

The first two addons are probes. They exist to answer, from the live client, the
questions every later addon depends on: whether SavedVariables come back from
disk, which API calls and events exist on the current build, what becomes a
secret value in combat, and what the planned hunter addon can read about range,
ammo and auras. Everything they measure is written into SavedVariables so it can
be read from disk after a session with `scripts/read-probe.py`.

The addons built on those answers so far: **HunterHUD**, a dead-zone and range
light plus an ammo counter, and **BuffReminder**, out-of-combat icons for
missing self-buffs. Client facts measured so far are collected in `CLAUDE.md`
under "Measured on this Mac".

## Layout

```
addons/ForeverProbe/     platform probe: SavedVariables lifecycle, build facts, API and
                         event presence, secret-value snapshots, Lua error capture,
                         event watch, ring-buffer log shared by other probes   /fp
addons/HunterProbe/      range and dead zone, ammo, auras, swing events, pet happiness  /hp
addons/HunterHUD/        hunter HUD: range light, dead zone, melee dot, ammo counter      /hh
addons/BuffReminder/     out-of-combat icons for missing self-buffs, pet, Aspect           /br
scripts/deploy.sh        symlink (or --copy) the addons into the client
scripts/seed-probe.sh    pre-seed ForeverProbe's SavedVariables files for the cold-start test
scripts/read-probe.py    parse the SavedVariables file and print the report and log
scripts/fetch-types.sh   download the client API dump and LSP types, regenerate .luacheckrc
scripts/lint.sh          luac syntax check plus luacheck
tests/                   offline tests: a WoW API stub drives both addons end to end
types/                   (gitignored) fetched API dump and Lua LSP definitions
```

## Quick start

```bash
scripts/fetch-types.sh        # once: API dump, LSP types, .luacheckrc
tests/run.sh                  # lint + offline tests + reader check
scripts/deploy.sh             # symlink addons into the client
scripts/seed-probe.sh         # with the game closed: seed the SavedVariables files
```

Then launch the beta, enable **ForeverProbe**, **HunterProbe**, **HunterHUD**
and **BuffReminder** on the character-select AddOns screen, and log in. ForeverProbe prints the
SavedVariables verdict in chat on login. Play a little (target something, fight
something, open bags), then log out fully. Read what happened:

```bash
python3 -I scripts/read-probe.py            # summary and the last 40 log lines
python3 -I scripts/read-probe.py -n 300 --src HP
python3 -I scripts/read-probe.py --json > session.json
```

## HunterHUD

A 170 by 36 pixel frame, hidden on non-hunters. On the left a light: green with
IN RANGE, red with DEAD ZONE, grey with OUT OF RANGE, dark with no live hostile
target. A small white dot beside it means Wing Clip is in range. On the right the
ammo count: plain, yellow at or under the warn threshold, red and flashing once
at or under the critical threshold, NO AMMO when empty, and two dashes when the
ranged weapon needs none.

Verified in game on build 70338: with `/hh debug on`, every light change
matched HunterProbe's independent sampler across three fights, with no errors.

How it decides: Auto Shot's range check answers true only between the dead zone
and 35 yards. When it answers false, a 35-yard item range check (Zorbin's
Ultra-Shrinker) separates "too close" from "too far". Both stay readable in
combat on this client. The frame polls twice a second only while a live hostile
is targeted.

`/hh` prints the commands: `on|off`, `lock|unlock` (drag when unlocked), `reset`,
`scale 0.5..2`, `warn N`, `crit N`, `debug on|off`, `status`.

## BuffReminder

A row of spell icons that appears out of combat when something you would keep
up is missing, and disappears when it is back. Nothing is shown in combat,
because aura reads throw there on this client; it re-checks half a second after
combat ends. Checks match buffs by name, so ranks do not matter, and a check is
only active once the spell is in your spellbook.

Default checks: Hunter (any Aspect; pet present and alive; pet fed, which shows
"Feed pet (content)" or "Feed pet (unhappy)" from the client's own happiness call
and clears while the pet is eating; Hunter's Mark on a live hostile target is off
by default), Druid (Mark of the Wild or Gift of the
Wild; Thorns off by default), Mage (Arcane Intellect or Brilliance; any Armor),
Priest (Fortitude; Inner Fire), Warlock (Demon Skin or Armor; pet), Paladin
(any Blessing), Shaman (Lightning Shield, off by default), Warrior (Battle
Shout, off by default). The table is `ns.CHECKS` at the top of the file.

`/br` prints the commands and this class's checks with their state:
`on|off [KEY]`, `check` (print what each check sees right now), `test` (show
everything for five seconds to place the frame),
`lock|unlock`, `reset`, `scale`, `debug on|off`, `status`.

## Porting report

Drop any third-party addon into the AddOns folder next to ForeverProbe, play for
a while, and ForeverProbe sorts everything that went wrong by addon: load state,
Lua errors classified as missing API call, unknown event, secret-value access,
nil index or other, with the function or event named, plus any action the
client blocked. `/fp port` prints the summary in chat; after logout,
`python3 -I scripts/read-probe.py --port` prints the full report with messages
and counts. This is the runtime complement to a static scan: it reports what the
addon actually hit.

`/fp trace on` adds a nil-global tracer: every read of a global that does not
exist is counted per addon with the file and line that read it, which shows the
removed functions an addon probes for even when it guards them. The tracer puts
a metamethod on the global table, which taints Blizzard's own code paths and
can block protected UI in combat until the next `/reload`. Use it out of combat,
in a porting session, and `/reload` afterwards. It never persists across sessions.

## In-game commands

`/fp` (ForeverProbe): `status`, `sv`, `build`, `api`, `events [full]`, `secrets`,
`errors [list|clear|on|off]`, `port`, `trace on|off`, `watch EVENT`,
`unwatch EVENT|all`, `log [n]`, `verbose 0..3`, `scripterrors on|off`, `json`,
`clear`, `reset`.

`/hp` (HunterProbe): `range`, `range on|off`, `ammo`, `auras`, `swing on|off`, `status`.

The log keeps everything regardless of chat verbosity. `/reload` writes the
SavedVariables file without logging out, so the reader can be run mid-session.

## Dev loop

Edit a `.lua` file, `/reload` in game. New files or TOC changes need a full
client restart. `tests/run.sh` before deploying catches syntax errors, unknown
globals against the real client API, and logic regressions without launching
the game.

## Notes on other people's work

`docs/pocketcfo-framework-catalog.md` catalogs the framework techniques in
PocketCFO, a six-module crafting-business suite with a Forever build, with a
vetting note per technique. `docs/forever-addon-kit-issue.md` and
`docs/atraeau-pr.md` are the texts of the issue and pull request sent to the
two reference repos.

## License

MIT. See LICENSE.

## Sources

- https://github.com/Thunderz96/forever-addon-kit for the measured client findings
- https://github.com/Atraeau/WoW-Addons for the API dump and LSP types
- https://github.com/tobarisu1/wow_forever_addons for working small addons and the Mac install approach
- https://github.com/WeakAuras/LibRangeCheck-3.0 for the range-check item IDs
