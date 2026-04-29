// LibraryScreen — folder + notebook browse, styled to the design handoff.
// Layout (desktop / iPad):
//   ┌─────────────── top bar (Notee logo · search · grid/rows · New) ───────────────┐
//   │ side rail (Library · All notebooks · Favorites · Recent · folder tree)        │
//   │  ────────────────────────────────────────────────────────────                  │
//   │  breadcrumb · "Folder name" · n folders · m notebooks                          │
//   │  grid: folder cards (back-tab + body + paper peek) + notebook covers          │
//   └────────────────────────────────────────────────────────────────────────────────┘
//
// Compact widths (< 720px) collapse the sidebar into an icon strip.
//
// This file is split into parts (top bar, sidebar, dialogs, sync widgets,
// main area, cover) to keep the per-file size manageable. All parts share
// the imports declared here and may freely reference one another's
// `_`-prefixed types.

import 'dart:async';
import 'dart:convert' show jsonEncode;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/services.dart' show HardwareKeyboard;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/db/repository.dart';
import '../../domain/folder.dart';
import '../../domain/page_object.dart';
import '../../domain/page_spec.dart';
import '../../features/canvas/painters/background_painter.dart';
import '../../features/canvas/widgets/background_image_layer.dart';
import '../../features/export/export_dialog.dart';
import '../../features/import/goodnotes_importer.dart';
import '../../features/import/pdf_render_cache.dart';
import '../../features/import/notee_importer.dart';
import '../../features/import/pdf_importer.dart';
import '../../theme/notee_dialog.dart';
import '../../theme/notee_icons.dart';
import '../../theme/notee_popover.dart';
import '../../theme/notee_theme.dart';
import '../../main.dart' show surfaceProvider;
import 'thumbnail_service.dart';
import '../auth/auth_state.dart';
import '../auth/login_dialog.dart';
import '../lock/note_lock_service.dart';
import '../notebook/notebook_state.dart';
import '../sync/history_screen.dart';
import '../sync/sync_actions.dart';
import '../sync/sync_state.dart';
import 'library_state.dart';

part 'library_top_bar.part.dart';
part 'library_sidebar.part.dart';
part 'library_dialogs.part.dart';
part 'library_sync_widgets.part.dart';
part 'library_main_area.part.dart';
part 'library_cover.part.dart';

enum _LibAction { newNotebook, newFolder, importPdf, importGoodNotes, importNotee }

enum _SortOrder { updatedAt, createdAt, name }

enum _LibFilter { all, favorites, recent }

extension _SortOrderLabel on _SortOrder {
  String get label {
    switch (this) {
      case _SortOrder.updatedAt: return '수정일';
      case _SortOrder.createdAt: return '생성일';
      case _SortOrder.name:      return '이름';
    }
  }
}

const _folderIconMap = <String, IconData>{
  // ── 기본
  'folder':   Icons.folder_rounded,
  'star':     Icons.star_rounded,
  'bookmark': Icons.bookmark_rounded,

  // ── 학생 — 과목
  'book':       Icons.menu_book_rounded,        // 국어·문학
  'translate':  Icons.translate_rounded,         // 외국어·영어
  'calculate':  Icons.calculate_rounded,         // 수학
  'functions':  Icons.functions_rounded,         // 함수·통계
  'science':    Icons.science_rounded,           // 과학·물리
  'biotech':    Icons.biotech_rounded,           // 화학·생명
  'eco':        Icons.eco_rounded,               // 생물·환경
  'public':     Icons.public_rounded,            // 지리·세계
  'history':    Icons.history_edu_rounded,       // 역사
  'groups':     Icons.groups_rounded,            // 사회·윤리
  'palette':    Icons.palette_rounded,           // 미술
  'music':      Icons.music_note_rounded,        // 음악
  'sport':      Icons.sports_soccer_rounded,     // 체육
  'code':       Icons.code_rounded,              // 컴퓨터·코딩
  'psychology': Icons.psychology_rounded,        // 심리·도덕

  // ── 학생 — 학업
  'school':     Icons.school_rounded,            // 학교
  'assignment': Icons.assignment_rounded,        // 과제·숙제
  'quiz':       Icons.quiz_rounded,              // 시험·퀴즈
  'lightbulb':  Icons.lightbulb_rounded,         // 아이디어·창의
  'article':    Icons.article_rounded,           // 리포트·논문

  // ── 직장인
  'work':       Icons.work_rounded,              // 업무
  'business':   Icons.business_center_rounded,   // 비즈니스
  'meeting':    Icons.people_rounded,            // 회의
  'chart':      Icons.bar_chart_rounded,         // 데이터·분석
  'payments':   Icons.payments_rounded,          // 재정·예산
  'campaign':   Icons.campaign_rounded,          // 마케팅·홍보
  'gavel':      Icons.gavel_rounded,             // 법률
  'event':      Icons.event_note_rounded,        // 일정·캘린더
  'mail':       Icons.mail_rounded,              // 이메일
  'architecture': Icons.architecture_rounded,   // 설계·디자인
  'sell':       Icons.sell_rounded,              // 영업·판매

  // ── 일상 / 생활
  'home':       Icons.home_rounded,              // 집·가정
  'restaurant': Icons.restaurant_rounded,        // 요리·레시피
  'shopping':   Icons.shopping_cart_rounded,     // 쇼핑
  'health':     Icons.monitor_heart_rounded,     // 건강·의료
  'fitness':    Icons.fitness_center_rounded,    // 운동·헬스
  'travel':     Icons.flight_rounded,            // 여행
  'explore':    Icons.explore_rounded,           // 탐험·모험
  'pets':       Icons.pets_rounded,              // 반려동물
  'savings':    Icons.savings_rounded,           // 저축·가계부
  'movie':      Icons.movie_rounded,             // 영화·미디어
  'child':      Icons.child_care_rounded,        // 육아·아이
  'meditation': Icons.self_improvement_rounded,  // 명상·취미
  'car':        Icons.directions_car_rounded,    // 자동차
};

