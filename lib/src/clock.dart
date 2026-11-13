/// Returns "now". Tests pass a fake clock so time-based rules
/// (token expiry, rate-limit windows, JWKS cache age) can be checked
/// without waiting.
typedef Clock = DateTime Function();

/// The real clock (UTC).
DateTime systemClock() => DateTime.now().toUtc();
