/*
 * va-shim-interlaced: OmacVM's VA driver shim (omacvm_drv_video.c, "H.264 coded interlaced")
 * refuses H.264 pictures coded as fields or MBAFF frames. Built twice by
 * va-shim-interlaced.sh: with -DSTUB_DRIVER as a stand-in for Mesa's driver (config 0
 * decodes H.264 High, 1 decodes HEVC Main, 2 encodes H.264, 3 is video processing; buffers
 * kept in memory) that counts every picture begun, every vaRenderPicture and vaEndPicture it
 * gets, and every H.264 picture parameter buffer with frame_mbs_only_flag 0 that reaches it,
 * (context IDs that were freed come back first, as in Mesa's handle table) and as the program
 * that loads the shim against it.
 *   va-shim-interlaced SHIM STUB on|off [ARGS...]
 * on: an H.264 decoder's picture whose picture parameters say frame_mbs_only_flag 0 (MBAFF
 * frames, field pictures) is refused at its vaRenderPicture with VA_STATUS_ERROR_UNIMPLEMENTED
 * before Mesa sees it, and so are its later vaRenderPicture (slices) and vaEndPicture: Mesa
 * gets none of it, nothing goes to the Mac. Its next progressive picture decodes. Parameters
 * and slices in one vaRenderPicture (GStreamer) are refused together. HEVC decoders, H.264
 * encoders and video processing are not looked at. off (OMACVM_VA_INTERLACED=1): Mesa gets
 * the interlaced pictures (as before the shim refused them).
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <va/va.h>
#include <va/va_backend.h>

#define MAX_IDS 4096

#ifdef STUB_DRIVER
int begun, renders, ends;   /* every picture begun, vaRenderPicture, vaEndPicture Mesa got */
int interlaced_params;      /* H.264 picture parameters with frame_mbs_only_flag 0 that reached Mesa */

static int context_config[MAX_IDS];
static VASurfaceID next_surface;
static VAContextID next_context, free_context = VA_INVALID_ID;
static struct buf { VABufferType type; unsigned size, count; void *data; } bufs[MAX_IDS];
static VABufferID next_buf = 1;

static VAStatus create_surfaces2(VADriverContextP ctx, unsigned int format, unsigned int w,
                                 unsigned int h, VASurfaceID *s, unsigned int n,
                                 VASurfaceAttrib *a, unsigned int na)
{
    (void)ctx; (void)format; (void)w; (void)h; (void)a; (void)na;
    for (unsigned i = 0; i < n; i++)
        s[i] = next_surface++;
    return VA_STATUS_SUCCESS;
}

static VAStatus destroy_surfaces(VADriverContextP ctx, VASurfaceID *s, int n)
{
    (void)ctx; (void)s; (void)n;
    return VA_STATUS_SUCCESS;
}

static VAStatus query_config_attributes(VADriverContextP ctx, VAConfigID config, VAProfile *profile,
                                        VAEntrypoint *entrypoint, VAConfigAttrib *a, int *n)
{
    static const VAProfile profiles[] = { VAProfileH264High, VAProfileHEVCMain, VAProfileH264High,
                                          VAProfileNone };
    static const VAEntrypoint entrypoints[] = { VAEntrypointVLD, VAEntrypointVLD,
                                                VAEntrypointEncSlice, VAEntrypointVideoProc };
    (void)ctx; (void)a;
    if (config > 3)
        return VA_STATUS_ERROR_INVALID_CONFIG;
    *profile = profiles[config];
    *entrypoint = entrypoints[config];
    *n = 0;
    return VA_STATUS_SUCCESS;
}

static VAStatus create_context(VADriverContextP ctx, VAConfigID config, int w, int h, int flag,
                               VASurfaceID *t, int nt, VAContextID *context)
{
    (void)ctx; (void)w; (void)h; (void)flag; (void)t; (void)nt;
    if (free_context != VA_INVALID_ID) {
        *context = free_context;
        free_context = VA_INVALID_ID;
    } else {
        *context = next_context++;
    }
    if (*context < MAX_IDS)
        context_config[*context] = (int)config;
    return VA_STATUS_SUCCESS;
}

static VAStatus destroy_context(VADriverContextP ctx, VAContextID c)
{
    (void)ctx;
    free_context = c;
    return VA_STATUS_SUCCESS;
}

