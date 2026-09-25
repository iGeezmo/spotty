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

import 'toolbox/screens.dart';

void main() {
  runApp(const HuasifeiApp());
}

/// Мок-режим для скриншотов B2 (390×844): не трогает сеть/хранилище, сразу
/// показывает MainShell с MockRouterClient. Никогда не включён в релиз —
/// tool/release.sh не передаёт этот define, значение по умолчанию false.
const kScreenshotMock = bool.fromEnvironment('SCREENSHOT_MOCK');

// ---------------------------------------------------------------------------
// Бренд Spotty by 0dai — своя палитра (индиго + бирюзовый акцент «пятно»),
// светлая и тёмная тема, следует системной настройке.
// ---------------------------------------------------------------------------
const _brandSeed = Color(0xFF5B6EF5);

final _darkScheme = ColorScheme.fromSeed(
  seedColor: _brandSeed,
  brightness: Brightness.dark,
).copyWith(
  tertiary: const Color(0xFF00D9B4),
  secondary: const Color(0xFFFF8A3D),
);

final _lightScheme = ColorScheme.fromSeed(
  seedColor: _brandSeed,
  brightness: Brightness.light,
).copyWith(
  tertiary: const Color(0xFF00877A),
  secondary: const Color(0xFFC9601A),
);

ThemeData _spottyTheme(Brightness brightness) => ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: brightness == Brightness.dark ? _darkScheme : _lightScheme,
      scaffoldBackgroundColor: brightness == Brightness.dark
          ? const Color(0xFF0E1016)
          : const Color(0xFFF4F5FA),
      cardTheme: const CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(20))),
      ),
      dividerColor:
          brightness == Brightness.dark ? Colors.white12 : Colors.black12,
    );

class HuasifeiApp extends StatelessWidget {
  const HuasifeiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Spotty by 0dai',
      debugShowCheckedModeBanner: false,
      theme: _spottyTheme(Brightness.light),
      darkTheme: _spottyTheme(Brightness.dark),
      themeMode: ThemeMode.system,
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
    if (kScreenshotMock) {
      setState(() {
        _creds = {'host': '192.168.5.1', 'user': 'app', 'pass': 'mock'};
        _loading = false;
      });
      return;
    }
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

/// ubus-объект/метод существует в ACL, но rpcd не отдаёт для него сигнатуру
/// (ubus code 3/8, или JSON-RPC error -32000 "Object not found") — т.е. это
/// НЕ проблема пароля/ACL/сети, а рассинхрон бэкенда на роутере. Показываем
/// явно, а не тихо глотаем как "нет данных".
class RouterMethodUnavailableError implements Exception {
  final String message;
  RouterMethodUnavailableError(this.message);
}

class RouterClient {
  final String host;
  final String user;
  final String pass;
  final bool mock;
  String? _session;

  RouterClient(
      {required this.host,
      required this.user,
      required this.pass,
      this.mock = false});

  Uri get _endpoint => Uri.parse('http://$host/ubus');

  static const _anonymousSid = '00000000000000000000000000000000';

  /// Мок-данные для скриншотов (kScreenshotMock) — никогда не используется
  /// вне мок-режима, никогда не идёт в сеть.
  Map<String, dynamic> _mockRpc(String object, String method, Map<String, dynamic> params) {
    if (object == 'session' && method == 'login') {
      return {'ubus_rpc_session': 'mockmockmockmockmockmockmockmock'};
    }
    if (object == 'opscx' && method == 'status') {
      return {
        'cellular': {'up': true, 'uptime': 345600, 'device': 'eth2', 'modem': 'FM350', 'rx_bytes': 0, 'tx_bytes': 0},
        'tunnel': {
          'ready': true,
          'external_address': '178.62.14.9',
          'updated_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 - 18,
          'valid_until': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 22,
        },
        'wifi': {'ssid': 'HUASIFEI-5G', 'clients': 4},
        'system': {'board': 'Huasifei WH3000 Pro', 'release': '25.12.5'},
      };
    }
    if (object == 'opscx' && method == 'diag_status') {
      return {
        'ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'verdict': {'state': 'warn', 'text': 'Сеть работает, но слой DNS отвечает медленно'},
        'layers': [
          {'id': 1, 'name': 'Сотовая сеть', 'state': 'ok', 'reason': 'на связи · LTE B7 · RSRP -94 дБм (средне)', 'data': {'radio': {'rat': 'LTE', 'band': 'B7', 'rsrp_dbm': -94, 'rsrq_db': -8, 'sinr_raw': 15}}},
          {'id': 2, 'name': 'IP по сотовой сети', 'state': 'ok', 'reason': 'Адрес получен'},
          {'id': 3, 'name': 'DNS', 'state': 'warn', 'reason': 'Ответ за 640 мс'},
          {'id': 4, 'name': 'VPN-туннель', 'state': 'ok', 'reason': 'Установлен'},
          {'id': 5, 'name': 'Маршрут через VPN', 'state': 'ok', 'reason': 'Весь трафик через туннель'},
          {'id': 6, 'name': 'Проверка вовне', 'state': 'ok', 'reason': 'Отвечает'},
          {'id': 7, 'name': 'Проверка закрытых сайтов', 'state': 'unknown', 'reason': 'нет данных'},
        ],
      };
    }
    if (object == 'opscx' && method == 'list_nodes') {
      return {
        'selected': 'de23',
        'current': 'de23',
        'nodes': [
          {'id': 'de23', 'meta': {'name': '🇩🇪 Anti-Block LTE #1', 'host': 'de23.example'}, 'probe_ok': 10, 'of': 10, 'median_ms': 74, 'egress': '178.62.14.9', 'loc': 'DE'},
          {'id': 'nl03', 'meta': {'name': '🇳🇱 Anti-Block LTE #3', 'host': 'nl03.example'}, 'probe_ok': 10, 'of': 10, 'median_ms': 61, 'egress': '178.62.10.2', 'loc': 'NL'},
          {'id': 'fi07', 'meta': {'name': '🇫🇮 Anti-Block LTE #7', 'host': 'fi07.example'}, 'probe_ok': 9, 'of': 10, 'median_ms': 88, 'egress': '81.4.5.6', 'loc': 'FI'},
        ],
      };
    }
    if (object == 'opscx' && method == 'get_status') {
      return {
        'interval_min': 30,
        'selected': 'de23',
        'manifest': {'node': 'de23'},
        'subs': [
          {'label': 'sub', 'url_sha12': 'abc123', 'last_ok': DateTime.now().millisecondsSinceEpoch ~/ 1000, 'priority': 5, 'result': 'ok'},
        ],
      };
    }
    if (object == 'opscx' && method == 'metrics_history') {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      return {
        'points': List.generate(12, (i) {
          final t = now - (11 - i) * 30;
          return {
            't': t,
            'rsrp': -95 + (i % 4),
            'rsrq': -9 + (i % 2),
            'sinr': 12 + (i % 3),
            'band': 'B7',
            'ping_ms': i == 5 ? null : 55.0 - i,
            'vpn': true,
            'clients': 4,
            'probe_fail_pct': 18 - (i % 5),
          };
        }),
      };
    }
    if (object == 'system' && method == 'reboot') return {};
    if (object == 'opscx' && (method == 'action' || method == 'select_node' || method == 'refresh_now' || method == 'set_subscription' || method == 'set_interval')) {
      return {};
    }
    if (object == 'spotty' && method == 'devices') {
      return {
        'schema': 'spotty.devices/1',
        'updated_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'devices': [
          {'mac_masked': '10:16:b1:**:**:f7', 'ip': '192.168.5.242', 'hostname': 'OPPO-Find-N6', 'link': 'wifi', 'band': '5g', 'signal_dbm': -70, 'rx_bytes': 3175845, 'tx_bytes': 9146639, 'source': 'hostapd'},
          {'mac_masked': 'c6:25:c1:**:**:5e', 'ip': '192.168.5.170', 'hostname': 'OWWE261', 'link': 'wifi', 'band': '5g', 'signal_dbm': -58, 'rx_bytes': 842112, 'tx_bytes': 190044, 'source': 'hostapd'},
          {'mac_masked': 'a4:83:e7:**:**:01', 'ip': '192.168.5.88', 'hostname': null, 'link': 'lan', 'band': null, 'signal_dbm': null, 'rx_bytes': 55210, 'tx_bytes': 0, 'source': 'conntrack'},
        ],
        'stale': false,
      };
    }
    if (object == 'spotty' && method == 'guest_status') {
      return {'schema': 'spotty.guest/1', 'supported': true, 'enabled': false, 'ssid': 'Huasifei-Guest', 'configured': true};
    }
    if (object == 'spotty' && method == 'guest_set') {
      return {'accepted': true, 'enabled': params['enabled'], 'error': null};
    }
    if (object == 'spotty' && method == 'guest_qr') {
      return {'accepted': true, 'ssid': 'Huasifei-Guest', 'qr': 'WIFI:T:WPA;S:Huasifei-Guest;P:mockmockmock01;;', 'error': null};
    }
    if (object == 'spotty' && method == 'guest_rotate') {
      return {'accepted': true, 'error': null};
    }
    if (object == 'spotty' && method == 'events') {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      return {
        'schema': 'spotty.events/1',
        'updated_at': now,
        'events': [
          {'ts': now - 4, 'tag': 'mode', 'text': 'LED_TICK vpn'},
          {'ts': now - 40, 'tag': 'cellular', 'text': 'FM350_TICK ready'},
          {'ts': now - 95, 'tag': 'hold', 'text': 'WORKER_HOLD VPN_UNVERIFIED'},
          {'ts': now - 200, 'tag': 'worker', 'text': 'WORKER_TICK vpn healthy'},
          {'ts': now - 610, 'tag': 'diag', 'text': 'opscx-diag: 6/7 слоёв ok'},
        ],
        'stale': false,
      };
    }
    if (object == 'spotty' && method == 'set_mode') {
      return {'accepted': true, 'requested_mode': params['mode'], 'error': null};
    }
    return {};
  }

