package com.marcelocunha.cunhatools;

import android.app.DownloadManager;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;

final class Notifications {
    static final int SERVICE = 1;
    static final int PROGRESS = 2;
    private static final String CHANNEL_SERVICE = "service";
    private static final String CHANNEL_PROGRESS = "progress";
    private static final String CHANNEL_DONE = "done";

    private final Context context;
    private final NotificationManager manager;
    private int nextId = 100;

    Notifications(Context context) {
        this.context = context;
        manager = context.getSystemService(NotificationManager.class);
        manager.createNotificationChannel(new NotificationChannel(CHANNEL_SERVICE, "Serviço ativo", NotificationManager.IMPORTANCE_MIN));
        manager.createNotificationChannel(new NotificationChannel(CHANNEL_PROGRESS, "Transferências em andamento", NotificationManager.IMPORTANCE_LOW));
        manager.createNotificationChannel(new NotificationChannel(CHANNEL_DONE, "Transferências concluídas", NotificationManager.IMPORTANCE_DEFAULT));
    }

    Notification service(String text) {
        return new Notification.Builder(context, CHANNEL_SERVICE)
            .setSmallIcon(R.drawable.ic_stat_transfer)
            .setContentTitle("Pair File Sharing")
            .setContentText(text)
            .setOngoing(true)
            .setShowWhen(false)
            .setContentIntent(openApp())
            .build();
    }

    void updateService(String text) {
        manager.notify(SERVICE, service(text));
    }

    void progress(String title, long done, long total, String detail) {
        int percent = total > 0 ? (int) Math.min(100, done * 100 / total) : 0;
        Intent cancel = new Intent(context, TransferService.class).setAction(TransferService.ACTION_CANCEL);
        Notification notification = new Notification.Builder(context, CHANNEL_PROGRESS)
            .setSmallIcon(R.drawable.ic_stat_transfer)
            .setContentTitle(title)
            .setContentText(detail)
            .setProgress(100, percent, total <= 0)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setContentIntent(openApp())
            .addAction(new Notification.Action.Builder(null, "Cancelar", PendingIntent.getService(context, 1, cancel, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT)).build())
            .build();
        manager.notify(PROGRESS, notification);
    }

    void clearProgress() {
        manager.cancel(PROGRESS);
    }

    // One file opens in its viewer; several open the Downloads screen.
    void finished(String title, String text, Uri single, String mime) {
        Intent open = single != null
            ? new Intent(Intent.ACTION_VIEW).setDataAndType(single, mime).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_ACTIVITY_NEW_TASK)
            : new Intent(DownloadManager.ACTION_VIEW_DOWNLOADS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        post(title, text, PendingIntent.getActivity(context, nextId, open, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT));
    }

    void failed(String title, String text) {
        post(title, text, openApp());
    }

    private void post(String title, String text, PendingIntent intent) {
        manager.notify(nextId++, new Notification.Builder(context, CHANNEL_DONE)
            .setSmallIcon(R.drawable.ic_stat_transfer)
            .setContentTitle(title)
            .setContentText(text)
            .setAutoCancel(true)
            .setContentIntent(intent)
            .build());
    }

    private PendingIntent openApp() {
        Intent intent = new Intent(context, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP);
        return PendingIntent.getActivity(context, 0, intent, PendingIntent.FLAG_IMMUTABLE);
    }

    void startForeground(Service service, String text) {
        service.startForeground(SERVICE, service(text), android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE);
    }
}
