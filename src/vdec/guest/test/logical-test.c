// SPDX-License-Identifier: MIT
/*
 * logical-test.c: vdecd-logical.h against a stand-in for the kernel's ioctls
 * (this file's ioctl). Run by src/tests/vdecd-logical.sh, one case per run
 * (the header decides "on" once per process):
 *   logical-test on              prints 1 or 0 (vdecd_logical_on)
 *   logical-test CASE            odd | odd-rows | even | refused-info | refused-exec
 * Exit 0 when the case holds; every difference is printed.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "vdecd-logical.h"

static int fail_info, fail_exec, n_info, n_exec, fd_seen = -1;
static uint32_t words[512];
static unsigned n_words;

int ioctl(int fd, unsigned long req, ...)
{
	va_list ap;
	void *arg;

	va_start(ap, req);
	arg = va_arg(ap, void *);
	va_end(ap);
	fd_seen = fd;
	if (req == DRM_IOCTL_VIRTGPU_RESOURCE_INFO) {
		struct drm_virtgpu_resource_info *ri = arg;

		n_info++;
		if (fail_info) {
			errno = EACCES;
			return -1;
		}
		ri->res_handle = 1000 + ri->bo_handle;
		return 0;
	}
	if (req == DRM_IOCTL_VIRTGPU_EXECBUFFER) {
		struct drm_virtgpu_execbuffer *eb = arg;

		n_exec++;
		if (fail_exec) {
			errno = EACCES;
			return -1;
		}
		n_words = eb->size / 4 < 512 ? eb->size / 4 : 512;
		memcpy(words, (const void *)(uintptr_t)eb->command, n_words * 4);
		return 0;
	}
	errno = ENOTTY;
	return -1;
}

static int fails;

static void expect(const char *what, long want, long got)
{
	if (want != got) {
		printf("FAIL: %s: want %ld, got %ld\n", what, want, got);
		fails++;
	}
}

/* The NOPs for N buffers (handles 1..N) at W x H, 8 per NOP. */
static void expect_payload(unsigned n, uint32_t w, uint32_t h)
{
	unsigned c = 0;

	for (unsigned i = 0; i < n; i += 8) {
		unsigned k = n - i < 8 ? n - i : 8;
		char what[64];

		snprintf(what, sizeof(what), "NOP %u header", i / 8);
		expect(what, (long)((2 + 3 * k) << 16), c < n_words ? words[c] : -1), c++;
		expect("magic \"OMLS\"", 0x534c4d4f, c < n_words ? words[c] : -1), c++;
		expect("version", 1, c < n_words ? words[c] : -1), c++;
		for (unsigned j = 0; j < k; j++) {
			snprintf(what, sizeof(what), "buffer %u resource", i + j + 1);
			expect(what, 1000 + i + j + 1, c < n_words ? words[c] : -1), c++;
			expect("width", w, c < n_words ? words[c] : -1), c++;
			expect("height", h, c < n_words ? words[c] : -1), c++;
		}
	}
	expect("words in the submit", c, n_words);
}

int main(int argc, char **argv)
{
	uint32_t handles[24];
	const char *mode = argc > 1 ? argv[1] : "";
	const char *why = "";
	int r;

	for (unsigned i = 0; i < 24; i++)
		handles[i] = i + 1;
	if (!strcmp(mode, "on")) {
		printf("%d\n", vdecd_logical_on());
		return 0;
	}
	if (!strcmp(mode, "odd")) {	/* VP9 853x480 in 854x480 buffers, 10 of them */
		r = vdecd_logical_declare(7, handles, 10, 854, 480, 853, 480, &why);
		expect("result", 1, r);
		expect("RESOURCE_INFO calls", 10, n_info);
		expect("EXECBUFFER calls", 1, n_exec);
		expect("the buffers' own DRM file", 7, fd_seen);
		expect_payload(10, 853, 480);
	} else if (!strcmp(mode, "odd-rows")) {	/* 1001x563 in 1002x564, the module's most */
		r = vdecd_logical_declare(7, handles, 24, 1002, 564, 1001, 563, &why);
		expect("result", 1, r);
		expect("RESOURCE_INFO calls", 24, n_info);
		expect("EXECBUFFER calls", 1, n_exec);
		expect_payload(24, 1001, 563);
	} else if (!strcmp(mode, "even")) {	/* the buffers are the picture's size */
		r = vdecd_logical_declare(7, handles, 10, 854, 480, 854, 480, &why);
		expect("result", 0, r);
		expect("ioctl calls", 0, n_info + n_exec);
		r = vdecd_logical_declare(7, handles, 10, 854, 480, 855, 480, &why);
		expect("a picture larger than its buffer: result", 0, r);
		expect("a picture larger than its buffer: ioctl calls", 0, n_info + n_exec);
	} else if (!strcmp(mode, "refused-info")) {
		fail_info = 1;
		r = vdecd_logical_declare(7, handles, 10, 854, 480, 853, 480, &why);
		expect("result", -1, r);
		expect("EXECBUFFER calls", 0, n_exec);
		if (strcmp(why, "DRM_IOCTL_VIRTGPU_RESOURCE_INFO"))
			printf("FAIL: why: %s\n", why), fails++;
	} else if (!strcmp(mode, "refused-exec")) {
		fail_exec = 1;
		r = vdecd_logical_declare(7, handles, 10, 854, 480, 853, 480, &why);
		expect("result", -1, r);
		if (strcmp(why, "DRM_IOCTL_VIRTGPU_EXECBUFFER"))
			printf("FAIL: why: %s\n", why), fails++;
	} else if (!strcmp(mode, "off")) {	/* the runtime cannot (or the switch says no) */
		r = vdecd_logical_declare(7, handles, 10, 854, 480, 853, 480, &why);
		expect("result", 0, r);
		expect("ioctl calls", 0, n_info + n_exec);
	} else {
		fprintf(stderr, "usage: logical-test on|odd|odd-rows|even|refused-info|refused-exec|off\n");
		return 2;
	}
	return fails ? 1 : 0;
}
