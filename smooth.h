#pragma once
#include <CoreVideo/CoreVideo.h>

#ifdef __cplusplus
extern "C" {
#endif

void SmoothSubmit(CVPixelBufferRef frame);
void SmoothHide(void);

#ifdef __cplusplus
}
#endif
