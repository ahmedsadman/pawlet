package main

import (
	"bytes"
	"strings"
	"testing"

	"github.com/ahmedsadman/pawlet/server/internal/admin"
)

func TestHashPasswordCommand(t *testing.T) {
	var out bytes.Buffer
	if err := hashPassword(strings.NewReader("hunter22\n"), &out); err != nil {
		t.Fatalf("hashPassword() error = %v", err)
	}
	hash := strings.TrimSpace(out.String())
	ok, err := admin.VerifyPassword(hash, "hunter22")
	if err != nil || !ok {
		t.Fatalf("printed hash does not verify: %q, %v", hash, err)
	}
	if err := hashPassword(strings.NewReader("\n"), &out); err == nil {
		t.Fatal("empty password accepted")
	}
}
