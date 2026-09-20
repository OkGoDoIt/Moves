#!/usr/bin/env python3
"""Clean Moves All Days exports before import.

The official app glued Aug 1–Sep 13 into one unknown track (Vietnam, two
Pacific flights, the Midwest, Atlanta, then San Francisco) and added a
19-minute 'run' from Saigon to Home. This splits that track at flights and
overnight stays, drops the teleport, and rewrites GPX, GeoJSON, and CSV.
"""

from __future__ import annotations

import csv
import json
import math
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path
from xml.etree import ElementTree as ET
from zoneinfo import ZoneInfo

GPX_NS = "http://www.topografix.com/GPX/1/1"
ET.register_namespace("", GPX_NS)

STAY_GAP = timedelta(hours=4)
STAY_MAX_METERS = 250.0
FLIGHT_MIN_METERS = 80_000.0
FLIGHT_MIN_KMH = 400.0
HOME = (37.749247, -122.460294)
HOME_RADIUS_METERS = 80.0
ICT = ZoneInfo("Asia/Ho_Chi_Minh")
PACIFIC = ZoneInfo("America/Los_Angeles")


def parse_iso(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)


def iso(dt: datetime) -> str:
    utc = dt.astimezone(timezone.utc)
    millis = int(utc.microsecond / 1000)
    return utc.strftime("%Y-%m-%dT%H:%M:%S") + f".{millis:03d}Z"


def haversine_m(a: tuple[float, float], b: tuple[float, float]) -> float:
    lat1, lon1, lat2, lon2 = map(math.radians, [a[0], a[1], b[0], b[1]])
    dlat, dlon = lat2 - lat1, lon2 - lon1
    h = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    return 6371000 * 2 * math.asin(math.sqrt(h))


def day_key_for(dt: datetime, lon: float) -> str:
    zone = ICT if lon > 0 else PACIFIC
    return dt.astimezone(zone).strftime("%Y-%m-%d")


def coordinate_title(lat: float, lon: float) -> str:
    return f"{lat:.5f}, {lon:.5f}"


def is_home(lat: float, lon: float) -> bool:
    return haversine_m((lat, lon), HOME) <= HOME_RADIUS_METERS


def gpx_tag(name: str) -> str:
    return f"{{{GPX_NS}}}{name}"


def load_gpx_points(path: Path) -> list[dict]:
    root = ET.parse(path).getroot()
    for trk in root.findall(gpx_tag("trk")):
        name = (trk.findtext(gpx_tag("name")) or "")
        for seg in trk.findall(gpx_tag("trkseg")):
            pts = []
            for pt in seg.findall(gpx_tag("trkpt")):
                time_text = pt.findtext(gpx_tag("time"))
                if not time_text:
                    continue
                ele_text = pt.findtext(gpx_tag("ele"))
                pts.append(
                    {
                        "lat": float(pt.attrib["lat"]),
                        "lon": float(pt.attrib["lon"]),
                        "ele": float(ele_text) if ele_text else None,
                        "time": parse_iso(time_text),
                    }
                )
            if pts and pts[0]["time"] == parse_iso("2026-08-01T07:17:17.000Z"):
                return pts
    raise SystemExit("Could not find the Aug 1 mega-track in the GPX file")


def kmh(prev: dict, cur: dict) -> float:
    dist = haversine_m((prev["lat"], prev["lon"]), (cur["lat"], cur["lon"]))
    dt = (cur["time"] - prev["time"]).total_seconds()
    if dt <= 0:
        return 0.0
    return (dist / dt) * 3.6


def is_flight_step(prev: dict, cur: dict) -> bool:
    dist = haversine_m((prev["lat"], prev["lon"]), (cur["lat"], cur["lon"]))
    return dist >= FLIGHT_MIN_METERS and kmh(prev, cur) >= FLIGHT_MIN_KMH


def is_stay_gap(prev: dict, cur: dict) -> bool:
    dist = haversine_m((prev["lat"], prev["lon"]), (cur["lat"], cur["lon"]))
    return (cur["time"] - prev["time"]) >= STAY_GAP and dist <= STAY_MAX_METERS


