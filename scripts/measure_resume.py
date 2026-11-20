"""Measure foreground requests on an already seeded simulator against the app's next list frame."""
import argparse
import datetime
import json
import os
import subprocess
import time
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("device", help="专用测试模拟器的 UDID")
parser.add_argument("output", type=Path)
parser.add_argument("--samples", type=int, default=50)
args = parser.parse_args()
env = dict(os.environ)
env.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
app = "local.saywhen.app"


def sim(*cmd):
    return subprocess.check_output(["xcrun", "simctl", *cmd], env=env, text=True).strip()


pid = sim("launch", args.device, app)
time.sleep(1)
intervals = []
for _ in range(args.samples):
    sim("launch", args.device, "com.apple.Preferences")
    time.sleep(0.65)
    start = time.time()
    if sim("launch", args.device, app) != pid:
        raise RuntimeError("App 出现新进程，不能计作热恢复")
    time.sleep(0.65)
    intervals.append((start, time.time()))

since = datetime.datetime.fromtimestamp(intervals[0][0] - 2).strftime("%Y-%m-%d %H:%M:%S")
log = sim("spawn", args.device, "log", "show", "--style", "ndjson", "--start", since,
          "--predicate", 'subsystem == "local.saywhen.app" AND eventMessage == "ListForegroundFrame"')
frames = []
for line in log.splitlines():
    entry = json.loads(line)
    if entry.get("eventMessage") == "ListForegroundFrame":
        frames.append(datetime.datetime.fromisoformat(entry["timestamp"]).timestamp())
values = []
for start, end in intervals:
    markers = [instant for instant in frames if start <= instant <= end]
    if len(markers) != 1:
        raise RuntimeError(f"一个恢复区间中得到 {len(markers)} 个列表帧标记")
    values.append(round((markers[0] - start) * 1000, 3))
args.output.write_text(json.dumps({"device": args.device, "unit": "ms", "samples": values}, indent=2) + "\n")
print(f"{len(values)} samples saved to {args.output}")
