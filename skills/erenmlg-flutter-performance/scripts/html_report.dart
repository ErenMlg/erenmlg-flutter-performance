// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'compare_perf.dart' as perf;
import 'timeline_top.dart' as tl;

// Builds perf_report.html from perf_report.json. Every number is recomputed
// from the run files with compare_perf.dart's rules, so the page can't show a
// figure typed by hand; the JSON supplies only names, findings, fixes and
// prompts. Imports compare_perf.dart and timeline_top.dart: keep the three
// files side by side.
const _usage =
    'usage: dart html_report.dart <report.json> [--out=perf_report.html] [--no-open]';

// Wrapper events that contain the real work; hidden from the evidence table
// because they would always top it.
const _containerEvents = {
  'VsyncProcessCallback',
  'Animator::BeginFrame',
  'Animator::Render',
  'Animator::DrawLastLayerTrees',
  'GPURasterizer::Draw',
  'Rasterizer::DoDraw',
  'Rasterizer::DrawToSurfaces',
  'Frame',
  'PipelineProduce',
  'PipelineItem',
};

// Plain-language captions for common timeline events in the evidence table.
const _eventMeaning = {
  'BUILD': 'building widgets (Dart)',
  'LAYOUT': 'measuring and positioning widgets',
  'PAINT': 'recording what to draw',
  'SEMANTICS': 'accessibility tree',
  'UPDATING COMPOSITING BITS': 'layer bookkeeping',
  'FINALIZE TREE': 'unmounting widgets',
  'Canvas::saveLayer': 'offscreen layer (Opacity, clip, shader mask)',
  'DecompressTexture': 'image decode',
  'ImageDecoder::Decode': 'image decode',
  'Scavenge': 'garbage collection',
  'CollectNewGeneration': 'garbage collection',
  'CollectOldGeneration': 'garbage collection',
  'ConcurrentMark': 'garbage collection',
  'SurfaceFrame::Submit': 'sending the frame to the GPU',
  'SurfaceFrame::Encode': 'encoding GPU commands',
  'ReactorGLES::React': 'GPU work (OpenGL ES)',
  'RenderPassGLES::EncodeCommandsInReactor': 'GPU render pass',
};

// Validates the report JSON, judges every screen, writes the page, prints one
// line per screen and opens the page unless --no-open is given.
void main(List<String> args) {
  final paths = args.where((a) => !a.startsWith('--')).toList();
  final flags = args.where((a) => a.startsWith('--')).toList();
  if (paths.length != 1 ||
      flags.any((f) => !f.startsWith('--out=') && f != '--no-open')) {
    _exit(_usage);
  }
  final jsonFile = File(paths.single);
  final Map<String, dynamic> report;
  try {
    final decoded = jsonDecode(jsonFile.readAsStringSync());
    if (decoded is! Map<String, dynamic>) {
      _exit('${jsonFile.path}: expected a JSON object');
    }
    report = decoded;
  } on FileSystemException catch (e) {
    _exit('${jsonFile.path}: ${e.message}');
  } on FormatException catch (e) {
    _exit('${jsonFile.path}: not valid JSON (${e.message})');
  }
  final fps = report['fps'];
  final screens = report['screens'];
  if (fps is! num || fps <= 0) _exit('"fps" must be a positive number');
  if (screens is! List || screens.isEmpty) {
    _exit('"screens" must be a non-empty list');
  }
  final budget = 1000 / fps;
  final dir = jsonFile.parent.path;

  final built = [
    for (final s in screens)
      if (s is Map<String, dynamic>)
        _Screen(s, dir, budget, fps.toDouble())
      else
        _exit('every entry in "screens" must be an object'),
  ];

  final outFlag = flags.where((f) => f.startsWith('--out=')).firstOrNull;
  final out = outFlag == null
      ? '$dir${Platform.pathSeparator}perf_report.html'
      : outFlag.substring(6);
  File(out).writeAsStringSync(_page(report, built, budget));
  print('Wrote $out (${built.length} measurement(s))');
  for (final s in built) {
    print('  ${s.verdict.padRight(4)} ${s.fpsText.padLeft(3)} fps  ${s.name}');
  }
  if (!flags.contains('--no-open')) _openInBrowser(out);
}

// Opens the page with the OS default handler; on failure prints the path
// instead of failing the run.
void _openInBrowser(String path) {
  final file = File(path).absolute.path;
  final (command, arguments) = Platform.isWindows
      ? ('cmd', ['/c', 'start', '', file])
      : Platform.isMacOS
      ? ('open', [file])
      : ('xdg-open', [file]);
  try {
    final result = Process.runSync(command, arguments);
    print(
      result.exitCode == 0
          ? 'Opened in the default browser'
          : 'Could not open a browser (exit ${result.exitCode}); open $file yourself.',
    );
  } on ProcessException catch (e) {
    print('Could not open a browser (${e.message}); open $file yourself.');
  }
}

// Same shape as the result of compare_perf's judge().
typedef _Judged = ({
  String verdict,
  String bottleneck,
  double? dropped,
  double fps,
  double hitch,
});

