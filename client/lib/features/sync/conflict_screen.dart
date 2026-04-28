// ConflictScreen — review and resolve sync conflicts for a note.
//
// Each conflict item shows the local (client) version vs the server version
// side by side. The user picks: keep local, keep server, or delete the object.
// After all items are resolved the session is submitted and a new commit is created.

import 'dart:convert';

import 'package:flutter/material.dart';

import '../../data/api/api_client.dart';
import '../../theme/notee_icons.dart';
import '../../theme/notee_theme.dart';

class ConflictScreen extends StatefulWidget {
  const ConflictScreen({
    super.key,
    required this.noteId,
    required this.sessionId,
    required this.client,
  });

  final String noteId;
  final String sessionId;
  final ApiClient client;

  @override
  State<ConflictScreen> createState() => _ConflictScreenState();
}

class _ConflictScreenState extends State<ConflictScreen> {
  Map<String, dynamic>? _session;
  final Map<String, String> _resolutions = {}; // itemId → local|server|deleted
  bool _loading = true;
  bool _submitting = false;
  String? _error;

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
      final data = await widget.client.conflictGet(
          widget.noteId, widget.sessionId);
      if (!mounted) return;
      setState(() {
        _session = data;
        _loading = false;
        // Pre-fill "server" as the default resolution for all items.
        final items =
            (data['items'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
        for (final item in items) {
          final id = item['id'] as String;
          final existing = item['resolution'] as String?;
          _resolutions[id] = (existing != null && existing.isNotEmpty)
              ? existing
              : 'server';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final t = NoteeProvider.of(context).tokens;
    final items = (_session?['items'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();

    // Ensure all items have a resolution.
    final unresolved =
        items.where((it) => !_resolutions.containsKey(it['id'])).toList();
    if (unresolved.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              '${unresolved.length} item(s) still need a resolution.'),
          backgroundColor: t.accent,
        ),
      );
      return;
    }

    setState(() => _submitting = true);
    try {
      final resList = _resolutions.entries
          .map((e) => {'itemId': e.key, 'resolution': e.value})
          .toList();
      await widget.client.conflictResolve(
          widget.noteId, widget.sessionId, resList);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Conflicts resolved. Pull to sync.'),
          backgroundColor: t.accent,
        ),
      );
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Submit failed: $e'),
          backgroundColor: Colors.red.shade700,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    final status = _session?['status'] as String?;
    final isResolved = status != null && status != 'pending';
    final items = (_session?['items'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();
    final resolvedCount =
        items.where((it) => _resolutions[it['id'] as String] != null).length;

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
          'Resolve Conflicts',
          style: TextStyle(
            color: t.ink,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        actions: [
          if (!isResolved && items.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: TextButton(
                onPressed: _submitting ? null : _submit,
                child: _submitting
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child:
                            CircularProgressIndicator(color: t.accent, strokeWidth: 2),
                      )
                    : Text(
                        'Done ($resolvedCount/${items.length})',
                        style: TextStyle(
                          color: resolvedCount == items.length
                              ? t.accent
                              : t.inkDim,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
              ),
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(height: 1, thickness: 1, color: t.tbBorder),
        ),
      ),
      body: _buildBody(t, items, isResolved),
    );
  }

  Widget _buildBody(
      NoteeTokens t, List<Map<String, dynamic>> items, bool isResolved) {
    if (_loading) {
      return Center(child: CircularProgressIndicator(color: t.accent));
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
    if (isResolved) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_outline, color: t.accent, size: 40),
            const SizedBox(height: 12),
            Text(
              'Conflicts already resolved.',
              style: TextStyle(color: t.inkDim, fontSize: 14),
            ),
          ],
        ),
      );
    }
    if (items.isEmpty) {
      return Center(
        child: Text(
          'No conflict items.',
          style: TextStyle(color: t.inkFaint, fontSize: 14),
        ),
      );
    }

    return Column(
      children: [
        _buildHeader(t, items),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.only(bottom: 24),
            itemCount: items.length,
            separatorBuilder: (_, __) =>
                Divider(height: 1, thickness: 1, color: t.tbBorder),
            itemBuilder: (ctx, i) {
              final item = items[i];
              final id = item['id'] as String;
              return _ConflictItemTile(
                item: item,
                resolution: _resolutions[id] ?? 'server',
                tokens: t,
                onResolution: (r) => setState(() => _resolutions[id] = r),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildHeader(NoteeTokens t, List<Map<String, dynamic>> items) {
    final baseRev = _session?['baseRev'] as int? ?? 0;
    return Container(
      color: t.toolbar,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(
        children: [
          Icon(Icons.merge_type, size: 16, color: t.inkDim),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${items.length} conflict(s) · base rev $baseRev',
              style: TextStyle(color: t.inkDim, fontSize: 13),
            ),
          ),
          GestureDetector(
            onTap: () => setState(() {
              for (final it in items) {
                _resolutions[it['id'] as String] = 'local';
              }
            }),
            child: Text('All local',
                style: TextStyle(color: t.accent, fontSize: 12)),
          ),
          const SizedBox(width: 16),
          GestureDetector(
            onTap: () => setState(() {
              for (final it in items) {
                _resolutions[it['id'] as String] = 'server';
              }
            }),
            child: Text('All server',
                style: TextStyle(color: t.accent, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

class _ConflictItemTile extends StatelessWidget {
  const _ConflictItemTile({
    required this.item,
    required this.resolution,
    required this.tokens,
    required this.onResolution,
  });

  final Map<String, dynamic> item;
  final String resolution;
  final NoteeTokens tokens;
  final ValueChanged<String> onResolution;

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    final objectId = item['objectId'] as String? ?? '';
    final localData = item['localData'];
    final serverData = item['serverData'];

    final localKind = _kindFrom(localData);
    final serverKind = _kindFrom(serverData);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Object ID header.
          Text(
            _shortId(objectId),
            style: TextStyle(
              color: t.inkFaint,
              fontSize: 11,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(height: 8),
          // Side-by-side versions.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _VersionCard(
                  label: 'Local',
                  kind: localKind,
                  data: localData,
                  isSelected: resolution == 'local',
                  tokens: t,
                  onTap: () => onResolution('local'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _VersionCard(
                  label: 'Server',
                  kind: serverKind,
                  data: serverData,
                  isSelected: resolution == 'server',
                  tokens: t,
                  onTap: () => onResolution('server'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Delete option.
          GestureDetector(
            onTap: () => onResolution('deleted'),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: resolution == 'deleted'
                    ? Colors.red.withValues(alpha: 0.08)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: resolution == 'deleted'
                      ? Colors.red.shade400
                      : t.tbBorder,
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  NoteeIconWidget(NoteeIcon.trash, size: 13,
                      color: resolution == 'deleted'
                          ? Colors.red.shade400
                          : t.inkFaint),
                  const SizedBox(width: 6),
                  Text(
                    'Delete',
                    style: TextStyle(
                      color: resolution == 'deleted'
                          ? Colors.red.shade400
                          : t.inkFaint,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _kindFrom(dynamic data) {
    if (data is Map<String, dynamic>) {
      return data['kind'] as String? ?? '?';
    }
    return '?';
  }

  String _shortId(String id) {
    if (id.length <= 8) return id;
    return '${id.substring(0, 4)}…${id.substring(id.length - 4)}';
  }
}

class _VersionCard extends StatelessWidget {
  const _VersionCard({
    required this.label,
    required this.kind,
    required this.data,
    required this.isSelected,
    required this.tokens,
    required this.onTap,
  });

  final String label;
  final String kind;
  final dynamic data;
  final bool isSelected;
  final NoteeTokens tokens;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: isSelected ? t.accentSoft : t.toolbar,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? t.accent : t.tbBorder,
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: isSelected ? t.accent : t.inkDim,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                if (isSelected)
                  NoteeIconWidget(NoteeIcon.check, size: 12, color: t.accent),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              kind,
              style: TextStyle(
                color: t.ink,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _summarize(data),
              style: TextStyle(color: t.inkFaint, fontSize: 11),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  String _summarize(dynamic data) {
    if (data == null) return '(empty)';
    if (data is Map<String, dynamic>) {
      // Show a compact JSON preview of a few keys.
      final preview = Map<String, dynamic>.fromEntries(
        data.entries.take(3),
      );
      return const JsonEncoder().convert(preview).replaceAll('"', '');
    }
    return data.toString();
  }
}
