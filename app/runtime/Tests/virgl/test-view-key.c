/* Sampler view slots and the shader key (virgl-legacy-vertex-cache.patch), without a GL
 * context: the renderer source is built in and the few GL calls of a view bind are stubbed.
 * Since a draw selects its shaders only when something marked them dirty, every change of
 * what vrend_fill_shader_key() reads from a bound view must set shader_dirty:
 *  - a texture buffer view with a swizzle the shader applies (L8 -> RRR1) replaced by one
 *    without (RGBA8), by no view, by a 2D view, or dropped by set_num_sampler_views;
 *  - a compute slot also sets cs_shader_dirty;
 *  - views without key bits swapped (2D for 2D, RGBA8 buffer for none) do not.
 * And vrend_view_key_bits() agrees with vrend_fill_shader_key(): two views give the same
 * key exactly when they give the same bits (so a new key input from views cannot be
 * missed silently).
 * The pixel case for this sits not in test-vertex-binds: on Apple's software renderer,
 * linking any program while a texture buffer is bound crashes in glBufferData (also
 * without these caches). */
#include "vrend/vrend_renderer.c"

static int failures;

static void check(int ok, const char *what)
{
   printf("%s: %s\n", ok ? "ok" : "FAIL", what);
   failures += !ok;
}

static void GLAPIENTRY nop_bind_texture(GLenum target, GLuint id)
{
   (void)target;
   (void)id;
}

static void GLAPIENTRY nop_tex_buffer(GLenum target, GLenum format, GLuint id)
{
   (void)target;
   (void)format;
   (void)id;
}

enum { V_L8 = 1, V_A8, V_RGBA8, V_2D, V_2D_B, V_RECT, V_COUNT };

static struct vrend_resource buffer = { .target = GL_TEXTURE_BUFFER, .gl_id = 7, .tbo_tex_id = 8,
                                        .storage_bits = VREND_STORAGE_GL_BUFFER };
static struct vrend_texture texture = { .base = { .target = GL_TEXTURE_2D, .gl_id = 9,
                                                  .storage_bits = VREND_STORAGE_GL_TEXTURE } };
static struct vrend_sampler_view views[V_COUNT];

static void make_views(struct vrend_sub_context *sub)
{
   static const struct { int id; enum virgl_formats format; bool buffer, rect; } v[] = {
      { V_L8, VIRGL_FORMAT_L8_UNORM, true, false },
      { V_A8, VIRGL_FORMAT_A8_UNORM, true, false },
      { V_RGBA8, VIRGL_FORMAT_R8G8B8A8_UNORM, true, false },
      { V_2D, VIRGL_FORMAT_R8G8B8A8_UNORM, false, false },
      { V_2D_B, VIRGL_FORMAT_L8_UNORM, false, false },
      { V_RECT, VIRGL_FORMAT_R8G8B8A8_UNORM, false, true },
   };
   for (unsigned i = 0; i < ARRAY_SIZE(v); i++) {
      struct vrend_sampler_view *view = &views[v[i].id];
      pipe_reference_init(&view->reference, 1);   /* the test's own: never freed */
      view->format = v[i].format;
      view->texture = v[i].buffer ? &buffer : &texture.base;
      view->target = view->texture->target;
      view->gl_id = 100 + v[i].id;                  /* not the texture's: no GL state */
      view->emulated_rect = v[i].rect;
      vrend_object_insert(sub->object_hash, view, v[i].id, VIRGL_OBJECT_SAMPLER_VIEW);
   }
}

/* bind view (0 = none) to slot 0 of stage, starting from a clean sub context */
static bool dirty_after(struct vrend_context *ctx, uint32_t stage, int from, int to,
                        bool *cs_dirty)
{
   vrend_set_single_sampler_view(ctx, stage, 0, from);
   ctx->sub->shader_dirty = false;
   ctx->sub->cs_shader_dirty = false;
   vrend_set_single_sampler_view(ctx, stage, 0, to);
   if (cs_dirty)
      *cs_dirty = ctx->sub->cs_shader_dirty;
   return ctx->sub->shader_dirty;
}

static void key_for(struct vrend_sub_context *sub, struct vrend_sampler_view *view,
                    struct vrend_shader_key *key)
{
   struct vrend_shader_selector fragment = { .type = PIPE_SHADER_FRAGMENT };
   struct vrend_sampler_view *old = sub->views[PIPE_SHADER_FRAGMENT].views[0];
   sub->views[PIPE_SHADER_FRAGMENT].views[0] = view;
   sub->views[PIPE_SHADER_FRAGMENT].max_num_views = 1;
   memset(key, 0, sizeof(*key));
   vrend_fill_shader_key(sub, &fragment, key);
   sub->views[PIPE_SHADER_FRAGMENT].views[0] = old;
}

