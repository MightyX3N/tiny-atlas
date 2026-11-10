"""3D trees for the default pack, from Quaternius's Stylized Nature MegaKit (bought; see the pack's credits).

For each tree model it writes:
  - the kit's own bark and leaf textures (at most TEX_MAX px; the game pixelates the whole picture on screen), leaves cut
    out sharply, a few colours fixed (autumn leaves made summer green)
  - a model file the game reads (lua/tinyatlas/packs/default_trees3d.lua): for each level of detail, the bark and the
    leaves as triangle lists (position, normal, texture coordinate), in metres, z up, trunk base at 0
Kept light enough for every device:
  the 3D tree (drawn near the rider): bark simplified with meshoptimizer (zeux, MIT), one leaf card in 4 kept and made
  bigger so the crown stays as full (at the pack's pixel size the difference does not show)
  its picture (drawn everywhere else): the 3D tree drawn from the side at the pack's pixel size (tools/packs/treeshot.js),
  for two crossed planes

usage: python3 trees3d.py <kit assets folder> <pack folder> MODEL [MODEL ...]
"""
import json, os, struct, subprocess, sys, tempfile
import numpy as np
import meshoptimizer
from PIL import Image

PX_PER_M = 24                       # pixels a metre for the distant trees' pictures (the game pixelates the whole
                                    # picture on screen, so the models keep their own textures)
TEX_MAX = 512                       # the kit's textures are kept as they are, at most this big (GMod: powers of two)
# colours the kit's own materials paint on (its textures are only shapes there): grass is a gradient from root to tip
# (MI_Grass_Common's Color_Bottom / Color_Top, brought to the pack's greens); the plants' olive leaves are pulled
# towards the pack's grass green
GRASS_TINT = (0.42, 0.60, 0.24, 0.80, 0.92, 0.45)    # root r, g, b, tip r, g, b
LEAF_GREEN = (95, 150, 55)
SUMMER = {"leaves_birch_c.png": (128, 168, 62)}    # leaves the kit paints in autumn colours -> their summer green
LEAF_COLOURS, BARK_COLOURS = 0, 0   # colours per texture (0: all of them)
# the small plants, rocks and mushrooms (no picture: they are only drawn near the rider): triangles each
PLANTS = {
    "Grass_Common_Short": 50, "Grass_Common_Tall": 70, "Grass_Wispy_Short": 60, "Grass_Wispy_Tall": 70,
    "Grass_Wide_Short": 60, "Fern_1": 90, "Fern_2": 80, "Clover_1": 70, "Plant_1": 60, "Plant_2": 90, "Plant_6": 60,
    "Bush_Common_Flowers": 220, "Bush_Long_1": 200, "Bush_Large": 240,
    "Flower_1_Group": 120, "Flower_2_Group": 120, "Flower_3_Group": 110, "Flower_4_Group": 120, "Flower_7_Group": 120,
    "Mushroom_Common": 60, "Mushroom_RedCap": 60, "Rock_Medium_1": 90, "Rock_Medium_2": 80, "Rock_Medium_3": 90,
    "Pebble_Round_1": 24, "Pebble_Round_3": 24, "Pebble_Square_2": 20, "Pebble_Square_4": 16,
}
LOD = [
    {"bark": 220, "leaf_keep": 4, "leaf_grow": 1.6},
]


