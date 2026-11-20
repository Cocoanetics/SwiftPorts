#!/usr/bin/env python3
"""Prepare an SDK-matched simulator and bound discovery, boot and test launch."""

import codecs
import json
import os
from pathlib import Path
import re
import selectors
import signal
import subprocess
import sys
import time


SIMULATOR_BOOT_TIMEOUT = 300
DESTINATION_DISCOVERY_TIMEOUT = 300
PACKAGE_RESOLUTION_TIMEOUT = 1500
TEST_SESSION_TIMEOUT = 1500
TEST_ACTIVITY_TIMEOUT = 300


def wait_for_tests(process, command, timeout, activity_timeout):
    """Stream test output, bounding both inactivity and the complete session."""
    deadline = time.monotonic() + timeout
    activity_deadline = time.monotonic() + activity_timeout
    decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
    pending = ""
    # Swift Testing and XCTest progress, rather than generic Xcode diagnostics.
    activity = re.compile(r"(?:^|[◇✔✘] )(?:Test|Suite) .+ (?:started|passed|failed)\b"
                          r"|^Test (?:Case|Suite) '")
    with selectors.DefaultSelector() as selector:
        selector.register(process.stdout, selectors.EVENT_READ)
        while True:
            now = time.monotonic()
            if now >= deadline:
                raise subprocess.TimeoutExpired(command, timeout)
            if now >= activity_deadline:
                raise subprocess.TimeoutExpired(command, activity_timeout)
            if not selector.select(min(deadline, activity_deadline) - now):
                continue
            chunk = os.read(process.stdout.fileno(), 65536)
            output = decoder.decode(chunk, final=not chunk)
            print(output, end="", flush=True)
            pending += output
            lines = pending.split("\n")
            pending = lines.pop()
            if any(activity.search(line) for line in lines):
                activity_deadline = time.monotonic() + activity_timeout
            if not chunk:
                # EOF can precede process exit; keep the remaining wait bounded.
                try:
                    process.wait(timeout=max(0, min(deadline, activity_deadline) - time.monotonic()))
                except subprocess.TimeoutExpired:
                    limit = timeout if deadline <= activity_deadline else activity_timeout
                    raise subprocess.TimeoutExpired(command, limit)
                return


def run(*command, timeout=120, capture=False, test_activity_timeout=None):
    print("+ " + " ".join(command), flush=True)
    process = subprocess.Popen(
        command, start_new_session=True, text=True,
        stdout=subprocess.PIPE if capture or test_activity_timeout else None,
        stderr=subprocess.STDOUT if capture or test_activity_timeout else None,
    )
    try:
        if test_activity_timeout:
            wait_for_tests(process, command, timeout, test_activity_timeout)
            output = ""
        else:
            output, _ = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired as error:
        # Include child test runners, which otherwise survive xcodebuild.
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            pass
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        output, _ = process.communicate()
        if output:
            print(output, flush=True)
        reason = " without test activity" if error.timeout == test_activity_timeout else ""
        raise RuntimeError(f"Timed out after {error.timeout}s{reason}: {' '.join(command)}")
    finally:
        if process.stdout:
            process.stdout.close()
    if process.returncode:
        if output:
            print(output, flush=True)
        raise RuntimeError(f"Exit {process.returncode}: {' '.join(command)}")
    return (output or "").strip()


def version(value):
    # CoreSimulator may spell the SDK's 27.1 as 27.1.0.
    parts = [int(part) for part in value.split(".")]
    while len(parts) > 1 and parts[-1] == 0:
        parts.pop()
    return parts


def select_runtime(runtimes, sdk):
    for runtime in runtimes:
        if (runtime.get("isAvailable")
                and runtime["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")
                and version(runtime["version"]) == version(sdk)):
            return runtime["identifier"]
    raise RuntimeError(f"No available iOS runtime matches selected SDK {sdk}")


def available_runtime(sdk):
    runtimes = json.loads(run("xcrun", "simctl", "list", "runtimes", "--json", capture=True))
    try:
        runtime = select_runtime(runtimes["runtimes"], sdk)
    except RuntimeError:
        return None
    print(f"Found available iOS {sdk} runtime: {runtime}", flush=True)
    return runtime


def test():
    sdk = run("xcrun", "--sdk", "iphonesimulator", "--show-sdk-version", capture=True)
    runtime = available_runtime(sdk)
    if runtime is None:
        raise RuntimeError(f"No available iOS runtime matches selected SDK {sdk}")
    devices = json.loads(run("xcrun", "simctl", "list", "devices", "available", "--json", capture=True))
    device = next((device for device in devices["devices"].get(runtime, [])
                   if device.get("isAvailable") and device["name"].startswith("iPhone")), None)
    udid = device["udid"] if device else run(
        "xcrun", "simctl", "create", "ci-iphone", "iPhone 16", runtime, capture=True,
    )
    print(f"Testing iOS SDK {sdk}, runtime {runtime}, simulator {udid}", flush=True)
    if not device or device.get("state") != "Booted":
        run("xcrun", "simctl", "boot", udid)
    run("xcrun", "simctl", "bootstatus", udid, "-b", timeout=SIMULATOR_BOOT_TIMEOUT)

    # Keep all Xcode products outside the checkout, including destination probes.
    build_root = Path(os.environ.get("RUNNER_TEMP", "/tmp")) / "SwiftPorts-iOS"
    common = ("xcodebuild", "-scheme", "SwiftPorts-Package",
              "-derivedDataPath", str(build_root / "DerivedData"))
    # A clean runner resolves and downloads the full package graph here. Keep
    # that work out of the shorter destination-discovery budget.
    run(*common, "-resolvePackageDependencies", timeout=PACKAGE_RESOLUTION_TIMEOUT)
    destinations = run(
        *common, "-showdestinations", timeout=DESTINATION_DISCOVERY_TIMEOUT, capture=True,
    )
    print(destinations, flush=True)
    if not any(re.search(r"platform:iOS Simulator\s*[,}]", line)
               and re.search(r"id:" + re.escape(udid) + r"\s*[,}]", line)
               and "error:" not in line for line in destinations.splitlines()):
        raise RuntimeError(f"SDK {sdk} simulator {udid} is absent from eligible scheme destinations")
    destination = ("-destination", f"platform=iOS Simulator,id={udid}", "-destination-timeout", "60")
    run(*common, *destination, "build-for-testing", timeout=1500)
    # Bound silent launch/stalls to five minutes, while active suites can run
    # longer. Keep a separate overall cap even if tests continually make progress.
    run(*common, *destination, "-parallel-testing-enabled", "NO",
        "test-without-building", timeout=TEST_SESSION_TIMEOUT,
        test_activity_timeout=TEST_ACTIVITY_TIMEOUT)


def main():
    image = f"{os.environ.get('ImageOS', 'unknown')} {os.environ.get('ImageVersion', 'unknown')}"
    print(f"Runner image: {image}", flush=True)
    try:
        test()
    except (RuntimeError, ValueError, KeyError, OSError) as error:
        print(f"::error::iOS Simulator CI failed on image {image}: {error}", flush=True)
        for command in (("xcrun", "simctl", "list", "runtimes"),
                        ("xcodebuild", "-showsdks"), ("xcode-select", "-p")):
            try:
                run(*command, timeout=30)
            except (RuntimeError, OSError) as diagnostic_error:
                print(f"Diagnostic failed: {diagnostic_error}", flush=True)
        return 1
    return 0


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--check-runtime":
        raise SystemExit(0 if available_runtime(sys.argv[2]) else 1)
    raise SystemExit(main())
