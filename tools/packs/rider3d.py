"""The rider and the bike for the default pack.

  bike: VOiD1 Gaming's "Free Low Poly Bike Models" (the mountain bike; their licence allows use in games, the source
        files stay out of the repo): frame, rear and front wheel, cranks with pedals, handlebar - each a part turning
        about its own axle
  rider: Quaternius' "Animated Men Characters" (CC0), Male_Casual (t-shirt and shorts): parts that move rigidly with their bone, coloured
        by area (jersey, trim, shorts, socks, shoes, skin, hair, eyes) so the game's kit generator paints the kit;
        the jersey and shorts get pattern coordinates (around and up the body) for stripes, hoops, sashes...
  poses: pedalling (CRANK_FRAMES crank angles, legs by two-bone IK to the pedals, the torso leant so the hands reach
        the bars) and the run cycle (the pack's own Man_Run, sampled)

Writes lua/tinyatlas/packs/default_rider.lua and materials/tinyatlas/packs/default/rider/bike.png.
Positions in metres, x forward, y left, z up; the bike stands on the ground with its bottom bracket at x = 0.
Poses are 3x4 matrices (rows) taking a part's rest position (as stored) to where it is in that pose.

usage: python3 rider3d.py <bike fbx> <bike texture png> <man fbx: Male_Casual.fbx> <pack folder>     (needs assimp)
"""
import json, math, os, subprocess, sys, tempfile
import numpy as np
from PIL import Image

RIDER_HEIGHT = 1.78            # metres, top of the head
CRANK_FRAMES = 24
RUN_FRAMES = 20
SADDLE_BACK, SADDLE_UP = 0.0, 0.04
WHEEL_D = 0.72                        # the bike's wheels (metres across): a full-size mountain bike's   # hip joints relative to the saddle's top (metres)
LEG_REACH = 0.965              # hip to ankle at the bottom of the stroke, as a share of the leg (knee bent ~30 degrees)
ANKLE_UP = 0.03                # the ankle above the pedal spindle
MIN_LEAN = 18                  # degrees: the torso leans at least this far (a mountain bike's riding position)
ARM_REACH = 0.90
SUN = np.array([0.45, -0.35, 0.82]); SUN = SUN / np.linalg.norm(SUN)


# ---- glTF (through assimp) ----
def load_gltf(src):
    d = tempfile.mkdtemp()
    out = os.path.join(d, "m.gltf")
    subprocess.run(["assimp", "export", src, out, "-f", "gltf2"], check=True, capture_output=True)
    j = json.load(open(out))
    buf = open(os.path.join(d, j["buffers"][0]["uri"]), "rb").read()
    return j, buf


def accessor(j, buf, i):
    a = j["accessors"][i]
    bv = j["bufferViews"][a["bufferView"]]
    n = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}[a["type"]]
    dt = {5126: np.float32, 5125: np.uint32, 5123: np.uint16, 5121: np.uint8}[a["componentType"]]
    off = bv.get("byteOffset", 0) + a.get("byteOffset", 0)
    stride = bv.get("byteStride", 0)
    item = n * np.dtype(dt).itemsize
    if stride and stride != item:
        return np.array([np.frombuffer(buf, dt, n, off + k * stride) for k in range(a["count"])])
    arr = np.frombuffer(buf, dt, a["count"] * n, off)
    return arr.reshape(-1, n) if n > 1 else arr


def quat_mat(q):
    x, y, z, w = q
    return np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                     [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                     [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])


def trs(t, r, s):
    M = np.eye(4)
    M[:3, :3] = quat_mat(r) * np.array(s)
    M[:3, 3] = t
    return M


def node_local(nd):
    if "matrix" in nd:
        return np.array(nd["matrix"]).reshape(4, 4).T
    return trs(nd.get("translation", [0, 0, 0]), nd.get("rotation", [0, 0, 0, 1]), nd.get("scale", [1, 1, 1]))


def parents(j):
    p = {}
    for i, nd in enumerate(j["nodes"]):
        for c in nd.get("children", []):
            p[c] = i
    return p


def world(j, locals_, par, i):
    M = locals_[i]
    while i in par:
        i = par[i]
        M = locals_[i] @ M
    return M


def shade_of(n):
    n = n / (np.linalg.norm(n) + 1e-9)
    s = max(0.0, float(n @ SUN))
    up = max(0.0, n[2])
    return min(1.08, 0.58 + 0.30 * s + 0.14 * up)


