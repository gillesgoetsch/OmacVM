// SPDX-License-Identifier: MIT
/*
 * omacvm-vdecd: does the decoding for the omacvm-vdec V4L2 device.
 *
 * Chromium (Arch Linux ARM's, built without VA-API) decodes video through
 * V4L2. The kernel module passes each bitstream buffer here; FFmpeg decodes it
 * with VA-API, which in an OmacVM.app VM runs on the Mac's media engine
 * (virglrenderer's VideoToolbox backend). The GPU then converts each picture
 * to ARGB into the app's CAPTURE buffer, a GBM buffer this daemon made, so a
 * virtio-gpu buffer the compositor can import. Why ARGB: with GL, Chromium on
 * Linux renders only ARGB frames from a decoder (NV12 needs a flag), and one
 * virtio-gpu buffer cannot hold both NV12 planes anyway. Why not VA-API's own
 * surfaces: in the guest they are one page long and Chromium checks plane
 * sizes against that.
 *
 * One thread, one EGL context; instances are served in turn. A video that
 * goes wrong (a picture size or stream VA-API cannot take, a GPU that does
 * not finish a picture within FENCE_TIMEOUT) fails alone: the module hands
 * its buffers back as errors and the app decodes on the CPU. A daemon that
 * hangs as a whole stops pinging systemd's watchdog (WatchdogSec) and is
 * restarted; the module then fails every open video. Messages and answers:
 * omacvm-vdec.h. Environment: OMACVM_VDEC_DEBUG=1 logs every frame,
 * OMACVM_VDEC_HEVC=1 offers HEVC too (not to Chromium: see va_codecs).
 * Exit 3: the module is from another build (it loads at the next VM start).
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>
#include <drm_fourcc.h>
#include <gbm.h>
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_vaapi.h>
#include <linux/videodev2.h>
#include <systemd/sd-daemon.h>
#include <va/va.h>
#include <va/va_drmcommon.h>

#include "omacvm-vdec.h"

#define RENDER_NODE "/dev/dri/renderD128"
#define MAX_PENDING_FRAMES 3	/* decoded, waiting for a CAPTURE buffer */
#define MAX_PENDING_INPUT 32	/* bounded anyway by the app's OUTPUT buffers */
#ifndef FENCE_TIMEOUT			/* a test build sets 1 to try the failure */
#define FENCE_TIMEOUT 1000000000ull	/* ns the GPU gets for one conversion */
#endif

static bool debug;
static int ctl = -1;
static struct gbm_device *gbm;
static EGLDisplay egl;
static AVBufferRef *hwdev;
static VADisplay va;
static PFNEGLCREATEIMAGEKHRPROC create_image;
static PFNEGLDESTROYIMAGEKHRPROC destroy_image;
static PFNGLEGLIMAGETARGETTEXTURE2DOESPROC image_target;
static PFNEGLCREATESYNCKHRPROC create_sync;
static PFNEGLCLIENTWAITSYNCKHRPROC wait_sync;
static PFNEGLDESTROYSYNCKHRPROC destroy_sync;

static double now_ms(void)
{
	struct timespec t;

	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

static void log_msg(const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc('\n', stderr);
}

/* A plane as a GL framebuffer: an EGLImage of a dmabuf, its texture, an FBO. */
struct plane {
	EGLImageKHR img;
	GLuint tex, fbo;
};

static bool plane_import(struct plane *p, int fd, uint32_t fourcc, int w, int h,
			 uint32_t offset, uint32_t pitch)
{
	EGLint a[] = {
		EGL_WIDTH, w, EGL_HEIGHT, h, EGL_LINUX_DRM_FOURCC_EXT, (EGLint)fourcc,
		EGL_DMA_BUF_PLANE0_FD_EXT, fd, EGL_DMA_BUF_PLANE0_OFFSET_EXT, (EGLint)offset,
		EGL_DMA_BUF_PLANE0_PITCH_EXT, (EGLint)pitch, EGL_NONE,
	};

	p->img = create_image(egl, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, NULL, a);
	if (!p->img)
		return false;
	glGenTextures(1, &p->tex);
	glBindTexture(GL_TEXTURE_2D, p->tex);
	image_target(GL_TEXTURE_2D, p->img);
	glGenFramebuffers(1, &p->fbo);
	glBindFramebuffer(GL_FRAMEBUFFER, p->fbo);
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, p->tex, 0);
	return glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
}

static void plane_free(struct plane *p)
{
	if (p->fbo)
		glDeleteFramebuffers(1, &p->fbo);
	if (p->tex)
		glDeleteTextures(1, &p->tex);
	if (p->img)
		destroy_image(egl, p->img);
	memset(p, 0, sizeof(*p));
}

struct capbuf {
	struct gbm_bo *bo;
	struct plane pl;
	bool free;		/* queued by the app, ours to write */
	uint64_t seq;
	EGLSyncKHR fence;	/* converted, the GPU not done yet */
	int64_t pts;
	bool ok;
};

struct srcimg {			/* a decoder surface, imported once */
	struct srcimg *next;
	VASurfaceID id;
	struct plane pl[2];
};

/* A bitstream buffer as read() left it: the message, then the data (and
 * FFmpeg's padding) in one pooled buffer that FFmpeg takes by reference. */
struct pkt {
	struct pkt *next;
	uint32_t index, size;
	uint64_t seq, ts;
	AVBufferRef *buf;
};

struct frame {
	struct frame *next;
	AVFrame *f;
};

