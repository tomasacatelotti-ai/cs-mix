// Conversión a MP3 de los archivos que bajan de un link (MP4, M4A, AAC...).
//
//   * El sistema decodifica: Android con MediaExtractor + MediaCodec del NDK,
//     Windows con el Source Reader de Media Foundation. Los dos entregan PCM
//     de 16 bits, así que no hace falta traer un decodificador AAC propio.
//   * LAME codifica a MP3 CBR. Se conserva la frecuencia del original cuando
//     es una de MPEG-1 (32 / 44,1 / 48 kHz) para no remuestrear; si no, 44,1.
//   * Más de dos canales (5.1) se reducen a izquierdo + derecho.

#include "cs_audio.h"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "lame/lame.h"

#if defined(__ANDROID__)
#include <fcntl.h>
#include <media/NdkMediaCodec.h>
#include <media/NdkMediaExtractor.h>
#include <media/NdkMediaFormat.h>
#include <sys/stat.h>
#include <unistd.h>
#elif defined(_WIN32)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <wrl/client.h>
#endif

namespace {

#if defined(_WIN32)
std::wstring widen(const char* s) {
  int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, nullptr, 0);
  if (n <= 0) return std::wstring();
  std::wstring w(static_cast<size_t>(n), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s, -1, &w[0], n);
  w.resize(static_cast<size_t>(n - 1));
  return w;
}
#endif

FILE* openOut(const char* path) {
#if defined(_WIN32)
  return _wfopen(widen(path).c_str(), L"w+b");
#else
  return std::fopen(path, "w+b");
#endif
}

// Recibe PCM de 16 bits intercalado con cualquier cantidad de canales y lo escribe como MP3.
class Mp3Writer {
 public:
  ~Mp3Writer() {
    if (gfp_) lame_close(gfp_);
    if (f_) std::fclose(f_);
  }

  bool isOpen() const { return gfp_ != nullptr; }

  int open(const char* out, int sampleRate, int srcChannels, int kbps) {
    if (sampleRate <= 0 || srcChannels <= 0) return CSA_CONV_DECODE;
    ch_ = srcChannels >= 2 ? 2 : 1;
    f_ = openOut(out);
    if (!f_) return CSA_CONV_WRITE;
    gfp_ = lame_init();
    if (!gfp_) return CSA_CONV_ENCODER;
    const bool mpeg1 = sampleRate == 32000 || sampleRate == 44100 || sampleRate == 48000;
    lame_set_in_samplerate(gfp_, sampleRate);
    lame_set_out_samplerate(gfp_, mpeg1 ? sampleRate : 44100);
    lame_set_num_channels(gfp_, ch_);
    lame_set_mode(gfp_, ch_ == 1 ? MONO : JOINT_STEREO);
    lame_set_VBR(gfp_, vbr_off);
    lame_set_brate(gfp_, kbps);
    lame_set_quality(gfp_, 2);  // 0 = mejor y más lento, 2 = casi igual y bastante más rápido
    lame_set_bWriteVbrTag(gfp_, 1);  // cabecera "Info": duración exacta en los reproductores
    if (lame_init_params(gfp_) < 0) return CSA_CONV_ENCODER;
    return CSA_CONV_OK;
  }

  int write(const int16_t* pcm, int frames, int srcChannels) {
    const int kStep = 4096;
    for (int done = 0; done < frames; done += kStep) {
      const int n = frames - done < kStep ? frames - done : kStep;
      const int16_t* src = pcm + static_cast<size_t>(done) * srcChannels;
      const int16_t* in = src;
      if (srcChannels != ch_) {
        // Mono pasa tal cual; con más de dos canales quedan izquierdo y derecho.
        tmp_.resize(static_cast<size_t>(n) * ch_);
        for (int i = 0; i < n; ++i) {
          for (int c = 0; c < ch_; ++c) tmp_[static_cast<size_t>(i) * ch_ + c] = src[static_cast<size_t>(i) * srcChannels + c];
        }
        in = tmp_.data();
      }
      mp3_.resize(static_cast<size_t>(n) * 5 / 4 + 7200);
      int bytes = ch_ == 2
          ? lame_encode_buffer_interleaved(gfp_, const_cast<short*>(reinterpret_cast<const short*>(in)), n,
                                           mp3_.data(), static_cast<int>(mp3_.size()))
          : lame_encode_buffer(gfp_, reinterpret_cast<const short*>(in), reinterpret_cast<const short*>(in), n,
                               mp3_.data(), static_cast<int>(mp3_.size()));
      if (bytes < 0) return CSA_CONV_ENCODER;
      if (bytes > 0 && std::fwrite(mp3_.data(), 1, static_cast<size_t>(bytes), f_) != static_cast<size_t>(bytes)) {
        return CSA_CONV_WRITE;
      }
    }
    return CSA_CONV_OK;
  }