def read_gltf(path):
    j = json.load(open(path))
    bins = [open(os.path.join(os.path.dirname(path), b["uri"]), "rb").read() for b in j["buffers"]]

    def acc(i):
        a = j["accessors"][i]
        bv = j["bufferViews"][a["bufferView"]]
        data = bins[bv["buffer"]]
        n = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}[a["type"]]
        dt = {5126: np.float32, 5125: np.uint32, 5123: np.uint16, 5121: np.uint8}[a["componentType"]]
        off = bv.get("byteOffset", 0) + a.get("byteOffset", 0)
        stride = bv.get("byteStride", 0)
        item = n * np.dtype(dt).itemsize
        if stride and stride != item:
            rows = [np.frombuffer(data, dt, n, off + k * stride) for k in range(a["count"])]
            return np.array(rows)
        return np.frombuffer(data, dt, a["count"] * n, off).reshape(-1, n) if n > 1 else np.frombuffer(data, dt, a["count"], off)

    parts = []
    for node in j["nodes"]:
        if "mesh" not in node:
            continue
        if any(k in node for k in ("rotation", "scale", "matrix")):
            raise SystemExit("node transforms are not handled: " + path)
        t = np.array(node.get("translation", [0, 0, 0]), np.float32)
        for pr in j["meshes"][node["mesh"]]["primitives"]:
            m = j["materials"][pr["material"]]
            tex = j["images"][j["textures"][m["pbrMetallicRoughness"]["baseColorTexture"]["index"]]["source"]]["uri"]
            pos = acc(pr["attributes"]["POSITION"]).astype(np.float32) + t
            nor = acc(pr["attributes"]["NORMAL"]).astype(np.float32)
            uv = acc(pr["attributes"]["TEXCOORD_0"]).astype(np.float32)
            idx = acc(pr["indices"]).astype(np.uint32)
            # glTF is y up, z towards the viewer; the game is z up, y north: (x, y, z) -> (x, -z, y)
            pos = np.stack([pos[:, 0], -pos[:, 2], pos[:, 1]], 1)
            nor = np.stack([nor[:, 0], -nor[:, 2], nor[:, 1]], 1)
            parts.append({"name": m["name"], "tex": tex, "leaf": "leaf" in m["name"].lower() or "leaves" in m["name"].lower(),
                          "pos": pos, "nor": nor, "uv": uv, "idx": idx})
    return parts


def density(part, size):
    """the texture's pixels per metre on this model (native)"""
    p, uv, i = part["pos"], part["uv"] * size, part["idx"].reshape(-1, 3)
    a = np.linalg.norm(np.cross(p[i[:, 1]] - p[i[:, 0]], p[i[:, 2]] - p[i[:, 0]]), axis=1) / 2
    e1, e2 = uv[i[:, 1]] - uv[i[:, 0]], uv[i[:, 2]] - uv[i[:, 0]]
    b = np.abs(e1[:, 0] * e2[:, 1] - e1[:, 1] * e2[:, 0]) / 2
    return float(np.sqrt(b.sum() / max(a.sum(), 1e-9)))


def pixel_texture(src, part, out_path, colours):
    im = Image.open(src).convert("RGBA")
    native = density(part, im.size[0])
    # a power of two (GMod), at most TEX_MAX
    side = min(TEX_MAX, 2 ** int(round(np.log2(max(8, im.size[0])))))
    small = im.resize((side, side), Image.LANCZOS)
    a = np.array(small)
    if part["name"].lower().startswith("grass"):
        # the colour comes from the root-to-tip tint (atlas/trees.lua), the texture keeps only light and dark
        g = a[:, :, :3].astype(float).mean(-1, keepdims=True)
        a[:, :, :3] = np.clip(g / max(1.0, float(g[a[:, :, 3] > 0].mean()) if (a[:, :, 3] > 0).any() else 1.0) * 200, 0, 255).astype(np.uint8)
    elif os.path.basename(src).lower() == "leaves.png":
        rgb = a[:, :, :3].astype(float)
        lum = rgb.mean(-1, keepdims=True)
        target = np.array(LEAF_GREEN, float)
        a[:, :, :3] = np.clip(rgb * 0.35 + target * (lum / target.mean()) * 0.65, 0, 255).astype(np.uint8)
    elif os.path.basename(src).lower() in SUMMER:
        # the kit paints these leaves in autumn colours: summer green instead, keeping the light and dark
        rgb = a[:, :, :3].astype(float)
        lum = rgb.mean(-1, keepdims=True)
        m = float(lum[a[:, :, 3] > 0].mean()) if (a[:, :, 3] > 0).any() else 1.0
        a[:, :, :3] = np.clip(np.array(SUMMER[os.path.basename(src).lower()], float) * (lum / m), 0, 255).astype(np.uint8)
    if not part["leaf"]:
        # bark: calmer than the kit's warm brown (next to the pack's ground colours)
        rgb = a[:, :, :3].astype(float)
        grey = rgb.mean(-1, keepdims=True)
        a[:, :, :3] = np.clip(grey + (rgb - grey) * 0.55, 0, 255).astype(np.uint8)
    alpha = a[:, :, 3] >= 128 if part["leaf"] else np.ones(a.shape[:2], bool)
    rgb = Image.fromarray(a[:, :, :3])
    q = rgb.quantize(colors=colours, method=Image.Quantize.MEDIANCUT).convert("RGB") if colours else rgb
    out = np.dstack([np.array(q), np.where(alpha, 255, 0).astype(np.uint8)])
    Image.fromarray(out, "RGBA").save(out_path)
    return side, native


