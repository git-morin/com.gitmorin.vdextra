## Nim half of the native module, exposed to the C/C++ half as plain C entry points.
##
## The port is staged, so this currently owns finding the live Mono runtime and resolving its
## exports; native.cpp still owns the hooks and the JNI methods and calls in here for symbols.

import std/strutils
import vdlog, elfsyms

const MONO_SONAME = "libmonosgen-2.0.so"

type GetPtrFn = proc(): pointer {.cdecl.}

# Set once, by whichever thread wins the attach race on the C++ side (guarded there by an
# atomic compare-exchange), and only read afterwards.
var gMono: ElfSyms

proc callPtrFn(s: ElfSyms, name: cstring): pointer =
  let fn = cast[GetPtrFn](s.sym(name))
  if fn == nil: nil else: fn()

proc runtimeIsUp(s: ElfSyms): bool =
  ## mono_get_corlib and mono_get_root_domain read globals that stay null until mono_init() has
  ## run in *that* image, which makes "is this the live runtime?" a question we can just ask.
  callPtrFn(s, "mono_get_corlib") != nil or callPtrFn(s, "mono_get_root_domain") != nil

proc vdFindLiveMono(): uint64 {.exportc: "vdFindLiveMono", cdecl, dynlib.} =
  ## Base address of the live Mono image, or 0 while no mapped instance reports a running
  ## runtime. Safe to call repeatedly; "not ready yet" is an ordinary answer, not a failure.
  if gMono.ok: return gMono.bias

  let s = findLiveImage(MONO_SONAME, runtimeIsUp)
  if not s.ok: return 0

  gMono = s
  let
    corlib = callPtrFn(s, "mono_get_corlib")
    rootDomain = callPtrFn(s, "mono_get_root_domain")
  logI("libmonosgen attached: live runtime at base=0x" & toHex(s.bias) &
       " (corlib=0x" & toHex(cast[uint64](corlib)) &
       " root_domain=0x" & toHex(cast[uint64](rootDomain)) &
       ", " & $residentInstances(MONO_SONAME).len & " resident instance(s), " &
       $s.count & " syms)")
  s.bias

proc vdMonoSym(name: cstring): pointer {.exportc: "vdMonoSym", cdecl, dynlib.} =
  ## Address of `name` inside the live Mono image, or nil. Only valid after vdFindLiveMono()
  ## has returned non-zero.
  if not gMono.ok: nil else: gMono.sym(name)