struct inst {
	struct inst *next;
	uint32_t id, codec;
	AVCodecContext *cc;
	struct pkt *in, **in_tail;
	int nin;
	struct frame *out, **out_tail;
	int nout;

	bool fmt_set;
	int width, height, vis_width, vis_height;
	uint32_t stride;

	struct capbuf cap[OVD_MAX_CAPTURE];
	int ncap, cap_width, cap_height;
	int busy[OVD_MAX_CAPTURE], nbusy;	/* converted, in order */

	bool cap_on;			/* the app's CAPTURE buffers stream */
	bool draining, drain_flushed;
	bool no_va;			/* FFmpeg could not use VA-API for this stream */
	bool failed;			/* the module was told: only CLOSE now */
	double decode_ms;		/* the last packet's, for OMACVM_VDEC_DEBUG */
	struct srcimg *src;
	AVBufferRef *src_frames;	/* the frames context src belongs to */
	unsigned frames, errors;
};

static struct inst *insts;

static struct inst *inst_find(uint32_t id)
{
	for (struct inst *i = insts; i; i = i->next)
		if (i->id == id)
			return i;
	return NULL;
}

/* ---- answers to the kernel ------------------------------------------------- */

static void done(int ioc, struct inst *in, uint32_t index, uint64_t seq, uint64_t ts, uint32_t flags)
{
	struct ovd_done d = { .inst = in->id, .index = index, .seq = seq, .timestamp = ts, .flags = flags };

	if (ioctl(ctl, ioc, &d) && errno != ENOENT)
		log_msg("vdecd: done ioctl: %s", strerror(errno));
}

/* ---- decoder ------------------------------------------------------------------ */

/* VA-API or nothing: decoding on the CPU here would be slower than
 * Chromium's own. Without it (a profile the Mac lacks, or no decoder left)
 * the app gets a decode error and can fall back to its software decoder. */
static enum AVPixelFormat pick_vaapi(AVCodecContext *c, const enum AVPixelFormat *f)
{
	struct inst *in = c->opaque;

	for (; *f != AV_PIX_FMT_NONE; f++)
		if (*f == AV_PIX_FMT_VAAPI)
			return *f;
	in->no_va = true;	/* pump() fails the video */
	return AV_PIX_FMT_NONE;
}

static void src_flush(struct inst *in)
{
	struct srcimg *s;

	while ((s = in->src)) {
		in->src = s->next;
		plane_free(&s->pl[0]);
		plane_free(&s->pl[1]);
		free(s);
	}
	av_buffer_unref(&in->src_frames);
}

static void frames_drop(struct inst *in)
{
	struct frame *fr;

	while ((fr = in->out)) {
		in->out = fr->next;
		av_frame_free(&fr->f);
		free(fr);
	}
	in->out_tail = &in->out;
	in->nout = 0;
}

static void input_drop(struct inst *in)
{
	struct pkt *p;

	while ((p = in->in)) {
		in->in = p->next;
		av_buffer_unref(&p->buf);
		free(p);
	}
	in->in_tail = &in->in;
	in->nin = 0;
}

/* This video fails: the module hands the app its buffers back as errors
 * and refuses new ones, so the app decodes on the CPU. Others go on.
 * why NULL: the app closed it already, nothing to say. */
static void inst_fail(struct inst *in, const char *why)
{
	if (in->failed)
		return;
	if (why)
		log_msg("vdecd: inst %u: %s: this video decodes on the CPU", in->id, why);
	in->failed = true;
	if (ioctl(ctl, OVD_IOC_ERROR, &in->id) && errno != ENOENT)
		log_msg("vdecd: error ioctl: %s", strerror(errno));
	input_drop(in);
	frames_drop(in);
	in->draining = in->drain_flushed = false;
}

static void finish(struct inst *in, bool deliver);

static void decoder_close(struct inst *in)
{
	finish(in, true);	/* conversions still read the decoder's surfaces */
	frames_drop(in);
	src_flush(in);
	avcodec_free_context(&in->cc);
}

static bool decoder_open(struct inst *in, uint32_t codec)
{
	enum AVCodecID id = codec == V4L2_PIX_FMT_H264 ? AV_CODEC_ID_H264 :
			    codec == V4L2_PIX_FMT_HEVC ? AV_CODEC_ID_HEVC :
			    codec == V4L2_PIX_FMT_VP9 ? AV_CODEC_ID_VP9 : AV_CODEC_ID_NONE;
	const AVCodec *dec = avcodec_find_decoder(id);

	decoder_close(in);
	if (!dec)
		return false;
	in->cc = avcodec_alloc_context3(dec);
	if (!in->cc)
		return false;
	in->cc->hw_device_ctx = av_buffer_ref(hwdev);
	in->cc->get_format = pick_vaapi;
	in->cc->opaque = in;
	in->cc->extra_hw_frames = MAX_PENDING_FRAMES + 2;
	in->cc->thread_count = 1;
	in->cc->pkt_timebase = (AVRational){ 1, 1000000000 };
	if (avcodec_open2(in->cc, dec, NULL) < 0) {
		avcodec_free_context(&in->cc);
		return false;
	}
	in->codec = codec;
	in->draining = in->drain_flushed = in->no_va = false;
	return true;
}

