## Our code is almost entirely raw interop - Mono object pointers, Dobby trampolines,
## ELF symbol tables - where nil is a normal value rather than an error. Nimony makes
## every ptr not-nil by default, so this opts the module back into Nim 2 rules; the
## stdlib modules that were ported from Nim do the same.
##
## assumeSync goes with it: the resolved entry points are globals written once while the
## module is loading and only read afterwards, which Nimony's thread-safety analysis cannot
## see. Its own ioring backends opt out the same way.
when defined(nimony):
  {.feature: "lenientnils".}
  {.feature: "assumeSync".}

  ## Nimony has no Atomic[T] of its own; ours lives in compat.
  import ../compat

import std/atomics
import ../vdlog, ../mono
import hook, loadcontent, panelupdate, sound, text, fonts, forcelan, bitrate, fit, section
export hook, loadcontent, panelupdate, sound, text, fonts, forcelan, bitrate, fit, section

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
