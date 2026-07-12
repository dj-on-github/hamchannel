import 'package:flutter/material.dart';

import '../modem/modem_service.dart';

/// Messaging terminal: type a message and send it all at once.
class MessagesTab extends StatefulWidget {
  const MessagesTab({super.key, required this.service});

  final ModemService service;

  @override
  State<MessagesTab> createState() => _MessagesTabState();
}

class _MessagesTabState extends State<MessagesTab> {
  final _text = TextEditingController();
  final _scroll = ScrollController();
  bool _showLog = false;

  void _send() {
    final t = _text.text.trim();
    if (t.isEmpty) return;
    widget.service.sendMessage(t);
    _text.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.service;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        return Column(
          children: [
            Expanded(
              child: s.chat.isEmpty
                  ? const Center(
                      child: Text(
                          'No traffic yet.\nStart the modem and type a message below.',
                          textAlign: TextAlign.center))
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.all(12),
                      itemCount: s.chat.length,
                      itemBuilder: (context, i) {
                        final c = s.chat[i];
                        final time =
                            '${c.at.hour.toString().padLeft(2, '0')}:${c.at.minute.toString().padLeft(2, '0')}';
                        return Align(
                          alignment: c.outgoing
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: Container(
                            margin: const EdgeInsets.symmetric(vertical: 3),
                            padding: const EdgeInsets.all(10),
                            constraints: const BoxConstraints(maxWidth: 520),
                            decoration: BoxDecoration(
                              color: c.outgoing
                                  ? Theme.of(context)
                                      .colorScheme
                                      .primaryContainer
                                  : Theme.of(context)
                                      .colorScheme
                                      .surfaceContainerHigh,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${c.from}  $time'
                                  '${c.outgoing && c.status.isNotEmpty ? '  ·  ${c.status}' : ''}',
                                  style: Theme.of(context)
                                      .textTheme
                                      .labelSmall
                                      ?.copyWith(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant),
                                ),
                                const SizedBox(height: 2),
                                SelectableText(c.text,
                                    style: const TextStyle(
                                        fontFamily: 'monospace')),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
            if (_showLog)
              Container(
                height: 140,
                width: double.infinity,
                color: Colors.black,
                padding: const EdgeInsets.all(8),
                child: ListView.builder(
                  reverse: true,
                  itemCount: s.log.length,
                  itemBuilder: (context, i) => Text(
                    s.log[s.log.length - 1 - i],
                    style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: Colors.greenAccent),
                  ),
                ),
              ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(
                    tooltip: 'Show modem log',
                    icon: Icon(_showLog
                        ? Icons.terminal
                        : Icons.terminal_outlined),
                    onPressed: () => setState(() => _showLog = !_showLog),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _text,
                      minLines: 1,
                      maxLines: 6,
                      style: const TextStyle(fontFamily: 'monospace'),
                      decoration: InputDecoration(
                        hintText: s.running
                            ? 'Type message to ${s.config.remoteCall} — sent as one burst'
                            : 'Start the modem first (bottom right)',
                        border: const OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: s.running ? _send : null,
                    icon: const Icon(Icons.send),
                    label: const Text('Send'),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
