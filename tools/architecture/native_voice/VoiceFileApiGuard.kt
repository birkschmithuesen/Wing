import java.io.File
import org.jetbrains.kotlin.cli.jvm.compiler.EnvironmentConfigFiles
import org.jetbrains.kotlin.cli.jvm.compiler.KotlinCoreEnvironment
import org.jetbrains.kotlin.config.CompilerConfiguration
import org.jetbrains.kotlin.cli.extensionsStorage
import org.jetbrains.kotlin.compiler.plugin.CompilerPluginRegistrar
import org.jetbrains.kotlin.com.intellij.openapi.util.Disposer
import org.jetbrains.kotlin.com.intellij.psi.PsiErrorElement
import org.jetbrains.kotlin.com.intellij.psi.util.PsiTreeUtil
import org.jetbrains.kotlin.psi.*

private const val ID = "NATIVE_VOICE_FILE_API_BOUNDARY"
private val wrappers = setOf("VoiceChannel", "VoiceCapture", "VoicePlayback")
private val fileApis = setOf("java.io.File", "java.io.FileInputStream", "java.io.FileOutputStream",
    "java.io.RandomAccessFile", "java.io.FileReader", "java.io.FileWriter", "java.nio.file.Files",
    "kotlin.io.readBytes", "kotlin.io.writeBytes")
private fun segments(node: KtExpression?): List<String>? = when (node) {
    is KtNameReferenceExpression -> listOf(node.getReferencedName())
    is KtDotQualifiedExpression -> segments(node.receiverExpression)?.let { left ->
        segments(node.selectorExpression)?.let { left + it } }
    is KtCallExpression -> segments(node.calleeExpression)
    else -> null
}
/** Parsed inputs live only for this invocation; no rule verdict is cached. */
data class VoiceParsedSource(val path: String, val source: String, val file: KtFile)

@OptIn(org.jetbrains.kotlin.CoreEnvironmentDeprecation::class,
    org.jetbrains.kotlin.DeprecatedForRemovalCompilerApi::class, CompilerConfiguration.Internals::class,
    org.jetbrains.kotlin.compiler.plugin.ExperimentalCompilerApi::class)
fun runVoiceParsedGuard(args: Array<String>, id: String, remedy: String,
    check: (List<VoiceParsedSource>) -> List<Pair<VoiceParsedSource, Int>>) {
    val disposable = Disposer.newDisposable()
    val status = try {
        require(args.isNotEmpty()) { "Provide Kotlin source paths" }
        val environment = KotlinCoreEnvironment.createForProduction(disposable,
            CompilerConfiguration().apply { extensionsStorage = CompilerPluginRegistrar.ExtensionStorage() },
            EnvironmentConfigFiles.JVM_CONFIG_FILES)
        val inputs = args.map { path ->
            val source = File(path).readText()
            val file = KtPsiFactory(environment.project).createFile(File(path).name, source)
            require(PsiTreeUtil.findChildrenOfType(file, PsiErrorElement::class.java).isEmpty()) { "Invalid Kotlin source: $path" }
            VoiceParsedSource(path, source, file)
        }
        val findings = check(inputs).distinct().sortedWith(compareBy({ it.first.path }, { it.second }))
        for ((input, offset) in findings) {
            val line = input.source.take(offset).count { it == '\n' } + 1
            println("${input.path}:$line [$id] $remedy")
        }
        println("$id: ${args.size} files, ${findings.size} violations")
        if (findings.isEmpty()) 0 else 1
    } catch (error: Exception) {
        System.err.println("[$id] Invalid input: ${error.message}")
        2
    } finally { Disposer.dispose(disposable) }
    kotlin.system.exitProcess(status)
}

fun main(args: Array<String>) = runVoiceParsedGuard(args, ID,
    "Keep native voice file APIs in VoiceFileWork; wrappers receive owned leases and bounded results.") { inputs ->
    inputs.flatMap { input ->
        val file = input.file
            val targets = file.declarations.filterIsInstance<KtClass>().any { it.name in wrappers }
            if (!targets) return@flatMap emptyList()
            val locations = mutableSetOf<Int>()
            for (directive in file.importDirectives) {
                val name = directive.importedFqName?.asString()
                if (name in fileApis || directive.isAllUnder && name in setOf("java.io", "java.nio.file", "kotlin.io")) locations += directive.textOffset
            }
            for (reference in PsiTreeUtil.findChildrenOfType(file, KtDotQualifiedExpression::class.java)) {
                if (PsiTreeUtil.getParentOfType(reference, KtImportDirective::class.java) != null) continue
                if (segments(reference)?.joinToString(".") in fileApis) locations += reference.textOffset
            }
            for (type in PsiTreeUtil.findChildrenOfType(file, KtUserType::class.java)) {
                fun typeName(node: KtUserType): String = node.qualifier?.let { typeName(it) + "." }.orEmpty() + node.referencedName
                if (typeName(type) in fileApis) locations += type.textOffset
            }
        locations.sorted().map { input to it }
    }
}
