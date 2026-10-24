/* The rows and columns of the guest's plane textures past the decoded picture
 * (virgl-video-plane-edge.patch). Mesa makes a VA surface's planes with width and
 * height rounded up to 16 (vl_video_buffer_create: a 320x180 NV12 surface is an R8
 * 320x192 and an RG8 160x96 texture), and a guest that shows the surface samples all
 * of it, while VideoToolbox returns the picture's own size. Before the fix nothing
 * wrote the rest, so it kept the host texture's first content: zeroes, a green bar
 * at the bottom (1080p, 360p) or on the right (854 and 426 wide).
 *
 * The planes are made like Mesa's and filled with a marker, then pictures decode into
 * them the way the guest's VA-API driver sends them: VP9 profile 0 and 2 (10-bit, P010
 * planes) and AV1 (8-bit: the host offers AV1 for NV12 only) from small clips in
 * video-padding/ (FFmpeg, libvpx and SVT-AV1), and H.264 with SPS/PPS in band made here by VideoToolbox's encoder (the Mac
 * applies the SPS crop). Heights and widths that are not multiples of 16 (180 has
 * 1080's and 360's remainder, 426 and 854 are YouTube's 240p and 480p), an odd size,
 * one without padding, and planes more than 64 bigger than the picture (a surface the
 * guest crops itself: the fill leaves them). After the last picture every texel of both
 * planes is read back: the picture itself must be bit for bit what FFmpeg's software
 * decoder makes of the clip (H.264: what VideoToolbox decodes from the stream on its
 * own), and every texel past it must repeat the picture's last row and column.
 * With OMACVM_VIDEO_EDGE_FILL=0 it expects the marker there instead (the guest's view
 * before the fix), so the test shows it can see the bar. Both copy paths: run it again
 * with OMACVM_VIDEO_COPY=1. Runs on Apple's software OpenGL (soft-gl.h); the decoder is
 * the Mac's media engine, fed these clips only. Skips a codec the Mac does not decode. */
#include <CoreMedia/CoreMedia.h>
#include <OpenGL/OpenGL.h>
#include <VideoToolbox/VideoToolbox.h>
#include <libgen.h>
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

enum { TEST_PIPE_BUFFER = 0, TEST_PIPE_TEXTURE_2D = 2 };
/* guest numbering (Mesa >= 26): enum pipe_video_profile / entrypoint */
enum { G_AVC_HIGH = 11, G_VP9_P0 = 24, G_VP9_P2 = 25, G_AV1_MAIN = 26, G_BITSTREAM = 1 };
enum { R_DESC = 1, R_BITS = 2 };
enum { FRAMES = 3, MAXW = 864, MAXH = 496 };
/* below anything the test pictures decode to; in 16 bits not a P010 value (low 6 bits) */
#define MARK 0x01

static CGLContextObj main_ctx;
static int failures;

static void check(int ok, const char *what)
{
   printf("%s: %s\n", ok ? "ok" : "FAIL", what);
   failures += !ok;
}

static void write_fence(void *cookie, uint32_t fence) { (void)cookie; (void)fence; }

static virgl_renderer_gl_context create_gl_context(void *cookie, int scanout,
                                                   struct virgl_renderer_gl_ctx_param *param)
{
   (void)cookie;
   (void)scanout;
   (void)param;
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
   .version = 1, .write_fence = write_fence, .create_gl_context = create_gl_context,
   .destroy_gl_context = destroy_gl_context, .make_current = make_current,
};

static uint32_t cmd[1024];
static unsigned ncmd;
static void emit(uint32_t v) { cmd[ncmd++] = v; }
static void submit(void)
{
   virgl_renderer_submit_cmd(cmd, 1, (int)ncmd);
   ncmd = 0;
}

static union virgl_picture_desc desc;
static uint8_t bits[1 << 20];
static struct iovec iov_desc = { &desc, sizeof(desc) }, iov_bits = { bits, sizeof(bits) };

static uint64_t fnv(uint64_t x, const uint8_t *d, size_t n)
{
   for (size_t i = 0; i < n; i++)
      x = (x ^ d[i]) * 1099511628211ull;
   return x;
}

