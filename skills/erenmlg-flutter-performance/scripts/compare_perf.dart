// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'dart:math';

// Turns perf_driver.dart summaries into numbers and a verdict: per-thread
// percentiles, dropped frames, delivered fps, bottleneck and PASS / WARN /
// UNSURE / FAIL. Compares against baseline runs, and with --summary prints one
// line per reportKey for a whole perf_runs/ folder. Standalone so it can be
// copied into an app repo for CI; html_report.dart imports it.
const _usage =
    'usage: dart compare_perf.dart <run.json>... '
    '[--baseline=<run.json>[,<run.json>...]] [--fps=60] [--tolerance=10] '
    '[--regression-only]\n'
    '       dart compare_perf.dart --summary=<perf_runs dir> [--fps=60]';
// Rows printed per thread in the comparison table.
const _metrics = ['p50', 'p90', 'p99', 'worst', 'janky %'];

// Compare mode: judges the given runs of one reportKey, optionally against a
// baseline, and exits 1 on FAIL so CI can gate on it.
void main(List<String> args) {
  for (final arg in args.where((a) => a.startsWith('--'))) {
    if (!RegExp(
      r'^--((fps|tolerance|baseline|summary)=|regression-only$)',
    ).hasMatch(arg)) {
      _exit(_usage);
    }
  }
  final regressionOnly = args.contains('--regression-only');
  final runPaths = args.where((a) => !a.startsWith('--')).toList();
  final fps = _number(args, 'fps', 60);
  final summaryDir = _option(args, 'summary');
  if (summaryDir != null) {
    if (runPaths.isNotEmpty) _exit(_usage);
    exit(_summary(summaryDir, 1000 / fps));
  }
  if (runPaths.isEmpty) _exit(_usage);
  final tolerance = _number(args, 'tolerance', 10);
  final budget = 1000 / fps;
  // Noise allowance for run-to-run spread and `slower` marks: tolerance % of
  // the value, but never less than tolerance % of the budget.
  double allowed(double reference) => max(budget, reference) * tolerance / 100;
  final runs = [for (final p in runPaths) PerfRun.load(p)];
  final baseline = [
    for (final p in _option(args, 'baseline')?.split(',') ?? const <String>[])
      PerfRun.load(p),
  ];
  final paths = [...runPaths, for (final r in baseline) r.path];
  // Isolated runs measure faster than sweep runs; mixing them fakes a change.
  if (paths.map(isIsolated).toSet().length > 1) {
    _exit(
      'Cannot compare an isolated PERF_ONLY run (*__isolated*) with a full '
      'sweep run: the device load differs. Compare full sweep with full sweep.',
    );
  }
  final floor = deviceFloor(
    File(runPaths.first).parent.path,
    isolated: isIsolated(runPaths.first),
    budget: budget,
  );

  double value(List<PerfRun> set, String thread, String metric) =>
      median(set.map((r) => r.metric(thread, metric, budget)));

  print(
    'Budget ${_ms(budget)} ms at ${fps.round()} Hz | '
    '${runs.length} run(s)${baseline.isEmpty ? '' : ' vs ${baseline.length} baseline run(s)'}'
    '${runs.length > 1 ? ', medians' : ''}',
  );

  // Sanity warnings: too few frames, or the device ran at another refresh rate.
  for (final run in runs) {
    if (run.ui.length < 60) {
      print(
        'WARNING ${run.path}: only ${run.ui.length} frames; percentiles are '
        'unreliable. Lengthen the traced action.',
      );
    }
    final share = run.refreshShare(fps);
    if (share != null && share < 90) {
      print(
        'WARNING ${run.path}: only ${share.toStringAsFixed(0)}% of frames ran '
        'at ${fps.round()} Hz, so the ${_ms(budget)} ms budget may not match '
        'what the device did.',
      );
    }
  }
  // A large spread between runs means a noisy device; medians can't be trusted.
  for (final thread in ['UI', 'Raster']) {
    for (final metric in ['p50', 'p90']) {
      final values = runs.map((r) => r.metric(thread, metric, budget));
      final spread = values.reduce(max) - values.reduce(min);
      final limit = allowed(median(values));
      if (spread > limit) {
        print(
          'WARNING: $thread $metric varies by ${_ms(spread)} ms between '
          'runs (allowed ${_ms(limit)}). The environment is noisy; fix that '
          'before trusting a comparison.',
        );
      }
    }
  }
  // Far fewer frames than the baseline usually means the traced window shrank,
  // not that the screen got faster.
  if (baseline.isNotEmpty) {
    final now = median(runs.map((r) => r.ui.length.toDouble()));
    final before = median(baseline.map((r) => r.ui.length.toDouble()));
    if (now < before * 0.75) {
      print(
        'WARNING: frame count dropped from ${before.round()} to '
        '${now.round()}. The traced window may no longer cover the same '
        'work; the improvement may be fake.',
      );
    }
  }

  final header = StringBuffer('\n${'metric'.padRight(16)}${'now'.padLeft(9)}');
  if (baseline.isNotEmpty) {
    header.write('${'before'.padLeft(9)}${'delta'.padLeft(9)}');
  }
  print(header);

  // Percentile table. p90/p99 growth past the allowance is marked `slower` as a
  // hint only: thread times swing between identical runs.
  var regressed = false;
  for (final thread in ['UI', 'Raster']) {
    for (final metric in _metrics) {
      final now = value(runs, thread, metric);
      final row = StringBuffer(
        '${'$thread $metric'.padRight(16)}${_ms(now).padLeft(9)}',
      );
      if (baseline.isNotEmpty) {
        final before = value(baseline, thread, metric);
        final delta = now - before;
        row.write(
          '${_ms(before).padLeft(9)}'
          '${'${delta >= 0 ? '+' : ''}${_ms(delta)}'.padLeft(9)}',
        );
        if ((metric == 'p90' || metric == 'p99') && delta > allowed(before)) {
          row.write('  slower');
        }
      }
      print(row);
    }
  }

  // Dropped frames decide the verdict; a regression counts only when every new
  // run is worse than every baseline run (see pacingRegressed).
  final late = droppedPercent(runs, budget);
  if (late != null) {
    final fpsNow = median(runs.map((r) => r.pacing(budget).fps));
    final row = StringBuffer(
      '${'dropped %'.padRight(16)}${_ms(late).padLeft(9)}',
    );
    final lateBefore = droppedPercent(baseline, budget);
    if (lateBefore != null) {
      final delta = late - lateBefore;
      row.write(
        '${_ms(lateBefore).padLeft(9)}'
        '${'${delta >= 0 ? '+' : ''}${_ms(delta)}'.padLeft(9)}',
      );
      if (pacingRegressed(runs, baseline, budget)) {
        regressed = true;
        row.write('  REGRESSED');
      } else if (delta > 5) {
        row.write('  not in every run');
      }
    }
    print(row);
    print(
      '${'delivered fps'.padRight(16)}${fpsNow.toStringAsFixed(1).padLeft(9)}',
    );
  } else {
    print(
      'WARNING: no frame_rasterizer_begin_times in the summary; judging by '
      'thread p90 only.',
    );
  }

  print(
    '${'device floor %'.padRight(16)}${_ms(floor).padLeft(9)}'
    '  (dropped on a plain list; subtracted before judging)',
  );

  final result = judge(
    runs,
    budget,
    floor: floor,
    regressed: regressed,
    regressionOnly: regressionOnly,
  );
  final bottleneck = switch (result.bottleneck) {
    'both' => 'both UI and Raster threads',
    'ui' => 'UI thread',
    'raster' => 'Raster thread',
    'spikes' => 'spikes (single frames over budget)',
    _ => 'none (frames reach the screen on time)',
  };
  print('\nBottleneck: $bottleneck\nVerdict: ${result.verdict}');
  exit(result.verdict == 'FAIL' ? 1 : 0);
}

