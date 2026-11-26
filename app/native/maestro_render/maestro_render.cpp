#include "maestro_render.h"

#define DR_FLAC_IMPLEMENTATION
#include "dr_libs/dr_flac.h"
#define DR_WAV_IMPLEMENTATION
#include "dr_libs/dr_wav.h"
#include "signalsmith-stretch/signalsmith-stretch.h"

#include <algorithm>
#include <cctype>
#include <climits>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <new>
#include <string>
#include <vector>

#ifdef _WIN32
#include <windows.h>
#endif

namespace {

using Channels = std::vector<std::vector<float>>;

// Platform path: wide on Windows so non-ASCII folder names work.
#ifdef _WIN32
using Path = std::wstring;
Path toPath(const std::string& utf8) {
  int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8.c_str(), -1, nullptr, 0);
  if (n <= 0) return Path();
  Path w(static_cast<size_t>(n), L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8.c_str(), -1, &w[0], n);
  w.resize(static_cast<size_t>(n - 1));
  return w;
}
drflac* openFlac(const Path& p) { return drflac_open_file_w(p.c_str(), nullptr); }
bool openWav(drwav* w, const Path& p) { return drwav_init_file_w(w, p.c_str(), nullptr); }
bool createWav(drwav* w, const Path& p, const drwav_data_format* f) {
  return drwav_init_file_write_w(w, p.c_str(), f, nullptr);
}
FILE* openWrite(const Path& p) { return _wfopen(p.c_str(), L"wb"); }
void removeFile(const Path& p) { DeleteFileW(p.c_str()); }
bool replaceFile(const Path& from, const Path& to) {
  return MoveFileExW(from.c_str(), to.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != 0;
}
#else
using Path = std::string;
Path toPath(const std::string& utf8) { return utf8; }
drflac* openFlac(const Path& p) { return drflac_open_file(p.c_str(), nullptr); }
bool openWav(drwav* w, const Path& p) { return drwav_init_file(w, p.c_str(), nullptr); }
bool createWav(drwav* w, const Path& p, const drwav_data_format* f) {
  return drwav_init_file_write(w, p.c_str(), f, nullptr);
}
FILE* openWrite(const Path& p) { return std::fopen(p.c_str(), "wb"); }
void removeFile(const Path& p) { std::remove(p.c_str()); }
bool replaceFile(const Path& from, const Path& to) { return std::rename(from.c_str(), to.c_str()) == 0; }
#endif

bool endsWithWav(const std::string& s) {
  if (s.size() < 4) return false;
  std::string ext = s.substr(s.size() - 4);
  for (auto& c : ext) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
  return ext == ".wav";
}

// Reads the whole file into planar float channels. Frame count need not be known up front.
template <class ReadFn>
void readAll(unsigned channels, ReadFn read, Channels& out) {
  const size_t block = 4096;
  std::vector<float> buf(block * channels);
  out.assign(channels, {});
  for (;;) {
    size_t got = static_cast<size_t>(read(block, buf.data()));
    if (got == 0) break;
    for (unsigned c = 0; c < channels; ++c) {
      auto& ch = out[c];
      for (size_t i = 0; i < got; ++i) ch.push_back(buf[i * channels + c]);
    }
    if (got < block) break;
  }
}

// Fails if fewer frames decode than the header promises (e.g. a FLAC cut short by a failed copy),
// since a truncated render would silently break lyric sync. dr_wav clamps its count to the file size.
bool decode(const std::string& inPath, Channels& audio, unsigned& sampleRate) {
  Path p = toPath(inPath);
  uint64_t expected = 0;  // 0 = unknown
  if (p.empty()) return false;
  if (endsWithWav(inPath)) {
    drwav w;
    if (!openWav(&w, p)) return false;
    unsigned channels = w.channels;
    sampleRate = w.sampleRate;
    expected = w.totalPCMFrameCount;
    if (channels == 0) {
      drwav_uninit(&w);
      return false;
    }
    try {
      readAll(channels, [&](size_t n, float* b) { return drwav_read_pcm_frames_f32(&w, n, b); }, audio);
    } catch (...) {
      drwav_uninit(&w);
      throw;
    }
    drwav_uninit(&w);
  } else {
    drflac* f = openFlac(p);
    if (!f) return false;
    unsigned channels = f->channels;
    sampleRate = f->sampleRate;
    expected = f->totalPCMFrameCount;
    try {
      readAll(channels, [&](size_t n, float* b) { return drflac_read_pcm_frames_f32(f, n, b); }, audio);
    } catch (...) {
      drflac_close(f);
      throw;
    }
    drflac_close(f);
  }
  if (audio.empty() || sampleRate == 0) return false;
  return expected == 0 || audio[0].size() == expected;
}

// Signalsmith wants `io[channel][index]`; this views planar buffers from a frame offset.
struct View {
  Channels& ch;
  size_t offset;
  float* operator[](int c) { return ch[static_cast<size_t>(c)].data() + offset; }
};

// Same steps as SignalsmithStretch::exact() (outputSeek -> process -> flush), so output is
// exactly outFrames long and aligned with the input, but the middle is chunked for progress.
// Returns false if the input is too short to prime the stretcher (well under a second).
bool stretchAll(Channels& in, Channels& out, int outFrames, unsigned sampleRate, float semitones,
                volatile float* progress) {
  const int channels = static_cast<int>(in.size());
  const int inFrames = static_cast<int>(in[0].size());
  signalsmith::stretch::SignalsmithStretch<float> stretch;
  stretch.presetDefault(channels, static_cast<float>(sampleRate));
  stretch.setTransposeSemitones(semitones);

  const float rate = inFrames / static_cast<float>(outFrames);
  const int seekLength = stretch.outputSeekLength(rate);
  const int outBody = outFrames - static_cast<int>(seekLength / rate);
  const int inBody = inFrames - seekLength;
  if (inBody <= 0 || outBody <= 0) return false;
  View head{in, 0};
  stretch.outputSeek(head, seekLength);

  const int64_t chunks = std::max<int64_t>(1, outBody / static_cast<int64_t>(sampleRate));  // ~1 s each
  for (int64_t k = 0; k < chunks; ++k) {
    const int64_t o0 = outBody * k / chunks, o1 = outBody * (k + 1) / chunks;
    const int64_t i0 = inBody * k / chunks, i1 = inBody * (k + 1) / chunks;
    View src{in, static_cast<size_t>(seekLength + i0)};
    View dst{out, static_cast<size_t>(o0)};
    stretch.process(src, static_cast<int>(i1 - i0), dst, static_cast<int>(o1 - o0));
    if (progress) *progress = 0.95f * static_cast<float>(k + 1) / static_cast<float>(chunks);
  }
  View tail{out, static_cast<size_t>(outBody)};
  stretch.flush(tail, outFrames - outBody, rate);
  return true;
}

// Drops the `n` cut spans in `cuts` ([start, end] seconds of the input, sorted, non-overlapping) and
// joins what's left with a 50 ms linear crossfade centred on each join, so the output is exactly the
// kept frames long and each join sits where the cut-time mapping in lib/library.dart puts it. Audio
// that starts or ends at a cut fades in/out over 25 ms. False if nothing is left.
bool applyCuts(Channels& audio, unsigned sampleRate, const double* cuts, int n) {
  const size_t total = audio[0].size();
  auto frame = [&](double sec) {
    return std::min(total, static_cast<size_t>(std::llround(std::max(0.0, sec) * sampleRate)));
  };
  std::vector<std::pair<size_t, size_t>> keep;  // [from, to) frames
  size_t pos = 0;
  for (int k = 0; k < n; ++k) {
    const size_t a = frame(cuts[2 * k]), b = frame(cuts[2 * k + 1]);
    if (a > pos) keep.push_back({pos, a});
    pos = std::max(pos, b);
  }
  if (pos < total) keep.push_back({pos, total});
  if (keep.empty()) return false;

  const size_t half = sampleRate * 25 / 1000;
  auto len = [&](size_t j) { return keep[j].second - keep[j].first; };
  for (auto& ch : audio) {
    std::vector<float> out;
    out.reserve(total);
    for (size_t j = 0; j < keep.size(); ++j) {
      const size_t o = out.size();  // output frame where segment j starts = the join
      out.insert(out.end(), ch.begin() + keep[j].first, ch.begin() + keep[j].second);
      if (j == 0) continue;
      // Fade the audio running on past the cut out and the audio leading into this segment in. Both
      // sides read real input (from inside the cut), and h <= half of each segment keeps reads in range.
      const size_t e = keep[j - 1].second, s = keep[j].first;
      const size_t h = std::min({half, len(j - 1) / 2, len(j) / 2});
      for (size_t i = 0; i < 2 * h; ++i) {
        const float t = (static_cast<float>(i) + 0.5f) / static_cast<float>(2 * h);
        out[o - h + i] = ch[e - h + i] * (1 - t) + ch[s - h + i] * t;
      }
    }
    if (keep.front().first > 0) {  // trimmed start
      const size_t h = std::min(half, len(0) / 2);
      for (size_t i = 0; i < h; ++i) out[i] *= (static_cast<float>(i) + 0.5f) / static_cast<float>(h);
    }
    if (keep.back().second < total) {  // trimmed end
      const size_t h = std::min(half, len(keep.size() - 1) / 2);
      for (size_t i = 0; i < h; ++i) out[out.size() - 1 - i] *= (static_cast<float>(i) + 0.5f) / static_cast<float>(h);
    }
    ch.swap(out);
  }
  return true;
}

// RMS over all channels of each 1/binsPerSecond s bin, into `out`. False if undecodable.
bool rmsBins(const char* path, float binsPerSecond, std::vector<float>& out) {
  Channels audio;
  unsigned rate = 0;
  if (!decode(path, audio, rate)) return false;
  const double perBin = rate / static_cast<double>(binsPerSecond);
  const size_t frames = audio[0].size(), bins = static_cast<size_t>(std::ceil(frames / perBin));
  out.assign(bins, 0.0f);
  for (size_t b = 0; b < bins; ++b) {
    const size_t from = static_cast<size_t>(b * perBin), to = std::min(frames, static_cast<size_t>((b + 1) * perBin));
    double sum = 0;
    for (const auto& ch : audio)
      for (size_t i = from; i < to; ++i) sum += static_cast<double>(ch[i]) * ch[i];
    if (to > from) out[b] = static_cast<float>(std::sqrt(sum / static_cast<double>((to - from) * audio.size())));
  }
  return true;
}

int writeWav(const std::string& outPath, const Channels& out, unsigned sampleRate) {
  const unsigned channels = static_cast<unsigned>(out.size());
  const size_t frames = out[0].size();

  // Peak-normalise to 0.98 only when the shift pushed it over; never boost quiet songs.
  float peak = 0;
  for (const auto& ch : out)
    for (float v : ch) peak = std::max(peak, std::fabs(v));
  const float gain = peak > 0.98f ? 0.98f / peak : 1.0f;

  const size_t block = 4096;
  std::vector<int16_t> buf(block * channels);
  const Path dst = toPath(outPath), tmp = toPath(outPath + ".tmp");
  if (dst.empty() || tmp.empty()) return MAESTRO_ERR_ARGS;

  drwav_data_format fmt{};
  fmt.container = drwav_container_riff;
  fmt.format = DR_WAVE_FORMAT_PCM;
  fmt.channels = channels;
  fmt.sampleRate = sampleRate;
  fmt.bitsPerSample = 16;
  drwav w;
  if (!createWav(&w, tmp, &fmt)) return MAESTRO_ERR_OUTPUT;

  bool ok = true;
  for (size_t start = 0; start < frames && ok; start += block) {
    const size_t n = std::min(block, frames - start);
    for (size_t i = 0; i < n; ++i)
      for (unsigned c = 0; c < channels; ++c) {
        float v = std::clamp(out[c][start + i] * gain, -1.0f, 1.0f);
        buf[i * channels + c] = static_cast<int16_t>(std::lrint(v * 32767.0f));
      }
    ok = drwav_write_pcm_frames(&w, n, buf.data()) == n;
  }
  ok = (drwav_uninit(&w) == DRWAV_SUCCESS) && ok;  // uninit also patches the header sizes
  if (!ok || !replaceFile(tmp, dst)) {
    removeFile(tmp);
    return MAESTRO_ERR_OUTPUT;
  }
  return MAESTRO_OK;
}

}  // namespace

