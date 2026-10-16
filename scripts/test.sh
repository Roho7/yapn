#!/bin/sh
# Until the Xcode license is accepted, Command Line Tools need Testing.framework passed explicitly.
set -e
if swift --version >/dev/null 2>&1; then
  exec swift test "$@"
fi
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
DEVELOPER_DIR=/Library/Developer/CommandLineTools exec swift test \
  -Xswiftc -F -Xswiftc "$F" -Xlinker -F -Xlinker "$F" -Xlinker -rpath -Xlinker "$F" "$@"
