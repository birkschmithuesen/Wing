package com.tarkilhk.wing.porterwake

import org.unifiedpush.android.connector.FailedReason
import org.unifiedpush.android.connector.PushService
import org.unifiedpush.android.connector.data.PushEndpoint
import org.unifiedpush.android.connector.data.PushMessage

// ANNAHME C1/C2 note: connector org.unifiedpush.android:connector:3.0.10. Maven
// resolution and the PushService/PushEndpoint/PushMessage/FailedReason names were
// confirmed by the voice-apk.yml compile (the four callbacks return Unit). The
// build host has no web access, so the latest-3.x claim and C2 (undecryptable
// messages still reach onMessage) are unverified until the device run.

/** UnifiedPush callbacks. The instance is the Wing connection id. */
class PorterPushService : PushService() {
    override fun onNewEndpoint(endpoint: PushEndpoint, instance: String) {
        PorterWakeNative.queueForMain(this, mapOf("type" to "endpoint", "connection" to instance, "url" to endpoint.url))
    }

    // Plain JSON from the gate arrives with decrypted == false (ANNAHME C2).
    override fun onMessage(message: PushMessage, instance: String) {
        PorterWakeNative.deliverPush(this, instance, message.content)
    }

    override fun onRegistrationFailed(reason: FailedReason, instance: String) {
        PorterWakeNative.queueForMain(this, mapOf("type" to "failed", "connection" to instance, "reason" to reason.name))
    }

    override fun onUnregistered(instance: String) {
        PorterWakeNative.queueForMain(this, mapOf("type" to "unregistered", "connection" to instance))
    }
}
