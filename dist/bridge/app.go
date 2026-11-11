package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
)

// App owns the bridge's lifetime while the store may be locked. whatsmeow is
// only constructed once a key is available, so a cancelled pinentry prompt
// leaves the process alive but with no database handle and no key in memory.
type App struct {
	ctx    context.Context
	dir    string
	out    *Writer
	enc    EncryptionConfig
	unlock sync.Mutex

	mu        sync.Mutex
	wa        *WA
	unlockErr string
	closed    bool
}

func NewApp(ctx context.Context, dir string, out *Writer, enc EncryptionConfig) *App {
	return &App{ctx: ctx, dir: dir, out: out, enc: enc}
}

// Open decrypts the store key and opens whatsmeow. It is safe to call again
// after a failed or cancelled unlock.
func (a *App) Open(ctx context.Context) error {
	a.unlock.Lock()
	defer a.unlock.Unlock()

	a.mu.Lock()
	if a.closed {
		a.mu.Unlock()
		return errors.New("bridge is shutting down")
	}
	if a.wa != nil {
		a.mu.Unlock()
		return nil
	}
	a.mu.Unlock()

	key, err := storeKey(ctx, a.enc, a.dir)
	if err != nil {
		a.setUnlockErr(err)
		return err
	}
	wa, err := NewWA(ctx, a.dir, a.out, key)
	zero(key)
	if err != nil {
		a.setUnlockErr(err)
		return err
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.closed {
		wa.Disconnect()
		return errors.New("bridge is shutting down")
	}
	a.wa = wa
	a.unlockErr = ""
	return nil
}

func (a *App) setUnlockErr(err error) {
	a.mu.Lock()
	a.unlockErr = err.Error()
	a.mu.Unlock()
}

func (a *App) current() (*WA, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.wa == nil {
		if a.unlockErr != "" {
			return nil, fmt.Errorf("store is locked: %s", a.unlockErr)
		}
		return nil, errors.New("store is locked; run :WhatsApp unlock")
	}
	return a.wa, nil
}

func (a *App) Status() map[string]interface{} {
	a.mu.Lock()
	defer a.mu.Unlock()
	st := map[string]interface{}{
		"store":     a.dir,
		"encrypted": a.enc.Mode == "gpg",
		"locked":    a.wa == nil,
	}
	if a.unlockErr != "" {
		st["error"] = a.unlockErr
	}
	if a.wa != nil {
		for k, v := range a.wa.Status() {
			st[k] = v
		}
	}
	return st
}

// Connect attaches the opened device. A fresh store has no device yet, so the
// editor gets "unpaired" and can show the QR flow.
func (a *App) Connect(ctx context.Context) error {
	wa, err := a.current()
	if err != nil {
		return err
	}
	return wa.Connect(ctx)
}

func (a *App) Unlock(ctx context.Context) error {
	if err := a.Open(ctx); err != nil {
		return err
	}
	// The store is open even if the network is down; report the connection
	// failure as an event so the editor does not keep showing "locked".
	if err := a.Connect(ctx); err != nil {
		a.out.Emit("error", map[string]string{"error": err.Error()})
	}
	return nil
}

// Logout unlinks the device and wipes every file that could contain the
// session: the SQLCipher databases, their WAL/SHM/journal side files, the
// wrapped key, and downloaded media.
func (a *App) Logout(ctx context.Context) error {
	wa, err := a.current()
	if err != nil {
		// A locked store cannot tell the phone to unlink this device, but the
		// user may need to abandon it (for example a plaintext store that was
		// opened with encryption enabled). Wipe locally and say so.
		if wipeErr := wipeStore(a.dir, keyPath(a.enc, a.dir)); wipeErr != nil {
			return fmt.Errorf("%v; wipe store: %w", err, wipeErr)
		}
		a.mu.Lock()
		a.unlockErr = ""
		a.mu.Unlock()
		return errors.New("local store wiped; this device may still be listed on your phone")
	}
	remoteErr := wa.Logout(ctx)
	wa.Disconnect()
	a.mu.Lock()
	a.wa = nil
	a.unlockErr = ""
	a.mu.Unlock()
	wipeErr := wipeStore(a.dir, keyPath(a.enc, a.dir))
	if remoteErr != nil && wipeErr != nil {
		return fmt.Errorf("%v; wipe store: %w", remoteErr, wipeErr)
	}
	if remoteErr != nil {
		return remoteErr
	}
	return wipeErr
}

func (a *App) Close() {
	a.mu.Lock()
	a.closed = true
	wa := a.wa
	a.wa = nil
	a.mu.Unlock()
	if wa != nil {
		wa.Disconnect()
	}
}

func wipeStore(dir string, keyFiles ...string) error {
	var first error
	files := []string{
		"session.db", "session.db-wal", "session.db-shm", "session.db-journal",
		"messages.db", "messages.db-wal", "messages.db-shm", "messages.db-journal",
		"session.key.gpg",
	}
	files = append(files, keyFiles...)
	for _, name := range files {
		path := name
		if !filepath.IsAbs(path) {
			path = filepath.Join(dir, name)
		}
		if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) && first == nil {
			first = err
		}
	}
	if err := os.RemoveAll(filepath.Join(dir, "media")); err != nil && first == nil {
		first = err
	}
	return first
}
