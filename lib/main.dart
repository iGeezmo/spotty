// Huasifei WH3000 Remote — простое приложение для управления
// туристическим роутером Huasifei WH3000 (OpenWrt 25.12.5) через
// его собственный ubus JSON-RPC API (/ubus), точно тот же канал,
// что использует встроенный LuCI веб-интерфейс.
//
// Подтверждённый на живом роутере (read-only разведка 2026-09-23) контракт:
//   ubus object "opscx":
//     status()               -> {cellular{...}, tunnel{...}, wifi{...}, system{...}}
//     action({action:String}) -> action in {"restart_tunnel","reconnect_cellular"}
//   ubus object "system":
//     reboot()                -> стандартная перезагрузка OpenWrt
//   ubus object "session":
//     login({username,password,timeout}) -> ubus_rpc_session token
//
// Никакого отдельного метода "переключить VPN/напрямую" на роутере НЕТ —
// есть только restart_tunnel (перезапуск VPN-туннеля) и reconnect_cellular
// (перезапуск сотового интерфейса, эквивалент "перезапустить модем").
// Кнопка reboot использует общий ubus-объект system (учётка app имеет system.reboot
// в ACL huasifei-app), это НЕ отдельный метод opscx.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  runApp(const HuasifeiApp());
}

class HuasifeiApp extends StatelessWidget {
  const HuasifeiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Huasifei Remote',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF2E7D32),
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const RootGate(),
    );
  }
}

/// Хранилище учётных данных — Android EncryptedSharedPreferences
/// (через flutter_secure_storage), пароль никогда не пишется в открытом виде
/// на диск и не логируется.
class Credentials {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static const _kHost = 'router_host';
  static const _kUser = 'router_user';
  static const _kPass = 'router_pass';

  static Future<Map<String, String>?> load() async {
    final host = await _storage.read(key: _kHost);
    final user = await _storage.read(key: _kUser);
    final pass = await _storage.read(key: _kPass);
    if (host == null || pass == null) return null;
    return {'host': host, 'user': user ?? 'app', 'pass': pass};
  }

  static Future<void> save(String host, String user, String pass) async {
    await _storage.write(key: _kHost, value: host);
    await _storage.write(key: _kUser, value: user);
    await _storage.write(key: _kPass, value: pass);
  }

  static Future<void> clear() async {
    await _storage.deleteAll();
  }
}

/// Решает, показать экран ввода данных или сразу экран статуса.
class RootGate extends StatefulWidget {
  const RootGate({super.key});
  @override
  State<RootGate> createState() => _RootGateState();
}

class _RootGateState extends State<RootGate> {
  Map<String, String>? _creds;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final c = await Credentials.load();
    setState(() {
      _creds = c;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_creds == null) {
      return SetupScreen(onSaved: _load);
    }
    return MainShell(
      host: _creds!['host']!,
      user: _creds!['user']!,
      pass: _creds!['pass']!,
      onLogout: () async {
        await Credentials.clear();
        await _load();
      },
    );
  }
}

/// Экран однократного ввода адреса роутера и пароля приложения (логин app).
class SetupScreen extends StatefulWidget {
  final VoidCallback onSaved;
  const SetupScreen({super.key, required this.onSaved});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _hostCtrl = TextEditingController(text: '192.168.5.1');
  final _userCtrl = TextEditingController(text: 'app');
  final _passCtrl = TextEditingController();
  bool _checking = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Huasifei Remote — настройка')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Form(
            key: _formKey,
            child: ListView(
              children: [
                const Text(
                  'Укажите адрес роутера и пароль учётки приложения (логин app — отдельная учётка с доступом только к функциям приложения). '
                  'Данные хранятся только на этом телефоне в защищённом '
                  'хранилище Android и никуда, кроме роутера, не отправляются.',
                  style: TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 24),
                TextFormField(
                  controller: _hostCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Адрес роутера (IP)',
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Обязательное поле' : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _userCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Пользователь',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _passCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Пароль приложения',
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) =>
                      (v == null || v.isEmpty) ? 'Введите пароль' : null,
                ),
                const SizedBox(height: 24),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(_error!,
                        style: const TextStyle(color: Colors.redAccent)),
                  ),
                FilledButton(
                  onPressed: _checking ? null : _submit,
                  child: _checking
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Проверить и сохранить'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _checking = true;
      _error = null;
    });
    final host = _hostCtrl.text.trim();
    final user = _userCtrl.text.trim().isEmpty ? 'app' : _userCtrl.text.trim();
    final pass = _passCtrl.text;
    final client = RouterClient(host: host, user: user, pass: pass);
    try {
      await client.login();
    } on RouterAuthError {
      setState(() {
        _error = 'Неверный пароль или пользователь.';
        _checking = false;
      });
      return;
    } on RouterUnreachableError {
      setState(() {
        _error = 'Нет связи с роутером по адресу $host. Проверьте Wi-Fi '
            '(нужно быть подключённым к сети роутера) и адрес.';
        _checking = false;
      });
      return;
    } catch (e) {
      setState(() {
        _error = 'Не удалось подключиться: $e';
        _checking = false;
      });
      return;
    }
    await Credentials.save(host, user, pass);
    widget.onSaved();
  }
}