static void receive_all(struct inst *in)
{
	for (;;) {
		AVFrame *f = av_frame_alloc();
		int r;

		if (!f)
			return;
		r = avcodec_receive_frame(in->cc, f);
		if (r < 0) {
			av_frame_free(&f);
			if (r != AVERROR(EAGAIN) && r != AVERROR_EOF && in->errors++ < 10)
				log_msg("vdecd: inst %u: decode error %d", in->id, r);
			return;
		}
		if (f->format != AV_PIX_FMT_VAAPI || !f->hw_frames_ctx) {
			av_frame_free(&f);
			continue;
		}
		struct frame *fr = calloc(1, sizeof(*fr));
		if (!fr) {
			av_frame_free(&f);
			return;
		}
		fr->f = f;
		*in->out_tail = fr;
		in->out_tail = &fr->next;
		in->nout++;
	}
}

/* ---- CAPTURE buffers ------------------------------------------------------------ */

static void cap_free(struct inst *in)
{
	finish(in, false);
	for (int i = 0; i < in->ncap; i++) {
		plane_free(&in->cap[i].pl);
		if (in->cap[i].bo)
			gbm_bo_destroy(in->cap[i].bo);
	}
	memset(in->cap, 0, sizeof(in->cap));
	in->ncap = 0;
	in->cap_on = false;
}

static struct gbm_bo *cap_bo(int w, int h)
{
	return gbm_bo_create(gbm, w, h, GBM_FORMAT_ARGB8888, GBM_BO_USE_LINEAR | GBM_BO_USE_RENDERING);
}

/* The row length GBM gives at this size (the app needs it up front). */
static uint32_t cap_stride(int w, int h)
{
	struct gbm_bo *bo = cap_bo(w, h);
	uint32_t stride;

	if (!bo)
		return 0;
	stride = gbm_bo_get_stride(bo);
	gbm_bo_destroy(bo);
	return stride;
}

static void cap_setup(struct inst *in, const struct ovd_msg *m)
{
	struct ovd_buffers b = { .inst = in->id };
	int n = m->count > OVD_MAX_CAPTURE ? (int)OVD_MAX_CAPTURE : (int)m->count;
	bool ok = in->fmt_set && (int)m->width == in->width && (int)m->height == in->height;

	cap_free(in);
	for (unsigned i = 0; i < OVD_MAX_CAPTURE; i++)
		b.fd[i] = -1;
	for (int i = 0; ok && i < n; i++) {
		struct capbuf *c = &in->cap[i];

		in->ncap = i + 1;
		c->bo = cap_bo(in->width, in->height);
		ok = c->bo && gbm_bo_get_stride(c->bo) == in->stride;
		b.fd[i] = ok ? gbm_bo_get_fd(c->bo) : -1;
		ok = ok && b.fd[i] >= 0 &&
		     plane_import(&c->pl, b.fd[i], DRM_FORMAT_ARGB8888, in->width, in->height, 0, in->stride);
	}
	b.count = ok ? n : 0;
	if (!ok)
		log_msg("vdecd: inst %u: no CAPTURE buffers for %dx%d", in->id, in->width, in->height);
	if (ioctl(ctl, OVD_IOC_SET_BUFFERS, &b) && errno != ENOENT)	/* ENOENT: closed meanwhile */
		log_msg("vdecd: set buffers: %s", strerror(errno));
	for (int i = 0; i < n; i++)
		if (b.fd[i] >= 0)
			close(b.fd[i]);
	if (!ok)
		cap_free(in);
	in->cap_width = ok ? in->width : 0;
	in->cap_height = ok ? in->height : 0;
	if (debug)
		log_msg("vdecd: inst %u: %d CAPTURE buffers %dx%d", in->id, b.count, in->width, in->height);
}

static struct capbuf *cap_get(struct inst *in)
{
	for (int i = 0; i < in->ncap; i++)
		if (in->cap[i].free)
			return &in->cap[i];
	return NULL;
}

/* ---- convert a decoded picture into a CAPTURE buffer ------------------------------ */

static const char *vs_src =
	"#version 300 es\n"
	"void main() {\n"
	"  vec2 p = vec2(float(gl_VertexID & 1), float(gl_VertexID >> 1));\n"
	"  gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);\n"
	"}\n";
/* Texels by position, not by normalized coordinates: an imported surface is
 * the host's texture, which can be wider than the picture (854 -> 864). Chroma
 * is interpolated by hand (centre-sited 4:2:0). */
static const char *fs_src =
	"#version 300 es\n"
	"precision highp float;\n"
	"uniform highp sampler2D y_tex, uv_tex;\n"
	"uniform mat3 matrix;\n"
	"uniform vec3 offset;\n"
	"uniform ivec2 cmax;\n"
	"out vec4 color;\n"
	"vec2 uv_at(ivec2 p) { return texelFetch(uv_tex, clamp(p, ivec2(0), cmax), 0).rg; }\n"
	"void main() {\n"
	"  ivec2 p = ivec2(gl_FragCoord.xy);\n"
	"  vec2 c = (vec2(p) + 0.5) * 0.5 - 0.5;\n"
	"  ivec2 c0 = ivec2(floor(c));\n"
	"  vec2 f = c - vec2(c0);\n"
	"  vec2 uv = mix(mix(uv_at(c0), uv_at(c0 + ivec2(1, 0)), f.x),\n"
	"                mix(uv_at(c0 + ivec2(0, 1)), uv_at(c0 + ivec2(1, 1)), f.x), f.y);\n"
	"  vec3 yuv = vec3(texelFetch(y_tex, p, 0).r, uv) - offset;\n"
	"  color = vec4(clamp(matrix * yuv, 0.0, 1.0), 1.0);\n"
	"}\n";