  Future<Map<String, dynamic>> _rpc(
      String sid, String object, String method, Map<String, dynamic> params) async {
    if (mock) {
      await Future.delayed(const Duration(milliseconds: 30));
      return _mockRpc(object, method, params);
    }
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
      // uhttpd-mod-ubus проверяет сессию/ACL ДО диспетчеризации и на отказе
      // отвечает JSON-RPC верхнеуровневым `error`, а не `result:[6,...]` —
      // измерено на живом роутере 2026-09-25. -32002 = "Access denied"
      // (сессия истекла или отозвана) — это и есть путь для повторного
      // логина в _withSession, раньше он был мёртвым кодом, потому что сюда
      // всё падало как RouterUnreachableError ("нет связи"), хотя роутер
      // был доступен. -32000 = "Object not found" — метод/объект не
      // зарегистрирован в rpcd, хотя разрешён в ACL (рассинхрон бэкенда).
      final err = decoded['error'] as Map<String, dynamic>?;
      final errCode = err?['code'] as int?;
      final errMsg = err?['message'] as String?;
      if (errCode == -32002) {
        throw RouterForbiddenError(errMsg ?? 'Сессия истекла');
      }
      if (errCode == -32000) {
        throw RouterMethodUnavailableError(
            'Метод не найден на роутере (rpcd): $object.$method');
      }
      throw RouterUnreachableError();
    }
    final result = decoded['result'] as List<dynamic>?;
    if (result == null || result.isEmpty) {
      throw RouterUnreachableError();
    }
    final code = result[0] as int;
    // ubus status codes: 0=OK, 3=METHOD_NOT_FOUND, 6=PERMISSION_DENIED,
    // 8=NOT_SUPPORTED. 3/8 на методе, разрешённом ACL, значит rpcd не
    // реализует его (или не перечитал плагин после деплоя) — это не "нет
    // связи" и не "запрещено", это отдельная, видимая пользователю причина.
    if (code == 6) {
      throw RouterForbiddenError('Действие не разрешено роутером');
    }
    if (code == 3 || code == 8) {
      throw RouterMethodUnavailableError(
          'Метод $object.$method не поддерживается роутером (код $code)');
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

  // -- Toolbox (rpcd object "spotty" — devices/guest wifi/events/mode) ------
  // Отдельный ubus-объект от "opscx": design в
  // .agent (см. ops-receipts/opscl-spotty-modules-20260924/router/design.md).
  // Бэкенд ещё не установлен на роутер — используются только в mock-режиме
  // до отдельного релиза после install-plan.

  /// schema spotty.devices/1: {devices:[{mac_masked, ip, hostname, link, band, signal_dbm, rx_bytes, tx_bytes, source}]}
  Future<Map<String, dynamic>> toolboxDevices() {
    return _withSession((sid) => _rpc(sid, 'spotty', 'devices', {}));
  }

  /// schema spotty.guest/1: {supported, enabled, ssid, configured}
  Future<Map<String, dynamic>> guestStatus() {
    return _withSession((sid) => _rpc(sid, 'spotty', 'guest_status', {}));
  }

  Future<Map<String, dynamic>> guestSet(bool enabled) {
    return _withSession(
        (sid) => _rpc(sid, 'spotty', 'guest_set', {'enabled': enabled}));
  }

  /// Возвращает {ssid, qr} — qr уже содержит пароль в формате WIFI:T:WPA;...;;
  /// (см. design.md: "только QR" значит без отдельного поля psk, а не без
  /// раскрытия — сам QR обязан содержать пароль, иначе его нельзя отсканировать).
  Future<Map<String, dynamic>> guestQr() {
    return _withSession((sid) => _rpc(sid, 'spotty', 'guest_qr', {}));
  }

  Future<Map<String, dynamic>> guestRotate() {
    return _withSession((sid) => _rpc(sid, 'spotty', 'guest_rotate', {}));
  }

  /// schema spotty.events/1: {events:[{ts, tag, text}]}
  Future<Map<String, dynamic>> toolboxEvents({int lines = 100}) {
    return _withSession(
        (sid) => _rpc(sid, 'spotty', 'events', {'lines': lines}));
  }

  /// mode: "direct" | "vpn" — та же команда, что signal-control set_mode.
  Future<Map<String, dynamic>> setMode(String mode) {
    return _withSession((sid) => _rpc(sid, 'spotty', 'set_mode', {'mode': mode}));
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

  /// {points:[{t,rsrp,rsrq,sinr,band,ping_ms,vpn,clients,probe_fail_pct}]} —
  /// реальный opscx.metrics_history (rpcd). Любое поле может быть null.
  /// Тихо возвращает null при ошибке — НИКОГДА не подставляет выдуманные точки.
  Future<Map<String, dynamic>?> metricsHistory({int points = 60}) async {
    try {
      return await _withSession(
          (sid) => _rpc(sid, 'opscx', 'metrics_history', {'points': points}));
    } catch (_) {
      return null;
    }
  }
}

// ---------------------------------------------------------------------------
// Сотовый сигнал — реальные поля из diag_status(), слой "Сотовая сеть":
// layers[].data.radio = {rat, band, rsrp_dbm, rsrq_db, sinr_raw, ...}
// (opscx-diag читает /tmp/run/opscx-fm350/signal.json). Пороги — из
// собственной подсказки роутера (RSRP LTE: >-90 хорошо, -90..-105 средне,
// <-105 плохо). Никакой оценки по CSQ, никаких выдуманных единиц.
// ---------------------------------------------------------------------------

/// Слой диагностики "Сотовая сеть" (id=1) из diag_status(), или null.
Map<String, dynamic>? cellularLayer(Map<String, dynamic>? diag) {
  final layers = (diag?['layers'] as List?) ?? const [];
  for (final l in layers) {
    final m = l as Map<String, dynamic>;
    if (m['id'] == 1) return m;
  }
  return null;
}

Map<String, dynamic>? radioData(Map<String, dynamic>? diag) {
  final layer = cellularLayer(diag);
  return (layer?['data'] as Map<String, dynamic>?)?['radio'] as Map<String, dynamic>?;
}

String signalBucketLabel(num? rsrpDbm) {
  if (rsrpDbm == null) return 'нет данных';
  if (rsrpDbm > -90) return 'Хорошо';
  if (rsrpDbm > -105) return 'Средне';
  return 'Плохо';
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
    _client = RouterClient(
        host: widget.host, user: widget.user, pass: widget.pass, mock: kScreenshotMock);
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

  void _openSettings() {
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => SettingsTab(update: _update, onRecheck: _checkUpdate)));
  }

