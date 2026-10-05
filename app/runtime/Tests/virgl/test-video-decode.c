/* H.264 decoding through the VideoToolbox backend, the way the guest's VA-API driver
 * drives it: a video codec with the BITSTREAM entrypoint, an NV12 video buffer whose
 * planes are guest textures, then per picture BEGIN_FRAME, DECODE_BITSTREAM (picture
 * description, compressed data) and END_FRAME. The stream is made here with
 * VTCompressionSession (parameter sets in-band, as FFmpeg and Chrome send them).
 * Before each picture the guest's luma texture is cleared, so a picture that never
 * arrives shows as a failure.
 * Checks: the pictures land in the guest's textures close to what went in (luma PSNR);
 * at most 8 decoders are open at once per VM: a 9th decodes nothing, closing one
 * makes room, and a guest context that goes away frees the decoders it had.
 * Runs on Apple's software OpenGL (soft-gl.h); the decoder is the Mac's media engine.
 * Skips when the Mac has no H.264 encoder or decoder. */
#include <CoreMedia/CoreMedia.h>
#include <OpenGL/OpenGL.h>
#include <VideoToolbox/VideoToolbox.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/uio.h>
#include "soft-gl.h"
#define VIRGL_RENDERER_UNSTABLE_APIS 1
#include "virglrenderer.h"
#include "virgl_hw.h"
#include "virgl_protocol.h"
#include "virgl_video_hw.h"

enum { W = 320, H = 240, FRAMES = 10, MAX_LIVE = 8 };
enum { TEST_PIPE_BUFFER = 0, TEST_PIPE_TEXTURE_2D = 2 };
/* guest numbering (Mesa >= 26): enum pipe_video_profile / entrypoint */
enum { G_AVC_HIGH = 11, G_ENTRYPOINT_BITSTREAM = 1 };
enum { R_Y = 1, R_UV, R_DESC, R_BITS };
enum { BUF = 2 };   /* codecs get 10, 11, ... */

static CGLContextObj main_ctx;
static int failures;

static void check(int ok, const char *what)
{
   printf("%s: %s\n", ok ? "ok" : "FAIL", what);
   failures += !ok;
}

static void write_fence(void *cookie, uint32_t fence)
{
   (void)cookie;
   (void)fence;
}

static virgl_renderer_gl_context create_gl_context(void *cookie, int scanout,
                                                   struct virgl_renderer_gl_ctx_param *param)
{
   (void)cookie;
   (void)scanout;
   (void)param;
   /* QEMU (ui/cocoa) shares every context with its view's context. */
   return soft_gl_context(main_ctx);
}

static void destroy_gl_context(void *cookie, virgl_renderer_gl_context ctx)
{
   (void)cookie;
   CGLDestroyContext(ctx);
}

static int make_current(void *cookie, int scanout, virgl_renderer_gl_context ctx)
{
   (void)cookie;
   (void)scanout;
   return CGLSetCurrentContext(ctx) ? -1 : 0;
}

static struct virgl_renderer_callbacks callbacks = {
   .version = 1,
   .write_fence = write_fence,
   .create_gl_context = create_gl_context,
   .destroy_gl_context = destroy_gl_context,
   .make_current = make_current,
};

struct cmds {
   uint32_t dw[65536];
   unsigned n;
};

static struct cmds *c;

static void emit(uint32_t v)
{
   c->dw[c->n++] = v;
}

static int submit(uint32_t ctx_id)
{
   int r = virgl_renderer_submit_cmd(c->dw, (int)ctx_id, (int)c->n);
   c->n = 0;
   return r;
}

static struct iovec iov[8];

static void make_res(uint32_t handle, uint32_t target, uint32_t format, uint32_t bind,
                     uint32_t w, uint32_t h, void *backing, size_t size)
{
   struct virgl_renderer_resource_create_args a = {
      .handle = handle, .target = target, .format = format, .bind = bind,
      .width = w, .height = h, .depth = 1, .array_size = 1,
   };
   virgl_renderer_resource_create(&a, NULL, 0);
   if (backing) {
      iov[handle] = (struct iovec){ backing, size };
      virgl_renderer_resource_attach_iov(handle, &iov[handle], 1);
   }
}

/* RESOURCE_INLINE_WRITE of a whole 2D level */
static void emit_plane(uint32_t handle, uint32_t w, uint32_t h, uint32_t bpp,
                       const uint8_t *data)
{
   uint32_t bytes = w * h * bpp, words = (bytes + 3) / 4;
   emit(VIRGL_CMD0(VIRGL_CCMD_RESOURCE_INLINE_WRITE, 0, 11 + words));
   emit(handle);
   emit(0);
   emit(0);
   emit(w * bpp);       /* stride */
   emit(0);
   emit(0);
   emit(0);
   emit(0);
   emit(w);
   emit(h);
   emit(1);
   memset(&c->dw[c->n], 0, words * 4);
   memcpy(&c->dw[c->n], data, bytes);
   c->n += words;
}

