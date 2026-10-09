package admin

import (
	"fmt"
	"net"
	"strings"
)

// Config is pawlet-admin's environment configuration. It deliberately holds
// none of pawletd's secrets.
type Config struct {
	PasswordHash     string
	SessionSecret    []byte
	Addr             string
	DatabasePath     string
	TrustedProxyCIDR string
}

// LoadConfig reads and validates the configuration.
func LoadConfig(lookup func(string) (string, bool)) (Config, error) {
	get := func(key, fallback string) string {
		if v, ok := lookup(key); ok && v != "" {
			return v
		}
		return fallback
	}
	cfg := Config{
		PasswordHash:     get("ADMIN_PASSWORD_HASH", ""),
		SessionSecret:    []byte(get("ADMIN_SESSION_SECRET", "")),
		Addr:             get("ADMIN_ADDR", ":8080"),
		DatabasePath:     get("DATABASE_PATH", "/data/pawlet.db"),
		TrustedProxyCIDR: get("TRUSTED_PROXY_CIDR", "172.16.0.0/12"),
	}

	var missing []string
	if cfg.PasswordHash == "" {
		missing = append(missing, "ADMIN_PASSWORD_HASH")
	}
	if len(cfg.SessionSecret) == 0 {
		missing = append(missing, "ADMIN_SESSION_SECRET")
	}
	if len(missing) > 0 {
		return Config{}, fmt.Errorf("missing configuration: %s", strings.Join(missing, ", "))
	}
	if len(cfg.SessionSecret) < 32 {
		return Config{}, fmt.Errorf("ADMIN_SESSION_SECRET must be at least 32 bytes, got %d", len(cfg.SessionSecret))
	}
	if _, err := parsePHC(cfg.PasswordHash); err != nil {
		return Config{}, fmt.Errorf("ADMIN_PASSWORD_HASH: %w (generate one with: pawlet-admin hash-password)", err)
	}
	if _, _, err := net.ParseCIDR(cfg.TrustedProxyCIDR); err != nil {
		return Config{}, fmt.Errorf("TRUSTED_PROXY_CIDR: %w", err)
	}
	return cfg, nil
}