// One `screens` entry of the report with its runs and baseline loaded and
// judged.
class _Screen {
  _Screen(this.raw, this.dir, this.budget, double fps)
    : name = '${raw['name'] ?? '?'}' {
    List<perf.PerfRun> load(Object? list) => [
      if (list is List)
        for (final p in list) perf.PerfRun.load(_join(dir, '$p')),
    ];
    runs = load(raw['runs']);
    baseline = load(raw['baseline']);
    if (runs.isEmpty) _exit('screen "$name": "runs" is empty');
    if ({
          ...runs,
          ...baseline,
        }.map((r) => perf.isIsolated(r.path)).toSet().length >
        1) {
      _exit(
        'screen "$name": mixes isolated PERF_ONLY runs with full sweep runs; '
        'compare full sweep with full sweep',
      );
    }
    floor = perf.deviceFloor(
      File(runs.first.path).parent.path,
      isolated: perf.isIsolated(runs.first.path),
      budget: budget,
    );
    for (final r in runs) {
      final share = r.refreshShare(fps);
      if (share != null && share < 90) {
        warnings.add(
          '${r.path}: ${share.toStringAsFixed(0)}% of frames at '
          '${fps.round()} Hz',
        );
      }
    }
    if (baseline.isNotEmpty) {
      before = perf.judge(baseline, budget, floor: floor);
    }
    regressed = perf.pacingRegressed(runs, baseline, budget);
    result = perf.judge(runs, budget, floor: floor, regressed: regressed);
    frames = perf
        .median(runs.map((r) => r.pacing(budget).frames.toDouble()))
        .round();
  }

  final Map<String, dynamic> raw;
  final String dir;
  final String name;
  final double budget;
  late final List<perf.PerfRun> runs;
  late final List<perf.PerfRun> baseline;
  late final double floor;
  final warnings = <String>[];
  late final bool regressed;
  late final _Judged result;
  _Judged? before;
  late final int frames;

  // Short traces (most opens and taps) have no meaningful percentage; they are
  // judged by missed frames and left out of the score.
  bool get short => frames < 60 || result.dropped == null;
  String get verdict => result.verdict;
  String get fpsText => result.fps.toStringAsFixed(0);
  double get onTime => 100 - (result.dropped ?? 0);
  // On-time share with the device floor added back: what the app alone costs.
  double get appOnTime => min(100, onTime + floor);

  double value(List<perf.PerfRun> set, String thread, String metric) =>
      perf.median(set.map((r) => r.metric(thread, metric, budget)));

  // Per-frame time of the first run (the slower of UI and Raster) for the chart.
  List<double> frameTimes() {
    List<num> list(String key) => [
      for (final v in (runs.first.summary[key] as List?) ?? const [])
        if (v is num) v,
    ];
    final build = list('frame_build_times');
    final raster = list('frame_rasterizer_times');
    final n = max(build.length, raster.length);
    double at(List<num> l, int i) => i < l.length ? l[i] / 1000 : 0;
    return [for (var i = 0; i < n; i++) max(at(build, i), at(raster, i))];
  }

  // Top events of the first run's full trace; null when its .timeline.json is
  // missing.
  tl.TimelineTop? timeline() {
    final path = runs.first.path.replaceFirst(
      RegExp(r'\.json$'),
      '.timeline.json',
    );
    if (!File(path).existsSync()) return null;
    return tl.readTimeline(path, onError: (m) => throw StateError(m));
  }
}

// Resolves run paths relative to the report's folder.
String _join(String dir, String path) =>
    File(path).isAbsolute ? path : '$dir${Platform.pathSeparator}$path';

