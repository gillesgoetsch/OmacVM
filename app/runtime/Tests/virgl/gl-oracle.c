/* GL oracle for the fuzzer: checks every draw call that virglrenderer makes against the
 * GL state at that moment and aborts when the GPU would read or write outside a buffer.
 *
 * Built as a dylib and linked into fuzz-cmd-stream / fuzz-replay: its __interpose
 * section replaces the draw entry points for every image, also those libepoxy looks up
 * with dlsym. Each check queries GL (no state tracking of its own), so it judges what
 * the driver really got, not what vrend believes it sent:
 *  - every enabled vertex attribute has a buffer (no client arrays) and the vertices
 *    and instances the draw fetches lie inside it; indexed draws read their indices back
 *    to find the largest one (primitive restart honoured);
 *  - indices come from a buffer and lie inside it;
 *  - every active uniform block of the current program has a buffer bound whose range
 *    from its start covers the block's data size;
 *  - while transform feedback is active, every bound range lies inside its buffer;
 *  - indirect draws: the command lies inside the indirect buffer, and the draw it
 *    describes passes the same checks;
 *  - no GL error is pending: a call the GL refused while the draw was set up (an
 *    attribute format, a buffer range) keeps older state that the checks above would
 *    judge by the wrong buffer, so vrend must have skipped the draw.
 * It also refuses to run unless the context is Apple's software renderer (soft-gl.h).
 * Test-only; never shipped. */
#define GL_SILENCE_DEPRECATION 1
#include <OpenGL/gl3.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef GL_PRIMITIVE_RESTART
#define GL_PRIMITIVE_RESTART 0x8F9D
#define GL_PRIMITIVE_RESTART_INDEX 0x8F9E
#endif
#ifndef GL_DRAW_INDIRECT_BUFFER_BINDING
#define GL_DRAW_INDIRECT_BUFFER_BINDING 0x8F43
#endif
#ifndef GL_VERTEX_ATTRIB_ARRAY_DIVISOR
#define GL_VERTEX_ATTRIB_ARRAY_DIVISOR 0x88FE
#endif

void glDrawArraysInstancedARB(GLenum, GLint, GLsizei, GLsizei);
void glDrawElementsInstancedARB(GLenum, GLsizei, GLenum, const void *, GLsizei);
void glDrawRangeElementsEXT(GLenum, GLuint, GLuint, GLsizei, GLenum, const void *);

static unsigned long draws_checked;

/* Draw calls that reached the GL so far (tests use it to see whether a draw was skipped). */
unsigned long gl_oracle_draws(void)
{
   return draws_checked;
}

__attribute__((format(printf, 1, 2)))
static void fail(const char *fmt, ...)
{
   va_list ap;
   va_start(ap, fmt);
   fprintf(stderr, "GL ORACLE: ");
   vfprintf(stderr, fmt, ap);
   fprintf(stderr, " (draw %lu)\n", draws_checked);
   va_end(ap);
   abort();
}

static void require_software(void)
{
   static int ok;
   if (ok)
      return;
   const char *name = (const char *)glGetString(GL_RENDERER);
   if (!name || strcmp(name, "Apple Software Renderer")) {
      fprintf(stderr, "GL ORACLE: renderer is \"%s\", refusing to draw on a GPU\n",
              name ? name : "(none)");
      abort();
   }
   ok = 1;
}

static uint64_t buffer_size(GLuint buf)
{
   GLint old = 0, size = 0;
   glGetIntegerv(GL_COPY_READ_BUFFER, &old);
   glBindBuffer(GL_COPY_READ_BUFFER, buf);
   glGetBufferParameteriv(GL_COPY_READ_BUFFER, GL_BUFFER_SIZE, &size);
   glBindBuffer(GL_COPY_READ_BUFFER, old);
   return (uint64_t)(uint32_t)size;
}

static void read_buffer(GLuint buf, uint64_t offset, uint64_t size, void *out)
{
   GLint old = 0;
   glGetIntegerv(GL_COPY_READ_BUFFER, &old);
   glBindBuffer(GL_COPY_READ_BUFFER, buf);
   glGetBufferSubData(GL_COPY_READ_BUFFER, offset, size, out);
   glBindBuffer(GL_COPY_READ_BUFFER, old);
}

static unsigned type_size(GLenum type)
{
   switch (type) {
   case GL_BYTE: case GL_UNSIGNED_BYTE: return 1;
   case GL_SHORT: case GL_UNSIGNED_SHORT: case GL_HALF_FLOAT: return 2;
   case GL_DOUBLE: return 8;
   default: return 4;
   }
}

