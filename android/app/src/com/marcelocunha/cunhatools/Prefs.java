package com.marcelocunha.cunhatools;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.Build;
import android.provider.Settings;
import com.marcelocunha.cunhatools.pfs.Keys;
import com.marcelocunha.cunhatools.pfs.Wire;

// App state in private SharedPreferences: identity, pairing with the Mac, toggles.
final class Prefs {
    private Prefs() {}

    static final class Pairing {
        final byte[] key;
        final String macId;
        final String macName;
        final String host;
        final int port;

        Pairing(byte[] key, String macId, String macName, String host, int port) {
            this.key = key;
            this.macId = macId;
            this.macName = macName;
            this.host = host;
            this.port = port;
        }
    }

    private static SharedPreferences of(Context context) {
        return context.getSharedPreferences("cunhatools", Context.MODE_PRIVATE);
    }

    static synchronized String phoneId(Context context) {
        String id = of(context).getString("phone_id", null);
        if (id == null) {
            id = Keys.hex(Keys.random(16));
            of(context).edit().putString("phone_id", id).apply();
        }
        return id;
    }

    static String phoneName(Context context) {
        String name = Settings.Global.getString(context.getContentResolver(), "device_name");
        return name == null || name.isEmpty() ? Build.MODEL : name;
    }

    static Pairing pairing(Context context) {
        SharedPreferences p = of(context);
        String key = p.getString("key", null);
        if (key == null) return null;
        try {
            byte[] bytes = Keys.decode(key);
            if (bytes.length != Keys.KEY_SIZE) return null;
            return new Pairing(bytes, p.getString("mac_id", ""), p.getString("mac_name", "Mac"), p.getString("mac_host", null), p.getInt("mac_port", Wire.MAC_PORT));
        } catch (IllegalArgumentException e) {
            return null;
        }
    }

    static void savePairing(Context context, Pairing pairing) {
        of(context).edit()
            .putString("key", Keys.encode(pairing.key))
            .putString("mac_id", pairing.macId)
            .putString("mac_name", pairing.macName)
            .putString("mac_host", pairing.host)
            .putInt("mac_port", pairing.port)
            .putBoolean("needs_confirm", true)
            .putBoolean("paused", false)
            .apply();
    }

    static void updateMac(Context context, String name, String host, int port) {
        SharedPreferences.Editor editor = of(context).edit();
        if (name != null && !name.isEmpty()) editor.putString("mac_name", name);
        if (host != null) editor.putString("mac_host", host);
        if (port > 0) editor.putInt("mac_port", port);
        editor.apply();
    }

    static boolean needsConfirm(Context context) {
        return of(context).getBoolean("needs_confirm", false);
    }

    static void setConfirmed(Context context) {
        of(context).edit().putBoolean("needs_confirm", false).apply();
    }

    static boolean paused(Context context) {
        return of(context).getBoolean("paused", false);
    }

    static void setPaused(Context context, boolean paused) {
        of(context).edit().putBoolean("paused", paused).apply();
    }

    static boolean keepAdbWifi(Context context) {
        return of(context).getBoolean("keep_adb_wifi", true);
    }

    static void setKeepAdbWifi(Context context, boolean keep) {
        of(context).edit().putBoolean("keep_adb_wifi", keep).apply();
    }

    static boolean askedNotifications(Context context) {
        return of(context).getBoolean("asked_notifications", false);
    }

    static void setAskedNotifications(Context context) {
        of(context).edit().putBoolean("asked_notifications", true).apply();
    }
}
