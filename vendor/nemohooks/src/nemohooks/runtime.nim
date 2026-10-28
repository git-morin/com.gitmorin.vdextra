## Finds whichever registered backend is live in the target, attaches to it, and drives the
## registered features until every gating one has installed.
##
## A module declares its backends with `useBackend`, calls `registerFeatures` at load, and
## `startRuntimePoll` from its JNI init; the rest here is what those three set in motion.
include nemohooks/features

import std/[atomics, os]
import log, elfsyms, compat, backend, feature

var
  gImage: ElfSyms
  gAttached: Atomic[bool]
  gPollStarted: Atomic[bool]
  gPollThread: PollThread

proc targetSyms*(): ElfSyms =
  ## Non-ok before a backend has attached, and when the backend waits for no library.
  gImage

proc targetSym*(name: cstring): pointer {.cdecl.} =
  ## A `SymResolver` over that image.
  if not gImage.ok: default(pointer) else: gImage.sym(name)

proc anyImage(s: ElfSyms): bool {.gcsafe.} = s.ok

proc activate(b: Backend) =
  setActiveBackend(b)
  if b.attach != nil: b.attach(gImage)
  if b.triggers != nil: b.triggers(gImage)

proc waitsOnALibrary(): bool =
  for b in candidates():
    if b.soname.len > 0: return true
  false

proc tryAttach(b: Backend): bool =
  if b.soname.len == 0:
    # A backend with nothing to wait for is live from the start, and would win against one
    # whose runtime is still coming up.
    if waitsOnALibrary():
      logE(b.name & " waits for no library, so it attaches before any other backend can come " &
           "up - give it a soname or register it alone")
    var expected = false
    if not gAttached.compareExchange(expected, true): return true
    logI(b.name & " attached (no runtime library to wait for)")
    activate(b)
    return true
  let probe = if b.probe != nil: b.probe else: anyImage
  let s = findLiveImage(b.soname, probe)
  if not s.ok: return false
  var expected = false
  if not gAttached.compareExchange(expected, true): return true
  gImage = s
  logI(b.name & " attached: " & b.soname & " at base=" & hex(cast[pointer](s.bias)) &
       " (" & $residentInstances(b.soname).len & " resident instance(s), " &
       $s.count & " syms)")
  activate(b)
  true

proc attachRuntime*(): bool {.discardable.} =
  ## Resolves entry points and installs trigger hooks on the first success. False while no
  ## registered backend is up yet.
  if gAttached.load(): return true
  if candidates().len == 0:
    logE("no backend registered - call useBackend before startRuntimePoll")
    return false
  for b in candidates():
    if tryAttach(b): return true
  false

proc attachNow*(tries = 20, delayMs = 100): bool {.discardable.} =
  ## Attaches and runs setup on the calling thread, for an injection point late enough that the
  ## target's runtime is already up.
  for _ in 0 ..< tries:
    if attachRuntime():
      doSetup()
      return true
    sleep(delayMs)
  false

proc waitingFor(): string =
  result = ""
  for b in candidates():
    if b.soname.len == 0: continue
    if result.len > 0: result.add " or "
    result.add b.soname
  if result.len == 0: result = "the target runtime"

proc pollBody() =
  sleep(2000)
  var i = 0
  while not attachRuntime():
    if i > 0 and i mod 300 == 0:
      logI("still waiting for a live " & waitingFor() & " (" & $(i div 5 + 2) & "s elapsed)")
    sleep(200)
    inc i
  i = 0
  while not gSetup.load():
    doSetup()
    if gSetup.load(): break
    if i > 0 and i mod 25 == 0: logI("background doSetup retry #" & $i)
    sleep(500)
    inc i

proc pollLoop() =
  when defined(nimony):
    pollBody()
  else:
    {.cast(gcsafe).}:
      pollBody()

when defined(nimony):
  proc pollEntry(arg: pointer) {.nimcall.} = pollLoop()
else:
  proc pollEntry(arg: pointer) {.thread, nimcall.} = pollLoop()

proc startRuntimePoll*() =
  ## Starts the background poll, at most once per process, and returns at once. Call it from
  ## the JNI init: injection happens long before the target's runtime exists.
  var expected = false
  if not gPollStarted.compareExchange(expected, true): return
  startThread(gPollThread, pollEntry)
