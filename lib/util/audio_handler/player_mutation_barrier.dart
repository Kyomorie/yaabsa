import 'dart:async';

class PlayerMutationLease {
  PlayerMutationLease._(this._id);

  final int _id;

  @override
  String toString() => 'PlayerMutationLease($_id)';
}

class PlayerMutationBarrier {
  int _sequence = 0;
  PlayerMutationLease? _currentLease;
  Future<void> _tail = Future<void>.value();

  PlayerMutationLease acquire() {
    final lease = PlayerMutationLease._(++_sequence);
    _currentLease = lease;
    return lease;
  }

  bool isCurrent(PlayerMutationLease lease) => identical(_currentLease, lease);

  bool invalidate(PlayerMutationLease lease) {
    if (!isCurrent(lease)) {
      return false;
    }

    _currentLease = null;
    return true;
  }

  Future<T?> run<T>(PlayerMutationLease lease, Future<T> Function() mutation) {
    final previous = _tail;
    final operation = () async {
      await previous;
      if (!isCurrent(lease)) {
        return null;
      }
      return mutation();
    }();

    _tail = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }

  Future<void> get drained => _tail;
}
