import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';

/// رابط الموقع الذي يعرضه التطبيق.
const kSiteUrl = 'https://a.qfilm.tv';

/// النطاق المسموح بالتنقل إليه (ومعه كل نطاقاته الفرعية).
const kSiteDomain = 'qfilm.tv';

const kUserAgent =
    'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36';

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

/// قوائم عامة على GitHub وغيرها لخوادم وسيطة مجانية (يفحصها التطبيق تلقائياً).
const kProxySources = <String>[
  'https://raw.githubusercontent.com/monosans/proxy-list/main/proxies/http.txt',
  'https://cdn.jsdelivr.net/gh/proxifly/free-proxy-list@main/proxies/protocols/http/data.txt',
  'https://raw.githubusercontent.com/TheSpeedX/PROXY-List/master/http.txt',
  'https://api.proxyscrape.com/v4/free-proxy-list/get?request=display_proxies&protocol=http&proxy_format=ipport&format=text&timeout=5000',
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
  String proxy; // الخادم الحالي، مثل: 1.2.3.4:8080 أو socks5://host:1080
  bool auto; // true = يبحث التطبيق عن أسرع خادم تلقائياً
  List<String> proxies; // بدائل جاهزة للتبديل التلقائي عند تعطل الخادم
  bool blockAds;
  Settings({
    this.vpnOn = false,
    this.proxy = '',
    this.auto = true,
    List<String>? proxies,
    this.blockAds = true,
  }) : proxies = proxies ?? [];

  Map<String, dynamic> toJson() => {
    'vpnOn': vpnOn,
    'proxy': proxy,
    'auto': auto,
    'proxies': proxies,
    'blockAds': blockAds,
  };

  factory Settings.fromJson(Map<String, dynamic> j) => Settings(
    vpnOn: j['vpnOn'] == true,
    proxy: (j['proxy'] ?? '').toString(),
    auto: j['auto'] != false,
    proxies: (j['proxies'] is List)
        ? (j['proxies'] as List).map((e) => e.toString()).toList()
        : [],
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

class FoundProxy {
  final String addr;
  final int ms;
  const FoundProxy(this.addr, this.ms);
}

/// يحمّل قوائم الخوادم الوسيطة العامة ويجرّب كل خادم بفتح الموقع الحقيقي عبر https،
/// ثم يعيد الأسرع. الاتصال مشفّر من التطبيق إلى الموقع (CONNECT)، فلا يستطيع الخادم
/// الوسيط قراءة المحتوى، وأي خادم يغيّر الشهادة يفشل في الفحص ويُستبعد.
class ProxyFinder {
  bool cancelled = false;

  Future<Set<String>> _fetch(String url) async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await c.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 15));
      final res = await req.close().timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) return {};
      final text = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 25));
      final re = RegExp(r'(\d{1,3}(?:\.\d{1,3}){3}):(\d{2,5})');
      return re.allMatches(text).map((m) => '${m[1]}:${m[2]}').toSet();
    } catch (_) {
      return {};
    } finally {
      c.close(force: true);
    }
  }

  Future<FoundProxy?> _test(String addr) async {
    final c = HttpClient()
      ..connectionTimeout = const Duration(seconds: 6)
      ..findProxy = ((_) => 'PROXY $addr');
    final sw = Stopwatch()..start();
    try {
      final req = await c.getUrl(Uri.parse(kSiteUrl)).timeout(const Duration(seconds: 7));
      req.headers.set(HttpHeaders.userAgentHeader, kUserAgent);
      final res = await req.close().timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      final bytes = <int>[];
      await for (final chunk in res.timeout(const Duration(seconds: 8))) {
        bytes.addAll(chunk);
        if (bytes.length > 150000) break;
      }
      final body = utf8.decode(bytes, allowMalformed: true).toLowerCase();
      // الصفحة الحقيقية فقط (وليس صفحة بديلة أو صفحة خادم وسيط).
      if (body.contains('qfilm') && !body.contains('servicepremium')) {
        return FoundProxy(addr, sw.elapsedMilliseconds);
      }
    } catch (_) {
    } finally {
      c.close(force: true);
    }
    return null;
  }

  Future<List<FoundProxy>> find({
    void Function(String)? onStatus,
    int want = 4,
    int maxCandidates = 500,
  }) async {
    cancelled = false;
    onStatus?.call('تحميل قوائم الخوادم...');
    final lists = await Future.wait(kProxySources.map(_fetch));
    final all = <String>{for (final l in lists) ...l}.toList()..shuffle();
    if (all.isEmpty) {
      onStatus?.call('تعذر تحميل القوائم، تحقق من الإنترنت');
      return [];
    }
    final pool = all.take(maxCandidates).toList();
    final found = <FoundProxy>[];
    var idx = 0, done = 0;

    Future<void> worker() async {
      while (!cancelled && found.length < want && idx < pool.length) {
        final addr = pool[idx++];
        final r = await _test(addr);
        done++;
        if (r != null) found.add(r);
        onStatus?.call('فُحص $done من ${pool.length}  •  وُجد ${found.length} يعمل');
      }
    }

    await Future.wait(List.generate(40, (_) => worker()));
    found.sort((a, b) => a.ms.compareTo(b.ms));
    return found;
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
  bool _busy = false; // بحث/تبديل خادم جارٍ
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
    // يظهر كمتصفح Chrome عادي (بعض المواقع ترسل صفحة بديلة لمتصفحات التطبيقات المدمجة).
    userAgent: kUserAgent,
    // لا يرسل الترويسة X-Requested-With التي تكشف اسم التطبيق.
    requestedWithHeaderOriginAllowList: <String>{},
  );

  void _snack(String t) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(t)));
  }

  Future<void> _reload() async {
    setState(() => failed = false);
    await web?.reload();
  }

  Future<void> _home() async {
    setState(() => failed = false);
    await web?.loadUrl(urlRequest: URLRequest(url: WebUri(kSiteUrl)));
  }

  /// نافذة تقدّم البحث عن أسرع خادم وسيط.
  Future<List<FoundProxy>> _runFinder() async {
    final finder = ProxyFinder();
    final status = ValueNotifier<String>('جارٍ البدء...');
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dc) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('جارٍ البحث عن أسرع خادم'),
          content: ValueListenableBuilder<String>(
            valueListenable: status,
            builder: (_, v, __) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const LinearProgressIndicator(),
                const SizedBox(height: 14),
                Text(v),
              ],
            ),
          ),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => finder.cancelled = true,
              child: const Text('إلغاء'),
            ),
          ],
        ),
      ),
    );
    List<FoundProxy> res = [];
    try {
      res = await finder.find(onStatus: (t) => status.value = t);
    } finally {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      status.dispose();
    }
    return res;
  }

  /// يبحث تلقائياً، ويشغّل أسرع خادم، ويحفظ الباقي كبدائل.
  Future<bool> _autoConnect() async {
    if (_busy) return false;
    _busy = true;
    try {
      final s = settings!;
      final found = await _runFinder();
      if (found.isEmpty) {
        _snack('لم أجد خادماً يعمل الآن. أعد المحاولة بعد قليل.');
        return false;
      }
      s.auto = true;
      s.proxy = found.first.addr;
      s.proxies = found.skip(1).map((e) => e.addr).toList();
      s.vpnOn = true;
      await applyProxy(s);
      await s.save();
      if (mounted) setState(() {});
      _snack('تم الاتصال عبر ${found.first.addr} (${found.first.ms} ms)');
      await _reload();
      return true;
    } finally {
      _busy = false;
    }
  }

  Future<void> _setVpn(bool on) async {
    final s = settings!;
    if (!on) {
      s.vpnOn = false;
      await applyProxy(s);
      await s.save();
      if (mounted) setState(() {});
      await _reload();
      return;
    }
    if (s.auto || s.proxy.trim().isEmpty) {
      await _autoConnect();
      return;
    }
    s.vpnOn = true;
    final ok = await applyProxy(s);
    if (!ok) {
      s.vpnOn = false;
      _snack('هذا الجهاز لا يدعم تشغيل VPN داخل التطبيق');
    }
    await s.save();
    if (mounted) setState(() {});
    await _reload();
  }

  /// خادم مدخل يدوياً (إن كان لديك خادم خاص).
  Future<void> _editProxy() async {
    final s = settings!;
    final ctl = TextEditingController(text: s.auto ? '' : s.proxy);
    final res = await showDialog<String>(
      context: context,
      builder: (dc) => AlertDialog(
        title: const Text('خادم VPN يدوي'),
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
              'أمثلة: 1.2.3.4:8080 أو socks5://1.2.3.4:1080',
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
            child: const Text('حفظ وتشغيل'),
          ),
        ],
      ),
    );
    ctl.dispose();
    if (res == null || res.trim().isEmpty) return;
    s.proxy = res.trim();
    s.auto = false;
    s.proxies = [];
    s.vpnOn = true;
    await applyProxy(s);
    await s.save();
    if (mounted) setState(() {});
    await _reload();
  }

  /// عند تعطل الخادم الحالي: التبديل لبديل جاهز، وإلا عرض صفحة الخطأ.
  Future<void> _onMainFrameError() async {
    final s = settings;
    if (s == null) return;
    if (s.vpnOn && s.auto && s.proxies.isNotEmpty && !_busy) {
      _busy = true;
      try {
        s.proxy = s.proxies.removeAt(0);
        await applyProxy(s);
        await s.save();
        if (mounted) setState(() {});
        _snack('تبديل تلقائي إلى خادم آخر...');
        await web?.reload();
      } finally {
        _busy = false;
      }
      return;
    }
    if (mounted) setState(() => failed = true);
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
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
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
                  s.vpnOn
                      ? '${s.auto ? "تلقائي" : "يدوي"} • ${s.proxy}'
                      : 'يبحث عن أسرع خادم تلقائياً',
                  textAlign: TextAlign.start,
                ),
                value: s.vpnOn,
                onChanged: (v) async {
                  Navigator.pop(sheet);
                  await _setVpn(v);
                },
              ),
              ListTile(
                leading: const Icon(Icons.speed),
                title: const Text('البحث عن خادم أسرع'),
                onTap: () async {
                  Navigator.pop(sheet);
                  await _autoConnect();
                },
              ),
              ListTile(
                leading: const Icon(Icons.dns_outlined),
                title: const Text('إدخال خادم يدوياً'),
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
    );
  }

  /// زر الرجوع: يرجع في الموقع، وعند أول صفحة يطلب ضغطة ثانية للخروج.
  Future<void> _onBack() async {
    if (await web?.canGoBack() ?? false) {
      await web?.goBack();
      return;
    }
    final now = DateTime.now();
    if (_lastBack != null &&
        now.difference(_lastBack!) < const Duration(seconds: 2)) {
      SystemNavigator.pop();
      return;
    }
    _lastBack = now;
    _snack('اضغط رجوع مرة أخرى للخروج');
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
                  if (req.isForMainFrame ?? true) _onMainFrameError();
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
                  SystemChrome.setEnabledSystemUIMode(
                    SystemUiMode.immersiveSticky,
                  );
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
                  onVpn: () => s.vpnOn ? _autoConnect() : _setVpn(true),
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
                  ? 'الخادم الحالي لا يعمل. ابحث عن خادم جديد.'
                  : 'تحقق من الإنترنت، وإن كان الموقع محجوباً في بلدك فشغّل VPN.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white60),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              autofocus: true,
              onPressed: onVpn,
              icon: const Icon(Icons.vpn_lock_outlined),
              label: Text(vpnOn ? 'بحث عن خادم جديد' : 'تشغيل VPN'),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('إعادة المحاولة'),
            ),
          ],
        ),
      ),
    ),
  );
}
