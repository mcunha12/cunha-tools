package com.marcelocunha.cunhatools;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Typeface;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.PowerManager;
import android.provider.Settings;
import android.util.TypedValue;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.ScrollView;
import android.widget.Switch;
import android.widget.TextView;

// Main screen: pairing and service status, send/pause buttons, the adb-over-Wi-Fi toggle, battery hint.
public final class MainActivity extends Activity {
    private static final int PICK_FILES = 1;

    private final Handler main = new Handler(Looper.getMainLooper());
    private TextView pairingText;
    private TextView serviceText;
    private TextView activityText;
    private ProgressBar progress;
    private Button cancelButton;
    private Button pauseButton;
    private TextView lastText;
    private Switch adbSwitch;
    private TextView adbHint;
    private LinearLayout batteryRow;
    private final Runnable refresher = new Runnable() {
        @Override
        public void run() {
            refresh();
            main.postDelayed(this, 500);
        }
    };

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        setContentView(build());
        if (!Prefs.askedNotifications(this) && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            Prefs.setAskedNotifications(this);
            requestPermissions(new String[] {Manifest.permission.POST_NOTIFICATIONS}, 2);
        }
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (Prefs.pairing(this) != null && !Prefs.paused(this)) TransferService.start(this);
        AdbWifi.ensure(this);
        main.post(refresher);
    }

    @Override
    protected void onPause() {
        main.removeCallbacks(refresher);
        super.onPause();
    }

    private View build() {
        LinearLayout column = new LinearLayout(this);
        column.setOrientation(LinearLayout.VERTICAL);
        int pad = dp(20);
        column.setPadding(pad, pad, pad, pad);

        TextView title = text("Pair File Sharing", 24);
        title.setTypeface(Typeface.DEFAULT_BOLD);
        column.addView(title);
        pairingText = text("", 16);
        column.addView(pairingText, spaced(8));
        serviceText = text("", 14);
        column.addView(serviceText, spaced(2));

        LinearLayout buttons = new LinearLayout(this);
        buttons.setOrientation(LinearLayout.HORIZONTAL);
        Button sendButton = new Button(this);
        sendButton.setText("Enviar arquivos");
        sendButton.setOnClickListener(v -> pickFiles());
        buttons.addView(sendButton, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1));
        pauseButton = new Button(this);
        pauseButton.setOnClickListener(v -> togglePause());
        buttons.addView(pauseButton, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1));
        column.addView(buttons, spaced(16));

        activityText = text("", 14);
        column.addView(activityText, spaced(16));
        progress = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
        progress.setMax(100);
        column.addView(progress, spaced(4));
        cancelButton = new Button(this);
        cancelButton.setText("Cancelar transferência");
        cancelButton.setOnClickListener(v -> startService(new Intent(this, TransferService.class).setAction(TransferService.ACTION_CANCEL)));
        column.addView(cancelButton, spaced(4));
        lastText = text("", 13);
        column.addView(lastText, spaced(12));

        adbSwitch = new Switch(this);
        adbSwitch.setText("Manter depuração sem fio ligada");
        adbSwitch.setOnCheckedChangeListener((view, checked) -> {
            Prefs.setKeepAdbWifi(this, checked);
            if (checked) AdbWifi.ensure(this);
        });
        column.addView(adbSwitch, spaced(24));
        adbHint = text("Usado pelo espelhamento de tela. Libere pelo Cunha Tools no Mac com o celular no cabo.", 12);
        column.addView(adbHint, spaced(2));

        batteryRow = new LinearLayout(this);
        batteryRow.setOrientation(LinearLayout.VERTICAL);
        batteryRow.addView(text("O Android pode encerrar o serviço em segundo plano. Libere o uso de bateria para receber arquivos com a tela apagada.", 13));
        Button battery = new Button(this);
        battery.setText("Liberar bateria");
        battery.setOnClickListener(v -> askBattery());
        batteryRow.addView(battery);
        column.addView(batteryRow, spaced(24));

        ScrollView scroll = new ScrollView(this);
        scroll.setFitsSystemWindows(true);
        scroll.addView(column);
        return scroll;
    }

    private void refresh() {
        Prefs.Pairing pairing = Prefs.pairing(this);
        pairingText.setText(pairing == null ? "Não pareado. Abra o Pair File Sharing no Mac e escolha Parear celular." : "Pareado com " + pairing.macName);
        TransferService.Snapshot snapshot = TransferService.snapshot();
        boolean paused = Prefs.paused(this);
        boolean receiving = snapshot != null && snapshot.receiving;
        serviceText.setText(receiving ? "Serviço ativo. Recebidos vão para Download/Pair File Sharing." : paused ? "Serviço pausado." : "Serviço parado.");
        pauseButton.setText(paused || !receiving ? "Retomar serviço" : "Pausar serviço");
        pauseButton.setEnabled(pairing != null);
        boolean busy = snapshot != null && snapshot.activity != null;
        activityText.setVisibility(busy ? View.VISIBLE : View.GONE);
        progress.setVisibility(busy ? View.VISIBLE : View.GONE);
        cancelButton.setVisibility(busy ? View.VISIBLE : View.GONE);
        if (busy) {
            activityText.setText(snapshot.activity);
            progress.setProgress(snapshot.percent);
        }
        String last = snapshot == null ? null : snapshot.last;
        lastText.setVisibility(last == null ? View.GONE : View.VISIBLE);
        lastText.setText(last == null ? "" : last);
        boolean canWrite = AdbWifi.canWrite(this);
        adbSwitch.setEnabled(canWrite);
        adbSwitch.setChecked(Prefs.keepAdbWifi(this));
        adbHint.setVisibility(canWrite ? View.GONE : View.VISIBLE);
        PowerManager power = getSystemService(PowerManager.class);
        batteryRow.setVisibility(power.isIgnoringBatteryOptimizations(getPackageName()) ? View.GONE : View.VISIBLE);
    }

    private void togglePause() {
        TransferService.Snapshot snapshot = TransferService.snapshot();
        if (snapshot != null && snapshot.receiving) {
            startService(new Intent(this, TransferService.class).setAction(TransferService.ACTION_PAUSE));
        } else {
            Prefs.setPaused(this, false);
            TransferService.start(this);
        }
    }

    private void pickFiles() {
        Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*").putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true);
        startActivityForResult(intent, PICK_FILES);
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == PICK_FILES && resultCode == RESULT_OK) ShareActivity.send(this, ShareActivity.collect(data));
    }

    private void askBattery() {
        Intent intent = new Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:" + getPackageName()));
        try {
            startActivity(intent);
        } catch (RuntimeException e) {
            startActivity(new Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS));
        }
    }

    private TextView text(String value, int sp) {
        TextView view = new TextView(this);
        view.setText(value);
        view.setTextSize(TypedValue.COMPLEX_UNIT_SP, sp);
        return view;
    }

    private LinearLayout.LayoutParams spaced(int topDp) {
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        params.topMargin = dp(topDp);
        return params;
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }
}
