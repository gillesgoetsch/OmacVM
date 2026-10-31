// SPDX-License-Identifier: MIT
/*
 * vdec-test: drives the omacvm-vdec V4L2 decoder the way Chromium does and
 * checks every picture against FFmpeg's software decoder.
 *
 *   vdec-test [MODE] FILE [FILE...]   (root or the video group, omacvm-vdecd running)
 *
 * Per file: OUTPUT buffers with one frame each, CAPTURE buffers taken from
 * the driver (MMAP) and exported (EXPBUF), each picture read back through EGL
 * the way the compositor imports it, compared with FFmpeg's software picture
 * converted to RGB (PSNR, lowest of all frames; "pictures" is a hash of every
 * picture in order, the same for two builds that decode the same). Then a seek (OUTPUT
 * STREAMOFF/STREAMON from the first key frame), then a drain (DEC_CMD_STOP:
 * an empty LAST buffer and the EOS event). A size change in the stream must
 * come as LAST + SOURCE_CHANGE. Prints one JSON line per file; exit 1 when a
 * check fails. MODEs (one, before the files):
 *   --early-drain  DEC_CMD_STOP before the first packet: EOS within 2 s, then
 *                  DEC_CMD_START and the normal run on the same decoder
 *   --churn        5 rounds: a busy decoder is closed (another thread) while
 *                  the next one opens; the next one must decode the file
 *   --expect-fail  the file must fail fast (a picture under 64 px): an error
 *                  back within 5 s, no hang
 *   --stall        (root) the daemon is stopped (SIGSTOP) after 20 pictures:
 *                  an error must come back within 15 s (systemd's watchdog
 *                  restarts it), then the file decodes again
 *   --flood        (root) with the daemon stopped for a moment, 1000
 *                  DEC_CMD_STOPs: the module fails the decoder (its message
 *                  queue is bounded) instead of growing
 *   --hold-all-at-eos  (root) Chromium's end of a stream: the last packets
 *                  fed, DEC_CMD_STOP, every OUTPUT buffer back and every
 *                  CAPTURE buffer held by the app while the decoder still owes
 *                  pictures and the LAST buffer. A second thread then polls the
 *                  way Chromium waits (POLLIN|POLLPRI plus a wake eventfd, no
 *                  POLLOUT): that poll must sleep, not return POLLERR (Chromium
 *                  drops such a wait and never sees the LAST). Three rounds per
 *                  file, each on a new decoder: wake (the buffers queued back:
 *                  POLLIN within 1 s, the owed pictures, LAST and EOS within
 *                  1 s), streamoff (both queues off: the poll returns within
 *                  1 s), daemon-gone (the daemon stopped as in --stall: POLLERR
 *                  within 15 s)
 *
 * Build: cc -O2 -o vdec-test vdec-test.c $(pkg-config --cflags --libs \
 *          libavformat libavcodec libavutil libswscale egl glesv2 gbm libdrm) -lm
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <signal.h>
#include <sys/eventfd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>
#include <drm_fourcc.h>
#include <gbm.h>
#include <libavcodec/avcodec.h>
#include <libavcodec/bsf.h>
#include <libavformat/avformat.h>
#include <libswscale/swscale.h>
#include <linux/videodev2.h>

#define NOUT 8
#define NCAP 6
#define MIN_PSNR 35.0

static int vfd;
static enum { NORMAL, EARLY_DRAIN, CHURN, EXPECT_FAIL, STALL, FLOOD, HOLD_EOS } mode;
/* --hold-all-at-eos: the round (what ends the held state) */
static enum { H_WAKE, H_STREAMOFF, H_DAEMON } hold_sub;
static EGLDisplay egl;
static PFNEGLCREATEIMAGEKHRPROC create_image;
static PFNEGLDESTROYIMAGEKHRPROC destroy_image;
static PFNGLEGLIMAGETARGETTEXTURE2DOESPROC image_target;

static void die(const char *what)
{
	fprintf(stderr, "vdec-test: %s: %s\n", what, strerror(errno));
	exit(1);
}

