#!/bin/zsh
set -euo pipefail
script_dir=${0:A:h}
xcodebuild -project "$script_dir/Rocam.xcodeproj" -scheme Rocam -configuration Debug -derivedDataPath "$script_dir/.build" CODE_SIGNING_ALLOWED=NO build
