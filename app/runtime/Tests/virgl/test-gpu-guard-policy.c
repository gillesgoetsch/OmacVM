/* The rules of the desktop reserve (virgl-gpu-guard-desktop-reserve.patch,
 * src/virgl_gpu_guard.h): how big the reserve is on each Mac, how far apps, the
 * desktop and screens may go, what a resource made before its context is known
 * becomes, and which contexts are the desktop's. And the grace at critical memory
 * pressure (virgl-gpu-guard-critical-grace.patch): how far the guest's GPU memory may
 * grow past what was in use when critical began, and that replacing buffers always
 * fits. No GL, no renderer: CI and the runtime build run it (test-gpu-guard-policy.sh). */
#include <stdio.h>
#include <stdint.h>
#include "virgl_gpu_guard.h"

#define MB (1ull << 20)
#define GB (1ull << 30)

static int failures;

static void check(int ok, const char *what)
{
   printf("%s: %s\n", ok ? "ok" : "FAIL", what);
   failures += !ok;
}

static const char *verdict_name(enum virgl_gpu_guard_verdict v)
{
   return v == VIRGL_GPU_GUARD_FITS ? "fits" : v == VIRGL_GPU_GUARD_DESKTOP_ONLY ? "desktop only" : "refused";
}

static void expect(const char *what, enum virgl_gpu_guard_verdict want, uint64_t in_use, uint64_t size,
                   uint64_t budget, uint64_t reserve, enum virgl_gpu_guard_who who, int room)
{
   char line[256];
   enum virgl_gpu_guard_verdict got = virgl_gpu_guard_verdict(in_use, size, budget, reserve, who, room);
   snprintf(line, sizeof line, "%s: %s (want %s)", what, verdict_name(got), verdict_name(want));
   check(got == want, line);
}

