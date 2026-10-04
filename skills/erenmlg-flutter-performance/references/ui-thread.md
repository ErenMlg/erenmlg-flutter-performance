# UI thread: confirm, then recommend

The UI thread runs Dart: build, layout, paint (recording a display list) and all your own synchronous code. When its p90 exceeds the frame budget, the frame is late before the GPU ever sees it. The fixes below are what to *recommend* in the report and fix prompt — the skill doesn't apply them.

## Confirm the cause first

**From the trace** — `dart <skill-dir>/scripts/timeline_top.dart <run>.timeline.json`, no device needed:
- `BUILD` ms/frame high → §A (rebuild scope) or §B (expensive build).
- `LAYOUT` ms/frame high → §B, look for intrinsics.
- `SEMANTICS` ms/frame high → check the test has `semanticsEnabled: false`; if it does, the app pays it only with a screen reader on.
- `Scavenge` / `CollectNewGeneration` counts in the hundreds, `total_ui_gc_time` high in the summary → §D.
- One long event outside the frame phases (e.g. a JSON or file call) → §C.

**In DevTools** (when the user can run it) → **Performance** on a profile build, reproduce the interaction, click a red (janky) frame.

- **Frame Analysis** says which phase dominates: build, layout or paint.
- Turn on **Enhance Tracing** → *Track widget builds*, *Track layouts*, *Track paints* to see *which* widgets appear in the flame chart. Turn them off again before measuring; they slow every frame.
- **Rebuild Stats** (Performance tab, or *Track widget rebuilds* in the IDE's Flutter Inspector) counts rebuilds per widget. A widget rebuilding every frame during a scroll that doesn't change it is the prime suspect.
- **CPU Profiler** (bottom-up view) for long Dart calls that aren't build/layout/paint.

Match what you see to a section below.

## A. Too many rebuilds (build phase dominates, high rebuild counts)

**Localize state.** `setState` rebuilds the whole subtree of that `State`. Move the changing value into the smallest widget that needs it.

```dart
// Before: every tick rebuilds the whole page, including the list.
class _PageState extends State<Page> {
  int seconds = 0;
  @override
  Widget build(BuildContext context) => Column(children: [
        Text('$seconds s'),
        const Expanded(child: HeavyList()),
      ]);
}

// After: only the timer text rebuilds.
class _PageState extends State<Page> {
  @override
  Widget build(BuildContext context) => const Column(children: [
        TimerText(),
        Expanded(child: HeavyList()),
      ]);
}
```

- Split big `build()` methods into widget **classes**, not helper methods. A helper method's output is rebuilt with its parent every time; a separate widget (especially a `const` one) can be skipped.
- Scope listeners: `ValueListenableBuilder`, `ListenableBuilder`, `AnimatedBuilder` around only the part that changes. Pass the static subtree as `child:` so it is built once, not on every tick.
- State-management selectors rebuild only on the field actually used: `context.select` / `Selector` (provider), `ref.watch(p.select(...))` (Riverpod), `BlocSelector` / `buildWhen` (bloc).

**Use `const` constructors.** A `const` widget is one canonical instance; when the framework sees the identical instance again it skips rebuilding that subtree. Enable `prefer_const_constructors` and `prefer_const_literals_to_create_immutables` in `analysis_options.yaml`, then `dart fix --apply`.

## B. Expensive build or layout

- **Lazy lists.** `ListView(children: [...])` or a `Column` inside `SingleChildScrollView` builds every item up front. Use `ListView.builder` / `GridView.builder` / `SliverList.builder`. For fixed-height rows add `itemExtent` or `prototypeItem` so the list doesn't have to lay out children to know their size.
- **Avoid intrinsic sizing.** `IntrinsicHeight`, `IntrinsicWidth` and `Table` with `IntrinsicColumnWidth` run an extra layout pass over their subtree, and nested intrinsics multiply it. In *Track layouts* they show up as `RenderIntrinsic*`. Replace with fixed sizes, `Expanded`/`Flexible`, or `CrossAxisAlignment.stretch`.
- **No real work in `build()`.** Sorting, filtering, date/number formatting, regex, decoding — compute once (in `initState`, `didUpdateWidget`, or the model layer) and store the result. `build()` can run every frame.
- **Build strings with `StringBuffer`.** `s += part` in a loop copies the whole string every iteration (quadratic time, lots of garbage). Use `StringBuffer` or `parts.join()`:

  ```dart
  final buffer = StringBuffer();
  for (final line in lines) {
    buffer.writeln(line.text);
  }
  final report = buffer.toString();
  ```

## C. Heavy synchronous Dart work

A single long event in the CPU profiler (not build/layout/paint) — JSON decoding a large response, parsing files, crypto, image manipulation — blocks every frame while it runs. Move it to another isolate:

```dart
final items = await Isolate.run(() => parseItems(responseBody)); // dart:isolate
```

`compute(parseItems, responseBody)` from `package:flutter/foundation.dart` does the same and also works on web (where it runs on the same thread). The function and its arguments must be sendable: top-level or static functions, plain data.

## D. GC churn

High `new_gen_gc_count` / `old_gen_gc_count` / `total_ui_gc_time` in the summary with a jagged frame chart means too many short-lived objects per frame.

- Hoist per-frame allocations out of `build()` and `paint()`: `Paint`, `Path`, `TextStyle`, `BorderRadius` as `static final` or `const` (`BorderRadius.all(Radius.circular(8))` is const; `BorderRadius.circular(8)` is not).
- Don't create lists, maps or closures inside hot list items when they could be created once.

## Verify

When the user reports a fix applied, re-measure (SKILL.md step 8). Dropped frames decide (the verdict rule); UI p90 and p99 should follow, and the targeted event should shrink in `timeline_top`. A p90 change of 2–3 ms alone is run-to-run noise. If dropped frames don't fall, the change didn't address the cause — recommend reverting it and name the next suspect.