// The verdict rule, shared with --summary and html_report.dart. Each run gets a
// level (0 ok, 1 WARN, 2 FAIL) from dropped frames above the device floor, or
// from missed frames when the trace is short (under 60 frames). The key takes
// the mildest level; runs that disagree, or a single flagged run, give UNSURE.
({String verdict, String bottleneck, double? dropped, double fps, double hitch})
judge(
  List<PerfRun> runs,
  double budget, {
  double floor = 0,
  bool regressed = false,
  bool regressionOnly = false,
}) {
  bool over(String thread, String metric) =>
      median(runs.map((r) => r.metric(thread, metric, budget))) > budget;
  final dropped = droppedPercent(runs, budget);
  final hitch = runs.map((r) => r.pacing(budget).worstGap).reduce(max);
  final short =
      median(runs.map((r) => r.pacing(budget).frames.toDouble())) < 60;
  final uiSlow = over('UI', 'p90');
  final rasterSlow = over('Raster', 'p90');
  final spikes = over('UI', 'p99') || over('Raster', 'p99');
  // Level of one run. Short trace: frames it should have shown in its busy time
  // minus frames it showed. Long trace: dropped % minus the floor, or one hitch
  // longer than 3 budgets.
  int level(PerfRun run) {
    final p = run.pacing(budget);
    if (p.frames == 0) return 0;
    if (short) {
      final expected = p.frames * 1000 / (p.fps * budget);
      final missed = (expected * (1 - floor / 100) - p.frames).round();
      return missed >= 6
          ? 2
          : missed >= 3
          ? 1
          : 0;
    }
    final appDropped = max(0.0, 100 * (1 - p.fps * budget / 1000)) - floor;
    return appDropped >= 10
        ? 2
        : appDropped >= 3 || (p.worstGap / budget).round() > 3
        ? 1
        : 0;
  }

  // No raster begin times in the summary: fall back to thread p90/p99.
  final levels = dropped == null
      ? [
          uiSlow || rasterSlow
              ? 2
              : spikes
              ? 1
              : 0,
        ]
      : runs.map(level).toList();
  final lowest = levels.reduce(min);
  final unsure = levels.reduce(max) > 0 && (lowest == 0 || runs.length < 2);
  final bottleneck = lowest == 0 && !unsure
      ? 'none'
      : switch ((uiSlow, rasterSlow)) {
          (true, true) => 'both',
          (true, false) => 'ui',
          (false, true) => 'raster',
          _ => 'spikes',
        };
  final verdict = regressed || (lowest == 2 && !unsure && !regressionOnly)
      ? 'FAIL'
      : unsure
      ? 'UNSURE'
      : lowest > 0
      ? 'WARN'
      : 'PASS';
  return (
    verdict: verdict,
    bottleneck: bottleneck,
    dropped: dropped,
    fps: median(runs.map((r) => r.pacing(budget).fps)),
    hitch: hitch,
  );
}

