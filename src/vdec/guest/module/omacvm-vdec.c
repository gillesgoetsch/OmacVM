// SPDX-License-Identifier: GPL-2.0
/*
 * omacvm-vdec: a V4L2 stateful video decoder for Chromium in OmacVM.app VMs.
 *
 * Arch Linux ARM builds Chromium without VA-API; its only hardware decoder
 * path is V4L2. This module is that V4L2 device. It decodes nothing itself:
 * omacvm-vdecd (a daemon, /dev/omacvm-vdec) gets the bitstream, decodes it
 * with VA-API on the Mac's media engine and writes the pictures into the
 * CAPTURE buffers as ARGB. Those buffers are virtio-gpu buffers the daemon
 * made (GBM), so the compositor can import what EXPBUF hands out; buffers
 * this module allocated could not be imported by virtio-gpu.
 *
 * Without the daemon the device offers no formats and refuses opens, so
 * apps keep decoding on the CPU.
 *
 * Locking: inst->lock is the vb2 lock of both queues (and is taken by hand
 * in the other ioctls). inst->slock guards the buffer table, the capture
 * setup handshake and the closing flag, which the daemon touches from its
 * own ioctls. Buffers go back to vb2 (vb2_buffer_done, IRQ-safe) under
 * slock, so once stop_streaming has taken them back nothing the daemon does
 * completes one again. Events go to the app's fh under slock and only while
 * !closing: release sets closing before the fh goes. The daemon's ioctls
 * hold a kref, which keeps the struct, not the fh or the queues.
 * Bitstream is not copied here: the daemon's read() copies it straight out of
 * the app's OUTPUT buffer (the one copy on its way to the decoder). The read
 * checks under slock that the buffer is still queued and counts itself in
 * inst->copying; stop_streaming takes the buffers back first, then waits for
 * that count to drop, so vb2 never frees a buffer the daemon is reading.
 * dev->lock guards the instance table and the daemon's file; dev->msg_lock
 * the message list and dev->online. Order: dev->lock, then slock; inst->lock,
 * then slock; msg_lock innermost.
 */
#include <linux/dma-buf.h>
#include <linux/file.h>
#include <linux/idr.h>
#include <linux/kref.h>
#include <linux/miscdevice.h>
#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/poll.h>
#include <linux/slab.h>
#include <linux/uaccess.h>
#include <media/v4l2-ctrls.h>
#include <media/v4l2-device.h>
#include <media/v4l2-event.h>
#include <media/v4l2-ioctl.h>
#include <media/v4l2-mem2mem.h>
#include <media/videobuf2-v4l2.h>
#include <media/videobuf2-vmalloc.h>

#include "omacvm-vdec.h"

#define DRV "omacvm-vdec"
#define SETUP_TIMEOUT (5 * HZ)
#define MIN_SIZE OVD_MIN_SIZE
/* Each open decoder is a decode session on the Mac and up to 24 pinned
 * CAPTURE buffers in the VM: past this, apps decode on the CPU. */
#define MAX_INSTANCES 8
/* Unread messages per decoder. A normal stream has a few control messages
 * plus one per queued buffer; past this the daemon is stuck or the app loops
 * STREAMON/STREAMOFF or DEC_CMD_STOP, and the decoder fails. */
#define MAX_INST_MSGS 256

struct ovd_dev {
	struct platform_device *pdev;
	struct v4l2_device v4l2_dev;
	struct video_device vdev;
	struct v4l2_m2m_dev *m2m_dev;
	struct miscdevice misc;

	struct mutex lock;		/* insts, daemon, caps */
	struct idr insts;
	unsigned int ninsts;
	struct file *daemon;
	struct ovd_caps caps;

	spinlock_t msg_lock;
	struct list_head msgs;
	bool online;			/* a daemon reads the messages */
	wait_queue_head_t msg_wq;
};

struct ovd_inst;

struct ovd_kmsg {
	struct list_head list;
	struct ovd_msg hdr;
	const void *data;		/* BITSTREAM: the OUTPUT buffer, not ours */
	struct ovd_inst *inst;		/* holds a reference */
};

struct ovd_buf {
	struct v4l2_m2m_buffer m2m;	/* first: vb2_v4l2_buffer inside */
	u64 seq;
	bool queued;			/* with us (or the daemon) */
};

struct ovd_inst {
	struct v4l2_fh fh;
	struct ovd_dev *dev;
	struct kref ref;
	u32 id;
	struct mutex lock;		/* vb2 queues + format ioctls */
	struct v4l2_ctrl_handler hdl;
	atomic_t nmsgs;			/* unread by the daemon */
	atomic_t copying;		/* daemon reads out of an OUTPUT buffer */
	wait_queue_head_t copy_wq;

	u32 codec;			/* OUTPUT fourcc */
	u32 out_width, out_height, out_sizeimage;

	spinlock_t slock;
	bool dead;			/* daemon gone, or it failed this decoder */
	bool closing;			/* release runs: no more events to fh */
	bool cap_streaming;
	bool last_pending;		/* the next CAPTURE buffer goes back LAST */
	u64 seq;
	struct ovd_buf *out[VB2_MAX_FRAME];
	struct ovd_buf *cap[VB2_MAX_FRAME];

	/* capture format, set by the daemon */
	bool fmt_known;
	u32 width, height, vis_width, vis_height, stride, min_buffers;

	/* capture setup handshake (queue_setup waits for the daemon) */
	wait_queue_head_t setup_wq;
	int setup_state;		/* 0 idle, 1 waiting, 2 done, <0 error */
	u32 setup_count;
	struct dma_buf *setup_dbuf[OVD_MAX_CAPTURE];
};

struct ovd_mem {
	struct dma_buf *dbuf;
	refcount_t users;
};

static struct ovd_dev *ovd;

static const struct ovd_codec {
	u32 fourcc;
	u32 bit;
} ovd_codecs[] = {
	{ V4L2_PIX_FMT_H264, OVD_CODEC_H264 },
	{ V4L2_PIX_FMT_HEVC, OVD_CODEC_HEVC },
	{ V4L2_PIX_FMT_VP9, OVD_CODEC_VP9 },
};

static bool codec_offered(struct ovd_dev *dev, u32 fourcc)
{
	unsigned int i;

	for (i = 0; i < ARRAY_SIZE(ovd_codecs); i++)
		if (ovd_codecs[i].fourcc == fourcc)
			return dev->caps.codecs & ovd_codecs[i].bit;
	return false;
}

static inline struct ovd_inst *file2inst(struct file *file)
{
	return container_of(file_to_v4l2_fh(file), struct ovd_inst, fh);
}

static void setup_release(struct ovd_inst *inst)
{
	struct dma_buf *put[OVD_MAX_CAPTURE];
	unsigned int i, n = 0;

	spin_lock(&inst->slock);
	for (i = 0; i < OVD_MAX_CAPTURE; i++) {
		if (inst->setup_dbuf[i])
			put[n++] = inst->setup_dbuf[i];
		inst->setup_dbuf[i] = NULL;
	}
	spin_unlock(&inst->slock);
	while (n)
		dma_buf_put(put[--n]);
}

static void inst_free(struct kref *ref)
{
	struct ovd_inst *inst = container_of(ref, struct ovd_inst, ref);

	setup_release(inst);
	kfree(inst);
}

/* Back to the app (slock held): every buffer goes back exactly once. */
static void buf_give_back(struct ovd_buf *b, enum vb2_buffer_state state)
{
	if (!b || !b->queued)
		return;
	b->queued = false;
	vb2_buffer_done(&b->m2m.vb.vb2_buf, state);
}

/* Hands every buffer still queued back to the app, flagged ERROR, so it
 * sees a failed decode (and can fall back) instead of waiting forever. */
