// Toolbox screens: Устройства, Гостевой Wi-Fi, Журнал событий, Прямой/VPN.
//
// Backend (ubus object "spotty") design lives in
// ops-receipts/opscl-spotty-modules-20260924/router/design.md — NOT
// installed on the router yet. These screens work today only in
// SCREENSHOT_MOCK mode (see RouterClient._mockRpc in main.dart); real calls
// will fail with RouterForbiddenError/unavailable until install-plan.md
// step 4 lands.

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../main.dart';

const _mono = 'monospace';

String _fmtBytes(num bytes) {
  if (bytes >= 1073741824) return '${(bytes / 1073741824).toStringAsFixed(1)} ГБ';
  if (bytes >= 1048576) return '${(bytes / 1048576).toStringAsFixed(1)} МБ';
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} КБ';
  return '$bytes Б';
}

String _fmtAgo(int ts) {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final d = now - ts;
  if (d < 60) return '$d с назад';
  if (d < 3600) return '${d ~/ 60} мин назад';
  return '${d ~/ 3600} ч назад';
}

Color _tagColor(String tag) {
  switch (tag) {
    case 'mode':
      return const Color(0xFF00D9B4);
    case 'cellular':
      return const Color(0xFF00A8FF);
    case 'hold':
      return const Color(0xFFFF5470);
    case 'worker':
      return const Color(0xFFFFB84D);
    default:
      return const Color(0xFF8A8FA3);
  }
}

// ---------------------------------------------------------------------------
// 1. Устройства
// ---------------------------------------------------------------------------

class DevicesScreen extends StatefulWidget {
  final RouterClient client;
  const DevicesScreen({super.key, required this.client});
  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  Map<String, dynamic>? _data;
  // ubus object "spotty" (per-device list) не установлен на большинстве
  // роутеров (design.md, ещё не задеплоен) — вызов падает Object not found.
  // diag_status() слой 7 "Устройства" всегда считает количество независимо
  // от этого объекта, так что счётчик не должен зависеть от отсутствующего
  // бэкенда, даже когда детальный список недоступен.
  int? _diagDeviceCount;
  bool _spottyUnavailable = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    Map<String, dynamic>? data;
    bool spottyFailed = false;
    try {
      data = await widget.client.toolboxDevices();
    } catch (_) {
      spottyFailed = true;
    }
    int? diagCount;
    try {
      final diag = await widget.client.diagStatus();
      final layer = diagLayerById(diag, 7);
      final raw = (layer?['data'] as Map<String, dynamic>?)?['devices'];
      if (raw is int) diagCount = raw;
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _data = data;
      _diagDeviceCount = diagCount;
      _spottyUnavailable = spottyFailed;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final devices = (_data?['devices'] as List?) ?? const [];
    final count = devices.isNotEmpty ? devices.length : (_diagDeviceCount ?? devices.length);
    return Scaffold(
      appBar: AppBar(title: const Text('Устройства')),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: _loading && devices.isEmpty && _diagDeviceCount == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text('$count устройств в сети',
                      style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5), fontSize: 12)),
                  const SizedBox(height: 10),
                  for (final raw in devices) _deviceCard(context, raw as Map<String, dynamic>),
                  if (devices.isEmpty && _spottyUnavailable && _diagDeviceCount != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        'Список устройств недоступен: бэкенд ubus "spotty" не установлен '
                        'на этом роутере. Счётчик выше — из диагностики (слой «Устройства»).',
                        style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5), fontSize: 12),
                      ),
                    ),
                  const SizedBox(height: 8),
                  Text(
                    'Трафик по Wi-Fi — от точки доступа (накопительно с подключения). '
                    'Трафик по проводным устройствам — по открытым соединениям сейчас, не общий счётчик.',
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withOpacity(0.4), fontSize: 11),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _deviceCard(BuildContext context, Map<String, dynamic> d) {
    final isWifi = d['link'] == 'wifi';
    final signal = d['signal_dbm'] as int?;
    return spottyCard(
      context,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.tertiary.withOpacity(0.16),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(isWifi ? Icons.wifi_rounded : Icons.lan_rounded,
                size: 18, color: Theme.of(context).colorScheme.tertiary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text((d['hostname'] as String?) ?? (d['mac_masked'] as String), style: const TextStyle(fontWeight: FontWeight.w700)),
              Text(
                '${d['ip']} · ${d['mac_masked']}${isWifi ? ' · ${d['band']}' : ' · LAN'}',
                style: TextStyle(fontFamily: _mono, fontSize: 11, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5)),
              ),
            ]),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            if (signal != null) Text('$signal дБм', style: const TextStyle(fontFamily: _mono, fontSize: 12)),
            Text('↓${_fmtBytes(d['rx_bytes'] as num)} ↑${_fmtBytes(d['tx_bytes'] as num)}',
                style: TextStyle(fontFamily: _mono, fontSize: 10, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.45))),
          ]),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 2. Гостевой Wi-Fi
// ---------------------------------------------------------------------------

class GuestWifiScreen extends StatefulWidget {
  final RouterClient client;
  const GuestWifiScreen({super.key, required this.client});
  @override
  State<GuestWifiScreen> createState() => _GuestWifiScreenState();
}

