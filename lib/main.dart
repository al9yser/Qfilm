import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';

/// رابط الموقع الذي يعرضه التطبيق.
const kSiteUrl = 'http://a.qfilm.tv';

/// النطاق المسموح بالتنقل إليه (ومعه كل نطاقاته الفرعية).
const kSiteDomain = 'qfilm.tv';

/// نطاقات إعلانات وتتبع تُحجب داخل التطبيق.
const kAdDomains = <String>[
  'tmll7.com',
  'histats.com',
  'doubleclick.net',
  'googlesyndication.com',
  'googleadservices.com',
  'popads.net',
  'popcash.net',
  'propellerads.com',
  'adsterra.com',
  'exoclick.com',
  'juicyads.com',
  'trafficjunky.net',
  'clickadu.com',
  'hilltopads.net',
  'onclickads.net',
  'adcash.com',
];

const _accent = Color(0xffe5304f);
const _bg = Color(0xff0b0b10);

bool hostIn(String host, Iterable<String> domains) {
  final h = host.toLowerCase();
  return domains.any((d) => h == d || h.endsWith('.$d'));
}

/// إعدادات المستخدم (تُحفظ على الجهاز).
class Settings {
  bool vpnOn;
  String proxy; // مثل: 1.2.3.4:8080 أو socks5://host:1080
  bool blockAds;
  Settings({this.vpnOn = false, this.proxy = '', this.blockAds = true});

  Map<String, dynamic> toJson() => {
    'vpnOn': vpnOn,
    'proxy': proxy,
    'blockAds': blockAds,
  };

  factory Settings.fromJson(Map<String, dynamic> j) => Settings(
    vpnOn: j['vpnOn'] == true,
    proxy: (j['proxy'] ?? '').toString(),
    blockAds: j['blockAds'] != false,
  );

  static Future<File> _file() async {
    final d = await getApplicationSupportDirectory();
    return File('${d.path}/settings.json');
  }

  static Future<Settings> load() async {
    try {
      final f = await _file();
      if (await f.exists()) {
        final m = jsonDecode(await f.readAsString());
        if (m is Map) return Settings.fromJson(Map<String, dynamic>.from(m));
      }
    } catch (_) {}
    return Settings();
  }

  Future<void> save() async {
    try {
      await (await _file()).writeAsString(jsonEncode(toJson()));
    } catch (_) {}
  }
}

/// تفعيل أو إيقاف البروكسي على مستوى متصفح التطبيق فقط (لا يمس باقي الجهاز).
Future<bool> applyProxy(Settings s) async {
  try {
    final pc = ProxyController.instance();
    if (s.vpnOn && s.proxy.trim().isNotEmpty) {
      await pc.setProxyOverride(
        settings: ProxySettings(proxyRules: [ProxyRule(url: s.proxy.trim())]),
      );
    } else {
      await pc.clearProxyOverride();
    }
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const QfilmApp());
}

