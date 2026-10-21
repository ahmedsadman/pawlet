/// How this install reaches an LLM, if at all.
enum LlmMode {
  /// Play install talking to Pawlet's server, which holds the OpenRouter key.
  proxy,

  /// Play install that could use the proxy but whose user turned the LLM off.
  /// No message goes to any LLM, yet the proxy session stays: it still
  /// attests and sends the on-device model's counts, exactly as in [proxy].
  optedOut,

  /// Non-Play install calling OpenRouter directly with the user's own key.
  byok,

  /// No LLM at all. The on-device model is the only classifier and no message
  /// ever leaves the phone.
  none;

  /// Whether this install holds a proxy session (attestation and model-stats
  /// upload), whether or not the LLM behind it is on.
  bool get usesProxySession =>
      this == LlmMode.proxy || this == LlmMode.optedOut;

  /// Whether Settings offers the bring-your-own-key input. A proxy-eligible
  /// install already has an LLM a switch away, so a personal key would buy
  /// nothing.
  bool get showsByokSection => !usesProxySession;

  /// The LLM group this install reports with its heartbeat.
  String get heartbeatGroup => switch (this) {
    LlmMode.proxy => 'on',
    LlmMode.optedOut => 'off',
    LlmMode.byok => 'byok',
    LlmMode.none => 'none',
  };
}

/// Resolves the mode from the five things that decide it. Pure, so every
/// isolate that feeds it the same inputs lands on the same answer.
///
/// [attestationIneligible] is set once Pawlet's server rejects this install's
/// Play Integrity verdict — a rooted device, a custom ROM, or absent Play
/// Services. Such an install came from Play but can never use the proxy, so it
/// is given the same choices a sideload install has rather than being left
/// receiving permanent 403s with the key input hidden.
///
/// [llmEnabled] is the user's LLM switch. It only splits a proxy-eligible
/// install between [LlmMode.proxy] and [LlmMode.optedOut]; elsewhere the key
/// alone decides.
LlmMode resolveLlmMode({
  required bool fromPlay,
  required bool proxyConfigured,
  required bool hasKey,
  required bool attestationIneligible,
  required bool llmEnabled,
}) {
  if (fromPlay && proxyConfigured && !attestationIneligible) {
    return llmEnabled ? LlmMode.proxy : LlmMode.optedOut;
  }
  return hasKey ? LlmMode.byok : LlmMode.none;
}