// ---------------------------------------------------------------------------
// Клиент ubus JSON-RPC (тот же протокол, что использует встроенный LuCI).
// ---------------------------------------------------------------------------

class RouterUnreachableError implements Exception {}

class RouterAuthError implements Exception {}

class RouterForbiddenError implements Exception {
  final String message;
  RouterForbiddenError(this.message);
}

class RouterClient {
  final String host;
  final String user;
  final String pass;
  String? _session;

  RouterClient({required this.host, required this.user, required this.pass});

  Uri get _endpoint => Uri.parse('http://$host/ubus');

  static const _anonymousSid = '00000000000000000000000000000000';

  Future<Map<String, dynamic>> _rpc(
      String sid, String object, String method, Map<String, dynamic> params) async {
    final body = jsonEncode({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'call',
      'params': [sid, object, method, params],
    });
    http.Response resp;
    try {
      resp = await http
          .post(_endpoint,
              headers: {'Content-Type': 'application/json'}, body: body)
          .timeout(const Duration(seconds: 6));
    } catch (_) {
      throw RouterUnreachableError();
    }
    if (resp.statusCode != 200) {
      throw RouterUnreachableError();
    }
    final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
    if (decoded.containsKey('error')) {
      throw RouterUnreachableError();
    }
    final result = decoded['result'] as List<dynamic>?;
    if (result == null || result.isEmpty) {
      throw RouterUnreachableError();
    }
    final code = result[0] as int;
    // ubus status codes: 0=OK, 6=ACCESS_DENIED, 5=NOT_FOUND ...
    if (code == 6) {
      throw RouterForbiddenError('Действие не разрешено роутером');
    }
    if (code != 0) {
      throw RouterUnreachableError();
    }
    return (result.length > 1 ? result[1] as Map<String, dynamic> : {});
  }

  Future<void> login() async {
    Map<String, dynamic> data;
    try {
      data = await _rpc(_anonymousSid, 'session', 'login',
          {'username': user, 'password': pass, 'timeout': 300});
    } on RouterForbiddenError {
      throw RouterAuthError();
    }
    final ubusId = data['ubus_rpc_session'] as String?;
    if (ubusId == null) {
      throw RouterAuthError();
    }
    _session = ubusId;
  }

  Future<T> _withSession<T>(Future<T> Function(String sid) fn) async {
    if (_session == null) {
      await login();
    }
    try {
      return await fn(_session!);
    } on RouterForbiddenError {
      // Сессия истекла — логинимся заново один раз.
      await login();
      return await fn(_session!);
    }
  }

  Future<Map<String, dynamic>> status() {
    return _withSession((sid) => _rpc(sid, 'opscx', 'status', {}));
  }

  /// action: "restart_tunnel" | "reconnect_cellular"
  Future<Map<String, dynamic>> action(String action) {
    return _withSession(
        (sid) => _rpc(sid, 'opscx', 'action', {'action': action}));
  }

  Future<void> reboot() {
    return _withSession((sid) => _rpc(sid, 'system', 'reboot', {}));
  }

  // -- Диагностика (opscx-diag, "Диагностика v4") --------------------------

  /// 7 слоёв сети (schema opscx.diag/1): каждый {id,name,state,reason,data},
  /// плюс общий вердикт {state,text} и ts (unix-время снятия диагностики).
  Future<Map<String, dynamic>> diagStatus() {
    return _withSession((sid) => _rpc(sid, 'opscx', 'diag_status', {}));
  }

  /// Запускает полный прогон диагностики на роутере (фоново).
  Future<Map<String, dynamic>> diagRun() {
    return _withSession((sid) => _rpc(sid, 'opscx', 'diag_run', {}));
  }

  // -- Подписка и узлы (vpnsub) ---------------------------------------------

  /// schema opscx.vpnsub-nodes/1: {selected, current, nodes:[...]}
  Future<Map<String, dynamic>> listNodes() {
    return _withSession((sid) => _rpc(sid, 'opscx', 'list_nodes', {}));
  }

  /// id — 12-символьный hex id узла, либо "auto" для автовыбора.
  Future<Map<String, dynamic>> selectNode(String id) {
    return _withSession(
        (sid) => _rpc(sid, 'opscx', 'select_node', {'id': id}));
  }

  /// Запускает синхронизацию/пробу всех подписок в фоне на роутере.
  Future<Map<String, dynamic>> refreshNow() {
    return _withSession((sid) => _rpc(sid, 'opscx', 'refresh_now', {}));
  }

  /// schema opscx.vpnsub-status/2: {interval_min, selected, current, decision, manifest, subs:[...]}
  Future<Map<String, dynamic>> vpnStatus() {
    return _withSession((sid) => _rpc(sid, 'opscx', 'get_status', {}));
  }

  /// url никогда не логируется и не сохраняется этим клиентом дольше вызова.
  Future<Map<String, dynamic>> setSubscription(
      String url, String label, int priority) {
    return _withSession((sid) => _rpc(sid, 'opscx', 'set_subscription',
        {'url': url, 'label': label, 'priority': priority}));
  }