class QfilmApp extends StatelessWidget {
  const QfilmApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Qfilm',
    theme: ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: _bg,
      colorScheme: ColorScheme.fromSeed(
        seedColor: _accent,
        brightness: Brightness.dark,
      ),
    ),
    builder: (context, child) =>
        Directionality(textDirection: TextDirection.rtl, child: child!),
    home: const Shell(),
  );
}

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  Settings? settings;
  InAppWebViewController? web;
  double progress = 0;
  bool failed = false;
  DateTime? _lastBack;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    final s = await Settings.load();
    // يجب تطبيق البروكسي قبل أول تحميل للصفحة.
    await applyProxy(s);
    if (mounted) setState(() => settings = s);
  }

  List<ContentBlocker> _blockers(bool on) => on
      ? [
          for (final d in kAdDomains)
            ContentBlocker(
              trigger: ContentBlockerTrigger(
                urlFilter: '.*${d.replaceAll('.', r'\.')}.*',
              ),
              action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
            ),
        ]
      : [];

  InAppWebViewSettings _webSettings(Settings s) => InAppWebViewSettings(
    javaScriptEnabled: true,
    domStorageEnabled: true,
    mediaPlaybackRequiresUserGesture: false,
    allowsInlineMediaPlayback: true,
    useShouldOverrideUrlLoading: true,
    javaScriptCanOpenWindowsAutomatically: false,
    supportMultipleWindows: false,
    mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
    contentBlockers: _blockers(s.blockAds),
    transparentBackground: false,
  );

  Future<void> _reload() async {
    setState(() => failed = false);
    await web?.reload();
  }

  Future<void> _home() async {
    setState(() => failed = false);
    await web?.loadUrl(urlRequest: URLRequest(url: WebUri(kSiteUrl)));
  }

  Future<void> _setVpn(bool on) async {
    final s = settings!;
    if (on && s.proxy.trim().isEmpty) {
      final ok = await _editProxy();
      if (!ok) return;
    }
    s.vpnOn = on;
    final applied = await applyProxy(s);
    if (!applied && mounted) {
      s.vpnOn = false;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('هذا الجهاز لا يدعم تشغيل VPN داخل التطبيق')),
      );
    }
    await s.save();
    if (mounted) setState(() {});
    await _reload();
  }

  Future<bool> _editProxy() async {
    final s = settings!;
    final ctl = TextEditingController(text: s.proxy);
    final res = await showDialog<String>(
      context: context,
      builder: (dc) => AlertDialog(
        title: const Text('خادم VPN'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctl,
              autofocus: true,
              textDirection: TextDirection.ltr,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                hintText: '1.2.3.4:8080',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (v) => Navigator.pop(dc, v),
            ),
            const SizedBox(height: 10),
            const Text(
              'أدخل عنوان الخادم الوسيط. أمثلة:\n1.2.3.4:8080\nsocks5://1.2.3.4:1080',
              style: TextStyle(fontSize: 12, color: Colors.white60),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dc),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dc, ctl.text),
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
    ctl.dispose();
    if (res == null || res.trim().isEmpty) return false;
    s.proxy = res.trim();
    await s.save();
    if (mounted) setState(() {});
    if (s.vpnOn) {
      await applyProxy(s);
      await _reload();
    }
    return true;
  }

  Future<void> _setAdBlock(bool on) async {
    final s = settings!;
    s.blockAds = on;
    await s.save();
    await web?.setSettings(settings: _webSettings(s));
    if (mounted) setState(() {});
    await _reload();
  }

  void _openMenu() {
    final s = settings!;
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheet) => StatefulBuilder(
        builder: (context, setSheet) => SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  autofocus: true,
                  leading: const Icon(Icons.home_outlined),
                  title: const Text('الرئيسية'),
                  onTap: () {
                    Navigator.pop(sheet);
                    _home();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.refresh),
                  title: const Text('تحديث الصفحة'),
                  onTap: () {
                    Navigator.pop(sheet);
                    _reload();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.arrow_forward),
                  title: const Text('رجوع'),
                  onTap: () {
                    Navigator.pop(sheet);
                    web?.goBack();
                  },
                ),
                const Divider(height: 1),
                SwitchListTile(
                  secondary: const Icon(Icons.vpn_lock_outlined),
                  title: const Text('تشغيل VPN'),
                  subtitle: Text(
                    s.proxy.isEmpty ? 'لم يُضبط خادم بعد' : s.proxy,
                    textDirection: TextDirection.ltr,
                    textAlign: TextAlign.start,
                  ),
                  value: s.vpnOn,
                  onChanged: (v) async {
                    Navigator.pop(sheet);
                    await _setVpn(v);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.dns_outlined),
                  title: const Text('إعداد خادم VPN'),
                  onTap: () async {
                    Navigator.pop(sheet);
                    await _editProxy();
                  },
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.shield_outlined),
                  title: const Text('حجب الإعلانات'),
                  value: s.blockAds,
                  onChanged: (v) async {
                    Navigator.pop(sheet);
                    await _setAdBlock(v);
                  },
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.exit_to_app),
                  title: const Text('خروج من التطبيق'),
                  onTap: () => SystemNavigator.pop(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// زر الرجوع: يرجع في الموقع، وعند أول صفحة يطلب ضغطة ثانية للخروج.
  Future<void> _onBack() async {
    if (await web?.canGoBack() ?? false) {
      await web?.goBack();
      return;
    }
    final now = DateTime.now();
    if (_lastBack != null && now.difference(_lastBack!) < const Duration(seconds: 2)) {
      SystemNavigator.pop();
      return;
    }
    _lastBack = now;
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('اضغط رجوع مرة أخرى للخروج'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = settings;
    if (s == null) return const _Splash();
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onBack();
      },
      child: Scaffold(
        body: SafeArea(
          child: Stack(
            children: [
              InAppWebView(
                initialUrlRequest: URLRequest(url: WebUri(kSiteUrl)),
                initialSettings: _webSettings(s),
                onWebViewCreated: (c) => web = c,
                onLoadStart: (c, u) {
                  if (mounted) setState(() => failed = false);
                },
                onProgressChanged: (c, p) {
                  if (mounted) setState(() => progress = p / 100);
                },
                onReceivedError: (c, req, err) {
                  if ((req.isForMainFrame ?? true) && mounted) {
                    setState(() => failed = true);
                  }
                },
                // نوافذ منبثقة وفتح تطبيقات خارجية (intent://) وتحويلات الإعلانات: مرفوضة.
                onCreateWindow: (c, action) async => false,
                shouldOverrideUrlLoading: (c, action) async {
                  final u = action.request.url;
                  if (u == null) return NavigationActionPolicy.CANCEL;
                  if (u.scheme != 'http' && u.scheme != 'https') {
                    return NavigationActionPolicy.CANCEL;
                  }
                  if (hostIn(u.host, kAdDomains)) {
                    return NavigationActionPolicy.CANCEL;
                  }
                  if (action.isForMainFrame && !hostIn(u.host, [kSiteDomain])) {
                    return NavigationActionPolicy.CANCEL;
                  }
                  return NavigationActionPolicy.ALLOW;
                },
                onEnterFullscreen: (c) {
                  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
                  SystemChrome.setPreferredOrientations([
                    DeviceOrientation.landscapeLeft,
                    DeviceOrientation.landscapeRight,
                  ]);
                },
                onExitFullscreen: (c) {
                  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
                  SystemChrome.setPreferredOrientations([]);
                },
              ),
              if (progress < 1 && !failed)
                const Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: LinearProgressIndicator(minHeight: 3, color: _accent),
                ),
              if (failed)
                _ErrorView(
                  vpnOn: s.vpnOn,
                  onRetry: _reload,
                  onVpn: () => _setVpn(!s.vpnOn),
                ),
              // زر القائمة العائم (يعمل باللمس والريموت)
              Positioned(
                bottom: 16,
                left: 16,
                child: FloatingActionButton.small(
                  heroTag: 'menu',
                  backgroundColor: _accent,
                  foregroundColor: Colors.white,
                  tooltip: 'القائمة',
                  onPressed: _openMenu,
                  child: const Icon(Icons.menu),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();
  @override
  Widget build(BuildContext context) => const Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.play_circle_fill, size: 84, color: _accent),
          SizedBox(height: 14),
          Text(
            'QFILM',
            style: TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w900,
              letterSpacing: 3,
            ),
          ),
        ],
      ),
    ),
  );
}

class _ErrorView extends StatelessWidget {
  final bool vpnOn;
  final VoidCallback onRetry;
  final VoidCallback onVpn;
  const _ErrorView({
    required this.vpnOn,
    required this.onRetry,
    required this.onVpn,
  });
  @override
  Widget build(BuildContext context) => Positioned.fill(
    child: Container(
      color: _bg,
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 64, color: Colors.white54),
            const SizedBox(height: 16),
            const Text(
              'تعذر فتح الموقع',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              vpnOn
                  ? 'تحقق من الإنترنت ومن عنوان خادم VPN.'
                  : 'تحقق من الإنترنت، وإن كان الموقع محجوباً في بلدك فشغّل VPN.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white60),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              autofocus: true,
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('إعادة المحاولة'),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: onVpn,
              icon: const Icon(Icons.vpn_lock_outlined),
              label: Text(vpnOn ? 'إيقاف VPN' : 'تشغيل VPN'),
            ),
          ],
        ),
      ),
    ),
  );
}
