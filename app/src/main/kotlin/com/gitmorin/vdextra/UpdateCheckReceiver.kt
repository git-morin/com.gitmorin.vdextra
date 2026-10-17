package com.gitmorin.vdextra

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

class UpdateCheckReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (ACTION != intent.action) return

        val prefs = context.getSharedPreferences(PrefKeys.NAME, Context.MODE_PRIVATE)
        val now = System.currentTimeMillis()
        val last = prefs.getLong(PrefKeys.LAST_UPDATE_CHECK, 0L)

        if (last > 0 && now - last < MIN_INTERVAL_MS && now >= last) {
            Log.i(TAG, "update check skipped, last was ${(now - last) / 60000} min ago")
            return
        }
        prefs.edit().putLong(PrefKeys.LAST_UPDATE_CHECK, now).apply()

        val pending = goAsync()
        Thread {
            try {
                checkForUpdate(context)
            } catch (t: Throwable) {
                prefs.edit()
                    .putLong(PrefKeys.LAST_UPDATE_CHECK, now - MIN_INTERVAL_MS + RETRY_AFTER_MS)
                    .apply()
                Log.w(
                    TAG,
                    "background update check failed, retrying in ${RETRY_AFTER_MS / 60000} min", t
                )
            } finally {
                pending.finish()
            }
        }.start()
    }

    private fun checkForUpdate(context: Context) {
        val channel = Updates.channelOf(
            context.getSharedPreferences(PrefKeys.NAME, Context.MODE_PRIVATE)
                .getString(PrefKeys.UPDATE_CHANNEL, Updates.STABLE)
        )
        val r = Updates.latest(channel)
        val current = context.packageManager.getPackageInfo(context.packageName, 0).versionName
        Log.i(
            TAG,
            "update check: channel=$channel installed=$current latest=${r?.version ?: "none"}"
        )
        if (r == null) return
        if (Updates.compareVersions(r.version, current) <= 0) return

        notifyAvailable(context, r.version)
        Log.i(TAG, "posted update notification for ${r.version}")
    }

    private fun notifyAvailable(context: Context, version: String) {
        val nm = context.getSystemService(NotificationManager::class.java) ?: return

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    context.getString(R.string.notif_channel_updates),
                    NotificationManager.IMPORTANCE_DEFAULT
                )
            )
        }

        val open = PendingIntent.getActivity(
            context, 0,
            Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val n = Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_module)
            .setContentTitle(context.getString(R.string.notif_update_title))
            .setContentText(context.getString(R.string.notif_update_text_format, version))
            .setContentIntent(open)
            .setAutoCancel(true)
            .build()

        try {
            nm.notify(NOTIFICATION_ID, n)
        } catch (t: Throwable) {
            Log.w(TAG, "could not post notification", t)
        }
    }

    internal companion object {
        const val ACTION = "com.gitmorin.vdextra.CHECK_FOR_UPDATE"

        private const val TAG = "VDExtra"

        private const val CHANNEL_ID = "updates"
        private const val NOTIFICATION_ID = 1
        private const val MIN_INTERVAL_MS = 6 * 60 * 60 * 1000L
        private const val RETRY_AFTER_MS = 15 * 60 * 1000L
    }
}
