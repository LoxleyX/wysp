#include "audio_capture.h"
#include "miniaudio.h"
#include <stdlib.h>
#include <string.h>

#define MAX_SAMPLES (16000 * 60)  // 60 seconds max

struct AudioCapture {
    ma_device device;
    float* buffer;
    int sample_count;
    int callback_count;
    int recording;
};

static void data_callback(ma_device* pDevice, void* pOutput, const void* pInput, ma_uint32 frameCount) {
    (void)pOutput;
    AudioCapture* cap = (AudioCapture*)pDevice->pUserData;

    if (!cap || !cap->recording) return;

    if (pInput && cap->sample_count + frameCount < MAX_SAMPLES) {
        memcpy(cap->buffer + cap->sample_count, pInput, frameCount * sizeof(float));
        cap->sample_count += frameCount;
        cap->callback_count++;
    }
}

AudioCapture* audio_capture_create(void) {
    AudioCapture* cap = (AudioCapture*)malloc(sizeof(AudioCapture));
    if (!cap) return NULL;

    cap->buffer = (float*)malloc(MAX_SAMPLES * sizeof(float));
    if (!cap->buffer) {
        free(cap);
        return NULL;
    }

    cap->sample_count = 0;
    cap->callback_count = 0;
    cap->recording = 0;

    ma_device_config config = ma_device_config_init(ma_device_type_capture);
    config.capture.format = ma_format_f32;
    config.capture.channels = 1;
    config.sampleRate = 16000;
    config.dataCallback = data_callback;
    config.pUserData = cap;

    if (ma_device_init(NULL, &config, &cap->device) != MA_SUCCESS) {
        free(cap->buffer);
        free(cap);
        return NULL;
    }

    return cap;
}

int audio_capture_start(AudioCapture* cap) {
    if (!cap) return -1;

    cap->sample_count = 0;
    cap->callback_count = 0;
    cap->recording = 1;

    if (ma_device_start(&cap->device) != MA_SUCCESS) {
        cap->recording = 0;
        return -1;
    }

    return 0;
}

int audio_capture_stop(AudioCapture* cap, float* buffer, int max_samples) {
    if (!cap) return 0;

    cap->recording = 0;
    ma_device_stop(&cap->device);

    int count = cap->sample_count;
    if (buffer && max_samples > 0) {
        int to_copy = count < max_samples ? count : max_samples;
        memcpy(buffer, cap->buffer, to_copy * sizeof(float));
    }

    return count;
}

int audio_capture_get_callback_count(AudioCapture* cap) {
    return cap ? cap->callback_count : 0;
}

void audio_capture_destroy(AudioCapture* cap) {
    if (!cap) return;

    ma_device_uninit(&cap->device);
    free(cap->buffer);
    free(cap);
}
