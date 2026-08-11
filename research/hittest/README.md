# Poltergeist / hittest — making an OOP synthetic mouse click actually actuate a control

Follow-up to `../oop/`. That experiment established that a bare out-of-process
`CGEventPostToPid` **mouse** event is *delivered* to the target process but
arrives **window-less (`win=0`) and un-hit-tested**, so a click never actuates
an on-screen control (the button action never fires). Accessibility — the normal
way to press a control OOP — is broken on this box because of the AMFI
relaxation, so it can't be the fallback.

**This experiment finds the OOP, no-injection way to make a synthetic left click
actually fire a background `NSButton`.** And it does: the fix is to **stamp the
CGEvent's window-routing field(s) before posting** so WindowServer hit-tests the
event against the target's window instead of falling back to a screen-location
hit-test (which skips non-key / background windows → `win=0`).

Tested on macOS 15.7 (24G222), Apple Silicon (arm64), SIP disabled, AMFI relaxed.

## TL;DR — the winning recipe

Out-of-process, **no code injection**, **cursor never moves**, target **in the
background** (not frontmost):

1. Create a normal `CGEventCreateMouseEvent(src, kCGEventLeftMouseDown/Up, globalPt, kCGMouseButtonLeft)`.
2. **Stamp field 51 = the target's `CGWindowID`** — this is the field that makes
   the event route + hit-test to that exact window. (The *documented*
   `kCGMouseEventWindowUnderMousePointer` = 91 / …ThatCanHandle = 92 do **not**
   route an AppKit event on their own — see ablation.)
3. Stamp the ordinary mouse fields too: `1`=clickState(1), `3`=buttonNumber(0),
   `7`=subtype(3), `40`=target pid. Field 51 alone routes the event but the
   button won't fire without a valid clickState/mouse-field set.
4. Post with `CGEventPostToPid(pid, ev)`. (`SLEventPostToPid` and
   `CGEventPostToPSN` work identically once the fields are stamped.)

That's it. A leading `mouseMoved` primer and the private `CGEventSetWindowLocation`
help on some targets but were **not required** for this AppKit `NSButton`.

Field 51 / 58 are undocumented indices; stamp them with the SkyLight
**`SLEventSetIntegerValueField`** (non-validating), resolved via `dlsym` — the
public `CGEventSetIntegerValueField` may silently ignore undocumented indices.
Nothing private is linked; every SPI is `dlsym`'d from SkyLight.

This is a Cocoa/ObjC re-derivation of the technique in trycua/cua's `cua-driver`
(`platform-macos/src/input/{mouse,skylight}.rs`) and yabai's
focus-without-raise; see "Provenance".

## Pieces

- **`Target.app`** (`target.m`) — the `../oop/` target, re-pathed to
  `/tmp/poltergeist-hittest`. "Press me" `NSButton` → increments a counter into a
  "pressed N" label. Ground-truth files:
  - `label.txt` — written **only when the button's action fires** (the success oracle).
  - `events.txt` — every mouse/key `NSEvent` via an `NSApplication.sendEvent:`
    override, **with `windowNumber`** (so we can see `win=0` vs `win=<real>`).
  - `info.txt` — pid, windowNumber, button global-CG center, button window offset.
- **`controller.app`** (`controller.m`) — separate process. Given
  `<pid> <windowNumber> --cg gx gy --winlocal wx wy --method NAME`, posts a click
  by one of several methods/ablations and logs counter-before/after, the
  windowNumber the target saw, whether the target was frontmost, and cursor drift.
- **`run.sh`** — for each method: relaunch a **fresh** Target, push it to the
  **background** (Finder frontmost), run the method, report actuation + the
  windowNumber the target saw. Fresh relaunch per method keeps the matrix clean.
- **`build.sh`** — build + ad-hoc sign both.

## The matrix — RESULT (target in BACKGROUND, session UNLOCKED)

A click **SUCCEEDS iff the counter increments** (`label.txt` → "pressed 1").
`target_frontmost=0` in every row below (genuine background). **Cursor moved 0.0px
in every row.**

| method | channel | stamps | actuated? | windowNumber target saw |
|---|---|---|---|---|
| `baseline` | CGEventPostToPid | none | **NO** | `win=0` |
| `fields` | CGEventPostToPid | 51+91/92+mouse fields + primer + WindowLocation | **YES** | `win=<real>` |
| `sl` | SLEventPostToPid | same | **YES** | `win=<real>` |
| `both` | SL + CGEventPostToPid | same | **YES** | `win=<real>` |
| `activate_both` | SLPS focus-without-raise → both | same | **YES** | `win=<real>` |
| `front_both` | SLPSSetFrontProcessWithOptions → both → restore | same | **YES** | `win=<real>` |
| `psn` | CGEventPostToPSN | same | **YES** | `win=<real>` |

Baseline reproduces the `../oop/` failure exactly. Every stamped method actuates
the **background** button. The winning method needs **no** target activation — a
plain stamped `CGEventPostToPid` (`fields`) actuated a non-frontmost window.

### Ablation — which stamp is essential (all via CGEventPostToPid, background)

