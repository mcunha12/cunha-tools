package com.marcelocunha.cunhatools.pfs.jvm;

import com.marcelocunha.cunhatools.pfs.FileSource;
import com.marcelocunha.cunhatools.pfs.Keys;
import com.marcelocunha.cunhatools.pfs.Peer;
import com.marcelocunha.cunhatools.pfs.SecureChannel;
import com.marcelocunha.cunhatools.pfs.Sender;
import com.marcelocunha.cunhatools.pfs.Server;
import com.marcelocunha.cunhatools.pfs.Session;
import com.marcelocunha.cunhatools.pfs.Source;
import com.marcelocunha.cunhatools.pfs.Wire;
import java.io.File;
import java.net.InetSocketAddress;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.CountDownLatch;

// JVM harness that plays the phone against the Mac app: receive, send, info, wrongkey.
public final class Cli {
    public static void main(String[] args) throws Exception {
        SecureChannel.socketBuffer = 4 << 20;
        if (args.length == 0) usage();
        switch (args[0]) {
            case "receive": receive(Integer.parseInt(args[1]), Keys.decode(args[2]), new File(args[3])); break;
            case "send": send(args[1], Integer.parseInt(args[2]), Keys.decode(args[3]), Integer.parseInt(args[4]), Arrays.copyOfRange(args, 5, args.length)); break;
            case "info": info(args[1], Integer.parseInt(args[2]), Keys.decode(args[3]), Keys.keyId(Keys.decode(args[3]))); break;
            case "wrongkey": wrongKey(args[1], Integer.parseInt(args[2]), Keys.decode(args[3])); break;
            default: usage();
        }
    }

    private static void usage() {
        System.err.println("uso: receive <porta> <chave> <pasta> | send <host> <porta> <chave> <conexões> <caminho>... | info <host> <porta> <chave> | wrongkey <host> <porta> <chave>");
        System.exit(2);
    }

    // Serves exactly one transfer, prints MB/s and exits 0 on success.
    private static void receive(int port, byte[] key, File folder) throws Exception {
        CountDownLatch done = new CountDownLatch(1);
        String[] error = new String[1];
        Server server = new Server(port, id -> Arrays.equals(id, Keys.keyId(key)) ? key : null, Wire.ROLE_PHONE, "jvm-phone", "JVM", new DirSink(folder), new Server.Events() {
            @Override
            public void peer(Peer peer) {}

            @Override
            public void started(Session session) {
                System.err.println("recebendo " + session.entries.length + " itens, " + session.total + " bytes de " + session.peer.name);
            }

            @Override
            public void ended(Session session, String reason) {
                double seconds = (System.nanoTime() - session.startedAt) / 1e9;
                if (reason == null) System.out.printf("recebido: %d itens, %d bytes em %.2f s = %.0f MB/s%n", session.entries.length, session.total, seconds, session.total / seconds / 1e6);
                error[0] = reason;
                done.countDown();
            }
        });
        server.start();
        System.err.println("ouvindo na porta " + server.port());
        done.await();
        server.close();
        if (error[0] != null) {
            System.err.println("falhou: " + error[0]);
            System.exit(1);
        }
    }

    private static void send(String host, int port, byte[] key, int connections, String[] paths) throws Exception {
        List<File> roots = new ArrayList<>();
        for (String path : paths) roots.add(new File(path));
        List<Source> sources = FileSource.collect(roots);
        Sender sender = new Sender(key, Wire.ROLE_PHONE, "jvm-phone", "JVM");
        Sender.Result result = sender.send(new InetSocketAddress(host, port), sources, connections);
        System.out.printf("enviado: %d itens, %d bytes em %.2f s = %.0f MB/s (%d conexões)%n", result.files, result.bytes, result.nanos / 1e9, result.megabytesPerSecond(), connections);
    }

    private static void info(String host, int port, byte[] key, byte[] keyId) throws Exception {
        Peer peer = Sender.info(new InetSocketAddress(host, port), 2000, key, Wire.ROLE_PHONE, "jvm-phone", "JVM", Wire.PHONE_PORT);
        System.out.println("info: " + peer.name + " id=" + peer.id + " porta=" + peer.port);
    }

    // Both cases must fail: an unknown key id, and a known key id presented with the wrong key.
    private static void wrongKey(String host, int port, byte[] realKey) throws Exception {
        InetSocketAddress address = new InetSocketAddress(host, port);
        int failures = 0;
        byte[] wrong = Keys.random(32);
        try {
            SecureChannel.connect(address, 2000, wrong, Wire.ROLE_PHONE).close();
            System.out.println("ERRO: chave desconhecida aceita");
        } catch (SecureChannel.AuthException e) {
            System.out.println("chave desconhecida rejeitada: " + e.getMessage());
            failures++;
        }
        try {
            SecureChannel.connect(address, 2000, wrong, Keys.keyId(realKey), Wire.ROLE_PHONE).close();
            System.out.println("ERRO: chave errada com id conhecido aceita");
        } catch (SecureChannel.AuthException e) {
            System.out.println("chave errada com id conhecido rejeitada: " + e.getMessage());
            failures++;
        }
        System.exit(failures == 2 ? 0 : 1);
    }
}
