#!/usr/bin/env python3
"""Anonymize a scrim-positions CSV for demos and tests.

Ship types become their closest mining-hull equivalent (capsules stay capsules) and
each pilot becomes "<Faction> Citizen <7 digits>". The seed keeps output reproducible.

    scripts/anonymize.py resouces/matches/out/match_03.positions.csv resouces/demo/match_03.positions.csv
"""
import argparse
import csv
import random
import sys

FACTIONS = ["Amarr", "Caldari", "Gallente", "Minmatar"]

# Combat hull -> mining hull of roughly the same size class.
#   frigate -> Venture, T2 frigate -> Prospect, destroyer -> Endurance,
#   T1/faction cruiser -> mining barge, T2 cruiser -> exhumer,
#   battlecruiser / command ship -> Porpoise, battleship -> Orca
SHIP_MAP = {
    "Capsule": "Capsule",
    # frigates
    "Punisher": "Venture",
    "Vigil": "Venture",
    "Geri": "Venture",
    "Deacon": "Prospect",
    "Thalia": "Prospect",
    # command destroyers
    "Magus": "Endurance",
    "Pontifex": "Endurance",
    # cruisers
    "Augoror Navy Issue": "Procurer",
    "Stratios": "Retriever",
    "Ashimmu": "Covetor",
    "Deimos": "Skiff",
    "Oneiros": "Mackinaw",
    # battlecruisers / command ships
    "Harbinger Navy Issue": "Porpoise",
    "Absolution": "Porpoise",
    "Astarte": "Porpoise",
    "Eos": "Porpoise",
    # battleships
    "Armageddon": "Orca",
    "Armageddon Navy Issue": "Orca",
}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("input")
    ap.add_argument("output")
    ap.add_argument("--seed", type=int, default=3)
    args = ap.parse_args()

    rng = random.Random(args.seed)
    names: dict[str, str] = {}
    used: set[str] = set()

    def pilot_name(pilot: str) -> str:
        if pilot not in names:
            while True:
                name = f"{rng.choice(FACTIONS)} Citizen {rng.randrange(10**7):07d}"
                if name not in used:
                    break
            used.add(name)
            names[pilot] = name
        return names[pilot]

    with open(args.input, newline="") as fin:
        reader = csv.DictReader(fin)
        rows = list(reader)
        fields = reader.fieldnames

    unknown = sorted({r["ship_type"] for r in rows} - SHIP_MAP.keys())
    if unknown:
        print(f"no mining equivalent for: {', '.join(unknown)}", file=sys.stderr)
        return 1

    # Assign names in sorted order so the mapping doesn't depend on row order.
    for pilot in sorted({r["pilot"] for r in rows}, key=str.lower):
        pilot_name(pilot)

    with open(args.output, "w", newline="") as fout:
        writer = csv.DictWriter(fout, fieldnames=fields, lineterminator="\n")
        writer.writeheader()
        for r in rows:
            r["pilot"] = names[r["pilot"]]
            if "raw_name" in r:
                r["raw_name"] = r["pilot"]
            r["ship_type"] = SHIP_MAP[r["ship_type"]]
            writer.writerow(r)
    return 0


if __name__ == "__main__":
    sys.exit(main())
