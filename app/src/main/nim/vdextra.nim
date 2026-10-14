# Toolchain spike: proves Nim -> C -> NDK -> libvdextra.so loads inside Virtual Desktop, that
# the Nim runtime is initialised, and that heap types work there, before any real logic is
# ported. Additive on purpose - native.cpp still provides every JNI method, so the module keeps
# working while this is verified. Deleted once the port lands.

const ANDROID_LOG_INFO = 4

proc androidLogWrite(prio: cint, tag: cstring, text: cstring): cint
  {.importc: "__android_log_write", header: "<android/log.h>", discardable.}

proc logInfo(msg: string) =
  androidLogWrite(ANDROID_LOG_INFO, "VDExtra", msg.cstring)

# Called from init.c's JNI_OnLoad, right after NimMain().
proc nimSpike() {.exportc: "nimSpike", cdecl, dynlib.} =
  # Exercise the heap and a couple of stdlib types deliberately: if the Nim runtime had not
  # been initialised, this is what would fault, not the bare log call above.
  var parts = @["nim", "spike", "alive"]
  var joined = ""
  for i, p in parts:
    if i > 0: joined.add('-')
    joined.add(p)
  logInfo("spike: " & joined & " (seq+string heap ok, " & $parts.len & " parts)")
