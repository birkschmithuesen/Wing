import org.jetbrains.kotlin.cli.jvm.compiler.EnvironmentConfigFiles
import org.jetbrains.kotlin.cli.jvm.compiler.KotlinCoreEnvironment
import org.jetbrains.kotlin.config.CompilerConfiguration
import org.jetbrains.kotlin.cli.extensionsStorage
import org.jetbrains.kotlin.compiler.plugin.CompilerPluginRegistrar
import org.jetbrains.kotlin.com.intellij.openapi.util.Disposer
import org.jetbrains.kotlin.com.intellij.psi.PsiErrorElement
import org.jetbrains.kotlin.com.intellij.psi.PsiElement
import org.jetbrains.kotlin.com.intellij.psi.util.PsiTreeUtil
import org.jetbrains.kotlin.psi.*

const val QA_ISOLATION_ID = "NATIVE_SHARE_QA_ISOLATION"
private const val QA_PACKAGE = "com.tarkilhk.wing.notificationqa"
private const val FIXTURE_PACKAGE = "com.tarkilhk.wing.shareqa.fixture"

/** Scoped syntax contract, complementary to compiled APK isolation checks. */
@OptIn(org.jetbrains.kotlin.CoreEnvironmentDeprecation::class,
    org.jetbrains.kotlin.DeprecatedForRemovalCompilerApi::class, CompilerConfiguration.Internals::class,
    org.jetbrains.kotlin.compiler.plugin.ExperimentalCompilerApi::class)
