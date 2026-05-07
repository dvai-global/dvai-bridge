/**
 * DVAI-Bridge React Native example.
 *
 * One screen with a backend selector + a streaming chat completion sent
 * via the official `openai` node SDK pointed at the local server URL
 * returned by `DVAIBridge.start({...})`.
 *
 * The selector hides backends that don't run on the current platform —
 * iOS-only options (Foundation / CoreML / MLX) are dimmed on Android,
 * and Android-only options (MediaPipe / LiteRT) are dimmed on iOS.
 */

import { useMemo, useState } from 'react';
import {
  ActivityIndicator,
  Platform,
  Pressable,
  ScrollView,
  StatusBar,
  StyleSheet,
  Text,
  TextInput,
  useColorScheme,
  View,
} from 'react-native';
import {
  SafeAreaProvider,
  useSafeAreaInsets,
} from 'react-native-safe-area-context';
import OpenAI from 'openai';
import {
  BackendKind,
  DVAIBridge,
  type BoundServer,
} from '@dvai-bridge/react-native';

type AvailablePlatform = 'ios' | 'android' | 'both';

interface BackendOption {
  kind: BackendKind;
  label: string;
  available: AvailablePlatform;
  description: string;
  /**
   * Default model path. Real apps download or side-load these — this
   * field is just a placeholder the user can override.
   */
  defaultModelPath: string;
}

const BACKENDS: BackendOption[] = [
  {
    kind: BackendKind.Llama,
    label: 'Llama (llama.cpp)',
    available: 'both',
    description: 'GGUF + Metal/Vulkan. Broadest coverage.',
    defaultModelPath: '/path/to/llama-3.2-1b-instruct.Q4_K_M.gguf',
  },
  {
    kind: BackendKind.Foundation,
    label: 'Apple Foundation Models',
    available: 'ios',
    description: 'iOS 26+ on-device, no model download.',
    defaultModelPath: '',
  },
  {
    kind: BackendKind.CoreML,
    label: 'CoreML',
    available: 'ios',
    description: 'Apple Neural Engine, .mlmodelc / .mlpackage.',
    defaultModelPath: '/path/to/Llama-3.2-1B.mlpackage',
  },
  {
    kind: BackendKind.MLX,
    label: 'MLX',
    available: 'ios',
    description: 'Apple Silicon only. SwiftPM-only.',
    defaultModelPath: 'mlx-community/Llama-3.2-3B-Instruct-4bit',
  },
  {
    kind: BackendKind.MediaPipe,
    label: 'MediaPipe LLM',
    available: 'android',
    description: '.task bundle, vision-capable Gemma support.',
    defaultModelPath: '/data/data/com.dvaibridgern/files/dvai-models/gemma.task',
  },
  {
    kind: BackendKind.LiteRT,
    label: 'LiteRT',
    available: 'android',
    description: '.tflite / .litertlm; pure-Kotlin tokenizer.',
    defaultModelPath: '/data/data/com.dvaibridgern/files/dvai-models/llama.tflite',
  },
];

function isOnPlatform(opt: BackendOption): boolean {
  if (opt.available === 'both') return true;
  return Platform.OS === opt.available;
}

function App() {
  const isDarkMode = useColorScheme() === 'dark';
  return (
    <SafeAreaProvider>
      <StatusBar barStyle={isDarkMode ? 'light-content' : 'dark-content'} />
      <AppContent />
    </SafeAreaProvider>
  );
}

