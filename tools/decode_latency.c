/*
 * Single-frame decode latency of the tico_raw decoder, through the public libavcodec API.
 *
 * usage: decode_latency <sample.bin> <threads> <none|slice|frame> [runs] [options]
 *
 * <sample.bin> is one video sample of a clip (tools/extract_frame.py), sent as one packet.
 * The decoder context stays open, as in a player that seeks: the first decode (cold:
 * the core allocates its buffers) is printed apart, then [runs] (default 10) warm decodes,
 * each timed from avcodec_send_packet() to the end of avcodec_receive_frame().
 * Output: one line per run, then "median <ms>".
 * [options] are decoder options as key=value pairs joined by commas, for example
 * "view=rec709,view_size=half". With frame threads the decoder holds a frame until more
 * packets arrive, so each run sends the packet, then the end of the stream (drain), takes
 * the frame and flushes the decoder after the timing: the time a player waits for the first
 * frame after a seek when every frame thread starts at once.
 *
 * Build against an out-of-tree FFmpeg build (static libraries), in bash (the extralibs
 * variables need word splitting):
 *   . "$FFMPEG_BUILD/ffbuild/config.sh"
 *   cc -O2 -I"$FFMPEG_BUILD" -I"$FFMPEG_BUILD/src" tools/decode_latency.c \
 *       "$FFMPEG_BUILD/libavcodec/libavcodec.a" "$FFMPEG_BUILD/libavutil/libavutil.a" \
 *       $extralibs_avcodec $extralibs_avutil -Wl,-no_warn_duplicate_libraries \
 *       -o decode_latency
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libavcodec/avcodec.h"
#include "libavutil/dict.h"
#include "libavutil/error.h"
#include "libavutil/mem.h"
#include "libavutil/time.h"

static int cmp_double(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}

/* Decode the packet once; return the time in ms, or a negative value on error. */
static double decode_once(AVCodecContext *avctx, const AVPacket *pkt, AVFrame *frame)
{
    int64_t t0 = av_gettime_relative(), t1;
    int ret = avcodec_send_packet(avctx, pkt);

    if (ret >= 0)
        ret = avcodec_receive_frame(avctx, frame);
    if (ret == AVERROR(EAGAIN)) {   /* frame threads: drain */
        ret = avcodec_send_packet(avctx, NULL);
        if (ret >= 0)
            ret = avcodec_receive_frame(avctx, frame);
    }
    t1 = av_gettime_relative();
    if (ret < 0) {
        fprintf(stderr, "decode failed: %s\n", av_err2str(ret));
        return -1;
    }
    av_frame_unref(frame);
    avcodec_flush_buffers(avctx);
    return (t1 - t0) / 1000.0;
}

int main(int argc, char **argv)
{
    const AVCodec *codec = avcodec_find_decoder_by_name("tico_raw");
    AVCodecContext *avctx = NULL;
    AVPacket *pkt = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    AVDictionary *opts = NULL;
    double t[100], cold;
    FILE *f;
    long len;
    int runs, i, ret = 1;

    if (argc < 4 || argc > 6) {
        fprintf(stderr, "usage: %s <sample.bin> <threads> <none|slice|frame> [runs] [options]\n",
                argv[0]);
        return 2;
    }
    runs = argc > 4 ? atoi(argv[4]) : 10;
    if (runs < 1 || runs > 100 || !codec || !pkt || !frame)
        return 2;
    if (argc > 5 && av_dict_parse_string(&opts, argv[5], "=", ",", 0) < 0) {
        fprintf(stderr, "cannot parse the options %s\n", argv[5]);
        return 2;
    }

    f = fopen(argv[1], "rb");
    if (!f || fseek(f, 0, SEEK_END) < 0 || (len = ftell(f)) <= 0 || len > 1 << 30 ||
        fseek(f, 0, SEEK_SET) < 0 || av_new_packet(pkt, len) < 0 ||
        fread(pkt->data, 1, len, f) != (size_t)len) {
        fprintf(stderr, "cannot read %s\n", argv[1]);
        goto end;
    }
    pkt->flags |= AV_PKT_FLAG_KEY;

    avctx = avcodec_alloc_context3(codec);
    if (!avctx)
        goto end;
    avctx->thread_count = atoi(argv[2]);
    avctx->thread_type  = !strcmp(argv[3], "slice") ? FF_THREAD_SLICE :
                          !strcmp(argv[3], "frame") ? FF_THREAD_FRAME : 0;
    if (avcodec_open2(avctx, codec, &opts) < 0)
        goto end;
    if (av_dict_count(opts)) {
        fprintf(stderr, "unknown option %s\n", av_dict_iterate(opts, NULL)->key);
        goto end;
    }
    printf("threads %d, active thread type %s\n", avctx->thread_count,
           avctx->active_thread_type & FF_THREAD_SLICE ? "slice" :
           avctx->active_thread_type & FF_THREAD_FRAME ? "frame" : "none");

    if ((cold = decode_once(avctx, pkt, frame)) < 0)
        goto end;
    printf("cold %.1f ms\n", cold);
    for (i = 0; i < runs; i++) {
        if ((t[i] = decode_once(avctx, pkt, frame)) < 0)
            goto end;
        printf("run %d %.1f ms\n", i + 1, t[i]);
    }
    qsort(t, runs, sizeof(*t), cmp_double);
    printf("median %.1f ms\n", runs & 1 ? t[runs / 2] : (t[runs / 2 - 1] + t[runs / 2]) / 2);
    ret = 0;
end:
    if (f)
        fclose(f);
    avcodec_free_context(&avctx);
    av_dict_free(&opts);
    av_packet_free(&pkt);
    av_frame_free(&frame);
    return ret;
}
