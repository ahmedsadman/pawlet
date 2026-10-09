package httpapi

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/ahmedsadman/pawlet/server/internal/llm"
	"github.com/ahmedsadman/pawlet/server/internal/metrics"
	"github.com/ahmedsadman/pawlet/server/internal/quota"
)

var metricsHash = strings.Repeat("m", 64)

// authed builds a classify request for metricsHash with a valid token.
func (h *testHarness) authed(content string) *http.Request {
	req := httptest.NewRequest(http.MethodPost, "/v1/classify",
		classifyRequestBody("BANK", content, "BDT"))
	req.Header.Set("Authorization", "Bearer "+h.mintToken(metricsHash))
	return req
}

// useLimits swaps in a limiter with the given ceilings on the harness clock.
func (h *testHarness) useLimits(l quota.Limits) {
	h.limiter = quota.New(l, noopSink{}, func() time.Time { return h.now })
	h.handler.Limiter = h.limiter
}

func TestClassifyCountsOutcomes(t *testing.T) {
	cases := []struct {
		name  string
		setup func(t *testing.T, h *testHarness) *http.Request
		want  string
	}{
		{
			name: "ok",
			setup: func(_ *testing.T, h *testHarness) *http.Request {
				h.touchInstall(metricsHash)
				return h.authed("content")
			},
			want: metrics.OK,
		},
		{
			name: "missing header",
			setup: func(_ *testing.T, _ *testHarness) *http.Request {
				return httptest.NewRequest(http.MethodPost, "/v1/classify", classifyRequestBody("BANK", "c", "BDT"))
			},
			want: metrics.Unauthorized,
		},
		{
			name: "unknown install",
			setup: func(_ *testing.T, h *testHarness) *http.Request {
				return h.authed("content")
			},
			want: metrics.Unauthorized,
		},
		{
			name: "banned",
			setup: func(t *testing.T, h *testHarness) *http.Request {
				h.touchInstall(metricsHash)
				if err := h.store.Ban(context.Background(), metricsHash, "test"); err != nil {
					t.Fatalf("ban: %v", err)
				}
				return h.authed("content")
			},
			want: metrics.Banned,
		},
		{
			name: "bad request",
			setup: func(_ *testing.T, h *testHarness) *http.Request {
				h.touchInstall(metricsHash)
				return h.authed("")
			},
			want: metrics.BadRequest,
		},
		{
			name: "daily quota",
			setup: func(_ *testing.T, h *testHarness) *http.Request {
				h.touchInstall(metricsHash)
				h.useLimits(quota.Limits{Daily: 1, Burst: 10, GlobalDaily: 1000})
				h.limiter.Admit(metricsHash)
				return h.authed("content")
			},
			want: metrics.RateLimitedDaily,
		},
		{
			name: "burst",
			setup: func(_ *testing.T, h *testHarness) *http.Request {
				h.touchInstall(metricsHash)
				h.useLimits(quota.Limits{Daily: 100, Burst: 1, GlobalDaily: 1000})
				h.limiter.Admit(metricsHash)
				return h.authed("content")
			},
			want: metrics.RateLimitedBurst,
		},
		{
			name: "global capacity",
			setup: func(_ *testing.T, h *testHarness) *http.Request {
				h.touchInstall(metricsHash)
				h.useLimits(quota.Limits{Daily: 100, Burst: 10, GlobalDaily: 1})
				h.limiter.Admit(strings.Repeat("z", 64))
				return h.authed("content")
			},
			want: metrics.Capacity,
		},
		{
			name: "upstream 429",
			setup: func(_ *testing.T, h *testHarness) *http.Request {
				h.touchInstall(metricsHash)
				h.classifier.err = &llm.CallError{Status: 429, Retryable: true}
				return h.authed("content")
			},
			want: metrics.Upstream429,
		},
		{
			name: "upstream retryable",
			setup: func(_ *testing.T, h *testHarness) *http.Request {
				h.touchInstall(metricsHash)
				h.classifier.err = &llm.CallError{Status: 502, Retryable: true}
				return h.authed("content")
			},
			want: metrics.UpstreamRetryable,
		},
		{
			name: "upstream rejected",
			setup: func(_ *testing.T, h *testHarness) *http.Request {
				h.touchInstall(metricsHash)
				h.classifier.err = &llm.CallError{Status: 400}
				return h.authed("content")
			},
			want: metrics.UpstreamRejected,
		},
		{
			name: "classifier non-call error",
			setup: func(_ *testing.T, h *testHarness) *http.Request {
				h.touchInstall(metricsHash)
				h.classifier.err = errors.New("boom")
				return h.authed("content")
			},
			want: metrics.UpstreamRetryable,
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			h := newTestHarness(t)
			req := c.setup(t, h)

			h.handler.Classify(httptest.NewRecorder(), req)

			if got := h.counter.n(metrics.ClassifyOutcome, c.want); got != 1 {
				t.Fatalf("classify_outcome/%s = %d, want 1 (all: %v)", c.want, got, h.counter.got)
			}
			if got := h.counter.total(metrics.ClassifyOutcome); got != 1 {
				t.Fatalf("classify_outcome total = %d, want exactly 1 (all: %v)", got, h.counter.got)
			}
		})
	}
}

