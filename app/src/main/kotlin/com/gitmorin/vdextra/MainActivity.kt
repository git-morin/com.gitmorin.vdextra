package com.gitmorin.vdextra

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.SharedPreferences
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.Settings
import android.view.LayoutInflater
import android.view.View
import android.widget.EditText
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import com.google.android.material.appbar.MaterialToolbar
import com.google.android.material.bottomnavigation.BottomNavigationView
import com.google.android.material.card.MaterialCardView
import com.google.android.material.color.MaterialColors
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.google.android.material.materialswitch.MaterialSwitch
import com.google.android.material.slider.Slider
import com.google.android.material.textfield.TextInputLayout
import io.github.libxposed.service.XposedService
import io.github.libxposed.service.XposedServiceHelper
import java.io.File
import java.util.Locale
import kotlin.math.floor
import kotlin.math.roundToInt

class MainActivity : AppCompatActivity() {

    private var binding = false

    private lateinit var toolbar: MaterialToolbar
    private lateinit var pageHome: View
    private lateinit var pageOptions: View
    private lateinit var homeStatus: MaterialCardView
    private lateinit var homeStatusIcon: ImageView
    private lateinit var homeStatusText: TextView
    private lateinit var homeStatusSub: TextView
    private lateinit var langValue: TextView
    private lateinit var channelValue: TextView
    private lateinit var updateValue: TextView
    private var pendingUpdate: Updates.Release? = null
    private var updateBusy = false
    private var installReceiverRegistered = false
    private var installSessionId = -1
    private lateinit var homeInfoSystem: LinearLayout
    private lateinit var homeInfoDict: LinearLayout
    private lateinit var swNoPerf: MaterialSwitch
    private lateinit var swExtend: MaterialSwitch
    private lateinit var swUnlock: MaterialSwitch
    private lateinit var swForceLan: MaterialSwitch
    private lateinit var swTextRoom: MaterialSwitch
    private lateinit var slMusicVolume: Slider
    private lateinit var musicVolumeValue: TextView
    private lateinit var musicSourceValue: TextView
    private lateinit var aboutValue: TextView
    private lateinit var pickMusic: ActivityResultLauncher<Array<String>>

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        setContentView(R.layout.activity_main)

        toolbar = findViewById(R.id.toolbar)
        pageHome = findViewById(R.id.page_home)
        pageOptions = findViewById(R.id.page_options)
        homeStatus = findViewById(R.id.home_status)
        homeStatusIcon = findViewById(R.id.home_status_icon)
        homeStatusText = findViewById(R.id.home_status_text)
        homeStatusSub = findViewById(R.id.home_status_sub)
        homeInfoSystem = findViewById(R.id.home_info_system)
        homeInfoDict = findViewById(R.id.home_info_dict)
        langValue = findViewById(R.id.lang_value)
        channelValue = findViewById(R.id.channel_value)
        updateValue = findViewById(R.id.update_value)
        slMusicVolume = findViewById(R.id.sl_music_volume)
        musicVolumeValue = findViewById(R.id.music_volume_value)
        musicSourceValue = findViewById(R.id.music_source_value)
        aboutValue = findViewById(R.id.about_value)
        swNoPerf = findViewById(R.id.sw_no_perf)
        swExtend = findViewById(R.id.sw_extend)
        swUnlock = findViewById(R.id.sw_unlock)
        swForceLan = findViewById(R.id.sw_force_lan)
        swTextRoom = findViewById(R.id.sw_text_room)

        findViewById<BottomNavigationView>(R.id.bottom_nav).setOnItemSelectedListener { item ->
            showPage(if (item.itemId == R.id.nav_options) 1 else 0)
            true
        }

