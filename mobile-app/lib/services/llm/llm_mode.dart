/// How this install reaches an LLM, if at all.
enum LlmMode {
  /// Play install talking to Pawlet's server, which holds the OpenRouter key.
  proxy,

  /// Non-Play install calling OpenRouter directly with the user's own key.
  byok,

  /// No LLM at all. The on-device model is the only classifier and no message
  /// ever leaves the phone.
  none;

  /// Whether Settings offers the bring-your-own-key input. A proxy install
  /// already has an LLM, so a personal key would buy nothing.
  bool get showsByokSection => this != LlmMode.proxy;
}

/// Resolves the mode from the four things that decide it. Pure, so every
/// isolate that feeds it the same inputs lands on the same answer.
///
/// [attestationIneligible] is set once Pawlet's server rejects this install's
/// Play Integrity verdict — a rooted device, a custom ROM, or absent Play
/// Services. Such an install came from Play but can never use the proxy, so it
/// is given the same choices a sideload install has rather than being left
/// receiving permanent 403s with the key input hidden.
LlmMode resolveLlmMode({
  required bool fromPlay,
  required bool apiBaseConfigured,
  required bool hasKey,
  required bool attestationIneligible,
}) {
  if (fromPlay && apiBaseConfigured && !attestationIneligible) {
    return LlmMode.proxy;
  }
  return hasKey ? LlmMode.byok : LlmMode.none;
}
