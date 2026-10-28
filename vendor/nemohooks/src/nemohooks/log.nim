## logcat output, and addresses formatted for it.
include nemohooks/features

import std/strutils
import compat

const
  ANDROID_LOG_DEBUG*: cint = 3
  ANDROID_LOG_INFO*: cint = 4
  ANDROID_LOG_ERROR*: cint = 6

  logTag* {.strdefine: "nemohooksLogTag".} = "nemohooks"

proc androidLogWrite(prio: cint, tag: cstring, text: cstring): cint
  {.importc: "__android_log_write", header: "<android/log.h>", discardable, gcsafe.}

proc emit(prio: cint, msg: string) =
  var tag = logTag # toCString needs a mutable string
  var m = msg
  androidLogWrite(prio, tag.toCString, m.toCString)

proc logD*(msg: string) = emit(ANDROID_LOG_DEBUG, msg)
  ## Per-call tracing: `adb logcat` drops it when filtered to `*:I`.

proc logI*(msg: string) = emit(ANDROID_LOG_INFO, msg)

proc logE*(msg: string) = emit(ANDROID_LOG_ERROR, msg)

proc hex*(p: pointer): string =
  ## An address's significant digits, without toHex's zero padding.
  let v = cast[uint64](p)
  if v == 0: "0x0"
  else: "0x" & toLowerAscii(toHex(cast[int64](v), 16)).strip(
    trailing = false, chars = {'0'})
