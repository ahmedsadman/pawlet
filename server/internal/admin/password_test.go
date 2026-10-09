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
	const (
		salt16 = "c3Nzc3Nzc3Nzc3Nzc3Nzcw"                          // 16 's' bytes
		key32  = "a2tra2tra2tra2tra2tra2tra2tra2tra2tra2tra2tra2s" // 32 'k' bytes
		key16  = "a2tra2tra2tra2tra2traw"                          // 16 'k' bytes
		key1   = "YQ"                                              // 1 byte
		salt1  = "YQ"                                              // 1 byte
		salt4  = "c2FsdA"                                          // 4 bytes
	)
	for _, bad := range []string{
		"", "plain", "$argon2i$v=19$m=65536,t=2,p=1$" + salt16 + "$" + key32,
		"$argon2id$v=18$m=65536,t=2,p=1$" + salt16 + "$" + key32,
		"$argon2id$v=19$m=0,t=2,p=1$" + salt16 + "$" + key32,
		"$argon2id$v=19$m=65536,t=2,p=1$!!$" + key32,
		"$argon2id$v=19$m=65536,t=2,p=1$" + salt16 + "$",
		"$argon2id$v=19junk$m=65536,t=2,p=1$" + salt16 + "$" + key32,
		"$argon2id$v=19$m=65536,t=2,p=1xyz$" + salt16 + "$" + key32,
		"$argon2id$v=19$m= 65536,t=2,p=1$" + salt16 + "$" + key32,
		"$argon2id$v=19$m=2000000,t=2,p=1$" + salt16 + "$" + key32,
		"$argon2id$v=19$m=1,t=1$" + salt16 + "$" + key32,
		"$argon2id$v=19$m=65536,t=2,p=1$" + salt1 + "$" + key32,
		"$argon2id$v=19$m=65536,t=2,p=1$" + salt16 + "$" + key1,
		"$argon2id$v=19$m=100,t=2,p=1$" + salt16 + "$" + key32,
		"$argon2id$v=19$m=65536,t=0,p=1$" + salt16 + "$" + key32,
		"$argon2id$v=19$m=65536,t=20,p=1$" + salt16 + "$" + key32,
		"$argon2id$v=19$m=65536,t=2,p=20$" + salt16 + "$" + key32,
		"$argon2id$v=19$m=19455,t=2,p=1$" + salt16 + "$" + key32,
		"$argon2id$v=19$m=1048577,t=2,p=1$" + salt16 + "$" + key32,
		"$argon2id$v=19$m=65536,t=11,p=1$" + salt16 + "$" + key32,
		"$argon2id$v=19$m=65536,t=2,p=17$" + salt16 + "$" + key32,
		"$argon2id$v=19$m=65536,t=2,p=1$" + salt4 + "$" + key32,
		"$argon2id$v=19$m=65536,t=2,p=1$" + salt16 + "$YWFhYWFhYWFhYWFhYWFh",
		"$argon2id$v=19$m=65536,t=2,p=1$" + salt16 + "$YWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWE",
	} {
		if _, err := VerifyPassword(bad, "x"); !errors.Is(err, ErrBadHash) {
			t.Errorf("VerifyPassword(%q) err = %v, want ErrBadHash", bad, err)
		}
	}
}

func TestVerifyPasswordAcceptsEdgeCases(t *testing.T) {
	const (
		salt16 = "c3Nzc3Nzc3Nzc3Nzc3Nzcw"                                                                 // 16 's' bytes
		key16  = "a2tra2tra2tra2tra2traw"                                                                 // 16 'k' bytes
		key64  = "a2tra2tra2tra2tra2tra2tra2tra2tra2tra2tra2tra2tra2tra2tra2tra2tra2tra2tra2tra2tra2traw" // 64 'k' bytes
	)
	cases := []string{
		"$argon2id$v=19$m=19456,t=2,p=1$" + salt16 + "$" + key16,
		"$argon2id$v=19$m=1048576,t=2,p=1$" + salt16 + "$" + key16,
		"$argon2id$v=19$m=65536,t=1,p=1$" + salt16 + "$" + key16,
		"$argon2id$v=19$m=65536,t=10,p=1$" + salt16 + "$" + key16,
		"$argon2id$v=19$m=65536,t=2,p=16$" + salt16 + "$" + key16,
		"$argon2id$v=19$m=65536,t=2,p=1$" + salt16 + "$" + key16,
		"$argon2id$v=19$m=65536,t=2,p=1$" + salt16 + "$" + key64,
	}
	for _, h := range cases {
		if _, err := parsePHC(h); err != nil {
			t.Errorf("parsePHC(%q) err = %v, want nil", h, err)
		}
	}
}
