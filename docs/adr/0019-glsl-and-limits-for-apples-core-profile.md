# 0019: GLSL and limits that Apple's core profile accepts

## Context

virglrenderer turns the guest's TGSI into GLSL and runs it on Apple's OpenGL 4.1
core profile. Upstream assumes a Linux driver: it writes `#version 130`/`140`,
asks for ARB extensions that are core in newer GLSL, reports 32 samplers per
stage and treats every host GL error as fatal (`check-gl-errors`). Apple refuses
GLSL 1.30, floatBitsToInt() below 3.30, extensions it does not list
(`GL_ARB_draw_instanced`, `GL_EXT_texture_shadow_lod`), more than 16 samplers per
stage and a framebuffer without attachments. Each refusal put the guest's whole
virgl context in error: dEQP-GLES3 in one process passed 455 of 896 cases (812 of
869 when restarted after each failure), Chrome drew black after its first bad
page (WebGL 1: 430 of 787 pages in one Chrome, 776 isolated).

## Options

1. Make host failures non-fatal everywhere (skip what the host refuses, build with
   `-Dcheck-gl-errors=false`). Hides the symptom, the refused work is still lost
   (black where the app drew), and every new gap stays invisible.
2. Fix the translation and the reported limits where they disagree with the Mac,
   one patch per gap, each with a build-time test on the Mac's own GL.
3. Rewrite emitted GLSL text before compiling (like the tap's
   `GL_EXT_shader_texture_lod` strip). Fragile, per symptom.

## Decision

Option 2, measured with the conformance harness without isolation (one dEQP
process, one Chrome):

- core profile shaders are at least `#version 330` (Apple supports 4.10), and no
  `#extension` line asks for what that version has in core (one table, used for
  every extension line);
- the blitter's shaders take their version from the blit context (4.00 on the Mac);
- shadow lookups ask for `GL_EXT_texture_shadow_lod` only for what it adds (lod
  forms, bias on array samplers);
- integer outputs (integer colour buffers, gl_SampleMask, gl_Layer...) are
  written like a float temporary and stored once with their bits, so no
  instruction needs to know the output's type (upstream bug that also hits
  Linux hosts; fixing it opcode by opcode kept missing cases). Not covered:
  integer outputs declared as an array range or with logic ops, and every
  output of a shader that reads or writes an output with an indirect index;
  they keep upstream's GLSL;
- a guest framebuffer without attachments gets a depth stand-in on hosts without
  `ARB_framebuffer_no_attachments`, as large as the first viewport, kept between
  framebuffer switches and freed when unused, with the depth test off while it
  is attached (as GL behaves without a depth buffer);
- the reported sampler limit is the smallest of the host's stages.
- (#589, 2026-10-31) clip distances on every desktop GL, not only on one with cull
  distances (the Mac has none): gl_ClipDistance is core GLSL there. The user clip
  planes' stores go into a shader variant for planes on (a key bit for the last
  vertex or tessellation evaluation shader, the geometry shader's existing one),
  so a shader drawn without planes keeps its GLSL; a last tessellation evaluation
  shader gets its y prescale and transform feedback stores as a vertex shader does;
  `GL_ARB_arrays_of_arrays` only where the GL has it; the tessellation output limits
  are reported without atomic counters. No setting either (architecture review
  2026-10-31): the same translation fixes, covered by text and GPU compile rows.

Option 1 stays useful as a safety net and is gpu-robust's track (ADR 0016: a
refused shader skips its draws, a lost context is reported to the guest).

## Consequences

- dEQP and WebGL pass rates in one process match the isolated ones (numbers in
  the graphics architecture document, "Shaders and limits on Apple's GL"). The
  whole dEQP-GLES3 list in one process: 21140 passed before, 42835 after.
- No setting: these are fixes of the translation, not a second path, so there
  is nothing to fall back to. GPU safe mode keeps them. Gaps not found yet are
  caught by gpu-robust's containment.
- GLSL 3.30 instead of 1.40/1.50 changes nothing for the guest: the translation
  writes no construct that 3.30 core removed; the build tests compile it.
- A framebuffer whose draw buffers are all GL_NONE costs a depth renderbuffer of
  the viewport's size (2 bytes a pixel, at most 8192x8192 = 128 MiB, kept while
  the guest switches back and forth, freed after 64 framebuffer changes or 4096
  draws without it); occlusion queries in it count every
  fragment. Before, the context died. The guest does not send its framebuffer's
  size (only with `VIRGL_CAP_FB_NO_ATTACH`), so a viewport larger than the
  framebuffer counts fragments outside it. Advertising that cap would give the
  exact size, but also give guests `ARB_framebuffer_no_attachments` with layers
  and samples to emulate: a later step if an app needs it.
- Guests see 16 samplers per stage instead of 32 (GLES 3.0 needs 16).
- Linux hosts: unchanged except the GLSL version on core profiles (3.30 where
  supported), no extension lines for what that version has in core, the blitter
  version and the integer outputs; all are spec-valid there too. Compute
  shaders keep their "#version 330" and their extension lines.
- What still fails in one process also fails isolated: real gaps (cube map
  filtering, one blit format conversion, WebGL pages listed in the architecture
  document), not a stopped context.
