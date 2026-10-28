## Where Nim 2 and Nimony disagree, so the rest of the library reads the same under both.

when defined(nimony):
  {.feature: "lenientnils".}

  import std/[locks, atomics, rawthreads]

  type PollThread* = RawThread

  proc startThread*(t: var PollThread; fn: proc (arg: pointer) {.nimcall.}) =
    try:
      create(t, fn, nil)
    except:
      discard

  template withLock*(l: var Lock; body: untyped) =
    acquire(l)
    try:
      body
    finally:
      release(l)

  type Atomic*[T] = object
    ## Nimony's atomics are operations on a location, so the value is held as one word and
    ## reinterpreted through a typed pointer.
    bits: uint64

  proc store*[T](a: var Atomic[T]; v: T) =
    var w: uint64 = 0
    cast[ptr T](addr w)[] = v
    atomicStore(a.bits, w)

  proc load*[T](a: var Atomic[T]): T =
    var w = atomicLoad(a.bits)
    cast[ptr T](addr w)[]

  proc compareExchange*[T](a: var Atomic[T]; expected: var T; desired: T): bool =
    ## On failure `expected` receives the value actually found.
    var want: uint64 = 0
    cast[ptr T](addr want)[] = expected
    var next: uint64 = 0
    cast[ptr T](addr next)[] = desired
    result = atomicCompareExchange(a.bits, want, next)
    if not result:
      expected = cast[ptr T](addr want)[]

else:
  proc toCString*(s: var string): cstring = s.cstring
  proc fromCString*(s: cstring): string = $s

  type PollThread* = Thread[pointer]

  proc startThread*(t: var PollThread; fn: proc (arg: pointer) {.thread, nimcall.}) =
    createThread(t, fn, nil)

proc asProc*[T](p: pointer): T =
  ## Moves between a bare address and a typed proc. Use these rather than `cast`.
  var tmp = p
  cast[ptr T](addr tmp)[]

proc asPointer*[T](f: T): pointer =
  var tmp = f
  cast[ptr pointer](addr tmp)[]
