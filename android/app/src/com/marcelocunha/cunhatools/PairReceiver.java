package com.marcelocunha.cunhatools;

import android.app.Activity;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import com.marcelocunha.cunhatools.pfs.Keys;
import com.marcelocunha.cunhatools.pfs.Wire;

// adb shell am broadcast -a com.marcelocunha.cunhatools.PAIR -n com.marcelocunha.cunhatools/.PairReceiver ... (see PROTOCOL.md)
public final class PairReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        String key = intent.getStringExtra("key");
        byte[] bytes;
        try {
            bytes = key == null ? null : Keys.decode(key);
        } catch (IllegalArgumentException e) {
            bytes = null;
        }
        if (bytes == null || bytes.length != Keys.KEY_SIZE) {
            setResultCode(Activity.RESULT_CANCELED);
            setResultData("erro|chave inválida|");
            return;
        }
        String name = intent.getStringExtra("mac_name");
        String host = intent.getStringExtra("host");
        int port = intent.getIntExtra("port", Wire.MAC_PORT);
        Prefs.savePairing(context, new Prefs.Pairing(bytes, orEmpty(intent.getStringExtra("mac_id")), name == null ? "Mac" : name, host == null || host.isEmpty() ? null : host, port));
        setResultCode(Activity.RESULT_OK);
        setResultData("ok|" + Prefs.phoneId(context) + "|" + Prefs.phoneName(context));
        TransferService.start(context);
    }

    private static String orEmpty(String value) {
        return value == null ? "" : value;
    }
}
