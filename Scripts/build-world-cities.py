#!/usr/bin/env python3
"""Builds Moves/WorldCities.tsv from the GeoNames cities5000 dump.

    python3 -I Scripts/build-world-cities.py <cities5000.txt> Moves/WorldCities.tsv

Source: https://download.geonames.org/export/dump/cities5000.zip (CC BY 4.0).

The dump lists city districts beside the cities they belong to. Two rules sort them out:
sections of a city (PPLX and similar) are dropped, and so is any place that lies within a
much larger city of the same first-level region: anywhere inside it when it is ten times
smaller, or well inside it when it is two and a half times smaller.

Columns, tab separated: name, country, latitude x 10^4, longitude x 10^4, population.
Sorted so a rebuild gives a readable diff.
"""

import math
import re
import sys
import unicodedata

# Sections, farms, abandoned and historical places, and settlements.
DROPPED_FEATURES = {"PPLX", "PPLH", "PPLCH", "PPLQ", "PPLW", "PPLF", "PPLL"}
RADIUS_PER_ROOT_PERSON_KM = 0.0085
# (how many times larger the other city is, how far into its radius counts as inside)
DOMINANCE = ((2.5, 0.55), (10, 1.0))
CELL = 1.0

# Vietnamese administrative words GeoNames keeps in some names.
VIETNAMESE_PREFIXES = ("Thanh Pho ", "Thi Xa ", "Thi Tran ", "Huyen ", "Xa ", "Ap ")


def radius_km(population):
    return RADIUS_PER_ROOT_PERSON_KM * math.sqrt(population)


def distance_km(a, b):
    mean = math.radians((a["lat"] + b["lat"]) / 2)
    dx = (a["lon"] - b["lon"]) * 111.32 * math.cos(mean)
    dy = (a["lat"] - b["lat"]) * 110.57
    return math.hypot(dx, dy)


def display_name(name, country):
    name = re.sub(r"\s+", " ", name).strip()
    if country != "VN":
        return name
    # Apple's names for Vietnam have no diacritics; match them.
    for barred in "ĐÐ":
        name = name.replace(barred, "D")
    name = name.replace("đ", "d")
    plain = unicodedata.normalize("NFD", name)
    plain = "".join(c for c in plain if not unicodedata.combining(c))
    for prefix in VIETNAMESE_PREFIXES:
        if plain.startswith(prefix):
            return plain[len(prefix):]
    return plain


def main():
    source, target = sys.argv[1], sys.argv[2]
    cities = []
    with open(source, encoding="utf-8") as handle:
        for line in handle:
            row = line.rstrip("\n").split("\t")
            if row[7] in DROPPED_FEATURES or int(row[14]) <= 0:
                continue
            cities.append({
                "name": display_name(row[1], row[8]),
                "country": row[8],
                "region": row[10],
                "lat": float(row[4]),
                "lon": float(row[5]),
                "population": int(row[14]),
            })

    grid = {}
    for city in cities:
        key = (math.floor(city["lat"] / CELL), math.floor(city["lon"] / CELL))
        grid.setdefault(key, []).append(city)

    kept = []
    for city in cities:
        row, column = math.floor(city["lat"] / CELL), math.floor(city["lon"] / CELL)
        dropped = False
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                for other in grid.get((row + dy, column + dx), ()):
                    if other is city or other["country"] != city["country"]:
                        continue
                    if other["region"] != city["region"]:
                        continue
                    ratio = other["population"] / city["population"]
                    if ratio < DOMINANCE[0][0]:
                        continue
                    reach = distance_km(city, other) / radius_km(other["population"])
                    dropped = dropped or any(ratio >= r and reach < d for r, d in DOMINANCE)
        if not dropped:
            kept.append(city)

    kept.sort(key=lambda c: (c["country"], -c["population"], c["name"]))
    with open(target, "w", encoding="utf-8") as handle:
        for c in kept:
            handle.write("\t".join([
                c["name"], c["country"], str(round(c["lat"] * 1e4)), str(round(c["lon"] * 1e4)),
                str(c["population"]),
            ]) + "\n")
    print(f"{len(cities)} places read, {len(kept)} written")


if __name__ == "__main__":
    main()