/* --- pictures to decode: one per access unit or frame --------------------------- */
struct unit { const uint8_t *d; size_t n; size_t tile; };   /* tile: AV1 tile data offset */
struct source {
   const char *name;
   uint32_t profile;
   int w, h, ten_bit;
   int dw, dh;                 /* what the host decodes (VideoToolbox's picture) */
   uint64_t hash;              /* of the reference picture; 0: compare with ref[] */
   int extra;                  /* planes this much bigger than Mesa's: past the fill's limit */
   struct unit u[FRAMES * 2];
   int count;
   uint8_t *store[FRAMES];
};

/* H.264 from VideoToolbox's encoder, Annex B, SPS/PPS before key frames (as FFmpeg
 * sends them to VA-API with the parameters in band) */
static void put_nal(uint8_t **out, size_t *n, const uint8_t *nal, size_t len)
{
   *out = realloc(*out, *n + 4 + len);
   memcpy(*out + *n, "\0\0\0\1", 4);
   memcpy(*out + *n + 4, nal, len);
   *n += 4 + len;
}

static CMFormatDescriptionRef enc_fmt;

static void enc_cb(void *ref, void *frame_ref, OSStatus st, VTEncodeInfoFlags flags,
                   CMSampleBufferRef sample)
{
   struct source *s = ref;
   (void)frame_ref;
   (void)flags;
   if (st != noErr || !sample || s->count >= FRAMES)
      return;
   uint8_t *out = NULL;
   size_t n = 0;
   CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sample);
   CFArrayRef att = CMSampleBufferGetSampleAttachmentsArray(sample, false);
   int key = !(att && CFArrayGetCount(att) &&
               CFDictionaryContainsKey(CFArrayGetValueAtIndex(att, 0),
                                       kCMSampleAttachmentKey_NotSync));
   if (key && fmt) {
      for (size_t i = 0; i < 2; i++) {
         const uint8_t *ps = NULL;
         size_t len = 0;
         if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, i, &ps, &len, NULL,
                                                                NULL) == noErr)
            put_nal(&out, &n, ps, len);
      }
      if (!enc_fmt) {
         enc_fmt = fmt;
         CFRetain(fmt);
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
   s->store[s->count] = out;
   s->u[s->count++] = (struct unit){ out, n, 0 };
}

