package admin

import (
	"strings"
	"testing"
)

func envLookup(m map[string]string) func(string) (string, bool) {
	return func(k string) (string, bool) { v, ok := m[k]; return v, ok }
}

func validAdminEnv(t *testing.T) map[string]string {
	return map[string]string{
		"ADMIN_PASSWORD_HASH":  hashForTests(t),
		"ADMIN_SESSION_SECRET": strings.Repeat("s", 32),
	}
}

func TestLoadConfigDefaults(t *testing.T) {
	cfg, err := LoadConfig(envLookup(validAdminEnv(t)))
	if err != nil {
		t.Fatalf("LoadConfig() error = %v", err)
	}
	if cfg.Addr != ":8080" || cfg.DatabasePath != "/data/pawlet.db" || cfg.TrustedProxyCIDR != "172.16.0.0/12" {
		t.Fatalf("defaults = %+v", cfg)
	}
}

func TestLoadConfigErrors(t *testing.T) {
	cases := map[string]func(map[string]string){
		"missing hash":   func(m map[string]string) { delete(m, "ADMIN_PASSWORD_HASH") },
		"missing secret": func(m map[string]string) { delete(m, "ADMIN_SESSION_SECRET") },
		"short secret":   func(m map[string]string) { m["ADMIN_SESSION_SECRET"] = "short" },
		"bad hash":       func(m map[string]string) { m["ADMIN_PASSWORD_HASH"] = "plaintext" },
		"bad cidr":       func(m map[string]string) { m["TRUSTED_PROXY_CIDR"] = "nope" },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			env := validAdminEnv(t)
			mutate(env)
			if _, err := LoadConfig(envLookup(env)); err == nil {
				t.Fatal("LoadConfig() error = nil")
			}
		})
	}
}
