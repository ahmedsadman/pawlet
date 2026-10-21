import '../auth/attestation_service.dart';
import 'llm_mode.dart';
import 'prompt_bundle.dart';

/// Foreground upkeep for whichever remote path this install uses. The UI
/// isolate runs it at launch, on resume and when connectivity returns. Never
/// throws.
///
/// Also the one place the UI picks up an attestation rejection, which the
/// service writes to prefs from inside a processing pass. Moving the mode
/// rebuilds AppServices, so the caller's [syncIneligible] must skip the sync
/// while a pass is running; the next launch, resume or reconnect picks it up.
Future<void> refreshLlmNetworkState({
  required LlmMode mode,
  required AttestationService? attestation,
  required PromptBundleStore promptBundles,
  required Future<void> Function() syncIneligible,
}) async {
  switch (mode) {
    // Opted out keeps the proxy session: attestation still carries the
    // model-stats upload, and a rejection must still reach the UI.
    case LlmMode.proxy:
    case LlmMode.optedOut:
      await attestation?.warmUp();
      await syncIneligible();
    case LlmMode.byok:
      await promptBundles.refresh();
    case LlmMode.none:
      // No LLM and no proxy session, so there is nothing to keep warm and no
      // bundle to fetch.
      break;
  }
}
