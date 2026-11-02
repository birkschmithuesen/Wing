import java.nio.channels.FileChannel
import java.nio.channels.FileLock
import java.nio.channels.OverlappingFileLockException
import java.nio.file.StandardOpenOption
import org.gradle.api.file.RegularFileProperty
import org.gradle.api.services.BuildService
import org.gradle.api.services.BuildServiceParameters

pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.5.0" apply false
    id("org.jetbrains.kotlin.android") version "2.4.21" apply false
}

include(":app")

// Cover direct Gradle/Flutter commands as well as the personal build script.
// Competing checkouts otherwise consume the warm daemon and compile in parallel.
abstract class HermesBuildLease : BuildService<HermesBuildLease.Parameters>, AutoCloseable {
    interface Parameters : BuildServiceParameters {
        val lockFile: RegularFileProperty
    }

    private var channel: FileChannel? = null
    private var lease: FileLock? = null

    @Synchronized
    fun acquire() {
        if (lease != null) return
        val opened = FileChannel.open(
            parameters.lockFile.get().asFile.toPath(),
            StandardOpenOption.CREATE, StandardOpenOption.WRITE
        )
        try {
            val acquired = try { opened.tryLock() } catch (_: OverlappingFileLockException) { null }
            check(acquired != null) {
                "Another Wing build is running. Let it finish, then retry. " +
                    "Reuse one checkout to keep Flutter and Gradle incremental outputs."
            }
            channel = opened
            lease = acquired
        } catch (failure: Throwable) {
            opened.close()
            throw failure
        }
    }

    override fun close() {
        try { lease?.release() } finally { channel?.close() }
    }
}

val hermesBuildLease = gradle.sharedServices.registerIfAbsent("hermesBuildLease", HermesBuildLease::class) {
    parameters.lockFile.fileValue(gradle.gradleUserHomeDir.resolve("wing-build.lock"))
}
hermesBuildLease.get().acquire()
gradle.beforeProject {
    tasks.configureEach { usesService(hermesBuildLease) }
}
