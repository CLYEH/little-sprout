package com.clyeh.sproutday.supabase

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class SupabaseConfigTest {
    @Test
    fun acceptsNonBlankValues() {
        val config = SupabaseConfig("https://example.supabase.co", "anon")
        assertEquals("https://example.supabase.co", config.url)
    }

    @Test
    fun blankUrlFailsLoudly() {
        assertThrows(IllegalArgumentException::class.java) { SupabaseConfig("", "anon") }
    }

    @Test
    fun blankAnonKeyFailsLoudly() {
        assertThrows(IllegalArgumentException::class.java) { SupabaseConfig("https://example.supabase.co", " ") }
    }
}