  void _goTab(int i) => setState(() => _tab = i);

  @override
  Widget build(BuildContext context) {
    final pages = [
      HomeTab(
          client: _client,
          host: widget.host,
          onLogout: widget.onLogout,
          onOpenSettings: _openSettings,
          onGoTab: _goTab,
          update: _update),
      ToolsTab(client: _client, onGoTab: _goTab, onOpenSettings: _openSettings, onLogout: widget.onLogout),
      VpnTab(client: _client, onOpenSettings: _openSettings, onLogout: widget.onLogout),
      CellularTab(client: _client, onOpenSettings: _openSettings, onLogout: widget.onLogout),
    ];
    return Scaffold(
      extendBody: true,
      body: SafeArea(bottom: false, child: IndexedStack(index: _tab, children: pages)),
      bottomNavigationBar: _pillTabBar(context),
    );
  }

  Widget _pillTabBar(BuildContext context) {
    final items = [
      (Icons.dashboard_rounded, 'Главная'),
      (Icons.build_circle_rounded, 'Инструменты'),
      (Icons.shield_rounded, 'VPN'),
      (Icons.signal_cellular_alt_rounded, 'Сотовая'),
    ];
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
      child: Container(
        height: 62,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF171A24) : Colors.white,
          borderRadius: BorderRadius.circular(31),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.28), blurRadius: 20, offset: const Offset(0, 8))],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            for (var i = 0; i < items.length; i++)
              InkWell(
                onTap: () => _goTab(i),
                customBorder: const StadiumBorder(),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: _tab == i ? cs.primary.withOpacity(0.18) : Colors.transparent,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Icon(items[i].$1,
                      size: 20,
                      color: _tab == i ? cs.primary : Theme.of(context).colorScheme.onSurface.withOpacity(0.35)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Общая шапка B2: бренд + шестерёнка (Настройки, с меткой обновления) +
/// человек (выйти/сменить роутер).
Widget spottyHeader(BuildContext context,
    {required VoidCallback onOpenSettings, required VoidCallback onLogout, bool hasUpdate = false}) {
  return Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
    child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
      spottyBrand(big: true),
      Row(children: [
        Stack(clipBehavior: Clip.none, children: [
          roundHeaderIcon(context, Icons.tune_rounded, onTap: onOpenSettings),
          if (hasUpdate)
            Positioned(
              right: -1,
              top: -1,
              child: Container(
                width: 10,
                height: 10,
                decoration: const BoxDecoration(color: Color(0xFF00D9B4), shape: BoxShape.circle),
              ),
            ),
        ]),
        const SizedBox(width: 8),
        roundHeaderIcon(context, Icons.person_outline_rounded, onTap: onLogout),
      ]),
    ]),
  );
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

/// Модули «Инструментов» — id связан с реальными экранами ниже; api=false
/// модули показываются приглушённо с пометкой «скоро» (нет метода на роутере).
const _moduleDefs = [
  {'id': 'internet', 'name': 'Интернет и VPN', 'icon': Icons.public_rounded, 'api': true},
  {'id': 'mode', 'name': 'Прямой / VPN', 'icon': Icons.swap_horiz_rounded, 'api': true},
  {'id': 'diag', 'name': 'Диагностика', 'icon': Icons.troubleshoot_rounded, 'api': true},
  {'id': 'cellular', 'name': 'Сотовая сеть', 'icon': Icons.signal_cellular_alt_rounded, 'api': true},
  {'id': 'devices', 'name': 'Устройства', 'icon': Icons.devices_rounded, 'api': true},
  {'id': 'wifi', 'name': 'Wi-Fi', 'icon': Icons.wifi_rounded, 'api': true},
  {'id': 'guest', 'name': 'Гостевой Wi-Fi', 'icon': Icons.qr_code_2_rounded, 'api': true},
  {'id': 'maint', 'name': 'Обслуживание', 'icon': Icons.build_circle_rounded, 'api': true},
  {'id': 'log', 'name': 'Журнал событий', 'icon': Icons.history_rounded, 'api': true},
];

