#ifndef PARLEY_TEST_HOME_GUARD_H
#define PARLEY_TEST_HOME_GUARD_H

/// 1 once the guard has checked, as the test bundle loaded, that the test process runs in a
/// throwaway home (#313). The bundle exits before any test runs otherwise, so a test that sees 0
/// means the guard is not linked in.
int parley_test_home_guard_passed(void);

#endif
