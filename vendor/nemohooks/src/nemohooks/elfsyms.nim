## Symbol lookup against a shared object already mapped into this process, read straight out of
## its in-memory image.
include nemohooks/features

import std/strutils
import compat

when defined(nimony):
  import std/[syncio, parseutils]

  func parseHexInt(s: string): int =
    result = 0
    discard parseHex(s, result)

const
  PT_LOAD = 1'u32
  PT_DYNAMIC = 2'u32
  DT_NULL = 0'i64
  DT_HASH = 4'i64
  DT_STRTAB = 5'i64
  DT_SYMTAB = 6'i64
  DT_SYMENT = 11'i64
  DT_GNU_HASH = 0x6ffffef5'i64
  SHN_UNDEF = 0'u16

type
  Elf64Ehdr {.packed.} = object
    ident: array[16, byte]
    etype, machine: uint16
    version: uint32
    entry, phoff, shoff: uint64
    flags: uint32
    ehsize, phentsize, phnum, shentsize, shnum, shstrndx: uint16

  Elf64Phdr {.packed.} = object
    ptype, flags: uint32
    offset, vaddr, paddr, filesz, memsz, align: uint64

  Elf64Dyn {.packed.} = object
    tag: int64
    val: uint64

  Elf64Sym {.packed.} = object
    name: uint32
    info, other: uint8
    shndx: uint16
    value, size: uint64

  ElfSyms* = object
    bias*: uint64
    strtab: ptr UncheckedArray[char]
    symtab: pointer
    count*: int
    syment: int

  LibInstance* = object
    base*, limit*: uint64

  SymResolver* = proc (name: cstring): pointer {.cdecl, gcsafe.}
    ## The address of a symbol in a mapped image.

  ReadyProbe* = proc (s: ElfSyms): bool {.nimcall, gcsafe.}
    ## Asked of a candidate image: is *this* copy the initialised one?

proc ok*(s: ElfSyms): bool = s.strtab != nil and s.symtab != nil and s.count > 0

proc sym*(s: ElfSyms, name: cstring): pointer =
  if not s.ok: return nil
  for i in 0 ..< s.count:
    let e = cast[ptr Elf64Sym](cast[uint64](s.symtab) + uint64(i * s.syment))
    if e.shndx == SHN_UNDEF or e.value == 0: continue
    if cast[cstring](addr s.strtab[int(e.name)]) == name:
      return cast[pointer](s.bias + e.value)
  nil

