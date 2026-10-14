#!/usr/bin/env bash
# Check that a 微信流.app is a macOS 12 installer payload.
#
# The installer workflow runs this twice: once on the bundle `make-app.sh` has
# just assembled, and once on the copy inside the finished DMG, because only the
# second one is what a user installs. It answers the questions a build log
# cannot: whether every Mach-O really stops at Monterey, whether the Universal 2
# half is there for an Intel Mac, whether all twelve Share-menu entries and the
# login helper survived assembly, whether the resources a feature reads at
# run time are inside the bundle, and whether the signatures say what the plists
# say — an app and an extension on different sides of an app group is the one
# failure that produces no error anywhere.
#
#   Scripts/verify-macos12-bundle.sh [/Volumes/微信流 0.1.15/微信流.app]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
SHARED="$REPO_ROOT/shared"
# shellcheck source=share-slots.sh
source "$ROOT/Scripts/share-slots.sh"

APP="${1:-$ROOT/dist/$APP_BUNDLE_NAME}"
APP_INFO="$ROOT/Resources/Info.plist"

if [ ! -d "$APP" ]; then
	echo "no bundle to verify: $APP" >&2
	exit 1
fi

FAILURES=0
fail() {
	echo "FAIL: $*" >&2
	FAILURES=$((FAILURES + 1))
}
pass() {
	echo "ok: $*"
}

read_plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null; }

# Every architecture of a Mach-O must agree on the floor. `vtool -show-build`
# reports one load command per slice, so a Universal 2 build that set the floor
# only on the architecture compiled last shows up here and nowhere else.
minimum_os_report() {
	vtool -show-build "$1" 2>/dev/null | awk '/minos/ { print $2 }' | sort -u
}

# Code WeChatBridge builds itself: it must stop exactly at the version the
# package and the Info.plists declare, which is what makes a Monterey Mac able
# to launch it at all.
check_floor() {
	local binary="$1" label="$2" expected="$3"
	local reported
	reported="$(minimum_os_report "$binary")"
	if [ -z "$reported" ]; then
		fail "$label: no macOS build version to read"
		return
	fi
	if [ "$reported" != "$expected" ]; then
		fail "$label: minimum system version is $reported, expected $expected"
		return
	fi
	pass "$label stops at macOS $expected"
}

# Anything else the app carries — Sparkle today — only has to not require more
# than Monterey offers.
check_not_newer_than_monterey() {
	local binary="$1" label="$2"
	local reported
	reported="$(minimum_os_report "$binary")"
	if [ -z "$reported" ]; then
		fail "$label: no macOS build version to read"
		return
	fi
	local lowest
	lowest="$(printf '%s\n%s\n' "12.0" "$reported" | sort -V | head -1)"
	if [ "$lowest" != "$reported" ]; then
		fail "$label requires macOS $reported, which Monterey does not have"
		return
	fi
	pass "$label is loadable on macOS $reported"
}

check_architectures() {
	local binary="$1" label="$2"
	local archs
	archs="$(lipo -archs "$binary" 2>/dev/null || true)"
	local arch
	for arch in arm64 x86_64; do
		if ! printf '%s\n' "$archs" | tr ' ' '\n' | grep -Fxq "$arch"; then
			fail "$label: $arch is missing (has: $archs)"
			return
		fi
	done
	pass "$label carries both architectures ($archs)"
}

check_file() {
	local path="$1" label="$2"
	if [ ! -e "$path" ] || { [ -f "$path" ] && [ ! -s "$path" ]; }; then
		fail "$label: missing $path"
		return
	fi
	pass "$label"
}

entitlements_of() {
	codesign -d --entitlements - --xml "$1" 2>/dev/null || true
}

has_entitlement() {
	printf '%s' "$1" | grep -Fq "$2"
}

APP_ID="$(read_plist "$APP/Contents/Info.plist" CFBundleIdentifier)"
APP_VERSION="$(read_plist "$APP/Contents/Info.plist" CFBundleShortVersionString)"
APP_BUILD="$(read_plist "$APP/Contents/Info.plist" CFBundleVersion)"
APP_MINIMUM_OS="$(read_plist "$APP/Contents/Info.plist" LSMinimumSystemVersion)"
STORAGE_MODE="$(read_plist "$APP/Contents/Info.plist" DKStorageMode)"

if [ "$APP_MINIMUM_OS" != "12.0" ]; then
	fail "the app declares macOS $APP_MINIMUM_OS as its minimum"
else
	pass "the app declares macOS 12.0 as its minimum"
fi
if [ "$STORAGE_MODE" != "shared" ]; then
	fail "the app is built in storage mode $STORAGE_MODE; an ad-hoc build must use shared"