static GLuint prog;
static GLint u_matrix, u_offset, u_cmax;

static bool prog_init(void)
{
	const char *src[2] = { vs_src, fs_src };
	GLenum type[2] = { GL_VERTEX_SHADER, GL_FRAGMENT_SHADER };
	GLint ok;

	prog = glCreateProgram();
	for (int i = 0; i < 2; i++) {
		GLuint sh = glCreateShader(type[i]);

		glShaderSource(sh, 1, &src[i], NULL);
		glCompileShader(sh);
		glGetShaderiv(sh, GL_COMPILE_STATUS, &ok);
		if (!ok) {
			char msg[512];

			glGetShaderInfoLog(sh, sizeof(msg), NULL, msg);
			log_msg("vdecd: shader: %s", msg);
			return false;
		}
		glAttachShader(prog, sh);
		glDeleteShader(sh);
	}
	glLinkProgram(prog);
	glGetProgramiv(prog, GL_LINK_STATUS, &ok);
	if (!ok)
		return false;
	glUseProgram(prog);
	glUniform1i(glGetUniformLocation(prog, "y_tex"), 0);
	glUniform1i(glGetUniformLocation(prog, "uv_tex"), 1);
	u_matrix = glGetUniformLocation(prog, "matrix");
	u_offset = glGetUniformLocation(prog, "offset");
	u_cmax = glGetUniformLocation(prog, "cmax");
	return true;
}

/* YUV -> RGB for the stream's matrix and range (BT.709 if it does not say,
 * BT.601 below 720 lines, as players do). */
static void set_matrix(const AVFrame *f)
{
	float kr = 0.2126f, kb = 0.0722f, kg, sy = 1, sc = 1, m[9];
	float off[3] = { 0, 128.f / 255, 128.f / 255 };

	switch (f->colorspace) {
	case AVCOL_SPC_BT470BG:
	case AVCOL_SPC_SMPTE170M:
		kr = 0.299f, kb = 0.114f;
		break;
	case AVCOL_SPC_BT2020_NCL:
	case AVCOL_SPC_BT2020_CL:
		kr = 0.2627f, kb = 0.0593f;
		break;
	case AVCOL_SPC_BT709:
		break;
	default:
		if (f->height < 720)
			kr = 0.299f, kb = 0.114f;
	}
	kg = 1 - kr - kb;
	if (f->color_range != AVCOL_RANGE_JPEG) {
		sy = 255.f / 219, sc = 255.f / 224;
		off[0] = 16.f / 255;
	}
	m[0] = sy, m[1] = 0, m[2] = 2 * (1 - kr) * sc;
	m[3] = sy, m[4] = -2 * kb * (1 - kb) / kg * sc, m[5] = -2 * kr * (1 - kr) / kg * sc;
	m[6] = sy, m[7] = 2 * (1 - kb) * sc, m[8] = 0;
	glUniformMatrix3fv(u_matrix, 1, GL_TRUE, m);
	glUniform3fv(u_offset, 1, off);
}

static struct srcimg *src_get(struct inst *in, AVFrame *f)
{
	VASurfaceID id = (VASurfaceID)(uintptr_t)f->data[3];
	VADRMPRIMESurfaceDescriptor d;
	struct srcimg *s;
	bool ok = true;

	/* Surfaces are cached per frames context, which we keep alive (and its
	 * surface ids with it) while anything is cached. */
	if (!in->src_frames || in->src_frames->data != f->hw_frames_ctx->data) {
		src_flush(in);
		in->src_frames = av_buffer_ref(f->hw_frames_ctx);
	}
	for (s = in->src; s; s = s->next)
		if (s->id == id)
			return s;

	if (vaExportSurfaceHandle(va, id, VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2,
				  VA_EXPORT_SURFACE_READ_ONLY | VA_EXPORT_SURFACE_SEPARATE_LAYERS, &d))
		return NULL;
	s = calloc(1, sizeof(*s));
	if (s && d.num_layers >= 2 && d.layers[0].drm_format == DRM_FORMAT_R8 &&
	    d.layers[1].drm_format == DRM_FORMAT_GR88) {
		s->id = id;
		for (int p = 0; p < 2 && ok; p++) {
			ok = plane_import(&s->pl[p], d.objects[d.layers[p].object_index[0]].fd,
					  d.layers[p].drm_format,
					  p ? (int)d.width / 2 : (int)d.width,
					  p ? (int)d.height / 2 : (int)d.height,
					  d.layers[p].offset[0], d.layers[p].pitch[0]);
			glBindTexture(GL_TEXTURE_2D, s->pl[p].tex);
			glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
			glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
			glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
			glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
		}
	} else {
		ok = false;	/* only 8-bit 4:2:0 (NV12) is offered */
	}
	for (unsigned o = 0; o < d.num_objects; o++)
		close(d.objects[o].fd);
	if (debug)
		log_msg("vdecd: inst %u: surface %u %ux%u pitch %u/%u frame %dx%d", in->id, id, d.width, d.height,
			d.layers[0].pitch[0], d.num_layers > 1 ? d.layers[1].pitch[0] : 0, f->width, f->height);
	if (!ok) {
		if (s) {
			plane_free(&s->pl[0]);
			plane_free(&s->pl[1]);
			free(s);
		}
		return NULL;
	}
	s->next = in->src;
	in->src = s;
	return s;
}

