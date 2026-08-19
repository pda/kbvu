#import <CoreAudio/AudioHardware.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <Foundation/Foundation.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct kbvu_capture {
    AudioObjectID tap_id;
    AudioObjectID aggregate_id;
    AudioDeviceIOProcID io_proc_id;
    AudioStreamBasicDescription format;
    void *context;
    bool started;
} kbvu_capture;

extern void kbvu_audio_samples(
    void *context,
    const float *left,
    const float *right,
    uint32_t frame_count,
    uint32_t stride);
extern void kbvu_audio_configure(void *context, double sample_rate_hz);

static void set_error(char *buffer, size_t capacity, const char *message) {
    if (capacity == 0) return;
    snprintf(buffer, capacity, "%s", message);
}

static void set_status_error(
    char *buffer,
    size_t capacity,
    const char *operation,
    OSStatus status) {
    if (capacity == 0) return;
    snprintf(buffer, capacity, "%s failed (OSStatus %d / 0x%08x)",
             operation, (int)status, (unsigned int)status);
}

static void destroy_capture(kbvu_capture *capture) {
    if (capture == NULL) return;
    if (capture->started) {
        AudioDeviceStop(capture->aggregate_id, capture->io_proc_id);
    }
    if (capture->io_proc_id != NULL) {
        AudioDeviceDestroyIOProcID(capture->aggregate_id, capture->io_proc_id);
    }
    if (capture->aggregate_id != kAudioObjectUnknown) {
        AudioHardwareDestroyAggregateDevice(capture->aggregate_id);
    }
    if (capture->tap_id != kAudioObjectUnknown) {
        AudioHardwareDestroyProcessTap(capture->tap_id);
    }
    free(capture);
}

