package com.gitmorin.vdextra;

import android.content.res.AssetManager;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Locale;

import lombok.experimental.UtilityClass;

/**
 * Registry of the bundled UI translation dictionaries.
 *
 * <p>A language is nothing more than an {@code assets/dict/<tag>.json} file whose name is a
 * BCP-47 language tag, so adding one is a drop-in: no code, no string resource and no list to
 * keep in sync. Display names come from {@link Locale} for the same reason.
 *
 * <p>Only the settings UI enumerates the list, through its own {@link AssetManager}. The hook
 * side runs inside the Virtual Desktop process, where the module APK is reachable only as a zip
 * file, and it just resolves the one selected tag via {@link #apkEntry(String)}.
 */
@UtilityClass
class Languages {

    /** Selected-language value meaning "leave Virtual Desktop's UI in English". */
    final String OFF = "";

    /** Selected by default, preserving the behaviour from before the picker existed. */
    final String DEFAULT = "zh";

    private final String DIR = "dict";
    private final String EXT = ".json";
    private final String APK_PREFIX = "assets/" + DIR + "/";

    /** Path of a language's dictionary within the app's own assets. */
    String assetPath(String tag) {
        return DIR + "/" + tag + EXT;
    }

    /** Name of the same entry inside the module APK. */
    String apkEntry(String tag) {
        return APK_PREFIX + tag + EXT;
    }

    boolean isOff(String tag) {
        return tag == null || tag.isEmpty();
    }

    /** Tags bundled in the app's own assets, ordered by display name. */
    List<String> available(AssetManager assets) {
        List<String> out = new ArrayList<>();
        try {
            String[] names = assets.list(DIR);
            if (names != null) {
                for (String n : names) if (n.endsWith(EXT)) out.add(stripExt(n));
            }
        } catch (Throwable ignored) {
        }
        sortByDisplayName(out);
        return out;
    }

    /**
     * The language's own name for itself - "中文", "Français" - so the picker reads naturally to
     * the person looking for their own language. Falls back to the raw tag for anything
     * {@link Locale} doesn't recognise.
     */
    String displayName(String tag) {
        if (isOff(tag)) return "";
        try {
            Locale loc = Locale.forLanguageTag(tag);
            String name = loc.getDisplayName(loc);
            if (name != null && !name.isEmpty()) {
                return name.substring(0, 1).toUpperCase(loc) + name.substring(1);
            }
        } catch (Throwable ignored) {
        }
        return tag;
    }

    private String stripExt(String fileName) {
        return fileName.substring(0, fileName.length() - EXT.length());
    }

    private void sortByDisplayName(List<String> tags) {
        Collections.sort(tags, (a, b) -> displayName(a).compareToIgnoreCase(displayName(b)));
    }
}
