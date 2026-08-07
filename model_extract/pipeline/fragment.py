#!/usr/bin/env python3
"""
Model extraction: FRAGMENT module -> geometry, textures, skeleton, animations.

Self-contained copy of tools/model_viewer/extract_model.py, taking raw bytes so
it can be fed straight from the ROM. See ../README.md for the format notes.
"""
import json, os, struct, sys, zlib

BASE = 0x8FF00000

# ---------------------------------------------------------------- geo layout

CMD_SIZES = {
    0x00:0x08, 0x01:0x04, 0x02:0x08, 0x03:0x08, 0x04:0x04, 0x05:0x04, 0x06:0x04,
    0x07:0x08, 0x08:0x0C, 0x09:0x04, 0x0A:0x08, 0x0B:0x18, 0x0C:0x04, 0x0D:0x04,
    0x0E:0x04, 0x0F:0x04, 0x10:0x04, 0x11:0x04, 0x12:0x04, 0x13:0x08, 0x14:0x0C,
    0x15:0x0C, 0x16:0x04, 0x17:0x14, 0x18:0x08, 0x19:0x08, 0x1A:0x04, 0x1B:0x10,
    0x1C:0x10, 0x1D:0x1C, 0x1E:0x08, 0x1F:0x18, 0x20:0x14, 0x21:0x10, 0x22:0x08,
    0x23:0x10, 0x24:0x04, 0x25:0x04, 0x26:0x14,
}


class Fragment:
    def __init__(self, data, name='<bytes>'):
        self.d = data if isinstance(data, (bytes, bytearray)) else open(data, 'rb').read()
        self.name = name if isinstance(data, (bytes, bytearray)) else str(data)
        if self.d[8:0x10] != b'FRAGMENT':
            raise ValueError(f'{self.name}: not a FRAGMENT module')
        self.hdrSize, self.relocOff, self.sizeRom, self.sizeRam = struct.unpack_from('>4I', self.d, 0x10)

    def off(self, ptr):
        return None if ptr == 0 else ptr - BASE

    def u8(self, o):  return self.d[o]
    def s8(self, o):  return struct.unpack_from('>b', self.d, o)[0]
    def u16(self, o): return struct.unpack_from('>H', self.d, o)[0]
    def s16(self, o): return struct.unpack_from('>h', self.d, o)[0]
    def u32(self, o): return struct.unpack_from('>I', self.d, o)[0]
    def s32(self, o): return struct.unpack_from('>i', self.d, o)[0]
    def ptr(self, o): return self.off(self.u32(o))

    def root(self):
        """The entry stub ends with `lui rX, hi; addiu rX, rX, lo` loading the root struct."""
        for o in range(0x20, 0x80, 4):
            w = self.u32(o)
            if (w >> 26) != 0x0F:                       # lui
                continue
            reg = (w >> 16) & 0x1F
            w2 = self.u32(o + 4)
            if (w2 >> 26) == 0x09 and ((w2 >> 21) & 0x1F) == reg:   # addiu rX, rX, imm
                return ((self.u16(o + 2) << 16) + self.s16(o + 6)) - BASE
        raise RuntimeError('could not locate root struct')

    def ptr_list(self, o):
        out = []
        while True:
            p = self.ptr(o)
            if p is None:
                return out
            out.append(p)
            o += 4


# --------------------------------------------------------------- F3DEX2 exec

def signed(v, bits):
    m = 1 << (bits - 1)
    return (v ^ m) - m


