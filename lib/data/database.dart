import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Opens (and migrates) the shared sqflite database.
///
/// `sms_records` doubles as the message store: `transactions.message_id` and
/// `bills.message_id` reference `sms_records.id`, so a transaction/bill can read
/// its backing SMS (sender, content, received time) without a separate table.
class AppDatabase {
  const AppDatabase._();

  static const String fileName = 'meowni.db';

  static const String smsTable = 'sms_records';
  static const String banksTable = 'banks';
  static const String transactionsTable = 'transactions';
  static const String billsTable = 'bills';

  static const int _version = 1;

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
        processed_at INTEGER
      )
    ''');
    // Dedupe overlapping foreground / background / cold-start reads of one SMS.
    await db.execute('''
      CREATE UNIQUE INDEX idx_sms_unique
      ON $smsTable (sender, timestamp, content)
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
    await db.execute('''
      CREATE UNIQUE INDEX idx_banks_name ON $banksTable (name)
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

  /// Applies incremental migrations. Each version's delta is additive so future
  /// upgrades can be appended below.
  static Future<void> onUpgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    // v1 is the initial schema; no migrations yet.
  }
}
