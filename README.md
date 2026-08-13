# winctl — out-of-process window capture & input (no code injection)

A single compiled CLI that lets an agent (or a human) **screenshot a specific
app window** and **send it keystrokes**, entirely **out-of-process**:

- **No code injection** — no `DYLD_INSERT_LIBRARIES`, no `task_for_pid`. It only
  reads the window server's backing store and posts events to a pid.
- **The fix for "`screencapture` returns only the desktop"** — capture reads the
  target window's backing store directly (SkyLight HW capture), so it returns the
  *actual app window* even when `screencapture` gives you the desktop, and it
  **works under the screensaver / locked screen** (the saver overlay is
  irrelevant — it's not reading the framebuffer).
- **Cursor-free input** — `type`/`key` deliver events via `CGEventPostToPid`
  straight into the target process; the real mouse never moves.

**Harness-independent:** winctl gives *itself* a stable TCC identity
(`com.nscake.winctl`) via self-disclaim and is granted **once**, so it works
the same whether launched from VS Code, Terminal, Ocean, or cron — the calling
host does **not** need Screen Recording / Accessibility. See "Harness
independence" below. Reuses the RE'd techniques from `research/oop`.

Tested on macOS 15.7 (24G222), Apple Silicon, SIP disabled + AMFI relaxed.

## Build

```sh
./build.sh      # compiles + signs with the stable identity (see below)
```

`build.sh` embeds an `Info.plist` (`winctl.plist`) (bundle id `com.nscake.winctl`) into
`__TEXT,__info_plist` and codesigns with **Tanner's Apple Development cert** so
the designated requirement is stable across rebuilds:

```
clang -arch arm64 -fobjc-arc -fmodules -O2 \
  -framework Cocoa -framework ApplicationServices -framework IOSurface -lsqlite3 \
  -sectcreate __TEXT __info_plist winctl.plist -o winctl winctl.m
codesign --force --sign "Apple Development: Tanner Bennett (JWB6AQ4N38)" \
  --identifier com.nscake.winctl winctl
```

Verify the DR is stable (identifier + that leaf cert — **not** an ad-hoc cdhash):

```sh
codesign -dr - winctl
# designated => identifier "com.nscake.winctl" and anchor apple generic and
#   certificate leaf[subject.CN] = "Apple Development: Tanner Bennett (JWB6AQ4N38)" and ...
```

The compiled `winctl` binary is gitignored (rebuild from source). It's
symlinked onto `PATH`:

```sh
ln -sf "$PWD/winctl" /usr/local/bin/winctl
```

Private/obsoleted symbols (SkyLight `SLSHWCaptureWindowList`, the SDK-removed
`CGWindowListCreateImage`) are resolved at runtime with `dlsym`, so nothing
private is linked.

## Usage

```
winctl list [--all] [--json]
winctl shot     <target> <out.png> [--json]
winctl type     <target> <text...>
winctl key      <target> <keyspec>       # return, cmd+s, cmd+shift+4, esc, tab, ...
winctl click    <target> <x> <y>         # coordinate form; OOP, see caveat below
winctl click    <target> --title T [--role R] [--id ID] [--press]   # element form
winctl describe <target> [--actionable] [--role R] [--title T] [--id ID] [--json]
winctl doctor [--json]
```

`<target>` is one of:

| form        | meaning                                                         |
|-------------|-----------------------------------------------------------------|
| `AppName`   | case-insensitive substring of the owner app; picks its largest normal window (falls back to off-screen windows if none are on-screen) |
| `pid:N`     | that process; its largest normal window                         |
| `win:ID`    | that exact `CGWindowID` (from `winctl list`)               |

### Examples

```sh
winctl list                              # find the target window-id/pid
winctl shot Finder /tmp/finder.png       # capture Finder's window
winctl shot win:8541 /tmp/w.png --json   # capture an exact window, JSON out
winctl type TextEdit "hello world"       # type into TextEdit, cursor-free
winctl key  TextEdit return              # press Return
winctl key  TextEdit cmd+s               # ⌘S
winctl describe Safari --actionable      # list clickable controls (role/label/id/frame)
winctl click Safari --title "Reload"     # click the control labelled "Reload"
winctl click Safari --id GoBackButton --press   # AXPress a control by identifier
winctl doctor                            # check TCC grants
```

`shot --json` prints `{"path","width","height","windowId","method","nonblack"}`.
`width/height` are the captured pixels (2× on retina via SkyLight HW capture).

## How the agent uses it

1. `winctl list` → find the target `window-id`/`pid`/app name.
2. `winctl shot <target> /tmp/x.png` → look at the actual window (not the
   desktop; works even with the screen locked).
3. `winctl describe <target> --actionable` → enumerate the clickable controls by
   **role / label / identifier / frame** instead of eyeballing pixels.
4. `winctl click <target> --title "…"` (or `--id`, `--role`, `--press`) → click a
   *specific control*; or `winctl type` / `winctl key` for the focused responder.

## Targeting controls by element (not just coordinates)

`describe` and the element form of `click` read the target's **Accessibility
element tree out of process** (`AXUIElementCreateApplication(pid)` → walk
`kAXChildrenAttribute`) — **no injection**. This is the OOP analog of the sim
tool's `describe`: you address a control by what it *is*, not where it happens to
be.

```sh
winctl describe pid:1234 --actionable        # only elements exposing AXPress
winctl describe pid:1234 --title Save --json  # filter; machine-readable
```

Each node prints `role “label” #identifier [AXPress] @x,y wxh`. Feed a filter
back into `click`:

```sh
winctl click pid:1234 --title "Save"                 # synthetic click at its center
winctl click pid:1234 --role AXButton --title Save   # disambiguate by role
winctl click pid:1234 --id saveButton --press        # invoke AXPress directly
```

- **Default (no `--press`)** resolves the element's on-screen frame and clicks its
  center via the same cursor-free, background-window field-51 path as a coordinate
  click — so it actuates even a non-frontmost window and the real cursor never
  moves. Verified end-to-end against the ground-truth button in `research/hittest`
  (counter incremented via `--title`, `--id`, and `--press` alike).
- **`--press`** calls `AXUIElementPerformAction(el, kAXPressAction)` — the most
  robust option for real controls (no geometry, works even if occluded), at the
  cost of only working for elements that vend an action.

Element targeting needs the **Accessibility** grant on the *responsible* identity
(the same grant `type`/`key`/`click` use — see below). `describe` warns if it's
missing.

## What works, honestly (this machine)

| capability            | mechanism                       | status |
|-----------------------|---------------------------------|--------|
| capture a window      | SkyLight `SLSHWCaptureWindowList` (2× retina) → `CGWindowListCreateImage` fallback | ✅ works, incl. under the screensaver / occluded / off-Space |
| type text             | `CGEventPostToPid` + unicode string | ✅ actuates the focused responder; real cursor unmoved (0 px) |
| key / chord           | `CGEventPostToPid` key + modifier flags | ✅ works (`return`, `cmd+s`, …) |
| **click a control**   | `CGEventPostToPid` mouse events **with window-routing fields + window-local location stamped** | ✅ **actuates a background control** (unlocked session); real cursor unmoved (0 px) |
| **target by element** | OOP `AXUIElement` tree walk → element center click, or `AXPress` | ✅ click/describe a control by role/label/identifier (needs Accessibility grant) |

### The OOP-click recipe (and its one caveat)

Earlier, a bare `CGEventPostToPid` mouse event arrived at the target
**un-hit-tested** (window number `0`) and did not actuate any control. The fix
(RE'd in `research/hittest/`) is to **stamp the CGEvent's window-routing fields before
posting** so WindowServer hit-tests the event against the target's exact window
instead of falling back to a screen-location hit-test (which skips non-key /
background windows → `win=0`):

- **field 51 = the target `CGWindowID`** — the essential router (the *documented*
  `kCGMouseEventWindowUnderMousePointer` = 91 / …92 do **not** route an AppKit
  event on their own);
- **the private `CGEventSetWindowLocation(ev, wx, wy)`** with **window-local**
  coordinates (top-left origin) — without it the routed event arrives with
  `locationInWindow ≈ (0, …)` and hit-tests *empty space*, so the control never
  fires even though the event reached the right window;
- fields `1`=clickState(1), `3`=buttonNumber(0), `7`=subtype(3), `40`=pid,
  `58`=click-group — make the routed event a valid actuating left click.

`click` stamps these (via the `dlsym`'d, non-validating SkyLight
`SLEventSetIntegerValueField`) on a `mouseMoved`+`down`+`up` sequence and posts
them via `CGEventPostToPid` (and `SLEventPostToPid` when present, for
Catalyst/Chromium). It **actuates a background window without activating it** —
no injection, no Accessibility grant, and the real cursor never moves (`click`
asserts `cursor_moved=0.0px`). Verified end-to-end against a ground-truth button
whose press writes a file (counter incremented).

**The one caveat — the session must be UNLOCKED.** While the screensaver is up
(or the display is asleep) input still lands, but a real **password lock**
(`ioreg -n Root -d1` → `CGSSessionScreenIsLocked=Yes`) makes WindowServer drop
**all** synthetic delivery — both `CGEventPostToPid` and `SLEventPostToPid`, for
mouse *and* keyboard. So `type`/`key`/`click` all work on an unlocked session
(including background windows and under the screensaver), and all stop at a
locked screen. `shot` is unaffected — it reads the backing store, not input.

## Driving an iOS Simulator

`winctl sim` controls a booted Simulator the way Claude Desktop's simulator pane
does — **discrete device-framebuffer screenshots + HID input to the SimDevice**,
never the host cursor (so it's independent of the Simulator.app window, and of the
Mac TCC grants above).

```sh
winctl sim list [--all]                 # booted sims (or all available)
winctl sim shot   booted /tmp/sim.png   # device framebuffer (xcrun simctl io)
winctl sim tap    booted 200 420
winctl sim swipe  booted 100 500 100 100 [duration]
winctl sim type   booted "hello"
winctl sim key    booted <hid-keycode>
winctl sim button booted <APPLE_PAY|HOME|LOCK|SIDE_BUTTON|SIRI>
```

`<target>` is a **udid**, a **device-name substring**, or **`booted`**.

`tap`/`swipe` take coordinates in **`sim shot` pixels** and auto-scale to the
device's logical points (idb works in points; a 3× screen is 1260×2736 px =
420×912 pt) — so read a pixel off the screenshot and tap that same number. Pass
`--points` to give raw points instead. idb (and the `idb_companion` it spawns)
are located even under a minimal harness PATH (pipx `~/.local/bin`, Homebrew).

- **Capture / list** use `xcrun simctl` — no extra dependencies, device-accurate
  (no host window chrome), works with Simulator.app hidden.
- **Input** shells out to Meta's **`idb`** (`brew install idb-companion &&
  pip3 install fb-idb`), which wraps the **same FBSimulatorControl / Indigo HID**
  engine Claude links in-process — so taps/swipes/text are real device HID events,
  not host clicks. If `idb` isn't installed, the input subcommands say so; capture
  and list still work.

This mirrors the reverse-engineering in `../Claude-iOS-Sim-RE` (Documents): Claude
embeds `FBSimulatorControl`, injects **Indigo HID**, and streams the **IOSurface
framebuffer**. `idb` is the packaged form of that same stack.

## Harness independence (self-disclaim + own TCC identity)

Capture needs **Screen Recording** (`kTCCServiceScreenCapture`); the element
tree / `--press` need **Accessibility** (`kTCCServiceAccessibility`); synthetic
input needs **`kTCCServicePostEvent`** (and `kTCCServiceListenEvent`), which
compose to Accessibility. All are **system** services in
`/Library/Application Support/com.apple.TCC/TCC.db`.

**The problem with a bare CLI:** it has no TCC identity of its own, so TCC
attributes its requests to whatever **host** is *responsible* for the shell (VS
Code, Terminal, Ocean…). The tool then only works where that host happens to be
granted — grant it for VS Code and it breaks under Terminal, etc.

**The fix — self-disclaim into our own identity.** On startup (in `main`, before
any capture/input), if `WINCTL_DISCLAIMED` is unset, winctl re-execs
*itself once* with the private `responsibility_spawnattrs_setdisclaim(&attr, 1)`
spawn attribute (declared extern; the same mechanism Claude.app's `disclaimer`
helper uses). The disclaimed child is decoupled from the parent's
responsibility, so it becomes **TCC-responsible for itself**. Combined with the
stable code signature (identifier `com.nscake.winctl` + Tanner's Apple
Development cert), TCC keys every request on **`com.nscake.winctl`** — the
same identity no matter which harness launched it.

`winctl doctor` confirms it: it reports self-disclaim ACTIVE, the live
self-check (which now reflects winctl's *own* grant), and prints
**"WORKS UNDER ANY HARNESS"** when green.

### One-time grant

On an AMFI-relaxed box winctl can grant **itself**: `sudo winctl grant` (and
`sudo winctl grant --revoke`) writes the rows below and restarts tccd; on a
standard Mac it refuses and points you to System Settings. `winctl doctor`
reports the AMFI state and tells you which path applies. The manual equivalent:

Grant winctl in the **system** TCC.db, once. **Identity matters:** on an
AMFI-relaxed box (`amfi_get_out_of_my_way=1`) every non-Apple binary is stamped
`CS_PLATFORM_BINARY`, and tccd cannot resolve a bundle id without a `.app` — so a
`client_type=0` (bundle-id) row is silently **ignored** for Accessibility/PostEvent
(`DB Action:None` → default deny; confirmable in `log stream --predicate 'process
== "tccd"'`). tccd identifies a bare CLI by its **resolved path**, so grant the
**path** with `client_type=1` and a **NULL csreq** (identifier-only, survives
rebuilds — no DR hex needed):

```sh
SYS='/Library/Application Support/com.apple.TCC/TCC.db'
BIN=$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$(command -v winctl)")
for SVC in kTCCServiceScreenCapture kTCCServiceAccessibility \
           kTCCServicePostEvent kTCCServiceListenEvent; do
  sqlite3 "$SYS" "INSERT OR REPLACE INTO access \
    (service,client,client_type,auth_value,auth_reason,auth_version,csreq,flags) \
    VALUES ('$SVC','$BIN',1,2,4,1,NULL,0);"
done
killall tccd
```

Because the grant is keyed to the **path**, `build.sh` rebuilds are fine (same
path, no csreq to invalidate), but **moving the binary voids the grant** — re-run
the block. Writing the root-owned system TCC.db requires root — on this machine
via the passwordless `sudo /Users/tanner/.iconchanger/helper.sh` primitive.
Verify with `winctl doctor` (GREEN = live and active).

### Revoke

```sh
SYS='/Library/Application Support/com.apple.TCC/TCC.db'
BIN=$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$(command -v winctl)")
sudo sqlite3 "$SYS" "DELETE FROM access WHERE client IN ('com.nscake.winctl','$BIN') AND service IN ('kTCCServiceScreenCapture','kTCCServiceAccessibility','kTCCServicePostEvent','kTCCServiceListenEvent');"
sudo killall tccd
```

## Files

- `winctl.m` — the whole CLI (Objective-C + Cocoa/CoreGraphics).
- `winctl` — compiled binary (gitignored; symlinked to `/usr/local/bin`).

See `research/oop/README.md` for the underlying reverse-engineering (the see/act
capability matrix, screensaver results, and why CARenderServer isn't reachable
out-of-process).
