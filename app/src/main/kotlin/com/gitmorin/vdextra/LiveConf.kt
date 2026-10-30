package com.gitmorin.vdextra

import java.io.File

/**
 * Settings written by the in-VD page, read back at startup.
 *
 * The native side writes this file under VD's own data directory whenever a control on the
 * VDExtra page changes, because the module runs as VD's uid and cannot write the remote
 * preferences the companion app owns. Values are stored as thousandths so the file holds only
 * integers: no float parsing, and no decimal separator a locale could move.
 *
 * Where a key is present here it wins over the remote preference, so a change made in VR is
 * what the next launch uses. A key that is absent falls through to the companion app, which is
 * what keeps both working while the page is still being filled in.
 */
internal object LiveConf {
    private const val FILE = "vdextra.conf"
    private const val SCALE = 1000f

    private val values = HashMap<String, Int>()

    fun load(filesDir: File?) {
        values.clear()
        val f = File(filesDir ?: return, FILE)
        if (!f.isFile) return
        try {
            f.forEachLine { line ->
                val s = line.trim()
                if (s.isNotEmpty() && !s.startsWith("#")) {
                    val eq = s.indexOf('=')
                    if (eq > 0) {
                        val v = s.substring(eq + 1).trim().toIntOrNull()
                        if (v != null) values[s.substring(0, eq).trim()] = v
                    }
                }
            }
        } catch (t: Throwable) {
            values.clear()
        }
    }

    fun has(key: String) = values.containsKey(key)

    fun size() = values.size

    fun bool(key: String, def: Boolean) = values[key]?.let { it != 0 } ?: def

    fun float(key: String, def: Float) = values[key]?.let { it / SCALE } ?: def
}
