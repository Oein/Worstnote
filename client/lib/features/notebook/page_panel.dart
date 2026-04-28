// PagePanel — left/right side panel listing all pages, with add/delete and
// per-page spec configuration (paper kind, custom dimensions, background).

import 'package:flutter/material.dart';

import '../../domain/page.dart';
import '../../domain/page_spec.dart';

class PagePanel extends StatelessWidget {
  const PagePanel({
    super.key,
    required this.pages,
    required this.activePageId,
    required this.onSelect,
    required this.onAdd,
    required this.onDelete,
    required this.onChangeSpec,
    this.onImportImage,
  });

  final List<NotePage> pages;
  final String? activePageId;
  final void Function(String pageId) onSelect;
  final void Function() onAdd;
  final void Function(String pageId) onDelete;
  final void Function(String pageId, PageSpec spec) onChangeSpec;

  /// If non-null, an "Import image as new page" button shows in the AppBar.
  final Future<void> Function()? onImportImage;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppBar(
            title: const Text('Pages'),
            primary: false,
            actions: [
              if (onImportImage != null)
                IconButton(
                  tooltip: 'Import image as new page',
                  icon: const Icon(Icons.image_outlined),
                  onPressed: onImportImage,
                ),
              IconButton(
                tooltip: 'Add page',
                icon: const Icon(Icons.add),
                onPressed: onAdd,
              ),
            ],
          ),
          Expanded(
            child: ListView.builder(
              itemCount: pages.length,
              itemBuilder: (context, i) {
                final p = pages[i];
                return Card(
                  color: p.id == activePageId
                      ? Theme.of(context).colorScheme.primaryContainer
                      : null,
                  margin:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: ListTile(
                    onTap: () => onSelect(p.id),
                    title: Text('Page ${p.index + 1}'),
                    subtitle: Text(_specSummary(p.spec)),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(
                        tooltip: 'Edit page',
                        icon: const Icon(Icons.tune),
                        onPressed: () async {
                          final next = await _editSpec(context, p.spec);
                          if (next != null) onChangeSpec(p.id, next);
                        },
                      ),
                      if (pages.length > 1)
                        IconButton(
                          tooltip: 'Delete page',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => onDelete(p.id),
                        ),
                    ]),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  String _specSummary(PageSpec s) {
    final size = '${s.widthPt.round()}×${s.heightPt.round()}pt';
    final bg = switch (s.background) {
      BlankBackground() => 'blank',
      GridBackground() => 'grid',
      RuledBackground() => 'ruled',
      DotBackground() => 'dot',
      ImageBackground() => 'image',
      PdfBackground() => 'pdf',
    };
    return '${s.kind.name} · $size · $bg';
  }
}

Future<PageSpec?> _editSpec(BuildContext context, PageSpec initial) {
  return showDialog<PageSpec>(
    context: context,
    builder: (_) => _SpecDialog(initial: initial),
  );
}

class _SpecDialog extends StatefulWidget {
  const _SpecDialog({required this.initial});
  final PageSpec initial;

  @override
  State<_SpecDialog> createState() => _SpecDialogState();
}

class _SpecDialogState extends State<_SpecDialog> {
  late PaperKind _kind;
  late double _w;
  late double _h;
  late PageBackground _bg;
  late TextEditingController _wCtl;
  late TextEditingController _hCtl;

  @override
  void initState() {
    super.initState();
    _kind = widget.initial.kind;
    _w = widget.initial.widthPt;
    _h = widget.initial.heightPt;
    _bg = widget.initial.background;
    _wCtl = TextEditingController(text: _w.toStringAsFixed(0));
    _hCtl = TextEditingController(text: _h.toStringAsFixed(0));
  }

  @override
  void dispose() {
    _wCtl.dispose();
    _hCtl.dispose();
    super.dispose();
  }

  void _applyKindPreset(PaperKind k) {
    setState(() {
      _kind = k;
      if (k != PaperKind.custom && k != PaperKind.pdfImported) {
        final (w, h) = PaperDimensions.forKind(k);
        _w = w; _h = h;
      }
      _wCtl.text = _w.toStringAsFixed(0);
      _hCtl.text = _h.toStringAsFixed(0);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit page'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Paper'),
            Wrap(spacing: 4, children: [
              for (final k in PaperKind.values)
                if (k != PaperKind.pdfImported)
                  ChoiceChip(
                    label: Text(k.name),
                    selected: _kind == k,
                    onSelected: (_) => _applyKindPreset(k),
                  ),
            ]),
            const SizedBox(height: 16),
            const Text('Size (pt)'),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _wCtl,
                  decoration: const InputDecoration(labelText: 'width'),
                  keyboardType: TextInputType.number,
                  onChanged: (v) {
                    final n = double.tryParse(v);
                    if (n != null && n > 0) {
                      _w = n;
                      _kind = PaperKind.custom;
                    }
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _hCtl,
                  decoration: const InputDecoration(labelText: 'height'),
                  keyboardType: TextInputType.number,
                  onChanged: (v) {
                    final n = double.tryParse(v);
                    if (n != null && n > 0) {
                      _h = n;
                      _kind = PaperKind.custom;
                    }
                  },
                ),
              ),
            ]),
            const SizedBox(height: 16),
            const Text('Background'),
            Wrap(spacing: 4, children: [
              for (final entry in [
                ('blank', const PageBackground.blank()),
                ('grid', const PageBackground.grid(spacingPt: 24)),
                ('ruled', const PageBackground.ruled(spacingPt: 28)),
                ('dot', const PageBackground.dot(spacingPt: 24)),
              ])
                ChoiceChip(
                  label: Text(entry.$1),
                  selected:
                      _bg.runtimeType == entry.$2.runtimeType,
                  onSelected: (_) => setState(() => _bg = entry.$2),
                ),
            ]),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.pop(
              context,
              PageSpec(
                widthPt: _w,
                heightPt: _h,
                kind: _kind,
                background: _bg,
              ),
            );
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
