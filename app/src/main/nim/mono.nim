import std/[tables, locks, math]
import vdlog

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
  StringNewUtf16Fn = proc(d: MonoDomain, text: ptr uint16, len: int32): MonoString {.cdecl, gcsafe.}
  GchandleNewFn = proc(o: MonoObject, pinned: cint): MonoGCHandle {.cdecl, gcsafe.}
  GchandleGetFn = proc(h: MonoGCHandle): MonoObject {.cdecl, gcsafe.}
  GchandleFreeFn = proc(h: MonoGCHandle) {.cdecl, gcsafe.}
  GetDomainFn = proc(): MonoDomain {.cdecl, gcsafe.}
  GetSizeFn* = proc(o: MonoObject): cfloat {.cdecl, gcsafe.}

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
  pStringNewUtf16*: StringNewUtf16Fn
  pGchandleNew*: GchandleNewFn
  pGchandleGet*: GchandleGetFn
  pGchandleFree*: GchandleFreeFn
  pGetRootDomain*: GetDomainFn
  pDomainGet*: GetDomainFn

var
  gCorlib*: MonoImage
  gDomain*: MonoDomain
  gClsOff*: MonoClass    ## OfflineRasterizedSpriteFont, for the font-class walk
  gDictField*: MonoField ## its CharacterToGlyph field
  getSizeFn*: GetSizeFn  ## SpriteFont::get_Size

const FULL* = 1000 ## glyph count we treat as full coverage

var
  gDict: Table[string, string]
  gGoodHandle: MonoGCHandle
  gGoodMap: Table[int, MonoGCHandle]
  gMapLock: Lock

gMapLock.initLock()

proc resolveMono*(sym: proc(name: cstring): pointer {.cdecl, gcsafe.}) =
  pGetCorlib = cast[GetCorlibFn](sym("mono_get_corlib"))
  pClassFromName = cast[ClassFromNameFn](sym("mono_class_from_name"))
  pClassGetMethod = cast[ClassGetMethodFn](sym("mono_class_get_method_from_name"))
  pRuntimeInvoke = cast[RuntimeInvokeFn](sym("mono_runtime_invoke"))
  pTypeGetClass = cast[TypeGetClassFn](sym("mono_type_get_class"))
  pCompileMethod = cast[CompileMethodFn](sym("mono_compile_method"))
  pObjGetClass = cast[ObjGetClassFn](sym("mono_object_get_class"))
  pObjUnbox = cast[ObjUnboxFn](sym("mono_object_unbox"))
  pClassGetParent = cast[ClassGetParentFn](sym("mono_class_get_parent"))
  pClassGetField = cast[ClassGetFieldFn](sym("mono_class_get_field_from_name"))
  pFieldGetValue = cast[FieldGetValueFn](sym("mono_field_get_value"))
  pFieldSetValue = cast[FieldSetValueFn](sym("mono_field_set_value"))
  pStringNewUtf16 = cast[StringNewUtf16Fn](sym("mono_string_new_utf16"))
  pGchandleNew = cast[GchandleNewFn](sym("mono_gchandle_new"))
  pGchandleGet = cast[GchandleGetFn](sym("mono_gchandle_get_target"))
  pGchandleFree = cast[GchandleFreeFn](sym("mono_gchandle_free"))
  pGetRootDomain = cast[GetDomainFn](sym("mono_get_root_domain"))
  pDomainGet = cast[GetDomainFn](sym("mono_domain_get"))

proc corlib*(): MonoImage =
  if gCorlib == nil and pGetCorlib != nil: gCorlib = pGetCorlib()
  gCorlib

proc setDomain*(d: MonoDomain) =
  ## The trigger hooks are handed a domain pointer well before any call of ours could ask for
  ## one, and on this build mono_domain_get can stay null, so the first one we see is kept.
  if gDomain == nil and d != nil: gDomain = d

proc domain*(): MonoDomain =
  if pDomainGet != nil:
    let d = pDomainGet()
    if d != nil: return d
  if gDomain != nil: return gDomain
  if pGetRootDomain != nil: return pGetRootDomain()
  nil

