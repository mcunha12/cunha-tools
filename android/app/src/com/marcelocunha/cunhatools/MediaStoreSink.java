package com.marcelocunha.cunhatools;

import android.content.ContentResolver;
import android.content.ContentValues;
import android.content.Context;
import android.net.Uri;
import android.os.Environment;
import android.os.ParcelFileDescriptor;
import android.provider.MediaStore;
import android.system.ErrnoException;
import android.system.Os;
import android.webkit.MimeTypeMap;
import com.marcelocunha.cunhatools.pfs.Entry;
import com.marcelocunha.cunhatools.pfs.Server;
import com.marcelocunha.cunhatools.pfs.Session;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Locale;

// Receives into Download/Pair File Sharing through MediaStore: pending item, positional writes, publish on completion.
final class MediaStoreSink implements Server.Sink {
    static final String FOLDER = Environment.DIRECTORY_DOWNLOADS + "/Pair File Sharing";

    static final class Saved {
        final Uri uri;
        final String mime;

        Saved(Uri uri, String mime) {
            this.uri = uri;
            this.mime = mime;
        }
    }

    private final ContentResolver resolver;

    MediaStoreSink(Context context) {
        resolver = context.getContentResolver();
    }

    @SuppressWarnings("unchecked")
    static List<Saved> saved(Session session) {
        synchronized (session) {
            if (session.sinkState == null) session.sinkState = Collections.synchronizedList(new ArrayList<Saved>());
            return (List<Saved>) session.sinkState;
        }
    }

    @Override
    public long usableSpace() {
        return Environment.getDataDirectory().getUsableSpace();
    }

    @Override
    public Server.Target create(Session session, int index) throws IOException {
        Entry entry = session.entries[index];
        String parent = entry.path.lastIndexOf('/') < 0 ? "" : "/" + entry.path.substring(0, entry.path.lastIndexOf('/'));
        String mime = mime(entry.name());
        ContentValues values = new ContentValues();
        values.put(MediaStore.MediaColumns.DISPLAY_NAME, entry.name());
        values.put(MediaStore.MediaColumns.MIME_TYPE, mime);
        values.put(MediaStore.MediaColumns.RELATIVE_PATH, FOLDER + parent + "/");
        values.put(MediaStore.MediaColumns.IS_PENDING, 1);
        final Uri uri;
        try {
            uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values);
        } catch (RuntimeException e) {
            throw new IOException("MediaStore recusou " + entry.path + ": " + e.getMessage());
        }
        if (uri == null) throw new IOException("MediaStore recusou " + entry.path);
        final ParcelFileDescriptor descriptor;
        try {
            descriptor = resolver.openFileDescriptor(uri, "rw");
            if (descriptor == null) throw new IOException("sem descritor");
        } catch (IOException | RuntimeException e) {
            resolver.delete(uri, null, null);
            throw new IOException("não foi possível gravar " + entry.path);
        }
        if (entry.size > 0) {
            try {
                Os.posix_fallocate(descriptor.getFileDescriptor(), 0, entry.size);
            } catch (ErrnoException ignored) {
                // Preallocation is an optimization; positional writes extend the file anyway.
            }
        }
        final FileChannel channel = new FileOutputStream(descriptor.getFileDescriptor()).getChannel();
        final List<Saved> saved = saved(session);
        return new Server.Target() {
            private boolean done;

            @Override
            public void write(byte[] buffer, int offset, int length, long position) throws IOException {
                ByteBuffer data = ByteBuffer.wrap(buffer, offset, length);
                while (data.hasRemaining()) position += channel.write(data, position);
            }

            @Override
            public synchronized void commit() throws IOException {
                if (done) return;
                done = true;
                channel.close();
                descriptor.close();
                ContentValues publish = new ContentValues();
                publish.put(MediaStore.MediaColumns.IS_PENDING, 0);
                resolver.update(uri, publish, null, null);
                saved.add(new Saved(uri, mime));
            }

            @Override
            public synchronized void abort() {
                if (done) return;
                done = true;
                try {
                    channel.close();
                    descriptor.close();
                } catch (IOException ignored) {
                }
                resolver.delete(uri, null, null);
            }
        };
    }

    @Override
    public void directory(Session session, int index) {
        // MediaStore has no empty folders; folders appear with their files.
    }

    @Override
    public void finish(Session session, boolean success) {}

    static String mime(String name) {
        int dot = name.lastIndexOf('.');
        String type = dot < 0 ? null : MimeTypeMap.getSingleton().getMimeTypeFromExtension(name.substring(dot + 1).toLowerCase(Locale.ROOT));
        return type == null ? "application/octet-stream" : type;
    }
}
