## A group of hooks installed together, and the registry `runtime` drives them from. A feature
## says what to install; the active backend says when that is possible and where.
include nemohooks/features

when defined(nimony):
  import compat
  import std/syncio

import std/atomics
import log, backend

type
  Feature* = ref object of RootObj
    ## Subclass it, override `install`, and hand it to `registerFeatures`.
    name*: string
    once*: bool     ## Give up after the first attempt instead of retrying.
    blocking*: bool ## Stop the rest of the registry when this one fails.
    gates*: bool    ## Setup is complete only once this one is done.
    done*: bool

method install*(f: Feature): bool {.base.} =
  when defined(nimony):
    quit "Feature.install is abstract"
  else:
    raise newException(Defect, "Feature.install is abstract")

var
  gSetup*: Atomic[bool]
    ## Set once every gating feature has installed. Hot-path hooks read it to stop retrying.
  gFeatures: seq[Feature]
  gInSetup: Atomic[bool]

proc registerFeatures*(fs: seq[Feature]) =
  ## Registration order is installation order, which matters when one feature resolves names a
  ## later one reads.
  for f in fs: gFeatures.add f

proc registerFeature*(f: Feature) =
  gFeatures.add f

proc features*(): seq[Feature] = gFeatures

proc setupComplete(): bool =
  for f in gFeatures:
    if f.gates and not f.done: return false
  true

proc doSetupImpl() =
  if not backendReady(): return
  for f in gFeatures:
    if f.done: continue
    let ok = f.install()
    if ok or f.once: f.done = true
    if not ok and f.blocking: return
  if setupComplete():
    gSetup.store(true)
    logI("setup done")

proc doSetup*() =
  ## Installs every feature not yet done. Any number of hook bodies may call it at once; the
  ## first one in does the work.
  if gSetup.load(): return
  var expected = false
  if not gInSetup.compareExchange(expected, true): return
  doSetupImpl()
  gInSetup.store(false)
