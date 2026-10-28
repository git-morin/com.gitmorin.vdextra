## The IL2CPP backend: Unity games built with IL2CPP rather than Mono.
##
## The surface matches `backends/mono` so a feature ports by changing which backend it imports.
## IL2CPP is compiled ahead of time and has no Type.GetType, so a method's entry point is read
## out of its MethodInfo and a class is found by walking the domain's assemblies - which is why
## a hook's `owner` names the assembly: `"MyGame.Player, Assembly-CSharp"`.
include nemohooks/features

import std/[atomics, strutils]
import ../[compat, log, elfsyms, managed, backend, hook, feature]
export managed

type
  Il2CppImage* = pointer
  Il2CppAssembly* = pointer
  Il2CppClass* = pointer
  Il2CppMethod* = pointer
  Il2CppObject* = pointer
  Il2CppString* = pointer
  Il2CppType* = pointer
  Il2CppDomain* = pointer
  Il2CppField* = pointer
  Il2CppThread* = pointer
  Il2CppGCHandle* = uint32

  GetDomainFn* = proc (): Il2CppDomain {.cdecl, gcsafe.}
  GetNameFn* = proc (p: pointer): cstring {.cdecl, gcsafe.}

  DomainAssembliesFn = proc (d: Il2CppDomain,
                             count: ptr csize_t): ptr UncheckedArray[Il2CppAssembly]
                            {.cdecl, gcsafe.}
  AssemblyImageFn = proc (a: Il2CppAssembly): Il2CppImage {.cdecl, gcsafe.}
  ClassFromNameFn = proc (img: Il2CppImage, ns, name: cstring): Il2CppClass {.cdecl, gcsafe.}
  ClassGetMethodFn = proc (c: Il2CppClass, name: cstring,
                           np: cint): Il2CppMethod {.cdecl, gcsafe.}
  ClassGetParentFn = proc (c: Il2CppClass): Il2CppClass {.cdecl, gcsafe.}
  ClassGetFieldFn = proc (c: Il2CppClass, name: cstring): Il2CppField {.cdecl, gcsafe.}
  ClassFromTypeFn = proc (t: Il2CppType): Il2CppClass {.cdecl, gcsafe.}
  ClassIsValueTypeFn = proc (c: Il2CppClass): bool {.cdecl, gcsafe.}
  RuntimeClassInitFn = proc (c: Il2CppClass) {.cdecl, gcsafe.}
  RuntimeInvokeFn = proc (m: Il2CppMethod, obj: pointer, params: ptr UncheckedArray[pointer],
                          exc: ptr Il2CppObject): Il2CppObject {.cdecl, gcsafe.}
  ObjGetClassFn = proc (o: Il2CppObject): Il2CppClass {.cdecl, gcsafe.}
  ObjUnboxFn = proc (o: Il2CppObject): pointer {.cdecl, gcsafe.}
  ObjectNewFn = proc (c: Il2CppClass): Il2CppObject {.cdecl, gcsafe.}
  ObjectInitFn = proc (o: Il2CppObject) {.cdecl, gcsafe.}
  FieldGetValueFn = proc (o: pointer, f: Il2CppField, outv: pointer) {.cdecl, gcsafe.}
  FieldSetValueFn = proc (o: pointer, f: Il2CppField, v: pointer) {.cdecl, gcsafe.}
  FieldStaticGetFn = proc (f: Il2CppField, outv: pointer) {.cdecl, gcsafe.}
  FieldStaticSetFn = proc (f: Il2CppField, v: pointer) {.cdecl, gcsafe.}
  FieldGetTypeFn = proc (f: Il2CppField): Il2CppType {.cdecl, gcsafe.}
  FieldGetFlagsFn = proc (f: Il2CppField): uint32 {.cdecl, gcsafe.}
  FieldGetOffsetFn = proc (f: Il2CppField): csize_t {.cdecl, gcsafe.}
  StringNewUtf16Fn = proc (text: ptr uint16, len: int32): Il2CppString {.cdecl, gcsafe.}
  GchandleNewFn = proc (o: Il2CppObject, pinned: bool): Il2CppGCHandle {.cdecl, gcsafe.}
  GchandleGetFn = proc (h: Il2CppGCHandle): Il2CppObject {.cdecl, gcsafe.}
  GchandleFreeFn = proc (h: Il2CppGCHandle) {.cdecl, gcsafe.}
  ThreadAttachFn = proc (d: Il2CppDomain): Il2CppThread {.cdecl, gcsafe.}
  ThreadDetachFn = proc (t: Il2CppThread) {.cdecl, gcsafe.}
  IterFn = proc (c: Il2CppClass, iter: ptr pointer): pointer {.cdecl, gcsafe.}

