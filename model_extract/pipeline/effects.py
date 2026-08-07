#!/usr/bin/env python3
"""
Generated stand-in effects.

IMPORTANT: nothing in this file is extracted game data. The real tail flame,
mane fire and gas are drawn by procedural callbacks that live in another
fragment (geo command 0x08 -> func_80014A60 calls node->unk_10, and the model
file supplies only two empty display lists plus zeroed scratch buffers). Those
callbacks have not been ported, so the models genuinely contain no flame mesh
and no flame texture.

What follows is an original, procedurally generated replacement: looping
flipbook textures plus a pair of crossed quads anchored to the bone the
callback hangs off. It is meant to make the models look right in the viewer,
and it is tagged `generated: true` everywhere it appears so it is never
mistaken for ripped content.
"""
import math

# geo cmd 0x08 callback ids -> which effect to stand in for. The grouping is the
# game's own: every species sharing a callback shares an effect.
FIRE_TAIL = 0x810000D8      # Charmander, Charmeleon, Charizard, Magmar, Moltres
FIRE_SMALL = 0x81000108     # Ponyta, Rapidash, Moltres wings
AURA = 0x810000E0           # Gastly, Koffing, Weezing, Vaporeon, Articuno, Moltres


class Rng:
    """Deterministic PRNG so a given species always generates the same effect."""

    def __init__(self, seed):
        self.s = seed & 0xFFFFFFFF or 0x9E3779B9

    def next(self):
        x = self.s
        x ^= (x << 13) & 0xFFFFFFFF
        x ^= x >> 17
        x ^= (x << 5) & 0xFFFFFFFF
        self.s = x & 0xFFFFFFFF
        return self.s

    def unit(self):
        return self.next() / 0x100000000


def _lattice(rng, w, h):
    return [[rng.unit() for _ in range(w)] for _ in range(h)]


def _smooth(t):
    return t * t * (3 - 2 * t)


def _sample(grid, x, y):
    """Bilinear value noise on a torus, so the field tiles in both axes."""
    h, w = len(grid), len(grid[0])
    x0, y0 = int(math.floor(x)) % w, int(math.floor(y)) % h
    x1, y1 = (x0 + 1) % w, (y0 + 1) % h
    fx, fy = _smooth(x - math.floor(x)), _smooth(y - math.floor(y))
    a = grid[y0][x0] + (grid[y0][x1] - grid[y0][x0]) * fx
    b = grid[y1][x0] + (grid[y1][x1] - grid[y1][x0]) * fx
    return a + (b - a) * fy


def _fbm(grids, x, y, scale):
    """Sum octaves of tileable noise."""
    total, amp, norm = 0.0, 1.0, 0.0
    for i, g in enumerate(grids):
        f = scale * (2 ** i)
        total += _sample(g, x * f, y * f) * amp
        norm += amp
        amp *= 0.5
    return total / norm


def _ramp(stops, t):
    t = max(0.0, min(1.0, t))
    for i in range(len(stops) - 1):
        a, b = stops[i], stops[i + 1]
        if t <= b[0]:
            k = 0.0 if b[0] == a[0] else (t - a[0]) / (b[0] - a[0])
            return tuple(int(a[1 + j] + (b[1 + j] - a[1 + j]) * k) for j in range(4))
    return tuple(stops[-1][1:])


FIRE_RAMP = [                       # intensity -> RGBA
    (0.00, 0, 0, 0, 0),
    (0.30, 120, 24, 8, 90),
    (0.52, 226, 78, 16, 205),
    (0.74, 252, 176, 44, 245),
    (1.00, 255, 246, 214, 255),
]

GAS_RAMP = [
    (0.00, 0, 0, 0, 0),
    (0.34, 52, 26, 78, 70),
    (0.60, 96, 52, 140, 140),
    (0.82, 148, 96, 196, 190),
    (1.00, 208, 176, 236, 215),
]


def fire_frames(seed, w=32, h=64, frames=8, wisp=1.0):
    """Upward-advected noise plume. Scrolling by an exact multiple of the noise
    lattice over the frame count makes the loop seamless."""
    rng = Rng(seed)
    grids = [_lattice(rng, 8, 8), _lattice(rng, 16, 16), _lattice(rng, 32, 32)]
    out = []
    for f in range(frames):
        t = f / frames
        buf = bytearray(w * h * 4)
        for y in range(h):
            v = y / (h - 1)                     # 0 at the base, 1 at the tip
            # plume envelope: wide and hot at the base, pinched at the tip
            taper = max(0.0, 1.0 - v) ** 0.42
            for x in range(w):
                u = (x / (w - 1)) * 2 - 1       # -1 .. 1 across the flame
                radial = (1.0 - min(1.0, abs(u) / max(0.10, taper * 0.95))) ** 0.7
                if radial <= 0:
                    continue
                n = _fbm(grids, x / w, (y / h) - t, 3.0)
                lick = 0.55 + 0.75 * (n - 0.5) * wisp
                inten = radial * (0.55 + 0.8 * taper) * lick
                inten -= 0.16 * v                # cool towards the tip
                if inten <= 0.02:
                    continue
                r, g, b, a = _ramp(FIRE_RAMP, inten)
                i = ((h - 1 - y) * w + x) * 4    # +Y in texture space is up
                buf[i:i+4] = bytes((r, g, b, a))
        out.append(bytes(buf))
    return w, h, out


