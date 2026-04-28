// Active tool + per-tool styling + user-saved presets.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/note.dart' show InputDrawMode;
import '../../domain/stroke.dart';
import '../lock/note_lock_service.dart';

enum PenSmoothingAlgorithm {
  leash,    // Positional lag: pen lags behind pointer by a fixed distance
  oneEuro,  // One-Euro filter: velocity-adaptive low-pass
}

extension PenSmoothingAlgorithmLabel on PenSmoothingAlgorithm {
  String get label => switch (this) {
    PenSmoothingAlgorithm.leash   => 'Leash',
    PenSmoothingAlgorithm.oneEuro => 'One-Euro',
  };
}

enum AppTool {
  pen,
  highlighter,
  eraserArea,
  eraserStroke,
  rectSelect,
  lasso,
  shapeRect,
  shapeEllipse,
  shapeTriangle,
  shapeDiamond,
  shapeArrow,
  shapeLine,
  tape,
  text,
}

/// Visual pen style. Affects rendering taper and smoothing curve only —
/// data on disk is the same `ToolKind.pen` stroke regardless.
enum PenType { ballpoint, fountain, brush }

@immutable
class ToolPreset {
  const ToolPreset({
    required this.kind,
    required this.colorArgb,
    required this.widthPt,
    this.opacity = 1.0,
  });
  final ToolKind kind; // pen | highlighter
  final int colorArgb;
  final double widthPt;
  final double opacity;
}

@immutable
class ToolState {
  const ToolState({
    required this.activeTool,
    required this.penColor,
    required this.penWidth,
    required this.penType,
    required this.penSmoothingAlgo,
    required this.penLeashStrength,
    required this.penOneEuroSmoothing,
    required this.penOneEuroBeta,
    required this.highlighterColor,
    required this.highlighterWidth,
    required this.eraserAreaRadius,
    required this.lastEraserVariant,
    required this.shapeColor,
    required this.shapeWidth,
    required this.shapeFilled,
    required this.shapeFillColorArgb,
    required this.lastShapeVariant,
    required this.tapeColor,
    required this.tapeWidth,
    required this.textColor,
    required this.textFontSizePt,
    required this.textFontWeight,
    required this.textFontFamily,
    required this.textItalic,
    required this.textAlign,
    required this.lassoIsRect,
    required this.penLineStyle,
    required this.penDashGap,
    required this.recentColors,
    required this.penPaletteColors,
    required this.penPaletteWidths,
    required this.penPaletteLineStyles,
    required this.highlighterPaletteColors,
    required this.highlighterPaletteWidths,
    required this.tapePaletteColors,
    required this.tapePaletteWidths,
    required this.shapeFillPaletteColors,
    required this.tapeRevealedOpacity,
    required this.presets,
    required this.inputDrawMode,
  });

  final AppTool activeTool;

  // pen
  final int penColor;
  final double penWidth;
  final PenType penType;
  final PenSmoothingAlgorithm penSmoothingAlgo;
  // Leash algorithm params
  final double penLeashStrength;   // 0..1
  // One-Euro algorithm params
  final double penOneEuroSmoothing; // 0..1 (0=raw, 1=heavy smooth)
  final double penOneEuroBeta;      // 0..1 (0=slow response, 1=fast)

  // highlighter
  final int highlighterColor;
  final double highlighterWidth;

  // area-eraser
  final double eraserAreaRadius;
  /// Remembers the last eraser variant the user picked so the toolbar's
  /// single eraser slot can re-activate it with one tap.
  final AppTool lastEraserVariant;

  // shapes
  final int shapeColor;
  final double shapeWidth;
  final bool shapeFilled;
  final int shapeFillColorArgb;
  /// Remembers the last shape variant for the single-slot shape button.
  final AppTool lastShapeVariant;

  // tape — drawn as a thick stroke; tap to toggle 100% / 10% at runtime.
  final int tapeColor;
  final double tapeWidth;

