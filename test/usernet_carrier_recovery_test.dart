// SPDX-FileCopyrightText: 2026 Ivan Zorin <creator@localzet.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:fl_clash/usernet/services/usernet_fabric_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final start = DateTime.utc(2026, 9, 16);

  test('brief call reconnect does not restart the carrier', () {
    expect(
      shouldRestartUserNetCarrier(
        'RECONNECTING',
        start,
        start.add(const Duration(seconds: 29)),
      ),
      isFalse,
    );
  });

  test('stalled call rotates after the recovery window', () {
    expect(
      shouldRestartUserNetCarrier(
        'TUNNEL_LOST',
        start,
        start.add(const Duration(seconds: 30)),
      ),
      isTrue,
    );
  });

  for (final status in [
    'STARTING',
    'CONNECTING',
    'CONTROL_CONNECTED',
    'WORK_SESSION_READY',
    'TRANSPORT_STARTING',
    'TRANSPORT_VERIFYING',
  ]) {
    test('$status allows both call handshakes before rotating', () {
      expect(
        shouldRestartUserNetCarrier(
          status,
          start,
          start.add(const Duration(seconds: 119)),
        ),
        isFalse,
      );
      expect(
        shouldRestartUserNetCarrier(
          status,
          start,
          start.add(const Duration(minutes: 2)),
        ),
        isTrue,
      );
    });
  }

  test('fatal relay error rotates immediately', () {
    expect(
      shouldRestartUserNetCarrier('ERROR:RELAY_OUTPUT', start, start),
      isTrue,
    );
  });

  test('a changed carrier reapplies the profile only once', () async {
    final handover = UserNetNetworkHandover();
    var active = false;
    var applies = 0;
    Future<void> run(bool next) => handover.run(
      profileId: 'one',
      isCurrent: () => true,
      fabricActive: () => active,
      probe: () async => active = next,
      apply: () async {
        applies++;
        return true;
      },
    );
    await run(true);
    await run(true);
    await run(false);
    expect(applies, 2);
  });

  test(
    'a superseded probe carries its transition to the latest event',
    () async {
      final handover = UserNetNetworkHandover();
      final started = Completer<void>();
      final complete = Completer<void>();
      var active = false;
      var applies = 0;
      final first = handover.run(
        profileId: 'one',
        isCurrent: () => true,
        fabricActive: () => active,
        probe: () async {
          started.complete();
          await complete.future;
          active = true;
        },
        apply: () async {
          applies++;
          return true;
        },
      );
      await started.future;
      final second = handover.run(
        profileId: 'one',
        isCurrent: () => true,
        fabricActive: () => active,
        probe: () async {},
        apply: () async {
          applies++;
          return true;
        },
      );
      complete.complete();
      await Future.wait([first, second]);
      expect(applies, 1);
    },
  );

  test('profile changes during probing do not reapply stale routes', () async {
    final handover = UserNetNetworkHandover();
    var active = false;
    var current = true;
    var applies = 0;
    await handover.run(
      profileId: 'one',
      isCurrent: () => current,
      fabricActive: () => active,
      probe: () async {
        active = true;
        current = false;
      },
      apply: () async {
        applies++;
        return true;
      },
    );
    await handover.run(
      profileId: 'two',
      isCurrent: () => true,
      fabricActive: () => active,
      probe: () async {},
      apply: () async {
        applies++;
        return true;
      },
    );
    expect(applies, 0);
  });

  test(
    'failed profile application is retried on the next network event',
    () async {
      final handover = UserNetNetworkHandover();
      var active = false;
      var applies = 0;
      Future<void> run() => handover.run(
        profileId: 'one',
        isCurrent: () => true,
        fabricActive: () => active,
        probe: () async => active = true,
        apply: () async => ++applies > 1,
      );
      await run();
      await run();
      await run();
      expect(applies, 2);
    },
  );

  test(
    'bounded probes and application retries need no new network event',
    () async {
      final handover = UserNetNetworkHandover();
      var active = false;
      var probes = 0;
      var applies = 0;
      await handover.run(
        profileId: 'one',
        isCurrent: () => true,
        fabricActive: () => active,
        maxProbes: 3,
        maxApplyAttempts: 3,
        firstProbeRetryDelay: Duration.zero,
        probeRetryDelay: Duration.zero,
        applyRetryDelay: Duration.zero,
        probe: () async {
          probes++;
          if (probes == 2) active = true;
        },
        apply: () async => ++applies == 3,
      );
      expect(probes, 3);
      expect(applies, 3);
    },
  );

  test('a new network event interrupts a delayed retry', () async {
    final handover = UserNetNetworkHandover();
    final started = Completer<void>();
    var probes = 0;
    final first = handover.run(
      profileId: 'one',
      isCurrent: () => true,
      fabricActive: () => false,
      maxProbes: 3,
      firstProbeRetryDelay: const Duration(hours: 1),
      probeRetryDelay: const Duration(hours: 1),
      probe: () async {
        probes++;
        started.complete();
      },
      apply: () async => true,
    );
    await started.future;
    await Future<void>.delayed(Duration.zero);
    final second = handover.run(
      profileId: 'one',
      isCurrent: () => true,
      fabricActive: () => false,
      probe: () async {
        probes++;
      },
      apply: () async => true,
    );
    await Future.wait([first, second]).timeout(const Duration(seconds: 1));
    expect(probes, 2);
  });
}