class HomeTab extends StatefulWidget {
  final RouterClient client;
  final String host;
  final VoidCallback onLogout;
  final VoidCallback onOpenSettings;
  final void Function(int) onGoTab;
  final UpdateInfo? update;
  const HomeTab({
    super.key,
    required this.client,
    required this.host,
    required this.onLogout,
    required this.onOpenSettings,
    required this.onGoTab,
    required this.update,
  });

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends _TabState<HomeTab> {
  Timer? _timer;
  Map<String, dynamic>? _status;
  Map<String, dynamic>? _diag;
  Map<String, dynamic>? _nodes;
  Map<String, dynamic>? _subs;

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

  // Причины, по которым секции ниже пустые — раньше глотались молча
  // (catch (_) {}), из-за чего диагностика/узлы/подписки выглядели как
  // "нет данных", хотя на деле метод не отвечает на роутере. Теперь видимо.
  String? _diagIssue;
  String? _nodesIssue;
  String? _subsIssue;

  String _sectionIssueText(Object e) {
    if (e is RouterMethodUnavailableError) return e.message;
    if (e is RouterForbiddenError) return e.message;
    if (e is RouterUnreachableError) return 'Нет связи с роутером.';
    return 'Ошибка: $e';
  }

  Future<void> _refresh() async {
    try {
      final s = await widget.client.status();
      Map<String, dynamic>? d;
      Map<String, dynamic>? n;
      Map<String, dynamic>? subs;
      String? diagIssue;
      String? nodesIssue;
      String? subsIssue;
      try {
        d = await widget.client.diagStatus();
      } catch (e) {
        diagIssue = _sectionIssueText(e);
      }
      try {
        n = await widget.client.listNodes();
      } catch (e) {
        nodesIssue = _sectionIssueText(e);
      }
      try {
        subs = await widget.client.vpnStatus();
      } catch (e) {
        subsIssue = _sectionIssueText(e);
      }
      if (!mounted) return;
      setState(() {
        _status = s;
        _diag = d;
        _nodes = n;
        _subs = subs;
        _diagIssue = diagIssue;
        _nodesIssue = nodesIssue;
        _subsIssue = subsIssue;
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
    final wifi = _status?['wifi'] as Map<String, dynamic>?;
    final clients = wifi?['clients'] as int?;
    final nodes = (_nodes?['nodes'] as List?) ?? const [];
    final currentId = _nodes?['current'] as String?;
    Map<String, dynamic>? currentNode;
    for (final n in nodes) {
      final m = n as Map<String, dynamic>;
      if (m['id'] == currentId) currentNode = m;
    }
    final loc = currentNode?['loc'] as String?;
    final flag = flagFromLoc(loc);
    final nodeShort = currentId ?? '—';
    final medianMs = (currentNode?['median_ms'] as int?);
    final verdict = _diag?['verdict'] as Map<String, dynamic>?;
    final verdictState = verdict?['state'] as String? ?? 'unknown';
    final verdictText = verdict?['text'] as String? ?? (_diagIssue ?? 'нет данных диагностики');
    final subsList = ((_subs?['subs'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final aliveCount = subsList.where((s) => s['result'] == 'ok').length;
    final radio = radioData(_diag);
    final dbm = radio?['rsrp_dbm'] as int?;
    final band = radio?['band'] as String?;

    return StateGlow(
      state: verdictState,
      child: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(padding: const EdgeInsets.only(bottom: 110), children: [
          spottyHeader(context,
              onOpenSettings: widget.onOpenSettings,
              onLogout: widget.onLogout,
              hasUpdate: widget.update != null),
          const SizedBox(height: 6),
          if (widget.update != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: _UpdateBanner(update: widget.update!, onTap: widget.onOpenSettings),
              ),
            ),
          errorBanner(),
          if (error == null && (_nodesIssue != null || _subsIssue != null))
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Card(
                color: Colors.orange.shade900,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_nodesIssue != null)
                        Text('Узлы: $_nodesIssue', style: const TextStyle(color: Colors.white)),
                      if (_subsIssue != null)
                        Text('Подписка: $_subsIssue', style: const TextStyle(color: Colors.white)),
                    ],
                  ),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(vpnReady ? Icons.shield_rounded : Icons.shield_outlined,
                    color: vpnReady ? const Color(0xFF00D9B4) : const Color(0xFFFFB84D), size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                      vpnReady ? 'VPN активен · $flag · $nodeShort' : 'Прямое подключение',
                      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
                ),
              ]),
              const SizedBox(height: 6),
              Text(verdictText,
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7), fontSize: 13)),
            ]),
          ),
          const SizedBox(height: 18),
          SizedBox(
            height: 118,
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              scrollDirection: Axis.horizontal,
              children: [
                MetricPill(
                    icon: Icons.podcasts_rounded,
                    value: dbm?.toDouble(),
                    unit: 'дБм · RSRP',
                    series: null,
                    color: const Color(0xFF00D9B4)),
                MetricPill(
                    icon: Icons.speed_rounded,
                    value: medianMs?.toDouble(),
                    unit: 'мс · узел',
                    series: null,
                    color: const Color(0xFF5B6EF5)),
                MetricPill(
                    icon: Icons.devices_rounded,
                    value: clients?.toDouble(),
                    unit: 'клиентов',
                    series: null,
                    color: Theme.of(context).colorScheme.tertiary),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: spottyCard(context, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                const CapsLabel(icon: Icons.podcasts_rounded, text: 'Сигнал'),
                GestureDetector(
                  onTap: () => widget.onGoTab(3),
                  child: const Text('ПОДРОБНЕЕ ›',
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Color(0xFF00D9B4))),
                ),
              ]),
              const SizedBox(height: 12),
              Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(dbm?.toString() ?? '—',
                    style: const TextStyle(fontFamily: _mono, fontWeight: FontWeight.w800, fontSize: 30)),
                const SizedBox(width: 4),
                if (dbm != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text('дБм',
                        style: TextStyle(fontFamily: _mono, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5))),
                  ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                      color: diagStateColor(dbm == null ? null : 'ok').withOpacity(0.16),
                      borderRadius: BorderRadius.circular(8)),
                  child: Text(signalBucketLabel(dbm),
                      style: const TextStyle(color: Color(0xFF00D9B4), fontSize: 11, fontWeight: FontWeight.w700)),
                ),
              ]),
              const SizedBox(height: 10),
              ThresholdScale(
                frac: dbm == null ? 0 : ((dbm + 120) / 50).clamp(0, 1),
                stops: const [Color(0xFFFF5470), Color(0xFFFFB84D), Color(0xFF00D9B4), Color(0xFF00A8FF)],
                label: dbm == null ? 'нет данных' : (band != null ? 'LTE $band' : 'RSRP'),
              ),
            ])),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              Expanded(
                  child: spottyCard(context,
                      child: _bigStat(context, (clients ?? 0).toString(), '', 'Устройства', 'в сети сейчас'))),
              const SizedBox(width: 12),
              Expanded(
                  child: spottyCard(context,
                      child: _bigStat(context, '$aliveCount/${subsList.length}', '', 'Подписка', 'живых узлов'))),
            ]),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: OutlinedButton.icon(
              onPressed: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => SubscriptionsTab(client: widget.client))),
              style: OutlinedButton.styleFrom(minimumSize: const Size(double.infinity, 46), shape: const StadiumBorder()),
              icon: const Icon(Icons.tune_rounded, size: 18),
              label: const Text('Настроить'),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _bigStat(BuildContext context, String value, String unit, String title, String sub) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(value, style: const TextStyle(fontFamily: _mono, fontWeight: FontWeight.w800, fontSize: 26)),
            if (unit.isNotEmpty)
              Text(' $unit',
                  style: TextStyle(fontFamily: _mono, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5))),
          ]),
          const SizedBox(height: 4),
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
          Text(sub, style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withOpacity(0.4), fontSize: 11)),
        ],
      );
}