# ---- the bike ----
BIKE_PARTS = {"Mountain Bike Body": "frame", "Mountain Bike Rear Wheel": "rear", "Mountain Bike Front Wheel": "front",
              "Mountain Bike Pedals": "cranks", "Mountain Bike Handle": "bars"}


def bike(src):
    j, buf = load_gltf(src)
    par = parents(j)
    loc = [node_local(nd) for nd in j["nodes"]]
    raw = {}
    for i, nd in enumerate(j["nodes"]):
        name = BIKE_PARTS.get(nd.get("name"))
        if not name or "mesh" not in nd:
            continue
        W = world(j, loc, par, i)
        p = j["meshes"][nd["mesh"]]["primitives"][0]
        v = accessor(j, buf, p["attributes"]["POSITION"]).astype(float)
        nrm = accessor(j, buf, p["attributes"]["NORMAL"]).astype(float)
        uv = accessor(j, buf, p["attributes"]["TEXCOORD_0"]).astype(float)
        idx = accessor(j, buf, p["indices"]).astype(int)
        vw = (W[:3, :3] @ v.T).T + W[:3, 3]
        nw = (W[:3, :3] @ nrm.T).T
        raw[name] = (vw, nw, uv, idx, W[:3, 3].copy())
    # model: y up, forward -z, x to the right -> game: x forward, y left, z up
    def game(p):
        return np.stack([-p[..., 2], -p[..., 0], p[..., 1]], axis=-1)
    frame = raw["frame"]
    saddle_m = frame[0][frame[0][:, 1] > frame[0][:, 1].max() - 8].mean(0)
    bb_m = raw["cranks"][4]
    # the size: the rider's legs reach the pedals (worked out by the caller); returned in model units first
    out = {"raw": raw, "game": game, "saddle_m": saddle_m, "bb_m": bb_m}
    # the pedals: on each side, the platform at the crank's end (the vertices farthest from the axle)
    pv = raw["cranks"][0]
    bb0 = raw["cranks"][4]
    ped = []
    for sgn in (-1, 1):
        sd = pv[pv[:, 0] * sgn > 12]
        d = np.linalg.norm((sd - bb0)[:, 1:], axis=1)
        ped.append(sd[d > d.max() - 8].mean(0))
    out["pedal_m"] = tuple(ped)
    bars = raw["bars"][0]
    grips = bars[np.abs(bars[:, 0]) > np.abs(bars[:, 0]).max() - 10]
    out["grip_m"] = (grips[grips[:, 0] < 0].mean(0), grips[grips[:, 0] > 0].mean(0))
    out["wheel_m"] = raw["rear"][0][:, 1].max() - raw["rear"][0][:, 1].min()
    return out


# ---- the man ----
# which bone a part follows (the fingers and thumbs go with the palm)
BONE_OF = {"Fingers.L": "Palm.L", "Fingers.R": "Palm.R", "MiddleHand.L": "Palm.L", "MiddleHand.R": "Palm.R",
           "Thumb1.L": "Palm.L", "Thumb1.R": "Palm.R", "Thumb2.L": "Palm.L", "Thumb2.R": "Palm.R", "Bone": "Body"}
AREA = {"Shirt": "jersey", "Shirt2": "trim", "Pants": "shorts", "Socks": "socks", "Shoes": "shoes", "Skin": "skin",
        "Hair": "hair", "Hair2": "hair", "Eyes": "eyes"}


