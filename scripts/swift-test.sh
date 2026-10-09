#!/bin/bash
# The ONE way to run the Swift tests (#313): in a fresh throwaway home (scripts/test-home.sh),
# serially, with the standard flags. `just test`, CI's `test` job and the documented one-liners all
# come through here.
#
#   scripts/swift-test.sh                   the whole suite (--filter TranscriberTests)
#   scripts/swift-test.sh <filter> [args]   one suite or test; the extra args go to `swift test`
#
# The home is created and checked in statements of their own, under `set -e`: if it cannot be
# made, or is empty, missing or the real home, nothing runs. (An empty CFFIXED_USER_HOME means the
# REAL home, where a test that falls back to Config.default records into ~/Documents/Recordings
# and runs the storage limit over it.)
#
# --no-parallel is load-bearing: run in parallel, the suite wedges a shared media daemon (test.yml).
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

home=$(bash "$here/test-home.sh")
bash "$here/test-home.sh" --check "$home"
export CFFIXED_USER_HOME="$home"

filter="${1:-TranscriberTests}"
[ "$#" -eq 0 ] || shift
exec swift test --no-parallel --filter "$filter" "$@" \
  -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/
