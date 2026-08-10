-- The original overworld poison step briefly pulses a translucent black
-- rectangle over the whole 160x144 frame.  That reads as a disruptive
-- full-screen blink once the world is rendered as a bright 3D scene.
--
-- Keep ApplyOutOfBattlePoisonDamage itself intact: it owns the four-step
-- counter, HP loss, sound, faint messages, Pikachu happiness and blackout.
-- The visual is conveniently represented by one field assigned at the end
-- of that routine, so clearing only that field after the original returns
-- removes the pulse without changing any poison gameplay.

local PoisonFlash = {}

function PoisonFlash.suppress(state)
  state.poisonFlash = nil
end

function PoisonFlash.install()
  local OverworldState = require("src.world.OverworldController")
  if OverworldState.dramaticShapePoisonFlashHook then return end

  local inner = OverworldState.applyFieldPoison
  function OverworldState:applyFieldPoison(...)
    local stop = inner(self, ...)
    PoisonFlash.suppress(self)
    return stop
  end

  OverworldState.dramaticShapePoisonFlashHook = true
end

return PoisonFlash
