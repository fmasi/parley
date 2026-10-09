#!/bin/bash
# Proves a test run left the user's records alone (#313).
#   test-canary.sh snapshot <file>   list every file under the real recording folder, and the real
#                                    config.json (path, size, mtime), into <file>
#   test-canary.sh verify <file>     list again. A file removed fails the run. A file added or
#                                    changed fails it too, unless the Parley app is running — it
#                                    may be recording — when they are listed as a warning.
# The recording folder is read from the real config.json (`recording_directory`), defaulting to
# ~/Documents/Recordings. A folder that does not exist (CI) lists as empty.
set -euo pipefail
real_home=$(cd ~ && pwd -P)
support="$real_home/Library/Application Support/Parley"
rec=$(/usr/bin/python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("recording_directory") or "")
except Exception: print("")' "$support/config.json")
rec=${rec:-$real_home/Documents/Recordings}
rec=${rec/#\~/$real_home}

listing() {
  {
    [ -d "$rec" ] && find "$rec" -type f -print0 2>/dev/null | xargs -0 stat -f '%m %z %N' 2>/dev/null
    [ -f "$support/config.json" ] && stat -f '%m %z %N' "$support/config.json"
  } | LC_ALL=C sort || true
}

case "${1:-}" in
  snapshot) listing > "$2" ;;
  verify)
    now=$(mktemp)
    listing > "$now"
    names() { sed 's/^[0-9]* [0-9]* //' "$1" | LC_ALL=C sort; }
    removed=$(LC_ALL=C comm -23 <(names "$2") <(names "$now"))
    touched=$(LC_ALL=C comm -13 "$2" "$now")
    rm -f "$now"
    if [ -n "$removed" ] || [ -n "$touched" ]; then
      echo
      echo "TEST CANARY (#313): files under $rec or Parley's config.json changed during the test run."
      [ -z "$removed" ] || { echo "Removed:"; printf '%s\n' "$removed" | sed -n '1,20p'; }
      [ -z "$touched" ] || { echo "Added or changed:"; printf '%s\n' "$touched" | sed -n '1,20p'; }
      if [ -z "$removed" ] && pgrep -qx Parley; then
        echo "Parley is running and may have written these itself; check them. Not failing the run."
        exit 0
      fi
      echo "Tests must never touch real recordings or config. Find the test that resolves a real path."
      exit 1
    fi
    echo "Test canary: the user's recordings and Parley config are untouched."
    ;;
  *) echo "usage: $0 snapshot|verify <file>" >&2; exit 2 ;;
esac