  // text
  final int textColor;
  final double textFontSizePt;
  final int textFontWeight;
  final String textFontFamily;
  final bool textItalic;
  final int textAlign; // 0=left, 1=center, 2=right

  // lasso / rect select
  final bool lassoIsRect;

  // line style for stroke tools (0=solid, 1=dashed, 2=dotted)
  final int penLineStyle;
  // dash/dot gap multiplier — 1.0 = tight, larger = wider gaps
  final double penDashGap;

  // recently used colors (most recent first, max 12)
  final List<int> recentColors;

  // per-tool editable palettes: 6 color slots + 5 width slots each
  final List<int> penPaletteColors;
  final List<double> penPaletteWidths;
  // Line style per pen-width slot (0=solid, 1=dashed, 2=dotted).
  final List<int> penPaletteLineStyles;
  final List<int> highlighterPaletteColors;
  final List<double> highlighterPaletteWidths;
  final List<int> tapePaletteColors;
  final List<double> tapePaletteWidths;
  // shape fill palette — independent from the pen stroke palette
  final List<int> shapeFillPaletteColors;

  // opacity used when a tape stroke is in revealed state (0.05 … 0.95)
  final double tapeRevealedOpacity;

  final List<ToolPreset> presets;

  // global input mode (stylus-only vs any) — shared across all app instances
  final InputDrawMode inputDrawMode;

  ToolState copyWith({
    AppTool? activeTool,
    int? penColor,
    double? penWidth,
    PenType? penType,
    PenSmoothingAlgorithm? penSmoothingAlgo,
    double? penLeashStrength,
    double? penOneEuroSmoothing,
    double? penOneEuroBeta,
    int? highlighterColor,
    double? highlighterWidth,
    double? eraserAreaRadius,
    AppTool? lastEraserVariant,
    int? shapeColor,
    double? shapeWidth,
    bool? shapeFilled,
    int? shapeFillColorArgb,
    AppTool? lastShapeVariant,
    int? tapeColor,
    double? tapeWidth,
    int? textColor,
    double? textFontSizePt,
    int? textFontWeight,
    String? textFontFamily,
    bool? textItalic,
    int? textAlign,
    bool? lassoIsRect,
    int? penLineStyle,
    double? penDashGap,
    List<int>? recentColors,
    List<int>? penPaletteColors,
    List<double>? penPaletteWidths,
    List<int>? penPaletteLineStyles,
    List<int>? highlighterPaletteColors,
    List<double>? highlighterPaletteWidths,
    List<int>? tapePaletteColors,
    List<double>? tapePaletteWidths,
    List<int>? shapeFillPaletteColors,
    double? tapeRevealedOpacity,
    List<ToolPreset>? presets,
    InputDrawMode? inputDrawMode,
  }) =>
      ToolState(
        activeTool: activeTool ?? this.activeTool,
        penColor: penColor ?? this.penColor,
        penWidth: penWidth ?? this.penWidth,
        penType: penType ?? this.penType,
        penSmoothingAlgo: penSmoothingAlgo ?? this.penSmoothingAlgo,
        penLeashStrength: penLeashStrength ?? this.penLeashStrength,
        penOneEuroSmoothing: penOneEuroSmoothing ?? this.penOneEuroSmoothing,
        penOneEuroBeta: penOneEuroBeta ?? this.penOneEuroBeta,
        highlighterColor: highlighterColor ?? this.highlighterColor,
        highlighterWidth: highlighterWidth ?? this.highlighterWidth,
        eraserAreaRadius: eraserAreaRadius ?? this.eraserAreaRadius,
        lastEraserVariant: lastEraserVariant ?? this.lastEraserVariant,
        shapeColor: shapeColor ?? this.shapeColor,
        shapeWidth: shapeWidth ?? this.shapeWidth,
        shapeFilled: shapeFilled ?? this.shapeFilled,
        shapeFillColorArgb: shapeFillColorArgb ?? this.shapeFillColorArgb,
        lastShapeVariant: lastShapeVariant ?? this.lastShapeVariant,
        tapeColor: tapeColor ?? this.tapeColor,
        tapeWidth: tapeWidth ?? this.tapeWidth,
        textColor: textColor ?? this.textColor,
        textFontSizePt: textFontSizePt ?? this.textFontSizePt,
        textFontWeight: textFontWeight ?? this.textFontWeight,
        textFontFamily: textFontFamily ?? this.textFontFamily,
        textItalic: textItalic ?? this.textItalic,
        textAlign: textAlign ?? this.textAlign,
        lassoIsRect: lassoIsRect ?? this.lassoIsRect,
        penLineStyle: penLineStyle ?? this.penLineStyle,
        penDashGap: penDashGap ?? this.penDashGap,
        recentColors: recentColors ?? this.recentColors,
        penPaletteColors: penPaletteColors ?? this.penPaletteColors,
        penPaletteWidths: penPaletteWidths ?? this.penPaletteWidths,
        penPaletteLineStyles:
            penPaletteLineStyles ?? this.penPaletteLineStyles,
        highlighterPaletteColors: highlighterPaletteColors ?? this.highlighterPaletteColors,
        highlighterPaletteWidths: highlighterPaletteWidths ?? this.highlighterPaletteWidths,
        tapePaletteColors: tapePaletteColors ?? this.tapePaletteColors,
        tapePaletteWidths: tapePaletteWidths ?? this.tapePaletteWidths,
        shapeFillPaletteColors:
            shapeFillPaletteColors ?? this.shapeFillPaletteColors,
        tapeRevealedOpacity: tapeRevealedOpacity ?? this.tapeRevealedOpacity,
        presets: presets ?? this.presets,
        inputDrawMode: inputDrawMode ?? this.inputDrawMode,
      );

