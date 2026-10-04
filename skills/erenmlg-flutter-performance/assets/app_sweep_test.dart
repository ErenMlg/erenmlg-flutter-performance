import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:my_app/main.dart' as app;

// Removes the test data that a screen's ensureData added. Run at the end of the sweep.
typedef _Cleanup = Future<void> Function();

// One screen of the sweep:
// - key: name used in report keys (e.g. home_open, home_scroll)
// - open: steps that navigate to the screen from the app's first screen
// - scroll: the list to scroll; if null, the first Scrollable that scrolls down is used
// - ensureData: adds test data when the screen needs it and returns a cleanup
//   that removes it (or null when nothing was added)
typedef _Screen = ({
  String key,
  Future<void> Function(WidgetTester tester) open,
  Finder? scroll,
  Future<_Cleanup?> Function(WidgetTester tester)? ensureData,
});

// Whether to run the cleanups of seeded test data at the end of the sweep
// (e.g. created users, added records).
const _deleteSeededData = true;

// Whether the app ships an English translation. When true the sweep runs the
// app in English: the app is told the phone's language is en-US, and
// _useEnglish switches an in-app language choice if the app has one.
const _appHasEnglish = true;

// Switches the app's own language choice to English for this run only, in
// memory; never the saved setting. Leave empty when the app follows the
// phone's language.
Future<void> _useEnglish(WidgetTester tester) async {}

final List<_Screen> _screens = [
  (key: 'home', open: (tester) async {}, scroll: null, ensureData: null),
  (
    key: 'settings',
    open: (tester) => tester.tap(find.byIcon(Icons.settings).hitTestable()),
    scroll: null,
    ensureData: null,
  ),
];

// Timeline streams to record (Dart, Embedder, GC).
const _streams = ['Dart', 'Embedder', 'GC'];

// Limits the sweep to the given screen keys.
// Example: --dart-define=PERF_ONLY=home,settings
const _only = String.fromEnvironment('PERF_ONLY');

// Set --dart-define=PERF_TAPS=false to skip the tap phase
// (open and scroll are still measured).
const _tapEverything = bool.fromEnvironment('PERF_TAPS', defaultValue: true);

// Limits the tap phase to the given tap report keys, slug included.
// Example: --dart-define=PERF_TAP_KEYS=home_tap1_iconbutton,settings_tap2_listtile
const _tapKeys = String.fromEnvironment('PERF_TAP_KEYS');

const _suffix = _only == '' ? '' : '__isolated';

// Max number of same-kind tappables tapped per list (same scrollable, widget
// type and depth). Tapping every row of a long list only wastes time.
const _sameKindPerList = 2;

// Words that mark a widget as destructive (data loss, logout, payments).
// Widgets whose label contains one of them as a whole word are not tapped.
const _destructiveWords = [
  'delete',
  'remove',
  'reset',
  'clear',
  'erase',
  'wipe',
  'log out',
  'logout',
  'sign out',
  'restore',
  'import',
  'pay',
  'buy',
  'purchase',
  'subscribe',
];

const _destructiveIcons = <IconData>[
  Icons.delete,
  Icons.delete_outline,
  Icons.delete_forever,
  Icons.delete_rounded,
  Icons.delete_outline_rounded,
  Icons.delete_sweep,
  Icons.logout,
  Icons.logout_rounded,
  Icons.exit_to_app,
  Icons.restore,
];

// Words that mark a widget as leaving the app (share sheet, camera, file
// picker, phone call...). Widgets whose label contains one of them as a whole
// word are not tapped.
const _leavesAppWords = [
  'share',
  'export',
  'camera',
  'scan',
  'gallery',
  'photo',
  'file',
  'upload',
  'download',
  'call',
  'print',
  'open in',
];

const _leavesAppIcons = <IconData>[
  Icons.share,
  Icons.share_rounded,
  Icons.ios_share,
  Icons.camera_alt,
  Icons.camera_alt_rounded,
  Icons.photo_camera,
  Icons.photo_library,
  Icons.document_scanner,
  Icons.qr_code_scanner,
  Icons.upload,
  Icons.upload_file,
  Icons.file_upload,
  Icons.download,
  Icons.file_download,
  Icons.call,
  Icons.phone,
  Icons.print,
  Icons.open_in_new,
];

// Toggles are tapped a second time right after their measured tap to restore
// their state.
const _toggleWidgets = [Switch, SwitchListTile, Checkbox, CheckboxListTile];

// Widgets whose change the test cannot undo. Tappables inside them are not
// tapped.
const _unrestorableWidgets = [Slider, RangeSlider, Radio, RadioListTile];