static VAStatus terminate(VADriverContextP ctx) { (void)ctx; return VA_STATUS_SUCCESS; }

static VAStatus create_buffer(VADriverContextP ctx, VAContextID c, VABufferType type,
                              unsigned int size, unsigned int count, void *data, VABufferID *id)
{
    (void)ctx; (void)c;
    if (next_buf >= MAX_IDS)
        return VA_STATUS_ERROR_ALLOCATION_FAILED;
    bufs[next_buf] = (struct buf){ type, size, count, calloc(count ? count : 1, size) };
    if (data)
        memcpy(bufs[next_buf].data, data, (size_t)size * count);
    *id = next_buf++;
    return VA_STATUS_SUCCESS;
}

static VAStatus buffer_info(VADriverContextP ctx, VABufferID id, VABufferType *type,
                            unsigned int *size, unsigned int *count)
{
    (void)ctx;
    if (!id || id >= next_buf)
        return VA_STATUS_ERROR_INVALID_BUFFER;
    *type = bufs[id].type;
    *size = bufs[id].size;
    *count = bufs[id].count;
    return VA_STATUS_SUCCESS;
}

static VAStatus map_buffer(VADriverContextP ctx, VABufferID id, void **p)
{
    (void)ctx;
    if (!id || id >= next_buf)
        return VA_STATUS_ERROR_INVALID_BUFFER;
    *p = bufs[id].data;
    return VA_STATUS_SUCCESS;
}

static VAStatus unmap_buffer(VADriverContextP ctx, VABufferID id)
{
    (void)ctx; (void)id;
    return VA_STATUS_SUCCESS;
}

static VAStatus destroy_buffer(VADriverContextP ctx, VABufferID id)
{
    (void)ctx; (void)id;
    return VA_STATUS_SUCCESS;
}

static VAStatus begin_picture(VADriverContextP ctx, VAContextID c, VASurfaceID t)
{
    (void)ctx; (void)c; (void)t;
    begun++;
    return VA_STATUS_SUCCESS;
}

static VAStatus render_picture(VADriverContextP ctx, VAContextID c, VABufferID *b, int n)
{
    (void)ctx;
    renders++;
    for (int i = 0; i < n; i++)
        if (c < MAX_IDS && context_config[c] == 0 && b[i] < next_buf &&
            bufs[b[i]].type == VAPictureParameterBufferType &&
            !((VAPictureParameterBufferH264 *)bufs[b[i]].data)->seq_fields.bits.frame_mbs_only_flag)
            interlaced_params++;
    return VA_STATUS_SUCCESS;
}

static VAStatus end_picture(VADriverContextP ctx, VAContextID c)
{
    (void)ctx; (void)c;
    ends++;
    return VA_STATUS_SUCCESS;
}

VAStatus __vaDriverInit_1_20(VADriverContextP ctx)
{
    ctx->str_vendor = "Mesa Gallium driver 26.2.5 for virgl (stand-in)";
    ctx->vtable->vaCreateSurfaces2 = create_surfaces2;
    ctx->vtable->vaDestroySurfaces = destroy_surfaces;
    ctx->vtable->vaQueryConfigAttributes = query_config_attributes;
    ctx->vtable->vaCreateContext = create_context;
    ctx->vtable->vaDestroyContext = destroy_context;
    ctx->vtable->vaTerminate = terminate;
    ctx->vtable->vaCreateBuffer = create_buffer;
    ctx->vtable->vaBufferInfo = buffer_info;
    ctx->vtable->vaMapBuffer = map_buffer;
    ctx->vtable->vaUnmapBuffer = unmap_buffer;
    ctx->vtable->vaDestroyBuffer = destroy_buffer;
    ctx->vtable->vaBeginPicture = begin_picture;
    ctx->vtable->vaRenderPicture = render_picture;
    ctx->vtable->vaEndPicture = end_picture;
    return VA_STATUS_SUCCESS;
}
#else
static int failed;
static struct VADriverVTable vt;
static struct VADriverContext dc;
static int *begun, *renders, *ends, *interlaced_params;

static void check(int ok, const char *what)
{
    printf("%s: %s\n", ok ? "ok" : "FAIL", what);
    failed |= !ok;
}

enum coding { PROGRESSIVE, MBAFF, FIELD };

