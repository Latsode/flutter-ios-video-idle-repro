#!/usr/bin/env python3
"""Run the repro app on an iOS Simulator and measure idle cost per phase.

An app running in the iOS Simulator is an ordinary macOS process, so its CPU
use can be read with `ps` and its native call stacks with `sample`. Neither
needs a physical device or Instruments.

Usage (on macOS with Xcode and Flutter installed):
    flutter build ios --simulator --debug
    python3 tool/measure_ios_sim.py
"""

import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

BUNDLE_ID = "ge.realize.repro.iosVideoIdleRepro"
APP_PATH = Path("build/ios/iphonesimulator/Runner.app")
OUT = Path(os.environ.get("OUT", "build/repro-results"))
PHASE_SECONDS = 20
# Skip app start-up, video download and route transitions at phase start.
SETTLE_SECONDS = 7
SAMPLE_SECONDS = 3
SYMBOLS = {
    "displayLinkFired": "FVPFrameUpdater displayLinkFired",
    "textureFrameAvailable": "textureFrameAvailable",
    "DrawLastLayerTrees": "DrawLastLayerTrees",
}
EXPECTED = {
    "controlIdle": "idle",
    "bugFeed": "BUSY (bug)",
    "bugUnderOtherScreen": "BUSY (bug)",
    "fixLazyInit": "idle",
    "shownThenPaused": "idle",
    "controlIdleEnd": "idle",
}


def run(*args, check=True):
    return subprocess.run(args, check=check, capture_output=True, text=True).stdout


def pick_device():
    devices = json.loads(run("xcrun", "simctl", "list", "devices", "available", "-j"))
    iphones = [
        (runtime, d)
        for runtime, ds in devices["devices"].items()
        if "iOS" in runtime
        for d in ds
        if d["name"].startswith("iPhone")
    ]
    if not iphones:
        sys.exit("No available iPhone simulator")
    booted = [d for _, d in iphones if d["state"] == "Booted"]
    runtime, device = (None, booted[0]) if booted else sorted(iphones, key=lambda x: x[0])[-1]
    return device


def current_phase(log_path):
    try:
        lines = log_path.read_text().splitlines()
    except FileNotFoundError:
        return None, None, []
    phase, started = None, None
    for line in lines:
        parts = line.split()
        if len(parts) >= 3 and parts[1] == "PHASE":
            phase, started = parts[2], int(parts[0]) / 1000
        elif len(parts) >= 2 and parts[1] == "DONE":
            phase, started = "DONE", int(parts[0]) / 1000
    return phase, started, lines


def max_samples(sample_text, needle):
    best = 0
    for line in sample_text.splitlines():
        if needle in line:
            match = re.search(r"(\d+)\s", line.strip(" +!:|"))
            if match:
                best = max(best, int(match.group(1)))
    return best


def main():
    if not APP_PATH.exists():
        sys.exit(f"{APP_PATH} missing; run: flutter build ios --simulator --debug")
    OUT.mkdir(parents=True, exist_ok=True)

    device = pick_device()
    udid = device["udid"]
    print(f"Simulator: {device['name']} ({udid})")
    if device["state"] != "Booted":
        run("xcrun", "simctl", "boot", udid, check=False)
    run("xcrun", "simctl", "bootstatus", udid, "-b")
    run("xcrun", "simctl", "install", udid, str(APP_PATH))

    launch = run(
        "xcrun", "simctl", "launch", "--terminate-running-process",
        f"--stdout={OUT.resolve()}/app_stdout.log",
        f"--stderr={OUT.resolve()}/app_stderr.log",
        udid, BUNDLE_ID,
    )
    pid = int(launch.strip().split(":")[-1])
    print(f"Launched pid {pid}")

    data_dir = Path(run("xcrun", "simctl", "get_app_container", udid, BUNDLE_ID, "data").strip())
    log_path = data_dir / "tmp" / "repro_phases.log"

    cpu = {}
    sampled = set()
    samplers = []
    deadline = time.time() + PHASE_SECONDS * (len(EXPECTED) + 2)
    while time.time() < deadline:
        phase, started, _ = current_phase(log_path)
        if phase == "DONE":
            break
        if phase is None:
            time.sleep(1)
            continue
        elapsed = time.time() - started
        if SETTLE_SECONDS <= elapsed < PHASE_SECONDS - 1:
            value = run("ps", "-p", str(pid), "-o", "%cpu=", check=False).strip()
            if not value:
                sys.exit("App process exited early; see app_stderr.log")
            cpu.setdefault(phase, []).append(float(value))
            if phase not in sampled:
                sampled.add(phase)
                samplers.append(subprocess.Popen(
                    ["sample", str(pid), str(SAMPLE_SECONDS), "-file", str(OUT / f"sample_{phase}.txt")],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                ))
        time.sleep(1)

    for sampler in samplers:
        sampler.wait()
    _, _, lines = current_phase(log_path)
    (OUT / "phases.log").write_text("\n".join(lines) + "\n")

    rows = []
    for phase, expected in EXPECTED.items():
        values = cpu.get(phase, [])
        avg = sum(values) / len(values) if values else float("nan")
        sample_path = OUT / f"sample_{phase}.txt"
        text = sample_path.read_text(errors="replace") if sample_path.exists() else ""
        counts = {k: max_samples(text, needle) for k, needle in SYMBOLS.items()}
        rows.append((phase, expected, avg, len(values), counts))

    header = (
        "| Phase | Expected | Avg CPU % (idle window) | ps samples "
        "| displayLinkFired | textureFrameAvailable | DrawLastLayerTrees |"
    )
    table = [header, "|" + "---|" * 7]
    for phase, expected, avg, n, c in rows:
        table.append(
            f"| {phase} | {expected} | {avg:.1f} | {n} | {c['displayLinkFired']} "
            f"| {c['textureFrameAvailable']} | {c['DrawLastLayerTrees']} |"
        )
    note = (
        f"\nStack columns: peak sample count containing the symbol during a "
        f"{SAMPLE_SECONDS}s `sample` of the app (0 = never seen). "
        "Symbols may be missing if the engine binary is stripped; CPU % is the primary signal.\n"
    )
    summary = "\n".join(table) + "\n" + note
    (OUT / "summary.md").write_text(summary)
    print(summary)

    init_lines = [l for l in lines if "INIT" in l]
    print(f"Video init events: {len(init_lines)}")
    for line in init_lines:
        print("  " + line)

    if summary_file := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(summary_file, "a") as f:
            f.write("## iOS Simulator idle-cost measurement\n\n" + summary)


if __name__ == "__main__":
    main()