fun checkQaIsolation(native: String, gradle: String): Pair<List<Pair<Int, String>>, List<Pair<Int, String>>> {
    val disposable = Disposer.newDisposable()
    try {
        val environment = KotlinCoreEnvironment.createForProduction(disposable,
            CompilerConfiguration().apply { extensionsStorage = CompilerPluginRegistrar.ExtensionStorage() },
            EnvironmentConfigFiles.JVM_CONFIG_FILES)
        val factory = KtPsiFactory(environment.project)
        val activity = factory.createFile("MainActivity.kt", native)
        val build = factory.createFile("build.gradle.kts", gradle)
        for (file in listOf(activity, build)) {
            require(PsiTreeUtil.findChildrenOfType(file, PsiErrorElement::class.java).isEmpty()) {
                "Cannot parse QA isolation input"
            }
        }
        val main = activity.declarations.filterIsInstance<KtClass>().single { it.name == "MainActivity" }
        val nativeFindings = mutableListOf<Pair<Int, String>>()
        val buildFindings = mutableListOf<Pair<Int, String>>()
        fun fail(node: PsiElement, text: String, findings: MutableList<Pair<Int, String>>, reason: String) {
            findings += (text.take(node.textOffset).count { it == '\n' } + 1) to reason
        }
        fun literal(expression: KtExpression?): String? {
            val string = expression as? KtStringTemplateExpression ?: return null
            if (string.entries.any { it !is KtLiteralStringTemplateEntry && it !is KtEscapeStringTemplateEntry }) return null
            return string.entries.joinToString("") {
                if (it is KtEscapeStringTemplateEntry) it.unescapedValue else it.text
            }
        }
        // Structural expression keys: comments/spacing cannot manufacture a match.
        fun key(expression: KtExpression?): String = when (expression) {
            is KtParenthesizedExpression -> key(expression.expression)
            is KtNameReferenceExpression -> "name:${expression.getReferencedName()}"
            is KtStringTemplateExpression -> literal(expression)?.let { "string:$it" } ?: "unsupported"
            is KtConstantExpression -> "constant:${expression.text}"
            is KtUnaryExpression -> "unary:${expression.operationReference.text}(${key(expression.baseExpression)})"
            is KtBinaryExpression -> "binary:${expression.operationReference.text}(${key(expression.left)},${key(expression.right)})"
            is KtDotQualifiedExpression -> "dot(${key(expression.receiverExpression)},${key(expression.selectorExpression)})"
            is KtCallExpression -> "call(${key(expression.calleeExpression)};${expression.valueArguments.joinToString(",") { key(it.getArgumentExpression()) }})"
            else -> "unsupported"
        }
        fun conjuncts(expression: KtExpression?): Set<String> {
            val unwrapped = if (expression is KtParenthesizedExpression) expression.expression else expression
            return if (unwrapped is KtBinaryExpression && unwrapped.operationReference.text == "&&") {
                conjuncts(unwrapped.left) + conjuncts(unwrapped.right)
            } else setOf(key(unwrapped))
        }
        val requiredCondition = setOf(
            "dot(name:BuildConfig,name:DEBUG)",
            "dot(name:BuildConfig,name:NATIVE_SHARE_QA)",
            "binary:==(dot(name:BuildConfig,name:APPLICATION_ID),string:$QA_PACKAGE)")
        fun guarded(node: PsiElement): Boolean {
            var parent = node.parent
            while (parent != null && parent !== main) {
                if (parent is KtIfExpression && parent.then != null &&
                    PsiTreeUtil.isAncestor(parent.then!!, node, false) &&
                    conjuncts(parent.condition) == requiredCondition) return true
                parent = parent.parent
            }
            return false
        }
        for (reference in PsiTreeUtil.findChildrenOfType(main, KtNameReferenceExpression::class.java)) {
            if (reference.getReferencedName() != "setClassName") continue
            val call = reference.parent as? KtCallExpression
            val arguments = call?.valueArguments?.map { literal(it.getArgumentExpression()) }
            if (call == null || !guarded(call) || arguments != listOf(FIXTURE_PACKAGE, "$FIXTURE_PACKAGE.ControlledCameraActivity")) {
                fail(reference, native, nativeFindings,
                    "Route the fixed fixture component only inside the debug, native-QA and isolated-package branch")
            }
        }
        for (string in PsiTreeUtil.findChildrenOfType(activity, KtStringTemplateExpression::class.java)) {
            if (literal(string)?.startsWith(FIXTURE_PACKAGE) == true && !guarded(string)) {
                fail(string, native, nativeFindings, "Keep controlled fixture references inside the isolated QA branch")
            }
        }
        val statements = build.declarations.filterIsInstance<KtScript>().flatMap { it.blockExpression.statements }
        val properties = statements.filterIsInstance<KtProperty>()
        fun property(name: String, wanted: String) {
            val candidates = properties.filter { it.name == name }
            if (candidates.size != 1 || candidates.singleOrNull()?.isVar != false || key(candidates.singleOrNull()?.initializer) != wanted) {
                fail(candidates.firstOrNull() ?: build, gradle, buildFindings,
                    "Read $name only from its explicit Gradle true opt-in")
            }
        }
        for (name in listOf("nativeShareQa", "notificationQa")) {
            property(name, "binary:==(dot(dot(name:providers,call(name:gradleProperty;string:$name)),name:orNull),string:true)")
        }
        val topChecks = PsiTreeUtil.findChildrenOfType(build, KtCallExpression::class.java).filter {
            (it.calleeExpression as? KtNameReferenceExpression)?.getReferencedName() == "check" &&
                it.parent is KtScriptInitializer
        }
        if (topChecks.none { key(it.valueArguments.firstOrNull()?.getArgumentExpression()) ==
                "binary:||(unary:!(name:nativeShareQa),name:notificationQa)" }) {
            fail(build, gradle, buildFindings, "Require nativeShareQa to imply notificationQa before configuring Android")
        }
        // Script declarations live in the script block, not KtFile.declarations.
        fun enclosingCalls(node: PsiElement): List<String> {
            val names = mutableListOf<String>()
            var parent = node.parent
            while (parent != null) {
                if (parent is KtCallExpression) {
                    (parent.calleeExpression as? KtNameReferenceExpression)?.getReferencedName()?.let { names += it }
                }
                parent = parent.parent
            }
            return names
        }
        for (reference in PsiTreeUtil.findChildrenOfType(build, KtNameReferenceExpression::class.java)) {
            if (reference.getReferencedName() != "buildConfigField") continue
            val call = reference.parent as? KtCallExpression
            if (call == null || literal(call.valueArguments.getOrNull(1)?.getArgumentExpression()) == null) {
                fail(reference, gradle, buildFindings, "Keep BuildConfig declarations direct with literal field names for isolation checks")
            }
        }
        val fieldCalls = PsiTreeUtil.findChildrenOfType(build, KtCallExpression::class.java).filter {
            (it.calleeExpression as? KtNameReferenceExpression)?.getReferencedName() == "buildConfigField" &&
                literal(it.valueArguments.getOrNull(1)?.getArgumentExpression()) == "NATIVE_SHARE_QA"
        }
        var defaults = 0
        var debug = 0
        for (call in fieldCalls) {
            val arguments = call.valueArguments.map { key(it.getArgumentExpression()) }
            val owners = enclosingCalls(call)
            if (owners == listOf("defaultConfig", "android") &&
                arguments == listOf("string:boolean", "string:NATIVE_SHARE_QA", "string:false")) defaults++
            else if (owners == listOf("debug", "buildTypes", "android") &&
                arguments == listOf("string:boolean", "string:NATIVE_SHARE_QA", "dot(name:nativeShareQa,call(name:toString;))")) debug++
            else fail(call, gradle, buildFindings, "Default NATIVE_SHARE_QA to false; override only in debug with nativeShareQa")
        }
        if (defaults != 1 || debug != 1) {
            fail(build, gradle, buildFindings, "Declare one false QA default and one explicit debug opt-in")
        }
        val suffixes = PsiTreeUtil.findChildrenOfType(build, KtBinaryExpression::class.java).filter {
            it.operationReference.text == "=" && key(it.left) == "name:applicationIdSuffix" &&
                enclosingCalls(it) == listOf("debug", "buildTypes", "android")
        }
        val suffix = suffixes.singleOrNull()?.right as? KtIfExpression
        if (suffix == null || key(suffix.condition) != "name:notificationQa" ||
            literal(suffix.then) != ".notificationqa" || literal(suffix.`else`) != ".dev") {
            fail(suffixes.firstOrNull() ?: build, gradle, buildFindings, "Keep opted-in debug QA in its isolated application ID")
        }
        return nativeFindings.distinct().sortedBy { it.first } to buildFindings.distinct().sortedBy { it.first }
    } finally { Disposer.dispose(disposable) }
}