def leaf_cards(idx):
    """leaf triangles grouped into cards (triangles sharing vertices)"""
    tri = idx.reshape(-1, 3)
    parent = list(range(int(idx.max()) + 1))

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x
    for a, b, c in tri:
        for u, v in ((a, b), (b, c)):
            ru, rv = find(u), find(v)
            if ru != rv:
                parent[ru] = rv
    cards = {}
    for t in tri:
        cards.setdefault(find(int(t[0])), []).append(t)
    return list(cards.values())


def lod_part(part, lod, k_lod):
    pos, idx = part["pos"], part["idx"]
    if part["leaf"]:
        cards = leaf_cards(idx)
        keep = cards[::lod["leaf_keep"]]
        p2 = pos.copy()
        tris = []
        for c in keep:
            c = np.array(c)
            if lod["leaf_grow"] != 1:
                vs = np.unique(c)
                ctr = pos[vs].mean(0)
                p2[vs] = ctr + (pos[vs] - ctr) * lod["leaf_grow"]
            tris.append(c)
        return p2, np.concatenate(tris).reshape(-1)
    target = min(len(idx), lod["bark"] * 3)
    dst = np.zeros(len(idx), np.uint32)
    size = float(np.ptp(pos, 0).max())
    # the kit's bark is in many pieces along its texture seams: the sloppy simplifier works across them (the trunk is a
    # few pixels wide at the pack's pixel size, so its fine shape is not seen)
    n = meshoptimizer.simplify_sloppy(dst, idx, pos, target_index_count=target, target_error=0.2)
    return pos, dst[:n]


