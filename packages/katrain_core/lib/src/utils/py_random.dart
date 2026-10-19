/// Python's `random.Random` (MT19937): same seeds give the same `random()` values as CPython, so ported code that
/// draws random numbers can be tested move by move against KaTrain.
library;

class PyRandom {
  static const int _n = 624;
  static const int _m = 397;
  final List<int> _mt = List.filled(_n, 0);
  int _index = _n + 1;

  /// Seeded like `random.Random(seed)` for an integer seed.
  PyRandom(int seed) {
    this.seed(BigInt.from(seed));
  }

  /// Seeded like `random.Random(seed)` for an integer seed of any size, as Python allows.
  PyRandom.big(BigInt seed) {
    this.seed(seed);
  }

  /// `random.seed(n)` for an integer: init_by_array with the 32-bit words of |n|, least significant first.
  void seed(BigInt seed) {
    var n = seed.abs();
    final key = <int>[];
    final mask = BigInt.from(0xFFFFFFFF);
    while (n > BigInt.zero) {
      key.add((n & mask).toInt());
      n = n >> 32;
    }
    if (key.isEmpty) key.add(0);
    _initByArray(key);
  }

  void _initGenrand(int s) {
    _mt[0] = s & 0xFFFFFFFF;
    for (var i = 1; i < _n; i++) {
      final prev = _mt[i - 1] ^ (_mt[i - 1] >> 30);
      _mt[i] = (_mul32(1812433253, prev) + i) & 0xFFFFFFFF;
    }
    _index = _n;
  }

  void _initByArray(List<int> key) {
    _initGenrand(19650218);
    var i = 1;
    var j = 0;
    for (var k = _n > key.length ? _n : key.length; k > 0; k--) {
      final prev = _mt[i - 1] ^ (_mt[i - 1] >> 30);
      _mt[i] = ((_mt[i] ^ _mul32(prev, 1664525)) + key[j] + j) & 0xFFFFFFFF;
      i++;
      j++;
      if (i >= _n) {
        _mt[0] = _mt[_n - 1];
        i = 1;
      }
      if (j >= key.length) j = 0;
    }
    for (var k = _n - 1; k > 0; k--) {
      final prev = _mt[i - 1] ^ (_mt[i - 1] >> 30);
      _mt[i] = ((_mt[i] ^ _mul32(prev, 1566083941)) - i) & 0xFFFFFFFF;
      i++;
      if (i >= _n) {
        _mt[0] = _mt[_n - 1];
        i = 1;
      }
    }
    _mt[0] = 0x80000000;
  }

  /// 32-bit multiplication modulo 2^32 without losing precision.
  static int _mul32(int a, int b) {
    final aHi = (a >> 16) & 0xFFFF;
    final aLo = a & 0xFFFF;
    return ((((aHi * b) & 0xFFFF) << 16) + aLo * b) & 0xFFFFFFFF;
  }

  int _genrand() {
    if (_index >= _n) {
      for (var kk = 0; kk < _n; kk++) {
        final y = (_mt[kk] & 0x80000000) | (_mt[(kk + 1) % _n] & 0x7FFFFFFF);
        var v = _mt[(kk + _m) % _n] ^ (y >> 1);
        if (y & 1 != 0) v ^= 0x9908B0DF;
        _mt[kk] = v;
      }
      _index = 0;
    }
    var y = _mt[_index++];
    y ^= y >> 11;
    y ^= (y << 7) & 0x9D2C5680;
    y ^= (y << 15) & 0xEFC60000;
    y ^= y >> 18;
    return y & 0xFFFFFFFF;
  }

  /// `random.random()`: a float in [0, 1) with 53 random bits.
  double random() {
    final a = _genrand() >> 5;
    final b = _genrand() >> 6;
    return (a * 67108864.0 + b) * (1.0 / 9007199254740992.0);
  }
}

/// The equivalent of Python's module-level `random`: KaTrain draws undo thresholds, self-play choices and AI moves
/// from one shared stream, so seeding this reproduces KaTrain's choices after `random.seed(n)`.
PyRandom globalRandom = PyRandom(DateTime.now().microsecondsSinceEpoch);
