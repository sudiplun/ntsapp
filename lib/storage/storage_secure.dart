import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureStorage {
  // Singleton instance
  static final SecureStorage _instance = SecureStorage._internal();

  // Factory constructor to return the singleton instance
  factory SecureStorage() {
    return _instance;
  }

  // Private constructor
  SecureStorage._internal();

  // FlutterSecureStorage instance
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  /// In-memory cache so repeated reads in a session do not pay the cost of a
  /// platform-channel/keychain round-trip. Startup and every page used to read
  /// the same handful of values several times.
  final Map<String, String?> _cache = <String, String?>{};

  /// Values that always have a fixed fallback. Keeping the defaults here means
  /// the app no longer has to write them to secure storage on first launch.
  static const Map<String, String> _defaults = <String, String>{
    'app_name': 'Note Safe',
    'media_dir': 'ntsmedia',
    'backup_dir': 'ntsbackup',
    'db_file': 'notetoself.db',
  };

  // CRUD Methods

  /// Write a key-value pair securely
  Future<void> write({required String key, required String value}) async {
    await _storage.write(key: key, value: value);
    _cache[key] = value;
  }

  /// Read a value by key
  Future<String?> read({required String key}) async {
    if (_cache.containsKey(key)) {
      return _cache[key] ?? _defaults[key];
    }
    final value = await _storage.read(key: key);
    _cache[key] = value;
    return value ?? _defaults[key];
  }

  Future<bool> containsKey({required String key}) async {
    if (_cache.containsKey(key)) {
      return _cache[key] != null;
    }
    final exists = await _storage.containsKey(key: key);
    if (exists) {
      _cache[key] = await _storage.read(key: key);
    }
    return exists;
  }

  /// Delete a value by key
  Future<void> delete({required String key}) async {
    _cache.remove(key);
    await _storage.delete(key: key);
  }
}
