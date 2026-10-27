#!/bin/sh
# Run the same core regression cases without XCTest when only Command Line Tools
# are installed. This is a standalone regression harness, not `swift test`.
set -eu
cd "$(dirname "$0")/.."
python3 Tests/run-standalone-tests.py