var
  pDomainGet*: GetDomainFn
  pDomainGetAssemblies*: DomainAssembliesFn
  pAssemblyGetImage*: AssemblyImageFn
  pImageGetName*: GetNameFn
  pClassFromName*: ClassFromNameFn
  pClassGetMethod*: ClassGetMethodFn
  pClassGetParent*: ClassGetParentFn
  pClassGetField*: ClassGetFieldFn
  pClassFromType*: ClassFromTypeFn
  pClassIsValueType*: ClassIsValueTypeFn
  pRuntimeClassInit*: RuntimeClassInitFn
  pRuntimeInvoke*: RuntimeInvokeFn
  pObjGetClass*: ObjGetClassFn
  pObjUnbox*: ObjUnboxFn
  pObjectNew*: ObjectNewFn
  pRuntimeObjectInit*: ObjectInitFn
  pFieldGetValue*: FieldGetValueFn
  pFieldSetValue*: FieldSetValueFn
  pFieldStaticGet*: FieldStaticGetFn
  pFieldStaticSet*: FieldStaticSetFn
  pFieldGetType*: FieldGetTypeFn
  pFieldGetFlags*: FieldGetFlagsFn
  pFieldGetOffset*: FieldGetOffsetFn
  pStringNewUtf16*: StringNewUtf16Fn
  pGchandleNew*: GchandleNewFn
  pGchandleGet*: GchandleGetFn
  pGchandleFree*: GchandleFreeFn
  pThreadAttach*: ThreadAttachFn
  pThreadDetach*: ThreadDetachFn
  pClassGetName*: GetNameFn
  pClassGetNamespace*: GetNameFn
  pFieldGetName*: GetNameFn
  pMethodGetName*: GetNameFn
  pClassGetFields*: IterFn
  pClassGetMethods*: IterFn

proc resolveIl2cpp*(sym: SymResolver) =
  pDomainGet = asProc[GetDomainFn](sym("il2cpp_domain_get"))
  pDomainGetAssemblies = asProc[DomainAssembliesFn](sym("il2cpp_domain_get_assemblies"))
  pAssemblyGetImage = asProc[AssemblyImageFn](sym("il2cpp_assembly_get_image"))
  pImageGetName = asProc[GetNameFn](sym("il2cpp_image_get_name"))
  pClassFromName = asProc[ClassFromNameFn](sym("il2cpp_class_from_name"))
  pClassGetMethod = asProc[ClassGetMethodFn](sym("il2cpp_class_get_method_from_name"))
  pClassGetParent = asProc[ClassGetParentFn](sym("il2cpp_class_get_parent"))
  pClassGetField = asProc[ClassGetFieldFn](sym("il2cpp_class_get_field_from_name"))
  pClassFromType = asProc[ClassFromTypeFn](sym("il2cpp_class_from_il2cpp_type"))
  pClassIsValueType = asProc[ClassIsValueTypeFn](sym("il2cpp_class_is_valuetype"))
  pRuntimeClassInit = asProc[RuntimeClassInitFn](sym("il2cpp_runtime_class_init"))
  pRuntimeInvoke = asProc[RuntimeInvokeFn](sym("il2cpp_runtime_invoke"))
  pObjGetClass = asProc[ObjGetClassFn](sym("il2cpp_object_get_class"))
  pObjUnbox = asProc[ObjUnboxFn](sym("il2cpp_object_unbox"))
  pObjectNew = asProc[ObjectNewFn](sym("il2cpp_object_new"))
  pRuntimeObjectInit = asProc[ObjectInitFn](sym("il2cpp_runtime_object_init"))
  pFieldGetValue = asProc[FieldGetValueFn](sym("il2cpp_field_get_value"))
  pFieldSetValue = asProc[FieldSetValueFn](sym("il2cpp_field_set_value"))
  pFieldStaticGet = asProc[FieldStaticGetFn](sym("il2cpp_field_static_get_value"))
  pFieldStaticSet = asProc[FieldStaticSetFn](sym("il2cpp_field_static_set_value"))
  pFieldGetType = asProc[FieldGetTypeFn](sym("il2cpp_field_get_type"))
  pFieldGetFlags = asProc[FieldGetFlagsFn](sym("il2cpp_field_get_flags"))
  pFieldGetOffset = asProc[FieldGetOffsetFn](sym("il2cpp_field_get_offset"))
  pStringNewUtf16 = asProc[StringNewUtf16Fn](sym("il2cpp_string_new_utf16"))
  pGchandleNew = asProc[GchandleNewFn](sym("il2cpp_gchandle_new"))
  pGchandleGet = asProc[GchandleGetFn](sym("il2cpp_gchandle_get_target"))
  pGchandleFree = asProc[GchandleFreeFn](sym("il2cpp_gchandle_free"))
  pThreadAttach = asProc[ThreadAttachFn](sym("il2cpp_thread_attach"))
  pThreadDetach = asProc[ThreadDetachFn](sym("il2cpp_thread_detach"))
  pClassGetName = asProc[GetNameFn](sym("il2cpp_class_get_name"))
  pClassGetNamespace = asProc[GetNameFn](sym("il2cpp_class_get_namespace"))
  pFieldGetName = asProc[GetNameFn](sym("il2cpp_field_get_name"))
  pMethodGetName = asProc[GetNameFn](sym("il2cpp_method_get_name"))
  pClassGetFields = asProc[IterFn](sym("il2cpp_class_get_fields"))
  pClassGetMethods = asProc[IterFn](sym("il2cpp_class_get_methods"))

