package com.gitmorin.vdextra;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.SharedPreferences;
import android.content.pm.PackageInstaller;
import android.database.Cursor;
import android.graphics.Color;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.provider.OpenableColumns;
import android.provider.Settings;
import android.view.LayoutInflater;
import android.view.View;
import android.widget.EditText;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

import androidx.activity.result.ActivityResultLauncher;
import androidx.activity.result.contract.ActivityResultContracts;
import androidx.appcompat.app.AppCompatActivity;

import com.google.android.material.appbar.MaterialToolbar;
import com.google.android.material.bottomnavigation.BottomNavigationView;
import com.google.android.material.card.MaterialCardView;
import com.google.android.material.color.MaterialColors;
import com.google.android.material.dialog.MaterialAlertDialogBuilder;
import com.google.android.material.materialswitch.MaterialSwitch;
import com.google.android.material.slider.Slider;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

import io.github.libxposed.service.XposedService;
import io.github.libxposed.service.XposedServiceHelper;

public class MainActivity extends AppCompatActivity {

    private static volatile XposedService sService = null;
    private static MainActivity sCurrent = null;
    private static boolean sRegistered = false;
    private static final XposedServiceHelper.OnServiceListener sListener = new XposedServiceHelper.OnServiceListener() {
        @Override public void onServiceBind(XposedService service) { sService = service; notifyServiceChanged(); }
        @Override public void onServiceDied(XposedService service) { sService = null; notifyServiceChanged(); }
    };

    private boolean binding = false;

    private MaterialToolbar toolbar;
    private BottomNavigationView bottomNav;
    private View pageHome, pageOptions;
    private MaterialCardView homeStatus;
    private ImageView homeStatusIcon;
    private TextView homeStatusText, homeStatusSub;
    private View rowLanguage, rowChannel, rowUpdate, rowMusicSource;
    private TextView langValue, channelValue, updateValue;
    private Updates.Release pendingUpdate;
    private boolean updateBusy;
    private boolean installReceiverRegistered;
    private int installSessionId = -1;
    private LinearLayout homeInfoSystem, homeInfoDict;
    private MaterialSwitch swNoPerf, swExtend, swUnlock, swForceLan;
    private Slider slMusicVolume;
    private TextView musicVolumeValue, musicSourceValue;
    private ActivityResultLauncher<String[]> pickMusic;

    private static void ensureServiceRegistered() {
        if (sRegistered) return;
        sRegistered = true;
        try { XposedServiceHelper.registerListener(sListener); } catch (Throwable t) { sRegistered = false; }
    }

    private static void notifyServiceChanged() {
        MainActivity a = sCurrent;
        if (a != null) a.runOnUiThread(a::refresh);
    }

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        setContentView(R.layout.activity_main);

        toolbar = findViewById(R.id.toolbar);
        bottomNav = findViewById(R.id.bottom_nav);
        pageHome = findViewById(R.id.page_home);
        pageOptions = findViewById(R.id.page_options);
        homeStatus = findViewById(R.id.home_status);
        homeStatusIcon = findViewById(R.id.home_status_icon);
        homeStatusText = findViewById(R.id.home_status_text);
        homeStatusSub = findViewById(R.id.home_status_sub);
        homeInfoSystem = findViewById(R.id.home_info_system);
        homeInfoDict = findViewById(R.id.home_info_dict);
        rowLanguage = findViewById(R.id.row_language);
        langValue = findViewById(R.id.lang_value);
        rowChannel = findViewById(R.id.row_channel);
        channelValue = findViewById(R.id.channel_value);
        rowUpdate = findViewById(R.id.row_update);
        updateValue = findViewById(R.id.update_value);
        slMusicVolume = findViewById(R.id.sl_music_volume);
        musicVolumeValue = findViewById(R.id.music_volume_value);
        rowMusicSource = findViewById(R.id.row_music_source);
        musicSourceValue = findViewById(R.id.music_source_value);
        swNoPerf = findViewById(R.id.sw_no_perf);
        swExtend = findViewById(R.id.sw_extend);
        swUnlock = findViewById(R.id.sw_unlock);
        swForceLan = findViewById(R.id.sw_force_lan);

        bottomNav.setOnItemSelectedListener(item -> {
            showPage(item.getItemId() == R.id.nav_options ? 1 : 0);
            return true;
        });

