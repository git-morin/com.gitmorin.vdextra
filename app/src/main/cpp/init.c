#include <jni.h>

void NimMain(void);
void vdDictPut(const char* key, const char* val);
void vdDictLogCount(void);
void vdSetVersion(const char* version);

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* reserved) {
  (void)vm;
  (void)reserved;
  NimMain();
  return JNI_VERSION_1_6;
}

// Only the APK knows its own version, and the in-VD page shows it, so it is handed over as a
// string the same way the dictionary is: through C, because a jstring needs the JNI env.
JNIEXPORT void JNICALL Java_com_gitmorin_vdextra_MainModule_nativeSetVersion(JNIEnv* env,
                                                                             jobject thiz,
                                                                             jstring version) {
  (void)thiz;
  if (!version) return;
  const char* cv = (*env)->GetStringUTFChars(env, version, NULL);
  if (cv) {
    vdSetVersion(cv);
    (*env)->ReleaseStringUTFChars(env, version, cv);
  }
}

JNIEXPORT void JNICALL Java_com_gitmorin_vdextra_MainModule_nativeSetDict(JNIEnv* env, jobject thiz,
                                                                          jobjectArray keys,
                                                                          jobjectArray vals) {
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
