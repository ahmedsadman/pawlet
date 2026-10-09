// Package metrics keeps daily aggregate counters in memory and flushes them
// to a Sink on an interval, so the request path never waits on the database.
package metrics

// Metric names. They are persisted in counters_daily and read by the admin
// dashboard, so renaming one splits its history.
const (
	ClassifyOutcome = "classify_outcome"
	SessionOutcome  = "session_outcome"
	ClassifyLatency = "classify_latency_ms"
	Model           = "model"
	Category        = "category"
)

// Outcome keys for classify_outcome and session_outcome.
const (
	OK                = "ok"
	Unauthorized      = "unauthorized"
	Banned            = "banned"
	BadRequest        = "bad_request"
	Internal          = "internal"
	RateLimitedDaily  = "rate_limited_daily"
	RateLimitedBurst  = "rate_limited_burst"
	Capacity          = "capacity"
	Upstream429       = "upstream_429"
	UpstreamRetryable = "upstream_retryable"
	UpstreamRejected  = "upstream_rejected"
	// ClientCancelled counts calls where the request context was cancelled
	// (client disconnect or server shutdown) before the upstream call finished.
	ClientCancelled = "client_cancelled"

	ChallengeInvalid     = "challenge_invalid"
	ChallengeRateLimited = "challenge_rate_limited"
	AttestUnavailable    = "attest_unavailable"

	// One key per attest verification error.
	PackageMismatch     = "package_mismatch"
	RequestHashMismatch = "request_hash_mismatch"
	StaleToken          = "stale_token"
	AppNotRecognized    = "app_not_recognized"
	CertMismatch        = "cert_mismatch"
	DeviceIntegrity     = "device_integrity"
	// AttestFailed is a verification error with no dedicated key. Verify
	// returns none today; it exists so a new error is counted, not dropped.
	AttestFailed = "attest_failed"
)

// Keys for the model and category metrics.
const (
	// UnknownModel stands in when the upstream response names no model.
	UnknownModel = "unknown"
	// CategoryNone is a message the LLM judged neither transaction nor bill.
	CategoryNone = "none"
)

// ModelStatsOutcome counts every /v1/model-stats response, one key per
// request: OK, Unauthorized, Banned, RateLimited, BadRequest or Internal.
const ModelStatsOutcome = "model_stats_outcome"

// RateLimited is model_stats_outcome's key for the per-install hourly limit.
// classify_outcome splits its limits into RateLimitedDaily and
// RateLimitedBurst instead.
const RateLimited = "rate_limited"
