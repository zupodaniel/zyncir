package com.zyncir.share;

import android.app.Activity;
import android.content.ClipData;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;

import java.util.ArrayList;

/**
 * The "Share to zyncir" target. Collects the shared file URIs and hands them to
 * {@link ShareService}, which streams the bytes straight to the Mac (no on-device
 * copy). This Activity has no UI and finishes immediately.
 */
public final class ShareActivity extends Activity {

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        ArrayList<Uri> uris = new ArrayList<>();
        Intent intent = getIntent();
        if (intent != null) {
            String action = intent.getAction();
            if (Intent.ACTION_SEND.equals(action)) {
                Uri u = intent.getParcelableExtra(Intent.EXTRA_STREAM);
                if (u != null) uris.add(u);
            } else if (Intent.ACTION_SEND_MULTIPLE.equals(action)) {
                ArrayList<Uri> list = intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM);
                if (list != null) {
                    for (Uri u : list) {
                        if (u != null) uris.add(u);
                    }
                }
            }
        }

        if (!uris.isEmpty()) {
            Intent svc = new Intent(this, ShareService.class);
            svc.putParcelableArrayListExtra(ShareService.EXTRA_URIS, uris);
            // Propagate read access to the (same-app) service for the whole batch.
            svc.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            ClipData clip = ClipData.newRawUri("uris", uris.get(0));
            for (int i = 1; i < uris.size(); i++) {
                clip.addItem(new ClipData.Item(uris.get(i)));
            }
            svc.setClipData(clip);
            startForegroundService(svc);
        }
        finish();
    }
}
