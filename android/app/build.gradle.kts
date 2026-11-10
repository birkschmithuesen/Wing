import com.android.build.gradle.internal.api.ApkVariantOutputImpl
import java.io.FileInputStream
import java.util.Properties

plugins {
   id("com.android.application")
   id("dev.flutter.flutter-gradle-plugin")
}

abstract class GenerateLauncherShortcuts : DefaultTask() {
    @get:Input
    abstract val applicationId: Property<String>

    @get:InputFile
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val template: RegularFileProperty

    @get:OutputDirectory
    abstract val outputDirectory: DirectoryProperty

    @TaskAction
    fun generate() {
        val output = outputDirectory.file("xml/shortcuts.xml").get().asFile
        output.parentFile.mkdirs()
        output.writeText(
            template.get().asFile.readText().replace("@APPLICATION_ID@", applicationId.get())
        )
    }
}

val keystoreProperties = Properties()
val keystorePath = rootProject.projectDir.parentFile.resolve("key.properties")
val minimumInstalledVersionCode = 2127
if (keystorePath.exists()) {
   keystoreProperties.load(FileInputStream(keystorePath))
}
val signingEnvironment = mapOf(
    "storeFile" to "WING_STORE_FILE",
    "storePassword" to "WING_STORE_PASSWORD",
    "keyAlias" to "WING_KEY_ALIAS",
    "keyPassword" to "WING_KEY_PASSWORD"
)
if (signingEnvironment.values.any { !System.getenv(it).isNullOrBlank() }) {
    check(signingEnvironment.values.all { !System.getenv(it).isNullOrBlank() }) {
        "All WING signing environment variables must be supplied"
    }
    signingEnvironment.forEach { (property, environment) ->
        keystoreProperties[property] = System.getenv(environment)
    }
}
val hasReleaseSigning = keystoreProperties.containsKey("storeFile")
// Opt in only for Wing development APKs. Ordinary debug builds retain
// their separate Dev identity and debug signing key.
val notificationQa = providers.gradleProperty("notificationQa").orNull == "true"
val nativeShareQa = providers.gradleProperty("nativeShareQa").orNull == "true"
check(!nativeShareQa || notificationQa) { "Native share QA requires the isolated notification QA package" }
val wingDevelopment = providers.gradleProperty("wingDevelopment").orNull == "true"
check(!(notificationQa && wingDevelopment)) { "Notification QA must use its isolated package" }
check(!wingDevelopment || signingEnvironment.keys.all {
    !keystoreProperties.getProperty(it).isNullOrBlank()
}) {
    "Wing development APKs require the complete Wing signing configuration"
}

android {
   buildFeatures { buildConfig = true }
   namespace = "com.tarkilhk.wing"
   compileSdk = 36
   ndkVersion = providers.gradleProperty("wing.ndkVersion").get()

   compileOptions {
       sourceCompatibility = JavaVersion.VERSION_17
       targetCompatibility = JavaVersion.VERSION_17
       isCoreLibraryDesugaringEnabled = true
   }

   defaultConfig {
       buildConfigField("boolean", "NATIVE_SHARE_QA", "false")
       check(flutter.versionCode > minimumInstalledVersionCode) {
           "versionCode ${flutter.versionCode} must be greater than " +
               "$minimumInstalledVersionCode to upgrade the accepted Wing APK"
       }
       applicationId = "com.tarkilhk.wing"
       minSdk = 24
       targetSdk = 36
       versionCode = flutter.versionCode
       versionName = flutter.versionName
       manifestPlaceholders["appLabel"] = "Wing"
   }

   signingConfigs {
       create("release") {
           if (keystoreProperties.containsKey("storeFile")) {
               storeFile = file(keystoreProperties["storeFile"] as String)
               storePassword = keystoreProperties["storePassword"] as String
               keyAlias = keystoreProperties["keyAlias"] as String
               keyPassword = keystoreProperties["keyPassword"] as String
           }
       }
   }

   buildTypes {
       debug {
           // The guarded Flutter versionCode is the base. The F-Droid ABI-split
           // block below derives per-ABI codes as base * 10 + ABI code; CI
           // verifies the packaged arm64 code against that scheme.
           applicationIdSuffix = if (notificationQa) ".notificationqa" else ".dev"
           versionNameSuffix = "-dev"
           buildConfigField("boolean", "NATIVE_SHARE_QA", nativeShareQa.toString())
           manifestPlaceholders["appLabel"] = "Wing Dev"
           if (wingDevelopment) {
               signingConfig = signingConfigs.getByName("release")
           }
       }
       getByName("profile") {
           // AOT performance builds must upgrade the separate Perf QA app, never
           // replace the user's installed release or its saved connections.
           applicationIdSuffix = ".perfqa"
           versionNameSuffix = "-perfqa"
           manifestPlaceholders["appLabel"] = "Wing Perf QA"
           signingConfig = signingConfigs.getByName("debug")
       }
       release {
           // CI/local analysis may build a release artifact without access to
           // the private distribution keystore. Never fall back to the debug
           // key: leave the APK explicitly unsigned until the real
           // key.properties file is supplied.
           manifestPlaceholders["appLabel"] = "Wing"
           if (hasReleaseSigning) {
               signingConfig = signingConfigs.getByName("release")
           }
       }
   }
}

// Signed development builds use the Wing release application ID.
androidComponents {
    onVariants(selector().withBuildType("debug")) { variant ->
        if (wingDevelopment) {
            variant.applicationId.set("com.tarkilhk.wing")
        }
    }
    onVariants(selector().withBuildType("release")) { variant ->
        variant.applicationId.set("com.tarkilhk.wing")
    }
    onVariants { variant ->
        // Android parses shortcut intents with system resources, so the target
        // package must be a literal, not an app string resource or placeholder.
        val generateShortcuts = tasks.register<GenerateLauncherShortcuts>(
            "generate${variant.name.replaceFirstChar { it.uppercase() }}LauncherShortcuts"
        ) {
            applicationId.set(variant.applicationId)
            template.set(layout.projectDirectory.file("src/main/shortcuts.xml.template"))
            outputDirectory.set(layout.buildDirectory.dir("generated/launcherShortcuts/${variant.name}"))
        }
        variant.sources.res?.addGeneratedSourceDirectory(
            generateShortcuts, GenerateLauncherShortcuts::outputDirectory
        )
    }
}

kotlin {
   compilerOptions {
       jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
   }
}

flutter {
   source = "../.."
}

// F-Droid ABI split: version codes are derived per ABI as base * 10 + abiCode,
// with armeabi-v7a < arm64-v8a < x86_64 as required by fdroiddata.
val abiCodes = mapOf("armeabi-v7a" to 1, "arm64-v8a" to 2, "x86_64" to 3)
android.applicationVariants.configureEach {
    val variant = this
    variant.outputs.forEach { output ->
        val abiVersionCode =
            abiCodes[output.filters.find { it.filterType == "ABI" }?.identifier]
        if (abiVersionCode != null) {
            (output as ApkVariantOutputImpl).versionCodeOverride =
                variant.versionCode * 10 + abiVersionCode
        }
    }
}

dependencies {
   coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
   testImplementation("junit:junit:4.13.2")
   testImplementation("org.robolectric:robolectric:4.16.1")
   // JVM tests exercise the actual native JSON boundary, outside Android's stub jar.
   testImplementation("org.json:json:20260814")
}

// Correct the upstream animation-cache lifetime in every embedding build mode.
apply(from = rootProject.file("ime-cache-fix.gradle.kts"))
