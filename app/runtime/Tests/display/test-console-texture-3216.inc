/*
 * 3.2.16's console texture code, for test-console-texture.sh --self-test in
 * CI (no QEMU source there): the texture helpers of QEMU's ui/console-gl.c
 * and the listeners of OmacVM's patched ui/cocoa.m before
 * qemu-cocoa-gl-console-texture-lazy.patch, copied as they were. The lazy
 * checks must fail on it. Not used by QEMU. GPL-2.0-or-later (QEMU) and MIT
 * (ui/console-gl.c), as the files they come from.
 */
static bool map_format(pixman_format_code_t format,
                       GLenum *glformat, GLenum *gltype)
{
    switch (format) {
    case PIXMAN_BE_b8g8r8x8:
    case PIXMAN_BE_b8g8r8a8:
        *glformat = GL_BGRA_EXT;
        *gltype = GL_UNSIGNED_BYTE;
        return true;
    case PIXMAN_BE_x8r8g8b8:
    case PIXMAN_BE_a8r8g8b8:
        *glformat = GL_RGBA;
        *gltype = GL_UNSIGNED_BYTE;
        return true;
    case PIXMAN_r5g6b5:
        *glformat = GL_RGB;
        *gltype = GL_UNSIGNED_SHORT_5_6_5;
        return true;
    default:
        return false;
    }
}

void surface_gl_create_texture(QemuGLShader *gls,
                               DisplaySurface *surface)
{
    GLenum glformat;
    GLenum gltype;

    assert(gls);
    assert(QEMU_IS_ALIGNED(surface_stride(surface), surface_bytes_per_pixel(surface)));

    if (surface->texture) {
        return;
    }

    assert(map_format(surface_format(surface), &glformat, &gltype));
    glGenTextures(1, &surface->texture);
    glEnable(GL_TEXTURE_2D);
    glBindTexture(GL_TEXTURE_2D, surface->texture);
    glPixelStorei(GL_UNPACK_ROW_LENGTH_EXT,
                  surface_stride(surface) / surface_bytes_per_pixel(surface));
    if (epoxy_is_desktop_gl()) {
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB,
                     surface_width(surface), surface_height(surface), 0,
                     glformat, gltype, surface_data(surface));
    } else {
        glTexImage2D(GL_TEXTURE_2D, 0, glformat,
                     surface_width(surface), surface_height(surface), 0,
                     glformat, gltype, surface_data(surface));
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_SWIZZLE_A, GL_ONE);
    }

    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
}

void surface_gl_update_texture(QemuGLShader *gls,
                               DisplaySurface *surface,
                               int x, int y, int w, int h)
{
    uint8_t *data = (void *)surface_data(surface);
    GLenum glformat;
    GLenum gltype;

    assert(gls);
    assert(map_format(surface_format(surface), &glformat, &gltype));

    if (surface->texture) {
        glBindTexture(GL_TEXTURE_2D, surface->texture);
        glPixelStorei(GL_UNPACK_ROW_LENGTH_EXT,
                      surface_stride(surface)
                      / surface_bytes_per_pixel(surface));
        glTexSubImage2D(GL_TEXTURE_2D, 0, x, y, w, h, glformat, gltype,
                        data + surface_stride(surface) * y
                        + surface_bytes_per_pixel(surface) * x);
    }
}

void surface_gl_destroy_texture(QemuGLShader *gls,
                                DisplaySurface *surface)
{
    if (!surface || !surface->texture) {
        return;
    }
    glDeleteTextures(1, &surface->texture);
    surface->texture = 0;
}

static bool omacvm_splash_enabled(void)
{
    if (omacvm_splash_on < 0) {
        const char *v = getenv("OMACVM_BOOT_SPLASH");
        omacvm_splash_on = !(v && !strcmp(v, "0"));
        info_report("cocoa: boot splash %s",
                    omacvm_splash_on ? "on" : "off (OMACVM_BOOT_SPLASH=0)");
    }
    return omacvm_splash_on;
}

static bool omacvm_splash_wanted(DisplayGLTextureBorrower borrow,
                                 DisplaySurface *s)
{
#ifdef CONFIG_EGL
    if (egl_surface) {
        return false;   /* the logo's texture is in the CGL contexts */
    }
#endif
    return !borrow && (!s || surface_is_placeholder(s)) &&
           omacvm_splash_enabled();
}

static void cocoa_gl_update(DisplayChangeListener *dcl,
                            int x, int y, int w, int h)
{
    with_gl_view_ctx(^{
        surface_gl_update_texture(dgc.gls, surface, x, y, w, h);
        gl_dirty = true;
    });
    cocoa_refresh_activity();
    omacvm_hold_dirty = true;
    /* OmacVM: a plain surface's frame (GPU safe mode) after a pause; QEMU's "not active" one is none. */
    if (surface && !surface_is_placeholder(surface)) {
        omacvm_gp_guest_frame();
    }
}
static void cocoa_gl_switch(DisplayChangeListener *dcl,
                            DisplaySurface *new_surface)
{
    with_gl_view_ctx(^{
        surface_gl_destroy_texture(dgc.gls, surface);
        surface_gl_create_texture(dgc.gls, new_surface);
    });

    cocoa_switch(dcl, new_surface);
    gl_dirty = true;
    cocoa_refresh_activity();
    omacvm_splash_update();
}
static void omacvm_head_gfx_update(DisplayChangeListener *dcl,
                                   int x, int y, int w, int h)
{
    OmacVMHead *hd = (OmacVMHead *)dcl;

    with_gl_view_ctx(^{
        surface_gl_update_texture(dgc.gls, hd->surface, x, y, w, h);
    });
    hd->dirty = true;
    cocoa_refresh_activity();
}
static void omacvm_head_gfx_switch(DisplayChangeListener *dcl,
                                   DisplaySurface *new_surface)
{
    OmacVMHead *hd = (OmacVMHead *)dcl;

    with_gl_view_ctx(^{
        surface_gl_destroy_texture(dgc.gls, hd->surface);
        if (new_surface) {
            surface_gl_create_texture(dgc.gls, new_surface);
        }
    });
    hd->surface = new_surface;
    hd->dirty = true;
    cocoa_refresh_activity();
}
