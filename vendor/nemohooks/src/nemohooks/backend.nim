## What a runtime has to answer for the rest of the library to hook it, and the registry of the
## backends a module declares. `runtime` drives whichever registered backend is live in the
## target, so `Hook`, `Feature` and the poll are written once.
include nemohooks/features

import elfsyms

type
  AttachFn* = proc (s: ElfSyms) {.nimcall.} ## Handed the image the backend was found in.
  ReadyFn* = proc (): bool {.nimcall.}
  ResolveFn* = proc (owner, sym: string, argc: int): pointer {.nimcall.}

  Backend* = ref object
    ## Only `probe` and `resolve` are load-bearing; the rest may be nil.
    name*: string       ## Labels log lines.
    soname*: string     ## Library to find in `/proc/self/maps`; empty means nothing to wait for.
    probe*: ReadyProbe  ## Is this mapped copy the initialised one? Nil accepts any image.
    attach*: AttachFn   ## Resolves the runtime's entry points out of the image, once.
    triggers*: AttachFn ## Hooks entry points that call `doSetup` from a runtime-owned thread.
    ready*: ReadyFn     ## May names be resolved yet? Nil means always.
    resolve*: ResolveFn ## Turns `owner`/`sym`/`argc` into the address to redirect.

var
  gBackends: seq[Backend]
  gActive: Backend

proc useBackend*(b: Backend) =
  ## Register several and whichever is live wins, the first registered breaking a tie. One with
  ## no soname is live immediately, so never register it alongside one that has to wait.
  gBackends.add b

proc useBackends*(bs: seq[Backend]) =
  for b in bs: gBackends.add b

proc candidates*(): seq[Backend] = gBackends

proc activeBackend*(): Backend =
  ## Nil until `runtime` has attached.
  gActive

proc setActiveBackend*(b: Backend) = gActive = b

proc backendName*(): string =
  if gActive == nil: "none" else: gActive.name

proc backendReady*(): bool =
  ## False before a backend is attached.
  if gActive == nil: false
  elif gActive.ready == nil: true
  else: gActive.ready()

proc backendResolve*(owner, sym: string, argc: int): pointer =
  if gActive == nil or gActive.resolve == nil: default(pointer)
  else: gActive.resolve(owner, sym, argc)