static bool convert_frame(struct inst *in, AVFrame *f, struct capbuf *c)
{
	VASurfaceID id = (VASurfaceID)(uintptr_t)f->data[3];
	struct srcimg *s;

	if (vaSyncSurface(va, id))
		return false;
	s = src_get(in, f);
	if (!s)
		return false;
	glBindFramebuffer(GL_FRAMEBUFFER, c->pl.fbo);
	glViewport(0, 0, in->width, in->height);
	glActiveTexture(GL_TEXTURE0);
	glBindTexture(GL_TEXTURE_2D, s->pl[0].tex);
	glActiveTexture(GL_TEXTURE1);
	glBindTexture(GL_TEXTURE_2D, s->pl[1].tex);
	set_matrix(f);
	glUniform2i(u_cmax, (f->width + 1) / 2 - 1, (f->height + 1) / 2 - 1);
	glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
	/* The app's GPU process reads it from another context: it gets the
	 * buffer when this fence says the Mac's GPU is done (finish()). Waiting
	 * later, not here, keeps the host busy with the next decode meanwhile. */
	c->fence = create_sync(egl, EGL_SYNC_FENCE_KHR, NULL);
	glFlush();
	return c->fence != EGL_NO_SYNC_KHR && glGetError() == GL_NO_ERROR;
}

/* Waits for the converted pictures in order and hands them to the app
 * (deliver), or only settles them (the buffers are being taken back).
 * Not forever: a GPU that does not finish one in FENCE_TIMEOUT fails this
 * video (and the rest of its pictures go back as errors at once). */
static void finish(struct inst *in, bool deliver)
{
	bool late = false;

	for (int k = 0; k < in->nbusy; k++) {
		struct capbuf *c = &in->cap[in->busy[k]];

		if (c->fence) {
			if (wait_sync(egl, c->fence, EGL_SYNC_FLUSH_COMMANDS_BIT_KHR, late ? 0 : FENCE_TIMEOUT) !=
			    EGL_CONDITION_SATISFIED_KHR) {
				c->ok = false;
				late = true;
			}
			destroy_sync(egl, c->fence);
			c->fence = NULL;
		}
		if (deliver)
			done(OVD_IOC_CAPTURE_DONE, in, in->busy[k], c->seq, c->pts, c->ok ? 0 : OVD_DONE_ERROR);
	}
	in->nbusy = 0;
	if (late)
		inst_fail(in, "the GPU did not finish a picture within 1 s");
}

/* ---- the work loop for one instance ------------------------------------------------ */

static bool set_format(struct inst *in, AVFrame *f)
{
	struct ovd_format fmt = { .inst = in->id, .min_buffers = 4 };
	int w = (f->width + 1) & ~1, h = (f->height + 1) & ~1;
	char why[96];

	/* The module's limits: what it refuses, the app must hear about. */
	if (w < (int)OVD_MIN_SIZE || h < (int)OVD_MIN_SIZE || w > (int)OVD_MAX_WIDTH ||
	    h > (int)OVD_MAX_HEIGHT || !(fmt.stride = cap_stride(w, h))) {
		snprintf(why, sizeof(why), "unsupported picture %dx%d", f->width, f->height);
		inst_fail(in, why);
		return false;
	}
	fmt.width = w;
	fmt.height = h;
	fmt.visible_width = f->width;
	fmt.visible_height = f->height;
	if (ioctl(ctl, OVD_IOC_SET_FORMAT, &fmt)) {
		snprintf(why, sizeof(why), "format %dx%d refused (%s)", f->width, f->height, strerror(errno));
		inst_fail(in, errno == ENOENT ? NULL : why);
		return false;
	}
	in->fmt_set = true;
	in->width = w;
	in->height = h;
	in->vis_width = f->width;
	in->vis_height = f->height;
	in->stride = fmt.stride;
	if (debug)
		log_msg("vdecd: inst %u: format %dx%d (visible %dx%d)", in->id, w, h, f->width, f->height);
	return true;
}

/* Hands decoded pictures to the app. False: waiting (buffers, or a new size). */
static bool output_frames(struct inst *in)
{
	bool progress = false;

	while (in->out) {
		AVFrame *f = in->out->f;
		struct capbuf *c;

		if (!in->fmt_set || f->width != in->vis_width || f->height != in->vis_height) {
			/* A new size: the frames before it are out. The app gets the
			 * new format (SOURCE_CHANGE), then an empty LAST buffer if
			 * its CAPTURE buffers stream. */
			c = NULL;
			if (in->ncap && in->cap_on && !(c = cap_get(in)))
				return progress;
			finish(in, true);	/* the pictures before the change first */
			if (in->failed || !set_format(in, f))
				return true;
			if (c) {
				c->free = false;
				done(OVD_IOC_CAPTURE_DONE, in, c - in->cap, c->seq, 0, OVD_DONE_LAST);
			}
			cap_free(in);
			return true;
		}
		if (in->cap_width != in->width || in->cap_height != in->height)
			return progress;	/* until the app allocates */
		c = cap_get(in);
		if (!c)
			return progress;
		double t0 = debug ? now_ms() : 0;
		bool ok = convert_frame(in, f, c);
		double t_conv = debug ? now_ms() - t0 : 0;

		c->free = false;
		c->pts = f->pts;
		c->ok = ok;
		in->busy[in->nbusy++] = c - in->cap;
		if (!ok && in->errors++ < 10)
			log_msg("vdecd: inst %u: conversion failed", in->id);
		if (debug)
			log_msg("vdecd: inst %u: frame %u pts %lld -> buffer %td, convert %.1f ms, decode %.1f ms",
				in->id, in->frames, (long long)f->pts, c - in->cap, t_conv, in->decode_ms);
		in->frames++;
		struct frame *fr = in->out;

		in->out = fr->next;
		if (!in->out)
			in->out_tail = &in->out;
		in->nout--;
		av_frame_free(&fr->f);
		free(fr);
		progress = true;
	}
	return progress;
}

