#!/bin/bash
# Tests for scripts/test-home.sh --remove and scripts/swift-test.sh's cleanup (#355): a throwaway
# home with a read-only disk image mounted inside it (as Xcode mounts its Metal toolchain on CI) is
# removed; a home that cannot be removed only warns; a path test-home.sh did not make is never
# touched; and the cleanup keeps the run's own exit status.
set -euo pipefail
cd "$(dirname "$0")/.."
fail=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

work=$(mktemp -d "${TMPDIR:-/tmp}/test-test-home.XXXXXX")
mnt="$work/parley-test-home.mounted/mnt"
# shellcheck disable=SC2329  # invoked by the trap
cleanup() {
  /usr/bin/hdiutil detach -force "$mnt" >/dev/null 2>&1 || true
  chmod -R u+w "$work" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

# 1. A read-only image mounted inside the home.
home="$work/parley-test-home.mounted"
mkdir -p "$mnt" "$work/src"
echo x > "$work/src/file"
/usr/bin/hdiutil create -quiet -srcfolder "$work/src" -format UDRO "$work/ro.dmg"
/usr/bin/hdiutil attach -quiet -readonly -nobrowse -mountpoint "$mnt" "$work/ro.dmg"
if [ -f "$mnt/file" ]; then ok "the image is mounted inside the home"; else bad "the image is mounted inside the home"; fi
if rm -rf "$home" 2>/dev/null; then bad "rm -rf alone cannot remove it"; else ok "rm -rf alone cannot remove it"; fi
status=0; bash scripts/test-home.sh --remove "$home" || status=$?
if [ "$status" = 0 ]; then ok "--remove exits 0"; else bad "--remove exits 0 (got $status)"; fi
if [ ! -e "$home" ]; then ok "--remove detached the image and removed the home"; else bad "--remove detached the image and removed the home"; fi

# 2. A home that cannot be removed warns and still exits 0.
home="$work/parley-test-home.stuck"
mkdir -p "$home/locked"; echo x > "$home/locked/file"; chmod 500 "$home/locked"
status=0; err=$(bash scripts/test-home.sh --remove "$home" 2>&1 >/dev/null) || status=$?
if [ "$status" = 0 ]; then ok "an unremovable home exits 0"; else bad "an unremovable home exits 0 (got $status)"; fi
if [[ "$err" == *"could not remove"* ]]; then ok "an unremovable home warns"; else bad "an unremovable home warns"; fi
chmod 700 "$home/locked"

# 3. Never a path test-home.sh did not make.
other="$work/not-a-test-home"; mkdir -p "$other"
bash scripts/test-home.sh --remove "$other"
if [ -d "$other" ]; then ok "a path outside the pattern is left alone"; else bad "a path outside the pattern is left alone"; fi

# 4. swift-test.sh's cleanup keeps the run's exit status (its own function and trap, run as is).
cleanup_src=$(sed -n '/^remove_home()/,/^trap remove_home EXIT$/p' scripts/swift-test.sh)
[ -n "$cleanup_src" ] || bad "swift-test.sh defines remove_home and traps it"
for want in 0 3; do
  home="$work/parley-test-home.trap$want"
  status=0
  bash -c "set -euo pipefail; here=scripts; home='$home'; mkdir -p \"\$home\"
$cleanup_src
exit $want" || status=$?
  if [ "$status" = "$want" ]; then ok "the cleanup keeps exit status $want"; else bad "the cleanup keeps exit status $want (got $status)"; fi
  if [ ! -e "$home" ]; then ok "the cleanup removed the home (status $want)"; else bad "the cleanup removed the home (status $want)"; fi
done

exit "$fail"
