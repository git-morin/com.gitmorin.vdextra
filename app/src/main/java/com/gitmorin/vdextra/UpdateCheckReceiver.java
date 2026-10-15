package com.gitmorin.vdextra;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.os.Build;

/**
 * Checks for an update when Virtual Desktop starts, on behalf of the module running inside it.
 *
 * <p>The module broadcasts rather than checking in place: the work would otherwise happen under
 * Virtual Desktop's identity, so the notification would appear to come from Virtual Desktop and
 * would need Virtual Desktop to hold the notification permission.
 */
public class UpdateCheckReceiver extends BroadcastReceiver {

    static final String ACTION = "com.gitmorin.vdextra.CHECK_FOR_UPDATE";

    private static final String CHANNEL_ID = "updates";
    private static final int NOTIFICATION_ID = 1;
    private static final long MIN_INTERVAL_MS = 6 * 60 * 60 * 1000L;

    @Override
    public void onReceive(Context context, Intent intent) {
        if (!ACTION.equals(intent.getAction())) return;

        SharedPreferences prefs = context.getSharedPreferences(PrefKeys.NAME, Context.MODE_PRIVATE);
        long now = System.currentTimeMillis();
        long last = prefs.getLong(PrefKeys.LAST_UPDATE_CHECK, 0L);
        // Virtual Desktop can be restarted repeatedly while testing, and GitHub rate-limits
        // unauthenticated callers, so one check every few hours is plenty.
        if (last > 0 && now - last < MIN_INTERVAL_MS && now >= last) return;
        prefs.edit().putLong(PrefKeys.LAST_UPDATE_CHECK, now).apply();

        // Network cannot run on the receiver's thread, and the result arrives long after
        // onReceive would have returned, so hold the broadcast open.
        final PendingResult pending = goAsync();
        new Thread(() -> {
            try {
                check(context);
            } catch (Throwable ignored) {
                // A failed background check is not worth telling anyone about; the Options
                // screen reports failures when the user asks for a check themselves.
            } finally {
                pending.finish();
            }
        }).start();
    }

    private void check(Context context) throws Exception {
        String channel = Updates.channelOf(
                context.getSharedPreferences(PrefKeys.NAME, Context.MODE_PRIVATE)
                        .getString(PrefKeys.UPDATE_CHANNEL, Updates.STABLE));
        Updates.Release r = Updates.latest(channel);
        if (r == null) return;

        String current = context.getPackageManager()
                .getPackageInfo(context.getPackageName(), 0).versionName;
        if (Updates.compareVersions(r.version, current) <= 0) return;

        notifyAvailable(context, r.version);
    }

    private void notifyAvailable(Context context, String version) {
        NotificationManager nm = context.getSystemService(NotificationManager.class);
        if (nm == null) return;

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(new NotificationChannel(
                    CHANNEL_ID,
                    context.getString(R.string.notif_channel_updates),
                    NotificationManager.IMPORTANCE_DEFAULT));
        }

        PendingIntent open = PendingIntent.getActivity(
                context, 0,
                new Intent(context, MainActivity.class)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP),
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);

        Notification n = new Notification.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_module)
                .setContentTitle(context.getString(R.string.notif_update_title))
                .setContentText(context.getString(R.string.notif_update_text_format, version))
                .setContentIntent(open)
                .setAutoCancel(true)
                .build();

        try {
            nm.notify(NOTIFICATION_ID, n);
        } catch (Throwable ignored) {
            // Notifications may simply be denied; nothing to recover.
        }
    }
}