int main(void)
{
   struct vrend_context ctx = { 0 };
   struct vrend_sub_context sub = { .parent = &ctx };
   char text[160];

   epoxy_glBindTexture = nop_bind_texture;
   epoxy_glTexBuffer = nop_tex_buffer;
   ctx.sub = &sub;
   ctx.shader_cfg.glsl_version = 410;
   vrend_state.use_core_profile = true;
   sub.object_hash = vrend_object_init_ctx_table();
   make_views(&sub);

   static const struct { uint32_t stage; int from, to; bool dirty; const char *what; } t[] = {
      { PIPE_SHADER_FRAGMENT, 0, V_L8, true, "no view -> L8 buffer (RRR1 in the shader)" },
      { PIPE_SHADER_FRAGMENT, V_L8, V_RGBA8, true, "L8 buffer -> RGBA8 buffer" },
      { PIPE_SHADER_FRAGMENT, V_L8, 0, true, "L8 buffer -> no view" },
      { PIPE_SHADER_FRAGMENT, V_L8, V_2D, true, "L8 buffer -> 2D texture" },
      { PIPE_SHADER_FRAGMENT, V_L8, V_A8, true, "L8 buffer -> A8 buffer (another swizzle)" },
      { PIPE_SHADER_FRAGMENT, V_2D, V_RECT, true, "2D texture -> emulated rectangle" },
      { PIPE_SHADER_FRAGMENT, V_RECT, 0, true, "emulated rectangle -> no view" },
      { PIPE_SHADER_FRAGMENT, V_2D, V_2D_B, false, "2D texture -> another 2D texture" },
      { PIPE_SHADER_FRAGMENT, 0, V_2D, false, "no view -> 2D texture" },
      { PIPE_SHADER_VERTEX, V_L8, V_2D, true, "vertex stage: L8 buffer -> 2D texture" },
   };
   for (unsigned i = 0; i < ARRAY_SIZE(t); i++) {
      bool dirty = dirty_after(&ctx, t[i].stage, t[i].from, t[i].to, NULL);
      snprintf(text, sizeof(text), "%s: %s", t[i].what,
               t[i].dirty ? "shaders marked dirty" : "nothing to select again");
      check(dirty == t[i].dirty, text);
   }
   bool cs_dirty = false;
   check(dirty_after(&ctx, PIPE_SHADER_COMPUTE, V_L8, 0, &cs_dirty) && cs_dirty,
         "compute stage: L8 buffer -> no view marks the compute shader dirty");

   /* set_num_sampler_views drops the slots past the new count */
   vrend_set_single_sampler_view(&ctx, PIPE_SHADER_FRAGMENT, 0, V_2D);
   vrend_set_single_sampler_view(&ctx, PIPE_SHADER_FRAGMENT, 1, V_L8);
   vrend_set_num_sampler_views(&ctx, PIPE_SHADER_FRAGMENT, 0, 2);
   sub.shader_dirty = false;
   vrend_set_num_sampler_views(&ctx, PIPE_SHADER_FRAGMENT, 0, 1);
   check(sub.shader_dirty, "set_num_sampler_views drops an L8 buffer slot: shaders marked dirty");
   vrend_set_num_sampler_views(&ctx, PIPE_SHADER_FRAGMENT, 0, 0);

   /* vrend_view_key_bits() and vrend_fill_shader_key() agree on every pair */
   struct vrend_sampler_view *all[V_COUNT] = { NULL };
   for (int i = 1; i < V_COUNT; i++)
      all[i] = &views[i];
   bool agree = true;
   for (int a = 0; a < V_COUNT; a++) {
      for (int b = 0; b < V_COUNT; b++) {
         struct vrend_shader_key ka, kb;
         key_for(&sub, all[a], &ka);
         key_for(&sub, all[b], &kb);
         bool same_key = !memcmp(&ka, &kb, sizeof(ka));
         bool same_bits = vrend_view_key_bits(all[a]) == vrend_view_key_bits(all[b]);
         if (same_key != same_bits) {
            printf("views %d and %d: same key %d, same key bits %d\n", a, b, same_key, same_bits);
            agree = false;
         }
      }
   }
   check(agree, "the key bits of a view change exactly when its part of the shader key does");

   printf("%s\n", failures ? "view key: FAILED" : "view key: all checks passed");
   return failures != 0;
}
