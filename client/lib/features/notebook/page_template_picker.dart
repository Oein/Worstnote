// Template picker dialogs for adding a new page.
//
// Public API:
//   showPageTemplatePicker  — root "페이지 추가" dialog (Layer 1)
//   showPageSettingsDialog  — "페이지 설정" dialog (Layer 2)
//
// Both can be used independently; the root dialog calls the settings dialog
// when the user taps "정하기".

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../domain/page_spec.dart';
import '../canvas/painters/background_painter.dart';
import '../../theme/notee_icons.dart';
import '../../theme/notee_theme.dart';

// ── Public entry points ────────────────────────────────────────────────────

/// Shows the root "페이지 추가" dialog.
/// Returns the [PageSpec] the user chose, or null if cancelled.
Future<PageSpec?> showPageTemplatePicker(
  BuildContext context, {
  PageSpec? currentSpec,
}) {
  return showDialog<PageSpec>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.25),
    builder: (_) => _AddPageDialog(currentSpec: currentSpec),
  );
}

/// Shows the standalone "페이지 설정" dialog (Layer 2).
/// Returns the [PageSpec] that the user confirmed, or null if cancelled.
Future<PageSpec?> showPageSettingsDialog(
  BuildContext context, {
  required PageSpec initial,
}) {
  return showDialog<PageSpec>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.25),
    builder: (_) => _PageSettingsDialog(initial: initial),
  );
}

// ── Shared dialog shell ────────────────────────────────────────────────────

/// Wraps [child] in the standard Notee dialog chrome:
/// transparent Dialog + card with toolbar bg, 14px radius, 0.5px border, shadow.
class _NoteeDialogShell extends StatelessWidget {
  const _NoteeDialogShell({
    required this.title,
    required this.child,
    this.width = 360,
  });

  final String title;
  final Widget child;
  final double width;

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 28),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width),
        child: Container(
          decoration: BoxDecoration(
            color: t.toolbar,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: t.tbBorder, width: 0.5),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 32,
                offset: const Offset(0, 8),
              ),
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 4,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Title bar
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 0),
                child: Text(
                  title,
                  style: TextStyle(
                    color: t.ink,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.1,
                  ),
                ),
              ),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

// ── Layer 1: "페이지 추가" ─────────────────────────────────────────────────

class _AddPageDialog extends StatelessWidget {
  const _AddPageDialog({this.currentSpec});

  final PageSpec? currentSpec;

