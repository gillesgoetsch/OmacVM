/* H.264 decoding through the VideoToolbox backend, the way the guest's VA-API driver
 * drives it: a video codec with the BITSTREAM entrypoint, an NV12 video buffer whose
 * planes are guest textures, then per picture BEGIN_FRAME, DECODE_BITSTREAM (picture
 * description, compressed data) and END_FRAME. The stream is made here with
 * VTCompressionSession (parameter sets in-band, as FFmpeg and Chrome send them).
 * Before each picture the guest's luma texture is cleared, so a picture that never
 * arrives shows as a failure.
 * Checks: the pictures land in the guest's textures close to what went in (luma PSNR);
 * they still do while the guest's conditional rendering says skip and while its
 * rasterizer discard is on, and the guest's rasterizer discard is back on afterwards
 * (Apple's software OpenGL may copy either way: then these guard the path only);
 * the video caps tell the guest's VA-API shim 32 decoders per VM (omacvm_max_open)
 * and the host keeps a hard limit above that: 48 decoders open at once per VM
 * decode, one more decodes nothing, closing one makes room, and a guest context
 * that goes away frees the decoders it had. HEVC as the Mac's own encoder writes it
 * (what hevc_vaapi in the VM records) decodes bit for bit as VideoToolbox decodes the
 * same stream itself, also when the slices predict their reference sets from the SPS's.
 * Runs on Apple's software OpenGL (soft-gl.h); the decoder is the Mac's media engine.
 * Skips when the Mac has no H.264 encoder or decoder (HEVC: no hardware HEVC encoder). */
#include <CoreMedia/CoreMedia.h>
#include <OpenGL/OpenGL.h>
#include <VideoToolbox/VideoToolbox.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/uio.h>
#include <time.h>
#include <unistd.h>
#include "soft-gl.h"
#define VIRGL_RENDERER_UNSTABLE_APIS 1
#include "virglrenderer.h"
#include "virgl_hw.h"
#include "virgl_protocol.h"
#include "virgl_video_hw.h"
#include "hevc-parse.h"

/* GL without the GL headers (they clash with virgl's) */
unsigned char glIsEnabled(unsigned int cap);
#define TEST_GL_RASTERIZER_DISCARD 0x8C89

/* CAPS_LIMIT: what the video caps tell the guest; MAX_LIVE: where the host refuses
 * (room for Mesa's late closes and apps without the shim) */
enum { W = 320, H = 240, FRAMES = 10, CAPS_LIMIT = 32, MAX_LIVE = 48 };
/* HEVC: HFRAMES pictures, a new IDR at HKEY; reference pictures are video buffers
 * REFBUF... (NREFBUF of them, more than a DPB holds) */
enum { HFRAMES = 12, HKEY = 8, REFBUF = 60, NREFBUF = 17 };
enum { TEST_PIPE_BUFFER = 0, TEST_PIPE_TEXTURE_2D = 2 };
/* guest numbering (Mesa >= 26): enum pipe_video_profile / entrypoint */
enum { G_AVC_HIGH = 11, G_HEVC_MAIN = 15, G_ENTRYPOINT_BITSTREAM = 1 };
enum { R_Y = 1, R_UV, R_DESC, R_BITS, R_QUERY };
enum { BUF = 2, QUERY = 40, RAST = 41 };   /* codecs get 10, 11, ... */

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

/* --- the streams: Annex B access units from VideoToolbox's encoder, parameter sets
 * before every key frame (as FFmpeg and Chrome send them) ------------------------- */
static uint8_t ys[HFRAMES][W * H];

struct stream {
   int hevc;
   int low_latency;              /* the encode backend's constant-QP session */
   int count;
   uint8_t *au[HFRAMES];
   size_t au_size[HFRAMES];
   CMFormatDescriptionRef fmt;   /* the encoder's parameter sets (reference decode) */
};
static struct stream avc, hevc_streams[2] = { { .hevc = 1 }, { .hevc = 1, .low_latency = 1 } };
static struct stream *hevc = &hevc_streams[0];

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
   struct stream *s = ref;
   (void)frame_ref;
   (void)flags;
   if (st != noErr || !sample || s->count >= HFRAMES)
      return;
   uint8_t *out = NULL;
   size_t n = 0;
   CFArrayRef att = CMSampleBufferGetSampleAttachmentsArray(sample, false);
   int key = !(att && CFArrayGetCount(att) &&
               CFDictionaryContainsKey(CFArrayGetValueAtIndex(att, 0),
                                       kCMSampleAttachmentKey_NotSync));
   if (key) {
      CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sample);
      for (size_t i = 0; i < (s->hevc ? 3u : 2u); i++) {
         const uint8_t *ps = NULL;
         size_t len = 0;
         OSStatus e = s->hevc ?
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, i, &ps, &len, NULL, NULL) :
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, i, &ps, &len, NULL, NULL);
         if (e == noErr)
            put_nal(&out, &n, ps, len);
      }
      if (!s->fmt && fmt) {
         s->fmt = fmt;
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
   s->au[s->count] = out;
   s->au_size[s->count++] = n;
}