/* Bytes one vertex of attribute i reads. */
static uint64_t attrib_bytes(GLuint i)
{
   GLint size = 0, type = 0;
   glGetVertexAttribiv(i, GL_VERTEX_ATTRIB_ARRAY_SIZE, &size);
   glGetVertexAttribiv(i, GL_VERTEX_ATTRIB_ARRAY_TYPE, &type);
   if (type == GL_INT_2_10_10_10_REV || type == GL_UNSIGNED_INT_2_10_10_10_REV ||
       type == GL_UNSIGNED_INT_10F_11F_11F_REV)
      return 4;
   if (size == GL_BGRA)
      size = 4;
   return (uint64_t)size * type_size(type);
}

/* max_vertex: largest vertex index fetched (base vertex applied), or -1 for none. */
static void check_vertices(int64_t max_vertex, uint64_t first_instance, uint64_t instances)
{
   GLint n = 0;
   glGetIntegerv(GL_MAX_VERTEX_ATTRIBS, &n);
   for (GLint i = 0; i < n && i < 32; i++) {
      GLint enabled = 0, buf = 0, stride = 0, divisor = 0;
      void *pointer = NULL;
      glGetVertexAttribiv(i, GL_VERTEX_ATTRIB_ARRAY_ENABLED, &enabled);
      if (!enabled)
         continue;
      glGetVertexAttribiv(i, GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING, &buf);
      if (!buf)
         fail("attribute %d enabled without a buffer (client array)", i);
      glGetVertexAttribiv(i, GL_VERTEX_ATTRIB_ARRAY_STRIDE, &stride);
      glGetVertexAttribiv(i, GL_VERTEX_ATTRIB_ARRAY_DIVISOR, &divisor);
      glGetVertexAttribPointerv(i, GL_VERTEX_ATTRIB_ARRAY_POINTER, &pointer);
      uint64_t elem = attrib_bytes(i);
      uint64_t step = stride ? (uint64_t)(uint32_t)stride : elem;
      int64_t last;
      if (divisor)
         last = instances ? (int64_t)(first_instance + (instances - 1) / (uint32_t)divisor) : -1;
      else
         last = instances ? max_vertex : -1;
      if (last < 0)
         continue;
      uint64_t end = (uint64_t)(uintptr_t)pointer + (uint64_t)last * step + elem;
      uint64_t size = buffer_size(buf);
      if (end > size)
         fail("attribute %d fetch ends at %llu, buffer has %llu bytes", i,
              (unsigned long long)end, (unsigned long long)size);
   }
}

static void check_uniform_blocks(void)
{
   GLint prog = 0, blocks = 0;
   glGetIntegerv(GL_CURRENT_PROGRAM, &prog);
   if (!prog)
      return;
   glGetProgramiv(prog, GL_ACTIVE_UNIFORM_BLOCKS, &blocks);
   for (GLint b = 0; b < blocks; b++) {
      GLint binding = 0, data_size = 0, buf = 0;
      GLint64 start = 0;
      glGetActiveUniformBlockiv(prog, b, GL_UNIFORM_BLOCK_BINDING, &binding);
      glGetActiveUniformBlockiv(prog, b, GL_UNIFORM_BLOCK_DATA_SIZE, &data_size);
      glGetIntegeri_v(GL_UNIFORM_BUFFER_BINDING, binding, &buf);
      if (!buf)
         fail("uniform block %d (binding %d) has no buffer", b, binding);
      glGetInteger64i_v(GL_UNIFORM_BUFFER_START, binding, &start);
      uint64_t size = buffer_size(buf);
      if ((uint64_t)start + (uint64_t)data_size > size)
         fail("uniform block %d reads up to %llu, buffer has %llu bytes", b,
              (unsigned long long)start + (unsigned)data_size, (unsigned long long)size);
   }
}

static void check_transform_feedback(void)
{
   GLint active = 0;
   glGetIntegerv(GL_TRANSFORM_FEEDBACK_BUFFER_ACTIVE, &active);
   if (!active)
      return;
   for (GLuint i = 0; i < 4; i++) {
      GLint buf = 0;
      GLint64 start = 0, size = 0;
      glGetIntegeri_v(GL_TRANSFORM_FEEDBACK_BUFFER_BINDING, i, &buf);
      if (!buf)
         continue;
      glGetInteger64i_v(GL_TRANSFORM_FEEDBACK_BUFFER_START, i, &start);
      glGetInteger64i_v(GL_TRANSFORM_FEEDBACK_BUFFER_SIZE, i, &size);
      uint64_t have = buffer_size(buf);
      if ((uint64_t)start + (uint64_t)size > have)
         fail("transform feedback range %u ends at %llu, buffer has %llu bytes", i,
              (unsigned long long)(start + size), (unsigned long long)have);
   }
}

