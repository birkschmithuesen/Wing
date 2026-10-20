package com.tarkilhk.wing.porterwake

import org.unifiedpush.android.connector.FailedReason
import org.unifiedpush.android.connector.PushService
import org.unifiedpush.android.connector.data.PushEndpoint
import org.unifiedpush.android.connector.data.PushMessage

// ANNAHME C1/C2 note: connector org.unifiedpush.android:connector:3.0.10 is coded
// against the plan's documented API. The version and the names below could not be
// verified from the build host (no web access); the voice-apk.yml compile is the
// evidence. If names differ, adapt only this file and PorterWakeNative.register/unregister.

/** UnifiedPush callbacks. The instance is the Wing connection id. */
class PorterPushService : PushService() {
    override fun onNewEndpoint(endpoint: PushEndpoint, instance: String) =
        PorterWakeNative.queueForMain(this, mapOf("type" to "endpoint", "connection" to instance, "url" to endpoint.url))

    // Plain JSON from the gate arrives with decrypted == false (ANNAHME C2).
    override fun onMessage(message: PushMessage, instance: String) =
        PorterWakeNative.deliverPush(this, instance, message.content)

    override fun onRegistrationFailed(reason: FailedReason, instance: String) =
        PorterWakeNative.queueForMain(this, mapOf("type" to "failed", "connection" to instance, "reason" to reason.name))

    override fun onUnregistered(instance: String) =
        PorterWakeNative.queueForMain(this, mapOf("type" to "unregistered", "connection" to instance))
}