/* FRAMES pictures; picture KEY_AT (> 0) is forced to be a key frame. HEVC is made
 * on the media engine, as the encode backend does (hevc_vaapi in the VM): a bitrate
 * session, or with LOW_LATENCY the constant-QP one (low-latency rate control, the QP
 * with every frame), whose stream differs (temporal sub-layers in the SPS). */
static int make_stream(struct stream *s, int frames, int key_at)
{
   VTCompressionSessionRef vt = NULL;
   CFMutableDictionaryRef spec = NULL;
   if (s->hevc) {
      spec = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                       &kCFTypeDictionaryValueCallBacks);
      CFDictionarySetValue(spec,
         kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder, kCFBooleanTrue);
      if (s->low_latency)
         CFDictionarySetValue(spec, kVTVideoEncoderSpecification_EnableLowLatencyRateControl,
                              kCFBooleanTrue);
   }
   OSStatus st = VTCompressionSessionCreate(NULL, W, H, s->hevc ? kCMVideoCodecType_HEVC :
                                            kCMVideoCodecType_H264, spec, NULL, NULL,
                                            enc_cb, s, &vt);
   if (spec)
      CFRelease(spec);
   if (st != noErr)
      return 0;
   VTSessionSetProperty(vt, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
   VTSessionSetProperty(vt, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
   VTSessionSetProperty(vt, kVTCompressionPropertyKey_ProfileLevel, s->hevc ?
                        kVTProfileLevel_HEVC_Main_AutoLevel :
                        kVTProfileLevel_H264_High_AutoLevel);
   int32_t qp = 25;
   CFNumberRef qp_num = CFNumberCreate(NULL, kCFNumberSInt32Type, &qp);
   CFMutableDictionaryRef opts = CFDictionaryCreateMutable(NULL, 0,
      &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
   CFMutableDictionaryRef force = CFDictionaryCreateMutable(NULL, 0,
      &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
   CFDictionarySetValue(force, kVTEncodeFrameOptionKey_ForceKeyFrame, kCFBooleanTrue);
   if (s->low_latency) {
      CFDictionarySetValue(opts, kVTEncodeFrameOptionKey_BaseFrameQP, qp_num);
      CFDictionarySetValue(force, kVTEncodeFrameOptionKey_BaseFrameQP, qp_num);
   }
   CFRelease(qp_num);
   static uint8_t uv[W * H / 2];
   for (int f = 0; f < frames; f++) {
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
      VTCompressionSessionEncodeFrame(vt, pix, CMTimeMake(f, 30), kCMTimeInvalid,
                                      key_at > 0 && f == key_at ? force : opts, NULL, NULL);
      CVPixelBufferRelease(pix);
   }
   VTCompressionSessionCompleteFrames(vt, kCMTimeInvalid);
   VTCompressionSessionInvalidate(vt);
   CFRelease(vt);
   CFRelease(force);
   CFRelease(opts);
   return s->count == frames;
}

/* --- HEVC as the Mac's own encoder writes it --------------------------------------- */
/* hevc_vaapi in the VM encodes on VideoToolbox. Its stream uses what a libx265 stream
 * does not: SPS reference picture sets picked by index, reference list modification
 * syntax (lists_modification_present_flag), weighted prediction tables, WPP entry
 * points and the default scaling lists; its constant-QP session also overrides the
 * deblocking filter per slice. The guest's VA-API driver (Mesa) gives the host what
 * FFmpeg parsed and leaves NumPocTotalCurr, NumDeltaPocsOfRefRpsIdx and
 * deblocking_filter_control_present_flag at 0; the descriptions here are filled the
 * same way, from a parse of the stream. A second
 * variant writes each P slice's reference set as a set predicted from the SPS's
 * (inter RPS prediction in the slice header, which other encoders use), with its size
 * in bits (st_rps_bits) as FFmpeg passes it. */

/* Per picture: its slices as the guest sends them (Annex B, slices only), the
 * description Mesa makes from FFmpeg's values, and the inter-predicted variant. */
struct hpic {
   uint8_t *bits, *bits_inter;
   size_t size, size_inter;
   unsigned st_bits_inter;
   int list_mod;
   struct virgl_h265_picture_desc d;
};
static struct hpic hpics[HFRAMES];

static int hevc_prepare(void)
{
   int dpb_poc[17], dpb_f[17], dpb_n = 0, prev_poc = 0;

   for (int f = 0; f < hevc->count; f++) {
      struct hpic *pic = &hpics[f];
      const uint8_t *a = hevc->au[f];
      size_t n = hevc->au_size[f];
      struct hslice first = { 0 };
      int have = 0, inter_done = 0;

      for (size_t off = 0; off + 4 < n;) {       /* put_nal wrote 4-byte start codes */
         size_t end = off + 4;
         while (end + 4 <= n && memcmp(a + end, "\0\0\0\1", 4))
            end++;
         if (end + 4 > n)
            end = n;
         const uint8_t *nal = a + off + 4;
         size_t len = end - off - 4;
         unsigned type = (nal[0] >> 1) & 63;
         uint8_t *r = malloc(len);
         size_t rn = unescape(nal, len, r);
         struct br b = { r, rn, 16, 0 };
         struct hslice s;
         int bad = 0;

         if (type == 33)
            bad = sps_parse(&b);
         else if (type == 34)
            bad = pps_parse(&b);
         else if (type <= 31) {
            bad = slice_parse(r, rn, &s);
            if (!bad) {
               if (s.first) {
                  first = s;
                  have = 1;
               }
               pic->list_mod |= s.list_mod;
               put_nal(&pic->bits, &pic->size, nal, len);
               if (slice_inter_rps(r, rn, &s, &pic->bits_inter, &pic->size_inter,
                                   &pic->st_bits_inter))
                  inter_done = 1;
               else
                  put_nal(&pic->bits_inter, &pic->size_inter, nal, len);
            }
         }
         free(r);
         if (bad) {
            printf("picture %d: NAL unit type %u not parsed\n", f, type);
            return -1;
         }
         off = end;
      }
      if (!have)
         return -1;

      int irap = first.type >= 16 && first.type <= 23, poc = 0;
      if (irap && (first.type <= 20 || f == 0)) {        /* IDR, BLA, first CRA */
         dpb_n = 0;
         poc = first.idr ? 0 : (int)first.poc_lsb;
      } else {
         int max = 1 << lsb_bits, lsb = (int)first.poc_lsb;
         int prev_lsb = prev_poc & (max - 1), msb = prev_poc - prev_lsb;
         if (lsb < prev_lsb && prev_lsb - lsb >= max / 2)
            msb += max;
         else if (lsb > prev_lsb && lsb - prev_lsb > max / 2)
            msb -= max;
         poc = msb + lsb;
      }
      if (!(first.type <= 14 && !(first.type & 1)) && !(first.type >= 6 && first.type <= 9))
         prev_poc = poc;

      struct virgl_h265_picture_desc *d = &pic->d;
      int new_poc[17], new_f[17], k = 0;
      memset(d, 0, sizeof(*d));
      d->base.profile = G_HEVC_MAIN;
      d->base.entry_point = G_ENTRYPOINT_BITSTREAM;
      for (int m = 0; m < 6; m++) {
         memcpy(hp.sps.ScalingList4x4[m], sl[0][m], 16);
         memcpy(hp.sps.ScalingList8x8[m], sl[1][m], 64);
         memcpy(hp.sps.ScalingList16x16[m], sl[2][m], 64);
         hp.sps.ScalingListDCCoeff16x16[m] = sl_dc[2][m];
      }
      for (int m = 0; m < 2; m++) {
         memcpy(hp.sps.ScalingList32x32[m], sl[3][3 * m], 64);
         hp.sps.ScalingListDCCoeff32x32[m] = sl_dc[3][3 * m];
      }
      d->pps = hp;
      d->CurrPicOrderCntVal = poc;
      d->IDRPicFlag = (uint8_t)first.idr;
      d->RAPPicFlag = (uint8_t)irap;
      d->NumShortTermPictureSliceHeaderBits = first.st_rps_bits;
      if (!inter_done)
         pic->st_bits_inter = first.st_rps_bits;
      /* Mesa (va/picture_hevc.c) never sets these (VA-API has no such fields): the
       * host must not need them. VA passes tile sizes also for uniform spacing. */
      d->NumPocTotalCurr = 0;
      d->NumDeltaPocsOfRefRpsIdx = 0;
      d->pps.deblocking_filter_control_present_flag = 0;
      d->pps.uniform_spacing_flag = 0;
      memset(d->RefPicSetStCurrBefore, 0xff, sizeof(d->RefPicSetStCurrBefore));
      memset(d->RefPicSetStCurrAfter, 0xff, sizeof(d->RefPicSetStCurrAfter));
      memset(d->RefPicSetLtCurr, 0xff, sizeof(d->RefPicSetLtCurr));
      for (unsigned i = 0; i < first.rps.neg + first.rps.pos; i++) {
         int rp = poc + first.rps.delta[i], j = 0;
         while (j < dpb_n && dpb_poc[j] != rp)
            j++;
         if (j == dpb_n || k >= 15) {
            printf("picture %d: reference POC %d is not in the DPB\n", f, rp);
            return -1;
         }
         d->ref[k] = REFBUF + (uint32_t)(dpb_f[j] % NREFBUF);
         d->PicOrderCntVal[k] = rp;
         if (first.rps.used[i] && i < first.rps.neg && d->NumPocStCurrBefore < 8)
            d->RefPicSetStCurrBefore[d->NumPocStCurrBefore++] = (uint8_t)k;
         else if (first.rps.used[i] && i >= first.rps.neg && d->NumPocStCurrAfter < 8)
            d->RefPicSetStCurrAfter[d->NumPocStCurrAfter++] = (uint8_t)k;
         new_poc[k] = rp;
         new_f[k++] = dpb_f[j];
      }
      memcpy(dpb_poc, new_poc, sizeof(int) * (size_t)k);
      memcpy(dpb_f, new_f, sizeof(int) * (size_t)k);
      dpb_n = k;
      dpb_poc[dpb_n] = poc;
      dpb_f[dpb_n++] = f;
   }
   return 0;
}

/* The same stream decoded by VideoToolbox directly (its own parameter sets). */
static uint8_t ref_y[HFRAMES][W * H], ref_uv[HFRAMES][W * H / 2];
static int ref_got[HFRAMES];

static void dec_cb(void *refcon, void *frame, OSStatus st, VTDecodeInfoFlags flags,
                   CVImageBufferRef img, CMTime pts, CMTime dur)
{
   intptr_t f = (intptr_t)frame;
   (void)refcon;
   (void)flags;
   (void)pts;
   (void)dur;
   if (st != noErr || !img || f < 0 || f >= HFRAMES)
      return;
   CVPixelBufferLockBaseAddress(img, kCVPixelBufferLock_ReadOnly);
   if (CVPixelBufferGetPlaneCount(img) == 2 && CVPixelBufferGetWidth(img) >= W &&
       CVPixelBufferGetHeight(img) >= H) {
      for (int p = 0; p < 2; p++) {
         const uint8_t *src = CVPixelBufferGetBaseAddressOfPlane(img, p);
         size_t row = CVPixelBufferGetBytesPerRowOfPlane(img, p);
         for (int j = 0; j < (p ? H / 2 : H); j++)
            memcpy(p ? ref_uv[f] + j * W : ref_y[f] + j * W, src + j * row, W);
      }
      ref_got[f] = 1;
   }
   CVPixelBufferUnlockBaseAddress(img, kCVPixelBufferLock_ReadOnly);
}

static int hevc_reference_decode(void)
{
   VTDecompressionSessionRef vt = NULL;
   VTDecompressionOutputCallbackRecord cb = { dec_cb, NULL };
   int32_t nv12 = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, got = 0;
   CFMutableDictionaryRef attrs = CFDictionaryCreateMutable(NULL, 0,
      &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
   CFNumberRef num = CFNumberCreate(NULL, kCFNumberSInt32Type, &nv12);
   CFDictionarySetValue(attrs, kCVPixelBufferPixelFormatTypeKey, num);
   CFRelease(num);
   OSStatus st = hevc->fmt ? VTDecompressionSessionCreate(NULL, hevc->fmt, NULL, attrs, &cb, &vt)
                          : -1;
   CFRelease(attrs);
   if (st != noErr)
      return 0;
   for (int f = 0; f < hevc->count; f++) {
      const uint8_t *a = hevc->au[f];
      size_t n = hevc->au_size[f], len = 0;
      uint8_t *sample_data = malloc(n);
      for (size_t off = 0; off + 4 < n;) {       /* length prefixes, no parameter sets */
         size_t end = off + 4;
         while (end + 4 <= n && memcmp(a + end, "\0\0\0\1", 4))
            end++;
         if (end + 4 > n)
            end = n;
         size_t nl = end - off - 4;
         unsigned type = (a[off + 4] >> 1) & 63;
         if (type < 32 || type > 34) {
            sample_data[len] = (uint8_t)(nl >> 24);
            sample_data[len + 1] = (uint8_t)(nl >> 16);
            sample_data[len + 2] = (uint8_t)(nl >> 8);
            sample_data[len + 3] = (uint8_t)nl;
            memcpy(sample_data + len + 4, a + off + 4, nl);
            len += 4 + nl;
         }
         off = end;
      }
      CMBlockBufferRef block = NULL;
      CMSampleBufferRef sample = NULL;
      if (CMBlockBufferCreateWithMemoryBlock(NULL, NULL, len, NULL, NULL, 0, len, 0, &block) ==
             noErr &&
          CMBlockBufferReplaceDataBytes(sample_data, block, 0, len) == noErr &&
          CMSampleBufferCreateReady(NULL, block, hevc->fmt, 1, 0, NULL, 1, &len, &sample) ==
             noErr) {
         VTDecompressionSessionDecodeFrame(vt, sample, 0, (void *)(intptr_t)f, NULL);
         VTDecompressionSessionWaitForAsynchronousFrames(vt);
      }
      if (sample)
         CFRelease(sample);
      if (block)
         CFRelease(block);
      free(sample_data);
      got += ref_got[f];
   }
   VTDecompressionSessionInvalidate(vt);
   CFRelease(vt);
   return got == hevc->count;
}

/* --- the guest's side ---------------------------------------------------------- */
static union virgl_picture_desc desc;
static uint8_t bits[1 << 20];
static uint8_t query_result[64];
static uint8_t blank[W * H];

/* whether the caps offer a decoder for PROFILE; *limit_ok: every decoder says
 * CAPS_LIMIT as its limit */
static int offered(int profile, int *limit_ok)
{
   uint32_t max_ver = 0, max_size = 0;
   int found = 0;
   virgl_renderer_get_cap_set(2, &max_ver, &max_size);
   union virgl_caps *caps = calloc(1, max_size > sizeof(*caps) ? max_size : sizeof(*caps));
   virgl_renderer_fill_caps(2, 2, caps);
   *limit_ok = 1;
   for (unsigned i = 0; i < caps->v2.num_video_caps && i < 32; i++) {
      if (caps->v2.video_caps[i].entrypoint != G_ENTRYPOINT_BITSTREAM)
         continue;
      found |= caps->v2.video_caps[i].profile == profile;
      *limit_ok &= caps->v2.video_caps[i].omacvm_max_open == CAPS_LIMIT;
   }
   free(caps);
   return found;
}

static void create_codec_for(uint32_t handle, uint32_t profile, uint32_t level)
{
   emit(VIRGL_CMD0(VIRGL_CCMD_CREATE_VIDEO_CODEC, 0, 8));
   emit(handle);
   emit(profile);
   emit(G_ENTRYPOINT_BITSTREAM);
   emit(1);                    /* chroma 4:2:0 */
   emit(level);
   emit(W);
   emit(H);
   emit(4);
}

static void create_codec(uint32_t handle)
{
   create_codec_for(handle, G_AVC_HIGH, 41);
}

static void destroy_codec(uint32_t handle)
{
   emit(VIRGL_CMD0(VIRGL_CCMD_DESTROY_VIDEO_CODEC, 0, 1));
   emit(handle);
}

static void create_buffer_as(uint32_t handle)
{
   emit(VIRGL_CMD0(VIRGL_CCMD_CREATE_VIDEO_BUFFER, 0, 6));
   emit(handle);
   emit(VIRGL_FORMAT_Y8_U8V8_420_UNORM);
   emit(W);
   emit(H);
   emit(R_Y);
   emit(R_UV);
}

static void create_buffer(void)
{
   create_buffer_as(BUF);
}

/* Clear the guest's luma plane, decode picture F with CODEC in context CTX_ID and
 * return the luma PSNR of what landed in the plane against picture F. */
static double decode_picture(uint32_t ctx_id, uint32_t codec, int f)
{
   emit_plane(R_Y, W, H, 1, blank);
   memcpy(bits, avc.au[f], avc.au_size[f]);
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
   emit((uint32_t)avc.au_size[f]);
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

/* A decoder the guest closed counts against the limit until its session ended on
 * its own queue (virgl-videotoolbox-session-queue.patch), a few ms later: open
 * decoder H in context CTX_ID and decode picture F with it, again every 10 ms
 * while it is refused, 2 s at most. Returns the luma PSNR; *WAITED: ms. */
static double open_when_room(uint32_t ctx_id, uint32_t h, int f, int *waited)
{
   double p = 0;

   for (*waited = 0; *waited <= 2000; *waited += 10) {
      create_codec(h);
      submit(ctx_id);
      p = decode_picture(ctx_id, h, f);
      if (p > 30)
         return p;
      destroy_codec(h);
      submit(ctx_id);
      usleep(10000);
   }
   return p;
}

/* Context CTX_ID gets the plane textures, the description and data buffers and the
 * NV12 video buffer. */
static void setup_context(uint32_t ctx_id)
{
   virgl_renderer_context_create(ctx_id, 4, "vdec");
   for (uint32_t r = R_Y; r <= R_QUERY; r++)
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

/* Decode HEVC picture F (INTER: the inter-predicted variant) with CODEC in context 1.
 * Returns 1 when both planes are what VideoToolbox decoded on its own; *psnr: luma
 * PSNR against the picture that went in. */
static int hevc_decode_picture(uint32_t codec, int f, int inter, double *psnr)
{
   const struct hpic *pic = &hpics[f];
   size_t size = inter ? pic->size_inter : pic->size;
   static uint8_t got_y[W * H], got_uv[W * H / 2];

   emit_plane(R_Y, W, H, 1, blank);
   emit_plane(R_UV, W / 2, H / 2, 2, blank);
   memcpy(bits, inter ? pic->bits_inter : pic->bits, size);
   memset(&desc, 0, sizeof(desc));
   desc.h265 = pic->d;
   if (inter)
      desc.h265.NumShortTermPictureSliceHeaderBits = pic->st_bits_inter;
   emit(VIRGL_CMD0(VIRGL_CCMD_BEGIN_FRAME, 0, 2));
   emit(codec);
   emit(BUF);
   emit(VIRGL_CMD0(VIRGL_CCMD_DECODE_BITSTREAM, 0, 5));
   emit(codec);
   emit(BUF);
   emit(R_DESC);
   emit(R_BITS);
   emit((uint32_t)size);
   emit(VIRGL_CMD0(VIRGL_CCMD_END_FRAME, 0, 2));
   emit(codec);
   emit(BUF);
   submit(1);

   struct virgl_box box_y = { 0, 0, 0, W, H, 1 }, box_uv = { 0, 0, 0, W / 2, H / 2, 1 };
   struct iovec out_y = { got_y, sizeof(got_y) }, out_uv = { got_uv, sizeof(got_uv) };
   memset(got_y, 0, sizeof(got_y));
   memset(got_uv, 0, sizeof(got_uv));
   if (virgl_renderer_transfer_read_iov(R_Y, 1, 0, W, 0, &box_y, 0, &out_y, 1) ||
       virgl_renderer_transfer_read_iov(R_UV, 1, 0, W, 0, &box_uv, 0, &out_uv, 1))
      return 0;
   double se = 0;
   for (int i = 0; i < W * H; i++) {
      double e = (double)got_y[i] - ys[f][i];
      se += e * e;
   }
   *psnr = se > 0 ? 10 * log10(255.0 * 255.0 / (se / (W * H))) : 99;
   return !memcmp(got_y, ref_y[f], sizeof(got_y)) && !memcmp(got_uv, ref_uv[f], sizeof(got_uv));
}

/* Every picture of *hevc as VideoToolbox decodes the stream itself, also with the
 * slices' reference sets predicted from the SPS's. Codecs CODEC and CODEC + 1. */
static void hevc_check(uint32_t codec, const char *mode)
{
   char line[300];
   int list_mod = 0, exact = 0, exact_inter = 0, inter = 0;
   double low = 99, low_inter = 99, p1;

   for (int f = 0; f < HFRAMES; f++) {
      free(hpics[f].bits);
      free(hpics[f].bits_inter);
      ref_got[f] = 0;
   }
   memset(hpics, 0, sizeof(hpics));
   memset(&hp, 0, sizeof(hp));
   if (!make_stream(hevc, HFRAMES, HKEY)) {
      printf("skip: no hardware HEVC encoder (%s) for the test stream (%d pictures)\n", mode,
             hevc->count);
      return;
   }
   if (hevc_prepare()) {
      snprintf(line, sizeof(line), "HEVC test stream (%s) parsed", mode);
      check(0, line);
      return;
   }
   if (!hevc_reference_decode()) {
      printf("skip: VideoToolbox does not decode its own HEVC stream (%s) here\n", mode);
      return;
   }
   for (int f = 0; f < HFRAMES; f++) {
      list_mod += hpics[f].list_mod;
      inter += hpics[f].st_bits_inter > 0;
   }
   printf("HEVC stream (%s): lists_modification_present %d (in %d pictures), weighted_pred "
          "%d, WPP %d, scaling lists %d, %u SPS reference sets\n", mode,
          hp.lists_modification_present_flag, list_mod, hp.weighted_pred_flag,
          hp.entropy_coding_sync_enabled_flag, hp.sps.scaling_list_enabled_flag, num_sets);
   for (int pass = 0; pass < 2; pass++) {
      create_codec_for(codec + (uint32_t)pass, G_HEVC_MAIN, 120);
      submit(1);
      for (int f = 0; f < HFRAMES; f++) {
         int same = hevc_decode_picture(codec + (uint32_t)pass, f, pass, &p1);
         if (pass) {
            exact_inter += same;
            low_inter = p1 < low_inter ? p1 : low_inter;
         } else {
            exact += same;
            low = p1 < low ? p1 : low;
         }
      }
      destroy_codec(codec + (uint32_t)pass);
      submit(1);
   }
   snprintf(line, sizeof(line), "HEVC from VideoToolbox's encoder, %s (IDR at 0 and %d): %d "
            "of %d pictures bit for bit as VideoToolbox decodes it, lowest luma PSNR %.1f dB",
            mode, HKEY, exact, HFRAMES, low);
   check(exact == HFRAMES && low > 30, line);
   snprintf(line, sizeof(line), "same with slice reference sets predicted from the SPS's "
            "(%d pictures, st_rps_bits): %d of %d bit for bit, lowest luma PSNR %.1f dB",
            inter, exact_inter, HFRAMES, low_inter);
   check(inter > 0 && exact_inter == HFRAMES && low_inter > 30, line);
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
   int limit_ok;
   if (!offered(G_AVC_HIGH, &limit_ok)) {
      printf("skip: no H.264 decoder offered\n");
      return 0;
   }
   snprintf(line, sizeof(line), "every decoder in the video caps says the limit (%d) for "
            "the guest's VA-API shim: %s", CAPS_LIMIT, limit_ok ? "yes" : "no");
   check(limit_ok, line);
   if (!make_stream(&avc, FRAMES, 0)) {
      printf("skip: no H.264 encoder to make the test stream (%d pictures)\n", avc.count);
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
   make_res(R_QUERY, TEST_PIPE_BUFFER, VIRGL_FORMAT_R8_UNORM, VIRGL_BIND_CUSTOM,
            sizeof(query_result), 1, query_result, sizeof(query_result));

   c = calloc(1, sizeof(*c));
   setup_context(1);

   double p = decode_all(1, 10);
   snprintf(line, sizeof(line), "%d pictures land in the guest's planes, lowest luma PSNR "
            "%.1f dB", FRAMES, p);
   check(p > 30, line);

   /* The guest's conditional rendering is on and says "skip" (an occlusion query
    * with no samples): the copy into its planes is not rendering and must happen. */
   emit(VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_QUERY, VIRGL_OBJ_QUERY_SIZE));
   emit(QUERY);
   emit(VIRGL_OBJ_QUERY_TYPE(0));      /* PIPE_QUERY_OCCLUSION_COUNTER */
   emit(0);
   emit(R_QUERY);
   emit(VIRGL_CMD0(VIRGL_CCMD_BEGIN_QUERY, 0, 1));
   emit(QUERY);
   emit(VIRGL_CMD0(VIRGL_CCMD_END_QUERY, 0, 1));
   emit(QUERY);
   emit(VIRGL_CMD0(VIRGL_CCMD_SET_RENDER_CONDITION, 0, VIRGL_RENDER_CONDITION_SIZE));
   emit(QUERY);
   emit(0);                            /* condition: skip when no samples passed */
   emit(0);                            /* PIPE_RENDER_COND_WAIT */
   submit(1);
   p = decode_all(1, 11);
   emit(VIRGL_CMD0(VIRGL_CCMD_SET_RENDER_CONDITION, 0, VIRGL_RENDER_CONDITION_SIZE));
   emit(0);
   emit(0);
   emit(0);
   emit(VIRGL_CMD0(VIRGL_CCMD_DESTROY_OBJECT, VIRGL_OBJECT_QUERY, 1));
   emit(QUERY);
   submit(1);
   snprintf(line, sizeof(line), "guest's conditional rendering on: pictures land, lowest "
            "luma PSNR %.1f dB", p);
   check(p > 30, line);

   /* The guest's rasterizer discards everything: the copy still lands, and the
    * guest's setting is back afterwards. */
   emit(VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_RASTERIZER, VIRGL_OBJ_RS_SIZE));
   emit(RAST);
   emit(VIRGL_OBJ_RS_S0_RASTERIZER_DISCARD(1) | VIRGL_OBJ_RS_S0_DEPTH_CLIP(1));
   for (int i = 0; i < VIRGL_OBJ_RS_SIZE - 2; i++)
      emit(i == 0 || i == 3 ? 0x3f800000 : 0);   /* point size, line width 1.0 */
   emit(VIRGL_CMD0(VIRGL_CCMD_BIND_OBJECT, VIRGL_OBJECT_RASTERIZER, 1));
   emit(RAST);
   submit(1);
   p = decode_all(1, 12);
   int discard_kept = glIsEnabled(TEST_GL_RASTERIZER_DISCARD);
   emit(VIRGL_CMD0(VIRGL_CCMD_BIND_OBJECT, VIRGL_OBJECT_RASTERIZER, 1));
   emit(0);
   emit(VIRGL_CMD0(VIRGL_CCMD_DESTROY_OBJECT, VIRGL_OBJECT_RASTERIZER, 1));
   emit(RAST);
   submit(1);
   snprintf(line, sizeof(line), "guest's rasterizer discard on: pictures land, lowest luma "
            "PSNR %.1f dB; discard still on afterwards: %s", p, discard_kept ? "yes" : "no");
   check(p > 30 && discard_kept, line);

   /* At most MAX_LIVE decoders at once (each holds a media engine session and
    * its pictures), also past CAPS_LIMIT: one more decodes nothing; closing one
    * makes room again, once its session ended on its queue. */
   int ok_all = 0;
   for (uint32_t h = 100; h < 100 + MAX_LIVE; h++) {
      create_codec(h);
      submit(1);
      ok_all += decode_picture(1, h, 0) > 30;
   }
   create_codec(100 + MAX_LIVE);
   submit(1);
   double over = decode_picture(1, 100 + MAX_LIVE, 0);
   destroy_codec(100);
   submit(1);
   int waited = 0;
   double after = open_when_room(1, 200, 0, &waited);
   /* the open ones keep decoding */
   int still = decode_picture(1, 101, 1) > 30;
   snprintf(line, sizeof(line), "%d decoders open: %d of %d decode, one more %s (PSNR %.1f), "
            "after closing one a new one %s (PSNR %.1f, room after %d ms), an open one still "
            "decodes: %s", MAX_LIVE, ok_all, MAX_LIVE, over > 30 ? "decodes" : "decodes nothing",
            over, after > 30 ? "decodes" : "decodes nothing", after, waited, still ? "yes" : "no");
   check(ok_all == MAX_LIVE && over < 20 && after > 30 && waited <= 1000 && still, line);
   for (uint32_t h = 101; h <= 100 + MAX_LIVE; h++)
      destroy_codec(h);
   destroy_codec(200);
   submit(1);

   /* A guest context that goes away with its decoders still open (a killed
    * player) frees them: MAX_LIVE open in context 2, context 2 destroyed, then
    * MAX_LIVE open again in context 1. */
   setup_context(2);
   int in2 = 0;
   for (uint32_t h = 300; h < 300 + MAX_LIVE; h++)
      in2 += open_when_room(2, h, 0, &waited) > 30;
   virgl_renderer_context_destroy(2);
   int again = 0;
   for (uint32_t h = 400; h < 400 + MAX_LIVE; h++)
      again += open_when_room(1, h, 0, &waited) > 30;
   for (uint32_t h = 400; h < 400 + MAX_LIVE; h++)
      destroy_codec(h);
   submit(1);
   snprintf(line, sizeof(line), "a context closed with %d decoders open (they decoded: %d) "
            "frees them: %d of %d new ones decode", MAX_LIVE, in2, again, MAX_LIVE);
   check(in2 == MAX_LIVE && again == MAX_LIVE, line);

   /* HEVC as the Mac's own encoder writes it (hevc_vaapi in the VM), from its bitrate
    * and its constant-QP session, with an IDR in the middle. */
   int hevc_ok = 0;
   if (!offered(G_HEVC_MAIN, &hevc_ok)) {
      printf("skip: no HEVC decoder offered\n");
   } else {
      for (uint32_t h = REFBUF; h < REFBUF + NREFBUF; h++)
         create_buffer_as(h);
      submit(1);
      for (int i = 0; i < 2; i++) {
         hevc = &hevc_streams[i];
         hevc_check(20 + 2 * (uint32_t)i, i ? "constant QP" : "bitrate");
      }
   }

   virgl_renderer_context_destroy(1);
   for (uint32_t r = R_Y; r <= R_QUERY; r++)
      virgl_renderer_resource_unref(r);
   for (int f = 0; f < HFRAMES; f++) {
      free(avc.au[f]);
      free(hevc_streams[0].au[f]);
      free(hevc_streams[1].au[f]);
      free(hpics[f].bits);
      free(hpics[f].bits_inter);
   }
   for (int i = 0; i < 2; i++)
      if (hevc_streams[i].fmt)
         CFRelease(hevc_streams[i].fmt);
   free(c);
   virgl_renderer_cleanup(&cookie);
   printf("%s\n", failures ? "video decode: FAILED" : "video decode: all checks passed");
   return failures != 0;
}