  Future<Map<String, dynamic>> setInterval(int minutes) {
    return _withSession(
        (sid) => _rpc(sid, 'opscx', 'set_interval', {'minutes': minutes}));
  }
}

// ---------------------------------------------------------------------------
// Самообновление через GitHub Releases (iGeezmo/spotty). Полностью
// отделено от протокола роутера: своя сеть (интернет), своя ошибка —
// сбой самообновления никогда не должен ронять или блокировать основной
// функционал приложения.
// ---------------------------------------------------------------------------

class UpdateInfo {
  final int versionCode;
  final String versionName;
  final String url;
  final String sha256;
  final String notes;

  UpdateInfo({
    required this.versionCode,
    required this.versionName,
    required this.url,
    required this.sha256,
    required this.notes,
  });

  factory UpdateInfo.fromJson(Map<String, dynamic> j) => UpdateInfo(
        versionCode: j['version_code'] as int,
        versionName: j['version_name'] as String,
        url: j['url'] as String,
        sha256: (j['sha256'] as String).toLowerCase(),
        notes: j['notes'] as String? ?? '',
      );
}

/// Ошибка самообновления с понятным пользователю текстом (несовпадение
/// sha256, сетевая ошибка, ошибка установщика).
class UpdateException implements Exception {
  final String message;
  UpdateException(this.message);
  @override
  String toString() => message;
}

class UpdateService {
  static const _manifestUrl =
      'https://github.com/iGeezmo/spotty/releases/latest/download/version.json';

  static final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  static bool _notificationsReady = false;

  static Future<void> _initNotifications() async {
    if (_notificationsReady) return;
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _notifications.initialize(
        settings: const InitializationSettings(android: androidInit));
    _notificationsReady = true;
  }

  /// Без сети или при любой ошибке манифеста — тихо возвращает null.
  /// Самообновление никогда не показывает пользователю сетевые ошибки сам —
  /// только явная ручная проверка в "Настройках" отражает их.
  static Future<UpdateInfo?> checkForUpdate({bool silent = true}) async {
    try {
      final resp = await http
          .get(Uri.parse(_manifestUrl))
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return null;
      final info =
          UpdateInfo.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
      final current = await PackageInfo.fromPlatform();
      final currentCode = int.tryParse(current.buildNumber) ?? 0;
      if (info.versionCode <= currentCode) return null;
      return info;
    } catch (_) {
      if (silent) return null;
      rethrow;
    }
  }

  static Future<void> notifyUpdate(UpdateInfo info) async {
    try {
      await _initNotifications();
      const androidDetails = AndroidNotificationDetails(
        'spotty_updates',
        'Обновления Spotty',
        channelDescription: 'Уведомления о новых версиях Spotty',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
      );
      await _notifications.show(
        id: 1001,
        title: 'Доступно обновление Spotty ${info.versionName}',
        body: 'Откройте приложение и нажмите «Обновить» в Настройках.',
        notificationDetails: const NotificationDetails(android: androidDetails),
      );
    } catch (_) {
      // Уведомления — не критичны, баннер в приложении остаётся основным путём.
    }
  }

  /// Скачивает APK во временный каталог приложения, сверяет sha256 и
  /// открывает системный установщик (REQUEST_INSTALL_PACKAGES + FileProvider).
  /// Бросает [UpdateException] с понятным текстом при любой ошибке.
  static Future<void> downloadAndInstall(
    UpdateInfo info, {
    void Function(double progress)? onProgress,
  }) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/spotty-${info.versionName}.apk');
    http.StreamedResponse resp;
    try {
      resp = await http.Client()
          .send(http.Request('GET', Uri.parse(info.url)))
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw UpdateException('Нет сети — обновление отменено.');
    }
    if (resp.statusCode != 200) {
      throw UpdateException(
          'Сервер обновлений вернул ошибку ${resp.statusCode}.');
    }
    final total = resp.contentLength ?? 0;
    var received = 0;
    final sink = file.openWrite();
    try {
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call(received / total);
      }
    } catch (_) {
      await sink.close();
      throw UpdateException('Загрузка обновления прервалась — попробуйте ещё раз.');
    }
    await sink.close();
    final gotHash =
        sha256.convert(await file.readAsBytes()).toString().toLowerCase();
    if (gotHash != info.sha256) {
      await file.delete().catchError((_) => file);
      throw UpdateException(
          'Контрольная сумма файла не совпадает — установка отменена.');
    }
    final result = await OpenFilex.open(file.path,
        type: 'application/vnd.android.package-archive');
    if (result.type != ResultType.done) {
      throw UpdateException('Не удалось открыть установщик: ${result.message}');
    }
  }
}

// ---------------------------------------------------------------------------
// Общие вспомогательные функции экранов.
// ---------------------------------------------------------------------------

/// Цвет по состоянию слоя диагностики. "unknown"/отсутствующее состояние
/// — ВСЕГДА серое, никогда не зелёное (нет данных ≠ всё хорошо).
Color diagStateColor(String? state) {
  switch (state) {
    case 'ok':
      return Colors.green;
    case 'warn':
      return Colors.orange;
    case 'fail':
    case 'error':
      return Colors.red;
    default:
      return Colors.grey;
  }
}

