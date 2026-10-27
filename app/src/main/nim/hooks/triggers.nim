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

import std/atomics
import ../vdlog, ../mono, ../compat
import hook, setup

type
  LdstrFn = proc(a0, a1, a2, a3: pointer): MonoString {.cdecl, gcsafe.}
  ObjNewFn = proc(d: MonoDomain, k: MonoClass): MonoObject {.cdecl, gcsafe.}
  JitInitFn = proc(name: cstring): MonoDomain {.cdecl, gcsafe.}
  JitExecFn = proc(d: MonoDomain, asmv: pointer, argc: cint,
                   argv: pointer): cint {.cdecl, gcsafe.}
  RunMainFn = proc(asmv: pointer, argc: cint, argv: pointer): cint {.cdecl, gcsafe.}

var
  hLdstr = newHook("", "mono_ldstr_checked", 0, nil)
  hObjNew = newHook("", "mono_object_new", 0, nil)
  hJitInit = newHook("", "mono_jit_init", 0, nil)
  hJitExec = newHook("", "mono_jit_exec", 0, nil)
  hRunMain = newHook("", "mono_runtime_run_main", 0, nil)

var
  ldstrCalls = 0
  objNewCalls = 0

proc hookLdstr(a0, a1, a2, a3: pointer): MonoString {.cdecl.} =
  guard "ldstr":
    if a0 != nil: setDomain(a0)
    inc ldstrCalls
    if ldstrCalls <= 5 or ldstrCalls mod 500 == 0: logI("ldstr call #" & $ldstrCalls)
    if not gSetup.load() and ldstrCalls mod 20 == 2: doSetup()
  let orig = origAs[LdstrFn](hLdstr)
  if orig != nil: orig(a0, a1, a2, a3) else: nil

proc hookObjNew(d: MonoDomain, k: MonoClass): MonoObject {.cdecl.} =
  guard "object_new":
    if d != nil: setDomain(d)
    inc objNewCalls
    if objNewCalls <= 5 or objNewCalls mod 2000 == 0:
      logI("object_new call #" & $objNewCalls)
    if not gSetup.load() and objNewCalls mod 50 == 7: doSetup()
  let orig = origAs[ObjNewFn](hObjNew)
  if orig != nil: orig(d, k) else: nil

proc hookJitInit(name: cstring): MonoDomain {.cdecl.} =
  logI("jit_init('" & (if name == nil: "?" else: fromCString(name)) & "') called")
  let orig = origAs[JitInitFn](hJitInit)
  result = if orig != nil: orig(name) else: nil
  if result != nil: setDomain(result)
  if not gSetup.load(): doSetup()

proc hookJitExec(d: MonoDomain, asmv: pointer, argc: cint, argv: pointer): cint {.cdecl.} =
  logI("jit_exec called")
  if d != nil: setDomain(d)
  if not gSetup.load(): doSetup()
  let orig = origAs[JitExecFn](hJitExec)
  if orig != nil: orig(d, asmv, argc, argv) else: -1

proc hookRunMain(asmv: pointer, argc: cint, argv: pointer): cint {.cdecl.} =
  logI("run_main called")
  if pGetRootDomain != nil: setDomain(pGetRootDomain())
  if not gSetup.load(): doSetup()
  let orig = origAs[RunMainFn](hRunMain)
  if orig != nil: orig(asmv, argc, argv) else: -1

hLdstr.replacement = asPointer(hookLdstr)
hObjNew.replacement = asPointer(hookObjNew)
hJitInit.replacement = asPointer(hookJitInit)
hJitExec.replacement = asPointer(hookJitExec)
hRunMain.replacement = asPointer(hookRunMain)

## Each hook is installed on its own line rather than looped over an array literal: gathering
## these ref fields into one crashes nimony 0.6.3 (finalir.nim: `n.stmtKind in {StmtsS, ScopeS}`).
proc installOne(h: Hook, sym: proc(name: cstring): pointer {.cdecl, gcsafe.}) =
  var name = h.sym
  h.installAt(sym(name.toCString))

proc installTriggerHooks*(sym: proc(name: cstring): pointer {.cdecl, gcsafe.}) =
  var ldstrSym = hLdstr.sym
  let ldstr = sym(ldstrSym.toCString)
  if ldstr == nil:
    logE("mono_ldstr_checked not found")
    return
  if not hLdstr.installAt(ldstr):
    logE("ldstr hook failed")
  installOne(hJitExec, sym)
  installOne(hJitInit, sym)
  installOne(hRunMain, sym)
  var objNewSym = hObjNew.sym
  if not hObjNew.installAt(sym(objNewSym.toCString)):
    logE("object_new hook failed")
  logI("mono hooked")
