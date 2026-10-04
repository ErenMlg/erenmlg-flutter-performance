// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_driver/flutter_driver.dart' as driver;
import 'package:integration_test/integration_test_driver.dart';

// Host-side driver: when the test finishes, saves each traced action's
// timeline as numbered files in perf_runs/.
Future<void> main() {
  return integrationDriver( 
    writeResponseOnFailure: true, // Still saves the traces collected so far when the test fails.
    responseDataCallback: (data) async {
      if (data == null) return;
      Directory('perf_runs').createSync(recursive: true);
      for (final entry in data.entries) {
        var n = 1;
        while (File('perf_runs/${entry.key}.$n.json').existsSync()) {
          n++;
        }
        final name = '${entry.key}.$n';
        final timeline = driver.Timeline.fromJson(
          entry.value as Map<String, dynamic>,
        );
        await driver.TimelineSummary.summarize(
          timeline,
        ).writeTimelineToFile(name, destinationDirectory: 'perf_runs');
        File(
          'perf_runs/$name.timeline_summary.json',
        ).renameSync('perf_runs/$name.json');
        print('Saved perf_runs/$name.json');
      }
    },
  );
}
