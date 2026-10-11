# Shared settings for the scripts. Override with environment variables.
WOW_ROOT="${WOW_ROOT:-/Applications/World of Warcraft}"
WOW_FLAVOR="${WOW_FLAVOR:-_classic_beta_}"
WOW_DIR="$WOW_ROOT/$WOW_FLAVOR"
WOW_ADDONS="${WOW_ADDONS:-$WOW_DIR/Interface/AddOns}"
WOW_WTF="$WOW_DIR/WTF"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADDON_SRC="$REPO_DIR/addons"

die() { echo "error: $*" >&2; exit 1; }

# Prints the single account folder under WTF/Account, or fails if there is not exactly one.
# Set WOW_ACCOUNT to pick one by name.
account_dir() {
	local base="$WOW_WTF/Account"
	[ -d "$base" ] || die "no WTF/Account folder at $base (launch the game once first)"
	if [ -n "${WOW_ACCOUNT:-}" ]; then
		[ -d "$base/$WOW_ACCOUNT" ] || die "no account folder $base/$WOW_ACCOUNT"
		echo "$base/$WOW_ACCOUNT"
		return
	fi
	local found=()
	for d in "$base"/*/; do
		[ -d "$d/SavedVariables" ] && found+=("${d%/}")
	done
	[ "${#found[@]}" -eq 1 ] || die "expected one account folder with SavedVariables under $base, found ${#found[@]}; set WOW_ACCOUNT"
	echo "${found[0]}"
}