extern "C" MAESTRO_API int maestro_render(const char* in_path, const char* out_wav, float semitones,
                                          float tempo, const double* cuts, int n_cuts,
                                          volatile float* progress) {
  if (!in_path || !out_wav || !std::isfinite(semitones) || !std::isfinite(tempo)) return MAESTRO_ERR_ARGS;
  if (std::fabs(semitones) > 24 || tempo < 0.25f || tempo > 4.0f) return MAESTRO_ERR_ARGS;
  if (n_cuts < 0 || (n_cuts > 0 && !cuts)) return MAESTRO_ERR_ARGS;
  for (int k = 0; k < n_cuts; ++k) {
    const double a = cuts[2 * k], b = cuts[2 * k + 1];
    if (!std::isfinite(a) || !std::isfinite(b) || b <= a || (k > 0 && a < cuts[2 * k - 1])) return MAESTRO_ERR_ARGS;
  }
  if (progress) *progress = 0;
  try {
    Channels in;
    unsigned sampleRate = 0;
    if (!decode(in_path, in, sampleRate)) return MAESTRO_ERR_INPUT;
    if (n_cuts > 0 && !applyCuts(in, sampleRate, cuts, n_cuts)) return MAESTRO_ERR_INPUT;
    const size_t inFrames = in[0].size();
    if (inFrames > static_cast<size_t>(INT_MAX / 4)) return MAESTRO_ERR_INPUT;  // Signalsmith uses int lengths

    if (semitones != 0 || tempo != 1.0f) {  // else cuts only: the audio is already final
      const int outFrames = static_cast<int>(std::llround(static_cast<double>(inFrames) / tempo));
      if (outFrames < 1) return MAESTRO_ERR_INPUT;
      Channels out(in.size(), std::vector<float>(static_cast<size_t>(outFrames)));
      if (!stretchAll(in, out, outFrames, sampleRate, semitones, progress)) return MAESTRO_ERR_INPUT;
      in.swap(out);  // frees the input before writing
    }

    int r = writeWav(out_wav, in, sampleRate);
    if (r == MAESTRO_OK && progress) *progress = 1;
    return r;
  } catch (const std::bad_alloc&) {
    return MAESTRO_ERR_MEMORY;
  } catch (...) {
    return MAESTRO_ERR_INTERNAL;
  }
}

