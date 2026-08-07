#!/usr/bin/env python3
"""
glTF 2.0 binary writer.

Each game bone becomes two nodes -- a pivot carrying translation/rotation and a
leaf carrying the accumulated scale -- because the game keeps scale out of the
matrix chain while glTF propagates it to children. See ../README.md.
"""
import json
import math
import struct

ND = 7          # decimals kept on node rest transforms


def quat_from_euler(r):
    """The game's rotation is Rx*Ry*Rz in row-vector form (src/F420.c
    func_8000F730); build that basis as glTF columns and convert."""
    sx, cx = math.sin(r[0] / 32768 * math.pi), math.cos(r[0] / 32768 * math.pi)
    sy, cy = math.sin(r[1] / 32768 * math.pi), math.cos(r[1] / 32768 * math.pi)
    sz, cz = math.sin(r[2] / 32768 * math.pi), math.cos(r[2] / 32768 * math.pi)
    # rows of the game matrix become the columns of the glTF rotation
    m = ((cy*cz, sx*sy*cz - cx*sz, cx*sy*cz + sx*sz),
         (cy*sz, sx*sy*sz + cx*cz, cx*sy*sz - sx*cz),
         (-sy,   sx*cy,            cx*cy))
    tr = m[0][0] + m[1][1] + m[2][2]
    if tr > 0:
        s = math.sqrt(tr + 1.0) * 2
        w = 0.25 * s
        x = (m[2][1] - m[1][2]) / s
        y = (m[0][2] - m[2][0]) / s
        z = (m[1][0] - m[0][1]) / s
    elif m[0][0] > m[1][1] and m[0][0] > m[2][2]:
        s = math.sqrt(1.0 + m[0][0] - m[1][1] - m[2][2]) * 2
        w = (m[2][1] - m[1][2]) / s
        x = 0.25 * s
        y = (m[0][1] + m[1][0]) / s
        z = (m[0][2] + m[2][0]) / s
    elif m[1][1] > m[2][2]:
        s = math.sqrt(1.0 + m[1][1] - m[0][0] - m[2][2]) * 2
        w = (m[0][2] - m[2][0]) / s
        x = (m[0][1] + m[1][0]) / s
        y = 0.25 * s
        z = (m[1][2] + m[2][1]) / s
    else:
        s = math.sqrt(1.0 + m[2][2] - m[0][0] - m[1][1]) * 2
        w = (m[1][0] - m[0][1]) / s
        x = (m[0][2] + m[2][0]) / s
        y = (m[1][2] + m[2][1]) / s
        z = 0.25 * s
    n = math.sqrt(x*x + y*y + z*z + w*w) or 1.0
    return [x/n, y/n, z/n, w/n]


def pose(bones, sample_fn):
    """Returns (pivotT, pivotQ, jointS) for every bone at one instant."""
    acc, pt, pq, js = [], [], [], []
    for i, b in enumerate(bones):
        t, r, s = sample_fn(i, b)
        pa = acc[b['parent']] if b['parent'] >= 0 else (1.0, 1.0, 1.0)
        pt.append([t[0]*pa[0], t[1]*pa[1], t[2]*pa[2]])
        pq.append(quat_from_euler(r))
        a = (pa[0]*s[0], pa[1]*s[1], pa[2]*s[2])
        acc.append(a)
        js.append(list(a))
    return pt, pq, js


# ------------------------------------------------------------------ glTF build