def man(src):
    j, buf = load_gltf(src)
    par = parents(j)
    loc = [node_local(nd) for nd in j["nodes"]]
    skin = j["skins"][0]
    joints = skin["joints"]
    ibm = accessor(j, buf, skin["inverseBindMatrices"]).reshape(-1, 4, 4).transpose(0, 2, 1)
    jname = [j["nodes"][k]["name"] for k in joints]
    bind = {jname[k]: np.linalg.inv(ibm[k]) for k in range(len(joints))}     # joint world matrices at rest
    mesh_node = [i for i, nd in enumerate(j["nodes"]) if "skin" in nd][0]
    tris = []          # (bone, area, 3 x pos, 3 x normal)
    for p in j["meshes"][j["nodes"][mesh_node]["mesh"]]["primitives"]:
        mat = j["materials"][p["material"]]["name"]
        v = accessor(j, buf, p["attributes"]["POSITION"]).astype(float)
        nrm = accessor(j, buf, p["attributes"]["NORMAL"]).astype(float)
        jo = accessor(j, buf, p["attributes"]["JOINTS_0"]).astype(int)
        we = accessor(j, buf, p["attributes"]["WEIGHTS_0"]).astype(float)
        idx = accessor(j, buf, p["indices"]).astype(int).reshape(-1, 3)
        for t in idx:
            score = {}
            for k in t:
                for c in range(4):
                    if we[k, c] > 0:
                        b = jname[jo[k, c]]
                        b = BONE_OF.get(b, b)
                        score[b] = score.get(b, 0) + we[k, c]
            bone = max(score, key=score.get)
            area = AREA.get(mat, "skin")
            if mat == "Eyes" and bone != "Head":
                area = "shoes"                     # Male_Casual paints the shoes with its eyes' black
            if mat == "Socks" and not bone.startswith(("LowerLeg", "Foot")):
                area = "trim"                      # ... and the collar and waistband with its socks' colour
            tris.append((bone, area, v[t], nrm[t]))
    # the mesh's own space (Blender's): z up, facing -y, +x to the left -> game: x forward, y left, z up;
    # sized so the head's top is at RIDER_HEIGHT, feet on the ground. Mm: mesh -> game (4 x 4)
    allv = np.concatenate([t[2] for t in tris])
    s = RIDER_HEIGHT / (allv[:, 2].max() - allv[:, 2].min())
    ground = allv[:, 2].min()
    Mm = np.eye(4)
    Mm[:3, :3] = np.array([[0, -1, 0], [1, 0, 0], [0, 0, 1]], float) * s
    Mm[:3, 3] = [0, 0, -ground * s]
    def game(p):
        p = np.asarray(p, float)
        return p @ Mm[:3, :3].T + Mm[:3, 3]
    def game_dir(p):
        p = np.asarray(p, float)
        return p @ (Mm[:3, :3] / s).T
    Wm = world(j, loc, par, mesh_node)                   # mesh -> the armature's world, at rest
    jp = {n: game(B[:3, 3]) for n, B in bind.items()}
    # ends of the end bones (nodes in the armature's world)
    Wmi = np.linalg.inv(Wm)
    for i, nd in enumerate(j["nodes"]):
        if nd.get("name", "").endswith("_end"):
            jp[nd["name"]] = game((Wmi @ world(j, loc, par, i))[:3, 3])
    return {"j": j, "buf": buf, "par": par, "loc": loc, "bind": bind, "tris": tris, "s": s, "game": game,
            "game_dir": game_dir, "jp": jp, "Mm": Mm, "Wm": Wm, "ibm": {jname[k]: ibm[k] for k in range(len(joints))}}


# ---- poses ----
def rot_y(a):
    c, s = math.cos(a), math.sin(a)
    return np.array([[c, 0, s], [0, 1, 0], [-s, 0, c]])


def frame_of(d, side):
    d = d / np.linalg.norm(d)
    side = side - d * (side @ d)
    side = side / np.linalg.norm(side)
    return np.stack([d, side, np.cross(d, side)], axis=1)


def seg(head0, tail0, head1, tail1, side0, side1):
    """the rotation and translation taking a segment from its rest place to (head1, tail1)"""
    R = frame_of(tail1 - head1, side1) @ frame_of(tail0 - head0, side0).T
    return R, head1 - R @ head0


def two_bone(a, b, root, target, side):
    """the middle joint for lengths a, b from root to target, bending towards +bend (perpendicular, in the plane)"""
    d = target - root
    L = np.linalg.norm(d)
    L = min(L, (a + b) * 0.999)
    u = d / np.linalg.norm(d)
    x = (a * a - b * b + L * L) / (2 * L)
    h = math.sqrt(max(0.0, a * a - x * x))
    return root + u * x + side * h, root + u * L