static void check_common(void)
{
   require_software();
   draws_checked++;
   GLenum err = glGetError();
   if (err != GL_NO_ERROR)
      fail("GL error 0x%x pending at a draw: a refused call left older state in place", err);
   check_uniform_blocks();
   check_transform_feedback();
}

static void check_arrays(GLint first, GLsizei count, uint64_t first_instance, uint64_t instances)
{
   check_common();
   if (count <= 0)
      return;
   check_vertices((int64_t)first + count - 1, first_instance, instances);
}

static unsigned index_size(GLenum type)
{
   return type == GL_UNSIGNED_BYTE ? 1 : type == GL_UNSIGNED_SHORT ? 2 : 4;
}

static void check_elements(GLsizei count, GLenum type, const void *indices, GLint base_vertex,
                           uint64_t instances)
{
   check_common();
   if (count <= 0)
      return;
   GLint ebo = 0;
   glGetIntegerv(GL_ELEMENT_ARRAY_BUFFER_BINDING, &ebo);
   if (!ebo)
      fail("indexed draw without an index buffer (client indices at %p)", indices);
   unsigned isize = index_size(type);
   uint64_t offset = (uint64_t)(uintptr_t)indices;
   uint64_t bytes = (uint64_t)count * isize;
   uint64_t size = buffer_size(ebo);
   if (offset + bytes > size)
      fail("indices end at %llu, index buffer has %llu bytes",
           (unsigned long long)(offset + bytes), (unsigned long long)size);
   uint8_t *data = malloc(bytes);
   read_buffer(ebo, offset, bytes, data);
   GLint restart_on = 0, restart_index = 0;
   glGetIntegerv(GL_PRIMITIVE_RESTART, &restart_on);
   glGetIntegerv(GL_PRIMITIVE_RESTART_INDEX, &restart_index);
   int64_t max = -1;
   for (GLsizei i = 0; i < count; i++) {
      uint32_t v = isize == 1 ? data[i] : isize == 2 ? ((uint16_t *)data)[i] : ((uint32_t *)data)[i];
      if (restart_on && v == (uint32_t)restart_index)
         continue;
      int64_t vertex = (int64_t)v + base_vertex;
      if (vertex > max)
         max = vertex;
   }
   free(data);
   check_vertices(max, 0, instances);
}

static void read_indirect(const void *offset, uint64_t bytes, uint32_t *cmd)
{
   GLint buf = 0;
   glGetIntegerv(GL_DRAW_INDIRECT_BUFFER_BINDING, &buf);
   if (!buf)
      fail("indirect draw without an indirect buffer (offset %p)", offset);
   uint64_t size = buffer_size(buf);
   if ((uint64_t)(uintptr_t)offset + bytes > size)
      fail("indirect command ends at %llu, buffer has %llu bytes",
           (unsigned long long)((uintptr_t)offset + bytes), (unsigned long long)size);
   read_buffer(buf, (uint64_t)(uintptr_t)offset, bytes, cmd);
}

/* The checks above judge a draw by its ranges; the software renderer would then spend
 * minutes on a draw of billions of vertices. Such draws are checked, counted and not
 * rasterized (the fuzzer looks for bad ranges, not pixels). */
static int too_big(long long count, long long instances)
{
   if (instances < 1)
      instances = 1;
   return count > 0 && count * instances > (1 << 18);
}

static void o_DrawArrays(GLenum mode, GLint first, GLsizei count)
{
   check_arrays(first, count, 0, 1);
   if (too_big(count, 1))
      return;
   glDrawArrays(mode, first, count);
}

static void o_DrawArraysInstanced(GLenum mode, GLint first, GLsizei count, GLsizei instances)
{
   check_arrays(first, count, 0, instances > 0 ? instances : 0);
   if (too_big(count, instances))
      return;
   glDrawArraysInstanced(mode, first, count, instances);
}

static void o_DrawArraysInstancedARB(GLenum mode, GLint first, GLsizei count, GLsizei instances)
{
   check_arrays(first, count, 0, instances > 0 ? instances : 0);
   if (too_big(count, instances))
      return;
   glDrawArraysInstancedARB(mode, first, count, instances);
}

