// Copyright (c) 2026 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsumiru/src/features/offline/data/chapter_manifest.dart';
import 'package:tsumiru/src/features/offline/data/offline_database.dart';
import 'package:tsumiru/src/features/offline/data/offline_page_store_io.dart';
import 'package:tsumiru/src/features/offline/data/offline_paths.dart';
import 'package:tsumiru/src/features/offline/data/offline_repository.dart';
import 'package:tsumiru/src/features/offline/data/offline_types.dart';

import '../../../../helpers/offline_test_db.dart';

const _mangaId = 7;
const _chapterId = 700;

void main() {
  late Directory tmp;
  late IoOfflinePageStore store;
  late OfflinePaths paths;
  late OfflineDatabase db;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('page_row_repair');
    paths = OfflinePaths(tmp.path);
    store = IoOfflinePageStore(paths);
    db = testOfflineDatabase();
    await db.upsertChapterMetadata(
      id: _chapterId,
      mangaId: _mangaId,
      name: 'Chapter 1',
      chapterIndex: 1,
      isRead: false,
      lastPageRead: 0,
      isBookmarked: false,
      serverIsDownloaded: true,
      pageCount: 2,
      updatedAt: DateTime(2026),
    );
  });

  tearDown(() async {
    await db.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  /// Puts a real committed chapter on disk (staging + manifest + commit).
  Future<void> commitTwoPagesToDisk() async {
    await store.beginChapter(
      _mangaId,
      _chapterId,
      const ChapterManifest(generation: 0, indices: [0, 1]),
    );
    await store.writePage(_mangaId, _chapterId, 0, [1, 2, 3], 'jpg');
    await store.writePage(_mangaId, _chapterId, 1, [4, 5, 6], 'jpg');
    await store.commitStaging(_mangaId, _chapterId);
  }

  test('a chapter with files on disk but no page rows heals without '
      're-downloading', () async {
    await commitTwoPagesToDisk();
    // The broken state: catalog says downloaded, page rows are gone.
    await db.setChapterDeviceState(
      _chapterId,
      OfflineDeviceState.downloaded,
    );
    final repo = OfflineRepository(db: db, paths: paths);
    expect(await repo.localChapterPages(_chapterId), isNull,
        reason: 'precondition: reader would fall through to the server');

    final healed = await repairDownloadedChapterPages(
      db: db,
      store: store,
      paths: paths,
      chapterId: _chapterId,
    );

    expect(healed, isNotNull);
    expect(healed!.length, 2);
    for (final path in healed) {
      expect(File(path).existsSync(), isTrue);
    }
    // The reader now resolves it locally, so no server round trip.
    final after = await repo.localChapterPages(_chapterId);
    expect(after, isNotNull);
    expect(after!.length, 2);
    final row = await db.chapterById(_chapterId);
    expect(row!.deviceState, OfflineDeviceState.downloaded);
  });

  test('a chapter claiming downloaded with nothing on disk is re-queued',
      () async {
    await db.setChapterDeviceState(
      _chapterId,
      OfflineDeviceState.downloaded,
    );

    final healed = await repairDownloadedChapterPages(
      db: db,
      store: store,
      paths: paths,
      chapterId: _chapterId,
    );

    expect(healed, isNull);
    final row = await db.chapterById(_chapterId);
    expect(row!.deviceState, OfflineDeviceState.queued,
        reason: 'must not keep claiming to be on-device');
  });

  test('a chapter can never be marked downloaded with no pages', () async {
    await db.commitDownloadedChapter(
      chapterId: _chapterId,
      pages: const [],
      downloadedAt: DateTime(2026),
    );

    final row = await db.chapterById(_chapterId);
    expect(row!.deviceState, isNot(OfflineDeviceState.downloaded),
        reason: 'the state that makes the reader stream from the server');
  });

  test('repair leaves a healthy chapter alone', () async {
    await commitTwoPagesToDisk();
    await db.commitDownloadedChapter(
      chapterId: _chapterId,
      pages: await store.committedPages(_mangaId, _chapterId),
      downloadedAt: DateTime(2026),
    );
    final before = await OfflineRepository(db: db, paths: paths)
        .localChapterPages(_chapterId);
    expect(before, isNotNull);

    // Nothing to repair — the rows are already there.
    final healed = await repairDownloadedChapterPages(
      db: db,
      store: store,
      paths: paths,
      chapterId: _chapterId,
    );
    expect(healed, isNotNull);
    expect(healed!.length, before!.length);
  });
}
