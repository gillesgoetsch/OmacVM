/*
 * macOS's shortcuts while the VM has the keyboard (omacvm-cocoa-shortcuts-logic.patch):
 * every shortcut in macOS's list reaches the VM as keys (or is named as one
 * that cannot), and macOS's own are off exactly while the VM has the keyboard.
 *   test-shortcuts LIST.tsv [LIVE.tsv]         check (LIVE: this Mac's own table)
 *   test-shortcuts --qcodes LIST.tsv           print each enabled chord's QEMU keys
 * LIST/LIVE rows: id, enabled, Mac key code, modifiers (CGEventFlags), name.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "omacvm-shortcuts.h"

/* Mac key code -> Linux key code and QEMU qcode, from QEMU's keycodemapdb
 * (f5772a62, data/keymaps.csv: the table QEMU's Cocoa UI uses). */
static const struct { int linux_code; const char *qcode; const char *name; } osx_keys[128] = {
    [0x00] = { 30, "a", "ANSI_A" },
    [0x01] = { 31, "s", "ANSI_S" },
    [0x02] = { 32, "d", "ANSI_D" },
    [0x03] = { 33, "f", "ANSI_F" },
    [0x04] = { 35, "h", "ANSI_H" },
    [0x05] = { 34, "g", "ANSI_G" },
    [0x06] = { 44, "z", "ANSI_Z" },
    [0x07] = { 45, "x", "ANSI_X" },
    [0x08] = { 46, "c", "ANSI_C" },
    [0x09] = { 47, "v", "ANSI_V" },
    [0x0a] = { 86, "less", "ISO_Section" },
    [0x0b] = { 48, "b", "ANSI_B" },
    [0x0c] = { 16, "q", "ANSI_Q" },
    [0x0d] = { 17, "w", "ANSI_W" },
    [0x0e] = { 18, "e", "ANSI_E" },
    [0x0f] = { 19, "r", "ANSI_R" },
    [0x10] = { 21, "y", "ANSI_Y" },
    [0x11] = { 20, "t", "ANSI_T" },
    [0x12] = { 2, "1", "ANSI_1" },
    [0x13] = { 3, "2", "ANSI_2" },
    [0x14] = { 4, "3", "ANSI_3" },
    [0x15] = { 5, "4", "ANSI_4" },
    [0x16] = { 7, "6", "ANSI_6" },
    [0x17] = { 6, "5", "ANSI_5" },
    [0x18] = { 13, "equal", "ANSI_Equal" },
    [0x19] = { 10, "9", "ANSI_9" },
    [0x1a] = { 8, "7", "ANSI_7" },
    [0x1b] = { 12, "minus", "ANSI_Minus" },
    [0x1c] = { 9, "8", "ANSI_8" },
    [0x1d] = { 11, "0", "ANSI_0" },
    [0x1e] = { 27, "bracket_right", "ANSI_RightBracket" },
    [0x1f] = { 24, "o", "ANSI_O" },
    [0x20] = { 22, "u", "ANSI_U" },
    [0x21] = { 26, "bracket_left", "ANSI_LeftBracket" },
    [0x22] = { 23, "i", "ANSI_I" },
    [0x23] = { 25, "p", "ANSI_P" },
    [0x24] = { 28, "ret", "Return" },
    [0x25] = { 38, "l", "ANSI_L" },
    [0x26] = { 36, "j", "ANSI_J" },
    [0x27] = { 40, "apostrophe", "ANSI_Quote" },
    [0x28] = { 37, "k", "ANSI_K" },
    [0x29] = { 39, "semicolon", "ANSI_Semicolon" },
    [0x2a] = { 43, "backslash", "ANSI_Backslash" },
    [0x2b] = { 51, "comma", "ANSI_Comma" },
    [0x2c] = { 53, "slash", "ANSI_Slash" },
    [0x2d] = { 49, "n", "ANSI_N" },
    [0x2e] = { 50, "m", "ANSI_M" },
    [0x2f] = { 52, "dot", "ANSI_Period" },
    [0x30] = { 15, "tab", "Tab" },
    [0x31] = { 57, "spc", "Space" },
    [0x32] = { 41, "grave_accent", "ANSI_Grave" },
    [0x33] = { 14, "backspace", "Delete" },
    [0x35] = { 1, "esc", "Escape" },
    [0x36] = { 126, "meta_r", "RightCommand" },
    [0x37] = { 125, "meta_l", "Command" },
    [0x38] = { 42, "shift", "Shift" },
    [0x39] = { 58, "caps_lock", "CapsLock" },
    [0x3a] = { 56, "alt", "Option" },
    [0x3b] = { 29, "ctrl", "Control" },
    [0x3c] = { 54, "shift_r", "RightShift" },
    [0x3d] = { 100, "alt_r", "RightOption" },
    [0x3e] = { 97, "ctrl_r", "RightControl" },
    [0x3f] = { 464, "", "Function" },
    [0x40] = { 187, "f17", "F17" },
    [0x41] = { 83, "kp_decimal", "ANSI_KeypadDecimal" },
    [0x43] = { 55, "asterisk", "ANSI_KeypadMultiply" },
    [0x45] = { 78, "kp_add", "ANSI_KeypadPlus" },
    [0x47] = { 69, "num_lock", "ANSI_KeypadClear" },
    [0x48] = { 115, "volumeup", "VolumeUp" },
    [0x49] = { 114, "volumedown", "VolumeDown" },
    [0x4a] = { 113, "audiomute", "Mute" },
    [0x4b] = { 98, "kp_divide", "ANSI_KeypadDivide" },
    [0x4c] = { 96, "kp_enter", "ANSI_KeypadEnter" },
    [0x4e] = { 74, "kp_subtract", "ANSI_KeypadMinus" },
    [0x4f] = { 188, "f18", "F18" },
    [0x50] = { 189, "f19", "F19" },
    [0x51] = { 117, "kp_equals", "ANSI_KeypadEquals" },
    [0x52] = { 82, "kp_0", "ANSI_Keypad0" },
    [0x53] = { 79, "kp_1", "ANSI_Keypad1" },
    [0x54] = { 80, "kp_2", "ANSI_Keypad2" },
    [0x55] = { 81, "kp_3", "ANSI_Keypad3" },
    [0x56] = { 75, "kp_4", "ANSI_Keypad4" },
    [0x57] = { 76, "kp_5", "ANSI_Keypad5" },
    [0x58] = { 77, "kp_6", "ANSI_Keypad6" },
    [0x59] = { 71, "kp_7", "ANSI_Keypad7" },
    [0x5a] = { 190, "f20", "F20" },
    [0x5b] = { 72, "kp_8", "ANSI_Keypad8" },
    [0x5c] = { 73, "kp_9", "ANSI_Keypad9" },
    [0x5d] = { 124, "yen", "JIS_Yen" },
    [0x5e] = { 89, "ro", "JIS_Underscore" },
    [0x5f] = { 95, "", "JIS_KeypadComma" },
    [0x60] = { 63, "f5", "F5" },
    [0x61] = { 64, "f6", "F6" },
    [0x62] = { 65, "f7", "F7" },
    [0x63] = { 61, "f3", "F3" },
    [0x64] = { 66, "f8", "F8" },
    [0x65] = { 67, "f9", "F9" },
    [0x66] = { 123, "lang2", "JIS_Eisu" },
    [0x67] = { 87, "f11", "F11" },
    [0x68] = { 122, "lang1", "JIS_Kana" },
    [0x69] = { 183, "f13", "F13" },
    [0x6a] = { 186, "f16", "F16" },
    [0x6b] = { 184, "f14", "F14" },
    [0x6d] = { 68, "f10", "F10" },
    [0x6e] = { 127, "compose", "KEY_COMPOSE" },
    [0x6f] = { 88, "f12", "F12" },
    [0x71] = { 185, "f15", "F15" },
    [0x72] = { 138, "help", "Help" },
    [0x73] = { 102, "home", "Home" },
    [0x74] = { 104, "pgup", "PageUp" },
    [0x75] = { 111, "delete", "ForwardDelete" },
    [0x76] = { 62, "f4", "F4" },
    [0x77] = { 107, "end", "End" },
    [0x78] = { 60, "f2", "F2" },
    [0x79] = { 109, "pgdn", "PageDown" },
    [0x7a] = { 59, "f1", "F1" },
    [0x7b] = { 105, "left", "LeftArrow" },
    [0x7c] = { 106, "right", "RightArrow" },
    [0x7d] = { 108, "down", "DownArrow" },
    [0x7e] = { 103, "up", "UpArrow" },
};

