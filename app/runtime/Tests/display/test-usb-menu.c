/* Tests ui/omacvm-usb-menu.h (omacvm-cocoa-usb-menu.patch).
 * Usage: test-usb-menu */
#include "omacvm-usb-menu.h"

#include <stdio.h>
#include <string.h>

static int failures, checks;

static void expect(int ok, const char *what)
{
    checks++;
    if (!ok) {
        printf("FAIL: %s\n", what);
        failures++;
    }
}

int main(void)
{
    /* QEMU not started by OmacVM.app, or the USB switch off: no item. */
    unsetenv("OMACVM_USB_REQUEST");
    expect(!omacvm_usb_request(), "no variable: no item");
    setenv("OMACVM_USB_REQUEST", "", 1);
    expect(!omacvm_usb_request(), "empty name: no item");

    /* The app's name (USBRun.requestName): the item, and the app's pid. */
    setenv("OMACVM_USB_REQUEST", "org.omacvm.app.usb.4242", 1);
    expect(omacvm_usb_request() && !strcmp(omacvm_usb_request(), "org.omacvm.app.usb.4242"),
           "the app's name is posted as it is");
    expect(omacvm_usb_launcher_pid("org.omacvm.app.usb.4242") == 4242, "pid from the name");
    expect(omacvm_usb_launcher_pid("org.omacvm.app.test.usb.73") == 73, "pid from a test build's name");
    expect(omacvm_usb_launcher_pid("org.example.usb.app.usb.12") == 12, "pid after the last .usb.");
    expect(omacvm_usb_launcher_pid("org.omacvm.app.usb.999999999") == 999999999, "9 digits");

    /* Names with no pid: QEMU yields to nobody (it still posts the name). */
    expect(omacvm_usb_launcher_pid(NULL) == 0, "no name");
    expect(omacvm_usb_launcher_pid("org.omacvm.app") == 0, "no .usb.");
    expect(omacvm_usb_launcher_pid("org.omacvm.app.usb.") == 0, "nothing after .usb.");
    expect(omacvm_usb_launcher_pid("org.omacvm.app.usb.0") == 0, "pid 0");
    expect(omacvm_usb_launcher_pid("org.omacvm.app.usb.-1") == 0, "a sign");
    expect(omacvm_usb_launcher_pid("org.omacvm.app.usb.12x") == 0, "not only digits");
    expect(omacvm_usb_launcher_pid("org.omacvm.app.usb. 12") == 0, "a space");
    expect(omacvm_usb_launcher_pid("org.omacvm.app.usb.1234567890") == 0, "10 digits");
    expect(omacvm_usb_launcher_pid("org.omacvm.app.features.4242") == 0, "Features…'s name");

    /* The process with that pid is the app only when its bundle id starts the name. */
    expect(omacvm_usb_is_launcher("org.omacvm.app.usb.4242", "org.omacvm.app"), "the release app");
    expect(omacvm_usb_is_launcher("org.omacvm.app.test.usb.4242", "org.omacvm.app.test"), "the test app");
    expect(!omacvm_usb_is_launcher("org.omacvm.app.test.usb.4242", "org.omacvm.app"),
           "another app's id that is a prefix");
    expect(!omacvm_usb_is_launcher("org.omacvm.app.usb.4242", "org.omacvm.app.test"), "a longer id");
    expect(!omacvm_usb_is_launcher("org.omacvm.app.usb.4242", "com.apple.finder"), "another app");
    expect(!omacvm_usb_is_launcher("org.omacvm.app.usb.4242", NULL), "a process without a bundle id");
    expect(!omacvm_usb_is_launcher("org.omacvm.app.usb.4242", ""), "an empty bundle id");
    expect(!omacvm_usb_is_launcher("org.omacvm.app.usb.42x", "org.omacvm.app"), "no pid in the name");
    expect(!omacvm_usb_is_launcher(NULL, "org.omacvm.app"), "no name");

    if (failures) {
        printf("usb menu: %d of %d checks FAIL\n", failures, checks);
        return 1;
    }
    printf("usb menu: %d checks ok\n", checks);
    return 0;
}