// ---------------------------------------------------------------------------
// Инструменты: список модулей, недоступные (нет метода на роутере) — тускло,
// с пометкой «скоро».
// ---------------------------------------------------------------------------

class ToolsTab extends StatefulWidget {
  final RouterClient client;
  final void Function(int) onGoTab;
  final VoidCallback onOpenSettings;
  final VoidCallback onLogout;
  const ToolsTab(
      {super.key, required this.client, required this.onGoTab, required this.onOpenSettings, required this.onLogout});

  @override
  State<ToolsTab> createState() => _ToolsTabState();
}

class _ToolsTabState extends State<ToolsTab> {
  Map<String, dynamic>? _status;
  Map<String, dynamic>? _diag;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final s = await widget.client.status();
      final d = await widget.client.diagStatus();
      if (!mounted) return;
      setState(() {
        _status = s;
        _diag = d;
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final wifi = _status?['wifi'] as Map<String, dynamic>?;
    final sys = _status?['system'] as Map<String, dynamic>?;
    final layers = (_diag?['layers'] as List?) ?? const [];
    final okLayers = layers.where((l) => (l as Map)['state'] == 'ok').length;
    final live = <String, String>{
      'internet': (_status?['tunnel']?['ready'] == true) ? 'VPN' : 'Напрямую',
      if (layers.isNotEmpty) 'diag': '$okLayers/${layers.length}',
      if (wifi?['clients'] != null) 'wifi': '${wifi!['clients']} клиента',
      if (sys?['release'] != null) 'maint': 'прошивка ${sys!['release']}',
    };

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
        spottyHeader(context, onOpenSettings: widget.onOpenSettings, onLogout: widget.onLogout),
        const SizedBox(height: 16),
        const Text('Инструменты', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 26)),
        Text('обновлено только что',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withOpacity(0.45), fontSize: 12)),
        const SizedBox(height: 16),
        for (final m in _moduleDefs)
          Builder(builder: (context) {
            final api = m['api'] as bool;
            final val = live[m['id']];
            final soon = !api;
            return Opacity(
              opacity: soon ? 0.45 : 1,
              child: InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: soon ? null : () => _openModule(context, m['id'] as String),
                child: Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF171A24) : Colors.white,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Row(children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.tertiary.withOpacity(0.16),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(m['icon'] as IconData, color: Theme.of(context).colorScheme.tertiary, size: 20),
                    ),
                    const SizedBox(width: 14),
                    Expanded(child: Text(m['name'] as String, style: const TextStyle(fontWeight: FontWeight.w700))),
                    Text(val ?? (api ? 'открыть' : 'скоро'),
                        style: TextStyle(
                            fontFamily: val != null ? _mono : null,
                            fontSize: 13,
                            color: Theme.of(context).colorScheme.onSurface.withOpacity(val != null ? 0.6 : 0.4))),
                    const SizedBox(width: 6),
                    Icon(Icons.chevron_right_rounded, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.3)),
                  ]),
                ),
              ),
            );
          }),
      ]),
    );
  }

  void _openModule(BuildContext context, String id) {
    switch (id) {
      case 'internet':
        widget.onGoTab(2);
        break;
      case 'diag':
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => NetworkTab(client: widget.client)));
        break;
      case 'cellular':
        widget.onGoTab(3);
        break;
      case 'wifi':
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => WifiInfoScreen(client: widget.client)));
        break;
      case 'maint':
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => MaintenanceScreen(client: widget.client)));
        break;
      case 'devices':
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => DevicesScreen(client: widget.client)));
        break;
      case 'guest':
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => GuestWifiScreen(client: widget.client)));
        break;
      case 'log':
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => EventsScreen(client: widget.client)));
        break;
      case 'mode':
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => ModeScreen(client: widget.client)));
        break;
    }
  }
}

class WifiInfoScreen extends StatefulWidget {
  final RouterClient client;
  const WifiInfoScreen({super.key, required this.client});
  @override
  State<WifiInfoScreen> createState() => _WifiInfoScreenState();
}

class _WifiInfoScreenState extends State<WifiInfoScreen> {
  Map<String, dynamic>? _status;

  @override
  void initState() {
    super.initState();
    widget.client.status().then((s) {
      if (mounted) setState(() => _status = s);
    }).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    final wifi = _status?['wifi'] as Map<String, dynamic>?;
    return Scaffold(
      appBar: AppBar(title: const Text('Wi-Fi')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        spottyCard(context, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.wifi_rounded, color: Color(0xFF00D9B4)),
            const SizedBox(width: 10),
            Text(wifi?['ssid'] as String? ?? '—', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          ]),
          const SizedBox(height: 6),
          Text('Устройств: ${wifi?['clients'] ?? '—'}', style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6))),
        ])),
        const SizedBox(height: 12),
        Text('Гостевая сеть и QR-код подключения — нужен новый метод на роутере, пока недоступно.',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5), fontSize: 12)),
      ]),
    );
  }
}

class MaintenanceScreen extends StatefulWidget {
  final RouterClient client;
  const MaintenanceScreen({super.key, required this.client});
  @override
  State<MaintenanceScreen> createState() => _MaintenanceScreenState();
}

class _MaintenanceScreenState extends _TabState<MaintenanceScreen> {
  Map<String, dynamic>? _status;

  @override
  void initState() {
    super.initState();
    widget.client.status().then((s) {
      if (mounted) setState(() => _status = s);
    }).catchError((_) {});
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
    final sys = _status?['system'] as Map<String, dynamic>?;
    return Scaffold(
      appBar: AppBar(title: const Text('Обслуживание')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        errorBanner(),
        spottyCard(context, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(sys?['board'] as String? ?? 'Huasifei WH3000', style: const TextStyle(fontWeight: FontWeight.w700)),
          Text('Прошивка: ${sys?['release'] ?? '—'}',
              style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withOpacity(0.55), fontSize: 12)),
          Text('Аптайм сотовой сети: ${cellular == null ? '—' : _fmtUptime((cellular['uptime'] ?? 0) as int)}',
              style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withOpacity(0.55), fontSize: 12)),
        ])),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: busy
              ? null
              : () => confirmAndRun(
                    context,
                    'Перезагрузить роутер?',
                    'Роутер полностью перезагрузится, Wi-Fi пропадёт на 1-2 минуты.',
                    () => widget.client.reboot(),
                  ),
          icon: const Icon(Icons.power_settings_new),
          label: const Text('Перезагрузить роутер'),
          style: FilledButton.styleFrom(backgroundColor: Colors.red.shade900, minimumSize: const Size(double.infinity, 48)),
        ),
        if (busy) const Padding(padding: EdgeInsets.only(top: 16), child: Center(child: CircularProgressIndicator())),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// VPN: дуга свежести доказательства (реальные updated_at/valid_until
