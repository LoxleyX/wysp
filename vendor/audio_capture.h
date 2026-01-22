#ifndef AUDIO_CAPTURE_H
#define AUDIO_CAPTURE_H

#include <stdint.h>

// Opaque handle
typedef struct AudioCapture AudioCapture;

// Create audio capture (returns NULL on failure)
AudioCapture* audio_capture_create(void);

// Start recording
int audio_capture_start(AudioCapture* cap);

// Stop recording and get samples
// Returns number of samples, fills buffer (caller provides buffer)
// Call with NULL buffer first to get required size
int audio_capture_stop(AudioCapture* cap, float* buffer, int max_samples);

// Get callback count (for debugging)
int audio_capture_get_callback_count(AudioCapture* cap);

// Destroy
void audio_capture_destroy(AudioCapture* cap);

#endif