static int fails, checks;
#define CHECK(cond, ...) do { checks++; if (!(cond)) { fails++; printf("FAIL "); printf(__VA_ARGS__); printf("\n"); } } while (0)

enum { SHIFT = 0x20000, CONTROL = 0x40000, OPTION = 0x80000, COMMAND = 0x100000, FN = 0x800000 };

/* The keys the VM gets for a chord: modifiers first, then the key. 0 keys: none for the guest. */
static int guest_keys(int keycode, unsigned flags, const char *qcodes[8], int *key_linux)
{
    int n = 0;
    if (flags & CONTROL) qcodes[n++] = "ctrl";
    if (flags & SHIFT) qcodes[n++] = "shift";
    if (flags & OPTION) qcodes[n++] = "alt";
    if (flags & COMMAND) qcodes[n++] = "meta_l";
    int special = omacvm_special_key(keycode);
    *key_linux = special >= 0 ? special
               : keycode >= 0 && keycode < 128 ? osx_keys[keycode].linux_code : 0;
    if (special >= 61 && special <= 64) {
        static const char *f[] = { "f3", "f4", "f5", "f6" };
        qcodes[n++] = f[special - 61];
    } else if (special > 0) {
        /* The globe key: QEMU has no qcode for KEY_PROG3; the guest gets its
           Linux code straight (QEMU's linux-keyed input, this runtime). */
    } else if (special < 0 && *key_linux) {
        qcodes[n++] = osx_keys[keycode].qcode;
    }
    return n;
}

