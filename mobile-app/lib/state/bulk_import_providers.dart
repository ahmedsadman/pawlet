import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/bulk_import/bulk_import_service.dart';
import '../services/bulk_import/inbox_reader.dart';
import '../services/finance/finance_matcher.dart';
import '../services/finance/finance_writer.dart';
import '../utils/currency_format.dart';
import 'providers.dart';

/// The inbox import, sharing the UI isolate's already-loaded on-device model:
/// a second interpreter would cost another ~26 MB and a cold warm-up right when
/// the user is staring at a progress bar. The writer and matcher are stateless
/// wrappers over the shared database, so they're built here rather than
/// threaded through AppServices.
final bulkImportServiceProvider = Provider<BulkImportService>((ref) {
  final db = ref.watch(databaseProvider);
  final services = ref.watch(appServicesProvider);
  return BulkImportService(
    inbox: TelephonyInboxReader(),
    smsRepository: services.smsRepository,
    banksRepository: services.banksRepository,
    local: services.localClassifier,
    financeWriter: FinanceWriter(db),
    financeMatcher: FinanceMatcher(db),
    currency: () => kBaseCurrency,
    usdRate: services.exchangeRate.usdToBdt,
  );
});
