## The Mono backend: Unity, Xenko, anything hosting `libmonosgen`.
##
## Above `resolveMono` is the runtime's C API, resolved out of the target's mapped image rather
## than linked against; below it is the surface a feature writes against.
include nemohooks/features

import std/atomics
import ../[compat, log, elfsyms, managed, backend, hook, feature]
export managed

type
  MonoImage* = pointer
  MonoClass* = pointer
  MonoMethod* = pointer
  MonoObject* = pointer
  MonoString* = pointer
  MonoType* = pointer
  MonoDomain* = pointer
  MonoField* = pointer
  MonoGCHandle* = uint32

  GetCorlibFn = proc(): MonoImage {.cdecl, gcsafe.}
  ClassFromNameFn = proc(img: MonoImage, ns, name: cstring): MonoClass {.cdecl, gcsafe.}
  ClassGetMethodFn = proc(c: MonoClass, name: cstring, np: cint): MonoMethod {.cdecl, gcsafe.}
  RuntimeInvokeFn = proc(m: MonoMethod, obj: pointer, params: ptr UncheckedArray[pointer],
                         exc: ptr MonoObject): MonoObject {.cdecl, gcsafe.}
  TypeGetClassFn = proc(t: MonoType): MonoClass {.cdecl, gcsafe.}
  CompileMethodFn = proc(m: MonoMethod): pointer {.cdecl, gcsafe.}
  ObjGetClassFn = proc(o: MonoObject): MonoClass {.cdecl, gcsafe.}
  ObjUnboxFn = proc(o: MonoObject): pointer {.cdecl, gcsafe.}
  ClassGetParentFn = proc(c: MonoClass): MonoClass {.cdecl, gcsafe.}
  ClassGetFieldFn = proc(c: MonoClass, name: cstring): MonoField {.cdecl, gcsafe.}
  FieldGetValueFn = proc(o: pointer, f: MonoField, outv: pointer) {.cdecl, gcsafe.}
  FieldSetValueFn = proc(o: pointer, f: MonoField, v: pointer) {.cdecl, gcsafe.}
  FieldStaticGetFn = proc(vt: pointer, f: MonoField, outv: pointer) {.cdecl, gcsafe.}
  ClassVtableFn = proc(d: MonoDomain, c: MonoClass): pointer {.cdecl, gcsafe.}
  RuntimeClassInitFn = proc(vt: pointer) {.cdecl, gcsafe.}
  StringNewUtf16Fn = proc(d: MonoDomain, text: ptr uint16,
                          len: int32): MonoString {.cdecl, gcsafe.}
  GchandleNewFn = proc(o: MonoObject, pinned: cint): MonoGCHandle {.cdecl, gcsafe.}
  GchandleGetFn = proc(h: MonoGCHandle): MonoObject {.cdecl, gcsafe.}
  GchandleFreeFn = proc(h: MonoGCHandle) {.cdecl, gcsafe.}
  ObjectNewFn = proc(d: MonoDomain, c: MonoClass): MonoObject {.cdecl, gcsafe.}
  ObjectInitFn = proc(o: MonoObject) {.cdecl, gcsafe.}
  IterFn = proc(c: MonoClass, iter: ptr pointer): pointer {.cdecl, gcsafe.}
  FieldGetTypeFn = proc(f: MonoField): MonoType {.cdecl, gcsafe.}
  FieldGetFlagsFn = proc(f: MonoField): uint32 {.cdecl, gcsafe.}
  TypeIsRefFn = proc(t: MonoType): bool {.cdecl, gcsafe.}
  FieldGetOffsetFn = proc(f: MonoField): cint {.cdecl, gcsafe.}

  GetDomainFn* = proc(): MonoDomain {.cdecl, gcsafe.}
  GetNameFn* = proc(p: pointer): cstring {.cdecl, gcsafe.}

