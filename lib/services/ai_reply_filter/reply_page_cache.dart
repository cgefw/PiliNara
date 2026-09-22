/// Short-lived, one-use prefetch cache. Failed responses are never retained.
/// Active readers share a Future; callers must clone mutable response objects.
class ReplyPageCache<T> {
  ReplyPageCache({
    required this.isSuccess,
    this.ttl = const Duration(seconds: 30),
    this.capacity = 8,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;
  final bool Function(T) isSuccess;
  final Duration ttl;
  final int capacity;
  final DateTime Function() _now;
  final Map<String, _Page<T>> _pages = {};

  Future<T> load(
    String key,
    Future<T> Function() loader, {
    bool prefetch = false,
  }) async {
    _pages.removeWhere(
      (_, page) =>
          page.completedAt != null &&
          _now().difference(page.completedAt!) >= ttl,
    );
    var page = _pages[key];
    if (page == null) {
      page = _Page<T>(Future.sync(loader));
      _pages[key] = page;
      while (_pages.length > capacity) {
        _pages.remove(_pages.keys.first);
      }
    }
    final current = page;
    if (!prefetch) current.consumed = true;
    try {
      final result = await current.future;
      current.completedAt ??= _now();
      if (current.consumed || !isSuccess(result)) {
        if (identical(_pages[key], current)) _pages.remove(key);
      }
      return result;
    } catch (_) {
      if (identical(_pages[key], current)) _pages.remove(key);
      rethrow;
    }
  }

  void invalidate(String prefix) =>
      _pages.removeWhere((key, _) => key.startsWith(prefix));
}

class _Page<T> {
  _Page(this.future);
  final Future<T> future;
  DateTime? completedAt;
  bool consumed = false;
}