static void inst_fail_all(struct ovd_inst *inst)
{
	unsigned int i;

	spin_lock(&inst->slock);
	WRITE_ONCE(inst->dead, true);
	inst->last_pending = false;
	if (inst->setup_state == 1)
		inst->setup_state = -ENODEV;
	for (i = 0; i < VB2_MAX_FRAME; i++) {
		buf_give_back(inst->out[i], VB2_BUF_STATE_ERROR);
		buf_give_back(inst->cap[i], VB2_BUF_STATE_ERROR);
	}
	spin_unlock(&inst->slock);
	wake_up_interruptible(&inst->setup_wq);
	/* A poll asleep on a decoder with nothing queued (ovd_poll) gets no
	 * buffer back from the loop above: wake it, it then sees the failure. */
	wake_up_all(&inst->fh.wait);
}

/* ---- messages to the daemon ------------------------------------------- */

static void msg_free(struct ovd_kmsg *m)
{
	atomic_dec(&m->inst->nmsgs);
	kref_put(&m->inst->ref, inst_free);
	kfree(m);
}

static void msg_free_list(struct list_head *gone)
{
	struct ovd_kmsg *m, *n;

	list_for_each_entry_safe(m, n, gone, list)
		msg_free(m);
}

/*
 * Queues a message for the daemon. Dropped without a daemon, and for a
 * failed decoder (but its CLOSE). A decoder past MAX_INST_MSGS unread
 * messages fails: kernel memory stays bounded whatever the app does.
 */
static int msg_send(struct ovd_inst *inst, const struct ovd_msg *hdr, const void *data)
{
	struct ovd_dev *dev = inst->dev;
	bool close = hdr->type == OVD_MSG_CLOSE;
	struct ovd_kmsg *m;
	int ret = 0;

	if (!close && READ_ONCE(inst->dead))
		return -ENODEV;
	m = kzalloc(sizeof(*m), GFP_KERNEL);
	if (!m)
		return -ENOMEM;
	m->hdr = *hdr;
	m->data = data;
	m->inst = inst;
	spin_lock(&dev->msg_lock);
	if (!dev->online) {
		ret = -ENODEV;
	} else if (!close && atomic_read(&inst->nmsgs) >= MAX_INST_MSGS) {
		ret = -ENOSPC;
	} else {
		atomic_inc(&inst->nmsgs);
		kref_get(&inst->ref);
		list_add_tail(&m->list, &dev->msgs);
	}
	spin_unlock(&dev->msg_lock);
	if (ret) {
		kfree(m);
		if (ret == -ENOSPC) {
			dev_warn_ratelimited(&dev->pdev->dev,
					     "decoder %u: %u messages unread, failed\n",
					     inst->id, MAX_INST_MSGS);
			inst_fail_all(inst);
		}
		return ret;
	}
	wake_up_interruptible(&dev->msg_wq);
	return 0;
}

static int msg_simple(struct ovd_inst *inst, u32 type)
{
	struct ovd_msg hdr = { .type = type, .inst = inst->id };

	return msg_send(inst, &hdr, NULL);
}

/* Unread messages of one decoder (and type; and buffer index unless ~0)
 * move to `gone`, to be freed with msg_free_list outside the locks. */
static void msg_take(struct ovd_dev *dev, u32 inst, u32 type, u32 index,
		     struct list_head *gone)
{
	struct ovd_kmsg *m, *n;

	spin_lock(&dev->msg_lock);
	list_for_each_entry_safe(m, n, &dev->msgs, list)
		if (m->hdr.inst == inst && m->hdr.type == type &&
		    (index == ~0u || m->hdr.index == index))
			list_move(&m->list, gone);
	spin_unlock(&dev->msg_lock);
}

/* Bitstream not yet read by the daemon is dropped on a flush. */
static void msg_purge(struct ovd_dev *dev, u32 inst, u32 type)
{
	LIST_HEAD(gone);

	msg_take(dev, inst, type, ~0u, &gone);
	msg_free_list(&gone);
}

/* ---- CAPTURE memory: the daemon's dmabufs -------------------------------- */

static void *ovd_mem_alloc(struct vb2_buffer *vb, struct device *d,
			   unsigned long size)
{
	struct ovd_inst *inst = vb2_get_drv_priv(vb->vb2_queue);
	unsigned int idx = vb->index;
	struct ovd_mem *mem;
	struct dma_buf *dbuf;

	if (idx >= OVD_MAX_CAPTURE)
		return ERR_PTR(-EINVAL);
	spin_lock(&inst->slock);
	dbuf = inst->setup_dbuf[idx];
	inst->setup_dbuf[idx] = NULL;
	spin_unlock(&inst->slock);
	if (!dbuf)
		return ERR_PTR(-ENOMEM);
	if (dbuf->size < vb->planes[0].length) {
		dma_buf_put(dbuf);
		return ERR_PTR(-EINVAL);
	}
	mem = kzalloc(sizeof(*mem), GFP_KERNEL);
	if (!mem) {
		dma_buf_put(dbuf);
		return ERR_PTR(-ENOMEM);
	}
	mem->dbuf = dbuf;
	refcount_set(&mem->users, 1);
	return mem;
}

static void ovd_mem_put(void *priv)
{
	struct ovd_mem *mem = priv;

	if (!refcount_dec_and_test(&mem->users))
		return;
	dma_buf_put(mem->dbuf);
	kfree(mem);
}

static struct dma_buf *ovd_mem_get_dmabuf(struct vb2_buffer *vb, void *priv,
					  unsigned long flags)
{
	struct ovd_mem *mem = priv;

	get_dma_buf(mem->dbuf);
	return mem->dbuf;
}

static unsigned int ovd_mem_num_users(void *priv)
{
	struct ovd_mem *mem = priv;

	return refcount_read(&mem->users);
}

/* Maps the guest's copy only; the picture itself lives in the Mac's GPU. */
static int ovd_mem_mmap(void *priv, struct vm_area_struct *vma)
{
	struct ovd_mem *mem = priv;

	return dma_buf_mmap(mem->dbuf, vma, 0);
}

static void *ovd_mem_vaddr(struct vb2_buffer *vb, void *priv)
{
	return NULL;
}

static const struct vb2_mem_ops ovd_mem_ops = {
	.alloc = ovd_mem_alloc,
	.put = ovd_mem_put,
	.get_dmabuf = ovd_mem_get_dmabuf,
	.num_users = ovd_mem_num_users,
	.mmap = ovd_mem_mmap,
	.vaddr = ovd_mem_vaddr,
};

/* ---- vb2 queue ops ------------------------------------------------------- */

static int ovd_queue_setup(struct vb2_queue *q, unsigned int *nbuf,
			   unsigned int *nplanes, unsigned int sizes[],
			   struct device *alloc_devs[])
{
	struct ovd_inst *inst = vb2_get_drv_priv(q);
	struct ovd_msg hdr = { .type = OVD_MSG_CAPTURE_SETUP, .inst = inst->id };
	long left;
	int state;

	if (V4L2_TYPE_IS_OUTPUT(q->type)) {
		if (*nplanes)
			return sizes[0] < inst->out_sizeimage ? -EINVAL : 0;
		*nplanes = 1;
		sizes[0] = inst->out_sizeimage;
		return 0;
	}

	/* vb2 asks again after a partial allocation: keep what we have. CREATE_BUFS
	 * cannot work (buffers come in one set from the daemon): alloc fails. */
	if (*nplanes)
		return *nplanes == 1 ? 0 : -EINVAL;