        slMusicVolume.addOnChangeListener { _, value, _ ->
            musicVolumeValue.text = getString(R.string.music_volume_format, value.toInt())
            save(PrefKeys.MUSIC_VOLUME, value / 100f)
        }
        swNoPerf.setOnCheckedChangeListener { _, c -> save(PrefKeys.DISABLE_QUALITY_SOUND, c) }
        swExtend.setOnCheckedChangeListener { _, c -> save(PrefKeys.BITRATE_EXTEND, c) }
        swUnlock.setOnCheckedChangeListener { _, c -> save(PrefKeys.BITRATE_UNLOCK, c) }
        swForceLan.setOnCheckedChangeListener { _, c -> save(PrefKeys.FORCE_LAN, c) }
        swTextRoom.setOnCheckedChangeListener { _, c -> save(PrefKeys.TEXT_ROOM, c) }
        swNoPerf.setOnLongClickListener { showSoundDialog(); true }
        swExtend.setOnLongClickListener { showScaleDialog(); true }
        findViewById<View>(R.id.row_no_perf).setOnLongClickListener { showSoundDialog(); true }
        findViewById<View>(R.id.row_extend).setOnLongClickListener { showScaleDialog(); true }
        swTextRoom.setOnLongClickListener { showTextRoomDialog(); true }
        findViewById<View>(R.id.row_text_room).setOnLongClickListener { showTextRoomDialog(); true }

        findViewById<View>(R.id.row_music_source).setOnClickListener { showMusicSourceDialog() }
        findViewById<View>(R.id.row_about).setOnClickListener { showAboutDialog() }
        findViewById<View>(R.id.row_language).setOnClickListener { showLanguageDialog() }
        findViewById<View>(R.id.row_channel).setOnClickListener { showChannelDialog() }
        findViewById<View>(R.id.row_update).setOnClickListener { onUpdateRowClicked() }

        pickMusic = registerForActivityResult(ActivityResultContracts.OpenDocument()) {
            onMusicPicked(it)
        }