const _namedTypes = {
  'IconButton',
  'FloatingActionButton',
  'BackButton',
  'CloseButton',
  'PopupMenuButton',
  'Chip',
  'ActionChip',
  'FilterChip',
  'ChoiceChip',
  'InputChip',
  'Card',
  'ListTile',
  'NavigationDestination',
  'Tab',
  'BottomNavigationBar',
  'NavigationBar',
  'AppBar',
  'Image',
  'CircleAvatar',
};

// Project-specific additions to the destructive lists. For example, add
// 'archive' to _extraUnsafeWords if archiving is destructive in your app, or a
// custom icon to _extraUnsafeIcons.
const _extraUnsafeWords = <String>[];

const _extraUnsafeIcons = <IconData>[];

bool _tapsFor(_Screen screen) =>
    _tapEverything &&
    (_tapKeys.isEmpty ||
        _tapKeys.split(',').any((k) => k.startsWith('${screen.key}_tap')));

bool _tapSelected(String key) =>
    _tapKeys.isEmpty || _tapKeys.split(',').contains(key);

// Scrolls down twice, then up twice. Fling distance and velocity affect the
// measured frames, so change them with care.
Future<void> _flingDownAndUp(WidgetTester tester, Finder target) async {
  for (var i = 0; i < 4; i++) {
    if (i < 2) {
      await tester.fling(target, const Offset(0, -500), 1500);
    } else {
      await tester.fling(target, const Offset(0, 500), 1500);
    }
    await tester.pumpAndSettle();
  }
}