  static const _initial = ToolState(
    activeTool: AppTool.pen,
    penColor: 0xFF111827,   // = penPaletteColors[0]
    penWidth: 1.8,          // = penPaletteWidths[2]
    penType: PenType.ballpoint,
    penSmoothingAlgo: PenSmoothingAlgorithm.leash,
    penLeashStrength: 0.06,
    penOneEuroSmoothing: 0.5,
    penOneEuroBeta: 0.3,
    highlighterColor: 0x66FFFF9A, // = highlighterPaletteColors[1]
    highlighterWidth: 20.0,       // = highlighterPaletteWidths[2]
    eraserAreaRadius: 6.0,
    lastEraserVariant: AppTool.eraserStroke,
    shapeColor: 0xFF111827,
    shapeWidth: 1.8,
    shapeFilled: false,
    shapeFillColorArgb: 0xFFFFFFFF,
    lastShapeVariant: AppTool.shapeRect,
    tapeColor: 0xFFFFE4B5,  // = tapePaletteColors[0]
    tapeWidth: 24.0,         // = tapePaletteWidths[1]
    textColor: 0xFF111827,
    textFontSizePt: 16.0,
    textFontWeight: 400,
    textFontFamily: 'Helvetica Neue',
    textItalic: false,
    textAlign: 0,
    lassoIsRect: false,
    penLineStyle: 0,
    penDashGap: 1.0,
    recentColors: <int>[],
    penPaletteColors: const <int>[
      0xFF111827, 0xFF2563EB, 0xFF16A34A,
      0xFFEA580C, 0xFFDC2626, 0xFF4B5563,
    ],
    penPaletteWidths: const <double>[0.7, 1.2, 1.8, 2.6, 3.6],
    penPaletteLineStyles: const <int>[0, 0, 0, 0, 0],
    highlighterPaletteColors: const <int>[
      0x66FFAFB3, 0x66FFFF9A, 0x66ADFF94,
      0x66A6F0FF, 0x66FFCC99, 0x66DEB0FF,
    ],
    highlighterPaletteWidths: const <double>[12.0, 16.0, 20.0, 24.0, 32.0],
    tapePaletteColors: const <int>[
      0xFFFFE4B5, 0xFFFFCC80, 0xFFFFCDD2,
      0xFFB2EBF2, 0xFFF0F4C3, 0xFFE1BEE7,
    ],
    tapePaletteWidths: const <double>[18.0, 24.0, 30.0, 36.0, 48.0],
    shapeFillPaletteColors: const <int>[
      0xFFFEE2E2, 0xFFDBEAFE, 0xFFDCFCE7,
      0xFFFEF9C3, 0xFFF3E8FF, 0xFFE5E7EB,
    ],
    tapeRevealedOpacity: 0.30,
    presets: <ToolPreset>[
      ToolPreset(kind: ToolKind.pen, colorArgb: 0xFF111827, widthPt: 1.5),
      ToolPreset(kind: ToolKind.pen, colorArgb: 0xFFE53935, widthPt: 2.0),
      ToolPreset(kind: ToolKind.pen, colorArgb: 0xFF1E88E5, widthPt: 2.0),
      ToolPreset(kind: ToolKind.highlighter, colorArgb: 0xFFFFFF9A, widthPt: 20, opacity: 0.35),
    ],
    inputDrawMode: InputDrawMode.any,
  );
}

