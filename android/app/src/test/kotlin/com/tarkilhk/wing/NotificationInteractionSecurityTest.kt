package com.tarkilhk.wing

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class NotificationInteractionSecurityTest {
    @Test fun conversationShortcutsCannotCarryPermissionAuthority() {
        var persisted: String? = null
        val store = NotificationHandleStore({ persisted }, { persisted = it; true })
        assertNull(store.issue(42, NotificationHandleStore.navigationPurpose, action("once")))
        val navigation = store.issue(42, NotificationHandleStore.navigationPurpose, action("", true))!!
        assertEquals("", store.readNavigation(navigation)!!.getString("choice"))
        assertNotNull(store.readNavigation(navigation))
        store.replace(42, "new revision", "new revision")
        assertEquals(navigation, store.issue(42, NotificationHandleStore.navigationPurpose, action("", true)))
        store.invalidate(42)
        assertNotNull(store.readNavigation(navigation))
        val decision = store.issue(42, NotificationHandleStore.actionPurpose, action("once"))!!
        assertNull(store.readNavigation(decision))
        assertNull(store.readNavigation("forged"))
    }

    @Test fun longApprovalPreviewsLeaveRoomForPlatformActions() {
        val command = "x".repeat(1000)
        assertEquals("x".repeat(120) + "…", NotificationInteractionSchema.approvalPreview(command, false))
        assertEquals("x".repeat(60) + "…", NotificationInteractionSchema.approvalPreview(command, true))
        assertEquals("echo first…", NotificationInteractionSchema.approvalPreview("echo first\necho second", false))
        assertEquals("echo ready", NotificationInteractionSchema.approvalPreview("echo ready", true))
    }

    @Test fun platformActionsNeverGrantHiddenOrTruncatedCommands() {
        fun actions(command: String = "echo ready", choices: List<String> = listOf("once", "deny"),
            preview: Boolean = true, busy: Boolean = false, large: Boolean = false) =
            NotificationInteractionSchema.visibleActions(mapOf("kind" to "approval", "preview" to preview,
                "expanded" to command, "choices" to choices, "submitting" to busy, "pending" to "1 approval"), large)
        assertEquals(listOf("once", "deny"), actions())
        assertEquals(listOf("once", "review", "deny"), actions(choices = listOf("once", "session", "always", "deny")))
        for (command in listOf("", "echo\nnext", "x".repeat(41), "echo…")) {
            assertEquals(listOf("review", "deny"), actions(command))
        }
        assertEquals(listOf("review", "deny"), actions(large = true))
        assertEquals(listOf("review"), actions(preview = false))
        assertEquals(emptyList<String>(), actions(busy = true))
    }

    @Test fun bodyTapCapturedByAndroidSurvivesReplacementBeforeActionActivityStarts() {
        var persisted: String? = null
        val store = NotificationHandleStore({ persisted }, { persisted = it; true })
        val original = action("", true)
        val body = store.issue(42, NotificationHandleStore.actionPurpose, original)!!
        val decision = store.issue(42, NotificationHandleStore.actionPurpose, action("once"))!!
        assertTrue(store.replace(42, original.getString("payload"), "next-revision"))
        assertEquals(original.toString(), store.consume(body, NotificationHandleStore.actionPurpose)?.toString())
        assertNull(store.consume(decision, NotificationHandleStore.actionPurpose))
    }

    @Test fun replacedBodyTapHasABoundedHandoffWindow() {
        var persisted: String? = null
        var time = 1000L
        val store = NotificationHandleStore({ persisted }, { persisted = it; true }, { time })
        val body = store.issue(42, NotificationHandleStore.actionPurpose, action("", true))!!
        store.invalidate(42)
        time += 4 * 60 * 1000
        store.invalidate(42)
        time += 60 * 1000
        assertNull(store.consume(body, NotificationHandleStore.actionPurpose))
    }

    @Test fun acceptedBodyTapSurvivesReadCancellationButPermissionChoicesDoNot() {
        var persisted: String? = null
        fun store() = NotificationHandleStore({ persisted }, { persisted = it; true })
        val navigation = store().issue(42, NotificationHandleStore.mainPurpose, action("", true))!!
        val decision = store().issue(42, NotificationHandleStore.mainPurpose, action("once", true))!!
        val privateAction = store().issue(42, NotificationHandleStore.actionPurpose, action("", true))!!
        assertTrue(store().invalidate(42))
        assertNotNull(store().consume(navigation, NotificationHandleStore.mainPurpose))
        assertNull(store().consume(navigation, NotificationHandleStore.mainPurpose))
        assertNull(store().consume(decision, NotificationHandleStore.mainPurpose))
        assertNotNull(store().consume(privateAction, NotificationHandleStore.actionPurpose))
    }

    @Test fun tappedConversationSurvivesANewerReplyBeforeMainResumes() {
        for (group in listOf(false, true)) {
            var persisted: String? = null
            fun store() = NotificationHandleStore({ persisted }, { persisted = it; true })
            val target = JSONObject().put("connection", "host").put("connection_identity", "owner")
                .put("focus", JSONObject().put("kind", "answer").put("id", "17"))
            if (group) target.put("room", "room-one")
            else target.put("profile", "default").put("session", "chat-one")
            val data = mapOf("payload" to target.toString(), "expanded" to "First reply",
                "chat" to "scoped-chat", "revision" to "answer:17", "id" to 42)
            val tap = NotificationInteractionSchema.contentTap(data)
            val action = store().issue(42, NotificationHandleStore.actionPurpose, tap)!!
            val delivered = store().consume(action, NotificationHandleStore.actionPurpose)!!
            val handoff = store().issue(42, NotificationHandleStore.mainPurpose, delivered)!!
            target.getJSONObject("focus").put("id", "18")
            assertTrue(store().replace(42, target.toString(), "answer:18"))
            assertNotNull("A newer reply must not swallow an already accepted conversation tap (group=$group)",
                store().consume(handoff, NotificationHandleStore.mainPurpose))
        }
    }

    @Test fun renderedGroupReplyCanIssueItsContentTapHandle() {
        val target = JSONObject().put("connection", "host").put("connection_identity", "owner")
            .put("room", "room-one").put("focus", JSONObject().put("kind", "answer").put("id", "17"))
        val data = mapOf("payload" to target.toString(), "expanded" to "Shared reply",
            "chat" to "room-one", "revision" to "answer:17", "id" to 42)
        var persisted: String? = null
        val store = NotificationHandleStore({ persisted }, { persisted = it; true })
        val tap = NotificationInteractionSchema.contentTap(data)
        val token = store.issue(42, NotificationHandleStore.actionPurpose, tap)
        assertNotNull("Android must be able to post a group reply with its real content tap", token)
        val delivered = store.consume(token, NotificationHandleStore.actionPurpose)!!
        assertFalse(delivered.getBoolean("review"))
        assertEquals("", delivered.getString("choice"))
        assertTrue(NotificationInteractionSchema.opensMain(delivered, true))
        assertTrue(NotificationInteractionSchema.opensMain(delivered, false))
        val mainToken = store.issue(42, NotificationHandleStore.mainPurpose, delivered)!!
        val reached = store.consume(mainToken, NotificationHandleStore.mainPurpose)!!
        assertEquals("room-one", JSONObject(reached.getString("payload")).getString("room"))
        assertNull(store.consume(token, NotificationHandleStore.actionPurpose))
        assertNull(store.consume(mainToken, NotificationHandleStore.mainPurpose))
    }

    @Test fun contentNavigationAndDirectDecisionsChooseTheirActivityHost() {
        val data = mapOf("payload" to action().getString("payload"), "expanded" to "echo ready",
            "chat" to "scoped-chat", "revision" to "approval:request-one", "id" to 42)
        val tap = NotificationInteractionSchema.contentTap(data)
        assertNotNull(NotificationInteractionSchema.parse(tap.toString()))
        assertTrue(tap.getBoolean("review"))
        assertTrue(NotificationInteractionSchema.opensMain(tap, true))
        for (choice in listOf("once", "session", "deny")) {
            val decision = NotificationInteractionSchema.action(data, choice, false)
            assertNotNull(NotificationInteractionSchema.parse(decision.toString()))
            assertFalse(NotificationInteractionSchema.opensMain(decision, true))
            assertTrue(NotificationInteractionSchema.opensMain(decision, false))
        }
        val permanentReview = NotificationInteractionSchema.action(data, "always", true)
        assertTrue(NotificationInteractionSchema.opensMain(permanentReview, true))
    }

    @Test fun localTestAlertCanIssueItsUntargetedContentTapHandle() {
        val data = mapOf("payload" to "", "expanded" to "Local alerts are working on this device.",
            "id" to 214600)
        var persisted: String? = null
        val store = NotificationHandleStore({ persisted }, { persisted = it; true })
        val tap = NotificationInteractionSchema.contentTap(data)
        assertNotNull(store.issue(214600, NotificationHandleStore.actionPurpose, tap))
        assertTrue(NotificationInteractionSchema.opensMain(tap, true))
    }

    @Test fun groupRepliesKeepRoomIdentityWithoutGainingDecisionAuthority() {
        val target = JSONObject().put("connection", "host").put("connection_identity", "owner")
            .put("room", "room-one").put("focus", JSONObject().put("kind", "answer").put("id", "17"))
        val value = action("", false).put("payload", target.toString())
        assertNotNull(NotificationInteractionSchema.parse(value.toString()))
        for (choice in listOf("once", "session", "always", "deny")) {
            assertNull(NotificationInteractionSchema.parse(JSONObject(value.toString()).put("choice", choice).toString()))
        }
        assertNull(NotificationInteractionSchema.parse(JSONObject(value.toString()).put("review", true).toString()))
        target.put("session", "private-worker")
        assertNull(NotificationInteractionSchema.parse(value.put("payload", target.toString()).toString()))
        target.remove("session")
        target.getJSONObject("focus").put("kind", "approval")
        assertNull(NotificationInteractionSchema.parse(value.put("payload", target.toString()).toString()))
    }
    @Test fun groupApprovalsAdmitOnlyFencedOneTimeOrDenyActions() {
        val target = JSONObject().put("connection", "host").put("connection_identity", "owner")
            .put("room", "room-one").put("focus", JSONObject().put("kind", "approval")
                .put("id", JSONArray().put("task").put("member").put("request").put(2).toString()))
        for (choice in listOf("", "once", "deny")) {
            val value = action(choice, false).put("payload", target.toString())
            assertNotNull(NotificationInteractionSchema.parse(value.toString()))
            assertNotNull(NotificationInteractionSchema.parse(value.put("review", true).toString()))
        }
        for (choice in listOf("session", "always")) {
            assertNull(NotificationInteractionSchema.parse(action(choice).put("payload", target.toString()).toString()))
        }
        target.getJSONObject("focus").put("id", JSONArray().put("task").put("member").put("request").put(0).toString())
        assertNull(NotificationInteractionSchema.parse(action().put("payload", target.toString()).toString()))
    }

    private fun action(choice: String = "once", review: Boolean = false): JSONObject {
        val target = JSONObject().put("connection", "host").put("connection_identity", "credential-owner")
            .put("profile", "default").put("session", "chat-one")
            .put("focus", JSONObject().put("kind", "approval").put("id", "request-one"))
        return JSONObject().put("payload", target.toString()).put("choice", choice).put("review", review)
            .put("command", "echo ready")
            .put("chat", "scoped-chat").put("revision", "approval:request-one").put("notification_id", 42)
    }

    @Test fun malformedInputsAreDiscardedWithoutThrowing() {
        for (raw in listOf(null, "", "{", "[]", "null", "false", "x".repeat(NotificationInteractionSchema.maxChars + 1))) {
            assertNull(NotificationInteractionSchema.parse(raw))
        }
        for ((key, value) in listOf("payload" to 1, "choice" to true, "choice" to "grant", "review" to "false", "command" to false, "command" to "x".repeat(801), "chat" to JSONArray(), "revision" to false)) {
            assertNull(NotificationInteractionSchema.parse(action().put(key, value).toString()))
        }
        assertNull(NotificationInteractionSchema.parse(action().put("unexpected", true).toString()))
        assertNull(NotificationInteractionSchema.parse(action().put("payload", "x".repeat(32 * 1024 + 1)).toString()))
        assertNull(NotificationInteractionSchema.parse(action().put("payload", "{").toString()))
        val target = JSONObject(action().getString("payload")).put("connection_identity", JSONObject.NULL)
        assertNull(NotificationInteractionSchema.parse(action().put("payload", target.toString()).toString()))
        target.put("connection_identity", "owner").put("focus", JSONObject().put("kind", "approval").put("id", 13))
        assertNull(NotificationInteractionSchema.parse(action().put("payload", target.toString()).toString()))
    }

    @Test fun allChoicesKeepTheirExactTargetAndReviewPolicyAcrossProcessRestart() {
        for (choice in listOf("", "once", "session", "always", "deny")) {
            for (review in listOf(false, true)) {
                var persisted: String? = null
                fun store() = NotificationHandleStore({ persisted }, { persisted = it; true })
                val source = action(choice, review)
                val token = store().issue(42, NotificationHandleStore.actionPurpose, source)!!
                source.put("choice", "deny").put("review", !review)
                    .put("payload", action().getString("payload").replace("chat-one", "chat-two"))
                    .put("revision", "different-revision")
                // The public main entry cannot accept a notification's private-action token.
                assertNull(store().consume(token, NotificationHandleStore.mainPurpose))
                val delivered = store().consume(token, NotificationHandleStore.actionPurpose)!!
                assertEquals(choice, delivered.getString("choice"))
                assertEquals(review, delivered.getBoolean("review"))
                assertEquals("approval:request-one", delivered.getString("revision"))
                assertEquals("request-one", JSONObject(delivered.getString("payload")).getJSONObject("focus").getString("id"))
                assertEquals("chat-one", JSONObject(delivered.getString("payload")).getString("session"))
                assertNull(store().consume(token, NotificationHandleStore.actionPurpose))
            }
        }
    }

    @Test fun publicHandoffsAreBoundSingleUseAndExpire() {
        var persisted: String? = null
        var time = 1000L
        fun store() = NotificationHandleStore({ persisted }, { persisted = it; true }, { time })
        val token = store().issue(42, NotificationHandleStore.mainPurpose, action("session", true))!!
        assertNull(store().consume("forged", NotificationHandleStore.mainPurpose))
        assertNull(store().consume(action().toString(), NotificationHandleStore.mainPurpose))
        assertNull(store().consume(java.util.UUID.randomUUID().toString(), NotificationHandleStore.mainPurpose))
        assertEquals("session", store().consume(token, NotificationHandleStore.mainPurpose)!!.getString("choice"))
        assertNull(store().consume(token, NotificationHandleStore.mainPurpose))
        val expired = store().issue(42, NotificationHandleStore.mainPurpose, action())!!
        time += 5 * 60 * 1000
        assertNull(store().consume(expired, NotificationHandleStore.mainPurpose))
    }

    @Test fun replacementAndCancellationRevokeOnlyTheirNotification() {
        var persisted: String? = null
        val store = NotificationHandleStore({ persisted }, { persisted = it; true })
        val old = store.issue(42, NotificationHandleStore.actionPurpose, action())!!
        val other = store.issue(43, NotificationHandleStore.actionPurpose, action())!!
        val main = store.issue(42, NotificationHandleStore.mainPurpose, action())!!
        assertTrue(store.invalidate(42))
        assertNull(store.consume(old, NotificationHandleStore.actionPurpose))
        assertNull(store.consume(main, NotificationHandleStore.mainPurpose))
        assertNotNull(store.consume(other, NotificationHandleStore.actionPurpose))
    }

    @Test fun storageFailureNeverDeliversAndCorruptStorageIsRecoverable() {
        var persisted: String? = "{"
        var allowWrite = true
        val store = NotificationHandleStore({ persisted }, { if (allowWrite) persisted = it; allowWrite })
        val token = store.issue(42, NotificationHandleStore.actionPurpose, action())!!
        allowWrite = false
        assertNull(store.consume(token, NotificationHandleStore.actionPurpose))
        assertNull(store.issue(42, NotificationHandleStore.mainPurpose, action()))
        allowWrite = true
        assertNotNull(store.consume(token, NotificationHandleStore.actionPurpose))
        persisted = JSONArray().put(JSONObject().put("expires", "tomorrow")).toString()
        assertNull(store.consume(token, NotificationHandleStore.actionPurpose))
        assertNotNull(store.issue(42, NotificationHandleStore.actionPurpose, action()))
    }

    @Test fun sameTargetRerenderPreservesLockedMainReviewButNewTargetRevokesIt() {
        var persisted: String? = null
        val store = NotificationHandleStore({ persisted }, { persisted = it; true })
        val value = action("once", true)
        val privateAction = store.issue(42, NotificationHandleStore.actionPurpose, value)!!
        val lockedReview = store.issue(42, NotificationHandleStore.mainPurpose, value)!!
        assertTrue(store.replace(42, value.getString("payload"), value.getString("revision")))
        assertNull(store.consume(privateAction, NotificationHandleStore.actionPurpose))
        assertTrue(store.consume(lockedReview, NotificationHandleStore.mainPurpose)!!.getBoolean("review"))
        val obsoleteReview = store.issue(42, NotificationHandleStore.mainPurpose, value)!!
        assertTrue(store.replace(42, value.getString("payload"), "new-revision"))
        assertNull(store.consume(obsoleteReview, NotificationHandleStore.mainPurpose))
    }

    @Test fun boundedStorageEvictsOldHandlesAndSchemaRejectsInvalidGrant() {
        var persisted: String? = null
        val store = NotificationHandleStore({ persisted }, { persisted = it; true })
        val first = store.issue(42, NotificationHandleStore.actionPurpose, action())!!
        repeat(512) { assertNotNull(store.issue(it, NotificationHandleStore.actionPurpose, action())) }
        assertEquals(512, JSONArray(persisted).length())
        assertNull(store.consume(first, NotificationHandleStore.actionPurpose))
        assertNull(store.issue(42, NotificationHandleStore.actionPurpose, action().put("review", "false")))
    }

    @Test fun dismissalsAreSchemaChecked() {
        val dismissal = JSONObject().put("dismiss", true).put("chat", "scoped-chat").put("revision", "rev")
        assertNotNull(NotificationInteractionSchema.parse(dismissal.toString()))
        var persisted: String? = null
        val store = NotificationHandleStore({ persisted }, { persisted = it; true })
        val token = store.issue(42, NotificationHandleStore.dismissPurpose, dismissal)!!
        assertNull(store.consume(token, NotificationHandleStore.mainPurpose))
        assertTrue(store.consume(token, NotificationHandleStore.dismissPurpose)!!.getBoolean("dismiss"))
        assertNull(store.consume(token, NotificationHandleStore.dismissPurpose))
        assertNull(NotificationInteractionSchema.parse(dismissal.put("choice", "once").toString()))
        assertNotNull(NotificationInteractionSchema.parse(JSONObject().put("payload", "").put("choice", "").put("review", true).put("command", "").toString()))
    }
}
