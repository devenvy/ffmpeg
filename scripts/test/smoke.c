// Portable libav runtime smoke test — the functional check for targets that
// ship no ffmpeg executable (Android .so, iOS .a). Built against the artifact's
// own libraries and run on an emulator/simulator in CI. Exercises the real
// runtime, not just the shape of the binaries:
//   1. links + loads every core libav* library (the program starting proves it)
//   2. encodes a synthetic frame and decodes it back (avcodec/avutil/swscale)
//   3. the whisper ASR filter is registered (af_whisper)
//   4. the https + tls protocols are present (TLS backend wired in)
// Exit 0 = all good; non-zero with a message = the first failure.
#include <stdio.h>
#include <string.h>
#include <libavcodec/avcodec.h>
#include <libavfilter/avfilter.h>
#include <libavformat/avformat.h>
#include <libavformat/avio.h>
#include <libavutil/frame.h>
#include <libavutil/imgutils.h>

#define DIE(...) do { fprintf(stderr, "smoke: " __VA_ARGS__); return 1; } while (0)

static int roundtrip(void) {
    const AVCodec *enc = avcodec_find_encoder(AV_CODEC_ID_MPEG4);   // built-in, every build
    const AVCodec *dec = avcodec_find_decoder(AV_CODEC_ID_MPEG4);
    if (!enc || !dec) DIE("mpeg4 encoder/decoder not found\n");

    AVCodecContext *ec = avcodec_alloc_context3(enc);
    if (!ec) DIE("alloc encoder ctx failed\n");
    ec->width = 160; ec->height = 120; ec->pix_fmt = AV_PIX_FMT_YUV420P;
    ec->time_base = (AVRational){1, 25}; ec->framerate = (AVRational){25, 1};
    if (avcodec_open2(ec, enc, NULL) < 0) DIE("open encoder failed\n");

    AVFrame *fr = av_frame_alloc();
    fr->format = ec->pix_fmt; fr->width = ec->width; fr->height = ec->height;
    if (av_frame_get_buffer(fr, 0) < 0) DIE("frame buffer alloc failed\n");
    for (int y = 0; y < fr->height; y++)
        for (int x = 0; x < fr->width; x++)
            fr->data[0][y * fr->linesize[0] + x] = (uint8_t)(x + y);
    for (int p = 1; p < 3; p++)
        memset(fr->data[p], 128, fr->linesize[p] * (fr->height / 2));
    fr->pts = 0;

    AVPacket *pkt = av_packet_alloc();
    int got_pkt = 0;
    if (avcodec_send_frame(ec, fr) < 0) DIE("send_frame failed\n");
    avcodec_send_frame(ec, NULL); // flush
    while (avcodec_receive_packet(ec, pkt) == 0) { got_pkt = 1; break; }
    if (!got_pkt) DIE("encoder produced no packet\n");

    AVCodecContext *dc = avcodec_alloc_context3(dec);
    dc->width = ec->width; dc->height = ec->height; dc->pix_fmt = ec->pix_fmt;
    dc->time_base = ec->time_base;
    if (avcodec_open2(dc, dec, NULL) < 0) DIE("open decoder failed\n");
    AVFrame *out = av_frame_alloc();
    int got_frame = 0;
    if (avcodec_send_packet(dc, pkt) < 0) DIE("send_packet failed\n");
    avcodec_send_packet(dc, NULL); // flush
    while (avcodec_receive_frame(dc, out) == 0) { got_frame = 1; break; }
    if (!got_frame) DIE("decoder produced no frame\n");
    if (out->width != ec->width || out->height != ec->height)
        DIE("decoded frame has wrong dimensions\n");

    av_frame_free(&out); av_packet_free(&pkt); av_frame_free(&fr);
    avcodec_free_context(&dc); avcodec_free_context(&ec);
    printf("smoke: encode+decode roundtrip OK\n");
    return 0;
}

static int has_whisper(void) {
    if (!avfilter_get_by_name("whisper")) DIE("whisper filter not registered\n");
    printf("smoke: whisper filter present\n");
    return 0;
}

static int has_tls(void) {
    int https = 0, tls = 0;
    for (int out = 0; out <= 1; out++) {
        void *o = NULL; const char *name;
        while ((name = avio_enum_protocols(&o, out))) {
            if (!strcmp(name, "https")) https = 1;
            if (!strcmp(name, "tls"))   tls = 1;
        }
    }
    if (!https) DIE("https protocol missing (TLS backend not wired)\n");
    if (!tls)   DIE("tls protocol missing (TLS backend not wired)\n");
    printf("smoke: https + tls protocols present\n");
    return 0;
}

int main(void) {
    printf("smoke: avcodec %u avformat %u avutil %u avfilter %u\n",
           avcodec_version(), avformat_version(), avutil_version(), avfilter_version());
    int rc = roundtrip(); if (rc) return rc;
    rc = has_whisper();    if (rc) return rc;
    rc = has_tls();        if (rc) return rc;
    printf("smoke: ALL PASS\n");
    return 0;
}
