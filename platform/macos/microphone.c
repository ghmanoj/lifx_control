#include "microphone.h"
#include <AudioToolbox/AudioToolbox.h>
#include <dispatch/dispatch.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <time.h>

// AVFoundation exposes its privacy prompt through an Objective-C class method.
extern id const AVMediaTypeAudio;
static bool microphone_access(void)
{
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block bool granted = false;
    typedef void (*request_access_fn)(id, SEL, id, void (^)(BOOL));
    ((request_access_fn)objc_msgSend)((id)objc_getClass("AVCaptureDevice"),
        sel_registerName("requestAccessForMediaType:completionHandler:"), AVMediaTypeAudio,
        ^(BOOL allowed) {
            granted = allowed;
            dispatch_semaphore_signal(done);
        });
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    dispatch_release(done);
    return granted;
}

struct capture {
    pthread_mutex_t lock;
    double rms;
    OSStatus error;
};

static void capture_input(void *context, AudioQueueRef queue, AudioQueueBufferRef buffer,
                          const AudioTimeStamp *time, UInt32 packets,
                          const AudioStreamPacketDescription *descriptions)
{
    (void)time;
    (void)packets;
    (void)descriptions;
    struct capture *capture = context;
    const int16_t *samples = buffer->mAudioData;
    size_t count = buffer->mAudioDataByteSize / sizeof *samples;
    double rms = microphone_rms(samples, count);
    OSStatus status = AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
    pthread_mutex_lock(&capture->lock);
    if (count)
        capture->rms = rms;
    if (status)
        capture->error = status;
    pthread_mutex_unlock(&capture->lock);
}

int capture_microphone(void)
{
    if (!microphone_access()) {
        fputs("Microphone access denied. Enable it in System Settings > Privacy & Security > Microphone.\n", stderr);
        return 1;
    }

    struct capture capture = { .lock = PTHREAD_MUTEX_INITIALIZER, .rms = -1 };
    AudioStreamBasicDescription format = {
        .mSampleRate = 44100, .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
        .mChannelsPerFrame = 1, .mBitsPerChannel = 16, .mFramesPerPacket = 1,
        .mBytesPerFrame = 2, .mBytesPerPacket = 2
    };
    AudioQueueRef queue = NULL;
    OSStatus status = AudioQueueNewInput(&format, capture_input, &capture, NULL, NULL, 0, &queue);
    for (int i = 0; !status && i < 3; i++) {
        AudioQueueBufferRef buffer;
        status = AudioQueueAllocateBuffer(queue, 1024 * format.mBytesPerFrame, &buffer);
        if (!status)
            status = AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
    }
    if (!status)
        status = AudioQueueStart(queue, NULL);
    while (!status) {
        nanosleep(&(struct timespec){ .tv_nsec = 100000000 }, NULL);
        pthread_mutex_lock(&capture.lock);
        double rms = capture.rms;
        status = capture.error;
        pthread_mutex_unlock(&capture.lock);
        if (rms < 0 || status)
            continue;
        if (!emit_microphone_level(rms))
            break;
    }
    if (queue)
        AudioQueueDispose(queue, true);
    pthread_mutex_destroy(&capture.lock);
    if (status)
        fprintf(stderr, "Microphone capture failed (%d). Check System Settings > Sound > Input.\n",
                (int)status);
    return 1;
}
