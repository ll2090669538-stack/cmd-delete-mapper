#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP_DIR="$ROOT_DIR/build/一键删除映射器.app"
CONTENTS_DIR="$APP_DIR/Contents"

mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"

swiftc -O \
  -framework AppKit \
  -framework CoreGraphics \
  -framework ApplicationServices \
  "$ROOT_DIR/main.swift" \
  -o "$CONTENTS_DIR/MacOS/CmdDelMapper"

cp "$ROOT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP_DIR"

printf 'Built app at: %s\n' "$APP_DIR"
