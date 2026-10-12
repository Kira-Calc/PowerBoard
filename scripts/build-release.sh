#!/bin/bash
# Builds an ad-hoc signed Release of the app and packs it as a zip in dist/ (SPEC 15.1).
# The app is not notarized; see README for how to open it.
set -euo pipefail

cd "$(dirname "$0")/.."

for tool in xcodegen xcodebuild ditto; do
    command -v "$tool" >/dev/null || { echo "Missing $tool" >&2; exit 1; }
done

python3 -I scripts/check-strings.py >/dev/null || { echo "String Catalog check failed: run scripts/check-strings.py" >&2; exit 1; }

xcodegen generate --quiet
swift test --package-path Packages/ElectricityCore --quiet

derived=build/ReleaseDerivedData
rm -rf "$derived"
xcodebuild -project PowerBoard.xcodeproj -scheme PowerBoard -configuration Release \
    -derivedDataPath "$derived" build > build/release.log 2>&1 || { tail -30 build/release.log >&2; exit 1; }

app=$(find "$derived/Build/Products/Release" -maxdepth 1 -name "*.app" | head -1)
[ -n "$app" ] || { echo "No app in $derived" >&2; exit 1; }
name=$(basename "$app" .app)
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist")

# Sign nested code first, then the app, all ad hoc.
codesign --force --sign - "$app/Contents/Helpers/"* 2>/dev/null || true
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
"$app/Contents/Helpers/$(ls "$app/Contents/Helpers" | grep -v '\.bundle$' | head -1)" --version >/dev/null

mkdir -p dist
zip="dist/${name// /-}-${version}.zip"
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
shasum -a 256 "$zip" | tee "$zip.sha256"
echo "Built $zip"
