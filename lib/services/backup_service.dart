import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../data/database.dart';
import '../data/settings_repository.dart';

/// Thrown when a backup file cannot be parsed or is not a supported backup.
class BackupFormatException implements Exception {
  BackupFormatException(this.message);
  final String message;
  @override
  String toString() => 'BackupFormatException: $message';
}

/// Serializes all local data to a single JSON document and restores it.
///
/// Scope: the four SQLite tables plus user settings. Secrets (PIN, API key)
/// live in SecureStore and are deliberately excluded. Restore is replace-all:
/// existing rows are wiped and the backup's rows are re-inserted with their
/// original ids (so `transactions`/`bills` references stay intact), inside one
/// DB transaction.
class BackupService {
  BackupService({required Database db, required SettingsRepository settings})
    : _db = db,
      _settings = settings;

  final Database _db;
  final SettingsRepository _settings;

  /// Bumped when the on-disk format changes incompatibly.
  static const int backupVersion = 1;

  static const List<String> _tables = [
    AppDatabase.smsTable,
    AppDatabase.banksTable,
    AppDatabase.transactionsTable,
    AppDatabase.billsTable,
  ];

  /// Builds the backup JSON string. [nowMs] is injectable for deterministic
  /// tests; production passes null and the current time is stamped.
  Future<String> exportJson({int? nowMs}) async {
    final database = <String, Object?>{};
    for (final table in _tables) {
      database[table] = await _db.query(table);
    }
    return jsonEncode({
      'meowni_backup_version': backupVersion,
      'exported_at': nowMs ?? DateTime.now().millisecondsSinceEpoch,
      'database': database,
      'settings': _settings.exportAll(),
    });
  }

  /// Validates [jsonString] then replaces all local data with its contents.
  /// Throws [BackupFormatException] on any structural problem — the DB is only
  /// touched after every table has validated, so a bad file is a no-op.
  Future<void> importJson(String jsonString) async {
    final Object? decoded;
    try {
      decoded = jsonDecode(jsonString);
    } on FormatException {
      throw BackupFormatException('File is not valid JSON.');
    }
    if (decoded is! Map) {
      throw BackupFormatException('Backup root must be a JSON object.');
    }
    final root = decoded.cast<String, Object?>();
    if (root['meowni_backup_version'] != backupVersion) {
      throw BackupFormatException(
        'Unsupported backup version: ${root['meowni_backup_version']}.',
      );
    }
    final database = root['database'];
    if (database is! Map) {
      throw BackupFormatException('Backup is missing its "database" section.');
    }
    final db = database.cast<String, Object?>();

    // Fully validate every table before mutating anything.
    final tableRows = <String, List<Map<String, Object?>>>{};
    for (final table in _tables) {
      final raw = db[table];
      if (raw is! List) {
        throw BackupFormatException(
          'Backup table "$table" is missing or invalid.',
        );
      }
      tableRows[table] = [
        for (final row in raw) (row as Map).cast<String, Object?>(),
      ];
    }

    await _db.transaction((txn) async {
      for (final table in _tables) {
        await txn.delete(table);
        for (final row in tableRows[table]!) {
          await txn.insert(
            table,
            row,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      }
    });

    final settings = root['settings'];
    await _settings.importAll(
      settings is Map
          ? settings.cast<String, Object?>()
          : const <String, Object?>{},
    );
  }
}
