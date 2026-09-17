#!/bin/sh
# Build the disposable Stage K fixture into fixtures/app/CUFixture.app.
set -e
cd "$(dirname "$0")"

APP=CUFixture.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -o "$APP/Contents/MacOS/CUFixture" main.swift \
  -framework AppKit -framework Foundation

cp Info.plist "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/CUFixture"

echo "built $APP"
echo "run:  open $APP   (or: $APP/Contents/MacOS/CUFixture)"
