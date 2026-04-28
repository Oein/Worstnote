// LayerPanel — right-side slide-in for managing layers on a page.
//
// Features (P3):
//   - Add / delete / duplicate (visual ops only, last layer un-deletable)
//   - Drag-to-reorder via ReorderableListView
//   - Toggle visibility / lock
//   - Opacity slider
//   - Inline rename

import 'package:flutter/material.dart';

import '../../domain/layer.dart';
import '../../theme/notee_theme.dart';

class LayerPanel extends StatelessWidget {
  const LayerPanel({
    super.key,
    required this.layers,
    required this.activeLayerId,
    required this.onSelect,
    required this.onToggleVisible,
    required this.onToggleLocked,
    this.onAdd,
    this.onDelete,
    this.onRename,
    this.onSetOpacity,
    this.onReorder,
  });

  final List<Layer> layers;
  final String activeLayerId;
  final void Function(String id) onSelect;
  final void Function(String id) onToggleVisible;
  final void Function(String id) onToggleLocked;
  final VoidCallback? onAdd;
  final void Function(String id)? onDelete;
  final void Function(String id, String name)? onRename;
  final void Function(String id, double opacity)? onSetOpacity;

  /// Receives layer ids in their new top-to-bottom display order.
  final void Function(List<String> orderedIds)? onReorder;

  @override
  Widget build(BuildContext context) {
    // Display order: top z first (so the topmost layer shows at top of panel).
    final sorted = [...layers]..sort((a, b) => b.z.compareTo(a.z));

    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppBar(
            title: const Text('Layers'),
            primary: false,
            actions: [
              IconButton(
                tooltip: 'Add layer',
                icon: const Icon(Icons.add),
                onPressed: onAdd,
              ),
            ],
          ),
          Expanded(
            child: ReorderableListView.builder(
              itemCount: sorted.length,
              buildDefaultDragHandles: false,
              onReorder: (oldIndex, newIndex) {
                if (newIndex > oldIndex) newIndex -= 1;
                final ids = sorted.map((l) => l.id).toList();
                final m = ids.removeAt(oldIndex);
                ids.insert(newIndex, m);
                // Convert top-down display order to bottom-up z order.
                final ordered = ids.reversed.toList();
                onReorder?.call(ordered);
              },
              itemBuilder: (context, i) {
                final l = sorted[i];
                return _LayerTile(
                  key: ValueKey(l.id),
                  index: i,
                  layer: l,
                  active: l.id == activeLayerId,
                  onSelect: () => onSelect(l.id),
                  onToggleVisible: () => onToggleVisible(l.id),
                  onToggleLocked: () => onToggleLocked(l.id),
                  onDelete:
                      onDelete == null ? null : () => onDelete!(l.id),
                  onRename: onRename == null
                      ? null
                      : (v) => onRename!(l.id, v),
                  onSetOpacity: onSetOpacity == null
                      ? null
                      : (v) => onSetOpacity!(l.id, v),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _LayerTile extends StatefulWidget {
  const _LayerTile({
    super.key,
    required this.index,
    required this.layer,
    required this.active,
    required this.onSelect,
    required this.onToggleVisible,
    required this.onToggleLocked,
    this.onDelete,
    this.onRename,
    this.onSetOpacity,
  });

  final int index;
  final Layer layer;
  final bool active;
  final VoidCallback onSelect;
  final VoidCallback onToggleVisible;
  final VoidCallback onToggleLocked;
  final VoidCallback? onDelete;
  final void Function(String name)? onRename;
  final void Function(double opacity)? onSetOpacity;

  @override
  State<_LayerTile> createState() => _LayerTileState();
}

class _LayerTileState extends State<_LayerTile> {
  bool _editing = false;
  late TextEditingController _nameCtl;

  @override
  void initState() {
    super.initState();
    _nameCtl = TextEditingController(text: widget.layer.name);
  }

  @override
  void didUpdateWidget(covariant _LayerTile old) {
    super.didUpdateWidget(old);
    if (old.layer.name != widget.layer.name && !_editing) {
      _nameCtl.text = widget.layer.name;
    }
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    super.dispose();
  }

  void _commitRename() {
    setState(() => _editing = false);
    final v = _nameCtl.text.trim();
    if (v.isEmpty) return;
    widget.onRename?.call(v);
  }

  @override
  Widget build(BuildContext context) {
    final l = widget.layer;
    final t = NoteeProvider.of(context).tokens;
    return Card(
      color: widget.active ? t.accentSoft : null,
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: InkWell(
        onTap: widget.onSelect,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                ReorderableDragStartListener(
                  index: widget.index,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4),
                    child: Icon(Icons.drag_indicator, size: 18),
                  ),
                ),
                IconButton(
                  tooltip: l.visible ? 'Hide' : 'Show',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(l.visible
                      ? Icons.visibility
                      : Icons.visibility_off),
                  onPressed: widget.onToggleVisible,
                ),
                IconButton(
                  tooltip: l.locked ? 'Unlock' : 'Lock',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(l.locked ? Icons.lock : Icons.lock_open),
                  onPressed: widget.onToggleLocked,
                ),
                Expanded(
                  child: _editing
                      ? TextField(
                          controller: _nameCtl,
                          autofocus: true,
                          onSubmitted: (_) => _commitRename(),
                          decoration: const InputDecoration(
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                        )
                      : GestureDetector(
                          onDoubleTap: widget.onRename == null
                              ? null
                              : () => setState(() => _editing = true),
                          child: Text(
                            l.name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontWeight: FontWeight.w600),
                          ),
                        ),
                ),
                if (widget.onDelete != null)
                  IconButton(
                    tooltip: 'Delete',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.delete_outline),
                    onPressed: widget.onDelete,
                  ),
              ]),
              if (widget.onSetOpacity != null)
                Row(children: [
                  const SizedBox(width: 4),
                  Text('Opacity ${(l.opacity * 100).round()}%',
                      style: const TextStyle(fontSize: 11)),
                  Expanded(
                    child: Slider(
                      min: 0,
                      max: 1,
                      value: l.opacity.clamp(0.0, 1.0),
                      onChanged: widget.onSetOpacity!,
                    ),
                  ),
                ]),
            ],
          ),
        ),
      ),
    );
  }
}
