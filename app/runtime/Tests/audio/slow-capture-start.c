// Test for qemu-sdl-audio-capture-thread.patch: makes the Mac's microphone
// slow to start, as coreaudiod was in the 2.6.0 test, so the VM's behaviour
// can be checked without touching macOS's permissions.
//
// Holds back AudioQueueStart on SDL's recording threads ("SDLAudioC...") by
// SLOWAQ_DELAY seconds; with SLOWAQ_FAIL=1 it then fails with 268451843 as
// coreaudiod's timeout did. Playback is not touched.
//
//   clang -dynamiclib -o slowaq.dylib slow-capture-start.c -framework AudioToolbox
//   codesign -s - -f slowaq.dylib
//
// Load it into the development runtime (runtime/.build, ad hoc and without
// the hardened runtime, so dyld takes DYLD_INSERT_LIBRARIES): a folder with
// runtime/.build/firmware (a link to the real one) and
// runtime/.build/qemu-gpu-runtime/bin/qemu-system-aarch64, a script that
// exports DYLD_INSERT_LIBRARIES=<path>/slowaq.dylib and execs the real QEMU.
// Then start a VM with that folder:
//
//   open -n --env OMACVM_RESOURCES=<folder> --env SLOWAQ_DELAY=20 \
//     dist/OmacVM.app --args --start --vm "<test VM>"
//
// Expected, with pw-record in the VM: SSH and the guest's ping keep answering,
// the recording runs at its rate with silence, qemu.log says "did not start
// within 5 seconds", then "started late" and the sound comes. A pw-play
// started meanwhile waits until then. With SLOWAQ_FAIL=1: silence and
// "SDL_OpenAudioDevice for recording failed", the VM keeps running.
#include <AudioToolbox/AudioToolbox.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static OSStatus slow_start(AudioQueueRef queue, const AudioTimeStamp *time)
{
    const char *delay = getenv("SLOWAQ_DELAY");
    char name[64] = "";

    pthread_getname_np(pthread_self(), name, sizeof(name));
    if (delay && strstr(name, "SDLAudioC")) {
        fprintf(stderr, "slowaq: holding AudioQueueStart on '%s' for %s s\n", name, delay);
        sleep(atoi(delay));
        if (getenv("SLOWAQ_FAIL")) {
            fprintf(stderr, "slowaq: failing AudioQueueStart\n");
            return 268451843;
        }
    }
    return AudioQueueStart(queue, time);
}

__attribute__((used)) static const struct {
    const void *replacement, *original;
} interposers[] __attribute__((section("__DATA,__interpose"))) = {
    { (const void *)slow_start, (const void *)AudioQueueStart },
};
