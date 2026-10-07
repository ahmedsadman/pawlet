import '../auth/attestation_service.dart';
import 'llm_mode.dart';
import 'prompt_bundle.dart';

/// Foreground upkeep for whichever remote path this install uses. The UI
/// isolate runs it at launch, on resume and when connectivity returns. Never
/// throws.
///
/// Also the one place the UI picks up an attestation rejection: the service
/// writes it to prefs from inside a processing pass, and moving the mode
/// there would rebuild AppServices under the running pass.
Future<void> refreshLlmNetworkState({
  required LlmMode mode,
  required AttestationService? attestation,
  required PromptBundleStore promptBundles,
  required void Function() syncIneligible,
}) async {
  switch (mode) {
    case LlmMode.proxy:
      await attestation?.warmUp();
      syncIneligible();
    case LlmMode.byok:
      await promptBundles.refresh();
    case LlmMode.none:
      // Nothing leaves the phone in this mode, not even a bundle fetch.
      break;
  }
}
