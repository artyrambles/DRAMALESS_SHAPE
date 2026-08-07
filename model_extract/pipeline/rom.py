#!/usr/bin/env python3
"""
Raw ROM access for the Pokemon Stadium (US) model export.

Everything here is stdlib-only: byte-order fixup, the Yay0 decompressor, the
PERS-SZP wrapper the assets use, and the little archive format that packs many
files into one segment. That is all it takes to get from baserom.z64 to model
data, so the export does not need `make init`, splat or crunch64.
"""
import hashlib
import struct

# ROM offsets taken from pokestadium-us.yaml.
POKEMON_MODELS = 0x920000       # archive of the 215 battle models
BATTLE_DATA    = 0x70D3A0       # per-species battle tables, indexed by D_80075BD0
MAIN_ROM       = 0x1000         # main code segment ...
MAIN_VRAM      = 0x80000400     # ... and where it lands in RAM
PTR_TABLE_VRAM = 0x80075BD0     # D_80075BD0[species - 1] -> offset into BATTLE_DATA

US_MD5 = 'ed1378bc12115f71209a77844965ba50'


class Rom:
    def __init__(self, path):
        data = bytearray(open(path, 'rb').read())
        magic = struct.unpack_from('>I', data, 0)[0]
        if magic == 0x37804012:                     # .v64, byte-swapped pairs
            data[0::2], data[1::2] = data[1::2], data[0::2]
        elif magic == 0x40123780:                   # .n64, word-reversed
            data = bytearray(b''.join(data[i:i+4][::-1] for i in range(0, len(data), 4)))
        elif magic != 0x80371240:                   # .z64, native big endian
            raise ValueError(f'{path}: not an N64 ROM (magic {magic:#010x})')
        self.data = bytes(data)
        self.md5 = hashlib.md5(self.data).hexdigest()

    @property
    def is_expected_us(self):
        return self.md5 == US_MD5

    def u32(self, o):
        return struct.unpack_from('>I', self.data, o)[0]

    def vram_to_rom(self, vram):
        return MAIN_ROM + (vram - MAIN_VRAM)

    # ---- archive ---------------------------------------------------------
    def archive(self, off):
        """Segments that hold many files start with
             u32 tag, u32 0, u32 totalSize, u32 fileCount
           followed by fileCount { u32 offset, u32 size, u32 pad[2] } records,
           all relative to the start of the segment (tools/unpack_asset.py).
           Only the top three bytes of the first word are reliably zero -- the
           model archive puts a nonzero value in the low byte."""
        if (self.u32(off) & 0xFFFFFF00) != 0 or self.u32(off + 4) != 0:
            return [self.data[off:]]
        count = self.u32(off + 12)
        if not 0 < count < 4096:
            return [self.data[off:]]
        out = []
        for i in range(count):
            rec = off + 0x10 + i * 0x10
            start, size = self.u32(rec), self.u32(rec + 4)
            out.append(self.data[off + start: off + start + size])
        return out


# ------------------------------------------------------------- decompression

def yay0_decompress(src):
    """Nintendo Yay0. Header: magic, decompressed size, link offset, chunk
    offset; then a bitstream where a 1 copies one literal byte and a 0 pulls a
    (distance, length) pair from the link table."""
    if src[:4] != b'Yay0':
        raise ValueError('not Yay0')
    size, link_off, chunk_off = struct.unpack_from('>3I', src, 4)
    out = bytearray(size)
    mask_p, link_p, chunk_p, pos = 0x10, link_off, chunk_off, 0
    mask, bits = 0, 0
    while pos < size:
        if bits == 0:
            mask = struct.unpack_from('>I', src, mask_p)[0]
            mask_p += 4
            bits = 32
        if mask & 0x80000000:
            out[pos] = src[chunk_p]
            chunk_p += 1
            pos += 1
        else:
            link = struct.unpack_from('>H', src, link_p)[0]
            link_p += 2
            dist = link & 0x0FFF
            count = link >> 12
            if count == 0:
                count = src[chunk_p] + 0x12
                chunk_p += 1
            else:
                count += 2
            copy = pos - dist - 1
            for _ in range(count):                  # overlapping runs are legal
                out[pos] = out[copy]
                pos += 1
                copy += 1
        mask = (mask << 1) & 0xFFFFFFFF
        bits -= 1
    return bytes(out)


def decompress(blob):
    """Unwrap whatever container an asset arrived in."""
    if blob[:8] == b'PERS-SZP':
        header = struct.unpack_from('>I', blob, 8)[0]
        return yay0_decompress(blob[header:])
    if blob[:4] == b'Yay0':
        return yay0_decompress(blob)
    return blob


def pokemon_models(rom):
    """Returns the decompressed model fragments, indexed by file number."""
    return [decompress(b) for b in rom.archive(POKEMON_MODELS)]
