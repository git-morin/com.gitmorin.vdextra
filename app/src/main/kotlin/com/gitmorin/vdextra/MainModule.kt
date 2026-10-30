package com.gitmorin.vdextra

import android.content.Context
import android.content.Intent
import android.util.Log
import io.github.libxposed.api.XposedModule
import io.github.libxposed.api.XposedModuleInterface.PackageLoadedParam
import java.io.File
import java.util.zip.ZipFile

class MainModule : XposedModule() {

    override fun onPackageLoaded(param: PackageLoadedParam) {
        if (!VdTarget.matches(param.packageName) || loaded) return
        loaded = true

        var moduleApk: String? = null
        try {
            moduleApk = moduleApplicationInfo?.sourceDir
        } catch (t: Throwable) {
            log(Log.ERROR, TAG, "get module apk failed", t)
        }

        try {
            System.loadLibrary("vdextra")
            log(Log.INFO, TAG, "native loaded")
        } catch (t: Throwable) {
            log(Log.ERROR, TAG, "native load failed", t)
        }

        hookRuntimeInit(param.defaultClassLoader)

        // Written by the in-VD page, which runs as this process and so cannot reach the remote
        // preferences the companion app owns. Loaded before anything is pushed to native, so a
        // change made in VR is what this launch uses.
        LiveConf.load(File("/data/data/" + param.packageName + "/files"))

        try {
            var lang = readString(PrefKeys.UI_LANGUAGE, null)
            val fromSystem = lang == null
            if (lang == null) lang = Languages.systemDefault(Languages.available(moduleApk))
            val dict = loadBuiltinDict(moduleApk, lang)

            nativeSetDict(dict.keys.toTypedArray(), dict.values.toTypedArray())
            nativeSetVersion(BuildConfig.VERSION_NAME)
            nativeInit()
            val musicVolume = liveFloat(PrefKeys.MUSIC_VOLUME, 1.0f)
            // Hearing music is how a user knows the module took effect without having changed
            // anything, so a source is configured by default.
            val musicPath = readString(PrefKeys.MUSIC_PATH, PrefKeys.MUSIC_DEFAULT)
                ?: PrefKeys.MUSIC_DEFAULT
            val custom = PrefKeys.MUSIC_VD != musicPath
            nativeSetMusicVolume(musicVolume)
            nativeSetCustomMusic(custom)
            if (custom) MusicPlayer.start(this, musicPath, musicVolume)
            nativeSetQuality(
                liveBool(PrefKeys.DISABLE_QUALITY_SOUND, false),
                readInt(PrefKeys.QUALITY_MASK, 0x7F)
            )
            nativeSetBitrate(
                liveBool(PrefKeys.BITRATE_EXTEND, false),
                liveBool(PrefKeys.BITRATE_UNLOCK, false),
                liveFloat(PrefKeys.BITRATE_SCALE, 2.0f)
            )
            nativeSetForceLan(liveBool(PrefKeys.FORCE_LAN, false))
            nativeSetSettingsFit(
                liveBool(PrefKeys.SETTINGS_FIT, true),
                liveFloat(PrefKeys.SETTINGS_FIT_PAD, 16.0f)
            )
            requestUpdateCheck()
            log(
                Log.INFO, TAG,
                "lang=" + (if (Languages.isOff(lang)) "off" else lang) +
                    (if (fromSystem) " (system)" else "") + " dict=" + dict.size +
                    " live=" + LiveConf.size()
            )
        } catch (t: Throwable) {
            log(Log.ERROR, TAG, "init failed", t)
        }
    }

    private fun hookRuntimeInit(cl: ClassLoader) {
        try {
            val runtimeCls = Class.forName("mono.android.Runtime", false, cl)
            val m = runtimeCls.getDeclaredMethod(
                "initInternal",
                String::class.java, Array<String>::class.java, String::class.java,
                Array<String>::class.java, Int::class.javaPrimitiveType,
                ClassLoader::class.java, Array<String>::class.java,
                Boolean::class.javaPrimitiveType, Boolean::class.javaPrimitiveType
            )
            hook(m).intercept { chain ->
                val result = chain.proceed()
                try {
                    nativeCheckMono()
                } catch (t: Throwable) {
                    log(Log.ERROR, TAG, "nativeCheckMono failed", t)
                }
                result
            }
            log(Log.INFO, TAG, "hooked mono.android.Runtime.initInternal")
        } catch (t: Throwable) {
            log(Log.ERROR, TAG, "hook initInternal failed", t)
        }
    }

