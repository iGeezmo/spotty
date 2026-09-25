// Screenshots of the four new toolbox screens in mock mode, for the
// install-plan receipt (not asserted against real router data — the mock
// RPCs live in RouterClient._mockRpc, object "spotty").
//
// Run: flutter test --update-goldens test/toolbox_goldens_test.dart
// Goldens land under test/goldens/*.png.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huasifei_remote/main.dart';
import 'package:huasifei_remote/toolbox/screens.dart';

Widget _wrap(Widget child) => MaterialApp(
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF5B4FE9)),
        useMaterial3: true,
      ),
      home: child,
    );

void main() {
  final client = RouterClient(host: 'mock', user: 'app', pass: 'x', mock: true);

  testWidgets('devices screen', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpWidget(_wrap(DevicesScreen(client: client)));
    await tester.pumpAndSettle();
    await expectLater(find.byType(DevicesScreen), matchesGoldenFile('goldens/devices.png'));
  });

  testWidgets('guest wifi screen', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpWidget(_wrap(GuestWifiScreen(client: client)));
    await tester.pumpAndSettle();
    await expectLater(find.byType(GuestWifiScreen), matchesGoldenFile('goldens/guest_wifi.png'));
  });

  testWidgets('events screen', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpWidget(_wrap(EventsScreen(client: client)));
    await tester.pumpAndSettle();
    await expectLater(find.byType(EventsScreen), matchesGoldenFile('goldens/events.png'));
  });

  testWidgets('mode screen', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpWidget(_wrap(ModeScreen(client: client)));
    await tester.pumpAndSettle();
    await expectLater(find.byType(ModeScreen), matchesGoldenFile('goldens/mode.png'));
  });
}