// туннеля), выход/узел, список живых узлов с выбором.
// ---------------------------------------------------------------------------

class VpnTab extends StatefulWidget {
  final RouterClient client;
  final VoidCallback onOpenSettings;
  final VoidCallback onLogout;
  const VpnTab({super.key, required this.client, required this.onOpenSettings, required this.onLogout});
  @override
  State<VpnTab> createState() => _VpnTabState();
}

class _VpnTabState extends _TabState<VpnTab> {
  Timer? _timer;
  Map<String, dynamic>? _status;
  Map<String, dynamic>? _nodes;

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
      Map<String, dynamic>? n;
      try {
        n = await widget.client.listNodes();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _status = s;
        _nodes = n;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final tunnel = _status?['tunnel'] as Map<String, dynamic>?;
    final ready = tunnel?['ready'] == true;
    final egress = tunnel?['external_address'] as String?;
    final updatedAt = tunnel?['updated_at'] as int?;
    final validUntil = tunnel?['valid_until'] as int?;
    final nowS = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    double frac = 0;
    String ageText = 'нет данных';
    if (updatedAt != null && validUntil != null && validUntil > updatedAt) {
      final age = nowS - updatedAt;
      final window = validUntil - updatedAt;
      frac = (1 - age / window).clamp(0.0, 1.0);
      ageText = age < 0 ? '0 с' : '$age с';
    }
    final nodes = ((_nodes?['nodes'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final currentId = _nodes?['current'] as String?;
    Map<String, dynamic>? currentNode;
    for (final n in nodes) {
      if (n['id'] == currentId) currentNode = n;
    }
    final sorted = [...nodes]..sort((a, b) {
        if (a['id'] == currentId) return -1;
        if (b['id'] == currentId) return 1;
        final okA = (a['probe_ok'] as int?) ?? 0;
        final okB = (b['probe_ok'] as int?) ?? 0;
        return okB.compareTo(okA);
      });

    return StateGlow(
      state: ready ? 'ok' : 'warn',
      child: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 110), children: [
          spottyHeader(context, onOpenSettings: widget.onOpenSettings, onLogout: widget.onLogout),
          const SizedBox(height: 16),
          const Text('VPN', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 26)),
          const SizedBox(height: 12),
          errorBanner(),
          spottyCard(context, child: Column(children: [
            const CapsLabel(icon: Icons.verified_rounded, text: 'Свежесть доказательства'),
            ArcGauge(
                frac: frac,
                color: ready ? const Color(0xFF00D9B4) : Theme.of(context).colorScheme.onSurface.withOpacity(0.3),
                centerText: ageText,
                centerSub: 'назад подтверждён'),
          ])),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
                child: spottyCard(context,
                    child: _stat(context, egress ?? '—', 'Выход', ready ? 'подтверждён' : 'не подтверждён'))),
            const SizedBox(width: 12),
            Expanded(
                child: spottyCard(context,
                    child: _stat(context, currentId ?? '—', 'Узел',
                        currentNode == null ? '—' : cleanNodeName((currentNode['meta'] as Map?)?['name'] as String? ?? '')))),
          ]),
          const SizedBox(height: 16),
          const Text('Узлы', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          const SizedBox(height: 8),
          if (sorted.isEmpty)
            const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('Список узлов пуст.', style: TextStyle(color: Colors.white70))),
          for (final n in sorted)
            Builder(builder: (context) {
              final id = n['id'] as String;
              final isCurrent = id == currentId;
              final ms = (n['median_ms'] as int?) ?? 99999;
              final alive = ((n['probe_ok'] as int?) ?? 0) > 0;
              final name = cleanNodeName((n['meta'] as Map?)?['name'] as String? ?? '');
              return InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: (!alive || busy || isCurrent)
                    ? null
                    : () => runGuarded(() => widget.client.selectNode(id), onDone: _refresh, notify: true),
                child: Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: isCurrent
                        ? const Color(0xFF00D9B4).withOpacity(0.14)
                        : (Theme.of(context).brightness == Brightness.dark ? const Color(0xFF171A24) : Colors.white),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(children: [
                    Expanded(flex: 3, child: Text(name, style: const TextStyle(fontWeight: FontWeight.w600))),
                    Expanded(
                      flex: 2,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: alive ? (1 - (ms / 150).clamp(0, 1)) : 0,
                          minHeight: 6,
                          backgroundColor: Theme.of(context).colorScheme.onSurface.withOpacity(0.1),
                          color: isCurrent ? const Color(0xFF00D9B4) : Theme.of(context).colorScheme.onSurface.withOpacity(0.35),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(alive ? '$ms мс' : '—',
                        style: TextStyle(
                            fontFamily: _mono, fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.55))),
                  ]),
                ),
              );
            }),
        ]),
      ),
    );
  }

  Widget _stat(BuildContext context, String value, String title, String sub) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value,
              style: const TextStyle(fontFamily: _mono, fontWeight: FontWeight.w800, fontSize: 20),
              overflow: TextOverflow.ellipsis),
          const SizedBox(height: 4),
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
          Text(sub, style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withOpacity(0.4), fontSize: 11)),
        ],
      );
}

// ---------------------------------------------------------------------------
// Сотовая сеть: RSRP/RSRQ/SINR/диапазон из diag_status() (слой "Сотовая
// сеть"), история — opscx.metrics_history({points}); нет modem_request/
// modem_result на роутере — они не вызываются вовсе.
// ---------------------------------------------------------------------------

class CellularTab extends StatefulWidget {
  final RouterClient client;
  final VoidCallback onOpenSettings;
  final VoidCallback onLogout;
  const CellularTab({super.key, required this.client, required this.onOpenSettings, required this.onLogout});
  @override
  State<CellularTab> createState() => _CellularTabState();
}

/// Оставляет только точки, где поле не null, конвертирует к double.
/// Пустой/однооэлементный результат — «копим историю», без выдумки.
List<double>? _seriesOf(List? points, String key) {
  if (points == null) return null;
  final vals = <double>[];
  for (final p in points) {
    final v = (p as Map)[key];
    if (v is num) vals.add(v.toDouble());
  }
  return vals;
}