/* Keys that reach the VM as nothing on purpose (omacvm-shortcuts.h). */
static int no_guest_key(int keycode)
{
    return keycode == 0x7f || keycode == 0x90 || keycode == 0x91;
}

static int check_list(const char *path, int print_qcodes, int *enabled_out)
{
    FILE *f = fopen(path, "r");
    if (!f) { printf("FAIL cannot read %s\n", path); fails++; return 0; }
    char line[512];
    int rows = 0, enabled = 0;
    while (fgets(line, sizeof line, f)) {
        if (line[0] == '#' || line[0] == '\n') continue;
        int id, en, kc; unsigned flags; char name[256] = "";
        if (sscanf(line, "%d\t%d\t%d\t%x\t%255[^\n]", &id, &en, &kc, &flags, name) < 4) continue;
        if (kc == 65535) continue;                /* no key bound */
        rows++;
        enabled += en;
        const char *q[8]; int lnx;
        int n = guest_keys(kc, flags, q, &lnx);
        if (print_qcodes) {
            if (!en || !lnx || kc == 0xb3) continue;   /* the globe key: no qcode (above) */
            printf("%d", id);
            for (int i = 0; i < n; i++) printf(" %s", q[i]);
            printf("\t%s\n", name);
            continue;
        }
        /* Never our escape combo: macOS would lose it to the VM's way out. */
        CHECK(!omacvm_is_escape_combo(kc, flags & CONTROL, flags & OPTION, flags & COMMAND, flags & SHIFT),
              "%s: shortcut %d (%s) is the escape combo", path, id, name);
        if (no_guest_key(kc)) {
            CHECK(lnx == 0, "%s: shortcut %d (%s): key 0x%x should give the guest nothing", path, id, name, kc);
        } else if (kc == 0xb3) {
            CHECK(lnx == OMACVM_GLOBE_LINUX_KEY, "%s: shortcut %d (%s): the globe key should reach the VM as KEY_PROG3",
                  path, id, name);
            CHECK(id != OMACVM_GLOBE_HOTKEY || (flags & (SHIFT | CONTROL | OPTION | COMMAND)) == 0,
                  "%s: macOS's globe shortcut %d has modifiers: not the lone press", path, id);
        } else {
            CHECK(lnx > 0, "%s: shortcut %d (%s): Mac key 0x%x has no key in the VM", path, id, name, kc);
            CHECK(n >= 1 && q[n - 1] && q[n - 1][0], "%s: shortcut %d (%s): no QEMU key name", path, id, name);
        }
    }
    fclose(f);
    if (enabled_out) *enabled_out = enabled;
    return rows;
}

