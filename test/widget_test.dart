import 'package:flutter_test/flutter_test.dart';
import 'package:qfilm/main.dart';

void main() {
  test('Settings json round trip', () {
    final s = Settings(vpnOn: true, proxy: '1.2.3.4:8080', blockAds: false);
    final r = Settings.fromJson(s.toJson());
    expect(r.vpnOn, true);
    expect(r.proxy, '1.2.3.4:8080');
    expect(r.blockAds, false);
  });

  test('hostIn matches domain and subdomains only', () {
    expect(hostIn('a.qfilm.tv', ['qfilm.tv']), true);
    expect(hostIn('qfilm.tv', ['qfilm.tv']), true);
    expect(hostIn('evilqfilm.tv', ['qfilm.tv']), false);
  });
}
