package com.gitmorin.vdextra;

import android.content.Context;
import android.content.Intent;
import android.media.AudioAttributes;
import android.media.MediaPlayer;
import android.util.Log;

import java.io.File;

// Runs inside Virtual Desktop. The Mono hooks only record what VD's own music is doing, in an
// atomic the poll loop below reads, so no audio call ever happens on a Mono thread.
final class MusicPlayer {

    private static final String TAG = "VDExtra";
    private static final int IDLE = 0, PLAYING = 1, PAUSED = 2;

    private static Thread sThread;

    private MusicPlayer() {
    }

    static synchronized void start(String path, float volume) {
        if (sThread != null) return;
        sThread = new Thread(() -> run(path, volume), "vdextra-music");
        sThread.setDaemon(true);
        sThread.start();
    }

    private static boolean isStream(String target) {
        return target.startsWith("http://") || target.startsWith("https://");
    }

    private static String resolve(String source) {
        if (isStream(source)) return source;
        if (new File(source).canRead()) return source;
        Log.w(TAG, "custom music gone: " + source);
        return null;
    }

    private static MediaPlayer open(String target, float volume) {
        MediaPlayer mp = new MediaPlayer();
        try {
            mp.setAudioAttributes(new AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build());
            mp.setDataSource(target);
            mp.setLooping(!isStream(target));   // a live stream has no end to loop
            mp.setVolume(volume, volume);
            mp.prepare();
            return mp;
        } catch (Throwable t) {
            Log.w(TAG, "could not open " + target, t);
            close(mp);
            return null;
        }
    }

    private static void close(MediaPlayer mp) {
        if (mp == null) return;
        try { mp.release(); } catch (Throwable ignored) { }
    }

    private static void run(String source, float volume) {
        Context ctx = awaitContext();
        if (ctx == null) {
            Log.w(TAG, "custom music: no context, falling back to VD");
            giveUp(null);
            return;
        }

        String target = resolve(source);
        if (target == null) {
            giveUp(ctx);
            return;
        }
        boolean stream = isStream(target);
        MediaPlayer mp = open(target, volume);
        if (mp == null) {
            giveUp(ctx);
            return;
        }
        Log.i(TAG, "custom music ready: " + target + " volume=" + volume);

        int applied = IDLE;
        while (true) {
            int want;
            try { want = MainModule.nativeMusicState(); } catch (Throwable t) { break; }
            if (want != applied) {
                try {
                    if (want == PLAYING) {
                        // recreated rather than resumed: a paused live buffer comes back stale
                        if (mp == null) mp = open(target, volume);
                        if (mp != null && !mp.isPlaying()) mp.start();
                    } else if (want == PAUSED && mp != null) {
                        if (stream) {
                            close(mp);
                            mp = null;
                        } else if (mp.isPlaying()) {
                            mp.pause();
                        }
                    }
                    applied = want;
                } catch (Throwable t) {
                    Log.w(TAG, "custom music transition failed", t);
                    break;
                }
            }
            try { Thread.sleep(200); } catch (InterruptedException e) { break; }
        }
        close(mp);
    }

    // Un-mute VD's own track, then tell the app so it can say why.
    private static void giveUp(Context ctx) {
        try { MainModule.nativeSetCustomMusic(false); } catch (Throwable ignored) { }
        if (ctx == null) return;
        try {
            ctx.sendBroadcast(new Intent(MusicMissingReceiver.ACTION)
                    .setClassName(BuildConfig.APPLICATION_ID, MusicMissingReceiver.class.getName())
                    .addFlags(Intent.FLAG_INCLUDE_STOPPED_PACKAGES));
        } catch (Throwable t) {
            Log.w(TAG, "could not report missing music", t);
        }
    }

    private static Context awaitContext() {
        for (int i = 0; i < 30; i++) {
            try {
                Object app = Class.forName("android.app.ActivityThread")
                        .getMethod("currentApplication").invoke(null);
                if (app instanceof Context) return (Context) app;
            } catch (Throwable t) {
                return null;
            }
            try { Thread.sleep(1000); } catch (InterruptedException e) { return null; }
        }
        return null;
    }
}
