// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

// Lists where the time went in one trace: every event name with its total
// time, count and ms per frame, largest first. Reads the full
// <key>.<n>.timeline.json that perf_driver.dart saves, not the summary.
const _usage = 'usage: dart timeline_top.dart <name>.timeline.json [--top=15]';

// One event name summed over the whole trace.
typedef TimelineEvent = ({String name, double totalMs, int count});

// Result of readTimeline: event count, trace length, frame count and the
// events ranked by total time.
typedef TimelineTop = ({
  int eventCount,
  double seconds,
  int frames,
  List<TimelineEvent> events,
});

// CLI entry: validates the arguments and prints the top N events as a table.
void main(List<String> args) {
  final paths = args.where((a) => !a.startsWith('--')).toList();
  final flags = args.where((a) => a.startsWith('--')).toList();
  if (paths.length != 1 || flags.any((f) => !f.startsWith('--top='))) {
    _exit(_usage);
  }
  final top = flags.isEmpty ? 15 : int.tryParse(flags.single.substring(6));
  if (top == null || top <= 0) _exit('--top must be a positive integer');

  final result = readTimeline(paths.single, onError: _exit);
  final frames = result.frames;
  print(
    '${result.eventCount} events over '
    '${result.seconds.toStringAsFixed(2)} s, $frames frames',
  );
  if (frames == 0) print('WARNING: no Frame events; per-frame column omitted.');
  print(
    '\n${'total ms'.padLeft(10)}${'count'.padLeft(8)}'
    '${frames > 0 ? 'ms/frame'.padLeft(10) : ''}  event',
  );
  for (final e in result.events.take(top)) {
    final perFrame = frames > 0
        ? (e.totalMs / frames).toStringAsFixed(2).padLeft(10)
        : '';
    print(
      '${e.totalMs.toStringAsFixed(1).padLeft(10)}'
      '${'${e.count}'.padLeft(8)}$perFrame  ${e.name}',
    );
  }
}

// Parses a Chrome trace file and sums the time per event name. Also used by
// html_report.dart, which passes its own onError instead of exiting.
TimelineTop readTimeline(
  String path, {
  required Never Function(String) onError,
}) {
  final Object? json;
  try {
    json = jsonDecode(File(path).readAsStringSync());
  } on FileSystemException catch (e) {
    onError('$path: ${e.message}');
  } on FormatException catch (e) {
    onError('$path: not valid JSON (${e.message})');
  }
  final events = json is Map<String, dynamic> ? json['traceEvents'] : null;
  if (events is! List || events.isEmpty) {
    onError(
      '$path: no "traceEvents"; pass a *.timeline.json, not the summary.',
    );
  }

  // Sort by timestamp; the original index breaks ties so a begin/end pair with
  // the same timestamp keeps its order.
  final indexed =
      [
        for (var i = 0; i < events.length; i++)
          if (events[i] is Map<String, dynamic> && events[i]['ts'] is num)
            (i, events[i] as Map<String, dynamic>),
      ]..sort((a, b) {
        final byTs = (a.$2['ts'] as num).compareTo(b.$2['ts'] as num);
        return byTs != 0 ? byTs : a.$1.compareTo(b.$1);
      });
  final timed = [for (final (_, e) in indexed) e];
  final totals = <String, double>{};
  final counts = <String, int>{};
  // Begin events still waiting for their end event, per thread.
  final open = <Object?, List<Map<String, dynamic>>>{};
  void add(String name, num micros) {
    totals[name] = (totals[name] ?? 0) + micros / 1000;
    counts[name] = (counts[name] ?? 0) + 1;
  }

  for (final e in timed) {
    // X = complete event with its own duration. B/E = begin/end pair; an end is
    // matched to the latest open begin with the same name on its thread.
    switch (e['ph']) {
      case 'X':
        add('${e['name']}', (e['dur'] as num?) ?? 0);
      case 'B':
        (open[e['tid']] ??= []).add(e);
      case 'E':
        final stack = open[e['tid']];
        if (stack == null || stack.isEmpty) break;
        final at = e['name'] == null
            ? stack.length - 1
            : stack.lastIndexWhere((b) => b['name'] == e['name']);
        if (at < 0) break;
        final begin = stack.removeAt(at);
        add('${begin['name']}', (e['ts'] as num) - (begin['ts'] as num));
    }
  }

  final ranked = totals.keys.toList()
    ..sort((a, b) => totals[b]!.compareTo(totals[a]!));
  return (
    eventCount: events.length,
    seconds: timed.isEmpty
        ? 0
        : ((timed.last['ts'] as num) - (timed.first['ts'] as num)) / 1e6,
    // Older engines have no Frame event; one raster draw per frame stands in.
    frames: counts['Frame'] ?? counts['GPURasterizer::Draw'] ?? 0,
    events: [
      for (final name in ranked)
        (name: name, totalMs: totals[name]!, count: counts[name]!),
    ],
  );
}

// Prints the error and exits with code 2 (usage or input error).
Never _exit(String message) {
  stderr.writeln(message);
  exit(2);
}
