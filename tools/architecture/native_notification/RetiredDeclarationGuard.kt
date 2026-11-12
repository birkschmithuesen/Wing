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

private const val ID = "NATIVE_RETIRED_DECLARATION"
private data class Retirement(val owner: String, val member: String, val constructor: Boolean)
// Exact authored owners, in the corresponding canonical input files only.
private val retirements = listOf(
    Retirement("BackgroundMonitoringService", "summaryId", false),
    Retirement("NotificationHandleStore", "random", true),
)

@OptIn(org.jetbrains.kotlin.CoreEnvironmentDeprecation::class,
    org.jetbrains.kotlin.DeprecatedForRemovalCompilerApi::class, CompilerConfiguration.Internals::class,
    org.jetbrains.kotlin.compiler.plugin.ExperimentalCompilerApi::class)
fun main(args: Array<String>) {
    val disposable = Disposer.newDisposable()
    val status = try {
        require(args.size == retirements.size)
        val environment = KotlinCoreEnvironment.createForProduction(disposable,
            CompilerConfiguration().apply { extensionsStorage = CompilerPluginRegistrar.ExtensionStorage() },
            EnvironmentConfigFiles.JVM_CONFIG_FILES)
        // Validate the entire input before reporting findings: bad input always exits 2.
        val inputs = args.zip(retirements).map { (path, retirement) ->
            val source = File(path).readText()
            val file = KtPsiFactory(environment.project).createFile(File(path).name, source)
            require(PsiTreeUtil.findChildrenOfType(file, PsiErrorElement::class.java).isEmpty())
            require(file.packageFqName.asString() == "com.tarkilhk.wing")
            val owners = file.declarations.filterIsInstance<KtClass>().filter { it.name == retirement.owner }
            require(owners.size == 1)
            Triple(source, owners.single(), retirement)
        }
        var findings = 0
        for ((index, input) in inputs.withIndex()) {
            val (source, owner, retirement) = input
            val offsets = if (retirement.constructor) {
                // The retired injection option is a parameter, with or without val/var.
                owner.primaryConstructorParameters.filter { it.name == retirement.member }.map { it.textOffset }
            } else {
                // Only the service's own member/companion, never a local or nested class.
                val members = owner.declarations.filterIsInstance<KtProperty>() +
                    owner.companionObjects.flatMap { it.declarations.filterIsInstance<KtProperty>() }
                members.filter { it.name == retirement.member }.map { it.textOffset } +
                    owner.primaryConstructorParameters.filter {
                        it.hasValOrVar() && it.name == retirement.member
                    }.map { it.textOffset }
            }
            for (offset in offsets.sorted()) {
                val line = source.take(offset).count { it == '\n' } + 1
                println("${args[index]}:$line [$ID] Retire ${retirement.owner}.${retirement.member}; preserve current owned notification behavior.")
                findings++
            }
        }
        println("$ID: ${inputs.size} files, $findings violations")
        if (findings == 0) 0 else 1
    } catch (_: Exception) {
        System.err.println("[$ID] Invalid native declaration input; verify both canonical owners and Kotlin syntax.")
        2
    } finally { Disposer.dispose(disposable) }
    kotlin.system.exitProcess(status)
}