IconData diagStateIcon(String? state) {
  switch (state) {
    case 'ok':
      return Icons.check_circle;
    case 'warn':
      return Icons.warning_amber;
    case 'fail':
    case 'error':
      return Icons.cancel;
    default:
      return Icons.help_outline;
  }
}

String fmtAgeShort(int? unixTs) {
  if (unixTs == null || unixTs <= 0) return 'нет данных';
  final ageS = DateTime.now().millisecondsSinceEpoch ~/ 1000 - unixTs;
  if (ageS < 0) return 'только что';
  if (ageS < 60) return '$ageS с назад';
  if (ageS < 3600) return '${ageS ~/ 60} мин назад';
  return '${ageS ~/ 3600} ч назад';
}

// ---------------------------------------------------------------------------
// Экран статуса.
// ---------------------------------------------------------------------------

/// Оболочка с нижней навигацией: Главная / Сеть / Узлы / Подписки.
/// Один RouterClient (и одна ubus-сессия) на все вкладки.
class MainShell extends StatefulWidget {
  final String host;
  final String user;
  final String pass;
  final VoidCallback onLogout;

  const MainShell({
    super.key,
    required this.host,
    required this.user,
    required this.pass,
    required this.onLogout,
  });

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  late final RouterClient _client;
  int _tab = 0;
  UpdateInfo? _update;
  Timer? _updateTimer;

  @override
  void initState() {
    super.initState();
    _client =
        RouterClient(host: widget.host, user: widget.user, pass: widget.pass);
    _checkUpdate();
    _updateTimer =
        Timer.periodic(const Duration(hours: 6), (_) => _checkUpdate());
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    super.dispose();
  }

  Future<void> _checkUpdate() async {
    final info = await UpdateService.checkForUpdate();
    if (!mounted) return;
    if (info != null &&
        (_update == null || info.versionCode != _update!.versionCode)) {
      unawaited(UpdateService.notifyUpdate(info));
    }
    setState(() => _update = info);
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      HomeTab(client: _client, host: widget.host, onLogout: widget.onLogout),
      NetworkTab(client: _client),
      NodesTab(client: _client),
      SubscriptionsTab(client: _client),
      SettingsTab(update: _update, onRecheck: _checkUpdate),
    ];
    return Scaffold(
      body: Column(
        children: [
          if (_update != null)
            _UpdateBanner(
              update: _update!,
              onTap: () => setState(() => _tab = 4),
            ),
          Expanded(child: IndexedStack(index: _tab, children: pages)),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home), label: 'Главная'),
          NavigationDestination(
              icon: Icon(Icons.network_check), label: 'Сеть'),
          NavigationDestination(icon: Icon(Icons.hub), label: 'Узлы'),
          NavigationDestination(
              icon: Icon(Icons.subscriptions), label: 'Подписки'),
          NavigationDestination(
              icon: Icon(Icons.settings), label: 'Настройки'),
        ],
      ),
    );
  }
}

class _UpdateBanner extends StatelessWidget {
  final UpdateInfo update;
  final VoidCallback onTap;
  const _UpdateBanner({required this.update, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.green.shade900,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              const Icon(Icons.system_update, color: Colors.white),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Доступно обновление ${update.versionName} — открыть в «Настройках»',
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Настройки: версия приложения, ручная проверка и установка обновлений.
// ---------------------------------------------------------------------------

class SettingsTab extends StatefulWidget {
  final UpdateInfo? update;
  final Future<void> Function() onRecheck;
  const SettingsTab({super.key, required this.update, required this.onRecheck});

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  PackageInfo? _pkg;
  bool _checking = false;
  bool _installing = false;
  double _progress = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadPkg();
  }

  Future<void> _loadPkg() async {
    final p = await PackageInfo.fromPlatform();
    if (mounted) setState(() => _pkg = p);
  }

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      await widget.onRecheck();
      if (mounted && widget.update == null) {
        setState(() => _error = null);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Обновлений не найдено')));
        }
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _install() async {
    final info = widget.update;
    if (info == null) return;
    setState(() {
      _installing = true;
      _progress = 0;
      _error = null;
    });
    try {
      await UpdateService.downloadAndInstall(info, onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      });
    } on UpdateException catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } catch (e) {
      if (mounted) setState(() => _error = 'Ошибка обновления: $e');
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pkg = _pkg;
    final update = widget.update;
    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Spotty by 0dai',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(
              pkg == null
                  ? 'Версия: …'
                  : 'Версия: ${pkg.version} (сборка ${pkg.buildNumber})',
              style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 24),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child:
                  Text(_error!, style: const TextStyle(color: Colors.redAccent)),
            ),
          if (update != null) ...[
            Card(
              color: Colors.green.shade900,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Доступна версия ${update.versionName}',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, color: Colors.white)),
                    if (update.notes.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(update.notes,
                            style: const TextStyle(color: Colors.white70)),
                      ),
                    const SizedBox(height: 12),
                    if (_installing)
                      LinearProgressIndicator(
                          value: _progress > 0 ? _progress : null)
                    else
                      FilledButton(
                          onPressed: _install, child: const Text('Обновить')),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
          OutlinedButton.icon(
            onPressed: _checking ? null : _check,
            icon: _checking
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
            label: const Text('Проверить обновления'),
          ),
        ],
      ),
    );
  }
}

