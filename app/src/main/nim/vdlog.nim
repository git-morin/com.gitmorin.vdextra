## Android logcat output, under the same "VDExtra" tag the C++ side uses, so a mixed-language
## build still reads as one log.

const
  ANDROID_LOG_INFO* = 4
  ANDROID_LOG_ERROR* = 6
  TAG = "VDExtra"

proc androidLogWrite(prio: cint, tag: cstring, text: cstring): cint
  {.importc: "__android_log_write", header: "<android/log.h>", discardable.}

proc logI*(msg: string) =
  androidLogWrite(ANDROID_LOG_INFO, TAG, msg.cstring)

proc logE*(msg: string) =
  androidLogWrite(ANDROID_LOG_ERROR, TAG, msg.cstring)