  int finish() {
    mp3_.resize(7200);
    int bytes = lame_encode_flush(gfp_, mp3_.data(), static_cast<int>(mp3_.size()));
    if (bytes < 0) return CSA_CONV_ENCODER;
    if (bytes > 0 && std::fwrite(mp3_.data(), 1, static_cast<size_t>(bytes), f_) != static_cast<size_t>(bytes)) {
      return CSA_CONV_WRITE;
    }
    lame_mp3_tags_fid(gfp_, f_);
    const bool ok = std::fflush(f_) == 0;
    std::fclose(f_);
    f_ = nullptr;
    return ok ? CSA_CONV_OK : CSA_CONV_WRITE;
  }

 private:
  lame_t gfp_ = nullptr;
  FILE* f_ = nullptr;
  int ch_ = 2;
  std::vector<int16_t> tmp_;
  std::vector<unsigned char> mp3_;
};

void setProgress(volatile int32_t* p, int64_t pos, int64_t dur) {
  if (!p || dur <= 0 || pos < 0) return;
  int64_t v = pos * 1000 / dur;
  *p = static_cast<int32_t>(v > 999 ? 999 : v);
}

#if defined(__ANDROID__)

int convertAndroid(const char* in, const char* out, int kbps, volatile int32_t* progress, volatile int32_t* cancel) {
  int fd = ::open(in, O_RDONLY | O_CLOEXEC);
  if (fd < 0) return CSA_CONV_NO_AUDIO;
  struct stat st {};
  fstat(fd, &st);

  AMediaExtractor* ex = AMediaExtractor_new();
  AMediaCodec* codec = nullptr;
  int rc = CSA_CONV_OK;
  int64_t durUs = 0;
  int32_t sr = 0, ch = 0, enc = 2;  // 2 = PCM 16 bits, 4 = float
  Mp3Writer w;

  do {
    if (AMediaExtractor_setDataSourceFd(ex, fd, 0, st.st_size) != AMEDIA_OK) {
      rc = CSA_CONV_NO_AUDIO;
      break;
    }
    std::string mime;
    AMediaFormat* trackFmt = nullptr;
    const size_t tracks = AMediaExtractor_getTrackCount(ex);
    for (size_t i = 0; i < tracks; ++i) {
      AMediaFormat* f = AMediaExtractor_getTrackFormat(ex, i);
      const char* m = nullptr;
      if (AMediaFormat_getString(f, AMEDIAFORMAT_KEY_MIME, &m) && m && std::strncmp(m, "audio/", 6) == 0) {
        mime = m;
        trackFmt = f;
        AMediaExtractor_selectTrack(ex, i);
        break;
      }
      AMediaFormat_delete(f);
    }
    if (!trackFmt) {
      rc = CSA_CONV_NO_AUDIO;
      break;
    }
    AMediaFormat_getInt64(trackFmt, AMEDIAFORMAT_KEY_DURATION, &durUs);
    AMediaFormat_getInt32(trackFmt, AMEDIAFORMAT_KEY_SAMPLE_RATE, &sr);
    AMediaFormat_getInt32(trackFmt, AMEDIAFORMAT_KEY_CHANNEL_COUNT, &ch);

    codec = AMediaCodec_createDecoderByType(mime.c_str());
    if (!codec || AMediaCodec_configure(codec, trackFmt, nullptr, nullptr, 0) != AMEDIA_OK ||
        AMediaCodec_start(codec) != AMEDIA_OK) {
      AMediaFormat_delete(trackFmt);
      rc = CSA_CONV_UNSUPPORTED;
      break;
    }
    AMediaFormat_delete(trackFmt);

    bool inEos = false, outEos = false;
    int idle = 0;
    std::vector<int16_t> conv;
    while (!outEos) {
      if (cancel && *cancel) {
        rc = CSA_CONV_CANCELLED;
        break;
      }
      if (!inEos) {
        ssize_t ib = AMediaCodec_dequeueInputBuffer(codec, 10000);
        if (ib >= 0) {
          size_t cap = 0;
          uint8_t* buf = AMediaCodec_getInputBuffer(codec, static_cast<size_t>(ib), &cap);
          ssize_t n = buf ? AMediaExtractor_readSampleData(ex, buf, cap) : -1;
          if (n < 0) {
            AMediaCodec_queueInputBuffer(codec, static_cast<size_t>(ib), 0, 0, 0, AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM);
            inEos = true;
          } else {
            int64_t t = AMediaExtractor_getSampleTime(ex);
            AMediaCodec_queueInputBuffer(codec, static_cast<size_t>(ib), 0, static_cast<size_t>(n),
                                         static_cast<uint64_t>(t > 0 ? t : 0), 0);
            AMediaExtractor_advance(ex);
          }
        }
      }

      AMediaCodecBufferInfo info{};
      ssize_t ob = AMediaCodec_dequeueOutputBuffer(codec, &info, 10000);
      if (ob >= 0) {
        idle = 0;
        if (info.size > 0) {
          size_t cap = 0;
          uint8_t* data = AMediaCodec_getOutputBuffer(codec, static_cast<size_t>(ob), &cap);
          if (data && ch > 0) {
            if (!w.isOpen()) {
              rc = w.open(out, sr, ch, kbps);
              if (rc != CSA_CONV_OK) {
                AMediaCodec_releaseOutputBuffer(codec, static_cast<size_t>(ob), false);
                break;
              }
            }
            const uint8_t* p = data + info.offset;
            int frames;
            const int16_t* pcm;
            if (enc == 4) {
              const float* fl = reinterpret_cast<const float*>(p);
              const size_t n = static_cast<size_t>(info.size) / sizeof(float);
              conv.resize(n);
              for (size_t i = 0; i < n; ++i) {
                float v = fl[i] * 32767.0f;
                conv[i] = static_cast<int16_t>(v > 32767.0f ? 32767 : (v < -32768.0f ? -32768 : v));
              }
              pcm = conv.data();
              frames = static_cast<int>(n / static_cast<size_t>(ch));
            } else {
              pcm = reinterpret_cast<const int16_t*>(p);
              frames = info.size / (2 * ch);
            }
            rc = w.write(pcm, frames, ch);
            setProgress(progress, info.presentationTimeUs, durUs);
          }
        }
        if (info.flags & AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM) outEos = true;
        AMediaCodec_releaseOutputBuffer(codec, static_cast<size_t>(ob), false);
        if (rc != CSA_CONV_OK) break;
      } else if (ob == AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED) {
        AMediaFormat* f = AMediaCodec_getOutputFormat(codec);
        if (f) {
          AMediaFormat_getInt32(f, AMEDIAFORMAT_KEY_SAMPLE_RATE, &sr);
          AMediaFormat_getInt32(f, AMEDIAFORMAT_KEY_CHANNEL_COUNT, &ch);
          AMediaFormat_getInt32(f, "pcm-encoding", &enc);
          AMediaFormat_delete(f);
        }
      } else if (inEos && ++idle > 500) {
        break;  // el decodificador no confirmó el final en 5 s: lo que salió ya está escrito
      }
    }
    if (rc == CSA_CONV_OK && !w.isOpen()) rc = CSA_CONV_DECODE;  // no salió ni un bloque de audio
  } while (false);

  if (codec) {
    AMediaCodec_stop(codec);
    AMediaCodec_delete(codec);
  }
  AMediaExtractor_delete(ex);
  ::close(fd);
  if (rc == CSA_CONV_OK) rc = w.finish();
  return rc;
}

