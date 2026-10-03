package llm

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestClassify_RequestFormat(t *testing.T) {
	var receivedBody string
	var receivedAuth string

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		receivedAuth = r.Header.Get("Authorization")
		body, _ := io.ReadAll(r.Body)
		receivedBody = string(body)

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{
			"choices": [{"message": {"content": "{\"category\": null, \"transaction\": null, \"bill\": null}"}}],
			"usage": {"total_tokens": 100}
		}`))
	}))
	defer srv.Close()

	client := &Client{
		Endpoint: srv.URL,
		APIKey:   "test-key",
		Models:   []string{"model-a", "model-b", "model-c"},
		Timeout:  5 * time.Second,
	}

	_, err := client.Classify(context.Background(), Request{
		Sender:   "TEST",
		Content:  "test content",
		Currency: "BDT",
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Verify Authorization header
	if receivedAuth != "Bearer test-key" {
		t.Errorf("Authorization = %q, want %q", receivedAuth, "Bearer test-key")
	}

	// Verify models are in the configured order
	if !strings.Contains(receivedBody, `"models":["model-a","model-b","model-c"]`) {
		t.Errorf("models not in configured order: %s", receivedBody)
	}

	// Verify provider.require_parameters is true
	if !strings.Contains(receivedBody, `"provider":{"require_parameters":true}`) {
		t.Errorf("provider.require_parameters not set: %s", receivedBody)
	}

	// Verify response_format is present
	if !strings.Contains(receivedBody, `"response_format":{`) {
		t.Errorf("response_format not present: %s", receivedBody)
	}
}

func TestClassify_FencedJSON(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{
			"choices": [{"message": {"content": "` + "```json\\n{\\\"category\\\": null, \\\"transaction\\\": null, \\\"bill\\\": null}\\n```" + `"}}],
			"usage": {"total_tokens": 50}
		}`))
	}))
	defer srv.Close()

	client := &Client{
		Endpoint: srv.URL,
		APIKey:   "test-key",
		Models:   []string{"test-model"},
		Timeout:  5 * time.Second,
	}

	resp, err := client.Classify(context.Background(), Request{
		Sender:   "TEST",
		Content:  "test",
		Currency: "BDT",
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if resp.Result.Category != CategoryNone {
		t.Errorf("Category = %q, want %q", resp.Result.Category, CategoryNone)
	}
}

func TestClassify_TotalTokens(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{
			"choices": [{"message": {"content": "{\"category\": null, \"transaction\": null, \"bill\": null}"}}],
			"usage": {"total_tokens": 12345}
		}`))
	}))
	defer srv.Close()

	client := &Client{
		Endpoint: srv.URL,
		APIKey:   "test-key",
		Models:   []string{"test-model"},
		Timeout:  5 * time.Second,
	}

	resp, err := client.Classify(context.Background(), Request{
		Sender:   "TEST",
		Content:  "test",
		Currency: "BDT",
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if resp.TotalTokens != 12345 {
		t.Errorf("TotalTokens = %d, want %d", resp.TotalTokens, 12345)
	}
}

func TestClassify_429Retryable(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Retry-After", "30")
		w.Header().Set("X-RateLimit-Reset", "1700000000000")
		w.WriteHeader(http.StatusTooManyRequests)
		_, _ = w.Write([]byte("rate limited"))
	}))
	defer srv.Close()

	client := &Client{
		Endpoint: srv.URL,
		APIKey:   "test-key",
		Models:   []string{"test-model"},
		Timeout:  5 * time.Second,
	}

	_, err := client.Classify(context.Background(), Request{
		Sender:   "TEST",
		Content:  "test",
		Currency: "BDT",
	})

	var callErr *CallError
	if !errors.As(err, &callErr) {
		t.Fatalf("expected *CallError, got %T", err)
	}

	if callErr.Status != 429 {
		t.Errorf("Status = %d, want 429", callErr.Status)
	}

	if !callErr.Retryable {
		t.Error("expected Retryable = true")
	}

	if callErr.RetryAfter != 30*time.Second {
		t.Errorf("RetryAfter = %v, want 30s", callErr.RetryAfter)
	}

	if callErr.ResetAtEpochMs != 1700000000000 {
		t.Errorf("ResetAtEpochMs = %d, want 1700000000000", callErr.ResetAtEpochMs)
	}
}

func TestClassify_400NotRetryable(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte("bad request"))
	}))
	defer srv.Close()

	client := &Client{
		Endpoint: srv.URL,
		APIKey:   "test-key",
		Models:   []string{"test-model"},
		Timeout:  5 * time.Second,
	}

	_, err := client.Classify(context.Background(), Request{
		Sender:   "TEST",
		Content:  "test",
		Currency: "BDT",
	})

	var callErr *CallError
	if !errors.As(err, &callErr) {
		t.Fatalf("expected *CallError, got %T", err)
	}

	if callErr.Status != 400 {
		t.Errorf("Status = %d, want 400", callErr.Status)
	}

	if callErr.Retryable {
		t.Error("expected Retryable = false")
	}
}

func TestClassify_500Retryable(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte("server error"))
	}))
	defer srv.Close()

	client := &Client{
		Endpoint: srv.URL,
		APIKey:   "test-key",
		Models:   []string{"test-model"},
		Timeout:  5 * time.Second,
	}

	_, err := client.Classify(context.Background(), Request{
		Sender:   "TEST",
		Content:  "test",
		Currency: "BDT",
	})

	var callErr *CallError
	if !errors.As(err, &callErr) {
		t.Fatalf("expected *CallError, got %T", err)
	}

	if callErr.Status != 500 {
		t.Errorf("Status = %d, want 500", callErr.Status)
	}

	if !callErr.Retryable {
		t.Error("expected Retryable = true")
	}
}

func TestClassify_EmptyChoices(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"choices": [], "usage": {"total_tokens": 0}}`))
	}))
	defer srv.Close()

	client := &Client{
		Endpoint: srv.URL,
		APIKey:   "test-key",
		Models:   []string{"test-model"},
		Timeout:  5 * time.Second,
	}

	_, err := client.Classify(context.Background(), Request{
		Sender:   "TEST",
		Content:  "test",
		Currency: "BDT",
	})

	var callErr *CallError
	if !errors.As(err, &callErr) {
		t.Fatalf("expected *CallError, got %T", err)
	}

	if !callErr.Retryable {
		t.Error("expected Retryable = true for empty choices")
	}
}