IconData _folderIconFor(String iconKey) =>
    _folderIconMap[iconKey] ?? Icons.folder_rounded;

// DFS walk returning each folder with its nesting depth.
// Collects [folderId] itself and all descendant folder IDs recursively.
Set<String> _allDescendantFolderIds(List<Folder> folders, String folderId) {
  final result = <String>{folderId};
  for (final f in folders.where((f) => f.parentId == folderId)) {
    result.addAll(_allDescendantFolderIds(folders, f.id));
  }
  return result;
}

String _relTime(DateTime t) {
  final d = DateTime.now().toUtc().difference(t.toUtc());
  if (d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  if (d.inDays < 7) return '${d.inDays}d ago';
  return '${(d.inDays / 7).round()}w ago';
}

class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final libAsync = ref.watch(libraryProvider);
    final t = NoteeProvider.of(context).tokens;
    return libAsync.when(
      loading: () => Scaffold(
        backgroundColor: t.bg,
        body: const Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Scaffold(
        backgroundColor: t.bg,
        body: Center(child: Text('Library error: $e')),
      ),
      data: (state) => _LibraryView(state: state),
    );
  }
}

class _LibraryView extends ConsumerStatefulWidget {
  const _LibraryView({required this.state});
  final LibraryState state;

  @override
  ConsumerState<_LibraryView> createState() => _LibraryViewState();
}

class _LibraryViewState extends ConsumerState<_LibraryView> {
  String _searchQuery = '';
  bool _isGridView = true;
  _SortOrder _sortOrder = _SortOrder.updatedAt;
  _LibFilter _filter = _LibFilter.all;
  Timer? _syncPollingTimer;

  static const _kGridView  = 'library.isGridView';
  static const _kSortOrder = 'library.sortOrder';

  Future<void> _loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _isGridView  = p.getBool(_kGridView) ?? true;
      _sortOrder   = _SortOrder.values.firstWhere(
        (s) => s.name == p.getString(_kSortOrder),
        orElse: () => _SortOrder.updatedAt,
      );
    });
  }

  Future<void> _saveGridView(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kGridView, v);
  }

  Future<void> _saveSortOrder(_SortOrder s) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kSortOrder, s.name);
  }

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scheduleMissingThumbnails());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(syncActionsProvider).resumeAssetDownloads();
      final auth = ref.read(authProvider).value;
      if (auth != null && auth.isLoggedIn) {
        ref.read(cloudSyncProvider.notifier).syncAll();
      }
    });
    _syncPollingTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      final auth = ref.read(authProvider).value;
      if (auth == null || !auth.isLoggedIn) return;
      final cloud = ref.read(cloudSyncProvider);
      if (cloud.status == CloudSyncStatus.syncing ||
          cloud.status == CloudSyncStatus.checking) return;
      ref.read(cloudSyncProvider.notifier).syncAll();
    });
  }

  @override
  void dispose() {
    _syncPollingTimer?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(_LibraryView old) {
    super.didUpdateWidget(old);
    if (old.state.notes != widget.state.notes) {
      _scheduleMissingThumbnails();
    }
  }

  void _scheduleMissingThumbnails() {
    for (final note in widget.state.notes) {
      if (ThumbnailService.instance.hasCachedInMemory(note.id)) continue;
      final spec = note.firstPageSpec;
      if (spec == null) continue;
      ThumbnailService.instance.schedule(
        noteId: note.id,
        spec: spec,
        strokes: note.firstPageStrokes,
        shapes: note.firstPageShapes,
        texts: note.firstPageTexts,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    final ctl = ref.read(libraryProvider.notifier);
    final wide = MediaQuery.sizeOf(context).width >= 720;

    Widget buildSidebar({required bool inDrawer}) => _Sidebar(
      state: widget.state,
      filter: _filter,
      onFilterChanged: (f) {
        setState(() => _filter = f);
        if (f == _LibFilter.all) {
          ref.read(libraryProvider.notifier).navigateRoot();
        }
        if (inDrawer) Navigator.of(context).pop();
      },
    );

    final hasStatusBar = MediaQuery.viewPaddingOf(context).top > 0;
    return Scaffold(
      backgroundColor: t.bg,
      drawer: wide
          ? null
          : Drawer(
              width: 260,
              backgroundColor: t.toolbar,
              child: SafeArea(child: buildSidebar(inDrawer: true)),
            ),
      body: SafeArea(
        bottom: false,
        top: hasStatusBar,
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TopBar(
            showMenuButton: !wide,
            isGridView: _isGridView,
            sortOrder: _sortOrder,
            onSearch: (v) => setState(() => _searchQuery = v),
            onToggleView: () {
              setState(() => _isGridView = !_isGridView);
              _saveGridView(_isGridView);
            },
            onSortChanged: (s) {
              setState(() => _sortOrder = s);
              _saveSortOrder(s);
            },
          ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (wide)
                  SizedBox(
                    width: 220,
                    child: buildSidebar(inDrawer: false),
                  ),
                if (wide)
                  Container(width: 0.5, color: t.tbBorder),
                Expanded(
                  child: _MainArea(
                    state: widget.state,
                    searchQuery: _searchQuery,
                    isGridView: _isGridView,
                    sortOrder: _sortOrder,
                    filter: _filter,
                    onCreateFolder: () async {
                      final name = await noteeAskName(context, title: 'New folder');
                      if (name != null && name.isNotEmpty) {
                        await ctl.createFolder(name);
                      }
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
        ),
      ),
    );
  }
}
