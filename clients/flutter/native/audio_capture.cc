// Record only the explicitly selected remote WebRTC track, never system playback.
#include "audio_capture.h"
#include "rtc_audio_track.h"
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <fstream>
#include <map>
#include <mutex>
#include <thread>
#include <stdexcept>
#include <vector>

namespace flutter_webrtc_plugin {
namespace {
class Capture : public libwebrtc::AudioTrackSink {
 public:
  Capture(libwebrtc::RTCAudioTrack* track, const std::string& path)
      : track_(track), file_(path, std::ios::binary | std::ios::trunc),
        started_(std::chrono::steady_clock::now()) {
    if (!file_) throw std::runtime_error("Cannot create audio recording");
    char header[44] = {}; file_.write(header, 44);
    writer_ = std::thread([this] { Write(); });
    track_->AddSink(this);
  }
  ~Capture() { Stop(); }
  void OnData(const void* data, int bits, int rate, size_t channels, size_t frames) override {
    std::lock_guard<std::mutex> lock(mutex_);
    if (done_ || failed_) return;
    if (bits != 16 || rate < 8000 || rate > 96000 || channels < 1 || channels > 2 || frames == 0 || frames > 9600) {
      failed_ = true; return;
    }
    if (rate_ == 0) {
      rate_ = rate; channels_ = channels;
      const auto delay = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - started_).count();
      if (delay > 3000) { failed_ = true; return; }
      queue_.emplace_back((static_cast<size_t>(delay) * rate / 1000) * channels * 2, 0);
      queued_ += queue_.back().size();
    }
    const size_t bytes = frames * channels * 2;
    if (rate_ != rate || channels_ != channels || queued_ + bytes > 4 * 1024 * 1024 || written_ + queued_ + bytes > 128 * 1024 * 1024) {
      failed_ = true; return;
    }
    const auto* first = static_cast<const char*>(data);
    queue_.emplace_back(first, first + bytes); queued_ += bytes; ready_.notify_one();
  }
  bool Stop() {
    if (stopped_) return success_;
    stopped_ = true;
    track_->RemoveSink(this);
    { std::lock_guard<std::mutex> lock(mutex_); done_ = true; ready_.notify_one(); }
    if (writer_.joinable()) writer_.join();
    if (!failed_ && rate_ > 0 && written_ > 0) {
      file_.seekp(0); file_.write("RIFF",4); Le(written_+36,4); file_.write("WAVEfmt ",8);
      Le(16,4); Le(1,2); Le(channels_,2); Le(rate_,4); Le(rate_*channels_*2,4);
      Le(channels_*2,2); Le(16,2); file_.write("data",4); Le(written_,4); file_.flush();
      success_ = file_.good();
    }
    file_.close(); return success_;
  }
 private:
  void Le(uint32_t value, int count) { for(int i=0;i<count;i++) file_.put(static_cast<char>((value>>(8*i))&255)); }
  void Write() {
    while (true) {
      std::vector<char> bytes;
      { std::unique_lock<std::mutex> lock(mutex_);
        ready_.wait(lock,[this]{return done_ || !queue_.empty();});
        if(queue_.empty() && done_) break;
        bytes = std::move(queue_.front()); queue_.pop_front(); queued_ -= bytes.size();
      }
      file_.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
      { std::lock_guard<std::mutex> lock(mutex_); written_ += bytes.size(); if(!file_) failed_=true; }
    }
  }
  libwebrtc::scoped_refptr<libwebrtc::RTCAudioTrack> track_;
  std::ofstream file_;
  std::chrono::steady_clock::time_point started_;
  std::mutex mutex_; std::condition_variable ready_; std::thread writer_;
  std::deque<std::vector<char>> queue_;
  size_t queued_=0; uint32_t written_=0; int rate_=0; size_t channels_=0;
  bool done_=false, failed_=false, stopped_=false, success_=false;
};
std::map<FlutterWebRTC*, std::map<std::string,std::unique_ptr<Capture>>> captures;
}
bool NaradAudioCapture(FlutterWebRTC* owner, const MethodCallProxy& call,
                       std::unique_ptr<MethodResultProxy>& result) {
  const auto method=call.method_name();
  if(method!="naradAudioStart" && method!="naradAudioStop") return false;
  try {
    if(!call.arguments()) throw std::runtime_error("Audio recording arguments missing");
    const auto args=GetValue<EncodableMap>(*call.arguments());
    const auto id=findString(args,"trackId");
    if(id.empty()) throw std::runtime_error("Audio track missing");
    auto& entries=captures[owner];
    if(method=="naradAudioStart") {
      if(entries.size()>=4 || entries.count(id)) throw std::runtime_error("Audio recording already active");
      auto track=owner->MediaTrackForId(id);
      if(!track || track->kind().std_string()!="audio") throw std::runtime_error("Audio track unavailable");
      const auto path=findString(args,"path");
      if(path.empty()) throw std::runtime_error("Audio path missing");
      entries[id]=std::make_unique<Capture>(static_cast<libwebrtc::RTCAudioTrack*>(track.get()),path);
    } else {
      auto it=entries.find(id);
      if(it==entries.end()) throw std::runtime_error("Audio recording unavailable");
      const bool ok=it->second->Stop(); entries.erase(it);
      if(!ok) throw std::runtime_error("No audio frames, unsupported format, or audio recording overflow");
    }
    result->Success();
  } catch(const std::exception& e) { result->Error("audio_recording",e.what()); }
  return true;
}
void NaradAudioCaptureDispose(FlutterWebRTC* owner) { captures.erase(owner); }
}
