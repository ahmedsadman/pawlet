import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/services/privacy_policy.dart';

void main() {
  test('the policy URL is the live HTTPS page', () {
    final uri = Uri.parse(PrivacyPolicy.url);
    expect(uri.scheme, 'https');
    expect(uri.host, 'ahmedsadman.github.io');
    expect(uri.path, '/pawlet/');
  });

  test('open() hands the policy URL to the launcher', () async {
    Uri? launched;
    PrivacyPolicy.launcher = (uri) async {
      launched = uri;
      return true;
    };
    addTearDown(PrivacyPolicy.resetLauncher);

    final ok = await PrivacyPolicy.open();

    expect(ok, isTrue);
    expect(launched, Uri.parse(PrivacyPolicy.url));
  });

  test('open() reports failure when no browser handles the URL', () async {
    PrivacyPolicy.launcher = (_) async => false;
    addTearDown(PrivacyPolicy.resetLauncher);

    expect(await PrivacyPolicy.open(), isFalse);
  });
}
