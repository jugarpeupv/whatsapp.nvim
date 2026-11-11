package main

import (
	"bytes"
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestResolveGPGKey(t *testing.T) {
	t.Setenv(gpgFingerprintEnv, "  ENV-FPR  ")
	if got := resolveGPGKey(""); got != "ENV-FPR" {
		t.Fatalf("env fingerprint: %q", got)
	}
	if got := resolveGPGKey(" CONFIG-FPR "); got != "CONFIG-FPR" {
		t.Fatalf("config should win: %q", got)
	}
	t.Setenv(gpgFingerprintEnv, "")
	if got := resolveGPGKey(""); got != "" {
		t.Fatalf("empty env: %q", got)
	}
}

func TestSQLCipherStoreRoundTrip(t *testing.T) {
	dir := t.TempDir()
	key := bytes.Repeat([]byte{7}, 32)
	path := filepath.Join(dir, "messages.db")

	s, err := OpenStore(path, key)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.UpsertChat("a@s.whatsapp.net", "Alice", false, 1); err != nil {
		t.Fatal(err)
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}

	head, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.HasPrefix(head, sqliteHeader) {
		t.Fatal("database was written as plaintext SQLite")
	}

	s, err = OpenStore(path, key)
	if err != nil {
		t.Fatal(err)
	}
	chats, err := s.ListChats()
	if err != nil {
		t.Fatal(err)
	}
	if len(chats) != 1 || chats[0].Name != "Alice" {
		t.Fatalf("round trip lost data: %+v", chats)
	}
	s.Close()

	if _, err := OpenStore(path, bytes.Repeat([]byte{8}, 32)); err == nil {
		t.Fatal("wrong key opened the database")
	}
}

func TestStoreKeyModes(t *testing.T) {
	dir := t.TempDir()
	key, err := storeKey(context.Background(), EncryptionConfig{Mode: "none"}, dir)
	if err != nil || key != nil {
		t.Fatalf("plaintext store: key=%v err=%v", key, err)
	}

	if err := os.WriteFile(filepath.Join(dir, "session.db"), sqliteHeader, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := storeKey(context.Background(), EncryptionConfig{Mode: "gpg", GPGKey: "x"}, dir); err == nil ||
		!strings.Contains(err.Error(), "not encrypted") {
		t.Fatalf("plaintext store with encryption did not fail clearly: %v", err)
	}
}

func TestWipeStore(t *testing.T) {
	dir := t.TempDir()
	for _, name := range []string{"session.db", "session.db-wal", "messages.db", "session.key.gpg"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.MkdirAll(filepath.Join(dir, "media", "chat"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := wipeStore(dir); err != nil {
		t.Fatal(err)
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatalf("store not wiped: %v", entries)
	}
}

func TestGPGKeyCreateAndDecrypt(t *testing.T) {
	gpg, err := exec.LookPath("gpg")
	if err != nil {
		t.Skip("gpg not installed")
	}
	// gpg-agent's socket path has a short limit; t.TempDir() paths on macOS
	// are long enough to break the agent, so use a compact temporary home.
	home, err := os.MkdirTemp("", "wakey-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = exec.Command(gpg, "--homedir", home, "--quiet", "--kill", "gpg-agent").Run()
		_ = os.RemoveAll(home)
	})
	env := append(os.Environ(), "GNUPGHOME="+home)
	gen := exec.Command(gpg, "--batch", "--passphrase", "", "--quick-gen-key",
		"wa-bridge test <wa-bridge@example.invalid>", "default", "default", "never")
	gen.Env = env
	if out, err := gen.CombinedOutput(); err != nil {
		t.Skipf("cannot create test GPG key: %v: %s", err, out)
	}
	list := exec.Command(gpg, "--with-colons", "--list-keys")
	list.Env = env
	out, err := list.Output()
	if err != nil {
		t.Fatal(err)
	}
	var fingerprint string
	for _, line := range strings.Split(string(out), "\n") {
		fields := strings.Split(line, ":")
		if len(fields) > 9 && fields[0] == "fpr" {
			fingerprint = fields[9]
			break
		}
	}
	if fingerprint == "" {
		t.Fatal("no fingerprint in gpg output")
	}

	cfg := EncryptionConfig{Mode: "gpg", GPGKey: fingerprint, Program: gpg, Home: home}
	dir := t.TempDir()
	key1, err := storeKey(context.Background(), cfg, dir)
	if err != nil {
		t.Fatal(err)
	}
	keyFile := filepath.Join(dir, "session.key.gpg")
	if info, err := os.Stat(keyFile); err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("key file mode: %v %v", info, err)
	}
	s, err := OpenStore(filepath.Join(dir, "messages.db"), key1)
	if err != nil {
		t.Fatal(err)
	}
	s.Close()
	key2, err := storeKey(context.Background(), cfg, dir)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(key1, key2) {
		t.Fatal("decrypted key differs from the generated key")
	}
	s, err = OpenStore(filepath.Join(dir, "messages.db"), key2)
	if err != nil {
		t.Fatal(err)
	}
	s.Close()
}