class ToolController extends Notifier<ToolState> {
  static const _kActiveToolKey          = 'notee.tool.activeTool';
  static const _kLastEraserKey          = 'notee.tool.lastEraserVariant';
  static const _kEraserRadiusKey        = 'notee.tool.eraserAreaRadius';
  static const _kPenColorKey            = 'notee.tool.penColor';
  static const _kPenWidthKey            = 'notee.tool.penWidth';
  static const _kPenTypeKey             = 'notee.tool.penType';
  static const _kPenSmoothingAlgoKey    = 'notee.tool.penSmoothingAlgo';
  static const _kPenLeashStrengthKey    = 'notee.tool.penLeashStrength';
  static const _kPenOneEuroSmoothingKey = 'notee.tool.penOneEuroSmoothing';
  static const _kPenOneEuroBetaKey      = 'notee.tool.penOneEuroBeta';
  static const _kHighlighterColorKey    = 'notee.tool.highlighterColor';
  static const _kHighlighterWidthKey    = 'notee.tool.highlighterWidth';
  static const _kPenPaletteColorsKey    = 'notee.tool.penPaletteColors';
  static const _kPenPaletteWidthsKey    = 'notee.tool.penPaletteWidths';
  static const _kHlPaletteColorsKey     = 'notee.tool.hlPaletteColors';
  static const _kHlPaletteWidthsKey     = 'notee.tool.hlPaletteWidths';
  static const _kInputDrawModeKey          = 'notee.tool.inputDrawMode';
  static const _kTapeRevealedOpacityKey    = 'notee.tool.tapeRevealedOpacity';

  @override
  ToolState build() {
    // Listen to cross-instance tool setting changes and reload prefs.
    final lockService = ref.read(noteLockServiceProvider);
    final sub = lockService.toolChanged.listen((_) => _restorePrefs());
    ref.onDispose(sub.cancel);

    Future.microtask(_restorePrefs);
    return ToolState._initial;
  }

  Future<void> _restorePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final activeName = prefs.getString(_kActiveToolKey);
    final lastEraserName = prefs.getString(_kLastEraserKey);
    final eraserRadius = prefs.getDouble(_kEraserRadiusKey);
    AppTool? active, lastEraser;
    for (final t in AppTool.values) {
      if (activeName != null && t.name == activeName) active = t;
      if (lastEraserName != null && t.name == lastEraserName) lastEraser = t;
    }

    List<int>? decodedIntList(String? s) {
      if (s == null) return null;
      try { return (jsonDecode(s) as List).cast<int>(); } catch (_) { return null; }
    }
    List<double>? decodedDoubleList(String? s) {
      if (s == null) return null;
      try { return (jsonDecode(s) as List).map((e) => (e as num).toDouble()).toList(); } catch (_) { return null; }
    }

