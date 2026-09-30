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

  static const int _version = 6;

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
        failure_reason TEXT,
        parse_source TEXT,
        needs_llm INTEGER NOT NULL DEFAULT 0
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
        -- Nullable: manual (user-entered) transactions have no backing SMS.
        message_id INTEGER,
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

  /// Upgrade policy: walk forward one step at a time, preserving data from
  /// every released version; rebuild destructively only from versions that
  /// predate release and so have no migration path.
  ///
  /// Installs in the wild carry hand-configured accounts and cards that cannot
  /// be re-derived from the SMS inbox, so every step from v5 onward needs a
  /// branch here.
  ///
  /// Keyed on [oldVersion] alone, and deliberately cumulative rather than an
  /// exact (old, new) match: a device that skips releases arrives with an
  /// arbitrarily old version and must still run every intervening step. An
  /// exact-pair match would silently drop such a device into the destructive
  /// rebuild the moment [_version] moves again.
  ///
  /// Every new step needs a test in `test/database_test.dart` covering both
  /// halves: that rows survive, and that the resulting schema matches what
  /// [createSchema] would have produced.
  static Future<void> onUpgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 5) {
      for (final table in const [
        smsTable,
        banksTable,
        transactionsTable,
        billsTable,
        metaTable,
      ]) {
        // Dropping a table also drops its indexes.
        await db.execute('DROP TABLE IF EXISTS $table');
      }
      await createSchema(db, newVersion);
      // Load-bearing, not a stylistic early exit: falling through would ALTER
      // a needs_llm column that createSchema just created.
      return;
    }

    if (oldVersion < 6) {
      // Purely additive; existing rows take the default.
      await db.execute(
        'ALTER TABLE $smsTable '
        'ADD COLUMN needs_llm INTEGER NOT NULL DEFAULT 0',
      );
    }
  }
}