def split_mega_track(points: list[dict]) -> list[dict]:
    """Cut the 43-day scribble into flights and local legs, dropping overnight pings."""
    if len(points) < 2:
        return []

    bounds = [0]
    in_flight = False
    for i in range(1, len(points)):
        prev, cur = points[i - 1], points[i]
        flight = is_flight_step(prev, cur)
        stay = is_stay_gap(prev, cur)
        if stay:
            bounds.append(i)
            in_flight = False
            continue
        if flight and not in_flight:
            bounds.append(i - 1 if i - 1 > bounds[-1] else i)
            in_flight = True
        elif in_flight and not flight:
            bounds.append(i)
            in_flight = False
    bounds.append(len(points))

    unique_bounds = []
    for index in bounds:
        if not unique_bounds or index > unique_bounds[-1]:
            unique_bounds.append(index)

    legs = []
    for start, end in zip(unique_bounds, unique_bounds[1:]):
        chunk = points[start:end]
        if len(chunk) < 2:
            continue
        dist = sum(
            haversine_m((a["lat"], a["lon"]), (b["lat"], b["lon"]))
            for a, b in zip(chunk, chunk[1:])
        )
        duration = (chunk[-1]["time"] - chunk[0]["time"]).total_seconds()
        if duration <= 0:
            continue
        # Overnight heartbeats: two pings, no real travel.
        if dist < 40 and duration >= STAY_GAP.total_seconds():
            continue
        avg_kmh = (dist / duration) * 3.6
        mode = "plane" if avg_kmh >= 300 and dist >= 150_000 else "unknown"
        start_place = "Home" if is_home(chunk[0]["lat"], chunk[0]["lon"]) else coordinate_title(chunk[0]["lat"], chunk[0]["lon"])
        end_place = "Home" if is_home(chunk[-1]["lat"], chunk[-1]["lon"]) else coordinate_title(chunk[-1]["lat"], chunk[-1]["lon"])
        legs.append(
            {
                "points": chunk,
                "mode": mode,
                "distance": dist,
                "start_place": start_place,
                "end_place": end_place,
                "day_key": day_key_for(chunk[0]["time"], chunk[0]["lon"]),
            }
        )
    return merge_adjacent_flights(legs)


def merge_adjacent_flights(legs: list[dict]) -> list[dict]:
    """Keep one transcontinental hop instead of a trail of 200 km plane stubs."""
    if not legs:
        return []
    merged = [legs[0]]
    for leg in legs[1:]:
        prev = merged[-1]
        gap = (leg["points"][0]["time"] - prev["points"][-1]["time"]).total_seconds()
        if prev["mode"] == "plane" and leg["mode"] == "plane" and 0 <= gap <= 45 * 60:
            merged[-1] = {
                "points": prev["points"] + leg["points"],
                "mode": "plane",
                "distance": prev["distance"] + leg["distance"],
                "start_place": prev["start_place"],
                "end_place": leg["end_place"],
                "day_key": prev["day_key"],
            }
            continue
        merged.append(leg)
    return merged


def stay_places(points: list[dict], existing: list[dict]) -> list[dict]:
    """Turn 4h+ stationary gaps into visits, labeling Home when it really is Home."""
    added = []
    for prev, cur in zip(points, points[1:]):
        if not is_stay_gap(prev, cur):
            continue
        lat, lon = prev["lat"], prev["lon"]
        arrival, departure = prev["time"], cur["time"]
        if any(
            abs((parse_iso(place["properties"]["arrival_time"]) - arrival).total_seconds()) <= 3 * 60
            and haversine_m(
                (place["geometry"]["coordinates"][1], place["geometry"]["coordinates"][0]),
                (lat, lon),
            )
            <= 90
            for place in existing + added
        ):
            continue
        props = {
            "arrival_time": iso(arrival),
            "day_key": day_key_for(arrival, lon),
            "departure_time": iso(departure),
            "record_type": "place",
            "title": "Home" if is_home(lat, lon) else coordinate_title(lat, lon),
        }
        if is_home(lat, lon):
            props["user_label"] = "Home"
        added.append(
            {
                "type": "Feature",
                "geometry": {"type": "Point", "coordinates": [lon, lat]},
                "properties": props,
            }
        )
    return added


def move_feature(leg: dict) -> dict:
    start = leg["points"][0]
    end = leg["points"][-1]
    properties = {
        "day_key": leg["day_key"],
        "distance_meters": leg["distance"],
        "end_place": leg["end_place"],
        "end_time": iso(end["time"]),
        "record_type": "move",
        "start_place": leg["start_place"],
        "start_time": iso(start["time"]),
        "transport_mode": leg["mode"],
    }
    return {
        "type": "Feature",
        "geometry": {
            "type": "LineString",
            "coordinates": [[pt["lon"], pt["lat"]] for pt in leg["points"]],
        },
        "properties": properties,
    }


def is_teleport_run(props: dict) -> bool:
    if props.get("record_type") != "move":
        return False
    if props.get("start_time") == "2026-09-13T18:15:18.981Z" and props.get("end_place") == "Home":
        return True
    dist = props.get("distance_meters") or 0
    return props.get("transport_mode") == "running" and dist > 1_000_000


