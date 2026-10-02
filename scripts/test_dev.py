#!/usr/bin/env python3
"""Tests for dev.py's argument handling (#271): which configuration it builds, and that the
build-only path never installs. Nothing here builds, installs, kills or launches anything.

Run with: python3 -m unittest scripts.test_dev -v
      or: cd scripts && python3 -m unittest test_dev -v
"""
import contextlib
import io
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dev


def plan(*argv):
    """What a run with these flags would do: (steps, configuration)."""
    args = dev.parse_args(list(argv))
    return dev.resolve_steps(args), dev.build_configuration(args)


class BuildConfigurationTests(unittest.TestCase):
    def test_the_everyday_install_is_a_release_build(self):
        steps, configuration = plan()
        self.assertEqual(steps, {"kill", "build", "install", "launch"})
        self.assertEqual(configuration, "release")
        self.assertEqual(dev.package_command(True, configuration)[-2:], ["--release", "--install"])

    def test_debug_build_is_opt_in(self):
        steps, configuration = plan("--debug-build")
        self.assertEqual(steps, {"kill", "build", "install", "launch"})
        self.assertEqual(configuration, "debug")
        self.assertNotIn("--release", dev.package_command(True, configuration))

    def test_debug_tails_the_log_and_leaves_the_build_release(self):
        steps, configuration = plan("--debug")
        self.assertIn("debug", steps)
        self.assertEqual(configuration, "release")

    def test_install_alone_also_installs_a_release_build(self):
        steps, configuration = plan("--install")
        self.assertEqual(steps, {"install"})
        self.assertEqual(configuration, "release")

    def test_build_only_never_installs(self):
        # `just build`, part of local CI: it must not touch /Applications or the running app.
        for flags in (("--build",), ("--build", "--debug-build")):
            steps, configuration = plan(*flags)
            self.assertEqual(steps, {"build"})
            self.assertNotIn("--install", dev.package_command("install" in steps, configuration))

    def test_debug_build_without_a_build_is_refused(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            dev.parse_args(["--kill", "--launch", "--debug-build"])

    def test_the_summary_names_the_configuration(self):
        self.assertIn("RELEASE build installed", dev.describe_build(True, "release"))
        self.assertIn("not installed", dev.describe_build(False, "release"))
        self.assertIn("unoptimised", dev.describe_build(True, "debug"))
        self.assertNotIn("unoptimised", dev.describe_build(True, "release"))


if __name__ == "__main__":
    unittest.main()
