package com.tarkilhk.wing.shareqa.fixture;

import android.app.Activity;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.net.Uri;
import android.os.Bundle;

/** Supplies one synthetic image through Android's actual clipboard grant. */
public final class ClipboardSenderActivity extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        ClipboardManager clipboard = getSystemService(ClipboardManager.class);
        clipboard.setPrimaryClip(ClipData.newUri(getContentResolver(),
                "Wing clipboard fixture", Uri.parse(ClipboardFixtureProvider.URI)));
        finish();
    }
}
