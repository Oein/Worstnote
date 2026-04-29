// HistoryScreen — browse note commit history and restore to a past state.
//
// Each commit shows: message, device ID, creation time, and the rev range.
// Tapping a commit opens a snapshot preview screen; a Restore button is there.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../data/api/api_client.dart';
import '../../domain/page_object.dart';
import '../../features/canvas/painters/layer_painter.dart';
import '../../theme/notee_icons.dart';
import '../../theme/notee_theme.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({
    super.key,
    required this.noteId,
    required this.client,
  });

  final String noteId;
  final ApiClient client;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<Map<String, dynamic>>? _commits;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.client.historyList(widget.noteId);
      if (!mounted) return;
      final list = data['commits'] as List<dynamic>? ?? [];
      setState(() {
        _commits = list.cast<Map<String, dynamic>>();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _restore(Map<String, dynamic> commit) async {
    final t = NoteeProvider.of(context).tokens;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: t.toolbar,
        title: Text('Restore?', style: TextStyle(color: t.ink, fontSize: 16)),
        content: Text(
          'Restore note to "${commit['message']}"?\n'
          'Current changes will be replaced.',
          style: TextStyle(color: t.inkDim, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: TextStyle(color: t.inkDim)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Restore', style: TextStyle(color: t.accent)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await widget.client.historyRestore(widget.noteId, commit['id'] as String);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Restored successfully. Pull to sync.'),
          backgroundColor: t.accent,
        ),
      );
      Navigator.pop(context, true); // signal caller to re-pull
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Restore failed: $e'),
          backgroundColor: Colors.red.shade700,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    return Scaffold(
      backgroundColor: t.bg,
      appBar: AppBar(
        backgroundColor: t.toolbar,
        elevation: 0,
        leading: IconButton(
          icon: NoteeIconWidget(NoteeIcon.chev, size: 18, color: t.ink),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'Version History',
          style: TextStyle(
            color: t.ink,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(height: 1, thickness: 1, color: t.tbBorder),
        ),
      ),
      body: _buildBody(t),
    );
  }

  Widget _buildBody(NoteeTokens t) {
    if (_loading) {
      return Center(
        child: CircularProgressIndicator(color: t.accent),
      );
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: TextStyle(color: t.inkDim, fontSize: 14)),
            const SizedBox(height: 12),
            TextButton(
              onPressed: _load,
              child: Text('Retry', style: TextStyle(color: t.accent)),
            ),
          ],
        ),
      );
    }
    final commits = _commits ?? [];
    if (commits.isEmpty) {
      return Center(
        child: Text(
          'No version history yet.\nPush changes to create commits.',
          textAlign: TextAlign.center,
          style: TextStyle(color: t.inkFaint, fontSize: 14),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: commits.length,
      separatorBuilder: (_, __) =>
          Divider(height: 1, thickness: 1, color: t.tbBorder),
      itemBuilder: (ctx, i) => _CommitTile(
        commit: commits[i],
        tokens: t,
        isLatest: i == 0,
        onTap: () async {
          final commit = commits[i];
          final restored = await Navigator.of(context).push<bool>(
            MaterialPageRoute(
              builder: (_) => _SnapshotScreen(
                noteId: widget.noteId,
                commit: commit,
                client: widget.client,
              ),
            ),
          );
          if (restored == true && mounted) {
            Navigator.pop(context, true);
          }
        },
      ),
    );
  }
}

class _CommitTile extends StatelessWidget {
  const _CommitTile({
    required this.commit,
    required this.tokens,
    required this.isLatest,
    required this.onTap,
  });

