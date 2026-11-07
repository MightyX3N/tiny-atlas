"""Make a seamless-tiling copy of the WOWe engine for baking texture tiles: every 2-D noise call of the form
perlin(A / s1, B / s2, seed) or fbm(A / s1, B / s2, oct, seed) is rewritten to a version that repeats every
TP pixels (the feature size is nudged so a whole number of features fits the tile). The original files are
never changed; the copy goes to OUT."""
import os, re, shutil, sys

SRC = os.path.join(os.path.dirname(__file__), '..', 'third_party', 'wowe', 'wowe')


def split_args(s):
    out, depth, cur = [], 0, ''
    for ch in s:
        if ch in '([{': depth += 1
        elif ch in ')]}': depth -= 1
        if ch == ',' and depth == 0: out.append(cur); cur = ''
        else: cur += ch
    out.append(cur)
    return [a.strip() for a in out]


def top_div(a):
    """'A / B' at top level -> (A, B), else None."""
    depth = 0
    for i in range(len(a) - 1, -1, -1):
        ch = a[i]
        if ch in ')]}': depth += 1
        elif ch in '([{': depth -= 1
        elif ch == '/' and depth == 0 and a[i - 1] != '/' and (i + 1 >= len(a) or a[i + 1] != '/'):
            return a[:i].strip(), a[i + 1:].strip()
    return None


def patch_text(t):
    n = 0
    for fname, newf, nfix in (('perlin', '_TPERLIN', 2), ('fbm', '_TFBM', 2)):
        i = 0
        while True:
            m = re.compile(r'(?<![\w.])' + fname + r'\(').search(t, i)
            if not m: break
            j = m.end(); depth = 1; k = j
            while depth:
                if t[k] == '(': depth += 1
                elif t[k] == ')': depth -= 1
                k += 1
            args = split_args(t[j:k - 1])
            d1, d2 = top_div(args[0]), top_div(args[1]) if len(args) > 1 else None
            if d1 and d2:
                rep = f'{newf}({d1[0]}, {d1[1]}, {d2[0]}, {d2[1]}, ' + ', '.join(args[2:]) + ')'
                t = t[:m.start()] + rep + t[k:]; n += 1; i = m.start() + len(rep)
            else:
                i = k
    return t, n


PRELUDE = '''
local _N = _WOWE.require("noise")
local _TP = _WOWE.TILE
local function _per(s) return math.max(1, math.floor(_TP / s + 0.5)) end
function _TPERLIN(A, s1, B, s2, seed)
  local n1, n2 = _per(s1), _per(s2)
  return _N.perlinTile(A * n1 / _TP, B * n2 / _TP, seed, n1, n2)
end
function _TFBM(A, s1, B, s2, oct, seed)
  local sum, amp, norm = 0, 1, 0
  local n1, n2 = _per(s1), _per(s2)
  for o = 1, oct do
    sum = sum + _N.perlinTile(A * n1 / _TP, B * n2 / _TP, seed + o * 31, n1, n2) * amp
    norm = norm + amp; amp = amp * 0.5; n1, n2 = n1 * 2, n2 * 2
  end
  return sum / norm
end
'''


def make(out):
    if os.path.exists(out): shutil.rmtree(out)
    shutil.copytree(SRC, out)
    total = 0
    for f in os.listdir(out):
        if not f.endswith('.lua') or f in ('noise.lua',): continue
        p = os.path.join(out, f); t = open(p).read()
        t2, n = patch_text(t)
        if f == 'scape.lua': t2 = t2.replace('N.TG = 96', 'N.TG = _WOWE.TILE')
        if n or f == 'scape.lua':
            # after the "local G = ..." line, so _WOWE exists
            t2 = t2.replace('local G = ... or _WOWE\n', 'local G = ... or _WOWE\n' + PRELUDE, 1)
            open(p, 'w').write(t2); total += n
    return total


if __name__ == '__main__':
    print(make(sys.argv[1]), 'noise calls made seamless')
