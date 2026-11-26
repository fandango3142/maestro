// Maestro key/tempo render: decode FLAC (or WAV), pitch/tempo shift with
// Signalsmith Stretch, write 16-bit PCM WAV. See docs/stage-manager-plan.md (WP-C1).
// Also the editor's guide mix (instrumental + vocals), WP-B2.
#pragma once

#ifdef _WIN32
#define MAESTRO_API __declspec(dllexport)
#else
#define MAESTRO_API __attribute__((visibility("default")))
#endif

#define MAESTRO_OK 0
#define MAESTRO_ERR_ARGS -1     // null path, NaN, or semitones/tempo out of range
#define MAESTRO_ERR_INPUT -2    // can't open/decode input, or it's too short to stretch
#define MAESTRO_ERR_OUTPUT -3   // can't write the .tmp file or rename it into place
#define MAESTRO_ERR_MEMORY -4   // out of memory
#define MAESTRO_ERR_INTERNAL -5 // any other C++ exception

#ifdef __cplusplus
extern "C" {
#endif

// Paths are UTF-8. Input type is picked by extension: ".wav" -> WAV, anything else -> FLAC.
// Output keeps the input's sample rate and channel count. Output length = round(input / tempo),
// aligned to the input (no latency offset). Written to "<out_wav>.tmp", then renamed over out_wav.
// `progress` (may be null) is set to 0..1 while rendering; 1 on success.
// Cuts (WP-E): `cuts` holds `n_cuts` [start, end] pairs in seconds of the input, sorted and not
// overlapping (else MAESTRO_ERR_ARGS); may be null when n_cuts is 0. They are removed before the
// stretch and the joins crossfaded over 50 ms centred on each join (25 ms fade at a trimmed start or
// end), so the output is round((input − cuts) / tempo) long. With cuts, 0 semitones / tempo 1 skips the
// stretch. Cutting everything is MAESTRO_ERR_INPUT.
MAESTRO_API int maestro_render(const char* in_path, const char* out_wav, float semitones, float tempo,
                               const double* cuts, int n_cuts, volatile float* progress);

// Waveform data (WP-E): RMS over all channels per 1/bins_per_second s bin of a and of b (b may be null:
// zeros). Writes out_path ("<out_path>.tmp" + rename): uint32 n, then n float32 for a, then n float32
// for b (b zero-padded or truncated to n). Little-endian (host order).
MAESTRO_API int maestro_peaks(const char* a_path, const char* b_path, const char* out_path, float bins_per_second);

// Guide mix (WP-B2): a + b summed sample-for-sample from 0, the shorter one padded with silence,
// so the result is as long as the longer input. Same rate required (else MAESTRO_ERR_INPUT); a mono
// input is added to every channel. Peak-normalised to 0.98 only if the sum goes over. Same output
// rules as maestro_render (16-bit WAV via "<out_wav>.tmp" + rename, progress 0..1).
MAESTRO_API int maestro_mix(const char* a_path, const char* b_path, const char* out_wav, volatile float* progress);

#ifdef __cplusplus
}
#endif
