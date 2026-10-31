local math3d = TR.math
Mat, Vec = math3d.Mat, math3d.Vec
Lerp, Clamp, AngleDelta = math3d.lerp, math3d.clamp, math3d.angleDelta
Rope = TR.rope

-- Loaded now, not on first use, so its events are there before anyone plays.
Mirror = TR.mirror
Mirror.configure({
    range = Config.mirror.range,
    soundRange = Config.mirror.soundRange,
    rate = Config.mirror.rate,
    volume = Config.volume,
})

if not IsDuplicityVersion() then Scene = TR.scene end
