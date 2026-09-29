package com.marcelocunha.cunhatools;

import android.Manifest;
import android.content.Context;
import android.content.pm.PackageManager;
import android.provider.Settings;

// Keeps Wireless debugging on for the screen mirroring tool; needs WRITE_SECURE_SETTINGS granted over adb.
final class AdbWifi {
    private AdbWifi() {}

    static boolean canWrite(Context context) {
        return context.checkSelfPermission(Manifest.permission.WRITE_SECURE_SETTINGS) == PackageManager.PERMISSION_GRANTED;
    }

    static void ensure(Context context) {
        if (!Prefs.keepAdbWifi(context) || !canWrite(context)) return;
        try {
            if (Settings.Global.getInt(context.getContentResolver(), "adb_wifi_enabled", 0) != 1) {
                Settings.Global.putInt(context.getContentResolver(), "adb_wifi_enabled", 1);
            }
        } catch (SecurityException ignored) {
            // Permission revoked since the check; nothing else to do.
        }
    }
}
