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
 *
 * --- Adaptation notes ---
 * scrcpy overrides getContentResolver() with a custom ContentResolver (routed
 * through ServiceManager.getActivityManager()) for Settings access. That return
 * type, android.content.IContentProvider, is a hidden API absent from the public
 * android.jar, and it would drag in scrcpy's entire wrapper web. The clipboard
 * code path (getPrimaryClip / setPrimaryClip / addPrimaryClipChangedListener)
 * calls the IClipboard binder directly using the context's package/attribution
 * and never touches the content resolver, so the override is dropped entirely;
 * the base system context's resolver remains available but unused.
 */
package com.zyncir;

import android.content.Context;
import android.content.ContextWrapper;
import android.content.AttributionSource;
import android.os.Process;

import java.lang.reflect.Field;

public final class FakeContext extends ContextWrapper {

    public static final String PACKAGE_NAME = "com.android.shell";

    private static final FakeContext INSTANCE = new FakeContext();

    public static FakeContext get() {
        return INSTANCE;
    }

    private FakeContext() {
        super(Workarounds.getSystemContext());
    }

    @Override
    public String getPackageName() {
        return PACKAGE_NAME;
    }

    @Override
    public String getOpPackageName() {
        return PACKAGE_NAME;
    }

    @Override
    public AttributionSource getAttributionSource() {
        AttributionSource.Builder builder = new AttributionSource.Builder(Process.SHELL_UID);
        builder.setPackageName(PACKAGE_NAME);
        return builder.build();
    }

    @SuppressWarnings("unused")
    public int getDeviceId() {
        return 0;
    }

    @Override
    public Context getApplicationContext() {
        return this;
    }

    @Override
    public Context createPackageContext(String packageName, int flags) {
        return this;
    }

    @Override
    public Object getSystemService(String name) {
        Object service = super.getSystemService(name);
        if (service == null) {
            return null;
        }

        // Reassign the service's mContext to this fake context so calls are
        // attributed to the shell package. "semclipboard" is Samsung-internal.
        if (Context.CLIPBOARD_SERVICE.equals(name) || "semclipboard".equals(name) || Context.ACTIVITY_SERVICE.equals(name)) {
            try {
                Field field = service.getClass().getDeclaredField("mContext");
                field.setAccessible(true);
                field.set(service, this);
            } catch (ReflectiveOperationException e) {
                throw new RuntimeException(e);
            }
        }

        return service;
    }
}
