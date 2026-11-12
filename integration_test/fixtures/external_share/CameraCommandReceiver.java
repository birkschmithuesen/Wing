package com.tarkilhk.wing.shareqa.fixture;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;

/** Explicit shell commands for the isolated fixture only; never in the app. */
public final class CameraCommandReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context context, Intent intent) {
        if (!"com.tarkilhk.wing.shareqa.fixture.CAMERA_COMMAND".equals(intent.getAction())) return;
        String command = intent.getStringExtra("command");
        String nonce = intent.getStringExtra("nonce");
        if (nonce == null || !nonce.matches("[a-f0-9]{32}")) return;
        SharedPreferences prefs = context.getSharedPreferences("controlled_camera", 0);
        if ("configure".equals(command)) {
            if (ControlledCameraActivity.active != null) return;
            String mode = intent.getStringExtra("mode");
            if (!("held".equals(mode) || "cancel".equals(mode) || "success".equals(mode))) return;
            prefs.edit().putString("nonce", nonce).putString("mode", mode).remove("error").commit();
        } else {
            if (!nonce.equals(prefs.getString("nonce", ""))) return;
            if (!("cancel".equals(command) || "success".equals(command) || "recreate".equals(command))) return;
            ControlledCameraActivity activity = ControlledCameraActivity.active;
            if (activity == null) {
                prefs.edit().putString("error", "CameraNotActive").commit();
            } else { activity.complete(command); }
        }
        prefs.edit().putString("last_command", command)
                .putInt("command_seq", prefs.getInt("command_seq", 0) + 1).commit();
    }
}
