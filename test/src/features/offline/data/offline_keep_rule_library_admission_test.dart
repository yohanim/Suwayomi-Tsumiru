// Copyright (c) 2026 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumiru/src/features/offline/data/offline_database.dart';

import '../../../../helpers/offline_test_db.dart';

// Specification of how a keep rule and `inLibraryAt` interact so that a kept
// series always reaches the background catch-up work spec.
//
// Background: the catch-up work spec (what the WorkManager isolate downloads
// from — it never opens drift) is built from libraryManga(), which hides any
// row whose inLibraryAt sentinel is '0' ("removed"). A keep rule — NOT
// inLibraryAt — is what actually decides a background download. When the two
// disagree (a '0' row that still carries a keep rule) the series is notified as
// a new chapter but never downloaded in the background; it only downloads on a
// foreground reconcile, which reads the row directly (mangaById, no library
// filter). This was the "notified but not downloaded" bug for manga 340.
//
// Two mechanisms keep them in agreement, each specified below:
//  1. setKeepRule clears a '0' sentinel when a real rule is applied, so new
//     occurrences never arise.
//  2. keepRuleManga() exposes every kept row regardless of inLibraryAt, so the
//     spec writer can union it in and heal any '0'+keep-rule row that already
//     exists (legacy data, or a '0' stamped by some other path).
void main() {
  late OfflineDatabase db;
  setUp(() => db = testOfflineDatabase());
  tearDown(() => db.close());

  Future<void> seed(int id, {String? inLibraryAt = '100'}) =>
      db.upsertMangaMetadata(
        id: id,
        title: 'M$id',
        updatedAt: DateTime(2026),
        inLibraryAt: inLibraryAt,
      );

  // Set the rule directly, bypassing setKeepRule's sentinel-clear, to model a
  // '0'+keep-rule row that already exists on disk (legacy data / another path).
  Future<void> forceKeepRule(int id, OfflineKeepRule rule, int count) =>
      (db.update(db.offlineMangas)..where((t) => t.id.equals(id))).write(
        OfflineMangasCompanion(
          keepRule: Value(rule),
          keepUnreadCount: Value(count),
        ),
      );

  Future<String?> inLibraryAtOf(int id) async =>
      (await db.mangaById(id))!.inLibraryAt;

  group('setKeepRule and the inLibraryAt sentinel', () {
    test('applying a real rule to a "removed" ("0") row clears the sentinel to '
        'NULL, re-admitting it to the library', () async {
      await seed(1, inLibraryAt: '0');
      await db.setKeepRule(1, OfflineKeepRule.nUnread, 5);

      expect(await inLibraryAtOf(1), isNull);
      expect((await db.libraryManga()).map((m) => m.id), contains(1));
    });

    test('turning a rule OFF never un-stamps a removed row — off is exactly the '
        'condition a prune stamps, so it must stay removed', () async {
      await seed(1, inLibraryAt: '0');
      await db.setKeepRule(1, OfflineKeepRule.off, 0);

      expect(await inLibraryAtOf(1), '0');
      expect((await db.libraryManga()).map((m) => m.id), isNot(contains(1)));
    });

    test('applying a rule to a row with a real add-date leaves the timestamp '
        'intact — it must not clobber the "Date added" sort key', () async {
      await seed(1, inLibraryAt: '1751234567000');
      await db.setKeepRule(1, OfflineKeepRule.nUnread, 5);

      expect(await inLibraryAtOf(1), '1751234567000');
    });

    test('applying a rule to a NULL row leaves it NULL — NULL already counts as '
        'in-library, nothing to heal', () async {
      await seed(1, inLibraryAt: null);
      await db.setKeepRule(1, OfflineKeepRule.nUnread, 5);

      expect(await inLibraryAtOf(1), isNull);
      expect((await db.libraryManga()).map((m) => m.id), contains(1));
    });

    test('the rule and count are still written alongside the sentinel clear',
        () async {
      await seed(1, inLibraryAt: '0');
      await db.setKeepRule(1, OfflineKeepRule.nUnread, 7);

      final m = (await db.mangaById(1))!;
      expect(m.keepRule, OfflineKeepRule.nUnread);
      expect(m.keepUnreadCount, 7);
    });
  });

  group('keepRuleManga (the reconciler-view union source for the spec)', () {
    test('returns every kept series regardless of inLibraryAt, and excludes '
        'rows with no rule', () async {
      await seed(1, inLibraryAt: '100'); // in library, no rule
      await seed(2, inLibraryAt: '0'); // "removed", but kept below
      await seed(3, inLibraryAt: null); // legacy-null, kept below
      await seed(4, inLibraryAt: '200'); // in library, kept below
      for (final id in [2, 3, 4]) {
        await forceKeepRule(id, OfflineKeepRule.nUnread, 5);
      }

      final kept = (await db.keepRuleManga()).map((m) => m.id).toSet();
      expect(kept, {2, 3, 4});
      expect(kept, isNot(contains(1)), reason: 'manga 1 has no keep rule');
    });

    test('a "0"-stamped kept row is invisible to libraryManga() but the '
        'library ∪ keepRule union (what the spec writer iterates) includes it',
        () async {
      await seed(1, inLibraryAt: '100'); // ordinary library manga
      await seed(2, inLibraryAt: '0'); // stranded kept row
      await forceKeepRule(2, OfflineKeepRule.nUnread, 5);

      final library = (await db.libraryManga()).map((m) => m.id).toSet();
      expect(library, isNot(contains(2)), reason: 'the "0" sentinel hides it');

      // The exact set writeCatchupWorkSpec now builds its per-manga specs from.
      final union = {
        for (final m in await db.libraryManga()) m.id,
        for (final m in await db.keepRuleManga()) m.id,
      };
      expect(union, {1, 2});
    });
  });
}
