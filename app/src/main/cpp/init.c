// C entry glue for the Nim side.
//
// Nim is built with --noMain:on, so nothing calls its runtime initialiser on its own - the
// generated code exports NimMain() but installs no library constructor. JNI_OnLoad is the right
// place to call it: the JVM invokes it during System.loadLibrary("vdextra"), before any native
// method of this library can be reached, so every Nim-backed export can assume a live runtime.
//
// Doing this from a constructor instead would run it at dlopen time, before the JVM has the
// library registered, with no defined ordering against the C++ translation unit's own static
// initialisers.

#include <jni.h>

void NimMain(void);

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* reserved) {
  (void)vm;
  (void)reserved;
  NimMain();
  return JNI_VERSION_1_6;
}
