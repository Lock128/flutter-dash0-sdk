import 'package:dash0_flutter_sdk/dash0_flutter_sdk.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('flushes when the queue is full', () {
    final batches = <List<int>>[];
    final b = Batcher<int>(batches.add, maxQueueSize: 3);
    b.send(1);
    b.send(2);
    expect(batches, isEmpty);
    b.send(3);
    expect(batches, [
      [1, 2, 3],
    ]);
    b.dispose();
  });

  test('flushes after the schedule delay', () {
    fakeAsync((async) {
      final batches = <List<int>>[];
      final b = Batcher<int>(batches.add,
          maxQueueSize: 10, scheduleDelay: const Duration(seconds: 1));
      b.send(1);
      b.send(2);
      async.elapse(const Duration(milliseconds: 999));
      expect(batches, isEmpty);
      async.elapse(const Duration(milliseconds: 2));
      expect(batches, [
        [1, 2],
      ]);
      // A new item starts a new timer.
      b.send(3);
      async.elapse(const Duration(seconds: 1));
      expect(batches, hasLength(2));
    });
  });

  test('immediate mode bypasses the queue', () {
    final batches = <List<int>>[];
    final b = Batcher<int>(batches.add)..immediate = true;
    b.send(1);
    expect(batches, [
      [1],
    ]);
    expect(b.pending, 0);
  });

  test('flush sends pending items once', () {
    final batches = <List<int>>[];
    final b = Batcher<int>(batches.add);
    b.send(1);
    b.flush();
    b.flush();
    expect(batches, hasLength(1));
  });
}
