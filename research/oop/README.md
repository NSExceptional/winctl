# Poltergeist / OOP — out-of-process "see & control while locked", no code injection

Companion to the parent Poltergeist PoC (which proved the **in-process**
`DYLD_INSERT_LIBRARIES` route). This subdir answers the follow-up question:

> Can an agent SEE and CONTROL another app while the screen is locked /
> screensaver is on, **without moving the real cursor**, and **without
> injecting any code** into the target (no `DYLD_INSERT_LIBRARIES`, no
> `task_for_pid`)? Everything the controller does is from a separate process.

Tested on macOS 15.7 (24G222), Apple Silicon (arm64), SIP disabled, AMFI
relaxed (`amfi_get_out_of_my_way=1`).

## Pieces

- **`Target.app`** (`target.m`) — tiny non-sandboxed AppKit app: a "Press me"
  `NSButton` that increments a counter into a "pressed N" `NSTextField` label,
  plus an editable `NSTextField` (first responder). Standard AX-accessible
  controls. It also logs, as ground truth for the experiment:
  - `/tmp/poltergeist-oop/label.txt` — written when the button's action fires.
  - `/tmp/poltergeist-oop/field.txt` — the text field's value on every change.
  - `/tmp/poltergeist-oop/events.txt` — **every** mouse/key `NSEvent` the process
    receives (via an `NSApplication.sendEvent:` override), with `windowNumber`.
  - `/tmp/poltergeist-oop/info.txt` — pid, windowNumber, button geometry.

- **`controller.app`** (`controller.m`) — separate app, own bundle id
  `com.nscake.PoltergeistController`, ad-hoc signed for a stable TCC identity.
  Given `<pid> <windowNumber>`, it tries, purely out-of-process:
  - **INPUT / AX:** `AXUIElementCreateApplication(pid)`, walk to the button,
    `AXUIElementPerformAction(kAXPressAction)`; `AXUIElementSetAttributeValue`
    on the field's `kAXValueAttribute`.
  - **INPUT / events:** `CGEventPostToPid(pid, …)` mouse down/up (+ a key path),
    recording the real cursor position before/after.
  - **CAPTURE:** (a) `CGWindowListCreateImage`, (b) SkyLight
    `SLSHWCaptureWindowList` / `CGSHWCaptureWindowList`, (c)
    `CARenderServerRenderLayerWithTransform`.

Private symbols (`CGWindowListCreateImage`, the SkyLight capture calls,
`CARenderServer*`) are resolved with `dlsym`, so nothing private is linked.

## The matrix — RESULT

Screensaver **OFF** and **ON** gave **identical** results in every cell (the
screensaver — started safely, see below — changed nothing).

| capability | mechanism | saver OFF | saver ON | notes |
|---|---|---|---|---|
| SEE | `CGWindowListCreateImage` | ✅ works | ✅ works | non-black 0.999; shows the real window. **Compile-time *unavailable* in the macOS 15 SDK** (Apple pushed ScreenCaptureKit) — called via `dlsym`; the symbol still functions. Needs Screen Recording TCC. |
| SEE | SkyLight HW (`SLSHWCaptureWindowList`) | ✅ works | ✅ works | non-black 0.99, 2× retina (840×456). Cleanest pixels. |
| SEE | `CARenderServer` / IOSurface | ⚪ not reachable | ⚪ not reachable | symbol present, but the target window's CA `context_id` is **not obtainable from another process** (no public enumeration of a foreign process's `CAContext` ids). Needs in-target cooperation → out of scope. |
| ACT | `AXPerformAction` / `AXSetValue` | ❌ blocked | ❌ blocked | Controller **is** AX-trusted and can enumerate every app's **menu bar**, but the **window and its controls are never vended** to it (`AXApplication.children` = `[self-reference, AXMenuBar]`; `AXMainWindow`→`AXApplication`). Reproduced identically against **TextEdit** ⇒ systemic on this box, not our target. Almost certainly the AMFI/codesign relaxation breaking the per-process AX handshake. `AXManualAccessibility`/`AXEnhancedUserInterface` nudges are unsupported here. |
| ACT | `CGEventPostToPid` | ⚠️ partial | ⚠️ partial | **Real cursor never moved (0 px)** — cursor-free confirmed. Events **are delivered to the process**. **Key** events route to the key window (`win=8558`) and **actuate the first responder** — a synthesized `x` changed the field to `x` even with the screensaver up. **Mouse** events arrive **window-less** (`win=0`) and un-hit-tested, so the **button action never fires** — a click does not actuate a control. |

