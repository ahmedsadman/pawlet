import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Opens (and migrates) the shared sqflite database.
///
/// `sms_records` doubles as the message store: `transactions.message_id` and
/// `bills.message_id` reference `sms_records.id`, so a transaction/bill can read
/// its backing SMS (sender, content, received time) without a separate table.
class AppDatabase {
  const AppDatabase._();

  static const String fileName = 'pawlet.db';

  static const String smsTable = 'sms_records';
  static const String banksTable = 'banks';
  static const String transactionsTable = 'transactions';
  static const String billsTable = 'bills';

  /// Key/value store for small operational metadata (e.g. the last prune time).
  static const String metaTable = 'app_meta';

  static const int _version = 3;

  static Future<Database> open() async {
    final path = p.join(await getDatabasesPath(), fileName);
    return openDatabase(
      path,
      version: _version,
      onCreate: createSchema,
      onUpgrade: onUpgrade,
    );
  }

  /// Creates the schema. Public so tests can build an in-memory database.
  static Future<void> createSchema(Database db, int version) async {
    await db.execute('''
      CREATE TABLE $smsTable (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sender TEXT NOT NULL,
        contact_name TEXT,
        content TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        status TEXT NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        updated_at INTEGER NOT NULL DEFAULT 0,
        next_attempt_at INTEGER,
        category TEXT,
        processed_at INTEGER,
        ignore_reason TEXT,
        failure_reason TEXT
      )
    ''');
    // Dedupe overlapping foreground / background / cold-start reads of one SMS.
    await db.execute('''
      CREATE UNIQUE INDEX idx_sms_unique
      ON $smsTable (sender, timestamp, content)
    ''');
    await _createSmsOpsIndexes(db);

    await db.execute('''
      CREATE TABLE $metaTable (
        key TEXT PRIMARY KEY,
        value INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE $banksTable (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        account_type TEXT NOT NULL DEFAULT 'deposit',
        card_digits TEXT,
        last_balance TEXT,
        last_balance_at INTEGER,
        created_at INTEGER NOT NULL,
        matchers TEXT
      )
    ''');
    // A bank name may back one deposit AND one or more credit cards, so the
    // uniqueness is partial per account type: one deposit per name, and cards
    // unique by (name, card_digits).
    await db.execute('''
      CREATE UNIQUE INDEX idx_banks_deposit ON $banksTable (name)
      WHERE account_type = 'deposit'
    ''');
    await db.execute('''
      CREATE UNIQUE INDEX idx_banks_credit ON $banksTable (name, card_digits)
      WHERE account_type = 'credit'
    ''');

    await db.execute('''
      CREATE TABLE $transactionsTable (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        message_id INTEGER NOT NULL,
        bank_id INTEGER,
        paired_with_id INTEGER,
        bill_id INTEGER,
        normalized_amount TEXT NOT NULL,
        normalized_currency TEXT NOT NULL,
        original_amount TEXT,
        original_currency TEXT,
        type TEXT NOT NULL,
        date INTEGER NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE UNIQUE INDEX idx_tx_message ON $transactionsTable (message_id)
    ''');
    await db.execute('''
      CREATE INDEX idx_tx_date ON $transactionsTable (date)
    ''');

    await db.execute('''
      CREATE TABLE $billsTable (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        message_id INTEGER NOT NULL,
        bank_id INTEGER,
        normalized_total_due TEXT NOT NULL,
        normalized_currency TEXT NOT NULL,
        original_amount TEXT,
        original_currency TEXT,
        statement_period INTEGER,
        paid_at INTEGER,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE UNIQUE INDEX idx_bill_message ON $billsTable (message_id)
    ''');
    await db.execute('''
      CREATE INDEX idx_bill_bank_period
      ON $billsTable (bank_id, statement_period)
    ''');
  }

  /// Composite indexes on the almost-always status-filtered `sms_records`.
  /// `(status, updated_at)` serves History ordering, the ignored-prune delete,
  /// reclaimStale and counts; `(status, next_attempt_at)` serves the hot
  /// processing path (dueForDelivery + soonestQueuedAttempt).
  static Future<void> _createSmsOpsIndexes(Database db) async {
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_sms_status_updated
      ON $smsTable (status, updated_at)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_sms_status_next
      ON $smsTable (status, next_attempt_at)
    ''');
  }

  /// Applies incremental migrations. Each version's delta is additive so future
  /// upgrades can be appended below.
  static Future<void> onUpgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    // v1 -> v2: allow a deposit + multiple credit cards under one bank name.
    if (oldVersion < 2) {
      await db.execute('DROP INDEX IF EXISTS idx_banks_name');
      await db.execute('''
        CREATE UNIQUE INDEX idx_banks_deposit ON $banksTable (name)
        WHERE account_type = 'deposit'
      ''');
      await db.execute('''
        CREATE UNIQUE INDEX idx_banks_credit ON $banksTable (name, card_digits)
        WHERE account_type = 'credit'
      ''');
      // Credit cards route by card digits only, so they must carry no
      // sender-matchers (otherwise a non-card SMS would match both the deposit
      // and the card and resolve as ambiguous).
      await db.execute(
        "UPDATE $banksTable SET matchers = NULL WHERE account_type = 'credit'",
      );
      // Rename stored rows to the shortened v2 catalog labels so the edit form
      // still preselects them (matchers are unchanged, so routing is unaffected).
      await db.execute(
        "UPDATE $banksTable SET name = 'EBL' WHERE name = 'Eastern Bank Limited'",
      );
      await db.execute(
        "UPDATE $banksTable SET name = 'MTB' WHERE name = 'Mutual Trust Bank'",
      );
      await db.execute(
        "UPDATE $banksTable SET name = 'StanChart (SCB)' "
        "WHERE name = 'Standard Chartered Bank (SCB)'",
      );
    }

    // v2 -> v3: retention model reboot. Schema-only — the app is pre-release, so
    // existing test devices get wiped and no data backfill is needed. Kept for
    // robustness on any non-wiped install: pre-v3 rows keep their old shape
    // (old category='ignored' success rows stay hidden; null failure_reason
    // reads back as the generic hint). Gated on the target [newVersion] so a
    // partial upgrade (e.g. straight to v2) doesn't apply a later delta.
    if (oldVersion < 3 && newVersion >= 3) {
      await db.execute('ALTER TABLE $smsTable ADD COLUMN ignore_reason TEXT');
      await db.execute('ALTER TABLE $smsTable ADD COLUMN failure_reason TEXT');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS $metaTable (
          key TEXT PRIMARY KEY,
          value INTEGER NOT NULL
        )
      ''');
      await _createSmsOpsIndexes(db);
    }
  }
}