proc domain*(): Il2CppDomain =
  if pDomainGet == nil: default(Il2CppDomain) else: pDomainGet()

proc attachThread*(): Il2CppThread =
  ## Needed before touching managed state from a thread the runtime did not create, which a
  ## hook body never is and the poll thread always is.
  if pThreadAttach == nil: default(Il2CppThread) else: pThreadAttach(domain())

proc detachThread*(t: Il2CppThread) =
  if t != nil and pThreadDetach != nil: pThreadDetach(t)

proc makeString*(u8: string): Il2CppString =
  ## Allocated in the target's heap: valid only while something managed references it.
  if pStringNewUtf16 == nil: return nil
  utf8ToUtf16(u8, utf16Scratch)
  if utf16Scratch.len == 0: return nil
  pStringNewUtf16(addr utf16Scratch[0], int32(utf16Scratch.len))

proc imageName*(img: Il2CppImage): string =
  if img == nil or pImageGetName == nil: return ""
  let c = pImageGetName(img)
  if c == nil: "" else: fromCString(c)

proc classIn*(img: Il2CppImage, ns, name: string): Il2CppClass =
  ## A nested type is spelled the way the runtime stores it, `Outer/Inner`.
  if img == nil or pClassFromName == nil: return nil
  var n = ns
  var c = name
  pClassFromName(img, n.toCString, c.toCString)

proc searchImages(want, ns, name: string): Il2CppClass =
  ## An empty `want` tries every image. An image name matches with or without its `.dll`.
  if pDomainGetAssemblies == nil or pAssemblyGetImage == nil: return nil
  let d = domain()
  if d == nil: return nil
  var n: csize_t = 0
  let asms = pDomainGetAssemblies(d, addr n)
  if asms == nil: return nil
  for i in 0 ..< int(n):
    let img = pAssemblyGetImage(asms[i])
    if img == nil: continue
    if want.len > 0:
      let have = imageName(img)
      if have != want and have != want & ".dll": continue
    let c = classIn(img, ns, name)
    if c != nil: return c
  nil

proc getClass*(qname: string): Il2CppClass =
  ## Resolves `"Namespace.Class, Assembly"`. Without the assembly, every image is searched.
  let comma = qname.find(',')
  var typeName = qname
  var asmName = ""
  if comma >= 0:
    typeName = qname[0 ..< comma].strip()
    asmName = qname[comma + 1 .. ^1].strip()
  let dot = typeName.rfind('.')
  var ns = ""
  var name = typeName
  if dot >= 0:
    ns = typeName[0 ..< dot]
    name = typeName[dot + 1 .. ^1]
  searchImages(asmName, ns, name)