var
  pGetCorlib*: GetCorlibFn
  pClassFromName*: ClassFromNameFn
  pClassGetMethod*: ClassGetMethodFn
  pRuntimeInvoke*: RuntimeInvokeFn
  pTypeGetClass*: TypeGetClassFn
  pCompileMethod*: CompileMethodFn
  pObjGetClass*: ObjGetClassFn
  pObjUnbox*: ObjUnboxFn
  pClassGetParent*: ClassGetParentFn
  pClassGetField*: ClassGetFieldFn
  pFieldGetValue*: FieldGetValueFn
  pFieldSetValue*: FieldSetValueFn
  pFieldStaticGet*: FieldStaticGetFn
  pClassVtable*: ClassVtableFn
  pRuntimeClassInit*: RuntimeClassInitFn
  pStringNewUtf16*: StringNewUtf16Fn
  pGchandleNew*: GchandleNewFn
  pGchandleGet*: GchandleGetFn
  pGchandleFree*: GchandleFreeFn
  pGetRootDomain*: GetDomainFn
  pDomainGet*: GetDomainFn
  pObjectNew*: ObjectNewFn
  pRuntimeObjectInit*: ObjectInitFn
  pClassGetName*: GetNameFn
  pClassGetNamespace*: GetNameFn
  pFieldGetName*: GetNameFn
  pMethodGetName*: GetNameFn
  pClassGetFields*: IterFn
  pClassGetMethods*: IterFn
  pFieldGetType*: FieldGetTypeFn
  pFieldGetFlags*: FieldGetFlagsFn
  pTypeIsReference*: TypeIsRefFn
  pFieldGetOffset*: FieldGetOffsetFn

var
  gCorlib*: MonoImage
  gDomain*: MonoDomain

proc resolveMono*(sym: SymResolver) =
  pGetCorlib = asProc[GetCorlibFn](sym("mono_get_corlib"))
  pClassFromName = asProc[ClassFromNameFn](sym("mono_class_from_name"))
  pClassGetMethod = asProc[ClassGetMethodFn](sym("mono_class_get_method_from_name"))
  pRuntimeInvoke = asProc[RuntimeInvokeFn](sym("mono_runtime_invoke"))
  pTypeGetClass = asProc[TypeGetClassFn](sym("mono_type_get_class"))
  pCompileMethod = asProc[CompileMethodFn](sym("mono_compile_method"))
  pObjGetClass = asProc[ObjGetClassFn](sym("mono_object_get_class"))
  pObjUnbox = asProc[ObjUnboxFn](sym("mono_object_unbox"))
  pClassGetParent = asProc[ClassGetParentFn](sym("mono_class_get_parent"))
  pClassGetField = asProc[ClassGetFieldFn](sym("mono_class_get_field_from_name"))
  pFieldGetValue = asProc[FieldGetValueFn](sym("mono_field_get_value"))
  pFieldSetValue = asProc[FieldSetValueFn](sym("mono_field_set_value"))
  pFieldStaticGet = asProc[FieldStaticGetFn](sym("mono_field_static_get_value"))
  pClassVtable = asProc[ClassVtableFn](sym("mono_class_vtable"))
  pRuntimeClassInit = asProc[RuntimeClassInitFn](sym("mono_runtime_class_init"))
  pStringNewUtf16 = asProc[StringNewUtf16Fn](sym("mono_string_new_utf16"))
  pGchandleNew = asProc[GchandleNewFn](sym("mono_gchandle_new"))
  pGchandleGet = asProc[GchandleGetFn](sym("mono_gchandle_get_target"))
  pGchandleFree = asProc[GchandleFreeFn](sym("mono_gchandle_free"))
  pGetRootDomain = asProc[GetDomainFn](sym("mono_get_root_domain"))
  pDomainGet = asProc[GetDomainFn](sym("mono_domain_get"))
  pObjectNew = asProc[ObjectNewFn](sym("mono_object_new"))
  pRuntimeObjectInit = asProc[ObjectInitFn](sym("mono_runtime_object_init"))
  pClassGetName = asProc[GetNameFn](sym("mono_class_get_name"))
  pClassGetNamespace = asProc[GetNameFn](sym("mono_class_get_namespace"))
  pFieldGetName = asProc[GetNameFn](sym("mono_field_get_name"))
  pMethodGetName = asProc[GetNameFn](sym("mono_method_get_name"))
  pClassGetFields = asProc[IterFn](sym("mono_class_get_fields"))
  pClassGetMethods = asProc[IterFn](sym("mono_class_get_methods"))
  pFieldGetType = asProc[FieldGetTypeFn](sym("mono_field_get_type"))
  pFieldGetFlags = asProc[FieldGetFlagsFn](sym("mono_field_get_flags"))
  pTypeIsReference = asProc[TypeIsRefFn](sym("mono_type_is_reference"))
  pFieldGetOffset = asProc[FieldGetOffsetFn](sym("mono_field_get_offset"))

