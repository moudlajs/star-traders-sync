package cli

import (
	"os"
	"os/signal"
	"sync"

	"github.com/moudlajs/star-traders-sync/internal/platform"
	"github.com/moudlajs/star-traders-sync/internal/transfer"
)

// exiter is the script's EXIT trap: undo hooks run on exit or a signal (exit 128+N), after any swap in flight.
type exiter struct {
	mu    sync.Mutex
	hooks []func()
	guard *transfer.Guard
	// exiting has one owner: a hub lock released over ssh is cut off, and leaked, if the process exits under it.
	exiting sync.Mutex
}

// finish runs the idempotent hooks on every way out, as the script's on_exit does.
func (e *exiter) finish() {
	e.exiting.Lock()
	e.run()
}

func (e *exiter) add(h func()) {
	e.mu.Lock()
	e.hooks = append(e.hooks, h)
	e.mu.Unlock()
}

func (e *exiter) setGuard(g *transfer.Guard) {
	e.mu.Lock()
	e.guard = g
	e.mu.Unlock()
}

func (e *exiter) run() {
	e.mu.Lock()
	hooks := append([]func(){}, e.hooks...)
	e.mu.Unlock()
	for i := len(hooks) - 1; i >= 0; i-- {
		hooks[i]()
	}
}

func (e *exiter) watch() func() {
	ch := make(chan os.Signal, 1)
	for sig := range platform.ExitSignals {
		signal.Notify(ch, sig)
	}
	done := make(chan struct{})
	go func() {
		select {
		case sig := <-ch:
			code := platform.ExitSignals[sig]
			out := func() {
				e.exiting.Lock() // never unlocked: this path ends the process
				e.run()
				os.Exit(code)
			}
			e.mu.Lock()
			g := e.guard
			e.mu.Unlock()
			if g != nil {
				g.Interrupt(out)
			} else {
				out()
			}
		case <-done:
		}
	}()
	return func() { signal.Stop(ch); close(done) }
}