	setup_release(inst);
	spin_lock(&inst->slock);
	if (inst->dead || !inst->fmt_known) {
		spin_unlock(&inst->slock);
		return inst->dead ? -ENODEV : -EINVAL;
	}
	*nbuf = clamp_t(unsigned int, *nbuf, 2, OVD_MAX_CAPTURE);
	*nplanes = 1;
	sizes[0] = inst->stride * inst->height;
	hdr.width = inst->width;
	hdr.height = inst->height;
	hdr.count = *nbuf;
	inst->setup_state = 1;
	inst->setup_count = 0;
	spin_unlock(&inst->slock);

	if (msg_send(inst, &hdr, NULL)) {
		spin_lock(&inst->slock);
		inst->setup_state = 0;
		spin_unlock(&inst->slock);
		return -ENODEV;
	}
	left = wait_event_interruptible_timeout(inst->setup_wq,
						inst->setup_state != 1,
						SETUP_TIMEOUT);
	spin_lock(&inst->slock);
	state = inst->setup_state;
	inst->setup_state = 0;
	if (state == 2)
		*nbuf = inst->setup_count;
	spin_unlock(&inst->slock);
	if (state != 2) {
		setup_release(inst);
		return left < 0 ? left : -ENOMEM;
	}
	return 0;
}

static int ovd_buf_init(struct vb2_buffer *vb)
{
	struct ovd_inst *inst = vb2_get_drv_priv(vb->vb2_queue);
	struct ovd_buf *b = container_of(to_vb2_v4l2_buffer(vb), struct ovd_buf,
					 m2m.vb);

	if (vb->index >= VB2_MAX_FRAME)
		return -EINVAL;
	spin_lock(&inst->slock);
	b->queued = false;
	if (V4L2_TYPE_IS_OUTPUT(vb->vb2_queue->type))
		inst->out[vb->index] = b;
	else
		inst->cap[vb->index] = b;
	spin_unlock(&inst->slock);
	return 0;
}

static void ovd_buf_cleanup(struct vb2_buffer *vb)
{
	struct ovd_inst *inst = vb2_get_drv_priv(vb->vb2_queue);

	if (vb->index >= VB2_MAX_FRAME)
		return;
	spin_lock(&inst->slock);
	if (V4L2_TYPE_IS_OUTPUT(vb->vb2_queue->type))
		inst->out[vb->index] = NULL;
	else
		inst->cap[vb->index] = NULL;
	spin_unlock(&inst->slock);
}

static int ovd_buf_out_validate(struct vb2_buffer *vb)
{
	to_vb2_v4l2_buffer(vb)->field = V4L2_FIELD_NONE;
	return 0;
}

static int ovd_buf_prepare(struct vb2_buffer *vb)
{
	struct ovd_inst *inst = vb2_get_drv_priv(vb->vb2_queue);

	/* No daemon: QBUF fails, so the app stops instead of spinning on
	 * buffers that come straight back. */
	if (READ_ONCE(inst->dead))
		return -ENODEV;
	/* CAPTURE: old-size buffers stay valid until the app reallocates. */
	if (V4L2_TYPE_IS_OUTPUT(vb->vb2_queue->type) &&
	    vb2_get_plane_payload(vb, 0) > vb2_plane_size(vb, 0))
		return -EINVAL;
	return 0;
}

/* An empty CAPTURE buffer flagged LAST: the end of a drain or of a size
 * (slock held, the buffer already taken out of the table's queued set). */
static void cap_done_last(struct ovd_buf *b)
{
	struct vb2_v4l2_buffer *vbuf = &b->m2m.vb;

	vbuf->flags |= V4L2_BUF_FLAG_LAST;
	vbuf->field = V4L2_FIELD_NONE;
	vb2_set_plane_payload(&vbuf->vb2_buf, 0, 0);
	vb2_buffer_done(&vbuf->vb2_buf, VB2_BUF_STATE_DONE);
}

static void ovd_buf_queue(struct vb2_buffer *vb)
{
	struct ovd_inst *inst = vb2_get_drv_priv(vb->vb2_queue);
	struct vb2_v4l2_buffer *vbuf = to_vb2_v4l2_buffer(vb);
	struct ovd_buf *b = container_of(vbuf, struct ovd_buf, m2m.vb);
	struct ovd_msg hdr = { .inst = inst->id, .index = vb->index };
	const void *data = NULL;
	u32 size = 0;
	u64 seq;

	if (V4L2_TYPE_IS_OUTPUT(vb->vb2_queue->type)) {
		data = vb2_plane_vaddr(vb, 0);
		size = vb2_get_plane_payload(vb, 0);
		if (size == 0 || size > OVD_MAX_BITSTREAM || !data) {
			vb2_buffer_done(vb, size ? VB2_BUF_STATE_ERROR : VB2_BUF_STATE_DONE);
			return;
		}
	}

	spin_lock(&inst->slock);
	if (inst->dead) {
		spin_unlock(&inst->slock);
		vb2_buffer_done(vb, VB2_BUF_STATE_ERROR);
		return;
	}
	if (!V4L2_TYPE_IS_OUTPUT(vb->vb2_queue->type) && inst->last_pending) {
		/* A drain ended while the daemon had no CAPTURE buffer. */
		inst->last_pending = false;
		cap_done_last(b);
		spin_unlock(&inst->slock);
		return;
	}
	seq = b->seq = ++inst->seq;
	b->queued = true;
	spin_unlock(&inst->slock);

	hdr.seq = seq;
	if (V4L2_TYPE_IS_OUTPUT(vb->vb2_queue->type)) {
		hdr.type = OVD_MSG_BITSTREAM;
		hdr.timestamp = vb->timestamp;
		hdr.size = size;
	} else {
		hdr.type = OVD_MSG_CAPTURE_QUEUED;
	}
	if (msg_send(inst, &hdr, data)) {
		/* No daemon to read it: back to the app at once. */
		spin_lock(&inst->slock);
		if (b->seq == seq)
			buf_give_back(b, VB2_BUF_STATE_ERROR);
		spin_unlock(&inst->slock);
	}
}

static int ovd_start_streaming(struct vb2_queue *q, unsigned int count)
{
	struct ovd_inst *inst = vb2_get_drv_priv(q);
	struct ovd_msg hdr = { .type = OVD_MSG_START, .inst = inst->id };

	if (V4L2_TYPE_IS_OUTPUT(q->type)) {
		hdr.codec = inst->codec;
		msg_send(inst, &hdr, NULL);
	} else {
		spin_lock(&inst->slock);
		inst->cap_streaming = true;
		spin_unlock(&inst->slock);
	}
	return 0;
}

/* Every buffer still with us goes back to the app (vb2 wants that). */
static void ovd_stop_streaming(struct vb2_queue *q)
{
	struct ovd_inst *inst = vb2_get_drv_priv(q);
	bool out = V4L2_TYPE_IS_OUTPUT(q->type);
	struct ovd_buf **tab = out ? inst->out : inst->cap;
	unsigned int i;

	if (out)
		msg_purge(inst->dev, inst->id, OVD_MSG_BITSTREAM);
	else
		msg_purge(inst->dev, inst->id, OVD_MSG_CAPTURE_QUEUED);
	spin_lock(&inst->slock);
	inst->last_pending = false;	/* a stream off ends a drain */
	if (!out)
		inst->cap_streaming = false;
	for (i = 0; i < VB2_MAX_FRAME; i++)
		buf_give_back(tab[i], VB2_BUF_STATE_ERROR);
	spin_unlock(&inst->slock);
	/* A read() that started before may still copy out of one of them. */
	if (out)
		wait_event(inst->copy_wq, !atomic_read(&inst->copying));
	msg_simple(inst, out ? OVD_MSG_FLUSH : OVD_MSG_CAPTURE_STOP);
}

