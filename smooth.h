// Feeding smooth-anything from a host application that already has decoded video frames.
// Build main.m into the host with SMOOTH_EMBEDDED defined.
#pragma once
#include <CoreVideo/CoreVideo.h>

#ifdef __cplusplus
extern "C" {
#endif

// Any thread. Hands over one decoded 8-bit 4:2:0 frame. The first call opens the output window.
void SmoothSubmit(CVPixelBufferRef frame);

// Any thread. Hides the output window, for example when the stream ends. The next frame shows it again.
void SmoothHide(void);

#ifdef __cplusplus
}
#endif