proc corlib*(): MonoImage =
  if gCorlib == nil and pGetCorlib != nil: gCorlib = pGetCorlib()
  gCorlib

proc setDomain*(d: MonoDomain) =
  if gDomain == nil and d != nil: gDomain = d

proc domain*(): MonoDomain =
  if pDomainGet != nil:
    let d = pDomainGet()
    if d != nil: return d
  if gDomain != nil: return gDomain
  if pGetRootDomain != nil: return pGetRootDomain()
  nil

proc monoStrLen*(s: MonoString): int = strLen(s)

proc monoStrChars*(s: MonoString): ptr UncheckedArray[uint16] = strChars(s)

proc makeString*(u8: string): MonoString =
  ## Allocated in the target's heap: valid only while something managed references it.
  if pStringNewUtf16 == nil: return nil
  utf8ToUtf16(u8, utf16Scratch)
  if utf16Scratch.len == 0: return nil
  pStringNewUtf16(domain(), addr utf16Scratch[0], int32(utf16Scratch.len))

proc makeMono*(u8: string): MonoString = makeString(u8)

proc getClass*(qname: string): MonoClass =
  ## Resolved through System.Type.GetType, which searches every loaded assembly.
  if pClassFromName == nil or pClassGetMethod == nil or pRuntimeInvoke == nil or
     pTypeGetClass == nil or corlib() == nil:
    return nil
  let ct = pClassFromName(gCorlib, "System", "Type")
  if ct == nil: return nil
  let mGT = pClassGetMethod(ct, "GetType", 1)
  if mGT == nil: return nil
  let nm = makeMono(qname)
  if nm == nil: return nil
  var args {.noinit.}: array[1, pointer]
  args[0] = nm
  var exc: MonoObject = nil
  let t = pRuntimeInvoke(mGT, nil, cast[ptr UncheckedArray[pointer]](addr args[0]), addr exc)
  if t == nil or exc != nil: return nil
  # MonoReflectionType keeps its MonoType* in the first field after the object header.
  let typePtr = readPtrAt(t, objectHeaderSize)
  if typePtr == nil: return nil
  pTypeGetClass(typePtr)

proc methodAddr*(c: MonoClass, name: string, np: int): pointer =
  if c == nil or pClassGetMethod == nil or pCompileMethod == nil: return nil
  var n = name
  let m = pClassGetMethod(c, n.toCString, cint(np))
  if m == nil: return nil
  pCompileMethod(m)

proc methodAddrInherited*(c: MonoClass, name: string, np: int, depth = 6): pointer =
  ## Like methodAddr, but walks base classes - the name lookup itself does not.
  var cur = c
  for _ in 0 ..< depth:
    if cur == nil: break
    let a = methodAddr(cur, name, np)
    if a != nil: return a
    cur = pClassGetParent(cur)
  nil

proc fieldGetF32*(o: pointer, f: MonoField): float32 =
  if o == nil or f == nil or pFieldGetValue == nil: return 0'f32
  var v {.noinit.}: float32
  pFieldGetValue(o, f, addr v)
  v

proc fieldGetPtr*(o: pointer, f: MonoField): pointer =
  if o == nil or f == nil or pFieldGetValue == nil: return nil
  var v {.noinit.}: pointer
  pFieldGetValue(o, f, addr v)
  v

proc fieldSetF32*(o: pointer, f: MonoField, v: float32) =
  if o == nil or f == nil or pFieldSetValue == nil: return
  var tmp = v
  pFieldSetValue(o, f, addr tmp)

proc fieldSetBool*(o: pointer, f: MonoField, v: bool) =
  if o == nil or f == nil or pFieldSetValue == nil: return
  var tmp = v
  pFieldSetValue(o, f, addr tmp)

proc pin*(o: MonoObject): MonoGCHandle =
  if o == nil or pGchandleNew == nil: 0'u32 else: pGchandleNew(o, 1)

proc moved*(h: MonoGCHandle): MonoObject =
  ## The pinned object at its current address; a moving collector may have relocated it.
  if h == 0'u32 or pGchandleGet == nil: default(MonoObject) else: pGchandleGet(h)

proc unpin*(h: MonoGCHandle) =
  if h != 0'u32 and pGchandleFree != nil: pGchandleFree(h)