    final penColor = prefs.getInt(_kPenColorKey);
    final penWidth = prefs.getDouble(_kPenWidthKey);
    final penTypeName = prefs.getString(_kPenTypeKey);
    PenType? penType;
    for (final t in PenType.values) {
      if (penTypeName != null && t.name == penTypeName) penType = t;
    }
    final smoothAlgoIdx = prefs.getInt(_kPenSmoothingAlgoKey);
    final smoothAlgo = smoothAlgoIdx != null && smoothAlgoIdx < PenSmoothingAlgorithm.values.length
        ? PenSmoothingAlgorithm.values[smoothAlgoIdx]
        : state.penSmoothingAlgo;
    final penLeashStrength = prefs.getDouble(_kPenLeashStrengthKey);
    final penOneEuroSmoothing = prefs.getDouble(_kPenOneEuroSmoothingKey);
    final penOneEuroBeta = prefs.getDouble(_kPenOneEuroBetaKey);
    final hlColor = prefs.getInt(_kHighlighterColorKey);
    final hlWidth = prefs.getDouble(_kHighlighterWidthKey);
    final penPaletteColors = decodedIntList(prefs.getString(_kPenPaletteColorsKey));
    final penPaletteWidths = decodedDoubleList(prefs.getString(_kPenPaletteWidthsKey));
    final hlPaletteColors = decodedIntList(prefs.getString(_kHlPaletteColorsKey));
    final hlPaletteWidths = decodedDoubleList(prefs.getString(_kHlPaletteWidthsKey));
    final inputDrawModeName = prefs.getString(_kInputDrawModeKey);
    InputDrawMode? inputDrawMode;
    for (final m in InputDrawMode.values) {
      if (inputDrawModeName != null && m.name == inputDrawModeName) inputDrawMode = m;
    }
    final tapeRevealedOpacity = prefs.getDouble(_kTapeRevealedOpacityKey);

