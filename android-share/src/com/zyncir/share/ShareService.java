package com.zyncir.share;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.ContentResolver;
import android.content.ContentValues;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.database.Cursor;
import android.net.LocalServerSocket;
import android.net.LocalSocket;
import android.net.Uri;
import android.os.IBinder;
import android.provider.MediaStore;
import android.provider.OpenableColumns;
import android.util.Log;

import java.io.DataOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

/**
 * Streams shared files straight to the Mac — no on-device copy. It binds a
 * localabstract socket ("zyncir-share") and drops a tiny reserved marker file in
 * the staging drop; the zyncir helper sees the marker and tells the Mac to
 * connect (via adb forward) and read the stream. Runs in the foreground so the
 * OS doesn't kill a multi-GB transfer.
 *
 * Wire framing on the socket: 4-byte big-endian file count, then per file a
 * 2-byte name length, UTF-8 name, 8-byte size (-1 = stream to EOF, last file
 * only), then the bytes.
 */
public final class ShareService extends Service {

    public static final String EXTRA_URIS = "uris";

    static final String SOCKET_NAME = "zyncir-share";
    static final String MARKER_NAME = "__zyncir_stream_request__";
    private static final String RELATIVE_PATH = "Download/zyncir/send";

    private static final String CHANNEL = "zyncir-transfer";
    private static final int NOTIF_ID = 1;
    private static final String TAG = "zyncir-share";

    private final List<Uri> queue = new ArrayList<>();
    private Thread worker;

    @Override
    public IBinder onBind(Intent intent) { return null; }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        startForegroundNotice();
        if (intent != null) {
            ArrayList<Uri> uris = intent.getParcelableArrayListExtra(EXTRA_URIS);
            if (uris != null) {
                synchronized (queue) { queue.addAll(uris); }
            }
        }
        startWorkerIfNeeded();
        return START_NOT_STICKY;
    }

    private synchronized void startWorkerIfNeeded() {
        if (worker != null && worker.isAlive()) return;
        worker = new Thread(this::run, "zyncir-share-stream");
        worker.start();
    }

    private void run() {
        LocalServerSocket server = null;
        try {
            server = new LocalServerSocket(SOCKET_NAME);
            writeMarker();                       // nudge the Mac to connect
            LocalSocket client = server.accept(); // Mac connects via adb forward
            Log.i(TAG, "Mac connected; streaming");
            List<Uri> batch;
            synchronized (queue) {
                batch = new ArrayList<>(queue);
                queue.clear();
            }
            stream(client, batch);
            client.close();
            Log.i(TAG, "streamed " + batch.size() + " file(s)");
        } catch (Exception e) {
            Log.e(TAG, "stream failed", e);
        } finally {
            closeQuietly(server);
            stopForeground(true);
            stopSelf();
        }
    }

    private void stream(LocalSocket client, List<Uri> uris) throws Exception {
        DataOutputStream out = new DataOutputStream(client.getOutputStream());
        out.writeInt(uris.size());
        for (Uri u : uris) {
            String name = displayName(u);
            long size = size(u);
            byte[] nameBytes = name.getBytes(StandardCharsets.UTF_8);
            out.writeShort(nameBytes.length);
            out.write(nameBytes);
            out.writeLong(size);
            InputStream in = null;
            try {
                in = getContentResolver().openInputStream(u);
                byte[] buf = new byte[262144];
                int n;
                while (in != null && (n = in.read(buf)) > 0) out.write(buf, 0, n);
            } finally {
                closeQuietly(in);
            }
        }
        out.flush();
    }

    /** Tiny reserved trigger file the helper watches for (not the file data). */
    private void writeMarker() {
        try {
            ContentResolver resolver = getContentResolver();
            ContentValues values = new ContentValues();
            values.put(MediaStore.Downloads.DISPLAY_NAME, MARKER_NAME);
            values.put(MediaStore.Downloads.RELATIVE_PATH, RELATIVE_PATH);
            values.put(MediaStore.Downloads.IS_PENDING, 1);
            Uri collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY);
            Uri item = resolver.insert(collection, values);
            if (item == null) return;
            try (OutputStream os = resolver.openOutputStream(item)) {
                if (os != null) os.write('1');
            }
            ContentValues done = new ContentValues();
            done.put(MediaStore.Downloads.IS_PENDING, 0);
            resolver.update(item, done, null, null);
        } catch (Exception e) {
            Log.e(TAG, "writeMarker failed", e);
        }
    }

    private String displayName(Uri uri) {
        Cursor c = null;
        try {
            c = getContentResolver().query(uri, new String[]{OpenableColumns.DISPLAY_NAME}, null, null, null);
            if (c != null && c.moveToFirst()) {
                String n = c.getString(0);
                if (n != null && !n.isEmpty()) return n;
            }
        } catch (Exception ignored) {
        } finally {
            closeQuietly(c);
        }
        String last = uri.getLastPathSegment();
        return (last != null && !last.isEmpty()) ? last : "shared.bin";
    }

    private long size(Uri uri) {
        Cursor c = null;
        try {
            c = getContentResolver().query(uri, new String[]{OpenableColumns.SIZE}, null, null, null);
            if (c != null && c.moveToFirst() && !c.isNull(0)) return c.getLong(0);
        } catch (Exception ignored) {
        } finally {
            closeQuietly(c);
        }
        return -1L;
    }

    private void startForegroundNotice() {
        NotificationManager nm = getSystemService(NotificationManager.class);
        if (nm.getNotificationChannel(CHANNEL) == null) {
            nm.createNotificationChannel(new NotificationChannel(
                    CHANNEL, "zyncir transfers", NotificationManager.IMPORTANCE_LOW));
        }
        Notification n = new Notification.Builder(this, CHANNEL)
                .setContentTitle("Sending to zyncir")
                .setSmallIcon(android.R.drawable.stat_sys_upload)
                .setOngoing(true)
                .build();
        startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC);
    }

    private static void closeQuietly(AutoCloseable c) {
        if (c != null) {
            try {
                c.close();
            } catch (Exception ignored) {
            }
        }
    }
}