proc methodHandle*(c: Il2CppClass, name: string, np: int): Il2CppMethod =
  if c == nil or pClassGetMethod == nil: return nil
  var n = name
  pClassGetMethod(c, n.toCString, cint(np))

proc methodAddr*(c: Il2CppClass, name: string, np: int): pointer =
  ## The compiled entry point, read from MethodInfo: `methodPointer` is its first field in
  ## every published IL2CPP layout.
  let m = methodHandle(c, name, np)
  if m == nil: return nil
  readPtrAt(m, 0)

proc methodAddrInherited*(c: Il2CppClass, name: string, np: int, depth = 6): pointer =
  ## Like methodAddr, but walks base classes - the name lookup itself does not.
  if pClassGetParent == nil: return methodAddr(c, name, np)
  var cur = c
  for _ in 0 ..< depth:
    if cur == nil: break
    let a = methodAddr(cur, name, np)
    if a != nil: return a
    cur = pClassGetParent(cur)
  nil

proc fieldGetF32*(o: pointer, f: Il2CppField): float32 =
  if o == nil or f == nil or pFieldGetValue == nil: return 0'f32
  var v {.noinit.}: float32
  pFieldGetValue(o, f, addr v)
  v

proc fieldGetPtr*(o: pointer, f: Il2CppField): pointer =
  if o == nil or f == nil or pFieldGetValue == nil: return nil
  var v {.noinit.}: pointer
  pFieldGetValue(o, f, addr v)
  v

proc fieldSetF32*(o: pointer, f: Il2CppField, v: float32) =
  if o == nil or f == nil or pFieldSetValue == nil: return
  var tmp = v
  pFieldSetValue(o, f, addr tmp)

proc fieldSetBool*(o: pointer, f: Il2CppField, v: bool) =
  if o == nil or f == nil or pFieldSetValue == nil: return
  var tmp = v
  pFieldSetValue(o, f, addr tmp)

proc pin*(o: Il2CppObject): Il2CppGCHandle =
  if o == nil or pGchandleNew == nil: 0'u32 else: pGchandleNew(o, true)

proc moved*(h: Il2CppGCHandle): Il2CppObject =
  ## The pinned object at its current address; a moving collector may have relocated it.
  if h == 0'u32 or pGchandleGet == nil: default(Il2CppObject) else: pGchandleGet(h)

proc unpin*(h: Il2CppGCHandle) =
  if h != 0'u32 and pGchandleFree != nil: pGchandleFree(h)

proc nameOf*(p: pointer, get: GetNameFn): string =
  if p == nil or get == nil: return "?"
  let c = get(p)
  if c == nil: "?" else: fromCString(c)

proc className*(c: Il2CppClass): string =
  if c == nil: return "nil"
  let ns = nameOf(c, pClassGetNamespace)
  let n = nameOf(c, pClassGetName)
  if ns.len == 0 or ns == "?": n else: ns & "." & n

proc objClassName*(o: Il2CppObject): string =
  if o == nil or pObjGetClass == nil: "nil" else: className(pObjGetClass(o))

proc fieldNames*(c: Il2CppClass, cap = 128): seq[string] =
  if c == nil or pClassGetFields == nil or pFieldGetName == nil: return @[]
  result = @[]
  var iter: pointer = nil
  while result.len < cap:
    let f = pClassGetFields(c, addr iter)
    if f == nil: break
    result.add nameOf(f, pFieldGetName)

proc methodNames*(c: Il2CppClass, cap = 256): seq[string] =
  if c == nil or pClassGetMethods == nil or pMethodGetName == nil: return @[]
  result = @[]
  var iter: pointer = nil
  while result.len < cap:
    let m = pClassGetMethods(c, addr iter)
    if m == nil: break
    result.add nameOf(m, pMethodGetName)

proc fieldDeclaredClass*(f: Il2CppField): Il2CppClass =
  if f == nil or pFieldGetType == nil or pClassFromType == nil: return nil
  let t = pFieldGetType(f)
  if t == nil: default(Il2CppClass) else: pClassFromType(t)