// True when the best new run lost more than the worst baseline run, by 5
// points of dropped frames (3 missed frames on short traces).
bool pacingRegressed(List<PerfRun> now, List<PerfRun> was, double budget) {
  if (now.isEmpty || was.isEmpty) return false;
  final short =
      median([...now, ...was].map((r) => r.pacing(budget).frames.toDouble())) <
      60;
  double lost(PerfRun run) {
    final p = run.pacing(budget);
    if (p.frames == 0) return 0;
    return short
        ? p.frames * 1000 / (p.fps * budget) - p.frames
        : max(0.0, 100 * (1 - p.fps * budget / 1000));
  }

  return now.map(lost).reduce(min) - was.map(lost).reduce(max) >=
      (short ? 3 : 5);
}

// reportKey of the plain 1000-row list every sweep scrolls first.
const calibrationKey = '_calibration_scroll';

// PERF_ONLY runs are saved with the __isolated suffix.
bool isIsolated(String path) => path.contains('__isolated');

// Dropped % of the calibration runs in the same folder: what this phone drops
// with no app code. Isolated runs use their own calibration. 0 when missing.
double deviceFloor(
  String dir, {
  required bool isolated,
  required double budget,
}) {
  final key = isolated ? '${calibrationKey}__isolated' : calibrationKey;
  final folder = Directory(dir);
  if (!folder.existsSync()) return 0;
  final pattern = RegExp(
    '^${RegExp.escape(key)}'
    r'\.\d+\.json$',
  );
  final runs = [
    for (final file in folder.listSync().whereType<File>())
      if (pattern.hasMatch(file.uri.pathSegments.last)) PerfRun.load(file.path),
  ];
  return runs.isEmpty ? 0 : droppedPercent(runs, budget) ?? 0;
}

