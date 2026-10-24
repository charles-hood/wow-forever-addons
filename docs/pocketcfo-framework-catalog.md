# PocketCFO: a catalog of framework techniques

PocketCFO v1.1.3 by Brian (published as MerchantCGaming) is a crafting-business
suite for Retail 12.1.5 with a parallel WoW: Forever build. Six addons, 156
Lua files, about 65,000 lines including the bundled Ace3 libraries. This
catalog records the reusable techniques in its framework layer, with a vetting
note per entry. Read 2026-10-24 from the zip; not run in game here.

Vetting levels used below:

- **Read**: I read the code and the lint against the Forever client's globals
  passes (zero unguarded calls to removed API across ten removed names).
- **Matches our probes**: consistent with what ForeverProbe measured on build
  70338 (see CLAUDE.md, "Measured on this Mac").
- **Unverified on Forever**: runtime behaviour on this client not measured by
  us or, per his own annotations, by him.

## 1. One source tree, two flavours by TOC

Every module ships two manifests: `Name.toc` (Interface 120105) and
`Name_Camelot.toc` (Interface 16001). The Forever manifest loads one extra
file, `Infrastructure/Flavor_Forever.lua`, which sets `PocketCFO.flavor =
"forever"`. Retail never loads it, so the flavour is nil there and every check
reads as Retail. Orders has no Forever manifest at all, because the feature
does not exist there.

The comment in that file says why: Forever reported project ID 1 and later 18,
so the project ID is not a reliable flavour test. **Matches our probes**: we
measured 18 on 70338 and recommended the same conclusion.

Worth borrowing: the flavour-by-manifest trick costs one file and removes a
whole class of wrong guesses. Our addons only target Forever, so we do not need
it yet, but any addon that wants a Retail twin should do it this way.

## 2. Compat shims at file top, never at call sites

Each file that needs a removed global declares a local at the top:

```lua
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetCoinTextureString = (C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString)
    or GetCoinTextureString or GetMoneyString
```

The body then calls the plain name. 104 references to `GetItemInfo`, zero
bare. Where a global might be absent with no replacement, the call sits behind
`if GetCoinTextureString then`. **Read**: the lint flags the trailing fallback
reads as undefined, which is the shim working, not a bug.

Worth borrowing: this is cleaner than the kit's ForeverCompat approach of
defining the removed globals back into `_G`, because it taints nothing and
makes each file's dependencies visible at the top.

## 3. Lazy, defensive service lookups

Services are plain tables hung on the core addon object (`PocketCFO.ItemIdentityService`)
with a global fallback (`_G.ItemIdentityService`). Consumers never hold a
reference; they call a local getter at use time:

```lua
local function GetInventoryStateService()
    return PocketCFO and PocketCFO.InventoryStateService or _G.InventoryStateService
end
```

There are 128 such getters. Combined with LoadOnDemand modules, this means
load order and module presence never matter: a missing service returns nil
and the caller reports "unresolved" with a reason string instead of erroring.
The ValuationService header spells the rule out: a consumer must never force
a LoadOnDemand addon to load as a side effect of a query. **Read**.

## 4. LoadOnDemand modules behind a tiny loader

Only the core loads at login. `Infrastructure/AddonLoader.lua` listens for
`TRADE_SKILL_SHOW` and `AUCTION_HOUSE_SHOW` and loads the crafting, orders and
AH modules the first time the matching window opens, through a `SafeLoad`
that tries `C_AddOns.LoadAddOn` then the old global. Valuation loads at
enable because tooltips need it. **Read**. On Forever the orders load is
skipped by flavour.

Worth borrowing for any suite: the player pays load time only for what they
use, and a broken module cannot stop the core from loading.

## 5. Diagnostics as a first-class module

`Infrastructure/Diagnostics.lua` (562 lines) is the piece most worth studying:

- A **command registry** with metadata per command (`description`, `usage`,
  `category`, `destructive`, `temporary`, `releaseExcluded`, `playerFacing`).
  `/mcg` and `/mcgd` dispatch into it; `/pcfo` exposes only the commands
  flagged `playerFacing`, with help generated from the metadata. One table,
  three slash commands, no duplicated state.