class _CellularTabState extends _TabState<CellularTab> {
  Timer? _timer;
  Map<String, dynamic>? _diag;
  List? _historyPoints;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 20), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    Map<String, dynamic>? diag;
    List? hist;
    try {
      diag = await widget.client.diagStatus();
    } catch (_) {}
    final histResp = await widget.client.metricsHistory(points: 120);
    hist = histResp?['points'] as List?;
    if (!mounted) return;
    setState(() {
      _diag = diag;
      _historyPoints = hist;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final radio = radioData(_diag);
    final layer = cellularLayer(_diag);
    final layerState = layer?['state'] as String?;
    final dbm = radio?['rsrp_dbm'] as int?;
    final rsrq = radio?['rsrq_db'] as int?;
    final sinr = radio?['sinr_raw'] as int?;
    final band = radio?['band'] as String?;
    final rat = radio?['rat'] as String?;

    final rsrpSeries = _seriesOf(_historyPoints, 'rsrp');
    final pingSeries = _seriesOf(_historyPoints, 'ping_ms');
    final sinrSeries = _seriesOf(_historyPoints, 'sinr');
    final failSeries = _seriesOf(_historyPoints, 'probe_fail_pct');

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 110), children: [
        spottyHeader(context, onOpenSettings: widget.onOpenSettings, onLogout: widget.onLogout),
        const SizedBox(height: 16),
        const Text('Сотовая сеть', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 26)),
        Text(
            (rat != null && band != null ? '$rat $band' : 'нет данных') + (_loading ? ' · обновляется…' : ''),
            style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5), fontSize: 12)),
        const SizedBox(height: 16),
        errorBanner(),
        if (layerState != null && layerState != 'ok')
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: spottyCard(context,
                child: Row(children: [
                  Icon(diagStateIcon(layerState), color: diagStateColor(layerState)),
                  const SizedBox(width: 10),
                  Expanded(child: Text(layer?['reason'] as String? ?? '—')),
                ])),
          ),
        spottyCard(context, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const CapsLabel(icon: Icons.podcasts_rounded, text: 'RSRP'),
          const SizedBox(height: 8),
          Text(dbm == null ? 'нет данных' : '$dbm дБм',
              style: const TextStyle(fontFamily: _mono, fontWeight: FontWeight.w800, fontSize: 26)),
          const SizedBox(height: 8),
          ThresholdScale(
            frac: dbm == null ? 0 : ((dbm + 120) / 50).clamp(0, 1),
            stops: const [Color(0xFFFF5470), Color(0xFFFFB84D), Color(0xFF00D9B4), Color(0xFF00A8FF)],
            label: '${signalBucketLabel(dbm)}${band != null ? ' · LTE $band' : ''}',
          ),
        ])),
        const SizedBox(height: 10),
        spottyCard(context, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const CapsLabel(icon: Icons.compare_arrows_rounded, text: 'RSRQ'),
          const SizedBox(height: 8),
          Text(rsrq == null ? 'нет данных' : '$rsrq дБ',
              style: const TextStyle(fontFamily: _mono, fontWeight: FontWeight.w800, fontSize: 22)),
        ])),
        const SizedBox(height: 10),
        spottyCard(context, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const CapsLabel(icon: Icons.graphic_eq_rounded, text: 'SINR'),
          const SizedBox(height: 8),
          Text(sinr == null ? 'нет данных' : '$sinr дБ',
              style: const TextStyle(fontFamily: _mono, fontWeight: FontWeight.w800, fontSize: 22)),
        ])),
        const SizedBox(height: 10),
        _historyCard(context, 'RSRP · история', rsrpSeries, const Color(0xFF00D9B4)),
        const SizedBox(height: 10),
        _historyCard(context, 'Пинг · история', pingSeries, const Color(0xFF5B6EF5)),
        const SizedBox(height: 10),
        _historyCard(context, 'SINR · история', sinrSeries, const Color(0xFF00D9B4)),
        const SizedBox(height: 10),
        _historyCard(context, 'Провалы пробы, % · история', failSeries, const Color(0xFFFFB84D)),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: busy
              ? null
              : () => confirmAndRun(
                    context,
                    'Перезапустить модем/сотовую связь?',
                    'Роутер отключит и заново поднимет сотовое соединение (reconnect_cellular). '
                        'Интернет пропадёт на несколько секунд.',
                    () => widget.client.action('reconnect_cellular'),
                    onDone: _load,
                  ),
          style: FilledButton.styleFrom(minimumSize: const Size(double.infinity, 48)),
          icon: const Icon(Icons.settings_input_antenna_rounded),
          label: const Text('Переподключить'),
        ),
        if (busy) const Padding(padding: EdgeInsets.only(top: 16), child: Center(child: CircularProgressIndicator())),
      ]),
    );
  }

  Widget _historyCard(BuildContext context, String label, List<double>? series, Color color) {
    return spottyCard(context, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      CapsLabel(icon: Icons.timeline_rounded, text: label),
      const SizedBox(height: 10),
      (series != null && series.length >= 2)
          ? SizedBox(height: 40, child: Spark(series: series, color: color))
          : SizedBox(
              height: 40,
              child: Center(
                child: Text('копим историю',
                    style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.4))),
              ),
            ),
    ]));
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

/// Regional-indicator флаг по двухбуквенному ISO-коду страны узла (`loc`).
String flagFromLoc(String? loc) {
  if (loc == null || loc.length != 2 || loc.toUpperCase() == 'XX') return '🏳️';
  const base = 0x1F1E6;
  final cc = loc.toUpperCase();
  final a = base + (cc.codeUnitAt(0) - 'A'.codeUnitAt(0));
  final b = base + (cc.codeUnitAt(1) - 'A'.codeUnitAt(0));
  return String.fromCharCode(a) + String.fromCharCode(b);
}

// =============================================================================
// Общий визуальный набор B2 (перенесён из lib/main_concepts.dart — референсы
// The Outsiders «Today»/«Customize», RAD Weather Details, Dropset «Workouts»):
// свечение по состоянию, пилюли-метрики со спарклайном (или «копим историю»,
// если реальной истории ещё нет), капс-подписи, шкала-градиент с порогом,
// дуга свежести, плавающий таб-бар-пилюля, круглые иконки в шапке.
// =============================================================================

const _mono = 'monospace';

Color _glowColor(String state) => switch (state) {
      'ok' => const Color(0xFF00D9B4),
      'warn' => const Color(0xFFFFB84D),
      _ => const Color(0xFFFF5470),
    };

/// Фоновое свечение сверху экрана, цвет = состояние вердикта диагностики.
class StateGlow extends StatelessWidget {
  final String state;
  final Widget child;
  const StateGlow({super.key, required this.state, required this.child});
  @override
  Widget build(BuildContext context) {
    final c = _glowColor(state);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Stack(children: [
      Positioned(
        top: 0,
        left: 0,
        right: 0,
        height: 340,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [c.withOpacity(isDark ? 0.38 : 0.22), c.withOpacity(0.0)],
            ),
          ),
        ),
      ),
      child,
    ]);
  }
}

