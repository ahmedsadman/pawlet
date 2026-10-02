package httpapi

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestBundleResponseStructure(t *testing.T) {
	handler := NewBundleHandler([]string{"model-a", "model-b"})

	req := httptest.NewRequest("GET", "/v1/bundle", nil)
	rec := httptest.NewRecorder()
	handler.Bundle(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}

	var payload map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &payload); err != nil {
		t.Fatalf("response is not valid JSON: %v", err)
	}

	if v, ok := payload["bundleVersion"].(float64); !ok || int(v) != 1 {
		t.Errorf("bundleVersion: expected 1, got %v", payload["bundleVersion"])
	}

	if v, ok := payload["schemaVersion"].(float64); !ok || int(v) != SchemaVersion {
		t.Errorf("schemaVersion: expected %d, got %v", SchemaVersion, payload["schemaVersion"])
	}

	if v, ok := payload["systemPrompt"].(string); !ok || v == "" {
		t.Errorf("systemPrompt: expected non-empty string, got %v", payload["systemPrompt"])
	}

	if v, ok := payload["userTemplate"].(string); !ok || v == "" {
		t.Errorf("userTemplate: expected non-empty string, got %v", payload["userTemplate"])
	}

	models, ok := payload["models"].([]any)
	if !ok {
		t.Fatalf("models: expected array, got %T", payload["models"])
	}
	if len(models) != 2 || models[0] != "model-a" || models[1] != "model-b" {
		t.Errorf("models: expected [model-a, model-b], got %v", models)
	}

	if payload["jsonSchema"] == nil {
		t.Error("jsonSchema: expected non-nil, got nil")
	}
}

func TestBundleETagIsSet(t *testing.T) {
	handler := NewBundleHandler([]string{"model-a"})

	req := httptest.NewRequest("GET", "/v1/bundle", nil)
	rec := httptest.NewRecorder()
	handler.Bundle(rec, req)

	etag := rec.Header().Get("ETag")
	if etag == "" {
		t.Error("ETag header is not set")
	}
	if !strings.HasPrefix(etag, `"`) || !strings.HasSuffix(etag, `"`) {
		t.Errorf("ETag is not wrapped in quotes: %s", etag)
	}
}

func TestBundleIfNoneMatchReturns304(t *testing.T) {
	handler := NewBundleHandler([]string{"model-a"})

	// First request to get the ETag
	req := httptest.NewRequest("GET", "/v1/bundle", nil)
	rec := httptest.NewRecorder()
	handler.Bundle(rec, req)
	etag := rec.Header().Get("ETag")

	// Second request with If-None-Match
	req2 := httptest.NewRequest("GET", "/v1/bundle", nil)
	req2.Header.Set("If-None-Match", etag)
	rec2 := httptest.NewRecorder()
	handler.Bundle(rec2, req2)

	if rec2.Code != http.StatusNotModified {
		t.Errorf("expected 304, got %d", rec2.Code)
	}

	if rec2.Body.Len() != 0 {
		t.Errorf("expected empty body on 304, got %d bytes", rec2.Body.Len())
	}
}

func TestBundleDifferentModelsProduceDifferentETags(t *testing.T) {
	handler1 := NewBundleHandler([]string{"model-a"})
	handler2 := NewBundleHandler([]string{"model-b"})

	req1 := httptest.NewRequest("GET", "/v1/bundle", nil)
	rec1 := httptest.NewRecorder()
	handler1.Bundle(rec1, req1)
	etag1 := rec1.Header().Get("ETag")

	req2 := httptest.NewRequest("GET", "/v1/bundle", nil)
	rec2 := httptest.NewRecorder()
	handler2.Bundle(rec2, req2)
	etag2 := rec2.Header().Get("ETag")

	if etag1 == etag2 {
		t.Errorf("expected different ETags for different model lists, both were %s", etag1)
	}
}

func TestBundleSameModelsProduceSameETag(t *testing.T) {
	models := []string{"model-a", "model-b"}

	handler1 := NewBundleHandler(models)
	handler2 := NewBundleHandler(models)

	req1 := httptest.NewRequest("GET", "/v1/bundle", nil)
	rec1 := httptest.NewRecorder()
	handler1.Bundle(rec1, req1)
	etag1 := rec1.Header().Get("ETag")

	req2 := httptest.NewRequest("GET", "/v1/bundle", nil)
	rec2 := httptest.NewRecorder()
	handler2.Bundle(rec2, req2)
	etag2 := rec2.Header().Get("ETag")

	if etag1 != etag2 {
		t.Errorf("expected same ETag for same model list, got %s and %s", etag1, etag2)
	}
}

func TestBundleCacheControlIsSetOn200And304(t *testing.T) {
	handler := NewBundleHandler([]string{"model-a"})

	// Test 200 path
	req := httptest.NewRequest("GET", "/v1/bundle", nil)
	rec := httptest.NewRecorder()
	handler.Bundle(rec, req)

	cc := rec.Header().Get("Cache-Control")
	if cc != "public, max-age=86400" {
		t.Errorf("200 path: expected Cache-Control 'public, max-age=86400', got %q", cc)
	}

	// Test 304 path
	etag := rec.Header().Get("ETag")
	req2 := httptest.NewRequest("GET", "/v1/bundle", nil)
	req2.Header.Set("If-None-Match", etag)
	rec2 := httptest.NewRecorder()
	handler.Bundle(rec2, req2)

	cc2 := rec2.Header().Get("Cache-Control")
	if cc2 != "public, max-age=86400" {
		t.Errorf("304 path: expected Cache-Control 'public, max-age=86400', got %q", cc2)
	}
}

func TestBundleContainsNoSecrets(t *testing.T) {
	handler := NewBundleHandler([]string{"model-a", "model-b"})

	req := httptest.NewRequest("GET", "/v1/bundle", nil)
	rec := httptest.NewRecorder()
	handler.Bundle(rec, req)

	body := rec.Body.String()

	if strings.Contains(body, "sk-") {
		t.Error("response body contains 'sk-' which looks like a secret key")
	}

	if strings.Contains(body, "Bearer") {
		t.Error("response body contains 'Bearer' which looks like an auth token")
	}
}