Evidence PNGs: `out/see_skylighthw_{off,on}.png`, `out/see_cgwindowlist_{off,on}.png`.
Raw controller logs: `out/controller_{off,on}.log`. Event ground truth:
`out/events_sample.txt`.

## The single most important answers

- **Does OOP capture return the app's pixels while the screensaver is on?**
  **YES.** Both `CGWindowListCreateImage` and SkyLight HW capture return the live
  window content (button, label, field text) *while `ScreenSaverEngine` is
  drawing over the screen* — they read the window's backing store, not the
  framebuffer, so the saver overlay is irrelevant. (Both require the Screen
  Recording TCC grant; without it they return nil/black.)

- **Does OOP Accessibility input drive a background app while the screensaver is
  on, cursor-free?** On this box, **no via AX** — the controller can't even *see*
  the target's window in the AX tree (only the menu bar), so there is no button
  to press. This is a machine-specific artifact (AMFI); on a stock Mac, OOP AX is
  the canonical cursor-free way to drive window controls.

- **`CGEventPostToPid` is the one input path that partially works OOP and is
  genuinely cursor-free:** it delivers events into the target's process. **Key**
  events reach the key window and actuate the focused control (confirmed under
  the screensaver). **Mouse** clicks are delivered but arrive without a window
  association, so they do not actuate on-screen controls.

## Honest reachability notes (private capture routes)

- **SkyLight HW capture** (`SLSHWCaptureWindowList`): reachable and working via
  `dlsym`; returns a `CFArray` of `CGImageRef`. Best image quality.
- **`CARenderServer`**: `CARenderServerRenderLayerWithTransform` resolves, but it
  needs the **client id + context id** of the target's `CAContext`. Those live in
  the target process; there is no public/entitlement-free way to enumerate a
  *foreign* process's context ids out-of-process. Not pursued further — it would
  require exactly the in-target cooperation this experiment forbids.

## TCC / Accessibility grant (this machine)

Accessibility (and Screen Recording) are **system** services — they live in the
**system** TCC db `/Library/Application Support/com.apple.TCC/TCC.db`, *not* the
per-user db. Key gotchas discovered:

1. A third-party Accessibility row needs a matching `csreq` blob (Apple's own
   rows have NULL csreq because they're platform binaries). Built via
   `SecRequirementCreateWithString`/`SecRequirementCopyData`; used an
   **identifier-only** requirement so it survives rebuilds.
2. **Responsible-process attribution:** launching the controller from the shell
   makes TCC attribute its AX request to the *terminal/agent host*. The
   controller must be launched as its **own** process via LaunchServices
   (`open controller.app --args …`) for its own grant to apply. Only then does
   `AXIsProcessTrusted()` return 1.
3. Writing the root-owned system db here used the machine's existing passwordless
   primitive (`sudo /Users/tanner/.iconchanger/helper.sh …`), then `killall tccd`.

To (re)grant after a rebuild:

```
HEX=$(/tmp/mkcsreq 'identifier "com.nscake.PoltergeistController"')   # see mkcsreq.m
SYS="/Library/Application Support/com.apple.TCC/TCC.db"
for SVC in kTCCServiceAccessibility kTCCServiceScreenCapture; do
  sqlite3 "$SYS" "INSERT OR REPLACE INTO access \
    (service,client,client_type,auth_value,auth_reason,auth_version,csreq,flags) \
    VALUES ('$SVC','com.nscake.PoltergeistController',0,2,4,1,X'$HEX',0);"
done
killall tccd
```

(The two grant rows added during this experiment were **removed** afterward for
hygiene — re-run the block above to reinstate them.)

## Build & run

```
clang -arch arm64 -fmodules -framework Cocoa -o Target.app/Contents/MacOS/Target target.m
clang -arch arm64 -fmodules -framework Cocoa -framework ApplicationServices \
      -framework QuartzCore -framework IOSurface -o controller.app/Contents/MacOS/controller controller.m
codesign --force --sign - --identifier com.nscake.PoltergeistOOPTarget Target.app
codesign --force --sign - --identifier com.nscake.PoltergeistController controller.app

open ./Target.app                                   # note pid + windowNumber from /tmp/poltergeist-oop/info.txt
open ./controller.app --args <pid> <windowNumber> /tmp/poltergeist-oop --tag off --offset <ox> <oy>
```

Screensaver test was gated on safety: `askForPassword` absent and a 300 s lock
grace ⇒ starting `ScreenSaverEngine` cannot lock the screen; it was `killall`'d
right after.