int main(int argc, char **argv)
{
    if (argc >= 3 && !strcmp(argv[1], "--qcodes")) {
        check_list(argv[2], 1, NULL);
        return fails != 0;
    }
    if (argc < 2) { fprintf(stderr, "usage: test-shortcuts LIST.tsv [LIVE.tsv]\n"); return 2; }

    /* When macOS's own shortcuts are off: only while the VM has the keyboard. */
    CHECK(omacvm_shortcuts_to_vm(1, 1, 1, 0, 0), "captured VM: shortcuts should go to the VM");
    CHECK(!omacvm_shortcuts_to_vm(0, 1, 1, 0, 0), "no full grab: macOS keeps its shortcuts");
    CHECK(!omacvm_shortcuts_to_vm(1, 0, 1, 0, 0), "another app in front: macOS keeps its shortcuts");
    CHECK(!omacvm_shortcuts_to_vm(1, 1, 0, 0, 0), "our window not key (a sheet, the start window): macOS keeps them");
    CHECK(!omacvm_shortcuts_to_vm(1, 1, 1, 1, 0), "OMACVM_MAC_SHORTCUTS=1: macOS keeps them");
    CHECK(!omacvm_shortcuts_to_vm(1, 1, 1, 0, 1), "hung VM window: macOS gets them back");

    /* The escape combo: exactly Control+Option+Esc, and through 3.0.x the old
       Control+Option+Command+Esc; with Shift neither. */
    CHECK(omacvm_is_escape_combo(53, 1, 1, 0, 0), "Ctrl+Opt+Esc is the escape combo");
    CHECK(omacvm_is_escape_combo(53, 1, 1, 1, 0), "Ctrl+Opt+Cmd+Esc (the old one) still is");
    CHECK(!omacvm_is_escape_combo(53, 1, 1, 0, 1), "Ctrl+Opt+Shift+Esc is not the escape combo");
    CHECK(!omacvm_is_escape_combo(53, 1, 1, 1, 1), "Ctrl+Opt+Cmd+Shift+Esc is not the escape combo");
    CHECK(!omacvm_is_escape_combo(53, 0, 1, 1, 0), "Opt+Cmd+Esc (Force Quit) is not the escape combo");
    CHECK(!omacvm_is_escape_combo(53, 1, 0, 1, 0), "Ctrl+Cmd+Esc is not the escape combo");
    CHECK(!omacvm_is_escape_combo(53, 1, 0, 0, 0) && !omacvm_is_escape_combo(53, 0, 1, 0, 0),
          "Ctrl+Esc and Opt+Esc are not the escape combo");
    CHECK(!omacvm_is_escape_combo(48, 1, 1, 1, 0) && !omacvm_is_escape_combo(48, 1, 1, 0, 0),
          "Ctrl+Opt(+Cmd)+Tab is not the escape combo");

    /* Apple's own key codes: the F-key they sit on. */
    CHECK(omacvm_special_key(0xa0) == 61, "Mission Control key -> F3");
    CHECK(omacvm_special_key(0xb1) == 62, "Spotlight key -> F4");
    CHECK(omacvm_special_key(0xb0) == 63, "Dictation key -> F5");
    CHECK(omacvm_special_key(0xb2) == 64, "Do Not Disturb key -> F6");
    CHECK(omacvm_special_key(0x83) == 62, "Launchpad key -> F4");
    CHECK(omacvm_special_key(0x67) == -1, "F11 uses QEMU's table");

    /* The globe key on its own: KEY_PROG3, a key no Mac key gives otherwise,
       below KEY_REPLY (232), the end of what QEMU's virtio keyboard offers. */
    CHECK(omacvm_special_key(0xb3) == 202 && OMACVM_GLOBE_LINUX_KEY == 202, "globe key -> KEY_PROG3 (202)");
    CHECK(OMACVM_GLOBE_LINUX_KEY < 232, "globe key below KEY_REPLY: QEMU's virtio keyboard offers it");
    for (int k = 0; k < 256; k++) {
        int lnx = omacvm_special_key(k);
        if (lnx < 0) lnx = k < 128 ? osx_keys[k].linux_code : 0;
        CHECK(k == 0xb3 || lnx != OMACVM_GLOBE_LINUX_KEY, "Mac key 0x%x also gives KEY_PROG3", k);
    }
    CHECK(omacvm_special_key(0x3f) == -1 && osx_keys[0x3f].linux_code == 464,
          "fn itself (0x3f) stays QEMU's (a modifier change the window drops)");

    /* macOS's globe shortcut: off only while the VM has the keyboard, even when
       macOS keeps its other shortcuts (that is not an input here). */
    CHECK(omacvm_globe_to_vm(1, 1, 0, 0), "VM has the keyboard: the globe key goes to the VM");
    CHECK(!omacvm_globe_to_vm(0, 1, 0, 0), "another app in front: macOS keeps the globe key");
    CHECK(!omacvm_globe_to_vm(1, 0, 0, 0), "our window not key: macOS keeps the globe key");
    CHECK(!omacvm_globe_to_vm(1, 1, 1, 0), "OMACVM_GLOBE_KEY=mac: macOS keeps the globe key");
    CHECK(!omacvm_globe_to_vm(1, 1, 0, 1), "hung VM window: macOS gets the globe key back");
    CHECK(OMACVM_GLOBE_HOTKEY == 188, "macOS's globe shortcut is 188");
    /* want VM, macOS has it on, ours */
    CHECK(omacvm_globe_action(1, 1, 0) == OMACVM_GLOBE_TAKE, "VM gets the keyboard: switch the shortcut off");
    CHECK(omacvm_globe_action(1, 0, 1) == OMACVM_GLOBE_KEEP, "already off by us: nothing");
    CHECK(omacvm_globe_action(1, 1, 1) == OMACVM_GLOBE_TAKE, "another VM gave it back meanwhile: off again");
    CHECK(omacvm_globe_action(1, 0, 0) == OMACVM_GLOBE_KEEP, "off by the user (or another VM): not ours, nothing");
    CHECK(omacvm_globe_action(0, 1, 1) == OMACVM_GLOBE_GIVE_BACK, "VM loses the keyboard: give it back");
    CHECK(omacvm_globe_action(0, 0, 1) == OMACVM_GLOBE_GIVE_BACK, "VM loses the keyboard: give it back (state not read)");
    CHECK(omacvm_globe_action(0, 1, 0) == OMACVM_GLOBE_KEEP, "not ours: never switched on by us");
    CHECK(omacvm_globe_action(0, 0, 0) == OMACVM_GLOBE_KEEP, "a user's off stays off");

    /* One globe press, one KEY_PROG3, whichever way macOS shows it. */
    {
        enum { D = OMACVM_GLOBE_EV_FN_DOWN, U = OMACVM_GLOBE_EV_FN_UP, BD = OMACVM_GLOBE_EV_B3_DOWN,
               BU = OMACVM_GLOBE_EV_B3_UP, O = OMACVM_GLOBE_EV_OTHER, R = OMACVM_GLOBE_EV_RESET };
        static const struct { const char *what; int n; int ev[8]; int ms[8]; int keys; } cases[] = {
            { "fn alone", 2, { D, U }, { 0, 90 }, 1 },
            { "fn alone, twice", 4, { D, U, D, U }, { 0, 90, 200, 290 }, 2 },
            { "0xb3 alone", 2, { BD, BU }, { 0, 20 }, 1 },
            { "fn, 0xb3 while held, fn up", 4, { D, BD, BU, U }, { 0, 10, 30, 90 }, 1 },
            { "fn tap, then its 0xb3", 4, { D, U, BD, BU }, { 0, 90, 100, 120 }, 1 },
            { "fn tap, a 0xb3 much later is a new press", 4, { D, U, BD, BU }, { 0, 90, 900, 920 }, 2 },
            { "fn+F1 (another key)", 3, { D, O, U }, { 0, 50, 90 }, 0 },
            { "fn+click / fn+Ctrl", 3, { D, O, U }, { 0, 50, 90 }, 0 },
            { "fn up without a down (VM got the keyboard mid-press)", 1, { U }, { 0 }, 0 },
            { "VM lost the globe key mid-press", 3, { D, R, U }, { 0, 50, 90 }, 0 },
            { "a key before fn does not spoil the tap", 3, { O, D, U }, { 0, 10, 90 }, 1 },
            { "fn + a media/volume/brightness key the window never sees", 3, { D, O, U }, { 0, 40, 120 }, 0 },
            { "fn held, then let go unused", 2, { D, U }, { 0, 900 }, 0 },
            { "fn tap just under the hold limit", 2, { D, U }, { 0, 650 }, 1 },
            { "0xb3 just before fn down (same press)", 4, { BD, D, BU, U }, { 0, 5, 30, 90 }, 1 },
            { "0xb3 down and up, then fn (same press)", 4, { BD, BU, D, U }, { 0, 20, 30, 90 }, 1 },
            { "0xb3 alone, a fn tap later is a new press", 4, { BD, BU, D, U }, { 0, 20, 600, 690 }, 2 },
            { "fn, 0xb3 while held, twice fast", 8, { D, BD, BU, U, D, BD, BU, U }, { 0, 2, 30, 90, 180, 182, 210, 270 }, 2 },
        };
        for (size_t c = 0; c < sizeof cases / sizeof cases[0]; c++) {
            OmacVMGlobeTap t = OMACVM_GLOBE_TAP_INIT;
            int keys = 0, downs = 0, ups = 0;
            for (int i = 0; i < cases[c].n; i++) {
                int ev = cases[c].ev[i], what = omacvm_globe_tap_step(&t, ev, cases[c].ms[i]);
                if (what == OMACVM_GLOBE_DO_TAP) keys++;
                if (ev == OMACVM_GLOBE_EV_B3_DOWN && what == OMACVM_GLOBE_DO_PASS) { keys++; downs++; }
                if (ev == OMACVM_GLOBE_EV_B3_UP && what == OMACVM_GLOBE_DO_PASS) ups++;
                CHECK(what != OMACVM_GLOBE_DO_TAP || ev == OMACVM_GLOBE_EV_FN_UP, "%s: a tap only at fn up", cases[c].what);
                CHECK(ev == OMACVM_GLOBE_EV_B3_DOWN || ev == OMACVM_GLOBE_EV_B3_UP ||
                      (what != OMACVM_GLOBE_DO_PASS && what != OMACVM_GLOBE_DO_DROP),
                      "%s: only a 0xb3 is passed or dropped", cases[c].what);
            }
            CHECK(keys == cases[c].keys, "%s: %d KEY_PROG3 presses to the VM, want %d", cases[c].what, keys, cases[c].keys);
            CHECK(downs == ups, "%s: every 0xb3 down passed has its up passed (%d downs, %d ups)", cases[c].what, downs, ups);
        }
    }

    /* What spoils a fn tap from macOS's counters: keys, media keys, clicks, scrolls; never fn itself. */
    {
        int have[32] = { 0 };
        for (size_t i = 0; i < sizeof omacvm_globe_unseen_types / sizeof omacvm_globe_unseen_types[0]; i++)
            have[omacvm_globe_unseen_types[i] & 31] = 1;
        CHECK(have[10] && have[14] && have[22] && have[1] && have[3] && have[25],
              "fn tap: key downs, media keys (NX_SYSDEFINED), scrolls and clicks the window never sees spoil it");
        CHECK(!have[12] && !have[11], "fn tap: flags changed (fn itself) and key ups never spoil it");
    }

    int enabled = 0, live_enabled = 0;
    int rows = check_list(argv[1], 0, &enabled);
    CHECK(rows > 100, "%s: only %d shortcuts", argv[1], rows);
    int live = argc >= 3 ? check_list(argv[2], 0, &live_enabled) : 0;
    if (fails) { printf("%d of %d checks failed\n", fails, checks); return 1; }
    printf("ok   %d shortcuts (%d enabled) from the list reach the VM as keys; macOS's own are off only while it has the keyboard\n",
           rows, enabled);
    if (argc >= 3) printf("ok   this Mac's own list: %d shortcuts (%d enabled), each reaches the VM\n", live, live_enabled);
    printf("ok   %d checks\n", checks);
    return 0;
}