int main(void)
{
   /* the reserve: a sixteenth of the Mac, 512 MB to 2 GB, at most a quarter of the budget */
   check(virgl_gpu_guard_reserve(8 * GB, 6 * GB) == 512 * MB, "8 GB Mac (budget 6 GB): 512 MB for the desktop");
   check(virgl_gpu_guard_reserve(16 * GB, 12 * GB) == 1 * GB, "16 GB Mac: 1 GB");
   check(virgl_gpu_guard_reserve(24 * GB, 18 * GB) == 1536 * MB, "24 GB Mac: 1.5 GB");
   check(virgl_gpu_guard_reserve(64 * GB, 48 * GB) == 2 * GB, "64 GB Mac: 2 GB (the most)");
   check(virgl_gpu_guard_reserve(4 * GB, 3 * GB) == 512 * MB, "4 GB: still 512 MB (the least)");
   check(virgl_gpu_guard_reserve(16 * GB, 64 * MB) == 16 * MB, "a 64 MB budget: a quarter of it, 16 MB");
   check(virgl_gpu_guard_reserve(16 * GB, 0) == 0, "no budget: no reserve");

   /* the limits on an 8 GB Mac: budget 6 GB, reserve 512 MB */
   uint64_t b = 6 * GB, r = 512 * MB;
   check(virgl_gpu_guard_limit(b, r, VIRGL_GPU_GUARD_APP) == 6 * GB - 512 * MB, "apps stop at 5.5 GB");
   check(virgl_gpu_guard_limit(b, r, VIRGL_GPU_GUARD_UNKNOWN) == 6 * GB - 512 * MB,
         "a resource of a context not known yet: also 5.5 GB as an app's");
   check(virgl_gpu_guard_limit(b, r, VIRGL_GPU_GUARD_DESKTOP) == 6 * GB, "the desktop: the whole 6 GB");
   check(virgl_gpu_guard_limit(b, r, VIRGL_GPU_GUARD_DISPLAY) == 6 * GB + 256 * MB,
         "screens and cursors: 256 MB past the budget");
   check(virgl_gpu_guard_limit(0, r, VIRGL_GPU_GUARD_APP) == UINT64_MAX, "no budget: no limit");
   check(virgl_gpu_guard_limit(64 * MB, 60 * MB, VIRGL_GPU_GUARD_APP) == 32 * MB,
         "a reserve of more than half the budget counts as half");
   check(virgl_gpu_guard_limit(UINT64_MAX, 0, VIRGL_GPU_GUARD_DISPLAY) == UINT64_MAX,
         "a huge budget does not wrap round for screens");

   /* the 2026-10-06 Air run: a browser filled 6 GB with pressure normal and Hyprland's
    * next buffer was refused (a black VM). Now: */
   uint64_t a = 6 * GB - 512 * MB;
   expect("browser below its share", VIRGL_GPU_GUARD_FITS, a - 64 * MB, 64 * MB, b, r, VIRGL_GPU_GUARD_UNKNOWN, 1);
   expect("browser one byte past its share: made, only the desktop may keep it", VIRGL_GPU_GUARD_DESKTOP_ONLY,
          a - 64 * MB + 1, 64 * MB, b, r, VIRGL_GPU_GUARD_UNKNOWN, 1);
   expect("Hyprland's 5K buffer (21 MB) with apps at their share", VIRGL_GPU_GUARD_DESKTOP_ONLY, a, 21 * MB, b, r,
          VIRGL_GPU_GUARD_UNKNOWN, 1);
   expect("the desktop's own (known context) up to the whole budget", VIRGL_GPU_GUARD_FITS, b - 21 * MB, 21 * MB, b, r,
          VIRGL_GPU_GUARD_DESKTOP, 1);
   expect("past the whole budget: refused, the desktop too", VIRGL_GPU_GUARD_REFUSED, b - 21 * MB + 1, 21 * MB, b, r,
          VIRGL_GPU_GUARD_DESKTOP, 1);
   expect("a context not known yet, past the whole budget: refused", VIRGL_GPU_GUARD_REFUSED, b, 4096, b, r,
          VIRGL_GPU_GUARD_UNKNOWN, 1);
   expect("an app's (known context, Venus) past its share: refused", VIRGL_GPU_GUARD_REFUSED, a, 4096, b, r,
          VIRGL_GPU_GUARD_APP, 1);
   expect("an app's that ends exactly at its share", VIRGL_GPU_GUARD_FITS, a - 4096, 4096, b, r,
          VIRGL_GPU_GUARD_APP, 1);
   expect("a screen with the budget full: in the 256 MB past it", VIRGL_GPU_GUARD_FITS, b, 56 * MB, b, r,
          VIRGL_GPU_GUARD_DISPLAY, 1);
   expect("a screen past those 256 MB: refused", VIRGL_GPU_GUARD_REFUSED, b + 200 * MB, 57 * MB, b, r,
          VIRGL_GPU_GUARD_DISPLAY, 1);

   /* macOS short of memory (MAC_HAS_ROOM false: critical, or warn and bigger than what is left) */
   expect("pressure: a big resource of a context not known yet is for the desktop only",
          VIRGL_GPU_GUARD_DESKTOP_ONLY, 1 * GB, 64 * MB, b, r, VIRGL_GPU_GUARD_UNKNOWN, 0);
   expect("pressure: an app's (known) is refused", VIRGL_GPU_GUARD_REFUSED, 1 * GB, 64 * MB, b, r,
          VIRGL_GPU_GUARD_APP, 0);
   expect("pressure: the desktop's own still fits", VIRGL_GPU_GUARD_FITS, 1 * GB, 64 * MB, b, r,
          VIRGL_GPU_GUARD_DESKTOP, 0);
   expect("pressure: a screen still fits", VIRGL_GPU_GUARD_FITS, 1 * GB, 64 * MB, b, r, VIRGL_GPU_GUARD_DISPLAY, 0);
   expect("pressure and the whole budget full: refused", VIRGL_GPU_GUARD_REFUSED, b, 64 * MB, b, r,
          VIRGL_GPU_GUARD_UNKNOWN, 0);
   expect("no budget, pressure: for the desktop only", VIRGL_GPU_GUARD_DESKTOP_ONLY, 40 * GB, 64 * MB, 0, 0,
          VIRGL_GPU_GUARD_UNKNOWN, 0);
   expect("no budget, no pressure: fits", VIRGL_GPU_GUARD_FITS, 40 * GB, 64 * MB, 0, 0, VIRGL_GPU_GUARD_UNKNOWN, 1);
   expect("a reserve of 0: apps go up to the whole budget", VIRGL_GPU_GUARD_FITS, b - 64 * MB, 64 * MB, b, 0,
          VIRGL_GPU_GUARD_UNKNOWN, 1);
   expect("size bigger than any limit, nothing in use: refused", VIRGL_GPU_GUARD_REFUSED, 0, b + 1, b, r,
          VIRGL_GPU_GUARD_UNKNOWN, 1);

   /* at critical (virgl-gpu-guard-critical-grace.patch): a 32nd of the Mac, 256 MB to 1 GB */
   check(virgl_gpu_guard_critical_grace(8 * GB) == 256 * MB, "critical grace, 8 GB Mac: 256 MB");
   check(virgl_gpu_guard_critical_grace(16 * GB) == 512 * MB, "16 GB Mac: 512 MB");
   check(virgl_gpu_guard_critical_grace(18 * GB) == 576 * MB, "18 GB Mac: 576 MB");
   check(virgl_gpu_guard_critical_grace(24 * GB) == 768 * MB, "24 GB Mac: 768 MB");
   check(virgl_gpu_guard_critical_grace(32 * GB) == 1 * GB, "32 GB Mac: 1 GB");
   check(virgl_gpu_guard_critical_grace(128 * GB) == 1 * GB, "128 GB Mac: still 1 GB (the most)");
   check(virgl_gpu_guard_critical_grace(4 * GB) == 256 * MB && virgl_gpu_guard_critical_grace(0) == 256 * MB,
         "4 GB, or the Mac's memory not known: 256 MB (the least)");

   /* the 2026-10-30 Mac mini: 4619 MB in use when critical began, 1820 MB free or
    * inactive, Chrome's next 5K window buffer (56 MB in QEMU's log). 3.2.14 lost
    * Chrome at every one. */
   uint64_t base = 4619 * MB, g = 512 * MB, left = 1820 * MB;
   check(virgl_gpu_guard_critical_room(base, 56 * MB, base, g, left),
         "critical: Chrome's 56 MB window buffer with nothing grown yet fits");
   check(virgl_gpu_guard_critical_room(base - 56 * MB, 56 * MB, base, g, left),
         "critical: a buffer that replaces one just freed fits");
   int replaced = 1;
   for (int i = 0; i < 1000; i++)          /* free one, make one: in use never grows */
      replaced &= virgl_gpu_guard_critical_room(base - 56 * MB, 56 * MB, base, g, left);
   check(replaced, "critical: replacing a buffer 1000 times always fits");
   check(virgl_gpu_guard_critical_room(base + g - 64 * MB, 64 * MB, base, g, left),
         "critical: growth that ends exactly at the grace fits");
   check(!virgl_gpu_guard_critical_room(base + g - 64 * MB + 1, 64 * MB, base, g, left),
         "critical: one byte past the grace: no room (for the desktop only)");
   check(virgl_gpu_guard_critical_room(base - 1 * GB, 1 * GB + g, base, g, 2 * GB),
         "critical: after 1 GB was freed, 1 GB + the grace fits in one");
   check(!virgl_gpu_guard_critical_room(base, 64 * MB, base, g, 64 * MB - 1),
         "critical: bigger than what macOS has left: no room, grace or not");
   check(virgl_gpu_guard_critical_room(base, 64 * MB, base, g, 64 * MB),
         "critical: exactly what macOS has left fits");
   check(!virgl_gpu_guard_critical_room(base, 64 * MB, base, g, 0), "critical: nothing left: no room");
   check(virgl_gpu_guard_critical_room(64 * MB, 64 * MB, UINT64_MAX - 10, g, UINT64_MAX),
         "critical: a baseline near the top does not wrap round");
   check(!virgl_gpu_guard_critical_room(0, UINT64_MAX, 0, g, UINT64_MAX),
         "critical: a size past any grace: no room");
   /* the verdict with that answer: room -> an app's; no room -> for the desktop only */
   expect("critical, within the grace: fits for whoever takes it", VIRGL_GPU_GUARD_FITS, base, 56 * MB, b, r,
          VIRGL_GPU_GUARD_UNKNOWN, virgl_gpu_guard_critical_room(base, 56 * MB, base, g, left));
   expect("critical, past the grace: for the desktop only", VIRGL_GPU_GUARD_DESKTOP_ONLY, base + g, 56 * MB, 48 * GB,
          2 * GB, VIRGL_GPU_GUARD_UNKNOWN, virgl_gpu_guard_critical_room(base + g, 56 * MB, base, g, left));

   /* whose context: the names the guest's kernel gives (the process name), exactly */
   const char *list = VIRGL_GPU_GUARD_DESKTOP_DEFAULT;
   check(virgl_gpu_guard_is_desktop("Hyprland", list), "Hyprland is the desktop");
   check(virgl_gpu_guard_is_desktop("quickshell", list), "quickshell (the bar) is the desktop");
   check(virgl_gpu_guard_is_desktop("hyprlock", list), "hyprlock (the lock screen) is the desktop");
   check(!virgl_gpu_guard_is_desktop("chromium", list), "chromium is an app");
   check(!virgl_gpu_guard_is_desktop("hyprland", list), "case counts: hyprland is not Hyprland");
   check(!virgl_gpu_guard_is_desktop("Hypr", list), "a prefix is not enough");
   check(!virgl_gpu_guard_is_desktop("Hyprlandx", list), "nor a longer name");
   check(!virgl_gpu_guard_is_desktop("", list) && !virgl_gpu_guard_is_desktop(NULL, list),
         "an unnamed context is an app");
   check(virgl_gpu_guard_is_desktop("b", "a,b,c") && virgl_gpu_guard_is_desktop("c", "a,b,c"),
         "any name in the list, the last too");
   check(!virgl_gpu_guard_is_desktop("Hyprland", ""), "an empty list: no desktop");
   check(!virgl_gpu_guard_is_desktop("", "a,,b"), "an empty item matches nothing");

   printf("%s\n", failures ? "gpu guard policy: FAILED" : "gpu guard policy: all checks passed");
   return failures != 0;
}