proc nameOf*(p: pointer, get: GetNameFn): string =
  if p == nil or get == nil: return "?"
  let c = get(p)
  if c == nil: "?" else: fromCString(c)

proc className*(c: MonoClass): string =
  if c == nil: return "nil"
  let ns = nameOf(c, pClassGetNamespace)
  let n = nameOf(c, pClassGetName)
  if ns.len == 0 or ns == "?": n else: ns & "." & n

proc objClassName*(o: MonoObject): string =
  if o == nil or pObjGetClass == nil: "nil" else: className(pObjGetClass(o))

proc fieldNames*(c: MonoClass, cap = 128): seq[string] =
  if c == nil or pClassGetFields == nil or pFieldGetName == nil: return @[]
  result = @[]
  var iter: pointer = nil
  while result.len < cap:
    let f = pClassGetFields(c, addr iter)
    if f == nil: break
    result.add nameOf(f, pFieldGetName)

proc methodNames*(c: MonoClass, cap = 256): seq[string] =
  if c == nil or pClassGetMethods == nil or pMethodGetName == nil: return @[]
  result = @[]
  var iter: pointer = nil
  while result.len < cap:
    let m = pClassGetMethods(c, addr iter)
    if m == nil: break
    result.add nameOf(m, pMethodGetName)

## Filter an instance walk on this: fieldGetPtr on a value field reads the value as an address.
proc fieldIsInstanceRef*(f: MonoField): bool =
  if f == nil or pFieldGetType == nil or pTypeIsReference == nil: return false
  if pFieldGetFlags != nil and (pFieldGetFlags(f) and FIELD_STATIC) != 0'u32: return false
  let t = pFieldGetType(f)
  if t == nil: return false
  pTypeIsReference(t)

proc fieldDeclaredClass*(f: MonoField): MonoClass =
  if f == nil or pFieldGetType == nil or pTypeGetClass == nil: return nil
  let t = pFieldGetType(f)
  if t == nil: default(MonoClass) else: pTypeGetClass(t)

proc fieldOffset*(c: MonoClass, name: string): int =
  ## Byte offset of an instance field, or -1. By name, so a moved layout reads as absent.
  if c == nil or pClassGetField == nil or pFieldGetOffset == nil: return -1
  var n = name
  let f = pClassGetField(c, n.toCString)
  if f == nil: -1 else: int(pFieldGetOffset(f))

proc staticObject*(c: MonoClass, name: string): MonoObject =
  ## Reads a reference-typed static field, initialising the class so the slot is populated.
  if c == nil or pClassVtable == nil or pRuntimeClassInit == nil or
     pFieldStaticGet == nil or pClassGetField == nil: return nil
  var n = name
  let f = pClassGetField(c, n.toCString)
  if f == nil: return nil
  let vt = pClassVtable(domain(), c)
  if vt == nil: return nil
  pRuntimeClassInit(vt)
  var v: pointer = nil
  pFieldStaticGet(vt, f, addr v)
  v

proc classOf*(o: MonoObject): MonoClass =
  if o == nil or pObjGetClass == nil: default(MonoClass) else: pObjGetClass(o)

proc isSubclassOf*(o: MonoObject, base: MonoClass, depth = 8): bool =
  ## Walks the object's class chain looking for `base`.
  if o == nil or base == nil or pObjGetClass == nil or pClassGetParent == nil: return false
  var cur = pObjGetClass(o)
  for _ in 0 ..< depth:
    if cur == nil: break
    if cur == base: return true
    cur = pClassGetParent(cur)
  false

proc newInstance*(c: MonoClass): MonoObject =
  ## Allocates and runs the default constructor; nil when either entry point is missing.
  if c == nil or pObjectNew == nil: return nil
  let o = pObjectNew(domain(), c)
  if o != nil and pRuntimeObjectInit != nil: pRuntimeObjectInit(o)
  o

proc invoke*(m: MonoMethod, obj: pointer, args: ptr UncheckedArray[pointer]): MonoObject =
  ## Answers nil when the method throws; a managed exception must not reach a hook body.
  if m == nil or pRuntimeInvoke == nil: return nil
  var exc: MonoObject = nil
  let r = pRuntimeInvoke(m, obj, args, addr exc)
  if exc != nil: default(MonoObject) else: r

