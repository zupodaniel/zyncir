package com.zyncir;

import com.zyncir.util.Log;
import com.zyncir.wrappers.ClipboardManager;

import android.net.LocalServerSocket;
import android.net.LocalSocket;
import android.os.Looper;

import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.EOFException;
import java.io.IOException;
import java.nio.charset.StandardCharsets;

/**
 * zyncir device-side helper.
 *
 * Launched as the shell user via:
 *   adb shell CLASSPATH=/data/local/tmp/zyncir.jar app_process / com.zyncir.Server
 *
 * It exposes a localabstract socket ("zyncir") which the macOS side reaches
 * through `adb forward tcp:<port> localabstract:zyncir`. Clipboard changes are
 * event-driven (OnPrimaryClipChangedListener) — there is no polling.
 *
 * Wire protocol (bidirectional, symmetric): each message is a 4-byte big-endian
 * length followed by that many UTF-8 bytes of clipboard text.
 */
public final class Server {

    private static final String SOCKET_NAME = "zyncir";
    private static final int MAX_MESSAGE_BYTES = 16 * 1024 * 1024;

    private final ClipboardManager clipboard;

    // Loop guard: the last text known to be synced in either direction. A value
    // we just wrote to the device clipboard (from the Mac) must not be echoed
    // back to the Mac, and vice-versa. Guarded by `lock` together with `out`.
    private final Object lock = new Object();
    private String lastValue;
    private DataOutputStream out;

    private Server(ClipboardManager clipboard) {
        this.clipboard = clipboard;
    }

    public static void main(String[] args) {
        // The clipboard change listener is delivered via a Handler bound to the
        // main looper, so it must be prepared and running.
        Looper.prepareMainLooper();

        Workarounds.apply();

        ClipboardManager clipboard = ClipboardManager.create();
        if (clipboard == null) {
            Log.e("No clipboard manager available on this device");
            return;
        }

        Server server = new Server(clipboard);
        server.registerClipboardListener();

        Thread acceptThread = new Thread(server::runAcceptLoop, "zyncir-accept");
        acceptThread.setDaemon(false);
        acceptThread.start();

        Log.i("zyncir helper started (event-driven, socket=" + SOCKET_NAME + ")");
        Looper.loop();
    }

    private void registerClipboardListener() {
        clipboard.addPrimaryClipChangedListener(this::onDeviceClipboardChanged);
    }

    /** Fired by Android only when the device clipboard actually changes. */
    private void onDeviceClipboardChanged() {
        CharSequence cs = clipboard.getText();
        if (cs == null) {
            return;
        }
        String text = cs.toString();
        synchronized (lock) {
            if (text.equals(lastValue)) {
                // This change is the one we just applied from the Mac, or a
                // duplicate of the last synced value — do not echo it back.
                return;
            }
            lastValue = text;
            sendLocked(text);
        }
    }

    private void runAcceptLoop() {
        LocalServerSocket serverSocket;
        try {
            serverSocket = new LocalServerSocket(SOCKET_NAME);
        } catch (IOException e) {
            Log.e("Could not bind localabstract socket '" + SOCKET_NAME + "'", e);
            System.exit(1);
            return;
        }

        while (true) {
            try {
                LocalSocket client = serverSocket.accept();
                Log.i("Mac connected");
                handleClient(client);
                Log.i("Mac disconnected");
            } catch (IOException e) {
                Log.e("Accept loop error", e);
            }
        }
    }

    private void handleClient(LocalSocket client) {
        DataInputStream in = null;
        try {
            in = new DataInputStream(client.getInputStream());
            DataOutputStream localOut = new DataOutputStream(client.getOutputStream());

            // Send a zero-length "hello" frame immediately so the Mac can tell a
            // real, bound connection apart from adb accepting the host port before
            // this socket exists. Then seed the current device clipboard.
            synchronized (lock) {
                this.out = localOut;
                localOut.writeInt(0); // hello
                localOut.flush();
                CharSequence current = clipboard.getText();
                if (current != null) {
                    String text = current.toString();
                    if (!text.isEmpty()) {
                        lastValue = text;
                        sendLocked(text);
                    }
                }
            }

            // Read frames from the Mac until disconnect.
            while (true) {
                String text = readMessage(in);
                if (text == null) {
                    break; // EOF
                }
                applyFromMac(text);
            }
        } catch (IOException e) {
            Log.d("Client connection ended: " + e.getMessage());
        } finally {
            synchronized (lock) {
                this.out = null;
            }
            closeQuietly(in);
            closeQuietly(client);
        }
    }

    private void applyFromMac(String text) {
        if (text.isEmpty()) {
            return; // ignore empty / keep-alive frames
        }
        synchronized (lock) {
            if (text.equals(lastValue)) {
                return; // already in sync
            }
            lastValue = text;
        }
        // setPrimaryClip will trigger onDeviceClipboardChanged, which sees the
        // value equals lastValue and suppresses the echo.
        clipboard.setText(text);
    }

    /** Caller must hold {@code lock}. */
    private void sendLocked(String text) {
        DataOutputStream localOut = this.out;
        if (localOut == null) {
            return;
        }
        try {
            byte[] bytes = text.getBytes(StandardCharsets.UTF_8);
            localOut.writeInt(bytes.length);
            localOut.write(bytes);
            localOut.flush();
        } catch (IOException e) {
            Log.d("Send failed (Mac likely disconnected): " + e.getMessage());
            this.out = null;
        }
    }

    private static String readMessage(DataInputStream in) throws IOException {
        int length;
        try {
            length = in.readInt();
        } catch (EOFException e) {
            return null;
        }
        if (length < 0 || length > MAX_MESSAGE_BYTES) {
            throw new IOException("Invalid message length: " + length);
        }
        byte[] bytes = new byte[length];
        in.readFully(bytes);
        return new String(bytes, StandardCharsets.UTF_8);
    }

    private static void closeQuietly(AutoCloseable c) {
        if (c != null) {
            try {
                c.close();
            } catch (Exception ignored) {
                // ignore
            }
        }
    }
}
