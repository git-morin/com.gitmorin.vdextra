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

  ## quit is auto-imported from system in Nim 2 but lives in syncio under Nimony.
  import std/syncio

import std/[atomics, strutils]
import ../vdlog, ../mono

proc dobbyHook(target, replace: pointer, orig: ptr pointer): cint
  {.importc: "DobbyHook", header: "dobby.h", gcsafe.}

type
  Hook* = ref object
    owner*: string
    sym*: string
    argc*: int
    replacement*: pointer
    orig*: pointer
    installed*: bool

  Feature* = ref object of RootObj
    name*: string
    once*: bool
    blocking*: bool
    gates*: bool
    done*: bool

  VoidFn* = proc(self: pointer) {.cdecl, gcsafe.}

proc newHook*(owner, sym: string, argc: int, replacement: pointer): Hook =
  Hook(owner: owner, sym: sym, argc: argc, replacement: replacement)

proc origAs*[T](h: Hook): T =
  asProc[T](h.orig)

proc installAt*(h: Hook, target: pointer): bool {.discardable.} =
  if h.installed: return true
  if target == nil or h.replacement == nil: return false
  if dobbyHook(target, h.replacement, addr h.orig) != 0: return false
  h.installed = true
  true

proc install*(h: Hook, cls: MonoClass): bool {.discardable.} =
  h.installAt(methodAddr(cls, h.sym, h.argc))

proc shortName(qualified: string): string =
  let bare = qualified.split(',')[0]
  let dot = bare.rfind('.')
  if dot < 0: bare else: bare[dot + 1 .. ^1]

proc install*(h: Hook): bool {.discardable.} =
  let cls = getClass(h.owner)
  if cls == nil:
    logE(shortName(h.owner) & " class not found")
    return false
  h.install(cls)

method install*(f: Feature): bool {.base.} =
  when defined(nimony):
    quit "Feature.install is abstract"
  else:
    raise newException(Defect, "Feature.install is abstract")

var
  gSetup*: Atomic[bool]

template guard*(what: string, body: untyped) =
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

proc findInherited*(c: MonoClass, name: string): pointer =
  var cur = c
  for _ in 0 ..< 4:
    if cur == nil: break
    let a = methodAddr(cur, name, 0)
    if a != nil: return a
    cur = pClassGetParent(cur)
  nil
