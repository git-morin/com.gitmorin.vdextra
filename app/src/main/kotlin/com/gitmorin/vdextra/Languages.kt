package com.gitmorin.vdextra

import android.content.res.AssetManager
import android.os.LocaleList
import java.util.Locale
import java.util.zip.ZipFile

internal object Languages {

    const val OFF = ""

    private const val DIR = "dict"
    private const val EXT = ".json"
    private const val APK_PREFIX = "assets/$DIR/"

    fun assetPath(tag: String) = "$DIR/$tag$EXT"

    fun apkEntry(tag: String) = "$APK_PREFIX$tag$EXT"

    fun isOff(tag: String?) = tag.isNullOrEmpty()

    fun available(assets: AssetManager): List<String> {
        val out = mutableListOf<String>()
        try {
            assets.list(DIR)?.forEach { if (it.endsWith(EXT)) out.add(it.removeSuffix(EXT)) }
        } catch (ignored: Throwable) {
        }
        sortByDisplayName(out)
        return out
    }

    fun available(moduleApk: String?): List<String> {
        val out = mutableListOf<String>()
        if (moduleApk == null) return out
        try {
            ZipFile(moduleApk).use { zf ->
                val entries = zf.entries()
                while (entries.hasMoreElements()) {
                    val name = entries.nextElement().name

                    if (name.startsWith(APK_PREFIX) && name.endsWith(EXT) &&
                        name.indexOf('/', APK_PREFIX.length) < 0
                    ) {
                        out.add(name.substring(APK_PREFIX.length).removeSuffix(EXT))
                    }
                }
            }
        } catch (ignored: Throwable) {
        }
        sortByDisplayName(out)
        return out
    }

    fun systemDefault(available: List<String>): String {
        if (available.isEmpty()) return OFF
        for (wanted in preferredLocales()) {
            bestMatch(wanted, available)?.let { return it }
        }
        return OFF
    }

    private fun bestMatch(wanted: Locale, available: List<String>): String? {
        val tag = wanted.toLanguageTag()
        available.firstOrNull { it.equals(tag, ignoreCase = true) }?.let { return it }

        val lang = wanted.language
        if (lang.isNullOrEmpty()) return null
        available.firstOrNull { it.equals(lang, ignoreCase = true) }?.let { return it }
        return available.firstOrNull {
            lang.equals(Locale.forLanguageTag(it).language, ignoreCase = true)
        }
    }

    private fun preferredLocales(): List<Locale> {
        val out = mutableListOf<Locale>()
        try {
            val list = LocaleList.getDefault()
            for (i in 0 until list.size()) out.add(list[i])
        } catch (ignored: Throwable) {
        }
        if (out.isEmpty()) out.add(Locale.getDefault())
        return out
    }

    fun displayName(tag: String): String {
        if (isOff(tag)) return ""
        try {
            val loc = Locale.forLanguageTag(tag)
            val name = loc.getDisplayName(loc)
            if (!name.isNullOrEmpty()) {
                return name.substring(0, 1).uppercase(loc) + name.substring(1)
            }
        } catch (ignored: Throwable) {
        }
        return tag
    }

    private fun sortByDisplayName(tags: MutableList<String>) {
        tags.sortWith { a, b -> displayName(a).compareTo(displayName(b), ignoreCase = true) }
    }
}
