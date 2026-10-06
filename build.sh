#!/bin/sh
# ./build.sh            build build/PortBar.app (universal)
# ./build.sh install    build, copy to /Applications, launch
# ./build.sh release    build and package build/PortBar-v<version>.dmg
# ./build.sh test       unit tests
# ./build.sh publish X.Y.Z   bump, tag, GitHub release, update the Homebrew cask
set -e
cd "$(dirname "$0")"
APP=build/PortBar.app
BIN="$APP/Contents/MacOS/PortBar"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)

if [ "$1" = publish ]; then
  NEW=${2:?usage: ./build.sh publish X.Y.Z}
  TAP=${TAP_DIR:-../homebrew-tap}
  [ -z "$(git status --porcelain)" ] || { echo "working tree not clean"; exit 1; }
  swift test
  BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" Info.plist) + 1 ))
  /usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $NEW" -c "Set CFBundleVersion $BUILD" Info.plist
  sed -i '' "s/PortBar [0-9.]* |/PortBar $NEW |/" README.md
  git commit -qam "chore: release $NEW"
  git tag -a "v$NEW" -m "PortBar $NEW"
  git push -q --follow-tags
  "$0" release
  gh release create "v$NEW" "build/PortBar-v$NEW.dmg" --title "PortBar $NEW" --generate-notes
  SHA=$(shasum -a 256 "build/PortBar-v$NEW.dmg" | cut -d' ' -f1)
  sed -i '' -e "s/version \".*\"/version \"$NEW\"/" -e "s/sha256 \".*\"/sha256 \"$SHA\"/" "$TAP/Casks/portbar.rb"
  git -C "$TAP" commit -qam "feat: portbar $NEW"
  git -C "$TAP" push -q
  echo "published $NEW; update with: brew upgrade --cask portbar"
  exit 0
fi

if [ "$1" = test ]; then
  exec swift test
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
for arch in arm64 x86_64; do
  swiftc -Osize -whole-module-optimization -module-name PortBar -target "$arch-apple-macos13.0" \
    Sources/PortCore/*.swift Sources/PortBar/*.swift -o "build/PortBar-$arch"
done
lipo -create build/PortBar-arm64 build/PortBar-x86_64 -output "$BIN"
strip -x "$BIN"
rm build/PortBar-arm64 build/PortBar-x86_64
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"

case "$1" in
  install)
    pkill -x PortBar || true
    rm -rf /Applications/PortBar.app
    cp -R "$APP" /Applications/
    ln -sf /Applications/PortBar.app/Contents/MacOS/PortBar "${CLI_DIR:-/opt/homebrew/bin}/portbar"
    open /Applications/PortBar.app
    ;;
  release)
    STAGE=build/dmg
    rm -rf "$STAGE" "build/PortBar-v$VERSION.dmg"
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -quiet -volname PortBar -srcfolder "$STAGE" -ov -format UDZO "build/PortBar-v$VERSION.dmg"
    rm -rf "$STAGE"
    shasum -a 256 "build/PortBar-v$VERSION.dmg"
    ;;
esac
