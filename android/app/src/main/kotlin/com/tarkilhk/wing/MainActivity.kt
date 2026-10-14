package com.tarkilhk.wing

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.ClipData
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.MediaStore
import android.provider.OpenableColumns
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val shareChannelName = "com.tarkilhk.wing/share"
    private val launchChannelName = "com.tarkilhk.wing/launch"
    private val fileDeliveryChannelName = "com.tarkilhk.wing/file_delivery"
    private val quickChatAction = "com.tarkilhk.wing.action.QUICK_CHAT"
    private val activityAction = "com.tarkilhk.wing.action.ACTIVITY"
    private val searchChatsAction = "com.tarkilhk.wing.action.SEARCH_CHATS"
    private val intakePreferencesName = "pending_share_intake"
    private val intakeQueueKey = "queue"
    private val pendingCameraKey = "pending_camera"
    private val cameraRequestCode = 9301
    private val maxSharedItems = 10
    private val maxSharedBytes = 64L * 1024L * 1024L
    private val maxPendingRecords = 10
    private val maxPendingBytes = 128L * 1024L * 1024L
    private val maxSharedTextChars = 256 * 1024
    private var networkAvailability: NetworkAvailabilityChannel? = null
    private var hermesCloud: HermesCloudChannel? = null
    private var shareChannel: MethodChannel? = null
    private var launchChannel: MethodChannel? = null
    private var fileDeliveryChannel: MethodChannel? = null
    private var pdfPreviewChannel: PdfPreviewChannel? = null
    private var mediaPreviewChannel: MediaPreviewChannel? = null
    private var voiceChannel: VoiceChannel? = null
    private var imageClipboardChannel: ImageClipboardChannel? = null
    private var initialShareIntent: Intent? = null
    private var initialLaunchAction: String? = null
    @Volatile private var activityResumed = false
    private var engineAttached = false

    override fun provideFlutterEngine(context: Context): FlutterEngine? = MonitoringRuntime.engine

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        val retainedEngine = MonitoringRuntime.engine != null
        initialShareIntent = intent.takeIf(::isShareIntent)
        initialLaunchAction = launchActionFor(intent)
        super.onCreate(savedInstanceState)
        if (retainedEngine) {
            // Dart startup has already run. Deliver taps/shares to its existing listeners.
            initialShareIntent = null
            initialLaunchAction = null
            onNewIntent(intent)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        engineAttached = true
        MonitoringRuntime.attach(this, flutterEngine)
        hermesCloud?.close()
        hermesCloud = HermesCloudChannel(this, flutterEngine.dartExecutor.binaryMessenger)
        voiceChannel?.close()
        voiceChannel = VoiceChannel(this, flutterEngine.dartExecutor.binaryMessenger)
        networkAvailability?.close()
        networkAvailability = NetworkAvailabilityChannel(this, flutterEngine.dartExecutor.binaryMessenger)
        imageClipboardChannel = ImageClipboardChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            this,
        )
        pdfPreviewChannel = PdfPreviewChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            cacheDir,
        )
        mediaPreviewChannel = MediaPreviewChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            this,
        ) { activityResumed }
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "com.tarkilhk.wing/mermaid_diagram",
            MermaidDiagramViewFactory(),
        )
        shareChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, shareChannelName).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "getPendingShare" -> {
                        val pendingIntent = initialShareIntent
                        initialShareIntent = null
                        intakeExecutor.execute {
                            try {
                                recoverPendingCamera()
                                if (pendingIntent != null) importShareIntent(pendingIntent)
                                postResult(result, oldestPendingPayload())
                            } catch (error: Exception) {
                                postShareError(safeImportMessage(error))
                                postResult(result, oldestPendingPayloadSafely())
                            } finally {
                                if (pendingIntent != null) clearConsumedShareIntent(pendingIntent)
                            }
                        }
                    }
                    "acknowledgeShare" -> {
                        val id = (call.argument<String>("id") ?: "").trim()
                        intakeExecutor.execute {
                            try {
                                postResult(result, acknowledgeShare(id))
                            } catch (_: Exception) {
                                postError(result, "share_ack_failed", genericAcknowledgeError)
                            }
                        }
                    }
                    "capturePhoto" -> {
                        val target = call.argument<Map<*, *>>("target")
                        intakeExecutor.execute {
                            try {
                                val descriptor = prepareCameraCapture(target)
                                runOnUiThread { launchCamera(descriptor, result) }
                            } catch (error: CameraCaptureException) {
                                postError(result, error.code, error.safeMessage)
                            } catch (_: Exception) {
                                postError(result, "camera_unavailable", genericCameraError)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }
        launchChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, launchChannelName).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInitialLaunchAction" -> {
                        val pending = initialLaunchAction
                        initialLaunchAction = null
                        result.success(pending)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        fileDeliveryChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            fileDeliveryChannelName,
        ).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "openInApp" -> openDownloadedFile(
                        call.argument<String>("filename"),
                        call.argument<String>("mimeType"),
                        call.argument<ByteArray>("bytes"),
                        result,
                    )
                    else -> result.notImplemented()
                }
            }
        }
    }

    private fun openDownloadedFile(
        rawFilename: String?,
        rawMimeType: String?,
        bytes: ByteArray?,
        result: MethodChannel.Result,
    ) {
        val mimeType = rawMimeType?.trim()?.lowercase().orEmpty()
        if (mimeType !in supportedOutputMimeTypes ||
            bytes == null || bytes.isEmpty() || bytes.size > maxDeliveredBytes
        ) {
            result.error("file_open_invalid", genericFileOpenError, null)
            return
        }
        val filename = safeDeliveredFilename(rawFilename)
        intakeExecutor.execute {
            try {
                val directory = File(cacheDir, "delivered_outputs")
                if (!directory.exists() && !directory.mkdirs()) {
                    throw IllegalStateException()
                }
                cleanupDeliveredOutputs(directory)
                val output = File(directory, "${UUID.randomUUID()}-$filename")
                FileOutputStream(output).use { stream ->
                    stream.write(bytes)
                    stream.fd.sync()
                }
                val uri = FileProvider.getUriForFile(
                    this,
                    "$packageName.fileprovider",
                    output,
                )
                runOnUiThread {
                    if (isFinishing || isDestroyed || !activityResumed) {
                        output.delete()
                        result.error("file_open_inactive", genericFileOpenError, null)
                        return@runOnUiThread
                    }
                    try {
                        val view = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, mimeType)
                            clipData = ClipData.newRawUri("Wing output", uri)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        startActivity(view)
                        result.success(true)
                    } catch (_: ActivityNotFoundException) {
                        output.delete()
                        result.success(false)
                    } catch (_: Exception) {
                        output.delete()
                        result.error("file_open_failed", genericFileOpenError, null)
                    }
                }
            } catch (_: Exception) {
                postError(result, "file_open_failed", genericFileOpenError)
            }
        }
    }

    private fun safeDeliveredFilename(raw: String?): String {
        val basename = raw
            ?.substringAfterLast('/')
            ?.substringAfterLast('\\')
            ?.trim()
            .orEmpty()
            .replace(Regex("[^A-Za-z0-9._ -]"), "_")
            .takeLast(120)
        return basename.takeIf { it.isNotEmpty() && it != "." && it != ".." } ?: "output"
    }

    private fun cleanupDeliveredOutputs(directory: File) {
        val now = System.currentTimeMillis()
        directory.listFiles()
            ?.filter { it.isFile }
            ?.sortedByDescending { it.lastModified() }
            ?.forEachIndexed { index, file ->
                if (index >= maxDeliveredFiles || now - file.lastModified() > deliveredFileMaxAgeMs) {
                    file.delete()
                }
            }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        // Clean up at engine detachment, before a replacement host installs its
        // handlers. The old host's later onDestroy must not clear those handlers.
        engineAttached = false
        activityResumed = false
        hermesCloud?.close()
        hermesCloud = null
        voiceChannel?.close()
        voiceChannel = null
        networkAvailability?.close()
        networkAvailability = null
        shareChannel?.setMethodCallHandler(null)
        shareChannel = null
        launchChannel?.setMethodCallHandler(null)
        launchChannel = null
        fileDeliveryChannel?.setMethodCallHandler(null)
        fileDeliveryChannel = null
        imageClipboardChannel?.dispose()
        imageClipboardChannel = null
        mediaPreviewChannel?.closeAll()
        mediaPreviewChannel = null
        pdfPreviewChannel?.closeAll()
        pdfPreviewChannel = null
        MonitoringRuntime.detach(isChangingConfigurations)
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != cameraRequestCode) return
        intakeExecutor.execute {
            try {
                finishCameraCapture(resultCode == Activity.RESULT_OK)
            } catch (error: Exception) {
                postShareError(safeCameraMessage(error))
            }
        }
    }

    override fun onResume() {
        super.onResume()
        if (!engineAttached) return
        activityResumed = true
        voiceChannel?.resume()
        if (!getSystemService(android.app.KeyguardManager::class.java).isKeyguardLocked) {
            ChatNotifications.handleMainIntent(this, intent)
        }
        MonitoringRuntime.activityVisible = true
        intakeExecutor.execute {
            try {
                reconcilePendingCameraOnResume()
            } catch (error: Exception) {
                postShareError(safeCameraMessage(error))
            }
        }
    }

    override fun onPause() {
        voiceChannel?.pause()
        activityResumed = false
        if (engineAttached) MonitoringRuntime.activityVisible = false
        super.onPause()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        if (voiceChannel?.permissionResult(requestCode, grantResults) == true) return
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (activityResumed && !getSystemService(android.app.KeyguardManager::class.java).isKeyguardLocked) {
            ChatNotifications.handleMainIntent(this, intent)
        }
        launchActionFor(intent)?.let { action ->
            launchChannel?.invokeMethod("launchAction", action)
            return
        }
        if (!isShareIntent(intent)) return
        intakeExecutor.execute {
            try {
                recoverPendingCamera()
                importShareIntent(intent)
                postSharePayload(oldestPendingPayload())
            } catch (error: Exception) {
                postShareError(safeImportMessage(error))
            } finally {
                clearConsumedShareIntent(intent)
            }
        }
    }

    private fun launchActionFor(intent: Intent?): String? = when (intent?.action) {
        quickChatAction -> "quickChat"
        activityAction -> "activity"
        searchChatsAction -> "searchChats"
        else -> null
    }

    private fun isShareIntent(intent: Intent?): Boolean =
        intent?.action == Intent.ACTION_SEND || intent?.action == Intent.ACTION_SEND_MULTIPLE

    private fun prepareCameraCapture(rawTarget: Map<*, *>?): CameraDescriptor {
        if (readCameraDescriptor() != null) {
            throw CameraCaptureException("camera_busy", cameraBusyError)
        }
        val target = validatedCameraTarget(rawTarget)
        val queue = readQueue()
        pruneOrphanedIntake(queue)
        if (queue.length() >= maxPendingRecords ||
            queueBytes(queue) > maxPendingBytes - maxSharedBytes
        ) {
            throw CameraCaptureException("camera_intake_full", queueFullError)
        }

        val id = UUID.randomUUID().toString()
        val directory = File(intakeDirectory(), id)
        val output = File(directory, "camera.jpg")
        try {
            if (!directory.mkdirs() || !output.createNewFile()) {
                throw CameraCaptureException("camera_unavailable", genericCameraError)
            }
            val descriptor = CameraDescriptor(id, output.absolutePath, target)
            if (!writeCameraDescriptor(descriptor)) {
                throw CameraCaptureException("camera_unavailable", genericCameraError)
            }
            return descriptor
        } catch (error: CameraCaptureException) {
            directory.deleteRecursively()
            throw error
        } catch (_: Exception) {
            directory.deleteRecursively()
            throw CameraCaptureException("camera_unavailable", genericCameraError)
        }
    }

    private fun launchCamera(descriptor: CameraDescriptor, result: MethodChannel.Result) {
        var outputUri: Uri? = null
        try {
            val uri = FileProvider.getUriForFile(
                this,
                "$packageName.fileprovider",
                File(descriptor.path),
            )
            outputUri = uri
            val capture = Intent(MediaStore.ACTION_IMAGE_CAPTURE).apply {
                putExtra(MediaStore.EXTRA_OUTPUT, uri)
                clipData = ClipData.newRawUri("camera-output", uri)
                addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivityForResult(capture, cameraRequestCode)
            result.success(null)
        } catch (_: ActivityNotFoundException) {
            abandonCameraLaunch(descriptor, outputUri, result)
        } catch (_: Exception) {
            abandonCameraLaunch(descriptor, outputUri, result)
        }
    }

    private fun abandonCameraLaunch(
        descriptor: CameraDescriptor,
        outputUri: Uri?,
        result: MethodChannel.Result,
    ) {
        if (outputUri != null) revokeCameraGrant(outputUri)
        intakeExecutor.execute {
            writeCameraDescriptor(null)
            deleteIntakeDirectory(descriptor.id)
            postError(result, "camera_unavailable", genericCameraError)
        }
    }

    private fun finishCameraCapture(succeeded: Boolean) {
        val descriptor = readCameraDescriptor() ?: return
        cameraOutputUri(descriptor)?.let(::revokeCameraGrant)
        if (!succeeded) {
            val cleared = writeCameraDescriptor(null)
            deleteIntakeDirectory(descriptor.id)
            if (!cleared) {
                throw CameraCaptureException("camera_unavailable", cameraCleanupError)
            }
            return
        }
        val queue = readQueue()
        enqueueCameraIfReady(descriptor, queue)
        postSharePayload(oldestPayload(queue))
    }

    private fun recoverPendingCamera() {
        val descriptor = readCameraDescriptor() ?: return
        val queue = readQueue()
        if (queueContains(queue, descriptor.id)) {
            cameraOutputUri(descriptor)?.let(::revokeCameraGrant)
            writeCameraDescriptor(null)
            return
        }
        if (!activityResumed) return
        val output = File(descriptor.path)
        if (!output.exists()) {
            if (!writeCameraDescriptor(null)) {
                throw CameraCaptureException("camera_unavailable", cameraCleanupError)
            }
            deleteIntakeDirectory(descriptor.id)
            return
        }
        if (!output.isFile || output.length() == 0L) return
        try {
            enqueueCameraIfReady(descriptor, queue)
        } finally {
            cameraOutputUri(descriptor)?.let(::revokeCameraGrant)
        }
    }

    private fun reconcilePendingCameraOnResume() {
        val descriptor = readCameraDescriptor() ?: return
        val queue = readQueue()
        if (queueContains(queue, descriptor.id)) {
            cameraOutputUri(descriptor)?.let(::revokeCameraGrant)
            writeCameraDescriptor(null)
            return
        }
        val output = File(descriptor.path)
        if (!output.isFile || output.length() == 0L) {
            cameraOutputUri(descriptor)?.let(::revokeCameraGrant)
            val cleared = writeCameraDescriptor(null)
            deleteIntakeDirectory(descriptor.id)
            if (!cleared) {
                throw CameraCaptureException("camera_unavailable", cameraCleanupError)
            }
            return
        }
        try {
            enqueueCameraIfReady(descriptor, queue)
            postSharePayload(oldestPayload(queue))
        } finally {
            cameraOutputUri(descriptor)?.let(::revokeCameraGrant)
        }
    }

    private fun enqueueCameraIfReady(descriptor: CameraDescriptor, queue: JSONArray) {
        if (queueContains(queue, descriptor.id)) {
            writeCameraDescriptor(null)
            return
        }
        val output = File(descriptor.path)
        val length = if (output.isFile) output.length() else 0L
        if (length <= 0L || length > maxSharedBytes) {
            writeCameraDescriptor(null)
            deleteIntakeDirectory(descriptor.id)
            throw CameraCaptureException("camera_invalid_output", invalidCameraOutputError)
        }
        if (queue.length() >= maxPendingRecords || queueBytes(queue) + length > maxPendingBytes) {
            throw CameraCaptureException("camera_intake_full", queueFullError)
        }
        val file = JSONObject()
            .put("path", output.absolutePath)
            .put("name", "Camera photo.jpg")
            .put("mediaType", "image/jpeg")
            .put("byteLength", length)
        queue.put(
            JSONObject()
                .put("id", descriptor.id)
                .put("fingerprint", "camera:${descriptor.id}")
                .put("text", JSONObject.NULL)
                .put("files", JSONArray().put(file))
                .put("target", JSONObject(descriptor.target)),
        )
        if (!writeQueue(queue)) {
            queue.remove(queue.length() - 1)
            throw CameraCaptureException("camera_unavailable", cameraStorageError)
        }
        // A crash between these commits leaves both markers. Recovery matches the
        // record ID and clears the descriptor without enqueueing a duplicate.
        writeCameraDescriptor(null)
    }

    private fun validatedCameraTarget(raw: Map<*, *>?): Map<String, String> {
        val keys = listOf("connection", "connection_identity", "profile", "session")
        if (raw == null || raw.keys.any { it !in keys }) {
            throw CameraCaptureException("camera_invalid_target", invalidCameraTargetError)
        }
        return keys.associateWith { key ->
            (raw[key] as? String)?.trim()?.takeIf { it.isNotEmpty() }
                ?: throw CameraCaptureException("camera_invalid_target", invalidCameraTargetError)
        }
    }

    private fun cameraOutputUri(descriptor: CameraDescriptor): Uri? = try {
        FileProvider.getUriForFile(this, "$packageName.fileprovider", File(descriptor.path))
    } catch (_: Exception) {
        null
    }

    private fun revokeCameraGrant(uri: Uri) {
        try {
            revokeUriPermission(
                uri,
                Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_READ_URI_PERMISSION,
            )
        } catch (_: Exception) {
            // The camera app may already have released its temporary grant.
        }
    }

    private fun queueContains(queue: JSONArray, id: String): Boolean =
        (0 until queue.length()).any { queue.getJSONObject(it).optString("id") == id }

    private fun importShareIntent(intent: Intent) {
        val queue = readQueue()
        pruneOrphanedIntake(queue)
        val fingerprint = shareFingerprint(intent)
        val alreadyPending = (0 until queue.length()).any {
            queue.getJSONObject(it).optString("fingerprint") == fingerprint
        }
        if (alreadyPending) return
        val cameraPending = readCameraDescriptor() != null
        if (queue.length() + (if (cameraPending) 1 else 0) >= maxPendingRecords) {
            throw ShareImportException(queueFullError)
        }

        val text = extractSharedText(intent)
        if ((text?.length ?: 0) > maxSharedTextChars) {
            throw ShareImportException(textTooLargeError)
        }
        val uris = sharedUris(intent)
        if (uris.size > maxSharedItems) {
            throw ShareImportException(tooManyFilesError)
        }
        if (text == null && uris.isEmpty()) {
            throw ShareImportException(genericImportError)
        }

        val id = UUID.randomUUID().toString()
        val directory = File(intakeDirectory(), id)
        val files = JSONArray()
        var copiedBytes = 0L
        try {
            uris.forEachIndexed { index, uri ->
                val remainingIncoming = maxSharedBytes - copiedBytes
                val cameraReservation = if (cameraPending) maxSharedBytes else 0L
                val remainingQueue =
                    maxPendingBytes - cameraReservation - queueBytes(queue) - copiedBytes
                if (remainingIncoming <= 0L) throw ShareImportException(incomingTooLargeError)
                if (remainingQueue <= 0L) throw ShareImportException(queueFullError)
                val file = copySharedUri(
                    uri = uri,
                    index = index,
                    fallbackType = intent.type,
                    directory = directory,
                    byteLimit = minOf(remainingIncoming, remainingQueue),
                    queueIsLimiting = remainingQueue < remainingIncoming,
                )
                files.put(file)
                copiedBytes += file.getLong("byteLength")
            }
            val record = JSONObject()
                .put("id", id)
                .put("fingerprint", fingerprint)
                .put("text", text ?: JSONObject.NULL)
                .put("files", files)
            queue.put(record)
            if (!writeQueue(queue)) throw ShareImportException(genericImportError)
        } catch (error: ShareImportException) {
            directory.deleteRecursively()
            throw error
        } catch (_: Exception) {
            directory.deleteRecursively()
            throw ShareImportException(genericImportError)
        }
    }

    private fun acknowledgeShare(id: String): Map<String, Any?>? {
        if (id.isEmpty()) throw ShareImportException(genericImportError)
        val queue = readQueue()
        val next = JSONArray()
        var removed = false
        for (index in 0 until queue.length()) {
            val record = queue.getJSONObject(index)
            if (!removed && record.getString("id") == id) {
                removed = true
            } else {
                next.put(record)
            }
        }
        if (removed) {
            if (!writeQueue(next)) throw ShareImportException(genericImportError)
            deleteIntakeDirectory(id)
        }
        pruneOrphanedIntake(next)
        return oldestPayload(next)
    }

    private fun copySharedUri(
        uri: Uri,
        index: Int,
        fallbackType: String?,
        directory: File,
        byteLimit: Long,
        queueIsLimiting: Boolean,
    ): JSONObject {
        val mediaType = contentResolver.getType(uri)?.trim().orEmpty()
            .ifEmpty { fallbackType?.trim().orEmpty() }
            .ifEmpty { "application/octet-stream" }
        val displayName = queryDisplayName(uri)
            ?.let(::safeDisplayName)
            ?.takeIf { it.isNotEmpty() && it != "." && it != ".." }
            ?: "shared-${index + 1}"
        directory.mkdirs()
        val destination = File(directory, "${UUID.randomUUID()}-$displayName")
        try {
            val input = contentResolver.openInputStream(uri)
                ?: throw ShareImportException(genericImportError)
            var total = 0L
            input.use { source ->
                FileOutputStream(destination).use { output ->
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    while (true) {
                        val read = source.read(buffer)
                        if (read < 0) break
                        total += read
                        if (total > byteLimit) {
                            throw ShareImportException(
                                if (queueIsLimiting) queueFullError else incomingTooLargeError,
                            )
                        }
                        output.write(buffer, 0, read)
                    }
                    output.flush()
                }
            }
            if (total <= 0L) throw ShareImportException(genericImportError)
            return JSONObject()
                .put("path", destination.absolutePath)
                .put("name", displayName)
                .put("mediaType", mediaType)
                .put("byteLength", total)
        } catch (error: ShareImportException) {
            destination.delete()
            throw error
        } catch (_: Exception) {
            destination.delete()
            throw ShareImportException(genericImportError)
        }
    }

    private fun readQueue(): JSONArray {
        val raw = intakePreferences().getString(intakeQueueKey, null) ?: return JSONArray()
        try {
            val queue = JSONArray(raw)
            if (queue.length() > maxPendingRecords) throw ShareImportException(genericImportError)
            for (index in 0 until queue.length()) validateRecord(queue.getJSONObject(index))
            if (queueBytes(queue) > maxPendingBytes) throw ShareImportException(genericImportError)
            return queue
        } catch (error: ShareImportException) {
            throw error
        } catch (_: Exception) {
            throw ShareImportException(genericImportError)
        }
    }

    private fun validateRecord(record: JSONObject) {
        val id = record.optString("id")
        if (!uuidPattern.matches(id) || record.optString("fingerprint").isEmpty()) {
            throw ShareImportException(genericImportError)
        }
        val files = record.optJSONArray("files") ?: throw ShareImportException(genericImportError)
        if (files.length() > maxSharedItems) throw ShareImportException(genericImportError)
        for (index in 0 until files.length()) {
            val file = files.getJSONObject(index)
            val path = file.optString("path")
            val length = file.optLong("byteLength", -1)
            if (path.isEmpty() || file.optString("name").isEmpty() || length <= 0L) {
                throw ShareImportException(genericImportError)
            }
        }
        if (record.has("target")) validateTargetObject(record.optJSONObject("target"))
    }

    private fun readCameraDescriptor(): CameraDescriptor? {
        val raw = intakePreferences().getString(pendingCameraKey, null) ?: return null
        try {
            val value = JSONObject(raw)
            val id = value.getString("record_id")
            if (!uuidPattern.matches(id)) {
                throw CameraCaptureException("camera_unavailable", genericCameraError)
            }
            val expected = File(File(intakeDirectory(), id), "camera.jpg").canonicalFile
            val stored = File(value.getString("path")).canonicalFile
            if (stored != expected) {
                throw CameraCaptureException("camera_unavailable", genericCameraError)
            }
            val target = validateTargetObject(value.optJSONObject("target"))
            return CameraDescriptor(id, expected.absolutePath, target)
        } catch (error: CameraCaptureException) {
            throw error
        } catch (_: Exception) {
            throw CameraCaptureException("camera_unavailable", genericCameraError)
        }
    }

    private fun validateTargetObject(value: JSONObject?): Map<String, String> {
        if (value == null) {
            throw CameraCaptureException("camera_invalid_target", invalidCameraTargetError)
        }
        val raw = mutableMapOf<String, Any?>()
        value.keys().forEach { key -> raw[key] = value.opt(key) }
        return validatedCameraTarget(raw)
    }

    private fun writeCameraDescriptor(descriptor: CameraDescriptor?): Boolean {
        val preferences = intakePreferences()
        val previous = preferences.getString(pendingCameraKey, null)
        val editor = preferences.edit()
        if (descriptor == null) {
            editor.remove(pendingCameraKey)
        } else {
            editor.putString(
                pendingCameraKey,
                JSONObject()
                    .put("record_id", descriptor.id)
                    .put("path", descriptor.path)
                    .put("target", JSONObject(descriptor.target))
                    .toString(),
            )
        }
        if (editor.commit()) return true

        val rollback = preferences.edit()
        if (previous == null) rollback.remove(pendingCameraKey)
        else rollback.putString(pendingCameraKey, previous)
        rollback.commit()
        return false
    }

    private fun writeQueue(queue: JSONArray): Boolean {
        val preferences = intakePreferences()
        val previous = preferences.getString(intakeQueueKey, null)
        val editor = preferences.edit()
        if (queue.length() == 0) editor.remove(intakeQueueKey)
        else editor.putString(intakeQueueKey, queue.toString())
        if (editor.commit()) return true

        // commit() updates the process cache before reporting a disk failure.
        // Restore the authoritative queue in memory and best-effort on disk.
        val rollback = preferences.edit()
        if (previous == null) rollback.remove(intakeQueueKey)
        else rollback.putString(intakeQueueKey, previous)
        rollback.commit()
        return false
    }

    private fun oldestPendingPayload(): Map<String, Any?>? = oldestPayload(readQueue())

    private fun oldestPendingPayloadSafely(): Map<String, Any?>? = try {
        oldestPendingPayload()
    } catch (_: Exception) {
        null
    }

    private fun oldestPayload(queue: JSONArray): Map<String, Any?>? =
        if (queue.length() == 0) null else payloadMap(queue.getJSONObject(0))

    private fun payloadMap(record: JSONObject): Map<String, Any?> {
        val files = record.getJSONArray("files")
        val payload = mutableMapOf<String, Any?>(
            "id" to record.getString("id"),
            "text" to if (record.isNull("text")) null else record.getString("text"),
            "files" to List(files.length()) { index ->
                val file = files.getJSONObject(index)
                mapOf(
                    "path" to file.getString("path"),
                    "name" to file.getString("name"),
                    "mediaType" to file.getString("mediaType"),
                    "byteLength" to file.getLong("byteLength"),
                )
            },
        )
        record.optJSONObject("target")?.let { target ->
            payload["target"] = validateTargetObject(target)
        }
        return payload
    }

    private fun queueBytes(queue: JSONArray): Long {
        var total = 0L
        for (recordIndex in 0 until queue.length()) {
            val files = queue.getJSONObject(recordIndex).getJSONArray("files")
            for (fileIndex in 0 until files.length()) {
                total += files.getJSONObject(fileIndex).getLong("byteLength")
            }
        }
        return total
    }

    private fun pruneOrphanedIntake(queue: JSONArray) {
        val retained = mutableSetOf<String>()
        for (index in 0 until queue.length()) retained += queue.getJSONObject(index).getString("id")
        readCameraDescriptor()?.let { retained += it.id }
        intakeDirectory().listFiles()?.forEach { file ->
            if (file.isDirectory && file.name !in retained) file.deleteRecursively()
        }
    }

    private fun deleteIntakeDirectory(id: String) {
        if (uuidPattern.matches(id)) File(intakeDirectory(), id).deleteRecursively()
    }

    private fun intakeDirectory(): File = File(filesDir, "pending_intake").apply { mkdirs() }

    private fun intakePreferences() =
        getSharedPreferences(intakePreferencesName, MODE_PRIVATE)

    private fun extractSharedText(intent: Intent): String? {
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)?.trim().orEmpty()
        val subject = intent.getStringExtra(Intent.EXTRA_SUBJECT)?.trim().orEmpty()
        return when {
            text.isEmpty() -> subject.ifEmpty { null }
            subject.isEmpty() || text.startsWith(subject) -> text
            else -> "$subject\n\n$text"
        }
    }

    @Suppress("DEPRECATION")
    private fun sharedUris(intent: Intent): List<Uri> {
        val streams = when (intent.action) {
            Intent.ACTION_SEND_MULTIPLE ->
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM).orEmpty()
            Intent.ACTION_SEND ->
                listOfNotNull(intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))
            else -> emptyList()
        }.toMutableList()
        val clip = intent.clipData
        if (clip != null) {
            for (index in 0 until clip.itemCount) clip.getItemAt(index).uri?.let(streams::add)
        }
        return streams.distinct()
    }

    private fun shareFingerprint(intent: Intent): String {
        val source = buildString {
            append(intent.action.orEmpty()).append('\u0000')
            append(intent.type.orEmpty()).append('\u0000')
            append(extractSharedText(intent).orEmpty()).append('\u0000')
            sharedUris(intent).forEach { append(it.toString()).append('\u0000') }
        }
        return MessageDigest.getInstance("SHA-256")
            .digest(source.toByteArray(Charsets.UTF_8))
            .joinToString("") { (it.toInt() and 0xff).toString(16).padStart(2, '0') }
    }

    private fun queryDisplayName(uri: Uri): String? = try {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (!cursor.moveToFirst()) return@use null
            val column = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (column < 0) null else cursor.getString(column)
        }
    } catch (_: Exception) {
        null
    }

    private fun safeDisplayName(value: String): String =
        value.substringAfterLast('/').substringAfterLast('\\')
            .replace(Regex("[^A-Za-z0-9._() -]"), "_")
            .take(160)

    private fun postResult(result: MethodChannel.Result, value: Any?) {
        runOnUiThread { result.success(value) }
    }

    private fun postError(result: MethodChannel.Result, code: String, message: String) {
        runOnUiThread { result.error(code, message, null) }
    }

    private fun postSharePayload(payload: Map<String, Any?>?) {
        if (payload != null) runOnUiThread { shareChannel?.invokeMethod("sharePayload", payload) }
    }

    private fun postShareError(message: String) {
        runOnUiThread { shareChannel?.invokeMethod("shareError", message) }
    }

    private fun safeImportMessage(error: Exception): String =
        when (error) {
            is ShareImportException -> error.safeMessage
            is CameraCaptureException -> error.safeMessage
            else -> genericImportError
        }

    private fun safeCameraMessage(error: Exception): String =
        (error as? CameraCaptureException)?.safeMessage ?: genericCameraError

    private fun clearConsumedShareIntent(consumed: Intent) {
        runOnUiThread {
            if (intent !== consumed) return@runOnUiThread
            setIntent(
                Intent(consumed).apply {
                    action = null
                    type = null
                    clipData = null
                    removeExtra(Intent.EXTRA_TEXT)
                    removeExtra(Intent.EXTRA_SUBJECT)
                    removeExtra(Intent.EXTRA_STREAM)
                },
            )
        }
    }

    private class ShareImportException(val safeMessage: String) : Exception()

    private class CameraCaptureException(
        val code: String,
        val safeMessage: String,
    ) : Exception()

    private data class CameraDescriptor(
        val id: String,
        val path: String,
        val target: Map<String, String>,
    )

    companion object {
        private val intakeExecutor = Executors.newSingleThreadExecutor()
        private const val maxDeliveredBytes = 32 * 1024 * 1024
        private const val maxDeliveredFiles = 12
        private const val deliveredFileMaxAgeMs = 24L * 60L * 60L * 1000L
        private val supportedOutputMimeTypes = setOf(
            "application/pdf",
            "audio/aac", "audio/flac", "audio/mp4", "audio/mpeg", "audio/ogg",
            "audio/wav", "audio/webm", "audio/x-wav",
            "video/mp4", "video/mpeg", "video/quicktime", "video/webm",
            "video/x-matroska", "video/x-msvideo",
        )
        private val uuidPattern = Regex(
            "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$",
        )
        private const val tooManyFilesError = "You can share up to 10 files at once."
        private const val incomingTooLargeError = "Shared files are limited to 64 MiB at once."
        private const val queueFullError =
            "Shared draft storage is full. Add or discard a pending share first."
        private const val textTooLargeError = "Shared text is too large to import."
        private const val genericImportError =
            "Shared content could not be imported. Try sharing it again."
        private const val genericAcknowledgeError =
            "The pending share could not be cleared. Try again."
        private const val cameraBusyError = "A camera capture is already in progress."
        private const val invalidCameraTargetError =
            "The destination chat is no longer available for this photo."
        private const val invalidCameraOutputError =
            "The camera did not return a usable photo."
        private const val cameraCleanupError =
            "The canceled photo could not be cleared. Try again."
        private const val cameraStorageError =
            "The photo could not be saved for review. Try again."
        private const val genericCameraError =
            "The camera could not be opened. Try again."
        private const val genericFileOpenError =
            "This file could not be opened on this device."
    }
}
