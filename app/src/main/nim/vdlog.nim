## Our code is almost entirely raw interop - Mono object pointers, Dobby trampolines,
## ELF symbol tables - where nil is a normal value rather than an error. Nimony makes
## every ptr not-nil by default, so this opts the module back into Nim 2 rules; the
## stdlib modules that were ported from Nim do the same.
when defined(nimony):
  {.feature: "lenientnils".}

const
  ## Typed: Nimony will not implicitly narrow an untyped integer literal to the cint the
  ## logging entry point declares.
  ANDROID_LOG_INFO*: cint = 4
  ANDROID_LOG_ERROR*: cint = 6
  TAG: cstring = "VDExtra"

## Nimony's string carries no terminating zero, so a cstring has to be asked for explicitly and
## the string has to be mutable to gain one. Shimming the Nim 2 side keeps both bodies
## identical instead of branching at every call.
when not defined(nimony):
  proc toCString(s: var string): cstring = s.cstring

proc androidLogWrite(prio: cint, tag: cstring, text: cstring): cint
  {.importc: "__android_log_write", header: "<android/log.h>", discardable, gcsafe.}

proc logI*(msg: string) =
  var m = msg
  androidLogWrite(ANDROID_LOG_INFO, TAG, m.toCString)

proc logE*(msg: string) =
  var m = msg
  androidLogWrite(ANDROID_LOG_ERROR, TAG, m.toCString)
