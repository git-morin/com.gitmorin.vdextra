## Writes the settings the in-VD page changed to a file under VD's own data directory, so a
## change made in VR survives a restart without the companion app.
##
## Only the writing half lives here. `MainModule` reads the file at startup and feeds it back
## through the JNI setters it already calls, which keeps the parsing in Kotlin and leaves one
## path into the features rather than two racing at load.
##
## POSIX I/O via importc rather than the standard library: this has to compile under Nim 2 and
## Nimony, whose syncio diverges, and the rest of the module is raw interop anyway.
include nemohooks/features

import nemohooks

const
  O_WRONLY = 1'i32
  O_CREAT = 0o100'i32
  O_TRUNC = 0o1000'i32
  MODE_RW = 0o600'i32

proc cOpen(path: cstring, flags: cint, mode: cint): cint
  {.importc: "open", header: "<fcntl.h>".}
proc cWrite(fd: cint, buf: pointer, n: csize_t): int
  {.importc: "write", header: "<unistd.h>", discardable.}
proc cClose(fd: cint): cint {.importc: "close", header: "<unistd.h>", discardable.}
proc cRename(old, new: cstring): cint {.importc: "rename", header: "<stdio.h>".}
proc cRead(fd: cint, buf: pointer, n: csize_t): int
  {.importc: "read", header: "<unistd.h>".}

## The process we are injected into, from /proc/self/cmdline, so the path is right without the
## package name being compiled in. cmdline is NUL-terminated, which is already a C string.
proc selfPackage(): string =
  var buf {.noinit.}: array[256, char]
  let fd = cOpen("/proc/self/cmdline", 0'i32, 0'i32) # O_RDONLY
  if fd < 0: return ""
  let n = cRead(fd, addr buf[0], csize_t(buf.len - 1))
  cClose(fd)
  if n <= 0: return ""
  buf[n] = '\0'
  fromCString(cast[cstring](addr buf[0]))

proc confPath*(): string =
  let pkg = selfPackage()
  if pkg.len == 0: "" else: "/data/data/" & pkg & "/files/vdextra.conf"

## Written to a neighbouring file and renamed over the real one: a reader that catches us
## mid-write would otherwise see a half-finished file and fall back to its defaults.
proc writeConf*(body: string): bool =
  let path = confPath()
  if path.len == 0:
    logE("conf: could not work out the package name, nothing saved")
    return false
  var tmp = path & ".tmp"
  var final = path
  let fd = cOpen(tmp.toCString, O_WRONLY or O_CREAT or O_TRUNC, MODE_RW)
  if fd < 0:
    logE("conf: cannot open " & tmp)
    return false
  var text = body
  var ok = true
  if text.len > 0:
    # Through toCString rather than `addr text[0]`: Nimony rejects taking the address of a
    # string's element, and asking for the C string is how both compilers hand over the bytes.
    ok = cWrite(fd, cast[pointer](text.toCString), csize_t(text.len)) == text.len
  cClose(fd)
  if not ok:
    logE("conf: short write to " & tmp)
    return false
  if cRename(tmp.toCString, final.toCString) != 0:
    logE("conf: cannot rename " & tmp & " over " & final)
    return false
  true