// Median dropped % over the runs (1 - delivered fps / refresh rate); null when
// no run has raster begin times.
double? droppedPercent(List<PerfRun> runs, double budget) {
  final rates = [
    for (final r in runs)
      if (r.pacing(budget) case (
        frames: final f,
        fps: final fps,
        worstGap: _,
      ) when f > 0)
        max(0.0, 100 * (1 - fps * budget / 1000)),
  ];
  return rates.isEmpty ? null : median(rates);
}

// One <key>.<n>.json summary written by perf_driver.dart.
class PerfRun {
  PerfRun(this.path, this.summary, this.ui, this.raster);

  // Reads a summary; exits with a clear message on a missing file, bad JSON or
  // a summary without frame times (a debug run or an empty trace).
  factory PerfRun.load(String path) {
    final Object? json;
    try {
      json = jsonDecode(File(path).readAsStringSync());
    } on FileSystemException catch (e) {
      _exit('$path: ${e.message}');
    } on FormatException catch (e) {
      _exit('$path: not valid JSON (${e.message})');
    }
    if (json is! Map<String, dynamic>) _exit('$path: expected a JSON object');
    final summary = json;
    List<double> times(String key) {
      final raw = summary[key];
      if (raw is! List || raw.isEmpty || raw.any((t) => t is! num)) {
        _exit(
          '$path: "$key" is missing or empty. Pass a *.timeline_summary.json '
          'from a --profile run whose traced action produced frames.',
        );
      }
      return [for (final us in raw) (us as num) / 1000]..sort();
    }

    return PerfRun(
      path,
      summary,
      times('frame_build_times'),
      times('frame_rasterizer_times'),
    );
  }

  final String path;
  final Map<String, dynamic> summary;

  // Sorted per-frame build (UI thread) and raster times, in ms.
  final List<double> ui, raster;

  // p50 / p90 / p99 / worst in ms, or 'janky %': share of frames over budget.
  double metric(String thread, String name, double budget) {
    final sorted = thread == 'UI' ? ui : raster;
    return switch (name) {
      'p50' => percentile(sorted, 50),
      'p90' => percentile(sorted, 90),
      'p99' => percentile(sorted, 99),
      'worst' => sorted.last,
      _ => sorted.where((t) => t > budget).length * 100 / sorted.length,
    };
  }

  // What the user saw: frames delivered and fps over the busy time, plus the
  // longest gap between frames. A long gap where no work overran the budget is
  // idle time (nothing to draw) and is skipped.
  ({int frames, double fps, double worstGap}) pacing(double budget) {
    List<num> list(String key) => [
      for (final v in (summary[key] as List?) ?? const [])
        if (v is num) v,
    ];
    final begins = list('frame_rasterizer_begin_times');
    final rasterTimes = list('frame_rasterizer_times');
    final buildTimes = list('frame_build_times');
    double ms(List<num> l, int i) => i >= 0 && i < l.length ? l[i] / 1000 : 0;
    var frames = 0;
    var active = 0.0, worst = 0.0;
    for (var i = 1; i < begins.length; i++) {
      final gap = (begins[i] - begins[i - 1]) / 1000;
      final work = [
        ms(rasterTimes, i),
        ms(buildTimes, i),
        ms(buildTimes, i - 1),
      ].reduce(max);
      if (gap > budget * 1.5 && work <= budget) continue;
      frames++;
      active += gap;
      if (gap > budget * 1.5) worst = max(worst, gap);
    }
    return (
      frames: frames,
      fps: active > 0 ? frames * 1000 / active : 0,
      worstGap: worst,
    );
  }

  // Share of frames that ran at the given refresh rate, from the summary's
  // <n>hz_frame_percentage fields; null when the engine didn't report them.
  double? refreshShare(double fps) {
    final rates = summary.entries.where(
      (e) => e.key.endsWith('hz_frame_percentage') && e.value is num,
    );
    if (!rates.any((e) => (e.value as num) > 0)) return null;
    final share = summary['${fps.round()}hz_frame_percentage'];
    return share is num ? share.toDouble() : 0;
  }
}

// Nearest-rank percentile of an already sorted list.
double percentile(List<double> sorted, int p) =>
    sorted[((sorted.length - 1) * p / 100).round()];

double median(Iterable<double> values) {
  final sorted = values.toList()..sort();
  final mid = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[mid]
      : (sorted[mid - 1] + sorted[mid]) / 2;
}

