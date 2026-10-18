package com.gitmorin.vdextra

internal object PrefKeys {
    const val NAME = "vdextra"

    const val UI_LANGUAGE = "ui_language"

    /** Widens a label so a longer translation fits, rather than shrinking the text. */
    const val TEXT_ROOM = "text_room"

    /** Ceiling on that widening, as a multiple of the width VD gave the label. */
    const val TEXT_ROOM_FACTOR = "text_room_factor"
    const val UPDATE_CHANNEL = "update_channel"
    const val LAST_UPDATE_CHECK = "last_update_check"
    const val MUSIC_VOLUME = "music_volume"
    const val MUSIC_PATH = "music_path"

    /** MUSIC_PATH values that are not a file path; absent means MUSIC_DEFAULT. */
    const val MUSIC_VD = "vd"

    /** Nightwave Plaza (https://plaza.one), credited in the about dialog. */
    const val MUSIC_PLAZA = "https://radio.plaza.one/mp3"
    const val MUSIC_DEFAULT = MUSIC_PLAZA
    const val MUSIC_NAME = "music_name"
    const val DISABLE_QUALITY_SOUND = "disable_quality_sound"
    const val QUALITY_MASK = "quality_mask"
    const val BITRATE_EXTEND = "bitrate_extend"
    const val BITRATE_SCALE = "bitrate_scale"
    const val BITRATE_UNLOCK = "bitrate_unlock"
    const val FORCE_LAN = "force_lan"
}
