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

import compat

const
  ## Typed: Nimony will not implicitly narrow an untyped integer literal to the cint the
  ## logging entry point declares.
  ANDROID_LOG_INFO*: cint = 4
  ANDROID_LOG_ERROR*: cint = 6
  TAG: cstring = "VDExtra"

proc androidLogWrite(prio: cint, tag: cstring, text: cstring): cint
  {.importc: "__android_log_write", header: "<android/log.h>", discardable, gcsafe.}

proc logI*(msg: string) =
  var m = msg
  androidLogWrite(ANDROID_LOG_INFO, TAG, m.toCString)

proc logE*(msg: string) =
  var m = msg
  androidLogWrite(ANDROID_LOG_ERROR, TAG, m.toCString)