else
	pass "storage is shared, so no app group identity is required (${APP_ID} $APP_VERSION/$APP_BUILD)"
fi

check_floor "$APP/Contents/MacOS/WeChatBridge" "the app" "$APP_MINIMUM_OS"
check_architectures "$APP/Contents/MacOS/WeChatBridge" "the app"

# The Share-menu entries are the app's whole surface: twelve signed appexes that
# all run the same executable and tell themselves apart by DKShareAction.
APPEX_COUNT=0
for SLOT_ROW in "${SHARE_SLOTS[@]}"; do
	IFS='|' read -r SLOT APPEX_NAME ID_SUFFIX SLOT_ACTION DISPLAY_NAME <<< "$SLOT_ROW"
	APPEX="$APP/Contents/PlugIns/$APPEX_NAME.appex"
	if [ ! -d "$APPEX" ]; then
		fail "share entry $SLOT is missing from the bundle"
		continue
	fi
	APPEX_COUNT=$((APPEX_COUNT + 1))
	PLIST="$APPEX/Contents/Info.plist"
	IDENTIFIER="$(read_plist "$PLIST" CFBundleIdentifier)"
	ACTION="$(read_plist "$PLIST" DKShareAction)"
	[ "$IDENTIFIER" = "$APP_ID.$ID_SUFFIX" ] || fail "share entry $SLOT has identifier $IDENTIFIER"
	[ "$ACTION" = "$SLOT_ACTION" ] || fail "share entry $SLOT carries action $ACTION, expected $SLOT_ACTION"
	[ "$(read_plist "$PLIST" CFBundleExecutable)" = "$APPEX_NAME" ] || fail "share entry $SLOT has the wrong executable name"
	[ "$(read_plist "$PLIST" LSMinimumSystemVersion)" = "12.0" ] || fail "share entry $SLOT does not declare macOS 12.0"
	[ "$(read_plist "$PLIST" CFBundleShortVersionString)" = "$APP_VERSION" ] || fail "share entry $SLOT is not at version $APP_VERSION"
	[ -d "$APPEX/Contents/Resources/zh-Hans.lproj" ] || fail "share entry $SLOT has no Simplified Chinese localisation"
	[ -d "$APPEX/Contents/Resources/en.lproj" ] || fail "share entry $SLOT has no English localisation"
done

if [ "$APPEX_COUNT" -ne "${#SHARE_SLOTS[@]}" ]; then
	fail "the bundle carries $APPEX_COUNT share entries, expected ${#SHARE_SLOTS[@]}"
else
	pass "all ${#SHARE_SLOTS[@]} share entries are present and consistent"
fi

# One executable, shipped twelve times over: it is checked once.
FIRST_APPEX_NAME="${SHARE_SLOTS[0]#*|}"
FIRST_APPEX_NAME="${FIRST_APPEX_NAME%%|*}"
FIRST_APPEX="$APP/Contents/PlugIns/$FIRST_APPEX_NAME.appex"
check_floor "$FIRST_APPEX/Contents/MacOS/$FIRST_APPEX_NAME" "the share extension" "12.0"
check_architectures "$FIRST_APPEX/Contents/MacOS/$FIRST_APPEX_NAME" "the share extension"

# The entry point is a build invariant: without it the appex builds, installs and
# silently never appears in the Share menu.
if nm -u "$FIRST_APPEX/Contents/MacOS/$FIRST_APPEX_NAME" 2>/dev/null | grep -Fq '_NSExtensionMain'; then
	pass "the share extension is linked against NSExtensionMain"
else
	fail "the share extension has no NSExtensionMain entry point"
fi

# The login helper is what 开机自启动 uses on Monterey, where SMAppService does not
# exist yet; without it the switch would be a control that does nothing.
LOGIN_ITEM_APP="$APP/Contents/Library/LoginItems/WeChatBridgeLoginItem.app"
LOGIN_ITEM_INFO="$LOGIN_ITEM_APP/Contents/Info.plist"
if [ ! -d "$LOGIN_ITEM_APP" ]; then
	fail "the login helper is missing from the bundle"
else
	[ "$(read_plist "$LOGIN_ITEM_INFO" CFBundleIdentifier)" = "$APP_ID.LoginItem" ] \
		|| fail "the login helper has identifier $(read_plist "$LOGIN_ITEM_INFO" CFBundleIdentifier)"
	[ "$(read_plist "$LOGIN_ITEM_INFO" LSMinimumSystemVersion)" = "12.0" ] \
		|| fail "the login helper does not declare macOS 12.0"
	[ -d "$LOGIN_ITEM_APP/Contents/Resources/zh-Hans.lproj" ] \
		|| fail "the login helper has no Simplified Chinese localisation"
	check_floor "$LOGIN_ITEM_APP/Contents/MacOS/WeChatBridgeLoginItem" "the login helper" "12.0"
	check_architectures "$LOGIN_ITEM_APP/Contents/MacOS/WeChatBridgeLoginItem" "the login helper"
