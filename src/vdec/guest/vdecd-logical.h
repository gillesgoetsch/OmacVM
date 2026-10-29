// SPDX-License-Identifier: MIT
/*
 * vdecd-logical.h: omacvm-vdecd tells the Mac's runtime the size to sample its
 * CAPTURE buffers at. Included by omacvm-vdecd.c; src/tests/vdecd-logical.sh
 * runs it against a stand-in for the kernel's ioctls.
 *
 * The buffers are the picture's size rounded up to even (the module's step:
 * VP9 853x480 gets 854x480 buffers), and Chromium imports each frame at the
 * picture's own size (853x480). Mesa's virgl driver drops an import's size,
 * so the Mac sampled the whole buffer: an odd-size video came out squeezed by
 * its extra column (and row). A runtime that says OMACVM_VALOGICAL=1
 * (/run/omacvm/host.env) samples a texture at a size the guest gives: a NOP
 * with the "OMLS" payload of virgl-resource-logical-size.patch (version 1,
 * then up to 8 x resource, width, height), sent on the DRM file that made the
 * buffers (the Mac takes only its own context's resources). Buffers of the
 * picture's own size (even sizes, nearly every video) need nothing.
 * OMACVM_VA_LOGICAL=0 or 1 overrides, as for the VA shim.
 */
#ifndef VDECD_LOGICAL_H
#define VDECD_LOGICAL_H

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <drm/virtgpu_drm.h>

#define VDECD_LOGICAL_MAGIC 0x534c4d4fu	/* "OMLS" */
#define VDECD_LOGICAL_PER_NOP 8u
#define VDECD_LOGICAL_MAX 32u		/* buffers per call; the module allows 24 */

/* The runtime samples at the guest's sizes (decided once). */
static bool vdecd_logical_on(void)
{
	static int on = -1;

	if (on < 0) {
		const char *env = getenv("OMACVM_VA_LOGICAL");
		const char *path = getenv("OMACVM_HOST_ENV");	/* tests */
		char line[256];
		FILE *f;

		on = 0;
		if (env && *env) {
			on = *env == '1';
		} else if ((f = fopen(path && *path ? path : "/run/omacvm/host.env", "re"))) {
			while (!on && fgets(line, sizeof(line), f))
				on = !strcmp(line, "OMACVM_VALOGICAL=1\n");
			fclose(f);
		}
	}
	return on;
}

/* N buffers (GEM handles on FD) of BW x BH holding pictures of W x H: asks the
 * Mac to sample each at W x H. 1: sent; 0: nothing to send (the buffers are
 * the picture's size, or the runtime cannot); -1: an ioctl was refused (*WHY
 * names it), nothing sent. */
static int vdecd_logical_declare(int fd, const uint32_t *handles, unsigned n, uint32_t bw,
				 uint32_t bh, uint32_t w, uint32_t h, const char **why)
{
	uint32_t cmd[3 * ((VDECD_LOGICAL_MAX + VDECD_LOGICAL_PER_NOP - 1) / VDECD_LOGICAL_PER_NOP) +
		     3 * VDECD_LOGICAL_MAX];
	uint32_t res[VDECD_LOGICAL_MAX];
	struct drm_virtgpu_execbuffer eb = { .fence_fd = -1 };
	unsigned c = 0;

	if ((w == bw && h == bh) || !w || !h || w > bw || h > bh || !n || n > VDECD_LOGICAL_MAX ||
	    !vdecd_logical_on())
		return 0;
	for (unsigned i = 0; i < n; i++) {
		struct drm_virtgpu_resource_info ri = { .bo_handle = handles[i] };

		if (ioctl(fd, DRM_IOCTL_VIRTGPU_RESOURCE_INFO, &ri) || !ri.res_handle) {
			*why = "DRM_IOCTL_VIRTGPU_RESOURCE_INFO";
			return -1;
		}
		res[i] = ri.res_handle;
	}
	for (unsigned i = 0; i < n; i += VDECD_LOGICAL_PER_NOP) {
		unsigned k = n - i < VDECD_LOGICAL_PER_NOP ? n - i : VDECD_LOGICAL_PER_NOP;

		cmd[c++] = (2 + 3 * k) << 16;	/* VIRGL_CMD0(VIRGL_CCMD_NOP, 0, length) */
		cmd[c++] = VDECD_LOGICAL_MAGIC;
		cmd[c++] = 1;			/* version */
		for (unsigned j = 0; j < k; j++) {
			cmd[c++] = res[i + j];
			cmd[c++] = w;
			cmd[c++] = h;
		}
	}
	eb.size = c * 4;
	eb.command = (uintptr_t)cmd;
	if (ioctl(fd, DRM_IOCTL_VIRTGPU_EXECBUFFER, &eb)) {
		*why = "DRM_IOCTL_VIRTGPU_EXECBUFFER";
		return -1;
	}
	return 1;
}

#endif