// The whole page, top to bottom: header, smoothness score, "fix these first"
// issues, table of stuttering screens, per-screen details, skipped taps, test
// data, device profile, glossary and the fix prompt.
String _page(
  Map<String, dynamic> report,
  List<_Screen> screens,
  double budget,
) {
  String n1(double v) => v.toStringAsFixed(v.abs() >= 100 ? 0 : 1);
  final hz = (1000 / budget).round();
  const rank = {'FAIL': 0, 'WARN': 1, 'UNSURE': 2, 'PASS': 3};
  final ordered = [...screens]
    ..sort((a, b) {
      final byVerdict = rank[a.verdict]!.compareTo(rank[b.verdict]!);
      return byVerdict != 0 ? byVerdict : a.result.fps.compareTo(b.result.fps);
    });
  final bad = ordered.where((s) => s.verdict == 'FAIL').toList();
  final warn = ordered.where((s) => s.verdict == 'WARN').toList();
  final smooth = ordered.where((s) => s.verdict == 'PASS').length;
  final unsure = ordered.where((s) => s.verdict == 'UNSURE').length;
  final listed = [...bad, ...warn];

  // Smoothness score: on-time share of the long traces, weighted by frame count.
  var weight = 0.0, onTime = 0.0;
  for (final s in screens) {
    if (s.short) continue;
    weight += s.frames;
    onTime += s.frames * s.appOnTime;
  }
  final score = weight == 0 ? 100 : (onTime / weight).floor();
  final scoreClass = score >= 97
      ? 'good'
      : score >= 90
      ? 'warn'
      : 'bad';
  final scoreLabel = score >= 97
      ? 'Smooth'
      : score >= 90
      ? 'Needs work'
      : 'Janky';
  final sentence = listed.isEmpty
      ? 'All ${screens.length} measurements reach the screen on time.'
      : '${bad.length} of ${screens.length} measurements stutter noticeably, '
            '${warn.length} slightly. Worst: ${listed.first.name} at '
            '${listed.first.fpsText} fps.';

  final app = _e('${report['app'] ?? ''}');
  final b = StringBuffer()
    ..writeln('<!doctype html><html lang="en"><head><meta charset="utf-8">')
    ..writeln(
      '<meta name="viewport" content="width=device-width,initial-scale=1">',
    )
    ..writeln('<title>Performance report · $app</title>')
    ..writeln('<style>$_css</style></head><body><main>')
    ..writeln(
      '<header><p class="eyebrow">Performance report</p><h1>$app</h1>'
      '<p class="meta">${_e('${report['device'] ?? ''}')} · $hz Hz · '
      '${_e('${report['backend'] ?? ''}')} · profile mode on a physical device · '
      '${DateTime.now().toIso8601String().substring(0, 10)}</p></header>',
    );

  final deviceFloor = screens.isEmpty ? 0.0 : screens.first.floor;
  final floorNote = deviceFloor < 0.05
      ? ''
      : '. This phone drops ${deviceFloor.toStringAsFixed(1)}% of frames even '
            'on a plain list; that share is not counted against the app. '
            'Users on newer phones will likely see fewer dropped frames; '
            'users on phones like this one see these numbers.';
  // Score ring: the r=52 circle's stroke is filled in proportion to the score.
  const circ = 2 * pi * 52;
  b.writeln(
    '<section class="hero card"><div class="score">'
    '<svg viewBox="0 0 120 120" role="img" aria-label="Smoothness score: $score / 100">'
    '<circle cx="60" cy="60" r="52" class="ring-bg"/>'
    '<circle cx="60" cy="60" r="52" class="ring $scoreClass" stroke-dasharray="'
    '${(circ * score / 100).toStringAsFixed(1)} ${circ.toStringAsFixed(1)}"/>'
    '<text x="60" y="58" class="ring-num">$score</text>'
    '<text x="60" y="82" class="ring-sub">/ 100</text></svg>'
    '<div><p class="eyebrow">Smoothness score</p>'
    '<p class="score-label $scoreClass">$scoreLabel</p>'
    '<p class="lede">${_e(sentence)}</p>'
    '<p class="legend"><span class="dot bad"></span>0–89 Janky'
    '<span class="dot warn"></span>90–96 Needs work'
    '<span class="dot good"></span>97+ Smooth'
    '<br><small>Share of frames the app delivers on time$floorNote</small></p></div></div>'
    '<div class="buckets">',
  );
  for (final (cls, label, list) in [
    ('bad', 'Janky', bad),
    ('warn', 'Slightly janky', warn),
  ]) {
    b.writeln(
      '<div class="bucket $cls"><p class="bucket-head">'
      '<span class="dot $cls"></span>$label <b>${list.length}</b></p><ul>',
    );
    for (final s in list) {
      b.writeln(
        '<li><a href="#${_id(s.name)}">${_e(s.name)}</a>'
        '<span class="n">${s.fpsText} fps</span></li>',
      );
    }
    if (list.isEmpty) b.writeln('<li class="muted">none</li>');
    b.writeln('</ul></div>');
  }
  b.writeln(
    '<p class="smooth-note"><span class="dot good"></span>$smooth '
    'measurement${smooth == 1 ? '' : 's'} run smoothly and are not listed.</p>'
    '${unsure == 0 ? '' : '<p class="smooth-note"><span class="dot"></span>$unsure '
              'stuttered in one run but not in another, which is within this '
              "phone's noise, so they are not listed.</p>"}'
    '</div></section>',
  );

  // Issues shared across screens, each with a copy button for its own prompt.
  final issues = report['issues'];
  if (issues is List && issues.isNotEmpty) {
    b.writeln('<section><h2>Fix these first</h2><div class="issues">');
    var i = 0;
    for (final issue in issues.whereType<Map<String, dynamic>>()) {
      i++;
      final affected = issue['screens'] is List
          ? issue['screens'] as List
          : const [];
      b.writeln(
        '<article class="issue card"><div class="issue-head">'
        '<span class="num ${i == 1 ? 'bad' : 'warn'}">$i</span><div>'
        '<h3>${_e('${issue['title'] ?? ''}')}</h3>'
        '${issue['why'] == null ? '' : '<p>${_e('${issue['why']}')}</p>'}</div></div>',
      );
      if (affected.isNotEmpty) {
        b.writeln(
          '<p class="chips"><span class="muted">Affects ${affected.length} '
          'screen${affected.length == 1 ? '' : 's'}:</span> '
          '${affected.map((a) => '<a class="chip" href="#${_id('$a')}">${_e('$a')}</a>').join(' ')}</p>',
        );
      }
      final rows = [
        if (issue['evidence'] != null)
          '<dt>Evidence</dt><dd>${_e('${issue['evidence']}')}</dd>',
        if (issue['location'] != null)
          '<dt>Where</dt><dd><code>${_e('${issue['location']}')}</code></dd>',
        if (issue['fix'] != null)
          '<dt>How to fix</dt><dd>${_e('${issue['fix']}')}</dd>',
        if (issue['expect'] != null)
          '<dt>Expected</dt><dd>${_e('${issue['expect']}')}</dd>',
      ];
      if (rows.isNotEmpty) b.writeln('<dl class="fix">${rows.join()}</dl>');
      if (issue['prompt'] is String) {
        b.writeln(
          '<button type="button" class="copy" data-copy="'
          '${_e('${issue['prompt']}')}">Copy prompt</button>',
        );
      }
      b.writeln('</article>');
    }
    b.writeln('</div></section>');
  }

  // Only FAIL and WARN screens are listed; PASS and UNSURE are counted above.
  if (listed.isNotEmpty) {
    b.writeln(
      '<section><h2>Screens that stutter</h2><div class="card scroll"><table class="list">'
      '<thead><tr><th>Screen</th><th>Status</th><th>Frame rate</th>'
      '<th>Frames on time</th><th>Where the time goes</th><th>UI / Raster p90</th></tr></thead><tbody>',
    );
    for (final s in listed) {
      final ui = s.value(s.runs, 'UI', 'p90');
      final raster = s.value(s.runs, 'Raster', 'p90');
      final interaction = s.raw['interaction'];
      b.writeln(
        '<tr><td><a href="#${_id(s.name)}">${_e(s.name)}</a>'
        '${interaction == null ? '' : '<small>${_e('$interaction')}</small>'}</td>'
        '<td>${_pill(s.verdict)}</td>'
        '<td class="fpscell"><b class="n">${s.fpsText}</b><small> / $hz</small></td>'
        '<td>${s.short ? '<small class="muted">short — judged by missed frames</small>' : _bar(s.onTime)}</td>'
        '<td>${_bottleneck(s.result.bottleneck)}'
        '${s.regressed ? '<small class="badtext">worse than before</small>' : ''}</td>'
        '<td class="n">${n1(ui)} / <span class="${raster > budget ? 'badtext' : ''}">'
        '${n1(raster)}</span> ms</td></tr>',
      );
    }
    b.writeln('</tbody></table></div></section>');

    b.writeln('<section><h2>Screen details and evidence</h2>');
    for (final s in listed) {
      _details(b, s, budget, hz, n1);
    }
    b.writeln('</section>');
  }

  final skippedTaps = report['skippedTaps'];
  if (skippedTaps is List && skippedTaps.isNotEmpty) {
    b.writeln(
      '<section><h2>Not tapped</h2><div class="card pad">'
      '<p class="muted">Every other tappable element was tapped and measured. '
      'These were left alone on purpose.</p><ul class="items">',
    );
    for (final t in skippedTaps.whereType<Map<String, dynamic>>()) {
      b.writeln(
        '<li><b>${_e('${t['label'] ?? ''}')}</b>'
        '${t['screen'] == null ? '' : ' <span class="muted">— ${_e('${t['screen']}')}</span>'}'
        ' <span class="tag">${_e('${t['reason'] ?? ''}')}</span></li>',
      );
    }
    b.writeln('</ul></div></section>');
  }

  final seeded = report['seeded'];
  if (seeded is List && seeded.isNotEmpty) {
    b.writeln(
      '<section><h2>Test data</h2><div class="card pad">'
      '<p class="muted">The test added this data to reach every screen.</p><ul class="items">',
    );
    for (final d in seeded.whereType<Map<String, dynamic>>()) {
      b.writeln(
        '<li>${_e('${d['what'] ?? ''}')}'
        '${d['screen'] == null ? '' : ' <span class="muted">— ${_e('${d['screen']}')}</span>'}'
        ' <span class="tag">${d['deleted'] == true ? 'deleted after the test' : 'kept on the device'}</span></li>',
      );
    }
    b.writeln('</ul></div></section>');
  }

  final profile = report['deviceProfile'];
  if (profile is Map<String, dynamic> && profile.isNotEmpty) {
    b.writeln(
      '<section><details class="card glossary"><summary>Test device — '
      '${_e('${report['device'] ?? ''}')}</summary><dl>',
    );
    for (final MapEntry(:key, :value) in profile.entries) {
      b.writeln('<dt>${_e(key)}</dt><dd>${_e('$value')}</dd>');
    }
    b.writeln(
      '<dt>Measured floor</dt><dd>${deviceFloor.toStringAsFixed(1)} % frames '
      'dropped on a plain list with no app code: the best this phone '
      'delivers, subtracted from every verdict.</dd></dl></details></section>',
    );
  }

  b.writeln(
    '<section><details class="card glossary"><summary>What do these numbers mean?</summary><dl>'
    '<dt>Frame rate</dt><dd>Frames per second while the screen was moving. The screen refreshes $hz times a second; $hz fps is perfectly smooth.</dd>'
    '<dt>Frames on time</dt><dd>Refreshes that showed a new frame. 97 % and more feels smooth; under 90 % feels janky.</dd>'
    '<dt>Longest hitch</dt><dd>The longest single freeze. Over ${(budget * 3).round()} ms is noticeable, over ${(budget * 6).round()} ms feels like a stall.</dd>'
    '<dt>UI / Raster</dt><dd>Flutter builds each frame on the UI thread (your Dart code) and draws it on the Raster thread (the GPU side). Each must finish within ${n1(budget)} ms. The slower one is where to look.</dd>'
    '<dt>p90</dt><dd>90 % of frames took this long or less. It ignores rare spikes but not frequent ones.</dd>'
    '<dt>Where the time goes</dt><dd>The events in the recorded trace that took the most time, averaged per frame. They are the evidence behind each finding.</dd>'
    '</dl></details></section>',
  );

  final prompt = report['fixPrompt'];
  if (prompt is String && prompt.trim().isNotEmpty) {
    b.writeln(
      '<section><h2>Fix prompt — paste to an agent</h2><div class="card prompt">'
      '<button type="button" class="copy" data-copy="${_e(prompt)}">Copy prompt</button>'
      '<pre>${_e(prompt)}</pre></div></section>',
    );
  }
  // Copy buttons: one delegated click handler copies data-copy to the clipboard.
  b.writeln(
    '</main><script>document.addEventListener("click",function(ev){'
    'var b=ev.target.closest("button.copy");if(!b)return;'
    'var text=b.getAttribute("data-copy"),label=b.textContent;'
    'var done=function(){b.textContent="Copied";'
    'setTimeout(function(){b.textContent=label;},1500);};'
    'if(navigator.clipboard){navigator.clipboard.writeText(text).then(done,function(){});}'
    '});</script></body></html>',
  );
  return b.toString();
}