## Filter an instance walk on this: fieldGetPtr on a value field reads the value as an address.
## IL2CPP exposes no type_is_reference, so the field's class is asked instead.
proc fieldIsInstanceRef*(f: Il2CppField): bool =
  if f == nil or pClassIsValueType == nil: return false
  if pFieldGetFlags != nil and (pFieldGetFlags(f) and FIELD_STATIC) != 0'u32: return false
  let c = fieldDeclaredClass(f)
  if c == nil: return false
  not pClassIsValueType(c)

proc fieldOffset*(c: Il2CppClass, name: string): int =
  ## Byte offset of an instance field, or -1. By name, so a moved layout reads as absent.
  if c == nil or pClassGetField == nil or pFieldGetOffset == nil: return -1
  var n = name
  let f = pClassGetField(c, n.toCString)
  if f == nil: -1 else: int(pFieldGetOffset(f))

proc staticObject*(c: Il2CppClass, name: string): Il2CppObject =
  ## Reads a reference-typed static field, initialising the class so the slot is populated.
  if c == nil or pFieldStaticGet == nil or pClassGetField == nil: return nil
  var n = name
  let f = pClassGetField(c, n.toCString)
  if f == nil: return nil
  if pRuntimeClassInit != nil: pRuntimeClassInit(c)
  var v: pointer = nil
  pFieldStaticGet(f, addr v)
  v

proc setStaticObject*(c: Il2CppClass, name: string, v: Il2CppObject) =
  if c == nil or pFieldStaticSet == nil or pClassGetField == nil: return
  var n = name
  let f = pClassGetField(c, n.toCString)
  if f == nil: return
  var tmp = v
  pFieldStaticSet(f, addr tmp)

proc classOf*(o: Il2CppObject): Il2CppClass =
  if o == nil or pObjGetClass == nil: default(Il2CppClass) else: pObjGetClass(o)

proc isSubclassOf*(o: Il2CppObject, base: Il2CppClass, depth = 8): bool =
  ## Walks the object's class chain looking for `base`.
  if o == nil or base == nil or pObjGetClass == nil or pClassGetParent == nil: return false
  var cur = pObjGetClass(o)
  for _ in 0 ..< depth:
    if cur == nil: break
    if cur == base: return true
    cur = pClassGetParent(cur)
  false

proc newInstance*(c: Il2CppClass): Il2CppObject =
  ## Allocates and runs the default constructor; nil when the allocator is missing.
  if c == nil or pObjectNew == nil: return nil
  let o = pObjectNew(c)
  if o != nil and pRuntimeObjectInit != nil: pRuntimeObjectInit(o)
  o

proc invoke*(m: Il2CppMethod, obj: pointer, args: ptr UncheckedArray[pointer]): Il2CppObject =
  ## Answers nil when the method throws; a managed exception must not reach a hook body.
  if m == nil or pRuntimeInvoke == nil: return nil
  var exc: Il2CppObject = nil
  let r = pRuntimeInvoke(m, obj, args, addr exc)
  if exc != nil: default(Il2CppObject) else: r

proc unboxInt32*(o: Il2CppObject): int =
  ## The boxed int behind a property getter's return value, or -1 when it cannot be read.
  if o == nil or pObjUnbox == nil: return -1
  let p = cast[ptr int32](pObjUnbox(o))
  if p == nil: -1 else: int(p[])

proc unboxBool*(o: Il2CppObject): int =
  ## Tri-state: 1, 0, or -1 when the value cannot be read.
  if o == nil or pObjUnbox == nil: return -1
  let p = cast[ptr uint8](pObjUnbox(o))
  if p == nil: -1 elif p[] != 0: 1 else: 0

# What `runtime` needs to find this runtime, attach to it, and resolve hooks.

const il2cppSoname* = "libil2cpp.so"
  ## `il2cppBackend` takes an override for a target that renamed it, which some packers do.

var gImage: ElfSyms

proc il2cppSym*(name: cstring): pointer {.cdecl.} =
  ## A `SymResolver` over the attached image.
  if not gImage.ok: default(pointer) else: gImage.sym(name)

proc il2cppSyms*(): ElfSyms = gImage