def gas_frames(seed, w=48, h=48, frames=10):
    """Slow swirling haze that fades out towards the rim."""
    rng = Rng(seed)
    grids = [_lattice(rng, 8, 8), _lattice(rng, 16, 16), _lattice(rng, 32, 32)]
    out = []
    for f in range(frames):
        t = f / frames
        buf = bytearray(w * h * 4)
        ang = t * 2 * math.pi
        for y in range(h):
            for x in range(w):
                dx = (x / (w - 1)) * 2 - 1
                dy = (y / (h - 1)) * 2 - 1
                d = math.hypot(dx, dy)
                if d >= 1.0:
                    continue
                falloff = (1.0 - d) ** 0.85
                # rotate the sample point so the haze churns without popping
                sx = dx * math.cos(ang) - dy * math.sin(ang)
                sy = dx * math.sin(ang) + dy * math.cos(ang)
                n = _fbm(grids, sx * 0.5 + 0.5, sy * 0.5 + 0.5 - t, 2.5)
                inten = falloff * (0.78 + 1.30 * (n - 0.44))
                if inten <= 0.03:
                    continue
                r, g, b, a = _ramp(GAS_RAMP, inten)
                i = (y * w + x) * 4
                buf[i:i+4] = bytes((r, g, b, a))
        out.append(bytes(buf))
    return w, h, out


def crossed_quads(bone, length, width, axis='y', centred=False):
    """Two quads at right angles so the effect reads from any angle -- the
    portable stand-in for a billboard, since glTF cannot billboard.

    `axis` picks which bone-local direction the quad grows along. Bone-local +X
    runs down the limb, so a flame laid out along X comes out lying sideways;
    'y' is that same quad rotated 90 degrees left about Z, which stands it up.
    `centred` straddles the origin instead of growing from it."""
    pos, uv, nrm, skin, idx = [], [], [], [], []
    for q in range(2):
        base = len(pos) // 3
        for (s, t) in ((0, 0), (1, 0), (1, 1), (0, 1)):
            a = (s - 0.5) * width
            b = (t - 0.5) * length if centred else t * length
            if axis == 'x':
                p = (b, a, 0.0) if q == 0 else (b, 0.0, a)
            else:                                   # (x, y) -> (-y, x)
                p = (-a, b, 0.0) if q == 0 else (0.0, b, a)
            pos += list(p)
            uv += [s, 1.0 - t]
            nrm += [0.0, 0.0, 1.0] if q == 0 else [1.0, 0.0, 0.0]
            skin.append(bone)
        idx += [base, base + 1, base + 2, base, base + 2, base + 3]
    return dict(pos=pos, uv=uv, nrm=nrm, skin=skin, idx=idx)


# desired size as a fraction of the model's world-space extent
SIZES = {
    'fire_tail':  (0.40, 0.22),     # length, width
    'fire_small': (0.075, 0.042),
    'gas':        (1.05, 1.05),
}


def build_for(species, fx, extent, bone_scale):
    """Returns [{kind, bone, geo, w, h, frames}] for one model, or [].

    `extent` is the model's world-space size and `bone_scale[i]` how much bone i
    already scales its local space; dividing by it keeps every effect the size we
    asked for regardless of where in the skeleton it hangs."""
    out = []
    for node in fx:
        cb, bone = node['callback'], node['bone']
        if bone < 0 or bone >= len(bone_scale):
            continue
        k = bone_scale[bone] or 1.0
        if cb == FIRE_TAIL:
            fl, fw = SIZES['fire_tail']
            w, h, fr = fire_frames(species * 7919 + 1, 32, 64, 8)
            geo = crossed_quads(bone, extent * fl / k, extent * fw / k, axis='y')
            out.append(dict(kind='fire', bone=bone, geo=geo, w=w, h=h, frames=fr))
        elif cb == FIRE_SMALL:
            fl, fw = SIZES['fire_small']
            w, h, fr = fire_frames(species * 6271 + bone, 24, 40, 8, wisp=1.25)
            geo = crossed_quads(bone, extent * fl / k, extent * fw / k, axis='y')
            out.append(dict(kind='fire', bone=bone, geo=geo, w=w, h=h, frames=fr))
        elif cb == AURA and species == 92:              # Gastly only
            fl, fw = SIZES['gas']
            w, h, fr = gas_frames(species * 5237 + 3, 48, 48, 10)
            geo = crossed_quads(bone, extent * fl / k, extent * fw / k, axis='y', centred=True)
            out.append(dict(kind='gas', bone=bone, geo=geo, w=w, h=h, frames=fr))
    return out
