---
name: erenmlg-flutter-performance
description: Measures Flutter jank on a real Android device and reports it without editing app code. Builds and runs a profile-mode performance test that opens, scrolls and taps every screen of the app (skipping destructive buttons), adds missing test data when a screen needs it, judges each screen by dropped frames against the device's real frame budget, backs every finding with timeline evidence, and saves an English HTML report in the project, opened in the default browser, listing only the screens that stutter, with the cause, the code location and a copy-paste fix prompt. Can also verify a fix by re-measuring and set up a CI regression gate.
disable-model-invocation: true
---

# Flutter Performance Tester

Invoked explicitly, this skill runs end to end on its own: find the device, write the tests, build, run them on the phone, analyze, and open the HTML report. The user should not have to type a command. The only routine question is the test-data one in step 1.

The loop is **measure → classify → confirm with evidence → report**, and, when someone has applied a fix, **re-measure → report**. Every claim in the report is backed by a measurement on the same device.

## Scope: measure and report, never fix

The skill never edits the app. It writes only measurement files — `integration_test/*_perf_test.dart`, `test_driver/perf_driver.dart`, `perf_runs/`, `perf_report.json`, `perf_report.html`, the two dev dependencies in `pubspec.yaml`, and CI files when the user asks for a gate. It does not touch `lib/` or other app source, even when a fix is one line and even when the request says "fix it". The only thing it may change on the device is **test data** (step 1).

It taps everything a user can tap — buttons, cards, list items, tabs, icons, form fields, toggles (switched back afterwards) — and measures each response, except two kinds of target: **destructive** ones (delete, remove, reset, clear, log out, restore, import, pay, buy; icons like delete or logout) and ones that **leave the app** (share, export, camera, gallery, files, call, print), because the test would lose the screen. Dialogs a tap opens are closed with back; their buttons are never pressed. Sliders and radio buttons are skipped because their old value can't be restored.

Why: the user decides what changes and hands the fix to an agent of their choice. A measuring tool that also edits code blurs cause and effect and takes that decision away. So fixes go into the report as recommendations and into a self-contained fix prompt. If the user asks you to apply one anyway, say the skill only measures and that the prompt is ready to paste.

Respect what the project already has: add new files next to existing `integration_test/` and `test_driver/` content (`perf_driver.dart` only if that name is free, otherwise `perf_driver_timeline.dart`) and never edit the user's own tests. Suggest adding `perf_runs/` to `.gitignore` (about 10 MB of timeline per run).

## Ground rules

Say these to the user in a sentence or two with the results — they are why the numbers can be trusted.

- **Profile mode on a physical device.** Debug mode is many times slower; emulators draw on the host GPU. If only an emulator is attached, run anyway and label the numbers as indicative.
- **Frame budget = 1000 / refresh rate.** 60 Hz → 16.7 ms, 90 Hz → 11.1 ms, 120 Hz → 8.3 ms. The UI thread (Dart: build, layout, paint) and the Raster thread (drawing on the GPU) each must fit the budget.
- **Rendering backend.** The log prints `Using the Impeller rendering backend (…)`. Impeller precompiles shaders, so first-run shader jank only happens on Skia. SkSL warm-up flags no longer exist — don't recommend them.
- **Measuring tools add overhead.** DevTools tracing options slow frames; never record numbers with them on.

## Workflow

### 1. Prepare (automatic, one question)

