package com.tarkilhk.wing.voiceoffline

import android.os.SystemClock
import android.speech.tts.TextToSpeech
import android.speech.tts.Voice
import android.util.Log
import java.util.Locale

/**
 * Queues one utterance per Dart-built language segment and sets the engine language before each one.
 * SherpaTTS reads the language of every request, so German and English alternate without a manual switch.
 * Logs carry language, status, timing and length only, never reply text.
 */
object LanguageSpeech {
    private const val TAG = "WingTtsLang"
    private val locales = mapOf("de" to Locale.GERMANY, "en" to Locale.US)

    fun enqueue(tts: TextToSpeech, owner: String, text: String, segments: List<Map<String, String>>?, voice: Voice?) {
        val parts = segments.orEmpty()
            .filter { !it["text"].isNullOrBlank() }
            .flatMap { segment -> limit(segment.getValue("text")).map { it to (segment["lang"] ?: "de") } }
            .ifEmpty { limit(text).map { it to "" } }
        parts.forEachIndexed { index, (part, lang) ->
            val started = SystemClock.elapsedRealtime()
            val status = if (lang.isEmpty()) TextToSpeech.SUCCESS else select(tts, lang, voice)
            val elapsed = SystemClock.elapsedRealtime() - started
            Log.i(TAG, "segment ${index + 1}/${parts.size} lang=${lang.ifEmpty { "default" }} status=$status ms=$elapsed chars=${part.length}")
            val tag = if (index == parts.lastIndex) "$owner:last" else "$owner:$index"
            check(tts.speak(part, TextToSpeech.QUEUE_ADD, null, tag) == TextToSpeech.SUCCESS) { "Could not generate speech." }
        }
    }

    private fun select(tts: TextToSpeech, lang: String, voice: Voice?): Int {
        val locale = locales[lang] ?: Locale.GERMANY
        if (voice != null && sameLanguage(voice.locale, locale)) return tts.setVoice(voice)
        val status = tts.setLanguage(locale)
        if (status >= TextToSpeech.LANG_AVAILABLE) return status
        Log.w(TAG, "fallback=de lang=$lang status=$status")
        return if (voice != null) tts.setVoice(voice) else tts.setLanguage(Locale.GERMANY)
    }

    private fun sameLanguage(a: Locale, b: Locale) =
        runCatching { a.isO3Language == b.isO3Language }.getOrDefault(a.language == b.language)

    /** Splits only text longer than the engine limit, at whitespace; a single over-long token is cut. */
    private fun limit(text: String): List<String> {
        val max = TextToSpeech.getMaxSpeechInputLength() - 1
        val parts = mutableListOf<String>()
        var rest = text.trim()
        while (rest.length > max) {
            var cut = rest.lastIndexOfAny(charArrayOf(' ', '\n', '\t'), max)
            if (cut <= 0) cut = max
            parts.add(rest.substring(0, cut).trim())
            rest = rest.substring(cut).trim()
        }
        if (rest.isNotEmpty()) parts.add(rest)
        return parts
    }
}