  final Map<String, dynamic> commit;
  final NoteeTokens tokens;
  final bool isLatest;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    final message = commit['message'] as String? ?? '';
    final deviceId = commit['deviceId'] as String? ?? '';
    final revTo = commit['revTo'] as int? ?? 0;
    final createdAtRaw = commit['createdAt'] as String? ?? '';
    final createdAt = DateTime.tryParse(createdAtRaw)?.toLocal();
    final timeStr = createdAt != null ? _formatTime(createdAt) : createdAtRaw;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: isLatest ? t.accent : t.accentSoft,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.commit,
                size: 16,
                color: isLatest ? Colors.white : t.accent,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          message,
                          style: TextStyle(
                            color: t.ink,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (isLatest)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: t.accentSoft,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            'latest',
                            style: TextStyle(
                              color: t.accent,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '$timeStr · rev $revTo'
                    '${deviceId.isNotEmpty ? ' · ${_shortDevice(deviceId)}' : ''}',
                    style: TextStyle(color: t.inkFaint, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            NoteeIconWidget(NoteeIcon.chev, size: 12, color: t.inkFaint),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.month}/${dt.day}/${dt.year}';
  }

  /// Decodes the deviceId platform prefix into a readable label.
  /// AuthController writes ids as "<platformTag>-<uuid>" — see _ensureDeviceId.
  ///   mac-...  → "macOS"
  ///   and-...  → "Android"
  ///   ios-...  → "iOS"
  ///   web-...  → "Web"
  /// A short suffix is appended so two devices on the same platform can be
  /// told apart at a glance.
  String _shortDevice(String id) {
    String label;
    String suffix;
    final dash = id.indexOf('-');
    if (dash > 0 && dash < 6) {
      final tag = id.substring(0, dash);
      label = switch (tag) {
        'mac' => 'macOS',
        'and' => 'Android',
        'ios' => 'iOS',
        'web' => 'Web',
        _ => tag,
      };
      final rest = id.substring(dash + 1);
      suffix = rest.length > 6 ? rest.substring(0, 6) : rest;
    } else {
      label = '디바이스';
      suffix = id.length > 6 ? id.substring(0, 6) : id;
    }
    return '$label · $suffix';
  }
}

// ── Snapshot preview screen ───────────────────────────────────────────────────

class _SnapshotScreen extends StatefulWidget {
  const _SnapshotScreen({
    required this.noteId,
    required this.commit,
    required this.client,
  });

  final String noteId;
  final Map<String, dynamic> commit;
  final ApiClient client;

  @override
  State<_SnapshotScreen> createState() => _SnapshotScreenState();
}

class _SnapshotScreenState extends State<_SnapshotScreen> {
  bool _loading = true;
  String? _error;
  List<Stroke> _strokes = [];
  List<ShapeObject> _shapes = [];
  bool _restoring = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await widget.client.historySnapshot(
        widget.noteId,
        widget.commit['id'] as String,
      );
      final objects = (data['objects'] as List?) ?? const [];
      final strokes = <Stroke>[];
      final shapes = <ShapeObject>[];
      for (final obj in objects) {
        final o = obj as Map<String, dynamic>;
        final kind = o['kind'] as String? ?? '';
        final rawData = o['data'];
        final objData = rawData is Map<String, dynamic>
            ? rawData
            : <String, dynamic>{};
        try {
          if (kind == 'stroke') {
            strokes.add(Stroke.fromJson({...objData, 'id': o['id'], 'pageId': o['pageId'], 'layerId': o['layerId']}));
          } else if (kind == 'shape') {
            shapes.add(ShapeObject.fromJson({...objData, 'id': o['id'], 'pageId': o['pageId'], 'layerId': o['layerId']}));
          }
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        _strokes = strokes;
        _shapes = shapes;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _restore() async {
    final t = NoteeProvider.of(context).tokens;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: t.toolbar,
        title: Text('복원?', style: TextStyle(color: t.ink, fontSize: 16)),
        content: Text(
          '"${widget.commit['message']}" 버전으로 복원합니다.\n현재 변경사항은 대체됩니다.',
          style: TextStyle(color: t.inkDim, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('취소', style: TextStyle(color: t.inkDim)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('복원', style: TextStyle(color: t.accent)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _restoring = true);
    try {
      await widget.client.historyRestore(
          widget.noteId, widget.commit['id'] as String);
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _restoring = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('복원 실패: $e'),
          backgroundColor: Colors.red.shade700,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    final message = widget.commit['message'] as String? ?? '';
    final createdAtRaw = widget.commit['createdAt'] as String? ?? '';
    final createdAt = DateTime.tryParse(createdAtRaw)?.toLocal();
    final timeStr = createdAt != null
        ? '${createdAt.year}/${createdAt.month.toString().padLeft(2, '0')}/${createdAt.day.toString().padLeft(2, '0')} '
          '${createdAt.hour.toString().padLeft(2, '0')}:${createdAt.minute.toString().padLeft(2, '0')}'
        : createdAtRaw;

    return Scaffold(
      backgroundColor: t.bg,
      appBar: AppBar(
        backgroundColor: t.toolbar,
        elevation: 0,
        leading: IconButton(
          icon: NoteeIconWidget(NoteeIcon.chev, size: 18, color: t.ink),
          onPressed: () => Navigator.pop(context),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message,
                style: TextStyle(
                    color: t.ink, fontSize: 15, fontWeight: FontWeight.w600),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
            Text(timeStr,
                style: TextStyle(color: t.inkFaint, fontSize: 11)),
          ],
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(height: 1, thickness: 1, color: t.tbBorder),
        ),
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: t.accent))
          : _error != null
              ? Center(
                  child: Text(_error!,
                      style: TextStyle(color: t.inkDim, fontSize: 14)))
              : _SnapshotCanvas(strokes: _strokes, shapes: _shapes, t: t),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: t.accent,
              minimumSize: const Size.fromHeight(44),
            ),
            onPressed: (_loading || _restoring) ? null : _restore,
            child: _restoring
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Text('이 버전으로 복원'),
          ),
        ),
      ),
    );
  }
}

class _SnapshotCanvas extends StatelessWidget {
  const _SnapshotCanvas({
    required this.strokes,
    required this.shapes,
    required this.t,
  });

