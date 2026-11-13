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

private const val ID = "NATIVE_SHARE_PROVIDER_BOUNDARY"
private const val QUEUE_ID = "NATIVE_SHARE_BOUNDED_QUEUE"

/** Scoped PSI contract: MainActivity's provider entry point can only be called
 * inside the declared BoundedProviderWork work lambda. Runtime deadlines and
 * safe closure/publication are behavioral properties, not claims of this rule. */
@OptIn(org.jetbrains.kotlin.CoreEnvironmentDeprecation::class,
    org.jetbrains.kotlin.DeprecatedForRemovalCompilerApi::class, CompilerConfiguration.Internals::class,
    org.jetbrains.kotlin.compiler.plugin.ExperimentalCompilerApi::class)
fun checkProviderBoundary(text: String): List<Pair<Int, String>> {
    val disposable = Disposer.newDisposable()
    try {
        val environment = KotlinCoreEnvironment.createForProduction(
            disposable, CompilerConfiguration().apply {
                extensionsStorage = CompilerPluginRegistrar.ExtensionStorage()
            }, EnvironmentConfigFiles.JVM_CONFIG_FILES)
        val file = KtPsiFactory(environment.project).createFile("MainActivity.kt", text)
        require(PsiTreeUtil.findChildrenOfType(file, PsiErrorElement::class.java).isEmpty()) {
            "Cannot parse native source"
        }
        val main = file.declarations.filterIsInstance<KtClass>().single { it.name == "MainActivity" }
        val functions = PsiTreeUtil.findChildrenOfType(main, KtNamedFunction::class.java)
        val copy = functions.single { it.name == "copySharedUri" }
        val findings = mutableListOf<Pair<Int, String>>()
        fun fail(node: org.jetbrains.kotlin.com.intellij.psi.PsiElement, reason: String) {
            findings += (text.take(node.textOffset).count { it == '\n' } + 1) to reason
        }
        if (copy.valueParameters.none { it.typeReference?.text == "BoundedProviderWork.Lease" }) {
            fail(copy, "Provider copy must receive its bounded attempt lease")
        }
        val owners = PsiTreeUtil.findChildrenOfType(main, KtProperty::class.java)
            .filter { it.name == "providerWork" }
        if (owners.size != 1 || (owners.single().initializer as? KtCallExpression)
                ?.calleeExpression?.text != "BoundedProviderWork") {
            fail(main, "Declare exactly one bounded provider owner")
        }
        for (reference in PsiTreeUtil.findChildrenOfType(main, KtNameReferenceExpression::class.java)) {
            if (reference.getReferencedName() in setOf("contentResolver", "getContentResolver")) {
                if (!PsiTreeUtil.isAncestor(copy, reference, false)) {
                    fail(reference, "Acquire/use the resolver only within the provider copy boundary")
                }
            }
            if (reference.getReferencedName() == "copySharedUri") {
                val call = reference.parent as? KtCallExpression
                var inside = false
                var parent = reference.parent
                while (parent != null && parent !== main) {
                    if (parent is KtLambdaExpression) {
                        val argument = parent.parent as? KtValueArgument
                        val submit = argument?.parent?.parent as? KtCallExpression
                        val qualified = submit?.parent as? KtDotQualifiedExpression
                        if (argument?.getArgumentName()?.asName?.asString() == "work" &&
                            submit?.calleeExpression?.text == "submit" &&
                            qualified?.receiverExpression?.text == "providerWork") inside = true
                    }
                    parent = parent.parent
                }
                if (call == null || !inside) fail(reference, "Invoke provider copy only in providerWork.submit(work = { ... })")
            }
        }
        return findings.distinct().sortedBy { it.first }
    } finally { Disposer.dispose(disposable) }
}

@OptIn(org.jetbrains.kotlin.CoreEnvironmentDeprecation::class,
    org.jetbrains.kotlin.DeprecatedForRemovalCompilerApi::class, CompilerConfiguration.Internals::class,
    org.jetbrains.kotlin.compiler.plugin.ExperimentalCompilerApi::class)
