import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ntsapp/models/model_change.dart';
import 'package:ntsapp/utils/common.dart';
import 'package:ntsapp/utils/enums.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The `item` table as created by StorageSqlite.initTables().
Future<Database> openItemSchema(String path) {
  return databaseFactory.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: 1,
      onConfigure: (db) async => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE item (
            id TEXT PRIMARY KEY,
            group_id TEXT NOT NULL,
            text TEXT,
            starred INTEGER,
            pinned INTEGER,
            archived_at INTEGER,
            type INTEGER,
            data TEXT,
            at INTEGER,
            updated_at INTEGER,
            thumbnail TEXT,
            state INTEGER
          )
        ''');
      },
    ),
  );
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('media change queue', () {
    test('a media upload runs through map -> thumbnail -> file -> done', () {
      // The pipeline of an image/video note.
      expect(
        ModelChange.getNextTaskType(SyncChangeTask.pushMapThumbnailFile),
        SyncChangeTask.pushThumbnailFile,
      );
      expect(
        ModelChange.getNextTaskType(SyncChangeTask.pushThumbnailFile),
        SyncChangeTask.pushFile,
      );
      expect(
        ModelChange.getNextTaskType(SyncChangeTask.pushFile),
        SyncChangeTask.delete,
      );
      // ... and of an audio/document note.
      expect(
        ModelChange.getNextTaskType(SyncChangeTask.pushMapFile),
        SyncChangeTask.pushFile,
      );
    });

    test('the media steps are recognised as media steps', () {
      expect(ModelChange.isMediaUploadTask(SyncChangeTask.pushMapThumbnailFile),
          isTrue);
      expect(ModelChange.isMediaUploadTask(SyncChangeTask.pushThumbnailFile),
          isTrue);
      expect(ModelChange.isMediaUploadTask(SyncChangeTask.pushFile), isTrue);
      expect(ModelChange.isMediaUploadTask(SyncChangeTask.pushMap), isFalse);
      expect(ModelChange.isMediaUploadTask(SyncChangeTask.pushMapThumbnail),
          isTrue);
      expect(ModelChange.isMediaUploadTask(null), isFalse);
    });

    test('editing a note keeps its queued file upload alive', () {
      final Map<String, dynamic> imageRow = {
        "id": "item-1",
        "type": ItemType.image.value,
      };
      // The file is being uploaded and the user edits the note's text.
      // The map still has to be pushed, but the file upload must not be
      // cancelled - otherwise the other device gets a note without its
      // media.
      final SyncChangeTask task = ModelChange.nextTaskAfterUpdate(
        table: "item",
        thumbnailIsNull: false,
        map: imageRow,
        mediaChanges: false,
        pending: SyncChangeTask.pushFile,
      );
      expect(task, SyncChangeTask.pushMapThumbnailFile);
      // ... and the pipeline continues from there.
      expect(ModelChange.getNextTaskType(task), SyncChangeTask.pushThumbnailFile);
    });

    test('editing a note with nothing queued only pushes the map', () {
      final SyncChangeTask task = ModelChange.nextTaskAfterUpdate(
        table: "item",
        thumbnailIsNull: false,
        map: {"id": "item-1", "type": ItemType.image.value},
        mediaChanges: false,
        pending: null,
      );
      expect(task, SyncChangeTask.pushMap);
    });

    test('editing a text note only pushes the map', () {
      final SyncChangeTask task = ModelChange.nextTaskAfterUpdate(
        table: "item",
        thumbnailIsNull: true,
        map: {"id": "item-1", "type": ItemType.text.value},
        mediaChanges: false,
        pending: SyncChangeTask.pushMap,
      );
      expect(task, SyncChangeTask.pushMap);
    });

    test('changing the media restarts the pipeline at the map step', () {
      final SyncChangeTask task = ModelChange.nextTaskAfterUpdate(
        table: "item",
        thumbnailIsNull: false,
        map: {"id": "item-1", "type": ItemType.image.value},
        mediaChanges: true,
        pending: SyncChangeTask.pushFile,
      );
      expect(task, SyncChangeTask.pushMapThumbnailFile);
    });
  });

  group('updated_at', () {
    test('an internal update does not move updated_at forward', () {
      final Map<String, dynamic> row = {
        "text": "hello",
        "state": 3,
        "updated_at": 1000,
      };
      // The sync engine updates the row locally (download state, the
      // rewritten file path, the downloaded thumbnail). That must not look
      // like a new edit.
      final Map<String, dynamic> columns = updatedRowColumns(
        row,
        ["state"],
        pushToSync: false,
        updatedAt: 9999,
      );
      expect(columns.containsKey("updated_at"), isFalse);
      expect(columns["state"], 3);
    });

    test('an update that is pushed moves updated_at forward', () {
      final Map<String, dynamic> row = {
        "text": "hello",
        "updated_at": 1000,
      };
      final Map<String, dynamic> columns = updatedRowColumns(
        row,
        ["text"],
        pushToSync: true,
        updatedAt: 9999,
      );
      expect(columns["updated_at"], 9999);
      expect(columns["text"], "hello");
    });

    test('a fetched media note still accepts the other device\'s edits', () {
      // The timeline of a media note that is edited on the other device:
      //   T0  the note is created on device A
      //   T1  device B fetches it
      //   T2  device A edits the note
      // The fetch must not make B's copy look newer than A's edit, or the
      // edit would be rejected as "older" and the note would stop
      // updating on B.
      const int createdAt = 1000;
      const int fetchedAt = 2000;
      const int editedAt = 1500;

      return () async {
        final Directory dir =
            Directory.systemTemp.createTempSync('ntsapp_lww');
        final Database db = await openItemSchema(p.join(dir.path, 'db.db'));

        await db.insert('item', {
          'id': 'item-1',
          'group_id': 'g1',
          'text': 'original',
          'type': ItemType.image.value,
          'updated_at': createdAt,
          'thumbnail': 'thumbnail-bytes',
        });

        // The fetch: the row is written with the server's updated_at and
        // then the local sync updates it (state, file path, thumbnail).
        await db.update(
          'item',
          {"updated_at": createdAt},
          where: 'id = ?',
          whereArgs: ['item-1'],
        );
        await db.update(
          'item',
          updatedRowColumns(
            {"state": 3},
            ["state"],
            pushToSync: false,
            updatedAt: fetchedAt,
          ),
          where: 'id = ?',
          whereArgs: ['item-1'],
        );

        Map<String, dynamic> row =
            (await db.query('item', where: 'id = ?', whereArgs: ['item-1']))
                .first;
        expect(row["updated_at"], createdAt,
            reason:
                'the local copy must not claim to be newer than the server');

        // Now the edit from device A arrives.
        int incomingUpdatedAt = editedAt;
        int existingUpdatedAt = row["updated_at"];
        expect(incomingUpdatedAt > existingUpdatedAt, isTrue,
            reason: 'the edit would have been rejected as "older"');

        await db.close();
        dir.deleteSync(recursive: true);
      }();
    });
  });
}