static const struct vb2_ops ovd_qops = {
	.queue_setup = ovd_queue_setup,
	.buf_init = ovd_buf_init,
	.buf_cleanup = ovd_buf_cleanup,
	.buf_out_validate = ovd_buf_out_validate,
	.buf_prepare = ovd_buf_prepare,
	.buf_queue = ovd_buf_queue,
	.start_streaming = ovd_start_streaming,
	.stop_streaming = ovd_stop_streaming,
};

static int ovd_queue_init(void *priv, struct vb2_queue *src, struct vb2_queue *dst)
{
	struct ovd_inst *inst = priv;
	int ret;

	src->type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
	src->io_modes = VB2_MMAP | VB2_DMABUF;
	src->drv_priv = inst;
	src->buf_struct_size = sizeof(struct ovd_buf);
	src->ops = &ovd_qops;
	src->mem_ops = &vb2_vmalloc_memops;
	src->timestamp_flags = V4L2_BUF_FLAG_TIMESTAMP_COPY;
	src->lock = &inst->lock;
	src->dev = &inst->dev->pdev->dev;
	ret = vb2_queue_init(src);
	if (ret)
		return ret;

	dst->type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	dst->io_modes = VB2_MMAP;
	dst->drv_priv = inst;
	dst->buf_struct_size = sizeof(struct ovd_buf);
	dst->ops = &ovd_qops;
	dst->mem_ops = &ovd_mem_ops;
	dst->timestamp_flags = V4L2_BUF_FLAG_TIMESTAMP_COPY;
	dst->lock = &inst->lock;
	dst->dev = &inst->dev->pdev->dev;
	return vb2_queue_init(dst);
}

/* ---- V4L2 ioctls ---------------------------------------------------------- */

static int ovd_querycap(struct file *file, void *priv, struct v4l2_capability *cap)
{
	strscpy(cap->driver, DRV, sizeof(cap->driver));
	strscpy(cap->card, "OmacVM video decoder", sizeof(cap->card));
	strscpy(cap->bus_info, "platform:" DRV, sizeof(cap->bus_info));
	return 0;
}

static int ovd_enum_fmt_out(struct file *file, void *priv, struct v4l2_fmtdesc *f)
{
	struct ovd_dev *dev = file2inst(file)->dev;
	unsigned int i, n = 0;

	for (i = 0; i < ARRAY_SIZE(ovd_codecs); i++) {
		if (!(dev->caps.codecs & ovd_codecs[i].bit))
			continue;
		if (n++ == f->index) {
			f->pixelformat = ovd_codecs[i].fourcc;
			f->flags = V4L2_FMT_FLAG_COMPRESSED | V4L2_FMT_FLAG_DYN_RESOLUTION;
			return 0;
		}
	}
	return -EINVAL;
}

static int ovd_enum_fmt_cap(struct file *file, void *priv, struct v4l2_fmtdesc *f)
{
	if (f->index)
		return -EINVAL;
	f->pixelformat = V4L2_PIX_FMT_ABGR32;
	return 0;
}

static void fill_out_fmt(struct ovd_inst *inst, struct v4l2_pix_format_mplane *mp)
{
	memset(mp->reserved, 0, sizeof(mp->reserved));
	mp->pixelformat = inst->codec;
	mp->width = inst->out_width;
	mp->height = inst->out_height;
	mp->field = V4L2_FIELD_NONE;
	mp->colorspace = V4L2_COLORSPACE_REC709;
	mp->num_planes = 1;
	memset(mp->plane_fmt, 0, sizeof(mp->plane_fmt));
	mp->plane_fmt[0].sizeimage = inst->out_sizeimage;
}

static void fill_cap_fmt(struct ovd_inst *inst, struct v4l2_pix_format_mplane *mp)
{
	u32 w = inst->width, h = inst->height, stride = inst->stride;

	if (!inst->fmt_known) {	/* a guess from OUTPUT until the daemon knows */
		w = ALIGN(inst->out_width, 2);
		h = ALIGN(inst->out_height, 2);
		stride = ALIGN(w * 4, 256);
	}
	memset(mp->reserved, 0, sizeof(mp->reserved));
	mp->pixelformat = V4L2_PIX_FMT_ABGR32;
	mp->width = w;
	mp->height = h;
	mp->field = V4L2_FIELD_NONE;
	mp->colorspace = V4L2_COLORSPACE_SRGB;	/* converted by the daemon */
	mp->num_planes = 1;
	memset(mp->plane_fmt, 0, sizeof(mp->plane_fmt));
	mp->plane_fmt[0].bytesperline = stride;
	mp->plane_fmt[0].sizeimage = stride * h;
}

static int ovd_g_fmt(struct file *file, void *priv, struct v4l2_format *f)
{
	struct ovd_inst *inst = file2inst(file);

	mutex_lock(&inst->lock);
	if (V4L2_TYPE_IS_OUTPUT(f->type))
		fill_out_fmt(inst, &f->fmt.pix_mp);
	else
		fill_cap_fmt(inst, &f->fmt.pix_mp);
	mutex_unlock(&inst->lock);
	return 0;
}

static void try_out_fmt(struct ovd_inst *inst, struct v4l2_pix_format_mplane *mp)
{
	u32 size = mp->plane_fmt[0].sizeimage;

	if (!codec_offered(inst->dev, mp->pixelformat))
		mp->pixelformat = inst->codec;
	mp->width = clamp(mp->width, MIN_SIZE, OVD_MAX_WIDTH);
	mp->height = clamp(mp->height, MIN_SIZE, OVD_MAX_HEIGHT);
	mp->field = V4L2_FIELD_NONE;
	mp->num_planes = 1;
	if (!size)
		size = max_t(u32, 1u << 20, mp->width * mp->height / 2);
	memset(mp->plane_fmt, 0, sizeof(mp->plane_fmt));
	mp->plane_fmt[0].sizeimage = clamp_t(u32, PAGE_ALIGN(size), 64u << 10, OVD_MAX_BITSTREAM);
	memset(mp->reserved, 0, sizeof(mp->reserved));
}

static int ovd_try_fmt(struct file *file, void *priv, struct v4l2_format *f)
{
	struct ovd_inst *inst = file2inst(file);

	mutex_lock(&inst->lock);
	if (V4L2_TYPE_IS_OUTPUT(f->type))
		try_out_fmt(inst, &f->fmt.pix_mp);
	else
		fill_cap_fmt(inst, &f->fmt.pix_mp);	/* the daemon decides */
	mutex_unlock(&inst->lock);
	return 0;
}

static int ovd_s_fmt(struct file *file, void *priv, struct v4l2_format *f)
{
	struct ovd_inst *inst = file2inst(file);
	struct v4l2_pix_format_mplane *mp = &f->fmt.pix_mp;
	struct vb2_queue *q = v4l2_m2m_get_vq(inst->fh.m2m_ctx, f->type);
	int ret = 0;

	mutex_lock(&inst->lock);
	if (!q || vb2_is_busy(q)) {
		ret = -EBUSY;
	} else if (V4L2_TYPE_IS_OUTPUT(f->type)) {
		try_out_fmt(inst, mp);
		inst->codec = mp->pixelformat;
		inst->out_width = mp->width;
		inst->out_height = mp->height;
		inst->out_sizeimage = mp->plane_fmt[0].sizeimage;
	} else {
		fill_cap_fmt(inst, mp);
	}
	mutex_unlock(&inst->lock);
	return ret;
}

