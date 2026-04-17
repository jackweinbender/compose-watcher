# compose-watcher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Linux daemon that watches a directory for Docker Compose file changes and runs `docker compose up/down` in response, for use in PR preview environments.

**Architecture:** A Go binary with three internal packages — `project` (name derivation), `compose` (docker CLI shims), and `watcher` (Linux inotify wrapper) — wired together in `main.go` which handles startup scan, event loop with per-file debounce, and graceful shutdown.

**Tech Stack:** Go 1.21+, standard library only (`log/slog`, `syscall` for inotify, `os/exec` for docker CLI); Linux-only binary due to inotify.

---

## File Map

| File | Responsibility |
|---|---|
| `go.mod` | Module definition |
| `internal/project/project.go` | `NameFromPath()` — derive project name from file path |
| `internal/project/project_test.go` | Table-driven tests for name derivation |
| `internal/compose/compose.go` | `Upsert()`, `Cleanup()`, `Prune()` — docker CLI wrappers with injectable runner |
| `internal/compose/compose_test.go` | Tests verifying correct CLI arguments |
| `internal/watcher/watcher.go` | Linux inotify wrapper — recursive watching, event channel (`//go:build linux`) |
| `internal/watcher/watcher_test.go` | Integration test (linux build tag, uses temp dir) |
| `scan.go` | `startupScan()`, `envOr()` — no build tag, testable on macOS |
| `scan_test.go` | `TestStartupScan` — no build tag, runs on macOS |
| `main.go` | `main()`, `runLoop()` — `//go:build linux` (imports watcher which is linux-only) |
| `README.md` | Build, install, systemd, configuration, GitHub Actions integration |

> **Why the split:** `internal/watcher` carries `//go:build linux` because it uses inotify syscalls. `main.go` imports it, so it must also carry `//go:build linux`. `scan.go` does not import watcher, so it can be compiled and tested on any platform — enabling `TestStartupScan` to run during local development on macOS.

---

### Task 1: Initialize Go module

**Files:**
- Create: `go.mod`
- Create: `main.go`

- [ ] **Step 1: Create `go.mod`**

```
module github.com/jackweinbender/compose-watcher

go 1.21
```

- [ ] **Step 2: Create stub `main.go`**

```go
package main

func main() {}
```

- [ ] **Step 3: Verify it compiles**

```bash
go build ./...
```

Expected: no output, exit 0.

- [ ] **Step 4: Commit**

```bash
git add go.mod main.go
git commit -m "chore: initialize go module"
```

---

### Task 2: Project name derivation

**Files:**
- Create: `internal/project/project.go`
- Create: `internal/project/project_test.go`

- [ ] **Step 1: Write the failing test**

`internal/project/project_test.go`:
```go
package project_test

import (
	"testing"

	"github.com/jackweinbender/compose-watcher/internal/project"
)

func TestNameFromPath(t *testing.T) {
	tests := []struct {
		watchRoot string
		filePath  string
		want      string
	}{
		{"/etc/compose-stacks", "/etc/compose-stacks/repo-a/pr-123.yml", "repo-a-pr-123"},
		{"/etc/compose-stacks", "/etc/compose-stacks/repo-b/pr-456.yaml", "repo-b-pr-456"},
		{"/etc/compose-stacks", "/etc/compose-stacks/repo-a/_traefik.yml", "repo-a-_traefik"},
		{"/etc/compose-stacks", "/etc/compose-stacks/repo-a/multi.service.yml", "repo-a-multi.service"},
	}
	for _, tt := range tests {
		t.Run(tt.want, func(t *testing.T) {
			got := project.NameFromPath(tt.watchRoot, tt.filePath)
			if got != tt.want {
				t.Errorf("NameFromPath(%q, %q) = %q, want %q", tt.watchRoot, tt.filePath, got, tt.want)
			}
		})
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
go test ./internal/project/...
```

Expected: FAIL — `cannot find package`

- [ ] **Step 3: Write implementation**

