# Upward selection: local fix and reproductions

Scope: phone native Android selection handles, live Markdown projection and source
viewport. Baseline: `e116daa` (0.2.13+22). No version bump, commits, push, deployment
or release publication were performed during development. The owner subsequently
authorized publishing this fix without further approval; release provenance is
recorded in `docs/0.2.14.md`.

## Recording and diagnosis

Inspected `video_76a9199ae64f.mp4` as a chronological contact sheet and individual
frames. The user extends the upper selection handle from the final task paragraph
with the keyboard open. Whole paragraphs shift, task source becomes visible, and
the upper handle appears above the editor toolbar. The tests below isolate real
causal mechanisms, not a pixel-identical replay of the recording. Physical-device
verification and overlay clipping above the toolbar remain unverified.

1. Native handles are in Flutter's Overlay, outside the field Listener. The old
   edge-scrolling coordinator saw long-press drags but never handle drags.
2. A range intersecting Markdown markers activated their source projection. This
   changes line height and wrapping while RenderEditable is deriving pointer
   offsets and handle positions from that same geometry.
3. Source-mode's reveal boundary wrapped the document viewport instead of the
   field, so native showOnScreen could already scroll that viewport before reaching
   the boundary. A net-monotonic-scroll assertion alone missed this competing path.

## RED → GREEN

- `test/mobile_selection_handle_test.dart`: real Android long press, release, then
  native handle drag in a keyboard-shortened phone document. Before the handle
  bridge: offset 900 → 900 and range 770..1049 unchanged while the pointer was
  stationary. After: offset 900 → 760, start 770 → 573, end remains 1049. The later
  fixture grabs another word to also exercise a touch in the handle's outer hit
  area; both the painted tip and outer hit target pass.
- `test/selection_projection_geometry_test.dart`: source unchanged and scroll=0,
  but entering the task/link selection changed height 168 → 191 / 105 → 168 at
  width 240 and 126 → 128 / 84 → 126 at width 320. GREEN preserves height, the
  fixed trailing glyph box, and lower range-handle point while expanding and
  retracting. Also checks lossless source copy, returning to caret/source editing,
  and replacing a selected range. Only the platform clipboard channel is mocked.
- Actual HomeScreen, live/source, upper/lower handles: check 120 consecutive 16ms
  frames for direction, maximum 20px delta, stable opposite text offset, unchanged
  text and EditableTextState, and stopping after release/cancel. The source frame
  bound first failed at 28.72px; moving the boundary below the viewport restores
  the same paced scrolling as live mode: 900 → 500.72 upwards and 900 → 1299.28
  downwards in this fixture.

## Implementation

- Android/Fuchsia controls forward raw overlay handle events to the existing edge
  coordinator; native Flutter drag recognizers and the context menu remain in
  control. Own an opaque minimum 48px target so padded hits do not fall through
  to the document and cancel the drag. Other platforms keep native controls.
- During edge steps, hit-test the moving end while retaining the opposite source
  offset. Keep Android's non-swapping endpoint rule.
- Freeze only the layout-driving selection at the last caret while a range is
  highlighted. The actual source selection, copy and edit values stay lossless;
  a text edit or collapsed/invalid selection invalidates this layout snapshot.
  Embedded table and callout editors receive the live selection, never the frozen
  layout selection. Handle identity comes from the overlay handle type and the
  paragraph direction, never pointer distance or individual bidi-run direction.
- Put the source reveal boundary between its field and document viewport.

## Review regressions reproduced and corrected

- Embedded table cell, callout title, and callout body: all three RED reproductions
  changed the selected range 0..5 back to the old collapsed caret 3 after rebuild.
  Separating the live editor selection from the layout snapshot fixes all three,
  including reversed ranges and unchanged controller/focus identities.
- Overlapping 48px handle targets: native Flutter moved the end handle first, but
  the custom coordinator inferred the start handle from pointer proximity. While
  scroll grew 363 → 762.28, the end offset remained stuck at 1297. Forwarding the
  actual handle type fixes growth 1297 → 2026; mixed LTR runs in an RTL paragraph
  and second-pointer interruption are covered too.

## Executed verification

- Full app suite after both review fixes: **316 passed, 15 skipped, zero failures**.
  Includes the four geometry/clipboard tests, six native handle tests, five
  embedded-selection tests, and three overlapping-target/RTL/lifecycle tests.
  Skipped tests are not claimed as executed.
- Final independent static review: passed, with no introduced correctness or
  security blockers. Both earlier review regressions were reproduced and fixed.
- `flutter analyze --no-pub`: no issues.
- Dart formatter and `git diff --check`: clean.
- Compiled application kernel/assets successfully:

  ```sh
  flutter build bundle --debug --no-pub --target-platform linux-x64 \
    --asset-dir build/selection-fix/flutter_assets
  ```

  This is a debug Flutter application bundle, **not an APK or desktop installer**.
  Android-target bundle initially failed because this machine has no Android SDK.
  At that development stage no physical phone test, signed Android build, or
  release had been performed. Follow-up: the signed CI installers were built and
  0.2.14+23 was published with the owner's explicit authorization; see
  `docs/0.2.14.md` for verified provenance and public download results. The
  physical-device gesture/overlay-clipping check remains unverified.

Raw diagnostic logs are in the coder scratch directory `selection-video/`:
`handle-red.log`, `projection-red.log`, `projection-green.log`,
`source-jump-red.log`, `source-jump-green.log`, `handle-padding-red.log`,
`handle-padding-green.log`, `embedded-selection-red.log`,
`embedded-selection-targeted-green.log`, `verified-tests.jsonl` and
`verified-tests.stderr`. Overlap RED/GREEN are in scratch `overlap-red.log` and
`overlap-green-final.log`.
Scratch is temporary; the reproducible assertions are retained in the repository.
