package attest

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"time"

	"golang.org/x/oauth2"
	"golang.org/x/oauth2/google"
)

// Decoder turns an opaque integrity token into a verdict payload. Declared
// here because this package consumes it; handlers take this interface so their
// tests never touch the network.
type Decoder interface {
	Decode(ctx context.Context, token string) (Payload, error)
}

// GoogleDecoder calls the Play Integrity decode endpoint.
type GoogleDecoder struct {
	Client      *http.Client
	Endpoint    string
	PackageName string
}

const playIntegrityScope = "https://www.googleapis.com/auth/playintegrity"

// NewGoogleDecoder builds a decoder authenticated by a service account file.
func NewGoogleDecoder(ctx context.Context, serviceAccountPath, packageName string) (*GoogleDecoder, error) {
	data, err := readFile(serviceAccountPath)
	if err != nil {
		return nil, fmt.Errorf("read service account: %w", err)
	}
	creds, err := google.CredentialsFromJSON(ctx, data, playIntegrityScope)
	if err != nil {
		return nil, fmt.Errorf("parse service account: %w", err)
	}
	client := oauth2.NewClient(ctx, creds.TokenSource)
	client.Timeout = 15 * time.Second

	endpoint := fmt.Sprintf(
		"https://playintegrity.googleapis.com/v1/%s:decodeIntegrityToken", packageName)
	return &GoogleDecoder{Client: client, Endpoint: endpoint, PackageName: packageName}, nil
}

// Decode posts the token and returns the decoded payload.
func (d *GoogleDecoder) Decode(ctx context.Context, token string) (Payload, error) {
	body, err := json.Marshal(map[string]string{"integrityToken": token})
	if err != nil {
		return Payload{}, fmt.Errorf("encode decode request: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, d.Endpoint, bytes.NewReader(body))
	if err != nil {
		return Payload{}, fmt.Errorf("build decode request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := d.Client.Do(req)
	if err != nil {
		return Payload{}, fmt.Errorf("call decode endpoint: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode != http.StatusOK {
		snippet, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return Payload{}, fmt.Errorf("decode endpoint returned %d: %s", resp.StatusCode, snippet)
	}

	var envelope struct {
		TokenPayloadExternal Payload `json:"tokenPayloadExternal"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&envelope); err != nil {
		return Payload{}, fmt.Errorf("parse decode response: %w", err)
	}
	return envelope.TokenPayloadExternal, nil
}

func readFile(path string) ([]byte, error) {
	return os.ReadFile(path) //nolint:gosec // path comes from trusted configuration
}
