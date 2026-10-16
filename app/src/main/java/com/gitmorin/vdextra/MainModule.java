package com.gitmorin.vdextra;

import android.content.Context;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.util.Log;

import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

import io.github.libxposed.api.XposedModule;
import io.github.libxposed.api.XposedModuleInterface.PackageLoadedParam;

public class MainModule extends XposedModule {
    private static final String TAG = "VDExtra";

    private static boolean sLoaded = false;

    public MainModule() {
        super();
    }

    @Override
    public void onPackageLoaded(PackageLoadedParam param) {
        if (!VdTarget.matches(param.getPackageName()) || sLoaded) return;
        sLoaded = true;

        String moduleApk = null;
        try {
            ApplicationInfo module = getModuleApplicationInfo();
            if (module != null) moduleApk = module.sourceDir;
        } catch (Throwable t) {
            log(Log.ERROR, TAG, "get module apk failed", t);
        }

        try {
            System.loadLibrary("vdextra");
            log(Log.INFO, TAG, "native loaded");
        } catch (Throwable t) {
            log(Log.ERROR, TAG, "native load failed", t);
        }

        hookRuntimeInit(param.getDefaultClassLoader());

        try {

            String lang = readString(PrefKeys.UI_LANGUAGE, null);
            boolean fromSystem = lang == null;
            if (fromSystem) lang = Languages.systemDefault(Languages.available(moduleApk));
            Map<String, String> dict = loadBuiltinDict(moduleApk, lang);
            String[] ks = new String[dict.size()], vs = new String[dict.size()];
            int i = 0;
            for (Map.Entry<String, String> e : dict.entrySet()) { ks[i] = e.getKey(); vs[i] = e.getValue(); i++; }

            nativeSetDict(ks, vs);
            nativeInit();
            float musicVolume = readFloat(PrefKeys.MUSIC_VOLUME, 1.0f);
            // Hearing music is how a user knows the module took effect without having changed
            // anything, so a source is configured by default.
            String musicPath = readString(PrefKeys.MUSIC_PATH, PrefKeys.MUSIC_DEFAULT);
            boolean custom = !PrefKeys.MUSIC_VD.equals(musicPath);
            nativeSetMusicVolume(musicVolume);
            nativeSetCustomMusic(custom);
            if (custom) MusicPlayer.start(musicPath, moduleApk, musicVolume);
            nativeSetQuality(readBool(PrefKeys.DISABLE_QUALITY_SOUND, false), readInt(PrefKeys.QUALITY_MASK, 0x7F));
            nativeSetBitrate(readBool(PrefKeys.BITRATE_EXTEND, false), readBool(PrefKeys.BITRATE_UNLOCK, false), readFloat(PrefKeys.BITRATE_SCALE, 2.0f));
            nativeSetForceLan(readBool(PrefKeys.FORCE_LAN, false));
            requestUpdateCheck();
            log(Log.INFO, TAG, "lang=" + (Languages.isOff(lang) ? "off" : lang)
                    + (fromSystem ? " (system)" : "") + " dict=" + dict.size());
        } catch (Throwable t) {
            log(Log.ERROR, TAG, "init failed", t);
        }
    }

    private void hookRuntimeInit(ClassLoader cl) {
        try {
            Class<?> runtimeCls = Class.forName("mono.android.Runtime", false, cl);
            Method m = runtimeCls.getDeclaredMethod("initInternal",
                    String.class, String[].class, String.class, String[].class,
                    int.class, ClassLoader.class, String[].class, boolean.class, boolean.class);
            hook(m).intercept(chain -> {
                Object result = chain.proceed();
                try {
                    nativeCheckMono();
                } catch (Throwable t) {
                    log(Log.ERROR, TAG, "nativeCheckMono failed", t);
                }
                return result;
            });
            log(Log.INFO, TAG, "hooked mono.android.Runtime.initInternal");
        } catch (Throwable t) {
            log(Log.ERROR, TAG, "hook initInternal failed", t);
        }
    }

    private void requestUpdateCheck() {
        new Thread(() -> {
            for (int i = 0; i < 30; i++) {
                try {
                    Object app = Class.forName("android.app.ActivityThread")
                            .getMethod("currentApplication").invoke(null);
                    if (app instanceof Context) {
                        ((Context) app).sendBroadcast(new Intent(UpdateCheckReceiver.ACTION)
                                .setClassName(BuildConfig.APPLICATION_ID,
                                        UpdateCheckReceiver.class.getName())
                                .addFlags(Intent.FLAG_INCLUDE_STOPPED_PACKAGES));
                        log(Log.INFO, TAG, "requested update check");
                        return;
                    }
                } catch (Throwable t) {
                    log(Log.WARN, TAG, "update check request failed", t);
                    return;
                }
                try { Thread.sleep(1000); } catch (InterruptedException e) { return; }
            }
        }, "vdextra-update-check").start();
    }

    private Map<String, String> loadBuiltinDict(String moduleApk, String lang) {
        Map<String, String> m = new LinkedHashMap<>();
        if (moduleApk == null || Languages.isOff(lang)) return m;
        try (ZipFile zf = new ZipFile(moduleApk)) {
            ZipEntry e = zf.getEntry(Languages.apkEntry(lang));
            if (e == null) {

                log(Log.WARN, TAG, "no bundled dictionary for language " + lang);
                return m;
            }
            try (var in = zf.getInputStream(e)) {
                DictJson.parseInto(new String(DictJson.readAll(in), StandardCharsets.UTF_8), m);
            }
        } catch (Throwable t) {
            log(Log.WARN, TAG, "builtin dict failed", t);
        }
        return m;
    }

    private String readString(String key, String def) {
        try {
            String v = getRemotePreferences(PrefKeys.NAME).getString(key, def);
            return v != null ? v : def;
        } catch (Throwable t) { return def; }
    }

    private boolean readBool(String key, boolean def) {
        try { return getRemotePreferences(PrefKeys.NAME).getBoolean(key, def); } catch (Throwable t) { return def; }
    }

    private int readInt(String key, int def) {
        try { return getRemotePreferences(PrefKeys.NAME).getInt(key, def); } catch (Throwable t) { return def; }
    }

    private float readFloat(String key, float def) {
        try { return getRemotePreferences(PrefKeys.NAME).getFloat(key, def); } catch (Throwable t) { return def; }
    }

    public native void nativeInit();
    public native boolean nativeCheckMono();
    public native void nativeSetDict(String[] keys, String[] vals);
    public native void nativeSetMusicVolume(float volume);
    public static native void nativeSetCustomMusic(boolean on);
    public static native int nativeMusicState();
    public native void nativeSetQuality(boolean enable, int mask);
    public native void nativeSetBitrate(boolean extend, boolean unlock, float scale);
    public native void nativeSetForceLan(boolean enable);
}