    state = state.copyWith(
      activeTool: active ?? state.activeTool,
      lastEraserVariant: lastEraser ?? state.lastEraserVariant,
      eraserAreaRadius: eraserRadius ?? state.eraserAreaRadius,
      penColor: penColor ?? state.penColor,
      penWidth: penWidth ?? state.penWidth,
      penType: penType ?? state.penType,
      penSmoothingAlgo: smoothAlgo,
      penLeashStrength: penLeashStrength ?? state.penLeashStrength,
      penOneEuroSmoothing: penOneEuroSmoothing ?? state.penOneEuroSmoothing,
      penOneEuroBeta: penOneEuroBeta ?? state.penOneEuroBeta,
      highlighterColor: hlColor ?? state.highlighterColor,
      highlighterWidth: hlWidth ?? state.highlighterWidth,
      penPaletteColors: penPaletteColors ?? state.penPaletteColors,
      penPaletteWidths: penPaletteWidths ?? state.penPaletteWidths,
      highlighterPaletteColors: hlPaletteColors ?? state.highlighterPaletteColors,
      highlighterPaletteWidths: hlPaletteWidths ?? state.highlighterPaletteWidths,
      inputDrawMode: inputDrawMode ?? state.inputDrawMode,
      tapeRevealedOpacity: tapeRevealedOpacity ?? state.tapeRevealedOpacity,
    );
  }

  Future<void> _persistToolPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kActiveToolKey, state.activeTool.name);
    await prefs.setString(_kLastEraserKey, state.lastEraserVariant.name);
    await prefs.setDouble(_kEraserRadiusKey, state.eraserAreaRadius);
    await prefs.setInt(_kPenColorKey, state.penColor);
    await prefs.setDouble(_kPenWidthKey, state.penWidth);
    await prefs.setString(_kPenTypeKey, state.penType.name);
    await prefs.setInt(_kPenSmoothingAlgoKey, state.penSmoothingAlgo.index);
    await prefs.setDouble(_kPenLeashStrengthKey, state.penLeashStrength);
    await prefs.setDouble(_kPenOneEuroSmoothingKey, state.penOneEuroSmoothing);
    await prefs.setDouble(_kPenOneEuroBetaKey, state.penOneEuroBeta);
    await prefs.setInt(_kHighlighterColorKey, state.highlighterColor);
    await prefs.setDouble(_kHighlighterWidthKey, state.highlighterWidth);
    await prefs.setString(_kPenPaletteColorsKey, jsonEncode(state.penPaletteColors));
    await prefs.setString(_kPenPaletteWidthsKey, jsonEncode(state.penPaletteWidths));
    await prefs.setString(_kHlPaletteColorsKey, jsonEncode(state.highlighterPaletteColors));
    await prefs.setString(_kHlPaletteWidthsKey, jsonEncode(state.highlighterPaletteWidths));
    await prefs.setDouble(_kTapeRevealedOpacityKey, state.tapeRevealedOpacity);
    // NOTE: inputDrawMode is intentionally NOT saved here — it is only written
    // by _saveInputDrawModeAndBroadcast() so tool-switching on another window
    // cannot overwrite this instance's mode.
  }

  void _broadcastAndPersist() {
    _persistToolPrefs();
    ref.read(noteLockServiceProvider).broadcastToolChanged();
  }

  Future<void> _persistEraserPrefs() => _persistToolPrefs();

  void setTool(AppTool t) {
    // Each tool keeps its own color/width preset — switching tools does NOT
    // copy state across (so the user's pen settings stay intact when toggling
    // to highlighter and back).
    var s = state.copyWith(activeTool: t);
    final eraserChanged =
        t == AppTool.eraserArea || t == AppTool.eraserStroke;
    if (eraserChanged) {
      s = s.copyWith(lastEraserVariant: t);
    }
    if (t == AppTool.shapeRect ||
        t == AppTool.shapeEllipse ||
        t == AppTool.shapeTriangle ||
        t == AppTool.shapeDiamond ||
        t == AppTool.shapeArrow ||
        t == AppTool.shapeLine) {
      s = s.copyWith(lastShapeVariant: t);
    }
    state = s;
    // Persist on every tool switch so the active tool + last eraser
    // variant survive app restarts and remain consistent across notes.
    _persistToolPrefs();
  }

  void setInputDrawMode(InputDrawMode mode) {
    state = state.copyWith(inputDrawMode: mode);
    _saveInputDrawModeAndBroadcast();
  }

  Future<void> _saveInputDrawModeAndBroadcast() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kInputDrawModeKey, state.inputDrawMode.name);
    ref.read(noteLockServiceProvider).broadcastToolChanged();
  }

  List<int> _withRecent(int argb) {
    final next = <int>[argb];
    for (final c in state.recentColors) {
      if (c != argb && next.length < 12) next.add(c);
    }
    return next;
  }

  void setPenColor(int c) {
    state = state.copyWith(penColor: c, recentColors: _withRecent(c));
    _broadcastAndPersist();
  }
  void setPenWidth(double w) {
    state = state.copyWith(penWidth: w);
    _broadcastAndPersist();
  }
  void setPenType(PenType pt) {
    state = state.copyWith(penType: pt);
    _broadcastAndPersist();
  }
  void setPenSmoothingAlgo(PenSmoothingAlgorithm a) {
    state = state.copyWith(penSmoothingAlgo: a);
    _broadcastAndPersist();
  }
  void setPenLeashStrength(double v) {
    state = state.copyWith(penLeashStrength: v.clamp(0.0, 1.0));
    _broadcastAndPersist();
  }
  void setPenOneEuroSmoothing(double v) {
    state = state.copyWith(penOneEuroSmoothing: v.clamp(0.0, 1.0));
    _broadcastAndPersist();
  }
  void setPenOneEuroBeta(double v) {
    state = state.copyWith(penOneEuroBeta: v.clamp(0.0, 1.0));
    _broadcastAndPersist();
  }
  void setPenLineStyle(int v) =>
      state = state.copyWith(penLineStyle: v.clamp(0, 2));
  void setPenDashGap(double v) =>
      state = state.copyWith(penDashGap: v.clamp(0.5, 5.0));
  void setHighlighterColor(int c) {
    state = state.copyWith(highlighterColor: c, recentColors: _withRecent(c));
    _broadcastAndPersist();
  }
  void setHighlighterWidth(double w) {
    state = state.copyWith(highlighterWidth: w);
    _broadcastAndPersist();
  }
  void setEraserAreaRadius(double r) {
    state = state.copyWith(eraserAreaRadius: r);
    _persistEraserPrefs();
  }
  void setShapeColor(int c) =>
      state = state.copyWith(shapeColor: c, recentColors: _withRecent(c));
  void setShapeWidth(double w) => state = state.copyWith(shapeWidth: w);
  void setShapeFilled(bool f) => state = state.copyWith(shapeFilled: f);
  void setShapeFillColor(int c) => state = state.copyWith(shapeFillColorArgb: c);
  void setTapeColor(int c) =>
      state = state.copyWith(tapeColor: c, recentColors: _withRecent(c));
  void setTapeWidth(double w) => state = state.copyWith(tapeWidth: w);
  void setTextColor(int c) =>
      state = state.copyWith(textColor: c, recentColors: _withRecent(c));
  void setTextFontSize(double s) => state = state.copyWith(textFontSizePt: s.clamp(8, 96));
  void setTextFontWeight(int w) => state = state.copyWith(textFontWeight: w);
  void setTextFontFamily(String f) => state = state.copyWith(textFontFamily: f);
  void setTextItalic(bool v) => state = state.copyWith(textItalic: v);
  void setTextAlign(int v) => state = state.copyWith(textAlign: v.clamp(0, 2));
  void setLassoRect(bool v) => state = state.copyWith(lassoIsRect: v);

  /// Update the active tool's color palette slot [index] to [argb].
  void setPaletteColor(int index, int argb) {
    switch (state.activeTool) {
      case AppTool.highlighter:
        if (index < 0 || index >= state.highlighterPaletteColors.length) return;
        final next = List<int>.from(state.highlighterPaletteColors)..[index] = argb;
        state = state.copyWith(highlighterPaletteColors: next);
      case AppTool.tape:
        if (index < 0 || index >= state.tapePaletteColors.length) return;
        // Tape always uses full alpha — opacity has no UX in the tape picker.
        final opaque = 0xFF000000 | (argb & 0x00FFFFFF);
        final next = List<int>.from(state.tapePaletteColors)..[index] = opaque;
        state = state.copyWith(tapePaletteColors: next);
      default:
        if (index < 0 || index >= state.penPaletteColors.length) return;
        final next = List<int>.from(state.penPaletteColors)..[index] = argb;
        state = state.copyWith(penPaletteColors: next);
    }
    _broadcastAndPersist();
  }

  /// Update the active tool's width palette slot [index] to [widthPt].
  void setPaletteWidth(int index, double widthPt) {
    switch (state.activeTool) {
      case AppTool.highlighter:
        if (index < 0 || index >= state.highlighterPaletteWidths.length) return;
        final next = List<double>.from(state.highlighterPaletteWidths)..[index] = widthPt;
        state = state.copyWith(highlighterPaletteWidths: next);
      case AppTool.tape:
        if (index < 0 || index >= state.tapePaletteWidths.length) return;
        final next = List<double>.from(state.tapePaletteWidths)..[index] = widthPt;
        state = state.copyWith(tapePaletteWidths: next);
      default:
        if (index < 0 || index >= state.penPaletteWidths.length) return;
        final next = List<double>.from(state.penPaletteWidths)..[index] = widthPt;
        state = state.copyWith(penPaletteWidths: next);
    }
    _broadcastAndPersist();
  }

  void setTapeRevealedOpacity(double v) {
    final clamped = (v * 20).round() / 20; // snap to 5% steps
    state = state.copyWith(tapeRevealedOpacity: clamped.clamp(0.05, 0.95));
  }

  /// Update the line style of pen-palette slot [index] (0=solid,1=dashed,
  /// 2=dotted) and apply it to the active pen line style.
  void setPenPaletteLineStyle(int index, int style) {
    if (index < 0 || index >= state.penPaletteLineStyles.length) return;
    final next = List<int>.from(state.penPaletteLineStyles)
      ..[index] = style.clamp(0, 2);
    state = state.copyWith(
      penPaletteLineStyles: next,
      penLineStyle: style.clamp(0, 2),
    );
  }

  void setShapeFillPaletteColor(int index, int argb) {
    if (index < 0 || index >= state.shapeFillPaletteColors.length) return;
    final next = List<int>.from(state.shapeFillPaletteColors)..[index] = argb;
    state = state.copyWith(shapeFillPaletteColors: next);
  }

  /// Save the *current pen or highlighter* style as a preset slot.
  void savePresetFromCurrent() {
    final t = state.activeTool;
    final p = (t == AppTool.highlighter)
        ? ToolPreset(
            kind: ToolKind.highlighter,
            colorArgb: state.highlighterColor,
            widthPt: state.highlighterWidth,
            opacity: 0.35,
          )
        : ToolPreset(
            kind: ToolKind.pen,
            colorArgb: state.penColor,
            widthPt: state.penWidth,
          );
    if (state.presets.length >= 12) return; // slot cap
    state = state.copyWith(presets: [...state.presets, p]);
  }

  void removePreset(int index) {
    if (index < 0 || index >= state.presets.length) return;
    final next = [...state.presets]..removeAt(index);
    state = state.copyWith(presets: next);
  }

  void applyPreset(int index) {
    if (index < 0 || index >= state.presets.length) return;
    final p = state.presets[index];
    if (p.kind == ToolKind.highlighter) {
      state = state.copyWith(
        activeTool: AppTool.highlighter,
        highlighterColor: p.colorArgb,
        highlighterWidth: p.widthPt,
      );
    } else {
      state = state.copyWith(
        activeTool: AppTool.pen,
        penColor: p.colorArgb,
        penWidth: p.widthPt,
      );
    }
  }
}

