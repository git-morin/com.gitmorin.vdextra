## One function redirected through a trampoline. The address comes from the active backend, so
## the same type covers a managed method, a native symbol and an offset into a stripped library.
include nemohooks/features

import std/strutils
import log, compat, backend

proc dobbyHook(target, replace: pointer, orig: ptr pointer): cint
  {.importc: "DobbyHook", header: "dobby.h", gcsafe.}

proc dobbyDestroy(target: pointer): cint
  {.importc: "DobbyDestroy", header: "dobby.h", gcsafe.}

type
  Hook* = ref object
    ## `owner` and `sym` are the active backend's to interpret; an empty `owner` means the
    ## backend's own image, which is how a runtime entry point is hooked.
    owner*: string
    sym*: string
    argc*: int ## Parameter count, for a backend that looks methods up by arity.
    replacement*: pointer
    orig*: pointer ## Trampoline back to the original body, reached through `origAs`.
    target*: pointer ## The address redirected, kept so the hook can be removed.
    installed*: bool

  VoidFn* = proc (self: pointer) {.cdecl, gcsafe.}
    ## The shape most .ctor hooks need.

proc newHook*(owner, sym: string, argc: int, replacement: pointer): Hook =
  Hook(owner: owner, sym: sym, argc: argc, replacement: replacement)

proc origAs*[T](h: Hook): T =
  asProc[T](h.orig)

proc shortName*(qualified: string): string =
  ## The bare class name out of an assembly-qualified one.
  let bare = qualified.split(',')[0]
  let dot = bare.rfind('.')
  if dot < 0: bare else: bare[dot + 1 .. ^1]

proc describe*(h: Hook): string =
  if h.owner.len == 0: h.sym else: shortName(h.owner) & "." & h.sym

proc installAt*(h: Hook, target: pointer): bool {.discardable.} =
  ## Redirects a known address; every other install path narrows to this one.
  if h.installed: return true
  if target == nil or h.replacement == nil: return false
  if dobbyHook(target, h.replacement, addr h.orig) != 0: return false
  h.target = target
  h.installed = true
  true

proc install*(h: Hook): bool {.discardable.} =
  ## Resolves through the active backend, which is what lets a feature read the same whichever
  ## runtime it targets.
  let target = backendResolve(h.owner, h.sym, h.argc)
  if target == nil:
    logE(describe(h) & ": no address resolved (" & backendName() & ")")
    return false
  h.installAt(target)

proc remove*(h: Hook): bool {.discardable.} =
  ## Restores the original code, for a module that toggles a feature at runtime.
  if not h.installed: return true
  if h.target == nil: return false
  if dobbyDestroy(h.target) != 0: return false
  h.installed = false
  h.orig = nil
  true

template guard*(what: string, body: untyped) =
  ## Wraps the part of a replacement that may raise. An exception leaving a hook body unwinds
  ## through the runtime's own frames and takes the process down; keep the call to `orig` out.
  when defined(nimony):
    try:
      body
    except:
      logE("hook " & what & " raised")
  else:
    try:
      body
    except CatchableError as e:
      logE("hook " & what & " raised: " & e.msg)
    except Defect as e:
      logE("hook " & what & " defect: " & e.msg)
