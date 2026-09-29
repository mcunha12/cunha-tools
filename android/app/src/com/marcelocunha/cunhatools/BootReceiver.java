package com.marcelocunha.cunhatools;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

// Starts the receiving service after boot and after an app update.
public final class BootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        AdbWifi.ensure(context);
        if (Prefs.pairing(context) != null && !Prefs.paused(context)) TransferService.start(context);
    }
}