/* a moving gradient with a square, so pictures differ */
static void make_picture(int f, uint8_t *y, uint8_t *uv)
{
   for (int j = 0; j < H; j++)
      for (int i = 0; i < W; i++) {
         int v = (i + 2 * f) * 255 / (W + 60);
         if (i >= 40 + 4 * f && i < 100 + 4 * f && j >= 60 && j < 120)
            v = 235;
         y[j * W + i] = (uint8_t)(16 + v * 219 / 255);
      }
   for (int j = 0; j < H / 2; j++)
      for (int i = 0; i < W / 2; i++) {
         uv[(j * W / 2 + i) * 2] = (uint8_t)(100 + j / 2);
         uv[(j * W / 2 + i) * 2 + 1] = (uint8_t)(150 - i / 4);
      }
}

/* --- the stream: FRAMES pictures, Annex B, SPS and PPS before the IDR ----------- */
static uint8_t ys[FRAMES][W * H];
static uint8_t *au[FRAMES];
static size_t au_size[FRAMES];
static int au_count;

static void put_nal(uint8_t **out, size_t *n, const uint8_t *nal, size_t len)
{
   *out = realloc(*out, *n + 4 + len);
   memcpy(*out + *n, "\0\0\0\1", 4);
   memcpy(*out + *n + 4, nal, len);
   *n += 4 + len;
}

static void enc_cb(void *ref, void *frame_ref, OSStatus st, VTEncodeInfoFlags flags,
                   CMSampleBufferRef sample)
{
   (void)ref;
   (void)frame_ref;
   (void)flags;
   if (st != noErr || !sample || au_count >= FRAMES)
      return;
   uint8_t *out = NULL;
   size_t n = 0;
   CFArrayRef att = CMSampleBufferGetSampleAttachmentsArray(sample, false);
   int key = !(att && CFArrayGetCount(att) &&
               CFDictionaryContainsKey(CFArrayGetValueAtIndex(att, 0),
                                       kCMSampleAttachmentKey_NotSync));
   if (key) {
      CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sample);
      for (size_t i = 0; i < 2; i++) {
         const uint8_t *ps = NULL;
         size_t len = 0;
         if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, i, &ps, &len, NULL,
                                                                NULL) == noErr)
            put_nal(&out, &n, ps, len);
      }
   }
   CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
   size_t total = CMBlockBufferGetDataLength(block);
   uint8_t *data = malloc(total);
   CMBlockBufferCopyDataBytes(block, 0, total, data);
   for (size_t off = 0; off + 4 <= total;) {
      size_t len = (size_t)data[off] << 24 | data[off + 1] << 16 | data[off + 2] << 8 |
                   data[off + 3];
      if (len > total - off - 4)
         break;
      put_nal(&out, &n, data + off + 4, len);
      off += 4 + len;
   }
   free(data);
   au[au_count] = out;
   au_size[au_count++] = n;
}

