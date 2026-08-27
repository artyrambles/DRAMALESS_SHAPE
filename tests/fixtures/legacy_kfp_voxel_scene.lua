local Ceiling = {}

-- Historical splice signature. The host must detect this text and refuse the
-- companion export without changing this source.
function Ceiling.draw()
  return "legacy"
end

return Ceiling