static bool feed_input(struct inst *in)
{
	bool progress = false;

	while (in->in && in->cc && in->nout < MAX_PENDING_FRAMES) {
		struct pkt *p = in->in;
		AVPacket *ap = av_packet_alloc();
		int r;

		if (!ap || !(ap->buf = av_buffer_ref(p->buf))) {
			av_packet_free(&ap);
			return progress;
		}
		ap->data = p->buf->data + sizeof(struct ovd_msg);
		ap->size = p->size;
		ap->pts = p->ts;
		double t0 = debug ? now_ms() : 0;
		r = avcodec_send_packet(in->cc, ap);
		if (debug)
			in->decode_ms = now_ms() - t0;
		av_packet_free(&ap);
		if (r == AVERROR(EAGAIN)) {
			receive_all(in);
			if (in->nout >= MAX_PENDING_FRAMES)
				return progress;
			continue;
		}
		if (r < 0 && in->errors++ < 10)
			log_msg("vdecd: inst %u: bitstream refused (%d)", in->id, r);
		done(OVD_IOC_OUTPUT_DONE, in, p->index, p->seq, 0, 0);
		in->in = p->next;
		if (!in->in)
			in->in_tail = &in->in;
		in->nin--;
		av_buffer_unref(&p->buf);
		free(p);
		receive_all(in);
		progress = true;
	}
	return progress;
}

/* DEC_CMD_STOP: everything queued comes out, then an empty LAST buffer + EOS.
 * Without CAPTURE buffers (no picture yet, or CAPTURE stopped) the module
 * sends EOS and makes the next CAPTURE buffer the LAST one (OVD_NO_BUFFER). */
static bool drain(struct inst *in)
{
	struct capbuf *c;

	if (!in->draining || in->in)
		return false;
	if (in->cc && !in->drain_flushed) {
		avcodec_send_packet(in->cc, NULL);
		in->drain_flushed = true;
		receive_all(in);
		return true;
	}
	if (in->out)
		return false;
	c = cap_get(in);
	if (!c && in->ncap && in->cap_on)
		return false;	/* the app holds them all: wait for one */
	finish(in, true);
	if (in->failed)
		return true;
	if (c) {
		c->free = false;
		done(OVD_IOC_CAPTURE_DONE, in, c - in->cap, c->seq, 0, OVD_DONE_LAST | OVD_DONE_EOS);
	} else {
		done(OVD_IOC_CAPTURE_DONE, in, OVD_NO_BUFFER, 0, 0, OVD_DONE_LAST | OVD_DONE_EOS);
	}
	if (in->cc)
		avcodec_flush_buffers(in->cc);
	in->draining = in->drain_flushed = false;
	return true;
}

static void pump(struct inst *in)
{
	for (int guard = 0; guard < 1000 && !in->failed; guard++) {
		bool progress = output_frames(in);

		progress |= feed_input(in);	/* the next decodes go out first */
		if (in->no_va) {
			in->no_va = false;
			inst_fail(in, "VA-API cannot decode this stream");
			return;
		}
		finish(in, true);
		progress |= drain(in);
		if (!progress)
			return;
	}
}

/* ---- messages ------------------------------------------------------------------ */

static void inst_close(struct inst *in)
{
	struct inst **pp = &insts;

	while (*pp != in)
		pp = &(*pp)->next;
	*pp = in->next;
	input_drop(in);
	decoder_close(in);
	cap_free(in);
	if (debug)
		log_msg("vdecd: inst %u: closed after %u frames", in->id, in->frames);
	free(in);
}

