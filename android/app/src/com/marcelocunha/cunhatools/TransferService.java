package com.marcelocunha.cunhatools;

import android.app.Service;
import android.content.ClipData;
import android.content.Context;
import android.content.Intent;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.NetworkRequest;
import android.net.Uri;
import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;
import android.net.wifi.WifiManager;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.PowerManager;
import com.marcelocunha.cunhatools.pfs.Keys;
import com.marcelocunha.cunhatools.pfs.Peer;
import com.marcelocunha.cunhatools.pfs.Sender;
import com.marcelocunha.cunhatools.pfs.Server;
import com.marcelocunha.cunhatools.pfs.Session;
import com.marcelocunha.cunhatools.pfs.Source;
import com.marcelocunha.cunhatools.pfs.Wire;
import java.io.File;
import java.io.IOException;
import java.net.InetSocketAddress;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Set;
import java.util.concurrent.CopyOnWriteArraySet;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

// Foreground service (connectedDevice): TCP listener + NSD announcement, send queue, Wi-Fi watcher for adb over Wi-Fi.
public final class TransferService extends Service {
    static final String ACTION_SEND = "com.marcelocunha.cunhatools.SEND";
    static final String ACTION_CANCEL = "com.marcelocunha.cunhatools.CANCEL";
    static final String ACTION_PAUSE = "com.marcelocunha.cunhatools.PAUSE";

    // What the main screen shows; replaced as a whole so readers never see half an update.
    static final class Snapshot {
        final boolean receiving;
        final String activity;
        final int percent;
        final String last;

        Snapshot(boolean receiving, String activity, int percent, String last) {
            this.receiving = receiving;
            this.activity = activity;
            this.percent = percent;
            this.last = last;
        }
    }

    private static volatile Snapshot snapshot;
    private static volatile String lastResult;

    private final ExecutorService sends = Executors.newSingleThreadExecutor();
    private final Set<Session> sessions = new CopyOnWriteArraySet<>();
    private final Handler main = new Handler(Looper.getMainLooper());
    private Notifications notifications;
    private Server server;
    private NsdManager.RegistrationListener registration;
    private ConnectivityManager.NetworkCallback wifiCallback;
    private PowerManager.WakeLock wakeLock;
    private WifiManager.WifiLock wifiLock;
    private volatile Sender sender;
    private volatile String sendTitle;
    private long lastDone;
    private long lastTime;
    private double rate;
    private boolean ticking;

    static Snapshot snapshot() {
        return snapshot;
    }

    // Returns false when Android refuses a background start; the Mac then wakes the service over adb.
    static boolean start(Context context) {
        try {
            context.startForegroundService(new Intent(context, TransferService.class));
            return true;
        } catch (RuntimeException e) {
            return false;
        }
    }