#elif defined(_WIN32)

using Microsoft::WRL::ComPtr;

int convertWindows(const char* in, const char* out, int kbps, volatile int32_t* progress, volatile int32_t* cancel) {
  const HRESULT co = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  const bool coOwned = SUCCEEDED(co);
  if (FAILED(co) && co != RPC_E_CHANGED_MODE) return CSA_CONV_DECODE;
  if (FAILED(MFStartup(MF_VERSION, MFSTARTUP_LITE))) {
    if (coOwned) CoUninitialize();
    return CSA_CONV_UNSUPPORTED;
  }

  int rc = CSA_CONV_OK;
  Mp3Writer w;
  {
    ComPtr<IMFSourceReader> reader;
    const DWORD audio = static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM);
    do {
      if (FAILED(MFCreateSourceReaderFromURL(widen(in).c_str(), nullptr, &reader))) {
        rc = CSA_CONV_NO_AUDIO;
        break;
      }
      reader->SetStreamSelection(static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS), FALSE);
      if (FAILED(reader->SetStreamSelection(audio, TRUE))) {
        rc = CSA_CONV_NO_AUDIO;
        break;
      }
      ComPtr<IMFMediaType> want;
      MFCreateMediaType(&want);
      want->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
      want->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
      want->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
      if (FAILED(reader->SetCurrentMediaType(audio, nullptr, want.Get()))) {
        rc = CSA_CONV_UNSUPPORTED;  // sin decodificador (Windows N sin el Media Feature Pack)
        break;
      }
      ComPtr<IMFMediaType> cur;
      if (FAILED(reader->GetCurrentMediaType(audio, &cur))) {
        rc = CSA_CONV_DECODE;
        break;
      }
      const int sr = static_cast<int>(MFGetAttributeUINT32(cur.Get(), MF_MT_AUDIO_SAMPLES_PER_SECOND, 0));
      const int ch = static_cast<int>(MFGetAttributeUINT32(cur.Get(), MF_MT_AUDIO_NUM_CHANNELS, 0));
      rc = w.open(out, sr, ch, kbps);
      if (rc != CSA_CONV_OK) break;

      int64_t dur = 0;  // en unidades de 100 ns
      PROPVARIANT v;
      PropVariantInit(&v);
      if (SUCCEEDED(reader->GetPresentationAttribute(static_cast<DWORD>(MF_SOURCE_READER_MEDIASOURCE), MF_PD_DURATION, &v)) &&
          v.vt == VT_UI8) {
        dur = static_cast<int64_t>(v.uhVal.QuadPart);
      }
      PropVariantClear(&v);

      for (;;) {
        if (cancel && *cancel) {
          rc = CSA_CONV_CANCELLED;
          break;
        }
        DWORD flags = 0;
        LONGLONG ts = 0;
        ComPtr<IMFSample> sample;
        if (FAILED(reader->ReadSample(audio, 0, nullptr, &flags, &ts, &sample))) {
          rc = CSA_CONV_DECODE;
          break;
        }
        if (flags & MF_SOURCE_READERF_ENDOFSTREAM) break;
        if (!sample) continue;
        ComPtr<IMFMediaBuffer> buf;
        if (FAILED(sample->ConvertToContiguousBuffer(&buf))) {
          rc = CSA_CONV_DECODE;
          break;
        }
        BYTE* data = nullptr;
        DWORD len = 0;
        if (FAILED(buf->Lock(&data, nullptr, &len))) {
          rc = CSA_CONV_DECODE;
          break;
        }
        rc = w.write(reinterpret_cast<const int16_t*>(data), static_cast<int>(len / (2u * static_cast<DWORD>(ch))), ch);
        buf->Unlock();
        if (rc != CSA_CONV_OK) break;
        setProgress(progress, ts, dur);
      }
    } while (false);
  }
  MFShutdown();
  if (coOwned) CoUninitialize();
  if (rc == CSA_CONV_OK) rc = w.finish();
  return rc;
}