`internal/project/project.go`:
```go
package project

import (
	"path/filepath"
	"strings"
)

// NameFromPath derives a unique Docker Compose project name from a file path
// relative to the watch root.
//
// Example: watchRoot=/etc/compose-stacks, file=.../repo-a/pr-123.yml → "repo-a-pr-123"
func NameFromPath(watchRoot, filePath string) string {
	rel, _ := filepath.Rel(watchRoot, filePath)
	dir := filepath.Dir(rel)
	base := filepath.Base(rel)
	ext := filepath.Ext(base)
	stem := strings.TrimSuffix(base, ext)
	if dir == "." {
		return stem
	}
	return dir + "-" + stem
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
go test ./internal/project/...
```

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add internal/project/
git commit -m "feat: add project name derivation"
```

---

### Task 3: Docker compose operations

**Files:**
- Create: `internal/compose/compose.go`
- Create: `internal/compose/compose_test.go`

- [ ] **Step 1: Write the failing tests**

`internal/compose/compose_test.go`:
```go
package compose_test

import (
	"context"
	"io"
	"log/slog"
	"slices"
	"testing"

	"github.com/jackweinbender/compose-watcher/internal/compose"
)

func discardLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

type call struct {
	name string
	args []string
}

func captureRunner(calls *[]call) compose.Runner {
	return func(_ context.Context, name string, args ...string) ([]byte, error) {
		*calls = append(*calls, call{name, args})
		return []byte("ok"), nil
	}
}

func TestUpsert(t *testing.T) {
	var calls []call
	err := compose.Upsert(
		context.Background(),
		"repo-a-pr-123",
		"/etc/compose-stacks/repo-a/pr-123.yml",
		discardLogger(),
		captureRunner(&calls),
	)
	if err != nil {
		t.Fatal(err)
	}
	if len(calls) != 1 {
		t.Fatalf("expected 1 call, got %d", len(calls))
	}
	wantArgs := []string{"compose", "-p", "repo-a-pr-123", "-f", "/etc/compose-stacks/repo-a/pr-123.yml", "up", "-d", "--remove-orphans"}
	if calls[0].name != "docker" || !slices.Equal(calls[0].args, wantArgs) {
		t.Errorf("got docker %v, want docker %v", calls[0].args, wantArgs)
	}
}

func TestCleanup(t *testing.T) {
	var calls []call
	err := compose.Cleanup(
		context.Background(),
		"repo-a-pr-123",
		discardLogger(),
		captureRunner(&calls),
	)
	if err != nil {
		t.Fatal(err)
	}
	if len(calls) != 1 {
		t.Fatalf("expected 1 call, got %d", len(calls))
	}
	wantArgs := []string{"compose", "-p", "repo-a-pr-123", "down", "-v"}
	if calls[0].name != "docker" || !slices.Equal(calls[0].args, wantArgs) {
		t.Errorf("got docker %v, want docker %v", calls[0].args, wantArgs)
	}
}

func TestPrune(t *testing.T) {
	var calls []call
	err := compose.Prune(context.Background(), discardLogger(), captureRunner(&calls))
	if err != nil {
		t.Fatal(err)
	}
	if len(calls) != 3 {
		t.Fatalf("expected 3 prune calls, got %d", len(calls))
	}
	wantCalls := []call{
		{"docker", []string{"image", "prune", "-f"}},
		{"docker", []string{"container", "prune", "-f"}},
		{"docker", []string{"volume", "prune", "-f"}},
	}
	for i, want := range wantCalls {
		if calls[i].name != want.name || !slices.Equal(calls[i].args, want.args) {
			t.Errorf("call[%d]: got %v %v, want %v %v", i, calls[i].name, calls[i].args, want.name, want.args)
		}
	}
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
go test ./internal/compose/...
```

Expected: FAIL — `cannot find package`

- [ ] **Step 3: Write implementation**

`internal/compose/compose.go`:
```go
package compose

import (
	"context"
	"log/slog"
	"os/exec"
	"time"
)

// Runner executes a command and returns combined stdout+stderr output.
// Replaceable in tests to capture invocations without running docker.
type Runner func(ctx context.Context, name string, args ...string) ([]byte, error)

// DefaultRunner executes commands using os/exec.
func DefaultRunner(ctx context.Context, name string, args ...string) ([]byte, error) {
	return exec.CommandContext(ctx, name, args...).CombinedOutput()
}

// Upsert runs `docker compose up -d --remove-orphans` for the given project and file.
// A 5-minute context timeout guards against hung image pulls.
func Upsert(ctx context.Context, projectName, filePath string, logger *slog.Logger, run Runner) error {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Minute)
	defer cancel()
	logger.Info("compose up starting", "project", projectName, "file", filePath)
	out, err := run(ctx, "docker", "compose", "-p", projectName, "-f", filePath, "up", "-d", "--remove-orphans")
	if len(out) > 0 {
		logger.Info("compose up output", "project", projectName, "output", string(out))
	}
	if err != nil {
		logger.Error("compose up failed", "project", projectName, "err", err)
		return err
	}
	logger.Info("compose up complete", "project", projectName)
	return nil
}