  final List<Stroke> strokes;
  final List<ShapeObject> shapes;
  final NoteeTokens t;

  @override
  Widget build(BuildContext context) {
    if (strokes.isEmpty && shapes.isEmpty) {
      return Center(
        child: Text('이 버전에는 내용이 없습니다.',
            style: TextStyle(color: t.inkFaint, fontSize: 14)),
      );
    }

    // Compute bounding box of all objects.
    double minX = double.infinity,
        minY = double.infinity,
        maxX = double.negativeInfinity,
        maxY = double.negativeInfinity;
    for (final s in strokes) {
      minX = math.min(minX, s.bbox.minX);
      minY = math.min(minY, s.bbox.minY);
      maxX = math.max(maxX, s.bbox.maxX);
      maxY = math.max(maxY, s.bbox.maxY);
    }
    for (final s in shapes) {
      minX = math.min(minX, s.bbox.minX);
      minY = math.min(minY, s.bbox.minY);
      maxX = math.max(maxX, s.bbox.maxX);
      maxY = math.max(maxY, s.bbox.maxY);
    }
    final padding = 32.0;
    final contentW = (maxX - minX).clamp(1.0, double.infinity) + padding * 2;
    final contentH = (maxY - minY).clamp(1.0, double.infinity) + padding * 2;

    return Container(
      color: t.page,
      child: LayoutBuilder(builder: (ctx, constraints) {
        final scaleX = constraints.maxWidth / contentW;
        final scaleY = constraints.maxHeight / contentH;
        final scale = math.min(scaleX, scaleY).clamp(0.05, 4.0);
        return Center(
          child: SizedBox(
            width: contentW * scale,
            height: contentH * scale,
            child: CustomPaint(
              painter: _SnapshotPainter(
                strokes: strokes,
                shapes: shapes,
                offsetX: -minX + padding,
                offsetY: -minY + padding,
                scale: scale,
              ),
            ),
          ),
        );
      }),
    );
  }
}

class _SnapshotPainter extends CustomPainter {
  _SnapshotPainter({
    required this.strokes,
    required this.shapes,
    required this.offsetX,
    required this.offsetY,
    required this.scale,
  });

  final List<Stroke> strokes;
  final List<ShapeObject> shapes;
  final double offsetX;
  final double offsetY;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(scale, scale);
    canvas.translate(offsetX, offsetY);
    // Delegate to the existing painter (layerOpacity=1, tape strokes skipped).
    CombinedLayerPainter(
      strokes: strokes,
      shapes: shapes,
      layerOpacity: 1.0,
    ).paint(canvas, size);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SnapshotPainter old) =>
      old.strokes != strokes ||
      old.shapes != shapes ||
      old.scale != scale;
}
