package llm

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
)

const DefaultEndpoint = "https://openrouter.ai/api/v1/chat/completions"

// Request carries the SMS message to classify.
type Request struct {
	Sender   string
	Content  string
	Currency string
}

// Response carries the fused classify+extract result and token usage.
type Response struct {
	Result      ClassifyResult
	TotalTokens int64
}

// CallError wraps a failed OpenRouter call with retry metadata.
type CallError struct {
	Status         int
	Message        string
	Retryable      bool
	RetryAfter     time.Duration
	ResetAtEpochMs int64
}

func (e *CallError) Error() string {
	return fmt.Sprintf("openrouter: HTTP %d: %s", e.Status, e.Message)
}

// Client calls OpenRouter's chat-completions API.
type Client struct {
	HTTP     *http.Client
	Endpoint string
	APIKey   string
	Models   []string
	Timeout  time.Duration
}

// Classify sends the SMS to OpenRouter and returns the fused classify+extract result.
// A single attempt is made per call — there is no internal retry loop. Transient
// failures (429/5xx/network/timeout/malformed JSON) surface as retryable *CallError
// so the processing pipeline owns retry/backoff.
func (c *Client) Classify(ctx context.Context, in Request) (Response, error) {
	httpClient := c.HTTP
	if httpClient == nil {
		httpClient = http.DefaultClient
	}

	endpoint := c.Endpoint
	if endpoint == "" {
		endpoint = DefaultEndpoint
	}

	timeout := c.Timeout
	if timeout == 0 {
		timeout = 2 * time.Minute
	}

	// Derive a timeout context from ctx
	timeoutCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	// Build the request body
	reqBody := map[string]any{
		"models": c.Models,
		"messages": []map[string]string{
			{"role": "system", "content": SystemPrompt},
			{"role": "user", "content": BuildUserContent(in.Sender, in.Content, in.Currency)},
		},
		"response_format": map[string]any{
			"type":        "json_schema",
			"json_schema": JSONSchema,
		},
		"provider": map[string]any{
			"require_parameters": true,
		},
	}

	bodyBytes, err := json.Marshal(reqBody)
	if err != nil {
		return Response{}, fmt.Errorf("marshal request: %w", err)
	}

	// Create the HTTP request
	req, err := http.NewRequestWithContext(timeoutCtx, "POST", endpoint, bytes.NewReader(bodyBytes))
	if err != nil {
		return Response{}, fmt.Errorf("create request: %w", err)
	}

	req.Header.Set("Authorization", "Bearer "+c.APIKey)
	req.Header.Set("Content-Type", "application/json")

	// Send the request
	resp, err := httpClient.Do(req)
	if err != nil {
		// Network/timeout errors are retryable
		return Response{}, &CallError{
			Status:    0,
			Message:   fmt.Sprintf("network error: %v", err),
			Retryable: true,
		}
	}
	defer resp.Body.Close()

	// Read the response body
	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return Response{}, &CallError{
			Status:    resp.StatusCode,
			Message:   fmt.Sprintf("read body: %v", err),
			Retryable: true,
		}
	}

	// Handle non-2xx responses
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		retryable := resp.StatusCode == 429 || resp.StatusCode == 408 || resp.StatusCode >= 500
		return Response{}, &CallError{
			Status:         resp.StatusCode,
			Message:        string(respBody),
			Retryable:      retryable,
			RetryAfter:     parseRetryAfter(resp.Header.Get("Retry-After")),
			ResetAtEpochMs: parseResetAt(resp.Header.Get("X-RateLimit-Reset")),
		}
	}

	// Parse the chat-completions envelope
	var envelope struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
		Usage struct {
			TotalTokens int64 `json:"total_tokens"`
		} `json:"usage"`
	}

	if err := json.Unmarshal(respBody, &envelope); err != nil {
		return Response{}, &CallError{
			Status:    resp.StatusCode,
			Message:   fmt.Sprintf("malformed envelope: %v", err),
			Retryable: true,
		}
	}

	// Empty choices array is retryable
	if len(envelope.Choices) == 0 {
		return Response{}, &CallError{
			Status:    resp.StatusCode,
			Message:   "empty choices array",
			Retryable: true,
		}
	}

	// Strip any JSON fence from the content
	content := stripJSONFence(envelope.Choices[0].Message.Content)

	// Decode the content payload with UseNumber to preserve precision
	decoder := json.NewDecoder(strings.NewReader(content))
	decoder.UseNumber()

	var payload map[string]any
	if err := decoder.Decode(&payload); err != nil {
		return Response{}, &CallError{
			Status:    resp.StatusCode,
			Message:   fmt.Sprintf("malformed content: %v", err),
			Retryable: true,
		}
	}

	// Normalise the payload
	result, err := Normalise(payload)
	if err != nil {
		return Response{}, &CallError{
			Status:    resp.StatusCode,
			Message:   fmt.Sprintf("normalise: %v", err),
			Retryable: true,
		}
	}

	return Response{
		Result:      result,
		TotalTokens: envelope.Usage.TotalTokens,
	}, nil
}

// stripJSONFence removes a ```json ... ``` fence from the content if present.
// Free models sometimes ignore response_format and wrap the JSON.
func stripJSONFence(content string) string {
	t := strings.TrimSpace(content)
	if strings.HasPrefix(t, "```") {
		// Find the first newline
		firstNewline := strings.IndexByte(t, '\n')
		if firstNewline != -1 {
			t = t[firstNewline+1:]
		}
		// Remove trailing fence if present
		if strings.HasSuffix(t, "```") {
			t = t[:len(t)-3]
		}
	}
	return strings.TrimSpace(t)
}

// parseRetryAfter parses a Retry-After header to a Duration. Only the
// delta-seconds form is honored: a non-negative integer becomes that many
// seconds. HTTP-date forms are not supported.
func parseRetryAfter(value string) time.Duration {
	if value == "" {
		return 0
	}
	n, err := strconv.Atoi(strings.TrimSpace(value))
	if err != nil || n < 0 {
		return 0
	}
	return time.Duration(n) * time.Second
}

// parseResetAt parses an X-RateLimit-Reset header to epoch milliseconds.
// OpenRouter sends an absolute epoch-ms timestamp; the raw integer is carried
// as-is. Missing/non-integer/negative returns 0.
func parseResetAt(value string) int64 {
	if value == "" {
		return 0
	}
	n, err := strconv.ParseInt(strings.TrimSpace(value), 10, 64)
	if err != nil || n < 0 {
		return 0
	}
	return n
}