- A **session log** in memory (`AppendSessionLog`) that modules write to with
  a `[MCG]` prefix, readable in game. 49 files define a local `SessionLog`
  helper over it. Some capture paths write to it even with debug off, with a
  comment saying why: a diagnostic command must be able to answer "was this
  event path reached at all".
- A **copyable dump window**: a scroll frame with a multi-line edit box,
  focus and select-all on show, title says "Ctrl+A, Ctrl+C to copy". The last
  dump is persisted to SavedVariables and restorable after a reload.
- **Diagnostic package providers**: modules register a function that returns a
  named bundle of their state; `/mcgd` can list and dump any package.

**Read**. Our ForeverProbe does the same job by writing to SavedVariables and
reading from disk; his design optimises for a player pasting a dump into a bug
report without leaving the game. The two are complementary, and the copyable
dump window is the piece we lack.

## 6. Verification status written into the code

Comments carry an explicit vetting state, in two words used consistently:
"Theoretical" (26 places) for behaviour assumed from Blizzard source or docs
and not yet seen, and "confirmed in-game" (22 places) with a date when it was
seen. Examples:

- `MailInfo = 17 confirmed in-game 2026-10-19`; the other interaction types
  "are read from Enum.PlayerInteractionType (Theoretical until seen)".
- The gold ledger header lists three assumptions as "Theoretical until seen
  in-game (verify via the session log with /mcg debug on)".
- A Forever-specific timing: the loot-money chat message arrived about one
  second after `PLAYER_MONEY` on the beta (captured 2026-10-20), so the hold
  window is 2 seconds on Forever and 0.5 on Retail.

**Read**. This is the same discipline as our "Measured on this Mac" section,
kept next to the code it governs rather than in a notes file. It is the single
most transferable habit in the codebase.

## 7. The gold ledger: attribution by claims, never by guess

`Services/GoldTracker/GoldLedger.lua` (1,130 lines) tags every change in a
character's gold with its source. The design:

1. A `PLAYER_MONEY` delta is held for a flush delay so related events can
   claim it regardless of arrival order.
2. Claims with an exact matching amount win first (quest reward, vendor sale,
   bank transfer). Then mailbox matching against the inbox. Then direction-only
   claims with a time-to-live (order completed, loot message, self-mail).
3. Then window rules: gold in while only the merchant or trade window is
   open can only be those; gold out may be merchant, trade, AH or mail.
4. Anything else is "other", shown as Unknown, and logged with context so
   each gap can be turned into a rule later.

The header states the rule: a category is assigned only for a specific
reason, never as a guess. AH sales are dated to the sale day, not the
collection day. Gold moved between your own characters is never income.

**Unverified on Forever** at the API level: we have not probed whether
`GetMoney`, mailbox money and auction results come back plain on this client.
Nothing in our findings says they are secret, and his own Forever capture on
2026-10-20 shows the ledger receiving money events, which is evidence they are
readable.

Worth borrowing: the "held delta plus competing claims with TTLs plus an
unknown log" shape is a general technique for attributing any state change
to its cause when the events arrive in uncertain order.

## 8. Inventory as observations plus adjustments

`Services/InventoryStateService/` separates two stores:

- **ObservationStore**: authoritative baseline rows per owner and location
  (bags, bank, warbank, mail, ah), written only by scanners.
- **AdjustmentStore**: layered deltas with their own IDs and reasons (a
  craft consumed mats, an auction was posted) applied on top until the next
  scan replaces the baseline.

An aggregator and an availability calculator read both. Rows are copied with
only scalar fields kept, so SavedVariables never receive frames or functions.
Snapshots carry a staleness threshold (15 minutes). The AH mailbox reconciler
turns mail evidence (sold, expired, cancelled) into adjustments and nothing
else: "owns outcome determination only; identity, lifecycle and inventory
adjustment are delegated".

**Read**. The clean split means a scan can be wrong or late without
corrupting what the addon believes it did in between.

## 9. Canonical item identity with opaque keys

