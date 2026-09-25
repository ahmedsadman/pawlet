import 'local_model.dart';

/// Runs the on-device fused model for one SMS. Returns null when the model is
/// unavailable (asset load / runtime failure) so the pipeline transparently
/// falls back to the LLM. Implementations must never throw.
abstract class LocalClassifier {
  Future<LocalPrediction?> infer(String content);
}
