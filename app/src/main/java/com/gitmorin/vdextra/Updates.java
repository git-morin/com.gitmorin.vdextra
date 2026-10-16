package com.gitmorin.vdextra;

import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageInstaller;
import android.net.Uri;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.function.IntConsumer;

import org.json.JSONArray;
import org.json.JSONObject;

import lombok.experimental.UtilityClass;

@UtilityClass
class Updates {

    static final String STABLE = "stable";
    static final String DEV = "dev";

    private final String RELEASES_URL = "https://api.github.com/repos/git-morin/vdextra/releases?per_page=30";
    private final String INSTALL_ACTION = "com.gitmorin.vdextra.INSTALL_RESULT";
    private final int TIMEOUT_MS = 15000;

    static final class Release {
        final String version;
        final String apkUrl;
        final long apkSize;

        Release(String version, String apkUrl, long apkSize) {
            this.version = version;
            this.apkUrl = apkUrl;
            this.apkSize = apkSize;
        }
    }

    static String channelOf(String pref) {
        return DEV.equals(pref) ? DEV : STABLE;
    }

    static Release latest(String channel) throws IOException {
        String body = get(RELEASES_URL);
        JSONArray arr;
        try {
            arr = new JSONArray(body);
        } catch (Throwable t) {
            throw new IOException("unexpected response from GitHub");
        }

        Release best = null;
        for (int i = 0; i < arr.length(); i++) {
            JSONObject o = arr.optJSONObject(i);
            if (o == null || o.optBoolean("draft", false)) continue;
            if (!DEV.equals(channel) && o.optBoolean("prerelease", false)) continue;

            String tag = o.optString("tag_name", "");
            if (tag.isEmpty()) continue;

            JSONArray assets = o.optJSONArray("assets");
            String url = null;
            long size = 0;
            for (int j = 0; assets != null && j < assets.length(); j++) {
                JSONObject a = assets.optJSONObject(j);
                if (a != null && a.optString("name", "").endsWith(".apk")) {
                    url = a.optString("browser_download_url", null);
                    size = a.optLong("size", 0);
                    break;
                }
            }
            if (url == null) continue;

            Release r = new Release(versionOf(tag), url, size);
            if (best == null || compareVersions(r.version, best.version) > 0) best = r;
        }
        return best;
    }

    static String versionOf(String tag) {
        return tag.startsWith("v") ? tag.substring(1) : tag;
    }

    static int compareVersions(String a, String b) {
        String[] av = a.split("-", 2);
        String[] bv = b.split("-", 2);

        int c = compareNumeric(av[0], bv[0]);
        if (c != 0) return c;

        boolean aPre = av.length > 1;
        boolean bPre = bv.length > 1;
        if (aPre != bPre) return aPre ? -1 : 1;
        if (!aPre) return 0;
        return comparePrerelease(av[1], bv[1]);
    }

    private int compareNumeric(String a, String b) {
        String[] x = a.split("\\.");
        String[] y = b.split("\\.");
        for (int i = 0; i < Math.max(x.length, y.length); i++) {
            int c = Integer.compare(part(x, i), part(y, i));
            if (c != 0) return c;
        }
        return 0;
    }

    private int comparePrerelease(String a, String b) {
        String[] x = a.split("\\.");
        String[] y = b.split("\\.");
        for (int i = 0; i < Math.max(x.length, y.length); i++) {
            String xi = i < x.length ? x[i] : "";
            String yi = i < y.length ? y[i] : "";
            if (xi.equals(yi)) continue;
            if (xi.isEmpty()) return -1;
            if (yi.isEmpty()) return 1;
            boolean xn = isNumeric(xi), yn = isNumeric(yi);
            if (xn && yn) return Integer.compare(Integer.parseInt(xi), Integer.parseInt(yi));
            if (xn != yn) return xn ? -1 : 1;
            return xi.compareTo(yi);
        }
        return 0;
    }

    private boolean isNumeric(String s) {
        if (s.isEmpty()) return false;
        for (int i = 0; i < s.length(); i++) if (s.charAt(i) < '0' || s.charAt(i) > '9') return false;
        return true;
    }

    private int part(String[] parts, int i) {
        if (i >= parts.length) return 0;
        try { return Integer.parseInt(parts[i].trim()); } catch (Throwable t) { return 0; }
    }

    private String get(String url) throws IOException {
        HttpURLConnection c = open(url);
        try {
            int code = c.getResponseCode();

            if (code == HttpURLConnection.HTTP_NOT_FOUND) {
                throw new IOException("releases are not public (HTTP 404)");
            }
            if (code / 100 != 2) throw new IOException("GitHub returned HTTP " + code);
            try (InputStream in = c.getInputStream()) {
                return new String(DictJson.readAll(in), StandardCharsets.UTF_8);
            }
        } finally {
            c.disconnect();
        }
    }

    private HttpURLConnection open(String url) throws IOException {
        HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
        c.setConnectTimeout(TIMEOUT_MS);
        c.setReadTimeout(TIMEOUT_MS);
        c.setInstanceFollowRedirects(true);
        c.setRequestProperty("Accept", "application/vnd.github+json");
        c.setRequestProperty("User-Agent", "VDExtra");
        return c;
    }

    static File download(Context ctx, Release r) throws IOException {
        File out = new File(ctx.getCacheDir(), "update.apk");
        HttpURLConnection c = open(r.apkUrl);
        try {
            if (c.getResponseCode() / 100 != 2) {
                throw new IOException("download failed with HTTP " + c.getResponseCode());
            }
            try (InputStream in = c.getInputStream(); OutputStream os = new FileOutputStream(out)) {
                byte[] buf = new byte[65536];
                int n;
                while ((n = in.read(buf)) > 0) os.write(buf, 0, n);
            }
        } finally {
            c.disconnect();
        }
        if (out.length() == 0) throw new IOException("downloaded file is empty");
        if (r.apkSize > 0 && out.length() != r.apkSize) {
            throw new IOException("download incomplete: " + out.length() + " of " + r.apkSize + " bytes");
        }
        return out;
    }

    static void install(Context ctx, File apk, IntConsumer onSession) throws IOException {
        PackageInstaller pi = ctx.getPackageManager().getPackageInstaller();
        PackageInstaller.SessionParams params =
                new PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL);
        params.setAppPackageName(ctx.getPackageName());

        int sessionId = pi.createSession(params);
        onSession.accept(sessionId);
        try (PackageInstaller.Session session = pi.openSession(sessionId)) {
            try (InputStream in = new java.io.FileInputStream(apk);
                 OutputStream out = session.openWrite("vdextra", 0, apk.length())) {
                byte[] buf = new byte[65536];
                int n;
                while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
                session.fsync(out);
            }
            Intent intent = new Intent(INSTALL_ACTION).setPackage(ctx.getPackageName());
            PendingIntent pending = PendingIntent.getBroadcast(
                    ctx, sessionId, intent,
                    PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_MUTABLE);
            session.commit(pending.getIntentSender());
        }
    }

    static String installAction() {
        return INSTALL_ACTION;
    }

    static boolean canInstall(Context ctx) {
        return ctx.getPackageManager().canRequestPackageInstalls();
    }

    static Uri settingsUriFor(Context ctx) {
        return Uri.parse("package:" + ctx.getPackageName());
    }
}
