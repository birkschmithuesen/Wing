package com.tarkilhk.wing.shareqa.fixture;

import android.app.Activity;
import android.content.Intent;
import android.content.SharedPreferences;
import android.database.Cursor;
import android.net.Uri;
import android.os.Bundle;
import android.provider.OpenableColumns;
import java.io.InputStream;
import java.io.OutputStream;

/** Disposable share-sheet destination that saves the granted bytes through DocumentsUI. */
public final class BackupSaveActivity extends Activity {
    private static final int SAVE = 7;
    private Uri source;
    private String filename;

    private SharedPreferences status() {
        return getSharedPreferences("backup_save", MODE_PRIVATE);
    }

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        if (state != null) {
            source = state.getParcelable("source");
            filename = state.getString("filename");
            return;
        }
        Intent intent = getIntent();
        // The host establishes ownership before starting the Flutter test.
        if (!Intent.ACTION_SEND.equals(intent.getAction())) {
            String prefix = intent.getStringExtra("qa_prefix");
            if (prefix == null || !prefix.matches("wing-backup-qa-[a-f0-9]{32}-")) {
                fail("Invalid owned-file prefix");
                return;
            }
            status().edit().clear().putString("prefix", prefix).commit();
            finish();
            return;
        }
        try {
            source = intent.getParcelableExtra(Intent.EXTRA_STREAM);
            if (source == null || !"content".equals(source.getScheme())) {
                throw new IllegalArgumentException("A granted content URI is required");
            }
            String prefix = status().getString("prefix", "");
            if (!prefix.matches("wing-backup-qa-[a-f0-9]{32}-")) {
                throw new IllegalArgumentException("Host ownership was not configured");
            }
            String displayName = null;
            try (Cursor cursor = getContentResolver().query(source,
                    new String[] {OpenableColumns.DISPLAY_NAME}, null, null, null)) {
                if (cursor != null && cursor.moveToFirst()) displayName = cursor.getString(0);
            }
            if (displayName == null || !displayName.matches("wing-config-[a-zA-Z0-9-]+\\.json")) {
                throw new IllegalArgumentException("Unexpected synthetic backup filename");
            }
            filename = prefix + displayName;
            status().edit().remove("error").remove("saved_uri").remove("saved_name")
                    .putString("pending_name", filename).commit();
            Intent save = new Intent(Intent.ACTION_CREATE_DOCUMENT);
            save.addCategory(Intent.CATEGORY_OPENABLE);
            save.setType("application/json");
            save.putExtra(Intent.EXTRA_TITLE, filename);
            startActivityForResult(save, SAVE);
        } catch (Exception error) {
            fail(error.toString());
        }
    }

    @Override protected void onSaveInstanceState(Bundle state) {
        state.putParcelable("source", source);
        state.putString("filename", filename);
        super.onSaveInstanceState(state);
    }

    @Override protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (request != SAVE) return;
        if (result != RESULT_OK || data == null || data.getData() == null) {
            fail("DocumentsUI save was cancelled");
            return;
        }
        Uri destination = data.getData();
        try (InputStream input = getContentResolver().openInputStream(source);
                OutputStream output = getContentResolver().openOutputStream(destination, "wt")) {
            if (input == null || output == null) throw new IllegalStateException("Missing stream");
            byte[] buffer = new byte[8192];
            int total = 0;
            int count;
            while ((count = input.read(buffer)) != -1) {
                total += count;
                if (total > 2 * 1024 * 1024) throw new IllegalArgumentException("Backup exceeds 2 MiB");
                output.write(buffer, 0, count);
            }
            output.flush();
            status().edit().putString("saved_uri", destination.toString())
                    .putString("saved_name", filename).putInt("saved_bytes", total).commit();
            finish();
        } catch (Exception error) {
            fail(error.toString());
        }
    }

    private void fail(String error) {
        status().edit().putString("error", error).commit();
        finish();
    }
}
