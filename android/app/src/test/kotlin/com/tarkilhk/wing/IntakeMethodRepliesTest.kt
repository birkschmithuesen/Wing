package com.tarkilhk.wing

import org.junit.Assert.*
import org.junit.Test

class IntakeMethodRepliesTest {
    private class MainThread {
        private val actions = ArrayDeque<() -> Unit>()
        fun post(action: () -> Unit) { actions.addLast(action) }
        fun drain() { while (actions.isNotEmpty()) actions.removeFirst().invoke() }
    }

    @Test fun retiringBeforeQueueExecutionCancelsReplyWithoutStartingMutation() {
        val main = MainThread()
        val owner = IntakeMethodReplies(main::post)
        val outcomes = mutableListOf<String>()
        val reply = owner.register { outcomes.add("cancelled") }
        var commits = 0

        owner.retire()
        if (reply.admit()) {
            commits++
            reply.complete { outcomes.add("acknowledged") }
        }
        main.drain()

        assertEquals(0, commits)
        assertEquals(listOf("cancelled"), outcomes)
    }

    @Test fun committedAcknowledgementSurvivesRetirementBeforeUiDelivery() {
        val main = MainThread()
        val owner = IntakeMethodReplies(main::post)
        val outcomes = mutableListOf<String>()
        val reply = owner.register { outcomes.add("cancelled") }
        assertTrue(reply.admit())
        reply.complete { outcomes.add("acknowledged") }
        owner.retire()
        main.drain()

        assertEquals(listOf("acknowledged"), outcomes)
    }

    @Test fun startedMutationKeepsItsReplyUntilTheDurableOutcomeSettles() {
        val main = MainThread()
        val owner = IntakeMethodReplies(main::post)
        val outcomes = mutableListOf<String>()
        val reply = owner.register { outcomes.add("cancelled") }
        assertTrue(reply.admit())

        owner.retire()
        main.drain()
        assertTrue(outcomes.isEmpty())
        reply.complete { outcomes.add("acknowledged") }
        main.drain()

        assertEquals(listOf("acknowledged"), outcomes)
    }

    @Test fun retirementAndDuplicateCompletionsSettleEachReplyOnce() {
        val main = MainThread()
        val owner = IntakeMethodReplies(main::post)
        val outcomes = mutableListOf<String>()
        val reply = owner.register { outcomes.add("cancelled") }
        assertTrue(reply.admit())

        reply.complete { outcomes.add("first") }
        reply.complete { outcomes.add("late") }
        owner.retire()
        owner.retire()
        main.drain()
        reply.complete { outcomes.add("later") }
        main.drain()

        assertEquals(listOf("first"), outcomes)
    }

    @Test fun oneReplyCannotAdmitTheMutationTwice() {
        val main = MainThread()
        val owner = IntakeMethodReplies(main::post)
        val outcomes = mutableListOf<String>()
        val reply = owner.register { outcomes.add("cancelled") }
        var commits = 0

        repeat(2) {
            if (reply.admit()) commits++
        }
        reply.complete { outcomes.add("acknowledged") }
        main.drain()

        assertEquals(1, commits)
        assertEquals(listOf("acknowledged"), outcomes)
    }

    @Test fun oldHostCleanupCannotCancelOrReplaceNewHostReplies() {
        val main = MainThread()
        val old = IntakeMethodReplies(main::post)
        val current = IntakeMethodReplies(main::post)
        val outcomes = mutableListOf<String>()
        val previous = old.register { outcomes.add("old cancelled") }
        val fresh = current.register { outcomes.add("new cancelled") }

        old.retire()
        assertFalse(previous.admit())
        assertTrue(fresh.admit())
        fresh.complete { outcomes.add("new acknowledged") }
        old.retire()
        main.drain()

        assertEquals(listOf("old cancelled", "new acknowledged"), outcomes)
    }

    @Test fun registeredAfterRetirementIsCancelledAndCannotStart() {
        val main = MainThread()
        val owner = IntakeMethodReplies(main::post)
        val outcomes = mutableListOf<String>()
        owner.retire()

        val reply = owner.register { outcomes.add("cancelled") }
        assertFalse(reply.admit())
        main.drain()

        assertEquals(listOf("cancelled"), outcomes)
    }
}