proc install*(h: Hook, cls: Il2CppClass): bool {.discardable.} =
  ## For a feature hooking several methods of one class: `getClass` walks the assembly list.
  h.installAt(methodAddr(cls, h.sym, h.argc))

proc findInherited*(c: Il2CppClass, name: string, depth = 4): pointer =
  ## The address of a parameterless method, walking up from `c`.
  methodAddrInherited(c, name, 0, depth)

proc il2cppResolve(owner, sym: string, argc: int): pointer =
  ## `owner` is "Namespace.Class, Assembly", or empty for an IL2CPP entry point.
  if owner.len == 0:
    var n = sym
    return il2cppSym(n.toCString)
  let cls = getClass(owner)
  if cls == nil:
    logE(shortName(owner) & " class not found")
    return nil
  methodAddr(cls, sym, argc)

proc il2cppReady(): bool =
  ## Every lookup starts from the domain, which only answers once il2cpp_init has built one.
  domain() != nil

proc il2cppIsUp(s: ElfSyms): bool {.gcsafe.} =
  ## A copy mapped but never initialised answers nil.
  let fn = asProc[GetDomainFn](s.sym("il2cpp_domain_get"))
  if fn == nil: false else: fn() != nil

proc il2cppAttach(s: ElfSyms) =
  gImage = s
  resolveIl2cpp(il2cppSym)
  logI("il2cpp: domain=" & hex(domain()))

## The trigger hooks, whose only job is to call `doSetup` from a thread the runtime owns.
## Invoke is the hot one; init covers a target still starting, class_init one already past it.
type
  InitFn = proc (name: cstring): cint {.cdecl, gcsafe.}
  InvokeFn = proc (m, obj, params, exc: pointer): Il2CppObject {.cdecl, gcsafe.}
  ClassInitFn = proc (c: Il2CppClass) {.cdecl, gcsafe.}

var
  hInit = newHook("", "il2cpp_init", 0, nil)
  hInvoke = newHook("", "il2cpp_runtime_invoke", 0, nil)
  hClassInit = newHook("", "il2cpp_runtime_class_init", 0, nil)

var
  invokeCalls = 0
  classInitCalls = 0

proc hookInit(name: cstring): cint {.cdecl.} =
  logI("il2cpp_init('" & (if name == nil: "?" else: fromCString(name)) & "') called")
  let orig = origAs[InitFn](hInit)
  result = if orig != nil: orig(name) else: 0
  if not gSetup.load(): doSetup()

proc hookInvoke(m, obj, params, exc: pointer): Il2CppObject {.cdecl.} =
  guard "runtime_invoke":
    inc invokeCalls
    if invokeCalls <= 5 or invokeCalls mod 2000 == 0:
      logI("runtime_invoke call #" & $invokeCalls)
    if not gSetup.load() and invokeCalls mod 20 == 2: doSetup()
  let orig = origAs[InvokeFn](hInvoke)
  if orig != nil: orig(m, obj, params, exc) else: nil

proc hookClassInit(c: Il2CppClass) {.cdecl.} =
  guard "class_init":
    inc classInitCalls
    if not gSetup.load() and classInitCalls mod 50 == 7: doSetup()
  let orig = origAs[ClassInitFn](hClassInit)
  if orig != nil: orig(c)

hInit.replacement = asPointer(hookInit)
hInvoke.replacement = asPointer(hookInvoke)
hClassInit.replacement = asPointer(hookClassInit)

proc installTrigger(h: Hook) =
  ## Through `il2cppSym`, so a trigger does not depend on this being the active backend.
  var n = h.sym
  if not h.installAt(il2cppSym(n.toCString)):
    logE(h.sym & " hook failed")

proc il2cppTriggers(s: ElfSyms) =
  installTrigger(hInvoke)
  installTrigger(hInit)
  installTrigger(hClassInit)
  logI("il2cpp hooked")

proc il2cppBackend*(soname = il2cppSoname): Backend =
  ## Hand this to `useBackend` to target an IL2CPP runtime.
  Backend(name: "il2cpp", soname: soname, probe: il2cppIsUp, attach: il2cppAttach,
          triggers: il2cppTriggers, ready: il2cppReady, resolve: il2cppResolve)
