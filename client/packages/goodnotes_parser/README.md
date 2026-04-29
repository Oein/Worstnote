# goodnotes_parser

순수 Dart로 작성한 **GoodNotes 5/6 (`.goodnotes`)** 패키지 파서.
Flutter, 서버, CLI 어디서나 쓸 수 있도록 Flutter SDK에 의존하지 않습니다.

## 지원 범위

- `.goodnotes` 파일 (zip 압축) **자동 해제** — 파일 경로 또는 바이트 모두 지원
- 이미 압축이 풀린 디렉터리도 직접 열기 가능
- `schema.pb`, `index.notes.pb`, `index.attachments.pb`, `index.search.pb`,
  `index.events.pb` 모두 디코드
- 페이지 = CRDT 변경 로그 (HEAD + BODY 페어) 디코드
- `bv41` LZ4-block 컨테이너 디코드 (순수 Dart 구현, 외부 의존 없음)
- `tpl\0` 스트로크 컨테이너 디코드 — 점 좌표·압력·베지어 세그먼트까지
- 텍스트 박스 (UTF-8 본문, 색·폰트크기) 추출
- 첨부 PDF / PNG 원본 그대로 추출
- OCR 인덱스 (한글 등 토큰 + 글리프 bbox)
- 도큐먼트 제목 / 페이지 순서 / 썸네일

## 설치

`pubspec.yaml`:

```yaml
dependencies:
  goodnotes_parser:
    path: ../goodnotes_parser   # 또는 git: 저장소 URL
```

## 사용 예

```dart
import 'package:goodnotes_parser/goodnotes_parser.dart';

Future<void> main() async {
  // 압축된 .goodnotes 파일 열기
  final doc = await GoodNotesDocument.openFile('/path/to/note.goodnotes');

  print('제목: ${doc.title}');
  print('스키마 버전: ${doc.schemaVersion}');
  print('페이지 수: ${doc.pages.length}');

  for (final page in doc.pages) {
    final bg = doc.backgroundOf(page);
    print('페이지 ${page.id}, 배경 = ${bg?.mimeType}');

    for (final el in page.elements) {
      switch (el) {
        case StrokeElement s:
          print('  스트로크 ${s.points.length}개 점, 색=${s.color}, '
                '굵기=${s.width}');
          for (final p in s.points.take(3)) {
            print('    (${p.x}, ${p.y})');
          }
        case TextElement t:
          print('  텍스트 "${t.text}" 크기=${t.fontSize}');
        case UnknownElement _:
          // 분류 불가 요소 (희귀): 원본 protobuf 바이트 보유
          break;
      }
    }
  }

  // 첨부 PDF/PNG 원본 꺼내기
  for (final a in doc.attachments.values) {
    if (a.isPdf) await File('out_${a.id}.pdf').writeAsBytes(a.bytes);
  }

  // OCR 토큰 활용
  for (final s in doc.searchIndices.values) {
    print('OCR ${s.targetId} (첨부?=${s.forAttachment}): '
          '${s.tokens.map((t) => t.text).where((t) => t.isNotEmpty)
              .join(", ")}');
  }
}
```

### 바이트로 직접 열기 (예: 업로드된 파일)

```dart
final bytes = await pickedFile.readAsBytes(); // image_picker / file_picker 등
final doc = GoodNotesDocument.openBytes(bytes);
```

### 이미 풀려 있는 디렉터리

```dart
final doc = await GoodNotesDocument.openDirectory(
  '/Users/me/Downloads/notes/testfile',
);
```

## 데이터 모델

```
GoodNotesDocument
├─ title : String?
├─ schemaVersion : int
├─ thumbnail : Uint8List?            (JPEG)
├─ pages : List<Page>
│   └─ Page
│       ├─ id, schemaVersion
│       ├─ backgroundAttachmentId : String?
│       └─ elements : List<PageElement>
│           ├─ StrokeElement
│           │   ├─ id, opType, lamport
│           │   ├─ bbox, color, width
│           │   └─ payload : TplPayload
│           │       ├─ pressures : List<int>     (uint16)
│           │       ├─ anchors   : List<TplPoint>
│           │       └─ segments  : List<TplSegment>
│           ├─ TextElement (text, color, fontSize, letterSpacing, bbox)
│           └─ UnknownElement (rawBody)
├─ attachments : Map<String, Attachment>
│       Attachment(id, diskUuid, bytes, isPdf, isPng)
└─ searchIndices : Map<String, SearchIndex>
        SearchIndex(targetId, forAttachment, tokens)
```

## 좌표계 / 단위

- 모든 좌표·BBox·폰트 크기는 **page point** (1 pt = 1/72 in).
- 색상 RGBA 0..1 float. `Color4.toArgb()` 로 Flutter `Color(...)` 호환 정수 변환.

## 한계 / 알려진 사항

- 굿노트 고유 펜 텍스처(만년필 효과 등)의 시각 효과는 모델에 담지 않습니다 —
  변환 시 가장 가까운 일반 펜으로 매핑하세요.
- 펜 세그먼트의 11개 float 중 9~10번째는 미분/속도 보정으로 추정됩니다.
  드로잉 재현에는 `(x, y, pressure)`만 사용해도 시각적으로 동일합니다.
- Schema 24/25/31 모두 지원 (testfile 12블록 / 본문 페이지 156블록 검증).

## 라이선스

MIT — 자유롭게 사용/수정 가능. (LICENSE 파일 추가 필요)
