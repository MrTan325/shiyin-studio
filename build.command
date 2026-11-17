#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p .build/module-cache 'dist/拾音工作台.app/Contents/MacOS' 'dist/拾音工作台.app/Contents/Resources'
xcrun swiftc -O -swift-version 5 -module-cache-path "$PWD/.build/module-cache" -target arm64-apple-macos14.0 Search/*.swift Dedup/*.swift Studio.swift -o 'dist/拾音工作台.app/Contents/MacOS/ShiyinStudio' -framework SwiftUI -framework AppKit -framework AVFoundation -framework Accelerate -framework CryptoKit -framework Metal -framework QuickLookUI -framework CoreServices -lsqlite3
cp Info.plist 'dist/拾音工作台.app/Contents/Info.plist'
cp AppIcon.icns 'dist/拾音工作台.app/Contents/Resources/AppIcon.icns'
cp -R Resources/. 'dist/拾音工作台.app/Contents/Resources/'
codesign --force --deep --sign - 'dist/拾音工作台.app'
codesign --verify --deep --strict 'dist/拾音工作台.app'
echo '已构建拾音工作台试用版。'
