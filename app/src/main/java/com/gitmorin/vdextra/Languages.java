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

@UtilityClass
class Languages {

    final String OFF = "";

    private final String DIR = "dict";
    private final String EXT = ".json";
    private final String APK_PREFIX = "assets/" + DIR + "/";

    String assetPath(String tag) {
        return DIR + "/" + tag + EXT;
    }

    String apkEntry(String tag) {
        return APK_PREFIX + tag + EXT;
    }

    boolean isOff(String tag) {
        return tag == null || tag.isEmpty();
    }

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

    List<String> available(String moduleApk) {
        List<String> out = new ArrayList<>();
        if (moduleApk == null) return out;
        try (ZipFile zf = new ZipFile(moduleApk)) {
            for (Enumeration<? extends ZipEntry> en = zf.entries(); en.hasMoreElements(); ) {
                String name = en.nextElement().getName();

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

    String systemDefault(List<String> available) {
        if (available.isEmpty()) return OFF;
        for (Locale wanted : preferredLocales()) {
            String match = bestMatch(wanted, available);
            if (match != null) return match;
        }
        return OFF;
    }

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