func TestClassifySuccessRecordsLatencyModelCategory(t *testing.T) {
	h := newTestHarness(t)
	h.touchInstall(metricsHash)
	h.classifier.response.Model = "qwen/qwen3.8-27b:free"

	h.handler.Classify(httptest.NewRecorder(), h.authed("content"))

	// The harness clock is frozen, so measured latency is zero.
	if got := h.counter.n(metrics.ClassifyLatency, "250"); got != 1 {
		t.Errorf("latency/250 = %d, want 1 (all: %v)", got, h.counter.got)
	}
	if got := h.counter.n(metrics.Model, "qwen/qwen3.8-27b:free"); got != 1 {
		t.Errorf("model = %d, want 1 (all: %v)", got, h.counter.got)
	}
	if got := h.counter.n(metrics.Category, "transaction"); got != 1 {
		t.Errorf("category/transaction = %d, want 1 (all: %v)", got, h.counter.got)
	}
}

func TestClassifySuccessMapsEmptyModelAndNoneCategory(t *testing.T) {
	h := newTestHarness(t)
	h.touchInstall(metricsHash)
	h.classifier.response = llm.Response{Result: llm.ClassifyResult{Category: llm.CategoryNone}}

	h.handler.Classify(httptest.NewRecorder(), h.authed("content"))

	if got := h.counter.n(metrics.Model, metrics.UnknownModel); got != 1 {
		t.Errorf("model/unknown = %d, want 1 (all: %v)", got, h.counter.got)
	}
	if got := h.counter.n(metrics.Category, metrics.CategoryNone); got != 1 {
		t.Errorf("category/none = %d, want 1 (all: %v)", got, h.counter.got)
	}
}

func TestClassifyFailureRecordsNoSuccessMetrics(t *testing.T) {
	h := newTestHarness(t)
	h.touchInstall(metricsHash)
	h.classifier.err = &llm.CallError{Status: 502, Retryable: true}

	h.handler.Classify(httptest.NewRecorder(), h.authed("content"))

	for _, m := range []string{metrics.ClassifyLatency, metrics.Model, metrics.Category} {
		if got := h.counter.total(m); got != 0 {
			t.Errorf("%s total = %d, want 0 on failure", m, got)
		}
	}
}

func TestClassifyModelKeyTruncation(t *testing.T) {
	h := newTestHarness(t)
	h.touchInstall(metricsHash)
	// 200-character model name
	longModel := strings.Repeat("x", 200)
	h.classifier.response.Model = longModel

	h.handler.Classify(httptest.NewRecorder(), h.authed("content"))

	// Should be counted under the first 128 bytes
	expected := longModel[:128]
	if got := h.counter.n(metrics.Model, expected); got != 1 {
		t.Errorf("model truncated key = %d, want 1 (all: %v)", got, h.counter.got)
	}
}

func TestModelKey(t *testing.T) {
	cases := []struct {
		name  string
		model string
		want  string
	}{
		{
			name:  "empty returns unknown",
			model: "",
			want:  metrics.UnknownModel,
		},
		{
			name:  "128-byte ASCII unchanged",
			model: strings.Repeat("x", 128),
			want:  strings.Repeat("x", 128),
		},
		{
			name:  "129-byte ASCII truncated",
			model: strings.Repeat("x", 129),
			want:  strings.Repeat("x", 128),
		},
		{
			name: "multibyte rune at boundary",
			// 126 'a' + one 3-byte UTF-8 character (U+2318 ⌘) = 129 bytes total.
			// Truncation should cut before the multibyte character.
			model: strings.Repeat("a", 126) + "⌘",
			want:  strings.Repeat("a", 126),
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := modelKey(c.model)
			if got != c.want {
				t.Errorf("modelKey(%q) = %q, want %q", c.model, got, c.want)
			}
			// Verify the result is valid UTF-8.
			if !utf8.ValidString(got) {
				t.Errorf("modelKey(%q) = %q, which is invalid UTF-8", c.model, got)
			}
		})
	}
}
