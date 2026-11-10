import java.security.MessageDigest
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import java.util.zip.ZipOutputStream
import org.gradle.api.artifacts.transform.TransformAction
import org.gradle.api.artifacts.transform.TransformOutputs
import org.gradle.api.artifacts.transform.TransformParameters
import org.gradle.api.artifacts.transform.InputArtifact
import org.gradle.api.attributes.Attribute
import org.gradle.api.file.FileSystemLocation
import org.gradle.api.provider.Provider
import org.objectweb.asm.ClassReader
import org.objectweb.asm.ClassVisitor
import org.objectweb.asm.ClassWriter
import org.objectweb.asm.MethodVisitor
import org.objectweb.asm.Opcodes

// Flutter 3.47.9, engine 89c39edfdfae2949f6806e4a315c0c08522238b7.
// https://github.com/flutter/flutter/issues/191156
// The SDK distributes compiled embeddings, so changing its Java source alone
// would not change the APK. Patch the producer once, before tests and dexing.
/** Scope Flutter's deferred inset snapshot to the animation that captured it. */
abstract class FlutterImeCacheTransform : TransformAction<TransformParameters.None> {
    @get:InputArtifact
    abstract val inputArtifact: Provider<FileSystemLocation>

    override fun transform(outputs: TransformOutputs) {
        val input = inputArtifact.get().asFile
        // AGP exposes optional NO-SOURCE resource artifacts as absent paths.
        if (!input.exists()) return
        if (input.isDirectory) {
            outputs.dir(input)
            return
        }
        if (!input.name.startsWith("flutter_embedding_") || input.extension != "jar") {
            outputs.file(input)
            return
        }
        val owner = "io/flutter/plugin/editing/ImeSyncDeferringInsetsCallback"
        val callback = "$owner\$AnimationCallback"
        val entryName = "$callback.class"
        ZipFile(input).use { source ->
            val entry = requireNotNull(source.getEntry(entryName))
            val original = source.getInputStream(entry).use { it.readBytes() }
            val hash = MessageDigest.getInstance("SHA-256").digest(original)
                .joinToString("") { "%02x".format(it) }
            check(hash == "191118ac6b2ccd44520d6416cfa5ab85150681d0f4597613eb428cfc0e14a6c3") {
                "Flutter IME callback changed; review the animation-cache patch for this SDK."
            }
            val writer = ClassWriter(ClassWriter.COMPUTE_MAXS)
            ClassReader(original).accept(object : ClassVisitor(Opcodes.ASM9, writer) {
                override fun visitMethod(
                    access: Int, name: String, descriptor: String,
                    signature: String?, exceptions: Array<out String>?,
                ): MethodVisitor {
                    val next = super.visitMethod(access, name, descriptor, signature, exceptions)
                    if (name != "onPrepare" || descriptor != "(Landroid/view/WindowInsetsAnimation;)V") return next
                    return object : MethodVisitor(Opcodes.ASM9, next) {
                        override fun visitCode() {
                            super.visitCode()
                            // Java equivalent, before needsSave = true:
                            // lastWindowInsets = null;
                            // Android 17 may omit onApplyWindowInsets for an animation.
                            // onEnd must never reuse the previous animation's snapshot.
                            visitVarInsn(Opcodes.ALOAD, 0)
                            visitFieldInsn(Opcodes.GETFIELD, callback, "this\$0", "L$owner;")
                            visitInsn(Opcodes.ACONST_NULL)
                            visitMethodInsn(
                                Opcodes.INVOKESTATIC, owner, "access\$502",
                                "(L$owner;Landroid/view/WindowInsets;)Landroid/view/WindowInsets;",
                                false,
                            )
                            visitInsn(Opcodes.POP)
                        }
                    }
                }
            }, 0)
            val patched = writer.toByteArray()
            val destination = outputs.file(input.nameWithoutExtension + "-ime-cache.jar")
            ZipOutputStream(destination.outputStream()).use { output ->
                source.entries().asSequence().forEach { entry ->
                    output.putNextEntry(ZipEntry(entry.name).apply { time = 0 })
                    if (entry.name == entryName) output.write(patched)
                    else source.getInputStream(entry).use { it.copyTo(output) }
                    output.closeEntry()
                }
            }
        }
    }
}

val imeCacheFixed = Attribute.of("com.tarkilhk.wing.ime-cache-fixed", Boolean::class.javaObjectType)
dependencies {
    attributesSchema.attribute(imeCacheFixed)
    artifactTypes.maybeCreate("jar").attributes.attribute(imeCacheFixed, false)
    registerTransform(FlutterImeCacheTransform::class) {
        from.attribute(imeCacheFixed, false)
        to.attribute(imeCacheFixed, true)
    }
}
configurations.configureEach {
    if (name.endsWith("RuntimeClasspath") || name.endsWith("CompileClasspath")) {
        attributes.attribute(imeCacheFixed, true)
    }
}
