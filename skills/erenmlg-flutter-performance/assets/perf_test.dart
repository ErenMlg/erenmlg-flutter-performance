import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:my_app/main.dart' as app;


// Single-scenario template: measures one interaction on one screen (here, a
// list scroll). Copied to integration_test/<scenario>_perf_test.dart.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.benchmarkLive;

  testWidgets('feed scroll performance', (tester) async {
    app.main();
    await tester.pumpAndSettle();

    final scrollable = find.descendant(
      of: find.byKey(const ValueKey('feed_list')),
      matching: find.byType(Scrollable),
    );
    expect(scrollable, findsOneWidget);

    await binding.traceAction(
      () async {
        for (var i = 0; i < 3; i++) {
          await tester.fling(scrollable, const Offset(0, -600), 2000);
          await tester.pumpAndSettle();
        }
        for (var i = 0; i < 3; i++) {
          await tester.fling(scrollable, const Offset(0, 600), 2000);
          await tester.pumpAndSettle();
        }
      },
      streams: const ['Dart', 'Embedder', 'GC'],
      reportKey: 'feed_scroll',
    );
  }, semanticsEnabled: false);
}