1. `flutter devices` and `adb devices`. Pick the physical Android device (ask only if several are attached). adb may not be on PATH: it lives in `<Android SDK>/platform-tools`; `flutter config --machine` shows the SDK path.
2. Refresh rate: `adb -s <id> shell dumpsys display | grep -oE "fps=[0-9.]+"` (use the active mode's value) → `--fps` for the scripts. If the list holds a higher rate than the active one, the phone is set below its best: tell the user which rate it supports and let them switch it in the phone's settings or accept the active rate — never change device settings yourself.
   Device profile, read in one `adb -s <id> shell` call (all read-only), for the report's `device` (`<model> · Android <n> · <SoC>`) and `deviceProfile` fields:
   - `getprop ro.product.model`, `ro.build.version.release`, `ro.soc.model` (empty on older Android; fall back to `ro.board.platform`)
   - CPU: core count from `ls -d /sys/devices/system/cpu/cpu[0-9]*`, max clocks from `cpufreq/cpuinfo_max_freq`; RAM from `/proc/meminfo` `MemTotal`
   - GPU: `dumpsys SurfaceFlinger | grep -m1 GLES`; screen: `wm size`, `wm density`
   - State: `settings get global low_power` (1 = battery saver), `dumpsys thermalservice | grep -m1 "Thermal Status"` (0 = not throttled), `dumpsys battery` level, temperature and charger
   The phone must run at its best before measuring: battery saver off, thermal status 0, battery above 20 % or charging. Otherwise ask the user to fix it (their device, their settings) or to accept numbers that will look worse, and say so in the report. Test phones are often several years old or low-end; judge findings against this profile and the measured floor (step 3), not against a flagship.
3. Wake the screen: `adb -s <id> shell input keyevent KEYCODE_WAKEUP`. If `dumpsys window` shows `isKeyguardShowing=true`, ask the user to unlock the phone — a locked screen renders no frames.
4. If `integration_test/app_sweep_perf_test.dart` exists from an earlier run and `flutter analyze` passes on it, reuse it: update `_screens` only for screens that were added or removed, and go to §3 Build and run. If it has no `_calibration_scroll` or no `_appHasEnglish` (written by an older version of this skill), first rebuild it from `assets/app_sweep_test.dart`, carrying over the fill-ins (`_screens`, `_deleteSeededData`, `_recover`, `_extraUnsafeWords`, `_extraUnsafeIcons`) unchanged, and move the old `perf_runs/` aside: runs without a device floor or `__isolated` names can't be compared with the new ones. Otherwise read the app's code: entry point, router or bottom navigation, the screens and how a user reaches each, how the project's own tests seed data and skip onboarding, and anything that never settles (repeating animations, network calls on open).
5. List the screens you will measure in chat and, **in the same message, ask the one routine question of the run**: *"Some screens need data to show real content. Should the test delete the data it adds after the run?"* Then continue without waiting for more input.

### 2. Write the performance test

1. Add dev dependencies if missing: `flutter pub add 'dev:integration_test:{"sdk":"flutter"}' 'dev:flutter_driver:{"sdk":"flutter"}'`.
2. Copy `assets/perf_driver.dart` to `test_driver/perf_driver.dart` unchanged. For every traced action it keeps a numbered copy of each run: `perf_runs/<reportKey>.<n>.json` (summary) and `perf_runs/<reportKey>.<n>.timeline.json` (full trace).
3. Whole app → copy `assets/app_sweep_test.dart` to `integration_test/app_sweep_perf_test.dart`. One screen → copy `assets/perf_test.dart` to `integration_test/<scenario>_perf_test.dart`.
4. Fill in the templates:
   - the import `package:my_app/main.dart` → the app's entry point (`app.main()`; `await` it if it is async);
   - `_screens` (sweep): one entry per screen; the sweep calls `_recover` before every screen, so each `open` navigates from the app's first screen (tap the tab, then the item). That lets any screen run alone. `scroll` only to override the auto-detected vertical list; `ensureData` for screens that need data (see below);
   - `_deleteSeededData` from the user's answer in step 1;
   - `_extraUnsafeWords` / `_extraUnsafeIcons`: labels and icons of this app's destructive or app-leaving controls that the built-in lists miss. Find them by reading the `onTap`/`onPressed` handlers that delete, clear or reset data, or call `launchUrl`, `Share`, an image or file picker; add their visible label (in the language the sweep runs in) or their `Icons.*` value. The built-in word lists are English only (labels are lowercased before matching). When the sweep can't run the app in English (`_appHasEnglish = false`), also add the app's own words for delete, remove, reset, clear, erase, wipe, log out, sign out, restore, import, pay, buy, purchase, subscribe, share, export, camera, scan, gallery, photo, file, upload, download, call, print and open in, in lowercase, so no destructive control is tapped;
   - `_recover` so it returns to the app's first screen (pop to the first route, then select the first tab). It must never throw: tap a close or back button only through a `.hitTestable()` finder that found something (a sheet or picker on top hides it), otherwise pop the route;
   - `_appHasEnglish` and `_useEnglish`: the sweep always runs the app in English when it can, so labels, logs and report terms are English. Look for translations (`l10n.yaml`, `*.arb`, `flutter_localizations`, `supportedLocales`, `easy_localization`, `.tr()`). With an English translation keep `_appHasEnglish = true`: the test tells the app the phone is set to en-US, which is enough for an app that follows the phone's language. If the app has its own language choice (a setting that overrides the phone), fill `_useEnglish` with the in-memory switch the settings page uses (e.g. `appLanguage.value = AppLanguage.en`). Never change the phone's language. If that switch also saves the choice, read the saved value first and put it back at the end the way seeded data is removed. Without an English translation set `_appHasEnglish = false` and say in chat that the app is measured in its own language. Report keys never depend on this: tap keys are named after the widget kind (`settings_tap3_listtile`), not its text, so they are always English and survive a change of language or data;
   - single scenario: the finder for the widget under test, the interaction and the `reportKey`.
5. `flutter analyze` the new files until clean.

Test data (`ensureData`): decide what each screen needs to show real content — a detail page needs one item, a list needs as many rows as a real user has (5 rows won't show list jank). Check at runtime and add only what is missing, through the app's own data layer (repository/DAO, the way the project's tests do; never by typing into forms), with names that read as test data ("Perf test goal"). Return a cleanup that removes exactly what was added. Never type real credentials: a screen behind a login uses the project's test account or is skipped with the reason.

What keeps a trace honest (already built into the templates — keep it):
- `framePolicy = benchmarkLive`: frames are scheduled like on a real device; otherwise `pump()` injects artificial frames.
- `semanticsEnabled: false`: the accessibility tree cost ~66 ms per frame on an 800-row list, a cost users without a screen reader never pay.
- `streams: ['Dart', 'Embedder', 'GC']` plus `--endless-trace-buffer`: with the default streams the API stream overflows the trace buffer and a 30-second scroll reports 3 frames.
- Trace only the interaction (settle first) and end it once the result is on screen, so work that moves later can't slip out of the window.
- Hermetic data: no network in the traced path, widgets found by Key or icon, and only hit-testable widgets tapped (`.hitTestable()`).
- Each sweep screen runs in its own `try/catch` with `_recover`: results reach the driver only when the test ends, so one unreachable screen must not lose the others.

### 3. Build and run (you run it)

```bash
flutter drive --profile --no-dds --endless-trace-buffer \
  --driver=test_driver/perf_driver.dart \
  --target=integration_test/<file>_perf_test.dart -d <device-id>   2>&1 | tee perf_runs/drive.<n>.log
```

Create `perf_runs/` first, and always write the full output to `perf_runs/drive.<n>.log` (PowerShell: `2>&1 | Tee-Object perf_runs/drive.<n>.log`) and filter only what you print. A failed drive's reason is in that log under `Failure Details`; never re-run a drive just to read an error you filtered away — in a real run that cost 9 minutes.

A failed drive still saves every trace it took (the driver uses `writeResponseOnFailure`), so a crash near the end loses only the screens after it. Read the log, fix the cause, check the fix with `PERF_ONLY` on the broken screen, and keep the saved runs: the next full sweep supplies the missing screens.

Use a long timeout: the first build takes 1–2 minutes, a sweep without taps about 2, a sweep that taps every target 7–8 on a 15-screen app. `--no-dds` avoids the binding's "DDS is enabled" connection error. Each run gets the next number in `perf_runs/`.

Keep device time down — every full sweep costs ~2 minutes without taps, and re-running it to debug one screen was the biggest waste in real runs:
1. Run the full sweep once. It measures every screen's open and scroll and then taps every safe target on each screen (`<screen>_tap<n>_<widget kind>`); this pass takes a few minutes longer because of the taps.
2. For every `SWEEP skipped <key>` line, read the matching `SWEEP visible <key>` line (the texts on screen when it failed), fix that entry's finders, and re-run **only the fixed screens**: add `--dart-define=PERF_ONLY=<key1>,<key2>`. Repeat until they pass; never re-run the whole sweep to debug one screen, and don't spend a run just to see what is on screen.
3. Run the full sweep a second time, repeating only the taps that came out WARN, FAIL or UNSURE in the summary (after one run every flagged tap is UNSURE): add `--dart-define=PERF_TAP_KEYS=<tap reportKeys>` (the keys as the summary prints them, e.g. `budget_remaining_tap3_iconbutton`), or `--dart-define=PERF_TAPS=false` when no tap was flagged. Passing tap keys takes this pass from ~8 minutes to ~2–3. Every open and scroll now has two runs and no flagged tap rests on one measurement.

`PERF_ONLY` runs are saved as `<key>__isolated`: a lone screen on a cool, idle phone measures faster than the same screen deep in a sweep, so isolated runs only prove a finder works. Never use them as a baseline, as a verdict, or in the report; the scripts refuse to mix them with sweep runs.

Every sweep first scrolls a plain 1000-row list (`_calibration_scroll`). It measures what this phone drops with no app code involved; the scripts subtract that **device floor** from every dropped-frames verdict, so the device's own limit is not reported as app jank. Read it as the phone's age: under 3 % the phone is fast enough to judge everything; 3–10 % it is an older phone, so say in the chat summary that newer phones will likely do better and that users on similar phones see these numbers; 10 % or more (the summary prints a WARNING) it is too slow to tell small app issues from its own limit, so report only FAIL verdicts as reliable and suggest confirming WARNs on a newer phone.

Before each sweep, check the phone's temperature with `adb shell dumpsys battery` (`temperature` is in tenths of °C). Over 38 °C, wait and poll every 30 s, for at most 5 minutes, until it drops below; a hot phone throttles and makes every screen look slower. Note the temperature of each sweep.

Check `SWEEP language: <tag>` at the top of the output: with `_appHasEnglish = true` it must start with `en`. Otherwise fix `_useEnglish` and re-run before reading any number. Each `SWEEP tap-key <key>: "<label>"` line pairs a tap key with the text it tapped; name report entries from it.

Collect from the output: `SWEEP tap-skipped <screen>: "<label>" — <reason>` lines go into the report's `skippedTaps`; `SWEEP tap-failed` and `SWEEP tap-moved` lines (a target that couldn't be tapped or moved between runs) into that screen's open items. `SWEEP skipped <key>: <reason>` lines go into the report's open items; `SWEEP seeded <key>` lines go into `seeded`; after `SWEEP cleanup-failed`, mark every seeded item as kept on the device and tell the user.

If the build fails with `java.io.IOException: Unable to establish loopback connection`, the JVM can't create its internal socket in the default temp directory (common inside sandboxed agent shells on Windows). Point it at a short directory it can write, and retry:

```bash
mkdir -p ~/.gradle/uds
export JAVA_TOOL_OPTIONS="-Djdk.net.unixdomain.tmpdir=$(cygpath -w ~/.gradle/uds 2>/dev/null || echo ~/.gradle/uds)"
```

Only if the build still can't run in your environment, hand the user one copy-paste command that runs the drive twice (steps chained with `&&`) and continue from `perf_runs/` when they say it's done.

### 4. Read the numbers

Start with one overview of every screen (one `dart` start instead of one per screen):

```bash
dart <skill-dir>/scripts/compare_perf.dart --summary=perf_runs --fps=<Hz>
```

It prints one line per reportKey — verdict, fps, dropped %, longest hitch, UI and Raster p90, runs, bottleneck — worst first. Look closer only at WARN and FAIL; they are the findings. UNSURE keys (one run stuttered, another didn't) are not findings: no issue, no fix prompt, no investigation — the report counts them in one line. A regression against `--baseline` likewise counts only when every new run is worse than every baseline run (5 points of dropped frames, or 3 missed frames on a short trace); a median jump that isn't in every run is printed as `not in every run`.

Look closer at a WARN or FAIL key with:

```bash
dart <skill-dir>/scripts/compare_perf.dart perf_runs/<key>.1.json perf_runs/<key>.2.json --fps=<Hz>
```

`<skill-dir>` is this skill's base directory. The script prints p50/p90/p99/worst per thread, **dropped frames %** and **delivered fps**, a **Bottleneck** and a **Verdict** (exit code 1 on FAIL). Options: `--baseline=<a.json>,<b.json>` compares against earlier runs and fails only when dropped frames grew by more than 5 points (thread p90s that grew past `--tolerance=10` % are marked `slower` as a hint, not a failure: they swing by 2–3 ms between identical runs), `--regression-only` fails only on regressions (for CI on an app that is already slow). Both runs must come from the same kind of drive: sweep with sweep.

The verdict follows what the user sees. Dropped frames = 1 − delivered fps ÷ refresh rate while the screen was busy; long gaps where no work overran are idle time and don't count. Each run is judged on its own: FAIL at ≥ 10 % dropped above the device floor, WARN at ≥ 3 % above it or a single hitch over 3 budgets. A trace under 60 frames (a screen opening, most taps) is too short for a percentage — one late frame in 30 is already 3 % — so it is judged by missed frames above the floor instead: FAIL at 6 or more, WARN at 3 or more. The key's verdict is the mildest of its runs, so a problem counts only when every run shows it; when one run stutters and another doesn't, the verdict is **UNSURE**: within the phone's noise, not a finding, not in the report's lists. On the Redmi Note 8 Pro, two runs of the same code differ by 2–3 points of dropped frames typically and up to 9, and this rule cut verdicts that changed between two sessions of unchanged code from 26 of 138 to 6. Thread p90s only name the bottleneck — on some GPUs raster time includes waiting for the display, so a raster p90 of 17–18 ms can still deliver 60 fps.

Treat every WARNING as a stop sign: "only N frames" on a multi-second action means events were dropped or the screen was off; a p50/p90 spread between runs means a noisy device (heat, battery saver, background apps) — fix the recording and re-run before reading percentiles.

### 5. Classify

| UI p90 > budget | Raster p90 > budget | Look at |
|---|---|---|
| yes | no | `references/ui-thread.md` |
| no | yes | `references/raster-thread.md` |
| yes | yes | both; the larger overrun first — fixing UI can raise raster load, since more frames get drawn |
| no | no, but hitches | one-off work: sync I/O or JSON decode on the UI isolate, image decode, first build of a heavy route, GC churn, shader compilation on Skia, platform views in lists |

### 6. Confirm the cause with evidence

```bash
dart <skill-dir>/scripts/timeline_top.dart perf_runs/<key>.1.timeline.json [--top=15]
```

It lists the events that took the most time, their counts and ms per frame (inclusive times; nested events overlap). `BUILD 28 ms/frame` points at Dart code, `Canvas::saveLayer ×16/frame` at offscreen layers, recurring `DecompressTexture` at image decoding. Match it to the code from step 1 and to the reference file for the thread. A finding without a number is a guess: keep for each the problem in one line, the `file:line`, the number that proves it, and the fix to recommend.

### 7. Report (HTML in the project root)

1. Write `perf_report.json` in the project root:

```json
{
  "app": "Monysa", "device": "Redmi Note 8 Pro · Android 11 · mt6785", "fps": 60, "backend": "Impeller (OpenGLES)",
  "deviceProfile": {"CPU": "8 cores, up to 2.05 GHz", "GPU": "Mali-G76 MC4, OpenGL ES 3.2", "RAM": "6 GB", "Screen": "1080×2340, 440 dpi", "Refresh rate": "60 Hz (max 60 Hz)", "State": "charging, 29 °C, battery saver off, not throttled"},
  "screens": [{
    "name": "Settings — scroll", "interaction": "fling the list down and up", "kind": "scroll",
    "runs": ["perf_runs/settings_scroll.1.json", "perf_runs/settings_scroll.2.json"],
    "baseline": [],
    "findings": [{"thread": "Raster", "problem": "…", "location": "lib/x.dart:42", "evidence": "Canvas::saveLayer 2/frame"}],
    "fixes": [{"status": "todo", "location": "lib/x.dart:42", "change": "…", "expect": "fewer dropped frames"}],
    "open": ["…"]
  }],
  "issues": [{"title": "…", "why": "…", "evidence": "…", "screens": ["Settings — scroll"],
              "location": "lib/x.dart:42", "fix": "…", "expect": "…", "prompt": "…"}],
  "seeded": [{"what": "1 goal \"Perf test goal\"", "screen": "Goal detail", "deleted": true}],
  "skippedTaps": [{"screen": "Settings", "label": "Reset all data", "reason": "destructive (\"reset\")"}],
  "fixPrompt": "…"
}
```

   - One `screens` entry per reportKey (`kind` `open`, `scroll` or `tap`; taps named like `Settings — tap "Theme"`), named the way a user would say it, in English with the app's English UI terms. The whole report is English; only the chat summary follows the user's language.
   - `issues` is the "fix these first" list the page leads with: findings that share a cause across screens, most impactful first, each with plain-language `why`, measured `evidence`, affected `screens`, `location`, `fix`, `expect` and its own self-contained `prompt`.
   - Up to five findings per screen, one line each; `open` holds at most three unconfirmed items. Screens that pass need no findings.
   - `fixes[].status`: `todo`, or after a re-measure `worked`, `worse` (recommend reverting) or `none` (no effect, recommend reverting).

2. Run `dart <skill-dir>/scripts/html_report.dart perf_report.json` from the project root. It computes every number from the run files with the same rules as `compare_perf.dart`, writes `perf_report.html` next to the JSON and opens it in the default browser (`--no-open` for CI, `--out=` for another path). The page lists only the screens that stutter; smooth ones are counted in one line. For each listed screen it shows the evidence: a per-frame chart against the budget and the top timeline events (read from the run's `.timeline.json`).
3. In chat, in the user's language: the report path, the smoothness score, how many screens stutter, and the top one or two issues — five lines at most.

A fix prompt must stand on its own: the project path, the measured numbers, the exact change per `file:line`, the measure and compare commands (tell the agent to copy `compare_perf.dart` into the repo if it won't run on this machine), the acceptance criterion (Verdict PASS, dropped frames under 3 %), and "revert any fix that makes its thread worse; change nothing else".

### 8. Verify a fix (when the user says one was applied)

Run the same drive the same number of times — full sweeps, same flags, phone at a similar temperature — and compare the new runs against the old ones with `--baseline`. A change smaller than the spread between the two baseline runs is no effect, not a win or a loss. Judge each fix by the thread it targeted and by per-run values, not only medians. Show with `timeline_top.dart` that the targeted event shrank. Regenerate the report with `runs` = new runs, `baseline` = old runs, and each fix's status. Recommend reverts; never revert yourself. When everything passes, offer to keep the new runs as the baseline.

## CI regression gate

When asked (writes CI and measurement files, never app code): copy `scripts/compare_perf.dart` into the repo (e.g. `tool/compare_perf.dart`); do an untraced warm-up pass before tracing; run the drive 3–5 times and compare medians against committed, device-specific baseline runs; add `--regression-only` if the app is already over budget and say so; pin the Flutter version; keep the device charged, awake and cool.

## Files

- `assets/perf_test.dart` — one-scenario test template.
- `assets/app_sweep_test.dart` — every screen's open and scroll, per-screen test data, recovery.
- `assets/perf_driver.dart` — host driver; numbered runs in `perf_runs/`.
- `scripts/compare_perf.dart` — numbers, verdict, baseline comparison; standalone, safe to copy into a repo.
- `scripts/timeline_top.dart` — where the time went in one trace.
- `scripts/html_report.dart` — the HTML report; imports the two scripts above, keep them side by side.
- `references/ui-thread.md`, `references/raster-thread.md` — how to confirm each cause and which fix to recommend.
