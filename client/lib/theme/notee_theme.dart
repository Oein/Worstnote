// Notee design tokens — pulled from the Claude Design handoff
// (notee-app.jsx THEMES). Each surface variant has matching ink/accent/etc.
// Provides a Material ThemeData factory for the app to consume.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

enum NoteeSurface { paper, white, sepia, dark }

class NoteeTokens {
  const NoteeTokens({
    required this.bg,
    required this.page,
    required this.pageEdge,
    required this.ink,
    required this.inkDim,
    required this.inkFaint,
    required this.rule,
    required this.accent,
    required this.accentSoft,
    required this.toolbar,
    required this.tbBorder,
    required this.shelf,
    required this.brightness,
  });

  final Color bg;          // app/canvas background
  final Color page;        // page paper color
  final Color pageEdge;    // soft 0.5px page outline
  final Color ink;          // primary text/ink color
  final Color inkDim;       // body text
  final Color inkFaint;     // subtle metadata
  final Color rule;         // dividers, page rules
  final Color accent;       // brand accent
  final Color accentSoft;   // accent fill on selected pills
  final Color toolbar;      // top/bottom bar background
  final Color tbBorder;     // toolbar border
  final Color shelf;        // library shelf shade
  final Brightness brightness;

  static const Map<NoteeSurface, NoteeTokens> all = {
    NoteeSurface.paper: NoteeTokens(
      bg: Color(0xFFF4EDE0),
      page: Color(0xFFFBF6EC),
      pageEdge: Color(0x0F000000),
      ink: Color(0xFF1A1612),
      inkDim: Color(0x8C1A1612),
      inkFaint: Color(0x521A1612),
      rule: Color(0x241A1612),
      accent: Color(0xFFB4502B),
      accentSoft: Color(0x1AB4502B),
      toolbar: Color(0xFFFBF6EC),
      tbBorder: Color(0x1F000000),
      shelf: Color(0xFFE8DFCC),
      brightness: Brightness.light,
    ),
    NoteeSurface.white: NoteeTokens(
      bg: Color(0xFFE8E8E6),
      page: Color(0xFFFFFFFF),
      pageEdge: Color(0x14000000),
      ink: Color(0xFF0D0C0B),
      inkDim: Color(0x8C0D0C0B),
      inkFaint: Color(0x520D0C0B),
      rule: Color(0x1A0D0C0B),
      accent: Color(0xFF2563EB),
      accentSoft: Color(0x142563EB),
      toolbar: Color(0xFFFFFFFF),
      tbBorder: Color(0x1A000000),
      shelf: Color(0xFFDCDCD8),
      brightness: Brightness.light,
    ),
    NoteeSurface.sepia: NoteeTokens(
      bg: Color(0xFFE8D9B8),
      page: Color(0xFFF3E7C8),
      pageEdge: Color(0x1F3A2A14),
      ink: Color(0xFF3A2A14),
      inkDim: Color(0x8C3A2A14),
      inkFaint: Color(0x523A2A14),
      rule: Color(0x2E3A2A14),
      accent: Color(0xFFA4421A),
      accentSoft: Color(0x1AA4421A),
      toolbar: Color(0xFFF3E7C8),
      tbBorder: Color(0x2E3A2A14),
      shelf: Color(0xFFD8C8A4),
      brightness: Brightness.light,
    ),
    NoteeSurface.dark: NoteeTokens(
      bg: Color(0xFF15140F),
      page: Color(0xFF1C1B16),
      pageEdge: Color(0x0FFFFFFF),
      ink: Color(0xFFECE8DF),
      inkDim: Color(0x8CECE8DF),
      inkFaint: Color(0x52ECE8DF),
      rule: Color(0x24ECE8DF),
      accent: Color(0xFFE87F54),
      accentSoft: Color(0x24E87F54),
      toolbar: Color(0xFF1C1B16),
      tbBorder: Color(0x1AFFFFFF),
      shelf: Color(0xFF0F0E0B),
      brightness: Brightness.dark,
    ),
  };
}

/// Theme bundle: tokens + matching Flutter ThemeData. Read via
/// `NoteeTheme.of(context)` (extension) instead of `Theme.of` whenever you
/// need the design tokens directly.
class NoteeTheme {
  const NoteeTheme({required this.tokens, required this.material});
  final NoteeTokens tokens;
  final ThemeData material;