// Cleanup runs `docker compose down -v` using only the project name.
// The compose file is not needed — docker uses its own project state metadata.
func Cleanup(ctx context.Context, projectName string, logger *slog.Logger, run Runner) error {
	logger.Info("compose down starting", "project", projectName)
	out, err := run(ctx, "docker", "compose", "-p", projectName, "down", "-v")
	if len(out) > 0 {
		logger.Info("compose down output", "project", projectName, "output", string(out))
	}
	if err != nil {
		logger.Error("compose down failed", "project", projectName, "err", err)
		return err
	}
	logger.Info("compose down complete", "project", projectName)
	return nil
}

// Prune removes dangling images, containers, and volumes.
// Errors are logged but not returned — prune failures are non-fatal.
func Prune(ctx context.Context, logger *slog.Logger, run Runner) error {
	resources := [][]string{
		{"image", "prune", "-f"},
		{"container", "prune", "-f"},
		{"volume", "prune", "-f"},
	}
	for _, args := range resources {
		logger.Info("pruning", "resource", args[0])
		out, err := run(ctx, "docker", args...)
		if len(out) > 0 {
			logger.Info("prune output", "resource", args[0], "output", string(out))
		}
		if err != nil {
			logger.Error("prune failed", "resource", args[0], "err", err)
		}
	}
	return nil
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
go test ./internal/compose/...
```

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add internal/compose/
git commit -m "feat: add docker compose operations"
```

---

### Task 4: inotify watcher

**Files:**
- Create: `internal/watcher/watcher.go`
- Create: `internal/watcher/watcher_test.go`

Note: both files carry `//go:build linux` — they are skipped on macOS during local development. The integration test requires a real filesystem and inotify; it will run in Linux CI.

- [ ] **Step 1: Write the integration test**

`internal/watcher/watcher_test.go`:
```go
//go:build linux

package watcher_test

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/jackweinbender/compose-watcher/internal/watcher"
)

func TestWatcher_UpsertOnCreate(t *testing.T) {
	dir := t.TempDir()
	sub := filepath.Join(dir, "repo-a")
	if err := os.MkdirAll(sub, 0755); err != nil {
		t.Fatal(err)
	}

	w, err := watcher.New(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer w.Close()
	w.Start()

	target := filepath.Join(sub, "pr-123.yml")
	if err := os.WriteFile(target, []byte("version: '3'"), 0644); err != nil {
		t.Fatal(err)
	}

	select {
	case ev := <-w.Events():
		if ev.Kind != watcher.Upsert {
			t.Errorf("want Upsert, got %v", ev.Kind)
		}
		if ev.Path != target {
			t.Errorf("want path %q, got %q", target, ev.Path)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timeout: no event received")
	}
}

func TestWatcher_DeleteOnRemove(t *testing.T) {
	dir := t.TempDir()
	sub := filepath.Join(dir, "repo-a")
	if err := os.MkdirAll(sub, 0755); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(sub, "pr-123.yml")
	if err := os.WriteFile(target, []byte("version: '3'"), 0644); err != nil {
		t.Fatal(err)
	}

	w, err := watcher.New(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer w.Close()
	w.Start()

	// drain any create events from the existing file being stat'd
	time.Sleep(50 * time.Millisecond)

	if err := os.Remove(target); err != nil {
		t.Fatal(err)
	}

	select {
	case ev := <-w.Events():
		if ev.Kind != watcher.Delete {
			t.Errorf("want Delete, got %v", ev.Kind)
		}
		if ev.Path != target {
			t.Errorf("want path %q, got %q", target, ev.Path)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timeout: no event received")
	}
}

func TestWatcher_IgnoresNonYaml(t *testing.T) {
	dir := t.TempDir()

	w, err := watcher.New(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer w.Close()
	w.Start()

	if err := os.WriteFile(filepath.Join(dir, "readme.txt"), []byte("hello"), 0644); err != nil {
		t.Fatal(err)
	}

	select {
	case ev := <-w.Events():
		t.Errorf("unexpected event for non-yaml file: %+v", ev)
	case <-time.After(200 * time.Millisecond):
		// correct: no event
	}
}
```

- [ ] **Step 2: Verify test compiles but is skipped on macOS**

```bash
go test ./internal/watcher/...
```

Expected on macOS: `[no test files]` or build skipped. On Linux: FAIL (no package yet).

- [ ] **Step 3: Write watcher implementation**

`internal/watcher/watcher.go`:
```go
//go:build linux

package watcher

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"unsafe"
)

// EventKind distinguishes file upsert from file deletion.
type EventKind int

const (
	Upsert EventKind = iota
	Delete
)

// Event carries the kind and absolute path of a changed .yml/.yaml file.
type Event struct {
	Kind EventKind
	Path string
}

// Watcher wraps a Linux inotify file descriptor with recursive directory support.
type Watcher struct {
	fd        int
	mu        sync.Mutex
	wds       map[int32]string // watch descriptor → absolute directory path
	dirs      map[string]int32 // absolute directory path → watch descriptor
	watchRoot string
	events    chan Event
	done      chan struct{}
}

const watchMask = syscall.IN_CLOSE_WRITE | syscall.IN_MOVED_TO | syscall.IN_CREATE | syscall.IN_DELETE

// New creates a Watcher rooted at watchRoot. It adds watches for watchRoot and
// all immediate subdirectories that exist at creation time.
func New(watchRoot string) (*Watcher, error) {
	fd, err := syscall.InotifyInit()
	if err != nil {
		return nil, err
	}
	w := &Watcher{
		fd:        fd,
		wds:       make(map[int32]string),
		dirs:      make(map[string]int32),
		watchRoot: watchRoot,
		events:    make(chan Event, 64),
		done:      make(chan struct{}),
	}
	if err := w.addWatch(watchRoot); err != nil {
		syscall.Close(fd)
		return nil, err
	}
	entries, _ := os.ReadDir(watchRoot)
	for _, e := range entries {
		if e.IsDir() {
			_ = w.addWatch(filepath.Join(watchRoot, e.Name()))
		}
	}
	return w, nil
}

func (w *Watcher) addWatch(dir string) error {
	wd, err := syscall.InotifyAddWatch(w.fd, dir, watchMask)
	if err != nil {
		return err
	}
	w.mu.Lock()
	w.wds[int32(wd)] = dir
	w.dirs[dir] = int32(wd)
	w.mu.Unlock()
	return nil
}

// Events returns the channel on which file events are delivered.
func (w *Watcher) Events() <-chan Event {
	return w.events
}

// Start begins reading inotify events in a background goroutine.
func (w *Watcher) Start() {
	go w.readLoop()
}

// Close stops the watcher and closes the inotify fd.
func (w *Watcher) Close() {
	close(w.done)
	syscall.Close(w.fd)
}

// bufSize accommodates up to 128 events in one read.
const bufSize = (syscall.SizeofInotifyEvent + syscall.NAME_MAX + 1) * 128

func (w *Watcher) readLoop() {
	buf := make([]byte, bufSize)
	for {
		n, err := syscall.Read(w.fd, buf)
		if err != nil || n == 0 {
			return
		}
		offset := 0
		for offset+syscall.SizeofInotifyEvent <= n {
			raw := (*syscall.InotifyEvent)(unsafe.Pointer(&buf[offset]))
			nameLen := int(raw.Len)
			nameStart := offset + syscall.SizeofInotifyEvent
			if nameStart+nameLen > n {
				break
			}

			var name string
			if nameLen > 0 {
				name = strings.TrimRight(string(buf[nameStart:nameStart+nameLen]), "\x00")
			}
			offset = nameStart + nameLen

			w.mu.Lock()
			dir, ok := w.wds[raw.Wd]
			w.mu.Unlock()
			if !ok {
				continue
			}

			// New subdirectory — add a watch for it.
			if raw.Mask&syscall.IN_ISDIR != 0 && raw.Mask&syscall.IN_CREATE != 0 && name != "" {
				_ = w.addWatch(filepath.Join(dir, name))
				continue
			}

			if name == "" {
				continue
			}

			ext := strings.ToLower(filepath.Ext(name))
			if ext != ".yml" && ext != ".yaml" {
				continue
			}

			fullPath := filepath.Join(dir, name)

			var kind EventKind
			switch {
			case raw.Mask&syscall.IN_DELETE != 0:
				kind = Delete
			case raw.Mask&(syscall.IN_CLOSE_WRITE|syscall.IN_MOVED_TO|syscall.IN_CREATE) != 0:
				kind = Upsert
			default:
				continue
			}

			select {
			case w.events <- Event{Kind: kind, Path: fullPath}:
			case <-w.done:
				return
			}
		}
	}
}
```

- [ ] **Step 4: Verify it compiles**

```bash
GOOS=linux go build ./internal/watcher/...
```

Expected: no output, exit 0.

- [ ] **Step 5: Commit**

```bash
git add internal/watcher/
git commit -m "feat: add linux inotify watcher"
```

---

### Task 5: Main program

**Files:**
- Create: `scan.go`
- Create: `scan_test.go`
- Modify: `main.go`

- [ ] **Step 1: Write test for startupScan**

`scan_test.go`:
```go
package main

import (
	"context"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"testing"

	"github.com/jackweinbender/compose-watcher/internal/compose"
)

func TestStartupScan(t *testing.T) {
	dir := t.TempDir()
	sub := filepath.Join(dir, "repo-a")
	if err := os.MkdirAll(sub, 0755); err != nil {
		t.Fatal(err)
	}
	files := []string{
		filepath.Join(sub, "_traefik.yml"),
		filepath.Join(sub, "pr-123.yml"),
	}
	for _, f := range files {
		if err := os.WriteFile(f, []byte(""), 0644); err != nil {
			t.Fatal(err)
		}
	}
	// Also write a non-yaml file that should be ignored.
	if err := os.WriteFile(filepath.Join(sub, "notes.txt"), []byte(""), 0644); err != nil {
		t.Fatal(err)
	}

	var upserted []string
	mockRun := func(_ context.Context, name string, args ...string) ([]byte, error) {
		// capture the -f argument (the file path)
		for i, a := range args {
			if a == "-f" && i+1 < len(args) {
				upserted = append(upserted, args[i+1])
			}
		}
		return nil, nil
	}

	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	if err := startupScan(context.Background(), dir, logger, mockRun); err != nil {
		t.Fatal(err)
	}

	sort.Strings(upserted)
	sort.Strings(files)
	if !slices.Equal(upserted, files) {
		t.Errorf("upserted %v, want %v", upserted, files)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
go test -run TestStartupScan .
```

Expected: FAIL — `undefined: startupScan`

- [ ] **Step 3: Create `scan.go`**

`scan.go` (no build tag — compiles and tests on all platforms):
```go
package main

import (
	"context"
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"
	"strings"

	"github.com/jackweinbender/compose-watcher/internal/compose"
	"github.com/jackweinbender/compose-watcher/internal/project"
)

func startupScan(ctx context.Context, watchRoot string, logger *slog.Logger, run compose.Runner) error {
	return filepath.WalkDir(watchRoot, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}
		ext := strings.ToLower(filepath.Ext(path))
		if ext != ".yml" && ext != ".yaml" {
			return nil
		}
		name := project.NameFromPath(watchRoot, path)
		logger.Info("startup: upserting stack", "project", name, "file", path)
		return compose.Upsert(ctx, name, path, logger, run)
	})
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
```

- [ ] **Step 4: Run the startup scan test**

```bash
go test -run TestStartupScan .
```

Expected: PASS

- [ ] **Step 5: Write `main.go` with linux build tag**

`main.go`:
```go
//go:build linux

package main

import (
	"context"
	"flag"
	"log/slog"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"github.com/jackweinbender/compose-watcher/internal/compose"
	"github.com/jackweinbender/compose-watcher/internal/project"
	"github.com/jackweinbender/compose-watcher/internal/watcher"
)

func main() {
	watchDir := flag.String("watch-dir", envOr("WATCH_DIR", "/etc/compose-stacks"), "root directory to watch recursively")
	logFormat := flag.String("log-format", envOr("LOG_FORMAT", "json"), "log format: json or text")
	flag.Parse()

	var handler slog.Handler
	if *logFormat == "text" {
		handler = slog.NewTextHandler(os.Stdout, nil)
	} else {
		handler = slog.NewJSONHandler(os.Stdout, nil)
	}
	logger := slog.New(handler)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	logger.Info("starting compose-watcher", "watch-dir", *watchDir)

	if err := startupScan(ctx, *watchDir, logger, compose.DefaultRunner); err != nil {
		logger.Error("startup scan failed", "err", err)
	}

	w, err := watcher.New(*watchDir)
	if err != nil {
		logger.Error("failed to initialize watcher", "err", err)
		os.Exit(1)
	}
	defer w.Close()
	w.Start()

	logger.Info("watching for changes", "dir", *watchDir)
	runLoop(ctx, w, *watchDir, logger, compose.DefaultRunner)
	logger.Info("shutting down")
}

func runLoop(ctx context.Context, w *watcher.Watcher, watchRoot string, logger *slog.Logger, run compose.Runner) {
	pending := map[string]*time.Timer{}
	var mu sync.Mutex

	for {
		select {
		case <-ctx.Done():
			return
		case event, ok := <-w.Events():
			if !ok {
				return
			}
			switch event.Kind {
			case watcher.Upsert:
				mu.Lock()
				if t, ok := pending[event.Path]; ok {
					t.Stop()
				}
				path := event.Path
				pending[path] = time.AfterFunc(500*time.Millisecond, func() {
					mu.Lock()
					delete(pending, path)
					mu.Unlock()
					name := project.NameFromPath(watchRoot, path)
					logger.Info("file upserted", "path", path, "project", name)
					if err := compose.Upsert(ctx, name, path, logger, run); err != nil {
						logger.Error("upsert failed", "path", path, "err", err)
					}
				})
				mu.Unlock()

			case watcher.Delete:
				mu.Lock()
				if t, ok := pending[event.Path]; ok {
					t.Stop()
					delete(pending, event.Path)
				}
				mu.Unlock()
				path := event.Path
				name := project.NameFromPath(watchRoot, path)
				logger.Info("file deleted", "path", path, "project", name)
				if err := compose.Cleanup(ctx, name, logger, run); err != nil {
					logger.Error("cleanup failed", "path", path, "err", err)
				}
				if err := compose.Prune(ctx, logger, run); err != nil {
					logger.Error("prune failed", "err", err)
				}
			}
		}
	}
}
```

- [ ] **Step 6: Verify cross-compile to Linux**

```bash
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o compose-watcher .
```

Expected: produces `compose-watcher` binary, exit 0.

- [ ] **Step 7: Commit**

```bash
git add main.go scan.go scan_test.go
git commit -m "feat: add main entry point with startup scan and event loop"
```

---

### Task 6: README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Write README**

`README.md`:
```markdown
# compose-watcher

A lightweight Linux daemon that manages Docker Compose stacks by watching a directory for file changes. Designed for PR preview environments: drop a compose file on the server to spin up a stack, remove it to tear it down.

## How it works

- **File created or modified** → `docker compose up -d --remove-orphans`
- **File deleted** → `docker compose down -v` → prune dangling images, containers, and volumes

The daemon watches a directory tree recursively using Linux inotify. Subdirectories provide per-repo namespace isolation. Project names are derived from the directory and file name:

```
/etc/compose-stacks/repo-a/pr-123.yml  →  project: repo-a-pr-123
```

On startup the daemon scans the watch root and runs `compose up` on all existing `.yml`/`.yaml` files, making restarts idempotent.

## Requirements

- Linux (uses inotify)
- Docker with Compose V2 (`docker compose` subcommand)

## Build

Requires Go 1.21+. Cross-compile from macOS or Linux:

```bash
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o compose-watcher .
```

## Install

```bash
sudo install -m 755 compose-watcher /usr/local/bin/compose-watcher
```

## Configuration

| Flag | Environment variable | Default | Description |
|---|---|---|---|
| `--watch-dir` | `WATCH_DIR` | `/etc/compose-stacks` | Root directory to watch recursively |
| `--log-format` | `LOG_FORMAT` | `json` | `json` or `text` |

## systemd setup

Create the watch directory:

```bash
sudo mkdir -p /etc/compose-stacks
```

Create the unit file at `/etc/systemd/system/compose-watcher.service`:

```ini
[Unit]
Description=compose-watcher
After=docker.service
Requires=docker.service

[Service]
ExecStart=/usr/local/bin/compose-watcher --watch-dir=/etc/compose-stacks
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
```

Enable and start:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now compose-watcher
sudo journalctl -fu compose-watcher
```

## Directory structure

```
/etc/compose-stacks/
├── repo-a/
│   ├── _traefik.yml       ← stable infra (underscore prefix is a convention only)
│   └── pr-123.yml         ← ephemeral PR preview
└── repo-b/
    ├── _traefik.yml
    └── pr-456.yml
```

The daemon treats all `.yml`/`.yaml` files identically regardless of name prefix.

## GitHub Actions integration

### Deploy preview (PR opened / pushed)

```yaml
- name: Deploy preview
  run: |
    envsubst < deploy/preview.yml.tmpl > pr-${{ github.event.pull_request.number }}.yml
    scp pr-${{ github.event.pull_request.number }}.yml \
        user@server:/etc/compose-stacks/${{ github.event.repository.name }}/
```

### Tear down preview (PR closed / merged)

```yaml
- name: Tear down preview
  run: |
    ssh user@server \
        rm /etc/compose-stacks/${{ github.event.repository.name }}/pr-${{ github.event.pull_request.number }}.yml
```

## Logging

All output is structured JSON by default (use `--log-format=text` for human-readable logs during development). Docker CLI output is captured and included in log entries. Example:

```json
{"time":"...","level":"INFO","msg":"compose up complete","project":"repo-a-pr-123"}
{"time":"...","level":"INFO","msg":"file deleted","path":"/etc/compose-stacks/repo-a/pr-123.yml","project":"repo-a-pr-123"}
```
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add installation and systemd setup guide"
```

---

### Task 7: Run full test suite

- [ ] **Step 1: Run all tests (macOS)**

```bash
go test ./...
```

Expected: all non-linux-tagged tests pass. Watcher package shows `[no test files]` on macOS — that is correct.

- [ ] **Step 2: Run tests with race detector**

```bash
go test -race ./...
```

Expected: PASS with no data race warnings.

- [ ] **Step 3: Verify Linux cross-compile**

```bash
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o compose-watcher .
file compose-watcher
```

Expected: `compose-watcher: ELF 64-bit LSB executable, x86-64, statically linked`

- [ ] **Step 4: Commit**

```bash
git add .
git commit -m "chore: verify full test suite and cross-compile"
```
