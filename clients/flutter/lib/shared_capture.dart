/// Reference-counted capture: each recipient owns a lease, not the device stream.
class SharedCapturePool<T> {
  SharedCapturePool(this.create, this.dispose);
  final Future<T> Function(String key) create;
  final Future<void> Function(T value) dispose;
  final _entries = <String, _Capture<T>>{};

  CaptureLease<T> acquire(String key) {
    final capture = _entries.putIfAbsent(
      key,
      () => _Capture(Future.sync(() => create(key))),
    );
    capture.users++;
    return CaptureLease(capture.value, () async {
      if (--capture.users != 0) return;
      if (identical(_entries[key], capture)) _entries.remove(key);
      T value;
      try {
        value = await capture.value;
      } catch (_) {
        return; // A failed acquisition owns no stream to dispose.
      }
      await dispose(value);
    });
  }
}

class _Capture<T> {
  _Capture(this.value);
  final Future<T> value;
  int users = 0;
}

class CaptureLease<T> {
  CaptureLease(this.value, this._release);
  final Future<T> value;
  final Future<void> Function() _release;
  Future<void>? _released;
  Future<void> release() => _released ??= _release();
}
