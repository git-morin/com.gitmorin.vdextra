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

import std/[tables, locks, math]
import vdlog, compat

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
  StringNewUtf16Fn = proc(d: MonoDomain, text: ptr uint16, len: int32): MonoString {.cdecl, gcsafe.}
  GchandleNewFn = proc(o: MonoObject, pinned: cint): MonoGCHandle {.cdecl, gcsafe.}
  GchandleGetFn = proc(h: MonoGCHandle): MonoObject {.cdecl, gcsafe.}
  GchandleFreeFn = proc(h: MonoGCHandle) {.cdecl, gcsafe.}
  GetDomainFn = proc(): MonoDomain {.cdecl, gcsafe.}
  GetSizeFn* = proc(o: MonoObject): cfloat {.cdecl, gcsafe.}
  ObjectNewFn = proc(d: MonoDomain, c: MonoClass): MonoObject {.cdecl, gcsafe.}
  ObjectInitFn = proc(o: MonoObject) {.cdecl, gcsafe.}
  GetNameFn = proc(p: pointer): cstring {.cdecl, gcsafe.}
  IterFn = proc(c: MonoClass, iter: ptr pointer): pointer {.cdecl, gcsafe.}
  FieldGetTypeFn = proc(f: MonoField): MonoType {.cdecl, gcsafe.}
  FieldGetFlagsFn = proc(f: MonoField): uint32 {.cdecl, gcsafe.}
  TypeIsRefFn = proc(t: MonoType): bool {.cdecl, gcsafe.}
  FieldGetOffsetFn = proc(f: MonoField): cint {.cdecl, gcsafe.}

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
  gClsOff*: MonoClass    ## OfflineRasterizedSpriteFont, for the font-class walk
  gDictField*: MonoField ## its CharacterToGlyph field
  getSizeFn*: GetSizeFn  ## SpriteFont::get_Size

const FULL* = 1000 ## glyph count we treat as full coverage

## Nimony refuses a direct `cast` between `pointer` and a proc type, and that conversion is the
## whole point of this module: every Mono entry point is resolved to a bare address and then
## called through a typed signature. Casting a *pointer to* the proc type and dereferencing is
## accepted by both compilers and loads the same word, so these two keep one source compiling
## under Nim 2 and Nimony alike.
proc asProc*[T](p: pointer): T =
  var tmp = p
  cast[ptr T](addr tmp)[]

proc asPointer*[T](f: T): pointer =
  var tmp = f
  cast[ptr pointer](addr tmp)[]


var
  gDict: Table[string, string]
  gGoodHandle: MonoGCHandle
  gGoodMap: Table[int, MonoGCHandle]
  gMapLock: Lock

gMapLock.initLock()

proc resolveMono*(sym: proc(name: cstring): pointer {.cdecl, gcsafe.}) =
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

proc monoStrLen*(s: MonoString): int =
  if s == nil: 0 else: int(cast[ptr int32](cast[uint64](s) + 16)[])

proc monoStrChars*(s: MonoString): ptr UncheckedArray[uint16] =
  cast[ptr UncheckedArray[uint16]](cast[uint64](s) + 20)

proc hasWideChars*(s: ptr UncheckedArray[uint16], len: int): bool =
  for i in 0 ..< len:
    if s[i] > 0x2E7F'u16: return true
  false

