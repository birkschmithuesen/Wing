package com.tarkilhk.wing.shareqa.fixture;

import android.app.Activity;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.net.Uri;
import android.os.Bundle;
import android.os.ParcelFileDescriptor;
import android.provider.MediaStore;
import java.io.ByteArrayOutputStream;
import java.io.OutputStream;
import java.security.MessageDigest;

/** A disposable foreign-UID camera; output is restricted to the owned QA host. */
public final class ControlledCameraActivity extends Activity {
    static ControlledCameraActivity active;
    private Uri output;
    private boolean settled;
    private static final String HOST = "com.tarkilhk.wing.notificationqa";

    SharedPreferences status() { return getSharedPreferences("controlled_camera", 0); }

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        try {
            String nonce = status().getString("nonce", "");
            if (!nonce.matches("[a-f0-9]{32}") || !HOST.equals(getCallingPackage())
                    || !MediaStore.ACTION_IMAGE_CAPTURE.equals(getIntent().getAction())) {
                throw new IllegalArgumentException("Owned capture configuration required");
            }
            output = state == null ? getIntent().getParcelableExtra(MediaStore.EXTRA_OUTPUT)
                    : state.getParcelable("output");
            if (output == null || !"content".equals(output.getScheme())
                    || !(HOST + ".fileprovider").equals(output.getAuthority())
                    || !output.getPath().matches("/pending_intake/[a-f0-9-]{36}/camera\\.jpg")) {
                throw new IllegalArgumentException("Unexpected owned output URI");
            }
            int flags = Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION;
            if (checkUriPermission(output, android.os.Process.myPid(), android.os.Process.myUid(), flags)
                    != PackageManager.PERMISSION_GRANTED) {
                throw new IllegalStateException("Missing capture output grant");
            }
            try (ParcelFileDescriptor file = getContentResolver().openFileDescriptor(output, "rw")) {
                if (file == null) throw new IllegalStateException("Missing output descriptor");
            }
            active = this;
            SharedPreferences.Editor edit = status().edit().remove("error")
                    .putString("output_uri", output.toString()).putBoolean("active", true)
                    .putInt("opened", status().getInt("opened", 0) + 1);
            if (state == null) edit.putInt("started", status().getInt("started", 0) + 1);
            else edit.putInt("recreated", status().getInt("recreated", 0) + 1);
            edit.commit();
            String mode = status().getString("mode", "held");
            if (!"held".equals(mode)) new android.os.Handler(getMainLooper()).post(() -> complete(mode));
        } catch (Exception error) {
            fail(error);
        }
    }

    @Override protected void onSaveInstanceState(Bundle state) {
        state.putParcelable("output", output);
        super.onSaveInstanceState(state);
    }

    @Override protected void onDestroy() {
        if (active == this) active = null;
        super.onDestroy();
    }

    void complete(String command) {
        if (settled) return;
        if ("recreate".equals(command)) { recreate(); return; }
        settled = true;
        try {
            if ("success".equals(command)) {
                Bitmap bitmap = Bitmap.createBitmap(2, 2, Bitmap.Config.ARGB_8888);
                bitmap.eraseColor(0xff2860a0);
                byte[] bytes;
                try (ByteArrayOutputStream encoded = new ByteArrayOutputStream()) {
                    if (!bitmap.compress(Bitmap.CompressFormat.JPEG, 85, encoded)) {
                        throw new IllegalStateException("JPEG encoding failed");
                    }
                    bytes = encoded.toByteArray();
                } finally { bitmap.recycle(); }
                if (bytes.length > 4096) throw new IllegalStateException("Synthetic photo exceeds bound");
                try (OutputStream stream = getContentResolver().openOutputStream(output, "w")) {
                    if (stream == null) throw new IllegalStateException("Missing output stream");
                    stream.write(bytes);
                    stream.flush();
                }
                StringBuilder digest = new StringBuilder();
                for (byte b : MessageDigest.getInstance("SHA-256").digest(bytes)) {
                    digest.append(String.format(java.util.Locale.ROOT, "%02x", b & 255));
                }
                status().edit().putInt("success", status().getInt("success", 0) + 1)
                        .putInt("bytes", bytes.length).putString("sha256", digest.toString())
                        .putBoolean("active", false).commit();
                setResult(RESULT_OK);
            } else if ("cancel".equals(command)) {
                status().edit().putInt("cancelled", status().getInt("cancelled", 0) + 1)
                        .putBoolean("active", false).commit();
                setResult(RESULT_CANCELED);
            } else { throw new IllegalArgumentException("Unknown camera outcome"); }
            finish();
        } catch (Exception error) { fail(error); }
    }

    private void fail(Exception error) {
        status().edit().putString("error", error.getClass().getSimpleName())
                .putBoolean("active", false).commit();
        setResult(RESULT_CANCELED);
        finish();
    }
}
