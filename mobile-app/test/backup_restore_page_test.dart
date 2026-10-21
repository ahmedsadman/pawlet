import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pawlet/data/settings_repository.dart';
import 'package:pawlet/services/backup_service.dart';
import 'package:pawlet/state/providers.dart';
import 'package:pawlet/ui/backup_restore_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockBackup extends Mock implements BackupService {}

/// Answers the restore picker with one in-memory file.
class _FakePicker extends FilePickerPlatform {
  @override
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => [_BytesFile(utf8.encode('{}'))];
}

final class _BytesFile extends PlatformFile {
  _BytesFile(this._bytes);
  final Uint8List _bytes;

  @override
  String get name => 'backup.json';

  @override
  Uri get uri => Uri.parse('content://test/backup.json');

  @override
  get xFile => throw UnimplementedError();

  @override
  int? lengthSync() => _bytes.length;

  @override
  Future<int?> length() async => _bytes.length;

  @override
  Future<Uint8List> readAsBytes() async => _bytes;

  @override
  Stream<Uint8List> readAsByteStream() => Stream.value(_bytes);
}

void main() {
  testWidgets('a restore moves the LLM switch to the restored value', (
    tester,
  ) async {
    FilePickerPlatform.instance = _FakePicker();
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final backup = _MockBackup();
    // The backup carries the switch turned off.
    when(() => backup.importJson(any())).thenAnswer(
      (_) => SettingsRepository(prefs).importAll({'llm_enabled': false}),
    );
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        backupServiceProvider.overrideWithValue(backup),
      ],
    );
    addTearDown(container.dispose);
    expect(container.read(llmEnabledProvider), isTrue);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: BackupRestorePage()),
      ),
    );
    await tester.tap(find.text('Restore from file'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore'));
    // Not pumpAndSettle: the busy spinner keeps animating behind the dialog.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    expect(find.text('Restore complete'), findsOneWidget);
    expect(container.read(llmEnabledProvider), isFalse);
  });
}
