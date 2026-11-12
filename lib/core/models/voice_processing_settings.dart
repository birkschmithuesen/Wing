import 'app_preferences.dart';
import 'profile_session_key.dart';

/// An authorized input choice carries only the settings its engine consumes.
sealed class VoiceInputSettings {
  const VoiceInputSettings();
}

final class LocalVoiceInputSettings extends VoiceInputSettings {
  const LocalVoiceInputSettings({required this.language});
  final String language;
}

final class HermesVoiceInputSettings extends VoiceInputSettings {
  const HermesVoiceInputSettings();
}

/// Local voice metadata never determines the remote profile's output settings.
sealed class VoiceOutputSettings {
  const VoiceOutputSettings();
}

final class LocalVoiceOutputSettings extends VoiceOutputSettings {
  const LocalVoiceOutputSettings({required this.voice, required this.rate});
  final String voice;
  final AppVoiceRate rate;
}

final class HermesVoiceOutputSettings extends VoiceOutputSettings {
  const HermesVoiceOutputSettings();
}

/// Immutable text/selection capture; Flutter editing controllers remain local.
final class VoiceDraft {
  const VoiceDraft({
    required this.text,
    required this.selectionStart,
    required this.selectionEnd,
  });
  final String text;
  final int selectionStart;
  final int selectionEnd;
}

/// Opaque reply identity cannot expose a mutable transcript record to a view.
final class VoiceReplyKey {
  const VoiceReplyKey(this.session, this._identity);
  final ProfileSessionKey session;
  final Object _identity;
  @override
  bool operator ==(Object other) =>
      other is VoiceReplyKey &&
      session == other.session &&
      _identity == other._identity;
  @override
  int get hashCode => Object.hash(session, _identity);
}

final class VoiceReply {
  const VoiceReply({required this.key, required this.text});
  final VoiceReplyKey key;
  final String text;
}

/// Fork (Wing Voice): local recognition through the on-phone VAD + Parakeet

/// route. Field-less: this library is domain-only; the round reads its

/// settings from VadInputRound.roundSettings.

final class VadVoiceInputSettings extends VoiceInputSettings {

  const VadVoiceInputSettings();

}