`Services/ItemIdentityService/ConfigKeyBuilder.lua` builds keys like
`pcfo:item:v1:id:2589:path:itemID` with escaped parts and a version prefix.
The matching path (`itemID`, `itemID_ilvl`, `itemID_ilvl_stat`) says how much
of the link matters for this item. Resolvers for commodities, variants and
auction paths feed it. Identity data is cached per itemID and per link, with a
retry table for items whose data has not arrived from the server.

**Read**. The retry table addresses the same problem we hit with range items:
item data is nil until cached. He requests and retries; we request at login.

## 10. Policy modules resolved by naming convention

In crafting, the analysis controller evaluates every candidate input once,
then asks a policy which rows to show. A processing type like "prospecting"
resolves to a module named `ProspectingAnalysisPolicy` if one exists; the
policy supplies the title and may pick a row-survival rule from a shared set
(`EvaluateAllInputs`, `RecommendCheapestInput`, `RecommendBestInputPerOutputFamily`,
`RecommendTopNPerOutputFamily`). Adding a processing type adds a policy file,
never a new evaluator. **Read**.

## 11. Event capture split from side effects

`CraftEventCapture.lua` is the single listener for the craft-result event and
does only the reads that must happen at event time (current recipe, pending
config). Everything that follows (inventory adjustment, statistics, the
operation observation) is coordinated by a separate dispatcher. The same
shape appears in the AH module: scanners write snapshots, a reconciler decides
outcomes, services own lifecycle. **Read**.

## 12. Long work in chunks with a yield

`FullScan.lua` processes auction replicate results in chunks of 200 with a
10 millisecond yield, a 60 second wait timeout and a 15 minute cooldown. 91
`C_Timer` uses across the suite, 333 `pcall` wrappers, and a `PackCall`
helper that returns `ok, {returns}` so callers never index a failed result.
**Read**.

## 13. Small things worth copying

- Module messages on the Ace event bus (`MCG_GOLD_BALANCES_CHANGED`,
  `MCG_GOLD_LEDGER_UPDATED`, `MCG_ORDER_RESULTS_UPDATED`) decouple data
  modules from the windows that display them.
- Window numbers are "built in full before anything is drawn (no partial
  redraws)", stated in the GoldWindow header.
- Tooltip state is kept in weak-keyed tables so tooltip frames never leak.
- The dump frame registers in `UISpecialFrames` so Escape closes it.
- `hooksecurefunc` only (14 uses), no replacement of Blizzard functions.
- Chat output carries a short prefix (`[MCG]`) and the product name is kept
  out of chat lines on purpose.
- Comments cite design documents (`claude/Gold_Sources_Design.md`, a
  CLAUDE.md with architecture notes), so the code points at the reasoning.

## 14. Risks and open questions for Forever

- **Ace3 is bundled** (LibStub, CallbackHandler, AceAddon, AceEvent, AceDB).
  Our probes did not test Ace3 on this client; it is widely used on Retail
  12.x so it should load, and AceDB persistence depends on SavedVariables,
  which we confirmed work on 70338.
- **Secret values.** The suite reads bag contents, money, mail and auction
  data. We measured none of those for secrecy. Health and power are secret
  here even out of combat, which is a reminder that Forever is stricter than
  Retail; a one-session probe on `GetMoney`, `C_AuctionHouse` results and
  mailbox money would settle it.
- **Frames by name.** `ProfessionsFrame`, `AuctionHouseFrame` and
  `TradeSkillFrame` are referenced by global name with existence checks. Which
  of those the Forever client builds (Retail profession UI versus the old
  trade skill frame) decides which code paths run. The checks mean neither
  case errors, but the feature set differs.
- **Combat log and forbidden actions.** Nothing in the suite registers the
  combat log event, and the AH posting path uses the Blizzard posting API, so
  the forbidden-action risk we found does not apply.

## What this catalog is for

The techniques in sections 2, 3, 5, 6 and 7 are the ones to carry into this
repo's own addons as they grow: top-of-file shims, lazy service getters, a
copyable in-game dump, verification states written in comments, and
claim-based attribution for anything that arrives as unordered events.
