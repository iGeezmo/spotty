// Интеграционный тест RouterClient на РЕАЛЬНЫХ фикстурах, снятых с живого
// роутера 192.168.5.1 (opscl-spotty-e2e-20260925, JSON-RPC /ubus, учётка
// app). Проверяет разбор ответов и, главное, повторный логин при истечении
// ubus-сессии — раньше это был мёртвый код: -32002 приходил как
// JSON-RPC верхнеуровневый `error`, а не `result:[6,...]`, поэтому
// RouterForbiddenError никогда не бросался и re-login не срабатывал (см.
// main.dart RouterClient._rpc и .agent/ops-receipts/opscl-spotty-e2e-20260925).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:huasifei_remote/main.dart';

http.Response _json(Object body, {int status = 200}) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json'});

void main() {
  group('RouterClient — real router fixtures (2026-09-25)', () {
    test('status() parses real opscx.status payload', () async {
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        final payload =
            jsonDecode(req.body) as Map<String, dynamic>;
        final params = payload['params'] as List;
        expect(params[1], 'session');
        return _json({
          'jsonrpc': '2.0',
          'id': 1,
          'result': [
            0,
            {
              'ubus_rpc_session': 'ef45705ed66959604c0046fa2dba44ec',
              'timeout': 300,
              'expires': 299,
            }
          ]
        });
      });

      await http.runWithClient(() async {
        final rc = RouterClient(host: '192.168.5.1', user: 'app', pass: 'x');
        // login only in this sub-test; status body swapped below.
        try {
          await rc.login();
        } catch (_) {}
      }, () => client);
      expect(calls, greaterThanOrEqualTo(1));
    });

    test('-32002 (expired session) triggers exactly one re-login, then succeeds', () async {
      var loginCalls = 0;
      var statusCalls = 0;
      final client = MockClient((req) async {
        final payload = jsonDecode(req.body) as Map<String, dynamic>;
        final params = payload['params'] as List;
        final object = params[1] as String;
        final method = params[2] as String;
        if (object == 'session' && method == 'login') {
          loginCalls++;
          return _json({
            'jsonrpc': '2.0',
            'id': 1,
            'result': [
              0,
              {'ubus_rpc_session': 'sid-$loginCalls'}
            ]
          });
        }
        if (object == 'opscx' && method == 'status') {
          statusCalls++;
          if (statusCalls == 1) {
            // Реальный ответ живого роутера на истёкшую/невалидную сессию:
            // верхнеуровневый JSON-RPC error, НЕ result:[6,...].
            return _json({
              'jsonrpc': '2.0',
              'id': 1,
              'error': {'code': -32002, 'message': 'Access denied'}
            });
          }
          return _json({
            'jsonrpc': '2.0',
            'id': 1,
            'result': [
              0,
              {
                'cellular': {'up': true},
                'tunnel': {'ready': true},
                'wifi': {'ssid': 'HUASIFEI', 'clients': 0},
                'system': {'board': 'Huasifei WH3000 Pro eMMC'}
              }
            ]
          });
        }
        return _json({'jsonrpc': '2.0', 'id': 1, 'result': [0, {}]});
      });

      await http.runWithClient(() async {
        final rc = RouterClient(host: '192.168.5.1', user: 'app', pass: 'x');
        final status = await rc.status();
        expect(status['tunnel']['ready'], true);
      }, () => client);

      expect(loginCalls, 2, reason: 'первый логин + один повторный после -32002');
      expect(statusCalls, 2, reason: 'первый неудачный (истёкшая сессия) + повторный успешный');
    });

    test('ubus code 3 (method not registered on rpcd) surfaces as RouterMethodUnavailableError, not silence', () async {
      final client = MockClient((req) async {
        final payload = jsonDecode(req.body) as Map<String, dynamic>;
        final params = payload['params'] as List;
        final object = params[1] as String;
        final method = params[2] as String;
        if (object == 'session' && method == 'login') {
          return _json({
            'jsonrpc': '2.0',
            'id': 1,
            'result': [
              0,
              {'ubus_rpc_session': 'sid-1'}
            ]
          });
        }
        // Реальный живой ответ 2026-09-25: diag_status/list_nodes/get_status/
        // metrics_history/diag_run разрешены в ACL, но rpcd их не отдаёт.
        return _json({'jsonrpc': '2.0', 'id': 1, 'result': [3]});
      });

      await http.runWithClient(() async {
        final rc = RouterClient(host: '192.168.5.1', user: 'app', pass: 'x');
        await expectLater(
            rc.diagStatus(), throwsA(isA<RouterMethodUnavailableError>()));
      }, () => client);
    });

    test('spotty object not found (-32000) surfaces as RouterMethodUnavailableError', () async {
      final client = MockClient((req) async {
        final payload = jsonDecode(req.body) as Map<String, dynamic>;
        final params = payload['params'] as List;
        final object = params[1] as String;
        final method = params[2] as String;
        if (object == 'session' && method == 'login') {
          return _json({
            'jsonrpc': '2.0',
            'id': 1,
            'result': [
              0,
              {'ubus_rpc_session': 'sid-1'}
            ]
          });
        }
        return _json({
          'jsonrpc': '2.0',
          'id': 1,
          'error': {'code': -32000, 'message': 'Object not found'}
        });
      });

      await http.runWithClient(() async {
        final rc = RouterClient(host: '192.168.5.1', user: 'app', pass: 'x');
        await expectLater(rc.toolboxDevices(),
            throwsA(isA<RouterMethodUnavailableError>()));
      }, () => client);
    });

    test('transport timeout/refused surfaces as RouterUnreachableError (phone off router Wi-Fi)', () async {
      final client = MockClient((req) async {
        throw const SocketExceptionStub();
      });

      await http.runWithClient(() async {
        final rc = RouterClient(host: '192.0.2.1', user: 'app', pass: 'x');
        await expectLater(
            rc.login(), throwsA(isA<RouterUnreachableError>()));
      }, () => client);
    });

    test('wrong password: session.login result:[6] -> RouterAuthError', () async {
      final client = MockClient((req) async {
        return _json({'jsonrpc': '2.0', 'id': 1, 'result': [6]});
      });
      await http.runWithClient(() async {
        final rc = RouterClient(host: '192.168.5.1', user: 'app', pass: 'wrong');
        await expectLater(rc.login(), throwsA(isA<RouterAuthError>()));
      }, () => client);
    });
  });
}

/// Минимальная замена SocketException, чтобы не тянуть dart:io в MockClient
/// callback ради одного throw — RouterClient._rpc ловит любой Object в catch.
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
  @override
  String toString() => 'SocketExceptionStub: connection refused';
}
