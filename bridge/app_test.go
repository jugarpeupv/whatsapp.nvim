package main

import (
	"context"
	"io"
	"testing"
)

func TestAppStartsLockedWhenKeyIsUnavailable(t *testing.T) {
	app := NewApp(context.Background(), t.TempDir(), NewWriter(io.Discard), EncryptionConfig{
		Mode: "gpg", GPGKey: "missing", Program: "false",
	})
	t.Cleanup(app.Close)
	if err := app.Open(context.Background()); err == nil {
		t.Fatal("open succeeded with an unusable key provider")
	}
	st := app.Status()
	if st["locked"] != true || st["encrypted"] != true || st["error"] == nil {
		t.Fatalf("status after failed unlock: %#v", st)
	}
}