proc displayWidth*(s: ptr UncheckedArray[uint16], len: int): int =
  ## Cheap east-asian-width proxy: the wide range counts double, so a CJK translation with
  ## fewer characters is not mistaken for a narrower one.
  result = 0
  for i in 0 ..< len:
    result += (if s[i] > 0x2E7F'u16: 2 else: 1)

proc utf16ToUtf8*(s: ptr UncheckedArray[uint16], len: int): string =
  result = newStringOfCap(len * 3)
  var i = 0
  while i < len:
    var cp = uint32(s[i])
    if cp >= 0xD800'u32 and cp <= 0xDBFF'u32 and i + 1 < len and
       s[i+1] >= 0xDC00'u16 and s[i+1] <= 0xDFFF'u16:
      cp = 0x10000'u32 + ((cp - 0xD800'u32) shl 10) + (uint32(s[i+1]) - 0xDC00'u32)
      inc i
    if cp < 0x80'u32:
      result.add char(cp)
    elif cp < 0x800'u32:
      result.add char(0xC0'u32 or (cp shr 6))
      result.add char(0x80'u32 or (cp and 0x3F'u32))
    elif cp < 0x10000'u32:
      result.add char(0xE0'u32 or (cp shr 12))
      result.add char(0x80'u32 or ((cp shr 6) and 0x3F'u32))
      result.add char(0x80'u32 or (cp and 0x3F'u32))
    else:
      result.add char(0xF0'u32 or (cp shr 18))
      result.add char(0x80'u32 or ((cp shr 12) and 0x3F'u32))
      result.add char(0x80'u32 or ((cp shr 6) and 0x3F'u32))
      result.add char(0x80'u32 or (cp and 0x3F'u32))
    inc i

