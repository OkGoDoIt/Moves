#!/usr/bin/env python3
"""Read a copied Moves SQLite store and print aggregate evidence-quality counts.

No coordinates, place names, comments, or trip identifiers are emitted. This is
an audit of recorded evidence, not a claim that a mode or a replacement is true.
Run against a backup, never the app's live store.
"""
import argparse
import collections
import datetime
import json
import math
import pathlib
import sqlite3


def distance(a, b):
    p, q = math.radians(a["ZLATITUDE"]), math.radians(b["ZLATITUDE"])
    delta = math.radians(b["ZLONGITUDE"] - a["ZLONGITUDE"])
    haversine = math.sin((q - p) / 2) ** 2 + math.cos(p) * math.cos(q) * math.sin(delta / 2) ** 2
    return 12_742_000 * math.asin(min(1, math.sqrt(haversine)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("store", type=pathlib.Path)
    parser.add_argument("--since", help="Include trips starting on/after this ISO date (UTC).")
    args = parser.parse_args()
    connection = sqlite3.connect(args.store.resolve().as_uri() + "?mode=ro", uri=True)
    connection.row_factory = sqlite3.Row
    samples = connection.execute("SELECT * FROM ZLOCATIONSAMPLE").fetchall()
    moves = connection.execute("SELECT * FROM ZMOVESEGMENT").fetchall()
    if args.since:
        since = datetime.datetime.fromisoformat(args.since).replace(tzinfo=datetime.timezone.utc)
        epoch = datetime.datetime(2001, 1, 1, tzinfo=datetime.timezone.utc)
        moves = [m for m in moves if m["ZSTARTDATE"] >= (since - epoch).total_seconds()]
    by_move = collections.defaultdict(list)
    for sample in samples:
        by_move[sample["ZMOVESEGMENT"]].append(sample)
    report = {"moves": len(moves), "store_samples": len(samples), "modes": {}}
    for mode in sorted({m["ZTRANSPORTMODERAWVALUE"] for m in moves}):
        group = [m for m in moves if m["ZTRANSPORTMODERAWVALUE"] == mode]
        flags = collections.Counter()
        for move in group:
            points = sorted(by_move[move["Z_PK"]], key=lambda p: p["ZTIMESTAMP"])
            if len(points) < 3:
                flags["fewer_than_three_points"] += 1
            if not move["ZSTEPCOUNT"]:
                flags["no_positive_step_count"] += 1
            if any(p["ZSOURCERAWVALUE"] == "fileRouteImport" for p in points):
                flags["includes_imported_points"] += 1
            pairs = []
            for a, b in zip(points, points[1:]):
                seconds = b["ZTIMESTAMP"] - a["ZTIMESTAMP"]
                if seconds <= 0:
                    continue
                meters = distance(a, b)
                uncertainty = max(0, a["ZHORIZONTALACCURACY"]) + max(0, b["ZHORIZONTALACCURACY"])
                pairs.append((seconds, meters / seconds, max(0, meters - uncertainty) / seconds))
            if any(seconds > 300 for seconds, _, _ in pairs):
                flags["gap_over_five_minutes"] += 1
            if any(seconds < 5 and speed > 9 for seconds, speed, _ in pairs):
                flags["brief_apparent_vehicle_speed_jump"] += 1
            if any(speed > 4.5 and lower < 2 for _, speed, lower in pairs):
                flags["cycling_speed_pair_not_excluding_walking_with_recorded_accuracy"] += 1
        report["modes"][mode] = {"count": len(group), **flags}
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
