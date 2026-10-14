package com.gitmorin.vdextra;

import android.content.res.AssetManager;
import android.os.LocaleList;

import java.util.ArrayList;
import java.util.Collections;
import java.util.Enumeration;
import java.util.List;
import java.util.Locale;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

import lombok.experimental.UtilityClass;

/**
 * Registry of the bundled UI translation dictionaries.
 *
 * <p>A language is nothing more than an {@code assets/dict/<tag>.json} file whose name is a
 * BCP-47 language tag, so adding one is a drop-in: no code, no string resource and no list to
 * keep in sync. Display names come from {@link Locale} for the same reason.
 *
 * <p>Both sides of the module need the list and they see the APK differently - the settings UI
 * reads its own assets through an {@link AssetManager}, while the hook runs inside the Virtual
 * Desktop process where the module APK is reachable only as a zip file - hence the two
 * {@code available()} overloads.
 */
@UtilityClass
class Languages {

    /** Selected-language value meaning "leave Virtual Desktop's UI in English". */
    final String OFF = "";

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

    /** The same list read out of the module APK, the only view the hook side has of its assets. */
    List<String> available(String moduleApk) {
        List<String> out = new ArrayList<>();
        if (moduleApk == null) return out;
        try (ZipFile zf = new ZipFile(moduleApk)) {
            for (Enumeration<? extends ZipEntry> en = zf.entries(); en.hasMoreElements(); ) {
                String name = en.nextElement().getName();
                // Direct children only - a nested path would not be a language tag.
                if (name.startsWith(APK_PREFIX) && name.endsWith(EXT)
                        && name.indexOf('/', APK_PREFIX.length()) < 0) {
                    out.add(stripExt(name.substring(APK_PREFIX.length())));
                }
            }
        } catch (Throwable ignored) {
        }
        sortByDisplayName(out);
        return out;
    }

    /**
     * The language to use when the user has not picked one: the best bundled match for the
     * system's own language preferences, or English when nothing matches.
     *
     * <p>English needs no dictionary and so is simply {@link #OFF} - which is also what an
     * English-locale device resolves to naturally, there being no {@code en.json} to match.
     */
    String systemDefault(List<String> available) {
        if (available.isEmpty()) return OFF;
        for (Locale wanted : preferredLocales()) {
            String match = bestMatch(wanted, available);
            if (match != null) return match;
        }
        return OFF;
    }

    /**
     * Narrowing match for one locale: the exact tag first, then the bare language, then any
     * region of that language - so a {@code pt-PT} device still gets a bundled {@code pt-BR}
     * dictionary, which is far better than falling back to English over a region mismatch.
     */
    private String bestMatch(Locale wanted, List<String> available) {
        String tag = wanted.toLanguageTag();
        for (String a : available) if (a.equalsIgnoreCase(tag)) return a;

        String lang = wanted.getLanguage();
        if (lang == null || lang.isEmpty()) return null;
        for (String a : available) if (a.equalsIgnoreCase(lang)) return a;
        for (String a : available) {
            if (lang.equalsIgnoreCase(Locale.forLanguageTag(a).getLanguage())) return a;
        }
        return null;
    }

    /** The device's languages in the user's own order of preference, best first. */
    private List<Locale> preferredLocales() {
        List<Locale> out = new ArrayList<>();
        try {
            LocaleList list = LocaleList.getDefault();
            for (int i = 0; i < list.size(); i++) out.add(list.get(i));
        } catch (Throwable ignored) {
        }
        if (out.isEmpty()) out.add(Locale.getDefault());
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
