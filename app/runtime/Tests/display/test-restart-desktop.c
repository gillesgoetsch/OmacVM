/* Tests ui/omacvm-desktop-restart.h (omacvm-cocoa-restart-desktop.patch).
 * Usage: test-restart-desktop EMPTY_DIR */
#include "omacvm-desktop-restart.h"

#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int failures;

static void expect(int ok, const char *what)
{
    if (!ok) {
        printf("FAIL: %s\n", what);
        failures++;
    }
}

static void touch(const char *path)
{
    int fd = open(path, O_WRONLY | O_CREAT, 0644);
    if (fd >= 0) {
        close(fd);
    }
}

int main(int argc, char **argv)
{
    char lost[1024], target[1024];
    const char *name = "org.omacvm.app.desktop-restart.4242";

    if (argc != 2) {
        return 2;
    }
    snprintf(lost, sizeof(lost), "%s/desktop-lost", argv[1]);
    snprintf(target, sizeof(target), "%s/elsewhere", argv[1]);

    /* QEMU not started by OmacVM.app: no item at all. */
    unsetenv("OMACVM_DESKTOP_LOST");
    unsetenv("OMACVM_DESKTOP_RESTART_REQUEST");
    expect(!omacvm_desktop_restart_request(), "no variables: no item");
    expect(!omacvm_desktop_lost(), "no variables: not lost");
    setenv("OMACVM_DESKTOP_LOST", lost, 1);
    setenv("OMACVM_DESKTOP_RESTART_REQUEST", "", 1);
    touch(lost);
    expect(!omacvm_desktop_restart_request(), "empty request name: no item");
    expect(!omacvm_desktop_lost(), "empty request name: not lost even with the file");
    unlink(lost);
    setenv("OMACVM_DESKTOP_LOST", "", 1);
    setenv("OMACVM_DESKTOP_RESTART_REQUEST", name, 1);
    expect(!omacvm_desktop_restart_request(), "empty file name: no item");

    /* Started by the app. */
    setenv("OMACVM_DESKTOP_LOST", lost, 1);
    expect(omacvm_desktop_restart_request() &&
           !strcmp(omacvm_desktop_restart_request(), name), "both: the app's name");
    expect(!omacvm_desktop_lost(), "no desktop-lost file: item hidden");
    touch(lost);
    expect(omacvm_desktop_lost(), "desktop-lost there: item shown");
    unlink(lost);
    expect(!omacvm_desktop_lost(), "desktop-lost removed (restart, VM stop): hidden again");

    /* Not a plain file: hidden. */
    touch(target);
    expect(symlink(target, lost) == 0, "made a link for desktop-lost");
    expect(!omacvm_desktop_lost(), "desktop-lost as a link: hidden");
    unlink(lost);
    unlink(target);
    expect(mkdir(lost, 0700) == 0, "made a folder for desktop-lost");
    expect(!omacvm_desktop_lost(), "desktop-lost as a folder: hidden");
    rmdir(lost);

    /* The logs folder is gone (VM folder moved): hidden, no crash. */
    setenv("OMACVM_DESKTOP_LOST", "/nonexistent-omacvm/logs/desktop-lost", 1);
    expect(!omacvm_desktop_lost(), "missing folder: hidden");

    if (failures) {
        return 1;
    }
    printf("restart desktop menu: all checks passed\n");
    return 0;
}