class _GuestWifiScreenState extends State<GuestWifiScreen> {
  Map<String, dynamic>? _status;
  String? _qr;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final s = await widget.client.guestStatus();
      if (!mounted) return;
      setState(() => _status = s);
    } catch (_) {}
  }

  Future<void> _toggle(bool enabled) async {
    setState(() => _busy = true);
    try {
      await widget.client.guestSet(enabled);
      await _refresh();
      if (enabled) await _loadQr();
    } catch (_) {
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadQr() async {
    try {
      final r = await widget.client.guestQr();
      if (!mounted) return;
      setState(() => _qr = r['qr'] as String?);
    } catch (_) {}
  }

  Future<void> _rotate() async {
    setState(() => _busy = true);
    try {
      await widget.client.guestRotate();
      await _loadQr();
    } catch (_) {
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final supported = _status?['supported'] == true;
    final enabled = _status?['enabled'] == true;
    final ssid = _status?['ssid'] as String?;

    return Scaffold(
      appBar: AppBar(title: const Text('Гостевой Wi-Fi')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (!supported)
          spottyCard(
            context,
            child: Row(children: [
              const Icon(Icons.info_outline_rounded, color: Color(0xFFFFB84D)),
              const SizedBox(width: 10),
              const Expanded(
                  child: Text('Гостевая сеть спроектирована, но ещё не установлена на роутер (гейт по kill-switch).')),
            ]),
          ),
        spottyCard(
          context,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.wifi_rounded, color: Color(0xFF00D9B4)),
              const SizedBox(width: 10),
              Expanded(child: Text(ssid ?? 'Huasifei-Guest', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16))),
              Switch(
                value: enabled,
                onChanged: (supported && !_busy) ? _toggle : null,
              ),
            ]),
            const SizedBox(height: 4),
            Text('Изолирована от основной сети; следует режиму Прямой/VPN.',
                style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5), fontSize: 12)),
          ]),
        ),
        const SizedBox(height: 12),
        if (enabled)
          spottyCard(
            context,
            child: Column(children: [
              if (_qr != null)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: QrImageView(data: _qr!, size: 200, backgroundColor: Colors.white),
                )
              else
                const Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()),
              const SizedBox(height: 8),
              Text(ssid ?? '—', style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: _busy ? null : _rotate,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Сменить пароль'),
              ),
            ]),
          ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// 3. Журнал событий
// ---------------------------------------------------------------------------

class EventsScreen extends StatefulWidget {
  final RouterClient client;
  const EventsScreen({super.key, required this.client});
  @override
  State<EventsScreen> createState() => _EventsScreenState();
}

class _EventsScreenState extends State<EventsScreen> {
  Map<String, dynamic>? _data;
  String _filter = 'all';

  @override
  void initState() {
    super.initState();
    widget.client.toolboxEvents(lines: 200).then((d) {
      if (mounted) setState(() => _data = d);
    }).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    final events = ((_data?['events'] as List?) ?? const [])
        .cast<Map<String, dynamic>>()
        .where((e) => _filter == 'all' || e['tag'] == _filter)
        .toList();
    final tags = ['all', 'mode', 'cellular', 'hold', 'worker', 'diag', 'other'];

    return Scaffold(
      appBar: AppBar(title: const Text('Журнал событий')),
      body: Column(children: [
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              for (final t in tags)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: ChoiceChip(
                    label: Text(t),
                    selected: _filter == t,
                    onSelected: (_) => setState(() => _filter = t),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: events.length,
            itemBuilder: (context, i) {
              final e = events[i];
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(
                    margin: const EdgeInsets.only(top: 5),
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(color: _tagColor(e['tag'] as String), shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(e['text'] as String, style: const TextStyle(fontFamily: _mono, fontSize: 12)),
                      Text(_fmtAgo(e['ts'] as int),
                          style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.4))),
                    ]),
                  ),
                ]),
              );
            },
          ),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// 4. Прямой / VPN
// ---------------------------------------------------------------------------

class ModeScreen extends StatefulWidget {
  final RouterClient client;
  const ModeScreen({super.key, required this.client});
  @override
  State<ModeScreen> createState() => _ModeScreenState();
}

class _ModeScreenState extends State<ModeScreen> {
  Map<String, dynamic>? _status;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    widget.client.status().then((s) {
      if (mounted) setState(() => _status = s);
    }).catchError((_) {});
  }

  Future<void> _set(String mode) async {
    setState(() => _busy = true);
    try {
      await widget.client.setMode(mode);
    } catch (_) {
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tunnel = _status?['tunnel'] as Map<String, dynamic>?;
    final vpn = tunnel?['ready'] == true;

    return Scaffold(
      appBar: AppBar(title: const Text('Прямой / VPN')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        spottyCard(
          context,
          child: Column(children: [
            Icon(vpn ? Icons.shield_rounded : Icons.public_rounded,
                size: 40, color: vpn ? const Color(0xFF00D9B4) : const Color(0xFFFFB84D)),
            const SizedBox(height: 8),
            Text(vpn ? 'Через VPN' : 'Напрямую', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
            if (tunnel?['external_address'] != null)
              Text('${tunnel!['external_address']}',
                  style: TextStyle(fontFamily: _mono, fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5))),
          ]),
        ),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(
            child: OutlinedButton(
              onPressed: _busy ? null : () => _set('direct'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
                backgroundColor: !vpn ? const Color(0xFFFFB84D).withOpacity(0.15) : null,
              ),
              child: const Text('Прямой'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: OutlinedButton(
              onPressed: _busy ? null : () => _set('vpn'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
                backgroundColor: vpn ? const Color(0xFF00D9B4).withOpacity(0.15) : null,
              ),
              child: const Text('VPN'),
            ),
          ),
        ]),
      ]),
    );
  }
}
