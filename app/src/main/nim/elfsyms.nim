import std/strutils

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

proc ok*(s: ElfSyms): bool = s.strtab != nil and s.symtab != nil and s.count > 0

proc sym*(s: ElfSyms, name: cstring): pointer =
  if not s.ok: return nil
  for i in 0 ..< s.count:
    let e = cast[ptr Elf64Sym](cast[uint64](s.symtab) + uint64(i * s.syment))
    if e.shndx == SHN_UNDEF or e.value == 0: continue
    if cast[cstring](addr s.strtab[e.name]) == name:
      return cast[pointer](s.bias + e.value)
  nil

proc elfSymsAt*(base: uint64): ElfSyms =
  ## `base` comes from /proc/self/maps and may be anything, so every failure answers with a
  ## non-ok result rather than raising.
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
  # bionic leaves DT_* pointer entries as link-time vaddrs on some paths and pre-relocates
  # them on others; a value already at or above the load bias is clearly the latter.
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
    of DT_HASH:   count = int(cast[ptr UncheckedArray[uint32]](fix(d.val))[1]) # nchain == nsyms
    of DT_GNU_HASH: gnu = cast[ptr UncheckedArray[uint32]](fix(d.val))
    else: discard
    d = cast[ptr Elf64Dyn](cast[uint64](d) + uint64(sizeof(Elf64Dyn)))

  # The GNU table stores no symbol count, so derive it from the highest bucket's chain
  # terminator. Only reachable for an image linked --hash-style=gnu alone; libmonosgen
  # carries both.
  if count == 0 and gnu != nil:
    let
      nbucket = gnu[0]
      symoff = gnu[1]
      bloomsz = gnu[2]
      buckets = cast[ptr UncheckedArray[uint32]](
        cast[uint64](gnu) + uint64(4 + bloomsz * 2) * 4'u64) # bloom words are 64-bit on ELF64
      chain = cast[ptr UncheckedArray[uint32]](
        cast[uint64](buckets) + uint64(nbucket) * 4'u64)
    var last = 0'u32
    for i in 0'u32 ..< nbucket:
      if buckets[i] > last: last = buckets[i]
    if last >= symoff:
      while (chain[last - symoff] and 1'u32) == 0: inc last
      count = int(last) + 1
    else:
      count = int(symoff)

  if strtab == nil or symtab == nil or count == 0: return
  ElfSyms(bias: bias, strtab: strtab, symtab: symtab, count: count, syment: syment)

proc residentInstances*(soname: string): seq[LibInstance] =
  ## A device can have several copies of one soname mapped at once (a Quest-customised zygote
  ## preloading VR-runtime libs alongside the app's private instance), so each load is tracked
  ## as its own tight range - one span over all matching lines would treat the gap between two
  ## unrelated images as valid. File offset 0 starts a fresh load; later segments extend it.
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
  except CatchableError:
    discard

proc findLiveImage*(soname: string, readyProbe: proc(s: ElfSyms): bool {.nimcall, gcsafe.}): ElfSyms =
  ## dlopen cannot reach a library in another linker namespace. bionic's already-loaded check
  ## (find_loaded_library_by_realpath) is scoped to the *calling* namespace, and this module is
  ## injected outside Virtual Desktop's per-APK ClassLoader namespace while libmonosgen is one
  ## of VD's private libs inside it - so dlopen of its path never finds the running instance to
  ## reuse, and instead maps a second copy whose mono_init() has never run. Every accessor in
  ## that copy then reads zeroed globals, which looks exactly like a runtime with its
  ## introspection compiled out, and the whole hooking layer silently does nothing. dlopen of a
  ## runtime copy also runs its DT_INIT_ARRAY constructors.
  ##
  ## RTLD_NOLOAD and dl_iterate_phdr are namespace-scoped too, so /proc/self/maps is the only
  ## view left. Walking the mapped image needs no file access because libmonosgen's .dynsym,
  ## .dynstr and .hash all sit inside its first PT_LOAD.
  ##
  ## Asking the image itself whether it is ready is both the "is the runtime up?" test and what
  ## separates the live runtime from a never-initialised copy, so there is no timing to guess.
  for inst in residentInstances(soname):
    let s = elfSymsAt(inst.base)
    if not s.ok: continue
    if readyProbe(s): return s
