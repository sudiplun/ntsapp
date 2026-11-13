import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Mirrors StorageSqlite.initTables() for the sync tables plus the child
/// tables that carry ON DELETE CASCADE foreign keys.
Future<Database> openSchema(String path) {
  return databaseFactory.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: 1,
      onConfigure: (db) async => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE category (
            id TEXT PRIMARY KEY,
            profile_id TEXT,
            title TEXT NOT NULL,
            color TEXT,
            position INTEGER,
            archived_at INTEGER,
            at INTEGER,
            state INTEGER,
            updated_at INTEGER,
            thumbnail TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE itemgroup (
            id TEXT PRIMARY KEY,
            category_id TEXT NOT NULL,
            title TEXT NOT NULL,
            pinned INTEGER,
            position INTEGER,
            archived_at INTEGER,
            color TEXT,
            at INTEGER,
            updated_at INTEGER,
            thumbnail TEXT,
            data TEXT,
            state INTEGER,
            FOREIGN KEY (category_id) REFERENCES category(id) ON DELETE CASCADE
          )
        ''');
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
            state INTEGER,
            FOREIGN KEY (group_id) REFERENCES itemgroup(id) ON DELETE CASCADE
          )
        ''');
        await db.execute('''
          CREATE TABLE itemfile (
            id TEXT PRIMARY KEY,
            hash TEXT NOT NULL,
            FOREIGN KEY (id) REFERENCES item(id) ON DELETE CASCADE
          )
        ''');
      },
    ),
  );
}

/// The upsert used by StorageSqlite.insert() after the fix: a plain INSERT,
/// and on a unique-constraint violation an in-place UPDATE.
Future<int> upsertRow(Database db, String table, Map<String, dynamic> row) async {
  try {
    return await db.insert(table, row);
  } on DatabaseException catch (e) {
    if (!e.isUniqueConstraintError()) rethrow;
    dynamic id = row['id'];
    if (id == null) rethrow;
    await db.update(table, row, where: 'id = ?', whereArgs: [id]);
    return 1;
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('upserting a group keeps the notes it already holds', () async {
    final dir = Directory.systemTemp.createTempSync('ntsapp_cascade');
    final db = await openSchema(p.join(dir.path, 'db.db'));

    await db.insert('category', {'id': 'c1', 'title': 'Cat'});
    await db.insert('itemgroup',
        {'id': 'g1', 'category_id': 'c1', 'title': 'Group', 'updated_at': 1});
    for (int i = 0; i < 3; i++) {
      await db.insert('item', {
        'id': 'i$i',
        'group_id': 'g1',
        'text': 'note $i',
        'type': 100000,
        'updated_at': 1,
      });
    }

    // The group row is received again from another device.
    await upsertRow(db, 'itemgroup',
        {'id': 'g1', 'category_id': 'c1', 'title': 'Renamed', 'updated_at': 2});

    final items = await db.query('item');
    final groups = await db.query('itemgroup');
    expect(groups.length, 1);
    expect(groups.first['title'], 'Renamed');
    // The notes survive the re-sync of their group.
    expect(items.length, 3);
  });

  test('upserting a category keeps its groups and notes', () async {
    final dir = Directory.systemTemp.createTempSync('ntsapp_cascade2');
    final db = await openSchema(p.join(dir.path, 'db.db'));

    await db.insert('category', {'id': 'c1', 'title': 'Cat'});
    await db.insert('itemgroup',
        {'id': 'g1', 'category_id': 'c1', 'title': 'Group', 'updated_at': 1});
    await db.insert('item', {
      'id': 'i1',
      'group_id': 'g1',
      'text': 'note',
      'type': 100000,
      'updated_at': 1,
    });

    await upsertRow(db, 'category',
        {'id': 'c1', 'title': 'Renamed', 'updated_at': 2});

    expect((await db.query('itemgroup')).length, 1);
    expect((await db.query('item')).length, 1);
  });

  test('a note whose group is missing fails on the FK', () async {
    final dir = Directory.systemTemp.createTempSync('ntsapp_fk');
    final db = await openSchema(p.join(dir.path, 'db.db'));

    await db.insert('category', {'id': 'c1', 'title': 'Cat'});
    Object? caught;
    try {
      await db.insert('item', {
        'id': 'i1',
        'group_id': 'g-missing',
        'text': 'note',
        'type': 100000,
        'updated_at': 1,
      });
    } catch (e) {
      caught = e;
    }
    expect(caught, isNotNull,
        reason: 'FK violation: item.group_id -> itemgroup.id is enforced');
  });

  test('a note whose group is missing can be stored after the placeholder '
      'group is created', () async {
    final dir = Directory.systemTemp.createTempSync('ntsapp_placeholder');
    final db = await openSchema(p.join(dir.path, 'db.db'));

    await db.insert('category', {'id': 'c1', 'title': 'DND'});
    // SyncUtils.ensureGroupExists() creates the placeholder group with the
    // same id as the group the note belongs to.
    await db.insert('itemgroup', {
      'id': 'g-remote',
      'category_id': 'c1',
      'title': 'Notes',
      'updated_at': 0,
    });

    await db.insert('item', {
      'id': 'i1',
      'group_id': 'g-remote',
      'text': 'note',
      'type': 100000,
      'updated_at': 1,
    });

    expect((await db.query('item')).length, 1);
  });

  test('the placeholder group is replaced by the real group row', () async {
    final dir = Directory.systemTemp.createTempSync('ntsapp_replace');
    final db = await openSchema(p.join(dir.path, 'db.db'));

    await db.insert('category', {'id': 'c1', 'title': 'DND'});
    await db.insert('itemgroup', {
      'id': 'g-remote',
      'category_id': 'c1',
      'title': 'Notes',
      'updated_at': 0,
    });
    await db.insert('item', {
      'id': 'i1',
      'group_id': 'g-remote',
      'text': 'note',
      'type': 100000,
      'updated_at': 1,
    });

    // The real group row arrives later (newer updated_at).
    await upsertRow(db, 'itemgroup', {
      'id': 'g-remote',
      'category_id': 'c1',
      'title': 'Real title',
      'updated_at': 500,
    });

    final groups = await db.query('itemgroup');
    expect(groups.first['title'], 'Real title');
    expect((await db.query('item')).length, 1);
  });
}
