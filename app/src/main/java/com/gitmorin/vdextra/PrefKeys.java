package com.gitmorin.vdextra;

import lombok.experimental.UtilityClass;

@UtilityClass
class PrefKeys {
    final String NAME = "vdextra";

    final String UI_LANGUAGE = "ui_language";
    final String UPDATE_CHANNEL = "update_channel";
    final String LAST_UPDATE_CHECK = "last_update_check";
    final String MUSIC_VOLUME = "music_volume";
    final String MUSIC_PATH = "music_path";

    /** MUSIC_PATH values that are not a file path; absent means MUSIC_DEFAULT. */
    final String MUSIC_VD = "vd";

    /** Nightwave Plaza (https://plaza.one), credited in the about dialog. */
    final String MUSIC_PLAZA = "https://radio.plaza.one/mp3";
    final String MUSIC_DEFAULT = MUSIC_PLAZA;
    final String MUSIC_NAME = "music_name";
    final String DISABLE_QUALITY_SOUND = "disable_quality_sound";
    final String QUALITY_MASK = "quality_mask";
    final String BITRATE_EXTEND = "bitrate_extend";
    final String BITRATE_SCALE = "bitrate_scale";
    final String BITRATE_UNLOCK = "bitrate_unlock";
    final String FORCE_LAN = "force_lan";
}
