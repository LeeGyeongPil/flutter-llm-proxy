import 'dart:async';

/// Passes [source] through unchanged while letting you look at each chunk
/// and learn how it ended.
///
/// - [onChunk] sees every chunk (the same list object is forwarded).
/// - [onFinish] runs exactly once: `cancelled == false` when the source
///   finished (or failed), `true` when the reader went away first — for a
///   proxy that means the client disconnected.
///
/// Cancelling the returned stream cancels the source subscription, so the
/// cancel travels all the way back to whoever produces the bytes.
Stream<List<int>> watchStream(
  Stream<List<int>> source, {
  void Function(List<int> chunk)? onChunk,
  required FutureOr<void> Function(bool cancelled) onFinish,
}) {
  StreamSubscription<List<int>>? sub;
  var finished = false;
  Future<void> finish(bool cancelled) async {
    if (finished) return;
    finished = true;
    await onFinish(cancelled);
  }

  late final StreamController<List<int>> controller;
  controller = StreamController<List<int>>(
    onListen: () {
      sub = source.listen(
        (chunk) {
          onChunk?.call(chunk);
          controller.add(chunk);
        },
        onError: controller.addError,
        onDone: () async {
          // 끝난 기록(usage 등)을 먼저 남기고 닫는다 — 바깥 쪽 관찰자가 결과를 볼 수 있게.
          await finish(false);
          await controller.close();
        },
      );
    },
    onPause: () => sub?.pause(),
    onResume: () => sub?.resume(),
    onCancel: () async {
      // 읽는 쪽(클라이언트)이 먼저 떠났다 → 원본도 끊는다.
      await finish(true);
      await sub?.cancel();
    },
  );
  return controller.stream;
}
