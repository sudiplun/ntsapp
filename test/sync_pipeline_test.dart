import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A row on the server side of the pull: the payload id plus the timestamp
/// the server stamped on it (`server_at`).
class ServerRow {
  final String id;
  final DateTime serverAt;
  const ServerRow(this.id, this.serverAt);
}

/// What a pull returns: the rows that arrived and the cursor to store.
class PullResult {
  final List<ServerRow> received;
  final DateTime cursor;
  const PullResult(this.received, this.cursor);
}

/// The pull, replicated from `SyncUtils.fetchMapChanges()`.
///
/// The server answers with every row whose `server_at` is newer than the
/// cursor the client sent (`lastAt`). The client then stores a new cursor.
///
/// [keepCapturedCursor] selects the two cursor rules:
///
///   - `true`  the cursor is the timestamp captured *before* the request was
///             sent (what the code does now).
///   - `false` the cursor is the local time *after* the batch was processed
///             (what the code used to do - it silently loses rows).
PullResult pull({
  required List<ServerRow> serverRows,
  required DateTime lastFetchedAt,
  required DateTime cursorCapturedAt,
  required DateTime requestEvaluatedAt,
  required DateTime batchFinishedAt,
  required bool keepCapturedCursor,
}) {
  // What the server had when it ran the query.
  final List<ServerRow> available = serverRows
      .where((ServerRow row) => !row.serverAt.isAfter(requestEvaluatedAt))
      .toList();
  // ... filtered by the cursor the client sent.
  final List<ServerRow> received = available
      .where((ServerRow row) => row.serverAt.isAfter(lastFetchedAt))
      .toList();
  final DateTime newCursor =
      keepCapturedCursor ? cursorCapturedAt : batchFinishedAt;
  return PullResult(received, newCursor);
}

/// Locates the package root by walking up from the current directory.
String packageRoot() {
  Directory dir = Directory.current;
  while (!File(p_join(dir.path, 'pubspec.yaml')).existsSync()) {
    final Directory parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError(
          'pubspec.yaml not found above ${Directory.current.path}');
    }
    dir = parent;
  }
  return dir.path;
}

String p_join(String a, String b) {
  if (a.endsWith('/')) return '$a$b';
  return '$a/$b';
}

/// The source of `SyncUtils.triggerSync()`.
String triggerSyncSource() {
  final String source = File(p_join(packageRoot(), 'lib/utils/utils_sync.dart'))
      .readAsStringSync();
  final int start = source.indexOf('Future<void> triggerSync(');
  expect(start, greaterThan(0), reason: 'triggerSync() not found');
  final int end = source.indexOf('static String? getSignedInUserId()', start);
  expect(end, greaterThan(start), reason: 'triggerSync() end not found');
  return source.substring(start, end);
}

void main() {
  group('pull cursor', () {
    // The timeline of a pull:
    //   10:00:00  the previous cursor
    //   10:00:01  the client captures the cursor and sends the request
    //   10:00:01  the server runs the query (nothing new yet)
    //   10:00:02  the other device pushes a note
    //   10:00:03  the client finishes processing the batch
    final DateTime previousCursor = DateTime.utc(2026, 1, 1, 10, 0, 0);
    final DateTime cursorCapturedAt = DateTime.utc(2026, 1, 1, 10, 0, 1);
    final DateTime requestEvaluatedAt = DateTime.utc(2026, 1, 1, 10, 0, 1);
    final DateTime pushedAt = DateTime.utc(2026, 1, 1, 10, 0, 2);
    final DateTime batchFinishedAt = DateTime.utc(2026, 1, 1, 10, 0, 3);
    final List<ServerRow> serverRows = [ServerRow('note-1', pushedAt)];

    test('a note pushed while the pull runs is picked up by the next pull', () {
      // The first pull misses the note: it was pushed after the query ran.
      final PullResult first = pull(
        serverRows: serverRows,
        lastFetchedAt: previousCursor,
        cursorCapturedAt: cursorCapturedAt,
        requestEvaluatedAt: requestEvaluatedAt,
        batchFinishedAt: batchFinishedAt,
        keepCapturedCursor: true,
      );
      expect(first.received, isEmpty);

      // The next pull still gets it, because the cursor was taken *before*
      // the request instead of after the batch was processed.
      final PullResult second = pull(
        serverRows: serverRows,
        lastFetchedAt: first.cursor,
        cursorCapturedAt: batchFinishedAt,
        requestEvaluatedAt: batchFinishedAt,
        batchFinishedAt: batchFinishedAt,
        keepCapturedCursor: true,
      );
      expect(second.received.map((ServerRow row) => row.id), ['note-1']);
    });

    test('the old cursor rule loses the note forever', () {
      // This is the behaviour the fix replaced - the note never arrives.
      final PullResult first = pull(
        serverRows: serverRows,
        lastFetchedAt: previousCursor,
        cursorCapturedAt: cursorCapturedAt,
        requestEvaluatedAt: requestEvaluatedAt,
        batchFinishedAt: batchFinishedAt,
        keepCapturedCursor: false,
      );
      expect(first.received, isEmpty);

      final PullResult second = pull(
        serverRows: serverRows,
        lastFetchedAt: first.cursor,
        cursorCapturedAt: batchFinishedAt,
        requestEvaluatedAt: batchFinishedAt,
        batchFinishedAt: batchFinishedAt,
        keepCapturedCursor: false,
      );
      expect(second.received, isEmpty,
          reason: 'the cursor jumped past the pushed row');
    });
  });

  group('sync cycle', () {
    test('the pull runs before the media uploads', () {
      final String body = triggerSyncSource();
      final int pull = body.indexOf('fetchMapChanges()');
      final int pushThumbnails = body.indexOf('pushThumbnails(');
      final int pushFiles = body.indexOf('pushFiles(');
      expect(pull, greaterThan(0), reason: 'fetchMapChanges() not called');
      expect(pushThumbnails, greaterThan(0),
          reason: 'pushThumbnails() not called');
      expect(pushFiles, greaterThan(0), reason: 'pushFiles() not called');
      // Notes sent from another device must show up without waiting for the
      // (much slower) media uploads.
      expect(pull, lessThan(pushThumbnails));
      expect(pull, lessThan(pushFiles));
    });

    test('the cycle does not depend on the internet probe', () {
      // The probe opened a TCP socket to 8.8.8.8:53, which many networks
      // block - the sync was then skipped entirely even though the network
      // was fine. The real Supabase call reports connectivity now.
      final String body = triggerSyncSource();
      expect(body.contains('hasInternetConnection'), isFalse);
    });

    test('the internet probe no longer opens a TCP socket to port 53', () {
      final String source = File(p_join(packageRoot(), 'lib/utils/common.dart'))
          .readAsStringSync();
      final int start = source.indexOf('Future<bool> hasInternetConnection()');
      expect(start, greaterThan(0),
          reason: 'hasInternetConnection() not found');
      final int end =
          source.indexOf('SupabaseClient? getSupabaseClient()', start);
      final String body = source.substring(start, end);
      expect(body.contains('Socket.connect'), isFalse);
      expect(body.contains('8.8.8.8'), isFalse);
      expect(body.contains('InternetAddress.lookup'), isTrue);
    });
  });
}