    @Override
    public void onCreate() {
        super.onCreate();
        notifications = new Notifications(this);
        notifications.startForeground(this, "Pronto para receber do Mac");
        PowerManager power = getSystemService(PowerManager.class);
        wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "cunhatools:transfer");
        wifiLock = getSystemService(WifiManager.class).createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "cunhatools:transfer");
        watchWifi();
        AdbWifi.ensure(this);
        if (!Prefs.paused(this)) startReceiving();
        publish();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        // Every startForegroundService call must be answered with startForeground, even when already running.
        notifications.startForeground(this, server != null ? "Pronto para receber do Mac" : "Recebimento pausado");
        String action = intent == null ? null : intent.getAction();
        if (ACTION_SEND.equals(action)) {
            enqueueSend(uris(intent));
        } else if (ACTION_CANCEL.equals(action)) {
            Sender active = sender;
            if (active != null) active.cancel();
            for (Session session : sessions) session.cancel();
        } else if (ACTION_PAUSE.equals(action)) {
            Prefs.setPaused(this, true);
            stopReceiving();
            if (sender == null) stopSelf();
        } else if (Prefs.paused(this)) {
            Prefs.setPaused(this, false);
            startReceiving();
        } else {
            startReceiving();
            confirmPairing();
        }
        publish();
        return START_STICKY;
    }

    @Override
    public void onDestroy() {
        stopReceiving();
        Sender active = sender;
        if (active != null) active.cancel();
        sends.shutdownNow();
        if (wifiCallback != null) getSystemService(ConnectivityManager.class).unregisterNetworkCallback(wifiCallback);
        releaseLocks();
        notifications.clearProgress();
        snapshot = null;
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    // MARK: receiving

    private synchronized void startReceiving() {
        if (server != null) return;
        final Context context = this;
        Server created = new Server(Wire.PHONE_PORT, keyId -> {
            Prefs.Pairing pairing = Prefs.pairing(context);
            return pairing != null && Arrays.equals(Keys.keyId(pairing.key), keyId) ? pairing.key : null;
        }, Wire.ROLE_PHONE, Prefs.phoneId(this), Prefs.phoneName(this), new MediaStoreSink(this), new Server.Events() {
            @Override
            public void peer(Peer peer) {
                Prefs.updateMac(context, peer.name, peer.host, peer.port);
            }

            @Override
            public void started(Session session) {
                sessions.add(session);
                main.post(TransferService.this::beginActivity);
            }

            @Override
            public void ended(Session session, String error) {
                sessions.remove(session);
                main.post(() -> received(session, error));
            }
        });
        try {
            created.start();
            server = created;
            register();
        } catch (IOException e) {
            lastResult = "Recebimento indisponível: " + e.getMessage();
        }
    }

    private synchronized void stopReceiving() {
        if (server != null) server.close();
        server = null;
        if (registration != null) {
            try {
                getSystemService(NsdManager.class).unregisterService(registration);
            } catch (RuntimeException ignored) {
            }
            registration = null;
        }
    }

    private void register() {
        NsdServiceInfo info = new NsdServiceInfo();
        info.setServiceName("Cunha Tools " + Prefs.phoneName(this));
        info.setServiceType(Wire.SERVICE_TYPE);
        info.setPort(Wire.PHONE_PORT);
        info.setAttribute("role", "phone");
        info.setAttribute("id", Prefs.phoneId(this));
        registration = new NsdManager.RegistrationListener() {
            @Override
            public void onServiceRegistered(NsdServiceInfo registered) {}

            @Override
            public void onRegistrationFailed(NsdServiceInfo failed, int error) {}

            @Override
            public void onServiceUnregistered(NsdServiceInfo unregistered) {}

            @Override
            public void onUnregistrationFailed(NsdServiceInfo failed, int error) {}
        };
        try {
            getSystemService(NsdManager.class).registerService(info, NsdManager.PROTOCOL_DNS_SD, registration);
        } catch (RuntimeException e) {
            registration = null;
        }
    }

    private void received(Session session, String error) {
        endActivityIfIdle();
        String from = session.peer.name;
        if (error != null) {
            lastResult = "Recebimento de " + from + " falhou: " + error;
            if (!"cancelado".equals(error)) notifications.failed("Recebimento falhou", error);
            publish();
            return;
        }
        double seconds = Math.max((System.nanoTime() - session.startedAt) / 1e9, 0.001);
        String summary = Format.items(session.entries.length) + " · " + Format.bytes(session.total) + " · " + Format.rate(session.total / seconds);
        lastResult = "Recebido de " + from + ": " + summary;
        List<MediaStoreSink.Saved> saved = MediaStoreSink.saved(session);
        MediaStoreSink.Saved single = saved.size() == 1 ? saved.get(0) : null;
        String text = single != null ? session.entries[0].name() + " · " + Format.bytes(session.total) : summary;
        notifications.finished("Recebido de " + from, text, single == null ? null : single.uri, single == null ? null : single.mime);
        publish();
    }

    // Confirms a new pairing with the Mac, which learns this phone's id, name and address.
    private void confirmPairing() {
        if (!Prefs.needsConfirm(this)) return;
        final Context context = this;
        sends.execute(() -> {
            Prefs.Pairing pairing = Prefs.pairing(context);
            if (pairing == null) return;
            for (int attempt = 0; attempt < 3 && Prefs.needsConfirm(context); attempt++) {
                InetSocketAddress address = pairing.host == null ? null : new InetSocketAddress(pairing.host, pairing.port);
                if (address == null || !tryInfo(address, pairing)) {
                    address = MacFinder.discover(context, pairing.macId, 4000);
                    if (address == null || !tryInfo(address, pairing)) continue;
                }
                Prefs.setConfirmed(context);
                Prefs.updateMac(context, null, address.getAddress().getHostAddress(), address.getPort());
            }
        });
    }

    private boolean tryInfo(InetSocketAddress address, Prefs.Pairing pairing) {
        try {
            Peer mac = Sender.info(address, 1500, pairing.key, Wire.ROLE_PHONE, Prefs.phoneId(this), Prefs.phoneName(this), Wire.PHONE_PORT);
            Prefs.updateMac(this, mac.name, null, 0);
            return true;
        } catch (IOException e) {
            return false;
        }
    }

    // MARK: sending

    private static List<Uri> uris(Intent intent) {
        List<Uri> list = new ArrayList<>();
        ClipData clip = intent.getClipData();
        if (clip != null) for (int i = 0; i < clip.getItemCount(); i++) if (clip.getItemAt(i).getUri() != null) list.add(clip.getItemAt(i).getUri());
        return list;
    }

    private void enqueueSend(List<Uri> uris) {
        if (uris.isEmpty()) return;
        sends.execute(() -> send(uris));
    }

    private void send(List<Uri> uris) {
        Prefs.Pairing pairing = Prefs.pairing(this);
        if (pairing == null) return;
        List<File> spooled = new ArrayList<>();
        Sender active = new Sender(pairing.key, Wire.ROLE_PHONE, Prefs.phoneId(this), Prefs.phoneName(this));
        sendTitle = uris.size() == 1 ? "Enviando para " + pairing.macName : "Enviando " + Format.items(uris.size()) + " para " + pairing.macName;
        sender = active;
        main.post(this::beginActivity);
        String result;
        try {
            List<Source> sources = UriSource.from(this, uris, spooled);
            Sender.Result done = deliver(active, pairing, sources);
            result = "Enviado para " + pairing.macName + ": " + Format.items(done.files) + " · " + Format.bytes(done.bytes) + " · " + Format.rate(done.megabytesPerSecond() * 1e6);
        } catch (IOException | RuntimeException e) {
            result = "cancelado".equals(e.getMessage()) ? "Envio cancelado." : "Envio falhou: " + e.getMessage();
            if (!"cancelado".equals(e.getMessage())) main.post(() -> notifications.failed("Envio falhou", String.valueOf(e.getMessage())));
        } finally {
            for (File file : spooled) file.delete();
        }
        final String text = result;
        sender = null;
        main.post(() -> {
            lastResult = text;
            endActivityIfIdle();
            if (Prefs.paused(this) && sessions.isEmpty()) stopSelf();
        });
    }

    // Last known address first; if the Mac does not answer, NSD finds its current one.
    private Sender.Result deliver(Sender active, Prefs.Pairing pairing, List<Source> sources) throws IOException {
        if (pairing.host != null) {
            try {
                return active.send(new InetSocketAddress(pairing.host, pairing.port), sources, Wire.CONNECTIONS);
            } catch (Sender.UnreachableException ignored) {
                // Fall through to discovery.
            }
        }
        InetSocketAddress found = MacFinder.discover(this, pairing.macId, 5000);
        if (found == null) throw new IOException("Mac não encontrado na rede. Confira se o Pair File Sharing está aberto e no mesmo Wi-Fi.");
        Prefs.updateMac(this, null, found.getAddress().getHostAddress(), found.getPort());
        return active.send(found, sources, Wire.CONNECTIONS);
    }

    // MARK: progress

    private void beginActivity() {
        if (!wakeLock.isHeld()) wakeLock.acquire(6 * 60 * 60 * 1000L);
        if (!wifiLock.isHeld()) wifiLock.acquire();
        lastDone = 0;
        lastTime = System.nanoTime();
        rate = 0;
        if (!ticking) {
            ticking = true;
            main.post(this::tick);
        }
    }

    private void endActivityIfIdle() {
        if (sender != null || !sessions.isEmpty()) return;
        releaseLocks();
        notifications.clearProgress();
        publish();
    }

    private void releaseLocks() {
        if (wakeLock != null && wakeLock.isHeld()) wakeLock.release();
        if (wifiLock != null && wifiLock.isHeld()) wifiLock.release();
    }

    private void tick() {
        Sender active = sender;
        Session session = sessions.isEmpty() ? null : sessions.iterator().next();
        if (active == null && session == null) {
            ticking = false;
            return;
        }
        long done = active != null ? active.sent() : session.received();
        long total = active != null ? active.total() : session.total;
        String title = active != null ? sendTitle : "Recebendo de " + session.peer.name;
        long now = System.nanoTime();
        double seconds = (now - lastTime) / 1e9;
        if (seconds > 0 && done >= lastDone) rate = rate == 0 ? (done - lastDone) / seconds : 0.7 * rate + 0.3 * (done - lastDone) / seconds;
        lastDone = done;
        lastTime = now;
        String detail = Format.bytes(done) + " de " + Format.bytes(total) + " · " + Format.rate(rate);
        if (rate > 0 && total > done) detail += " · faltam " + Format.duration((total - done) / rate);
        notifications.progress(title, done, total, detail);
        int percent = total > 0 ? (int) (done * 100 / total) : 0;
        snapshot = new Snapshot(server != null, title + "\n" + detail, percent, lastResult);
        main.postDelayed(this::tick, 500);
    }

    private void publish() {
        boolean receiving = server != null;
        snapshot = new Snapshot(receiving, null, 0, lastResult);
        notifications.updateService(receiving ? "Pronto para receber do Mac" : "Recebimento pausado");
    }

    // Wi-Fi comes back: re-enable adb over Wi-Fi when the user keeps that toggle on.
    private void watchWifi() {
        wifiCallback = new ConnectivityManager.NetworkCallback() {
            @Override
            public void onAvailable(Network network) {
                AdbWifi.ensure(TransferService.this);
            }
        };
        NetworkRequest request = new NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build();
        getSystemService(ConnectivityManager.class).registerNetworkCallback(request, wifiCallback);
    }
}
