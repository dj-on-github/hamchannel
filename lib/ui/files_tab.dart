import 'package:flutter/material.dart';

import '../modem/modem_service.dart';

/// Received files + request-a-file-from-the-remote-station.
class FilesTab extends StatefulWidget {
  const FilesTab({super.key, required this.service});

  final ModemService service;

  @override
  State<FilesTab> createState() => _FilesTabState();
}

class _FilesTabState extends State<FilesTab> {
  final _reqName = TextEditingController();

  @override
  void dispose() {
    _reqName.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.service;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final received = s.store.receivedFiles();
        final incoming =
            s.transfers.values.where((t) => t.incoming && !t.done).toList();
        final listing = s.remoteListing
            .split('\n')
            .where((l) => l.trim().isNotEmpty)
            .map((l) {
          final parts = l.split('\t');
          return (parts.first, parts.length > 1 ? parts[1] : '?');
        }).toList();

        return Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ---------------- received files ----------------
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Received files',
                        style: Theme.of(context).textTheme.titleMedium),
                    Text(s.store.recvDir.path,
                        style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 8),
                    if (incoming.isNotEmpty) ...[
                      for (final t in incoming)
                        Card(
                          child: ListTile(
                            dense: true,
                            leading: const Icon(Icons.download),
                            title: Text('${t.name} ← ${t.peer}'),
                            subtitle: LinearProgressIndicator(
                              value: t.chunksTotal == 0
                                  ? null
                                  : t.chunksDone / t.chunksTotal,
                            ),
                            trailing: Text(t.chunksTotal == 0
                                ? '…'
                                : '${t.chunksDone}/${t.chunksTotal}'),
                          ),
                        ),
                      const SizedBox(height: 8),
                    ],
                    Expanded(
                      child: received.isEmpty
                          ? const Center(child: Text('Nothing received yet.'))
                          : ListView.builder(
                              itemCount: received.length,
                              itemBuilder: (context, i) {
                                final f = received[i];
                                return ListTile(
                                  leading:
                                      const Icon(Icons.insert_drive_file),
                                  title: Text(f.uri.pathSegments.last),
                                  subtitle: Text(f.path),
                                  trailing: Text('${f.lengthSync()} B'),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
              const VerticalDivider(width: 32),
              // ---------------- request from remote ----------------
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Request from ${s.config.remoteCall}',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        OutlinedButton.icon(
                          onPressed: s.running ? s.requestListing : null,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Fetch remote file list'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: listing.isEmpty
                          ? const Center(
                              child: Text(
                                  'No remote listing yet.\nFetch the list, or request a file by name below.',
                                  textAlign: TextAlign.center))
                          : ListView.builder(
                              itemCount: listing.length,
                              itemBuilder: (context, i) {
                                final (name, size) = listing[i];
                                return ListTile(
                                  dense: true,
                                  leading: const Icon(Icons.cloud_download),
                                  title: Text(name),
                                  subtitle: Text('$size B'),
                                  trailing: FilledButton(
                                    onPressed: s.running
                                        ? () => s.requestFile(name)
                                        : null,
                                    child: const Text('Request'),
                                  ),
                                );
                              },
                            ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _reqName,
                            decoration: const InputDecoration(
                              labelText: 'Request file by name',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: s.running
                              ? () {
                                  final n = _reqName.text.trim();
                                  if (n.isNotEmpty) {
                                    s.requestFile(n);
                                    _reqName.clear();
                                  }
                                }
                              : null,
                          child: const Text('Request'),
                        ),
                      ],
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