    private fun requestUpdateCheck() {
        Thread(::sendUpdateCheckRequest, "vdextra-update-check").start()
    }

    private fun sendUpdateCheckRequest() {
        repeat(30) {
            try {
                val app = Class.forName("android.app.ActivityThread")
                    .getMethod("currentApplication").invoke(null)
                if (app is Context) {
                    app.sendBroadcast(
                        Intent(UpdateCheckReceiver.ACTION)
                            .setClassName(
                                BuildConfig.APPLICATION_ID,
                                UpdateCheckReceiver::class.java.name
                            )
                            .addFlags(Intent.FLAG_INCLUDE_STOPPED_PACKAGES)
                    )
                    log(Log.INFO, TAG, "requested update check")
                    return
                }
            } catch (t: Throwable) {
                log(Log.WARN, TAG, "update check request failed", t)
                return
            }
            try {
                Thread.sleep(1000)
            } catch (e: InterruptedException) {
                return
            }
        }
    }

    private fun loadBuiltinDict(moduleApk: String?, lang: String): Map<String, String> {
        val m = LinkedHashMap<String, String>()
        if (moduleApk == null || Languages.isOff(lang)) return m
        try {
            ZipFile(moduleApk).use { zf ->
                val e = zf.getEntry(Languages.apkEntry(lang))
                if (e == null) {
                    log(Log.WARN, TAG, "no bundled dictionary for language $lang")
                    return m
                }
                zf.getInputStream(e).use {
                    DictJson.parseInto(it.readBytes().toString(Charsets.UTF_8), m)
                }
            }
        } catch (t: Throwable) {
            log(Log.WARN, TAG, "builtin dict failed", t)
        }
        return m
    }

    // The in-VD page wins where it has written a value; everything else still comes from the
    // companion app, which is what keeps both usable while the page is being filled in.
    private fun liveBool(key: String, def: Boolean) =
        if (LiveConf.has(key)) LiveConf.bool(key, def) else readBool(key, def)

    private fun liveFloat(key: String, def: Float) =
        if (LiveConf.has(key)) LiveConf.float(key, def) else readFloat(key, def)

    private fun readString(key: String, def: String?): String? =
        try {
            getRemotePreferences(PrefKeys.NAME).getString(key, def) ?: def
        } catch (t: Throwable) {
            def
        }

    private fun readBool(key: String, def: Boolean) =
        try {
            getRemotePreferences(PrefKeys.NAME).getBoolean(key, def)
        } catch (t: Throwable) {
            def
        }

    private fun readInt(key: String, def: Int) =
        try {
            getRemotePreferences(PrefKeys.NAME).getInt(key, def)
        } catch (t: Throwable) {
            def
        }

    private fun readFloat(key: String, def: Float) =
        try {
            getRemotePreferences(PrefKeys.NAME).getFloat(key, def)
        } catch (t: Throwable) {
            def
        }

    // Instance methods, not statics: JNI resolves them by the mangled MainModule name either
    // way, and keeping them off the companion avoids the Companion suffix the mangler would
    // otherwise look for.
    external fun nativeInit()

    external fun nativeCheckMono(): Boolean

    external fun nativeSetDict(keys: Array<String>, vals: Array<String>)

    external fun nativeSetVersion(version: String)

    external fun nativeSetMusicVolume(volume: Float)

    external fun nativeSetCustomMusic(on: Boolean)

    external fun nativeMusicState(): Int

    external fun nativeMusicVolume(): Float

    external fun nativeSetQuality(enable: Boolean, mask: Int)

    external fun nativeSetBitrate(extend: Boolean, unlock: Boolean, scale: Float)

    external fun nativeSetForceLan(enable: Boolean)

    external fun nativeSetSettingsFit(enable: Boolean, pad: Float)

    private companion object {
        const val TAG = "VDExtra"

        var loaded = false
    }
}
