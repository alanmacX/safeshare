#include <cstdint>
#include <memory>
#include <string>
#include <vector>
#include <unistd.h>
#include <sys/stat.h>

#include "napi/native_api.h"
#include "multimedia/player_framework/native_avbuffer.h"
#include "multimedia/player_framework/native_avcodec_base.h"
#include "multimedia/player_framework/native_avdemuxer.h"
#include "multimedia/player_framework/native_avformat.h"
#include "multimedia/player_framework/native_avmuxer.h"
#include "multimedia/player_framework/native_avsource.h"

namespace {
constexpr int32_t DEFAULT_SAMPLE_CAPACITY = 32 * 1024 * 1024;
constexpr int32_t MAX_TRACK_COUNT = 32;

struct RemuxWork {
    napi_env env = nullptr;
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    int32_t inputFd = -1;
    int64_t inputLength = 0;
    int32_t outputFd = -1;
    int32_t trackCount = 0;
    int32_t videoTrackCount = 0;
    int64_t sampleCount = 0;
    std::string error;
};

void SetError(RemuxWork *work, const char *message)
{
    if (work->error.empty()) {
        work->error = message;
    }
}

bool Ok(OH_AVErrCode result)
{
    return result == AV_ERR_OK;
}

bool IsAudioOrVideoTrack(OH_AVFormat *format, int32_t *trackType)
{
    int32_t type = -1;
    if (OH_AVFormat_GetIntValue(format, OH_MD_KEY_TRACK_TYPE, &type)) {
        if (trackType != nullptr) *trackType = type;
        return type == MEDIA_TYPE_AUD || type == MEDIA_TYPE_VID;
    }
    // Older demuxers may omit track-type while still exposing codec MIME.
    // Accept only explicit audio/video MIME families; timed metadata,
    // subtitles and auxiliary tracks are intentionally not copied.
    const char *mime = nullptr;
    if (!OH_AVFormat_GetStringValue(format, OH_MD_KEY_CODEC_MIME, &mime) || mime == nullptr) {
        return false;
    }
    const std::string value(mime);
    if (value.rfind("audio/", 0) == 0) {
        if (trackType != nullptr) *trackType = MEDIA_TYPE_AUD;
        return true;
    }
    if (value.rfind("video/", 0) == 0) {
        if (trackType != nullptr) *trackType = MEDIA_TYPE_VID;
        return true;
    }
    return false;
}

uint32_t ReadBe32(const uint8_t *bytes)
{
    return (static_cast<uint32_t>(bytes[0]) << 24) |
        (static_cast<uint32_t>(bytes[1]) << 16) |
        (static_cast<uint32_t>(bytes[2]) << 8) | static_cast<uint32_t>(bytes[3]);
}

uint64_t ReadBe64(const uint8_t *bytes)
{
    return (static_cast<uint64_t>(ReadBe32(bytes)) << 32) | ReadBe32(bytes + 4);
}

bool WriteZeros(int32_t fd, int64_t offset, size_t length)
{
    uint8_t zeros[16] = {0};
    return length <= sizeof(zeros) && pwrite(fd, zeros, length, offset) == static_cast<ssize_t>(length);
}

bool ClearContainerTimesInRange(int32_t fd, int64_t start, int64_t end, int depth)
{
    if (depth > 4) return false;
    int64_t cursor = start;
    while (cursor + 8 <= end) {
        uint8_t header[16] = {0};
        if (pread(fd, header, sizeof(header), cursor) < 8) return false;
        uint64_t size = ReadBe32(header);
        int64_t headerSize = 8;
        if (size == 1) {
            size = ReadBe64(header + 8);
            headerSize = 16;
        } else if (size == 0) {
            size = static_cast<uint64_t>(end - cursor);
        }
        if (size < static_cast<uint64_t>(headerSize) ||
            size > static_cast<uint64_t>(end - cursor)) return false;
        const std::string type(reinterpret_cast<char *>(header + 4), 4);
        const int64_t payload = cursor + headerSize;
        const int64_t boxEnd = cursor + static_cast<int64_t>(size);
        if (type == "mvhd" || type == "tkhd" || type == "mdhd") {
            uint8_t version = 0;
            if (pread(fd, &version, 1, payload) != 1) return false;
            // FullBox header (version + flags) is followed by creation and
            // modification times. Clearing both prevents AVMuxer-generated
            // timestamps from reappearing as fresh privacy findings.
            const size_t fieldBytes = version == 1 ? 8 : 4;
            if (!WriteZeros(fd, payload + 4, fieldBytes) ||
                !WriteZeros(fd, payload + 4 + static_cast<int64_t>(fieldBytes), fieldBytes)) return false;
        } else if (type == "moov" || type == "trak" || type == "mdia") {
            if (!ClearContainerTimesInRange(fd, payload, boxEnd, depth + 1)) return false;
        }
        cursor = boxEnd;
    }
    return cursor == end;
}

bool ClearContainerTimes(int32_t fd)
{
    struct stat info {};
    if (fstat(fd, &info) != 0 || info.st_size <= 0) return false;
    if (!ClearContainerTimesInRange(fd, 0, info.st_size, 0)) return false;
    return fsync(fd) == 0;
}

void ExecuteRemux(napi_env, void *raw)
{
    auto *work = static_cast<RemuxWork *>(raw);
    OH_AVSource *source = nullptr;
    OH_AVDemuxer *demuxer = nullptr;
    OH_AVMuxer *muxer = nullptr;
    OH_AVFormat *sourceFormat = nullptr;
    std::vector<OH_AVFormat *> trackFormats;
    std::vector<uint32_t> sourceTracks;
    std::vector<int32_t> outputTracks;
    std::vector<OH_AVBuffer *> samples;
    std::vector<OH_AVCodecBufferAttr> sampleAttrs;
    std::vector<uint8_t> sampleEnded;
    bool muxerStarted = false;
    int32_t sourceTrackCount = 0;
    bool rotationApplied = false;

    source = OH_AVSource_CreateWithFD(work->inputFd, 0, work->inputLength);
    if (source == nullptr) {
        SetError(work, "SOURCE_CREATE_FAILED");
        goto cleanup;
    }
    sourceFormat = OH_AVSource_GetSourceFormat(source);
    if (sourceFormat == nullptr ||
        !OH_AVFormat_GetIntValue(sourceFormat, OH_MD_KEY_TRACK_COUNT, &sourceTrackCount) ||
        sourceTrackCount <= 0 || sourceTrackCount > MAX_TRACK_COUNT) {
        SetError(work, "TRACK_COUNT_INVALID");
        goto cleanup;
    }
    demuxer = OH_AVDemuxer_CreateWithSource(source);
    muxer = OH_AVMuxer_Create(work->outputFd, AV_OUTPUT_FORMAT_MPEG_4);
    if (demuxer == nullptr || muxer == nullptr) {
        SetError(work, "PIPELINE_CREATE_FAILED");
        goto cleanup;
    }

    trackFormats.reserve(sourceTrackCount);
    sourceTracks.reserve(sourceTrackCount);
    outputTracks.reserve(sourceTrackCount);
    for (int32_t index = 0; index < sourceTrackCount; ++index) {
        OH_AVFormat *format = OH_AVSource_GetTrackFormat(source, static_cast<uint32_t>(index));
        if (format == nullptr) {
            SetError(work, "TRACK_FORMAT_FAILED");
            goto cleanup;
        }
        int32_t trackType = -1;
        if (!IsAudioOrVideoTrack(format, &trackType)) {
            OH_AVFormat_Destroy(format);
            continue;
        }
        // Rotation is a property of the video track format, not reliably of
        // the source-wide format. Applying the track value to the output
        // preserves portrait/landscape playback without copying private
        // source metadata.
        if (trackType == MEDIA_TYPE_VID && !rotationApplied) {
            int32_t rotation = 0;
            if (OH_AVFormat_GetIntValue(format, OH_MD_KEY_ROTATION, &rotation) &&
                (rotation == 0 || rotation == 90 || rotation == 180 || rotation == 270)) {
                if (!Ok(OH_AVMuxer_SetRotation(muxer, rotation))) {
                    OH_AVFormat_Destroy(format);
                    SetError(work, "ROTATION_COPY_FAILED");
                    goto cleanup;
                }
                rotationApplied = true;
            }
        }
        if (trackType == MEDIA_TYPE_VID) ++work->videoTrackCount;
        trackFormats.push_back(format);
        int32_t outputTrack = -1;
        if (!Ok(OH_AVMuxer_AddTrack(muxer, &outputTrack, format)) || outputTrack < 0 ||
            !Ok(OH_AVDemuxer_SelectTrackByID(demuxer, static_cast<uint32_t>(index)))) {
            SetError(work, "TRACK_SETUP_FAILED");
            goto cleanup;
        }
        sourceTracks.push_back(static_cast<uint32_t>(index));
        outputTracks.push_back(outputTrack);
    }
    work->trackCount = static_cast<int32_t>(outputTracks.size());
    if (work->trackCount <= 0) {
        SetError(work, "NO_PLAYABLE_TRACKS");
        goto cleanup;
    }
    if (!Ok(OH_AVMuxer_Start(muxer))) {
        SetError(work, "MUXER_START_FAILED");
        goto cleanup;
    }
    muxerStarted = true;
    samples.reserve(work->trackCount);
    sampleAttrs.resize(work->trackCount);
    sampleEnded.assign(work->trackCount, 0);
    for (int32_t index = 0; index < work->trackCount; ++index) {
        OH_AVBuffer *buffer = OH_AVBuffer_Create(DEFAULT_SAMPLE_CAPACITY);
        if (buffer == nullptr) {
            SetError(work, "BUFFER_CREATE_FAILED");
            goto cleanup;
        }
        samples.push_back(buffer);
        if (!Ok(OH_AVDemuxer_ReadSampleBuffer(demuxer, sourceTracks[index], buffer)) ||
            !Ok(OH_AVBuffer_GetBufferAttr(buffer, &sampleAttrs[index]))) {
            SetError(work, "SAMPLE_READ_FAILED");
            goto cleanup;
        }
        if ((sampleAttrs[index].flags & AVCODEC_BUFFER_FLAGS_INCOMPLETE_FRAME) != 0) {
            SetError(work, "SAMPLE_TOO_LARGE");
            goto cleanup;
        }
        if ((sampleAttrs[index].flags & AVCODEC_BUFFER_FLAGS_EOS) != 0) sampleEnded[index] = 1;
    }

    // Keep the output globally interleaved by PTS. Writing one entire audio
    // track before the video track produces technically populated MP4 files
    // that some Huawei previewers cannot seek or thumbnail reliably.
    while (true) {
        int32_t next = -1;
        for (int32_t index = 0; index < work->trackCount; ++index) {
            if (sampleEnded[index] != 0) continue;
            if (next < 0 || sampleAttrs[index].pts < sampleAttrs[next].pts) next = index;
        }
        if (next < 0) break;
        if (sampleAttrs[next].size > 0) {
            if (!Ok(OH_AVMuxer_WriteSampleBuffer(muxer,
                static_cast<uint32_t>(outputTracks[next]), samples[next]))) {
                SetError(work, "SAMPLE_WRITE_FAILED");
                goto cleanup;
            }
            ++work->sampleCount;
        }
        if (!Ok(OH_AVDemuxer_ReadSampleBuffer(demuxer, sourceTracks[next], samples[next])) ||
            !Ok(OH_AVBuffer_GetBufferAttr(samples[next], &sampleAttrs[next]))) {
            SetError(work, "SAMPLE_READ_FAILED");
            goto cleanup;
        }
        if ((sampleAttrs[next].flags & AVCODEC_BUFFER_FLAGS_INCOMPLETE_FRAME) != 0) {
            SetError(work, "SAMPLE_TOO_LARGE");
            goto cleanup;
        }
        if ((sampleAttrs[next].flags & AVCODEC_BUFFER_FLAGS_EOS) != 0) sampleEnded[next] = 1;
    }

cleanup:
    for (OH_AVBuffer *buffer : samples) {
        if (buffer != nullptr) OH_AVBuffer_Destroy(buffer);
    }
    if (muxerStarted) {
        const bool stopped = Ok(OH_AVMuxer_Stop(muxer));
        if (!stopped && work->error.empty()) {
            SetError(work, "MUXER_STOP_FAILED");
        } else if (stopped && work->error.empty() && !ClearContainerTimes(work->outputFd)) {
            SetError(work, "CONTAINER_TIME_CLEAR_FAILED");
        }
    }
    if (muxer != nullptr) OH_AVMuxer_Destroy(muxer);
    if (demuxer != nullptr) OH_AVDemuxer_Destroy(demuxer);
    for (OH_AVFormat *format : trackFormats) {
        OH_AVFormat_Destroy(format);
    }
    if (sourceFormat != nullptr) OH_AVFormat_Destroy(sourceFormat);
    if (source != nullptr) OH_AVSource_Destroy(source);
}

void CompleteRemux(napi_env env, napi_status status, void *raw)
{
    std::unique_ptr<RemuxWork> work(static_cast<RemuxWork *>(raw));
    if (status != napi_ok && work->error.empty()) {
        work->error = "ASYNC_WORK_FAILED";
    }
    if (!work->error.empty()) {
        napi_value message = nullptr;
        napi_value error = nullptr;
        napi_create_string_utf8(env, work->error.c_str(), NAPI_AUTO_LENGTH, &message);
        napi_create_error(env, nullptr, message, &error);
        napi_reject_deferred(env, work->deferred, error);
    } else {
        napi_value result = nullptr;
        napi_value trackCount = nullptr;
        napi_value sampleCount = nullptr;
        napi_value videoTrackCount = nullptr;
        napi_create_object(env, &result);
        napi_create_int32(env, work->trackCount, &trackCount);
        napi_create_int64(env, work->sampleCount, &sampleCount);
        napi_create_int32(env, work->videoTrackCount, &videoTrackCount);
        napi_set_named_property(env, result, "trackCount", trackCount);
        napi_set_named_property(env, result, "sampleCount", sampleCount);
        napi_set_named_property(env, result, "videoTrackCount", videoTrackCount);
        napi_resolve_deferred(env, work->deferred, result);
    }
    napi_delete_async_work(env, work->work);
}

napi_value RemuxToMp4(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value argv[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc != 3) {
        napi_throw_type_error(env, nullptr, "Expected input fd, length, and output fd");
        return nullptr;
    }
    auto work = std::make_unique<RemuxWork>();
    work->env = env;
    if (napi_get_value_int32(env, argv[0], &work->inputFd) != napi_ok ||
        napi_get_value_int64(env, argv[1], &work->inputLength) != napi_ok ||
        napi_get_value_int32(env, argv[2], &work->outputFd) != napi_ok ||
        work->inputFd < 0 || work->outputFd < 0 || work->inputLength <= 0) {
        napi_throw_type_error(env, nullptr, "Invalid remux descriptors");
        return nullptr;
    }
    napi_value promise = nullptr;
    napi_value resourceName = nullptr;
    napi_create_promise(env, &work->deferred, &promise);
    napi_create_string_utf8(env, "SafeShareRemux", NAPI_AUTO_LENGTH, &resourceName);
    if (napi_create_async_work(env, nullptr, resourceName, ExecuteRemux, CompleteRemux,
        work.get(), &work->work) != napi_ok || napi_queue_async_work(env, work->work) != napi_ok) {
        napi_throw_error(env, nullptr, "Unable to queue remux");
        return nullptr;
    }
    work.release();
    return promise;
}
} // namespace

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor descriptors[] = {
        {"remuxToMp4", nullptr, RemuxToMp4, nullptr, nullptr, nullptr, napi_default, nullptr}
    };
    napi_define_properties(env, exports, sizeof(descriptors) / sizeof(descriptors[0]), descriptors);
    return exports;
}
EXTERN_C_END

static napi_module module = {
    1, 0, nullptr, Init, "remuxer", nullptr, {0}
};

extern "C" __attribute__((constructor)) void RegisterRemuxerModule()
{
    napi_module_register(&module);
}
