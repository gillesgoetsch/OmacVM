// SPDX-License-Identifier: MIT
/*
 * refused-test.c: vdecd-refused.h's rule, one row per sequence of FFmpeg's
 * answers. Run by src/tests/vdecd-refused.sh. Exit 0 when every row holds;
 * every difference is printed.
 */
#include <stdio.h>
#include <string.h>

#include "vdecd-refused.h"

/* One answer: an error of FFmpeg's, a decoded picture (PIC) or a START. */
#define PIC 1
#define START 2

struct row {
	const char *what;
	int seq[16];
	int n;
	int fail_at;		/* index of the answer that fails the video, -1: never */
};

static const struct row rows[] = {
	{ "3 refusals before a picture: fail at the third",
	  { AVERROR(EIO), AVERROR(EIO), AVERROR(EIO) }, 3, 2 },
	{ "2 refusals: not yet",
	  { AVERROR(EIO), AVERROR(EIO) }, 2, -1 },
	{ "SPS and PPS alone (no frame) do not count",
	  { AVERROR_INVALIDDATA, AVERROR_INVALIDDATA, AVERROR_INVALIDDATA, AVERROR_INVALIDDATA,
	    AVERROR_INVALIDDATA, AVERROR_INVALIDDATA, AVERROR_INVALIDDATA, AVERROR_INVALIDDATA,
	    AVERROR_INVALIDDATA, AVERROR_INVALIDDATA }, 10, -1 },
	{ "SPS, PPS, then 3 refused pictures: fail at the third",
	  { AVERROR_INVALIDDATA, AVERROR_INVALIDDATA, AVERROR(EIO), AVERROR(EIO), AVERROR(EIO) }, 5, 4 },
	{ "EAGAIN and EOF do not count",
	  { AVERROR(EAGAIN), AVERROR_EOF, AVERROR(EAGAIN), AVERROR_EOF, AVERROR(EAGAIN) }, 5, -1 },
	{ "a picture, then refusals: lost pictures, as before",
	  { PIC, AVERROR(EIO), AVERROR(EIO), AVERROR(EIO), AVERROR(EIO), AVERROR(EIO),
	    AVERROR(EIO), AVERROR(EIO), AVERROR(EIO), AVERROR(EIO), AVERROR(EIO) }, 11, -1 },
	{ "2 refusals, a picture, 2 refusals: never",
	  { AVERROR(EIO), AVERROR(EIO), PIC, AVERROR(EIO), AVERROR(EIO) }, 5, -1 },
	{ "a picture, START (a new track), 3 refusals: fail",
	  { PIC, START, AVERROR(EIO), AVERROR(EIO), AVERROR(EIO) }, 5, 4 },
	{ "2 refusals, START, 2 refusals: not yet (counted from START)",
	  { AVERROR(EIO), AVERROR(EIO), START, AVERROR(EIO), AVERROR(EIO) }, 5, -1 },
};

int main(void)
{
	int bad = 0;

	for (size_t i = 0; i < sizeof(rows) / sizeof(rows[0]); i++) {
		const struct row *row = &rows[i];
		struct vdecd_refused r;
		int got = -1;

		memset(&r, 0, sizeof(r));	/* a new instance (calloc) */
		vdecd_refused_start(&r);
		for (int k = 0; k < row->n && got < 0; k++) {
			if (row->seq[k] == PIC)
				vdecd_refused_picture(&r);
			else if (row->seq[k] == START)
				vdecd_refused_start(&r);
			else if (vdecd_refused_error(&r, row->seq[k]))
				got = k;
		}
		if (got == row->fail_at) {
			printf("ok   %s\n", row->what);
		} else {
			printf("FAIL %s: want the fail at %d, got %d\n", row->what, row->fail_at, got);
			bad = 1;
		}
	}
	return bad;
}
