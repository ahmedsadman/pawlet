package config

import "testing"

func validEnv() map[string]string {
	return map[string]string{
		"OPENROUTER_API_KEY":          "sk-test",
		"JWT_SECRET":                  "0123456789abcdef0123456789abcdef",
		"GOOGLE_SERVICE_ACCOUNT_JSON": "/run/secrets/sa.json",
		"CERT_SHA256_DIGESTS":         "AA:BB",
		"ENV":                         "production",
	}
}

func lookup(m map[string]string) func(string) (string, bool) {
	return func(k string) (string, bool) {
		v, ok := m[k]
		return v, ok
	}
}

func TestLoadAppliesDefaults(t *testing.T) {
	cfg, err := Load(lookup(validEnv()))
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if cfg.PackageName != "com.pastabyte.pawlet" {
		t.Errorf("PackageName = %q", cfg.PackageName)
	}
	if cfg.DailyPerInstall != 200 {
		t.Errorf("DailyPerInstall = %d, want 200", cfg.DailyPerInstall)
	}
	if cfg.BurstPerMin != 20 {
		t.Errorf("BurstPerMin = %d, want 20", cfg.BurstPerMin)
	}
	if len(cfg.Models) != 3 || cfg.Models[0] != "nvidia/nemotron-3-super-120b-a12b:free" {
		t.Errorf("Models = %v", cfg.Models)
	}
}

func TestLoadRejectsMissingRequired(t *testing.T) {
	env := validEnv()
	delete(env, "OPENROUTER_API_KEY")

	if _, err := Load(lookup(env)); err == nil {
		t.Fatal("Load() error = nil, want an error for the missing key")
	}
}

func TestLoadRejectsDevSecretInProduction(t *testing.T) {
	env := validEnv()
	env["DEV_SHARED_SECRET"] = "hunter2"

	if _, err := Load(lookup(env)); err == nil {
		t.Fatal("Load() error = nil, want a refusal to start")
	}
}

func TestLoadAllowsDevSecretOutsideProduction(t *testing.T) {
	env := validEnv()
	env["ENV"] = "development"
	env["DEV_SHARED_SECRET"] = "hunter2"

	cfg, err := Load(lookup(env))
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if cfg.DevSharedSecret != "hunter2" {
		t.Errorf("DevSharedSecret = %q", cfg.DevSharedSecret)
	}
}

func TestLoadParsesModelsOverride(t *testing.T) {
	env := validEnv()
	env["MODELS"] = "a/one:free, b/two:free"

	cfg, err := Load(lookup(env))
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	want := []string{"a/one:free", "b/two:free"}
	if len(cfg.Models) != len(want) || cfg.Models[1] != want[1] {
		t.Errorf("Models = %v, want %v", cfg.Models, want)
	}
}