proc unboxInt32*(o: MonoObject): int =
  ## The boxed int behind a property getter's return value, or -1 when it cannot be read.
  if o == nil or pObjUnbox == nil: return -1
  let p = cast[ptr int32](pObjUnbox(o))
  if p == nil: -1 else: int(p[])

proc unboxBool*(o: MonoObject): int =
  ## Tri-state: 1, 0, or -1 when the value cannot be read.
  if o == nil or pObjUnbox == nil: return -1
  let p = cast[ptr uint8](pObjUnbox(o))
  if p == nil: -1 elif p[] != 0: 1 else: 0

# What `runtime` needs to find this runtime, attach to it, and resolve hooks.

const monoSoname* = "libmonosgen-2.0.so"
  ## `monoBackend` takes an override for a target that embeds Mono under another name.

type GetPtrFn = proc (): pointer {.cdecl, gcsafe.}

var gImage: ElfSyms

proc monoSym*(name: cstring): pointer {.cdecl.} =
  ## A `SymResolver` over the attached image.
  if not gImage.ok: default(pointer) else: gImage.sym(name)

proc monoSyms*(): ElfSyms = gImage

proc install*(h: Hook, cls: MonoClass): bool {.discardable.} =
  ## For a feature hooking several methods of one class: `getClass` is a managed call each time.
  h.installAt(methodAddr(cls, h.sym, h.argc))

proc findInherited*(c: MonoClass, name: string, depth = 4): pointer =
  ## The address of a parameterless method, walking up from `c`.
  methodAddrInherited(c, name, 0, depth)

proc monoResolve(owner, sym: string, argc: int): pointer =
  ## `owner` is an assembly-qualified class name, or empty for a Mono entry point.
  if owner.len == 0:
    var n = sym
    return monoSym(n.toCString)
  let cls = getClass(owner)
  if cls == nil:
    logE(shortName(owner) & " class not found")
    return nil
  methodAddr(cls, sym, argc)

proc monoReady(): bool =
  ## corlib only answers once mono_init has built a domain.
  corlib() != nil

proc callPtrFn(s: ElfSyms, name: cstring): pointer =
  let fn = asProc[GetPtrFn](s.sym(name))
  if fn == nil: default(pointer) else: fn()

proc monoIsUp(s: ElfSyms): bool {.gcsafe.} =
  ## Either accessor answering non-nil means mono_init has run in this image.
  callPtrFn(s, "mono_get_corlib") != nil or callPtrFn(s, "mono_get_root_domain") != nil

proc monoAttach(s: ElfSyms) =
  gImage = s
  resolveMono(monoSym)
  logI("mono: corlib=" & hex(callPtrFn(s, "mono_get_corlib")) &
       " root_domain=" & hex(callPtrFn(s, "mono_get_root_domain")))

## The trigger hooks, whose only job is to call `doSetup` from a thread the runtime owns.
## ldstr and object_new are the hot pair that keeps retrying; the rest cover startup.
type
  LdstrFn = proc (a0, a1, a2, a3: pointer): MonoString {.cdecl, gcsafe.}
  ObjNewFn = proc (d: MonoDomain, k: MonoClass): MonoObject {.cdecl, gcsafe.}
  JitInitFn = proc (name: cstring): MonoDomain {.cdecl, gcsafe.}
  JitExecFn = proc (d: MonoDomain, asmv: pointer, argc: cint,
                    argv: pointer): cint {.cdecl, gcsafe.}
  RunMainFn = proc (asmv: pointer, argc: cint, argv: pointer): cint {.cdecl, gcsafe.}

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

proc installTrigger(h: Hook) =
  ## Through `monoSym`, so a trigger does not depend on this being the active backend.
  var n = h.sym
  if not h.installAt(monoSym(n.toCString)):
    logE(h.sym & " hook failed")

proc monoTriggers(s: ElfSyms) =
  installTrigger(hLdstr)
  installTrigger(hObjNew)
  installTrigger(hJitInit)
  installTrigger(hJitExec)
  installTrigger(hRunMain)
  logI("mono hooked")

proc monoBackend*(soname = monoSoname): Backend =
  ## Hand this to `useBackend` to target a Mono runtime.
  Backend(name: "mono", soname: soname, probe: monoIsUp, attach: monoAttach,
          triggers: monoTriggers, ready: monoReady, resolve: monoResolve)