static int ovd_g_selection(struct file *file, void *priv, struct v4l2_selection *s)
{
	struct ovd_inst *inst = file2inst(file);
	struct v4l2_pix_format_mplane mp;

	if (s->type != V4L2_BUF_TYPE_VIDEO_CAPTURE &&
	    s->type != V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE)
		return -EINVAL;
	mutex_lock(&inst->lock);
	fill_cap_fmt(inst, &mp);
	s->r.left = 0;
	s->r.top = 0;
	s->r.width = mp.width;
	s->r.height = mp.height;
	if ((s->target == V4L2_SEL_TGT_COMPOSE ||
	     s->target == V4L2_SEL_TGT_COMPOSE_DEFAULT) && inst->fmt_known) {
		s->r.width = inst->vis_width;
		s->r.height = inst->vis_height;
	}
	mutex_unlock(&inst->lock);
	switch (s->target) {
	case V4L2_SEL_TGT_COMPOSE:
	case V4L2_SEL_TGT_COMPOSE_DEFAULT:
	case V4L2_SEL_TGT_COMPOSE_BOUNDS:
	case V4L2_SEL_TGT_COMPOSE_PADDED:
		return 0;
	}
	return -EINVAL;
}

static int ovd_enum_framesizes(struct file *file, void *priv,
			       struct v4l2_frmsizeenum *fs)
{
	struct ovd_dev *dev = file2inst(file)->dev;

	if (fs->index || !codec_offered(dev, fs->pixel_format))
		return -EINVAL;
	fs->type = V4L2_FRMSIZE_TYPE_STEPWISE;
	fs->stepwise.min_width = MIN_SIZE;
	fs->stepwise.max_width = min(dev->caps.max_width, OVD_MAX_WIDTH);
	fs->stepwise.step_width = 2;
	fs->stepwise.min_height = MIN_SIZE;
	fs->stepwise.max_height = min(dev->caps.max_height, OVD_MAX_HEIGHT);
	fs->stepwise.step_height = 2;
	return 0;
}

static int ovd_decoder_cmd(struct file *file, void *priv, struct v4l2_decoder_cmd *dc)
{
	struct ovd_inst *inst = file2inst(file);
	struct vb2_queue *cap = v4l2_m2m_get_dst_vq(inst->fh.m2m_ctx);
	struct vb2_queue *out = v4l2_m2m_get_src_vq(inst->fh.m2m_ctx);
	int ret = v4l2_m2m_ioctl_try_decoder_cmd(file, priv, dc);

	if (ret)
		return ret;
	mutex_lock(&inst->lock);
	if (dc->cmd == V4L2_DEC_CMD_STOP) {
		if (vb2_is_streaming(out))
			msg_simple(inst, OVD_MSG_DRAIN);
	} else {
		vb2_clear_last_buffer_dequeued(cap);
		spin_lock(&inst->slock);
		inst->last_pending = false;
		spin_unlock(&inst->slock);
	}
	mutex_unlock(&inst->lock);
	return 0;
}

static int ovd_subscribe_event(struct v4l2_fh *fh, const struct v4l2_event_subscription *sub)
{
	switch (sub->type) {
	case V4L2_EVENT_SOURCE_CHANGE:
	case V4L2_EVENT_EOS:
		return v4l2_event_subscribe(fh, sub, 4, NULL);
	default:
		return v4l2_ctrl_subscribe_event(fh, sub);
	}
}

static const struct v4l2_ioctl_ops ovd_ioctl_ops = {
	.vidioc_querycap = ovd_querycap,
	.vidioc_enum_fmt_vid_out = ovd_enum_fmt_out,
	.vidioc_enum_fmt_vid_cap = ovd_enum_fmt_cap,
	.vidioc_g_fmt_vid_out_mplane = ovd_g_fmt,
	.vidioc_g_fmt_vid_cap_mplane = ovd_g_fmt,
	.vidioc_try_fmt_vid_out_mplane = ovd_try_fmt,
	.vidioc_try_fmt_vid_cap_mplane = ovd_try_fmt,
	.vidioc_s_fmt_vid_out_mplane = ovd_s_fmt,
	.vidioc_s_fmt_vid_cap_mplane = ovd_s_fmt,
	.vidioc_g_selection = ovd_g_selection,
	.vidioc_enum_framesizes = ovd_enum_framesizes,

	.vidioc_reqbufs = v4l2_m2m_ioctl_reqbufs,
	.vidioc_querybuf = v4l2_m2m_ioctl_querybuf,
	.vidioc_qbuf = v4l2_m2m_ioctl_qbuf,
	.vidioc_dqbuf = v4l2_m2m_ioctl_dqbuf,
	.vidioc_prepare_buf = v4l2_m2m_ioctl_prepare_buf,
	.vidioc_expbuf = v4l2_m2m_ioctl_expbuf,
	.vidioc_streamon = v4l2_m2m_ioctl_streamon,
	.vidioc_streamoff = v4l2_m2m_ioctl_streamoff,

	.vidioc_try_decoder_cmd = v4l2_m2m_ioctl_try_decoder_cmd,
	.vidioc_decoder_cmd = ovd_decoder_cmd,
	.vidioc_subscribe_event = ovd_subscribe_event,
	.vidioc_unsubscribe_event = v4l2_event_unsubscribe,
};

/* ---- controls -------------------------------------------------------------- */

static int ovd_g_volatile_ctrl(struct v4l2_ctrl *ctrl)
{
	struct ovd_inst *inst = container_of(ctrl->handler, struct ovd_inst, hdl);

	if (ctrl->id != V4L2_CID_MIN_BUFFERS_FOR_CAPTURE)
		return -EINVAL;
	spin_lock(&inst->slock);
	ctrl->val = inst->min_buffers;
	spin_unlock(&inst->slock);
	return 0;
}

static const struct v4l2_ctrl_ops ovd_ctrl_ops = {
	.g_volatile_ctrl = ovd_g_volatile_ctrl,
};

static int ovd_ctrls_init(struct ovd_inst *inst)
{
	struct v4l2_ctrl_handler *hdl = &inst->hdl;
	u32 codecs = inst->dev->caps.codecs;
	struct v4l2_ctrl *min_bufs;

	v4l2_ctrl_handler_init(hdl, 4);
	/* Volatile: read from the daemon's format each time (venus does the same). */
	min_bufs = v4l2_ctrl_new_std(hdl, &ovd_ctrl_ops, V4L2_CID_MIN_BUFFERS_FOR_CAPTURE,
				     1, 32, 1, 4);
	if (min_bufs)
		min_bufs->flags |= V4L2_CTRL_FLAG_VOLATILE;
	if (codecs & OVD_CODEC_H264)
		v4l2_ctrl_new_std_menu(hdl, &ovd_ctrl_ops, V4L2_CID_MPEG_VIDEO_H264_PROFILE,
			V4L2_MPEG_VIDEO_H264_PROFILE_HIGH,
			~(BIT(V4L2_MPEG_VIDEO_H264_PROFILE_BASELINE) |
			  BIT(V4L2_MPEG_VIDEO_H264_PROFILE_CONSTRAINED_BASELINE) |
			  BIT(V4L2_MPEG_VIDEO_H264_PROFILE_MAIN) |
			  BIT(V4L2_MPEG_VIDEO_H264_PROFILE_HIGH)),
			V4L2_MPEG_VIDEO_H264_PROFILE_HIGH);
	if (codecs & OVD_CODEC_HEVC)
		v4l2_ctrl_new_std_menu(hdl, &ovd_ctrl_ops, V4L2_CID_MPEG_VIDEO_HEVC_PROFILE,
			V4L2_MPEG_VIDEO_HEVC_PROFILE_MAIN,
			~BIT(V4L2_MPEG_VIDEO_HEVC_PROFILE_MAIN),
			V4L2_MPEG_VIDEO_HEVC_PROFILE_MAIN);
	if (codecs & OVD_CODEC_VP9)
		v4l2_ctrl_new_std_menu(hdl, &ovd_ctrl_ops, V4L2_CID_MPEG_VIDEO_VP9_PROFILE,
			V4L2_MPEG_VIDEO_VP9_PROFILE_0,
			~BIT(V4L2_MPEG_VIDEO_VP9_PROFILE_0),
			V4L2_MPEG_VIDEO_VP9_PROFILE_0);
	if (hdl->error) {
		int err = hdl->error;

		v4l2_ctrl_handler_free(hdl);
		return err;
	}
	inst->fh.ctrl_handler = hdl;
	return 0;
}

