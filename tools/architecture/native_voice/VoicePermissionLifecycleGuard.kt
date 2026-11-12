import org.jetbrains.kotlin.com.intellij.psi.util.PsiTreeUtil
import org.jetbrains.kotlin.psi.*

private const val PERMISSION_ID = "NATIVE_VOICE_PERMISSION_LIFECYCLE"
private const val OWNER_PACKAGE = "com.tarkilhk.wing"

private fun ownedReceiver(call: KtCallExpression, field: String): Boolean {
    val qualified = call.parent as? KtQualifiedExpression ?: return false
    if (qualified.selectorExpression !== call) return false
    val receiver = qualified.receiverExpression
    if (receiver is KtNameReferenceExpression) return receiver.getReferencedName() == field
    if (receiver is KtDotQualifiedExpression && receiver.receiverExpression is KtThisExpression) {
        return receiver.receiverExpression.text == "this" &&
            (receiver.selectorExpression as? KtNameReferenceExpression)?.getReferencedName() == field
    }
    return false
}
private fun calledName(call: KtCallExpression) =
    (call.calleeExpression as? KtNameReferenceExpression)?.getReferencedName()

object VoicePermissionLifecycleGuard {
@JvmStatic fun main(args: Array<String>) = runVoiceParsedGuard(args, PERMISSION_ID,
    "Pause only owned voice media; retire pending permission authority through onStop/leaveForeground.") { inputs ->
    val owners = inputs.flatMap { input ->
        if (input.file.packageFqName.asString() != OWNER_PACKAGE) emptyList()
        else input.file.declarations.filterIsInstance<KtClass>()
            .filter { it.name in setOf("MainActivity", "VoiceChannel") }.map { input to it }
    }
    fun owner(name: String): Pair<VoiceParsedSource, KtClass> {
        val matches = owners.filter { it.second.name == name }
        require(matches.size == 1) { "Expected one canonical $OWNER_PACKAGE.$name" }
        return matches.single()
    }
    val (activityInput, activity) = owner("MainActivity")
    val (voiceInput, voice) = owner("VoiceChannel")
    val findings = mutableListOf<Pair<VoiceParsedSource, Int>>()
    val canonicalTypes = setOf("VoiceChannel", "VoiceCapture", "VoicePlayback")
    for (input in listOf(activityInput, voiceInput)) {
        for (directive in input.file.importDirectives) {
            val imported = directive.importedFqName ?: continue
            val visible = directive.aliasName ?: imported.shortName().asString()
            require(visible !in canonicalTypes || imported.asString() == "$OWNER_PACKAGE.$visible") {
                "Unsupported import shadow of canonical voice type $visible"
            }
        }
        require(input.file.declarations.filterIsInstance<KtTypeAlias>().none { it.name in canonicalTypes }) {
            "Unsupported alias of canonical voice type"
        }
    }
    require(activity.declarations.filterIsInstance<KtClassOrObject>().none { it.name == "VoiceChannel" }) {
        "Unsupported nested VoiceChannel type"
    }
    require(voice.declarations.filterIsInstance<KtClassOrObject>().none { it.name in setOf("VoiceCapture", "VoicePlayback") }) {
        "Unsupported nested media owner type"
    }
    fun method(type: KtClass, name: String): KtNamedFunction? {
        val matches = type.declarations.filterIsInstance<KtNamedFunction>().filter { it.name == name }
        require(matches.size <= 1) { "Ambiguous $name" }
        return matches.singleOrNull()
    }
    fun body(function: KtNamedFunction): KtBlockExpression {
        require(function.valueParameters.isEmpty()) { "Unsupported lifecycle parameters" }
        return function.bodyExpression as? KtBlockExpression ?: error("Expected lifecycle block body")
    }
    fun rejectShadow(block: KtBlockExpression, fields: Set<String>) {
        require(PsiTreeUtil.findChildrenOfType(block, KtNamedDeclaration::class.java).none { it.name in fields }) {
            "Unsupported local shadow of canonical lifecycle field"
        }
        require(PsiTreeUtil.findChildrenOfType(block, KtClassOrObject::class.java).isEmpty()) {
            "Unsupported nested lifecycle receiver"
        }
    }
    val voiceField = activity.declarations.filterIsInstance<KtProperty>().singleOrNull { it.name == "voiceChannel" }
    require(voiceField?.typeReference?.text?.filterNot { it.isWhitespace() } == "VoiceChannel?") {
        "Expected canonical nullable VoiceChannel field"
    }
    for ((name, command) in listOf("onPause" to "pause", "onStop" to "leaveForeground")) {
        val function = method(activity, name)
        if (function == null) { findings += activityInput to activity.textOffset; continue }
        val block = body(function)
        rejectShadow(block, setOf("voiceChannel"))
        val directCalls = block.statements.mapNotNull { statement ->
            (statement as? KtQualifiedExpression)?.selectorExpression as? KtCallExpression
        }
        if (directCalls.count { ownedReceiver(it, "voiceChannel") && calledName(it) == command } != 1) {
            findings += activityInput to function.textOffset
        }
        if (name == "onPause") {
            for (call in PsiTreeUtil.findChildrenOfType(block, KtCallExpression::class.java)) {
                if (ownedReceiver(call, "voiceChannel") && calledName(call) == "leaveForeground") {
                    findings += activityInput to call.textOffset
                }
            }
        }
    }
    for (field in listOf("capture", "playback")) {
        val members = voice.declarations.filterIsInstance<KtProperty>().filter { it.name == field }
        require(members.size == 1) { "Expected owned media field $field" }
        val initializer = members.single().initializer as? KtCallExpression
        val expected = if (field == "capture") "VoiceCapture" else "VoicePlayback"
        require(initializer != null && calledName(initializer) == expected) {
            "Expected literal captured $expected constructor"
        }
    }
    val pause = method(voice, "pause")
    if (pause == null) findings += voiceInput to voice.textOffset
    else {
        val block = body(pause)
        rejectShadow(block, setOf("capture", "playback"))
        val calls = PsiTreeUtil.findChildrenOfType(block, KtCallExpression::class.java)
        fun media(call: KtCallExpression) =
            ownedReceiver(call, "capture") && calledName(call) == "pause" ||
            ownedReceiver(call, "playback") && calledName(call) == "stop"
        for (call in calls) if (!media(call)) findings += voiceInput to call.textOffset
        for ((field, command) in listOf("capture" to "pause", "playback" to "stop")) {
            if (calls.count { ownedReceiver(it, field) && calledName(it) == command } != 1) {
                findings += voiceInput to pause.textOffset
            }
        }
    }
    findings
}
}
