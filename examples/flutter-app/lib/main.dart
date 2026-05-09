// DVAI-Bridge Flutter example.
//
// One screen with a backend dropdown (Llama / Foundation / CoreML / MLX /
// MediaPipe / LiteRT). Backends that don't run on the current platform
// are disabled in the dropdown. After Start succeeds, the prompt is sent
// as a streaming chat completion through `dart:io`'s `HttpClient`
// pointed at the local server URL.
//
// v3.2.1 — distributed-inference pattern. Flutter delegates to the
// native iOS / Android SDKs through Pigeon channels, so the same
// pre-init capability gate + paired-Hub offload pattern is exposed
// via `DvaiBridge.assessHardware()` +
// `DvaiBridge.start(StartOptions(offload: ...))` +
// `DvaiBridge.initiatePairing(peer)`. Reference flow:
// `examples/ios-offload-dogfood`. Combine the existing backend
// dropdown with the precheck branch to produce an offload-aware UX.

import 'dart:async';
import 'dart:convert';
import 'dart:io'
    show ContentType, HttpClient, HttpClientRequest, HttpClientResponse, Platform;

import 'package:dvai_bridge/dvai_bridge.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

void main() {
  runApp(const DvaiBridgeExampleApp());
}

class DvaiBridgeExampleApp extends StatelessWidget {
  const DvaiBridgeExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DVAI-Bridge Flutter',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.dark,
        ),
      ),
      home: const HomePage(),
    );
  }
}

class _BackendOption {
  const _BackendOption({
    required this.kind,
    required this.label,
    required this.platforms,
    required this.defaultModelPath,
  });

  final BackendKind kind;
  final String label;
  // Either {'ios','android'}, {'ios'}, or {'android'}.
  final Set<String> platforms;
  final String defaultModelPath;
}

const List<_BackendOption> _backends = <_BackendOption>[
  _BackendOption(
    kind: BackendKind.llama,
    label: 'Llama (llama.cpp)',
    platforms: <String>{'ios', 'android'},
    defaultModelPath: '/path/to/llama-3.2-1b-instruct.Q4_K_M.gguf',
  ),
  _BackendOption(
    kind: BackendKind.foundation,
    label: 'Apple Foundation Models',
    platforms: <String>{'ios'},
    defaultModelPath: '',
  ),
  _BackendOption(
    kind: BackendKind.coreml,
    label: 'CoreML',
    platforms: <String>{'ios'},
    defaultModelPath: '/path/to/Llama-3.2-1B.mlpackage',
  ),
  _BackendOption(
    kind: BackendKind.mlx,
    label: 'MLX',
    platforms: <String>{'ios'},
    defaultModelPath: 'mlx-community/Llama-3.2-3B-Instruct-4bit',
  ),
  _BackendOption(
    kind: BackendKind.mediapipe,
    label: 'MediaPipe LLM',
    platforms: <String>{'android'},
    defaultModelPath: '/data/data/co.deepvoiceai.bridge.example.flutter_app/files/dvai-models/gemma.task',
  ),
  _BackendOption(
    kind: BackendKind.litert,
    label: 'LiteRT',
    platforms: <String>{'android'},
    defaultModelPath: '/data/data/co.deepvoiceai.bridge.example.flutter_app/files/dvai-models/llama.tflite',
  ),
];

