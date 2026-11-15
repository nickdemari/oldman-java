#!/bin/sh
# Build Oldman Java release zips.
#
#   dist/OldmanJava-<version>-Forever.zip             Oldman Java + QuestieDB in one download
#                                                    (GitHub, Wago, manual installs)
#   dist/OldmanJava-<version>-Forever-CurseForge.zip  Oldman Java only; CurseForge installs
#                                                    QuestieDB itself as a required dependency
#
# Usage:
#   ./build.sh                                  fetch the latest stable QuestieDB Forever release
#   ./build.sh QuestieDB-x.y.z-Forever.zip release.json
#                                               use an already-downloaded release (still verified)
set -eu

ROOT=$(cd "$(dirname "$0")" && pwd)
ADDON="$ROOT/OldmanJava"
DIST="$ROOT/dist"
REPO="Questie/QuestieDB"
REQUIRED_CONTRACT=4   # LibQuestieDB.RequireContract(4) in OldmanJava/Data.lua

fail() { echo "build: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing required tool: $1"; }
need curl; need unzip; need zip; need python3; need shasum

VERSION=$(sed -n 's/^## Version: *//p' "$ADDON/OldmanJava.toc" | tr -d '\r')
INTERFACE=$(sed -n 's/^## Interface: *//p' "$ADDON/OldmanJava.toc" | tr -d '\r')
[ -n "$VERSION" ] || fail "no ## Version in OldmanJava.toc"
[ -n "$INTERFACE" ] || fail "no ## Interface in OldmanJava.toc"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# 1. Get QuestieDB's Forever release and its manifest.
if [ $# -ge 2 ]; then
  cp "$1" "$WORK/questiedb.zip"
  cp "$2" "$WORK/release.json"
else
  echo "Finding the latest stable QuestieDB release..."
  curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" -o "$WORK/latest.json"
  URLS=$(python3 -c '
import json, sys
assets = json.load(open(sys.argv[1]))["assets"]
zip_url = next(a["browser_download_url"] for a in assets if a["name"].endswith("-Forever.zip"))
json_url = next(a["browser_download_url"] for a in assets if a["name"] == "release.json")
print(zip_url, json_url)
' "$WORK/latest.json") || fail "latest QuestieDB release has no Forever zip or release.json"
  ZIP_URL=${URLS% *}
  JSON_URL=${URLS#* }
  echo "Downloading $ZIP_URL"
  curl -fsSL "$ZIP_URL" -o "$WORK/questiedb.zip"
  curl -fsSL "$JSON_URL" -o "$WORK/release.json"
fi

# 2. Verify checksum, data contract and client interface before bundling anything.
INFO=$(python3 -c '
import json, sys
meta = json.load(open(sys.argv[1]))["questiedb"]
art = next(a for a in meta["artifacts"] if a["flavor"] == "Forever")
print(meta["version"], meta["contractVersion"], meta["minSupportedContract"], art["sha256"])
' "$WORK/release.json") || fail "release.json has no Forever artifact"
set -- $INFO
QDB_VERSION=$1; QDB_CONTRACT=$2; QDB_MIN_CONTRACT=$3; EXPECTED_SHA=$4

ACTUAL_SHA=$(shasum -a 256 "$WORK/questiedb.zip" | cut -d' ' -f1)
[ "$ACTUAL_SHA" = "$EXPECTED_SHA" ] || fail "QuestieDB checksum mismatch (got $ACTUAL_SHA, expected $EXPECTED_SHA)"
[ "$QDB_CONTRACT" -ge "$REQUIRED_CONTRACT" ] || fail "QuestieDB $QDB_VERSION has contract $QDB_CONTRACT; Oldman Java needs $REQUIRED_CONTRACT"
[ "$QDB_MIN_CONTRACT" -le "$REQUIRED_CONTRACT" ] || fail "QuestieDB $QDB_VERSION dropped support for contract $REQUIRED_CONTRACT"

if unzip -Z1 "$WORK/questiedb.zip" | grep -qv '^QuestieDB/'; then
  fail "QuestieDB zip contains files outside QuestieDB/"
fi
QDB_INTERFACE=$(unzip -p "$WORK/questiedb.zip" QuestieDB/QuestieDB_Forever.toc | sed -n 's/^## Interface: *//p;3q' | tr -d '\r')
[ "$QDB_INTERFACE" = "$INTERFACE" ] || fail "QuestieDB targets interface $QDB_INTERFACE, Oldman Java targets $INTERFACE"

# 3. Stage both addons and zip them.
STAGE="$WORK/stage"
mkdir -p "$STAGE"
cp -R "$ADDON" "$STAGE/OldmanJava"
find "$STAGE" -name '.DS_Store' -delete
(cd "$STAGE" && unzip -q "$WORK/questiedb.zip")

mkdir -p "$DIST"
BUNDLE="$DIST/OldmanJava-$VERSION-Forever.zip"
CURSEFORGE="$DIST/OldmanJava-$VERSION-Forever-CurseForge.zip"
rm -f "$BUNDLE" "$CURSEFORGE"
(cd "$STAGE" && zip -qrX "$BUNDLE" OldmanJava QuestieDB && zip -qrX "$CURSEFORGE" OldmanJava)

echo
echo "Oldman Java $VERSION (interface $INTERFACE) with QuestieDB $QDB_VERSION (contract $QDB_CONTRACT, checksum verified)"
for f in "$BUNDLE" "$CURSEFORGE"; do
  printf '  %s  %s\n' "$(du -h "$f" | cut -f1 | tr -d ' ')" "${f#$ROOT/}"
done
