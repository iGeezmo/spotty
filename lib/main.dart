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
// Кнопка reboot использует общий ubus-объект system (root-сессия имеет
// read/write '*' по /etc/config/rpcd), это НЕ отдельный метод opscx.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

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
    return {'host': host, 'user': user ?? 'root', 'pass': pass};
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
    return StatusScreen(
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

/// Экран однократного ввода адреса роутера и пароля root.
class SetupScreen extends StatefulWidget {
  final VoidCallback onSaved;
  const SetupScreen({super.key, required this.onSaved});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _hostCtrl = TextEditingController(text: '192.168.5.1');
  final _userCtrl = TextEditingController(text: 'root');
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
                  'Укажите адрес роутера и пароль администратора (root). '
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
                    labelText: 'Пароль root',
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
    final user = _userCtrl.text.trim().isEmpty ? 'root' : _userCtrl.text.trim();
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
}

// ---------------------------------------------------------------------------
// Экран статуса.
// ---------------------------------------------------------------------------

class StatusScreen extends StatefulWidget {
  final String host;
  final String user;
  final String pass;
  final VoidCallback onLogout;

  const StatusScreen({
    super.key,
    required this.host,
    required this.user,
    required this.pass,
    required this.onLogout,
  });

  @override
  State<StatusScreen> createState() => _StatusScreenState();
}

class _StatusScreenState extends State<StatusScreen> {
  late final RouterClient _client;
  Timer? _timer;
  Map<String, dynamic>? _status;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _client =
        RouterClient(host: widget.host, user: widget.user, pass: widget.pass);
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final s = await _client.status();
      if (!mounted) return;
      setState(() {
        _status = s;
        _error = null;
      });
    } on RouterAuthError {
      if (!mounted) return;
      setState(() => _error = 'Неверный пароль. Выйдите и введите заново.');
    } on RouterUnreachableError {
      if (!mounted) return;
      setState(() => _error = 'Нет связи с роутером.');
    } on RouterForbiddenError catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Ошибка: $e');
    }
  }

  Future<void> _confirmAndRun(
      String title, String body, Future<void> Function() run) async {
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
    setState(() => _busy = true);
    try {
      await run();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Команда отправлена на роутер')));
      }
    } on RouterAuthError {
      if (mounted) setState(() => _error = 'Неверный пароль.');
    } on RouterUnreachableError {
      if (mounted) setState(() => _error = 'Нет связи с роутером.');
    } on RouterForbiddenError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Ошибка: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
      await _refresh();
    }
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
    final s = _status;
    final cellular = s?['cellular'] as Map<String, dynamic>?;
    final tunnel = s?['tunnel'] as Map<String, dynamic>?;
    final wifi = s?['wifi'] as Map<String, dynamic>?;
    final sys = s?['system'] as Map<String, dynamic>?;

    final internetUp = cellular?['up'] == true;
    final vpnReady = tunnel?['ready'] == true;

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
            if (_error != null)
              Card(
                color: Colors.red.shade900,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(_error!,
                      style: const TextStyle(color: Colors.white)),
                ),
              ),
            _StatusCard(
              icon: internetUp ? Icons.wifi_tethering : Icons.wifi_off,
              iconColor: internetUp ? Colors.green : Colors.red,
              title: 'Интернет',
              value: internetUp ? 'Есть' : 'Нет',
            ),
            _StatusCard(
              icon: vpnReady ? Icons.lock : Icons.lock_open,
              iconColor: vpnReady ? Colors.green : Colors.orange,
              title: 'Режим связи',
              value: vpnReady
                  ? 'VPN-туннель подтверждён'
                  : 'VPN не подтверждён (напрямую или устанавливается)',
            ),
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
              icon: Icons.public,
              iconColor: Colors.teal,
              title: 'Внешний IP через VPN',
              value: tunnel?['external_address'] as String? ?? 'нет данных',
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
            const SizedBox(height: 24),
            const Text('Действия', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _busy
                  ? null
                  : () => _confirmAndRun(
                        'Перезапустить VPN-туннель?',
                        'Роутер попробует перезапустить VPN-туннель '
                            '(restart_tunnel). На части прошивок этот шаг '
                            'может ничего не менять — это ограничение самого '
                            'роутера, не приложения.',
                        () => _client.action('restart_tunnel'),
                      ),
              icon: const Icon(Icons.vpn_key),
              label: const Text('Перезапустить VPN-туннель'),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _busy
                  ? null
                  : () => _confirmAndRun(
                        'Перезапустить модем/сотовую связь?',
                        'Роутер отключит и заново поднимет сотовое '
                            'соединение (reconnect_cellular). Интернет '
                            'пропадёт на несколько секунд.',
                        () => _client.action('reconnect_cellular'),
                      ),
              icon: const Icon(Icons.settings_input_antenna),
              label: const Text('Перезапустить модем'),
            ),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              onPressed: _busy
                  ? null
                  : () => _confirmAndRun(
                        'Перезагрузить роутер?',
                        'Роутер полностью перезагрузится, Wi-Fi пропадёт на '
                            '1-2 минуты.',
                        () => _client.reboot(),
                      ),
              icon: const Icon(Icons.power_settings_new),
              label: const Text('Перезагрузить роутер'),
              style: FilledButton.styleFrom(backgroundColor: Colors.red.shade900),
            ),
            if (_busy)
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
