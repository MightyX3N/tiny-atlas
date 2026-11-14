#!/bin/sh
# Builds a world to ride from an OpenStreetMap file, with VoxBox:
#
#   tools/build_world.sh area.osm.pbf "Route name" LAT1 LON1 LAT2 LON2 [LAT LON ...]
#
# plans a bike route through the points, cuts the map around it, builds the voxel tiles into world/
# (or WORLD=dir). Needs python3 with osmium (pip install osmium) and luajit.
set -e
[ $# -ge 6 ] || { sed -n 2,8p "$0"; exit 1; }
HERE="$(cd "$(dirname "$0")/.." && pwd)"
VB="$HERE/voxbox"
PBF="$1"; NAME="$2"; shift 2
OUT="${WORLD:-$HERE/world}"
CORRIDOR="${CORRIDOR:-300}"   # full detail this far either side of the route (m)
FAR="${FAR:-1000}"             # a lighter 40 cm version of the area out to here
WORK="$HERE/build/map"
mkdir -p "$WORK"

python3 "$VB/tools/route_plan.py" "$PBF" "$WORK/route.gpx" "$@" --name="$NAME"
# the map around the route, with room for the corridor
BBOX=$(python3 - "$WORK/route.gpx" "$FAR" <<'PY'
import math, re, sys
pts = [(float(a), float(b)) for a, b in re.findall(r'lat="([-\d.]+)" lon="([-\d.]+)"', open(sys.argv[1]).read())]
m = float(sys.argv[2]) + 200.0
la = [p[0] for p in pts]; lo = [p[1] for p in pts]
dla = m / 111320.0; dlo = m / (111320.0 * math.cos(math.radians(sum(la) / len(la))))
print(min(la) - dla, min(lo) - dlo, max(la) + dla, max(lo) + dlo)
PY
)
python3 "$VB/tools/osm_extract.py" "$PBF" "$WORK/area.lua" $BBOX
rm -rf "$OUT"
luajit "$VB/builder/build.lua" "$WORK/area.lua" "$WORK/route.gpx" "$OUT" "$CORRIDOR" "far=$FAR"
# what can be seen from each stretch of the route (the game loads exactly that, ahead of the rider)
luajit "$VB/builder/visibility.lua" "$OUT"
echo "world built in $OUT"
