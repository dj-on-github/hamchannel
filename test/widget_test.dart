import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hamchannel/audio/audio_backend.dart';
import 'package:hamchannel/main.dart';
import 'package:hamchannel/modem/modem_service.dart';

void main() {
  testWidgets('app builds with all four tabs', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('hamchan_ui');
    final service = ModemService(
      config: AppConfig(),
      backendFactory: (_) => LoopbackAudioBackend(),
      sharedDir: Directory('${tmp.path}/shared'),
      recvDir: Directory('${tmp.path}/received'),
    );
    await tester.pumpWidget(HamChannelApp(service: service));
    expect(find.text('Messages'), findsOneWidget);
    expect(find.text('Send Files'), findsOneWidget);
    expect(find.text('Files'), findsOneWidget);
    expect(find.text('Signal Quality'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Start'), findsOneWidget);
    service.dispose();
    tmp.deleteSync(recursive: true);
  });
}