// Value of --name=value, or null when absent; exits on an empty value.
String? _option(List<String> args, String name) {
  final prefix = '--$name=';
  final arg = args.where((a) => a.startsWith(prefix)).firstOrNull;
  if (arg == null) return null;
  final value = arg.substring(prefix.length);
  if (value.isEmpty) _exit('--$name needs a value');
  return value;
}

// Positive numeric option with a default.
double _number(List<String> args, String name, double fallback) {
  final raw = _option(args, name);
  if (raw == null) return fallback;
  final value = double.tryParse(raw);
  if (value == null || value <= 0) _exit('--$name must be a positive number');
  return value;
}

String _ms(double ms) => ms.toStringAsFixed(2);

// Prints the error and exits with code 2 (usage or input error).
Never _exit(String message) {
  stderr.writeln(message);
  exit(2);
}

// --summary mode: groups <key>.<n>.json files by key, judges each key and
// prints one line per key, worst first (by verdict, then lowest fps). Exits 1
// when any key FAILs.
int _summary(String dir, double budget) {
  final folder = Directory(dir);
  if (!folder.existsSync()) _exit('$dir: no such directory');
  final byKey = <String, List<String>>{};
  for (final file in folder.listSync().whereType<File>()) {
    final name = file.uri.pathSegments.last;
    final match = RegExp(r'^(.+)\.(\d+)\.json$').firstMatch(name);
    if (match == null || name.endsWith('.timeline.json')) continue;
    (byKey[match.group(1)!] ??= []).add(file.path);
  }
  if (byKey.isEmpty) _exit('$dir: no <reportKey>.<n>.json summaries');
  final floor = deviceFloor(dir, isolated: false, budget: budget);
  final isolatedFloor = deviceFloor(dir, isolated: true, budget: budget);
  const rank = {'FAIL': 0, 'WARN': 1, 'UNSURE': 2, 'PASS': 3};
  final rows =
      [
        for (final MapEntry(:key, :value) in byKey.entries)
          () {
            final runs = [for (final p in value..sort()) PerfRun.load(p)];
            double p90(String thread) =>
                median(runs.map((r) => r.metric(thread, 'p90', budget)));
            return (
              key: key,
              runs: runs.length,
              result: judge(
                runs,
                budget,
                floor: isIsolated(key) ? isolatedFloor : floor,
              ),
              ui: p90('UI'),
              raster: p90('Raster'),
            );
          }(),
      ]..sort((a, b) {
        final byVerdict = rank[a.result.verdict]!.compareTo(
          rank[b.result.verdict]!,
        );
        return byVerdict != 0
            ? byVerdict
            : a.result.fps.compareTo(b.result.fps);
      });
  print(
    'Budget ${_ms(budget)} ms at ${(1000 / budget).round()} Hz | ${rows.length} reportKeys',
  );
  print(
    'Device floor: ${_ms(floor)} % dropped on a plain list '
    '(isolated runs: ${_ms(isolatedFloor)} %); verdicts subtract it. '
    'Never compare a *__isolated key with a full sweep key.\n',
  );
  if (floor >= 10) {
    print(
      'WARNING: this phone drops ${_ms(floor)} % on a plain list; it is too '
      'slow to tell small app issues from its own limit. Trust only FAIL '
      'verdicts here and confirm WARNs on a newer phone.\n',
    );
  }
  print(
    '${'verdict'.padRight(8)}${'fps'.padLeft(6)}${'drop%'.padLeft(7)}'
    '${'hitch'.padLeft(8)}${'UI p90'.padLeft(8)}${'R p90'.padLeft(8)}'
    '${'runs'.padLeft(5)}  bottleneck  reportKey',
  );
  for (final r in rows) {
    final dropped = r.result.dropped;
    print(
      '${r.result.verdict.padRight(8)}'
      '${r.result.fps.toStringAsFixed(1).padLeft(6)}'
      '${(dropped == null ? '-' : dropped.toStringAsFixed(1)).padLeft(7)}'
      '${r.result.hitch.toStringAsFixed(0).padLeft(8)}'
      '${_ms(r.ui).padLeft(8)}${_ms(r.raster).padLeft(8)}'
      '${'${r.runs}'.padLeft(5)}  ${r.result.bottleneck.padRight(10)}  ${r.key}',
    );
  }
  return rows.any((r) => r.result.verdict == 'FAIL') ? 1 : 0;
}
