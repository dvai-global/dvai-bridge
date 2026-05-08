// v3.2 — Flutter parallel to Android's CapabilityPrecheckTest.kt,
// iOS CapabilityPrecheckTests.swift, and .NET CapabilityPrecheckTests.cs.
//
// The Flutter SDK doesn't run the heuristic itself — `assessHardware()`
// is a Pigeon platform-channel call that delegates to the native iOS /
// Android SDK and gets back a `HardwareAssessmentMessage`. This test
// covers the Dart-side decoding contract:
//
//   - Wire-format strings round-trip through every public enum.
//   - `HardwareAssessment.fromMessage` decodes the Pigeon shape correctly.
//   - Unknown wire strings fall back to the documented safe defaults
//     (PrecheckMode.tooWeak, GpuClass.integrated, CpuClass.mid).
//   - Equality + hashCode behave as expected for `DeviceCapabilityHints`
//     and `HardwareAssessment` (consumer apps may key caches off these).

import 'package:dvai_bridge/dvai_bridge.dart';
import 'package:dvai_bridge/src/messages.g.dart' as wire;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PrecheckMode wire format', () {
    test('every enum value round-trips through wire / fromWire', () {
      for (final PrecheckMode m in PrecheckMode.values) {
        expect(PrecheckMode.fromWire(m.wire), m);
      }
    });

    test('wire strings match cross-platform kebab-case contract', () {
      expect(PrecheckMode.ok.wire, 'ok');
      expect(PrecheckMode.offloadOnly.wire, 'offload-only');
      expect(PrecheckMode.tooWeak.wire, 'too-weak');
    });

    test('unknown wire string falls back to tooWeak (under-promise)', () {
      expect(PrecheckMode.fromWire('mystery'), PrecheckMode.tooWeak);
      expect(PrecheckMode.fromWire(''), PrecheckMode.tooWeak);
    });
  });

  group('GpuClass wire format', () {
    test('every enum value round-trips through wire / fromWire', () {
      for (final GpuClass g in GpuClass.values) {
        expect(GpuClass.fromWire(g.wire), g);
      }
    });

    test('wire strings include kebab-case appleSilicon', () {
      expect(GpuClass.none.wire, 'none');
      expect(GpuClass.integrated.wire, 'integrated');
      expect(GpuClass.discrete.wire, 'discrete');
      expect(GpuClass.appleSilicon.wire, 'apple-silicon');
    });

    test('unknown wire string falls back to integrated', () {
      expect(GpuClass.fromWire('apple_silicon'), GpuClass.integrated);
      expect(GpuClass.fromWire('quantum'), GpuClass.integrated);
    });
  });

  group('CpuClass wire format', () {
    test('every enum value round-trips through wire / fromWire', () {
      for (final CpuClass c in CpuClass.values) {
        expect(CpuClass.fromWire(c.wire), c);
      }
    });

    test('wire strings are low / mid / high', () {
      expect(CpuClass.low.wire, 'low');
      expect(CpuClass.mid.wire, 'mid');
      expect(CpuClass.high.wire, 'high');
    });

    test('unknown wire string falls back to mid', () {
      expect(CpuClass.fromWire('ultra'), CpuClass.mid);
      expect(CpuClass.fromWire(''), CpuClass.mid);
    });
  });

  group('DeviceCapabilityHints', () {
    test('equality compares all four fields', () {
      const a = DeviceCapabilityHints(
        hasNpu: true,
        ramGb: 16,
        gpuClass: GpuClass.appleSilicon,
        cpuClass: CpuClass.high,
      );
      const b = DeviceCapabilityHints(
        hasNpu: true,
        ramGb: 16,
        gpuClass: GpuClass.appleSilicon,
        cpuClass: CpuClass.high,
      );
      const c = DeviceCapabilityHints(
        hasNpu: false,
        ramGb: 16,
        gpuClass: GpuClass.appleSilicon,
        cpuClass: CpuClass.high,
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(c)));
    });

    test('toString includes wire-format enum strings', () {
      const h = DeviceCapabilityHints(
        hasNpu: false,
        ramGb: 8,
        gpuClass: GpuClass.integrated,
        cpuClass: CpuClass.mid,
      );
      final s = h.toString();
      expect(s, contains('integrated'));
      expect(s, contains('mid'));
      expect(s, contains('hasNpu: false'));
      expect(s, contains('ramGb: 8'));
    });
  });

  group('HardwareAssessment.fromMessage', () {
    test('decodes a high-end ok assessment', () {
      final msg = wire.HardwareAssessmentMessage(
        mode: 'ok',
        tokPerSec: 42.5,
        reason: '42.5 tok/s — ok.',
        hasNpu: false,
        ramGb: 32,
        gpuClass: 'discrete',
        cpuClass: 'high',
      );
      final a = HardwareAssessment.fromMessage(msg);
      expect(a.mode, PrecheckMode.ok);
      expect(a.tokPerSec, 42.5);
      expect(a.reason, '42.5 tok/s — ok.');
      expect(a.hints.hasNpu, isFalse);
      expect(a.hints.ramGb, 32);
      expect(a.hints.gpuClass, GpuClass.discrete);
      expect(a.hints.cpuClass, CpuClass.high);
    });

    test('decodes an offload-only mid-range assessment', () {
      final msg = wire.HardwareAssessmentMessage(
        mode: 'offload-only',
        tokPerSec: 8.0,
        reason: '8.0 tok/s — below comfort, offload only.',
        hasNpu: false,
        ramGb: 8,
        gpuClass: 'integrated',
        cpuClass: 'mid',
      );
      final a = HardwareAssessment.fromMessage(msg);
      expect(a.mode, PrecheckMode.offloadOnly);
      expect(a.tokPerSec, 8.0);
      expect(a.hints.gpuClass, GpuClass.integrated);
      expect(a.hints.cpuClass, CpuClass.mid);
    });

    test('decodes a too-weak assessment', () {
      final msg = wire.HardwareAssessmentMessage(
        mode: 'too-weak',
        tokPerSec: 0.5,
        reason: '0.5 tok/s — too weak.',
        hasNpu: false,
        ramGb: 2,
        gpuClass: 'none',
        cpuClass: 'low',
      );
      final a = HardwareAssessment.fromMessage(msg);
      expect(a.mode, PrecheckMode.tooWeak);
      expect(a.tokPerSec, lessThan(3.0));
      expect(a.hints.gpuClass, GpuClass.none);
      expect(a.hints.cpuClass, CpuClass.low);
      expect(a.hints.hasNpu, isFalse);
    });

    test('apple-silicon class is decoded', () {
      final msg = wire.HardwareAssessmentMessage(
        mode: 'ok',
        tokPerSec: 50.0,
        reason: 'apple silicon',
        hasNpu: true,
        ramGb: 16,
        gpuClass: 'apple-silicon',
        cpuClass: 'high',
      );
      final a = HardwareAssessment.fromMessage(msg);
      expect(a.hints.gpuClass, GpuClass.appleSilicon);
      expect(a.hints.hasNpu, isTrue);
    });

    test('unknown mode wire string falls back to tooWeak (safe default)', () {
      final msg = wire.HardwareAssessmentMessage(
        mode: 'rocket-fuel',
        tokPerSec: 100.0,
        reason: 'native sent something we do not recognise',
        hasNpu: true,
        ramGb: 64,
        gpuClass: 'discrete',
        cpuClass: 'high',
      );
      final a = HardwareAssessment.fromMessage(msg);
      // Unknown mode → tooWeak. Forces consumers down the bail path
      // rather than silently letting an unrecognised native build claim
      // "ok" — better to under-promise than to over-promise.
      expect(a.mode, PrecheckMode.tooWeak);
    });
  });

  group('HardwareAssessment equality', () {
    test('value-equal assessments are ==', () {
      const hints = DeviceCapabilityHints(
        hasNpu: false,
        ramGb: 16,
        gpuClass: GpuClass.discrete,
        cpuClass: CpuClass.high,
      );
      const a = HardwareAssessment(
        mode: PrecheckMode.ok,
        tokPerSec: 30.0,
        reason: '30 tok/s — ok.',
        hints: hints,
      );
      const b = HardwareAssessment(
        mode: PrecheckMode.ok,
        tokPerSec: 30.0,
        reason: '30 tok/s — ok.',
        hints: hints,
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('different mode breaks equality', () {
      const hints = DeviceCapabilityHints(
        hasNpu: false,
        ramGb: 8,
        gpuClass: GpuClass.integrated,
        cpuClass: CpuClass.mid,
      );
      const a = HardwareAssessment(
        mode: PrecheckMode.offloadOnly,
        tokPerSec: 8.0,
        reason: 'r',
        hints: hints,
      );
      const b = HardwareAssessment(
        mode: PrecheckMode.ok,
        tokPerSec: 8.0,
        reason: 'r',
        hints: hints,
      );
      expect(a, isNot(equals(b)));
    });
  });
}
