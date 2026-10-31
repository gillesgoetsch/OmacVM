/* The consecutive binding walk of descriptor writes and copies (virgl-venus-descriptor-
 * limits.patch, vkr_set_walk_init/next; ADR 0065) against a plain model of the spec's
 * rule, on random layouts. CPU only: no Vulkan driver, no GPU.
 *
 * The model: from dstBinding on, the bindings with descriptors that match the first one
 * (type, stages, flags, immutable samplers or not; the first one always) are laid end to
 * end, up to the first one that does not match; bindings with no descriptors are skipped
 * (VUIDs VkWriteDescriptorSet-dstArrayElement-00321, descriptorCount-00317, -00318, -10776,
 * -10777). An update of `count` from element `first` fits when first + count lies inside
 * that row, and its parts are its runs per binding. Inline uniform blocks and empty updates
 * stay inside the first binding. Each random case checks the walk gives exactly the model's
 * parts (binding, first element, count, place in the write) or fails exactly where the
 * model does, and that every update the earlier rule took (first inside the first binding)
 * is still taken, with the same descriptors.
 *
 *   test-venus-descriptor-walk SEED [ITERATIONS]   (default 100000) */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "vkr_descriptor_set.h"

static uint64_t rng;
static uint32_t rnd(uint32_t n)
{
   rng = rng * 6364136223846793005ull + 1442695040888963407ull;
   return n ? (uint32_t)((rng >> 33) % n) : 0;
}

static uint32_t room_of(const struct vkr_set_layout_binding *b, uint32_t variable)
{
   return (b->flags & VK_DESCRIPTOR_BINDING_VARIABLE_DESCRIPTOR_COUNT_BIT) ? variable : b->count;
}

static bool same_kind(const struct vkr_set_layout_binding *a, const struct vkr_set_layout_binding *b)
{
   return a->type == b->type && a->stages == b->stages && a->flags == b->flags &&
          !a->immutable_planes == !b->immutable_planes;
}

/* the earlier rule (first inside the first binding): fits or not */
static bool old_rule(const struct vkr_set_layout *l, uint32_t index, uint32_t variable, uint32_t first,
                     uint32_t count)
{
   const struct vkr_set_layout_binding *b = &l->bindings[index];
   uint64_t room = room_of(b, variable);
   if (b->type == VK_DESCRIPTOR_TYPE_INLINE_UNIFORM_BLOCK)
      return !(first & 3) && !(count & 3) && (uint64_t)first + count <= room;
   if (first > room)
      return false;
   room -= first;
   for (uint32_t i = index + 1; room < count && i < l->binding_count; i++) {
      const struct vkr_set_layout_binding *next = &l->bindings[i];
      if (!next->count)
         continue;
      if (!same_kind(next, b))
         return false;
      room += room_of(next, variable);
   }
   return room >= count;
}

struct part {
   uint32_t index, element, count, offset;
};

/* the model's parts; -1 when the update does not fit */
static int model(const struct vkr_set_layout *l, uint32_t index, uint32_t variable, uint32_t first, uint32_t count,
                 struct part *out)
{
   const struct vkr_set_layout_binding *b0 = &l->bindings[index];
   const uint32_t room0 = room_of(b0, variable);
   if (b0->type == VK_DESCRIPTOR_TYPE_INLINE_UNIFORM_BLOCK || !count) {
      const bool ok = b0->type == VK_DESCRIPTOR_TYPE_INLINE_UNIFORM_BLOCK
                         ? !(first & 3) && !(count & 3) && (uint64_t)first + count <= room0
                         : first <= room0;
      if (!ok)
         return -1;
      out[0] = (struct part){ index, first, count, 0 };
      return 1;
   }
   /* the row of slots: (binding, element) */
   static uint32_t slot_binding[4096], slot_element[4096];
   uint32_t slots = 0;
   for (uint32_t i = index; i < l->binding_count; i++) {
      const struct vkr_set_layout_binding *b = &l->bindings[i];
      if (i != index && !b->count)
         continue;
      if (i != index && !same_kind(b, b0))
         break;
      for (uint32_t e = 0; e < room_of(b, variable) && slots < 4096; e++) {
         slot_binding[slots] = i;
         slot_element[slots] = e;
         slots++;
      }
   }
   if ((uint64_t)first + count > slots)
      return -1;
   int n = 0;
   for (uint32_t s = first; s < first + count; s++) {
      if (n && out[n - 1].index == slot_binding[s]) {
         out[n - 1].count++;
      } else {
         out[n] = (struct part){ slot_binding[s], slot_element[s], 1, s - first };
         n++;
      }
   }
   return n;
}

