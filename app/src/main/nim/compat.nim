## The handful of places where Nim 2 and Nimony disagree, kept in one module so the rest of the
## sources read the same under both compilers.

when defined(nimony):
  {.feature: "lenientnils".}

  import std/[locks, atomics, rawthreads]

  ## Nimony's thread handle, and `create` in place of `createThread`. Its entry point takes an
  ## argument where Nim 2's takes none, so the shared signature passes one and ignores it.
  type PollThread* = RawThread

  proc startThread*(t: var PollThread; fn: proc (arg: pointer) {.nimcall.}) =
    try:
      create(t, fn, nil)
    except:
      discard

  ## Nimony's locks module stops at acquire/release.
  template withLock*(l: var Lock; body: untyped) =
    acquire(l)
    try:
      body
    finally:
      release(l)

  ## Nimony has no `Atomic[T]`: "atomics are operations, not type properties", so its
  ## atomicLoad/atomicStore work on a plain location and accept only `Trivial` types - which
  ## excludes the float32 two of our features keep. Holding every value as the integer of the
  ## widest width covers all four types we use with one implementation, and keeps the
  ## `.load()`/`.store()` spelling the rest of the code already has.
  ##
  ## The payload is written through a typed pointer into a zeroed word and read back the same
  ## way, which is a plain reinterpretation on the little-endian arm64 we target.
  type Atomic*[T] = object
    bits: uint64

  proc store*[T](a: var Atomic[T]; v: T) =
    var w: uint64 = 0
    cast[ptr T](addr w)[] = v
    atomicStore(a.bits, w)

  proc load*[T](a: var Atomic[T]): T =
    var w = atomicLoad(a.bits)
    cast[ptr T](addr w)[]

  ## Compares and swaps the stored word, and - as Nim 2's does - writes the value actually
  ## found back into `expected` when the swap fails.
  proc compareExchange*[T](a: var Atomic[T]; expected: var T; desired: T): bool =
    var want: uint64 = 0
    cast[ptr T](addr want)[] = expected
    var next: uint64 = 0
    cast[ptr T](addr next)[] = desired
    result = atomicCompareExchange(a.bits, want, next)
    if not result:
      expected = cast[ptr T](addr want)[]

else:
  ## Nimony's string carries no terminating zero, so a cstring has to be asked for explicitly
  ## and the string has to be mutable to gain one; `fromCString` copies the other way. Both
  ## live in its system module, so only Nim 2 needs them spelled out.
  proc toCString*(s: var string): cstring = s.cstring
  proc fromCString*(s: cstring): string = $s

  type PollThread* = Thread[pointer]

  proc startThread*(t: var PollThread; fn: proc (arg: pointer) {.thread, nimcall.}) =
    createThread(t, fn, nil)