        slMusicVolume.addOnChangeListener((sl, value, fromUser) -> {
            musicVolumeValue.setText(getString(R.string.music_volume_format, (int) value));
            save(PrefKeys.MUSIC_VOLUME, value / 100f);
        });
        swNoPerf.setOnCheckedChangeListener((v, c) -> save(PrefKeys.DISABLE_QUALITY_SOUND, c));
        swExtend.setOnCheckedChangeListener((v, c) -> save(PrefKeys.BITRATE_EXTEND, c));
        swUnlock.setOnCheckedChangeListener((v, c) -> save(PrefKeys.BITRATE_UNLOCK, c));
        swForceLan.setOnCheckedChangeListener((v, c) -> save(PrefKeys.FORCE_LAN, c));
        swNoPerf.setOnLongClickListener(v -> { showSoundDialog(); return true; });
        swExtend.setOnLongClickListener(v -> { showScaleDialog(); return true; });
        findViewById(R.id.row_no_perf).setOnLongClickListener(v -> { showSoundDialog(); return true; });
        findViewById(R.id.row_extend).setOnLongClickListener(v -> { showScaleDialog(); return true; });

        rowMusicSource.setOnClickListener(v -> showMusicSourceDialog());
        rowLanguage.setOnClickListener(v -> showLanguageDialog());
        rowChannel.setOnClickListener(v -> showChannelDialog());
        rowUpdate.setOnClickListener(v -> onUpdateRowClicked());

        pickMusic = registerForActivityResult(
                new ActivityResultContracts.OpenDocument(), this::onMusicPicked);

