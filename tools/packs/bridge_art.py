"""Bridge parts for the default pack: small seamless pixel-art tiles (32 x 32) drawn here.

    python3 tools/packs/bridge_art.py <pack addon dir>

  bridge/brick_1.png    the walls beside the arch (spandrels) and the abutments
  bridge/stone_1.png    stone blocks: the arch ring and deck edge
  bridge/parapet_1.png  the low wall along each side: brick with a stone coping on top
  bridge/arch_1.png     the underside of the arch: darker brick
Each tile covers 1.5 m x 1.5 m (pack.bridge.tile_metres). Renderers build each bridge from these parts to fit
its real length, width and height (see docs/FORMATS.md).
"""
import os, sys
import numpy as np
from PIL import Image

N = 32


def noise(rng, shape, amp):
    return rng.integers(-amp, amp + 1, shape)


def bricks(rng, base, mortar, bw=8, bh=4, vary=14):
    im = np.zeros((N, N, 3), np.int32)
    im[:] = mortar
    for row in range(N // bh):
        off = (bw // 2) * (row % 2)
        for col in range(-1, N // bw + 1):
            x0 = col * bw + off
            c = np.array(base) + rng.integers(-vary, vary + 1) + noise(rng, 3, 4)
            for y in range(row * bh, row * bh + bh - 1):
                for x in range(x0, x0 + bw - 1):
                    im[y, x % N] = c + noise(rng, 3, 5)
            # a lighter top edge on each brick, a darker bottom-right corner (pixel-art shading)
            for x in range(x0, x0 + bw - 1):
                im[row * bh, x % N] = np.minimum(im[row * bh, x % N] + 18, 255)
            im[row * bh + bh - 2, (x0 + bw - 2) % N] = np.maximum(im[row * bh + bh - 2, (x0 + bw - 2) % N] - 22, 0)
    return im


def stones(rng, base, mortar):
    im = np.zeros((N, N, 3), np.int32)
    im[:] = mortar
    for row in range(N // 8):
        off = 8 * (row % 2)
        for col in range(-1, N // 16 + 1):
            x0 = col * 16 + off
            c = np.array(base) + rng.integers(-10, 11)
            for y in range(row * 8, row * 8 + 7):
                for x in range(x0, x0 + 15):
                    im[y, x % N] = c + noise(rng, 3, 4)
            for x in range(x0, x0 + 15):
                im[row * 8, x % N] = np.minimum(im[row * 8, x % N] + 22, 255)
            for y in range(row * 8, row * 8 + 7):
                im[y, (x0 + 14) % N] = np.maximum(im[y, (x0 + 14) % N] - 20, 0)
    return im


def save(im, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    a = np.clip(im, 0, 255).astype(np.uint8)
    Image.fromarray(np.dstack([a, np.full((N, N), 255, np.uint8)]), 'RGBA').save(path)


def main(pack_dir, pid='default'):
    out = os.path.join(pack_dir, 'materials', 'tinyatlas', 'packs', pid, 'bridge')
    rng = np.random.default_rng(7)
    save(bricks(rng, (142, 66, 48), (176, 160, 140)), os.path.join(out, 'brick_1.png'))
    save(stones(rng, (190, 178, 158), (120, 112, 100)), os.path.join(out, 'stone_1.png'))
    par = bricks(rng, (138, 64, 46), (176, 160, 140))
    cap = stones(rng, (196, 186, 166), (120, 112, 100))
    par[:7] = cap[:7]
    par[7] = (90, 84, 76)                       # shadow under the coping
    save(par, os.path.join(out, 'parapet_1.png'))
    save(bricks(rng, (98, 46, 36), (112, 100, 88), vary=10), os.path.join(out, 'arch_1.png'))
    print('bridge parts ->', out)


if __name__ == '__main__':
    main(sys.argv[1])