fi

# Sparkle rides along for updates that the app does not offer yet. It is still
# signed and still has to load on Monterey.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [ ! -d "$SPARKLE" ]; then
	fail "Sparkle.framework is missing from the bundle"
else
	check_not_newer_than_monterey "$SPARKLE/Versions/Current/Sparkle" "Sparkle"
	check_architectures "$SPARKLE/Versions/Current/Sparkle" "Sparkle"
fi

# Resources a feature reads out of its own bundle at run time. `Bundle.module`
# would point back into the build directory, where a distributed app has nothing.
for REQUIRED in \
	"Contents/Resources/Licenses" \
	"Contents/Resources/AppLogos" \
	"Contents/Resources/Skills/catalog.json" \
	"Contents/Resources/AppIcon.icns" \
	"Contents/Resources/LICENSE" \
	"Contents/Resources/THIRD-PARTY-NOTICES.md" \
	"Contents/Resources/zh-Hans.lproj" \
	"Contents/Resources/en.lproj"; do
	check_file "$APP/$REQUIRED" "the bundle carries $(basename "$REQUIRED")"
done

# The skill library is the app's knowledge: an empty directory here is a 技能
# pane that offers nothing.
SKILL_COUNT="$(find "$APP/Contents/Resources/Skills" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
if [ "${SKILL_COUNT:-0}" -lt 1 ]; then
	fail "the bundle carries no skills"
else
	pass "the bundle carries $SKILL_COUNT skills"
fi

# Signatures. `codesign --verify --deep` walks the appexes and the framework, so
# it is also the check that the nested code was signed before the app was.
if codesign --verify --deep --strict "$APP" 2>/dev/null; then
	pass "every signature in the bundle verifies"
else
	fail "the bundle does not verify:"
	codesign --verify --deep --strict --verbose=2 "$APP" >&2 || true
fi

APP_ENTITLEMENTS="$(entitlements_of "$APP")"
if has_entitlement "$APP_ENTITLEMENTS" "com.apple.security.application-groups"; then
	fail "the app still carries an app group entitlement, which an ad-hoc build cannot honour"
else
	pass "the app claims no app group"
fi
if has_entitlement "$APP_ENTITLEMENTS" "com.apple.security.app-sandbox"; then
	fail "the app is sandboxed; pluginkit refuses every entry switch from inside the sandbox"
else
	pass "the app is not sandboxed, so the 入口 pane can switch entries on and off"
fi

SHARE_ENTITLEMENTS="$(entitlements_of "$APP/Contents/PlugIns/$FIRST_APPEX_NAME.appex")"
if has_entitlement "$SHARE_ENTITLEMENTS" "com.apple.security.app-sandbox"; then
	pass "the share extension is sandboxed"
else
	fail "the share extension is not sandboxed"
fi
if has_entitlement "$SHARE_ENTITLEMENTS" "com.apple.security.temporary-exception.files.home-relative-path.read-write"; then
	pass "the share extension can write the shared inbox"
else
	fail "the share extension has no exception for the shared inbox, so every share would be refused"
fi
if has_entitlement "$SHARE_ENTITLEMENTS" "com.apple.security.application-groups"; then
	fail "the share extension still carries an app group entitlement"
else
	pass "the share extension claims no app group"
fi

# The app reads its inbox path out of its own Info.plist, so the two halves have
# to agree on the storage mode even though nothing at run time compares them.
SHARE_STORAGE_MODE="$(read_plist "$APP/Contents/PlugIns/$FIRST_APPEX_NAME.appex/Contents/Info.plist" DKStorageMode)"
if [ "$SHARE_STORAGE_MODE" != "$STORAGE_MODE" ]; then
	fail "storage mode disagreement: app $STORAGE_MODE, extension $SHARE_STORAGE_MODE"
else
	pass "the app and its extension agree on shared storage"
fi

if [ -d "$SHARED/Skills" ]; then
	for SKILL in "$SHARED/Skills"/*/; do
		NAME="$(basename "$SKILL")"
		[ -d "$APP/Contents/Resources/Skills/$NAME" ] || fail "skill $NAME is not in the bundle"
	done
fi

if [ "$FAILURES" -gt 0 ]; then
	echo "" >&2
	echo "$FAILURES check(s) failed for $APP" >&2
	exit 1
fi
echo ""
echo "$APP is a macOS 12 installer payload: $(lipo -archs "$APP/Contents/MacOS/WeChatBridge"), version $APP_VERSION ($APP_BUILD), ${#SHARE_SLOTS[@]} share entries, ad-hoc signed, shared storage"
