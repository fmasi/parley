// The test process refuses to run in the user's real home (#313).
//
// A test that falls back to Config.default records into NSHomeDirectory()/Documents/Recordings and
// runs a 15 h storage limit over it: run in the real home, it deletes the user's archives. The
// suite therefore runs with CFFIXED_USER_HOME set to a throwaway home (scripts/swift-test.sh). An
// EMPTY value means the real home, and a one-line `CFFIXED_USER_HOME="$(...)" swift test` passes
// an empty value when the command that makes the home fails.
//
// Swift Testing has no process-wide setup, so this check is a C constructor: it runs when the test
// bundle is loaded, before any suite. If CFFIXED_USER_HOME is unset, empty, missing, or resolves
// to the user's real home, it prints why and exits the process: no test runs, `swift test` fails.
// A check inside one test would let every other test run first.
#include "TestHomeGuard.h"

#include <limits.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int passed = 0;

static void refuse(const char *why, const char *home) {
    fprintf(stderr,
            "\nTEST HOME GUARD (#313): %s%s%s.\n"
            "The tests must never run in the user's real home: a test that falls back to\n"
            "Config.default would record into, and run the storage limit over, the real recordings.\n"
            "Run them through `bash scripts/swift-test.sh [<filter>]` or `just test`.\n\n",
            why, home ? ": " : "", home ? home : "");
    _exit(78);  // EX_CONFIG
}

static int same_dir(const char *a, const char *b) {
    char ra[PATH_MAX], rb[PATH_MAX];
    if (!a || !b || !realpath(a, ra) || !realpath(b, rb)) return 0;
    return strcmp(ra, rb) == 0;
}

__attribute__((constructor)) static void parley_test_home_guard(void) {
    const char *fixed = getenv("CFFIXED_USER_HOME");
    char resolved[PATH_MAX];
    if (!fixed || !*fixed) refuse("CFFIXED_USER_HOME is not set, so the home is the real one", NULL);
    if (!realpath(fixed, resolved)) refuse("CFFIXED_USER_HOME is not an existing folder", fixed);
    struct passwd *pw = getpwuid(getuid());
    if (pw && same_dir(fixed, pw->pw_dir)) refuse("CFFIXED_USER_HOME is the user's real home", fixed);
    if (same_dir(fixed, getenv("HOME"))) refuse("CFFIXED_USER_HOME is $HOME, the user's real home", fixed);
    passed = 1;
}

int parley_test_home_guard_passed(void) { return passed; }