// One screen's collapsible card: user-facing KPIs, frame chart, top timeline
// events, thread gauges and percentile table, then the findings, fixes and
// open items from the JSON. FAIL cards start open.
void _details(
  StringBuffer b,
  _Screen s,
  double budget,
  int hz,
  String Function(double) n1,
) {
  final hasBase = s.baseline.isNotEmpty;
  final hitch = s.result.hitch;
  b.writeln(
    '<details class="card screen" id="${_id(s.name)}"'
    '${s.verdict == 'FAIL' ? ' open' : ''}><summary>'
    '<span class="sname">${_e(s.name)}</span>${_pill(s.verdict)}'
    '<span class="n muted">${s.fpsText} fps</span></summary><div class="body">',
  );
  b.writeln(
    '<p class="eyebrow">What the user sees</p><div class="kpis">'
    '<div><span class="kv n">${s.fpsText}<small> fps</small></span>'
    '<span class="kl">Frame rate (of $hz)</span></div>'
    '<div><span class="kv n">${s.short ? '—' : '${n1(s.result.dropped!)}<small> %</small>'}</span>'
    '<span class="kl">Dropped frames</span></div>'
    '<div><span class="kv n ${hitch > budget * 3 ? 'badtext' : ''}">'
    '${hitch == 0 ? '—' : '${n1(hitch)}<small> ms</small>'}</span>'
    '<span class="kl">Longest hitch</span></div></div>',
  );
  if (s.before case final was?) {
    b.writeln(
      '<p class="muted">Before: ${was.fps.toStringAsFixed(0)} fps → '
      'after: ${s.fpsText} fps</p>',
    );
  }

  b.writeln('<p class="eyebrow">Evidence</p>');
  b.writeln(_frameChart(s.frameTimes(), budget));
  final timeline = s.timeline();
  if (timeline != null && timeline.frames > 0) {
    final events = timeline.events
        .where((e) => !_containerEvents.contains(e.name))
        .take(6)
        .toList();
    b.writeln(
      '<div class="scroll"><table class="metrics"><thead><tr>'
      '<th>Where the time goes</th><th>ms per frame</th><th>count</th>'
      '</tr></thead><tbody>',
    );
    for (final e in events) {
      final perFrame = e.totalMs / timeline.frames;
      final meaning = _eventMeaning[e.name];
      b.writeln(
        '<tr><td><code>${_e(e.name)}</code>'
        '${meaning == null ? '' : '<small>${_e(meaning)}</small>'}</td>'
        '<td class="n ${perFrame > budget ? 'badtext' : ''}">${perFrame.toStringAsFixed(2)}</td>'
        '<td class="n muted">${e.count}</td></tr>',
      );
    }
    b.writeln(
      '</tbody></table></div><p class="muted small">From '
      '${_e(File(s.runs.first.path).uri.pathSegments.last.replaceFirst('.json', '.timeline.json'))}: '
      '${timeline.frames} frames over ${timeline.seconds.toStringAsFixed(1)} s. '
      'Times are inclusive; nested events overlap.</p>',
    );
  }

  b.writeln('<p class="eyebrow">Diagnosis (for developers)</p>');
  for (final th in ['UI', 'Raster']) {
    final v = s.value(s.runs, th, 'p90');
    final scale = max(v, budget * 2);
    b.writeln(
      '<div class="gauge"><span class="gl">$th p90</span><div class="track">'
      '<div class="fill ${v > budget ? 'over' : 'ok'}" style="width:'
      '${(v / scale * 100).toStringAsFixed(1)}%"></div><div class="mark" style="left:'
      '${(budget / scale * 100).toStringAsFixed(1)}%" title="Budget ${n1(budget)} ms"></div>'
      '</div><span class="gv n">${n1(v)} ms</span></div>',
    );
  }
  b.writeln(
    '<div class="scroll"><table class="metrics"><thead><tr><th>Metric</th>'
    '${hasBase ? '<th>Before</th><th>After</th>' : '<th>Measured</th>'}'
    '<th>Budget</th></tr></thead><tbody>',
  );
  for (final th in ['UI', 'Raster']) {
    for (final m in ['p50', 'p90', 'p99', 'worst']) {
      String cell(double v) =>
          '<td class="n ${m != 'p50' && v > budget ? 'badtext' : ''}">'
          '${n1(v)} ms</td>';
      b.writeln(
        '<tr><td>$th $m</td>'
        '${hasBase ? cell(s.value(s.baseline, th, m)) : ''}${cell(s.value(s.runs, th, m))}'
        '<td class="n muted">${n1(budget)} ms</td></tr>',
      );
    }
  }
  b.writeln(
    '</tbody></table></div><p class="muted small">${s.runs.length} '
    'run${s.runs.length == 1 ? '' : 's'} · ${s.frames} frames</p>',
  );
  if (s.warnings.isNotEmpty) {
    b.writeln(
      '<div class="note"><b>Measurement notes</b><ul>'
      '${s.warnings.map((w) => '<li>${_e(w)}</li>').join()}</ul></div>',
    );
  }
  final findings = s.raw['findings'];
  if (findings is List && findings.isNotEmpty) {
    b.writeln('<p class="eyebrow">Findings</p><ol class="items">');
    for (final f in findings.whereType<Map<String, dynamic>>()) {
      b.writeln(
        '<li><span class="tag">${_e('${f['thread'] ?? ''}')}</span> '
        '${_e('${f['problem'] ?? ''}')}'
        '${f['location'] == null ? '' : ' <code>${_e('${f['location']}')}</code>'}'
        '${f['evidence'] == null ? '' : '<div class="muted small">evidence: ${_e('${f['evidence']}')}</div>'}</li>',
      );
    }
    b.writeln('</ol>');
  }
  final fixes = s.raw['fixes'];
  if (fixes is List && fixes.isNotEmpty) {
    b.writeln('<p class="eyebrow">Recommended fixes</p><ol class="items">');
    for (final f in fixes.whereType<Map<String, dynamic>>()) {
      final (icon, label) = switch ('${f['status'] ?? 'todo'}') {
        'worked' => ('✅', 'worked'),
        'worse' => ('↩', 'made it worse — revert'),
        'none' => ('➖', 'no effect — revert'),
        _ => ('⬜', 'not applied'),
      };
      b.writeln(
        '<li><span title="$label">$icon</span> '
        '${f['location'] == null ? '' : '<code>${_e('${f['location']}')}</code> — '}'
        '${_e('${f['change'] ?? ''}')}<div class="muted small">$label'
        '${f['expect'] == null ? '' : ' · should lower: ${_e('${f['expect']}')}'}</div></li>',
      );
    }
    b.writeln('</ol>');
  }
  final open = s.raw['open'];
  if (open is List && open.isNotEmpty) {
    b.writeln(
      '<p class="eyebrow">Open</p><ul class="items">'
      '${open.map((o) => '<li>${_e('$o')}</li>').join()}</ul>',
    );
  }
  b.writeln('</div></details>');
}

