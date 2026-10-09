#!/bin/bash
# Proves a test run left the user's records alone (#313).
#   test-canary.sh run <command...>  snapshot, run the command, verify. Exits with the command's
#                                    status, or 1 if the command passed but the canary fails.
#   test-canary.sh snapshot <file>   list every file under the real recording folder, Parley's
#                                    real Application Support folder (config.json, the recording
#                                    sentinel recording.json, ...) and the LaunchAgent plist
#                                    (path, size, mtime), into <file>
#   test-canary.sh verify <file>     list again. A file removed fails the run. A file added or
#                                    changed fails it too, unless the Parley app is running — it
#                                    may be recording — when they are listed as a warning; so is
#                                    a removed app file then, but never a removed recording.
# The recording folder is read from the real config.json (`recording_directory`), defaulting to
# ~/Documents/Recordings. A folder that is a link (to an external disk or a NAS) is followed; links
# inside it are not. A folder that does not exist (CI) lists as empty.
set -euo pipefail
real_home=$(cd ~ && pwd -P)
support="$real_home/Library/Application Support/Parley"
agents="$real_home/Library/LaunchAgents"
rec=$(/usr/bin/python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("recording_directory") or "")
except Exception: print("")' "$support/config.json")
rec=${rec:-$real_home/Documents/Recordings}
rec=${rec/#\~/$real_home}

listing() {
  {
    # -H: follow the folder itself when it is a link, not the links inside it.
    [ -d "$rec" ] && find -H "$rec" -type f -print0 2>/dev/null | xargs -0 stat -f '%m %z %N' 2>/dev/null
    [ -d "$support" ] && find -H "$support" -type f -print0 2>/dev/null | xargs -0 stat -f '%m %z %N' 2>/dev/null
    [ -d "$agents" ] && find "$agents" -maxdepth 1 -iname '*parley*' -print0 2>/dev/null | xargs -0 stat -f '%m %z %N' 2>/dev/null
  } | LC_ALL=C sort -u || true
}

verify() {
  local now removed touched
  now=$(mktemp)
  listing > "$now"
  names() { sed 's/^[0-9]* [0-9]* //' "$1" | LC_ALL=C sort; }
  removed=$(LC_ALL=C comm -23 <(names "$1") <(names "$now"))
  touched=$(LC_ALL=C comm -13 "$1" "$now")
  rm -f "$now"
  if [ -n "$removed" ] || [ -n "$touched" ]; then
    echo
    echo "TEST CANARY (#313): files under $rec, Parley's Application Support folder or its LaunchAgent changed during the test run."
    [ -z "$removed" ] || { echo "Removed:"; printf '%s\n' "$removed" | sed -n '1,20p'; }
    [ -z "$touched" ] || { echo "Added or changed:"; printf '%s\n' "$touched" | sed -n '1,20p'; }
    # The running app adds and changes files, and removes its own state (recording.json when a
    # recording ends): only a removed recording still fails the run then.
    # A here-string, not `printf | grep -q`: grep -q stops at the first match, a long list then
    # SIGPIPEs printf, and pipefail would turn that into "no recording removed".
    if pgrep -qx Parley && ! grep -qF -- "$rec/" <<<"$removed"; then
      echo "Parley is running and may have done this itself; check them. Not failing the run."
      return 0
    fi
    echo "Tests must never touch real recordings, config or app state. Find the test that resolves a real path."
    return 1
  fi
  echo "Test canary: the user's recordings, Parley's app data and its LaunchAgent are untouched."
}

case "${1:-}" in
  snapshot) listing > "$2" ;;
  verify) verify "$2" ;;
  run)
    shift
    [ "$#" -gt 0 ] || { echo "usage: $0 run <command...>" >&2; exit 2; }
    snap=$(mktemp)
    listing > "$snap"
    rc=0
    # An interrupted run is still checked: it is the one most likely to have stopped half-way
    # through a test that deletes.
    trap 'verify "$snap" || :; rm -f "$snap"; exit 130' INT
    trap 'verify "$snap" || :; rm -f "$snap"; exit 143' TERM
    "$@" || rc=$?
    trap - INT TERM
    canary=0
    verify "$snap" || canary=$?
    rm -f "$snap"
    [ "$rc" -ne 0 ] && exit "$rc"
    exit "$canary"
    ;;
  *) echo "usage: $0 run <command...> | snapshot <file> | verify <file>" >&2; exit 2 ;;
esac
