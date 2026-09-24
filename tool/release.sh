#!/usr/bin/env bash
# tool/release.sh X.Y.Z ["notes text"]
#
# Собирает и публикует один релиз Spotty (iGeezmo/spotty):
#  - поднимает build number (version_code) в pubspec.yaml, ставит version_name=X.Y.Z
#  - собирает release APK той же подписью (~/.android/debug.keystore)
#  - проверяет подпись apksigner + совпадение сертификата с предыдущим релизом
#  - пишет version.json (version_code, version_name, url, sha256, notes)
#  - публикует релиз vX.Y.Z на GitHub с apk + version.json
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VER="${1:?usage: tool/release.sh X.Y.Z [\"notes\"]}"
NOTES="${2:-Spotty v${VER}}"
REPO="iGeezmo/spotty"
CERT_FILE="tool/RELEASE_CERT_SHA256"
DIST="tool/dist"

if [[ ! "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "STOP: версия должна быть X.Y.Z (получено: $VER)" >&2
  exit 2
fi

CUR_LINE="$(grep -E '^version: ' pubspec.yaml)"
CUR_BUILD="$(echo "$CUR_LINE" | sed -E 's/^version: [0-9]+\.[0-9]+\.[0-9]+\+([0-9]+)$/\1/')"
if [[ -z "$CUR_BUILD" ]]; then
  echo "STOP: не удалось разобрать текущий version+build из pubspec.yaml: $CUR_LINE" >&2
  exit 2
fi
NEW_BUILD=$((CUR_BUILD + 1))
NEW_LINE="version: ${VER}+${NEW_BUILD}"
sed -i "s/^version: .*/${NEW_LINE}/" pubspec.yaml
echo "pubspec.yaml: ${CUR_LINE} -> ${NEW_LINE}"

echo "flutter pub get..."
flutter pub get >/dev/null

echo "flutter build apk --release..."
flutter build apk --release

SRC_APK="build/app/outputs/flutter-apk/app-release.apk"
if [[ ! -f "$SRC_APK" ]]; then
  echo "STOP: не найден собранный APK: $SRC_APK" >&2
  exit 3
fi

mkdir -p "$DIST"
APK_NAME="spotty-${VER}.apk"
APK_PATH="$DIST/$APK_NAME"
cp "$SRC_APK" "$APK_PATH"

echo "apksigner verify..."
apksigner verify --print-certs "$APK_PATH"

CERT_SHA="$(apksigner verify --print-certs "$APK_PATH" 2>/dev/null \
  | grep -i 'SHA-256 digest' | head -1 | awk -F': ' '{print $2}' | tr -d ' ')"
if [[ -z "$CERT_SHA" ]]; then
  echo "STOP: не удалось извлечь SHA-256 сертификата из apksigner" >&2
  exit 3
fi

if [[ -f "$CERT_FILE" ]]; then
  PREV_CERT_SHA="$(cat "$CERT_FILE")"
  if [[ "$CERT_SHA" != "$PREV_CERT_SHA" ]]; then
    echo "STOP: сертификат подписи изменился относительно прошлого релиза." >&2
    echo "  прошлый:  $PREV_CERT_SHA" >&2
    echo "  текущий:  $CERT_SHA" >&2
    echo "  Android откажется ставить это обновление поверх старой версии." >&2
    exit 4
  fi
  echo "Сертификат совпадает с прошлым релизом: $CERT_SHA"
else
  echo "$CERT_SHA" > "$CERT_FILE"
  echo "Первый релиз — сертификат сохранён в $CERT_FILE: $CERT_SHA"
fi

APK_SHA256="$(sha256sum "$APK_PATH" | awk '{print $1}')"
DOWNLOAD_URL="https://github.com/${REPO}/releases/download/v${VER}/${APK_NAME}"

VERSION_JSON="$DIST/version.json"
cat > "$VERSION_JSON" <<EOF
{
  "version_code": ${NEW_BUILD},
  "version_name": "${VER}",
  "url": "${DOWNLOAD_URL}",
  "sha256": "${APK_SHA256}",
  "notes": "${NOTES}"
}
EOF

echo "version.json:"
cat "$VERSION_JSON"

echo "gh release create v${VER}..."
gh release create "v${VER}" "$APK_PATH" "$VERSION_JSON" \
  --repo "$REPO" \
  --title "Spotty v${VER}" \
  --notes "${NOTES}"

echo "OK: released v${VER} (build ${NEW_BUILD}), sha256=${APK_SHA256}"
echo "APK: $APK_PATH"
