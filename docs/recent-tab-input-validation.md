# Recent-tab held Control regression — 2026-10-21

The switcher used `NSEvent.modifierFlags` twice after its initiating menu
action to decide whether Control had already been released. During an actual
computer-use Control-Tab hold, the initiating event contained Control but the
global snapshot was zero. The next-main-turn check committed after 19.77 ms,
before reveal, and removed the observers that should handle subsequent arrows.

`RecentTabSwitcherInputSession` now owns delayed reveal and the gesture lifetime.
The initiating event establishes held Control; delivered modifier-change events
end the gesture. Global snapshots cannot terminate an active gesture. Reveal
still uses the operational 50 ms threshold. Cancellation and commit invalidate
pending reveal work; each release can commit at most once.

## Regression command

Build the app first from the repository root:

```sh
CONFIGURATION=Debug Scripts/build.sh
bash Scripts/verify_recent_tab_input.sh
```

The probe links the built production CioUI implementation. Its 11 checks cover
held input despite a zero global snapshot, reveal, selection movement before
commit, single release, quick release without a late panel, cancellation,
replacement sessions, menu latching, and repeated modifier events. The original
snapshot checks reproduced the early-commit failure in the initial replay;
removing them made the replay pass.

## Computer-use checks

Used the absolute repository Debug app path with an isolated `CIO_DATA_DIR`,
mock keychain, and five local fixture pages. The user's workspace was not used
as test data. Temporary traces were removed from production source afterward.

- Held Control-Tab: reveal at 51.90 ms; commit at the delivered release,
  1436.49 ms after initiation, despite the global Control snapshot remaining zero.
- Open chooser via Tabs → Next Tab: Right highlighted Page B and Left returned
  the highlight to Page A while Main secondary remained the active web page.
- Control-Right then release: selected Page B; the trace showed the old active
  page retained through the arrow event and changed only after release.
- Native address editor focused: Control-Left in the latched chooser returned
  highlight to the current Page B; release confirmed it and restored page focus.
- Quick Control-Tab: commit at 4.51 ms with no reveal event; Main secondary
  became the selected page.

The computer-use provider releases modifiers between separate `pressKey` calls
and cannot send Tab and an arrow as separate non-modifier keys within one held
chord. Therefore the complete continuously-held Tab-then-arrow sequence is
covered by the production input-session replay plus the separate actual-window
checks above, rather than claimed as one uninterrupted computer-use gesture.

## Physical-arrow follow-up

The user still observed a stationary highlight during a continuously held
Control gesture. The earlier replay validated lifetime and selection, but did
not validate WindowServer's delivery of physical Control-arrows. The machine
has enabled symbolic shortcuts for these arrows, including Function variants;
absence of a desktop animation alone does not establish which input route ran.

The user explicitly authorized a local uninterrupted keyboard-input script.
With Cio frontmost, a HID-level Control-Tab, Right, Right, Left, release replay
reproduced the stationary highlight: Tab and Control release reached AppKit,
while all three arrows were absent. A separate Carbon-dispatcher probe also
received none of the arrows despite successful registration. Carbon's
same-process callback test was therefore insufficient, and that implementation
was removed.

`RecentTabSwitcherArrowKeys` now installs a scoped filtering session event tap
only when Cio already has Accessibility authorization. It consumes only held
Control-Left/Right and their matching key-ups while the owning Cio window is
active. Command/Option chords and unrelated keys pass through. Release,
cancellation, window closure and loss of activation remove the tap and clear
consumed-key state. The tap never requests permissions from Control-Tab and does
not modify persisted system shortcuts. Without authorization, existing local
AppKit/Chromium handling remains available, but system-reserved arrows still
cannot reach Cio.

```sh
bash Scripts/verify_recent_tab_system_arrows.sh
```

Seventeen checks replay the production filtering callback: both directions,
key-up, repeats/modifier variants, eligibility, unrelated keys, lifecycle and
cleanup. The original 11 lifetime and 21 native shortcut checks are retained.
These callback checks do not establish WindowServer delivery. Before the
permission grant, the Cio process reported `AXIsProcessTrusted() == false`.
The required repository Debug build passed, and the old app was quit before
opening the final build. All 49 callback/lifetime/native shortcut checks passed.

## Authorized uninterrupted system-input acceptance

On 2026-10-21, the user explicitly authorized enabling Cio's Accessibility
access. System Settings showed the Cio toggle enabled after authentication.
The final Debug app at the absolute repository build path ran as PID 43838.
Unlike the earlier isolated fixtures, this acceptance used the existing open
workspace without creating or closing tabs.

An authorized local script posted HID-level events, holding Control continuously
across Tab, Right, Right, Left and releasing it only at the end. A timed run
completed successfully; a second run waited at each phase for computer-use
screenshots. Every phase reported Cio as the frontmost process. The screenshots
and accessibility state established:

- Control-Tab highlighted card 2 (the single App Store tab).
- First Right highlighted card 3 (the other Bilibili tab).
- Second Right highlighted card 4 (the three-pane split group).
- Left returned the highlight to card 3.
- Throughout the held phases, the active web-content container remained
  `4FC5C408-DC62-4104-B6FD-0E1AFC33E61F`.
- Releasing Control dismissed the chooser and selected card 3, confirmed by
  the selected sidebar row and web-content container
  `730EAFF1-44CF-469D-9081-F88E22A1F4FC`.

Both scripts exited successfully and released Control. This validates the
complete continuous gesture through WindowServer and the visible final Debug
app, in addition to the callback/lifetime regression probes.
