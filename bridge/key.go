package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

const (
	storePlaintext = iota
	storeEncrypted
	storeMissing
)

const (
	gpgFingerprintEnv = "WHATSAPP_GPG_FINGERPRINT"
	gpgHomeEnv        = "WHATSAPP_GPG_HOME"
)

// resolveGPGKey prefers the explicit config/flag value and falls back to the
// environment. The fingerprint is public; the passphrase never lives here.
func resolveGPGKey(explicit string) string {
	if key := strings.TrimSpace(explicit); key != "" {
		return key
	}
	return strings.TrimSpace(os.Getenv(gpgFingerprintEnv))
}

// resolveGPGHome does the same for the dedicated GNUPGHOME. Shells usually
// expand ~ before exporting, but accept it here too for config values.
func resolveGPGHome(explicit string) string {
	home := strings.TrimSpace(explicit)
	if home == "" {
		home = strings.TrimSpace(os.Getenv(gpgHomeEnv))
	}
	if home == "~" {
		if dir, err := os.UserHomeDir(); err == nil {
			return dir
		}
	}
	if strings.HasPrefix(home, "~/") {
		if dir, err := os.UserHomeDir(); err == nil {
			return filepath.Join(dir, home[2:])
		}
	}
	return home
}

var sqliteHeader = []byte("SQLite format 3\x00")

// EncryptionConfig describes how the store key is protected. The key itself is
// never a passphrase given to SQLCipher: SQLCipher gets a random 32-byte key,
// wrapped by GPG so the private key and its policy (passphrase, smartcard,
// touch) stay the user's decision.
type EncryptionConfig struct {
	Mode    string // "none" or "gpg"
	GPGKey  string // recipient fingerprint
	Program string // defaults to gpg in PATH
	KeyFile string // defaults to <store>/session.key.gpg
	Home    string // optional GNUPGHOME
}

func storeKind(path string) (int, error) {
	f, err := os.Open(path)
	if errors.Is(err, os.ErrNotExist) {
		return storeMissing, nil
	}
	if err != nil {
		return storeMissing, err
	}
	defer f.Close()
	head := make([]byte, len(sqliteHeader))
	n, err := f.Read(head)
	if err != nil && n == 0 {
		return storeMissing, nil
	}
	if bytes.Equal(head[:n], sqliteHeader) {
		return storePlaintext, nil
	}
	return storeEncrypted, nil
}

func fileExists(path string) bool {
	_, err := os.Lstat(path)
	return err == nil
}

func keyPath(cfg EncryptionConfig, dir string) string {
	if cfg.KeyFile != "" {
		return cfg.KeyFile
	}
	return filepath.Join(dir, "session.key.gpg")
}

// storeKey opens the key for this store. A fresh store gets a random key
// encrypted to the configured GPG key; an existing key file is decrypted on
// demand. A plaintext store is never silently converted: the user must log
// out and pair again, which also gives them a clean device on the phone.
func storeKey(ctx context.Context, cfg EncryptionConfig, dir string) ([]byte, error) {
	cfg.GPGKey = resolveGPGKey(cfg.GPGKey)
	cfg.Home = resolveGPGHome(cfg.Home)
	keyFile := keyPath(cfg, dir)
	keyExists := fileExists(keyFile)
	sessionKind, err := storeKind(filepath.Join(dir, "session.db"))
	if err != nil {
		return nil, err
	}
	messageKind, err := storeKind(filepath.Join(dir, "messages.db"))
	if err != nil {
		return nil, err
	}

	switch cfg.Mode {
	case "", "none":
		if keyExists {
			return nil, errors.New("store key file exists; set encryption = 'gpg' to use it")
		}
		if sessionKind == storeEncrypted || messageKind == storeEncrypted {
			return nil, errors.New("store is encrypted; set encryption = 'gpg' to open it")
		}
		return nil, nil
	case "gpg":
		if cfg.GPGKey == "" {
			return nil, fmt.Errorf("encryption = 'gpg' needs gpg.key or %s (fingerprint)", gpgFingerprintEnv)
		}
		if keyExists {
			if sessionKind == storePlaintext || messageKind == storePlaintext {
				return nil, errors.New("store is not encrypted; run :Whatsapp logout and pair again to enable encryption")
			}
			return decryptStoreKey(ctx, cfg, keyFile)
		}
		if sessionKind == storePlaintext || messageKind == storePlaintext {
			return nil, errors.New("store is not encrypted; run :Whatsapp logout and pair again to enable encryption")
		}
		if sessionKind == storeEncrypted || messageKind == storeEncrypted {
			return nil, errors.New("encrypted store is missing session.key.gpg; restore that file or log out and pair again")
		}
		return createStoreKey(ctx, cfg, keyFile)
	default:
		return nil, fmt.Errorf("unknown encryption mode %q (want none or gpg)", cfg.Mode)
	}
}

func createStoreKey(ctx context.Context, cfg EncryptionConfig, path string) ([]byte, error) {
	key := make([]byte, 32)
	if _, err := rand.Read(key); err != nil {
		return nil, fmt.Errorf("generate store key: %w", err)
	}
	args := []string{"--batch", "--yes", "--quiet", "--trust-model", "always"}
	if cfg.Home != "" {
		args = append(args, "--homedir", cfg.Home)
	}
	args = append(args, "--recipient", cfg.GPGKey, "--output", path, "--encrypt")
	cmd := exec.CommandContext(ctx, gpgProgram(cfg), args...)
	cmd.Stdin = bytes.NewReader(key)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		_ = os.Remove(path)
		zero(key)
		return nil, gpgError("encrypt store key", err, stderr)
	}
	restrictFile(path)
	return key, nil
}

func decryptStoreKey(ctx context.Context, cfg EncryptionConfig, path string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()
	// No --batch here: gpg-agent must be free to launch pinentry-mac. Batch
	// mode is for encryption, which only needs the public key.
	args := []string{"--yes", "--quiet"}
	if cfg.Home != "" {
		args = append(args, "--homedir", cfg.Home)
	}
	args = append(args, "--decrypt", "--output", "-", path)
	cmd := exec.CommandContext(ctx, gpgProgram(cfg), args...)
	var out, stderr bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		zero(out.Bytes())
		return nil, gpgError("decrypt store key", err, stderr)
	}
	if out.Len() != 32 {
		zero(out.Bytes())
		return nil, fmt.Errorf("decrypt store key: expected 32 bytes, got %d", out.Len())
	}
	key := append([]byte(nil), out.Bytes()...)
	zero(out.Bytes())
	return key, nil
}

func gpgProgram(cfg EncryptionConfig) string {
	if cfg.Program != "" {
		return cfg.Program
	}
	return "gpg"
}

func gpgError(action string, err error, stderr bytes.Buffer) error {
	msg := strings.TrimSpace(stderr.String())
	if msg == "" {
		return fmt.Errorf("%s: %w", action, err)
	}
	// Keep the useful last line; gpg's warnings can be long.
	lines := strings.Split(msg, "\n")
	return fmt.Errorf("%s: %w: %s", action, err, lines[len(lines)-1])
}

func zero(b []byte) {
	for i := range b {
		b[i] = 0
	}
}