static int make_stream(void)
{
   VTCompressionSessionRef s = NULL;
   if (VTCompressionSessionCreate(NULL, W, H, kCMVideoCodecType_H264, NULL, NULL, NULL,
                                  enc_cb, NULL, &s) != noErr)
      return 0;
   VTSessionSetProperty(s, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
   VTSessionSetProperty(s, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
   VTSessionSetProperty(s, kVTCompressionPropertyKey_ProfileLevel,
                        kVTProfileLevel_H264_High_AutoLevel);
   static uint8_t uv[W * H / 2];
   for (int f = 0; f < FRAMES; f++) {
      CVPixelBufferRef pix = NULL;
      CVPixelBufferCreate(NULL, W, H, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, NULL,
                          &pix);
      make_picture(f, ys[f], uv);
      CVPixelBufferLockBaseAddress(pix, 0);
      for (int p = 0; p < 2; p++) {
         uint8_t *dst = CVPixelBufferGetBaseAddressOfPlane(pix, p);
         size_t row = CVPixelBufferGetBytesPerRowOfPlane(pix, p);
         for (int j = 0; j < (p ? H / 2 : H); j++)
            memcpy(dst + j * row, p ? uv + j * W : ys[f] + j * W, W);
      }
      CVPixelBufferUnlockBaseAddress(pix, 0);
      VTCompressionSessionEncodeFrame(s, pix, CMTimeMake(f, 30), kCMTimeInvalid, NULL, NULL,
                                      NULL);
      CVPixelBufferRelease(pix);
   }
   VTCompressionSessionCompleteFrames(s, kCMTimeInvalid);
   VTCompressionSessionInvalidate(s);
   CFRelease(s);
   return au_count == FRAMES;
}

/* --- the guest's side ---------------------------------------------------------- */
static union virgl_picture_desc desc;
static uint8_t bits[1 << 20];
static uint8_t blank[W * H];

static int h264_offered(void)
{
   uint32_t max_ver = 0, max_size = 0;
   int found = 0;
   virgl_renderer_get_cap_set(2, &max_ver, &max_size);
   union virgl_caps *caps = calloc(1, max_size > sizeof(*caps) ? max_size : sizeof(*caps));
   virgl_renderer_fill_caps(2, 2, caps);
   for (unsigned i = 0; i < caps->v2.num_video_caps && i < 32; i++)
      found |= caps->v2.video_caps[i].entrypoint == G_ENTRYPOINT_BITSTREAM &&
               caps->v2.video_caps[i].profile == G_AVC_HIGH;
   free(caps);
   return found;
}

static void create_codec(uint32_t handle)
{
   emit(VIRGL_CMD0(VIRGL_CCMD_CREATE_VIDEO_CODEC, 0, 8));
   emit(handle);
   emit(G_AVC_HIGH);
   emit(G_ENTRYPOINT_BITSTREAM);
   emit(1);                    /* chroma 4:2:0 */
   emit(41);
   emit(W);
   emit(H);
   emit(4);
}

static void destroy_codec(uint32_t handle)
{
   emit(VIRGL_CMD0(VIRGL_CCMD_DESTROY_VIDEO_CODEC, 0, 1));
   emit(handle);
}

static void create_buffer(void)
{
   emit(VIRGL_CMD0(VIRGL_CCMD_CREATE_VIDEO_BUFFER, 0, 6));
   emit(BUF);
   emit(VIRGL_FORMAT_Y8_U8V8_420_UNORM);
   emit(W);
   emit(H);
   emit(R_Y);
   emit(R_UV);
}

/* Clear the guest's luma plane, decode picture F with CODEC in context CTX_ID and
 * return the luma PSNR of what landed in the plane against picture F. */
static double decode_picture(uint32_t ctx_id, uint32_t codec, int f)
{
   emit_plane(R_Y, W, H, 1, blank);
   memcpy(bits, au[f], au_size[f]);
   memset(&desc, 0, sizeof(desc));
   desc.h264.base.profile = G_AVC_HIGH;
   desc.h264.base.entry_point = G_ENTRYPOINT_BITSTREAM;
   desc.h264.frame_num = (uint32_t)f;
   desc.h264.is_reference = 1;
   desc.h264.num_ref_frames = 4;
   desc.h264.slice_count = 1;
   emit(VIRGL_CMD0(VIRGL_CCMD_BEGIN_FRAME, 0, 2));
   emit(codec);
   emit(BUF);
   emit(VIRGL_CMD0(VIRGL_CCMD_DECODE_BITSTREAM, 0, 5));
   emit(codec);
   emit(BUF);
   emit(R_DESC);
   emit(R_BITS);
   emit((uint32_t)au_size[f]);
   emit(VIRGL_CMD0(VIRGL_CCMD_END_FRAME, 0, 2));
   emit(codec);
   emit(BUF);
   submit(ctx_id);

   static uint8_t got[W * H];
   struct virgl_box box = { 0, 0, 0, W, H, 1 };
   struct iovec out = { got, sizeof(got) };
   memset(got, 0, sizeof(got));
   if (virgl_renderer_transfer_read_iov(R_Y, ctx_id, 0, W, 0, &box, 0, &out, 1))
      return 0;
   double se = 0;
   for (int i = 0; i < W * H; i++) {
      double e = (double)got[i] - ys[f][i];
      se += e * e;
   }
   double mse = se / (W * H);
   return mse > 0 ? 10 * log10(255.0 * 255.0 / mse) : 99;
}

/* Context CTX_ID gets the plane textures, the description and data buffers and the
 * NV12 video buffer. */
static void setup_context(uint32_t ctx_id)
{
   virgl_renderer_context_create(ctx_id, 4, "vdec");
   for (uint32_t r = R_Y; r <= R_BITS; r++)
      virgl_renderer_ctx_attach_resource((int)ctx_id, (int)r);
   create_buffer();
   submit(ctx_id);
}

/* All FRAMES pictures through one decoder: lowest luma PSNR. */
static double decode_all(uint32_t ctx_id, uint32_t codec)
{
   double min = 99;
   create_codec(codec);
   submit(ctx_id);
   for (int f = 0; f < FRAMES; f++) {
      double p = decode_picture(ctx_id, codec, f);
      if (p < min)
         min = p;
   }
   destroy_codec(codec);
   submit(ctx_id);
   return min;
}

int main(void)
{
   char line[200];

   setvbuf(stdout, NULL, _IONBF, 0);
   main_ctx = soft_gl_context(NULL);
   if (!main_ctx || CGLSetCurrentContext(main_ctx)) {
      printf("skip: no OpenGL context on this Mac\n");
      return 0;
   }
   soft_gl_require();
   static int cookie;
   if (virgl_renderer_init(&cookie, VIRGL_RENDERER_USE_VIDEO, &callbacks)) {
      printf("FAIL: virgl_renderer_init\n");
      return 1;
   }
   if (!h264_offered()) {
      printf("skip: no H.264 decoder offered\n");
      return 0;
   }
   if (!make_stream()) {
      printf("skip: no H.264 encoder to make the test stream (%d pictures)\n", au_count);
      return 0;
   }
   memset(blank, 0, sizeof(blank));

   make_res(R_Y, TEST_PIPE_TEXTURE_2D, VIRGL_FORMAT_R8_UNORM,
            VIRGL_BIND_SAMPLER_VIEW | VIRGL_BIND_RENDER_TARGET, W, H, NULL, 0);
   make_res(R_UV, TEST_PIPE_TEXTURE_2D, VIRGL_FORMAT_R8G8_UNORM,
            VIRGL_BIND_SAMPLER_VIEW | VIRGL_BIND_RENDER_TARGET, W / 2, H / 2, NULL, 0);
   make_res(R_DESC, TEST_PIPE_BUFFER, VIRGL_FORMAT_R8_UNORM, VIRGL_BIND_CUSTOM,
            sizeof(desc), 1, &desc, sizeof(desc));
   make_res(R_BITS, TEST_PIPE_BUFFER, VIRGL_FORMAT_R8_UNORM, VIRGL_BIND_CUSTOM,
            sizeof(bits), 1, bits, sizeof(bits));

   c = calloc(1, sizeof(*c));
   setup_context(1);

   double p = decode_all(1, 10);
   snprintf(line, sizeof(line), "%d pictures land in the guest's planes, lowest luma PSNR "
            "%.1f dB", FRAMES, p);
   check(p > 30, line);

   /* At most 8 decoders at once (each holds a media engine session and its
    * pictures): the 9th decodes nothing; closing one makes room again. */
   int ok8 = 0;
   for (uint32_t h = 30; h < 30 + MAX_LIVE; h++) {
      create_codec(h);
      submit(1);
      ok8 += decode_picture(1, h, 0) > 30;
   }
   create_codec(30 + MAX_LIVE);
   submit(1);
   double ninth = decode_picture(1, 30 + MAX_LIVE, 0);
   destroy_codec(30);
   create_codec(40);
   submit(1);
   double after = decode_picture(1, 40, 0);
   /* the open ones keep decoding */
   int still = decode_picture(1, 31, 1) > 30;
   snprintf(line, sizeof(line), "%d decoders open: %d of %d decode, a 9th %s (PSNR %.1f), "
            "after closing one a new one %s (PSNR %.1f), an open one still decodes: %s",
            MAX_LIVE, ok8, MAX_LIVE, ninth > 30 ? "decodes" : "decodes nothing", ninth,
            after > 30 ? "decodes" : "decodes nothing", after, still ? "yes" : "no");
   check(ok8 == MAX_LIVE && ninth < 20 && after > 30 && still, line);
   for (uint32_t h = 31; h <= 40; h++)
      destroy_codec(h);
   submit(1);

   /* A guest context that goes away with its decoders still open (a killed
    * player) frees them: 8 open in context 2, context 2 destroyed, then 8 open
    * again in context 1. */
   setup_context(2);
   for (uint32_t h = 50; h < 50 + MAX_LIVE; h++)
      create_codec(h);
   submit(2);
   int in2 = decode_picture(2, 50 + MAX_LIVE - 1, 0) > 30;
   virgl_renderer_context_destroy(2);
   int again = 0;
   for (uint32_t h = 60; h < 60 + MAX_LIVE; h++) {
      create_codec(h);
      submit(1);
      again += decode_picture(1, h, 0) > 30;
   }
   for (uint32_t h = 60; h < 60 + MAX_LIVE; h++)
      destroy_codec(h);
   submit(1);
   snprintf(line, sizeof(line), "a context closed with %d decoders open (they decoded: %s) "
            "frees them: %d of %d new ones decode", MAX_LIVE, in2 ? "yes" : "no", again,
            MAX_LIVE);
   check(in2 && again == MAX_LIVE, line);

   virgl_renderer_context_destroy(1);
   for (uint32_t r = R_Y; r <= R_BITS; r++)
      virgl_renderer_resource_unref(r);
   for (int f = 0; f < FRAMES; f++)
      free(au[f]);
   free(c);
   virgl_renderer_cleanup(&cookie);
   printf("%s\n", failures ? "video decode: FAILED" : "video decode: all checks passed");
   return failures != 0;
}