static int h264_stream(struct source *s)
{
   VTCompressionSessionRef vt = NULL;
   if (VTCompressionSessionCreate(NULL, s->w, s->h, kCMVideoCodecType_H264, NULL, NULL, NULL,
                                  enc_cb, s, &vt) != noErr)
      return 0;
   VTSessionSetProperty(vt, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
   VTSessionSetProperty(vt, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
   VTSessionSetProperty(vt, kVTCompressionPropertyKey_ProfileLevel,
                        kVTProfileLevel_H264_High_AutoLevel);
   for (int f = 0; f < FRAMES; f++) {
      CVPixelBufferRef pix = NULL;
      if (CVPixelBufferCreate(NULL, s->w, s->h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                              NULL, &pix) != kCVReturnSuccess)
         break;
      CVPixelBufferLockBaseAddress(pix, 0);
      for (int p = 0; p < 2; p++) {
         uint8_t *dst = CVPixelBufferGetBaseAddressOfPlane(pix, p);
         size_t row = CVPixelBufferGetBytesPerRowOfPlane(pix, p);
         int pw = (int)CVPixelBufferGetWidthOfPlane(pix, p) * (p ? 2 : 1);
         for (int j = 0; j < (int)CVPixelBufferGetHeightOfPlane(pix, p); j++)
            for (int i = 0; i < pw; i++) {
               /* a moving gradient with a bright square; chroma 100-150 */
               int v = p ? (i & 1 ? 150 - i / 8 : 100 + j / 2) :
                       16 + (i + 3 * f) * 200 / (s->w + 10) + j % 7;
               if (!p && i >= 20 + 4 * f && i < 60 + 4 * f && j >= 20 && j < 60)
                  v = 230;
               dst[j * row + (size_t)i] = (uint8_t)v;
            }
      }
      CVPixelBufferUnlockBaseAddress(pix, 0);
      VTCompressionSessionEncodeFrame(vt, pix, CMTimeMake(f, 30), kCMTimeInvalid, NULL, NULL,
                                      NULL);
      CVPixelBufferRelease(pix);
   }
   VTCompressionSessionCompleteFrames(vt, kCMTimeInvalid);
   VTCompressionSessionInvalidate(vt);
   CFRelease(vt);
   return s->count == FRAMES && enc_fmt;
}

/* The same stream decoded by VideoToolbox on its own: the last picture, NV12. */
static uint8_t ref[2][MAXW * MAXH * 2];
static size_t ref_row[2];
static int ref_w[2], ref_h[2], ref_got;

static void dec_cb(void *refcon, void *frame, OSStatus st, VTDecodeInfoFlags flags,
                   CVImageBufferRef img, CMTime pts, CMTime dur)
{
   (void)refcon;
   (void)flags;
   (void)pts;
   (void)dur;
   if (st != noErr || !img || (intptr_t)frame != FRAMES - 1 ||
       CVPixelBufferGetPlaneCount(img) != 2)
      return;
   CVPixelBufferLockBaseAddress(img, kCVPixelBufferLock_ReadOnly);
   ref_got = 1;
   for (int p = 0; p < 2; p++) {
      ref_row[p] = CVPixelBufferGetBytesPerRowOfPlane(img, p);
      ref_w[p] = (int)CVPixelBufferGetWidthOfPlane(img, p);
      ref_h[p] = (int)CVPixelBufferGetHeightOfPlane(img, p);
      if (ref_row[p] * (size_t)ref_h[p] <= sizeof(ref[p]))
         memcpy(ref[p], CVPixelBufferGetBaseAddressOfPlane(img, p), ref_row[p] * (size_t)ref_h[p]);
      else
         ref_got = 0;
   }
   CVPixelBufferUnlockBaseAddress(img, kCVPixelBufferLock_ReadOnly);
}

static int h264_reference(const struct source *s)
{
   VTDecompressionSessionRef vt = NULL;
   VTDecompressionOutputCallbackRecord cb = { dec_cb, NULL };
   int32_t pf = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
   CFMutableDictionaryRef attrs = CFDictionaryCreateMutable(NULL, 0,
      &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
   CFNumberRef num = CFNumberCreate(NULL, kCFNumberSInt32Type, &pf);
   CFDictionarySetValue(attrs, kCVPixelBufferPixelFormatTypeKey, num);
   CFRelease(num);
   OSStatus st = VTDecompressionSessionCreate(NULL, enc_fmt, NULL, attrs, &cb, &vt);
   CFRelease(attrs);
   if (st != noErr)
      return 0;
   ref_got = 0;
   for (int f = 0; f < s->count; f++) {
      const uint8_t *a = s->u[f].d;
      size_t n = s->u[f].n, len = 0;
      uint8_t *data = malloc(n);
      for (size_t off = 0; off + 4 < n;) {       /* length prefixes, no parameter sets */
         size_t end = off + 4;
         while (end + 4 <= n && memcmp(a + end, "\0\0\0\1", 4))
            end++;
         if (end + 4 > n)
            end = n;
         size_t nl = end - off - 4;
         unsigned type = a[off + 4] & 31u;
         if (type != 7 && type != 8) {
            data[len] = (uint8_t)(nl >> 24);
            data[len + 1] = (uint8_t)(nl >> 16);
            data[len + 2] = (uint8_t)(nl >> 8);
            data[len + 3] = (uint8_t)nl;
            memcpy(data + len + 4, a + off + 4, nl);
            len += 4 + nl;
         }
         off = end;
      }
      CMBlockBufferRef block = NULL;
      CMSampleBufferRef sample = NULL;
      if (CMBlockBufferCreateWithMemoryBlock(NULL, NULL, len, NULL, NULL, 0, len, 0, &block) ==
             noErr &&
          CMBlockBufferReplaceDataBytes(data, block, 0, len) == noErr &&
          CMSampleBufferCreateReady(NULL, block, enc_fmt, 1, 0, NULL, 1, &len, &sample) ==
             noErr) {
         VTDecompressionSessionDecodeFrame(vt, sample, 0, (void *)(intptr_t)f, NULL);
         VTDecompressionSessionWaitForAsynchronousFrames(vt);
      }
      if (sample)
         CFRelease(sample);
      if (block)
         CFRelease(block);
      free(data);
   }
   VTDecompressionSessionInvalidate(vt);
   CFRelease(vt);
   return ref_got;
}

/* IVF clips: 32-byte header, 12-byte frame headers. VP9: superframes split as Chrome and
 * FFmpeg do before VA-API; AV1: one frame per temporal unit, its tile data offset. */
static uint8_t *clip_data;

static int ivf_units(struct source *s, const char *dir)
{
   char path[1200];
   snprintf(path, sizeof(path), "%s/%s", dir, s->name);
   FILE *f = fopen(path, "rb");
   if (!f)
      return 0;
   fseek(f, 0, SEEK_END);
   long n = ftell(f);
   fseek(f, 0, SEEK_SET);
   free(clip_data);
   clip_data = malloc((size_t)n);
   size_t got = fread(clip_data, 1, (size_t)n, f);
   fclose(f);
   if (got != (size_t)n || n < 32)
      return 0;
   for (size_t p = 32; p + 12 <= (size_t)n && s->count < FRAMES * 2;) {
      size_t len = clip_data[p] | clip_data[p + 1] << 8 | clip_data[p + 2] << 16 |
                   (size_t)clip_data[p + 3] << 24;
      p += 12;
      if (len < 2 || p + len > (size_t)n)
         break;
      const uint8_t *d = clip_data + p;
      uint8_t last = d[len - 1];
      int frames = (last & 7) + 1, mag = ((last >> 3) & 3) + 1;
      size_t idx = 2 + (size_t)mag * (size_t)frames;
      if (s->profile != G_AV1_MAIN && (last & 0xe0) == 0xc0 && len >= idx &&
          d[len - idx] == last) {
         size_t off = 0;
         for (int i = 0; i < frames && s->count < FRAMES * 2; i++) {
            size_t sz = 0;
            for (int j = 0; j < mag; j++)
               sz |= (size_t)d[len - idx + 1 + (size_t)(i * mag + j)] << (8 * j);
            s->u[s->count++] = (struct unit){ d + off, sz, 0 };
            off += sz;
         }
      } else if (s->profile == G_AV1_MAIN) {
         size_t q = 0, tile = 0;
         while (q < len && !tile) {                   /* OBUs: the frame (6) or tile group (4) */
            int type = (d[q] >> 3) & 15, ext = (d[q] >> 2) & 1;
            size_t r = q + 1 + (size_t)ext, size = 0;
            for (int sh = 0; r < len; sh += 7) {
               size |= (size_t)(d[r] & 0x7f) << sh;
               if (!(d[r++] & 0x80))
                  break;
            }
            if (type == 6 || type == 4)
               tile = r + size - 1;                    /* a byte of its tile data */
            q = r + size;
         }
         s->u[s->count++] = (struct unit){ d, len, tile };
      } else {
         s->u[s->count++] = (struct unit){ d, len, 0 };
      }
      p += len;
   }
   return s->count > 0;
}

/* --- the guest's side ---------------------------------------------------------- */
static int offered(uint32_t profile)
{
   uint32_t max_ver = 0, max_size = 0;
   int found = 0;
   virgl_renderer_get_cap_set(2, &max_ver, &max_size);
   union virgl_caps *caps = calloc(1, max_size > sizeof(*caps) ? max_size : sizeof(*caps));
   virgl_renderer_fill_caps(2, 2, caps);
   for (unsigned i = 0; i < caps->v2.num_video_caps && i < 32; i++)
      found |= caps->v2.video_caps[i].profile == profile &&
               caps->v2.video_caps[i].entrypoint == G_BITSTREAM;
   free(caps);
   return found;
}

static uint32_t next_res = 10, next_obj = 100;

static void make_plane(uint32_t handle, uint32_t format, uint32_t w, uint32_t h, uint32_t bpp)
{
   struct virgl_renderer_resource_create_args a = {
      .handle = handle, .target = TEST_PIPE_TEXTURE_2D, .format = format,
      .bind = VIRGL_BIND_SAMPLER_VIEW | VIRGL_BIND_RENDER_TARGET,
      .width = w, .height = h, .depth = 1, .array_size = 1,
   };
   virgl_renderer_resource_create(&a, NULL, 0);
   virgl_renderer_ctx_attach_resource(1, (int)handle);
   size_t n = (size_t)w * h * bpp;
   uint8_t *d = malloc(n);
   memset(d, MARK, n);
   struct virgl_box box = { 0, 0, 0, w, h, 1 };
   struct iovec io = { d, n };
   virgl_renderer_transfer_write_iov(handle, 1, 0, w * bpp, 0, &box, 0, &io, 1);
   free(d);
}

static uint8_t got[2][MAXW * MAXH * 4];

static void run_case(struct source *s, int expect_marker)
{
   char line[400];
   int h264 = s->profile == G_AVC_HIGH;
   /* Mesa's planes and video buffer: rounded up to 16; H.264's codec size too
    * (virgl_video_create_codec), VP9's and AV1's the frame's */
   uint32_t aw = (((uint32_t)s->w + 15) & ~15u) + (uint32_t)s->extra;
   uint32_t ah = (((uint32_t)s->h + 15) & ~15u) + (uint32_t)s->extra;
   uint32_t bpp = s->ten_bit ? 2 : 1, pw[2] = { aw, aw / 2 }, ph[2] = { ah, ah / 2 };
   uint32_t texel[2] = { bpp, 2 * bpp }, res[2], codec = next_obj++, buf = next_obj++;
   res[0] = next_res++;
   res[1] = next_res++;
   make_plane(res[0], s->ten_bit ? VIRGL_FORMAT_R16_UNORM : VIRGL_FORMAT_R8_UNORM, pw[0], ph[0],
              bpp);
   make_plane(res[1], s->ten_bit ? VIRGL_FORMAT_R16G16_UNORM : VIRGL_FORMAT_R8G8_UNORM, pw[1],
              ph[1], 2 * bpp);
   emit(VIRGL_CMD0(VIRGL_CCMD_CREATE_VIDEO_CODEC, 0, 8));
   emit(codec);
   emit(s->profile);
   emit(G_BITSTREAM);
   emit(1);                    /* chroma 4:2:0 */
   emit(s->profile == G_AV1_MAIN ? 8 : 41);
   emit(h264 ? aw : (uint32_t)s->w);
   emit(h264 ? ah : (uint32_t)s->h);
   emit(4);
   emit(VIRGL_CMD0(VIRGL_CCMD_CREATE_VIDEO_BUFFER, 0, 6));
   emit(buf);
   emit(s->ten_bit ? VIRGL_FORMAT_X6Y10_X6U10X6V10_420_UNORM : VIRGL_FORMAT_Y8_U8V8_420_UNORM);
   emit(aw);                   /* the vl buffer's size (virgl_encode.c) */
   emit(ah);
   emit(res[0]);
   emit(res[1]);
   submit();

   for (int f = 0; f < s->count; f++) {
      const struct unit *u = &s->u[f];
      if (u->n > sizeof(bits))
         continue;
      memset(&desc, 0, sizeof(desc));
      memcpy(bits, u->d, u->n);
      desc.base.profile = s->profile;
      desc.base.entry_point = G_BITSTREAM;
      if (h264) {
         desc.h264.frame_num = (uint32_t)f;
         desc.h264.is_reference = 1;
         desc.h264.num_ref_frames = 4;
         desc.h264.slice_count = 1;
      } else if (s->profile == G_AV1_MAIN) {
         desc.av1.picture_parameter.frame_width = (uint16_t)s->w;
         desc.av1.picture_parameter.frame_height = (uint16_t)s->h;
         desc.av1.picture_parameter.max_width = (uint16_t)(s->w - 1);
         desc.av1.picture_parameter.max_height = (uint16_t)(s->h - 1);
         desc.av1.slice_parameter.slice_count = 1;
         desc.av1.slice_parameter.slice_data_offset[0] = (uint32_t)u->tile;
         desc.av1.slice_parameter.slice_data_size[0] = 1;
      } else {
         desc.vp9.picture_parameter.frame_width = (uint16_t)s->w;
         desc.vp9.picture_parameter.frame_height = (uint16_t)s->h;
         desc.vp9.picture_parameter.profile = s->ten_bit ? 2 : 0;
         desc.vp9.picture_parameter.bit_depth = s->ten_bit ? 10 : 8;
         desc.vp9.slice_parameter.slice_data_size = (uint32_t)u->n;
      }
      emit(VIRGL_CMD0(VIRGL_CCMD_BEGIN_FRAME, 0, 2));
      emit(codec);
      emit(buf);
      emit(VIRGL_CMD0(VIRGL_CCMD_DECODE_BITSTREAM, 0, 5));
      emit(codec);
      emit(buf);
      emit(R_DESC);
      emit(R_BITS);
      emit((uint32_t)u->n);
      emit(VIRGL_CMD0(VIRGL_CCMD_END_FRAME, 0, 2));
      emit(codec);
      emit(buf);
      submit();
   }

   /* the picture (bit for bit), and past what the host decoded: its last row/column */
   uint64_t hash = 1469598103934665603ull;
   int exact = 1, edge = 1, past = 0, marker = 0;
   for (int p = 0; p < 2; p++) {
      uint32_t t = texel[p], ew = p ? ((uint32_t)s->dw + 1) / 2 : (uint32_t)s->dw;
      uint32_t eh = p ? ((uint32_t)s->dh + 1) / 2 : (uint32_t)s->dh;
      size_t row = (size_t)pw[p] * t;
      struct virgl_box box = { 0, 0, 0, pw[p], ph[p], 1 };
      struct iovec io = { got[p], row * ph[p] };
      ew = ew < pw[p] ? ew : pw[p];
      eh = eh < ph[p] ? eh : ph[p];
      memset(got[p], 0x5c, row * ph[p]);
      if (virgl_renderer_transfer_read_iov(res[p], 1, 0, (uint32_t)row, 0, &box, 0, &io, 1)) {
         exact = edge = 0;
         continue;
      }
      for (uint32_t y = 0; y < eh; y++) {
         hash = fnv(hash, got[p] + y * row, (size_t)ew * t);
         if (!s->hash && (y >= (uint32_t)ref_h[p] || ew > (uint32_t)ref_w[p] ||
                          memcmp(got[p] + y * row, ref[p] + y * ref_row[p], (size_t)ew * t)))
            exact = 0;
      }
      for (uint32_t y = 0; y < ph[p]; y++)
         for (uint32_t x = y < eh ? ew : 0; x < pw[p]; x++) {
            const uint8_t *v = got[p] + y * row + x * t;
            uint32_t sx = x < ew ? x : ew - 1, sy = y < eh ? y : eh - 1;
            past++;
            marker += v[0] == MARK && v[t - 1] == MARK;
            edge &= !memcmp(v, got[p] + sy * row + sx * t, t);
         }
   }
   if (s->hash)
      exact = hash == s->hash;
   snprintf(line, sizeof(line), "%s %dx%d%s into planes %ux%u + %ux%u, %d pictures: the "
            "picture bit for bit as %s: %s (%016llx); %d texels past it: %s", s->name, s->w,
            s->h, s->ten_bit ? " 10-bit" : "", pw[0], ph[0], pw[1], ph[1], s->count,
            s->hash ? "FFmpeg decodes it" : "VideoToolbox decodes it on its own",
            exact ? "yes" : "no", (unsigned long long)hash, past,
            s->extra ? (marker == past ? "never written (a surface, not padding)" :
                        "written although it is past the fill's limit") :
            expect_marker ? (marker == past ? "never written (as before the fix)" :
                             "written although the fill is off") :
            edge && !marker ? "its last row and column" :
            marker ? "never written (the bar)" : "something else");
   check(exact && (expect_marker ? marker == past : edge && !marker), line);

   emit(VIRGL_CMD0(VIRGL_CCMD_DESTROY_VIDEO_BUFFER, 0, 1));
   emit(buf);
   emit(VIRGL_CMD0(VIRGL_CCMD_DESTROY_VIDEO_CODEC, 0, 1));
   emit(codec);
   submit();
   for (int p = 0; p < 2; p++) {
      virgl_renderer_ctx_detach_resource(1, (int)res[p]);
      virgl_renderer_resource_unref(res[p]);
   }
}

int main(void)
{
   const char *fill = getenv("OMACVM_VIDEO_EDGE_FILL"), *copy = getenv("OMACVM_VIDEO_COPY");
   int expect_marker = fill && !strcmp(fill, "0"), ran = 0;
   char here[1024], dir[1100];

   setvbuf(stdout, NULL, _IONBF, 0);
   setenv("OMACVM_VIDEO_AV1", "1", 0);
   snprintf(here, sizeof(here), "%s", __FILE__);
   snprintf(dir, sizeof(dir), "%s/video-padding", dirname(here));
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
   printf("video padding: %s copy, edge fill %s\n", copy ? "CPU" : "GPU",
          expect_marker ? "off (expecting the bar)" : "on");
   virgl_renderer_context_create(1, 5, "vpad");
   struct virgl_renderer_resource_create_args a = {
      .handle = R_DESC, .target = TEST_PIPE_BUFFER, .format = VIRGL_FORMAT_R8_UNORM,
      .bind = VIRGL_BIND_CUSTOM, .width = sizeof(desc), .height = 1, .depth = 1,
      .array_size = 1,
   };
   virgl_renderer_resource_create(&a, NULL, 0);
   virgl_renderer_resource_attach_iov(R_DESC, &iov_desc, 1);
   a.handle = R_BITS;
   a.width = sizeof(bits);
   virgl_renderer_resource_create(&a, NULL, 0);
   virgl_renderer_resource_attach_iov(R_BITS, &iov_bits, 1);
   virgl_renderer_ctx_attach_resource(1, R_DESC);
   virgl_renderer_ctx_attach_resource(1, R_BITS);

   /* FFmpeg's software decode of each clip's last picture: FNV-1a of Y, then UV
    * interleaved (10-bit as P010); video-padding/README says how they were made */
   static struct source clips[] = {
#define CLIP(file, prof, cw, ch, ten, sum, more) \
      { .name = file, .profile = prof, .w = cw, .h = ch, .ten_bit = ten, .dw = cw, .dh = ch, \
        .hash = sum, .extra = more }
      CLIP("vp9p0-320x180.ivf", G_VP9_P0, 320, 180, 0, 0x43273c816ba2b012ull, 0),
      CLIP("vp9p0-426x240.ivf", G_VP9_P0, 426, 240, 0, 0xad2bf90b325d9f65ull, 0),
      CLIP("vp9p0-321x181.ivf", G_VP9_P0, 321, 181, 0, 0x3398897b7b9f396eull, 0),
      CLIP("vp9p2-330x182.ivf", G_VP9_P2, 330, 182, 1, 0x2174241ece435612ull, 0),
      CLIP("av1-320x180.ivf", G_AV1_MAIN, 320, 180, 0, 0xb72bd625932bd0a5ull, 0),
      /* a 480x352 surface for a 320x180 picture: more than padding, left alone */
      CLIP("vp9p0-320x180.ivf", G_VP9_P0, 320, 180, 0, 0x43273c816ba2b012ull, 160),
#undef CLIP
   };
   for (unsigned i = 0; i < sizeof(clips) / sizeof(clips[0]); i++) {
      struct source *s = &clips[i];
      if (!offered(s->profile)) {
         printf("skip: %s: no decoder offered for profile %u\n", s->name, s->profile);
         continue;
      }
      if (!ivf_units(s, dir)) {
         check(0, s->name);
         continue;
      }
      run_case(s, expect_marker || s->extra);
      ran++;
   }

   /* H.264 with SPS/PPS in band: rows (180), columns (854), both, and no padding */
   static const struct { int w, h; } sizes[] = { { 320, 180 }, { 854, 480 }, { 330, 182 },
                                                 { 320, 240 } };
   for (unsigned i = 0; i < sizeof(sizes) / sizeof(sizes[0]) && offered(G_AVC_HIGH); i++) {
      struct source s = { .name = "H.264 in band", .profile = G_AVC_HIGH, .w = sizes[i].w,
                          .h = sizes[i].h };
      if (!h264_stream(&s) || !h264_reference(&s)) {
         printf("skip: H.264 %dx%d: VideoToolbox does not encode or decode it here\n", s.w, s.h);
      } else {
         s.dw = ref_w[0];         /* the Mac applies the SPS crop */
         s.dh = ref_h[0];
         run_case(&s, expect_marker && (s.w % 16 || s.h % 16));
         ran++;
      }
      for (int f = 0; f < s.count; f++)
         free(s.store[f]);
      if (enc_fmt)
         CFRelease(enc_fmt);
      enc_fmt = NULL;
   }

   /* a Mac with a media engine must run cases: none means the host offers no decoder */
   if (!ran && VTIsHardwareDecodeSupported(kCMVideoCodecType_H264))
      check(0, "no case ran, although this Mac decodes H.264 in hardware");

   virgl_renderer_context_destroy(1);
   virgl_renderer_resource_unref(R_DESC);
   virgl_renderer_resource_unref(R_BITS);
   virgl_renderer_cleanup(&cookie);
   free(clip_data);
   printf("%s (%d cases)\n", failures ? "video padding: FAILED" : "video padding: all checks passed",
          ran);
   return failures != 0;
}