fun checkBoundedQueues(text: String): List<Pair<Int, String>> {
    val disposable = Disposer.newDisposable()
    try {
        val environment = KotlinCoreEnvironment.createForProduction(disposable,
            CompilerConfiguration().apply { extensionsStorage = CompilerPluginRegistrar.ExtensionStorage() },
            EnvironmentConfigFiles.JVM_CONFIG_FILES)
        val file = KtPsiFactory(environment.project).createFile("QueueOwner.kt", text)
        require(PsiTreeUtil.findChildrenOfType(file, PsiErrorElement::class.java).isEmpty()) { "Cannot parse queue owner" }
        val calls = PsiTreeUtil.findChildrenOfType(file, KtCallExpression::class.java)
        val findings = mutableListOf<Pair<Int, String>>()
        fun fail(call: org.jetbrains.kotlin.com.intellij.psi.PsiElement) {
            findings += (text.take(call.textOffset).count { it == '\n' } + 1) to
                "Use explicit bounded workers/ArrayBlockingQueue and settle rejected work"
        }
        fun integer(expression: KtExpression?) = expression?.text?.replace("_", "")?.toIntOrNull()
        val aliases = file.importDirectives.filter {
            it.importedFqName?.asString() == "java.util.concurrent.Executors"
        }.map { it.aliasName ?: "Executors" }.toSet() + "Executors"
        for (property in PsiTreeUtil.findChildrenOfType(file, KtProperty::class.java)) {
            if (property.name == "intakeExecutor" &&
                PsiTreeUtil.getParentOfType(property, KtClass::class.java)?.name == "MainActivity" &&
                (property.initializer as? KtCallExpression)?.calleeExpression?.text != "BoundedIntakeQueue") fail(property)
        }
        val importedFactories = file.importDirectives.filter {
            it.importedFqName?.asString()?.startsWith("java.util.concurrent.Executors.") == true
        }.map { it.aliasName ?: it.importedFqName!!.shortName().asString() }.toSet()
        val queueNames = file.importDirectives.filter {
            it.importedFqName?.asString() == "java.util.concurrent.ArrayBlockingQueue"
        }.map { it.aliasName ?: "ArrayBlockingQueue" }.toSet() + "ArrayBlockingQueue"
        val poolNames = file.importDirectives.filter {
            it.importedFqName?.asString() == "java.util.concurrent.ThreadPoolExecutor"
        }.map { it.aliasName ?: "ThreadPoolExecutor" }.toSet() + "ThreadPoolExecutor"
        val unsafeHandlers = setOf("CallerRunsPolicy", "DiscardPolicy", "DiscardOldestPolicy")
        val importedHandlers = file.importDirectives.filter {
            it.importedFqName?.asString() in unsafeHandlers.map { name ->
                "java.util.concurrent.ThreadPoolExecutor.$name"
            }
        }.map { it.aliasName ?: it.importedFqName!!.shortName().asString() }.toSet()
        fun unsafeHandler(call: KtCallExpression): Boolean {
            val name = call.calleeExpression?.text
            val qualified = (call.parent as? KtDotQualifiedExpression)
                ?.takeIf { it.selectorExpression === call }
            return if (qualified == null) name in importedHandlers
            else name in unsafeHandlers &&
                (qualified.receiverExpression.text in poolNames ||
                    qualified.receiverExpression.text == "java.util.concurrent.ThreadPoolExecutor")
        }
        for (call in calls) {
            val name = call.calleeExpression?.text
            val receiver = (call.parent as? KtDotQualifiedExpression)?.receiverExpression?.text
            if (name in setOf("newSingleThreadExecutor", "newFixedThreadPool", "newCachedThreadPool", "newWorkStealingPool") &&
                (receiver in aliases || receiver == "java.util.concurrent.Executors")) fail(call)
            if (name in importedFactories) fail(call)
            if (name !in poolNames) continue
            val args = call.valueArguments.map { it.getArgumentExpression() }
            val minimum = integer(args.getOrNull(0))
            val maximum = integer(args.getOrNull(1))
            val queue = args.getOrNull(4) as? KtCallExpression
            // The sixth Java argument may be a RejectedExecutionHandler, not
            // just a ThreadFactory. Seven-argument rejection alone misses it.
            val sixth = args.getOrNull(5)
            val unsafeSixth = sixth != null &&
                (listOfNotNull(sixth as? KtCallExpression) +
                    PsiTreeUtil.findChildrenOfType(sixth, KtCallExpression::class.java))
                    .any(::unsafeHandler)
            val capacity = queue?.valueArguments?.singleOrNull()?.getArgumentExpression()
            var bound = integer(capacity)
            if (bound == null && capacity is KtNameReferenceExpression) {
                val helper = PsiTreeUtil.getParentOfType(call, KtNamedFunction::class.java)
                val parameterIndex = helper?.valueParameters?.indexOfFirst { it.name == capacity.getReferencedName() } ?: -1
                if (helper != null && parameterIndex >= 0 && helper.hasModifier(org.jetbrains.kotlin.lexer.KtTokens.PRIVATE_KEYWORD)) {
                    val default = integer(helper.valueParameters[parameterIndex].defaultValue)
                    val actualBounds = calls.filter { it.calleeExpression?.text == helper.name }.map {
                        val named = it.valueArguments.firstOrNull { argument ->
                            argument.getArgumentName()?.asName?.asString() == capacity.getReferencedName()
                        }
                        val argument = named ?: it.valueArguments.getOrNull(parameterIndex)
                        if (argument == null) default else integer(argument.getArgumentExpression())
                    }
                    if (default in 1..32 && actualBounds.isNotEmpty() && actualBounds.all { it in 1..32 }) {
                        bound = actualBounds.filterNotNull().maxOrNull()
                    }
                }
            }
            if (minimum !in 1..2 || maximum !in 1..2 || maximum!! < minimum!! ||
                queue?.calleeExpression?.text !in queueNames || bound !in 1..32 ||
                args.size > 6 || unsafeSixth) fail(call)
        }
        return findings.distinct().sortedBy { it.first }
    } finally { Disposer.dispose(disposable) }
}