/* One picture on CONTEXT into TARGET as FFmpeg's VA-API decoder sends it (begin; picture
 * parameters; slice parameters and data; end), or with ONE_CALL all buffers in one
 * vaRenderPicture (GStreamer). For an H.264 decoder the picture parameters say the CODING;
 * other contexts get a zeroed buffer of the same size (an HEVC decoder's parameters read as
 * H.264 would say frame_mbs_only_flag 0). REFUSED: the picture's renders and end come back
 * VA_STATUS_ERROR_UNIMPLEMENTED and Mesa gets neither; else all pass on. */
static void picture(VAContextID context, VASurfaceID target, int h264, enum coding coding,
                    int one_call, int refused, const char *what)
{
    VAPictureParameterBufferH264 pp;
    VASliceParameterBufferH264 sp;
    unsigned char data[64] = { 0, 0, 1, 0x65 };
    VABufferID b[3];
    VAStatus sb, sr1, sr2 = VA_STATUS_SUCCESS, se;
    int g = *begun, r = *renders, e = *ends, il = *interlaced_params;
    char line[400];

    memset(&pp, 0, sizeof(pp));
    memset(&sp, 0, sizeof(sp));
    if (h264) {
        pp.picture_width_in_mbs_minus1 = 44;
        pp.picture_height_in_mbs_minus1 = coding == FIELD ? 17 : 35;
        pp.seq_fields.bits.chroma_format_idc = 1;
        pp.seq_fields.bits.frame_mbs_only_flag = coding == PROGRESSIVE;
        pp.seq_fields.bits.mb_adaptive_frame_field_flag = coding == MBAFF;
        pp.seq_fields.bits.direct_8x8_inference_flag = 1;
        pp.pic_fields.bits.field_pic_flag = coding == FIELD;
        pp.CurrPic.flags = coding == FIELD ? VA_PICTURE_H264_TOP_FIELD : 0;
    }
    sp.slice_data_size = sizeof(data);
    vt.vaCreateBuffer(&dc, context, VAPictureParameterBufferType, sizeof(pp), 1, &pp, &b[0]);
    vt.vaCreateBuffer(&dc, context, VASliceParameterBufferType, sizeof(sp), 1, &sp, &b[1]);
    vt.vaCreateBuffer(&dc, context, VASliceDataBufferType, sizeof(data), 1, data, &b[2]);

    sb = vt.vaBeginPicture(&dc, context, target);
    if (one_call) {
        sr1 = vt.vaRenderPicture(&dc, context, b, 3);
    } else {
        sr1 = vt.vaRenderPicture(&dc, context, &b[0], 1);
        sr2 = vt.vaRenderPicture(&dc, context, &b[1], 2);
    }
    se = vt.vaEndPicture(&dc, context);
    for (int i = 0; i < 3; i++)
        vt.vaDestroyBuffer(&dc, b[i]);

    snprintf(line, sizeof(line), "%s: begin/render/render/end status %d/%d/%d/%d, Mesa got "
             "%d begun, %d renders, %d ends, %d interlaced parameters (expected: %s)", what, sb,
             sr1, sr2, se, *begun - g, *renders - r, *ends - e, *interlaced_params - il,
             refused ? "renders and end refused, Mesa only the begin" : "all passed on");
    if (refused)
        check(sb == VA_STATUS_SUCCESS && sr1 == VA_STATUS_ERROR_UNIMPLEMENTED &&
              (one_call || sr2 == VA_STATUS_ERROR_UNIMPLEMENTED) &&
              se == VA_STATUS_ERROR_UNIMPLEMENTED && *begun == g + 1 && *renders == r &&
              *ends == e && *interlaced_params == il, line);
    else
        check(sb == VA_STATUS_SUCCESS && sr1 == VA_STATUS_SUCCESS && sr2 == VA_STATUS_SUCCESS &&
              se == VA_STATUS_SUCCESS && *begun == g + 1 && *renders == r + (one_call ? 1 : 2) &&
              *ends == e + 1, line);
}