  // Opens a file picker and returns a PageSpec (currently returns a4Blank as
  // a placeholder; a real import pipeline would parse the file).
  Future<PageSpec?> _pickFile(BuildContext context) async {
    const typeGroup = XTypeGroup(
      label: 'Documents',
      extensions: ['pdf', 'png', 'jpg', 'jpeg'],
    );
    final file = await openFile(acceptedTypeGroups: [typeGroup]);
    if (file == null) return null;
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('파일 가져오기는 아직 지원되지 않습니다.'),
          duration: Duration(seconds: 2),
        ),
      );
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;

    return _NoteeDialogShell(
      title: '페이지 추가',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Quick-action row ──────────────────────────────────────────
            Row(
              children: [
                Expanded(
                  child: _QuickActionButton(
                    icon: NoteeIcon.folder,
                    label: '불러오기',
                    tokens: t,
                    onTap: () async {
                      final spec = await _pickFile(context);
                      if (context.mounted) {
                        Navigator.of(context).pop(spec);
                      }
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _QuickActionButton(
                    icon: NoteeIcon.mic,
                    label: '이미지 찍기',
                    tokens: t,
                    onTap: () async {
                      // Desktop has no camera; alias to file picker.
                      final spec = await _pickFile(context);
                      if (context.mounted) {
                        Navigator.of(context).pop(spec);
                      }
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            // ── Quick template tiles (4-across) ──────────────────────────
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 현재 페이지
                Expanded(
                  child: _ChoiceTile(
                    label: '현재 페이지',
                    spec: currentSpec ?? PageSpec.a4Blank(),
                    tokens: t,
                    onTap: () => Navigator.of(context)
                        .pop(currentSpec ?? PageSpec.a4Blank()),
                  ),
                ),
                const SizedBox(width: 8),
                // 일반 A4
                Expanded(
                  child: _ChoiceTile(
                    label: '일반 A4',
                    spec: PageSpec.a4Blank(),
                    tokens: t,
                    onTap: () =>
                        Navigator.of(context).pop(PageSpec.a4Blank()),
                  ),
                ),
                const SizedBox(width: 8),
                // 모눈종이
                Expanded(
                  child: _ChoiceTile(
                    label: '모눈종이',
                    spec: const PageSpec(
                      widthPt: 595.276,
                      heightPt: 841.89,
                      kind: PaperKind.a4,
                      background: PageBackground.grid(spacingPt: 20),
                    ),
                    tokens: t,
                    onTap: () => Navigator.of(context).pop(const PageSpec(
                      widthPt: 595.276,
                      heightPt: 841.89,
                      kind: PaperKind.a4,
                      background: PageBackground.grid(spacingPt: 20),
                    )),
                  ),
                ),
                const SizedBox(width: 8),
                // 점선지
                Expanded(
                  child: _ChoiceTile(
                    label: '점선지',
                    spec: const PageSpec(
                      widthPt: 595.276,
                      heightPt: 841.89,
                      kind: PaperKind.a4,
                      background: PageBackground.dot(spacingPt: 20),
                    ),
                    tokens: t,
                    onTap: () => Navigator.of(context).pop(const PageSpec(
                      widthPt: 595.276,
                      heightPt: 841.89,
                      kind: PaperKind.a4,
                      background: PageBackground.dot(spacingPt: 20),
                    )),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            // ── Bottom row: 직접 정하기 + 취소 ──────────────────────────
            Row(
              children: [
                // 직접 정하기 → opens Layer 2
                GestureDetector(
                  onTap: () async {
                    final result = await showPageSettingsDialog(
                      context,
                      initial: currentSpec ?? PageSpec.a4Blank(),
                    );
                    if (result != null && context.mounted) {
                      Navigator.of(context).pop(result);
                    }
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        NoteeIconWidget(
                            NoteeIcon.plus, size: 13, color: t.inkDim),
                        const SizedBox(width: 5),
                        Text(
                          '직접 정하기',
                          style: TextStyle(
                            color: t.inkDim,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const Spacer(),
                _TextButton(
                  label: '취소',
                  tokens: t,
                  onTap: () => Navigator.of(context).pop(null),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── Layer 2: "페이지 설정" ─────────────────────────────────────────────────

class _PageSettingsDialog extends StatefulWidget {
  const _PageSettingsDialog({required this.initial});

  final PageSpec initial;

  @override
  State<_PageSettingsDialog> createState() => _PageSettingsDialogState();
}

class _PageSettingsDialogState extends State<_PageSettingsDialog> {
  late PaperKind _kind;
  late bool _landscape;
  late PageBackground _bg;

  static const _nonSquareKinds = {
    PaperKind.a3, PaperKind.a4, PaperKind.a5,
    PaperKind.b3, PaperKind.b4, PaperKind.b5,
    PaperKind.letter,
  };

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _kind = (initial.kind == PaperKind.custom ||
             initial.kind == PaperKind.pdfImported)
        ? PaperKind.a4
        : initial.kind;
    // Detect landscape: width > height for non-square kinds
    _landscape = _nonSquareKinds.contains(_kind) &&
        initial.widthPt > initial.heightPt;
    _bg = initial.background;
  }

  PageSpec _buildSpec() {
    var (w, h) = PaperDimensions.forKind(_kind);
    if (_landscape && _nonSquareKinds.contains(_kind)) {
      final tmp = w; w = h; h = tmp;
    }
    return PageSpec(widthPt: w, heightPt: h, kind: _kind, background: _bg);
  }

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;

    const sizeGroups = [
      [(PaperKind.a3, 'A3'), (PaperKind.a4, 'A4'), (PaperKind.a5, 'A5')],
      [(PaperKind.b3, 'B3'), (PaperKind.b4, 'B4'), (PaperKind.b5, 'B5')],
      [(PaperKind.letter, 'Letter'), (PaperKind.square, '정사각형')],
    ];

    final bgOptions = [
      (const PageBackground.blank(), '빈'),
      (const PageBackground.ruled(spacingPt: 20), '줄'),
      (const PageBackground.grid(spacingPt: 20), '격자'),
      (const PageBackground.dot(spacingPt: 20), '점'),
    ];

    final showOrientation = _nonSquareKinds.contains(_kind);

    return _NoteeDialogShell(
      title: '페이지 설정',
      width: 400,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Size section ──────────────────────────────────────────────
            Text('크기', style: noteeSectionEyebrow(t)),
            const SizedBox(height: 8),
            for (final group in sizeGroups) ...[
              Row(children: [
                for (final (kind, label) in group)
                  Padding(
                    padding: const EdgeInsets.only(right: 6, bottom: 6),
                    child: _SizeChip(
                      label: label,
                      selected: _kind == kind,
                      tokens: t,
                      onTap: () => setState(() => _kind = kind),
                    ),
                  ),
              ]),
            ],
            // ── Orientation section ───────────────────────────────────────
            if (showOrientation) ...[
              const SizedBox(height: 4),
              Row(children: [
                _OrientationButton(
                  label: '세로',
                  isPortrait: true,
                  selected: !_landscape,
                  tokens: t,
                  onTap: () => setState(() => _landscape = false),
                ),
                const SizedBox(width: 6),
                _OrientationButton(
                  label: '가로',
                  isPortrait: false,
                  selected: _landscape,
                  tokens: t,
                  onTap: () => setState(() => _landscape = true),
                ),
              ]),
            ],
            const SizedBox(height: 16),
            // ── Background section ────────────────────────────────────────
            Text('배경', style: noteeSectionEyebrow(t)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final (bg, label) in bgOptions)
                  _BgTile(
                    background: bg,
                    label: label,
                    selected: _bg.runtimeType == bg.runtimeType,
                    tokens: t,
                    onTap: () => setState(() => _bg = bg),
                  ),
              ],
            ),
            const SizedBox(height: 18),
            // ── Action row ────────────────────────────────────────────────
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                _TextButton(
                  label: '취소',
                  tokens: t,
                  onTap: () => Navigator.of(context).pop(null),
                ),
                const SizedBox(width: 8),
                _FilledButton(
                  label: '적용',
                  tokens: t,
                  onTap: () => Navigator.of(context).pop(_buildSpec()),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── Small reusable widgets ─────────────────────────────────────────────────

/// Outlined quick-action button with icon + label (used in Layer 1 top row).
class _QuickActionButton extends StatelessWidget {
  const _QuickActionButton({
    required this.icon,
    required this.label,
    required this.tokens,
    required this.onTap,
  });

  final NoteeIcon icon;
  final String label;
  final NoteeTokens tokens;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: t.tbBorder, width: 1),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            NoteeIconWidget(icon, size: 16, color: t.inkDim),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                style: TextStyle(
                  color: t.ink,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Page preview tile with a BackgroundPainter thumbnail + label.
class _ChoiceTile extends StatelessWidget {
  const _ChoiceTile({
    required this.label,
    required this.spec,
    required this.tokens,
    required this.onTap,
  });

  final String label;
  final PageSpec spec;
  final NoteeTokens tokens;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 3:4 aspect-ratio thumbnail
          AspectRatio(
            aspectRatio: 3 / 4,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: t.tbBorder, width: 0.5),
              ),
              clipBehavior: Clip.antiAlias,
              child: CustomPaint(
                painter: BackgroundPainter(background: spec.background),
                child: const SizedBox.expand(),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: TextStyle(
              color: t.ink,
              fontSize: 11.5,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

/// Small pill chip for selecting paper size.
class _SizeChip extends StatelessWidget {
  const _SizeChip({
    required this.label,
    required this.selected,
    required this.tokens,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final NoteeTokens tokens;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? t.accentSoft : t.bg,
          borderRadius: BorderRadius.circular(99),
          border: Border.all(
            color: selected ? t.accent : t.tbBorder,
            width: selected ? 1 : 0.5,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? t.accent : t.ink,
            fontSize: 12,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}

class _OrientationButton extends StatelessWidget {
  const _OrientationButton({
    required this.label,
    required this.isPortrait,
    required this.selected,
    required this.tokens,
    required this.onTap,
  });

  final String label;
  final bool isPortrait;
  final bool selected;
  final NoteeTokens tokens;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? t.accentSoft : t.bg,
          borderRadius: BorderRadius.circular(99),
          border: Border.all(
            color: selected ? t.accent : t.tbBorder,
            width: selected ? 1 : 0.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _PageShapeIcon(portrait: isPortrait, selected: selected, tokens: t),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                color: selected ? t.accent : t.ink,
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PageShapeIcon extends StatelessWidget {
  const _PageShapeIcon({
    required this.portrait,
    required this.selected,
    required this.tokens,
  });
  final bool portrait;
  final bool selected;
  final NoteeTokens tokens;

  @override
  Widget build(BuildContext context) {
    final w = portrait ? 8.0 : 11.0;
    final h = portrait ? 11.0 : 8.0;
    return Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(1.5),
        border: Border.all(
          color: selected ? tokens.accent : tokens.inkDim,
          width: 1.2,
        ),
      ),
    );
  }
}

/// Background style tile with a small CustomPaint preview.
class _BgTile extends StatelessWidget {
  const _BgTile({
    required this.background,
    required this.label,
    required this.selected,
    required this.tokens,
    required this.onTap,
  });

  final PageBackground background;
  final String label;
  final bool selected;
  final NoteeTokens tokens;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    // Each tile is roughly (total width - 3 gaps) / 4 wide; using a fixed
    // width here so Wrap lays them out predictably.
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 72,
        child: Column(
          children: [
            AspectRatio(
              aspectRatio: 3 / 4,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: selected ? t.accent : t.tbBorder,
                    width: selected ? 1.5 : 0.5,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: CustomPaint(
                  painter: BackgroundPainter(background: background),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
            const SizedBox(height: 5),
            Text(
              label,
              style: TextStyle(
                color: selected ? t.accent : t.inkDim,
                fontSize: 11,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Plain text button (for "취소" actions).
class _TextButton extends StatelessWidget {
  const _TextButton({
    required this.label,
    required this.tokens,
    required this.onTap,
  });

  final String label;
  final NoteeTokens tokens;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Text(
          label,
          style: TextStyle(
            color: tokens.inkDim,
            fontSize: 12.5,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

/// Filled accent button (for "적용" / confirm actions).
class _FilledButton extends StatelessWidget {
  const _FilledButton({
    required this.label,
    required this.tokens,
    required this.onTap,
  });

  final String label;
  final NoteeTokens tokens;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        decoration: BoxDecoration(
          color: t.accent,
          borderRadius: BorderRadius.circular(9),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