class Model:
    """Walks the geo layout, executes the display lists, accumulates draw data."""

    def __init__(self, frag):
        self.f = frag
        r = frag.root()
        self.species = frag.u16(r)
        self.geoLayouts = frag.ptr_list(frag.ptr(r + 0x08))
        self.anims     = frag.ptr_list(frag.ptr(r + 0x0C))
        self.auxAnims  = frag.ptr_list(frag.ptr(r + 0x10))

        self.textures = []      # {fmt, siz, w, h, texels, data}
        self.tluts = []         # palettes: {count, data, dl}
        self.bones = []         # {parent, boneId, chan, t, r, s}
        self.boneById = {}
        self.prims = []         # {tex, cull, verts:[...], tris:[...]}
        self.primsByKey = {}
        self.vtxBase = None
        self.rootScale = [1.0, 1.0, 1.0]
        self.fx = []            # geo cmd 0x08 procedural effect nodes
        self.warnings = []

    # ---- textures -------------------------------------------------------
    def read_texture_table(self, off, count):
        f = self.f
        for i in range(count):
            o = off + i * 0xC
            self.textures.append(dict(
                fmt=f.u8(o), siz=f.u8(o + 1), w=f.s16(o + 2),
                h=f.u16(o + 4), texels=f.u16(o + 6), data=f.ptr(o + 8)))

    def read_tlut_table(self, off, count):
        """Palettes reuse the texture-record layout: the count sits in the width
        field, the palette data in the next word, and unk_08 is the DL that loads
        it (src/12D80.c func_80015B20). The DL is authoritative, so run it."""
        f = self.f
        for i in range(count):
            o = off + i * 0xC
            rec = dict(count=f.u16(o + 2), data=f.ptr(o + 4), dl=f.ptr(o + 8))
            dl = rec['dl']
            if dl is not None:
                for _ in range(16):
                    w0, w1 = struct.unpack_from('>II', f.d, dl)
                    op = w0 >> 24
                    if op == 0xFD:                          # G_SETTIMG
                        rec['data'] = f.off(w1)
                    elif op == 0xF0:                        # G_LOADTLUT
                        rec['count'] = ((w1 >> 14) & 0x3FF) + 1
                    elif op == 0xDF:
                        break
                    dl += 8
            self.tluts.append(rec)

    # ---- geo layout -----------------------------------------------------
    def build(self):
        self.curTex = -1
        self.curTlut = -1
        self.curMat = None
        self.curTexAnim = -1
        # Mirrors gCurGraphNodeList in src/geo_layout.c: stack[-1] is the slot the
        # next node command writes to, and a node's parent -- and the bone whose
        # matrix is live -- is the slot *below* it (func_80017AC4).
        self.stack = [-1]
        # The RSP vertex cache persists across display lists: a bone's list often
        # preloads verts that the *next* bone's list then indexes, which is how
        # these models get blended joints. Each slot remembers the bone whose
        # matrix was current when it was loaded.
        self.vbuf = [None] * 64
        self.walk(self.geoLayouts[0])

    def walk(self, o, depth=0):
        f = self.f
        if depth > 32:
            return
        while True:
            cmd = f.u8(o)
            size = CMD_SIZES.get(cmd)
            if size is None:
                self.warnings.append(f'unknown geo cmd {cmd:#04x} at {o:#x}')
                return
            if cmd == 0x01 or cmd == 0x04:              # end / return
                return
            if cmd in (0x00, 0x03):                     # branch (with return)
                self.walk(f.ptr(o + 4), depth + 1)
            elif cmd == 0x02:                           # jump (no return)
                o = f.ptr(o + 4)
                continue
            elif cmd == 0x05:                           # open node
                self.stack.append(self.stack[-1])
            elif cmd == 0x06:                           # close node
                self.stack.pop()
            elif cmd == 0x17:                           # model header
                self.read_texture_table(f.ptr(o + 8), f.s16(o + 2))
                if f.ptr(o + 0xC):
                    self.read_tlut_table(f.ptr(o + 0xC), f.s16(o + 4))
                self.vtxBase = f.ptr(o + 0x10)
                self.nVerts = f.s16(o + 6)
            elif cmd == 0x08:                           # procedural effect callback
                self.fx.append(dict(bone=self.curBone(), callback=f.u32(o + 4),
                                    arg=f.ptr(o + 8)))
            elif cmd == 0x1C:                           # uniform scale node
                self.rootScale = [f.s32(o + 4) / 65536.0, f.s32(o + 8) / 65536.0,
                                  f.s32(o + 0xC) / 65536.0]
            elif cmd == 0x1D:                           # bone / joint node
                idx = len(self.bones)
                self.bones.append(dict(
                    parent=self.curBone(), boneId=f.u8(o + 1), flags=f.u8(o + 2),
                    chan=f.s8(o + 3),
                    t=[f.s16(o + 4), f.s16(o + 6), f.s16(o + 8)],
                    r=[f.s16(o + 0xA), f.s16(o + 0xC), f.s16(o + 0xE)],
                    s=[f.s32(o + 0x10) / 65536.0, f.s32(o + 0x14) / 65536.0,
                       f.s32(o + 0x18) / 65536.0]))
                self.boneById[f.u8(o + 1)] = idx
                self.stack[-1] = idx
            elif cmd == 0x23:                           # set texture / material
                self.curTex = f.s16(o + 8)
                self.curTlut = f.s16(o + 0xA)
                self.curMat = f.ptr(o + 4)
                # offset 0x02 is the texture-animation channel; -1 means static.
                # func_800176DC swaps this material's texture per frame from the
                # auxiliary animation's channel stream.
                self.curTexAnim = f.s16(o + 2)
            elif cmd == 0x22:                           # display list on current bone
                self.run_dl(f.ptr(o + 4), self.curBone())
            elif cmd == 0x1E:                           # display list on named bone
                self.run_dl(f.ptr(o + 4), self.boneById.get(f.s16(o + 2), self.curBone()))
            elif cmd in (0x20, 0x21):                   # display list + own transform
                self.run_dl(f.ptr(o + (0x10 if cmd == 0x20 else 0xC)), self.curBone())
            o += size

    def curBone(self):
        return self.stack[-2] if len(self.stack) >= 2 else -1

    # ---- display lists --------------------------------------------------
    def run_dl(self, o, bone, depth=0):
        if o is None or depth > 8:
            return
        f = self.f
        vbuf = self.vbuf
        cull = 0x400
        while True:
            w0, w1 = struct.unpack_from('>II', f.d, o)
            op = w0 >> 24
            o += 8
            if op == 0xDF:                              # G_ENDDL
                return
            if op == 0xDE:                              # G_DL
                self.run_dl(f.off(w1), bone, depth + 1)
                if (w0 >> 16) & 0xFF:                   # branch, not call
                    return
                continue
            if op == 0x01:                              # G_VTX
                n = (w0 >> 12) & 0xFF
                v0 = ((w0 & 0xFFF) >> 1) - n
                a = f.off(w1)
                for i in range(n):
                    p = a + i * 0x10
                    if 0 <= v0 + i < len(vbuf):
                        vbuf[v0 + i] = (
                            f.s16(p), f.s16(p + 2), f.s16(p + 4),       # position
                            f.s16(p + 8) / 32.0, f.s16(p + 10) / 32.0,  # s, t (S10.5)
                            f.s8(p + 12), f.s8(p + 13), f.s8(p + 14),   # normal
                            f.u8(p + 15),                               # alpha
                            bone)                                       # owning bone
                continue
            if op == 0xD9:                              # G_GEOMETRYMODE
                cull = (cull & (w0 & 0xFFFFFF)) | w1
                continue
            if op in (0x05, 0x06):                      # G_TRI1 / G_TRI2
                prim = self.prim_for(self.curTex, self.curTlut, self.curMat,
                                     self.curTexAnim, cull & 0x600)

                def emit(a, b, c):
                    tri = []
                    for idx in (a, b, c):
                        v = vbuf[idx] if idx < len(vbuf) else None
                        if v is None:
                            return
                        j = prim['_remap'].get(v)
                        if j is None:
                            j = len(prim['verts'])
                            prim['_remap'][v] = j
                            prim['verts'].append(v)
                        tri.append(j)
                    if (cull & 0x200) and not (cull & 0x400):
                        tri.reverse()
                    prim['tris'].append(tri)

                emit(((w0 >> 16) & 0xFF) // 2, ((w0 >> 8) & 0xFF) // 2, (w0 & 0xFF) // 2)
                if op == 0x06:
                    emit(((w1 >> 16) & 0xFF) // 2, ((w1 >> 8) & 0xFF) // 2, (w1 & 0xFF) // 2)
                continue
            # everything else (SETTILE / sync / ...) is state we reconstruct
            # from the texture table instead, so it is skipped.

    def prim_for(self, tex, tlut, mat, texAnim, cull):
        key = (tex, tlut, mat, texAnim, cull)
        p = self.primsByKey.get(key)
        if p is None:
            p = dict(tex=tex, tlut=tlut, mat=mat, texAnim=texAnim, cull=cull,
                     verts=[], tris=[], _remap={})
            self.primsByKey[key] = p
            self.prims.append(p)
        return p

    def tile_palette(self, mat):
        """CI4 selects a 16-entry block of the TLUT via the render tile's palette
        field; read it from the material display list's final G_SETTILE."""
        if mat is None:
            return 0
        pal = 0
        for _ in range(16):
            w0, w1 = struct.unpack_from('>II', self.f.d, mat)
            op = w0 >> 24
            if op == 0xF5 and ((w1 >> 24) & 7) == 0:        # G_SETTILE, render tile
                pal = (w1 >> 20) & 0xF
            elif op == 0xDF:
                break
            mat += 8
        return pal


# ---------------------------------------------------------------- animations

def bitfield(f, base, index, bits):
    """src/F420.c func_80010500: signed `bits`-wide field at bit index*bits.

    C integer division truncates toward zero; Python's floors. That only differs
    for negative indices, which is exactly what an empty channel produces, so the
    truncating form is used here to match the hardware."""
    bitpos = index * bits
    word = bitpos // 16 if bitpos >= 0 else -((-bitpos) // 16)   # C: trunc to zero
    rem = bitpos - word * 16                                     # C: sign follows bitpos
    o = base + word * 2
    v = (f.u16(o) << 16) | f.u16(o + 2)
    v = (v << (rem & 31)) & 0xFFFFFFFF          # MIPS masks the shift to 5 bits
    return signed(v >> (32 - bits), bits)


class Animation:
    """src/17300.c. Two sampling modes: packed per-frame streams (default) and
    hermite keyframes (flags & 8)."""

    def __init__(self, frag, off):
        f = self.f = frag
        self.off = off
        # The flags live in the LOW byte of the u16 at +0 -- reading the byte
        # AT +0 gets the always-zero high byte, which silently turns every
        # hermite animation (flags & 8: Pidgeot, Dodrio, Exeggutor, Tangela,
        # Magmar) into a packed-stream read of keyframe tables.
        self.flags     = f.u16(off)
        self.startFrame= f.u16(off + 4)
        self.loopStart = f.u16(off + 6)
        self.nChannels = f.u16(off + 8)
        self.nFrames   = f.u16(off + 0xA)
        self.chanTable = f.ptr(off + 0xC)
        self.scaleData = f.ptr(off + 0x10)
        self.rotData   = f.ptr(off + 0x14)
        self.transData = f.ptr(off + 0x18)

    def chan(self, i):
        o = self.chanTable + i * 0xA
        f = self.f
        return dict(nScale=f.u8(o), nRot=f.u8(o + 1), nTrans=f.u8(o + 2),
                    interp=f.u8(o + 3), oScale=f.u16(o + 4),
                    oRot=f.u16(o + 6), oTrans=f.u16(o + 8))

    # -- packed stream sampling (flags & 8 == 0) --------------------------
    # A count of 0 means the component has no stream. In the ROM that only
    # ever happens in HERMITE animations, where a count under 2 means "the
    # offset field IS the constant value" -- no packed animation of any of the
    # 151 species carries an empty channel, so the bind-pose fallback here is
    # dead code kept as a safety net.
    def _trans_packed(self, c, frame):
        if c['nTrans'] == 0:
            return None
        bits = 16 if (self.flags & 4) else 12
        if c['nTrans'] == 1:
            # (s16) casts both ways: func_80016848 reads the u16 offset field
            # back as a signed constant.
            return float(signed(c['oTrans'], 16) if (self.flags & 4)
                         else signed((c['oTrans'] * 16) & 0xFFFF, 16) >> 4)
        i = c['oTrans'] + min(frame, c['nTrans'] - 1)
        return float(bitfield(self.f, self.transData, i, bits))

    def _rot_packed(self, c, frame):
        if c['nRot'] == 0:
            return None
        if c['nRot'] == 1:
            return signed((c['oRot'] * 16) & 0xFFFF, 16)
        i = c['oRot'] + min(frame, c['nRot'] - 1)
        return signed((bitfield(self.f, self.rotData, i, 12) * 16) & 0xFFFF, 16)

    def _scale_packed(self, c, frame):
        if c['nScale'] == 0:
            return None
        if c['nScale'] == 1:
            return c['oScale'] / 1000.0
        i = c['oScale'] + min(frame, c['nScale'] - 1)
        return self.f.s16(self.scaleData + i * 2) / 1000.0

    # -- hermite keyframe sampling (flags & 8) ----------------------------
    def _hermite(self, base, n, frame, wide):
        f = self.f
        stride = 8 if wide else 6

        def key(i):
            o = base + i * stride
            return (f.s16(o), f.s16(o + 2), f.s16(o + 4),
                    f.s16(o + 6) if wide else f.s16(o + 4))

        k0 = key(0)
        if k0[0] >= frame:
            return float(k0[1])
        last = key(n - 1)
        if frame >= last[0]:
            return float(last[1])
        i = 0
        while i < n - 2:
            if frame < key(i + 1)[0]:
                break
            i += 1
        a, b = key(i), key(i + 1)
        x = (frame - a[0]) / 30.0
        y = 30.0 / (b[0] - a[0])
        x2, x3 = x * x, x * x * x
        y2, y3 = y * y, y * y * y
        return (a[1] * (2 * x3 * y3 - 3 * x2 * y2 + 1)
                + b[1] * (-2 * x3 * y3 + 3 * x2 * y2)
                + (a[3] if wide else a[2]) * (x3 * y2 - 2 * x2 * y + x)
                + b[2] * (x3 * y2 - x2 * y))

    def _trans_key(self, c, frame):
        if c['nTrans'] < 2:
            return float(signed(c['oTrans'], 16))
        return self._hermite(self.transData + c['oTrans'] * 2, c['nTrans'], frame, c['interp'] & 1)

    def _rot_key(self, c, frame):
        if c['nRot'] < 2:
            deg = signed(c['oRot'], 16) / 10.0
        else:
            deg = self._hermite(self.rotData + c['oRot'] * 2, c['nRot'], frame, c['interp'] & 2) / 10.0
        deg %= 360.0
        # func_80016DE0 returns s16: the f32 -> s16 cast WRAPS an angle above
        # 180 degrees to its negative twin. Same binary angle either way, but
        # the packer stores i16 with clamping, so an unwrapped 350-degree
        # value would pin at 32767 (= 180 degrees) instead.
        return signed(int(deg / 360.0 * 65536.0) & 0xFFFF, 16)

    def _scale_key(self, c, frame):
        if c['nScale'] < 2:
            return signed(c['oScale'], 16) / 100.0
        return self._hermite(self.scaleData + c['oScale'] * 2, c['nScale'], frame, c['interp'] & 4) / 100.0

    def sample_trs(self, chanIndex, frame, bind=None):
        """Returns (translation, rotation, scale) triples for one bone. Components
        whose channel carries no data fall back to the bone's bind value."""
        base = chanIndex * 3
        if base < 0 or base + 2 >= self.nChannels:
            return None
        cs = [self.chan(base + i) for i in range(3)]
        if self.flags & 8:
            out = ([self._trans_key(c, frame) for c in cs],
                   [self._rot_key(c, frame) for c in cs],
                   [self._scale_key(c, frame) for c in cs])
        else:
            out = ([self._trans_packed(c, frame) for c in cs],
                   [self._rot_packed(c, frame) for c in cs],
                   [self._scale_packed(c, frame) for c in cs])
        if bind is None:
            bind = ([0, 0, 0], [0, 0, 0], [1.0, 1.0, 1.0])
        return tuple([v if v is not None else bind[k][i] for i, v in enumerate(comp)]
                     for k, comp in enumerate(out))


class AuxAnimation:
    """Texture animation (src/18140.c). Same header shape as the skeletal
    animations, but each channel is a per-frame stream of texture-table indices
    that func_800176DC substitutes into a material."""

    def __init__(self, frag, off):
        f = self.f = frag
        self.flags     = f.u16(off)         # low byte, same layout as Animation
        self.startFrame= f.u16(off + 4)
        self.loopStart = f.u16(off + 6)
        self.nChannels = f.u16(off + 8)
        self.nFrames   = f.u16(off + 0xA)
        self.chanTable = f.ptr(off + 0xC)
        self.data      = f.ptr(off + 0x10)

    def sample(self, chan, frame):
        """func_80017540: index into the stream, clamped to the channel length."""
        if not (0 <= chan < self.nChannels) or self.chanTable is None:
            return None
        o = self.chanTable + chan * 4
        count, base = self.f.u16(o), self.f.u16(o + 2)
        if count == 0:
            return None
        i = base + (frame if frame < count else count - 1)
        return self.f.u8(self.data + i)

    def track(self, chan):
        n = max(1, self.nFrames)
        return [self.sample(chan, i) for i in range(n)]


# ------------------------------------------------------------------ textures

def rgba5551(p):
    return (((p >> 11) & 0x1F) * 255 // 31, ((p >> 6) & 0x1F) * 255 // 31,
            ((p >> 1) & 0x1F) * 255 // 31, 255 if (p & 1) else 0)


def decode_texture(f, tex, tlut=None, palette=0):
    """Returns (w, h, RGBA8 bytes) for the N64 texture formats these models use."""
    w, h, fmt, siz, addr = tex['w'], tex['h'], tex['fmt'], tex['siz'], tex['data']
    out = bytearray(w * h * 4)
    d = f.d
    n = w * h

    def nibble(i):
        return (d[addr + i // 2] >> (0 if i & 1 else 4)) & 0xF

    if fmt == 0 and siz == 2:                       # RGBA16 (5/5/5/1)
        for i in range(n):
            out[i*4:i*4+4] = bytes(rgba5551(struct.unpack_from('>H', d, addr + i * 2)[0]))
    elif fmt == 0 and siz == 3:                     # RGBA32
        out[:] = d[addr:addr + n * 4]
    elif fmt == 2:                                  # CI4 / CI8 -> RGBA16 palette
        pal = []
        if tlut is not None and tlut['data'] is not None:
            base = tlut['data'] + (palette * 16 * 2 if siz == 0 else 0)
            for i in range(16 if siz == 0 else 256):
                pal.append(bytes(rgba5551(struct.unpack_from('>H', d, base + i * 2)[0])))
        if not pal:
            pal = [b'\xff\x00\xff\xff'] * 256
        for i in range(n):
            idx = nibble(i) if siz == 0 else d[addr + i]
            out[i*4:i*4+4] = pal[idx % len(pal)]
    elif fmt == 3:                                  # IA16 / IA8 / IA4
        for i in range(n):
            if siz == 2:
                v = struct.unpack_from('>H', d, addr + i * 2)[0]
                l, a = v >> 8, v & 0xFF
            elif siz == 1:
                v = d[addr + i]
                l, a = (v >> 4) * 17, (v & 0xF) * 17
            else:
                v = nibble(i)
                l, a = ((v >> 1) * 255) // 7, 255 if (v & 1) else 0
            out[i*4:i*4+4] = bytes((l, l, l, a))
    elif fmt == 4:                                  # I8 / I4
        for i in range(n):
            l = d[addr + i] if siz == 1 else nibble(i) * 17
            out[i*4:i*4+4] = bytes((l, l, l, 255))
    else:
        for i in range(n):                          # unsupported: magenta
            out[i*4:i*4+4] = b'\xff\x00\xff\xff'
    return w, h, bytes(out)


def png(w, h, rgba):
    """Minimal PNG encoder (no PIL dependency)."""
    raw = b''.join(b'\x00' + rgba[y*w*4:(y+1)*w*4] for y in range(h))

    def chunk(tag, data):
        c = tag + data
        return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xFFFFFFFF)

    return (b'\x89PNG\r\n\x1a\n'
            + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(raw, 9))
            + chunk(b'IEND', b''))


# ---------------------------------------------------------------------- main

def unique(seq):
    """The distinct values of `seq`, in the order they first appear.

    Used where a set used to be. A set of small ints iterates in hash-slot
    order, which is stable across runs but is neither insertion nor sort order
    and is a CPython implementation detail -- and here it decided the order
    textures get REGISTERED in, and so their indices in the packed file. Order
    of appearance is a property of the data instead of the interpreter, which
    is what lets the Lua extractor produce the same file.
    """
    seen, out = set(), []
    for v in seq:
        if v in seen:
            continue
        seen.add(v)
        out.append(v)
    return out


def dedupe_fx(nodes):
    """The geo layout's effect callbacks, once each, IN THE ORDER THEY APPEAR.

    A geo layout can name the same callback on the same bone more than once
    (the walk visits a subtree twice), so these have to be deduplicated, and it
    used to be done by dropping them through a set. That was a real bug rather
    than a style point: the set held tuples containing strings, so its iteration
    order moved with PYTHONHASHSEED, and the generated flames of every species
    carrying more than one -- Ponyta, Rapidash and Moltres -- came out in a
    different order, with different seeds and therefore different pixels, on
    different runs of the same build.

    Order of appearance is the game's own order, it is stable, and it is what
    the Lua extractor can reproduce.
    """
    seen, out = set(), []
    for node in nodes:
        key = (node['bone'], node['callback'], node['arg'])
        if key in seen:
            continue
        seen.add(key)
        out.append(dict(node))
    return out


def extract(path, name=None, raw=False):
    """`raw=True` carries each texture's decoded RGBA8 bytes as `rgba` instead
    of encoding a PNG data URI into `png`.

    The viewer and the glTF export both want a PNG, so that stays the default.
    The mod's own packer wants the pixels: it stores them uncompressed, so that
    its Lua counterpart -- which has no zlib whose output is guaranteed to
    agree with this one's byte for byte -- can be checked against it exactly.
    """
    f = Fragment(path, name or str(path))
    m = Model(f)
    m.build()

    import base64
    auxAnims = [AuxAnimation(f, o) for o in m.auxAnims]

    texIndexMap, texOut = {}, []

    def register(texIdx, tlut, pal):
        key = (texIdx, tlut, pal)
        if key in texIndexMap:
            return texIndexMap[key]
        if not (0 <= texIdx < len(m.textures)):
            return -1
        texIndexMap[key] = len(texOut)
        tl = m.tluts[tlut] if 0 <= tlut < len(m.tluts) else None
        w, h, rgba = decode_texture(f, m.textures[texIdx], tl, pal)
        rec = dict(index=texIdx, w=w, h=h)
        if raw:
            rec['rgba'] = rgba
        else:
            rec['png'] = ('data:image/png;base64,'
                          + base64.b64encode(png(w, h, rgba)).decode())
        texOut.append(rec)
        return texIndexMap[key]

    for p in m.prims:
        if not p['tris']:
            continue
        pal = m.tile_palette(p['mat'])
        register(p['tex'], p['tlut'], pal)
        # An animated material can swap to any texture its channel names, so all
        # of them have to be decoded up front.
        if p['texAnim'] >= 0:
            for a in auxAnims:
                for t in unique(a.track(p['texAnim'])):
                    if t is not None:
                        register(t, p['tlut'], pal)

    prims = []
    for p in m.prims:
        if not p['tris']:
            continue
        pos, uv, nrm, skin = [], [], [], []
        pal = m.tile_palette(p['mat'])
        ti = texIndexMap.get((p['tex'], p['tlut'], pal), -1)
        # texture-table index -> slot in texOut, for the animated swap
        texMap = {}
        if p['texAnim'] >= 0:
            for a in auxAnims:
                for t in unique(a.track(p['texAnim'])):
                    if t is not None and (t, p['tlut'], pal) in texIndexMap:
                        texMap[t] = texIndexMap[(t, p['tlut'], pal)]
        tw, th = (m.textures[p['tex']]['w'], m.textures[p['tex']]['h']) if ti >= 0 else (32, 32)
        for v in p['verts']:
            pos += [v[0], v[1], v[2]]
            uv += [v[3] / tw, v[4] / th]
            nrm += [v[5] / 127.0, v[6] / 127.0, v[7] / 127.0]
            skin.append(v[9])
        prims.append(dict(tex=ti, cull=p['cull'], texAnim=p['texAnim'],
                          texMap={str(k): v for k, v in sorted(texMap.items())},
                          pos=pos, uv=uv, nrm=nrm, skin=skin,
                          idx=[i for t in p['tris'] for i in t]))

    def compress(values, nd):
        """Constant tracks collapse to a scalar; most channels never move."""
        r = [round(v, nd) for v in values]
        return r[0] if all(v == r[0] for v in r) else r

    anims = []
    for i, off in enumerate(m.anims):
        a = Animation(f, off)
        nf = max(1, a.nFrames)
        tracks = []
        for b in m.bones:
            ch = b['chan']
            bind = (b['t'], b['r'], b['s'])
            if ch < 0 or a.sample_trs(ch, 0, bind) is None:
                tracks.append(None)
                continue
            samples = [a.sample_trs(ch, fr, bind) for fr in range(nf)]
            tracks.append(dict(
                t=[compress([s[0][k] for s in samples], 3) for k in range(3)],
                r=[compress([s[1][k] for s in samples], 0) for k in range(3)],
                s=[compress([s[2][k] for s in samples], 5) for k in range(3)]))
        anims.append(dict(index=i, frames=nf, flags=a.flags,
                          channels=a.nChannels, loopStart=a.loopStart, tracks=tracks))

    auxOut = []
    for i, a in enumerate(auxAnims):
        auxOut.append(dict(index=i, frames=max(1, a.nFrames), flags=a.flags,
                           loopStart=a.loopStart,
                           channels=[a.track(c) for c in range(a.nChannels)]))

    return dict(
        species=m.species,
        name=SPECIES.get(m.species, f'#{m.species}'),
        file=os.path.basename(f.name),
        rootScale=m.rootScale,
        bones=[dict(parent=b['parent'], boneId=b['boneId'], chan=b['chan'],
                    flags=b['flags'], t=b['t'], r=b['r'], s=b['s']) for b in m.bones],
        textures=texOut,
        prims=prims,
        anims=anims,
        auxAnims=auxOut,
        fx=dedupe_fx(m.fx),
        warnings=m.warnings,
    )


SPECIES = {}
_NAMES = (
    "Bulbasaur Ivysaur Venusaur Charmander Charmeleon Charizard Squirtle Wartortle Blastoise "
    "Caterpie Metapod Butterfree Weedle Kakuna Beedrill Pidgey Pidgeotto Pidgeot Rattata Raticate "
    "Spearow Fearow Ekans Arbok Pikachu Raichu Sandshrew Sandslash NidoranF Nidorina Nidoqueen "
    "NidoranM Nidorino Nidoking Clefairy Clefable Vulpix Ninetales Jigglypuff Wigglytuff Zubat "
    "Golbat Oddish Gloom Vileplume Paras Parasect Venonat Venomoth Diglett Dugtrio Meowth Persian "
    "Psyduck Golduck Mankey Primeape Growlithe Arcanine Poliwag Poliwhirl Poliwrath Abra Kadabra "
    "Alakazam Machop Machoke Machamp Bellsprout Weepinbell Victreebel Tentacool Tentacruel Geodude "
    "Graveler Golem Ponyta Rapidash Slowpoke Slowbro Magnemite Magneton Farfetchd Doduo Dodrio "
    "Seel Dewgong Grimer Muk Shellder Cloyster Gastly Haunter Gengar Onix Drowzee Hypno Krabby "
    "Kingler Voltorb Electrode Exeggcute Exeggutor Cubone Marowak Hitmonlee Hitmonchan Lickitung "
    "Koffing Weezing Rhyhorn Rhydon Chansey Tangela Kangaskhan Horsea Seadra Goldeen Seaking "
    "Staryu Starmie MrMime Scyther Jynx Electabuzz Magmar Pinsir Tauros Magikarp Gyarados Lapras "
    "Ditto Eevee Vaporeon Jolteon Flareon Porygon Omanyte Omastar Kabuto Kabutops Aerodactyl "
    "Snorlax Articuno Zapdos Moltres Dratini Dragonair Dragonite Mewtwo Mew").split()
for _i, _n in enumerate(_NAMES):
    SPECIES[_i + 1] = _n


if __name__ == '__main__':
    here = os.path.dirname(os.path.abspath(__file__))
    src = sys.argv[1] if len(sys.argv) > 1 else 'assets/us/pokemon_models/24.bin'
    dst = sys.argv[2] if len(sys.argv) > 2 else os.path.join(here, 'model.js')
    data = extract(src)
    body = json.dumps(data, separators=(',', ':'))
    with open(dst, 'w') as fp:
        fp.write('window.PKMN_MODEL = ' + body + ';\n')
    tris = sum(len(p['idx']) // 3 for p in data['prims'])
    print(f"{data['name']} (#{data['species']})  bones={len(data['bones'])}  prims={len(data['prims'])}  "
          f"tris={tris}  textures={len(data['textures'])}  anims={len(data['anims'])}")
    print(f"frames per anim: {[a['frames'] for a in data['anims']]}")
    if data['warnings']:
        print('warnings:', data['warnings'][:5])
    print(f'wrote {dst} ({os.path.getsize(dst)/1024:.0f} KB)')