/* One message; a BITSTREAM one takes *buf (it holds the data). */
static void handle(const struct ovd_msg *m, AVBufferRef **buf)
{
	struct inst *in = inst_find(m->inst);

	if (debug && m->type != OVD_MSG_BITSTREAM && m->type != OVD_MSG_CAPTURE_QUEUED)
		log_msg("vdecd: inst %u: message %u (in %d, out %d)", m->inst, m->type,
			in ? in->nin : -1, in ? in->nout : -1);

	if (m->type == OVD_MSG_OPEN) {
		/* The module does not reuse ids; should one come again anyway,
		 * the old decoder's state goes, it is not the new one's. */
		if (in)
			inst_close(in);
		in = calloc(1, sizeof(*in));
		if (!in)
			return;
		in->id = m->inst;
		in->in_tail = &in->in;
		in->out_tail = &in->out;
		in->next = insts;
		insts = in;
		if (debug)
			log_msg("vdecd: inst %u: open", in->id);
		return;
	}
	if (!in)
		return;
	if (m->type == OVD_MSG_CLOSE) {
		inst_close(in);
		return;
	}
	if (in->failed)
		return;

	switch (m->type) {
	case OVD_MSG_START:
		if ((!in->cc || in->codec != m->codec) && !decoder_open(in, m->codec)) {
			char why[64];

			snprintf(why, sizeof(why), "cannot decode %.4s", (const char *)&m->codec);
			inst_fail(in, why);
		}
		break;
	case OVD_MSG_BITSTREAM: {
		struct pkt *p = in->nin < MAX_PENDING_INPUT ? calloc(1, sizeof(*p)) : NULL;

		if (!p) {
			done(OVD_IOC_OUTPUT_DONE, in, m->index, m->seq, 0, OVD_DONE_ERROR);
			break;
		}
		p->buf = *buf;
		*buf = NULL;
		memset(p->buf->data + sizeof(*m) + m->size, 0, AV_INPUT_BUFFER_PADDING_SIZE);
		p->size = m->size;
		p->index = m->index;
		p->seq = m->seq;
		p->ts = m->timestamp;
		*in->in_tail = p;
		in->in_tail = &p->next;
		in->nin++;
		break;
	}
	case OVD_MSG_FLUSH:
		finish(in, true);
		input_drop(in);
		frames_drop(in);
		if (in->cc)
			avcodec_flush_buffers(in->cc);
		in->draining = in->drain_flushed = false;
		break;
	case OVD_MSG_DRAIN:
		in->draining = true;
		break;
	case OVD_MSG_CAPTURE_SETUP:
		cap_setup(in, m);
		break;
	case OVD_MSG_CAPTURE_QUEUED:
		if (m->index < (uint32_t)in->ncap) {
			in->cap[m->index].free = true;
			in->cap[m->index].seq = m->seq;
			in->cap_on = true;
		}
		break;
	case OVD_MSG_CAPTURE_STOP:
		finish(in, false);
		for (int i = 0; i < in->ncap; i++)
			in->cap[i].free = false;
		in->cap_on = false;
		break;
	}
	pump(in);
}

/* ---- setup ------------------------------------------------------------------------ */

/* HEVC only on request: Chromium's V4L2 stateful decoder (153) does not
 * implement it, yet would tell pages it plays HEVC if we offered it. */
static uint32_t va_codecs(void)
{
	bool hevc = getenv("OMACVM_VDEC_HEVC") && *getenv("OMACVM_VDEC_HEVC") == '1';
	int n = vaMaxNumProfiles(va), np = 0;
	VAProfile *profiles = calloc(n, sizeof(*profiles));
	uint32_t codecs = 0;

	if (!profiles || vaQueryConfigProfiles(va, profiles, &np))
		np = 0;
	for (int i = 0; i < np; i++) {
		VAEntrypoint ep[16];
		int ne = 0;
		bool vld = false;

		if (vaQueryConfigEntrypoints(va, profiles[i], ep, &ne) || ne > 16)
			continue;
		for (int e = 0; e < ne; e++)
			vld |= ep[e] == VAEntrypointVLD;
		if (!vld)
			continue;
		if (profiles[i] == VAProfileH264High)
			codecs |= OVD_CODEC_H264;
		else if (profiles[i] == VAProfileHEVCMain && hevc)
			codecs |= OVD_CODEC_HEVC;
		else if (profiles[i] == VAProfileVP9Profile0)
			codecs |= OVD_CODEC_VP9;
	}
	free(profiles);
	return codecs;
}

