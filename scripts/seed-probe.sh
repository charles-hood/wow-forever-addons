#!/usr/bin/env bash
# Pre-seed ForeverProbe's SavedVariables files so the very first cold start can
# answer "does the client read saved variables back from disk?".
#
# Writes WTF/Account/<acct>/SavedVariables/ForeverProbe.lua (account-wide) and
# WTF/Account/<acct>/<Realm>/<Char>/SavedVariables/ForeverProbe.lua for every
# character folder found. Existing files are backed up to *.bak-<stamp> first.
#
#   scripts/seed-probe.sh          seed (refuses to overwrite a file the game wrote
#                                  unless --force)
#   scripts/seed-probe.sh --force
#
# Run it while the game is NOT running: the client rewrites these files on logout.
set -euo pipefail
source "$(dirname "$0")/common.sh"

force=0
[ "${1:-}" = "--force" ] && force=1

if pgrep -qf "World of Warcraft Beta" 2>/dev/null; then
	die "the game is running; quit it first, or the client will overwrite the seed on logout"
fi

acct="$(account_dir)"
stamp="$(date +%Y-%m-%dT%H:%M:%S)"

write_seed() {
	local file="$1" global="$2"
	mkdir -p "$(dirname "$file")"
	if [ -f "$file" ]; then
		if grep -q '"seeded"' "$file" && [ "$force" -eq 0 ]; then
			echo "already seeded: $file"
			return
		fi
		if grep -q '"sessions"' "$file" && [ "$force" -eq 0 ]; then
			echo "skip (game has written it; it already carries a session counter, which is the same test): $file"
			return
		fi
		cp "$file" "$file.bak-$(date +%Y%m%d%H%M%S)"
	fi
	cat > "$file" <<LUA

$global = {
	["seeded"] = true,
	["seededAt"] = "$stamp",
	["seededBy"] = "scripts/seed-probe.sh",
}
LUA
	echo "seeded: $file"
}

write_seed "$acct/SavedVariables/ForeverProbe.lua" ForeverProbeDB

for realm in "$acct"/*/; do
	[ -d "$realm" ] || continue
	rn="$(basename "$realm")"
	[ "$rn" = "SavedVariables" ] && continue
	for char in "$realm"*/; do
		[ -d "$char" ] || continue
		write_seed "$char/SavedVariables/ForeverProbe.lua" ForeverProbeCharDB
	done
done

echo
echo "Now launch the game with ForeverProbe enabled. On login it prints the verdict; after logout read it with scripts/read-probe.py"
