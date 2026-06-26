#!/bin/bash
set -e

if [ -z "$1" ]; then
    echo "Usage: $0 <version> [build_number]"
    exit 1
fi

VERSION=$1
BUILD_NUMBER=$2
PLIST_PATH="Sources/MyWispr/Resources/Info.plist"

if [ -z "$BUILD_NUMBER" ]; then
    CURRENT_BUILD=$(python3 -c "
import plistlib
with open('$PLIST_PATH', 'rb') as f:
    plist = plistlib.load(f)
print(plist.get('CFBundleVersion', '1'))
")
    BUILD_NUMBER=$((CURRENT_BUILD + 1))
fi

echo "Bumping version to $VERSION (Build $BUILD_NUMBER)..."

# Edit plist
python3 -c "
import plistlib
with open('$PLIST_PATH', 'rb') as f:
    plist = plistlib.load(f)
plist['CFBundleShortVersionString'] = '$VERSION'
plist['CFBundleVersion'] = '$BUILD_NUMBER'
with open('$PLIST_PATH', 'wb') as f:
    plistlib.dump(plist, f)
"

# Update README.md
python3 -c "
import re
with open('README.md', 'r') as f:
    content = f.read()

match = re.search(r'Download-v([\d\.]+)-blue', content)
if match:
    old_version = match.group(1)
    print(f'Replacing README version references: {old_version} -> $VERSION')
    content = content.replace(f'v{old_version}', f'v$VERSION')
    content = content.replace(f'MyWispr-{old_version}.dmg', f'MyWispr-$VERSION.dmg')
    
    changelog_marker = '## Releases & Changelog\n\n'
    new_entry = '- **v$VERSION** — Release v$VERSION.\n'
    content = content.replace(changelog_marker, changelog_marker + new_entry)
    
    with open('README.md', 'w') as f:
        f.write(content)
else:
    print('Error: Could not parse old version in README.md')
"

echo "Staging changes and committing..."
git add "$PLIST_PATH" README.md
git commit -m "Bump version to $VERSION"
git push origin main

echo "Building MyWispr in release mode..."
swift build -c release

echo "Packaging and ad-hoc codesigning app bundle..."
rm -rf .dist
mkdir -p .dist/MyWispr.app/Contents/MacOS
mkdir -p .dist/MyWispr.app/Contents/Resources
cp .build/release/MyWispr .dist/MyWispr.app/Contents/MacOS/MyWispr
cp "$PLIST_PATH" .dist/MyWispr.app/Contents/Info.plist
cp MyWispr.icns .dist/MyWispr.app/Contents/Resources/MyWispr.icns
codesign --force --deep --sign - .dist/MyWispr.app

echo "Creating DMG..."
DMG_NAME="MyWispr-$VERSION.dmg"
hdiutil create -volname MyWispr -srcfolder .dist -ov -format UDZO "$DMG_NAME"
rm -rf .dist

echo "Creating git tag v$VERSION..."
git tag "v$VERSION"
git push origin "v$VERSION"

echo "Uploading $DMG_NAME to GitHub releases..."
CREDENTIALS=$(echo "url=https://github.com" | git credential fill)
TOKEN=$(echo "$CREDENTIALS" | grep password | cut -d= -f2)

# Create/Ensure Release exists on GitHub
RELEASE_RESP=$(curl -s -X POST -H "Authorization: token $TOKEN" \
  -H "Accept: application/vnd.github.v3+json" \
  https://api.github.com/repos/abennat-cyber/MyWispr/releases \
  -d "{\"tag_name\":\"v$VERSION\",\"name\":\"v$VERSION\",\"body\":\"Release v$VERSION\"}")

RELEASE_ID=$(echo "$RELEASE_RESP" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data.get('id', ''))
")

# If release exists already, get release by tag
if [ -z "$RELEASE_ID" ] || [ "$RELEASE_ID" == "None" ]; then
    RELEASE_RESP=$(curl -s -H "Authorization: token $TOKEN" \
      https://api.github.com/repos/abennat-cyber/MyWispr/releases/tags/v$VERSION)
    RELEASE_ID=$(echo "$RELEASE_RESP" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data.get('id', ''))
")
fi

if [ -z "$RELEASE_ID" ] || [ "$RELEASE_ID" == "None" ]; then
    echo "Error: Could not retrieve or create GitHub Release ID."
    exit 1
fi

# Delete existing asset if it exists
ASSET_ID=$(echo "$RELEASE_RESP" | python3 -c "
import sys, json
data = json.load(sys.stdin)
assets = data.get('assets', [])
for asset in assets:
    if asset.get('name') == '$DMG_NAME':
        print(asset.get('id'))
        break
")

if [ -n "$ASSET_ID" ] && [ "$ASSET_ID" != "None" ]; then
    echo "Deleting existing asset ID $ASSET_ID..."
    curl -s -X DELETE -H "Authorization: token $TOKEN" \
      "https://api.github.com/repos/abennat-cyber/MyWispr/releases/assets/$ASSET_ID"
fi

echo "Uploading $DMG_NAME..."
curl -s -X POST -H "Authorization: token $TOKEN" \
  -H "Content-Type: application/x-apple-diskimage" \
  --data-binary "@$DMG_NAME" \
  "https://uploads.github.com/repos/abennat-cyber/MyWispr/releases/$RELEASE_ID/assets?name=$DMG_NAME"

echo "Release v$VERSION successfully published!"
