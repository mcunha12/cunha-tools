package com.marcelocunha.cunhatools;

import android.app.Activity;
import android.app.AlertDialog;
import android.net.Uri;
import android.os.Bundle;
import android.widget.Toast;
import com.marcelocunha.cunhatools.pfs.Keys;
import com.marcelocunha.cunhatools.pfs.Wire;

// cunhatools://pair?k=<key>&n=<Mac>&id=<Mac id>&h=<host>&p=<port>, opened by the camera from the Mac's QR code.
public final class PairActivity extends Activity {
    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        Uri uri = getIntent().getData();
        final Prefs.Pairing pairing = uri == null ? null : parse(uri);
        if (pairing == null) {
            Toast.makeText(this, "Código de pareamento inválido.", Toast.LENGTH_LONG).show();
            finish();
            return;
        }
        new AlertDialog.Builder(this)
            .setTitle("Parear com " + pairing.macName + "?")
            .setMessage("Este Mac vai poder enviar e receber arquivos deste celular pela rede Wi-Fi.")
            .setPositiveButton("Parear", (dialog, which) -> {
                Prefs.savePairing(this, pairing);
                TransferService.start(this);
                Toast.makeText(this, "Pareado com " + pairing.macName + ".", Toast.LENGTH_SHORT).show();
                finish();
            })
            .setNegativeButton("Cancelar", (dialog, which) -> finish())
            .setOnCancelListener(dialog -> finish())
            .show();
    }

    private static Prefs.Pairing parse(Uri uri) {
        try {
            byte[] key = Keys.decode(uri.getQueryParameter("k"));
            if (key.length != Keys.KEY_SIZE) return null;
            String name = uri.getQueryParameter("n");
            String host = uri.getQueryParameter("h");
            String port = uri.getQueryParameter("p");
            return new Prefs.Pairing(key, orEmpty(uri.getQueryParameter("id")), name == null || name.isEmpty() ? "Mac" : name,
                host == null || host.isEmpty() ? null : host, port == null ? Wire.MAC_PORT : Integer.parseInt(port));
        } catch (RuntimeException e) {
            return null;
        }
    }

    private static String orEmpty(String value) {
        return value == null ? "" : value;
    }
}
