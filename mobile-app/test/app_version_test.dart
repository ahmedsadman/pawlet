import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:pawlet/services/app_version.dart';

void main() {
  void mockBuild(String buildNumber) => PackageInfo.setMockInitialValues(
    appName: 'Pawlet',
    packageName: 'com.pastabyte.pawlet',
    version: '1.1.0',
    buildNumber: buildNumber,
    buildSignature: '',
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
}
