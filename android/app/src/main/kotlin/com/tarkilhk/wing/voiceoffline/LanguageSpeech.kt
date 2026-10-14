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
 *
 * Each segment may carry `paragraphBreak = "true"` (Dart: [SpeechSegment.paragraphBreak], segment
 * granularity) when it is the first segment of a new paragraph (a blank line in the original reply). A
 * ~1 s silent utterance is queued before such a segment's first part, on top of the shorter gap the engine
 * already leaves between queued utterances. Dart only marks the *segment* that starts a paragraph: if
 * several paragraphs merge into one same-language segment (an unsure sentence takes its neighbour's
 * language across a blank line), the break lands inside that segment's text as a plain `\n` instead and is
 * not spoken as a pause. That is an accepted trade-off for keeping the wire format simple.
 */
object LanguageSpeech {
    private const val TAG = "WingTtsLang"
    private const val PARAGRAPH_SILENCE_MS = 1000L
    private val locales = mapOf("de" to Locale.GERMANY, "en" to Locale.US)

    private data class Part(val text: String, val lang: String, val paragraphBreak: Boolean)

    fun enqueue(tts: TextToSpeech, owner: String, text: String, segments: List<Map<String, String>>?, voice: Voice?) {
        val parts = segments.orEmpty()
            .filter { !it["text"].isNullOrBlank() }
            .flatMap { segment ->
                val lang = segment["lang"] ?: "de"
                val paragraphBreak = segment["paragraphBreak"] == "true"
                limit(segment.getValue("text")).mapIndexed { i, chunk ->
                    Part(chunk, lang, paragraphBreak && i == 0)
                }
            }
            .ifEmpty { limit(text).map { Part(it, "", false) } }
        parts.forEachIndexed { index, part ->
            if (part.paragraphBreak) tts.playSilentUtterance(PARAGRAPH_SILENCE_MS, TextToSpeech.QUEUE_ADD, null)
            val started = SystemClock.elapsedRealtime()
            val status = if (part.lang.isEmpty()) TextToSpeech.SUCCESS else select(tts, part.lang, voice)
            val elapsed = SystemClock.elapsedRealtime() - started
            Log.i(TAG, "segment ${index + 1}/${parts.size} lang=${part.lang.ifEmpty { "default" }} status=$status ms=$elapsed chars=${part.text.length}")
            val tag = if (index == parts.lastIndex) "$owner:last" else "$owner:$index"
            check(tts.speak(part.text, TextToSpeech.QUEUE_ADD, null, tag) == TextToSpeech.SUCCESS) { "Could not generate speech." }
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
