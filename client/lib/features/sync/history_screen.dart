// HistoryScreen — browse note commit history and restore to a past state.
//
// Each commit shows: message, device ID, creation time, and the rev range.
// Tapping a commit shows a confirmation sheet before restoring.

import 'package:flutter/material.dart';

import '../../data/api/api_client.dart';
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
        onRestore: () => _restore(commits[i]),
      ),
    );
  }
}

class _CommitTile extends StatelessWidget {
  const _CommitTile({
    required this.commit,
    required this.tokens,
    required this.isLatest,
    required this.onRestore,
  });

  final Map<String, dynamic> commit;
  final NoteeTokens tokens;
  final bool isLatest;
  final VoidCallback onRestore;

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
      onTap: onRestore,
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

  String _shortDevice(String id) {
    if (id.length <= 8) return id;
    return id.substring(0, 8);
  }
}