static void o_DrawElements(GLenum mode, GLsizei count, GLenum type, const void *indices)
{
   check_elements(count, type, indices, 0, 1);
   if (too_big(count, 1))
      return;
   glDrawElements(mode, count, type, indices);
}

static void o_DrawRangeElements(GLenum mode, GLuint start, GLuint end, GLsizei count, GLenum type,
                                const void *indices)
{
   check_elements(count, type, indices, 0, 1);
   if (too_big(count, 1))
      return;
   glDrawRangeElements(mode, start, end, count, type, indices);
}

static void o_DrawRangeElementsEXT(GLenum mode, GLuint start, GLuint end, GLsizei count,
                                   GLenum type, const void *indices)
{
   check_elements(count, type, indices, 0, 1);
   if (too_big(count, 1))
      return;
   glDrawRangeElementsEXT(mode, start, end, count, type, indices);
}

static void o_DrawElementsInstanced(GLenum mode, GLsizei count, GLenum type, const void *indices,
                                    GLsizei instances)
{
   check_elements(count, type, indices, 0, instances > 0 ? instances : 0);
   if (too_big(count, instances))
      return;
   glDrawElementsInstanced(mode, count, type, indices, instances);
}

static void o_DrawElementsInstancedARB(GLenum mode, GLsizei count, GLenum type,
                                       const void *indices, GLsizei instances)
{
   check_elements(count, type, indices, 0, instances > 0 ? instances : 0);
   if (too_big(count, instances))
      return;
   glDrawElementsInstancedARB(mode, count, type, indices, instances);
}

static void o_DrawElementsBaseVertex(GLenum mode, GLsizei count, GLenum type, const void *indices,
                                     GLint base)
{
   check_elements(count, type, indices, base, 1);
   if (too_big(count, 1))
      return;
   glDrawElementsBaseVertex(mode, count, type, (void *)indices, base);
}

static void o_DrawRangeElementsBaseVertex(GLenum mode, GLuint start, GLuint end, GLsizei count,
                                          GLenum type, const void *indices, GLint base)
{
   check_elements(count, type, indices, base, 1);
   if (too_big(count, 1))
      return;
   glDrawRangeElementsBaseVertex(mode, start, end, count, type, (void *)indices, base);
}

static void o_DrawElementsInstancedBaseVertex(GLenum mode, GLsizei count, GLenum type,
                                              const void *indices, GLsizei instances, GLint base)
{
   check_elements(count, type, indices, base, instances > 0 ? instances : 0);
   if (too_big(count, instances))
      return;
   glDrawElementsInstancedBaseVertex(mode, count, type, indices, instances, base);
}

static void o_DrawArraysIndirect(GLenum mode, const void *indirect)
{
   uint32_t cmd[4]; /* count, instances, first, base instance */
   read_indirect(indirect, sizeof(cmd), cmd);
   check_arrays((GLint)cmd[2], (GLsizei)cmd[0], cmd[3], cmd[1]);
   if (too_big(cmd[0], cmd[1]))
      return;
   glDrawArraysIndirect(mode, indirect);
}

static void o_DrawElementsIndirect(GLenum mode, GLenum type, const void *indirect)
{
   uint32_t cmd[5]; /* count, instances, first index, base vertex, base instance */
   read_indirect(indirect, sizeof(cmd), cmd);
   check_elements((GLsizei)cmd[0], type, (const void *)(uintptr_t)((uint64_t)cmd[2] * index_size(type)),
                  (GLint)cmd[3], cmd[1]);
   if (too_big(cmd[0], cmd[1]))
      return;
   glDrawElementsIndirect(mode, type, indirect);
}

static void o_DrawTransformFeedback(GLenum mode, GLuint id)
{
   (void)mode;
   (void)id;
   fail("glDrawTransformFeedback: vertex count unknown to the host");
}

#define I(f) { (const void *)o_##f, (const void *)gl##f }
__attribute__((used)) static const struct { const void *replacement, *original; } interposers[]
   __attribute__((section("__DATA,__interpose"))) = {
   I(DrawArrays), I(DrawArraysInstanced), I(DrawArraysInstancedARB),
   I(DrawElements), I(DrawRangeElements), I(DrawRangeElementsEXT),
   I(DrawElementsInstanced), I(DrawElementsInstancedARB), I(DrawElementsBaseVertex),
   I(DrawRangeElementsBaseVertex), I(DrawElementsInstancedBaseVertex),
   I(DrawArraysIndirect), I(DrawElementsIndirect), I(DrawTransformFeedback),
};
