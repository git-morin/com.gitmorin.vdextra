package com.gitmorin.vdextra;

import lombok.experimental.UtilityClass;

/** SharedPreferences name and key constants shared between {@link MainActivity} and {@link MainModule}. */
@UtilityClass
class PrefKeys {
    final String NAME = "vdextra";

    final String UI_LANGUAGE = "ui_language";
    final String UPDATE_CHANNEL = "update_channel";
    final String LAST_UPDATE_CHECK = "last_update_check";
    final String DISABLE_MUSIC = "disable_music";
    final String DISABLE_QUALITY_SOUND = "disable_quality_sound";
    final String QUALITY_MASK = "quality_mask";
    final String BITRATE_EXTEND = "bitrate_extend";
    final String BITRATE_SCALE = "bitrate_scale";
    final String BITRATE_UNLOCK = "bitrate_unlock";
    final String FORCE_LAN = "force_lan";
}