proc elfSymsAt*(base: uint64): ElfSyms =
  ## A non-ok result for anything that is not a readable ELF image. Never raises.
  result = default(ElfSyms)
  let eh = cast[ptr Elf64Ehdr](base)
  if eh.ident[0] != 0x7f or eh.ident[1] != byte('E') or
     eh.ident[2] != byte('L') or eh.ident[3] != byte('F'):
    return

  var dynVa = 0'u64
  var minVa = high(uint64)
  for i in 0 ..< int(eh.phnum):
    let ph = cast[ptr Elf64Phdr](base + eh.phoff + uint64(i * int(eh.phentsize)))
    if ph.ptype == PT_DYNAMIC: dynVa = ph.vaddr
    elif ph.ptype == PT_LOAD and ph.vaddr < minVa: minVa = ph.vaddr
  if dynVa == 0 or minVa == high(uint64): return

  let bias = base - minVa
  # bionic pre-relocates DT_* pointer entries on some paths and leaves link-time vaddrs on others.
  template fix(v: uint64): uint64 = (if v >= bias: v else: bias + v)

  var
    strtab: ptr UncheckedArray[char] = nil
    symtab: pointer = nil
    syment = sizeof(Elf64Sym)
    count = 0
    gnu: ptr UncheckedArray[uint32] = nil

  var d = cast[ptr Elf64Dyn](bias + dynVa)
  while d.tag != DT_NULL:
    case d.tag
    of DT_STRTAB: strtab = cast[ptr UncheckedArray[char]](fix(d.val))
    of DT_SYMTAB: symtab = cast[pointer](fix(d.val))
    of DT_SYMENT: syment = int(d.val)
    of DT_HASH: count = int(cast[ptr UncheckedArray[uint32]](fix(d.val))[1]) # nchain == nsyms
    of DT_GNU_HASH: gnu = cast[ptr UncheckedArray[uint32]](fix(d.val))
    else: discard
    d = cast[ptr Elf64Dyn](cast[uint64](d) + uint64(sizeof(Elf64Dyn)))

  # The GNU table stores no symbol count, so derive it from the highest bucket's chain end.
  if count == 0 and gnu != nil:
    let
      nbucket = gnu[0]
      symoff = gnu[1]
      bloomsz = gnu[2]
      buckets = cast[ptr UncheckedArray[uint32]](
        cast[uint64](gnu) + uint64(4 + bloomsz * 2) * 4'u64)
      chain = cast[ptr UncheckedArray[uint32]](
        cast[uint64](buckets) + uint64(nbucket) * 4'u64)
    var last = 0'u32
    for i in 0'u32 ..< nbucket:
      if buckets[int(i)] > last: last = buckets[int(i)]
    if last >= symoff:
      while (chain[int(last - symoff)] and 1'u32) == 0: inc last
      count = int(last) + 1
    else:
      count = int(symoff)

  if strtab == nil or symtab == nil or count == 0: return
  result = ElfSyms(bias: bias, strtab: strtab, symtab: symtab, count: count, syment: syment)

proc residentInstances*(soname: string): seq[LibInstance] =
  ## Every mapped load of `soname`, as its own range - a process can have several of one
  ## soname. File offset 0 starts a load; later segments extend it.
  result = @[]
  try:
    for line in lines("/proc/self/maps"):
      let slash = line.find('/')
      if slash < 0 or not line.endsWith(soname): continue
      let dash = line.find('-')
      let space = line.find(' ')
      if dash < 0 or space < 0: continue
      let
        b = parseHexInt(line[0 ..< dash]).uint64
        e = parseHexInt(line[dash + 1 ..< space]).uint64
        fields = line[space + 1 .. ^1].splitWhitespace()
      if fields.len < 2: continue
      if parseHexInt(fields[1]).uint64 == 0:
        result.add LibInstance(base: b, limit: e)
      elif result.len > 0 and e > result[^1].limit:
        result[^1].limit = e
  except:
    discard

proc findLiveImage*(soname: string, readyProbe: ReadyProbe): ElfSyms =
  ## The initialised instance of `soname`, or a non-ok result while none is up yet.
  ##
  ## dlopen, RTLD_NOLOAD and dl_iterate_phdr are all scoped to the calling linker namespace,
  ## which an injected module is outside of, so `/proc/self/maps` is the only view of the
  ## target's own libraries. `readyProbe` tells the live runtime from a never-initialised copy.
  result = default(ElfSyms)
  for inst in residentInstances(soname):
    let s = elfSymsAt(inst.base)
    if not s.ok: continue
    if readyProbe(s): return s

proc liveImage*(soname: string): ElfSyms =
  ## The first mapped load of `soname` whose symbol tables can be read. A managed runtime wants
  ## `findLiveImage` instead, which asks whether the copy is the initialised one.
  result = default(ElfSyms)
  for inst in residentInstances(soname):
    let s = elfSymsAt(inst.base)
    if s.ok: return s

proc symbolIn*(soname, name: string): pointer =
  ## The address of an exported symbol in a library already mapped into this process.
  let s = liveImage(soname)
  if not s.ok: return nil
  var n = name
  s.sym(n.toCString)

proc offsetIn*(soname: string, offset: int): pointer =
  ## An address inside a mapped library, as the file offset a disassembler shows.
  let s = liveImage(soname)
  if not s.ok: return nil
  cast[pointer](s.bias + uint64(offset))

proc parseHexAddr*(s: string): int =
  ## Hex with an optional `0x`, or -1 when `s` is not a number - offset zero is a valid answer.
  var t = s
  if t.len > 2 and t[0] == '0' and (t[1] == 'x' or t[1] == 'X'): t = t[2 .. ^1]
  if t.len == 0: return -1
  for i in 0 ..< t.len:
    if t[i] notin {'0' .. '9', 'a' .. 'f', 'A' .. 'F'}: return -1
  parseHexInt(t)