String _hostPlatform() {
  if (kIsWeb) return 'web';
  if (Platform.isIOS) return 'ios';
  if (Platform.isAndroid) return 'android';
  return 'other';
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final TextEditingController _modelPath;
  late final TextEditingController _prompt;
  _BackendOption _selected = _backends.first;
  String _output = '';
  String _streamStatus = 'Idle.';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _modelPath = TextEditingController(text: _selected.defaultModelPath);
    _prompt = TextEditingController(text: 'Why is the sky blue?');
  }

  @override
  void dispose() {
    _modelPath.dispose();
    _prompt.dispose();
    super.dispose();
  }

  void _onSelect(_BackendOption? opt) {
    if (opt == null) return;
    setState(() {
      _selected = opt;
      _modelPath.text = opt.defaultModelPath;
    });
  }

  Future<void> _start() async {
    setState(() => _busy = true);
    try {
      final BoundServer server = await DVAIBridge.instance.start(
        StartOptions(
          backend: _selected.kind,
          modelPath: _modelPath.text.isEmpty ? null : _modelPath.text,
          contextSize: 2048,
        ),
      );
      setState(() {
        _streamStatus = 'Ready: ${server.baseUrl} (${server.modelId})';
      });
    } catch (err) {
      setState(() => _streamStatus = 'Start failed: $err');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _stop() async {
    setState(() => _busy = true);
    try {
      await DVAIBridge.instance.stop();
      setState(() => _streamStatus = 'Stopped.');
    } catch (err) {
      setState(() => _streamStatus = 'Stop failed: $err');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _send() async {
    final StatusInfo info = await DVAIBridge.instance.status();
    if (!info.running || info.baseUrl == null || info.modelId == null) {
      setState(() => _streamStatus = 'Start the server first.');
      return;
    }
    setState(() {
      _output = '';
      _streamStatus = 'Streaming…';
      _busy = true;
    });

    final HttpClient client = HttpClient();
    try {
      final Uri url = Uri.parse('${info.baseUrl}/chat/completions');
      final HttpClientRequest req = await client.postUrl(url);
      req.headers.contentType =
          ContentType('application', 'json', charset: 'utf-8');
      final String body = jsonEncode(<String, Object?>{
        'model': info.modelId,
        'messages': <Map<String, String>>[
          <String, String>{'role': 'user', 'content': _prompt.text},
        ],
        'stream': true,
      });
      req.add(utf8.encode(body));
      final HttpClientResponse res = await req.close();

      String buffer = '';
      await for (final List<int> chunk in res) {
        buffer += utf8.decode(chunk);
        while (true) {
          final int sep = buffer.indexOf('\n\n');
          if (sep == -1) break;
          final String evt = buffer.substring(0, sep);
          buffer = buffer.substring(sep + 2);
          for (final String line in evt.split('\n')) {
            if (!line.startsWith('data:')) continue;
            final String payload = line.substring(5).trim();
            if (payload == '[DONE]') {
              setState(() => _streamStatus = 'Done.');
              return;
            }
            try {
              final Map<String, dynamic> json =
                  jsonDecode(payload) as Map<String, dynamic>;
              final List<dynamic>? choices =
                  json['choices'] as List<dynamic>?;
              if (choices == null || choices.isEmpty) continue;
              final Map<String, dynamic>? delta =
                  (choices[0] as Map<String, dynamic>)['delta']
                      as Map<String, dynamic>?;
              final String piece = delta?['content'] as String? ?? '';
              if (piece.isNotEmpty) {
                setState(() => _output += piece);
              }
            } on FormatException {
              // Ignore non-JSON keepalives.
            }
          }
        }
      }
      setState(() => _streamStatus = 'Done.');
    } catch (err) {
      setState(() => _streamStatus = 'Stream failed: $err');
    } finally {
      client.close(force: true);
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final String host = _hostPlatform();
    return Scaffold(
      appBar: AppBar(title: const Text('DVAI-Bridge — Flutter')),
      body: SafeArea(
        child: StreamBuilder<DVAIBridgeState>(
          stream: DVAIBridge.instance.stateStream,
          builder: (BuildContext ctx, AsyncSnapshot<DVAIBridgeState> snap) {
            final DVAIBridgeState? state = snap.data;
            return Padding(
              padding: const EdgeInsets.all(16),
              child: ListView(
                children: <Widget>[
                  Text(
                    state?.isReady == true
                        ? 'Bridge: ready (${state!.backend?.name})'
                        : _streamStatus,
                    style: Theme.of(ctx).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 12),
                  const Text('Backend'),
                  DropdownButton<_BackendOption>(
                    isExpanded: true,
                    value: _selected,
                    onChanged: _busy ? null : _onSelect,
                    items: _backends.map((_BackendOption opt) {
                      final bool enabled = opt.platforms.contains(host);
                      return DropdownMenuItem<_BackendOption>(
                        value: opt,
                        enabled: enabled,
                        child: Text(
                          enabled
                              ? opt.label
                              : '${opt.label} (not on ${host == 'ios' ? 'Android' : 'iOS'})',
                          style: TextStyle(
                            color: enabled ? null : Colors.grey,
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 12),
                  const Text('Model path'),
                  TextField(
                    controller: _modelPath,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: FilledButton(
                          onPressed: _busy ? null : _start,
                          child: const Text('Start'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _busy ? null : _stop,
                          child: const Text('Stop'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Text('Prompt'),
                  TextField(
                    controller: _prompt,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  FilledButton(
                    onPressed: _busy ? null : _send,
                    child: const Text('Send'),
                  ),
                  const SizedBox(height: 16),
                  const Text('Response'),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(_output.isEmpty ? '—' : _output),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