final toolProvider =
    NotifierProvider<ToolController, ToolState>(ToolController.new);

/// Convenience: derive the underlying [ToolKind] used for stroke building.
/// All "stroke-producing" tools (pen, highlighter, all erasers, tape) route
/// through StrokeBuilder; non-stroke tools (selection, shapes, text) fall
/// through to [ToolKind.pen] as a placeholder (they don't actually produce
/// strokes; the canvas branches on AppTool to decide gesture handling).
ToolKind toolKindFor(AppTool t) {
  switch (t) {
    case AppTool.pen:
      return ToolKind.pen;
    case AppTool.highlighter:
      return ToolKind.highlighter;
    case AppTool.eraserStroke:
      return ToolKind.eraserStroke;
    case AppTool.eraserArea:
      return ToolKind.eraserArea;
    case AppTool.tape:
      return ToolKind.tape;
    case AppTool.rectSelect:
    case AppTool.lasso:
    case AppTool.shapeRect:
    case AppTool.shapeEllipse:
    case AppTool.shapeTriangle:
    case AppTool.shapeDiamond:
    case AppTool.shapeArrow:
    case AppTool.shapeLine:
    case AppTool.text:
      return ToolKind.pen;
  }
}

/// Effective area-eraser radius based on the active variant.
double effectiveEraserRadius(ToolState s) => s.eraserAreaRadius;