// SVG bar chart with one bar per frame, red when over the budget. Bars are
// capped so one huge frame doesn't flatten the rest.
String _frameChart(List<double> times, double budget) {
  if (times.isEmpty) return '';
  const height = 64.0;
  final cap = max(budget * 2.5, min(times.reduce(max), budget * 6));
  final width = times.length * 3.0;
  final y = (double ms) => height - min(ms, cap) / cap * height;
  final bars = StringBuffer();
  for (var i = 0; i < times.length; i++) {
    final t = times[i];
    bars.write(
      '<rect x="${i * 3}" y="${y(t).toStringAsFixed(1)}" width="2" '
      'height="${(height - y(t)).toStringAsFixed(1)}" class="${t > budget ? 'over' : 'ok'}"/>',
    );
  }
  final over = times.where((t) => t > budget).length;
  return '<figure class="frames"><svg viewBox="0 0 $width $height" preserveAspectRatio="none" '
      'role="img" aria-label="Frame times: $over of ${times.length} over the budget">'
      '$bars<line x1="0" x2="$width" y1="${y(budget).toStringAsFixed(1)}" '
      'y2="${y(budget).toStringAsFixed(1)}" class="budget"/></svg>'
      '<figcaption>Each bar is one frame (the slower of UI and Raster). '
      'Red bars miss the ${budget.toStringAsFixed(1)} ms budget (dashed line): '
      '$over of ${times.length}. Bars are capped at ${cap.toStringAsFixed(0)} ms.</figcaption></figure>';
}

