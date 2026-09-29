package com.marcelocunha.cunhatools.pfs;

// The other side as it introduced itself, plus the address it connected from.
public final class Peer {
    public final String id;
    public final String name;
    public final String host;
    public final int port;
    public final byte[] keyId;

    public Peer(String id, String name, String host, int port, byte[] keyId) {
        this.id = id;
        this.name = name;
        this.host = host;
        this.port = port;
        this.keyId = keyId;
    }
}