  static NoteeTheme build(NoteeSurface surface) {
    final t = NoteeTokens.all[surface]!;
    // The UI chrome uses a clean sans-serif (Inter Tight). Newsreader
    // (serif) is reserved for prominent moments only — notebook covers,
    // dialog titles, page headlines, the "All notebooks" hero. Mono lives
    // in tiny eyebrow labels.
    final uiFamily = GoogleFonts.interTight().fontFamily!;

    final material = ThemeData(
      useMaterial3: true,
      brightness: t.brightness,
      scaffoldBackgroundColor: t.bg,
      canvasColor: t.bg,
      dividerColor: t.rule,
      colorScheme: ColorScheme(
        brightness: t.brightness,
        primary: t.accent,
        onPrimary: Colors.white,
        secondary: t.accent,
        onSecondary: Colors.white,
        error: const Color(0xFFC62828),
        onError: Colors.white,
        surface: t.page,
        onSurface: t.ink,
        surfaceContainerLowest: t.bg,
        surfaceContainerLow: t.bg,
        surfaceContainer: t.toolbar,
        surfaceContainerHigh: t.toolbar,
        surfaceContainerHighest: t.toolbar,
        outline: t.tbBorder,
        outlineVariant: t.rule,
      ),
      // UI chrome is sans (Inter Tight); only display/headline/large titles
      // (notebook covers, page hero, dialog title) keep the Newsreader serif.
      // Mono is reserved for tiny eyebrow/meta labels.
      fontFamily: uiFamily,
      textTheme: TextTheme(
        displayLarge: GoogleFonts.newsreader(
            fontWeight: FontWeight.w600, color: t.ink, letterSpacing: -0.5),
        displayMedium: GoogleFonts.newsreader(
            fontWeight: FontWeight.w600, color: t.ink, letterSpacing: -0.4),
        displaySmall: GoogleFonts.newsreader(
            fontWeight: FontWeight.w600, color: t.ink, letterSpacing: -0.3),
        headlineLarge: GoogleFonts.newsreader(
            fontWeight: FontWeight.w600, color: t.ink, letterSpacing: -0.4),
        headlineMedium: GoogleFonts.newsreader(
            fontWeight: FontWeight.w600, color: t.ink, letterSpacing: -0.3),
        headlineSmall: GoogleFonts.newsreader(
            fontWeight: FontWeight.w600, color: t.ink),
        titleLarge: GoogleFonts.interTight(
            fontWeight: FontWeight.w600, color: t.ink, fontSize: 15),
        titleMedium: GoogleFonts.interTight(
            fontWeight: FontWeight.w600, color: t.ink),
        titleSmall: GoogleFonts.interTight(
            fontWeight: FontWeight.w600, color: t.ink),
        bodyLarge: GoogleFonts.interTight(color: t.ink),
        bodyMedium: GoogleFonts.interTight(color: t.ink),
        bodySmall: GoogleFonts.interTight(color: t.inkDim),
        labelLarge: GoogleFonts.interTight(
            fontWeight: FontWeight.w600, color: t.ink),
        labelMedium: GoogleFonts.interTight(color: t.inkDim),
        labelSmall: GoogleFonts.jetBrainsMono(
            fontSize: 10, color: t.inkFaint, letterSpacing: 0.4),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: t.toolbar,
        foregroundColor: t.ink,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: GoogleFonts.interTight(
          color: t.ink,
          fontSize: 14,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.1,
        ),
        toolbarHeight: 44,
        iconTheme: IconThemeData(color: t.ink, size: 18),
      ),
      iconTheme: IconThemeData(color: t.ink, size: 18),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: t.ink,
          minimumSize: const Size(32, 32),
          padding: EdgeInsets.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: t.ink,
          foregroundColor: t.page,
          textStyle: GoogleFonts.interTight(
              fontSize: 12.5, fontWeight: FontWeight.w600),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(9)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        ),
      ),
      dividerTheme: DividerThemeData(color: t.rule, thickness: 0.5, space: 1),
      // Make sure default Material widgets pick up the right ink color.
      primaryColor: t.accent,
    );

    // Touch up font fallback chains so subtle widgets (tooltip, snackbar,
    // chips) all use the design family.
    return NoteeTheme(
      tokens: t,
      material: material.copyWith(
        cardColor: t.toolbar,
        chipTheme: ChipThemeData(
          backgroundColor: t.bg,
          labelStyle:
              GoogleFonts.interTight(color: t.inkDim, fontSize: 11),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(99)),
          ),
        ),
      ),
    );
  }
}

/// Convenience accessor for any subtree under a NoteeProvider.
class NoteeProvider extends InheritedWidget {
  const NoteeProvider({
    super.key,
    required this.theme,
    required super.child,
  });
  final NoteeTheme theme;
  static NoteeTheme of(BuildContext c) {
    final w = c.dependOnInheritedWidgetOfExactType<NoteeProvider>();
    assert(w != null, 'NoteeProvider missing above this widget');
    return w!.theme;
  }

  @override
  bool updateShouldNotify(NoteeProvider old) =>
      old.theme.tokens != theme.tokens;
}

/// Tiny helper: warm parchment-style "page" decoration for paper rectangles.
BoxDecoration noteePaperDecoration(NoteeTokens t,
    {double radius = 4, bool emphasize = false}) {
  return BoxDecoration(
    color: t.page,
    borderRadius: BorderRadius.circular(radius),
    boxShadow: [
      BoxShadow(
        color: t.pageEdge,
        spreadRadius: 0.5,
        blurRadius: 0,
      ),
      BoxShadow(
        color: Colors.black.withValues(alpha: emphasize ? 0.14 : 0.10),
        offset: const Offset(0, 8),
        blurRadius: 24,
      ),
      BoxShadow(
        color: Colors.black.withValues(alpha: emphasize ? 0.08 : 0.06),
        offset: const Offset(0, 1),
        blurRadius: 3,
      ),
    ],
  );
}

/// Mono-uppercase "section eyebrow" text style.
TextStyle noteeSectionEyebrow(NoteeTokens t) =>
    GoogleFonts.jetBrainsMono(
      fontSize: 9,
      fontWeight: FontWeight.w600,
      letterSpacing: 1.6,
      color: t.inkFaint,
    );
