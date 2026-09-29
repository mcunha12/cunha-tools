package com.marcelocunha.cunhatools;

import android.content.Context;
import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;
import android.os.Build;
import com.marcelocunha.cunhatools.pfs.Wire;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

// Finds the paired Mac on the LAN through NSD (_cunhapfs._tcp, TXT id), only when a send needs it.
final class MacFinder {
    private MacFinder() {}

    static InetSocketAddress discover(Context context, String macId, long timeoutMs) {
        NsdManager nsd = context.getSystemService(NsdManager.class);
        CountDownLatch found = new CountDownLatch(1);
        AtomicReference<InetSocketAddress> result = new AtomicReference<>();
        Executor executor = context.getMainExecutor();
        NsdManager.DiscoveryListener listener = new NsdManager.DiscoveryListener() {
            @Override
            public void onServiceFound(NsdServiceInfo info) {
                if (result.get() == null) resolve(nsd, info, executor, macId, result, found);
            }

            @Override
            public void onServiceLost(NsdServiceInfo info) {}

            @Override
            public void onDiscoveryStarted(String type) {}

            @Override
            public void onDiscoveryStopped(String type) {}

            @Override
            public void onStartDiscoveryFailed(String type, int error) {
                found.countDown();
            }

            @Override
            public void onStopDiscoveryFailed(String type, int error) {}
        };
        try {
            nsd.discoverServices(Wire.SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener);
            found.await(timeoutMs, TimeUnit.MILLISECONDS);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        } catch (RuntimeException ignored) {
            // Discovery unavailable (no Wi-Fi); the caller reports the Mac as not found.
        } finally {
            try {
                nsd.stopServiceDiscovery(listener);
            } catch (RuntimeException ignored) {
            }
        }
        return result.get();
    }

    private static void resolve(NsdManager nsd, NsdServiceInfo info, Executor executor, String macId, AtomicReference<InetSocketAddress> result, CountDownLatch found) {
        if (Build.VERSION.SDK_INT >= 34) {
            NsdManager.ServiceInfoCallback callback = new NsdManager.ServiceInfoCallback() {
                @Override
                public void onServiceInfoCallbackRegistrationFailed(int error) {}

                @Override
                public void onServiceUpdated(NsdServiceInfo resolved) {
                    if (accept(resolved, resolved.getHostAddresses(), macId, result)) found.countDown();
                    try {
                        nsd.unregisterServiceInfoCallback(this);
                    } catch (RuntimeException ignored) {
                    }
                }

                @Override
                public void onServiceLost() {}

                @Override
                public void onServiceInfoCallbackUnregistered() {}
            };
            try {
                nsd.registerServiceInfoCallback(info, executor, callback);
            } catch (RuntimeException ignored) {
            }
        } else {
            resolveLegacy(nsd, info, macId, result, found);
        }
    }

    @SuppressWarnings("deprecation")
    private static void resolveLegacy(NsdManager nsd, NsdServiceInfo info, String macId, AtomicReference<InetSocketAddress> result, CountDownLatch found) {
        try {
            nsd.resolveService(info, new NsdManager.ResolveListener() {
                @Override
                public void onResolveFailed(NsdServiceInfo failed, int error) {}

                @Override
                public void onServiceResolved(NsdServiceInfo resolved) {
                    InetAddress host = resolved.getHost();
                    if (host != null && accept(resolved, java.util.Collections.singletonList(host), macId, result)) found.countDown();
                }
            });
        } catch (RuntimeException ignored) {
        }
    }

    private static boolean accept(NsdServiceInfo info, List<InetAddress> addresses, String macId, AtomicReference<InetSocketAddress> result) {
        Map<String, byte[]> attributes = info.getAttributes();
        String role = text(attributes.get("role"));
        String id = text(attributes.get("id"));
        if (!"mac".equals(role) || (macId != null && !macId.isEmpty() && !macId.equals(id))) return false;
        for (InetAddress address : addresses) {
            if (address instanceof Inet4Address) {
                return result.compareAndSet(null, new InetSocketAddress(address, info.getPort()));
            }
        }
        return !addresses.isEmpty() && result.compareAndSet(null, new InetSocketAddress(addresses.get(0), info.getPort()));
    }

    private static String text(byte[] value) {
        return value == null ? null : new String(value, StandardCharsets.UTF_8);
    }
}