/* NULL when the GPU is ready, else the part that failed. */
static const char *gpu_init(void)
{
	int drm = open(RENDER_NODE, O_RDWR | O_CLOEXEC);
	EGLint ctx_attr[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
	PFNEGLGETPLATFORMDISPLAYEXTPROC get_display;
	EGLContext ctx;

	if (drm < 0)
		return "open";
	if (!(gbm = gbm_create_device(drm)))
		return "GBM";
	get_display = (void *)eglGetProcAddress("eglGetPlatformDisplayEXT");
	create_image = (void *)eglGetProcAddress("eglCreateImageKHR");
	destroy_image = (void *)eglGetProcAddress("eglDestroyImageKHR");
	image_target = (void *)eglGetProcAddress("glEGLImageTargetTexture2DOES");
	create_sync = (void *)eglGetProcAddress("eglCreateSyncKHR");
	wait_sync = (void *)eglGetProcAddress("eglClientWaitSyncKHR");
	destroy_sync = (void *)eglGetProcAddress("eglDestroySyncKHR");
	if (!get_display || !create_image || !destroy_image || !image_target ||
	    !create_sync || !wait_sync || !destroy_sync)
		return "EGL";
	egl = get_display(EGL_PLATFORM_GBM_KHR, gbm, NULL);
	if (!egl || !eglInitialize(egl, NULL, NULL) || !eglBindAPI(EGL_OPENGL_ES_API))
		return "EGL";
	ctx = eglCreateContext(egl, EGL_NO_CONFIG_KHR, EGL_NO_CONTEXT, ctx_attr);
	if (!ctx || !eglMakeCurrent(egl, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx))
		return "EGL";
	if (av_hwdevice_ctx_create(&hwdev, AV_HWDEVICE_TYPE_VAAPI, RENDER_NODE, NULL, 0) < 0)
		return "VA-API";
	va = ((AVVAAPIDeviceContext *)((AVHWDeviceContext *)hwdev->data)->hwctx)->display;
	return prog_init() ? NULL : "GL";
}

/* A file in systemd's runtime folder (kept across restarts: the unit). */
static bool runtime_path(char *path, size_t size, const char *name)
{
	const char *dir = getenv("RUNTIME_DIRECTORY");

	return dir && snprintf(path, size, "%s/%s", dir, name) < (int)size;
}

/* What omacvm check reports: the codecs on offer. */
static void write_status(const char *codecs)
{
	char path[512];
	FILE *f;

	if (!runtime_path(path, sizeof(path), "status"))
		return;
	f = fopen(path, "w");
	if (f) {
		fprintf(f, "%s\n", codecs);
		fclose(f);
	}
}

/* The GPU is not usable: wait longer each time, then exit 4 and systemd
 * starts a new process (a Mesa fixed by an update loads only in a new one).
 * With the unit's RestartSec=2: 2 s, 4 s, 8 s ... up to 2 minutes. The count
 * is in the runtime folder; it goes once the daemon is ready, so a crash
 * later is restarted in 2 s again. */
static void gpu_wait(void)
{
	char path[512];
	int n = 0, wait;
	FILE *f;

	if (!runtime_path(path, sizeof(path), "gpu-tries"))
		return;
	f = fopen(path, "r");
	if (f) {
		if (fscanf(f, "%d", &n) != 1 || n < 0)
			n = 0;
		fclose(f);
	}
	f = fopen(path, "w");
	if (f) {
		fprintf(f, "%d\n", n + 1);
		fclose(f);
	}
	wait = n >= 6 ? 118 : (2 << n) - 2;
	for (int s = 0; s < wait; s++) {
		sd_notify(0, "WATCHDOG=1");
		sleep(1);
	}
}

int main(void)
{
	struct ovd_caps caps = { .max_width = OVD_MAX_WIDTH, .max_height = OVD_MAX_HEIGHT,
				 .version = OVD_VERSION };
	/* read() fills a pooled buffer: a bitstream stays in it until FFmpeg
	 * is done (no copy here); the pages a buffer touched stay mapped. */
	size_t bufsize = sizeof(struct ovd_msg) + OVD_MAX_BITSTREAM;
	AVBufferPool *pool = av_buffer_pool_init(bufsize + AV_INPUT_BUFFER_PADDING_SIZE, NULL);
	AVBufferRef *buf = NULL;
	char codecs[32], path[512];
	uint64_t wd_usec = 0;
	int wd_ms = -1;		/* systemd's watchdog: ping every third of it */
	double pinged = 0;
	const char *gpu_fail;

	debug = getenv("OMACVM_VDEC_DEBUG") && *getenv("OMACVM_VDEC_DEBUG") == '1';
	signal(SIGPIPE, SIG_IGN);
	if (!pool)
		return 1;
	/* Not ready (yet): no status from an earlier run. */
	if (runtime_path(path, sizeof(path), "status"))
		unlink(path);
	/* The GPU can come later (a broken Mesa fixed by an update). */
	gpu_fail = gpu_init();
	if (gpu_fail) {
		log_msg("vdecd: the GPU is not usable (%s on %s failed): apps decode on the CPU, trying again",
			gpu_fail, RENDER_NODE);
		gpu_wait();
		return 4;
	}
	if (runtime_path(path, sizeof(path), "gpu-tries"))
		unlink(path);
	caps.codecs = va_codecs();
	if (!caps.codecs) {
		log_msg("vdecd: VA-API offers no H.264, HEVC or VP9 decoding: exiting, apps decode on the CPU");
		return 0;
	}
	ctl = open("/dev/omacvm-vdec", O_RDWR | O_CLOEXEC);
	if (ctl < 0) {
		log_msg("vdecd: /dev/omacvm-vdec: %s (module not loaded?)", strerror(errno));
		return 1;
	}
	if (ioctl(ctl, OVD_IOC_SET_CAPS, &caps)) {
		if (errno == EPROTO) {
			log_msg("vdecd: the omacvm-vdec module loaded is from another build: "
				"restart the VM (apps decode on the CPU until then)");
			return 3;
		}
		log_msg("vdecd: set caps: %s", strerror(errno));
		return 1;
	}
	snprintf(codecs, sizeof(codecs), "%s%s%s", caps.codecs & OVD_CODEC_H264 ? " H.264" : "",
		 caps.codecs & OVD_CODEC_HEVC ? " HEVC" : "", caps.codecs & OVD_CODEC_VP9 ? " VP9" : "");
	log_msg("vdecd: ready:%s", codecs);
	write_status(codecs + 1);
	if (sd_watchdog_enabled(0, &wd_usec) > 0 && wd_usec >= 3000)
		wd_ms = (int)(wd_usec / 3000);

	for (;;) {
		struct pollfd pfd = { .fd = ctl, .events = POLLIN };
		struct ovd_msg m;
		ssize_t n;
		int r;

		if (wd_ms > 0 && now_ms() - pinged >= wd_ms) {
			sd_notify(0, "WATCHDOG=1");
			pinged = now_ms();
		}
		r = poll(&pfd, 1, wd_ms);
		if (r < 0 && errno == EINTR)
			continue;
		if (r < 0) {
			log_msg("vdecd: poll: %s", strerror(errno));
			return 1;
		}
		if (!r)
			continue;
		if (!buf && !(buf = av_buffer_pool_get(pool))) {
			log_msg("vdecd: out of memory");
			return 1;
		}
		n = read(ctl, buf->data, bufsize);
		if (n < 0 && errno == EINTR)
			continue;
		if (n < (ssize_t)sizeof(m)) {
			log_msg("vdecd: read: %s", n < 0 ? strerror(errno) : "short");
			return 1;
		}
		memcpy(&m, buf->data, sizeof(m));
		if (m.type == OVD_MSG_BITSTREAM && (size_t)n != sizeof(m) + m.size)
			continue;
		handle(&m, &buf);
	}
}
