#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p .build/module-cache
xcrun swiftc -O -swift-version 5 -module-cache-path "$PWD/.build/module-cache" Search/Models.swift Search/Database.swift Search/MediaReader.swift Search/Indexer.swift Search/FileOperations.swift Search/FileClipboard.swift Tests/main.swift -o .build/search-tests -framework AVFoundation -framework CoreServices -framework AppKit -lsqlite3
python3 Tests/make_fixtures.py .build/fixture.mov
.build/search-tests "$PWD/.build/fixture.mov"