extern "C" MAESTRO_API int maestro_mix(const char* a_path, const char* b_path, const char* out_wav,
                                       volatile float* progress) {
  if (!a_path || !b_path || !out_wav) return MAESTRO_ERR_ARGS;
  if (progress) *progress = 0;
  try {
    Channels a, b;
    unsigned rateA = 0, rateB = 0;
    if (!decode(a_path, a, rateA)) return MAESTRO_ERR_INPUT;
    if (progress) *progress = 0.4f;
    if (!decode(b_path, b, rateB) || rateA != rateB) return MAESTRO_ERR_INPUT;
    if (progress) *progress = 0.8f;
    // Sum into the longer one, so the shorter is padded with silence. Both start at sample 0.
    if (b[0].size() > a[0].size()) std::swap(a, b);
    if (a.size() < b.size()) {  // mono + stereo: the mono one goes to both sides
      const std::vector<float> first = a[0];  // a copy: resize may move a[0]
      a.resize(b.size(), first);
    }
    for (size_t c = 0; c < a.size(); ++c) {
      const auto& src = b[std::min(c, b.size() - 1)];
      for (size_t i = 0; i < src.size(); ++i) a[c][i] += src[i];
    }
    b = Channels();
    int r = writeWav(out_wav, a, rateA);
    if (r == MAESTRO_OK && progress) *progress = 1;
    return r;
  } catch (const std::bad_alloc&) {
    return MAESTRO_ERR_MEMORY;
  } catch (...) {
    return MAESTRO_ERR_INTERNAL;
  }
}

