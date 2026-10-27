#!/usr/bin/env python3
"""Sample RSS, rolling ps CPU, and cumulative process CPU time (not physical footprint)."""
import argparse
import datetime as dt
import json
import subprocess
import sys
import time


def parse_cpu_time(value):
    """Parse ps [[days-]hours:]minutes:seconds, including fractional seconds."""
    days, separator, clock = value.partition("-")
    if not separator:
        days, clock = "0", days
    parts = clock.split(":")
    if len(parts) not in (2, 3):
        raise ValueError("invalid process CPU time")
    seconds = float(parts[-1]) + 60 * int(parts[-2])
    if len(parts) == 3:
        seconds += 3600 * int(parts[0])
    return int(days) * 86400 + seconds


def read_process(pid):
    result = subprocess.run(
        ["ps", "-p", str(pid), "-o", "rss=,%cpu=,time=,stat=,comm="],
        capture_output=True, text=True, check=False,
    )
    if result.returncode != 0 and result.stderr.strip():
        raise RuntimeError("ps sampling failed: " + result.stderr.strip())
    line = result.stdout.strip()
    if not line:
        return None
    parts = line.split(None, 4)
    try:
        if parts[3].startswith("Z"):
            return None
        return {"pid": pid, "rssKiB": int(parts[0]), "cpuPercent": float(parts[1]),
                "cpuTimeSeconds": parse_cpu_time(parts[2]),
                "command": parts[4] if len(parts) > 4 else ""}
    except (ValueError, IndexError):
        return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pids", required=True, help="Comma-separated process IDs")
    parser.add_argument("--duration", required=True, type=float, help="Sampling duration in seconds")
    parser.add_argument("--period", required=True, type=float, help="Seconds between samples")
    parser.add_argument("--status", default="unspecified", help="Human-readable state at sampling time")
    parser.add_argument("--output", help="Write JSON to this path (default: stdout)")
    args = parser.parse_args()
    pids = [int(value) for value in args.pids.split(",") if value.strip()]
    if not pids or args.duration < 0 or args.period <= 0:
        parser.error("provide PIDs, duration >= 0, and period > 0")

    started = time.monotonic()
    samples = []
    index = 0
    while True:
        sampled_at = dt.datetime.now(dt.timezone.utc).isoformat()
        processes = [read_process(pid) for pid in pids]
        alive = [proc for proc in processes if proc is not None]
        samples.append({
            "sample": index + 1,
            "timestamp": sampled_at,
            "processes": [proc if proc is not None else {"pid": pid, "alive": False}
                          for pid, proc in zip(pids, processes)],
            "totalRssKiB": sum(proc["rssKiB"] for proc in alive),
            "totalRssMiB": round(sum(proc["rssKiB"] for proc in alive) / 1024, 2),
            "totalCpuPercent": round(sum(proc["cpuPercent"] for proc in alive), 2),
        })
        index += 1
        elapsed = time.monotonic() - started
        if elapsed >= args.duration:
            break
        time.sleep(min(args.period, max(0, args.duration - elapsed)))

    document = {
        "pids": pids, "durationSeconds": args.duration, "periodSeconds": args.period,
        "status": args.status, "sampleCount": len(samples), "samples": samples,
    }
    output = json.dumps(document, indent=2) + "\n"
    if args.output:
        with open(args.output, "w", encoding="utf-8") as stream:
            stream.write(output)
    else:
        sys.stdout.write(output)


if __name__ == "__main__":
    main()
