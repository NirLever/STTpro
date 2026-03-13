namespace STTpro.Core.Stt;

public record SttResult(
    string Text,
    string DetectedLanguage,
    TimeSpan Duration,
    double Confidence,
    double NoSpeechProbability = 0);