extern "C" MAESTRO_API int maestro_peaks(const char* a_path, const char* b_path, const char* out_path,
                                         float bins_per_second) {
  if (!a_path || !out_path || !std::isfinite(bins_per_second) || bins_per_second < 1 || bins_per_second > 1000)
    return MAESTRO_ERR_ARGS;
  try {
    std::vector<float> a, b;
    if (!rmsBins(a_path, bins_per_second, a)) return MAESTRO_ERR_INPUT;
    if (b_path && !rmsBins(b_path, bins_per_second, b)) return MAESTRO_ERR_INPUT;
    b.resize(a.size(), 0.0f);  // no vocals, or a different length: as many bins as `a`, zero-padded
    const Path dst = toPath(out_path), tmp = toPath(std::string(out_path) + ".tmp");
    if (dst.empty() || tmp.empty()) return MAESTRO_ERR_ARGS;
    FILE* f = openWrite(tmp);
    if (!f) return MAESTRO_ERR_OUTPUT;
    const uint32_t n = static_cast<uint32_t>(a.size());
    bool ok = std::fwrite(&n, sizeof n, 1, f) == 1;
    ok = ok && std::fwrite(a.data(), sizeof(float), n, f) == n && std::fwrite(b.data(), sizeof(float), n, f) == n;
    ok = (std::fclose(f) == 0) && ok;
    if (!ok || !replaceFile(tmp, dst)) {
      removeFile(tmp);
      return MAESTRO_ERR_OUTPUT;
    }
    return MAESTRO_OK;
  } catch (const std::bad_alloc&) {
    return MAESTRO_ERR_MEMORY;
  } catch (...) {
    return MAESTRO_ERR_INTERNAL;
  }
}