        ensureServiceRegistered();
        askForNotificationsIfNeeded();
        showPage(0);
        refresh();
    }

    private void askForNotificationsIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return;
        if (checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS)
                == android.content.pm.PackageManager.PERMISSION_GRANTED) return;
        try {
            requestPermissions(new String[]{ android.Manifest.permission.POST_NOTIFICATIONS }, 1);
        } catch (Throwable ignored) {}
    }

    @Override protected void onResume() {
        super.onResume();
        sCurrent = this;
        if (sService == null) { try { XposedServiceHelper.registerListener(sListener); } catch (Throwable ignored) {} }
        ensureServiceRegistered();
        refresh();
    }

    @Override protected void onPause() {
        if (sCurrent == this) sCurrent = null;
        super.onPause();
    }

    @Override protected void onDestroy() {
        unregisterInstallReceiver();
        super.onDestroy();
    }

    private void registerInstallReceiver() {
        if (installReceiverRegistered) return;
        IntentFilter f = new IntentFilter(Updates.installAction());
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            getApplicationContext().registerReceiver(installReceiver, f, Context.RECEIVER_NOT_EXPORTED);
        } else {
            getApplicationContext().registerReceiver(installReceiver, f);
        }
        installReceiverRegistered = true;
    }

    private void unregisterInstallReceiver() {
        if (!installReceiverRegistered) return;
        installReceiverRegistered = false;
        try { getApplicationContext().unregisterReceiver(installReceiver); } catch (Throwable ignored) {}
    }

    private void showPage(int p) {
        pageHome.setVisibility(p == 0 ? View.VISIBLE : View.GONE);
        pageOptions.setVisibility(p == 1 ? View.VISIBLE : View.GONE);
        toolbar.setTitle(p == 0 ? getString(R.string.app_name) : getString(R.string.nav_options));
        if (p == 0) refresh();
    }

    private void refresh() {
        boolean active = sService != null;

        int container = MaterialColors.getColor(this,
                active ? com.google.android.material.R.attr.colorPrimaryContainer
                       : com.google.android.material.R.attr.colorErrorContainer,
                active ? Color.parseColor("#EADDFF") : Color.parseColor("#F9DEDC"));
        int on = MaterialColors.getColor(this,
                active ? com.google.android.material.R.attr.colorOnPrimaryContainer
                       : com.google.android.material.R.attr.colorOnErrorContainer,
                active ? Color.parseColor("#21005D") : Color.parseColor("#410E0B"));

        homeStatus.setCardBackgroundColor(container);
        homeStatusIcon.setImageResource(active ? R.drawable.ic_check_circle : R.drawable.ic_warning);
        homeStatusIcon.setColorFilter(on);
        homeStatusText.setText(active ? R.string.status_active : R.string.status_inactive);
        homeStatusText.setTextColor(on);
        homeStatusSub.setTextColor(on);
        homeStatusSub.setText(active ? "" : getString(R.string.status_inactive_hint));
        homeStatusSub.setVisibility(active ? View.GONE : View.VISIBLE);

        SharedPreferences p = getSharedPreferences(PrefKeys.NAME, MODE_PRIVATE);

        homeInfoSystem.removeAllViews();
        addInfo(homeInfoSystem, R.drawable.ic_module, getString(R.string.info_module_version), version(getPackageName()));
        addInfo(homeInfoSystem, R.drawable.ic_app, getString(R.string.info_vd_version), vdVersion());

        String lang = currentLanguage();
        langValue.setText(languageLabel(lang));

        channelValue.setText(channelLabel(currentChannel()));
        if (!updateBusy && pendingUpdate == null) {
            updateValue.setText(getString(R.string.update_current_format, version(getPackageName())));
        }

        homeInfoDict.removeAllViews();
        addInfo(homeInfoDict, R.drawable.ic_dict, getString(R.string.dict_language_title), languageSummary(lang));

        binding = true;
        String musicName = p.getString(PrefKeys.MUSIC_NAME, null);
        musicSourceValue.setText(p.getString(PrefKeys.MUSIC_URI, null) == null
                ? getString(R.string.music_source_vd)
                : (musicName != null ? musicName : getString(R.string.music_source_custom)));

        int vol = Math.round(p.getFloat(PrefKeys.MUSIC_VOLUME, 1.0f) * 100f);
        slMusicVolume.setValue(Math.max(0, Math.min(100, vol)));
        musicVolumeValue.setText(getString(R.string.music_volume_format, vol));
        swNoPerf.setChecked(p.getBoolean(PrefKeys.DISABLE_QUALITY_SOUND, false));
        swExtend.setChecked(p.getBoolean(PrefKeys.BITRATE_EXTEND, false));
        swUnlock.setChecked(p.getBoolean(PrefKeys.BITRATE_UNLOCK, false));
        swForceLan.setChecked(p.getBoolean(PrefKeys.FORCE_LAN, true));
        binding = false;
    }

    private void addInfo(LinearLayout box, int iconRes, String label, String value) {
        View row = LayoutInflater.from(this).inflate(R.layout.item_info, box, false);
        ImageView icon = row.findViewById(R.id.info_icon);
        icon.setImageResource(iconRes);
        icon.setColorFilter(MaterialColors.getColor(this,
                com.google.android.material.R.attr.colorPrimary, Color.parseColor("#6750A4")));
        ((TextView) row.findViewById(R.id.info_label)).setText(label);
        ((TextView) row.findViewById(R.id.info_value)).setText(value);
        box.addView(row);
    }

    private void save(String key, Object value) {
        if (binding) return;
        put(getSharedPreferences(PrefKeys.NAME, MODE_PRIVATE).edit(), key, value).apply();
        if (sService != null) {
            try { put(sService.getRemotePreferences(PrefKeys.NAME).edit(), key, value).commit(); } catch (Throwable ignored) {}
        }
    }

    private static SharedPreferences.Editor put(SharedPreferences.Editor e, String key, Object v) {
        if (v == null) e.remove(key);
        else if (v instanceof Boolean) e.putBoolean(key, (Boolean) v);
        else if (v instanceof Integer) e.putInt(key, (Integer) v);
        else if (v instanceof Float) e.putFloat(key, (Float) v);
        else if (v instanceof Long) e.putLong(key, (Long) v);
        else e.putString(key, String.valueOf(v));
        return e;
    }

    private void showSoundDialog() {
        View v = LayoutInflater.from(this).inflate(R.layout.dialog_sounds, null);
        int[] ids = {R.id.snd0, R.id.snd1, R.id.snd2, R.id.snd3, R.id.snd4, R.id.snd5, R.id.snd6};
        MaterialSwitch[] sw = new MaterialSwitch[ids.length];
        int mask = getSharedPreferences(PrefKeys.NAME, MODE_PRIVATE).getInt(PrefKeys.QUALITY_MASK, 0x7F);
        for (int i = 0; i < ids.length; i++) {
            sw[i] = v.findViewById(ids[i]);
            sw[i].setChecked((mask & (1 << i)) != 0);
        }
        new MaterialAlertDialogBuilder(this)
                .setTitle(R.string.dialog_sounds_title)
                .setView(v)
                .setPositiveButton(R.string.action_done, null)
                .setOnDismissListener(dd -> {
                    int m = 0;
                    for (int i = 0; i < sw.length; i++) if (sw[i].isChecked()) m |= (1 << i);
                    save(PrefKeys.QUALITY_MASK, m);
                })
                .show();
    }

    private void showScaleDialog() {
        View v = LayoutInflater.from(this).inflate(R.layout.dialog_scale, null);
        EditText in = v.findViewById(R.id.scale_input);
        in.setText(formatScale(getSharedPreferences(PrefKeys.NAME, MODE_PRIVATE).getFloat(PrefKeys.BITRATE_SCALE, 2.0f)));
        new MaterialAlertDialogBuilder(this)
                .setTitle(R.string.dialog_scale_title)
                .setView(v)
                .setPositiveButton(R.string.action_done, null)
                .setOnDismissListener(dd -> {
                    float s;
                    try { s = Float.parseFloat(in.getText().toString().trim()); } catch (Throwable t) { s = 2.0f; }
                    if (s < 1f) s = 1f;
                    if (s > 3f) s = 3f;
                    save(PrefKeys.BITRATE_SCALE, s);
                })
                .show();
    }

    private String version(String pkg) {
        try { return getPackageManager().getPackageInfo(pkg, 0).versionName; }
        catch (Throwable t) { return "—"; }
    }

    private String vdVersion() {
        for (String pkg : VdTarget.PACKAGES) {
            try { return getPackageManager().getPackageInfo(pkg, 0).versionName; }
            catch (Throwable ignored) {}
        }
        return getString(R.string.version_not_installed);
    }

    private void showMusicSourceDialog() {
        String[] labels = {
                getString(R.string.music_source_vd),
                getString(R.string.music_source_pick),
        };
        boolean custom = getSharedPreferences(PrefKeys.NAME, MODE_PRIVATE)
                .getString(PrefKeys.MUSIC_URI, null) != null;
        new MaterialAlertDialogBuilder(this)
                .setTitle(R.string.dialog_music_source_title)
                .setSingleChoiceItems(labels, custom ? 1 : 0, (d, which) -> {
                    d.dismiss();
                    if (which == 0) {
                        save(PrefKeys.MUSIC_URI, null);
                        save(PrefKeys.MUSIC_NAME, null);
                        refresh();
                        Toast.makeText(this, R.string.toast_music_vd, Toast.LENGTH_LONG).show();
                        return;
                    }
                    try {
                        pickMusic.launch(new String[]{ "audio/*" });
                    } catch (Throwable t) {
                        Toast.makeText(this, R.string.toast_music_no_picker, Toast.LENGTH_LONG).show();
                    }
                })
                .show();
    }

    private void onMusicPicked(Uri uri) {
        if (uri == null) return;
        try {
            getContentResolver().takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION);
        } catch (Throwable t) {
            Toast.makeText(this, R.string.toast_music_no_access, Toast.LENGTH_LONG).show();
            return;
        }
        save(PrefKeys.MUSIC_URI, uri.toString());
        save(PrefKeys.MUSIC_NAME, displayName(uri));
        refresh();
        Toast.makeText(this, getString(R.string.toast_music_format, displayName(uri)),
                Toast.LENGTH_LONG).show();
    }

    private String displayName(Uri uri) {
        try (Cursor c = getContentResolver().query(uri, null, null, null, null)) {
            if (c != null && c.moveToFirst()) {
                int i = c.getColumnIndex(OpenableColumns.DISPLAY_NAME);
                if (i >= 0 && !c.isNull(i)) return c.getString(i);
            }
        } catch (Throwable ignored) { }
        String last = uri.getLastPathSegment();
        return last != null ? last : uri.toString();
    }

    private void showLanguageDialog() {
        List<String> tags = new ArrayList<>();
        tags.add(Languages.OFF);
        tags.addAll(Languages.available(getAssets()));

        String current = currentLanguage();
        String[] labels = new String[tags.size()];
        int checked = 0;
        for (int i = 0; i < tags.size(); i++) {
            String tag = tags.get(i);
            labels[i] = languageSummary(tag);
            if (tag.equals(current)) checked = i;
        }

        new MaterialAlertDialogBuilder(this)
                .setTitle(R.string.dialog_language_title)
                .setSingleChoiceItems(labels, checked, (d, which) -> {
                    String tag = tags.get(which);
                    save(PrefKeys.UI_LANGUAGE, tag);
                    d.dismiss();
                    refresh();
                    Toast.makeText(this, getString(R.string.toast_language_format, languageLabel(tag)),
                            Toast.LENGTH_LONG).show();
                })
                .show();
    }

    private String currentChannel() {
        return Updates.channelOf(getSharedPreferences(PrefKeys.NAME, MODE_PRIVATE)
                .getString(PrefKeys.UPDATE_CHANNEL, Updates.STABLE));
    }

    private String channelLabel(String channel) {
        return getString(Updates.DEV.equals(channel)
                ? R.string.update_channel_dev : R.string.update_channel_stable);
    }

    private void showChannelDialog() {
        String[] channels = { Updates.STABLE, Updates.DEV };
        String[] labels = { channelLabel(Updates.STABLE), channelLabel(Updates.DEV) };
        int checked = Updates.DEV.equals(currentChannel()) ? 1 : 0;
        new MaterialAlertDialogBuilder(this)
                .setTitle(R.string.dialog_channel_title)
                .setSingleChoiceItems(labels, checked, (d, which) -> {
                    save(PrefKeys.UPDATE_CHANNEL, channels[which]);

                    pendingUpdate = null;
                    d.dismiss();
                    refresh();
                })
                .show();
    }

    private void onUpdateRowClicked() {
        if (updateBusy) return;
        if (pendingUpdate != null) startInstall(pendingUpdate);
        else checkForUpdate();
    }

    private void checkForUpdate() {
        updateBusy = true;
        updateValue.setText(R.string.update_checking);
        String channel = currentChannel();
        String current = version(getPackageName());
        new Thread(() -> {
            try {
                Updates.Release r = Updates.latest(channel);
                boolean newer = r != null && Updates.compareVersions(r.version, current) > 0;
                runOnUiThread(() -> {
                    updateBusy = false;
                    pendingUpdate = newer ? r : null;
                    updateValue.setText(newer
                            ? getString(R.string.update_available_format, r.version)
                            : getString(R.string.update_up_to_date));
                });
            } catch (Throwable t) {
                runOnUiThread(() -> {
                    updateBusy = false;
                    pendingUpdate = null;
                    updateValue.setText(getString(R.string.update_failed_format, reason(t)));
                });
            }
        }).start();
    }

    private void startInstall(Updates.Release r) {

        if (!Updates.canInstall(this)) {
            Toast.makeText(this, R.string.update_needs_permission, Toast.LENGTH_LONG).show();
            try {
                startActivity(new Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                        Updates.settingsUriFor(this)));
            } catch (Throwable ignored) {}
            return;
        }
        updateBusy = true;
        registerInstallReceiver();
        updateValue.setText(R.string.update_downloading);
        new Thread(() -> {
            try {
                File apk = Updates.download(this, r);
                runOnUiThread(() -> updateValue.setText(R.string.update_installing));
                Updates.install(this, apk, id -> installSessionId = id);
            } catch (Throwable t) {
                runOnUiThread(() -> {
                    updateBusy = false;
                    unregisterInstallReceiver();
                    updateValue.setText(getString(R.string.update_failed_format, reason(t)));
                });
            }
        }).start();
    }

    private static String reason(Throwable t) {
        String m = t.getMessage();
        return (m == null || m.isEmpty()) ? t.getClass().getSimpleName() : m;
    }

    private final BroadcastReceiver installReceiver = new BroadcastReceiver() {
        @Override public void onReceive(Context c, Intent i) {
            int session = i.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1);
            if (installSessionId < 0 || session != installSessionId) return;
            int status = i.getIntExtra(PackageInstaller.EXTRA_STATUS, -1);
            if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
                Intent confirm = i.getParcelableExtra(Intent.EXTRA_INTENT);
                if (confirm != null) {
                    confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                    try { startActivity(confirm); } catch (Throwable ignored) {}
                }
            } else if (status == PackageInstaller.STATUS_SUCCESS) {
                pendingUpdate = null;
                updateBusy = false;
                installSessionId = -1;
                unregisterInstallReceiver();
                Toast.makeText(MainActivity.this, R.string.update_restart_hint, Toast.LENGTH_LONG).show();
                refresh();
            } else {
                updateBusy = false;
                installSessionId = -1;
                unregisterInstallReceiver();
                String m = i.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE);
                updateValue.setText(getString(R.string.update_failed_format,
                        m == null ? String.valueOf(status) : m));
            }
        }
    };

    private String currentLanguage() {
        String v = getSharedPreferences(PrefKeys.NAME, MODE_PRIVATE)
                .getString(PrefKeys.UI_LANGUAGE, null);
        return v != null ? v : Languages.systemDefault(Languages.available(getAssets()));
    }

    private String languageLabel(String tag) {
        return Languages.isOff(tag) ? getString(R.string.lang_off) : Languages.displayName(tag);
    }

    private String languageSummary(String tag) {
        return Languages.isOff(tag) ? getString(R.string.lang_off)
                : getString(R.string.lang_entry_format, Languages.displayName(tag), bundledCount(tag));
    }

    private int bundledCount(String tag) {
        if (Languages.isOff(tag)) return 0;
        try (var in = getAssets().open(Languages.assetPath(tag))) {
            return DictJson.count(new String(DictJson.readAll(in), StandardCharsets.UTF_8));
        } catch (Throwable t) { return 0; }
    }

    private static String formatScale(float s) {
        if (s == Math.round(s)) return String.valueOf((int) s);
        return String.format(Locale.getDefault(), "%.2f", s);
    }
}