fun main(arguments: Array<String>) {
    try {
        val rule = arguments.firstOrNull()?.takeIf { it.startsWith("--rule=") }?.substringAfter('=') ?: "all"
        require(rule in setOf("all", "provider-boundary", "bounded-queues", "qa-isolation")) { "Unknown rule" }
        val paths = if (arguments.firstOrNull()?.startsWith("--rule=") == true) arguments.drop(1) else arguments.toList()
        require(paths.isNotEmpty()) { "Expected native source paths" }
        var violations = 0
        if (rule == "all" || rule == "qa-isolation") {
            require(paths.last().endsWith(".gradle.kts")) { "Expected Gradle QA configuration" }
            val (native, gradle) = checkQaIsolation(File(paths.first()).readText(), File(paths.last()).readText())
            for ((path, findings) in listOf(paths.first() to native, paths.last() to gradle)) {
                findings.forEach { (line, reason) -> println("$path:$line [$QA_ISOLATION_ID] $reason") }
                violations += findings.size
            }
        }
        for ((index, path) in paths.withIndex()) {
            if (path.endsWith(".gradle.kts") || rule == "qa-isolation") continue
            val file = File(path)
            val text = file.readText()
            if (index == 0 && rule != "bounded-queues") {
                val findings = checkProviderBoundary(text)
                findings.forEach { (line, reason) -> println("${file.path}:$line [$ID] $reason") }
                violations += findings.size
            }
            val queues = if (rule == "provider-boundary") emptyList() else checkBoundedQueues(text)
            queues.forEach { (line, reason) -> println("${file.path}:$line [$QUEUE_ID] $reason") }
            violations += queues.size
        }
        if (violations > 0) kotlin.system.exitProcess(1)
    } catch (error: Exception) {
        val errorId = if (arguments.firstOrNull() == "--rule=qa-isolation") QA_ISOLATION_ID else ID
        System.err.println("$errorId: input error: ${error.message}")
        kotlin.system.exitProcess(2)
    }
}
