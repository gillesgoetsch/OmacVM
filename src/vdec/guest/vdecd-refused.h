// SPDX-License-Identifier: MIT
/*
 * vdecd-refused.h: omacvm-vdecd fails a video whose first pictures VA-API
 * refuses. Included by omacvm-vdecd.c; src/tests/vdecd-refused.sh runs it.
 *
 * VA-API in an OmacVM.app VM refuses some pictures it cannot decode right:
 * H.264 coded interlaced (field pictures, MBAFF frames; the VA shim, see
 * AGENTS section 8). FFmpeg then returns AVERROR(EIO) for each of them and no
 * picture comes out. Chromium's V4L2 decoder waits for the first picture
 * with no error and shows nothing; it falls back to its own decoder on the
 * CPU only for a decode error before its first picture. So after
 * VDECD_REFUSED_MAX refusals before the first picture the daemon fails the
 * video. Only AVERROR(EIO) counts: Chromium sends the SPS and the PPS in
 * buffers of their own, which give AVERROR_INVALIDDATA ("no frame"). Once a
 * picture came out, a refusal is a lost picture as before (failing then
 * would be a playback error). Per decoder instance, from its START: Chromium
 * starts again on the same device for a new track and may fall back again
 * then; a seek closes the device and opens a new instance.
 */
#ifndef VDECD_REFUSED_H
#define VDECD_REFUSED_H

#include <errno.h>
#include <stdbool.h>
#include <libavutil/error.h>

#define VDECD_REFUSED_MAX 3u

struct vdecd_refused {
	bool decoded;		/* a picture came out since START */
	unsigned count;		/* refusals before it */
};

/* OVD_MSG_START: a new stream on this instance. */
static inline void vdecd_refused_start(struct vdecd_refused *r)
{
	r->decoded = false;
	r->count = 0;
}

/* A decoded picture came out. */
static inline void vdecd_refused_picture(struct vdecd_refused *r)
{
	r->decoded = true;
}

/* An error of avcodec_send_packet or avcodec_receive_frame. true: fail the
 * video now (the caller lets the decode loop end first). */
static inline bool vdecd_refused_error(struct vdecd_refused *r, int err)
{
	if (r->decoded || err != AVERROR(EIO))
		return false;
	return ++r->count >= VDECD_REFUSED_MAX;
}

#endif
