# LLM modes

How the app reaches a large language model to improve classification accuracy — or does not reach one at all — is decided by a **mode** resolved at runtime from four inputs. Three modes exist, each giving the user a different privacy/accuracy trade-off. The resolution function is pure (same inputs always produce the same answer), so every isolate lands on the same mode.

## The three modes

Defined in `lib/services/llm/llm_mode.dart` and resolved by `resolveLlmMode()`:

- **`proxy`** — Play install talking to Pawlet's own server, which holds the OpenRouter key. The message text leaves the phone but the user never manages a key.
- **`byok`** (bring your own key) — Calls OpenRouter directly with a key the user entered in Settings. Non-Play installs, and Play installs that failed attestation, land here when a key is saved.
- **`none`** — No LLM at all. The on-device model is the only classifier, and your messages never leave your phone.

The four inputs:

1. **`fromPlay`** — Whether the Play Store installed this app. Read from the platform over a channel served by `MainActivity` (`lib/services/install_source.dart`), compared against the known Play package name.
2. **`apiBaseConfigured`** — Whether the build points at Pawlet's server via the `PAWLET_API_BASE` environment variable. No current build sets this.
3. **`hasKey`** — Whether an OpenRouter key is stored in the keystore.
4. **`attestationIneligible`** — Whether Pawlet's server has rejected this device's Play Integrity verdict (rooted device, custom ROM, or absent Play Services). Nothing writes this flag yet; the writer arrives with the attestation stage.

Resolution logic: if all of `fromPlay`, `apiBaseConfigured`, and not `attestationIneligible` hold, the mode is `proxy`. Otherwise, `byok` if a key exists, else `none`.

**Current reachability:** The `proxy` mode is defined but never reached. No build sets `PAWLET_API_BASE`, so every install today resolves to either `byok` or `none`. The code and the UI exist so the mode is ready when the server stage lands; a reader finding what looks like dead `proxy` paths should know they are deliberately staged.

## Install source is a UI affordance, not a security boundary

The install source decides whether Settings offers the bring-your-own-key input. A Play install that can reach the proxy has an LLM already, so offering a personal key would buy nothing — the section is hidden. A sideload install, or a Play install that failed attestation, has no other way to reach an LLM, so the section is shown.

This decision is **never a trust boundary**. Pawlet's server demands a Play Integrity verdict regardless of what the client claims `fromPlay` to be, so a sideload install lying about its source gains nothing. The UI check merely avoids showing a useless input.

## Why the install source is cached

Background isolates (WorkManager, SMS receiver) have no `MainActivity`, so the platform channel that reads the installer package is unreachable there. They would always resolve `fromPlay` as false and land on a different mode from the UI isolate, which would break classification. The UI isolate queries the platform once at launch and caches the answer in SharedPreferences (`installed_from_play`), which background isolates then read. All isolates see the same value, so all resolve the same mode.

The flag is also the reason the mode function is pure rather than reading the channel itself: purity means it can be tested, and background isolates can safely call it.

## Settings UI per mode

The Privacy section in Settings shows different controls depending on the mode:

- **`proxy`:** No bring-your-own-key section. A short privacy paragraph explains the LLM runs server-side on Pawlet's infrastructure.
- **`byok`:** The bring-your-own-key section is shown (`lib/ui/settings/byok_section.dart`). The user enters a key, which is validated before storage. The privacy paragraph notes the on-device model handles most messages, with the LLM used only for tricky ones.
- **`none`:** The bring-your-own-key section is shown, identical to `byok`. The privacy paragraph states **your messages never leave your phone** (narrow claim, accurate — currency exchange rates are still fetched over the network).

When `attestationIneligible` is true and the mode is `byok` or `none`, an additional warning paragraph appears in peach, explaining that this device did not pass Google's integrity check and a personal key is the only way to restore LLM parsing.

The section's visibility is controlled by `LlmMode.showsByokSection`, which returns false only for `proxy`.

## Key validation before storage

When the user enters a key and presses Save, the key is validated against OpenRouter's key-metadata endpoint (`lib/services/llm/key_validator.dart`) before being written to the keystore. The check hits `https://openrouter.ai/api/v1/key` with the key in an `Authorization` header, timing out after 15 seconds.

Three outcomes:

- **`valid`** — HTTP 200. The key is stored.
- **`invalid`** — HTTP 401 or 403. The user sees "Invalid key".
- **`unreachable`** — Timeout, network error, or any other failure (including rate limits and server errors). The user sees "Couldn't reach OpenRouter".

The split between `invalid` and `unreachable` is deliberate. A bad connection should never be reported as a bad key, because the user would then think the key itself is wrong and waste time regenerating it. An `unreachable` result invites a retry; an `invalid` result says the key is the problem.

The validation uses the metadata endpoint rather than a chat completion because it is faster and costs nothing — the user is watching a spinner.

## No key ships in the binary

The app previously included an OpenRouter API key compiled into the build. That key is gone. Every LLM call now either goes through the proxy (not yet reachable) or uses a key the user entered.

## What happens with no LLM

When the mode is `none`, the on-device model runs ungated: its two confidence thresholds are skipped, so any prediction it produces is accepted. The structural checks survive — a missing amount span, an unparseable number, or a foreign currency with no conversion path still means no record, because those are facts about the message rather than confidence judgements. A `null` label still means ignore.

If the ungated gate still rejects the message (structural failure), the row is marked `failure` with the new `FailureReason.localOnly`, shown in Messages as "On-device parsing failed". This is a terminal state but recoverable: the Messages page already offers Retry on every failure row, so saving a key later and retrying will re-run the message through the now-gated pipeline and defer it to the LLM.

The `needs_llm` flag is never set when no LLM exists, because it is permanent (never cleared) and its two readers would otherwise strand the row. A row that already carries the flag from an earlier state (e.g. the user removed their key) is re-run through the ungated gate rather than skipped.

Layer 3 is skipped entirely with no LLM — no provider is constructed, no HTTP client, no network call is reachable.
