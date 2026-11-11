// Fork (Wing Voice): on-device speech dependencies and the side-by-side variant.
// Applied at the end of build.gradle.kts so these overrides run after upstream's.
import com.android.build.api.dsl.ApplicationExtension
import com.android.build.api.variant.ApplicationAndroidComponentsExtension
import java.io.File
import java.net.URI
import java.security.MessageDigest

/** Downloads a pinned artifact once and verifies its SHA256 (never committed to git). */
abstract class FetchVerifiedFile : DefaultTask() {
    @get:Input
    abstract val url: Property<String>

    @get:Input
    abstract val sha256: Property<String>

    @get:Input
    abstract val fileName: Property<String>

    @get:OutputDirectory
    abstract val outputDirectory: DirectoryProperty

    @TaskAction
    fun fetch() {
        val target = outputDirectory.file(fileName).get().asFile
        if (target.isFile && digest(target) == sha256.get()) return
        target.parentFile.mkdirs()
        val part = File(target.path + ".part")
        URI(url.get()).toURL().openStream().use { input ->
            part.outputStream().use { input.copyTo(it) }
        }
        val actual = digest(part)
        check(actual == sha256.get()) { "SHA256 mismatch for ${url.get()}: $actual" }
        check(part.renameTo(target)) { "Could not move $part to $target" }
    }

    private fun digest(file: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { stream ->
            val buffer = ByteArray(1 shl 16)
            while (true) {
                val n = stream.read(buffer)
                if (n < 0) break
                md.update(buffer, 0, n)
            }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }
}

val fetchSherpaOnnxAar = tasks.register<FetchVerifiedFile>("fetchSherpaOnnxAar") {
    url.set("https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.8/sherpa-onnx-1.13.8.aar")
    sha256.set("633c24321e06b1fe79feafa03ea16cbc0f8a286641e2da3559bac91bdb13bd96")
    fileName.set("sherpa-onnx-1.13.8.aar")
    outputDirectory.set(layout.projectDirectory.dir("libs"))
}
val fetchSileroVad = tasks.register<FetchVerifiedFile>("fetchSileroVad") {
    url.set("https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx")
    sha256.set("9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6")
    fileName.set("silero_vad.onnx")
    outputDirectory.set(layout.buildDirectory.dir("generated/vadAssets"))
}
// preBuild is created by AGP per variant; match it lazily.
tasks.matching { it.name == "preBuild" }.configureEach { dependsOn(fetchSherpaOnnxAar) }

// Local side-by-side variant ("Wing Voice"): own package id and label, so it
// installs next to the official Wing release and signs with a local key.
val voiceVariant = providers.gradleProperty("voiceVariant").orNull == "true"

extensions.configure<ApplicationExtension>("android") {
    buildTypes.getByName("release") {
        proguardFiles("proguard-rules.pro")
        if (voiceVariant) manifestPlaceholders["appLabel"] = "Wing Voice"
    }
}

extensions.configure<ApplicationAndroidComponentsExtension>("androidComponents") {
    onVariants(selector().withBuildType("release")) { variant ->
        if (voiceVariant) variant.applicationId.set("com.tarkilhk.wing.voice")
    }
    onVariants { variant ->
        variant.sources.assets?.addGeneratedSourceDirectory(
            fetchSileroVad, FetchVerifiedFile::outputDirectory
        )
    }
}

dependencies {
    add("implementation", files("libs/sherpa-onnx-1.13.8.aar"))
    add("implementation", "org.apache.commons:commons-compress:1.27.1")
}