#endif

}  // namespace

extern "C" CSA_API int32_t csa_convert_mp3(const char* in_utf8, const char* out_utf8, int32_t kbps,
                                           volatile int32_t* progress_permille, volatile int32_t* cancel) {
  if (!in_utf8 || !out_utf8) return CSA_CONV_NO_AUDIO;
  if (kbps < 32 || kbps > 320) kbps = 160;
  if (progress_permille) *progress_permille = 0;
  int rc;
#if defined(__ANDROID__)
  rc = convertAndroid(in_utf8, out_utf8, kbps, progress_permille, cancel);
#elif defined(_WIN32)
  rc = convertWindows(in_utf8, out_utf8, kbps, progress_permille, cancel);
#else
  (void)cancel;
  rc = CSA_CONV_UNSUPPORTED;
#endif
  if (rc == CSA_CONV_OK && progress_permille) *progress_permille = 1000;
  return rc;
}

// Para probar el codificador sin decodificador del sistema: PCM 16 bits intercalado en memoria.
extern "C" CSA_API int32_t csa_encode_pcm_mp3(const int16_t* pcm, int32_t frames, int32_t sample_rate,
                                              int32_t channels, const char* out_utf8, int32_t kbps) {
  if (!pcm || !out_utf8 || frames < 0) return CSA_CONV_DECODE;
  Mp3Writer w;
  int rc = w.open(out_utf8, sample_rate, channels, kbps);
  if (rc == CSA_CONV_OK) rc = w.write(pcm, frames, channels);
  if (rc == CSA_CONV_OK) rc = w.finish();
  return rc;
}
