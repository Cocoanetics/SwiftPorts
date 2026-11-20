#!/usr/bin/env python3
"""Prepare an SDK-matched simulator and bound discovery, boot and test launch."""

import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys


SIMULATOR_BOOT_TIMEOUT = 300
DESTINATION_DISCOVERY_TIMEOUT = 300
PACKAGE_RESOLUTION_TIMEOUT = 1500


def run(*command, timeout=120, capture=False):
    print("+ " + " ".join(command), flush=True)
    process = subprocess.Popen(
        command, start_new_session=True, text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None,
    )
    try:
        output, _ = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
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
        raise RuntimeError(f"Timed out after {timeout}s: {' '.join(command)}")
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
    # A separate test phase bounds the zero-tests/launch hang without charging
    # compilation against that limit. Per-test timeouts cannot catch launch hangs.
    run(*common, *destination, "-parallel-testing-enabled", "NO",
        "test-without-building", timeout=300)


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
