/// Deterministic MET-based calorie model.
///
/// All arithmetic lives here in code — no values are ever guessed or generated.
/// kcal/min = MET * 3.5 * weightKg / 200
class CalorieEngine {
  CalorieEngine(this.weightKg);

  double weightKg;
  double _met = 2.5;
  double kcal = 0;

  double get met => _met;

  /// [normSpeed] is the fastest hand speed normalised by the screen diagonal
  /// (roughly "screens per second"); [dt] is seconds since the last update.
  void update(double normSpeed, double dt) {
    // Map intensity to a MET value in the 2.5 (light) .. 8.0 (vigorous) band.
    final target = (2.5 + normSpeed * 2.2).clamp(2.5, 8.0);
    _met += (target - _met) * 0.12; // smooth so the counter doesn't jitter
    kcal += _met * 3.5 * weightKg / 200 / 60 * dt;
  }

  void reset() {
    _met = 2.5;
    kcal = 0;
  }
}
