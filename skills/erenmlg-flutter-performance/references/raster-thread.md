# Raster thread: confirm, then recommend

The raster thread turns the display list into GPU commands. When its p90 exceeds the budget while the UI thread is fine, the Dart code is cheap but the *scene* is expensive to draw. The usual cause is offscreen passes (`saveLayer`), followed by oversized images, large blurs and shadows, and needless repainting. The fixes below are what to *recommend* in the report and fix prompt — the skill doesn't apply them.

## Confirm the cause first

**From the trace** — `dart <skill-dir>/scripts/timeline_top.dart <run>.timeline.json --top=500`, then look for:
- `Canvas::saveLayer` — more than a few per frame → §A. Count per frame is the evidence (e.g. 6533 over 411 frames ≈ 16/frame).
- `DecompressTexture` or other image-decode events recurring during a scroll → §B (decoded larger than shown, or evicted from the image cache and decoded again).
- `SurfaceFrame::Submit` / render-pass events dominating with few `saveLayer`s → GPU-bound drawing: §D (shadows, blur) or simply too much on screen.
- Raster spikes only on the first appearance of an effect, Skia backend → §E.

**In DevTools** (when the user can run it) → **Performance** on a profile build, reproduce, click a janky frame with a tall raster bar. The DevTools toggles need no code change. The code switches below (`checkerboardOffscreenLayers`, `debug*` flags) do — suggest them to the user instead of adding them yourself.

- **Toggle layer types.** Under *More debugging options*, switch off *Render Opacity layers*, *Render Clip layers*, *Render Physical Shape layers* one at a time (same as `debugDisableOpacityLayers`, `debugDisableClipLayers`, `debugDisablePhysicalShapeLayers`). If raster time drops sharply with one of them off, that layer type is the cost. The screen will look wrong while it's off; that's expected.
- **Highlight offscreen layers.** `MaterialApp(checkerboardOffscreenLayers: true)` draws a checkerboard wherever `saveLayer` is used. Remove it after diagnosis.
- **Highlight repaints.** Inspector → *Highlight repaints* (`debugRepaintRainbowEnabled = true`). Borders that change color on every frame mark regions that repaint; a big region repainting because of a small spinner is a candidate for a `RepaintBoundary`.
- **Highlight oversized images.** Inspector → *Highlight oversized images* (`debugInvertOversizedImages = true`) inverts images decoded larger than they are displayed.

## A. `saveLayer` triggers

A `saveLayer` renders a subtree to an offscreen texture and composites it back — a render-target switch that is expensive, especially per frame and on mobile GPUs.

**`Opacity`** on anything but a trivial child:
- Static transparency on a color or image → put the alpha in the paint instead:
  ```dart
  // Before
  Opacity(opacity: 0.5, child: Container(color: Colors.blue));
  // After
  Container(color: Colors.blue.withValues(alpha: 0.5));

  // Images take an opacity animation directly
  Image.asset('assets/hero.png', opacity: const AlwaysStoppedAnimation(0.5));
  ```
- Animated fades → `FadeTransition` (driven by an `AnimationController`) or `AnimatedOpacity`, not `Opacity` rebuilt by `setState` every frame. They update the layer's alpha without rebuilding or repainting the child.
- Hiding → `Visibility` or don't build the widget, rather than `Opacity(opacity: 0)`.

**Clips.** `Clip.antiAliasWithSaveLayer` is the only clip mode that forces `saveLayer`; switch to `Clip.antiAlias` (smooth edges) or `Clip.hardEdge` (cheapest, fine for rectangles). Don't clip when nothing overflows. For rounded rectangles, `BoxDecoration(borderRadius: ...)` on a `DecoratedBox`/`Container` is cheaper than wrapping a child in `ClipRRect`.

**`ShaderMask`, `ColorFiltered`, `BackdropFilter`.** All need offscreen work. Keep them out of list items and off animated subtrees, and keep their area small. Wrap a `BackdropFilter` in a `ClipRect` so it blurs only its own bounds. When several blurred panels share the same backdrop, put them under one `BackdropGroup` and use `BackdropFilter.grouped` so the backdrop is captured once.

## B. Oversized images

A 4000 × 3000 photo shown as a 96 px avatar is still decoded and uploaded at full size. Decode at display size:

```dart
final dpr = MediaQuery.devicePixelRatioOf(context);
Image.network(
  url,
  width: 96,
  height: 96,
  cacheWidth: (96 * dpr).round(),
);
```

Set one of `cacheWidth` / `cacheHeight` to keep the aspect ratio. `ResizeImage(provider, width: ...)` does the same for any `ImageProvider`. For images that appear during a transition, `precacheImage` them beforehand so decoding doesn't land in an animation frame.

## C. Repaint scope

`RepaintBoundary` gives a subtree its own layer, so it can be repainted — or reused — independently of its neighbors. Use it where a small, frequently changing widget (spinner, progress bar, ticker, video) sits inside a large static screen, or around a complex static subtree next to something animating. Confirm with *Highlight repaints* before and after.

Don't sprinkle it everywhere: each boundary is an extra layer with its own memory and compositing cost. `ListView` already wraps each item in one (`addRepaintBoundaries: true`).

`CustomPainter.shouldRepaint` returning `true` unconditionally re-records and re-rasterizes the painting every frame. Return `true` only when the inputs changed, and pass a `repaint:` listenable instead of rebuilding the `CustomPaint` for animations.

## D. Blur, shadows, and effects in bulk

Large-radius `BoxShadow`s, `ImageFilter.blur`, and shadowed text on dozens of list items each cost GPU time every frame they're on screen. Shrink the blur radius, use elevation on fewer surfaces, or bake static shadows into an image asset.

## E. Shader compilation (Skia backend only)

Raster spikes the *first* time an effect or route appears, smooth afterwards, and the log says Skia rather than Impeller. Impeller precompiles its shaders, so on iOS and most Android devices this doesn't happen. If the app has opted out of Impeller (`--no-enable-impeller`, or `io.flutter.embedding.android.EnableImpeller` set to `false` in `AndroidManifest.xml`, or `FLTEnableImpeller` set to `false` in `Info.plist`), test with it enabled. The old SkSL warm-up (`--cache-sksl`) is gone from current Flutter.

## Verify

When the user reports a fix applied, re-measure (SKILL.md step 8). Dropped frames decide (the verdict rule); Raster p90 and p99 should follow, and the targeted event should shrink in `timeline_top`. Fewer `saveLayer`s alone isn't proof — in the real-device test, removing them cut `saveLayer` from 6533 to 62 while raster p99 still rose from 17 to 25 ms. If dropped frames don't fall, recommend reverting and name the next suspect.