function AppContent() {
  const insets = useSafeAreaInsets();
  const [selected, setSelected] = useState<BackendKind>(BackendKind.Llama);
  const [modelPath, setModelPath] = useState<string>(
    BACKENDS.find((b) => b.kind === BackendKind.Llama)!.defaultModelPath,
  );
  const [prompt, setPrompt] = useState<string>('Why is the sky blue?');
  const [output, setOutput] = useState<string>('');
  const [busy, setBusy] = useState<boolean>(false);
  const [status, setStatus] = useState<string>('Idle.');
  const [server, setServer] = useState<BoundServer | null>(null);

  const selectedOption = useMemo(
    () => BACKENDS.find((b) => b.kind === selected)!,
    [selected],
  );

  const onSelect = (kind: BackendKind) => {
    setSelected(kind);
    const opt = BACKENDS.find((b) => b.kind === kind)!;
    setModelPath(opt.defaultModelPath);
  };

  const onStart = async () => {
    setBusy(true);
    setStatus(`Starting ${selectedOption.label}…`);
    try {
      const bound = await DVAIBridge.start({
        backend: selected,
        modelPath: modelPath ? modelPath : undefined,
        contextSize: 2048,
      });
      setServer(bound);
      setStatus(`Ready: ${bound.baseUrl} (${bound.modelId})`);
    } catch (err) {
      setStatus(`Start failed: ${(err as Error).message}`);
    } finally {
      setBusy(false);
    }
  };

  const onStop = async () => {
    setBusy(true);
    try {
      await DVAIBridge.stop();
      setServer(null);
      setStatus('Stopped.');
    } catch (err) {
      setStatus(`Stop failed: ${(err as Error).message}`);
    } finally {
      setBusy(false);
    }
  };

  const onSend = async () => {
    if (!server) {
      setStatus('Start the server first.');
      return;
    }
    setBusy(true);
    setOutput('');
    setStatus('Streaming…');
    try {
      const client = new OpenAI({
        baseURL: server.baseUrl,
        apiKey: 'local-bypass-key',
        dangerouslyAllowBrowser: true,
      });
      const stream = await client.chat.completions.create({
        model: server.modelId,
        messages: [{ role: 'user', content: prompt }],
        stream: true,
      });
      let full = '';
      for await (const chunk of stream) {
        const piece = chunk.choices[0]?.delta?.content ?? '';
        full += piece;
        setOutput(full);
      }
      setStatus('Done.');
    } catch (err) {
      setStatus(`Stream failed: ${(err as Error).message}`);
    } finally {
      setBusy(false);
    }
  };

  return (
    <ScrollView
      style={[styles.container, { paddingTop: insets.top }]}
      contentContainerStyle={styles.content}
    >
      <Text style={styles.title}>DVAI-Bridge — React Native</Text>
      <Text style={styles.subtitle}>{status}</Text>

      <Text style={styles.sectionLabel}>Backend</Text>
      <View style={styles.backendGrid}>
        {BACKENDS.map((opt) => {
          const enabled = isOnPlatform(opt);
          const isSelected = selected === opt.kind;
          return (
            <Pressable
              key={opt.kind}
              disabled={!enabled || busy}
              onPress={() => onSelect(opt.kind)}
              style={[
                styles.backendOption,
                !enabled && styles.backendOptionDisabled,
                isSelected && styles.backendOptionSelected,
              ]}
            >
              <Text style={styles.backendLabel}>{opt.label}</Text>
              <Text style={styles.backendHint}>{opt.description}</Text>
              {!enabled && (
                <Text style={styles.backendUnavail}>
                  {opt.available === 'ios'
                    ? 'iOS only'
                    : opt.available === 'android'
                      ? 'Android only'
                      : ''}
                </Text>
              )}
            </Pressable>
          );
        })}
      </View>

      <Text style={styles.sectionLabel}>Model path</Text>
      <TextInput
        value={modelPath}
        onChangeText={setModelPath}
        placeholder={selectedOption.defaultModelPath}
        autoCapitalize="none"
        autoCorrect={false}
        style={styles.input}
      />

      <View style={styles.row}>
        <Pressable
          disabled={busy || !!server}
          onPress={onStart}
          style={[styles.btn, (busy || !!server) && styles.btnDisabled]}
        >
          <Text style={styles.btnText}>Start</Text>
        </Pressable>
        <Pressable
          disabled={busy || !server}
          onPress={onStop}
          style={[styles.btn, (busy || !server) && styles.btnDisabled]}
        >
          <Text style={styles.btnText}>Stop</Text>
        </Pressable>
      </View>

      <Text style={styles.sectionLabel}>Prompt</Text>
      <TextInput
        value={prompt}
        onChangeText={setPrompt}
        multiline
        style={[styles.input, styles.textArea]}
      />
      <Pressable
        disabled={busy || !server}
        onPress={onSend}
        style={[styles.btn, (busy || !server) && styles.btnDisabled]}
      >
        {busy ? <ActivityIndicator /> : <Text style={styles.btnText}>Send</Text>}
      </Pressable>

      <Text style={styles.sectionLabel}>Response</Text>
      <View style={styles.responseBox}>
        <Text style={styles.responseText}>{output}</Text>
      </View>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: '#0b0e14' },
  content: { padding: 16, gap: 12 },
  title: { fontSize: 22, fontWeight: '600', color: '#e6e6e6' },
  subtitle: { fontSize: 13, color: '#9aa4b2' },
  sectionLabel: {
    fontSize: 13,
    color: '#9aa4b2',
    textTransform: 'uppercase',
    letterSpacing: 0.5,
    marginTop: 8,
  },
  backendGrid: { gap: 8 },
  backendOption: {
    padding: 12,
    backgroundColor: '#161b22',
    borderRadius: 10,
    borderWidth: 1,
    borderColor: '#2a313c',
  },
  backendOptionSelected: { borderColor: '#2f6feb' },
  backendOptionDisabled: { opacity: 0.4 },
  backendLabel: { color: '#e6e6e6', fontSize: 15, fontWeight: '500' },
  backendHint: { color: '#9aa4b2', fontSize: 12, marginTop: 2 },
  backendUnavail: { color: '#ef6464', fontSize: 11, marginTop: 4 },
  input: {
    backgroundColor: '#161b22',
    color: '#e6e6e6',
    borderRadius: 8,
    padding: 12,
    fontSize: 14,
    borderWidth: 1,
    borderColor: '#2a313c',
  },
  textArea: { minHeight: 80, textAlignVertical: 'top' },
  row: { flexDirection: 'row', gap: 8 },
  btn: {
    flex: 1,
    backgroundColor: '#2f6feb',
    paddingVertical: 12,
    borderRadius: 8,
    alignItems: 'center',
  },
  btnDisabled: { backgroundColor: '#2a313c' },
  btnText: { color: '#fff', fontWeight: '600' },
  responseBox: {
    minHeight: 120,
    backgroundColor: '#161b22',
    borderRadius: 8,
    padding: 12,
    borderWidth: 1,
    borderColor: '#2a313c',
  },
  responseText: { color: '#e6e6e6', fontSize: 14, lineHeight: 20 },
});

export default App;
