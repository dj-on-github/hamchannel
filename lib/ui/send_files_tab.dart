import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../modem/modem_service.dart';

/// File sending: pick local files and queue them for transmission.
class SendFilesTab extends StatelessWidget {
  const SendFilesTab({super.key, required this.service});

  final ModemService service;

  Future<void> _pickAndSend(BuildContext context) async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: true,
      dialogTitle: 'Choose files to send over the radio',
      initialDirectory: service.lastDir,
    );
    if (result == null) return;
    final firstPath = result.files.first.path;
    if (firstPath != null) service.rememberDir(firstPath);
    for (final f in result.files) {
      Uint8List? bytes = f.bytes;
      if (bytes == null && f.path != null) {
        bytes = await File(f.path!).readAsBytes();
      }
      if (bytes == null) continue;
      service.sendFile(f.name, bytes);
    }
  }

  Future<void> _pickAndShare(BuildContext context) async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: true,
      dialogTitle: 'Add files to the shared folder (remote can request them)',
      initialDirectory: service.lastDir,
    );
    if (result == null) return;
    final firstPath = result.files.first.path;
    if (firstPath != null) service.rememberDir(firstPath);
    for (final f in result.files) {
      Uint8List? bytes = f.bytes;
      if (bytes == null && f.path != null) {
        bytes = await File(f.path!).readAsBytes();
      }
      if (bytes == null) continue;
      File('${service.store.sharedDir.path}/${f.name}')
          .writeAsBytesSync(bytes);
    }
    service.refresh();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final s = service;
        final outgoing =
            s.transfers.values.where((t) => !t.incoming).toList().reversed.toList();
        final shared = s.store.sharedFiles();
        final est = s.netBitRate / 8; // bytes/s
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  FilledButton.icon(
                    onPressed: s.running ? () => _pickAndSend(context) : null,
                    icon: const Icon(Icons.upload_file),
                    label: const Text('Choose files & send…'),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: () => _pickAndShare(context),
                    icon: const Icon(Icons.folder_shared),
                    label: const Text('Add to shared folder…'),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      s.running
                          ? '~${est.toStringAsFixed(0)} B/s net · a 10 kB file '
                              'takes ~${(10240 / est).toStringAsFixed(0)} s + ARQ turnarounds'
                          : 'Modem stopped — start it from the status bar.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text('Transfers', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Expanded(
                child: outgoing.isEmpty
                    ? const Center(child: Text('No outgoing transfers yet.'))
                    : ListView.builder(
                        itemCount: outgoing.length,
                        itemBuilder: (context, i) {
                          final t = outgoing[i];
                          final frac = t.chunksTotal == 0
                              ? 0.0
                              : t.chunksDone / t.chunksTotal;
                          return Card(
                            child: ListTile(
                              leading: Icon(
                                t.done
                                    ? Icons.check_circle
                                    : t.failed
                                        ? Icons.error
                                        : Icons.upload,
                                color: t.done
                                    ? Colors.lightGreen
                                    : t.failed
                                        ? Colors.redAccent
                                        : null,
                              ),
                              title: Text('${t.name} → ${t.peer}'),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  LinearProgressIndicator(value: frac),
                                  const SizedBox(height: 2),
                                  Text(t.done
                                      ? 'delivered & verified'
                                      : t.failed
                                          ? 'failed'
                                          : '${t.chunksDone}/${t.chunksTotal} chunks acknowledged'),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
              const Divider(),
              Text('Shared folder (remote can request these)',
                  style: Theme.of(context).textTheme.titleMedium),
              Text(s.store.sharedDir.path,
                  style: Theme.of(context).textTheme.bodySmall),
              SizedBox(
                height: 110,
                child: shared.isEmpty
                    ? const Center(child: Text('Shared folder is empty.'))
                    : ListView(
                        children: [
                          for (final f in shared)
                            ListTile(
                              dense: true,
                              leading: const Icon(Icons.insert_drive_file),
                              title: Text(f.uri.pathSegments.last),
                              trailing: Text('${f.lengthSync()} B'),
                            ),
                        ],
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}
