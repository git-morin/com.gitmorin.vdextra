package com.gitmorin.vdextra;

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

/** Module entry point: loads the native hooks inside the Virtual Desktop process and applies settings. */
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

        hookLoadLibrary();

        try {
            boolean useImported = readBool(PrefKeys.USE_IMPORTED_DICT, true);
            Map<String, String> dict = new LinkedHashMap<>(loadBuiltinDict(moduleApk));
            if (useImported) dict.putAll(loadImportedDict());
            String[] ks = new String[dict.size()], vs = new String[dict.size()];
            int i = 0;
            for (Map.Entry<String, String> e : dict.entrySet()) { ks[i] = e.getKey(); vs[i] = e.getValue(); i++; }

            nativeSetDict(ks, vs);
            nativeInit();
            nativeSetNoMusic(readBool(PrefKeys.DISABLE_MUSIC, false));
            nativeSetQuality(readBool(PrefKeys.DISABLE_QUALITY_SOUND, false), readInt(PrefKeys.QUALITY_MASK, 0x7F));
            nativeSetBitrate(readBool(PrefKeys.BITRATE_EXTEND, false), readBool(PrefKeys.BITRATE_UNLOCK, false), readFloat(PrefKeys.BITRATE_SCALE, 2.0f));
            nativeSetForceLan(readBool(PrefKeys.FORCE_LAN, true));
            log(Log.INFO, TAG, "dict=" + dict.size() + " imported=" + useImported);
        } catch (Throwable t) {
            log(Log.ERROR, TAG, "init failed", t);
        }
    }

    // Catches libmonosgen becoming resident synchronously, on Xamarin's own bootstrap thread,
    // right as each native library load returns - instead of racing that bootstrap from our
    // own background poll thread (nativeInit's fallback), which consistently arrived too late
    // for Mono's runtime to accept any foreign-thread attach we tried (see native.cpp).
    private void hookLoadLibrary() {
        try {
            Method m = System.class.getDeclaredMethod("loadLibrary", String.class);
            hook(m).intercept(chain -> {
                Object result = chain.proceed();
                try {
                    nativeCheckMono();
                } catch (Throwable t) {
                    log(Log.ERROR, TAG, "nativeCheckMono failed", t);
                }
                return result;
            });
        } catch (Throwable t) {
            log(Log.ERROR, TAG, "hook loadLibrary failed", t);
        }
    }

    private Map<String, String> loadBuiltinDict(String moduleApk) {
        Map<String, String> m = new LinkedHashMap<>();
        if (moduleApk == null) return m;
        try (ZipFile zf = new ZipFile(moduleApk)) {
            ZipEntry e = zf.getEntry("assets/zh_ui_dict.json");
            if (e != null) {
                try (var in = zf.getInputStream(e)) {
                    DictJson.parseInto(new String(DictJson.readAll(in), StandardCharsets.UTF_8), m);
                }
            }
        } catch (Throwable t) {
            log(Log.WARN, TAG, "builtin dict failed", t);
        }
        return m;
    }

    private Map<String, String> loadImportedDict() {
        Map<String, String> m = new LinkedHashMap<>();
        try {
            String json = getRemotePreferences(PrefKeys.NAME).getString(PrefKeys.IMPORTED_DICT, null);
            if (json != null) DictJson.parseInto(json, m);
        } catch (Throwable t) {
            log(Log.WARN, TAG, "imported dict failed", t);
        }
        return m;
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
    public native void nativeSetNoMusic(boolean disable);
    public native void nativeSetQuality(boolean enable, int mask);
    public native void nativeSetBitrate(boolean extend, boolean unlock, float scale);
    public native void nativeSetForceLan(boolean enable);
}