def is_mega_unknown(props: dict) -> bool:
    return (
        props.get("record_type") == "move"
        and props.get("start_time") == "2026-08-01T07:17:17.000Z"
        and (props.get("distance_meters") or 0) > 1_000_000
    )


def clean_geojson(path: Path, legs: list[dict], extra_places: list[dict]) -> None:
    data = json.loads(path.read_text())
    features = []
    inserted_split = False
    for feature in data["features"]:
        props = feature.get("properties") or {}
        if props.get("record_type") == "place" and props.get("arrival_time") == "2026-04-21T12:18:59.000Z":
            props["departure_time"] = "2026-04-21T12:18:59.000Z"
            feature["properties"] = props
            features.append(feature)
            continue
        if is_teleport_run(props) or is_mega_unknown(props):
            if is_mega_unknown(props) and not inserted_split:
                features.extend(extra_places)
                features.extend(move_feature(leg) for leg in legs)
                inserted_split = True
            continue
        features.append(feature)
    if not inserted_split:
        features.extend(extra_places)
        features.extend(move_feature(leg) for leg in legs)
    path.write_text(json.dumps({"features": features, "type": "FeatureCollection"}, indent=2) + "\n")


def clean_csv(path: Path, legs: list[dict], extra_places: list[dict]) -> None:
    with path.open(newline="") as handle:
        rows = list(csv.DictReader(handle))
        fieldnames = list(rows[0].keys()) if rows else []

    cleaned = []
    inserted_split = False
    for row in rows:
        if row["record_type"] == "place" and row["start_time"] == "2026-04-21T12:18:59.000Z":
            row["end_time"] = "2026-04-21T12:18:59.000Z"
            cleaned.append(row)
            continue
        props = {
            "record_type": row["record_type"],
            "start_time": row["start_time"],
            "end_place": row["title"].split(" to ")[-1] if row["record_type"] == "move" else "",
            "distance_meters": float(row["distance_meters"]) if row["distance_meters"] else 0,
            "transport_mode": row["transport_mode"],
        }
        if is_teleport_run(props) or is_mega_unknown(props):
            if is_mega_unknown(props) and not inserted_split:
                cleaned.extend(csv_place_row(place) for place in extra_places)
                cleaned.extend(csv_move_row(leg) for leg in legs)
                inserted_split = True
            continue
        cleaned.append(row)
    if not inserted_split:
        cleaned.extend(csv_place_row(place) for place in extra_places)
        cleaned.extend(csv_move_row(leg) for leg in legs)

    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, lineterminator="\n")
        writer.writeheader()
        writer.writerows(cleaned)


def csv_place_row(place: dict) -> dict:
    props = place["properties"]
    lon, lat = place["geometry"]["coordinates"]
    return {
        "record_type": "place",
        "start_time": props["arrival_time"],
        "end_time": props.get("departure_time", ""),
        "title": props["title"],
        "day_key": props["day_key"],
        "transport_mode": "",
        "distance_meters": "",
        "step_count": "",
        "latitude": f"{lat:.6f}",
        "longitude": f"{lon:.6f}",
        "comment": "",
    }


def csv_move_row(leg: dict) -> dict:
    start, end = leg["points"][0], leg["points"][-1]
    return {
        "record_type": "move",
        "start_time": iso(start["time"]),
        "end_time": iso(end["time"]),
        "title": f"{leg['start_place']} to {leg['end_place']}",
        "day_key": leg["day_key"],
        "transport_mode": leg["mode"],
        "distance_meters": f"{leg['distance']:.2f}",
        "step_count": "",
        "latitude": "",
        "longitude": "",
        "comment": "",
    }


def xml_escape(value: str) -> str:
    return (
        value.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
        .replace("'", "&apos;")
    )


