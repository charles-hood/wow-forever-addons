#!/usr/bin/env bash
# Put the addons under addons/ into the Forever client's AddOns folder.
#
#   scripts/deploy.sh            symlink every addon (edit here, /reload in game)
#   scripts/deploy.sh --copy     copy instead of link
#   scripts/deploy.sh --clean    remove what this script put there
#   scripts/deploy.sh NAME ...   only these addons
#
# Symlinks are the default because they make the edit/reload loop instant. If the
# client refuses to list a linked addon on the character-select AddOns screen,
# run again with --copy.
set -euo pipefail
source "$(dirname "$0")/common.sh"

mode=link
names=()
for a in "$@"; do
	case "$a" in
		--copy) mode=copy ;;
		--clean) mode=clean ;;
		-h|--help) sed -n '2,12p' "$0"; exit 0 ;;
		*) names+=("$a") ;;
	esac
done

[ -d "$WOW_DIR" ] || die "client folder not found: $WOW_DIR"
mkdir -p "$WOW_ADDONS"

if [ "${#names[@]}" -eq 0 ]; then
	for d in "$ADDON_SRC"/*/; do
		n="$(basename "$d")"
		[ -f "$d/$n.toc" ] && names+=("$n")
	done
fi
[ "${#names[@]}" -gt 0 ] || die "no addon folders with a matching .toc under $ADDON_SRC"

if pgrep -qf "World of Warcraft Beta" 2>/dev/null; then
	echo "note: the game is running. New files and TOC changes need a full restart; Lua edits need /reload."
fi

for n in "${names[@]}"; do
	src="$ADDON_SRC/$n"
	dst="$WOW_ADDONS/$n"
	[ -f "$src/$n.toc" ] || die "$src/$n.toc not found"
	case "$mode" in
		clean)
			if [ -L "$dst" ]; then rm "$dst"; echo "removed link $dst"
			elif [ -d "$dst" ]; then rm -rf "$dst"; echo "removed copy $dst"
			else echo "nothing at $dst"; fi
			;;
		link)
			if [ -d "$dst" ] && [ ! -L "$dst" ]; then
				die "$dst is a real folder, not a link. Run --clean first (it deletes it) or use --copy."
			fi
			ln -sfn "$src" "$dst"
			echo "linked $dst -> $src"
			;;
		copy)
			if [ -L "$dst" ]; then rm "$dst"; fi
			mkdir -p "$dst"
			rsync -a --delete --exclude '.DS_Store' "$src/" "$dst/"
			echo "copied $src -> $dst"
			;;
	esac
done

if [ "$mode" != clean ]; then
	echo
	echo "Now: launch (or restart) the game, open AddOns on character select, enable: ${names[*]}"
	echo "If a linked addon is missing from that list, rerun with --copy."
fi
