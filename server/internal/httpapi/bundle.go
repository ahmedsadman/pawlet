package httpapi

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"slices"

	"github.com/ahmedsadman/pawlet/server/internal/llm"
)

// SchemaVersion is the contract version of the bundle body. A client that does
// not recognise this value falls back to its baked-in copy, so a server deploy
// can never break an older install.
const SchemaVersion = 1

type BundleHandler struct {
	body []byte
	etag string
}

// NewBundleHandler precomputes the bundle payload and its ETag exactly once at
// construction. The data is static and self-contained — a marshal failure here
// is a programming error, not a runtime condition, so panicking at startup is
// acceptable.
func NewBundleHandler(models []string) *BundleHandler {
	// Copy the slice: the payload and its ETag are rendered once here, so a
	// caller mutating the original afterwards would silently desync the served
	// bytes from the ETag clients cache against.
	models = slices.Clone(models)
	payload := map[string]any{
		"bundleVersion": 1,
		"schemaVersion": SchemaVersion,
		"systemPrompt":  llm.SystemPrompt,
		"userTemplate":  llm.BuildUserContent("{sender}", "{content}", "{currency}"),
		"models":        models,
		"jsonSchema":    llm.JSONSchema,
	}

	body, err := json.Marshal(payload)
	if err != nil {
		panic("bundle payload marshal failed: " + err.Error())
	}

	hash := sha256.Sum256(body)
	etag := `"` + hex.EncodeToString(hash[:8]) + `"`

	return &BundleHandler{
		body: body,
		etag: etag,
	}
}

// Bundle serves the precomputed prompt bundle. Sets ETag and Cache-Control on
// every response. Returns 304 on a matching If-None-Match; otherwise returns
// the full payload with 200.
func (h *BundleHandler) Bundle(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("ETag", h.etag)
	w.Header().Set("Cache-Control", "public, max-age=86400")

	if r.Header.Get("If-None-Match") == h.etag {
		w.WriteHeader(http.StatusNotModified)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	w.Write(h.body)
}
