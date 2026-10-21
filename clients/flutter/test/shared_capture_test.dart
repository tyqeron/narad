import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:narad_client/shared_capture.dart';

void main() {
  test(
    'two listeners share one capture and stopping either preserves the other',
    () async {
      var created = 0, disposed = 0;
      final pool = SharedCapturePool<Object>(
        (_) async {
          created++;
          return Object();
        },
        (_) async {
          disposed++;
        },
      );
      final phone = pool.acquire('monitor'), tablet = pool.acquire('monitor');
      expect(await phone.value, same(await tablet.value));
      expect(created, 1);
      await phone.release();
      await phone.release();
      expect(disposed, 0);
      final next = pool.acquire('monitor');
      expect(await next.value, same(await tablet.value));
      await tablet.release();
      expect(disposed, 0);
      await next.release();
      expect(disposed, 1);
      final restarted = pool.acquire('monitor');
      await restarted.value;
      expect(created, 2);
      await restarted.release();
      expect(disposed, 2);
    },
  );
  test(
    'cancellation during capture initialization cleans up exactly once',
    () async {
      final ready = Completer<Object>();
      var disposed = 0;
      final pool = SharedCapturePool<Object>((_) => ready.future, (_) async {
        disposed++;
      });
      final lease = pool.acquire('monitor');
      final stopped = lease.release();
      ready.complete(Object());
      await stopped;
      await lease.release();
      expect(disposed, 1);
    },
  );
  test('a failed capture can be retried without leaking a lease', () async {
    var calls = 0, disposed = 0;
    final pool = SharedCapturePool<Object>(
      (_) async {
        if (++calls == 1) throw StateError('unavailable');
        return Object();
      },
      (_) async {
        disposed++;
      },
    );
    final failed = pool.acquire('monitor');
    await expectLater(failed.value, throwsStateError);
    await failed.release();
    final retry = pool.acquire('monitor');
    await retry.value;
    await retry.release();
    expect(calls, 2);
    expect(disposed, 1);
  });
}
