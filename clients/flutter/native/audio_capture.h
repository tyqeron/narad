#pragma once
#include "flutter_webrtc.h"
namespace flutter_webrtc_plugin {
bool NaradAudioCapture(FlutterWebRTC* owner, const MethodCallProxy& call,
                       std::unique_ptr<MethodResultProxy>& result);
void NaradAudioCaptureDispose(FlutterWebRTC* owner);
}