// Bottleneck code from judge() as table text.
String _bottleneck(String code) => switch (code) {
  'ui' => 'UI thread (Dart code)',
  'raster' => 'Raster thread (drawing)',
  'both' => 'UI and Raster',
  'spikes' => 'single hitches',
  _ => 'on time',
};

// Small on-time / dropped bar for the screens table.
String _bar(double onTime) {
  final ok = onTime.clamp(0, 100).toDouble();
  final cls = ok >= 97
      ? 'good'
      : ok >= 90
      ? 'warn'
      : 'bad';
  return '<div class="dist"><span class="on" style="width:${ok.toStringAsFixed(1)}%"></span>'
      '<span class="off $cls" style="width:${(100 - ok).toStringAsFixed(1)}%"></span></div>'
      '<small class="n">${ok.toStringAsFixed(0)} %</small>';
}

// Verdict badge.
String _pill(String verdict) => switch (verdict) {
  'FAIL' => '<span class="pill bad">✕ Janky</span>',
  'WARN' => '<span class="pill warn">! Slightly janky</span>',
  _ => '<span class="pill good">✓ Smooth</span>',
};

// Anchor id for a screen name; the hash keeps similar names apart.
String _id(String name) =>
    's-${name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-')}-${name.hashCode.abs()}';

// HTML-escapes every value that comes from the JSON.
String _e(String s) => const HtmlEscape().convert(s);

