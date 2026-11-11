package com.tarkilhk.wing.voiceoffline

import android.app.Activity
import android.os.Build
import android.speech.SpeechRecognizer

internal fun onDeviceRecognition(activity: Activity): Boolean =
    Build.VERSION.SDK_INT >= 31 && SpeechRecognizer.isOnDeviceRecognitionAvailable(activity)

internal fun recognitionAvailable(activity: Activity): Boolean =
    onDeviceRecognition(activity) || SpeechRecognizer.isRecognitionAvailable(activity)

internal fun createRecognizer(activity: Activity): SpeechRecognizer =
    if (onDeviceRecognition(activity)) SpeechRecognizer.createOnDeviceSpeechRecognizer(activity)
    else SpeechRecognizer.createSpeechRecognizer(activity)

/** Drops heartbeat placeholders ("…"/"...") some offline recognizers emit as partial results. */
internal fun cleanTranscript(raw: String): String {
    val trimmed = raw.trim()
    if (trimmed.all { it == '…' || it == '.' || it.isWhitespace() }) return ""
    return trimmed.removePrefix("…").removePrefix("...").trim()
}
