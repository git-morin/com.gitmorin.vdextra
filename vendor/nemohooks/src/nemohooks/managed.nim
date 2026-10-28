## The object and string layout Mono and IL2CPP share, raw reads and writes at a field offset,
## and UTF-16 conversion. Re-exported by both managed backends.
include nemohooks/features

const
  objectHeaderSize* = 16
    ## Class pointer plus monitor. A field offset reported by either runtime includes it.
  stringLenOffset* = 16
  stringCharsOffset* = 20

  FIELD_STATIC* = 0x0010'u32
    ## FIELD_ATTRIBUTE_STATIC, as both runtimes report it.

proc strLen*(s: pointer): int =
  ## In UTF-16 code units.
  if s == nil: 0 else: int(cast[ptr int32](cast[uint64](s) + uint64(stringLenOffset))[])

proc strChars*(s: pointer): ptr UncheckedArray[uint16] =
  ## In place, in the target's heap.
  cast[ptr UncheckedArray[uint16]](cast[uint64](s) + uint64(stringCharsOffset))

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

var utf16Scratch* {.threadvar.}: seq[uint16]
  ## Conversion buffer behind each backend's `makeString`. Valid until the next conversion.

proc toUtf8*(s: pointer): string =
  ## A managed string as a Nim string, read from the layout rather than through the runtime.
  if s == nil: "" else: utf16ToUtf8(strChars(s), strLen(s))

proc readPtrAt*(o: pointer, off: int): pointer =
  if o == nil or off < 0: default(pointer)
  else: cast[ptr pointer](cast[uint64](o) + uint64(off))[]

proc readF32At*(o: pointer, off: int): float32 =
  if o == nil or off < 0: 0.0'f32
  else: cast[ptr float32](cast[uint64](o) + uint64(off))[]

proc readI32At*(o: pointer, off: int): int32 =
  if o == nil or off < 0: 0'i32
  else: cast[ptr int32](cast[uint64](o) + uint64(off))[]

proc writePtrAt*(o: pointer, off: int, v: pointer) =
  if o == nil or off < 0: return
  cast[ptr pointer](cast[uint64](o) + uint64(off))[] = v

proc writeBoolAt*(o: pointer, off: int, v: bool) =
  if o == nil or off < 0: return
  cast[ptr uint8](cast[uint64](o) + uint64(off))[] = (if v: 1'u8 else: 0'u8)

proc writeF32At*(o: pointer, off: int, v: float32) =
  if o == nil or off < 0: return
  cast[ptr float32](cast[uint64](o) + uint64(off))[] = v
