/*
 * Adapted from scrcpy (https://github.com/Genymobile/scrcpy)
 * Copyright (C) 2018 Genymobile
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package com.zyncir.wrappers;

import com.zyncir.FakeContext;

import android.content.ClipData;
import android.content.Context;

/**
 * Thin wrapper over the real android.content.ClipboardManager obtained through a
 * FakeContext (shell UID). Because it is a genuine ClipboardManager instance, it
 * supports event-driven change notification via OnPrimaryClipChangedListener — no
 * polling required.
 */
public final class ClipboardManager {
    private final android.content.ClipboardManager manager;

    public static ClipboardManager create() {
        android.content.ClipboardManager manager =
                (android.content.ClipboardManager) FakeContext.get().getSystemService(Context.CLIPBOARD_SERVICE);
        if (manager == null) {
            // Some devices have no clipboard manager
            return null;
        }
        return new ClipboardManager(manager);
    }

    private ClipboardManager(android.content.ClipboardManager manager) {
        this.manager = manager;
    }

    public CharSequence getText() {
        ClipData clipData = manager.getPrimaryClip();
        if (clipData == null || clipData.getItemCount() == 0) {
            return null;
        }
        return clipData.getItemAt(0).getText();
    }

    public boolean setText(CharSequence text) {
        ClipData clipData = ClipData.newPlainText(null, text);
        manager.setPrimaryClip(clipData);
        return true;
    }

    public void addPrimaryClipChangedListener(android.content.ClipboardManager.OnPrimaryClipChangedListener listener) {
        manager.addPrimaryClipChangedListener(listener);
    }
}