static const VkDescriptorType types[] = { VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                                          VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                                          VK_DESCRIPTOR_TYPE_INLINE_UNIFORM_BLOCK };

int main(int argc, char **argv)
{
   if (argc < 2) {
      printf("usage: test-venus-descriptor-walk SEED [ITERATIONS]\n");
      return 2;
   }
   const uint64_t seed = strtoull(argv[1], NULL, 0);
   const uint32_t iterations = argc > 2 ? (uint32_t)strtoul(argv[2], NULL, 0) : 100000;
   rng = seed * 2654435761u + 1;
   struct vkr_set_layout *l = calloc(1, sizeof(*l) + 16 * sizeof(l->bindings[0]));
   uint32_t fits = 0, later = 0, split = 0, failures = 0;
   for (uint32_t it = 0; it < iterations && failures < 10; it++) {
      l->binding_count = 1 + rnd(8);
      uint32_t number = rnd(3);
      /* mostly one kind, so updates often run on; sometimes another kind in between */
      const VkDescriptorType main_type = types[rnd(4)];
      for (uint32_t i = 0; i < l->binding_count; i++) {
         struct vkr_set_layout_binding *b = &l->bindings[i];
         memset(b, 0, sizeof(*b));
         b->binding = number;
         number += 1 + (rnd(4) == 0);
         b->type = rnd(5) ? main_type : types[rnd(4)];
         b->count = b->type == VK_DESCRIPTOR_TYPE_INLINE_UNIFORM_BLOCK ? 4 * rnd(5) : rnd(6);
         b->stages = rnd(8) ? VK_SHADER_STAGE_ALL : VK_SHADER_STAGE_FRAGMENT_BIT;
         b->flags = rnd(10) ? 0 : VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT;
         if (b->type == VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER)
            b->immutable_planes = (uint8_t)(rnd(3) == 0 ? 0 : rnd(3) == 0 ? 3 : 1);
      }
      if (rnd(4) == 0)
         l->bindings[l->binding_count - 1].flags |= VK_DESCRIPTOR_BINDING_VARIABLE_DESCRIPTOR_COUNT_BIT;
      const uint32_t variable = rnd(7);
      const uint32_t index = rnd(l->binding_count);
      const uint32_t first = rnd(14), count = rnd(10);

      struct part want[64], got[64];
      const int n_want = model(l, index, variable, first, count, want);
      struct vkr_set_walk walk;
      struct vkr_set_part p;
      vkr_set_walk_init(&walk, l, variable, index, first, count);
      int n_got = 0;
      while (vkr_set_walk_next(&walk, &p) && n_got < 64)
         got[n_got++] = (struct part){ p.index, p.element, p.count, p.offset };
      const int n_walk = walk.failed ? -1 : n_got;
      bool ok = n_walk == n_want;
      for (int i = 0; ok && i < n_want; i++)
         ok = !memcmp(&got[i], &want[i], sizeof(want[i]));
      const bool before = old_rule(l, index, variable, first, count);
      if (before && n_walk < 0)
         ok = false; /* the earlier rule took it */
      if (!ok) {
         failures++;
         printf("FAIL: seed %llu case %u: binding index %u first %u count %u variable %u: walk %d parts, "
                "model %d, earlier rule %s\n", (unsigned long long)seed, it, index, first, count, variable,
                n_walk, n_want, before ? "fits" : "does not fit");
         for (uint32_t i = 0; i < l->binding_count; i++)
            printf("   binding %u: type %d count %u stages 0x%x flags 0x%x planes %u\n", l->bindings[i].binding,
                   l->bindings[i].type, l->bindings[i].count, l->bindings[i].stages, l->bindings[i].flags,
                   l->bindings[i].immutable_planes);
      }
      fits += n_walk >= 0;
      later += n_walk >= 0 && !before;
      split += n_walk > 1;
   }
   printf("%s: seed %llu, %u updates: %u fit (%u split per binding, %u starting past their binding)\n",
          failures ? "FAILED" : "all ok", (unsigned long long)seed, iterations, fits, split, later);
   free(l);
   return failures != 0;
}