/* ---- video device file ops -------------------------------------------------- */

static int ovd_open(struct file *file)
{
	struct ovd_dev *dev = video_drvdata(file);
	struct ovd_inst *inst;
	int ret, id;

	inst = kzalloc(sizeof(*inst), GFP_KERNEL);
	if (!inst)
		return -ENOMEM;
	inst->dev = dev;
	kref_init(&inst->ref);
	mutex_init(&inst->lock);
	spin_lock_init(&inst->slock);
	init_waitqueue_head(&inst->setup_wq);
	init_waitqueue_head(&inst->copy_wq);
	atomic_set(&inst->nmsgs, 0);
	atomic_set(&inst->copying, 0);
	inst->out_width = 1280;
	inst->out_height = 720;
	inst->out_sizeimage = 1u << 20;
	inst->min_buffers = 4;

	mutex_lock(&dev->lock);
	if (!dev->daemon || !dev->caps.codecs || dev->ninsts >= MAX_INSTANCES) {
		ret = !dev->daemon || !dev->caps.codecs ? -ENODEV : -EBUSY;
		mutex_unlock(&dev->lock);
		kfree(inst);
		return ret;
	}
	inst->codec = V4L2_PIX_FMT_H264;
	if (!codec_offered(dev, inst->codec))
		inst->codec = dev->caps.codecs & OVD_CODEC_VP9 ? V4L2_PIX_FMT_VP9 : V4L2_PIX_FMT_HEVC;
	/* Reserved (NULL) until the decoder is set up; cyclic, so an id is not
	 * reused while the daemon may still hold the old decoder's state. */
	id = idr_alloc_cyclic(&dev->insts, NULL, 1, 0, GFP_KERNEL);
	if (id >= 0)
		dev->ninsts++;
	mutex_unlock(&dev->lock);
	if (id < 0) {
		kfree(inst);
		return id;
	}
	inst->id = id;

	v4l2_fh_init(&inst->fh, video_devdata(file));
	ret = ovd_ctrls_init(inst);
	if (ret)
		goto err_fh;
	inst->fh.m2m_ctx = v4l2_m2m_ctx_init(dev->m2m_dev, inst, ovd_queue_init);
	if (IS_ERR(inst->fh.m2m_ctx)) {
		ret = PTR_ERR(inst->fh.m2m_ctx);
		v4l2_ctrl_handler_free(&inst->hdl);
		goto err_fh;
	}
	inst->fh.m2m_ctx->q_lock = &inst->lock;
	v4l2_fh_add(&inst->fh, file);
	mutex_lock(&dev->lock);
	idr_replace(&dev->insts, inst, id);
	mutex_unlock(&dev->lock);
	if (msg_simple(inst, OVD_MSG_OPEN))
		WRITE_ONCE(inst->dead, true);	/* the daemon just went: QBUF fails */
	return 0;

err_fh:
	v4l2_fh_exit(&inst->fh);
	mutex_lock(&dev->lock);
	idr_remove(&dev->insts, id);
	dev->ninsts--;
	mutex_unlock(&dev->lock);
	kfree(inst);
	return ret;
}

static int ovd_release(struct file *file)
{
	struct ovd_inst *inst = file2inst(file);
	struct ovd_dev *dev = inst->dev;

	spin_lock(&inst->slock);
	inst->closing = true;
	spin_unlock(&inst->slock);
	mutex_lock(&dev->lock);
	idr_remove(&dev->insts, inst->id);
	dev->ninsts--;
	mutex_unlock(&dev->lock);

	v4l2_fh_del(&inst->fh, file);
	mutex_lock(&inst->lock);
	v4l2_m2m_ctx_release(inst->fh.m2m_ctx);
	mutex_unlock(&inst->lock);
	v4l2_fh_exit(&inst->fh);
	v4l2_ctrl_handler_free(&inst->hdl);
	setup_release(inst);
	msg_purge(dev, inst->id, OVD_MSG_BITSTREAM);
	msg_simple(inst, OVD_MSG_CLOSE);
	kref_put(&inst->ref, inst_free);
	return 0;
}

/*
 * v4l2_m2m_poll() reports EPOLLERR while neither queue has a buffer queued.
 * Here that is no error while a queue streams: at the end of a stream the
 * app holds every CAPTURE buffer, OUTPUT is drained, and the daemon waits
 * for a buffer to put the last pictures and the LAST one in. Chromium 153
 * drops a wait that gets EPOLLERR and posts no new one, so it never saw
 * that LAST: playback stood still at the end of a clip and a loop never
 * looped. So the poll sleeps then, until a buffer comes back, an event or
 * a stream off (vb2 wakes done_wq) or a failure (inst_fail_all wakes
 * fh.wait). Neither queue streaming, or a failed decoder: EPOLLERR as
 * before. v4l2_m2m_poll() has registered all three wait queues before this
 * looks at the state, under the lock the stream ioctls take.
 */
static __poll_t ovd_poll(struct file *file, poll_table *wait)
{
	struct ovd_inst *inst = file2inst(file);
	struct v4l2_m2m_ctx *ctx = inst->fh.m2m_ctx;
	__poll_t rc;

	mutex_lock(&inst->lock);
	rc = v4l2_m2m_poll(file, ctx, wait);
	if ((rc & EPOLLERR) && !READ_ONCE(inst->dead) &&
	    (vb2_is_streaming(v4l2_m2m_get_src_vq(ctx)) ||
	     vb2_is_streaming(v4l2_m2m_get_dst_vq(ctx))))
		rc &= ~EPOLLERR;
	mutex_unlock(&inst->lock);
	return rc;
}

static const struct v4l2_file_operations ovd_fops = {
	.owner = THIS_MODULE,
	.open = ovd_open,
	.release = ovd_release,
	.poll = ovd_poll,
	.unlocked_ioctl = video_ioctl2,
	.mmap = v4l2_m2m_fop_mmap,
};

/* ---- the daemon's device ----------------------------------------------------- */

static struct ovd_inst *inst_get(struct ovd_dev *dev, u32 id)
{
	struct ovd_inst *inst;

	mutex_lock(&dev->lock);
	inst = idr_find(&dev->insts, id);
	if (inst)
		kref_get(&inst->ref);
	mutex_unlock(&dev->lock);
	return inst;
}

static int daemon_open(struct inode *inode, struct file *file)
{
	struct ovd_dev *dev = ovd;
	int ret = 0;

	mutex_lock(&dev->lock);
	if (dev->daemon) {
		ret = -EBUSY;
	} else {
		dev->daemon = file;
		spin_lock(&dev->msg_lock);
		dev->online = true;
		spin_unlock(&dev->msg_lock);
	}
	mutex_unlock(&dev->lock);
	file->private_data = dev;
	return ret;
}

/* The daemon is gone: every open decode fails, no new ones start. */
static int daemon_release(struct inode *inode, struct file *file)
{
	struct ovd_dev *dev = file->private_data;
	struct ovd_inst *inst;
	LIST_HEAD(gone);
	int id;

	mutex_lock(&dev->lock);
	if (dev->daemon != file) {
		mutex_unlock(&dev->lock);
		return 0;
	}
	dev->daemon = NULL;
	memset(&dev->caps, 0, sizeof(dev->caps));
	spin_lock(&dev->msg_lock);
	dev->online = false;
	list_splice_init(&dev->msgs, &gone);
	spin_unlock(&dev->msg_lock);
	idr_for_each_entry(&dev->insts, inst, id)
		inst_fail_all(inst);
	mutex_unlock(&dev->lock);
	msg_free_list(&gone);
	return 0;
}

