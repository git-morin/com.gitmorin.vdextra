package com.gitmorin.vdextra;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.util.Iterator;
import java.util.Map;

import org.json.JSONObject;

import lombok.experimental.UtilityClass;

/** Reads and parses the {@code key -> translation} JSON dictionary format used by both the builtin and imported dictionaries. */
@UtilityClass
class DictJson {

    /** @return the entry count, 0 for a null/empty dictionary, or -1 if {@code json} isn't valid. */
    int count(String json) {
        if (json == null) return 0;
        try {
            JSONObject o = new JSONObject(json);
            int c = 0;
            for (Iterator<String> it = o.keys(); it.hasNext(); ) { it.next(); c++; }
            return c;
        } catch (Throwable t) { return -1; }
    }

    /** Parses {@code json} into {@code out}, silently leaving it unchanged if {@code json} isn't valid. */
    void parseInto(String json, Map<String, String> out) {
        try {
            JSONObject o = new JSONObject(json);
            for (Iterator<String> it = o.keys(); it.hasNext(); ) {
                String k = it.next();
                out.put(k, o.optString(k, ""));
            }
        } catch (Throwable ignored) {
        }
    }

    byte[] readAll(InputStream in) throws IOException {
        ByteArrayOutputStream b = new ByteArrayOutputStream();
        byte[] buf = new byte[8192];
        int n;
        while ((n = in.read(buf)) > 0) b.write(buf, 0, n);
        return b.toByteArray();
    }
}
