package com.gitmorin.vdextra;

import lombok.experimental.UtilityClass;

/** SharedPreferences name and key constants shared between {@link MainActivity} and {@link MainModule}. */
@UtilityClass
class PrefKeys {
    final String NAME = "vdextra";

    final String IMPORTED_DICT = "imported_dict";
    final String IMPORTED_TIME = "imported_time";
    final String USE_IMPORTED_DICT = "use_imported_dict";
    final String DISABLE_MUSIC = "disable_music";
    final String DISABLE_QUALITY_SOUND = "disable_quality_sound";
    final String QUALITY_MASK = "quality_mask";
    final String BITRATE_EXTEND = "bitrate_extend";
    final String BITRATE_SCALE = "bitrate_scale";
    final String BITRATE_UNLOCK = "bitrate_unlock";
    final String FORCE_LAN = "force_lan";
}
