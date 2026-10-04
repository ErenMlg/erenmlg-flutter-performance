# Flutter Performance Tester

A [Claude Code](https://code.claude.com) skill that finds jank in a Flutter app on a real Android device and hands you an HTML report of the screens that stutter — how badly, why, where in the code, and a ready-to-paste prompt to fix it.

It **measures and reports; it never edits your app code.**

## What it does

Run `/erenmlg-flutter-performance` in a Flutter project with a phone attached. The skill then, on its own:

1. Finds the device and its refresh rate, and reads your app to list its screens.
2. Asks one question: should the data it adds to reach empty screens be deleted afterwards?
3. Writes a profile-mode integration test that opens, scrolls and taps every screen (`integration_test/app_sweep_perf_test.dart`) and a driver that saves each run. It taps every button, card, list item and toggle it can reach, except destructive ones (delete, reset, log out, pay…) and ones that leave the app (share, camera, files…); toggles are switched back and dialogs are closed without pressing their buttons. If the app has an English translation, the test runs it in English (without touching the phone's language setting), and every measurement key is English whatever language the app is in.
4. Builds, installs and runs it twice on the phone with `flutter drive --profile`.
5. Judges every screen by **dropped frames** against the device's real frame budget (16.7 ms at 60 Hz, 8.3 ms at 120 Hz) and confirms each cause with timeline evidence.
6. Writes `perf_report.html` in your project root and opens it in your browser.

The report leads with a smoothness score and a "fix these first" list; it lists only the screens that stutter, each with a per-frame chart, the events that took the time, the code location and a recommended fix. Every fix comes with a self-contained prompt you can give to any coding agent. After a fix, run the skill again to verify it: it compares against the earlier runs and marks each fix as worked, made it worse, or no effect.

## Requirements

- Claude Code
- Flutter SDK (Dart included) on the PATH
- An Android phone with USB debugging enabled, screen unlocked during the run (an emulator works, but its numbers are only indicative)

iOS devices are not tested yet.

## Install

As a plugin:

```
/plugin marketplace add ErenMlg/erenmlg-flutter-performance
/plugin install erenmlg-flutter-performance@erenmlg
```

Invoke it with `/erenmlg-flutter-performance:erenmlg-flutter-performance`.

Or copy the skill folder by hand:

```bash
git clone https://github.com/ErenMlg/erenmlg-flutter-performance
cp -r erenmlg-flutter-performance/skills/erenmlg-flutter-performance ~/.claude/skills/
```

Invoke it with `/erenmlg-flutter-performance`.

The skill only runs when you invoke it; it does not start by itself when you mention performance.

## What it writes into your project

| Path | What |
|---|---|
| `integration_test/*_perf_test.dart` | the measurement test |
| `test_driver/perf_driver.dart` | saves every run to `perf_runs/` |
| `perf_runs/` | frame summaries and full timelines (~10 MB per run; add it to `.gitignore`) |
| `perf_report.json`, `perf_report.html` | the report data and page |
| `pubspec.yaml` | `integration_test` and `flutter_driver` dev dependencies, if missing |

Nothing under `lib/` is touched. On the device, the test may add clearly named test data for screens that need it, and deletes it afterwards if you said so.

## How the verdict works

A screen is judged by what a user sees, not by raw thread timings:

| Dropped frames (1 − delivered fps ÷ refresh rate) | Verdict |
|---|---|
| under 3 % and no hitch over 3 frame budgets | Smooth (not listed) |
| 3 % or more, or one hitch over 3 budgets | Slightly janky |
| 10 % or more | Janky |

Every sweep starts by scrolling a plain list with no app code. What the phone drops there is its **device floor**; verdicts count only what the app drops above it, so an older phone's own limit is not blamed on your app.

Short actions (under 60 frames: screen openings, most taps) are judged by missed frames instead: 3 or more is slightly janky, 6 or more is janky. Every screen is measured at least twice and a problem counts only when every run shows it; one bad run next to a clean one is reported as **unsure** (within the phone's noise) and not listed. UI and Raster thread p90s name the bottleneck: the UI thread runs your Dart code, the Raster thread draws on the GPU.

## Scripts

The bundled Dart scripts also work on their own:

```bash
dart skills/erenmlg-flutter-performance/scripts/compare_perf.dart --summary=perf_runs --fps=60
dart skills/erenmlg-flutter-performance/scripts/compare_perf.dart perf_runs/home_scroll.1.json perf_runs/home_scroll.2.json --fps=60
dart skills/erenmlg-flutter-performance/scripts/timeline_top.dart perf_runs/home_scroll.1.timeline.json
dart skills/erenmlg-flutter-performance/scripts/html_report.dart perf_report.json
```

To re-measure only some screens, pass `--dart-define=PERF_ONLY=<reportKey base>,<...>` to `flutter drive`. Those runs are saved as `<key>__isolated` and are only for checking that a screen can be reached: a lone screen on an idle phone measures faster than inside a full sweep, so the scripts refuse to compare the two. Before/after comparisons are always full sweep against full sweep, and only a change in dropped frames counts as a regression.

`compare_perf.dart` exits with 1 on a failing verdict and accepts `--baseline=` and `--regression-only`, so it can gate CI.

## Troubleshooting

- **`Unable to establish loopback connection` during the Gradle build** (seen in sandboxed shells on Windows): the skill sets `JAVA_TOOL_OPTIONS=-Djdk.net.unixdomain.tmpdir=<~/.gradle/uds>` and retries.
- **"only N frames" warning**: the screen was off or locked during the run. Unlock the phone and run again.

## License

MIT
