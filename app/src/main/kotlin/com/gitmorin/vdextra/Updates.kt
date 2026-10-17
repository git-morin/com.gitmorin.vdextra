package com.gitmorin.vdextra

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.Uri
import org.json.JSONArray
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

internal object Updates {

    const val STABLE = "stable"
    const val DEV = "dev"

    const val INSTALL_ACTION = "com.gitmorin.vdextra.INSTALL_RESULT"

    private const val RELEASES_URL =
        "https://api.github.com/repos/git-morin/com.gitmorin.vdextra/releases?per_page=30"
    private const val TIMEOUT_MS = 15000

    class Release(val version: String, val apkUrl: String, val apkSize: Long)

    fun channelOf(pref: String?) = if (DEV == pref) DEV else STABLE

    fun latest(channel: String): Release? {
        val body = get(RELEASES_URL)
        val arr = try {
            JSONArray(body)
        } catch (t: Throwable) {
            throw IOException("unexpected response from GitHub")
        }

        var best: Release? = null
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            if (o.optBoolean("draft", false)) continue
            if (DEV != channel && o.optBoolean("prerelease", false)) continue

            val tag = o.optString("tag_name", "")
            if (tag.isEmpty()) continue

            val assets = o.optJSONArray("assets")
            var url: String? = null
            var size = 0L
            for (j in 0 until (assets?.length() ?: 0)) {
                val a = assets?.optJSONObject(j) ?: continue
                if (a.optString("name", "").endsWith(".apk")) {
                    url = a.optString("browser_download_url", null)
                    size = a.optLong("size", 0)
                    break
                }
            }
            val apkUrl = url ?: continue

            val r = Release(versionOf(tag), apkUrl, size)
            if (best == null || compareVersions(r.version, best.version) > 0) best = r
        }
        return best
    }

    fun versionOf(tag: String): String {
        val dash = tag.indexOf('-')
        if (dash > 0 && isNumeric(tag.substring(0, dash))) return tag.substring(dash + 1)
        return tag.removePrefix("v")
    }

    fun compareVersions(a: String, b: String): Int {
        val av = a.split("-", limit = 2)
        val bv = b.split("-", limit = 2)

        val c = compareNumeric(av[0], bv[0])
        if (c != 0) return c

        val aPre = av.size > 1
        val bPre = bv.size > 1
        if (aPre != bPre) return if (aPre) -1 else 1
        if (!aPre) return 0
        return comparePrerelease(av[1], bv[1])
    }

    private fun compareNumeric(a: String, b: String): Int {
        val x = a.split(".")
        val y = b.split(".")
        for (i in 0 until maxOf(x.size, y.size)) {
            val c = part(x, i).compareTo(part(y, i))
            if (c != 0) return c
        }
        return 0
    }

    private fun comparePrerelease(a: String, b: String): Int {
        val x = a.split(".")
        val y = b.split(".")
        for (i in 0 until maxOf(x.size, y.size)) {
            val xi = x.getOrElse(i) { "" }
            val yi = y.getOrElse(i) { "" }
            if (xi == yi) continue
            if (xi.isEmpty()) return -1
            if (yi.isEmpty()) return 1
            val xn = isNumeric(xi)
            val yn = isNumeric(yi)
            if (xn && yn) return xi.toInt().compareTo(yi.toInt())
            if (xn != yn) return if (xn) -1 else 1
            return xi.compareTo(yi)
        }
        return 0
    }

    private fun isNumeric(s: String) = s.isNotEmpty() && s.all { it in '0'..'9' }

    private fun part(parts: List<String>, i: Int) =
        parts.getOrNull(i)?.trim()?.toIntOrNull() ?: 0

    private fun get(url: String): String {
        val c = open(url)
        try {
            val code = c.responseCode

            if (code == HttpURLConnection.HTTP_NOT_FOUND) {
                throw IOException("releases are not public (HTTP 404)")
            }
            if (code / 100 != 2) throw IOException("GitHub returned HTTP $code")
            return c.inputStream.use { it.readBytes().toString(Charsets.UTF_8) }
        } finally {
            c.disconnect()
        }
    }

    private fun open(url: String): HttpURLConnection {
        val c = URL(url).openConnection() as HttpURLConnection
        c.connectTimeout = TIMEOUT_MS
        c.readTimeout = TIMEOUT_MS
        c.instanceFollowRedirects = true
        c.setRequestProperty("Accept", "application/vnd.github+json")
        c.setRequestProperty("User-Agent", "VDExtra")
        return c
    }

    fun download(ctx: Context, r: Release): File {
        val out = File(ctx.cacheDir, "update.apk")
        val c = open(r.apkUrl)
        try {
            if (c.responseCode / 100 != 2) {
                throw IOException("download failed with HTTP ${c.responseCode}")
            }
            c.inputStream.use { input -> FileOutputStream(out).use { input.copyTo(it, 65536) } }
        } finally {
            c.disconnect()
        }
        if (out.length() == 0L) throw IOException("downloaded file is empty")
        if (r.apkSize > 0 && out.length() != r.apkSize) {
            throw IOException("download incomplete: ${out.length()} of ${r.apkSize} bytes")
        }
        return out
    }

    fun install(ctx: Context, apk: File, onSession: (Int) -> Unit) {
        val pi = ctx.packageManager.packageInstaller
        val params =
            PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        params.setAppPackageName(ctx.packageName)

        val sessionId = pi.createSession(params)
        onSession(sessionId)
        pi.openSession(sessionId).use { session ->
            FileInputStream(apk).use { input ->
                session.openWrite("vdextra", 0, apk.length()).use { out ->
                    input.copyTo(out, 65536)
                    session.fsync(out)
                }
            }
            val intent = Intent(INSTALL_ACTION).setPackage(ctx.packageName)
            val pending = PendingIntent.getBroadcast(
                ctx, sessionId, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
            )
            session.commit(pending.intentSender)
        }
    }

    fun canInstall(ctx: Context) = ctx.packageManager.canRequestPackageInstalls()

    fun settingsUriFor(ctx: Context): Uri = Uri.parse("package:" + ctx.packageName)
}
