#!/bin/bash
# Wrapper around the Makefile that never touches the Xcode license check.
#
# /usr/bin/make (and /usr/bin/swift, clang, ...) are xcode-select shims; with Xcode selected as
# the active developer directory but its license unaccepted, the shims abort with
# "You have not agreed to the Xcode license agreements" before our Makefile even runs.
# Calling CLT's own make with DEVELOPER_DIR pinned sidesteps that entirely.
#
#   tools/build_app.sh            # == make (release app)
#   tools/build_app.sh run        # build + open
#   tools/build_app.sh test
#   tools/build_app.sh verify
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
exec /Library/Developer/CommandLineTools/usr/bin/make "$@"
