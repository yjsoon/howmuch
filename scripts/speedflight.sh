#!/bin/bash
# Cuts a signed ad hoc IPA, uploads it to Speedflight, and prints the page
# link as the last line. Signs through the App Store Connect key in
# .env.speedflight; the key must belong to DEVELOPMENT_TEAM.
#
#   scripts/speedflight.sh "<title>" "<notes>" [screenshot.png ...]
#
# The page link is the only auth for installing. The secret in
# .env.speedflight is the only auth for uploading. Do not paste either
# anywhere public.
set -euo pipefail
cd "$(dirname "$0")/.."

TITLE="${1:?usage: speedflight.sh \"<title>\" \"<notes>\" [screenshot.png ...]}"
NOTES="${2:?usage: speedflight.sh \"<title>\" \"<notes>\" [screenshot.png ...]}"
shift 2
SCREENSHOTS=("$@")

if [[ -f .env.speedflight ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env.speedflight
  set +a
fi
: "${ASC_KEY_ID:?set ASC_KEY_ID in .env.speedflight}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID in .env.speedflight}"
: "${SPEEDFLIGHT_SECRET:?set SPEEDFLIGHT_SECRET in .env.speedflight}"
: "${SPEEDFLIGHT_DEEP_LINK:?set SPEEDFLIGHT_DEEP_LINK in .env.speedflight}"
: "${SPEEDFLIGHT_AUTHOR:?set SPEEDFLIGHT_AUTHOR in .env.speedflight}"
ASC_PRIVATE_KEY_PATH="${ASC_PRIVATE_KEY_PATH:-$HOME/private_keys/AuthKey_$ASC_KEY_ID.p8}"
[[ -f "$ASC_PRIVATE_KEY_PATH" ]] || { echo "missing ASC key file: $ASC_PRIVATE_KEY_PATH" >&2; exit 1; }

PROJECT="apps/ios/HowMuch.xcodeproj"
SCHEME="HowMuch"
BUNDLE_ID="sg.soon.howmuch"
TEAM_ID="PQ6U5ESLN2"
BASE="${SPEEDFLIGHT_BASE:-https://speedflight.dev}"
# The same worker on its workers.dev route, kept as an upload fallback. The
# page link stays on the custom domain.
FALLBACK_BASE="https://speedflight.jake-7c3.workers.dev"
OUT="build/share"
# Separate from simulator/device iteration caches. Do not wipe this as a first response.
DERIVED_DATA="${HOWMUCH_ARCHIVE_DERIVED:-$PWD/build/xcode/DerivedData-archive}"
XCODE_JOBS="${HOWMUCH_XCODE_JOBS:-2}"
XCODE_LOG_DIR="${HOWMUCH_XCODE_LOG_DIR:-$PWD/build/xcode/logs}"
LOCK_DIR="${HOWMUCH_XCODE_LOCK_DIR:-$PWD/build/xcode/ios-xcodebuild.lock}"

# Publication requires a clean, remote-backed revision, including in CI.
# A detached exact revision needs an explicit containing origin branch or tag.
BRANCH="$(git symbolic-ref --quiet --short HEAD || true)"
COMMIT="$(git rev-parse HEAD)"
# https form of origin, so the page can link the branch and commit.
REPO_URL="$(git remote get-url origin 2>/dev/null | sed -E 's#^git@([^:]+):#https://\1/#; s#\.git$##')"
case "$REPO_URL" in https://*) ;; *) REPO_URL="" ;; esac
if [[ -n "$(git status --porcelain)" ]]; then
  echo "publication prerequisite unmet: working tree must be clean; no commit or push is authorized by this check" >&2
  exit 1
fi
SOURCE_REF="${SPEEDFLIGHT_SOURCE_REF:-${BRANCH:+refs/heads/$BRANCH}}"
case "$SOURCE_REF" in
  refs/heads/*|refs/tags/*) ;;
  *) echo "publication prerequisite unmet: SPEEDFLIGHT_SOURCE_REF must name a full origin branch or tag (refs/heads/... or refs/tags/...)" >&2; exit 1 ;;
esac
if ! git check-ref-format "$SOURCE_REF"; then
  echo "publication prerequisite unmet: invalid origin branch or tag" >&2
  exit 1
fi
# Fetch exactly the selected ref; cached tracking refs are not publication proof.
# This does not check out, merge, rebase, commit, or push anything.
if ! git fetch --no-tags origin "$SOURCE_REF"; then
  echo "publication prerequisite unmet: could not fetch the selected origin branch or tag" >&2
  exit 1
fi
if ! git merge-base --is-ancestor "$COMMIT" 'FETCH_HEAD^{commit}'; then
  echo "publication prerequisite unmet: HEAD is not contained in the selected origin branch or tag; revision changes and pushes need authorization" >&2
  exit 1
fi
BRANCH="${SOURCE_REF#refs/*/}"

# Uncomment for XcodeGen projects: the project file is generated and gitignored.
# xcodegen generate --quiet

rm -rf "$OUT"
mkdir -p "$OUT" "$DERIVED_DATA" "$XCODE_LOG_DIR"
if mkdir "$LOCK_DIR" 2>/dev/null; then
  printf '%s\n' "$$" >"$LOCK_DIR/pid"
  trap 'rm -rf "$LOCK_DIR"' EXIT
else
  other="$(cat "$LOCK_DIR/pid" 2>/dev/null || echo unknown)"
  echo "error: another HowMuch xcodebuild owns this checkout (pid $other)" >&2
  exit 75
fi

# Archive signed, not with CODE_SIGNING_ALLOWED=NO: an unsigned archive
# carries no entitlements and the export re-sign does not add them back.
# Cloud signing with the ASC key makes a development certificate for the
# archive and the ad hoc one for the export. Keep full logs: -quiet hid
# actool/swift progress that still ran under memory pressure.
ARCHIVE_LOG="$XCODE_LOG_DIR/speedflight-archive-$(date '+%Y%m%d-%H%M%S').log"
echo "archiving with derivedData=$DERIVED_DATA jobs=$XCODE_JOBS log=$ARCHIVE_LOG"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$DERIVED_DATA" \
  -archivePath "$OUT/App.xcarchive" \
  -jobs "$XCODE_JOBS" \
  -allowProvisioningUpdates \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  -authenticationKeyPath "$ASC_PRIVATE_KEY_PATH" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  COMPILER_INDEX_STORE_ENABLE=NO \
  archive 2>&1 | tee "$ARCHIVE_LOG" "$OUT/archive.log"

cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>destination</key><string>export</string>
  <key>method</key><string>release-testing</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>thinning</key><string>&lt;none&gt;</string>
</dict>
</plist>
PLIST

EXPORT_LOG="$XCODE_LOG_DIR/speedflight-export-$(date '+%Y%m%d-%H%M%S').log"
xcodebuild -exportArchive \
  -archivePath "$OUT/App.xcarchive" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -exportPath "$OUT/export" \
  -allowProvisioningUpdates \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  -authenticationKeyPath "$ASC_PRIVATE_KEY_PATH" \
  2>&1 | tee "$EXPORT_LOG" "$OUT/export.log"
mv "$OUT"/export/*.ipa "$OUT/signed.ipa"

# 1. Register the build with its metadata. The server answers with the ids.
META="$(jq -n \
  --arg title "$TITLE" --arg notes "$NOTES" \
  --arg deepLink "$SPEEDFLIGHT_DEEP_LINK" \
  --arg branch "$BRANCH" --arg commit "$COMMIT" \
  --arg author "$SPEEDFLIGHT_AUTHOR" \
  --arg repoUrl "$REPO_URL" \
  '{title:$title, notes:$notes, deepLink:$deepLink, branch:$branch, commit:$commit, author:$author}
   + (if $repoUrl == "" then {} else {repoUrl:$repoUrl} end)')"
create() {
  curl -sfS --retry 3 --retry-all-errors --retry-delay 3 \
    -X POST "$1/api/apps/$SPEEDFLIGHT_SECRET/$BUNDLE_ID/builds" \
    -H "Content-Type: application/json" --data "$META"
}
CREATED="$(create "$BASE" || create "$FALLBACK_BASE")"
BUILD_ID="$(jq -r .buildId <<<"$CREATED")"
PAGE_URL="$(jq -r .pageUrl <<<"$CREATED")"

# 2. Upload the IPA. The server reads name, version, and build number from
#    its Info.plist and rejects it if the bundle id does not match.
upload() {
  curl -sfS --http1.1 --retry 5 --retry-all-errors --retry-delay 5 \
    -X PUT "$1/api/apps/$SPEEDFLIGHT_SECRET/$BUNDLE_ID/builds/$BUILD_ID/app.ipa" \
    --data-binary @"$OUT/signed.ipa" >/dev/null
}
upload "$BASE" || upload "$FALLBACK_BASE"

# 3. Screenshots, if given: what changed, as pictures. Named 01-, 02-, ...
#    so the page keeps the order you passed them in.
# The guarded expansion keeps macOS bash 3.2's set -u happy when no
# screenshots were passed; a bare "${SCREENSHOTS[@]}" aborts the script.
n=0
for shot in ${SCREENSHOTS[@]+"${SCREENSHOTS[@]}"}; do
  [[ -f "$shot" ]] || { echo "no such screenshot: $shot" >&2; continue; }
  n=$((n + 1))
  ext="${shot##*.}"
  case "$ext" in png|PNG) type=image/png ;; jpg|jpeg|JPG|JPEG) type=image/jpeg ;; webp) type=image/webp ;; *) echo "skip $shot: not png/jpg/webp" >&2; continue ;; esac
  name="$(printf '%02d-%s' "$n" "$(basename "$shot" | tr -c 'A-Za-z0-9._-\n' '-')")"
  curl -sfS --retry 3 --retry-all-errors --retry-delay 3 \
    -X PUT "$BASE/api/apps/$SPEEDFLIGHT_SECRET/$BUNDLE_ID/builds/$BUILD_ID/screenshots/$name" \
    -H "Content-Type: $type" --data-binary @"$shot" >/dev/null || echo "screenshot upload failed: $shot" >&2
done

# 4. Icon, if configured. Best effort.
if [[ -n "${SPEEDFLIGHT_ICON:-}" && -f "$SPEEDFLIGHT_ICON" ]]; then
  curl -sS -X PUT "$BASE/api/apps/$SPEEDFLIGHT_SECRET/$BUNDLE_ID/icon" \
    -H "Content-Type: image/png" --data-binary @"$SPEEDFLIGHT_ICON" >/dev/null || true
fi

echo
echo "Build page: $PAGE_URL"