def main():
    bike_src, bike_tex, man_src, pack = sys.argv[1:5]
    B = bike(bike_src)
    M = man(man_src)
    jp = M["jp"]
    hipL, hipR = jp["UpperLeg.L"], jp["UpperLeg.R"]
    kneeL, kneeR = jp["LowerLeg.L"], jp["LowerLeg.R"]
    ankL, ankR = jp["LowerLeg.L_end"], jp["LowerLeg.R_end"]
    toeL, toeR = jp["Foot.L_end"], jp["Foot.R_end"]
    thigh = np.linalg.norm(kneeL - hipL)
    shin = np.linalg.norm(ankL - kneeL)
    # the bike's size: full size (by its wheels), then the saddle lowered on its post until the legs reach the pedals
    g = B["game"]
    saddle_m, bb_m = B["saddle_m"], B["bb_m"]
    crank_m = np.linalg.norm((B["pedal_m"][0] - bb_m)[1:])
    sb = WHEEL_D / B["wheel_m"]
    want = LEG_REACH * (thigh + shin) + ANKLE_UP - SADDLE_UP
    seat = saddle_m - bb_m
    seat_len = np.linalg.norm(seat[1:])
    drop = seat_len + crank_m - want / sb                     # model units, along the seat tube
    if drop > 0:
        axis = seat / np.linalg.norm(seat)
        fv = B["raw"]["frame"][0]
        top = fv[:, 1].max()
        # the saddle and the top of its post: above where the top tube meets the seat tube, around the saddle
        near = (fv[:, 1] > top - 0.17 * seat_len) & (np.abs(fv[:, 2] - saddle_m[2]) < 0.3 * seat_len)
        fv[near] -= axis * drop
        saddle_m = saddle_m - axis * drop
        print("saddle lowered %.2f m (%d vertices)" % (drop * sb, int(near.sum())))

    def bike_pt(p):
        q = g(np.asarray(p, float)) * sb
        return q - np.array([g(bb_m)[0] * sb, 0, 0])          # bottom bracket at x = 0, wheels on the ground
    saddle = bike_pt(saddle_m)
    bb = bike_pt(bb_m)
    crank_r = crank_m * sb
    grips = [bike_pt(p) for p in B["grip_m"]]
    pedal_y = [bike_pt(p)[1] for p in B["pedal_m"]]
    print("bike: scale %.4f m a unit, wheel %.2f m, saddle %.2f m up, crank %.3f m, bars %.2f m ahead" % (
        sb, B["wheel_m"] * sb, saddle[2], crank_r, grips[0][0] - saddle[0]))

    # where the hips sit
    hip_mid0 = (hipL + hipR) / 2
    hip_mid = saddle + np.array([SADDLE_BACK, 0, SADDLE_UP])
    shift = hip_mid - hip_mid0
    pivot0 = hip_mid0
    # the torso leant forward until the hands reach the bars
    upper = np.linalg.norm(jp["LowerArm.L"] - jp["UpperArm.L"])
    fore = np.linalg.norm(jp["Palm.L"] - jp["LowerArm.L"])
    # the hand: from the wrist to the middle of the palm's part (the mesh is in the bind T-pose)
    palm_v = np.concatenate([M["game"](t[2]) for t in M["tris"] if t[0] == "Palm.L"])
    hand = float(np.linalg.norm(palm_v.mean(0) - jp["Palm.L"]))
    arm = upper + fore

    def shoulder_at(theta, name):
        return hip_mid + rot_y(theta) @ (jp[name] - pivot0)
    lean = math.radians(MIN_LEAN)
    for k in range(int(MIN_LEAN * 2), 200):
        th = math.radians(k * 0.5)
        S = shoulder_at(th, "UpperArm.L")
        G = grips[0] if grips[0][1] > 0 else grips[1]
        if np.linalg.norm(G - S) <= ARM_REACH * arm + hand:
            lean = th
            break
    print("rider: %.2f m, legs %.2f m, arms %.2f m, leans %.0f degrees" % (RIDER_HEIGHT, thigh + shin, arm, math.degrees(lean)))
    R_t = rot_y(lean)
    torso_bones = ["Body", "Hips", "Abdomen", "Torso", "Neck", "Shoulder.L", "Shoulder.R"]
    Y = np.array([0.0, 1.0, 0.0])

    def ride_pose(phi):
        P = {}
        t_torso = hip_mid - R_t @ pivot0
        for bname in torso_bones:
            P[bname] = (R_t, t_torso)
        # the head looks up the road
        Rh = rot_y(lean * 0.35)
        neck = R_t @ jp["Head"] + t_torso
        P["Head"] = (Rh, neck - Rh @ jp["Head"])
        # arms to the grips (the left grip has +y)
        for sd, G in (("L", max(grips, key=lambda p: p[1])), ("R", min(grips, key=lambda p: p[1]))):
            S = R_t @ jp["UpperArm." + sd] + t_torso
            target = G + np.array([-hand * 0.6, 0, 0.02])
            out = np.array([0, 1.0 if sd == "L" else -1.0, 0])
            bend = (np.array([-0.3, 0, -1.0]) + out * 0.4)
            bend = bend - (target - S) * (bend @ (target - S)) / ((target - S) @ (target - S))
            bend /= np.linalg.norm(bend)
            E, W = two_bone(upper, fore, S, target, bend)
            P["UpperArm." + sd] = seg(jp["UpperArm." + sd], jp["LowerArm." + sd], S, E, Y, np.cross(bend, E - S))
            P["LowerArm." + sd] = seg(jp["LowerArm." + sd], jp["Palm." + sd], E, W, Y, np.cross(bend, W - E))
            Rf = P["LowerArm." + sd][0]
            P["Palm." + sd] = (Rf, W - Rf @ jp["Palm." + sd])
        # legs to the pedals: the left pedal leads by half a turn
        for sd, hip0, knee0, ank0, toe0, off in (("L", hipL, kneeL, ankL, toeL, 0.0), ("R", hipR, kneeR, ankR, toeR, math.pi)):
            a = phi + off
            py = pedal_y[0] if sd == "L" else pedal_y[1]
            py = max(pedal_y) if sd == "L" else min(pedal_y)
            pedal = np.array([bb[0] + crank_r * math.cos(a), py, bb[2] + crank_r * math.sin(a)])
            # the foot: its ball on the pedal, heel dropping a little at the bottom of the stroke
            ankle_a = math.radians(8) * math.sin(a + 0.6)
            Rfoot = rot_y(-ankle_a)
            ball0 = ank0 + (toe0 - ank0) * 0.62
            ankle = pedal - Rfoot @ (ball0 - ank0) + np.array([0, 0, ANKLE_UP])
            hip = hip0 + shift
            K, A = two_bone(thigh, shin, hip, ankle, np.array([1.0, 0, 0.25]) / math.hypot(1, 0.25))
            P["UpperLeg." + sd] = seg(hip0, knee0, hip, K, Y, Y)
            P["LowerLeg." + sd] = seg(knee0, ank0, K, A, Y, Y)
            P["Foot." + sd] = (Rfoot, A - Rfoot @ ank0)
        return P

    if os.getenv("DEBUG_POSE"):
        P0 = ride_pose(0.0)
        def at(b, p): R, t = P0[b]; return np.round(R @ p + t, 3)
        print("saddle", np.round(saddle, 3), "bb", np.round(bb, 3), "grips", [np.round(g_, 3) for g_ in grips])
        print("hip_mid", np.round(hip_mid, 3), "hip_mid0", np.round(hip_mid0, 3))
        print("shoulder L", at("UpperArm.L", jp["UpperArm.L"]), "elbow", at("UpperArm.L", jp["LowerArm.L"]), "wrist", at("LowerArm.L", jp["Palm.L"]))
        print("hip L", at("UpperLeg.L", hipL), "knee", at("UpperLeg.L", kneeL), "ankle", at("LowerLeg.L", ankL))
        print("neck", at("Torso", jp["Neck"]), "hips joint", at("Hips", jp["Hips"]))
    ride = []
    for f in range(CRANK_FRAMES):
        phi = -2 * math.pi * f / CRANK_FRAMES        # forward pedalling: the pedal goes over the top towards the front
        ride.append(ride_pose(phi))

    # ---- the run cycle (Man_Run), sampled ----
    j, buf = M["j"], M["buf"]
    anim = [a for a in j["animations"] if a["name"].endswith("Man_Run")][0]
    chans = {}
    for c in anim["channels"]:
        smp = anim["samplers"][c["sampler"]]
        chans[(c["target"]["node"], c["target"]["path"])] = (accessor(j, buf, smp["input"]).astype(float),
                                                              accessor(j, buf, smp["output"]).astype(float))
    T = max(v[0].max() for v in chans.values())

    def sample(node, path, t, default):
        key = (node, path)
        if key not in chans:
            return default
        ts, vs = chans[key]
        if t <= ts[0]:
            return vs[0]
        if t >= ts[-1]:
            return vs[-1]
        k = np.searchsorted(ts, t) - 1
        f = (t - ts[k]) / (ts[k + 1] - ts[k])
        a, b = vs[k], vs[k + 1]
        if path == "rotation":
            if a @ b < 0:
                b = -b
            q = a * (1 - f) + b * f
            return q / np.linalg.norm(q)
        return a * (1 - f) + b * f

    nodes = j["nodes"]
    name_idx = {nd.get("name"): i for i, nd in enumerate(nodes)}
    run = []
    s = M["s"]
    C = np.array([[0, 0, 1], [1, 0, 0], [0, 1, 0]], float)      # model -> game directions
    for f in range(RUN_FRAMES):
        t = T * f / RUN_FRAMES
        locs = []
        for i, nd in enumerate(nodes):
            t0 = nd.get("translation", [0, 0, 0]); r0 = nd.get("rotation", [0, 0, 0, 1]); s0 = nd.get("scale", [1, 1, 1])
            if "matrix" in nd:
                locs.append(node_local(nd)); continue
            locs.append(trs(sample(i, "translation", t, np.array(t0)), sample(i, "rotation", t, np.array(r0)),
                            sample(i, "scale", t, np.array(s0))))
        P = {}
        Mm, Wmi = M["Mm"], np.linalg.inv(M["Wm"])
        Mmi = np.linalg.inv(Mm)
        for bname in M["bind"]:
            if BONE_OF.get(bname, bname) != bname:
                continue
            Wt = world(j, locs, M["par"], name_idx[bname])
            K = Mm @ Wmi @ Wt @ M["ibm"][bname] @ Mmi    # rest (game) -> posed (game)
            P[bname] = (K[:3, :3], K[:3, 3])
        run.append(P)
    # the run's stride: how far a step carries (from the feet's speed when on the ground - about 2.2 m a cycle at
    # the pack's pace); the game plays the cycle faster or slower with the speed
    run_cycle_m = 2.6

    # ---- write ----
    bones = sorted({t[0] for t in M["tris"]})
    lines = ["-- Generated by tools/packs/rider3d.py - do not edit. The rider (Quaternius, Animated Men Characters, CC0)",
             "-- and the bike (VOiD1 Gaming, Free Low Poly Bike Models). Metres, x forward, y left, z up.", "return {"]
    # bike parts: v = x, y, z, u, v, shade (relative to the part's pivot), i = triangles
    # the left pedal's angle in the crank part as stored (x forward, z up): the game turns the part to phi - crank0
    lp = bike_pt(max(B["pedal_m"], key=lambda p: bike_pt(p)[1])) - bb
    crank0 = math.atan2(lp[2], lp[0])
    lines.append("  bike = { tex = \"rider_bike\", wheel_r = %.4f, crank_r = %.4f, crank0 = %.4f, parts = {" % (B["wheel_m"] * sb / 2, crank_r, crank0))
    pivots = {"frame": bb, "rear": bike_pt(B["raw"]["rear"][4]), "front": bike_pt(B["raw"]["front"][4]),
              "cranks": bb, "bars": bike_pt(B["raw"]["bars"][4])}
    for name, (vw, nw, uv, idx, _) in B["raw"].items():
        pv = pivots[name]
        vals = []
        gv = np.array([bike_pt(p) for p in vw]) - pv
        gn = g(nw)
        for k in range(len(vw)):
            vals += [gv[k, 0], gv[k, 1], gv[k, 2], uv[k, 0], uv[k, 1], shade_of(gn[k])]
        lines.append("    %s = { pivot = { %.4f, %.4f, %.4f }, v = {%s}, i = {%s} }," % (
            name, pv[0], pv[1], pv[2], ",".join("%.4g" % x for x in vals), ",".join(str(int(x)) for x in idx)))
    lines.append("  } },")
    # rider parts by bone: v = x, y, z (rest), shade, area index, pattern u, pattern v
    areas = ["jersey", "trim", "shorts", "socks", "shoes", "skin", "hair", "eyes"]
    lines.append("  areas = { %s }," % ", ".join('"%s"' % a for a in areas))
    torso_c = (jp["Hips"] + jp["Neck"]) / 2
    # the sleeves: the arm bones, and of the shoulder bones only what is out past the shoulder joint (the rest of
    # what they move is the top of the chest and back, part of the jersey's pattern)
    arm_y = abs(jp["UpperArm.L"][1] - torso_c[1]) - 0.02

    def sleeve(bname, p):
        if bname.startswith(("UpperArm", "LowerArm")):
            return True
        return bname.startswith("Shoulder") and abs(p[1] - torso_c[1]) > arm_y
    # the jersey's pattern runs from its hem to its collar
    zs = [M["game"](P3)[k][2] for (bb_, area, P3, N3) in M["tris"] for k in range(3)
          if area == "jersey" and not sleeve(bb_, sum(M["game"](P3)) / 3)]
    z_waist, z_neck = min(zs), max(zs)
    print("jersey from %.2f to %.2f m, sleeves past %.2f m" % (z_waist, z_neck, arm_y))
    lines.append("  rider = { parts = {")
    for bname in bones:
        vals, idx = [], []
        for (bb_, area, P3, N3) in M["tris"]:
            if bb_ != bname:
                continue
            gp, gn = M["game"](P3), M["game_dir"](N3)
            # sleeve or not for the whole triangle (by its middle), so none is stretched across the texture
            in_sleeve = area in ("jersey", "trim") and sleeve(bname, (gp[0] + gp[1] + gp[2]) / 3)
            for k in range(3):
                p = gp[k]
                # pattern coordinates: around the body (front 0.5) and up it, for the jersey and the shorts
                ang = math.atan2(p[1] - torso_c[1], p[0] - torso_c[0])
                pu = (ang / (2 * math.pi) + 0.5) % 1.0
                if in_sleeve:
                    pv = -1.0                                         # sleeves
                else:
                    pv = (p[2] - z_waist) / (z_neck - z_waist)
                idx.append(len(vals) // 7)
                vals += [p[0], p[1], p[2], shade_of(gn[k]), areas.index(area), pu, pv]
        # a triangle across the back's seam (pattern u from ~1 to ~0) gets its small u past 1 (the texture repeats)
        for t in range(0, len(idx), 3):
            us = [vals[idx[t + k] * 7 + 5] for k in range(3)]
            if max(us) - min(us) > 0.5:
                for k in range(3):
                    if vals[idx[t + k] * 7 + 5] < 0.5:
                        # its own copy of the vertex, so the triangles beside it keep theirs
                        o = idx[t + k] * 7
                        idx[t + k] = len(vals) // 7
                        vals += vals[o:o + 7]
                        vals[-2] += 1.0
        lines.append("    [\"%s\"] = { v = {%s}, i = {%s} }," % (bname, ",".join("%.4g" % x for x in vals), ",".join(str(x) for x in idx)))
    lines.append("  },")

    def mats(P):
        out = []
        for bname in bones:
            R, t = P.get(bname, (np.eye(3), np.zeros(3)))
            out.append("[\"%s\"]={%s}" % (bname, ",".join("%.4f" % x for x in [R[0, 0], R[0, 1], R[0, 2], t[0], R[1, 0], R[1, 1], R[1, 2], t[1], R[2, 0], R[2, 1], R[2, 2], t[2]])))
        return "{" + ",".join(out) + "}"
    lines.append("  ride = {")
    for P in ride:
        lines.append("    " + mats(P) + ",")
    lines.append("  },")
    lines.append("  run_cycle_m = %.2f, run = {" % run_cycle_m)
    for P in run:
        lines.append("    " + mats(P) + ",")
    lines.append("  } },")
    lines.append("  textures = { rider_bike = { file = \"rider/bike.png\" } },")
    lines.append("}")
    lua = os.path.join(pack, "lua/tinyatlas/packs/default_rider.lua")
    open(lua, "w").write("\n".join(lines) + "\n")
    os.makedirs(os.path.join(pack, "materials/tinyatlas/packs/default/rider"), exist_ok=True)
    im = Image.open(bike_tex).convert("RGB").resize((512, 512), Image.LANCZOS)
    im.save(os.path.join(pack, "materials/tinyatlas/packs/default/rider/bike.png"))
    ntri = sum(len(B["raw"][k][3]) // 3 for k in B["raw"]) + len(M["tris"])
    print("wrote %s (%d KB): %d triangles, %d bones, %d pedalling and %d running poses" % (
        lua, os.path.getsize(lua) // 1024, ntri, len(bones), len(ride), len(run)))


if __name__ == "__main__":
    main()
