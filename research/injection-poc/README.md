# Poltergeist

A proof-of-concept for **home#60**: control and "see" a macOS app the way Claude
Code Desktop drives the iOS Simulator — but for arbitrary Mac apps, and crucially
**while the screen is locked / asleep / screensaver-on, without moving the real
cursor**.

## The idea

The high-level path (ScreenCaptureKit, CGWindowList, CGEvent) all go through
**WindowServer + the login session** — exactly what a locked screen owns, which is
why an earlier agent couldn't verify its work with the screensaver up. So don't go
through WindowServer at all: **inject a shim into the target process and do capture
+ input entirely in-process.** The app keeps rendering its layer tree in memory and
processing its own event queue regardless of the physical display, so:

- **Capture** = make the app render *itself*: `-[NSView cacheDisplayInRect:toBitmapImageRep:]`
  → PNG. No screenshot API, no Screen-Recording permission, works while locked.
- **Input** ("virtual cursor") = synthesize `NSEvent`s and deliver them to the app's
  own loop via `-[NSApplication postEvent:atStart:]`. The app gets a click/keystroke;
  the **real cursor never moves** and WindowServer is never involved.
- **Describe** (not yet built) = walk the in-process AX/NSView tree — no Accessibility
  permission, because we *are* the app.

This maps 1:1 onto how Claude's sim tool works: the model "sees" via discrete
screenshots + an accessibility describe (the live H.264 video is only for the human
pane). `cacheDisplay` is the discrete-screenshot analog.

## What's here

| File | What |
| --- | --- |
| `poltergeist.m` | the injected shim: main-thread capture timer, a `/tmp/poltergeist.sock` control socket, `shot`/`click`/`type` commands |
| `target.m` | a tiny non-sandboxed AppKit app (editable `NSTextView`) used as the throwaway target |
| `run.sh` | launches the target with `DYLD_INSERT_LIBRARIES=libpoltergeist.dylib` |
| `ctl` | shell one-liner to send a command to the socket |
| `mouseloc.m`, `pixstats.m` | test helpers (real-cursor position; PNG non-black check) |

Build: `clang -dynamiclib -arch arm64e -framework Cocoa -o libpoltergeist.dylib poltergeist.m`
(**arm64e** matters — system binaries are arm64e, and the shim must match to inject).

## Verified (see `/tmp/poltergeist/*.png`)

- **A — baseline capture:** injected shim renders the window to a non-black PNG.
- **B — in-process input:** typed "Hello from Poltergeist" over the socket; it appears
  in the capture; `NSEvent.mouseLocation` was **identical before and after** (real
  cursor never moved).
- **C — screen-off proof:** with the **screensaver running**, the in-process capture
  kept producing the app's real content (`during_saver_inproc.png`), while an external
  `screencapture` at the same moment did **not** contain the app's window
  (`external.png`). Done safely — verified `askForPassword` was off with a 300s lock
  grace before starting the saver, then killed it.

## Findings / caveats

- **DYLD injection works here** (AMFI relaxed) — the shim loaded into **TextEdit**.
  But TextEdit is **App-Sandboxed**, which blocked the shim's `/tmp` writes and its
  socket `bind()`. Injecting into a sandboxed app means writing into *its* container
  and using an in-container/abstract socket. The PoC therefore used a non-sandboxed
  `Target.app`; injecting into arbitrary sandboxed apps is a known next step.
- Must build the shim **arm64e** to match system binaries.
- `cacheDisplay` captures CPU/AppKit drawing. **GPU/remote content** (Metal, video,
  a `WKWebView`'s separate process) won't fully appear — the fallback is reading the
  window's backing **`IOSurface`** (the CAContext remote layer), or injecting the shim
  into the helper process too. Not needed for plain AppKit.
- For an already-running process (vs. launch-time DYLD), injection is `task_for_pid` +
  a remote thread — more code, feasible on this machine.

## Not a shipping tool

Local research PoC only. No networking; the shim writes to `/tmp` and a local socket.
