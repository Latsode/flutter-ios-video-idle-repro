#!/usr/bin/env python3
"""Run the repro app on an iOS Simulator and measure idle cost per phase.

An app running in the iOS Simulator is an ordinary macOS process, so its CPU
use can be read with `ps` and its native call stacks with `sample`. Neither
needs a physical device or Instruments.

Each scenario runs in a fresh app launch so a leak in one scenario cannot
affect another.

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
LABEL = os.environ.get("REPRO_LABEL", "")
PHASE_SECONDS = 20
PHASES = ["baseline", "active", "afterDispose"]
SCENARIOS = ["eagerThumbnail", "eagerThumbnailUnderRoute", "eagerShown", "lazy"]
# Skip app start-up, video download and route transitions at phase start.
SETTLE_SECONDS = 8
SAMPLE_SECONDS = 3
SYMBOLS = {
    "displayLinkFired": "displayLinkFired",
    "textureFrameAvailable": "textureFrameAvailable",
    "DrawLastLayerTrees": "DrawLastLayerTrees",
}
BUSY_CPU = 10.0


def run(*args, check=True, env=None):
    return subprocess.run(args, check=check, capture_output=True, text=True, env=env).stdout


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
    return booted[0] if booted else sorted(iphones, key=lambda x: x[0])[-1][1]


def read_log(log_path):
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


def run_scenario(udid, scenario, log_path):
    run("xcrun", "simctl", "terminate", udid, BUNDLE_ID, check=False)
    log_path.unlink(missing_ok=True)
    env = dict(os.environ, SIMCTL_CHILD_REPRO_SCENARIO=scenario)
    launch = run(
        "xcrun", "simctl", "launch",
        f"--stdout={OUT.resolve()}/{scenario}_stdout.log",
        f"--stderr={OUT.resolve()}/{scenario}_stderr.log",
        udid, BUNDLE_ID, env=env,
    )
    pid = int(launch.strip().split(":")[-1])
    print(f"[{scenario}] pid {pid}", flush=True)

    cpu, sampled, samplers = {}, set(), []
    deadline = time.time() + PHASE_SECONDS * (len(PHASES) + 2)
    while time.time() < deadline:
        phase, started, _ = read_log(log_path)
        if phase == "DONE":
            break
        if phase is None:
            time.sleep(1)
            continue
        elapsed = time.time() - started
        if SETTLE_SECONDS <= elapsed < PHASE_SECONDS - 1:
            value = run("ps", "-p", str(pid), "-o", "%cpu=", check=False).strip()
            if not value:
                sys.exit(f"[{scenario}] app exited early; see {scenario}_stderr.log")
            cpu.setdefault(phase, []).append(float(value))
            if phase not in sampled:
                sampled.add(phase)
                samplers.append(subprocess.Popen(
                    ["sample", str(pid), str(SAMPLE_SECONDS), "-file",
                     str(OUT / f"sample_{scenario}_{phase}.txt")],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                ))
        time.sleep(1)
    for sampler in samplers:
        sampler.wait()

    _, _, lines = read_log(log_path)
    (OUT / f"{scenario}_phases.log").write_text("\n".join(lines) + "\n")
    events = {
        "INITIALIZED": sum(" INITIALIZED" in l for l in lines),
        "INIT_FAILED": sum(" INIT_FAILED" in l for l in lines),
        "DISPOSED": sum(" DISPOSED" in l for l in lines),
    }

    rows = []
    for phase in PHASES:
        values = cpu.get(phase, [])
        avg = sum(values) / len(values) if values else float("nan")
        path = OUT / f"sample_{scenario}_{phase}.txt"
        text = path.read_text(errors="replace") if path.exists() else ""
        counts = {k: max_samples(text, needle) for k, needle in SYMBOLS.items()}
        rows.append((scenario, phase, avg, len(values), counts))
    return rows, events


def main():
    if not APP_PATH.exists():
        sys.exit(f"{APP_PATH} missing; run: flutter build ios --simulator --debug")
    OUT.mkdir(parents=True, exist_ok=True)

    device = pick_device()
    udid = device["udid"]
    print(f"Simulator: {device['name']} ({udid})", flush=True)
    if device["state"] != "Booted":
        run("xcrun", "simctl", "boot", udid, check=False)
    run("xcrun", "simctl", "bootstatus", udid, "-b")
    run("xcrun", "simctl", "install", udid, str(APP_PATH))
    data_dir = Path(run("xcrun", "simctl", "get_app_container", udid, BUNDLE_ID, "data").strip())
    log_path = data_dir / "tmp" / "repro_phases.log"

    table = [
        "| Scenario | Phase | Avg CPU % | ps samples | Verdict "
        "| displayLinkFired | textureFrameAvailable | DrawLastLayerTrees |",
        "|" + "---|" * 8,
    ]
    event_lines = []
    for scenario in SCENARIOS:
        rows, events = run_scenario(udid, scenario, log_path)
        event_lines.append(f"- {scenario}: {events}")
        for _, phase, avg, n, c in rows:
            verdict = "BUSY" if avg >= BUSY_CPU else "idle"
            table.append(
                f"| {scenario} | {phase} | {avg:.1f} | {n} | {verdict} "
                f"| {c['displayLinkFired']} | {c['textureFrameAvailable']} "
                f"| {c['DrawLastLayerTrees']} |"
            )

    title = f"## iOS Simulator idle cost {LABEL}".rstrip()
    summary = (
        f"{title}\n\nSimulator: {device['name']}\n\n"
        + "\n".join(table)
        + f"\n\nPhases are {PHASE_SECONDS}s; CPU is averaged from second {SETTLE_SECONDS} "
        "of each phase. Stack columns: peak sample count containing the symbol "
        f"during a {SAMPLE_SECONDS}s `sample` of the app (0 = not seen).\n\n"
        "Video events per scenario:\n" + "\n".join(event_lines) + "\n"
    )
    (OUT / "summary.md").write_text(summary)
    print(summary)
    if summary_file := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(summary_file, "a") as f:
            f.write(summary)


if __name__ == "__main__":
    main()
