package com.gitmorin.vdextra

import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.util.Log
import java.io.File

internal object MusicPlayer {

    private const val TAG = "VDExtra"
    private const val IDLE = 0
    private const val PLAYING = 1
    private const val PAUSED = 2

    private var thread: Thread? = null

    @Synchronized
    fun start(module: MainModule, path: String, volume: Float) {
        if (thread != null) return
        val t = Thread({ run(module, path, volume) }, "vdextra-music")
        t.isDaemon = true
        thread = t
        t.start()
    }

    private fun isStream(target: String) =
        target.startsWith("http://") || target.startsWith("https://")

    private fun resolve(source: String): String? {
        if (isStream(source)) return source
        if (File(source).canRead()) return source
        Log.w(TAG, "custom music gone: $source")
        return null
    }

    private fun open(target: String, volume: Float): MediaPlayer? {
        val mp = MediaPlayer()
        return try {
            mp.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build()
            )
            mp.setDataSource(target)
            mp.isLooping = !isStream(target)
            mp.setVolume(volume, volume)
            mp.prepare()
            mp
        } catch (t: Throwable) {
            Log.w(TAG, "could not open $target", t)
            close(mp)
            null
        }
    }

    private fun close(mp: MediaPlayer?) {
        if (mp == null) return
        try {
            mp.release()
        } catch (ignored: Throwable) {
        }
    }

    private fun syncVolume(module: MainModule, mp: MediaPlayer?, current: Float): Float {
        val want = try {
            module.nativeMusicVolume()
        } catch (t: Throwable) {
            return current
        }
        if (want == current) return current
        try {
            mp?.setVolume(want, want)
        } catch (t: Throwable) {
            Log.w(TAG, "custom music volume failed", t)
        }
        return want
    }

    private fun run(module: MainModule, source: String, volume: Float) {
        val ctx = awaitContext()
        if (ctx == null) {
            Log.w(TAG, "custom music: no context, falling back to VD")
            giveUp(module, null)
            return
        }

        val target = resolve(source)
        if (target == null) {
            giveUp(module, ctx)
            return
        }
        val stream = isStream(target)
        var vol = volume
        var mp: MediaPlayer? = open(target, vol)
        if (mp == null) {
            giveUp(module, ctx)
            return
        }
        Log.i(TAG, "custom music ready: $target volume=$vol")

        var applied = IDLE
        while (true) {
            val want = try {
                module.nativeMusicState()
            } catch (t: Throwable) {
                break
            }
            if (want != applied) {
                try {
                    if (want == PLAYING) {
                        if (mp == null) mp = open(target, vol)
                        mp?.let { if (!it.isPlaying) it.start() }
                    } else if (want == PAUSED && mp != null) {
                        if (stream) {
                            close(mp)
                            mp = null
                        } else if (mp.isPlaying) {
                            mp.pause()
                        }
                    }
                    applied = want
                } catch (t: Throwable) {
                    Log.w(TAG, "custom music transition failed", t)
                    break
                }
            }
            vol = syncVolume(module, mp, vol)
            try {
                Thread.sleep(200)
            } catch (e: InterruptedException) {
                break
            }
        }
        close(mp)
    }

    private fun giveUp(module: MainModule, ctx: Context?) {
        try {
            module.nativeSetCustomMusic(false)
        } catch (ignored: Throwable) {
        }
        if (ctx == null) return
        try {
            ctx.sendBroadcast(
                Intent(MusicMissingReceiver.ACTION)
                    .setClassName(
                        BuildConfig.APPLICATION_ID,
                        MusicMissingReceiver::class.java.name
                    )
                    .addFlags(Intent.FLAG_INCLUDE_STOPPED_PACKAGES)
            )
        } catch (t: Throwable) {
            Log.w(TAG, "could not report missing music", t)
        }
    }

    private fun awaitContext(): Context? {
        repeat(30) {
            try {
                val app = Class.forName("android.app.ActivityThread")
                    .getMethod("currentApplication").invoke(null)
                if (app is Context) return app
            } catch (t: Throwable) {
                return null
            }
            try {
                Thread.sleep(1000)
            } catch (e: InterruptedException) {
                return null
            }
        }
        return null
    }
}