def plant_part(part, share):
    """a plant's part cut to `share` triangles: leaf-like cards thinned (and grown to fill), solid parts simplified"""
    pos, idx = part["pos"], part["idx"]
    tris = len(idx) // 3
    if tris <= share:
        return pos, idx
    if part["leaf"]:
        cards = leaf_cards(idx)
        per = max(1, tris // max(1, len(cards)))
        keep_n = max(1, share // per)
        step = max(1, int(np.ceil(len(cards) / keep_n)))
        grow = min(1.8, step ** 0.35)
        p2 = pos.copy()
        out = []
        for c in cards[::step]:
            c = np.array(c)
            vs = np.unique(c)
            ctr = pos[vs].mean(0)
            p2[vs] = ctr + (pos[vs] - ctr) * grow
            out.append(c)
        return p2, np.concatenate(out).reshape(-1)
    dst = np.zeros(len(idx), np.uint32)
    n = meshoptimizer.simplify_sloppy(dst, idx, pos, target_index_count=share * 3, target_error=0.3)
    return pos, dst[:n]


def lua_numbers(a, fmt):
    return ",".join(fmt % v for v in a)


def main():
    kit, pack, models = sys.argv[1], sys.argv[2], sys.argv[3:]
    tex_dir = os.path.join(pack, "materials/tinyatlas/packs/default/trees3d")
    os.makedirs(tex_dir, exist_ok=True)
    out = ["-- Generated by tools/packs/trees3d.py - do not edit. 3D trees (Quaternius Stylized Nature MegaKit),",
           "-- pixel-art textures. models[name] = { height, lods = { { parts = { { tex, leaf, v = {x,y,z,nx,ny,nz,u,v,...},",
           "-- i = {vertex numbers, three per triangle, from 0} } } } } }",
           "return {", "  models = {"]
    textures = {}
    for name in models:
        parts = read_gltf(os.path.join(kit, name + ".gltf"))
        # trunk base at 0, centred on the trunk
        allp = np.concatenate([p["pos"] for p in parts])
        bark = [p for p in parts if not p["leaf"]]
        base = (bark[0] if bark else parts[0])["pos"]
        low = base[base[:, 2] < base[:, 2].min() + 0.5]
        ox, oy, oz = float(low[:, 0].mean()), float(low[:, 1].mean()), float(allp[:, 2].min())
        height = float(allp[:, 2].max() - oz)
        out.append('    ["%s"] = { height = %.2f, lods = {' % (name, height))
        for p in parts:
            key = os.path.splitext(p["tex"])[0].lower()
            if key not in textures:
                side, native = pixel_texture(os.path.join(kit, p["tex"]), p, os.path.join(tex_dir, key + ".png"),
                                             LEAF_COLOURS if p["leaf"] else BARK_COLOURS)
                textures[key] = p["leaf"]
                print("  texture %s: %d px" % (key, side))
        shot = {"parts": []}
        plant = name in PLANTS
        all_tris = sum(len(p["idx"]) // 3 for p in parts)
        for k_lod, lod in enumerate(LOD):
            out.append("      { parts = {")
            total = 0
            for p in parts:
                if plant:
                    share = max(8, int(PLANTS[name] * (len(p["idx"]) // 3) / all_tris))
                    pos, idx = plant_part(p, share)
                else:
                    pos, idx = lod_part(p, lod, k_lod)
                # only the vertices used, numbered again
                used, remap = np.unique(idx, return_inverse=True)
                v = []
                for i in used:
                    x, y, z = pos[i]
                    nx, ny, nz = p["nor"][i]
                    u, vv = p["uv"][i]
                    v += [round(float(x - ox), 2), round(float(y - oy), 2), round(float(z - oz), 2),
                          round(float(nx), 2), round(float(ny), 2), round(float(nz), 2), round(float(u), 3), round(float(vv), 3)]
                total += len(idx) // 3
                key = os.path.splitext(p["tex"])[0].lower()
                if k_lod == 0:
                    shot["parts"].append({"tex": key, "file": key + ".png", "leaf": bool(p["leaf"]), "v": v, "i": [int(x) for x in remap]})
                tint = (", tint = { %s }" % ", ".join("%.2f" % c for c in GRASS_TINT)) if p["name"].lower().startswith("grass") else ""
                out.append('        { tex = "tree_%s", leaf = %s%s, v = {%s}, i = {%s} },' % (key, "true" if p["leaf"] else "false", tint,
                           ",".join("%g" % x for x in v), ",".join(str(int(x)) for x in remap)))
            out.append("      } },")
            print("  %s 3D: %d triangles" % (name, total))
        if plant:
            out.append("    }, plant = true },")
            continue
        # its picture, for the crossed planes away from the rider
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump(shot, f)
        pic = name.lower() + "_picture"
        res = subprocess.run(["node", os.path.join(os.path.dirname(os.path.abspath(__file__)), "treeshot.js"), f.name, tex_dir,
                              os.path.join(tex_dir, pic + ".png"), str(PX_PER_M)], capture_output=True, text=True)
        os.unlink(f.name)
        info = json.loads(res.stdout.strip().splitlines()[-1]) if res.returncode == 0 and res.stdout.strip() else None
        if not info:
            raise SystemExit("picture of %s failed: %s" % (name, res.stdout + res.stderr))
        # hard edges (the pixel look), then the canvas made a power of two for GMod (the picture at its bottom middle)
        im = Image.open(os.path.join(tex_dir, pic + ".png")).convert("RGBA")
        a = np.array(im)
        a[:, :, 3] = np.where(a[:, :, 3] >= 128, 255, 0)
        W2 = 2 ** int(np.ceil(np.log2(max(8, a.shape[1])))); H2 = 2 ** int(np.ceil(np.log2(max(8, a.shape[0]))))
        canvas = np.zeros((H2, W2, 4), np.uint8)
        ox_ = (W2 - a.shape[1]) // 2
        canvas[H2 - a.shape[0]:, ox_:ox_ + a.shape[1]] = a
        Image.fromarray(canvas, "RGBA").save(os.path.join(tex_dir, pic + ".png"))
        u0, u1 = ox_ / W2, (ox_ + a.shape[1]) / W2
        v0 = (H2 - a.shape[0]) / H2
        textures[pic] = True
        out.append('    }, picture = { tex = "tree_%s", w = %.2f, h = %.2f, uv = { %.4f, %.4f, %.4f, 1 } } },' %
                   (pic, info["width_m"], info["height_m"], u0, v0, u1))
        print("  %s picture: %d x %d px" % (name, info["w"], info["h"]))
    out.append("  },")
    out.append("  textures = {")
    for key, leaf in sorted(textures.items()):
        out.append('    tree_%s = { file = "trees3d/%s.png", alphatest = %s },' % (key, key, "true" if leaf else "false"))
    out.append("  },")
    out.append("}")
    lua = os.path.join(pack, "lua/tinyatlas/packs/default_trees3d.lua")
    open(lua, "w").write("\n".join(out) + "\n")
    print("wrote", lua, "%.0f KB" % (os.path.getsize(lua) / 1024))


if __name__ == "__main__":
    main()
