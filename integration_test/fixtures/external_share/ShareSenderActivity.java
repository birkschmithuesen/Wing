package com.tarkilhk.wing.shareqa.fixture;

import android.app.Activity;
import android.content.ClipData;
import android.content.ComponentName;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import java.util.ArrayList;

/** Sends only synthetic content to the isolated notification QA package. */
public final class ShareSenderActivity extends Activity {
    private static final String TARGET = "com.tarkilhk.wing.notificationqa";

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        String mode = getIntent().getStringExtra("mode");
        String nonce = getIntent().getStringExtra("nonce");
        if (!("no-grant".equals(mode) || "grant".equals(mode) || "mixed".equals(mode)
                || "stall-type".equals(mode) || "stall-query".equals(mode)
                || "stall-open".equals(mode) || "stall-read".equals(mode))
                || nonce == null || !nonce.matches("[a-f0-9]{32}")) {
            finish();
            return;
        }
        Uri uri = Uri.parse("content://" + ProbeProvider.AUTHORITY + "/blob/" + nonce);
        if (mode.startsWith("stall-")) {
            uri = uri.buildUpon().appendQueryParameter("fault", mode.substring(6)).build();
        }
        Intent share = new Intent("mixed".equals(mode) ? Intent.ACTION_SEND_MULTIPLE : Intent.ACTION_SEND);
        share.setComponent(new ComponentName(TARGET, "com.tarkilhk.wing.MainActivity"));
        share.setType("text/plain");
        share.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        // Keep grant-bearing ClipData limited to our own URI. The mixed stream
        // list additionally tests Wing's preflight of a URI this sender cannot grant.
        share.setClipData(ClipData.newRawUri("Owned share fixture", uri));
        if ("mixed".equals(mode)) {
            ArrayList<Uri> streams = new ArrayList<>();
            streams.add(uri);
            streams.add(Uri.parse("content://" + TARGET + ".fileprovider/delivered_outputs/share-boundary-marker.txt"));
            share.putParcelableArrayListExtra(Intent.EXTRA_STREAM, streams);
        } else {
            share.putExtra(Intent.EXTRA_STREAM, uri);
        }
        if (!"no-grant".equals(mode)) share.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        try {
            getSharedPreferences("sender", 0).edit()
                    .putLong("dispatch_started_ms", android.os.SystemClock.elapsedRealtime()).commit();
            startActivity(share);
            getSharedPreferences("sender", 0).edit()
                    .putLong("dispatch_returned_ms", android.os.SystemClock.elapsedRealtime())
                    .putString("sent", mode + ":" + nonce).remove("error").commit();
        } catch (RuntimeException error) {
            getSharedPreferences("sender", 0).edit()
                    .putString("error", error.getClass().getSimpleName()).commit();
        }
        finish();
    }
}