class Glb:
    def __init__(self):
        self.buf = bytearray()
        self.views = []
        self.accessors = []

    def view(self, data, target=None):
        while len(self.buf) % 4:
            self.buf.append(0)
        off = len(self.buf)
        self.buf += data
        v = dict(buffer=0, byteOffset=off, byteLength=len(data))
        if target:
            v['target'] = target
        self.views.append(v)
        return len(self.views) - 1

    def accessor(self, data, ctype, atype, count, target=None,
                 minmax=None, normalized=False):
        a = dict(bufferView=self.view(data, target), componentType=ctype,
                 count=count, type=atype)
        if normalized:
            a['normalized'] = True
        if minmax:
            a['min'], a['max'] = minmax
        self.accessors.append(a)
        return len(self.accessors) - 1

    def floats(self, values, atype, target=None, minmax=None):
        n = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4, 'MAT4': 16}[atype]
        return self.accessor(struct.pack(f'<{len(values)}f', *values),
                             5126, atype, len(values) // n, target, minmax)

    def finish(self, gltf):
        gltf['buffers'] = [dict(byteLength=len(self.buf))]
        gltf['bufferViews'] = self.views
        gltf['accessors'] = self.accessors
        js = json.dumps(gltf, separators=(',', ':')).encode()
        js += b' ' * (-len(js) % 4)
        bin_ = bytes(self.buf) + b'\0' * (-len(self.buf) % 4)
        return (struct.pack('<III', 0x46546C67, 2, 12 + 8 + len(js) + 8 + len(bin_))
                + struct.pack('<II', len(js), 0x4E4F534A) + js
                + struct.pack('<II', len(bin_), 0x004E4942) + bin_)


def build_glb(data, pngs):
    bones = data['bones']
    nb = len(bones)
    g = Glb()
    gltf = dict(asset=dict(version='2.0',
                           generator='pokestadium tools/model_viewer/export_gltf.py'))

    # ---- nodes: root scale, then a pivot/joint pair per bone ----------------
    bind_t, bind_q, bind_s = pose(bones, lambda i, b: (b['t'], b['r'], b['s']))
    nodes = [dict(name='model_root', scale=[round(v, 6) for v in data['rootScale']])]
    pivot_id = [0] * nb
    joint_id = [0] * nb
    for i, b in enumerate(bones):
        pivot_id[i] = len(nodes)
        nodes.append(dict(name=f'bone{b["boneId"]:02d}',
                          translation=[round(v, ND) for v in bind_t[i]],
                          rotation=[round(v, ND) for v in bind_q[i]]))
        joint_id[i] = len(nodes)
        nodes.append(dict(name=f'bone{b["boneId"]:02d}_scale',
                          scale=[round(v, ND) for v in bind_s[i]]))
        nodes[pivot_id[i]]['children'] = [joint_id[i]]
    for i, b in enumerate(bones):
        parent = pivot_id[b['parent']] if b['parent'] >= 0 else 0
        nodes[parent].setdefault('children', []).append(pivot_id[i])

    # ---- textures / materials ---------------------------------------------
    images, samplers, textures, materials = [], [], [], []
    if pngs:
        samplers.append(dict(magFilter=9729, minFilter=9729,
                             wrapS=33071, wrapT=33071))       # LINEAR, CLAMP
    for i, blob in enumerate(pngs):
        images.append(dict(mimeType='image/png',
                           bufferView=g.view(blob), name=f'tex{i:02d}'))
        textures.append(dict(sampler=0, source=i))

    prims_out = []
    for p in data['prims']:
        nv = len(p['pos']) // 3
        pos = [float(v) for v in p['pos']]
        mn = [min(pos[k::3]) for k in range(3)]
        mx = [max(pos[k::3]) for k in range(3)]
        attrs = dict(
            POSITION=g.floats(pos, 'VEC3', 34962, (mn, mx)),
            NORMAL=g.floats([float(v) for v in p['nrm']], 'VEC3', 34962),
            TEXCOORD_0=g.floats([float(v) for v in p['uv']], 'VEC2', 34962),
            JOINTS_0=g.accessor(
                struct.pack(f'<{nv*4}H', *[v for j in p['skin'] for v in (j, 0, 0, 0)]),
                5123, 'VEC4', nv, 34962),
            WEIGHTS_0=g.floats([v for _ in range(nv) for v in (1.0, 0.0, 0.0, 0.0)],
                               'VEC4', 34962),
        )
        idx = g.accessor(struct.pack(f'<{len(p["idx"])}H', *p['idx']),
                         5123, 'SCALAR', len(p['idx']), 34963)
        blend = p.get('blend')
        mat = dict(
            name=f'mat{len(materials):02d}',
            alphaMode='BLEND' if blend else 'MASK',
            doubleSided=bool(blend) or not (p['cull'] & 0x400),
            pbrMetallicRoughness=dict(metallicFactor=0.0, roughnessFactor=0.9),
        )
        if blend:
            # generated effects are unlit so they read as emissive fire/gas
            mat['emissiveFactor'] = [1.0, 1.0, 1.0]
        else:
            mat['alphaCutoff'] = 0.5
        if p['tex'] >= 0:
            mat['pbrMetallicRoughness']['baseColorTexture'] = dict(index=p['tex'])
            if blend:
                mat['emissiveTexture'] = dict(index=p['tex'])
        materials.append(mat)
        prims_out.append(dict(attributes=attrs, indices=idx,
                              material=len(materials) - 1))

    skin_node = len(nodes)
    nodes.append(dict(name=data['name'], mesh=0, skin=0))

    ident = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
    gltf['skins'] = [dict(joints=joint_id, skeleton=0,
                          inverseBindMatrices=g.floats(ident * nb, 'MAT4'))]
    gltf['meshes'] = [dict(name=data['name'], primitives=prims_out)]

    # ---- animations --------------------------------------------------------
    anims = []
    for a in data['anims']:
        nf = a['frames']
        times = [round(fr / 30.0, 6) for fr in range(nf)]   # authored at 30 fps

        def sample_fn(i, b, _a=a):
            tr = _a['tracks'][i]
            if not tr:
                return b['t'], b['r'], b['s']
            pick = lambda c, fr: (c if isinstance(c, (int, float))
                                  else c[min(fr, len(c) - 1)])
            return ([pick(c, sample_fn.fr) for c in tr['t']],
                    [pick(c, sample_fn.fr) for c in tr['r']],
                    [pick(c, sample_fn.fr) for c in tr['s']])

        seq_t = [[] for _ in range(nb)]
        seq_q = [[] for _ in range(nb)]
        seq_s = [[] for _ in range(nb)]
        for fr in range(nf):
            sample_fn.fr = fr
            pt, pq, js = pose(bones, sample_fn)
            for i in range(nb):
                if seq_q[i] and sum(x*y for x, y in zip(seq_q[i][-1], pq[i])) < 0:
                    pq[i] = [-v for v in pq[i]]     # keep quaternions continuous
                seq_t[i].append(pt[i]); seq_q[i].append(pq[i]); seq_s[i].append(js[i])

        channels, samplers_a = [], []
        cache = {}

        def time_accessor(keys):
            if keys not in cache:
                t = times if keys == nf else [times[0], times[-1]]
                cache[keys] = g.floats(t, 'SCALAR', minmax=([t[0]], [t[-1]]))
            return cache[keys]

        for i in range(nb):
            for seq, path, node, dflt in (
                    (seq_t[i], 'translation', pivot_id[i], nodes[pivot_id[i]]['translation']),
                    (seq_q[i], 'rotation', pivot_id[i], nodes[pivot_id[i]]['rotation']),
                    (seq_s[i], 'scale', joint_id[i], nodes[joint_id[i]]['scale'])):
                const = all(v == seq[0] for v in seq)
                # A constant channel can only be dropped when it already equals the
                # node's rest value; otherwise the node would sit in its bind pose.
                if const and [round(c, ND) for c in seq[0]] == dflt:
                    continue
                if const:
                    seq = [seq[0], seq[0]]
                time_acc = time_accessor(len(seq))
                flat = [c for v in seq for c in v]
                if path == 'rotation':
                    out = g.accessor(
                        struct.pack(f'<{len(flat)}h',
                                    *[max(-32768, min(32767, round(c * 32767)))
                                      for c in flat]),
                        5122, 'VEC4', len(seq), normalized=True)
                else:
                    out = g.floats(flat, 'VEC3')
                samplers_a.append(dict(input=time_acc, output=out,
                                       interpolation='LINEAR'))
                channels.append(dict(sampler=len(samplers_a) - 1,
                                     target=dict(node=node, path=path)))
        if channels:
            anims.append(dict(name=a['name'], channels=channels, samplers=samplers_a))
    if anims:
        gltf['animations'] = anims

    gltf['nodes'] = nodes
    gltf['scenes'] = [dict(nodes=[0, skin_node])]
    gltf['scene'] = 0
    if images:
        gltf['images'] = images
        gltf['samplers'] = samplers
        gltf['textures'] = textures
    gltf['materials'] = materials
    return g.finish(gltf)


