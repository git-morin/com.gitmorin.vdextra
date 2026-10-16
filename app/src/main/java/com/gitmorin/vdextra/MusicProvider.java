package com.gitmorin.vdextra;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.content.Context;
import android.database.Cursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;

import java.io.FileNotFoundException;

public class MusicProvider extends ContentProvider {

    static final String AUTHORITY = "com.gitmorin.vdextra.music";
    static final Uri CURRENT = Uri.parse("content://" + AUTHORITY + "/current");

    @Override
    public boolean onCreate() {
        return true;
    }

    private String configured() {
        Context c = getContext();
        if (c == null) return null;
        return c.getSharedPreferences(PrefKeys.NAME, Context.MODE_PRIVATE)
                .getString(PrefKeys.MUSIC_URI, null);
    }

    // Virtual Desktop runs as its own uid and holds no storage permission, but the document
    // grant from the picker belongs to us, so we open the file and hand over the descriptor.
    @Override
    public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        String src = configured();
        if (src == null) throw new FileNotFoundException("no music configured");
        Context c = getContext();
        if (c == null) throw new FileNotFoundException("no context");
        ParcelFileDescriptor pfd;
        try {
            pfd = c.getContentResolver().openFileDescriptor(Uri.parse(src), "r");
        } catch (FileNotFoundException e) {
            throw e;
        } catch (Throwable t) {
            throw new FileNotFoundException("cannot open " + src + ": " + t);
        }
        if (pfd == null) throw new FileNotFoundException("cannot open " + src);
        return pfd;
    }

    @Override
    public String getType(Uri uri) {
        String src = configured();
        Context c = getContext();
        if (src == null || c == null) return "audio/*";
        String t = c.getContentResolver().getType(Uri.parse(src));
        return t != null ? t : "audio/*";
    }

    @Override
    public Cursor query(Uri uri, String[] projection, String selection, String[] args, String sort) {
        return null;
    }

    @Override
    public Uri insert(Uri uri, ContentValues values) {
        throw new UnsupportedOperationException();
    }

    @Override
    public int update(Uri uri, ContentValues values, String selection, String[] args) {
        throw new UnsupportedOperationException();
    }

    @Override
    public int delete(Uri uri, String selection, String[] args) {
        throw new UnsupportedOperationException();
    }
}
