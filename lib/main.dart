import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audio/audio_backend.dart';
import 'audio/real_audio.dart';
import 'modem/modem.dart';
import 'modem/modem_service.dart';
import 'ui/channel_tab.dart';
import 'ui/files_tab.dart';
import 'ui/messages_tab.dart';
import 'ui/send_files_tab.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final prefs = await SharedPreferences.getInstance();
  final cfgJson = prefs.getString('config');
  final config = cfgJson != null
      ? AppConfig.fromJson(jsonDecode(cfgJson) as Map<String, Object?>)
      : AppConfig();

  final docs = await getApplicationDocumentsDirectory();
  final base = Directory('${docs.path}/hamchannel');

  final service = ModemService(
    config: config,
    backendFactory: (cfg) => cfg.useLoopback
        ? LoopbackAudioBackend()
        : RealAudioBackend(
            inputDeviceId: cfg.inputDeviceId,
            inputDeviceLabel: cfg.inputDeviceLabel,
            outputDeviceName: cfg.outputDeviceName,
          ),
    sharedDir: Directory('${base.path}/shared'),
    recvDir: Directory('${base.path}/received'),
    onPersistConfig: () =>
        prefs.setString('config', jsonEncode(config.toJson())),
  );

  runApp(HamChannelApp(service: service));
}

class HamChannelApp extends StatelessWidget {
  const HamChannelApp({super.key, required this.service});

  final ModemService service;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HamChannel',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2E7D32),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: HomeScreen(service: service),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.service});

  final ModemService service;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs =
      TabController(length: 4, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.service;
    return Scaffold(
      appBar: AppBar(
        title: const Text('HamChannel — OFDM/LDPC soundcard modem'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(icon: Icon(Icons.chat), text: 'Messages'),
            Tab(icon: Icon(Icons.upload_file), text: 'Send Files'),
            Tab(icon: Icon(Icons.folder_shared), text: 'Files'),
            Tab(icon: Icon(Icons.tune), text: 'Channel'),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                MessagesTab(service: s),
                SendFilesTab(service: s),
                FilesTab(service: s),
                ChannelTab(service: s),
              ],
            ),
          ),
          StatusBar(service: s),
        ],
      ),
    );
  }
}

class StatusBar extends StatelessWidget {
  const StatusBar({super.key, required this.service});

  final ModemService service;

  Future<void> _pickAndReadPcm(ModemService s) async {
    final res = await FilePicker.platform.pickFiles(
      dialogTitle: 'Read a PCM file into the receiver',
      initialDirectory: s.lastDir,
    );
    final path = res?.files.single.path;
    if (path != null) {
      s.rememberDir(path);
      // Fire and forget; progress shows on the button and in the log.
      unawaited(s.readPcmFile(path));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final s = service;
        final theme = Theme.of(context);
        Color stateColor;
        String stateText;
        if (!s.running) {
          stateColor = Colors.grey;
          stateText = 'STOPPED';
        } else if (s.transmitting) {
          stateColor = Colors.redAccent;
          stateText = 'TX';
        } else if (s.rxState == RxState.collecting) {
          stateColor = Colors.amber;
          stateText = 'RX SIGNAL';
        } else {
          stateColor = Colors.lightGreen;
          stateText = 'LISTENING';
        }
        final level = (s.rxLevel * 100).clamp(0, 100).toDouble();
        return Material(
          color: theme.colorScheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: stateColor.withValues(alpha: 0.25),
                    border: Border.all(color: stateColor),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(stateText,
                      style: TextStyle(
                          color: stateColor, fontWeight: FontWeight.bold)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: Text(
                    s.lastError.isNotEmpty ? s.lastError : s.statusLine,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: s.lastError.isNotEmpty
                          ? Colors.redAccent
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                const Text('RX '),
                SizedBox(
                  width: 90,
                  child: LinearProgressIndicator(
                    value: (level / 100).clamp(0.0, 1.0),
                    minHeight: 8,
                  ),
                ),
                const SizedBox(width: 12),
                Text('SNR ${s.lastSnrDb.toStringAsFixed(1)} dB'),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: (!s.running || s.pcmReading)
                      ? null
                      : () => _pickAndReadPcm(s),
                  icon: s.pcmReading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.play_circle_outline),
                  label: const Text('Read PCM'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: () => s.running ? s.stop() : s.start(),
                  icon: Icon(s.running ? Icons.stop : Icons.play_arrow),
                  label: Text(s.running ? 'Stop' : 'Start'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
