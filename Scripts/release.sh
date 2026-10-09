#!/bin/bash
# Build a validated DMG in release/<version>/ without replacing published versions.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"
RELEASE_DIR="${RELEASE_OUTPUT_DIR:-$REPO_ROOT/release}"
APP_NAME="QuillTeX"
ARCH=arm64

# Read the Release configuration before building, so existing archives fail early.
VERSION="$(xcodebuild -project "$REPO_ROOT/$APP_NAME.xcodeproj" -scheme "$APP_NAME" \
    -configuration Release -showBuildSettings | awk '$1 == "MARKETING_VERSION" && !version { version = $3 } END { print version }')"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: invalid app version: $VERSION" >&2
    exit 1
fi
ARCHIVE_DIR="$RELEASE_DIR/$VERSION"
if [ -e "$ARCHIVE_DIR" ]; then
    echo "error: refusing to overwrite archived version: $ARCHIVE_DIR" >&2
    exit 1
fi
mkdir -p "$BUILD_DIR" "$RELEASE_DIR"
STAGING="$(mktemp -d "$BUILD_DIR/.package.XXXXXX")"
DMG_MOUNTED=0
cleanup() {
    local result=$?
    trap - EXIT
    if [ "$DMG_MOUNTED" -eq 1 ]; then
        hdiutil detach "$STAGING/mounted" -quiet || true
    fi
    rm -rf "$STAGING"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

xcodebuild -project "$REPO_ROOT/$APP_NAME.xcodeproj" -scheme "$APP_NAME" \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$BUILD_DIR/DerivedData" ARCHS="$ARCH" ONLY_ACTIVE_ARCH=YES  build
APP="$BUILD_DIR/DerivedData/Build/Products/Release/$APP_NAME.app"
BUILT_VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
if [ "$BUILT_VERSION" != "$VERSION" ]; then
    echo "error: built version $BUILT_VERSION differs from requested version $VERSION" >&2
    exit 1
fi
codesign --verify --deep --strict "$APP"
mkdir "$STAGING/image" "$STAGING/archive"
ditto "$APP" "$STAGING/image/$APP_NAME.app"
ln -s /Applications "$STAGING/image/Applications"
DMG_NAME="$APP_NAME-$VERSION.dmg"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGING/image" \
    -format UDZO "$STAGING/archive/$DMG_NAME"
hdiutil verify "$STAGING/archive/$DMG_NAME"
mkdir "$STAGING/mounted"
hdiutil attach "$STAGING/archive/$DMG_NAME" -readonly -nobrowse -mountpoint "$STAGING/mounted" -quiet
DMG_MOUNTED=1
[ "$(readlink "$STAGING/mounted/Applications")" = /Applications ]
codesign --verify --deep --strict "$STAGING/mounted/$APP_NAME.app"
/usr/sbin/mtree -c -p "$APP" -k type,link,size,sha256digest > "$STAGING/app.manifest"
/usr/sbin/mtree -p "$STAGING/mounted/$APP_NAME.app" -f "$STAGING/app.manifest"
hdiutil detach "$STAGING/mounted" -quiet
DMG_MOUNTED=0
python3 "$REPO_ROOT/Scripts/create-appcast.py" "$VERSION" "$STAGING/archive"
(cd "$STAGING/archive" && shasum -a 256 "$DMG_NAME" appcast.xml > SHA256SUMS.txt)

# mkdir exclusively claims this new version, including against concurrent builds.
# Every cleanup above is limited to this invocation's temporary packaging directory.
mkdir "$ARCHIVE_DIR"
mv "$STAGING/archive/$DMG_NAME" "$STAGING/archive/SHA256SUMS.txt" "$STAGING/archive/appcast.xml" "$ARCHIVE_DIR/"
echo "DMG: $ARCHIVE_DIR/$DMG_NAME"
(cd "$ARCHIVE_DIR" && shasum -a 256 -c SHA256SUMS.txt)
