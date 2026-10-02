// Package config loads and validates the service's environment configuration.
package config

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
)

// defaultModels mirrors SettingsRepository.defaultLlmModels in the app, so the
// server's fallback order matches what the client used to send.
var defaultModels = []string{
	"nvidia/nemotron-3-super-120b-a12b:free",
	"qwen/qwen3.8-27b:free",
	"nex-agi/nex-n2.5-pro:free",
}

// DefaultModels returns the app's current OpenRouter fallback list, newest
// first. A copy is returned so callers cannot mutate the shared default.
func DefaultModels() []string {
	out := make([]string, len(defaultModels))
	copy(out, defaultModels)
	return out
}

// Config is the fully resolved service configuration.
type Config struct {
	OpenRouterAPIKey   string
	JWTSecret          []byte
	ServiceAccountPath string
	PackageName        string
	CertSHA256Digests  []string
	Models             []string
	DailyPerInstall    int
	BurstPerMin        int
	GlobalDailyCap     int
	ChallengePerIPHour int
	TrustedProxyCIDR   string
	Env                string
	DevSharedSecret    string
	Addr               string
	DatabasePath       string
}

// LookupEnv matches the signature of os.LookupEnv so tests can inject values.
type LookupEnv func(string) (string, bool)

// Load reads configuration from lookup, applies defaults, and validates.
func Load(lookup LookupEnv) (Config, error) {
	get := func(key, fallback string) string {
		if v, ok := lookup(key); ok && v != "" {
			return v
		}
		return fallback
	}

	cfg := Config{
		OpenRouterAPIKey:   get("OPENROUTER_API_KEY", ""),
		ServiceAccountPath: get("GOOGLE_SERVICE_ACCOUNT_JSON", ""),
		PackageName:        get("PACKAGE_NAME", "com.pastabyte.pawlet"),
		TrustedProxyCIDR:   get("TRUSTED_PROXY_CIDR", "172.16.0.0/12"),
		Env:                get("ENV", "development"),
		DevSharedSecret:    get("DEV_SHARED_SECRET", ""),
		Addr:               get("ADDR", ":8080"),
		DatabasePath:       get("DATABASE_PATH", "/data/pawlet.db"),
	}

	cfg.JWTSecret = []byte(get("JWT_SECRET", ""))
	cfg.CertSHA256Digests = splitList(get("CERT_SHA256_DIGESTS", ""))
	cfg.Models = splitList(get("MODELS", ""))
	if len(cfg.Models) == 0 {
		cfg.Models = DefaultModels()
	}

	var err error
	if cfg.DailyPerInstall, err = parseInt(get("DAILY_PER_INSTALL", "200")); err != nil {
		return Config{}, fmt.Errorf("DAILY_PER_INSTALL: %w", err)
	}
	if cfg.BurstPerMin, err = parseInt(get("BURST_PER_MIN", "20")); err != nil {
		return Config{}, fmt.Errorf("BURST_PER_MIN: %w", err)
	}
	if cfg.GlobalDailyCap, err = parseInt(get("GLOBAL_DAILY_CAP", "20000")); err != nil {
		return Config{}, fmt.Errorf("GLOBAL_DAILY_CAP: %w", err)
	}
	if cfg.ChallengePerIPHour, err = parseInt(get("CHALLENGE_PER_IP_HOUR", "60")); err != nil {
		return Config{}, fmt.Errorf("CHALLENGE_PER_IP_HOUR: %w", err)
	}

	return cfg, cfg.validate()
}

func (c Config) validate() error {
	var missing []string
	if c.OpenRouterAPIKey == "" {
		missing = append(missing, "OPENROUTER_API_KEY")
	}
	if len(c.JWTSecret) == 0 {
		missing = append(missing, "JWT_SECRET")
	}
	if c.ServiceAccountPath == "" {
		missing = append(missing, "GOOGLE_SERVICE_ACCOUNT_JSON")
	}
	if len(c.CertSHA256Digests) == 0 {
		missing = append(missing, "CERT_SHA256_DIGESTS")
	}
	if len(missing) > 0 {
		return fmt.Errorf("missing configuration: %s", strings.Join(missing, ", "))
	}
	if len(c.JWTSecret) < 32 {
		return fmt.Errorf("JWT_SECRET must be at least 32 bytes, got %d", len(c.JWTSecret))
	}
	// A bypass credential in production would make every verdict check optional.
	if c.Env == "production" && c.DevSharedSecret != "" {
		return errors.New("DEV_SHARED_SECRET must not be set when ENV=production")
	}
	return nil
}

func splitList(raw string) []string {
	if raw == "" {
		return nil
	}
	parts := strings.Split(raw, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		if trimmed := strings.TrimSpace(p); trimmed != "" {
			out = append(out, trimmed)
		}
	}
	return out
}

func parseInt(raw string) (int, error) {
	n, err := strconv.Atoi(raw)
	if err != nil {
		return 0, err
	}
	if n <= 0 {
		return 0, fmt.Errorf("must be positive, got %d", n)
	}
	return n, nil
}
