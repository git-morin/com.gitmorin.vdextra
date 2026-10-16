package com.gitmorin.vdextra;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.util.Log;

public class MusicMissingReceiver extends BroadcastReceiver {

    static final String ACTION = "com.gitmorin.vdextra.MUSIC_MISSING";

    private static final String TAG = "VDExtra";
    private static final String CHANNEL_ID = "music";
    private static final int NOTIFICATION_ID = 2;

    @Override
    public void onReceive(Context context, Intent intent) {
        if (!ACTION.equals(intent.getAction())) return;

        String name = context.getSharedPreferences(PrefKeys.NAME, Context.MODE_PRIVATE)
                .getString(PrefKeys.MUSIC_NAME, null);
        Log.i(TAG, "custom music unreadable, VD music restored (was " + name + ")");

        // The choice is deliberately kept: the file may come back, and the module already falls
        // back on its own every launch, so there is nothing stale to clear.
        NotificationManager nm = context.getSystemService(NotificationManager.class);
        if (nm == null) return;

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(new NotificationChannel(
                    CHANNEL_ID,
                    context.getString(R.string.notif_channel_music),
                    NotificationManager.IMPORTANCE_DEFAULT));
        }

        PendingIntent open = PendingIntent.getActivity(
                context, 0,
                new Intent(context, MainActivity.class)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP),
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);

        Notification n = new Notification.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_module)
                .setContentTitle(context.getString(R.string.notif_music_missing_title))
                .setContentText(name != null
                        ? context.getString(R.string.notif_music_missing_text_format, name)
                        : context.getString(R.string.notif_music_missing_text))
                .setContentIntent(open)
                .setAutoCancel(true)
                .build();

        try {
            nm.notify(NOTIFICATION_ID, n);
        } catch (Throwable t) {
            Log.w(TAG, "could not post music notification", t);
        }
    }
}
