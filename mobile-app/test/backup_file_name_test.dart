import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/ui/backup_restore_page.dart';

void main() {
  test('backupFileName zero-pads date and time', () {
    expect(
      backupFileName(DateTime(2026, 3, 7, 9, 5)),
      'pawlet-backup-2026-03-07-0905.json',
    );
  });
}