// Scrolls a plain 1000-row list and records it as _calibration_scroll.
// compare_perf.dart reads it as the device floor (dropped-frame rate with
// trivial content) and judges the app's numbers against it. The calibration
// route is popped afterwards.
Future<void> _calibrate(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
) async {
  final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
  navigator.push(
    PageRouteBuilder<void>(
      pageBuilder: (context, animation, secondaryAnimation) => ColoredBox(
        color: const Color(0xFFFFFFFF),
        child: ListView.builder(
          key: const ValueKey('perf_calibration'),
          itemCount: 1000,
          itemBuilder: (_, i) => SizedBox(
            height: 56,
            child: Text(
              'Row $i',
              textDirection: TextDirection.ltr,
              style: const TextStyle(color: Color(0xFF000000)),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await binding.traceAction(
    () =>
        _flingDownAndUp(tester, find.byKey(const ValueKey('perf_calibration'))),
    streams: _streams,
    reportKey: '_calibration_scroll$_suffix',
  );
  navigator.pop();
  await tester.pumpAndSettle();
}

// Whether the screen is part of this sweep: all screens, or only those listed
// in PERF_ONLY.
bool _selected(_Screen screen) =>
    _only.isEmpty || _only.split(',').contains(screen.key);

// Joins up to 30 visible Text strings. Logged when a screen fails, to show
// what was on screen.
String _visibleTexts(WidgetTester tester) => find
    .byType(Text)
    .hitTestable()
    .evaluate()
    .map((element) => (element.widget as Text).data)
    .whereType<String>()
    .take(30)
    .join(' | ');

// Pops back to the first route so the next step starts from a clean state.
// Called before each screen and before a tap only when the previous tap left
// the screen dirty (see the tap loop in main).
Future<void> _recover(WidgetTester tester) async {
  tester
      .state<NavigatorState>(find.byType(Navigator).first)
      .popUntil((route) => route.isFirst);
  await tester.pumpAndSettle();
}

// Visible, hit-testable InkResponse (including InkWell) or GestureDetector
// widgets that have an onTap. These are the tap candidates.
final _tappableFinder = find
    .byWidgetPredicate(
      (w) =>
          (w is InkResponse && w.onTap != null) ||
          (w is GestureDetector && w.onTap != null),
    )
    .hitTestable();

// Builds the label and the icon list of a tappable. The label joins the Text
// and Tooltip strings of its subtree plus the tooltips of up to 10 ancestors;
// if that is empty, it falls back to the type of the nearest ancestor listed in
// _namedTypes. The label feeds the skip checks and the report key.
({String label, List<IconData> icons}) _describe(Element element) {
  final texts = <String>[];
  final icons = <IconData>[];
  void visit(Element e) {
    final widget = e.widget;
    if (widget is Text && widget.data != null) texts.add(widget.data!);
    if (widget is Icon && widget.icon != null) icons.add(widget.icon!);
    if (widget is Tooltip && widget.message != null) {
      texts.add(widget.message!);
    }
    e.visitChildElements(visit);
  }

  visit(element);
  var depth = 0;
  element.visitAncestorElements((ancestor) {
    final widget = ancestor.widget;
    if (widget is Tooltip && widget.message != null) texts.add(widget.message!);
    return ++depth < 10;
  });
  var label = texts.join(' ').trim();
  if (label.isEmpty) {
    element.visitAncestorElements((ancestor) {
      final type = '${ancestor.widget.runtimeType}';
      if (_namedTypes.contains(type)) label = type;
      return label.isEmpty;
    });
  }
  return (label: label, icons: icons);
}

// Whether any ancestor's exact runtimeType is in [types] (subclasses do not
// match). Used to detect unrestorable widgets and toggles.
bool _hasAncestor(Element element, List<Type> types) {
  var found = false;
  element.visitAncestorElements((ancestor) {
    found = types.contains(ancestor.widget.runtimeType);
    return !found;
  });
  return found;
}

// Returns the first of [words] that appears in [label] as a whole word, or
// null. The label is lowercased first.
String? _matchWord(String label, List<String> words) {
  final text = label.toLowerCase();
  for (final word in words) {
    if (RegExp(
      r'(^|[^\p{L}])' + RegExp.escape(word) + r'($|[^\p{L}])',
      unicode: true,
    ).hasMatch(text)) {
      return word;
    }
  }
  return null;
}

// Returns why a tappable must not be tapped (unrestorable, destructive, leaves
// the app), or null if it is safe. The caller logs the reason.
String? _skipReason(Element element, String label, List<IconData> icons) {
  if (_hasAncestor(element, _unrestorableWidgets)) {
    return 'changes a value the test cannot restore';
  }
  final destructive = _matchWord(label, [
    ..._destructiveWords,
    ..._extraUnsafeWords,
  ]);
  if (destructive != null) return 'destructive ("$destructive")';
  if (icons.any(
    (i) => _destructiveIcons.contains(i) || _extraUnsafeIcons.contains(i),
  )) {
    return 'destructive (icon)';
  }
  final leaves = _matchWord(label, _leavesAppWords);
  if (leaves != null) return 'leaves the app ("$leaves")';
  if (icons.any(_leavesAppIcons.contains)) return 'leaves the app (icon)';
  return null;
}

// Collects the tappables of the current screen that the sweep will tap. Skips
// duplicates (same label at the same spot), unsafe ones (logged as
// tap-skipped) and any same-kind items beyond _sameKindPerList per list. Each
// target keeps its index in _tappableFinder, its label and whether it is a
// toggle.
// The widget kind a report key is named after: the nearest known ancestor type
// (IconButton, ListTile, Card...) or the tappable's own type. Keys use this
// instead of the label so they stay English and do not change with the app's
// language or its data (a month name, a transaction title).
String _kind(Element element) {
  var kind = '${element.widget.runtimeType}';
  var depth = 0;
  element.visitAncestorElements((ancestor) {
    final type = '${ancestor.widget.runtimeType}';
    if (_namedTypes.contains(type)) {
      kind = type;
      return false;
    }
    return ++depth < 10;
  });
  return kind;
}

List<({int index, String label, String kind, bool toggle})> _tapTargets(
  String key,
) {
  final elements = _tappableFinder.evaluate().toList();
  final perList = <String, int>{};
  final seen = <String>{};
  final targets = <({int index, String label, String kind, bool toggle})>[];
  for (var i = 0; i < elements.length; i++) {
    final element = elements[i];
    final (:label, :icons) = _describe(element);
    final name = label.isEmpty ? '${element.widget.runtimeType} #$i' : label;
    final box = element.renderObject;
    if (box is RenderBox && box.hasSize) {
      final center = box.localToGlobal(box.size.center(Offset.zero));
      if (!seen.add('$label|${center.dx ~/ 8}|${center.dy ~/ 8}')) continue;
    }
    final skip = _skipReason(element, label, icons);
    if (skip != null) {
      debugPrint('SWEEP tap-skipped $key: "$name" — $skip');
      continue;
    }
    final list = Scrollable.maybeOf(element);
    if (list != null) {
      final kind =
          '${identityHashCode(list)}|${element.widget.runtimeType}|'
          '${element.depth}';
      perList[kind] = (perList[kind] ?? 0) + 1;
      if (perList[kind]! > _sameKindPerList) continue;
    }
    targets.add((
      index: i,
      label: label,
      kind: _kind(element),
      toggle: _hasAncestor(element, _toggleWidgets),
    ));
  }
  return targets;
}

// Turns a widget kind into the slug part of a report key: lowercase a-z and
// 0-9, other characters become underscores, at most 24 characters, or
// 'unlabeled' when nothing is left.
String _slug(String label) {
  final slug = label
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  if (slug.isEmpty) return 'unlabeled';
  return slug.length > 24 ? slug.substring(0, 24) : slug;
}

// The sweep:
// 1. Records the calibration scroll (device floor).
// 2. For each screen: measures its open and scroll, then taps every safe
//    tappable and measures each tap.
// 3. Deletes the seeded test data if _deleteSeededData is set.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.benchmarkLive;

  testWidgets('app sweep', (tester) async {
    if (_appHasEnglish) {
      binding.platformDispatcher.localesTestValue = const [Locale('en', 'US')];
      binding.platformDispatcher.localeTestValue = const Locale('en', 'US');
    }
    app.main();
    await tester.pumpAndSettle();
    if (_appHasEnglish) {
      await _useEnglish(tester);
      await tester.pumpAndSettle();
    }
    debugPrint(
      'SWEEP language: '
      '${Localizations.localeOf(tester.element(find.byType(Navigator).first)).toLanguageTag()}',
    );
    try {
      await _calibrate(tester, binding);
    } catch (e) {
      debugPrint('SWEEP calibration-failed: $e');
      await _recover(tester);
    }

    final cleanups = <_Cleanup>[];
    for (final screen in _screens.where(_selected)) {
      try {
        await _recover(tester);
        if (screen.ensureData case final ensure?) {
          final cleanup = await ensure(tester);
          if (cleanup != null) {
            cleanups.add(cleanup);
            debugPrint('SWEEP seeded ${screen.key}');
          }
        }
        await binding.traceAction(
          () async {
            await screen.open(tester);
            await tester.pumpAndSettle();
          },
          streams: _streams,
          reportKey: '${screen.key}_open$_suffix',
        );

        final scrollable =
            screen.scroll ??
            find.byWidgetPredicate(
              (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
            );
        if (scrollable.evaluate().isNotEmpty) {
          final target = scrollable.first;
          await binding.traceAction(
            () => _flingDownAndUp(tester, target),
            streams: _streams,
            reportKey: '${screen.key}_scroll$_suffix',
          );
        }
      } catch (e) {
        debugPrint('SWEEP skipped ${screen.key}: $e');
        debugPrint('SWEEP visible ${screen.key}: ${_visibleTexts(tester)}');
        continue;
      }

      if (!_tapsFor(screen)) continue;
      final List<({int index, String label, String kind, bool toggle})> targets;
      try {
        await _recover(tester);
        await screen.open(tester);
        await tester.pumpAndSettle();
        targets = _tapTargets(screen.key);
      } catch (e) {
        debugPrint('SWEEP tap-failed ${screen.key}: $e');
        continue;
      }
      debugPrint('SWEEP taps ${screen.key}: ${targets.length}');
      // The screen is open and untouched here. A tap leaves it dirty when its
      // route is no longer on top (page, dialog, sheet or menu opened, or the
      // screen popped); only then does the next tap reset to the first route.
      var dirty = false;
      for (final (n, target) in targets.indexed) {
        final base = '${screen.key}_tap${n + 1}_${_slug(target.kind)}';
        if (!_tapSelected(base)) continue;
        final key = '$base$_suffix';
        debugPrint('SWEEP tap-key $key: "${target.label}"');
        try {
          bool onTarget() {
            final elements = _tappableFinder.evaluate().toList();
            return target.index < elements.length &&
                _describe(elements[target.index]).label == target.label;
          }

          // Also resets when an in-place change (tab switch, expanded card)
          // moved the target, so no tap is lost to it.
          if (dirty || !onTarget()) {
            await _recover(tester);
            await screen.open(tester);
            await tester.pumpAndSettle();
            dirty = false;
            if (!onTarget()) {
              debugPrint('SWEEP tap-moved $key');
              continue;
            }
          }
          final route = ModalRoute.of(
            _tappableFinder.evaluate().elementAt(target.index),
          );
          await binding.traceAction(
            () async {
              await tester.tap(
                _tappableFinder.at(target.index),
                warnIfMissed: false,
              );
              await tester.pumpAndSettle(
                const Duration(milliseconds: 100),
                EnginePhase.sendSemanticsUpdate,
                const Duration(seconds: 10),
              );
            },
            streams: _streams,
            reportKey: key,
          );
          if (target.toggle) {
            await tester.tap(
              _tappableFinder.at(target.index),
              warnIfMissed: false,
            );
            await tester.pumpAndSettle();
          }
          dirty = route == null || !route.isCurrent;
        } catch (e) {
          debugPrint('SWEEP tap-failed $key: $e');
          dirty = true;
        }
      }
    }

    if (_deleteSeededData && cleanups.isNotEmpty) {
      try {
        await _recover(tester);
        for (final cleanup in cleanups.reversed) {
          await cleanup();
        }
        debugPrint('SWEEP deleted seeded data');
      } catch (e) {
        debugPrint('SWEEP cleanup-failed: $e');
      }
    }
  }, semanticsEnabled: false);
}