/// Общий базовый класс для вкладок с ошибкой/занятостью/подтверждением —
/// избегает дублирования кода между Сеть/Узлы/Подписки.
abstract class _TabState<T extends StatefulWidget> extends State<T> {
  String? error;
  bool busy = false;

  Future<void> confirmAndRun(BuildContext context, String title, String body,
      Future<void> Function() run, {VoidCallback? onDone}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Подтвердить')),
        ],
      ),
    );
    if (ok != true) return;
    await runGuarded(run, onDone: onDone, notify: true);
  }

  Future<void> runGuarded(Future<void> Function() run,
      {VoidCallback? onDone, bool notify = false}) async {
    if (!mounted) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await run();
      if (mounted && notify) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Команда отправлена на роутер')));
      }
    } on RouterAuthError {
      if (mounted) setState(() => error = 'Неверный пароль.');
    } on RouterUnreachableError {
      if (mounted) setState(() => error = 'Нет связи с роутером.');
    } on RouterForbiddenError catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (e) {
      if (mounted) setState(() => error = 'Ошибка: $e');
    } finally {
      if (mounted) setState(() => busy = false);
      onDone?.call();
    }
  }

  Widget errorBanner() {
    if (error == null) return const SizedBox.shrink();
    return Card(
      color: Colors.red.shade900,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text(error!, style: const TextStyle(color: Colors.white)),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Главная: крупно VPN/напрямую, узел, выход, вердикт диагностики.
// ---------------------------------------------------------------------------

class HomeTab extends StatefulWidget {
  final RouterClient client;
  final String host;
  final VoidCallback onLogout;
  const HomeTab(
      {super.key, required this.client, required this.host, required this.onLogout});

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends _TabState<HomeTab> {
  Timer? _timer;
  Map<String, dynamic>? _status;
  Map<String, dynamic>? _diag;
  Map<String, dynamic>? _nodes;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final s = await widget.client.status();
      Map<String, dynamic>? d;
      Map<String, dynamic>? n;
      try {
        d = await widget.client.diagStatus();
      } catch (_) {}
      try {
        n = await widget.client.listNodes();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _status = s;
        _diag = d;
        _nodes = n;
        error = null;
      });
    } on RouterAuthError {
      if (!mounted) return;
      setState(() => error = 'Неверный пароль. Выйдите и введите заново.');
    } on RouterUnreachableError {
      if (!mounted) return;
      setState(() => error = 'Нет связи с роутером.');
    } on RouterForbiddenError catch (e) {
      if (!mounted) return;
      setState(() => error = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => error = 'Ошибка: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final tunnel = _status?['tunnel'] as Map<String, dynamic>?;
    final vpnReady = tunnel?['ready'] == true;
    final egress = tunnel?['external_address'] as String?;
    final nodes = (_nodes?['nodes'] as List?) ?? const [];
    final currentId = _nodes?['current'] as String?;
    Map<String, dynamic>? currentNode;
    for (final n in nodes) {
      final m = n as Map<String, dynamic>;
      if (m['id'] == currentId) currentNode = m;
    }
    final nodeName = currentNode == null
        ? '—'
        : cleanNodeName((currentNode['meta']
                as Map<String, dynamic>?)?['name'] as String? ??
            '');
    final verdict = (_diag?['verdict'] as Map<String, dynamic>?);
    final verdictState = verdict?['state'] as String?;
    final verdictText = verdict?['text'] as String? ?? 'нет данных';

    return Scaffold(
      appBar: AppBar(
        title: Text('Huasifei WH3000 — ${widget.host}'),
        actions: [
          IconButton(
              onPressed: widget.onLogout,
              icon: const Icon(Icons.logout),
              tooltip: 'Сменить роутер / пароль'),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            errorBanner(),
            Card(
              color: vpnReady ? Colors.green.shade900 : Colors.orange.shade900,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(vpnReady ? Icons.lock : Icons.lock_open,
                            size: 36, color: Colors.white),
                        const SizedBox(width: 12),
                        Text(
                          vpnReady ? 'VPN' : 'Напрямую',
                          style: const TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.bold,
                              color: Colors.white),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text('Узел: $nodeName',
                        style: const TextStyle(color: Colors.white70)),
                    Text('Выход: ${egress ?? 'нет данных'}',
                        style: const TextStyle(color: Colors.white70)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                leading:
                    Icon(diagStateIcon(verdictState), color: diagStateColor(verdictState)),
                title: const Text('Диагностика сети'),
                subtitle: Text(verdictText),
              ),
            ),
            const SizedBox(height: 24),
            const Text('Действия', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: busy
                  ? null
                  : () => confirmAndRun(
                        context,
                        'Перезапустить VPN-туннель?',
                        'Роутер попробует перезапустить VPN-туннель '
                            '(restart_tunnel). На части прошивок этот шаг '
                            'может ничего не менять — это ограничение самого '
                            'роутера, не приложения.',
                        () => widget.client.action('restart_tunnel'),
                        onDone: _refresh,
                      ),
              icon: const Icon(Icons.vpn_key),
              label: const Text('Перезапустить VPN-туннель'),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: busy
                  ? null
                  : () => confirmAndRun(
                        context,
                        'Перезапустить модем/сотовую связь?',
                        'Роутер отключит и заново поднимет сотовое '
                            'соединение (reconnect_cellular). Интернет '
                            'пропадёт на несколько секунд.',
                        () => widget.client.action('reconnect_cellular'),
                        onDone: _refresh,
                      ),
              icon: const Icon(Icons.settings_input_antenna),
              label: const Text('Перезапустить модем'),
            ),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              onPressed: busy
                  ? null
                  : () => confirmAndRun(
                        context,
                        'Перезагрузить роутер?',
                        'Роутер полностью перезагрузится, Wi-Fi пропадёт на '
                            '1-2 минуты.',
                        () => widget.client.reboot(),
                        onDone: _refresh,
                      ),
              icon: const Icon(Icons.power_settings_new),
              label: const Text('Перезагрузить роутер'),
              style: FilledButton.styleFrom(backgroundColor: Colors.red.shade900),
            ),
            if (busy)
              const Padding(
                padding: EdgeInsets.only(top: 16),
                child: Center(child: CircularProgressIndicator()),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Сеть: 7 слоёв диагностики (opscx-diag) + сводка status().
// ---------------------------------------------------------------------------

class NetworkTab extends StatefulWidget {
  final RouterClient client;
  const NetworkTab({super.key, required this.client});

  @override
  State<NetworkTab> createState() => _NetworkTabState();
}

class _NetworkTabState extends _TabState<NetworkTab> {
  Timer? _timer;
  Map<String, dynamic>? _status;
  Map<String, dynamic>? _diag;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    await runGuarded(() async {
      final s = await widget.client.status();
      final d = await widget.client.diagStatus();
      if (!mounted) return;
      setState(() {
        _status = s;
        _diag = d;
      });
    });
  }

  String _fmtUptime(int seconds) {
    final d = seconds ~/ 86400;
    final h = (seconds % 86400) ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final parts = <String>[];
    if (d > 0) parts.add('${d}д');
    if (h > 0) parts.add('${h}ч');
    parts.add('${m}м');
    return parts.join(' ');
  }

  @override
  Widget build(BuildContext context) {
    final cellular = _status?['cellular'] as Map<String, dynamic>?;
    final wifi = _status?['wifi'] as Map<String, dynamic>?;
    final sys = _status?['system'] as Map<String, dynamic>?;

    final verdict = _diag?['verdict'] as Map<String, dynamic>?;
    final verdictState = verdict?['state'] as String?;
    final verdictText = verdict?['text'] as String? ?? 'нет данных';
    final layers = (_diag?['layers'] as List?) ?? const [];
    final diagTs = _diag?['ts'] as int?;

    return Scaffold(
      appBar: AppBar(title: const Text('Сеть')),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            errorBanner(),
            Card(
              color: diagStateColor(verdictState).withOpacity(0.18),
              child: ListTile(
                leading: Icon(diagStateIcon(verdictState),
                    color: diagStateColor(verdictState), size: 32),
                title: Text(verdictText,
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text('Снято: ${fmtAgeShort(diagTs)}'),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: busy
                  ? null
                  : () => confirmAndRun(
                        context,
                        'Запустить полную диагностику?',
                        'Роутер прогонит 7 слоёв проверки сети заново '
                            '(diag_run). Это займёт 10-15 секунд.',
                        () => widget.client.diagRun(),
                        onDone: () =>
                            Future.delayed(const Duration(seconds: 3), _refresh),
                      ),
              icon: const Icon(Icons.troubleshoot),
              label: const Text('Полная диагностика'),
            ),
            const SizedBox(height: 16),
            const Text('7 слоёв', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            if (layers.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('Нет данных диагностики.', style: TextStyle(color: Colors.white70)),
              ),
            for (final raw in layers)
              Builder(builder: (_) {
                final l = raw as Map<String, dynamic>;
                final state = l['state'] as String?;
                return Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    leading: Icon(diagStateIcon(state), color: diagStateColor(state)),
                    title: Text('${l['id']}. ${l['name'] ?? '—'}'),
                    subtitle: Text(
                        '${l['reason'] ?? 'нет данных'}\nВозраст: ${fmtAgeShort(diagTs)}'),
                    isThreeLine: true,
                  ),
                );
              }),
            const SizedBox(height: 24),
            const Text('Сводка', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            _StatusCard(
              icon: Icons.sim_card,
              iconColor: Colors.blueGrey,
              title: 'Сотовая связь (модем ${cellular?['modem'] ?? '—'})',
              value: cellular == null
                  ? '—'
                  : 'Интерфейс ${cellular['device'] ?? '—'}, '
                      'аптайм ${_fmtUptime((cellular['uptime'] ?? 0) as int)}',
            ),
            _StatusCard(
              icon: Icons.wifi,
              iconColor: Colors.indigo,
              title: 'Wi-Fi',
              value: wifi == null
                  ? '—'
                  : '${wifi['ssid'] ?? '—'}, устройств: ${wifi['clients'] ?? 0}',
            ),
            _StatusCard(
              icon: Icons.router,
              iconColor: Colors.grey,
              title: 'Модель / прошивка',
              value: sys == null
                  ? '—'
                  : '${sys['board'] ?? '—'}\n${sys['release'] ?? ''}',
            ),
          ],
        ),
      ),
    );
  }
}

/// Имя узла из недоверенного provider `remarks`: убираем эмодзи-баннеры,
/// но сохраняем один ведущий флаг (regional-indicator пара), если есть.
String cleanNodeName(String raw) {
  if (raw.isEmpty) return '—';
  final flagMatch = RegExp(r'^\s*([\u{1F1E6}-\u{1F1FF}]{2})', unicode: true)
      .firstMatch(raw);
  final flag = flagMatch?.group(1);
  var rest = raw
      .replaceAll(RegExp(r'\[[^\]]*\]'), '')
      .replaceAll(
          RegExp(r'[\u{1F1E6}-\u{1F1FF}\u{200D}\u{FE0F}\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]',
              unicode: true),
          '')
      .trim();
  rest = rest.replaceAll(RegExp(r'\s+'), ' ');
  if (rest.isEmpty) rest = raw.trim();
  return flag == null ? rest : '$flag $rest';
}

// ---------------------------------------------------------------------------
// Узлы: список из list_nodes, select_node, Авто/Ручной, "Проверить узлы".
// ---------------------------------------------------------------------------

class NodesTab extends StatefulWidget {
  final RouterClient client;
  const NodesTab({super.key, required this.client});

  @override
  State<NodesTab> createState() => _NodesTabState();
}

class _NodesTabState extends _TabState<NodesTab> {
  Timer? _timer;
  Map<String, dynamic>? _nodes;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 20), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    await runGuarded(() async {
      final n = await widget.client.listNodes();
      if (!mounted) return;
      setState(() => _nodes = n);
    });
  }

  String _flagFromLoc(String? loc) {
    if (loc == null || loc.length != 2 || loc == 'XX') return '🏳️';
    final base = 0x1F1E6;
    final cc = loc.toUpperCase();
    final a = base + (cc.codeUnitAt(0) - 'A'.codeUnitAt(0));
    final b = base + (cc.codeUnitAt(1) - 'A'.codeUnitAt(0));
    return String.fromCharCode(a) + String.fromCharCode(b);
  }

  @override
  Widget build(BuildContext context) {
    final selected = _nodes?['selected'] as String?; // "auto" | id узла
    final currentId = _nodes?['current'] as String?;
    final isAuto = selected == 'auto' || selected == null;
    final nodes = ((_nodes?['nodes'] as List?) ?? const [])
        .cast<Map<String, dynamic>>()
        .toList()
      ..sort((a, b) {
        final okA = (a['probe_ok'] as int?) ?? 0;
        final okB = (b['probe_ok'] as int?) ?? 0;
        if (a['id'] == currentId) return -1;
        if (b['id'] == currentId) return 1;
        return okB.compareTo(okA);
      });

    return Scaffold(
      appBar: AppBar(title: const Text('Узлы')),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            errorBanner(),
            Card(
              child: SwitchListTile(
                title: const Text('Автовыбор узла'),
                subtitle: Text(isAuto
                    ? 'Роутер сам выбирает лучший узел'
                    : 'Узел закреплён вручную'),
                value: isAuto,
                onChanged: busy
                    ? null
                    : (v) => runGuarded(
                        () => widget.client.selectNode(v ? 'auto' : (currentId ?? 'auto')),
                        onDone: _refresh),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: busy ? null : () => runGuarded(() => widget.client.refreshNow(), onDone: () => Future.delayed(const Duration(seconds: 2), _refresh), notify: true),
              icon: const Icon(Icons.refresh),
              label: const Text('Проверить узлы'),
            ),
            const SizedBox(height: 16),
            if (nodes.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('Список узлов пуст.', style: TextStyle(color: Colors.white70)),
              ),
            for (final n in nodes)
              Builder(builder: (_) {
                final meta = n['meta'] as Map<String, dynamic>? ?? const {};
                final id = n['id'] as String;
                final isCurrent = id == currentId;
                final probeOk = (n['probe_ok'] as int?) ?? 0;
                final of = (n['of'] as int?) ?? 10;
                final medianMs = (n['median_ms'] as int?) ?? 99999;
                final egress = n['egress'] as String? ?? '-';
                final loc = n['loc'] as String?;
                final name = cleanNodeName(meta['name'] as String? ?? '');
                final alive = probeOk > 0;
                return Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  color: isCurrent ? Colors.green.shade900.withOpacity(0.3) : null,
                  child: ListTile(
                    leading: Text(_flagFromLoc(loc), style: const TextStyle(fontSize: 22)),
                    title: Text('$name — ${meta['host'] ?? '?'}'),
                    subtitle: Text(
                        '${meta['transport'] ?? '?'} · проба $probeOk/$of · '
                        '${medianMs >= 99999 ? '—' : '$medianMs мс'} · выход: $egress'
                        '${isCurrent ? '\n★ текущий' : ''}'),
                    isThreeLine: true,
                    trailing: isCurrent
                        ? const Icon(Icons.star, color: Colors.amber)
                        : TextButton(
                            onPressed: !alive || busy
                                ? null
                                : () => runGuarded(() => widget.client.selectNode(id),
                                    onDone: _refresh, notify: true),
                            child: const Text('Выбрать'),
                          ),
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Подписки: get_status, "Обновить все", "Заменить ссылку" (set_subscription),
// период обновления (set_interval).
// ---------------------------------------------------------------------------

class SubscriptionsTab extends StatefulWidget {
  final RouterClient client;
  const SubscriptionsTab({super.key, required this.client});

  @override
  State<SubscriptionsTab> createState() => _SubscriptionsTabState();
}

class _SubscriptionsTabState extends _TabState<SubscriptionsTab> {
  Timer? _timer;
  Map<String, dynamic>? _status;
  final _urlCtrl = TextEditingController();
  final _labelCtrl = TextEditingController();
  final _intervalCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 20), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _urlCtrl.dispose();
    _labelCtrl.dispose();
    _intervalCtrl.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    await runGuarded(() async {
      final s = await widget.client.vpnStatus();
      if (!mounted) return;
      setState(() {
        _status = s;
        _intervalCtrl.text = '${s['interval_min'] ?? 30}';
      });
    });
  }

  String _fmtTs(int? ts) {
    if (ts == null || ts == 0) return 'нет данных';
    final dt = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(dt.day)}.${two(dt.month)} ${two(dt.hour)}:${two(dt.minute)}';
  }

  Future<void> _replaceUrl() async {
    final url = _urlCtrl.text.trim();
    if (!url.startsWith('https://')) {
      setState(() => error = 'Ссылка должна начинаться с https://');
      return;
    }
    final label = _labelCtrl.text.trim().isEmpty ? 'sub' : _labelCtrl.text.trim();
    await runGuarded(() async {
      await widget.client.setSubscription(url, label, 5);
      // Значение никогда не остаётся в памяти виджета дольше вызова.
      _urlCtrl.clear();
    }, onDone: () => Future.delayed(const Duration(seconds: 2), _refresh), notify: true);
  }

  Future<void> _saveInterval() async {
    final minutes = int.tryParse(_intervalCtrl.text.trim());
    if (minutes == null || minutes < 5 || minutes > 1440) {
      setState(() => error = 'Период — целое число минут, 5-1440');
      return;
    }
    await runGuarded(() => widget.client.setInterval(minutes), onDone: _refresh, notify: true);
  }

  @override
  Widget build(BuildContext context) {
    final subs = ((_status?['subs'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final manifest = _status?['manifest'] as Map<String, dynamic>?;
    final selected = _status?['selected'] as String?;

    return Scaffold(
      appBar: AppBar(title: const Text('Подписки')),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            errorBanner(),
            for (final s in subs)
              Card(
                child: ListTile(
                  leading: Icon(
                      (s['result'] == 'ok') ? Icons.check_circle : Icons.error,
                      color: (s['result'] == 'ok') ? Colors.green : Colors.red),
                  title: Text(s['label'] as String? ?? '—'),
                  subtitle: Text('Отпечаток: ${s['url_sha12'] ?? '—'}\n'
                      'Обновлено: ${_fmtTs(s['last_ok'] as int?)}\n'
                      'Приоритет: ${s['priority'] ?? '—'}'),
                  isThreeLine: true,
                ),
              ),
            Card(
              child: ListTile(
                leading: const Icon(Icons.hub, color: Colors.indigo),
                title: const Text('Узлы'),
                subtitle: Text('Режим: ${selected == 'auto' || selected == null ? 'Авто' : 'Ручной'}\n'
                    'Текущий материал: ${manifest?['node'] ?? '—'}'),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: busy
                  ? null
                  : () => runGuarded(() => widget.client.refreshNow(),
                      onDone: () => Future.delayed(const Duration(seconds: 2), _refresh),
                      notify: true),
              icon: const Icon(Icons.sync),
              label: const Text('Обновить все'),
            ),
            const SizedBox(height: 24),
            const Text('Заменить ссылку', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            const Text(
                'Ссылка нигде не логируется и не показывается обратно — '
                'только отпечаток (sha12) выше, после обновления.',
                style: TextStyle(color: Colors.white70, fontSize: 12)),
            const SizedBox(height: 8),
            TextField(
              controller: _labelCtrl,
              decoration: const InputDecoration(
                  labelText: 'Название подписки', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _urlCtrl,
              obscureText: true,
              autocorrect: false,
              decoration: const InputDecoration(
                  labelText: 'Ссылка подписки (https://...)',
                  border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: busy ? null : _replaceUrl,
              child: const Text('Заменить ссылку'),
            ),
            const SizedBox(height: 24),
            const Text('Период обновления (минуты, 5–1440)',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _intervalCtrl,
                    keyboardType: TextInputType.number,
                    decoration:
                        const InputDecoration(border: OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: busy ? null : _saveInterval,
                  child: const Text('Сохранить'),
                ),
              ],
            ),
            if (busy)
              const Padding(
                padding: EdgeInsets.only(top: 16),
                child: Center(child: CircularProgressIndicator()),
              ),
          ],
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String value;

  const _StatusCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: Icon(icon, color: iconColor),
        title: Text(title),
        subtitle: Text(value),
      ),
    );
  }
}
