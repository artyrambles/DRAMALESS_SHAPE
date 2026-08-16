-- Minimal 4x4 matrix math for voxel world mode.
--
-- Row-major, and sent to the shader with shader:send("mvp", "row", m).
-- LOVE 11.5's matrix uniform defaults to column-major, so the "row" layout
-- argument is what lets these tables read the same way they are written
-- here -- translation in the fourth column, m[4]/m[8]/m[12].
--
-- Only what the renderer actually needs: a perspective projection (the
-- camera), an orthographic one (the sun's shadow pass), a look-based view,
-- and the translate/rotateY/scale a model matrix is built from. No general
-- inverse, no quaternions.

local Mat4 = {}

function Mat4.identity()
  return { 1, 0, 0, 0,
           0, 1, 0, 0,
           0, 0, 1, 0,
           0, 0, 0, 1 }
end

-- a * b, both row-major
function Mat4.mul(a, b)
  local o = {}
  for r = 0, 3 do
    local a0, a1 = a[r * 4 + 1], a[r * 4 + 2]
    local a2, a3 = a[r * 4 + 3], a[r * 4 + 4]
    for c = 1, 4 do
      o[r * 4 + c] = a0 * b[c] + a1 * b[4 + c] + a2 * b[8 + c] + a3 * b[12 + c]
    end
  end
  return o
end

function Mat4.translate(x, y, z)
  return { 1, 0, 0, x,
           0, 1, 0, y,
           0, 0, 1, z,
           0, 0, 0, 1 }
end

function Mat4.scale(x, y, z)
  return { x, 0, 0, 0,
           0, y, 0, 0,
           0, 0, z, 0,
           0, 0, 0, 1 }
end

function Mat4.rotateY(a)
  local c, s = math.cos(a), math.sin(a)
  return { c, 0, s, 0,
           0, 1, 0, 0,
          -s, 0, c, 0,
           0, 0, 0, 1 }
end

function Mat4.rotateX(a)
  local c, s = math.cos(a), math.sin(a)
  return { 1, 0, 0, 0,
           0, c, -s, 0,
           0, s, c, 0,
           0, 0, 0, 1 }
end

-- Right-handed perspective onto GL clip space (z in [-1, 1]).
function Mat4.perspective(fovY, aspect, near, far)
  local f = 1 / math.tan(fovY / 2)
  local d = near - far
  return { f / aspect, 0, 0, 0,
           0, f, 0, 0,
           0, 0, (far + near) / d, (2 * far * near) / d,
           0, 0, -1, 0 }
end

-- Right-handed orthographic projection onto GL clip space (z in [-1, 1]).
-- The view-space box is x in [l, r], y in [b, t], z in [-f, -n] -- near and
-- far are DISTANCES down the view's -z, exactly as in perspective() above.
-- Parallel, so a sun is a direction and nothing else: no eye point, no
-- foreshortening, and clip z stays linear in world units, which is what
-- lets the shadow pass store depth as a plain number.
function Mat4.ortho(l, r, b, t, n, f)
  return { 2 / (r - l), 0, 0, -(r + l) / (r - l),
           0, 2 / (t - b), 0, -(t + b) / (t - b),
           0, 0, -2 / (f - n), -(f + n) / (f - n),
           0, 0, 0, 1 }
end

-- re-addded from TERRARIUM
-- The inverse of `m`, or nil when it has none.
--
-- Gauss-Jordan on the augmented [M | I] rather than the cofactor formula:
-- this runs once per frame against a matrix that is already built, so the
-- fifty microseconds the elimination costs over the closed form buy nothing
-- worth having -- and a closed-form 4x4 adjugate is sixteen expressions
-- nobody can check by reading, in a file whose whole layout convention
-- (row-major, translation in the fourth column) is the sort of thing a
-- transcribed formula gets silently backwards.
--
-- Partial pivoting, because the camera matrix has a zero in [1][1] at no
-- pitch worth naming but a projection row that is all zeros but one, and a
-- naive elimination divides by whatever happens to be on the diagonal.
function Mat4.invert(m)
  local a = {}
  for r = 0, 3 do
    local row = {}
    for c = 1, 4 do row[c] = m[r * 4 + c] end
    for c = 1, 4 do row[4 + c] = (c == r + 1) and 1 or 0 end
    a[r + 1] = row
  end

  for i = 1, 4 do
    local p, best = i, math.abs(a[i][i])
    for r = i + 1, 4 do
      local v = math.abs(a[r][i])
      if v > best then p, best = r, v end
    end
    -- singular: the caller drops whatever it wanted the inverse for rather
    -- than dividing by a rounding error
    if best < 1e-12 then return nil end
    a[i], a[p] = a[p], a[i]
    local piv = a[i][i]
    for c = 1, 8 do a[i][c] = a[i][c] / piv end
    for r = 1, 4 do
      if r ~= i then
        local f = a[r][i]
        if f ~= 0 then
          for c = 1, 8 do a[r][c] = a[r][c] - f * a[i][c] end
        end
      end
    end
  end

  local o = {}
  for r = 1, 4 do
    for c = 1, 4 do o[(r - 1) * 4 + c] = a[r][4 + c] end
  end
  return o
end

-- Right-handed look-at. eye/target/up are {x, y, z}.
function Mat4.lookAt(eye, target, up)
  local function sub(a, b) return { a[1] - b[1], a[2] - b[2], a[3] - b[3] } end
  local function norm(v)
    local l = math.sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3])
    if l == 0 then return { 0, 0, 0 } end
    return { v[1] / l, v[2] / l, v[3] / l }
  end
  local function cross(a, b)
    return { a[2] * b[3] - a[3] * b[2],
             a[3] * b[1] - a[1] * b[3],
             a[1] * b[2] - a[2] * b[1] }
  end
  local function dot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end

  local f = norm(sub(target, eye))     -- forward
  local s = norm(cross(f, up))         -- right
  local u = cross(s, f)                -- true up
  return { s[1], s[2], s[3], -dot(s, eye),
           u[1], u[2], u[3], -dot(u, eye),
          -f[1], -f[2], -f[3], dot(f, eye),
           0, 0, 0, 1 }
