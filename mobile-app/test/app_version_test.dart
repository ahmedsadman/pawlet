import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:pawlet/services/app_version.dart';

void main() {
  void mockBuild(String buildNumber, {DateTime? installTime}) =>
      PackageInfo.setMockInitialValues(
        appName: 'Pawlet',
        packageName: 'com.pastabyte.pawlet',
        version: '0.2.1',
        buildNumber: buildNumber,
        buildSignature: '',
        installTime: installTime,
      );

  test('reads the build number as the version code', () async {
    mockBuild('21');
    expect(await readAppVersionCode(), 21);
  });

  test('an unusable build number yields null', () async {
    for (final bad in ['', 'abc', '0', '-3']) {
      mockBuild(bad);
      expect(await readAppVersionCode(), isNull, reason: 'buildNumber "$bad"');
    }
  });

  test('reads the install time in epoch ms', () async {
    final installed = DateTime.utc(2026, 10, 13, 9);
    mockBuild('30', installTime: installed);
    expect(await readInstallTime(), installed.millisecondsSinceEpoch);
  });

  test('an unknown install time yields null', () async {
    mockBuild('30');
    expect(await readInstallTime(), isNull);
  });
}