static OSStatus audio_callback(
    AudioObjectID device,
    const AudioTimeStamp *now,
    const AudioBufferList *input_data,
    const AudioTimeStamp *input_time,
    AudioBufferList *output_data,
    const AudioTimeStamp *output_time,
    void *client_data) {
    (void)device;
    (void)now;
    (void)input_time;
    (void)output_data;
    (void)output_time;

    kbvu_capture *capture = client_data;
    if (capture == NULL || input_data == NULL) return noErr;

    const bool non_interleaved =
        (capture->format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    if (non_interleaved) {
        if (input_data->mNumberBuffers < 2) return noErr;
        const AudioBuffer *left = &input_data->mBuffers[0];
        const AudioBuffer *right = &input_data->mBuffers[1];
        if (left->mData == NULL || right->mData == NULL ||
            left->mNumberChannels != 1 || right->mNumberChannels != 1) return noErr;
        const uint32_t left_frames = left->mDataByteSize / sizeof(float);
        const uint32_t right_frames = right->mDataByteSize / sizeof(float);
        const uint32_t frame_count = left_frames < right_frames ? left_frames : right_frames;
        kbvu_audio_samples(capture->context, left->mData, right->mData, frame_count, 1);
    } else {
        if (input_data->mNumberBuffers < 1) return noErr;
        const AudioBuffer *stereo = &input_data->mBuffers[0];
        if (stereo->mData == NULL || stereo->mNumberChannels != 2) return noErr;
        const uint32_t frame_count = stereo->mDataByteSize / (2 * sizeof(float));
        const float *samples = stereo->mData;
        kbvu_audio_samples(capture->context, samples, samples + 1, frame_count, 2);
    }
    return noErr;
}

static bool format_is_supported(const AudioStreamBasicDescription *format) {
    const AudioFormatFlags required = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    const bool non_interleaved =
        (format->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    const UInt32 expected_bytes_per_frame =
        (non_interleaved ? 1 : 2) * sizeof(float);
    return format->mFormatID == kAudioFormatLinearPCM &&
        (format->mFormatFlags & required) == required &&
        (format->mFormatFlags & kAudioFormatFlagIsBigEndian) == kAudioFormatFlagsNativeEndian &&
        format->mBitsPerChannel == 32 &&
        format->mChannelsPerFrame == 2 &&
        format->mFramesPerPacket == 1 &&
        format->mBytesPerFrame == expected_bytes_per_frame &&
        format->mBytesPerPacket == expected_bytes_per_frame;
}

int kbvu_capture_start(
    void *context,
    kbvu_capture **out_capture,
    char *error_message,
    size_t error_capacity) {
    if (out_capture == NULL) return -1;
    *out_capture = NULL;

    if (@available(macOS 14.2, *)) {
        @autoreleasepool {
            kbvu_capture *capture = calloc(1, sizeof(*capture));
            if (capture == NULL) {
                set_error(error_message, error_capacity, "could not allocate capture state");
                return -1;
            }
            capture->tap_id = kAudioObjectUnknown;
            capture->aggregate_id = kAudioObjectUnknown;
            capture->context = context;

            CATapDescription *description =
                [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:@[]];
            description.name = @"kbvu system output";
            description.privateTap = YES;
            description.muteBehavior = CATapUnmuted;

            OSStatus status = AudioHardwareCreateProcessTap(description, &capture->tap_id);
            if (status != noErr) {
                set_status_error(error_message, error_capacity,
                                 "AudioHardwareCreateProcessTap", status);
                destroy_capture(capture);
                return (int)status;
            }

            AudioObjectPropertyAddress format_address = {
                kAudioTapPropertyFormat,
                kAudioObjectPropertyScopeGlobal,
                kAudioObjectPropertyElementMain,
            };
            UInt32 format_size = sizeof(capture->format);
            status = AudioObjectGetPropertyData(
                capture->tap_id, &format_address, 0, NULL,
                &format_size, &capture->format);
            if (status != noErr) {
                set_status_error(error_message, error_capacity,
                                 "reading the tap format", status);
                destroy_capture(capture);
                return (int)status;
            }
            if (!format_is_supported(&capture->format)) {
                set_error(error_message, error_capacity,
                          "the Core Audio tap did not provide stereo native-endian packed Float32 PCM");
                destroy_capture(capture);
                return -2;
            }
            kbvu_audio_configure(capture->context, capture->format.mSampleRate);

            CFStringRef tap_uid = NULL;
            AudioObjectPropertyAddress uid_address = {
                kAudioTapPropertyUID,
                kAudioObjectPropertyScopeGlobal,
                kAudioObjectPropertyElementMain,
            };
            UInt32 uid_size = sizeof(tap_uid);
            status = AudioObjectGetPropertyData(
                capture->tap_id, &uid_address, 0, NULL, &uid_size, &tap_uid);
            if (status != noErr || tap_uid == NULL) {
                set_status_error(error_message, error_capacity,
                                 "reading the tap UID", status);
                destroy_capture(capture);
                return status == noErr ? -3 : (int)status;
            }

            NSString *aggregate_uid = [NSString stringWithFormat:
                @"dev.kbvu.meter.%@", NSUUID.UUID.UUIDString];
            NSDictionary *tap_entry = @{
                @kAudioSubTapUIDKey: (__bridge NSString *)tap_uid,
                @kAudioSubTapDriftCompensationKey: @YES,
            };
            NSDictionary *aggregate_description = @{
                @kAudioAggregateDeviceNameKey: @"kbvu system output capture",
                @kAudioAggregateDeviceUIDKey: aggregate_uid,
                @kAudioAggregateDeviceIsPrivateKey: @YES,
                @kAudioAggregateDeviceIsStackedKey: @NO,
                @kAudioAggregateDeviceTapListKey: @[tap_entry],
                @kAudioAggregateDeviceTapAutoStartKey: @YES,
            };
            status = AudioHardwareCreateAggregateDevice(
                (__bridge CFDictionaryRef)aggregate_description,
                &capture->aggregate_id);
            CFRelease(tap_uid);
            if (status != noErr) {
                set_status_error(error_message, error_capacity,
                                 "AudioHardwareCreateAggregateDevice", status);
                destroy_capture(capture);
                return (int)status;
            }

            status = AudioDeviceCreateIOProcID(
                capture->aggregate_id, audio_callback, capture,
                &capture->io_proc_id);
            if (status != noErr) {
                set_status_error(error_message, error_capacity,
                                 "AudioDeviceCreateIOProcID", status);
                destroy_capture(capture);
                return (int)status;
            }

            status = AudioDeviceStart(capture->aggregate_id, capture->io_proc_id);
            if (status != noErr) {
                set_status_error(error_message, error_capacity,
                                 "AudioDeviceStart", status);
                destroy_capture(capture);
                return (int)status;
            }
            capture->started = true;
            *out_capture = capture;
            return 0;
        }
    }

    set_error(error_message, error_capacity,
              "system-output capture requires macOS 14.2 or newer");
    return -4;
}

void kbvu_capture_stop(kbvu_capture *capture) {
    if (@available(macOS 14.2, *)) {
        @autoreleasepool {
            destroy_capture(capture);
        }
    }
}