def write_gpx(path: Path, geojson_path: Path, original_gpx: Path, legs: list[dict]) -> None:
    geo = json.loads(geojson_path.read_text())
    original = ET.parse(original_gpx)
    original_root = original.getroot()

    # Keep original waypoint names except we add stay waypoints from extra places
    # by rebuilding from GeoJSON places + timed GPX tracks for moves.
    timed_by_start: dict[str, list[dict]] = {}
    for trk in original_root.findall(gpx_tag("trk")):
        for seg in trk.findall(gpx_tag("trkseg")):
            pts = []
            for pt in seg.findall(gpx_tag("trkpt")):
                time_text = pt.findtext(gpx_tag("time"))
                if not time_text:
                    continue
                ele_text = pt.findtext(gpx_tag("ele"))
                pts.append(
                    {
                        "lat": float(pt.attrib["lat"]),
                        "lon": float(pt.attrib["lon"]),
                        "ele": float(ele_text) if ele_text else None,
                        "time": parse_iso(time_text),
                    }
                )
            if pts:
                timed_by_start[iso(pts[0]["time"])] = pts
    for leg in legs:
        timed_by_start[iso(leg["points"][0]["time"])] = leg["points"]

    places = [f for f in geo["features"] if f["properties"].get("record_type") == "place"]
    moves = [f for f in geo["features"] if f["properties"].get("record_type") == "move"]

    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        f'<gpx version="1.1" creator="Moves iOS Rebuild" xmlns="{GPX_NS}">',
    ]
    for place in sorted(places, key=lambda f: f["properties"]["arrival_time"]):
        lon, lat = place["geometry"]["coordinates"]
        lines.append(f'  <wpt lat="{lat:.6f}" lon="{lon:.6f}">')
        lines.append(f'    <name>{xml_escape(place["properties"]["title"])}</name>')
        lines.append(f'    <time>{place["properties"]["arrival_time"]}</time>')
        lines.append("  </wpt>")

    by_day: dict[str, list] = defaultdict(list)
    for move in moves:
        by_day[move["properties"]["day_key"]].append(move)

    for day in sorted(by_day):
        lines.append("  <trk>")
        lines.append(f"    <name>{xml_escape(day)}</name>")
        for move in sorted(by_day[day], key=lambda f: f["properties"]["start_time"]):
            points = timed_by_start.get(move["properties"]["start_time"])
            if not points:
                coords = move["geometry"]["coordinates"]
                start = parse_iso(move["properties"]["start_time"])
                end = parse_iso(move["properties"]["end_time"])
                duration = max((end - start).total_seconds(), 1)
                points = []
                for index, (lon, lat) in enumerate(coords):
                    fraction = index / max(len(coords) - 1, 1)
                    points.append(
                        {
                            "lat": lat,
                            "lon": lon,
                            "ele": None,
                            "time": start + timedelta(seconds=duration * fraction),
                        }
                    )
            if len(points) < 2:
                continue
            lines.append("    <trkseg>")
            for point in points:
                lines.append(f'      <trkpt lat="{point["lat"]:.6f}" lon="{point["lon"]:.6f}">')
                if point.get("ele") is not None:
                    lines.append(f'        <ele>{point["ele"]:.2f}</ele>')
                lines.append(f'        <time>{iso(point["time"])}</time>')
                lines.append("      </trkpt>")
            lines.append("    </trkseg>")
        lines.append("  </trk>")
    lines.append("</gpx>")
    path.write_text("\n".join(lines) + "\n")


def summarize(geojson_path: Path) -> None:
    data = json.loads(geojson_path.read_text())
    places = [f for f in data["features"] if f["properties"].get("record_type") == "place"]
    moves = [f for f in data["features"] if f["properties"].get("record_type") == "move"]
    print(f"places {len(places)} moves {len(moves)}")
    print("modes", {mode: sum(1 for m in moves if m["properties"].get("transport_mode") == mode)
                    for mode in sorted({m["properties"].get("transport_mode") for m in moves})})
    long_moves = sorted(moves, key=lambda m: m["properties"].get("distance_meters") or 0, reverse=True)[:6]
    for move in long_moves:
        props = move["properties"]
        print(
            f"  {props['distance_meters']/1000:.1f}km {props['transport_mode']} "
            f"{props['start_time']} {props['start_place']} -> {props['end_place']}"
        )


def main() -> None:
    downloads = Path("/Users/roger/Downloads")
    geojson = downloads / "moves-all-days.geojson"
    gpx = downloads / "moves-all-days.gpx"
    csv_path = downloads / "moves-all-days.csv"

    original_geo = json.loads(geojson.read_text())
    original_places = [f for f in original_geo["features"] if f["properties"].get("record_type") == "place"]
    mega_points = load_gpx_points(gpx)
    legs = split_mega_track(mega_points)
    extras = stay_places(mega_points, original_places)

    print(f"split mega-track into {len(legs)} legs, added {len(extras)} stay places")
    for leg in legs:
        start, end = leg["points"][0], leg["points"][-1]
        print(
            f"  {leg['mode']:8} n={len(leg['points']):4} "
            f"{iso(start['time'])} -> {iso(end['time'])} "
            f"{leg['distance']/1000:.1f}km {leg['start_place']} -> {leg['end_place']}"
        )

    clean_geojson(geojson, legs, extras)
    clean_csv(csv_path, legs, extras)
    write_gpx(gpx, geojson, gpx, legs)
    summarize(geojson)

    fixtures = Path("/Users/roger/Repos/Moves/MovesTests/Fixtures")
    if fixtures.is_dir():
        for source in (geojson, gpx, csv_path):
            target = fixtures / source.name
            target.write_bytes(source.read_bytes())
            print(f"copied {source.name} -> {target}")


if __name__ == "__main__":
    main()
