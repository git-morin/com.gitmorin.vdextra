import std/atomics
import ../vdlog, ../mono
import hook, sound, text, fonts, forcelan, bitrate, fit, section
export hook, sound, text, fonts, forcelan, bitrate, fit, section

# Order is load-bearing: font-independent features first so a missing TextBlock cannot
# stop them, and text before the font-capture features, which need what it resolves.
let features: seq[Feature] = @[
  Feature(cueSoundsFeature), Feature(bitrateFeature), Feature(forceLanFeature), Feature(
      musicFeature),
  Feature(textFeature), Feature(fontSerializerFeature), Feature(contentLoadFeature),
  Feature(fitFeature), Feature(sectionFeature)
]

var gInSetup: Atomic[bool]

proc setupComplete(): bool =
  for f in features:
    if f.gates and not f.done: return false
  true

proc doSetupImpl() =
  if corlib() == nil: return
  for f in features:
    if f.done: continue
    let ok = f.install()
    if ok or f.once: f.done = true
    if not ok and f.blocking: return
  if setupComplete():
    gSetup.store(true)
    logI("setup done")

proc doSetup*() =
  if gSetup.load(): return
  var expected = false
  if not gInSetup.compareExchange(expected, true): return
  doSetupImpl()
  gInSetup.store(false)
