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

class MusicMissingReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (ACTION != intent.action) return

        val name = context.getSharedPreferences(PrefKeys.NAME, Context.MODE_PRIVATE)
            .getString(PrefKeys.MUSIC_NAME, null)
        Log.i(TAG, "custom music unreadable, VD music restored (was $name)")

        val nm = context.getSystemService(NotificationManager::class.java) ?: return

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    context.getString(R.string.notif_channel_music),
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
            .setContentTitle(context.getString(R.string.notif_music_missing_title))
            .setContentText(
                if (name != null) {
                    context.getString(R.string.notif_music_missing_text_format, name)
                } else {
                    context.getString(R.string.notif_music_missing_text)
                }
            )
            .setContentIntent(open)
            .setAutoCancel(true)
            .build()

        try {
            nm.notify(NOTIFICATION_ID, n)
        } catch (t: Throwable) {
            Log.w(TAG, "could not post music notification", t)
        }
    }

    internal companion object {
        const val ACTION = "com.gitmorin.vdextra.MUSIC_MISSING"

        private const val TAG = "VDExtra"
        private const val CHANNEL_ID = "music"
        private const val NOTIFICATION_ID = 2
    }
}
