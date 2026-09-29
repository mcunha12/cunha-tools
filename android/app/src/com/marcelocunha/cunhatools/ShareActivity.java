package com.marcelocunha.cunhatools;

import android.app.Activity;
import android.content.ClipData;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.widget.Toast;
import java.util.ArrayList;
import java.util.List;

// Share sheet target "Enviar para o Mac": hands the URIs, with their read grants, to the service.
public final class ShareActivity extends Activity {
    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        List<Uri> uris = collect(getIntent());
        send(this, uris);
        finish();
    }

    static void send(Context context, List<Uri> uris) {
        Prefs.Pairing pairing = Prefs.pairing(context);
        if (pairing == null) {
            Toast.makeText(context, "Pareie com o Mac primeiro: abra o Pair File Sharing no Mac.", Toast.LENGTH_LONG).show();
            return;
        }
        if (uris.isEmpty()) {
            Toast.makeText(context, "Nada para enviar.", Toast.LENGTH_SHORT).show();
            return;
        }
        Intent intent = new Intent(context, TransferService.class).setAction(TransferService.ACTION_SEND);
        ClipData clip = ClipData.newRawUri("arquivos", uris.get(0));
        for (int i = 1; i < uris.size(); i++) clip.addItem(new ClipData.Item(uris.get(i)));
        intent.setClipData(clip);
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        context.startForegroundService(intent);
        Toast.makeText(context, "Enviando para " + pairing.macName + "…", Toast.LENGTH_SHORT).show();
    }

    @SuppressWarnings("deprecation")
    static List<Uri> collect(Intent intent) {
        List<Uri> uris = new ArrayList<>();
        if (intent == null) return uris;
        ClipData clip = intent.getClipData();
        if (clip != null) {
            for (int i = 0; i < clip.getItemCount(); i++) {
                Uri uri = clip.getItemAt(i).getUri();
                if (uri != null && !uris.contains(uri)) uris.add(uri);
            }
        }
        if (Intent.ACTION_SEND.equals(intent.getAction())) {
            Uri uri = intent.getParcelableExtra(Intent.EXTRA_STREAM);
            if (uri != null && !uris.contains(uri)) uris.add(uri);
        } else if (Intent.ACTION_SEND_MULTIPLE.equals(intent.getAction())) {
            ArrayList<Uri> list = intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM);
            if (list != null) for (Uri uri : list) if (uri != null && !uris.contains(uri)) uris.add(uri);
        } else if (intent.getData() != null && !uris.contains(intent.getData())) {
            uris.add(intent.getData());
        }
        return uris;
    }
}
