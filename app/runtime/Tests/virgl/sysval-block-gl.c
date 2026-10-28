/* GL stand-in for test-sysval-block: a dylib whose __interpose section replaces
 * glGetActiveUniformBlockiv (also where libepoxy looks it up with dlsym), so the test can
 * make the GL's answer for a program's VirglBlock fail (#547):
 *  1 the query fails as on a GL that refuses calls: a GL error, nothing written;
 *  2 the GL reports a block smaller than vrend's sysval block (16 bytes).
 * Status queries that write nothing, as on such a GL (gl_status_fault):
 *  1 a shader's compile status and its info log;
 *  2 a program pipeline's validate status;
 *  3 a program's link status and its info log.
 * It also counts the glDrawArrays calls that reach the GL and every VirglBlock size
 * query. Test-only; never shipped. */
#define GL_SILENCE_DEPRECATION 1
#include <OpenGL/gl3.h>
#include <string.h>

static int fault, status_fault;
static unsigned long faults_done, draws, block_queries, status_faults_done;

void sysval_block_fault(int mode)
{
   fault = mode;
}

unsigned long sysval_block_faults(void)
{
   return faults_done;
}

unsigned long sysval_block_draws(void)
{
   return draws;
}

unsigned long sysval_block_queries(void)
{
   return block_queries;
}

void gl_status_fault(int mode)
{
   status_fault = mode;
}

unsigned long gl_status_faults(void)
{
   return status_faults_done;
}

static void stand_in_GetActiveUniformBlockiv(GLuint program, GLuint index, GLenum pname,
                                             GLint *params)
{
   if (fault && pname == GL_UNIFORM_BLOCK_DATA_SIZE) {
      char name[32] = "";
      GLsizei len = 0;
      glGetActiveUniformBlockName(program, index, sizeof(name), &len, name);
      if (!strcmp(name, "VirglBlock")) {
         block_queries++;
         faults_done++;
         if (fault == 1) {
            /* an index past the program's blocks: GL_INVALID_VALUE, params untouched */
            glGetActiveUniformBlockiv(program, 0x7fffffff, pname, params);
            return;
         }
         *params = 16;
         return;
      }
   }
   if (pname == GL_UNIFORM_BLOCK_DATA_SIZE) {
      char name[32] = "";
      GLsizei len = 0;
      glGetActiveUniformBlockName(program, index, sizeof(name), &len, name);
      block_queries += !strcmp(name, "VirglBlock");
   }
   glGetActiveUniformBlockiv(program, index, pname, params);
}

static void stand_in_GetShaderiv(GLuint shader, GLenum pname, GLint *params)
{
   if (status_fault == 1 && pname == GL_COMPILE_STATUS) {
      status_faults_done++;
      return;
   }
   glGetShaderiv(shader, pname, params);
}

static void stand_in_GetShaderInfoLog(GLuint shader, GLsizei size, GLsizei *length,
                                      GLchar *log)
{
   if (status_fault == 1) {
      status_faults_done++;
      return;
   }
   glGetShaderInfoLog(shader, size, length, log);
}

static void stand_in_GetProgramiv(GLuint program, GLenum pname, GLint *params)
{
   if (status_fault == 3 && pname == GL_LINK_STATUS) {
      status_faults_done++;
      return;
   }
   glGetProgramiv(program, pname, params);
}

static void stand_in_GetProgramInfoLog(GLuint program, GLsizei size, GLsizei *length,
                                       GLchar *log)
{
   if (status_fault == 3) {
      status_faults_done++;
      return;
   }
   glGetProgramInfoLog(program, size, length, log);
}

static void stand_in_GetProgramPipelineiv(GLuint pipeline, GLenum pname, GLint *params)
{
   if (status_fault == 2 && pname == GL_VALIDATE_STATUS) {
      status_faults_done++;
      return;
   }
   glGetProgramPipelineiv(pipeline, pname, params);
}

static void stand_in_DrawArrays(GLenum mode, GLint first, GLsizei count)
{
   draws++;
   glDrawArrays(mode, first, count);
}

__attribute__((used)) static const struct {
   const void *replacement;
   const void *replacee;
} interposers[] __attribute__((section("__DATA,__interpose"))) = {
   { (const void *)stand_in_GetActiveUniformBlockiv, (const void *)glGetActiveUniformBlockiv },
   { (const void *)stand_in_DrawArrays, (const void *)glDrawArrays },
   { (const void *)stand_in_GetShaderiv, (const void *)glGetShaderiv },
   { (const void *)stand_in_GetShaderInfoLog, (const void *)glGetShaderInfoLog },
   { (const void *)stand_in_GetProgramiv, (const void *)glGetProgramiv },
   { (const void *)stand_in_GetProgramInfoLog, (const void *)glGetProgramInfoLog },
   { (const void *)stand_in_GetProgramPipelineiv, (const void *)glGetProgramPipelineiv },
};
