package com.zyncir;

import android.net.LocalServerSocket;
import android.net.LocalSocket;
import android.os.FileObserver;

import com.zyncir.util.Log;

import java.io.File;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.Iterator;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;

/**
 * Nudges the Mac to pull whenever a file lands in the staging drop, so the Mac
 * no longer has to poll. Exposed on its own localabstract socket
 * ("zyncir-files") so the clipboard protocol stays untouched.
 *
 * A nudge is the completed file's name plus a newline; the Mac treats any data
 * as "scan the drop now" and pulls whatever is present (idempotent).
 */
public final class FileSignal {

    private static final String SOCKET_NAME = "zyncir-files";
    private static final String STAGING = "/sdcard/Download/zyncir/send";

    private final List<OutputStream> clients = new CopyOnWriteArrayList<>();
    private FileObserver observer;

    public void start() {
        new File(STAGING).mkdirs();
        Thread t = new Thread(this::runAcceptLoop, "zyncir-files-accept");
        t.setDaemon(false);
        t.start();
        startObserver();
    }

    private synchronized void startObserver() {
        if (observer != null) {
            try { observer.stopWatching(); } catch (Exception ignored) {}
        }
        new File(STAGING).mkdirs();
        // CLOSE_WRITE covers direct writes; MOVED_TO covers the MediaStore finalize
        // (rename from ".pending-…" to the real name) — both signal a *complete*
        // file. DELETE_SELF/MOVE_SELF let us re-watch if the drop is deleted out
        // from under us (an inotify watch is pinned to the inode, so a delete +
        // recreate would otherwise silently stop delivering events).
        observer = new FileObserver(new File(STAGING),
                FileObserver.CLOSE_WRITE | FileObserver.MOVED_TO
                        | FileObserver.DELETE_SELF | FileObserver.MOVE_SELF) {
            @Override
            public void onEvent(int event, String path) {
                int e = event & FileObserver.ALL_EVENTS;
                if (e == FileObserver.DELETE_SELF || e == FileObserver.MOVE_SELF) {
                    Log.i("file signal: drop removed — re-watching");
                    startObserver();
                    return;
                }
                if (path == null || path.startsWith(".")) return;
                nudge(path);
            }
        };
        observer.startWatching();
        Log.i("file signal watching " + STAGING);
    }

    private void nudge(String name) {
        byte[] line = (name + "\n").getBytes(StandardCharsets.UTF_8);
        for (Iterator<OutputStream> it = clients.iterator(); it.hasNext(); ) {
            OutputStream os = it.next();
            try {
                os.write(line);
                os.flush();
            } catch (Exception e) {
                clients.remove(os);
                closeQuietly(os);
            }
        }
    }

    private void runAcceptLoop() {
        LocalServerSocket serverSocket;
        try {
            serverSocket = new LocalServerSocket(SOCKET_NAME);
        } catch (Exception e) {
            Log.e("Could not bind localabstract socket '" + SOCKET_NAME + "'", e);
            return;
        }
        while (true) {
            try {
                LocalSocket client = serverSocket.accept();
                clients.add(client.getOutputStream());
                Log.i("Mac connected (file signal)");
            } catch (Exception e) {
                Log.e("file signal accept error", e);
            }
        }
    }

    private static void closeQuietly(OutputStream os) {
        try {
            os.close();
        } catch (Exception ignored) {
        }
    }
}