        ensureServiceRegistered()
        askForNotificationsIfNeeded()
        showPage(0)
        refresh()
    }

    private fun askForNotificationsIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
            == PackageManager.PERMISSION_GRANTED
        ) return
        try {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        } catch (ignored: Throwable) {
        }
    }

    override fun onResume() {
        super.onResume()
        foreground = this
        if (service == null) {
            try {
                XposedServiceHelper.registerListener(listener)
            } catch (ignored: Throwable) {
            }
        }
        ensureServiceRegistered()
        refresh()
    }

    override fun onPause() {
        if (foreground == this) foreground = null
        super.onPause()
    }

    override fun onDestroy() {
        unregisterInstallReceiver()
        super.onDestroy()
    }

    private fun registerInstallReceiver() {
        if (installReceiverRegistered) return
        val f = IntentFilter(Updates.INSTALL_ACTION)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            applicationContext.registerReceiver(installReceiver, f, Context.RECEIVER_NOT_EXPORTED)
        } else {
            applicationContext.registerReceiver(installReceiver, f)
        }
        installReceiverRegistered = true
    }

    private fun unregisterInstallReceiver() {
        if (!installReceiverRegistered) return
        installReceiverRegistered = false
        try {
            applicationContext.unregisterReceiver(installReceiver)
        } catch (ignored: Throwable) {
        }
    }

    private fun showPage(p: Int) {
        pageHome.visibility = if (p == 0) View.VISIBLE else View.GONE
        pageOptions.visibility = if (p == 1) View.VISIBLE else View.GONE
        toolbar.title =
            if (p == 0) getString(R.string.app_name) else getString(R.string.nav_options)
        if (p == 0) refresh()
    }

    private fun refresh() {
        val active = service != null

        val container = MaterialColors.getColor(
            this,
            if (active) com.google.android.material.R.attr.colorPrimaryContainer
            else com.google.android.material.R.attr.colorErrorContainer,
            if (active) Color.parseColor("#EADDFF") else Color.parseColor("#F9DEDC")
        )
        val on = MaterialColors.getColor(
            this,
            if (active) com.google.android.material.R.attr.colorOnPrimaryContainer
            else com.google.android.material.R.attr.colorOnErrorContainer,
            if (active) Color.parseColor("#21005D") else Color.parseColor("#410E0B")
        )

        homeStatus.setCardBackgroundColor(container)
        homeStatusIcon.setImageResource(
            if (active) R.drawable.ic_check_circle else R.drawable.ic_warning
        )
        homeStatusIcon.setColorFilter(on)
        homeStatusText.setText(if (active) R.string.status_active else R.string.status_inactive)
        homeStatusText.setTextColor(on)
        homeStatusSub.setTextColor(on)
        homeStatusSub.text = if (active) "" else getString(R.string.status_inactive_hint)
        homeStatusSub.visibility = if (active) View.GONE else View.VISIBLE

        val p = prefs()

        homeInfoSystem.removeAllViews()
        addInfo(
            homeInfoSystem, R.drawable.ic_module,
            getString(R.string.info_module_version), version(packageName)
        )
        addInfo(homeInfoSystem, R.drawable.ic_app, getString(R.string.info_vd_version), vdVersion())

        val lang = currentLanguage()
        langValue.text = languageLabel(lang)

        channelValue.text = channelLabel(currentChannel())
        if (!updateBusy && pendingUpdate == null) {
            updateValue.text = getString(R.string.update_current_format, version(packageName))
        }

        homeInfoDict.removeAllViews()
        addInfo(
            homeInfoDict, R.drawable.ic_dict,
            getString(R.string.dict_language_title), languageSummary(lang)
        )

        binding = true
        musicSourceValue.text = musicSourceLabel(p)
        aboutValue.text = getString(R.string.about_version_format, version(packageName))

        val vol = (p.getFloat(PrefKeys.MUSIC_VOLUME, 1.0f) * 100f).roundToInt()
        slMusicVolume.value = vol.coerceIn(0, 100).toFloat()
        musicVolumeValue.text = getString(R.string.music_volume_format, vol)
        swNoPerf.isChecked = p.getBoolean(PrefKeys.DISABLE_QUALITY_SOUND, false)
        swExtend.isChecked = p.getBoolean(PrefKeys.BITRATE_EXTEND, false)
        swUnlock.isChecked = p.getBoolean(PrefKeys.BITRATE_UNLOCK, false)
        swForceLan.isChecked = p.getBoolean(PrefKeys.FORCE_LAN, false)
        swTextRoom.isChecked = p.getBoolean(PrefKeys.TEXT_ROOM, true)
        binding = false
    }

    private fun addInfo(box: LinearLayout, iconRes: Int, label: String, value: String) {
        val row = LayoutInflater.from(this).inflate(R.layout.item_info, box, false)
        val icon = row.findViewById<ImageView>(R.id.info_icon)
        icon.setImageResource(iconRes)
        icon.setColorFilter(
            MaterialColors.getColor(
                this, com.google.android.material.R.attr.colorPrimary,
                Color.parseColor("#6750A4")
            )
        )
        row.findViewById<TextView>(R.id.info_label).text = label
        row.findViewById<TextView>(R.id.info_value).text = value
        box.addView(row)
    }

    private fun prefs(): SharedPreferences =
        getSharedPreferences(PrefKeys.NAME, Context.MODE_PRIVATE)

    private fun save(key: String, value: Any?) {
        if (binding) return
        put(prefs().edit(), key, value).apply()
        val svc = service ?: return
        try {
            put(svc.getRemotePreferences(PrefKeys.NAME).edit(), key, value).commit()
        } catch (ignored: Throwable) {
        }
    }

    private fun put(
        e: SharedPreferences.Editor,
        key: String,
        v: Any?
    ): SharedPreferences.Editor {
        when (v) {
            null -> e.remove(key)
            is Boolean -> e.putBoolean(key, v)
            is Int -> e.putInt(key, v)
            is Float -> e.putFloat(key, v)
            is Long -> e.putLong(key, v)
            else -> e.putString(key, v.toString())
        }
        return e
    }

    private fun showSoundDialog() {
        val v = LayoutInflater.from(this).inflate(R.layout.dialog_sounds, null)
        val ids = intArrayOf(
            R.id.snd0, R.id.snd1, R.id.snd2, R.id.snd3, R.id.snd4, R.id.snd5, R.id.snd6
        )
        val mask = prefs()
            .getInt(PrefKeys.QUALITY_MASK, 0x7F)
        val sw = ids.mapIndexed { i, id ->
            v.findViewById<MaterialSwitch>(id).apply { isChecked = (mask and (1 shl i)) != 0 }
        }
        MaterialAlertDialogBuilder(this)
            .setTitle(R.string.dialog_sounds_title)
            .setView(v)
            .setPositiveButton(R.string.action_done, null)
            .setOnDismissListener {
                var m = 0
                sw.forEachIndexed { i, s -> if (s.isChecked) m = m or (1 shl i) }
                save(PrefKeys.QUALITY_MASK, m)
            }
            .show()
    }

    private fun showScaleDialog() = showNumberDialog(
        R.string.dialog_scale_title, R.string.scale_hint,
        prefs().getFloat(PrefKeys.BITRATE_SCALE, 2.0f), 1f..3f
    ) { save(PrefKeys.BITRATE_SCALE, it) }

    private fun showTextRoomDialog() = showNumberDialog(
        R.string.dialog_text_room_title, R.string.text_room_hint,
        prefs().getFloat(PrefKeys.TEXT_ROOM_FACTOR, 0.5f), 0.3f..1f
    ) { save(PrefKeys.TEXT_ROOM_FACTOR, it) }

    private fun showNumberDialog(
        titleRes: Int,
        hintRes: Int,
        current: Float,
        allowed: ClosedFloatingPointRange<Float>,
        onDone: (Float) -> Unit
    ) {
        val v = LayoutInflater.from(this).inflate(R.layout.dialog_scale, null)
        v.findViewById<TextInputLayout>(R.id.scale_input_layout).setHint(hintRes)
        val input = v.findViewById<EditText>(R.id.scale_input)
        input.setText(formatScale(current))
        MaterialAlertDialogBuilder(this)
            .setTitle(titleRes)
            .setView(v)
            .setPositiveButton(R.string.action_done, null)
            .setOnDismissListener {
                // Unparseable input keeps the value that was already there.
                val s = input.text.toString().trim().toFloatOrNull() ?: current
                onDone(s.coerceIn(allowed))
            }
            .show()
    }

    private fun version(pkg: String): String =
        try {
            packageManager.getPackageInfo(pkg, 0).versionName ?: "—"
        } catch (t: Throwable) {
            "—"
        }

    private fun vdVersion(): String {
        for (pkg in VdTarget.PACKAGES) {
            try {
                return packageManager.getPackageInfo(pkg, 0).versionName ?: "—"
            } catch (ignored: Throwable) {
            }
        }
        return getString(R.string.version_not_installed)
    }

    private fun musicSourceLabel(p: SharedPreferences): String {
        val path = p.getString(PrefKeys.MUSIC_PATH, PrefKeys.MUSIC_DEFAULT)
        if (PrefKeys.MUSIC_VD == path) return getString(R.string.music_source_vd)
        if (PrefKeys.MUSIC_PLAZA == path) return getString(R.string.music_source_plaza)
        return p.getString(PrefKeys.MUSIC_NAME, null) ?: getString(R.string.music_source_custom)
    }

    private fun showMusicSourceDialog() {
        val labels = arrayOf(
            getString(R.string.music_source_vd),
            getString(R.string.music_source_plaza),
            getString(R.string.music_source_pick),
        )
        val values = arrayOf(PrefKeys.MUSIC_VD, PrefKeys.MUSIC_PLAZA)
        val path = prefs()
            .getString(PrefKeys.MUSIC_PATH, PrefKeys.MUSIC_DEFAULT)
        val checked = when (path) {
            PrefKeys.MUSIC_VD -> 0
            PrefKeys.MUSIC_PLAZA -> 1
            else -> 2
        }
        MaterialAlertDialogBuilder(this)
            .setTitle(R.string.dialog_music_source_title)
            .setSingleChoiceItems(labels, checked) { d, which ->
                d.dismiss()
                if (which == values.size) {
                    try {
                        pickMusic.launch(arrayOf("audio/*"))
                    } catch (t: Throwable) {
                        Toast.makeText(
                            this, R.string.toast_music_no_picker, Toast.LENGTH_LONG
                        ).show()
                    }
                    return@setSingleChoiceItems
                }
                save(PrefKeys.MUSIC_PATH, values[which])
                save(PrefKeys.MUSIC_NAME, null)
                refresh()
                Toast.makeText(
                    this, getString(R.string.toast_music_format, labels[which]), Toast.LENGTH_LONG
                ).show()
            }
            .show()
    }

    private fun showAboutDialog() {
        val v = LayoutInflater.from(this).inflate(R.layout.dialog_about, null)
        v.findViewById<TextView>(R.id.about_version).text =
            getString(R.string.about_version_format, version(packageName))
        MaterialAlertDialogBuilder(this)
            .setTitle(R.string.about_title)
            .setView(v)
            .setPositiveButton(R.string.action_done, null)
            .show()
    }

    private fun onMusicPicked(uri: Uri?) {
        if (uri == null) return
        val path = pathOf(uri)
        if (path == null) {
            Toast.makeText(this, R.string.toast_music_no_path, Toast.LENGTH_LONG).show()
            return
        }
        val name = File(path).name
        save(PrefKeys.MUSIC_PATH, path)
        save(PrefKeys.MUSIC_NAME, name)
        refresh()
        Toast.makeText(this, getString(R.string.toast_music_format, name), Toast.LENGTH_LONG).show()
    }

    // Virtual Desktop reads the file itself, so the picked document has to resolve to a real
    // path: a content uri would be useless there, since package visibility hides our process
    // from it and it holds no grant of ours.
    private fun pathOf(uri: Uri): String? {
        try {
            if ("file" == uri.scheme) return uri.path
            if (DocumentsContract.isDocumentUri(this, uri)) {
                val parts = DocumentsContract.getDocumentId(uri).split(":", limit = 2)
                if ("com.android.externalstorage.documents" == uri.authority && parts.size == 2) {
                    if ("primary".equals(parts[0], ignoreCase = true)) {
                        return File(Environment.getExternalStorageDirectory(), parts[1])
                            .absolutePath
                    }
                    return "/storage/${parts[0]}/${parts[1]}"
                }
                if ("com.android.providers.media.documents" == uri.authority && parts.size == 2) {
                    return queryPath(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, parts[1])
                }
            }
            if ("content" == uri.scheme) return queryPath(uri, null)
        } catch (ignored: Throwable) {
        }
        return null
    }

    private fun queryPath(base: Uri, id: String?): String? {
        val sel = if (id == null) null else "_id=?"
        val args = if (id == null) null else arrayOf(id)
        try {
            contentResolver.query(base, arrayOf("_data"), sel, args, null)?.use { c ->
                if (c.moveToFirst() && !c.isNull(0)) return c.getString(0)
            }
        } catch (ignored: Throwable) {
        }
        return null
    }

    private fun showLanguageDialog() {
        val tags = mutableListOf(Languages.OFF)
        tags.addAll(Languages.available(assets))

        val selected = currentLanguage()
        val labels = Array(tags.size) { languageSummary(tags[it]) }
        val checked = tags.indexOf(selected).coerceAtLeast(0)

        MaterialAlertDialogBuilder(this)
            .setTitle(R.string.dialog_language_title)
            .setSingleChoiceItems(labels, checked) { d, which ->
                val tag = tags[which]
                save(PrefKeys.UI_LANGUAGE, tag)
                d.dismiss()
                refresh()
                Toast.makeText(
                    this, getString(R.string.toast_language_format, languageLabel(tag)),
                    Toast.LENGTH_LONG
                ).show()
            }
            .show()
    }

    private fun currentChannel(): String = Updates.channelOf(
        prefs()
            .getString(PrefKeys.UPDATE_CHANNEL, Updates.STABLE)
    )

    private fun channelLabel(channel: String): String = getString(
        if (Updates.DEV == channel) R.string.update_channel_dev
        else R.string.update_channel_stable
    )

    private fun showChannelDialog() {
        val channels = arrayOf(Updates.STABLE, Updates.DEV)
        val labels = arrayOf(channelLabel(Updates.STABLE), channelLabel(Updates.DEV))
        val checked = if (Updates.DEV == currentChannel()) 1 else 0
        MaterialAlertDialogBuilder(this)
            .setTitle(R.string.dialog_channel_title)
            .setSingleChoiceItems(labels, checked) { d, which ->
                save(PrefKeys.UPDATE_CHANNEL, channels[which])

                pendingUpdate = null
                d.dismiss()
                refresh()
            }
            .show()
    }

    private fun onUpdateRowClicked() {
        if (updateBusy) return
        val pending = pendingUpdate
        if (pending != null) startInstall(pending) else checkForUpdate()
    }

    private fun checkForUpdate() {
        updateBusy = true
        updateValue.setText(R.string.update_checking)
        val channel = currentChannel()
        val installed = version(packageName)
        Thread {
            try {
                val r = Updates.latest(channel)
                val newer =
                    if (r != null && Updates.compareVersions(r.version, installed) > 0) r else null
                runOnUiThread {
                    updateBusy = false
                    pendingUpdate = newer
                    updateValue.text = if (newer != null) {
                        getString(R.string.update_available_format, newer.version)
                    } else {
                        getString(R.string.update_up_to_date)
                    }
                }
            } catch (t: Throwable) {
                runOnUiThread {
                    updateBusy = false
                    pendingUpdate = null
                    updateValue.text = getString(R.string.update_failed_format, reason(t))
                }
            }
        }.start()
    }

    private fun startInstall(r: Updates.Release) {
        if (!Updates.canInstall(this)) {
            Toast.makeText(this, R.string.update_needs_permission, Toast.LENGTH_LONG).show()
            try {
                startActivity(
                    Intent(
                        Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                        Updates.settingsUriFor(this)
                    )
                )
            } catch (ignored: Throwable) {
            }
            return
        }
        updateBusy = true
        registerInstallReceiver()
        updateValue.setText(R.string.update_downloading)
        Thread {
            try {
                val apk = Updates.download(this, r)
                runOnUiThread { updateValue.setText(R.string.update_installing) }
                Updates.install(this, apk) { installSessionId = it }
            } catch (t: Throwable) {
                runOnUiThread {
                    updateBusy = false
                    unregisterInstallReceiver()
                    updateValue.text = getString(R.string.update_failed_format, reason(t))
                }
            }
        }.start()
    }

    private fun reason(t: Throwable): String {
        val m = t.message
        return if (m.isNullOrEmpty()) t.javaClass.simpleName else m
    }

    private val installReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, i: Intent) {
            val session = i.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1)
            if (installSessionId < 0 || session != installSessionId) return
            val status = i.getIntExtra(PackageInstaller.EXTRA_STATUS, -1)
            if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
                val confirm = i.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                if (confirm != null) {
                    confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    try {
                        startActivity(confirm)
                    } catch (ignored: Throwable) {
                    }
                }
            } else if (status == PackageInstaller.STATUS_SUCCESS) {
                pendingUpdate = null
                updateBusy = false
                installSessionId = -1
                unregisterInstallReceiver()
                Toast.makeText(
                    this@MainActivity, R.string.update_restart_hint, Toast.LENGTH_LONG
                ).show()
                refresh()
            } else {
                updateBusy = false
                installSessionId = -1
                unregisterInstallReceiver()
                val m = i.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
                updateValue.text = getString(R.string.update_failed_format, m ?: status.toString())
            }
        }
    }

    private fun currentLanguage(): String =
        prefs()
            .getString(PrefKeys.UI_LANGUAGE, null)
            ?: Languages.systemDefault(Languages.available(assets))

    private fun languageLabel(tag: String): String =
        if (Languages.isOff(tag)) getString(R.string.lang_off) else Languages.displayName(tag)

    private fun languageSummary(tag: String): String =
        if (Languages.isOff(tag)) {
            getString(R.string.lang_off)
        } else {
            getString(R.string.lang_entry_format, Languages.displayName(tag), bundledCount(tag))
        }

    private fun bundledCount(tag: String): Int {
        if (Languages.isOff(tag)) return 0
        return try {
            assets.open(Languages.assetPath(tag)).use {
                DictJson.count(it.readBytes().toString(Charsets.UTF_8))
            }
        } catch (t: Throwable) {
            0
        }
    }

    private fun formatScale(s: Float): String =
        if (s == floor(s)) s.toInt().toString()
        else "%.2f".format(Locale.getDefault(), s)

    private companion object {
        @Volatile
        var service: XposedService? = null

        var foreground: MainActivity? = null
        var registered = false

        val listener = object : XposedServiceHelper.OnServiceListener {
            override fun onServiceBind(s: XposedService) {
                service = s
                notifyServiceChanged()
            }

            override fun onServiceDied(s: XposedService) {
                service = null
                notifyServiceChanged()
            }
        }

        fun ensureServiceRegistered() {
            if (registered) return
            registered = true
            try {
                XposedServiceHelper.registerListener(listener)
            } catch (t: Throwable) {
                registered = false
            }
        }

        fun notifyServiceChanged() {
            val a = foreground ?: return
            a.runOnUiThread(a::refresh)
        }
    }
}