int main(int argc, char **argv)
{
    VAStatus (*init)(VADriverContextP);
    char what[200];

    if (argc < 4)
        return 2;
    void *stub = dlopen(argv[2], RTLD_NOW | RTLD_GLOBAL);
    void *shim = dlopen(argv[1], RTLD_NOW);
    if (!stub || !shim) {
        fprintf(stderr, "dlopen: %s\n", dlerror());
        return 2;
    }
    begun = dlsym(stub, "begun");
    renders = dlsym(stub, "renders");
    ends = dlsym(stub, "ends");
    interlaced_params = dlsym(stub, "interlaced_params");
    init = (VAStatus (*)(VADriverContextP))dlsym(shim, "__vaDriverInit_1_20");
    dc.vtable = &vt;
    dc.max_attributes = 4;
    if (!begun || !renders || !ends || !interlaced_params || !init || init(&dc) != VA_STATUS_SUCCESS) {
        fprintf(stderr, "the shim did not load the stand-in driver\n");
        return 2;
    }

    VASurfaceID s[2];
    VAContextID h264, hevc, enc, proc;
    vt.vaCreateSurfaces2(&dc, VA_RT_FORMAT_YUV420, 720, 576, s, 2, NULL, 0);
    vt.vaCreateContext(&dc, 0, 720, 576, VA_PROGRESSIVE, s, 2, &h264);
    vt.vaCreateContext(&dc, 1, 720, 576, VA_PROGRESSIVE, s, 2, &hevc);
    vt.vaCreateContext(&dc, 2, 720, 576, VA_PROGRESSIVE, s, 2, &enc);
    vt.vaCreateContext(&dc, 3, 720, 576, VA_PROGRESSIVE, s, 2, &proc);

    if (!strcmp(argv[3], "off")) {
        /* the switch: the interlaced picture goes to Mesa (and to the Mac) */
        picture(h264, s[0], 1, MBAFF, 0, 0, "switch on: an MBAFF picture reaches Mesa");
        snprintf(what, sizeof(what), "switch on: Mesa got its interlaced parameters (%d)",
                 *interlaced_params);
        check(*interlaced_params == 1, what);
        vt.vaTerminate(&dc);
        return failed;
    }

    picture(h264, s[0], 1, PROGRESSIVE, 0, 0, "H.264 coded as frames");
    picture(h264, s[1], 1, MBAFF, 0, 1, "H.264 MBAFF frame (x264's interlaced coding)");
    picture(h264, s[0], 1, FIELD, 0, 1, "H.264 field picture (PAFF)");
    picture(h264, s[1], 1, FIELD, 1, 1, "H.264 field picture, parameters and slices in one call");
    picture(h264, s[0], 1, PROGRESSIVE, 0, 0, "the same decoder, a picture coded as a frame again");
    picture(h264, s[0], 1, PROGRESSIVE, 1, 0, "a frame, parameters and slices in one call");
    picture(hevc, s[0], 0, PROGRESSIVE, 0, 0, "HEVC decoder (its parameters are not H.264's)");
    picture(enc, s[0], 0, PROGRESSIVE, 0, 0, "H.264 encoder");
    picture(proc, s[1], 0, PROGRESSIVE, 0, 0, "video processing");

    /* the H.264 decoder's ID comes back for an HEVC decoder: not looked at; and back again
     * for an H.264 decoder: looked at */
    vt.vaDestroyContext(&dc, h264);
    VAContextID hevc2, h264b;
    vt.vaCreateContext(&dc, 1, 720, 576, VA_PROGRESSIVE, s, 2, &hevc2);
    snprintf(what, sizeof(what), "the H.264 decoder's ID (%u) back for an HEVC decoder (%u)", h264, hevc2);
    check(hevc2 == h264, what);
    picture(hevc2, s[0], 0, PROGRESSIVE, 0, 0, what);
    vt.vaDestroyContext(&dc, hevc2);
    vt.vaCreateContext(&dc, 0, 720, 576, VA_PROGRESSIVE, s, 2, &h264b);
    snprintf(what, sizeof(what), "and back for an H.264 decoder (%u): MBAFF refused", h264b);
    picture(h264b, s[1], 1, MBAFF, 0, 1, what);

    snprintf(what, sizeof(what), "no interlaced H.264 parameters reached Mesa (%d)", *interlaced_params);
    check(*interlaced_params == 0, what);
    vt.vaTerminate(&dc);
    if (failed) {
        printf("va-shim-interlaced: FAILED\n");
        return 1;
    }
    return 0;
}
#endif
