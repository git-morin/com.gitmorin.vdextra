#include <jni.h>

void NimMain(void);
void vdDictPut(const char* key, const char* val);
void vdDictLogCount(void);

// Nim is built with --noMain:on, so nothing initialises its runtime on its own: the generated
// code exports NimMain() but installs no library constructor. JNI_OnLoad is the right place to
// call it, because the JVM invokes it during System.loadLibrary("vdextra") before any native
// method of this library can be reached. A constructor would instead run at dlopen time, with
// no defined ordering against other translation units' initialisers.
JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* reserved) {
  (void)vm;
  (void)reserved;
  NimMain();
  return JNI_VERSION_1_6;
}

// The only JNI method still in C: walking two jobjectArrays is the one job here that is
// genuinely more direct through the C JNI interface than through Nim's FFI. Every other native
// method is exported straight from Nim.
JNIEXPORT void JNICALL Java_com_gitmorin_vdextra_MainModule_nativeSetDict(
    JNIEnv* env, jobject thiz, jobjectArray keys, jobjectArray vals) {
  (void)thiz;
  jint n = (*env)->GetArrayLength(env, keys);
  jint m = (*env)->GetArrayLength(env, vals);
  for (jint i = 0; i < n && i < m; i++) {
    jstring k = (jstring)(*env)->GetObjectArrayElement(env, keys, i);
    jstring v = (jstring)(*env)->GetObjectArrayElement(env, vals, i);
    const char* ck = k ? (*env)->GetStringUTFChars(env, k, NULL) : NULL;
    const char* cv = v ? (*env)->GetStringUTFChars(env, v, NULL) : NULL;
    if (ck && cv) vdDictPut(ck, cv);
    if (ck) (*env)->ReleaseStringUTFChars(env, k, ck);
    if (cv) (*env)->ReleaseStringUTFChars(env, v, cv);
    if (k) (*env)->DeleteLocalRef(env, k);
    if (v) (*env)->DeleteLocalRef(env, v);
  }
  vdDictLogCount();
}