// Inline stylesheet with light and dark themes, so the page is a single file.
const _css = '''
:root{--bg:#f4f5f7;--card:#fff;--ink:#16181d;--ink2:#555b66;--ink3:#80868f;--rule:#e3e6ea;
--good:#0ca30c;--good-t:#0a6b1f;--good-bg:#e8f5ea;--warn:#eda100;--warn-t:#8a5a00;--warn-bg:#fdf4de;
--bad:#d03b3b;--bad-t:#b02a2a;--bad-bg:#fbeaea;--accent:#2a63d6;--track:#eceef2;--on:#2fb45a;
--sans:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;--mono:ui-monospace,"Cascadia Mono",Consolas,monospace;
color-scheme:light}
@media (prefers-color-scheme:dark){:root{--bg:#111215;--card:#1a1b1f;--ink:#f1f2f4;--ink2:#b6bac3;--ink3:#8a909b;
--rule:#2c2f35;--good-t:#5fd37a;--good-bg:#16301d;--warn-t:#f0b64a;--warn-bg:#352a12;--bad-t:#f08a8a;--bad-bg:#3a1c1c;
--accent:#7aa7ff;--track:#26292f;--on:#3fc26a;color-scheme:dark}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.55 var(--sans)}
main{max-width:1040px;margin:0 auto;padding:28px 16px 64px;display:grid;gap:28px}
h1{margin:2px 0 0;font-size:30px;line-height:1.15;letter-spacing:-.01em;text-wrap:balance}
h2{margin:0 0 12px;font-size:20px}h3{margin:0;font-size:16px;line-height:1.35}
.eyebrow{margin:0;font-size:11px;font-weight:700;letter-spacing:.08em;text-transform:uppercase;color:var(--ink3)}
.meta,.muted{color:var(--ink2)}.meta{margin:6px 0 0;font-size:13px}.small{font-size:12.5px}
.card{background:var(--card);border:1px solid var(--rule);border-radius:12px}.pad{padding:16px 18px}
.n{font-family:var(--mono);font-variant-numeric:tabular-nums}
a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}
a:focus-visible,summary:focus-visible,button:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
.hero{display:grid;grid-template-columns:minmax(300px,1fr) 1.2fr;gap:24px;padding:22px}
.score{display:grid;grid-template-columns:120px 1fr;gap:18px;align-items:center}
.score svg{width:120px;height:120px}.ring-bg{fill:none;stroke:var(--track);stroke-width:10}
.ring{fill:none;stroke-width:10;stroke-linecap:round;transform:rotate(-90deg);transform-origin:60px 60px}
.ring.good{stroke:var(--good)}.ring.warn{stroke:var(--warn)}.ring.bad{stroke:var(--bad)}
.ring-num{font:700 34px var(--sans);fill:var(--ink);text-anchor:middle;dominant-baseline:middle}
.ring-sub{font:12px var(--sans);fill:var(--ink3);text-anchor:middle}
.score-label{margin:2px 0 6px;font-size:22px;font-weight:700}
.score-label.good{color:var(--good-t)}.score-label.warn{color:var(--warn-t)}.score-label.bad{color:var(--bad-t)}
.lede{margin:0 0 10px;color:var(--ink2)}.legend{margin:0;font-size:12.5px;color:var(--ink2)}
.dot{display:inline-block;width:8px;height:8px;border-radius:50%;margin:0 4px 0 10px;vertical-align:1px}
.legend .dot:first-child,.bucket-head .dot,.smooth-note .dot{margin-left:0}
.dot.good{background:var(--good)}.dot.warn{background:var(--warn)}.dot.bad{background:var(--bad)}
.buckets{display:grid;grid-template-columns:repeat(2,1fr);gap:10px;align-content:start}
.bucket{border-radius:10px;padding:12px}.bucket.bad{background:var(--bad-bg)}.bucket.warn{background:var(--warn-bg)}
.bucket-head{margin:0 0 8px;font-weight:600;font-size:13px}
.bucket ul{list-style:none;margin:0;padding:0;display:grid;gap:4px;font-size:13px}
.bucket li{display:flex;justify-content:space-between;gap:8px}.bucket li .n{color:var(--ink2);white-space:nowrap}
.smooth-note{grid-column:1/-1;margin:2px 0 0;font-size:13px;color:var(--ink2)}
.issues{display:grid;gap:12px}.issue{padding:16px 18px}
.issue-head{display:grid;grid-template-columns:28px 1fr;gap:12px}.issue-head p{margin:4px 0 0;color:var(--ink2)}
.num{display:grid;place-items:center;width:28px;height:28px;border-radius:50%;font-weight:700;font-size:13px;color:#fff}
.num.bad{background:var(--bad)}.num.warn{background:var(--warn-t)}
.chips{margin:12px 0 0 40px;font-size:13px;line-height:2}.chip{padding:2px 8px;border-radius:999px;background:var(--track)}
.fix{margin:10px 0 0 40px;display:grid;grid-template-columns:max-content 1fr;gap:4px 12px;font-size:14px}
.fix dt{color:var(--ink3);font-weight:600}.fix dd{margin:0}
button.copy{margin:12px 0 0 40px;font:inherit;font-size:13px;padding:6px 12px;border-radius:8px;border:1px solid var(--rule);background:var(--card);color:var(--ink);cursor:pointer}
button.copy:hover{border-color:var(--accent)}
.scroll{overflow-x:auto}table{border-collapse:collapse;width:100%;font-size:14px}
th,td{text-align:left;padding:10px 12px;border-bottom:1px solid var(--rule);vertical-align:middle}
tr:last-child td{border-bottom:0}th{font-size:12px;color:var(--ink3);font-weight:600}
table.list{min-width:780px}td small{display:block;color:var(--ink3);font-size:12px}
.fpscell b{font-size:18px}.fpscell small{display:inline}
.dist{display:flex;gap:2px;width:120px;height:10px;margin-bottom:3px}
.dist span{display:block;height:100%}.dist .on{background:var(--on);border-radius:4px 0 0 4px}
.dist .off{border-radius:0 4px 4px 0;min-width:2px}.dist .off.good{background:var(--track)}
.dist .off.warn{background:var(--warn)}.dist .off.bad{background:var(--bad)}
.pill{display:inline-flex;gap:4px;align-items:center;font-size:12px;font-weight:600;padding:2px 9px;border-radius:999px;white-space:nowrap}
.pill.good{background:var(--good-bg);color:var(--good-t)}.pill.warn{background:var(--warn-bg);color:var(--warn-t)}.pill.bad{background:var(--bad-bg);color:var(--bad-t)}
.badtext{color:var(--bad-t)}td small.badtext{color:var(--bad-t)}
details.screen{margin-bottom:10px}details.screen>summary{display:flex;gap:10px;align-items:center;padding:14px 16px;cursor:pointer;list-style:none}
details.screen>summary::-webkit-details-marker{display:none}
details.screen>summary::before{content:"▸";color:var(--ink3)}details[open].screen>summary::before{content:"▾"}
.sname{font-weight:600}.body{padding:0 18px 18px;display:grid;gap:12px}
.kpis{display:grid;grid-template-columns:repeat(3,1fr);gap:10px}
.kpis>div{border:1px solid var(--rule);border-radius:10px;padding:10px 12px;display:grid}
.kv{font-size:24px;font-weight:600}.kv small{font-size:13px;color:var(--ink3);font-weight:400}.kl{font-size:12.5px;color:var(--ink2)}
.frames{margin:0}.frames svg{display:block;width:100%;height:72px;background:var(--track);border-radius:6px}
.frames rect.ok{fill:var(--accent)}.frames rect.over{fill:var(--bad)}
.frames line.budget{stroke:var(--ink);stroke-width:1;stroke-dasharray:4 3;vector-effect:non-scaling-stroke}
.frames figcaption{margin-top:4px;font-size:12.5px;color:var(--ink2)}
.gauge{display:grid;grid-template-columns:90px 1fr 80px;gap:10px;align-items:center}
.gl{font-size:13px;color:var(--ink2)}.track{position:relative;height:10px;background:var(--track);border-radius:3px}
.fill{height:100%;border-radius:0 4px 4px 0}.fill.ok{background:var(--accent)}.fill.over{background:var(--bad)}
.mark{position:absolute;top:-4px;bottom:-4px;width:2px;background:var(--ink)}
table.metrics{min-width:420px}
.note{background:var(--warn-bg);color:var(--warn-t);border-radius:8px;padding:10px 12px;font-size:13px}
.note ul{margin:4px 0 0;padding-left:18px}.items{margin:0;padding-left:20px;display:grid;gap:8px}
.tag{font-size:11px;font-weight:700;border:1px solid var(--rule);border-radius:4px;padding:1px 6px}
code{font-family:var(--mono);background:var(--track);padding:1px 5px;border-radius:4px;font-size:12.5px}
.glossary>summary{padding:14px 16px;cursor:pointer;font-weight:600}
.glossary dl{margin:0;padding:0 18px 16px;display:grid;grid-template-columns:max-content 1fr;gap:8px 16px}
.glossary dt{font-weight:600}.glossary dd{margin:0;color:var(--ink2)}
.prompt{padding:14px;position:relative}.prompt button.copy{position:absolute;top:10px;right:10px;margin:0}
.prompt pre{margin:0;padding-top:34px;white-space:pre-wrap;font:12.5px/1.5 var(--mono)}
@media (max-width:1000px){.hero{grid-template-columns:1fr}}
@media (max-width:760px){.buckets{grid-template-columns:1fr}
.kpis{grid-template-columns:1fr}.chips,.fix,button.copy{margin-left:0}.gauge{grid-template-columns:70px 1fr 64px}}
''';

// Prints the error and exits with code 2 (usage or input error).
Never _exit(String message) {
  stderr.writeln(message);
  exit(2);
}
