## The native backend: plain functions in any shared object the target has mapped.
##
## A hook's `owner` is the soname holding the function; `sym` is an exported symbol or a
## `+0x...` file offset for a stripped library. A wrong offset still resolves and patches
## whatever it lands on, so prefer a symbol wherever one is exported.
##
## ```nim
## newHook("libgame.so", "Player_TakeDamage", 0, asPointer(hookTakeDamage))
## newHook("libgame.so", "+0x2f1b40", 0, asPointer(hookTick))
## ```
include nemohooks/features

import ../[compat, log, elfsyms, backend, hook]

var gImage: ElfSyms

proc nativeSym*(name: cstring): pointer {.cdecl.} =
  ## A `SymResolver` over the library this backend was given, if it was given one.
  if not gImage.ok: default(pointer) else: gImage.sym(name)

proc nativeSyms*(): ElfSyms = gImage

proc newNativeHook*(soname, sym: string, replacement: pointer): Hook =
  ## A hook on an exported function, without newHook's unused parameter count.
  newHook(soname, sym, 0, replacement)

proc newOffsetHook*(soname: string, offset: int, replacement: pointer): Hook =
  ## A hook on an unexported function, by offset from the library's load bias.
  newHook(soname, "+" & hex(cast[pointer](offset)), 0, replacement)

proc nativeResolve(owner, sym: string, argc: int): pointer =
  ## An empty `owner` means the library this backend was given. `argc` is unused.
  if sym.len > 1 and sym[0] == '+':
    let off = parseHexAddr(sym[1 .. ^1])
    if off < 0:
      logE(sym & ": not a hex offset")
      return nil
    if owner.len > 0: return offsetIn(owner, off)
    if not gImage.ok: return nil
    return cast[pointer](gImage.bias + uint64(off))
  if owner.len > 0: return symbolIn(owner, sym)
  var n = sym
  nativeSym(n.toCString)

proc nativeAttach(s: ElfSyms) =
  gImage = s

proc nativeBackend*(soname = ""): Backend =
  ## With no soname it is live immediately; with one, the poll waits for that library first.
  ## No triggers and no readiness condition, so setup runs once on the poll thread.
  Backend(name: "native", soname: soname, attach: nativeAttach, resolve: nativeResolve)
