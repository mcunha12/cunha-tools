package com.marcelocunha.cunhatools;

import android.content.ContentResolver;
import android.content.Context;
import android.database.Cursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.DocumentsContract;
import android.provider.OpenableColumns;
import com.marcelocunha.cunhatools.pfs.Entry;
import com.marcelocunha.cunhatools.pfs.FileSource;
import com.marcelocunha.cunhatools.pfs.Source;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.util.ArrayList;
import java.util.List;

// A shared or picked content URI, read by position straight from its file descriptor.
final class UriSource implements Source {
    private final ContentResolver resolver;
    private final Uri uri;
    private final Entry entry;

    private UriSource(ContentResolver resolver, Uri uri, Entry entry) {
        this.resolver = resolver;
        this.uri = uri;
        this.entry = entry;
    }

    @Override
    public Entry entry() {
        return entry;
    }

    @Override
    public Reader open() throws IOException {
        final ParcelFileDescriptor descriptor = resolver.openFileDescriptor(uri, "r");
        if (descriptor == null) throw new IOException("não foi possível abrir " + entry.path);
        final FileChannel channel = new FileInputStream(descriptor.getFileDescriptor()).getChannel();
        return new Reader() {
            @Override
            public int read(byte[] buffer, int offset, int length, long position) throws IOException {
                return channel.read(ByteBuffer.wrap(buffer, offset, length), position);
            }

            @Override
            public void close() throws IOException {
                channel.close();
                descriptor.close();
            }
        };
    }

    // Streams without a size (cloud items, pipes) are copied to the cache first so they can be read by position.
    static List<Source> from(Context context, List<Uri> uris, List<File> spooled) throws IOException {
        ContentResolver resolver = context.getContentResolver();
        List<Source> sources = new ArrayList<>();
        for (Uri uri : uris) {
            String name = "arquivo";
            long size = -1;
            long modified = 0;
            try (Cursor cursor = resolver.query(uri, null, null, null, null)) {
                if (cursor != null && cursor.moveToFirst()) {
                    int nameColumn = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME);
                    int sizeColumn = cursor.getColumnIndex(OpenableColumns.SIZE);
                    int modifiedColumn = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_LAST_MODIFIED);
                    if (nameColumn >= 0 && !cursor.isNull(nameColumn)) name = cursor.getString(nameColumn);
                    if (sizeColumn >= 0 && !cursor.isNull(sizeColumn)) size = cursor.getLong(sizeColumn);
                    if (modifiedColumn >= 0 && !cursor.isNull(modifiedColumn)) modified = cursor.getLong(modifiedColumn);
                }
            } catch (RuntimeException ignored) {
                // Some providers reject a null projection; the name and size then come from the descriptor.
            }
            long statSize;
            try (ParcelFileDescriptor descriptor = resolver.openFileDescriptor(uri, "r")) {
                if (descriptor == null) throw new IOException("não foi possível abrir " + name);
                statSize = descriptor.getStatSize();
            }
            if (statSize >= 0) {
                sources.add(new UriSource(resolver, uri, new Entry(name, statSize, modified, false)));
            } else {
                File copy = spool(context, resolver, uri, name);
                spooled.add(copy);
                sources.add(new FileSource(copy, name));
            }
        }
        return sources;
    }

    private static File spool(Context context, ContentResolver resolver, Uri uri, String name) throws IOException {
        File folder = new File(context.getCacheDir(), "spool");
        if (!folder.isDirectory() && !folder.mkdirs()) throw new IOException("cache indisponível");
        File copy = File.createTempFile("pfs", ".bin", folder);
        try (InputStream in = resolver.openInputStream(uri); OutputStream out = new FileOutputStream(copy)) {
            if (in == null) throw new IOException("não foi possível ler " + name);
            byte[] buffer = new byte[1 << 20];
            int n;
            while ((n = in.read(buffer)) > 0) out.write(buffer, 0, n);
        }
        return copy;
    }
}
