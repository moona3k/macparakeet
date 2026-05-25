import Foundation

/// Errors thrown by `VibeVoiceASR`. Mirrors the negative return codes
/// from `vv_capi_load` / `vv_capi_asr`, with a few Swift-level errors
/// for file-not-found and JSON-decode failures.
public enum VibeVoiceASRError: Error, Equatable, Sendable {
    /// `vv_capi_load` returned non-zero. The C ABI doesn't expose a
    /// granular reason; we surface the raw code for logging.
    case loadFailed(code: Int32)

    /// `vv_capi_asr` returned a negative value other than the
    /// "buffer too small" case. Raw code surfaced for logging.
    case transcribeFailed(code: Int32)

    /// `vv_capi_asr` returned -<required-size>, meaning our caller-
    /// owned buffer wasn't large enough to hold the JSON. The actor
    /// grows the buffer and retries; this error is only thrown if
    /// growth would exceed `VibeVoiceASR.maxBufferSize` (16 MB).
    case outputBufferTooSmall(requiredBytes: Int)

    /// The JSON output decoded by `JSONDecoder` was structurally
    /// unexpected (not an array of segments).
    case malformedJSON(String)

    /// `loadModel` wasn't called, or was called with a path that
    /// doesn't exist on disk.
    case modelNotLoaded

    /// One of the audio / model / tokenizer file paths doesn't exist
    /// on disk. Caught Swift-side before the C call.
    case fileNotFound(URL)
}