# A MonoString carries its length at offset 16 and its UTF-16 data at offset 20.
proc monoStrLen*(s: MonoString): int =
  if s == nil: 0 else: int(cast[ptr int32](cast[uint64](s) + 16)[])

proc monoStrChars*(s: MonoString): ptr UncheckedArray[uint16] =
  cast[ptr UncheckedArray[uint16]](cast[uint64](s) + 20)

proc hasCjk*(s: ptr UncheckedArray[uint16], len: int): bool =
  ## Really "needs the full-coverage font": anything above U+2E7F. Note that this misses
  ## Cyrillic and Greek, which sit below it - see the README before adding such a language.
  for i in 0 ..< len:
    if s[i] > 0x2E7F'u16: return true
  false

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
  ## The translated string for `text`, or nil to leave it alone. Any string the dictionary
  ## does not carry passes through untouched, which is what makes partial dictionaries valid.
  # With no dictionary loaded - an English UI - there is nothing to look up, so skip the
  # conversion entirely rather than allocating a key per set_Text call.
  if gDict.len == 0: return nil
  let len = monoStrLen(text)
  if len <= 0 or len > 2048: return nil
  let key = utf16ToUtf8(monoStrChars(text), len)
  let hit = gDict.getOrDefault(key, "")
  if hit.len == 0: nil else: makeMono(hit)

proc getClass*(qname: string): MonoClass =
  ## Resolves an assembly-qualified name through System.Type.GetType, which is the only route
  ## that works here: the assemblies are AOT images, so there is no JIT-time name table to ask.
  if pClassFromName == nil or pClassGetMethod == nil or pRuntimeInvoke == nil or
     pTypeGetClass == nil or corlib() == nil:
    return nil
  let ct = pClassFromName(gCorlib, "System", "Type")
  if ct == nil: return nil
  let mGT = pClassGetMethod(ct, "GetType", 1)
  if mGT == nil: return nil
  let nm = makeMono(qname)
  if nm == nil: return nil
  var args: array[1, pointer]
  args[0] = nm
  var exc: MonoObject = nil
  let t = pRuntimeInvoke(mGT, nil, cast[ptr UncheckedArray[pointer]](addr args[0]), addr exc)
  if t == nil or exc != nil: return nil
  let typePtr = cast[ptr pointer](cast[uint64](t) + 16)[]
  if typePtr == nil: return nil
  pTypeGetClass(typePtr)

proc methodAddr*(c: MonoClass, name: string, np: int): pointer =
  if c == nil or pClassGetMethod == nil or pCompileMethod == nil: return nil
  let m = pClassGetMethod(c, name.cstring, cint(np))
  if m == nil: return nil
  pCompileMethod(m)

proc fieldGetF32*(o: pointer, f: MonoField): float32 =
  if o == nil or f == nil or pFieldGetValue == nil: return 0'f32
  var v: float32
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

# goodFont/goodMap entries are pinned, so Mono's moving collector cannot relocate them out
# from under the raw pointers we keep.
proc pin*(o: MonoObject): MonoGCHandle =
  if o == nil or pGchandleNew == nil: 0'u32 else: pGchandleNew(o, 1)

proc moved*(h: MonoGCHandle): MonoObject =
  if h == 0'u32 or pGchandleGet == nil: nil else: pGchandleGet(h)

proc unpin*(h: MonoGCHandle) =
  if h != 0'u32 and pGchandleFree != nil: pGchandleFree(h)

proc glyphCount*(font: MonoObject): int =
  ## -1 when the count cannot be read at all, which is distinct from a font that has none.
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
  ## Sizes 30 and 32 match to the nearest cached size; anything else prefers the largest
  ## non-32 entry, falling back to 32.
  var h: MonoGCHandle = 0
  withLock gMapLock:
    if gGoodHandle == 0'u32: return nil
    let r = int(round(size))
    if r == 30 or r == 32:
      if gGoodMap.hasKey(r):
        h = gGoodMap[r]
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
        h = if gGoodMap.hasKey(32): gGoodMap[32] else: gGoodHandle
  moved(h)
