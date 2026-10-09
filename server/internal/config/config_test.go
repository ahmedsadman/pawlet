package config

import (
	"strings"
	"testing"
)

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
	delete(env, "GOOGLE_SERVICE_ACCOUNT_JSON")
	delete(env, "CERT_SHA256_DIGESTS")

	_, err := Load(lookup(env))
	if err == nil {
		t.Fatal("Load() error = nil, want an error for missing keys")
	}
	msg := err.Error()
	for _, key := range []string{"OPENROUTER_API_KEY", "GOOGLE_SERVICE_ACCOUNT_JSON", "CERT_SHA256_DIGESTS"} {
		if !strings.Contains(msg, key) {
			t.Errorf("error message = %q, want it to include %q", msg, key)
		}
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

func TestLoadRejectsShortJWTSecret(t *testing.T) {
	env := validEnv()
	env["JWT_SECRET"] = "0123456789abcdef"

	_, err := Load(lookup(env))
	if err == nil {
		t.Fatal("Load() error = nil, want an error for short JWT_SECRET")
	}
	msg := err.Error()
	if !strings.Contains(msg, "at least 32 bytes") {
		t.Errorf("error message = %q, want it to mention the length requirement", msg)
	}
	if !strings.Contains(msg, "16") {
		t.Errorf("error message = %q, want it to mention the actual length 16", msg)
	}
}

func TestLoadRejectsMissingGoogleServiceAccount(t *testing.T) {
	env := validEnv()
	delete(env, "GOOGLE_SERVICE_ACCOUNT_JSON")

	_, err := Load(lookup(env))
	if err == nil {
		t.Fatal("Load() error = nil, want an error for missing GOOGLE_SERVICE_ACCOUNT_JSON")
	}
	msg := err.Error()
	if !strings.Contains(msg, "GOOGLE_SERVICE_ACCOUNT_JSON") {
		t.Errorf("error message = %q, want it to include GOOGLE_SERVICE_ACCOUNT_JSON", msg)
	}
}

func TestLoadRejectsMissingCertDigests(t *testing.T) {
	env := validEnv()
	delete(env, "CERT_SHA256_DIGESTS")

	_, err := Load(lookup(env))
	if err == nil {
		t.Fatal("Load() error = nil, want an error for missing CERT_SHA256_DIGESTS")
	}
	msg := err.Error()
	if !strings.Contains(msg, "CERT_SHA256_DIGESTS") {
		t.Errorf("error message = %q, want it to include CERT_SHA256_DIGESTS", msg)
	}
}

func TestLoadRejectsNonPositiveInteger(t *testing.T) {
	env := validEnv()
	env["DAILY_PER_INSTALL"] = "0"

	_, err := Load(lookup(env))
	if err == nil {
		t.Fatal("Load() error = nil, want an error for zero DAILY_PER_INSTALL")
	}
	msg := err.Error()
	if !strings.Contains(msg, "DAILY_PER_INSTALL") {
		t.Errorf("error message = %q, want it to include DAILY_PER_INSTALL", msg)
	}
}

func TestLoadRejectsNonNumericInteger(t *testing.T) {
	env := validEnv()
	env["BURST_PER_MIN"] = "abc"

	_, err := Load(lookup(env))
	if err == nil {
		t.Fatal("Load() error = nil, want an error for non-numeric BURST_PER_MIN")
	}
	msg := err.Error()
	if !strings.Contains(msg, "BURST_PER_MIN") {
		t.Errorf("error message = %q, want it to include BURST_PER_MIN", msg)
	}
}

func TestSplitListTrimsAndFiltersBlanks(t *testing.T) {
	env := validEnv()
	env["MODELS"] = "a/one:free, , b/two:free"

	cfg, err := Load(lookup(env))
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	want := []string{"a/one:free", "b/two:free"}
	if len(cfg.Models) != 2 {
		t.Errorf("len(Models) = %d, want 2", len(cfg.Models))
	}
	for i, model := range cfg.Models {
		if model != want[i] {
			t.Errorf("Models[%d] = %q, want %q", i, model, want[i])
		}
	}
}

func TestLoadReadsImageTag(t *testing.T) {
	env := validEnv()
	cfg, err := Load(lookup(env))
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if cfg.ImageTag != "" {
		t.Errorf("ImageTag = %q, want empty by default", cfg.ImageTag)
	}

	env["IMAGE_TAG"] = "bcd465a"
	cfg, err = Load(lookup(env))
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if cfg.ImageTag != "bcd465a" {
		t.Errorf("ImageTag = %q, want bcd465a", cfg.ImageTag)
	}
}
