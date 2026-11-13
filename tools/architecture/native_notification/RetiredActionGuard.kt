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

private const val ID = "NATIVE_NOTIFICATION_RETIRED_ACTION"
private fun unwrap(value: KtExpression?): KtExpression? =
    if (value is KtParenthesizedExpression) unwrap(value.expression) else value
private fun literal(value: KtExpression?): String? {
    val string = unwrap(value) as? KtStringTemplateExpression ?: return null
    if (string.entries.any { it !is KtLiteralStringTemplateEntry && it !is KtEscapeStringTemplateEntry }) return null
    return string.entries.joinToString("") {
        if (it is KtEscapeStringTemplateEntry) it.unescapedValue else it.text
    }
}
private fun method(value: KtExpression?, receiver: String): Boolean {
    val access = unwrap(value) as? KtDotQualifiedExpression ?: return false
    return (unwrap(access.receiverExpression) as? KtNameReferenceExpression)?.getReferencedName() == receiver &&
        (access.selectorExpression as? KtNameReferenceExpression)?.getReferencedName() == "method"
}

@OptIn(org.jetbrains.kotlin.CoreEnvironmentDeprecation::class,
    org.jetbrains.kotlin.DeprecatedForRemovalCompilerApi::class, CompilerConfiguration.Internals::class,
    org.jetbrains.kotlin.compiler.plugin.ExperimentalCompilerApi::class)
fun main(args: Array<String>) {
    val disposable = Disposer.newDisposable()
    val status = try {
        require(args.size == 1)
        val environment = KotlinCoreEnvironment.createForProduction(disposable,
            CompilerConfiguration().apply { extensionsStorage = CompilerPluginRegistrar.ExtensionStorage() },
            EnvironmentConfigFiles.JVM_CONFIG_FILES)
        val path = args.single()
        val source = File(path).readText()
        val file = KtPsiFactory(environment.project).createFile(File(path).name, source)
        require(PsiTreeUtil.findChildrenOfType(file, PsiErrorElement::class.java).isEmpty())
        require(file.packageFqName.asString() == "com.tarkilhk.wing")
        val owners = file.declarations.filterIsInstance<KtObjectDeclaration>().filter { it.name == "ChatNotifications" }
        require(owners.size == 1)
        val locations = mutableSetOf<Int>()
        for (call in PsiTreeUtil.findChildrenOfType(owners.single(), KtCallExpression::class.java)) {
            if ((call.calleeExpression as? KtNameReferenceExpression)?.getReferencedName() != "setMethodCallHandler") continue
            // The retained handler binds MethodCall as its first lambda parameter.
            // Do not infer unsupported aliases/computed/delegated dispatch.
            val lambda = call.lambdaArguments.singleOrNull()?.getLambdaExpression() ?: continue
            val parameters = lambda.valueParameters
            if (parameters.isEmpty()) continue // null/removal and unrelated registrations
            val receiver = parameters.first().name ?: throw IllegalArgumentException()
            for (branch in PsiTreeUtil.findChildrenOfType(lambda, KtWhenExpression::class.java)) {
                if (!method(branch.subjectExpression, receiver)) continue
                for (entry in branch.entries) {
                    for (condition in entry.conditions.filterIsInstance<KtWhenConditionWithExpression>()) {
                        if (literal(condition.expression) == "cancelAll") locations += condition.textOffset
                    }
                }
            }
            for (test in PsiTreeUtil.findChildrenOfType(lambda, KtBinaryExpression::class.java)) {
                if (test.operationReference.text != "==") continue
                if (method(test.left, receiver) && literal(test.right) == "cancelAll" ||
                    method(test.right, receiver) && literal(test.left) == "cancelAll") locations += test.textOffset
            }
        }
        for (offset in locations.sorted()) {
            val line = source.take(offset).count { it == '\n' } + 1
            println("$path:$line [$ID] Retire cancelAll notification dispatch; preserve captured per-ID cancellation.")
        }
        println("$ID: 1 file, ${locations.size} violations")
        if (locations.isEmpty()) 0 else 1
    } catch (_: Exception) {
        System.err.println("[$ID] Invalid native action input; inspect source syntax and canonical notification owner.")
        2
    } finally { Disposer.dispose(disposable) }
    kotlin.system.exitProcess(status)
}