/// Мини-спарклайн с точкой текущего значения.
class Spark extends StatelessWidget {
  final List<double> series;
  final Color color;
  const Spark({super.key, required this.series, required this.color});
  @override
  Widget build(BuildContext context) => SizedBox(
        height: 28,
        width: double.infinity,
        child: CustomPaint(painter: _SparkPainter(series, color)),
      );
}

class _SparkPainter extends CustomPainter {
  final List<double> series;
  final Color color;
  _SparkPainter(this.series, this.color);
  @override
  void paint(Canvas canvas, Size size) {
    if (series.length < 2) return;
    final minV = series.reduce((a, b) => a < b ? a : b);
    final maxV = series.reduce((a, b) => a > b ? a : b);
    final range = (maxV - minV).abs() < 0.001 ? 1.0 : (maxV - minV);
    final dx = size.width / (series.length - 1);
    final path = Path();
    for (var i = 0; i < series.length; i++) {
      final x = dx * i;
      final y = size.height - ((series[i] - minV) / range) * size.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round);
    final lastX = size.width;
    final lastY = size.height - ((series.last - minV) / range) * size.height;
    canvas.drawCircle(Offset(lastX, lastY), 3.5, Paint()..color = color);
    canvas.drawCircle(Offset(lastX, lastY), 6, Paint()..color = color.withOpacity(0.25));
  }

  @override
  bool shouldRepaint(covariant _SparkPainter oldDelegate) => false;
}

/// Вертикальная пилюля-метрика: крупное число + единица + мини-спарклайн.
/// series == null или короче 2 точек — история ещё не накоплена (нет
/// opscx.metrics_history на роутере): показывает «копим историю», НИКОГДА
/// не подставляет выдуманные точки.
class MetricPill extends StatelessWidget {
  final IconData icon;
  final double? value;
  final String unit;
  final List<double>? series;
  final Color color;
  const MetricPill(
      {super.key,
      required this.icon,
      required this.value,
      required this.unit,
      required this.series,
      required this.color});
  @override
  Widget build(BuildContext context) {
    final cardColor =
        Theme.of(context).brightness == Brightness.dark ? const Color(0xFF171A24) : Colors.white;
    final v = value;
    return Container(
      width: 92,
      margin: const EdgeInsets.only(right: 10),
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 10),
      decoration: BoxDecoration(color: cardColor, borderRadius: BorderRadius.circular(22)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 16, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5)),
        const SizedBox(height: 10),
        Text(
            v == null
                ? '—'
                : (v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1)),
            style: const TextStyle(fontFamily: _mono, fontWeight: FontWeight.w700, fontSize: 21)),
        Text(unit,
            style: TextStyle(
                fontFamily: _mono, fontSize: 11, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.45))),
        const SizedBox(height: 6),
        (series != null && series!.length >= 2)
            ? Spark(series: series!, color: color)
            : SizedBox(
                height: 28,
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: Text('копим историю',
                      style: TextStyle(fontSize: 9, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.35))),
                ),
              ),
      ]),
    );
  }
}

/// Капс-подпись секции с иконкой.
class CapsLabel extends StatelessWidget {
  final IconData icon;
  final String text;
  const CapsLabel({super.key, required this.icon, required this.text});
  @override
  Widget build(BuildContext context) => Row(children: [
        Icon(icon, size: 14, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.55)),
        const SizedBox(width: 6),
        Text(text.toUpperCase(),
            style: TextStyle(
                fontSize: 11,
                letterSpacing: 1.1,
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.55))),
      ]);
}

/// Шкала-градиент с порогами и маркером текущего значения.
class ThresholdScale extends StatelessWidget {
  final double frac; // 0..1 положение маркера
  final List<Color> stops;
  final String label;
  const ThresholdScale({super.key, required this.frac, required this.stops, required this.label});
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          height: 10,
          child: Stack(clipBehavior: Clip.none, children: [
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                gradient: LinearGradient(colors: stops),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: -3,
              child: Align(
                alignment: Alignment(frac.clamp(0, 1) * 2 - 1, 0),
                child: Container(width: 3, height: 16, color: Colors.white),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 6),
        Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
      ]);
}

/// Дуга свежести (0..1). Используется для возраста последнего подтверждённого
/// состояния VPN-туннеля — реальные updated_at/valid_until с роутера.
class ArcGauge extends StatelessWidget {
  final double frac;
  final Color color;
  final String centerText;
  final String centerSub;
  const ArcGauge(
      {super.key, required this.frac, required this.color, required this.centerText, required this.centerSub});
  @override
  Widget build(BuildContext context) => SizedBox(
        height: 118,
        child: Stack(alignment: Alignment.bottomCenter, children: [
          CustomPaint(
              size: const Size(double.infinity, 110),
              painter: _ArcPainter(
                  frac: frac,
                  color: color,
                  trackColor: Theme.of(context).colorScheme.onSurface.withOpacity(0.1))),
          Padding(
            padding: const EdgeInsets.only(bottom: 18),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(centerText, style: const TextStyle(fontFamily: _mono, fontWeight: FontWeight.w800, fontSize: 22)),
              Text(centerSub, style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.55))),
            ]),
          ),
        ]),
      );
}

class _ArcPainter extends CustomPainter {
  final double frac;
  final Color color;
  final Color trackColor;
  _ArcPainter({required this.frac, required this.color, required this.trackColor});
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(8, 8, size.width - 16, size.width - 16);
    const start = 3.14159;
    const sweep = 3.14159;
    canvas.drawArc(rect, start, sweep, false,
        Paint()..color = trackColor..style = PaintingStyle.stroke..strokeWidth = 8..strokeCap = StrokeCap.round);
    canvas.drawArc(rect, start, sweep * frac.clamp(0, 1), false,
        Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 8..strokeCap = StrokeCap.round);
  }

  @override
  bool shouldRepaint(covariant _ArcPainter oldDelegate) =>
      oldDelegate.frac != frac || oldDelegate.color != color || oldDelegate.trackColor != trackColor;
}

Widget roundHeaderIcon(BuildContext context, IconData icon, {VoidCallback? onTap}) => InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: Theme.of(context).brightness == Brightness.dark ? Colors.white10 : Colors.black12,
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 18),
      ),
    );

Widget spottyBrand({bool big = false}) => Builder(builder: (context) {
      final cs = Theme.of(context).colorScheme;
      return Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: big ? 40 : 28,
          height: big ? 40 : 28,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(colors: [cs.primary, cs.tertiary]),
          ),
          child: const Icon(Icons.blur_on_rounded, color: Colors.white, size: 18),
        ),
        const SizedBox(width: 10),
        Text('Spotty', style: TextStyle(fontWeight: FontWeight.w800, fontSize: big ? 22 : 18)),
      ]);
    });

Widget spottyCard(BuildContext context, {required Widget child}) => Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF171A24) : Colors.white,
        borderRadius: BorderRadius.circular(20),
      ),
      child: child,
    );

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

  String _flagFromLoc(String? loc) => flagFromLoc(loc);

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