| variant | stamps applied | routed to window? | actuated? |
|---|---|---|---|
| `abl_primeronly` | primer only, no fields | `win=0` | NO |
| `abl_misc_only` | mouse fields (1/3/7/40/58), **no** window id | `win=0` | NO |
| `abl_only9192` | only 91/92 | `win=0` | NO |
| `abl_misc9192` | mouse fields + 91/92 (no 51) | `win=0` | NO |
| `abl_only51` | only field 51 (no clickState) | `win=<real>` | NO |
| `abl_5191_nomisc` | 51 + 91/92, no clickState | `win=<real>` | NO |
| `abl_misc51` | mouse fields + **51** | `win=<real>` | **YES** |
| `abl_noprimer` | full stamps, **no** primer | `win=<real>` | **YES** |
| `abl_noloc` | full stamps + primer, **no** CGEventSetWindowLocation | `win=<real>` | **YES** |

Reading the ablation:

- **Field 51 (windowNumber) is the routing field.** Only stamps that include 51
  make the target see `win=<real>`; `91/92` and the mouse fields alone leave it
  `win=0`. The publicly-documented 91/92 do **not** substitute for 51 on AppKit.
- **Routing is necessary but not sufficient.** `abl_only51` / `abl_5191_nomisc`
  reach the window (`win=<real>`) yet don't fire — a routed event still needs a
  valid clickState/mouse-field set to be a real actuating click.
- **51 + the mouse field set = actuation** (`abl_misc51`).
- The **mouseMoved primer** and **CGEventSetWindowLocation** were **not required**
  for this AppKit `NSButton` (`abl_noprimer`, `abl_noloc` both fired). They are in
  the full recipe because cua needs them for Chromium/Catalyst targets; keep them
  for robustness across target toolkits.

Two ablations (`pure_public` = public setter for field 51; `abl_51_clickstate` =
51 + clickState only) landed at/after the screen-lock boundary below and are
**inconclusive** — not relied on here.

## The critical caveat: this needs the session UNLOCKED

Midway through the run the screen **locked**
(`ioreg -n Root -d1` → `CGSSessionScreenIsLocked=Yes`). The moment it locked,
**every** method stopped delivering — the target's `events.txt` was never even
created, i.e. WindowServer dropped **all** synthetic delivery, both
`CGEventPostToPid` **and** `SLEventPostToPid`. Secure event input was **off**
(`CGSIsSecureEventInputSet` → 0), so the lock itself is the gate.

So: **synthetic mouse delivery to a background app works while the login session
is active/unlocked, and is blocked entirely once the screen is locked.** This is
stronger than the `../oop/` "works under the screensaver" result — a *screensaver*
is not a *lock*. All the ✅ rows above are from before the lock; they are real and
were reproduced across two full matrix passes + two ablation passes. I did **not**
attempt to unlock Tanner's machine to re-verify, so the post-lock rows in the raw
logs (`out/controller_{det,ls,fg,pure_public}.log`, and the trailing NO entries in
the per-method logs) should be ignored.

## Does SLPSPostEventRecordTo help?

`activate_without_raise` (yabai/cua's two-`SLPSPostEventRecordTo` focus-without-raise
recipe: `_SLPSGetFrontProcess` → defocus front `bytes[0x8a]=0x02` → focus target
`bytes[0x8a]=0x01`, window id at `0x3c`, `bytes[0x04]=0xf8`, `bytes[0x08]=0x0d`)
returned rc=0 and is included in `activate_both`. But it turned out to be
**unnecessary for actuation** here: the field-51 stamp alone makes a *background*
window hit-test the click without making it key. `SLPSPostEventRecordTo` is the
right tool when you specifically need the window to become AppKit-key (menu
validation, first-responder-sensitive controls); it is not what makes a plain
button press land.

## Build & run

```
./build.sh
./run.sh                 # full matrix (background)
./run.sh fields          # one method
./run.sh abl_misc51 abl_only51 abl_misc9192   # specific ablations
```

`run.sh` reads pid/windowNumber/coords from `/tmp/poltergeist-hittest/info.txt`,
activates Finder so the target is background, runs the controller, and prints the
`RESULT` line plus the windowNumber(s) the target saw. Requires the session to be
**unlocked** (see caveat).

## No TCC grant was added

The winning path (`CGEventPostToPid` / `SLEventPostToPid` with stamped fields)
needed **no** Accessibility grant on this box — consistent with `../oop/`, where
`CGEventPostToPid` delivered events without AX. No system-TCC rows were added or
removed by this experiment; nothing to revoke.

## Provenance

The stamped-field recipe was re-derived from open source, then verified here:
- **trycua/cua** `libs/cua-driver/rust/crates/platform-macos/src/input/`
  (`mouse.rs`, `skylight.rs`) — the `SLEventPostToPid` + `SLEventSetIntegerValueField`
  field stamps (f1/f3/f7/f40/**f51**/f58/f91/f92), `CGEventSetWindowLocation`, the
  mouseMoved primer, and `activate_without_raise`. Also their blog
  "Inside macOS window internals".
- **yabai** `src/window_manager.c` (`window_manager_make_key_window`) and
  `src/misc/extern.h` — the 0xf8 `SLPSPostEventRecordTo` event-record layout and
  the SkyLight PSN/front-process prototypes.
- **NUIKit/CGSInternal** `CGSEvent.h` — the `CGSEventRecord` field offsets
  (`type@0x8`, `location@0x10`, `windowLocation@0x20`, `window@0x3c`).