end


-- Hot-path model constructors. They are algebraically identical to composing
-- translate/rotate/scale matrices with Mat4.mul, but allocate ONE 16-number
-- table instead of a chain of temporary matrices.

-- T(px+8,y,py+8) * Ry(yaw) * Rx(pitch) * Sx(mirror) * T(-8,0,0)
function Mat4.billboard(px, py, y, yaw, pitch, mirror)
  local cy, sy = math.cos(yaw or 0), math.sin(yaw or 0)
  local cx, sx = math.cos(pitch or 0), math.sin(pitch or 0)
  local mx = mirror and -1 or 1

  return {
     cy * mx, sy * sx, sy * cx, px + 8 - 8 * cy * mx,
     0,       cx,      -sx,     y,
    -sy * mx, cy * sx, cy * cx, py + 8 + 8 * sy * mx,
     0,       0,       0,       1,
  }
end

-- T(wx,y,wz) * T(half,0,0) * Ry(yaw) * T(-half,0,0) * Rx(pitch)
-- When half is zero this is simply T * Ry * Rx.
function Mat4.figure(wx, y, wz, yaw, pitch, half)
  local cy, sy = math.cos(yaw or 0), math.sin(yaw or 0)
  local cx, sx = math.cos(pitch or 0), math.sin(pitch or 0)
  half = half or 0

  return {
     cy, sy * sx, sy * cx, wx + half * (1 - cy),
     0,  cx,      -sx,     y,
    -sy, cy * sx, cy * cx, wz + half * sy,
     0,  0,       0,       1,
  }
end

-- T(px+8,y,py+8) * Sx(mirror) * T(-8,0,0) * S(1,1,0)
function Mat4.caster(px, py, y, mirror)
  local mx = mirror and -1 or 1
  return {
    mx, 0, 0, px + 8 - 8 * mx,
    0,  1, 0, y,
    0,  0, 0, py + 8,
    0,  0, 0, 1,
  }
end

return Mat4