static double now_ms(void)
{
	struct timespec t;

	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

static int xioctl(unsigned long req, void *arg)
{
	int r;

	do
		r = ioctl(vfd, req, arg);
	while (r < 0 && errno == EINTR);
	return r;
}

/* ---- the reference: FFmpeg's software decoder, converted to RGBA --------------- */

struct ref {
	AVFormatContext *fc;
	AVCodecContext *cc;
	AVBSFContext *bsf;	/* MP4 H.264 -> Annex B, as Chromium sends it */
	int stream;
	struct SwsContext *sws;
	int sw, sh;
};

static void ref_open(struct ref *r, const char *path)
{
	const AVCodec *dec;

	memset(r, 0, sizeof(*r));
	if (avformat_open_input(&r->fc, path, NULL, NULL) || avformat_find_stream_info(r->fc, NULL) < 0)
		die(path);
	r->stream = av_find_best_stream(r->fc, AVMEDIA_TYPE_VIDEO, -1, -1, &dec, 0);
	if (r->stream < 0)
		die("no video stream");
	r->cc = avcodec_alloc_context3(dec);
	avcodec_parameters_to_context(r->cc, r->fc->streams[r->stream]->codecpar);
	r->cc->thread_count = 1;
	if (avcodec_open2(r->cc, dec, NULL))
		die("software decoder");
	if (dec->id == AV_CODEC_ID_H264) {
		av_bsf_alloc(av_bsf_get_by_name("h264_mp4toannexb"), &r->bsf);
		avcodec_parameters_copy(r->bsf->par_in, r->fc->streams[r->stream]->codecpar);
		r->bsf->time_base_in = r->fc->streams[r->stream]->time_base;
		if (av_bsf_init(r->bsf))
			die("annexb filter");
	}
}

/* The packets of one stream, read through once (a container without a count). */
static int64_t count_packets(const char *path, int stream)
{
	AVFormatContext *fc = NULL;
	AVPacket *p = av_packet_alloc();
	int64_t n = 0;

	if (!p || avformat_open_input(&fc, path, NULL, NULL))
		die(path);
	while (av_read_frame(fc, p) >= 0) {
		n += p->stream_index == stream;
		av_packet_unref(p);
	}
	av_packet_free(&p);
	avformat_close_input(&fc);
	return n;
}

/* The next packet of the stream as the decoder gets it (NULL at the end). */
static AVPacket *ref_packet(struct ref *r)
{
	AVPacket *p = av_packet_alloc();

	for (;;) {
		if (r->bsf && av_bsf_receive_packet(r->bsf, p) == 0)
			return p;
		if (av_read_frame(r->fc, p) < 0) {
			av_packet_free(&p);
			return NULL;
		}
		if (p->stream_index != r->stream) {
			av_packet_unref(p);
			continue;
		}
		if (!r->bsf)
			return p;
		av_bsf_send_packet(r->bsf, p);
	}
}

/* ---- CAPTURE buffers, imported through EGL ----------------------------------------- */

struct cap {
	int fd;
	EGLImageKHR img;
	GLuint tex, fbo;
};

static struct cap caps[NCAP];
static int ncap, cap_w, cap_h, vis_w, vis_h, cap_stride;
static int cap_in;	/* CAPTURE buffers queued with the driver */

static void egl_init(void)
{
	int drm = open("/dev/dri/renderD128", O_RDWR | O_CLOEXEC);
	struct gbm_device *gbm = drm >= 0 ? gbm_create_device(drm) : NULL;
	PFNEGLGETPLATFORMDISPLAYEXTPROC get_display = (void *)eglGetProcAddress("eglGetPlatformDisplayEXT");
	EGLint attr[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
	EGLContext ctx;

	create_image = (void *)eglGetProcAddress("eglCreateImageKHR");
	destroy_image = (void *)eglGetProcAddress("eglDestroyImageKHR");
	image_target = (void *)eglGetProcAddress("glEGLImageTargetTexture2DOES");
	if (!gbm || !get_display)
		die("gbm/egl");
	egl = get_display(EGL_PLATFORM_GBM_KHR, gbm, NULL);
	if (!eglInitialize(egl, NULL, NULL) || !eglBindAPI(EGL_OPENGL_ES_API))
		die("eglInitialize");
	ctx = eglCreateContext(egl, EGL_NO_CONFIG_KHR, EGL_NO_CONTEXT, attr);
	if (!ctx || !eglMakeCurrent(egl, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx))
		die("egl context");
}

static void cap_release(void)
{
	struct v4l2_requestbuffers rb = { .type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE, .memory = V4L2_MEMORY_MMAP };

	for (int i = 0; i < ncap; i++) {
		glDeleteFramebuffers(1, &caps[i].fbo);
		glDeleteTextures(1, &caps[i].tex);
		destroy_image(egl, caps[i].img);
		close(caps[i].fd);
	}
	ncap = 0;
	cap_in = 0;
	xioctl(VIDIOC_REQBUFS, &rb);
}

/* False: the decoder failed (an expected end in the failure modes). */
static bool cap_queue(int i)
{
	struct v4l2_plane pl[1] = { 0 };
	struct v4l2_buffer b = { .type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE, .memory = V4L2_MEMORY_MMAP,
				 .index = i, .length = 1, .m.planes = pl };

	if (xioctl(VIDIOC_QBUF, &b))
		return false;
	cap_in++;
	return true;
}

/* After SOURCE_CHANGE: the new format, buffers, exports, imports, stream on.
 * False: the decoder failed. */
static bool cap_setup(void)
{
	struct v4l2_format f = { .type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE };
	struct v4l2_selection sel = { .type = V4L2_BUF_TYPE_VIDEO_CAPTURE, .target = V4L2_SEL_TGT_COMPOSE };
	struct v4l2_requestbuffers rb = { .count = NCAP, .type = f.type, .memory = V4L2_MEMORY_MMAP };
	int type = f.type;

	if (xioctl(VIDIOC_G_FMT, &f) || xioctl(VIDIOC_G_SELECTION, &sel))
		die("G_FMT/G_SELECTION CAPTURE");
	if (f.fmt.pix_mp.pixelformat != V4L2_PIX_FMT_ABGR32 || f.fmt.pix_mp.num_planes != 1) {
		errno = EPROTO;
		die("CAPTURE format is not single-plane ABGR32");
	}
	cap_w = f.fmt.pix_mp.width;
	cap_h = f.fmt.pix_mp.height;
	cap_stride = f.fmt.pix_mp.plane_fmt[0].bytesperline;
	vis_w = sel.r.width;
	vis_h = sel.r.height;
	if (xioctl(VIDIOC_REQBUFS, &rb) || rb.count < 2)
		return false;
	ncap = rb.count > NCAP ? NCAP : rb.count;
	for (int i = 0; i < ncap; i++) {
		struct v4l2_exportbuffer e = { .type = type, .index = i, .plane = 0, .flags = O_CLOEXEC | O_RDWR };
		EGLint a[] = {
			EGL_WIDTH, cap_w, EGL_HEIGHT, cap_h, EGL_LINUX_DRM_FOURCC_EXT, DRM_FORMAT_ARGB8888,
			EGL_DMA_BUF_PLANE0_FD_EXT, 0, EGL_DMA_BUF_PLANE0_OFFSET_EXT, 0,
			EGL_DMA_BUF_PLANE0_PITCH_EXT, cap_stride, EGL_NONE,
		};

		if (xioctl(VIDIOC_EXPBUF, &e))
			die("EXPBUF");
		caps[i].fd = e.fd;
		/* The check Chromium makes before it imports a frame. */
		if (lseek(e.fd, 0, SEEK_END) < (off_t)cap_stride * cap_h) {
			errno = EPROTO;
			die("CAPTURE dmabuf smaller than its plane");
		}
		a[7] = e.fd;
		caps[i].img = create_image(egl, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, NULL, a);
		if (!caps[i].img)
			die("EGL import of a CAPTURE buffer");
		glGenTextures(1, &caps[i].tex);
		glBindTexture(GL_TEXTURE_2D, caps[i].tex);
		image_target(GL_TEXTURE_2D, caps[i].img);
		glGenFramebuffers(1, &caps[i].fbo);
		glBindFramebuffer(GL_FRAMEBUFFER, caps[i].fbo);
		glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, caps[i].tex, 0);
		if (!cap_queue(i))
			return false;
	}
	return xioctl(VIDIOC_STREAMON, &type) == 0;
}

/* ---- one file ------------------------------------------------------------------------ */

struct result {
	int frames, sizes, seeks, errors;
	double min_psnr;
	uint64_t hash;		/* FNV-1a of every picture read back, in order */
	bool drained, eos;
	bool failed;		/* the decoder refused buffers (an error came back) */
	bool timeout;		/* no progress: a hang */
	bool early_eos;		/* --early-drain: EOS without a picture */
	double fail_ms;		/* --stall/--expect-fail: until the error came */
	/* --hold-all-at-eos */
	bool hold;		/* the held state was reached (LAST still owed) */
	bool blocked;		/* the poll still slept 500 ms into it */
	int revents;		/* what that poll returned with */
	double poll_ms;		/* from its start to its return */
	double after_ms;	/* from the round's action to its return; -1: none */
	double last_ms;		/* wake: from the buffers' requeue to LAST */
	int after_frames;	/* wake: pictures that came after the requeue */
	int missing;		/* wake: software pictures the driver never sent */
};

/* The daemon's pid (--stall). */
static pid_t daemon_pid(void)
{
	FILE *p = popen("pidof -s omacvm-vdecd", "r");
	int pid = 0;

	if (p) {
		if (fscanf(p, "%d", &pid) != 1)
			pid = 0;
		pclose(p);
	}
	return pid;
}

/* --early-drain: STOP with nothing decoded; EOS must come, then START. */
static bool early_drain(void)
{
	struct v4l2_decoder_cmd dc = { .cmd = V4L2_DEC_CMD_STOP };
	double t0 = now_ms();

	if (xioctl(VIDIOC_DECODER_CMD, &dc))
		die("DEC_CMD_STOP (early)");
	while (now_ms() - t0 < 2000) {
		struct pollfd pfd = { .fd = vfd, .events = POLLPRI };
		struct v4l2_event ev;

		if (poll(&pfd, 1, 200) > 0 && (pfd.revents & POLLPRI))
			while (xioctl(VIDIOC_DQEVENT, &ev) == 0)
				if (ev.type == V4L2_EVENT_EOS) {
					dc.cmd = V4L2_DEC_CMD_START;
					if (xioctl(VIDIOC_DECODER_CMD, &dc))
						die("DEC_CMD_START");
					return true;
				}
	}
	return false;
}

/* ---- --hold-all-at-eos: one wait the way Chromium waits ------------------------------- */

/* Chromium 153 (v4l2_stateful_video_decoder.cc, WaitOnceForEvents) waits
 * for CAPTURE on its own thread: poll() on the device for POLLIN|POLLPRI and
 * on a wake eventfd, no timeout; a return with neither POLLIN nor POLLPRI
 * ends that wait without a new one. Here capped at 20 s so a hang ends. */
struct waiter {
	int fd, wake;
	pthread_t t;
	int done;		/* set (atomic) when the poll returned */
	int revents;
	bool woken;		/* by the eventfd, not the device */
	double t0, t_ret;
};

static void *wait_once(void *p)
{
	struct waiter *w = p;
	struct pollfd pfd[2] = { { .fd = w->fd, .events = POLLIN | POLLPRI },
				 { .fd = w->wake, .events = POLLIN } };
	int r;

	do
		r = poll(pfd, 2, 20000);
	while (r < 0 && errno == EINTR);
	w->revents = r > 0 ? pfd[0].revents : 0;
	w->woken = r > 0 && (pfd[1].revents & POLLIN);
	w->t_ret = now_ms();
	__atomic_store_n(&w->done, 1, __ATOMIC_RELEASE);
	return NULL;
}

/* True when the wait returned within `ms` from `from`. */
static bool waiter_back(struct waiter *w, double from, double ms)
{
	while (!__atomic_load_n(&w->done, __ATOMIC_ACQUIRE)) {
		if (now_ms() - from >= ms)
			return false;
		usleep(2000);
	}
	return true;
}

/* Every CAPTURE buffer is with the app, OUTPUT is drained, the decoder owes
 * the LAST buffer: one wait from a second thread, then this round's action.
 * Wake: the held buffers go back (`held`, cleared); the main loop then
 * dequeues the rest and times the LAST from res->last_ms's start (*t_act). */
static void hold_check(struct result *res, bool *held, double *t_act)
{
	struct waiter w = { .fd = vfd };
	int out_type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE, cap_type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	double limit = hold_sub == H_DAEMON ? 15000 : 1000;
	pid_t stopped = 0;
	uint64_t one = 1;

	res->hold = true;
	res->after_ms = -1;
	w.wake = eventfd(0, EFD_CLOEXEC);
	if (w.wake < 0)
		die("eventfd");
	w.t0 = now_ms();
	if (pthread_create(&w.t, NULL, wait_once, &w))
		die("pthread_create");
	res->blocked = !waiter_back(&w, w.t0, 500);
	*t_act = now_ms();
	switch (hold_sub) {
	case H_WAKE:
		for (int i = 0; i < ncap; i++)
			if (held[i]) {
				held[i] = false;
				if (!cap_queue(i))
					res->failed = true;
			}
		break;
	case H_STREAMOFF:
		if (xioctl(VIDIOC_STREAMOFF, &out_type) || xioctl(VIDIOC_STREAMOFF, &cap_type))
			die("STREAMOFF (held)");
		cap_in = 0;
		break;
	case H_DAEMON:
		stopped = daemon_pid();
		if (stopped <= 0 || kill(stopped, SIGSTOP))
			die("SIGSTOP omacvm-vdecd");
		break;
	}
	if (res->blocked && waiter_back(&w, *t_act, limit))
		res->after_ms = w.t_ret - *t_act;
	if (stopped)
		kill(stopped, SIGCONT);	/* when the watchdog has not killed it */
	if (!__atomic_load_n(&w.done, __ATOMIC_ACQUIRE) && write(w.wake, &one, sizeof(one)) < 0)
		die("eventfd write");
	pthread_join(w.t, NULL);
	close(w.wake);
	res->revents = w.woken ? -1 : w.revents;
	res->poll_ms = w.t_ret - w.t0;
	if (getenv("VDEC_TEST_DEBUG"))
		fprintf(stderr, "hold: blocked %d revents 0x%x poll %.0f ms after %.0f ms\n", res->blocked,
			w.revents, res->poll_ms, res->after_ms);
}

static double psnr_rgb(const uint8_t *a, const uint8_t *b, int w, int h, int bstride)
{
	double se = 0;

	for (int y = 0; y < h; y++)
		for (int x = 0; x < w; x++)
			for (int c = 0; c < 3; c++) {
				int d = a[((size_t)y * w + x) * 4 + c] - b[(size_t)y * bstride + x * 4 + c];

				se += d * d;
			}
	se /= (double)w * h * 3;
	return se == 0 ? 99 : 10 * log10(255.0 * 255.0 / se);
}

/* Software pictures by timestamp, kept until the driver's picture comes. */
#define NREF 64
static AVFrame *refs[NREF];

static void ref_keep(AVFrame *f)
{
	for (int i = 0; i < NREF; i++)
		if (!refs[i]) {
			refs[i] = f;
			return;
		}
	av_frame_free(&f);
}

static AVFrame *ref_take(int64_t ts)
{
	for (int i = 0; i < NREF; i++)
		if (refs[i] && refs[i]->pts == ts) {
			AVFrame *f = refs[i];

			refs[i] = NULL;
			return f;
		}
	return NULL;
}

static void refs_clear(void)
{
	for (int i = 0; i < NREF; i++)
		av_frame_free(&refs[i]);
}

static void compare(struct ref *r, struct result *res, int idx, int64_t ts)
{
	AVFrame *sf = ref_take(ts);
	static uint8_t *px;
	uint8_t *rgb[1];
	int stride[1];

	if (!sf) {
		res->errors++;
		fprintf(stderr, "vdec-test: no software picture for timestamp %lld\n", (long long)ts);
		return;
	}
	if (sf->width != vis_w || sf->height != vis_h) {
		res->errors++;
		fprintf(stderr, "vdec-test: picture %dx%d, software %dx%d\n", vis_w, vis_h, sf->width, sf->height);
		av_frame_free(&sf);
		return;
	}
	px = realloc(px, (size_t)vis_w * vis_h * 4);
	glBindFramebuffer(GL_FRAMEBUFFER, caps[idx].fbo);
	glReadPixels(0, 0, vis_w, vis_h, GL_RGBA, GL_UNSIGNED_BYTE, px);
	for (size_t i = 0; i < (size_t)vis_w * vis_h * 4; i++)
		res->hash = (res->hash ^ px[i]) * 0x100000001b3ull;
	r->sws = sws_getCachedContext(r->sws, sf->width, sf->height, sf->format, sf->width, sf->height,
				      AV_PIX_FMT_RGBA, SWS_BILINEAR | SWS_ACCURATE_RND | SWS_FULL_CHR_H_INT,
				      NULL, NULL, NULL);
	{
		int cs = sf->colorspace == AVCOL_SPC_BT470BG || sf->colorspace == AVCOL_SPC_SMPTE170M ? SWS_CS_ITU601 :
			 sf->colorspace == AVCOL_SPC_BT709 || sf->height >= 720 ? SWS_CS_ITU709 : SWS_CS_ITU601;
		const int *coef = sws_getCoefficients(cs);

		sws_setColorspaceDetails(r->sws, coef, sf->color_range == AVCOL_RANGE_JPEG, coef, 1, 0, 1 << 16, 1 << 16);
	}
	stride[0] = sf->width * 4;
	rgb[0] = malloc((size_t)stride[0] * sf->height);
	sws_scale(r->sws, (const uint8_t *const *)sf->data, sf->linesize, 0, sf->height, rgb, stride);
	double p = psnr_rgb(px, rgb[0], vis_w, vis_h, stride[0]);

	if (p < res->min_psnr)
		res->min_psnr = p;
	free(rgb[0]);
	av_frame_free(&sf);
}

/* Feeds the software decoder too, so both see the same packets. */
static void ref_decode(struct ref *r, AVPacket *p)
{
	AVFrame *f = av_frame_alloc();

	avcodec_send_packet(r->cc, p);
	while (avcodec_receive_frame(r->cc, f) == 0) {
		ref_keep(f);	/* by pts, as the driver copies it */
		f = av_frame_alloc();
	}
	av_frame_free(&f);
}

static void run(const char *path, struct result *res, int stop_after)
{
	struct ref r;
	struct v4l2_format f = { .type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE };
	struct v4l2_requestbuffers rb = { .count = NOUT, .type = f.type, .memory = V4L2_MEMORY_MMAP };
	struct v4l2_event_subscription sub = { .type = V4L2_EVENT_SOURCE_CHANGE };
	void *out_map[NOUT];
	bool out_free[NOUT];
	int out_type = f.type, cap_type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	int64_t n = 0, seek_at, last_ts = -1, skip_below = -1, epoch = 0;
	AVRational tb;
	bool fed_all = false, stopped = false, sizing = false;
	AVPacket *pending = NULL;
	pid_t stalled = 0;
	double t_fail = 0;
	bool busy = false;
	int wait_ms = mode == STALL ? 15000 : 5000;
	/* --hold-all-at-eos: CAPTURE buffers held near the end; one goes back
	 * only while OUTPUT still waits for the daemon, so at most one is queued
	 * when OUTPUT is drained and the LAST is still owed then. */
	bool held[NCAP] = { false }, hold_done = false;
	int64_t n_run = 0, nb;
	double t_act = 0;

	memset(res, 0, sizeof(*res));
	res->min_psnr = 99;
	res->hash = 0xcbf29ce484222325ull;
	ref_open(&r, path);
	nb = r.fc->streams[r.stream]->nb_frames;
	seek_at = nb > 40 ? 30 : -1;
	if (mode == HOLD_EOS && nb <= 0)
		nb = count_packets(path, r.stream);	/* WebM has no count */
	tb = r.fc->streams[r.stream]->time_base;

	f.fmt.pix_mp.pixelformat = r.cc->codec_id == AV_CODEC_ID_H264 ? V4L2_PIX_FMT_H264 :
				   r.cc->codec_id == AV_CODEC_ID_VP9 ? V4L2_PIX_FMT_VP9 : V4L2_PIX_FMT_HEVC;
	f.fmt.pix_mp.width = r.cc->width;
	f.fmt.pix_mp.height = r.cc->height;
	f.fmt.pix_mp.num_planes = 1;
	/* 2 MB as Chromium asks for HD; VDEC_TEST_OUTPUT_MB for streams with bigger packets. */
	f.fmt.pix_mp.plane_fmt[0].sizeimage = (getenv("VDEC_TEST_OUTPUT_MB") ?
					       atoi(getenv("VDEC_TEST_OUTPUT_MB")) : 2) << 20;
	if (xioctl(VIDIOC_S_FMT, &f) || xioctl(VIDIOC_SUBSCRIBE_EVENT, &sub))
		die("S_FMT OUTPUT / subscribe");
	sub.type = V4L2_EVENT_EOS;
	if (xioctl(VIDIOC_SUBSCRIBE_EVENT, &sub) || xioctl(VIDIOC_REQBUFS, &rb) || rb.count < NOUT)
		die("subscribe EOS / REQBUFS OUTPUT");
	for (int i = 0; i < NOUT; i++) {
		struct v4l2_plane pl[1];
		struct v4l2_buffer b = { .type = out_type, .memory = V4L2_MEMORY_MMAP, .index = i,
					 .length = 1, .m.planes = pl };

		if (xioctl(VIDIOC_QUERYBUF, &b))
			die("QUERYBUF");
		out_map[i] = mmap(NULL, pl[0].length, PROT_READ | PROT_WRITE, MAP_SHARED, vfd, pl[0].m.mem_offset);
		if (out_map[i] == MAP_FAILED)
			die("mmap OUTPUT");
		out_free[i] = true;
	}
	if (xioctl(VIDIOC_STREAMON, &out_type))
		die("STREAMON OUTPUT");
	if (mode == EARLY_DRAIN)
		res->early_eos = early_drain();
	if (mode == EXPECT_FAIL)
		t_fail = now_ms();
	if (mode == FLOOD) {
		struct v4l2_decoder_cmd dc = { .cmd = V4L2_DEC_CMD_STOP };
		pid_t pid = daemon_pid();

		if (pid <= 0 || kill(pid, SIGSTOP))
			die("SIGSTOP omacvm-vdecd");
		t_fail = now_ms();
		for (int k = 0; k < 1000; k++)
			xioctl(VIDIOC_DECODER_CMD, &dc);
		kill(pid, SIGCONT);
	}

	for (int guard = 0; guard < 200000 && !res->failed; guard++) {
		struct pollfd pfd = { .fd = vfd, .events = POLLIN | POLLOUT | POLLPRI };
		struct v4l2_event ev;
		struct v4l2_plane pl[1];
		struct v4l2_buffer b;

		/* Feed one frame per free OUTPUT buffer. */
		for (int i = 0; i < NOUT && !fed_all; i++) {
			if (!out_free[i])
				continue;
			if (!pending)
				pending = ref_packet(&r);
			if (!pending) {
				fed_all = true;
				break;
			}
			if (n == seek_at) {	/* seek: drop what is queued, start over */
				if (xioctl(VIDIOC_STREAMOFF, &out_type) || xioctl(VIDIOC_STREAMON, &out_type))
					die("seek (STREAMOFF/STREAMON OUTPUT)");
				for (int k = 0; k < NOUT; k++)
					out_free[k] = true;
				av_packet_free(&pending);
				av_seek_frame(r.fc, r.stream, 0, AVSEEK_FLAG_BACKWARD);
				if (r.bsf)
					av_bsf_flush(r.bsf);
				avcodec_flush_buffers(r.cc);
				refs_clear();
				res->seeks++;
				seek_at = -1;
				n_run = 0;
				/* New timestamps after the seek (1000 s on): pictures
				 * decoded before it may still come out. */
				epoch += 1000000000;
				skip_below = epoch * 1000;
				last_ts = -1;
				i = -1;		/* feed again from the first buffer */
				continue;
			}
			memset(&b, 0, sizeof(b));
			memset(pl, 0, sizeof(pl));
			b.type = out_type;
			b.memory = V4L2_MEMORY_MMAP;
			b.index = i;
			b.length = 1;
			b.m.planes = pl;
			/* Presentation time in us, as Chromium passes it. */
			int64_t us = epoch + av_rescale_q(pending->pts == AV_NOPTS_VALUE ? n : pending->pts,
							  tb, (AVRational){ 1, 1000000 });

			b.timestamp.tv_sec = us / 1000000;
			b.timestamp.tv_usec = us % 1000000;
			pl[0].bytesused = pending->size;
			if ((uint32_t)pending->size > f.fmt.pix_mp.plane_fmt[0].sizeimage)
				die("a packet is bigger than the OUTPUT buffers (VDEC_TEST_OUTPUT_MB)");
			memcpy(out_map[i], pending->data, pending->size);
			pending->pts = us * 1000;	/* the driver's ns */
			ref_decode(&r, pending);
			if (xioctl(VIDIOC_QBUF, &b)) {
				res->failed = true;	/* the decoder failed */
				break;
			}
			out_free[i] = false;
			av_packet_free(&pending);
			n++;
			n_run++;
			if (stop_after && n == stop_after) {	/* --churn: left busy */
				busy = true;
				goto out;
			}
		}
		if (res->failed)
			break;
		if (fed_all && !stopped && ncap) {
			struct v4l2_decoder_cmd dc = { .cmd = V4L2_DEC_CMD_STOP };

			ref_decode(&r, NULL);
			if (xioctl(VIDIOC_DECODER_CMD, &dc))
				die("DEC_CMD_STOP");
			stopped = true;
		}

		if (poll(&pfd, 1, wait_ms) <= 0) {
			fprintf(stderr, "vdec-test: no progress for %d s\n", wait_ms / 1000);
			res->errors++;
			res->timeout = true;
			break;
		}
		if (pfd.revents & POLLPRI) {
			while (xioctl(VIDIOC_DQEVENT, &ev) == 0) {
				if (getenv("VDEC_TEST_DEBUG"))
					fprintf(stderr, "event %u (frames %d)\n", ev.type, res->frames);
				if (ev.type == V4L2_EVENT_EOS)
					res->eos = true;
				if (ev.type == V4L2_EVENT_SOURCE_CHANGE) {
					res->sizes++;
					if (ncap)
						sizing = true;	/* after the LAST buffer */
					else if (!cap_setup())
						res->failed = true;
				}
			}
		}
		memset(&b, 0, sizeof(b));
		b.type = out_type;
		b.memory = V4L2_MEMORY_MMAP;
		b.length = 1;
		b.m.planes = pl;
		while (xioctl(VIDIOC_DQBUF, &b) == 0) {
			out_free[b.index] = true;
			if (b.flags & V4L2_BUF_FLAG_ERROR)
				res->failed = true;
		}
		b.type = cap_type;
		/* Near the end: fed (or the last NCAP + 26 packets of a known count) after the seek. */
		bool holding = mode == HOLD_EOS && !hold_done && seek_at < 0 &&
			       (fed_all || (nb > 0 && n_run >= nb - (NCAP + 26)));

		while (ncap && xioctl(VIDIOC_DQBUF, &b) == 0) {
			cap_in--;
			if (b.flags & V4L2_BUF_FLAG_ERROR) {
				res->errors++;
				res->failed = true;
			} else if (b.m.planes[0].bytesused) {
				int64_t ts = ((int64_t)b.timestamp.tv_sec * 1000000 + b.timestamp.tv_usec) * 1000;

				if (ts >= skip_below) {
					if (ts <= last_ts)
						res->errors++;	/* display order */
					last_ts = ts;
					compare(&r, res, b.index, ts);
					res->frames++;
					if (t_act)
						res->after_frames++;
					if (mode == STALL && res->frames == 20 && !stalled) {
						stalled = daemon_pid();
						if (stalled <= 0 || kill(stalled, SIGSTOP))
							die("SIGSTOP omacvm-vdecd");
						t_fail = now_ms();
					}
				}
			}
			if (b.flags & V4L2_BUF_FLAG_LAST) {
				/* As the V4L2 decoder spec says: a LAST buffer can come before
				 * we read the SOURCE_CHANGE event that goes with it. */
				while (xioctl(VIDIOC_DQEVENT, &ev) == 0) {
					if (ev.type == V4L2_EVENT_EOS)
						res->eos = true;
					if (ev.type == V4L2_EVENT_SOURCE_CHANGE) {
						res->sizes++;
						sizing = true;
					}
				}
				if (getenv("VDEC_TEST_DEBUG"))
					fprintf(stderr, "LAST (sizing %d, frames %d)\n", sizing, res->frames);
				if (sizing) {	/* a new size: new buffers */
					if (xioctl(VIDIOC_STREAMOFF, &cap_type))
						die("STREAMOFF CAPTURE");
					cap_release();
					if (!cap_setup())
						res->failed = true;
					sizing = false;
					break;
				}
				res->drained = true;
				if (t_act)
					res->last_ms = now_ms() - t_act;
				break;
			}
			if (holding && b.index < NCAP) {
				held[b.index] = true;
				continue;
			}
			if (!cap_queue(b.index)) {
				res->failed = true;
				break;
			}
		}
		if (holding && !res->drained && !res->failed) {
			int outq = 0;

			for (int i = 0; i < NOUT; i++)
				outq += !out_free[i];
			if (stopped && !outq && !cap_in) {
				/* The held state: nothing queued, LAST owed. */
				hold_check(res, held, &t_act);
				hold_done = true;
				if (hold_sub != H_WAKE)
					break;
			} else if (outq && !cap_in) {
				for (int i = 0; i < ncap; i++)
					if (held[i]) {
						held[i] = false;
						if (!cap_queue(i))
							res->failed = true;
						break;
					}
			}
		}
		if (res->drained && res->eos)
			break;
	}
	if (mode == HOLD_EOS)
		for (int i = 0; i < NREF; i++)
			res->missing += refs[i] && refs[i]->pts >= skip_below;
	if (res->failed && t_fail)
		res->fail_ms = now_ms() - t_fail;
	if (stalled)
		kill(stalled, SIGCONT);	/* when the watchdog has not killed it */
out:
	if (busy) {	/* closing the fd does the rest, in the driver */
		for (int i = 0; i < ncap; i++) {
			glDeleteFramebuffers(1, &caps[i].fbo);
			glDeleteTextures(1, &caps[i].tex);
			destroy_image(egl, caps[i].img);
			close(caps[i].fd);
		}
		ncap = 0;
		cap_in = 0;
	} else {
		xioctl(VIDIOC_STREAMOFF, &out_type);
		xioctl(VIDIOC_STREAMOFF, &cap_type);
		cap_release();
		rb.count = 0;
		xioctl(VIDIOC_REQBUFS, &rb);
	}
	refs_clear();
	for (int i = 0; i < NOUT; i++)
		munmap(out_map[i], f.fmt.pix_mp.plane_fmt[0].sizeimage);
	sws_freeContext(r.sws);
	av_bsf_free(&r.bsf);
	avcodec_free_context(&r.cc);
	avformat_close_input(&r.fc);
}

static int find_device(void)
{
	char path[32];

	for (int i = 0; i < 64; i++) {
		struct v4l2_capability c;
		int fd;

		snprintf(path, sizeof(path), "/dev/video%d", i);
		fd = open(path, O_RDWR | O_NONBLOCK | O_CLOEXEC);
		if (fd < 0)
			continue;
		if (ioctl(fd, VIDIOC_QUERYCAP, &c) == 0 && !strcmp((char *)c.driver, "omacvm-vdec"))
			return fd;
		close(fd);
	}
	return -1;
}

/* The device opens again (the daemon is back), within `ms`. */
static int wait_device(int ms)
{
	double t0 = now_ms();
	int fd;

	while ((fd = find_device()) < 0 && now_ms() - t0 < ms)
		usleep(200000);
	return fd;
}

static void *close_fd(void *fd)
{
	close((int)(intptr_t)fd);
	return NULL;
}

/* --hold-all-at-eos: the held state reached and the poll asleep in it, then
 * the round's end in time (and, for wake, every picture right). */
static bool hold_ok(const struct result *res)
{
	if (!res->hold || !res->blocked || res->after_ms < 0)
		return false;
	switch (hold_sub) {
	case H_WAKE:
		return res->revents > 0 && (res->revents & POLLIN) && res->after_ms <= 1000 &&
		       res->drained && res->eos && res->last_ms <= 1000 && !res->missing &&
		       res->frames > 0 && !res->errors && res->min_psnr >= MIN_PSNR;
	case H_STREAMOFF:
		return res->revents > 0 && res->after_ms <= 1000;
	case H_DAEMON:
		return res->revents > 0 && (res->revents & POLLERR) && res->after_ms <= 15000;
	}
	return false;
}

static bool result_ok(const struct result *res)
{
	switch (mode) {
	case EXPECT_FAIL:
	case FLOOD:
		return res->failed && !res->timeout && res->fail_ms < 5000;
	case EARLY_DRAIN:
		if (!res->early_eos)
			return false;
		break;
	default:
		break;
	}
	return res->frames > 0 && !res->errors && res->min_psnr >= MIN_PSNR && res->drained && res->eos;
}

static void print(const char *file, const char *what, const struct result *res, bool ok)
{
	printf("{\"file\": \"%s\", \"test\": \"%s\", \"ok\": %s, \"frames\": %d, \"min_psnr_rgb\": %.1f, "
	       "\"sizes\": %d, \"seeks\": %d, \"drained\": %s, \"eos\": %s, \"errors\": %d, \"failed\": %s, "
	       "\"timeout\": %s, \"fail_ms\": %.0f, \"pictures\": \"%016llx\"}\n", file, what, ok ? "true" : "false", res->frames,
	       res->min_psnr, res->sizes, res->seeks, res->drained ? "true" : "false",
	       res->eos ? "true" : "false", res->errors, res->failed ? "true" : "false",
	       res->timeout ? "true" : "false", res->fail_ms, (unsigned long long)res->hash);
	fflush(stdout);
}

static void print_hold(const char *file, const char *what, const struct result *res, bool ok)
{
	char ev[16];

	if (res->revents < 0)
		snprintf(ev, sizeof(ev), "none");
	else
		snprintf(ev, sizeof(ev), "0x%x", res->revents);
	printf("{\"file\": \"%s\", \"test\": \"%s\", \"ok\": %s, \"hold\": %s, \"blocked\": %s, "
	       "\"revents\": \"%s\", \"poll_ms\": %.0f, \"after_ms\": %.0f, \"last_ms\": %.0f, "
	       "\"after_frames\": %d, \"missing\": %d, \"frames\": %d, \"min_psnr_rgb\": %.1f, \"seeks\": %d, "
	       "\"drained\": %s, \"eos\": %s, \"errors\": %d, \"failed\": %s, \"pictures\": \"%016llx\"}\n",
	       file, what, ok ? "true" : "false", res->hold ? "true" : "false", res->blocked ? "true" : "false", ev,
	       res->poll_ms, res->after_ms, res->last_ms, res->after_frames, res->missing, res->frames,
	       res->min_psnr, res->seeks, res->drained ? "true" : "false", res->eos ? "true" : "false",
	       res->errors, res->failed ? "true" : "false", (unsigned long long)res->hash);
	fflush(stdout);
}

static int test_file(const char *file)
{
	static const char *names[] = { "decode", "early-drain", "churn", "expect-fail", "stall", "flood" };
	static const char *rounds[] = { "hold-all-at-eos/wake", "hold-all-at-eos/streamoff",
					 "hold-all-at-eos/daemon-gone" };
	struct result res;
	bool ok;

	vfd = wait_device(mode == NORMAL ? 0 : 15000);
	if (vfd < 0) {
		fprintf(stderr, "vdec-test: no omacvm-vdec device (module loaded, omacvm-vdecd running?)\n");
		exit(1);
	}
	if (mode == CHURN) {
		/* A busy decoder closes in another thread while the next opens:
		 * the next one must not get the old one's id, state or answers. */
		for (int round = 0; round < 5; round++) {
			pthread_t t;
			int busy;

			run(file, &res, 6);	/* 6 packets queued, nothing waited for */
			busy = vfd;
			pthread_create(&t, NULL, close_fd, (void *)(intptr_t)busy);
			vfd = find_device();
			pthread_join(t, NULL);
			if (vfd < 0)
				vfd = wait_device(2000);
			if (vfd < 0) {
				fprintf(stderr, "vdec-test: no device after a close\n");
				exit(1);
			}
		}
	}
	if (mode == HOLD_EOS) {
		int bad = 0;

		for (int s = H_WAKE; s <= H_DAEMON; s++) {
			hold_sub = s;
			if (s != H_WAKE && (vfd = wait_device(15000)) < 0) {
				fprintf(stderr, "vdec-test: no device for %s\n", rounds[s]);
				return 1;
			}
			run(file, &res, 0);
			close(vfd);
			ok = hold_ok(&res);
			print_hold(file, rounds[s], &res, ok);
			bad += !ok;
		}
		/* The daemon systemd starts again serves the next file. */
		if ((vfd = wait_device(15000)) >= 0)
			close(vfd);
		return bad != 0;
	}
	run(file, &res, 0);
	close(vfd);
	ok = result_ok(&res);
	if (mode == STALL) {
		/* The stalled daemon is gone; its successor decodes the file. */
		struct result again;
		bool stall_ok = res.failed && !res.timeout && res.fail_ms < 15000;

		print(file, "stall", &res, stall_ok);
		vfd = wait_device(15000);
		if (vfd < 0) {
			fprintf(stderr, "vdec-test: no device 15 s after the stall\n");
			return 1;
		}
		mode = NORMAL;
		run(file, &again, 0);
		close(vfd);
		mode = STALL;
		ok = result_ok(&again);
		print(file, "after-stall", &again, ok);
		return !(ok && stall_ok);
	}
	print(file, names[mode], &res, ok);
	return !ok;
}

int main(int argc, char **argv)
{
	int fails = 0, i = 1;

	if (argc > 1 && argv[1][0] == '-') {
		if (!strcmp(argv[1], "--early-drain"))
			mode = EARLY_DRAIN;
		else if (!strcmp(argv[1], "--churn"))
			mode = CHURN;
		else if (!strcmp(argv[1], "--expect-fail"))
			mode = EXPECT_FAIL;
		else if (!strcmp(argv[1], "--stall"))
			mode = STALL;
		else if (!strcmp(argv[1], "--flood"))
			mode = FLOOD;
		else if (!strcmp(argv[1], "--hold-all-at-eos"))
			mode = HOLD_EOS;
		else
			argc = 0;
		i = 2;
	}
	if (argc <= i) {
		fprintf(stderr, "usage: vdec-test [--early-drain|--churn|--expect-fail|--stall|--flood|"
			"--hold-all-at-eos] FILE...\n");
		return 2;
	}
	egl_init();
	for (; i < argc; i++)
		fails += test_file(argv[i]);
	return fails ? 1 : 0;
}
