package com.tarkilhk.wing

import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.Parameterized

@RunWith(Parameterized::class)
class ExternalShareUriPolicyTest(
    private val intent: String,
    private val scheme: String?,
    private val authority: String?,
    private val provider: String?,
    private val granted: Boolean,
    private val expected: Boolean,
) {
    @Test fun acceptsOnlyAuthorizedExternalContent() {
        assertEquals(intent, expected, ExternalShareUriPolicy.allows(
            scheme, authority, provider, "com.tarkilhk.wing.dev", granted,
        ))
    }

    companion object {
        @JvmStatic
        @Parameterized.Parameters(name = "{0}")
        fun cases(): List<Array<Any?>> = listOf(
            arrayOf("granted external content", "content", "photos.provider", "photos.app", true, true),
            arrayOf("file scheme", "file", "photos.provider", "photos.app", true, false),
            arrayOf("resource scheme", "android.resource", "photos.provider", "photos.app", true, false),
            arrayOf("missing scheme", null, "photos.provider", "photos.app", true, false),
            arrayOf("missing authority", "content", null, "photos.app", true, false),
            arrayOf("empty authority", "content", "", "photos.app", true, false),
            arrayOf("cross-user authority", "content", "10@photos.provider", "photos.app", true, false),
            arrayOf("unresolved provider", "content", "photos.provider", null, true, false),
            // Ownership is determined by package, even when authority has an alias.
            arrayOf("self-owned provider alias", "content", "some.alias", "com.tarkilhk.wing.dev", true, false),
            arrayOf("missing read grant", "content", "photos.provider", "photos.app", false, false),
        )
    }
}