func TestParseRetryAfter(t *testing.T) {
	tests := []struct {
		input string
		want  time.Duration
	}{
		{"30", 30 * time.Second},
		{"0", 0},
		{"-1", 0},                            // negative
		{"Thu, 01 Jan 2024 00:00:00 GMT", 0}, // HTTP-date form
		{"", 0},                              // empty
		{"invalid", 0},                       // non-integer
	}

	for _, tt := range tests {
		got := parseRetryAfter(tt.input)
		if got != tt.want {
			t.Errorf("parseRetryAfter(%q) = %v, want %v", tt.input, got, tt.want)
		}
	}
}

func TestParseResetAt(t *testing.T) {
	tests := []struct {
		input string
		want  int64
	}{
		{"1700000000000", 1700000000000},
		{"0", 0},
		{"-1", 0},      // negative
		{"invalid", 0}, // non-integer
		{"", 0},        // empty
	}

	for _, tt := range tests {
		got := parseResetAt(tt.input)
		if got != tt.want {
			t.Errorf("parseResetAt(%q) = %d, want %d", tt.input, got, tt.want)
		}
	}
}

func TestClassify_ContextCancellation(t *testing.T) {
	// Server that delays response
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		time.Sleep(2 * time.Second)
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{
			"choices": [{"message": {"content": "{\"category\": null, \"transaction\": null, \"bill\": null}"}}],
			"usage": {"total_tokens": 0}
		}`))
	}))
	defer srv.Close()

	client := &Client{
		Endpoint: srv.URL,
		APIKey:   "test-key",
		Models:   []string{"test-model"},
		Timeout:  10 * time.Second,
	}

	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()

	_, err := client.Classify(ctx, Request{
		Sender:   "TEST",
		Content:  "test",
		Currency: "BDT",
	})

	if err == nil {
		t.Fatal("expected error due to context cancellation")
	}

	var callErr *CallError
	if !errors.As(err, &callErr) {
		t.Fatalf("expected *CallError, got %T", err)
	}

	if !callErr.Retryable {
		t.Error("expected Retryable = true for context cancellation")
	}
}

func TestStripJSONFence(t *testing.T) {
	tests := []struct {
		input string
		want  string
	}{
		{
			input: "```json\n{\"key\": \"value\"}\n```",
			want:  `{"key": "value"}`,
		},
		{
			input: "```json\n{\"key\": \"value\"}",
			want:  `{"key": "value"}`,
		},
		{
			input: "{\"key\": \"value\"}",
			want:  `{"key": "value"}`,
		},
		{
			input: "```\n{\"key\": \"value\"}\n```",
			want:  `{"key": "value"}`,
		},
		{
			input: "  ```json\n{\"key\": \"value\"}\n```  ",
			want:  `{"key": "value"}`,
		},
	}

	for _, tt := range tests {
		got := stripJSONFence(tt.input)
		if got != tt.want {
			t.Errorf("stripJSONFence(%q) = %q, want %q", tt.input, got, tt.want)
		}
	}
}

func TestClassifyErrorNeverCarriesTheResponseBody(t *testing.T) {
	const secret = "SENSITIVE-SMS-ECHOED-BY-UPSTREAM"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"error":"bad request for ` + secret + `"}`))
	}))
	t.Cleanup(srv.Close)
	c := &Client{
		HTTP:     srv.Client(),
		Endpoint: srv.URL,
		APIKey:   "sk-test",
		Models:   []string{"a/one:free"},
		Timeout:  30 * time.Second,
	}

	_, err := c.Classify(context.Background(), Request{Sender: "EBL", Content: secret, Currency: "BDT"})

	if err == nil {
		t.Fatal("Classify() error = nil, want an error")
	}
	if strings.Contains(err.Error(), secret) {
		t.Fatalf("error text carries message content: %q", err.Error())
	}
}
