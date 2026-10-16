// Narad's bounded replacement for flutter_webrtc 1.6.2's frame capturer.
// Keep the upstream ABI; avoid its busy wait, data race and leaked pixel buffer.
#include "flutter_frame_capturer.h"
#include "svpng.hpp"
#include <chrono>
#include <cstdio>
#include <thread>
#include <vector>

namespace flutter_webrtc_plugin {
FlutterFrameCapturer::FlutterFrameCapturer(RTCVideoTrack* track, std::string path)
    : track_(track), path_(path), catch_frame_(false) {}

void FlutterFrameCapturer::OnFrame(scoped_refptr<RTCVideoFrame> frame) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (frame_ != nullptr) return;
  frame_ = frame->Copy();
  catch_frame_ = true;
}

void FlutterFrameCapturer::CaptureFrame(std::unique_ptr<MethodResultProxy> result) {
  track_->AddRenderer(this);
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
  bool ready = false;
  while (std::chrono::steady_clock::now() < deadline) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      ready = catch_frame_;
    }
    if (ready) break;
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
  track_->RemoveRenderer(this);
  if (!ready) {result->Error("camera_timeout", "No camera frame arrived within three seconds"); return;}
  std::lock_guard<std::mutex> lock(mutex_);
  if (SaveFrame()) result->Success();
  else result->Error("camera_frame", "Cannot save camera frame");
}

bool FlutterFrameCapturer::SaveFrame() {
  if (frame_ == nullptr) return false;
  const int width = frame_->width(), height = frame_->height();
  if (width < 1 || height < 1 || width > 8192 || height > 8192) return false;
  std::vector<uint8_t> pixels(static_cast<size_t>(width) * height * 4);
  frame_->ConvertToARGB(RTCVideoFrame::Type::kABGR, pixels.data(), -1, width, height);
  FILE* output = std::fopen(path_.c_str(), "wb");
  if (!output) return false;
  svpng(output, width, height, pixels.data(), 1);
  const bool good = !std::ferror(output);
  return std::fclose(output) == 0 && good;
}
} // namespace flutter_webrtc_plugin