/* A BITSTREAM message is read only while its buffer is still with us (not
 * taken back by a stream off or a failure since): the copy then counts in
 * inst->copying until bits_done. */
static bool bits_hold(struct ovd_kmsg *m)
{
	struct ovd_inst *inst = m->inst;
	struct ovd_buf *b;
	bool ok;

	spin_lock(&inst->slock);
	b = m->hdr.index < VB2_MAX_FRAME ? inst->out[m->hdr.index] : NULL;
	ok = b && b->queued && b->seq == m->hdr.seq;
	if (ok)
		atomic_inc(&inst->copying);
	spin_unlock(&inst->slock);
	return ok;
}

static void bits_done(struct ovd_inst *inst)
{
	if (atomic_dec_and_test(&inst->copying))
		wake_up(&inst->copy_wq);
}

static ssize_t daemon_read(struct file *file, char __user *buf, size_t len, loff_t *off)
{
	struct ovd_dev *dev = file->private_data;
	struct ovd_kmsg *m;
	int ret;

	if (len < sizeof(struct ovd_msg))
		return -EINVAL;
	for (;;) {
		spin_lock(&dev->msg_lock);
		m = list_first_entry_or_null(&dev->msgs, struct ovd_kmsg, list);
		if (m && sizeof(m->hdr) + m->hdr.size > len) {
			spin_unlock(&dev->msg_lock);
			return -EMSGSIZE;
		}
		if (m)
			list_del(&m->list);
		spin_unlock(&dev->msg_lock);
		if (m && (m->hdr.type != OVD_MSG_BITSTREAM || bits_hold(m)))
			break;
		if (m) {		/* the app has that buffer back: stale */
			msg_free(m);
			continue;
		}
		if (file->f_flags & O_NONBLOCK)
			return -EAGAIN;
		ret = wait_event_interruptible(dev->msg_wq, !list_empty(&dev->msgs));
		if (ret)
			return ret;
	}
	ret = sizeof(m->hdr) + m->hdr.size;
	if (copy_to_user(buf, &m->hdr, sizeof(m->hdr)) ||
	    (m->hdr.size && copy_to_user(buf + sizeof(m->hdr), m->data, m->hdr.size)))
		ret = -EFAULT;
	if (m->hdr.type == OVD_MSG_BITSTREAM)
		bits_done(m->inst);
	msg_free(m);
	return ret;
}

static __poll_t daemon_poll(struct file *file, poll_table *wait)
{
	struct ovd_dev *dev = file->private_data;

	poll_wait(file, &dev->msg_wq, wait);
	return list_empty(&dev->msgs) ? 0 : EPOLLIN | EPOLLRDNORM;
}

static long set_format(struct ovd_dev *dev, struct ovd_format __user *uarg)
{
	static const struct v4l2_event ev = {
		.type = V4L2_EVENT_SOURCE_CHANGE,
		.u.src_change.changes = V4L2_EVENT_SRC_CH_RESOLUTION,
	};
	struct ovd_format f;
	struct ovd_inst *inst;

	if (copy_from_user(&f, uarg, sizeof(f)))
		return -EFAULT;
	if (f.width < MIN_SIZE || f.width > OVD_MAX_WIDTH || f.width % 2 ||
	    f.height < MIN_SIZE || f.height > OVD_MAX_HEIGHT || f.height % 2 ||
	    !f.visible_width || f.visible_width > f.width ||
	    !f.visible_height || f.visible_height > f.height ||
	    f.stride < 4 * f.width || f.stride > 8 * OVD_MAX_WIDTH ||
	    !f.min_buffers || f.min_buffers > 32)
		return -EINVAL;
	inst = inst_get(dev, f.inst);
	if (!inst)
		return -ENOENT;
	spin_lock(&inst->slock);
	if (!inst->closing) {
		inst->width = f.width;
		inst->height = f.height;
		inst->vis_width = f.visible_width;
		inst->vis_height = f.visible_height;
		inst->stride = f.stride;
		inst->min_buffers = f.min_buffers;
		inst->fmt_known = true;
		v4l2_event_queue_fh(&inst->fh, &ev);
	}
	spin_unlock(&inst->slock);
	kref_put(&inst->ref, inst_free);
	return 0;
}

static long set_buffers(struct ovd_dev *dev, struct ovd_buffers __user *uarg)
{
	struct ovd_buffers *b;
	struct dma_buf *dbuf[OVD_MAX_CAPTURE] = { };
	struct ovd_inst *inst;
	unsigned int i;
	long ret = 0;

	b = memdup_user(uarg, sizeof(*b));
	if (IS_ERR(b))
		return PTR_ERR(b);
	inst = inst_get(dev, b->inst);
	if (!inst) {
		kfree(b);
		return -ENOENT;
	}
	if (b->count > OVD_MAX_CAPTURE) {
		ret = -EINVAL;
		goto out;
	}
	for (i = 0; i < b->count && !ret; i++) {
		dbuf[i] = dma_buf_get(b->fd[i]);
		if (IS_ERR(dbuf[i])) {
			ret = PTR_ERR(dbuf[i]);
			dbuf[i] = NULL;
		}
	}
	spin_lock(&inst->slock);
	if (inst->setup_state != 1) {
		ret = ret ?: -EINVAL;
	} else if (ret || !b->count) {
		inst->setup_state = -ENOMEM;
	} else {
		memcpy(inst->setup_dbuf, dbuf, sizeof(dbuf));
		memset(dbuf, 0, sizeof(dbuf));
		inst->setup_count = b->count;
		inst->setup_state = 2;
	}
	spin_unlock(&inst->slock);
	wake_up_interruptible(&inst->setup_wq);
out:
	for (i = 0; i < OVD_MAX_CAPTURE; i++)
		if (dbuf[i])
			dma_buf_put(dbuf[i]);
	kref_put(&inst->ref, inst_free);
	kfree(b);
	return ret;
}

static const struct v4l2_event eos_event = { .type = V4L2_EVENT_EOS };

/*
 * A drain ended while the daemon had no CAPTURE buffer (slock held): a
 * CAPTURE buffer queued with us whose message the daemon has not read yet
 * goes back LAST now (and its message with it), else the next one queued
 * while CAPTURE streams. Not streaming (no picture yet): EOS alone, as the
 * V4L2 decoder spec has it.
 */
static void no_buffer_last(struct ovd_inst *inst, bool eos, struct list_head *gone)
{
	struct ovd_buf *b = NULL;
	unsigned int i;

	for (i = 0; i < VB2_MAX_FRAME; i++)
		if (inst->cap[i] && inst->cap[i]->queued && (!b || inst->cap[i]->seq < b->seq))
			b = inst->cap[i];
	if (b) {
		b->queued = false;
		msg_take(inst->dev, inst->id, OVD_MSG_CAPTURE_QUEUED, b->m2m.vb.vb2_buf.index, gone);
		cap_done_last(b);
	} else if (inst->cap_streaming) {
		inst->last_pending = true;
	}
	if (eos)
		v4l2_event_queue_fh(&inst->fh, &eos_event);
}