proc utf8ToUtf16*(u8: string, outBuf: var seq[uint16]) =
  outBuf.setLen(0)
  var i = 0
  let n = u8.len
  while i < n:
    let c = uint32(uint8(u8[i]))
    var cp: uint32
    var extra: int
    if c < 0x80'u32: cp = c; extra = 0
    elif (c and 0xE0'u32) == 0xC0'u32: cp = c and 0x1F'u32; extra = 1
    elif (c and 0xF0'u32) == 0xE0'u32: cp = c and 0x0F'u32; extra = 2
    elif (c and 0xF8'u32) == 0xF0'u32: cp = c and 0x07'u32; extra = 3
    else:
      inc i
      continue
    if i + extra >= n: break
    for k in 0 ..< extra:
      cp = (cp shl 6) or (uint32(uint8(u8[i + 1 + k])) and 0x3F'u32)
    i += 1 + extra
    if cp <= 0xFFFF'u32:
      outBuf.add uint16(cp)
    else:
      let v = cp - 0x10000'u32
      outBuf.add uint16(0xD800'u32 or (v shr 10))
      outBuf.add uint16(0xDC00'u32 or (v and 0x3FF'u32))

var tUtf16 {.threadvar.}: seq[uint16]

proc makeMono*(u8: string): MonoString =
  if pStringNewUtf16 == nil: return nil
  utf8ToUtf16(u8, tUtf16)
  if tUtf16.len == 0: return nil
  pStringNewUtf16(domain(), addr tUtf16[0], int32(tUtf16.len))

proc dictPut*(key, val: string) =
  gDict[key] = val

proc dictLen*(): int = gDict.len

proc translate*(text: MonoString): MonoString =
  if gDict.len == 0: return nil
  let len = monoStrLen(text)
  if len <= 0 or len > 2048: return nil
  let key = utf16ToUtf8(monoStrChars(text), len)
  let hit = gDict.getOrDefault(key, "")
  if hit.len == 0: default(MonoString) else: makeMono(hit)

proc getClass*(qname: string): MonoClass =
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
  let typePtr = cast[ptr pointer](cast[uint64](t) + 16)[]
  if typePtr == nil: return nil
  pTypeGetClass(typePtr)

proc methodAddr*(c: MonoClass, name: string, np: int): pointer =
  if c == nil or pClassGetMethod == nil or pCompileMethod == nil: return nil
  var n = name
  let m = pClassGetMethod(c, n.toCString, cint(np))
  if m == nil: return nil
  pCompileMethod(m)

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
  if h == 0'u32 or pGchandleGet == nil: default(MonoObject) else: pGchandleGet(h)

proc unpin*(h: MonoGCHandle) =
  if h != 0'u32 and pGchandleFree != nil: pGchandleFree(h)

proc glyphCount*(font: MonoObject): int =
  if font == nil or gDictField == nil or pFieldGetValue == nil or pObjGetClass == nil or
     pClassGetMethod == nil or pRuntimeInvoke == nil or pObjUnbox == nil:
    return -1
  var dict: pointer = nil
  pFieldGetValue(font, gDictField, addr dict)
  if dict == nil: return 0
  let dc = pObjGetClass(dict)
  if dc == nil: return -1
  let cm = pClassGetMethod(dc, "get_Count", 0)
  if cm == nil: return -1
  var exc: MonoObject = nil
  let r = pRuntimeInvoke(cm, dict, nil, addr exc)
  if exc != nil or r == nil: return -1
  let pi = cast[ptr int32](pObjUnbox(r))
  if pi == nil: -1 else: int(pi[])

proc fontSize*(f: MonoObject): float32 =
  if f == nil or getSizeFn == nil: 0'f32 else: float32(getSizeFn(f))

proc isFontClass*(o: MonoObject): bool =
  if o == nil or pObjGetClass == nil or pClassGetParent == nil or gClsOff == nil: return false
  var cur = pObjGetClass(o)
  for _ in 0 ..< 8:
    if cur == nil: break
    if cur == gClsOff: return true
    cur = pClassGetParent(cur)
  false

const FIELD_STATIC = 0x0010'u32

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

## A non-reference field read through fieldGetPtr would hand back a float or a bool
## reinterpreted as an address, so every instance walk has to filter on this first.
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
  ## Byte offset of an instance field, or -1. Resolved by name so a VD layout change is a
  ## missing field rather than a wrong read.
  if c == nil or pClassGetField == nil or pFieldGetOffset == nil: return -1
  var n = name
  let f = pClassGetField(c, n.toCString)
  if f == nil: -1 else: int(pFieldGetOffset(f))

proc readPtrAt*(o: pointer, off: int): pointer =
  if o == nil or off < 0: default(pointer)
  else: cast[ptr pointer](cast[uint64](o) + uint64(off))[]

proc readF32At*(o: pointer, off: int): float32 =
  if o == nil or off < 0: 0.0'f32
  else: cast[ptr float32](cast[uint64](o) + uint64(off))[]

proc writePtrAt*(o: pointer, off: int, v: pointer) =
  if o == nil or off < 0: return
  cast[ptr pointer](cast[uint64](o) + uint64(off))[] = v

proc writeBoolAt*(o: pointer, off: int, v: bool) =
  if o == nil or off < 0: return
  cast[ptr uint8](cast[uint64](o) + uint64(off))[] = (if v: 1'u8 else: 0'u8)

proc methodAddrInherited*(c: MonoClass, name: string, np: int): pointer =
  ## Like methodAddr, but walks base classes: mono_class_get_method_from_name does not, and
  ## the collection mutators live on FastCollection two levels above UIElementCollection.
  var cur = c
  for _ in 0 ..< 6:
    if cur == nil: break
    let a = methodAddr(cur, name, np)
    if a != nil: return a
    cur = pClassGetParent(cur)
  nil

## Mono's collection and array layout: a List-like collection keeps its storage behind an
## items pointer, a managed array *is* the storage, and both report their length at the same
## offset - so only the element read differs between them.
const
  LIST_ITEMS* = 16
  LIST_SIZE* = 24
  ARRAY_DATA* = 32

proc childCount*(coll: pointer): int =
  if coll == nil: 0
  else: int(cast[ptr int32](cast[uint64](coll) + uint64(LIST_SIZE))[])

proc childAt*(coll: pointer, i: int): pointer =
  let items = cast[ptr pointer](cast[uint64](coll) + uint64(LIST_ITEMS))[]
  if items == nil: return nil
  cast[ptr pointer](cast[uint64](items) + uint64(ARRAY_DATA + i * 8))[]

proc arrayAt*(arr: pointer, i: int): pointer =
  if arr == nil: return nil
  cast[ptr pointer](cast[uint64](arr) + uint64(ARRAY_DATA + i * 8))[]

## Xenko's Thickness stores its edges in this order, which is NOT the CSS one. Read from
## metadata (Bottom@16 Left@20 Right@24 Top@28, minus the 16-byte header): assuming
## left/top/right/bottom silently edits the wrong edge and looks almost right.
const
  THICKNESS_BOTTOM* = 0
  THICKNESS_LEFT* = 1
  THICKNESS_RIGHT* = 2
  THICKNESS_TOP* = 3

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

proc newInstance*(c: MonoClass): MonoObject =
  ## Allocates and runs the default constructor; nil when either entry point is missing.
  if c == nil or pObjectNew == nil: return nil
  let o = pObjectNew(domain(), c)
  if o != nil and pRuntimeObjectInit != nil: pRuntimeObjectInit(o)
  o

proc charToGlyph(font: MonoObject): MonoObject =
  if font == nil or gDictField == nil or pFieldGetValue == nil: return nil
  var dict: pointer = nil
  pFieldGetValue(font, gDictField, addr dict)
  dict

var
  gContainsKey: MonoMethod
  gContainsKeyClass: MonoClass

proc dictHasKey(dict: MonoObject, unit: uint16): int =
  if dict == nil or pObjGetClass == nil or pClassGetMethod == nil or
     pRuntimeInvoke == nil or pObjUnbox == nil: return -1
  let dc = pObjGetClass(dict)
  if dc == nil: return -1
  if dc != gContainsKeyClass:
    gContainsKey = pClassGetMethod(dc, "ContainsKey", 1)
    gContainsKeyClass = dc
  let m = gContainsKey
  if m == nil: return -1
  # Widened deliberately: mono_runtime_invoke reads sizeof(parameter) bytes through this
  # pointer, and a zeroed int32 reads correctly whether the key is a char or an int. A uint16
  # would leave the upper half of an int key as stack garbage.
  var key = int32(unit)
  var args {.noinit.}: array[1, pointer]
  args[0] = addr key
  var exc: MonoObject = nil
  let r = pRuntimeInvoke(m, dict, cast[ptr UncheckedArray[pointer]](addr args[0]), addr exc)
  if exc != nil or r == nil: return -1
  let b = cast[ptr uint8](pObjUnbox(r))
  if b == nil: -1 elif b[] != 0: 1 else: 0

proc fontCovers*(font: MonoObject, s: ptr UncheckedArray[uint16], len: int): bool =
  if len <= 0: return true
  # Anything the dictionary cannot answer falls back to the codepoint heuristic this replaced,
  # so a font that cannot be inspected still behaves as it did before.
  if not isFontClass(font): return not hasWideChars(s, len)
  let dict = charToGlyph(font)
  if dict == nil: return not hasWideChars(s, len)
  var asked: seq[uint16] = @[]
  for i in 0 ..< len:
    let u = s[i]
    if u < 0x80'u16: continue
    if u in asked: continue
    asked.add u
    case dictHasKey(dict, u)
    of 0: return false
    of 1: discard
    else: return not hasWideChars(s, len)
  true

proc markGood*(f: MonoObject, tag: string) =
  if f == nil: return
  let g = glyphCount(f)
  if g < FULL: return
  let sz = fontSize(f)
  let k = int(round(sz))
  if gGoodHandle == 0'u32:
    gGoodHandle = pin(f)
    logI("[F] goodFont(" & tag & ") size=" & $sz & " glyphs=" & $g)
  withLock gMapLock:
    if not gGoodMap.hasKey(k): gGoodMap[k] = pin(f)

proc goodMapHas*(k: int): bool =
  withLock gMapLock:
    result = gGoodMap.hasKey(k)

proc goodFont*(): MonoObject = moved(gGoodHandle)

proc pickReplacement*(size: float32): MonoObject =
  var h: MonoGCHandle = 0
  withLock gMapLock:
    if gGoodHandle == 0'u32: return nil
    let r = int(round(size))
    if r == 30 or r == 32:
      if gGoodMap.hasKey(r):
        h = gGoodMap.getOrDefault(r)
      else:
        var best = gGoodHandle
        var bd = high(int)
        for k, v in gGoodMap:
          let d = abs(k - r)
          if d < bd:
            bd = d
            best = v
        h = best
    else:
      var mk = low(int)
      for k, v in gGoodMap:
        if k != 32 and k > mk:
          mk = k
          h = v
      if h == 0'u32:
        h = if gGoodMap.hasKey(32): gGoodMap.getOrDefault(32) else: gGoodHandle
  moved(h)
