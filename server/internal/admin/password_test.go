package admin

import (
	"errors"
	"strings"
	"sync"
	"testing"
)

var (
	testHashOnce sync.Once
	testHash     string
)

// hashForTests hashes "correct horse" once; argon2id is deliberately slow.
func hashForTests(t *testing.T) string {
	t.Helper()
	testHashOnce.Do(func() {
		h, err := HashPassword("correct horse")
		if err != nil {
			panic(err)
		}
		testHash = h
	})
	return testHash
}

func TestHashPasswordFormatAndVerify(t *testing.T) {
	h := hashForTests(t)
	if !strings.HasPrefix(h, "$argon2id$v=19$m=65536,t=2,p=1$") {
		t.Fatalf("hash = %q", h)
	}
	ok, err := VerifyPassword(h, "correct horse")
	if err != nil || !ok {
		t.Fatalf("VerifyPassword(right) = %v, %v", ok, err)
	}
	ok, err = VerifyPassword(h, "wrong horse")
	if err != nil || ok {
		t.Fatalf("VerifyPassword(wrong) = %v, %v", ok, err)
	}
}

func TestHashPasswordSaltsEachHash(t *testing.T) {
	a, _ := HashPassword("x")
	b, _ := HashPassword("x")
	if a == b {
		t.Fatal("two hashes of the same password are identical")
	}
}

func TestVerifyPasswordRejectsMalformedHashes(t *testing.T) {
	for _, bad := range []string{
		"", "plain", "$argon2i$v=19$m=65536,t=2,p=1$c2FsdA$a2V5",
		"$argon2id$v=18$m=65536,t=2,p=1$c2FsdA$a2V5",
		"$argon2id$v=19$m=0,t=2,p=1$c2FsdA$a2V5",
		"$argon2id$v=19$m=65536,t=2,p=1$!!$a2V5",
		"$argon2id$v=19$m=65536,t=2,p=1$c2FsdA$",
	} {
		if _, err := VerifyPassword(bad, "x"); !errors.Is(err, ErrBadHash) {
			t.Errorf("VerifyPassword(%q) err = %v, want ErrBadHash", bad, err)
		}
	}
}