static long buf_done(struct ovd_dev *dev, struct ovd_done __user *uarg, bool output)
{
	struct ovd_buf *b = NULL;
	struct ovd_inst *inst;
	struct ovd_done d;
	LIST_HEAD(gone);

	if (copy_from_user(&d, uarg, sizeof(d)))
		return -EFAULT;
	inst = inst_get(dev, d.inst);
	if (!inst)
		return -ENOENT;

	spin_lock(&inst->slock);
	if (!output && d.index == OVD_NO_BUFFER) {
		if ((d.flags & OVD_DONE_LAST) && !inst->closing && !inst->dead)
			no_buffer_last(inst, d.flags & OVD_DONE_EOS, &gone);
		goto out;
	}
	if (d.index < VB2_MAX_FRAME) {
		b = output ? inst->out[d.index] : inst->cap[d.index];
		if (b && (!b->queued || b->seq != d.seq))
			b = NULL;
	}
	if (!b)
		goto out;
	b->queued = false;
	if (output) {
		vb2_buffer_done(&b->m2m.vb.vb2_buf, d.flags & OVD_DONE_ERROR ?
				VB2_BUF_STATE_ERROR : VB2_BUF_STATE_DONE);
	} else if (d.flags & OVD_DONE_LAST) {
		cap_done_last(b);
		if ((d.flags & OVD_DONE_EOS) && !inst->closing)
			v4l2_event_queue_fh(&inst->fh, &eos_event);
	} else {
		struct vb2_buffer *vb = &b->m2m.vb.vb2_buf;

		vb->timestamp = d.timestamp;
		b->m2m.vb.field = V4L2_FIELD_NONE;
		b->m2m.vb.flags &= ~V4L2_BUF_FLAG_LAST;
		vb2_set_plane_payload(vb, 0, vb2_plane_size(vb, 0));
		vb2_buffer_done(vb, d.flags & OVD_DONE_ERROR ?
				VB2_BUF_STATE_ERROR : VB2_BUF_STATE_DONE);
	}
out:
	spin_unlock(&inst->slock);
	msg_free_list(&gone);
	kref_put(&inst->ref, inst_free);
	return 0;
}

static long daemon_ioctl(struct file *file, unsigned int cmd, unsigned long arg)
{
	struct ovd_dev *dev = file->private_data;
	void __user *uarg = (void __user *)arg;

	switch (cmd) {
	case OVD_IOC_SET_CAPS: {
		struct ovd_caps c;

		if (copy_from_user(&c, uarg, sizeof(c)))
			return -EFAULT;
		if (c.version != OVD_VERSION) {
			dev_warn(&dev->pdev->dev,
				 "omacvm-vdecd speaks version %u, this module %u: restart the VM\n",
				 c.version, OVD_VERSION);
			return -EPROTO;
		}
		c.codecs &= OVD_CODEC_H264 | OVD_CODEC_HEVC | OVD_CODEC_VP9;
		c.max_width = clamp(c.max_width, MIN_SIZE, OVD_MAX_WIDTH);
		c.max_height = clamp(c.max_height, MIN_SIZE, OVD_MAX_HEIGHT);
		mutex_lock(&dev->lock);
		dev->caps = c;
		mutex_unlock(&dev->lock);
		return 0;
	}
	case OVD_IOC_SET_FORMAT:
		return set_format(dev, uarg);
	case OVD_IOC_SET_BUFFERS:
		return set_buffers(dev, uarg);
	case OVD_IOC_OUTPUT_DONE:
		return buf_done(dev, uarg, true);
	case OVD_IOC_CAPTURE_DONE:
		return buf_done(dev, uarg, false);
	case OVD_IOC_ERROR: {
		struct ovd_inst *inst;
		u32 id;

		if (get_user(id, (u32 __user *)uarg))
			return -EFAULT;
		inst = inst_get(dev, id);
		if (!inst)
			return -ENOENT;
		inst_fail_all(inst);
		kref_put(&inst->ref, inst_free);
		return 0;
	}
	}
	return -ENOTTY;
}

static const struct file_operations daemon_fops = {
	.owner = THIS_MODULE,
	.open = daemon_open,
	.release = daemon_release,
	.read = daemon_read,
	.poll = daemon_poll,
	.unlocked_ioctl = daemon_ioctl,
	.llseek = noop_llseek,
};

/* ---- module ------------------------------------------------------------------- */

static void ovd_device_run(void *priv)
{
	/* Never scheduled: job_ready says no. Work goes through the daemon. */
}

static int ovd_job_ready(void *priv)
{
	return 0;
}

static const struct v4l2_m2m_ops ovd_m2m_ops = {
	.device_run = ovd_device_run,
	.job_ready = ovd_job_ready,
};

static int __init ovd_init(void)
{
	struct ovd_dev *dev;
	int ret;

	dev = kzalloc(sizeof(*dev), GFP_KERNEL);
	if (!dev)
		return -ENOMEM;
	mutex_init(&dev->lock);
	idr_init(&dev->insts);
	spin_lock_init(&dev->msg_lock);
	INIT_LIST_HEAD(&dev->msgs);
	init_waitqueue_head(&dev->msg_wq);

	dev->pdev = platform_device_register_simple(DRV, -1, NULL, 0);
	if (IS_ERR(dev->pdev)) {
		ret = PTR_ERR(dev->pdev);
		goto err_free;
	}
	/* Named here: without a name v4l2 takes the (unbound) driver's. */
	strscpy(dev->v4l2_dev.name, DRV, sizeof(dev->v4l2_dev.name));
	ret = v4l2_device_register(&dev->pdev->dev, &dev->v4l2_dev);
	if (ret)
		goto err_pdev;
	dev->m2m_dev = v4l2_m2m_init(&ovd_m2m_ops);
	if (IS_ERR(dev->m2m_dev)) {
		ret = PTR_ERR(dev->m2m_dev);
		goto err_v4l2;
	}

	ovd = dev;
	dev->misc.minor = MISC_DYNAMIC_MINOR;
	dev->misc.name = DRV;
	dev->misc.fops = &daemon_fops;
	dev->misc.mode = 0600;
	ret = misc_register(&dev->misc);
	if (ret)
		goto err_m2m;

	strscpy(dev->vdev.name, DRV, sizeof(dev->vdev.name));
	dev->vdev.fops = &ovd_fops;
	dev->vdev.ioctl_ops = &ovd_ioctl_ops;
	dev->vdev.release = video_device_release_empty;
	dev->vdev.v4l2_dev = &dev->v4l2_dev;
	dev->vdev.vfl_dir = VFL_DIR_M2M;
	dev->vdev.device_caps = V4L2_CAP_VIDEO_M2M_MPLANE | V4L2_CAP_STREAMING;
	video_set_drvdata(&dev->vdev, dev);
	ret = video_register_device(&dev->vdev, VFL_TYPE_VIDEO, -1);
	if (ret)
		goto err_misc;
	dev_info(&dev->pdev->dev, "decoder at /dev/video%d\n", dev->vdev.num);
	return 0;

err_misc:
	misc_deregister(&dev->misc);
err_m2m:
	ovd = NULL;
	v4l2_m2m_release(dev->m2m_dev);
err_v4l2:
	v4l2_device_unregister(&dev->v4l2_dev);
err_pdev:
	platform_device_unregister(dev->pdev);
err_free:
	kfree(dev);
	return ret;
}

static void __exit ovd_exit(void)
{
	struct ovd_dev *dev = ovd;

	video_unregister_device(&dev->vdev);
	misc_deregister(&dev->misc);
	v4l2_m2m_release(dev->m2m_dev);
	v4l2_device_unregister(&dev->v4l2_dev);
	platform_device_unregister(dev->pdev);
	idr_destroy(&dev->insts);
	kfree(dev);
}

module_init(ovd_init);
module_exit(ovd_exit);
MODULE_DESCRIPTION("OmacVM: V4L2 video decoder backed by a userspace daemon");
MODULE_LICENSE("GPL");
/* With a version, modpost records the source's checksum (srcversion): the
 * installer tells the loaded module from a newly built one by it. */
MODULE_VERSION("0.2");
MODULE_IMPORT_NS("DMA_BUF");
