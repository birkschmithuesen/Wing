package com.tarkilhk.wing.shareqa.fixture;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.graphics.Bitmap;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;
import java.io.File;
import java.io.FileNotFoundException;
import java.io.FileOutputStream;

/** A fixed, synthetic PNG owned by the disposable clipboard fixture. */
public final class ClipboardFixtureProvider extends ContentProvider {
    static final String URI = "content://com.tarkilhk.wing.shareqa.fixture.clipboard/image";
    private File image;

    @Override public boolean onCreate() {
        image = new File(getContext().getFilesDir(), "wing-clipboard-probe.png");
        Bitmap bitmap = Bitmap.createBitmap(32, 32, Bitmap.Config.ARGB_8888);
        bitmap.eraseColor(0xff2090c0);
        try (FileOutputStream stream = new FileOutputStream(image)) {
            if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)) {
                throw new IllegalStateException("Cannot encode clipboard fixture");
            }
        } catch (Exception error) {
            throw new IllegalStateException("Cannot create clipboard fixture", error);
        } finally {
            bitmap.recycle();
        }
        return true;
    }

    private void requireImage(Uri uri) {
        if (!URI.equals(uri.toString())) throw new IllegalArgumentException("Unknown fixture URI");
    }

    @Override public String getType(Uri uri) {
        requireImage(uri);
        return "image/png";
    }

    @Override public Cursor query(Uri uri, String[] projection, String selection,
            String[] selectionArgs, String sortOrder) {
        requireImage(uri);
        String[] columns = projection == null
                ? new String[] {OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE} : projection;
        MatrixCursor cursor = new MatrixCursor(columns);
        Object[] row = new Object[columns.length];
        for (int index = 0; index < columns.length; index++) {
            if (OpenableColumns.DISPLAY_NAME.equals(columns[index])) row[index] = image.getName();
            if (OpenableColumns.SIZE.equals(columns[index])) row[index] = image.length();
        }
        cursor.addRow(row);
        return cursor;
    }

    @Override public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        requireImage(uri);
        if (!"r".equals(mode)) throw new FileNotFoundException("Read-only fixture");
        return ParcelFileDescriptor.open(image, ParcelFileDescriptor.MODE_READ_ONLY);
    }

    @Override public Uri insert(Uri uri, ContentValues values) { throw new UnsupportedOperationException(); }
    @Override public int delete(Uri uri, String selection, String[] args) { throw new UnsupportedOperationException(); }
    @Override public int update(Uri uri, ContentValues values, String selection, String[] args) { throw new UnsupportedOperationException(); }
}
