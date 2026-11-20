"""Regression checks for runner images carrying runtimes newer than Xcode."""

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import Mock, patch


spec = importlib.util.spec_from_file_location(
    "ci_ios_simulator", Path(__file__).with_name("ci-ios-simulator.py"),
)
ci = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci)
RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-27-1"
UDID = "469F5BD3-0000-0000-0000-000000000000"


def runtime(version="27.1", available=True):
    return {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-" + version.replace(".", "-"),
            "version": version, "isAvailable": available}


class SimulatorTests(unittest.TestCase):
    def test_xcode_27_0_sdk_ignores_27_1_and_27_2_runtimes(self):
        self.assertEqual(ci.select_runtime(
            [runtime("27.2"), runtime("27.1"), runtime("27.0")], "27.0",
        ), "com.apple.CoreSimulator.SimRuntime.iOS-27-0")

    def test_sdk_match_wins_over_newer_runtime(self):
        self.assertEqual(ci.select_runtime([runtime("27.2"), runtime()], "27.1"), RUNTIME)
        self.assertEqual(ci.select_runtime([runtime()], "27.1.0"), RUNTIME)

    def test_missing_or_unavailable_match_fails(self):
        for runtimes in ([], [runtime("27.2")], [runtime(available=False)]):
            with self.subTest(runtimes=runtimes), self.assertRaisesRegex(RuntimeError, "SDK 27.1"):
                ci.select_runtime(runtimes, "27.1")

    def test_available_runtime_accepts_an_installed_match(self):
        runtimes = json.dumps({"runtimes": [runtime("27.2"), runtime("27.0")]})
        with patch.object(ci, "run", return_value=runtimes), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(ci.available_runtime("27.0"),
                             "com.apple.CoreSimulator.SimRuntime.iOS-27-0")

    def test_available_runtime_rejects_a_missing_match(self):
        runtimes = json.dumps({"runtimes": [runtime("27.2"), runtime("27.0", available=False)]})
        with patch.object(ci, "run", return_value=runtimes), contextlib.redirect_stdout(io.StringIO()):
            self.assertIsNone(ci.available_runtime("27.0"))

    def simulate(self, *, destinations=None, fail=None):
        def run(*command, **kwargs):
            if fail and fail in command:
                raise RuntimeError("Timed out: " + fail)
            if "--show-sdk-version" in command:
                return "27.1"
            if "runtimes" in command:
                return json.dumps({"runtimes": [runtime("27.2"), runtime()]})
            if "devices" in command:
                return json.dumps({"devices": {
                    RUNTIME: [{"name": "iPhone 18 Pro", "udid": "seeded-image-device",
                               "state": "Shutdown", "isAvailable": True}],
                    runtime("27.2")["identifier"]: [{"name": "iPhone 17", "udid": "wrong",
                                                     "isAvailable": True}],
                }})
            if "create" in command:
                return UDID
            if "-showdestinations" in command:
                return destinations if destinations is not None else (
                    "{ platform:iOS Simulator, arch:arm64, id:" + UDID + ", OS:27.1, name:iPhone 16 }")
            return ""
        return patch.object(ci, "run", side_effect=run)

    def test_boot_precedes_destination_check_and_build(self):
        with self.simulate() as run, contextlib.redirect_stdout(io.StringIO()):
            ci.test()
        commands = [call.args for call in run.call_args_list]
        boot = commands.index(("xcrun", "simctl", "boot", UDID))
        bootstatus = commands.index(("xcrun", "simctl", "bootstatus", UDID, "-b"))
        resolution = next(i for i, command in enumerate(commands)
                          if "-resolvePackageDependencies" in command)
        discovery = next(i for i, command in enumerate(commands) if "-showdestinations" in command)
        build = next(i for i, command in enumerate(commands) if "build-for-testing" in command)
        self.assertLess(boot, bootstatus)
        self.assertLess(bootstatus, resolution)
        self.assertLess(resolution, discovery)
        self.assertLess(discovery, build)
        self.assertEqual(run.call_args_list[bootstatus].kwargs["timeout"], 300)
        self.assertEqual(run.call_args_list[resolution].kwargs["timeout"], 1500)
        self.assertEqual(run.call_args_list[discovery].kwargs["timeout"], 300)
        self.assertEqual(run.call_args_list[build].kwargs["timeout"], 1500)
        test = run.call_args_list[-1]
        self.assertIn("test-without-building", test.args)
        self.assertEqual(test.kwargs["timeout"], 1500)
        self.assertEqual(test.kwargs["test_activity_timeout"], 300)
        self.assertIn("platform=iOS Simulator,id=" + UDID, test.args)

    def test_creates_fresh_device_on_matched_runtime(self):
        with self.simulate() as run, contextlib.redirect_stdout(io.StringIO()):
            ci.test()
        run.assert_any_call("xcrun", "simctl", "create", "ci-iphone", "iPhone 16", RUNTIME, capture=True)
        self.assertFalse(any("devices" in call.args for call in run.call_args_list))

    def test_absent_or_ineligible_destination_stops_before_build(self):
        for destinations in ("{ platform:macOS, id:" + UDID + " }",
                             "{ platform:iOS Simulator, id:another-device }",
                             "{ platform:iOS Simulator, id:" + UDID + ", error:unavailable }"):
            with self.subTest(destinations=destinations), self.simulate(destinations=destinations) as run:
                with contextlib.redirect_stdout(io.StringIO()), self.assertRaisesRegex(RuntimeError, "absent"):
                    ci.test()
                self.assertFalse(any("build-for-testing" in call.args for call in run.call_args_list))

    def test_failure_reports_image_and_diagnostics(self):
        for fail in ("bootstatus", "-resolvePackageDependencies",
                     "-showdestinations", "build-for-testing", "test-without-building"):
            output = io.StringIO()
            with self.simulate(fail=fail) as run, patch.dict(os.environ, {"ImageVersion": "20261119.0378.1"}):
                with contextlib.redirect_stdout(output):
                    self.assertEqual(ci.main(), 1)
            self.assertIn("::error::", output.getvalue())
            self.assertIn("20261119.0378.1", output.getvalue())
            run.assert_any_call("xcrun", "simctl", "list", "runtimes", timeout=30)
            run.assert_any_call("xcodebuild", "-showsdks", timeout=30)
            run.assert_any_call("xcode-select", "-p", timeout=30)

    def test_command_timeout_reaps_process(self):
        processes = []
        popen = subprocess.Popen

        def start(*args, **kwargs):
            process = popen(*args, **kwargs)
            processes.append(process)
            return process

        for activity_timeout in (None, 0.05):
            with self.subTest(activity_timeout=activity_timeout):
                with contextlib.redirect_stdout(io.StringIO()), patch.object(ci.subprocess, "Popen", side_effect=start):
                    with self.assertRaisesRegex(RuntimeError, "Timed out"):
                        ci.run(sys.executable, "-c", "import time; time.sleep(30)",
                               timeout=1 if activity_timeout else 0.05,
                               test_activity_timeout=activity_timeout, capture=True)
                self.assertIsNotNone(processes[-1].returncode)

    def test_monitored_command_streams_output_and_preserves_exit_status(self):
        for status in (0, 7):
            output = io.StringIO()
            command = (sys.executable, "-c",
                       "import sys; print('◇ Test bridge() started.'); "
                       f"print('runner diagnostic', file=sys.stderr); sys.exit({status})")
            with self.subTest(status=status), contextlib.redirect_stdout(output):
                if status:
                    with self.assertRaisesRegex(RuntimeError, "Exit 7"):
                        ci.run(*command, timeout=5, test_activity_timeout=1)
                else:
                    ci.run(*command, timeout=5, test_activity_timeout=1)
            self.assertIn("◇ Test bridge() started.", output.getvalue())
            self.assertIn("runner diagnostic", output.getvalue())

    @contextlib.contextmanager
    def simulate_test_session(self, events):
        """Drive pipe readiness and a monotonic clock without real five-minute waits."""
        clock = [0]
        chunks = []

        def select(timeout):
            if events and events[0][0] <= clock[0] + timeout:
                when, chunk = events.pop(0)
                clock[0] = when
                chunks.append(chunk)
                return [True]
            clock[0] += timeout
            return []

        selector = Mock()
        selector.select.side_effect = select
        process = Mock()
        output = io.StringIO()
        with patch.object(ci.time, "monotonic", side_effect=lambda: clock[0]), \
                patch.object(ci.selectors, "DefaultSelector") as factory, \
                patch.object(ci.os, "read", side_effect=lambda *args: chunks.pop(0)), \
                contextlib.redirect_stdout(output):
            factory.return_value.__enter__.return_value = selector
            yield process, clock, output

    def test_active_session_can_exceed_five_minutes(self):
        events = [(100, '◇ Suite "GitKitSSHBridge threading" started.\n'.encode()),
                  (350, '◇ Test bridge() started.\n'.encode()),
                  (600, '✔ Test bridge() passed after 250 seconds.\n'.encode()),
                  (650, b"")]
        with self.simulate_test_session(events) as (process, clock, output):
            ci.wait_for_tests(process, ("xcodebuild",), 1500, 300)
            self.assertEqual(clock[0], 650)
            self.assertIn("passed after 250 seconds", output.getvalue())

    def test_silent_launch_fails_within_five_minutes(self):
        with self.simulate_test_session([]) as (process, clock, _):
            with self.assertRaises(subprocess.TimeoutExpired) as error:
                ci.wait_for_tests(process, ("xcodebuild",), 1500, 300)
            self.assertEqual(error.exception.timeout, 300)
            self.assertEqual(clock[0], 300)

    def test_xcode_diagnostics_do_not_extend_launch_timeout(self):
        events = [(100, b"Preparing test runner\n"), (250, b"Simulator diagnostics\n")]
        with self.simulate_test_session(events) as (process, clock, _):
            with self.assertRaises(subprocess.TimeoutExpired):
                ci.wait_for_tests(process, ("xcodebuild",), 1500, 300)
            self.assertEqual(clock[0], 300)

    def test_stalled_session_fails_after_five_minutes_without_activity(self):
        events = [(100, b"Test Case '-[Tests bridge]' started.\n")]
        with self.simulate_test_session(events) as (process, clock, _):
            with self.assertRaises(subprocess.TimeoutExpired):
                ci.wait_for_tests(process, ("xcodebuild",), 1500, 300)
            self.assertEqual(clock[0], 400)

    def test_active_session_still_has_an_overall_bound(self):
        events = [(when, b"Test Case '-[Tests bridge]' passed.\n")
                  for when in range(100, 1600, 100)]
        with self.simulate_test_session(events) as (process, clock, _):
            with self.assertRaises(subprocess.TimeoutExpired) as error:
                ci.wait_for_tests(process, ("xcodebuild",), 1500, 300)
            self.assertEqual(error.exception.timeout, 1500)
            self.assertEqual(clock[0], 1500)

    def test_activity_split_across_pipe_reads_is_recognized(self):
        events = [(100, b'\xe2'), (150, b'\x97\x87 Test bridge() star'),
                  (200, b'ted.\n'), (450, b"")]
        with self.simulate_test_session(events) as (process, clock, output):
            ci.wait_for_tests(process, ("xcodebuild",), 1500, 300)
            self.assertEqual(clock[0], 450)
            self.assertEqual(output.getvalue(), "◇ Test bridge() started.\n")

    def test_closed_output_does_not_remove_timeout(self):
        with self.simulate_test_session([(100, b"")]) as (process, _, _):
            process.wait.side_effect = subprocess.TimeoutExpired(("xcodebuild",), 200)
            with self.assertRaises(subprocess.TimeoutExpired) as error:
                ci.wait_for_tests(process, ("xcodebuild",), 1500, 300)
            process.wait.assert_called_once_with(timeout=200)
            self.assertEqual(error.exception.timeout, 300)


if __name__ == "__main__":
    unittest.main()
