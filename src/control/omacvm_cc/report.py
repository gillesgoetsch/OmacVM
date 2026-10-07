"""Report a problem: collect what helps (checks, versions, recent logs),
take out what is personal, show it, then open a pre-filled GitHub issue.
Nothing is uploaded by OmacVM: the browser opens a form the person submits.

Redaction, in this order:
 1. Known values (exact, case-insensitive, longest first): user, full and
    first names (a plain word like "max" only where it stands as a name:
    "Max", "user max", "max@host"), host names (and the owner in "Anna's
    MacBook Pro", "Maxs-MacBook-Pro"), VM names, Wi-Fi names and BSSIDs (a
    plain one-word Wi-Fi name as a whole word only),
    Bluetooth names and addresses, the Bridge token, home folders.
 2. Patterns: the names in the Bridge's own log lines (its connected
    Bluetooth devices, the Wi-Fi name after ssid=, audio devices, the camera,
    Omanotch's VM names, ...), an owner's name with a device word ("Anna's
    AirPods", "AirPods von Anna", "iPhone de Jean-Luc", "MacBook-Pro-von-Anna",
    "iPhone (Anna)", Finnish "Annan AirPods", "annas-macbook-pro", known or not), PEM blocks, SSH keys, bearer, Basic,
    GitHub, Anthropic, Slack, AWS and GitLab tokens, key=value and
    "--passphrase value" secrets, e-mail
    addresses, hardware addresses, UUIDs, serial numbers, IPv4/IPv6
    addresses (the Mac's VM-network addresses get a label), long hex and
    base64 runs.
 3. Gate: if any known value is still in the text after Unicode
    normalisation, the report is refused (RedactionFailed), never shown or sent.

Also runs on the Mac (`omacvm report`) with macOS's /usr/bin/python3 3.9:
stdlib only, no newer syntax outside annotations.
"""
from __future__ import annotations

import re
import unicodedata
import urllib.parse
from dataclasses import dataclass, field

ISSUES = "https://github.com/gillesgoetsch/omacvm/issues/new"
URL_MAX = 7000   # browsers and GitHub cut longer URLs

# The Mac's address on each VM network: kept apart, but not personal.
MAC_ADDRS = {"10.211.55.2": "<mac-parallels>", "192.168.64.1": "<mac-utm>", "10.0.2.2": "<mac-app>"}
KEEP_ADDRS = {"127.0.0.1", "0.0.0.0", "255.255.255.255"}

LABELS = {"user": "<user>", "host": "<host>", "vm": "<vm>", "wifi": "<wifi>",
          "bt": "<bt-device>", "secret": "<secret>"}
NOUNS = {"user": "user name", "host": "host name", "vm": "VM name", "wifi": "Wi-Fi name",
         "bt": "Bluetooth device", "secret": "secret", "home": "home folder", "ip": "address",
         "hw": "hardware address", "email": "e-mail address", "key": "key", "uuid": "ID",
         "serial": "serial number", "audio": "audio device", "camera": "camera"}


class RedactionFailed(Exception):
    pass


@dataclass
class Known:
    """Values that must never leave the machine, by kind."""
    user: list = field(default_factory=list)
    host: list = field(default_factory=list)
    vm: list = field(default_factory=list)
    wifi: list = field(default_factory=list)
    bt: list = field(default_factory=list)
    secret: list = field(default_factory=list)
    home: list = field(default_factory=list)

    def add(self, kind: str, *values) -> None:
        lst = getattr(self, kind)
        for v in values:
            v = norm(str(v or "")).strip()
            if kind not in ("secret", "home"):
                # Product words are no one's personal data: a VM named "Omarchy"
                # with host name "omarchy" must not turn "Omarchy 4.0.3" into "<vm> 4.0.3".
                # Nor is an account called "user" or "admin".
                if product_only(v) or (kind == "user" and v.casefold() in GENERIC_ACCOUNTS):
                    continue
            # The owner in a device or Mac name ("Zorro's AirPods", "Mac mini
            # von Gilles", "AirPods von Max"): a person's name, also where it
            # stands alone. Before the device-word test below: "AirPods von
            # Max" is device and plain words alone, but Max is someone.
            if kind in ("bt", "host") and re.search(r"\b" + DEVICE_WORDS, v, re.IGNORECASE):
                for m in OWNER_AFTER.finditer(v):
                    part = m.group(1) or m.group(2)
                    if self._owner(part):
                        self.user.append(part)
            # macOS's host name form, also in lower case: "Maxs-MacBook-Pro",
            # "annas-macbook-pro", Finnish "Annan-MacBook-Pro".
            m = HOST_FORM.match(v) if kind == "host" else None
            if m and self._owner(m.group(1)):
                self.user.append(m.group(1))
                # "Thomas-MacBook-Pro": the s may be the name's own (Thomas), not 's.
                whole = v[:m.end(1) + 1]
                if whole[-1:].casefold() == "s" and v[m.end(1) + 1:m.end(1) + 2] == "-" and not self.has(whole):
                    self.user.append(whole)
            # Wi-Fi and Bluetooth names of device and plain words alone (a
            # phone's hotspot "iPhone", "AirPods Pro") are nobody's name, and
            # taking them out would take out every "iPhone" in the logs. So is
            # a host or VM name like "MacBook-Pro". A user, first or full name
            # always counts, even when it is a plain word ("Max", "Marshall").
            if (kind in ("wifi", "bt") and common_only(v)) or \
                    (kind in ("host", "vm") and common_only(v) and re.search(r"\b" + DEVICE_WORDS + r"\b", v, re.I)):
                continue
            if len(v) >= 2 and not self.has(v):
                lst.append(v)
            # A full name's parts too ("Zorro Testmann": "Zorro", "Testmann";
            # the first one always, "Max Muster": "Max"). Of a host name only its owner.
            if kind in ("user", "bt", "host"):
                for i, word in enumerate(re.split(r"[\s_]+", v)):
                    owner = POSSESSIVE.match(word)
                    if kind == "host" and not owner:
                        continue
                    if " " not in v and not owner:
                        continue   # a one-word value is in already
                    if owner:
                        part, k = owner.group(1), "user"
                        ok = len(part) >= 2 and owner_word(part)
                    else:
                        part, k = word.strip("-"), kind
                        if kind == "user" and i == 0:
                            ok = len(part) >= 2 and not product_only(part)
                        else:
                            ok = len(part) >= 3 and part.casefold() not in COMMON and part.casefold() not in PARTICLES \
                                and not product_only(part)
                    if ok and not self.has(part):
                        getattr(self, k).append(part)

    def _owner(self, part: str) -> bool:
        """PART, the owner in a known device or host name, is a new name."""
        return len(part) >= 2 and (owner_word(part) or part.casefold() in NAME_LIKE) and \
            part.casefold() not in GENERIC_ACCOUNTS and not self.has(part)

    def has(self, v: str) -> bool:
        return any(v.casefold() == w.casefold() for _, w in self.items())

    def items(self):
        for kind in ("secret", "wifi", "vm", "host", "user", "bt"):
            for v in getattr(self, kind):
                yield kind, v


# Words in device and person names that are not personal on their own.
COMMON = {"airpods", "pro", "max", "macbook", "magic", "keyboard", "mouse", "trackpad", "iphone", "ipad",
          "the", "and", "von", "van", "der", "mini", "air", "studio", "imac", "headphones", "speaker",
          "apple", "logitech", "bose", "sony", "beats", "my", "your", "new", "old", "work", "home",
          # OmacVM's own parts and words in its logs ("the guest's Mouse",
          # "Bridge's Mac helper", "OmacVM Gestures' Trackpad")
          "guest", "host", "bridge", "gestures", "hyprland", "wayland", "kernel", "system", "device", "devices",
          "bluetooth", "wifi", "wi-fi", "network", "user", "this", "that", "its", "every", "other", "default",
          "windows", "settings", "camera", "display", "screen", "audio", "battery", "clock", "notch", "control",
          "centre", "center", "update", "helper", "helpers", "today", "everyone", "nobody", "someone",
          "desktop", "tools", "python", "textual", "swift", "mesa", "virgl", "metal", "venus", "apps", "app"}

# Plain words that are first names too: an owner when written with a capital
# ("Max's iPhone", "AirPods von Max"), a user name always.
NAME_LIKE = {"max", "marshall"}
# Accounts nobody is named after.
GENERIC_ACCOUNTS = {"user", "admin", "administrator", "guest", "test", "tester", "demo", "default", "vagrant", "nobody"}
# Name particles: not a name on their own ("Ludwig van Beethoven", "Ana de la Cruz").
PARTICLES = {"de", "da", "di", "du", "do", "del", "della", "des", "la", "le", "los", "las", "zu", "zur", "y", "e",
             "af", "av", "fra", "ten", "ter", "den", "dos", "das", "el", "bin", "ibn", "al", "van", "von", "der"}
# Not an owner in "<Word>'s <Word>": contractions ("What's New", "Let's
# Encrypt") and the apps Omarchy and OmacVM work with ("Chromium's GPU
# process", "Waybar's Clock").
NOT_OWNERS = {"what", "let", "there", "here", "it", "he", "she", "who", "where", "how", "when", "why", "one",
              "yesterday", "tomorrow", "world", "chromium", "chrome", "google", "firefox", "waybar", "walker",
              "alacritty", "ghostty", "kitty", "neovim", "nvim", "vim", "mako", "swayosd", "hyprlock", "hypridle",
              "hyprpaper", "hyprsunset", "swaybg", "btop", "lazygit", "lazydocker", "spotify", "obsidian", "signal",
              "typora", "docker", "pipewire", "wireplumber", "systemd", "nautilus", "localsend", "xournalpp",
              "basecamp", "elephant", "uwsm", "sddm", "plymouth", "limine", "snapper", "pacman", "github", "gnome",
              "gtk", "mpv", "imv", "libreoffice", "zoom", "discord", "whatsapp", "claude", "cursor", "omanotch",
              "impala", "bluetui", "wiremix", "fastfetch", "chatgpt", "dropbox", "safari", "finder", "xcode",
              "electron", "vulkan", "kosmickrisp", "moltenvk", "blender", "steam", "spice", "virtio", "ssh"}


def owner_word(w: str) -> bool:
    """W can be an owner's name in a device name: not a plain or product
    word, except the plain words that are names too, with a capital."""
    if w.casefold() in NAME_LIKE and w[:1].isupper():
        return True
    return w.casefold() not in COMMON and not product_only(w)


# Names of the products OmacVM works with, and the defaults they come with
# (Arch Linux ARM's host name "alarm", Omarchy's "omarchy"): a value made of
# these words alone is not taken out.
PRODUCT = {"omarchy", "omacvm", "parallels", "utm", "fusion", "vmware", "arch", "linux", "archlinux", "alarm",
           "arm", "arm64", "aarch64", "vm", "mac", "macos", "qemu", "localhost", "local", "root", "omanotch"}


def product_only(v: str) -> bool:
    """True when every word of V is a product word ("Omarchy", "omarchy-arm")."""
    words = [w for w in re.split(r"[^0-9a-z]+", v.casefold()) if w]
    return bool(words) and all(w in PRODUCT for w in words)


def common_only(v: str) -> bool:
    """True when V is device and plain words alone ("iPhone", "AirPods Pro",
    a phone's hotspot): nobody's name, and taking it out everywhere would
    take out every "iPhone" in the logs."""
    def plain(w: str) -> bool:
        return (w.casefold() in COMMON or product_only(w) or re.fullmatch(DEVICE_WORDS, w, re.I) is not None
                or re.fullmatch(r"\d{1,2}", w) is not None)
    words = [w for w in re.split(r"[^\w-]+", v) if w.strip("-")]
    # "Wi-Fi" as one word, "MacBook-Pro" as its parts.
    return bool(words) and all(plain(w) or all(plain(p) for p in w.split("-") if p) for w in words)


# A name with "'s" ("Zorro's", after norm() made every apostrophe plain).
POSSESSIVE = re.compile(r"^(.+?)'s?$", re.IGNORECASE)
# Apostrophes macOS and others put in device names ("Zorro’s AirPods").
APOSTROPHES = str.maketrans({"\u2019": "'", "\u2018": "'", "\u02bc": "'", "\u2032": "'", "\uff07": "'", "`": "'"})
UESCAPE = re.compile(r"\\u([0-9a-fA-F]{4})")
# \xHH runs (systemd-escape, Python and C strings): UTF-8 bytes.
XESCAPE = re.compile(r"(?:\\+x[0-9a-fA-F]{2})+")


def norm(s: str) -> str:
    """NFKC (full-width and other look-alike forms become plain letters),
    JSON's \\uXXXX and \\xHH escapes decoded ("Zorro\\u2019s" in a log line
    is "Zorro's", "ZorroNet\\x205G" in a unit name "ZorroNet 5G",
    "J\\xc3\\xbcrgen" "Jürgen"), every apostrophe a plain one. Control
    characters stay escaped."""
    def esc(m: re.Match) -> str:
        c = int(m.group(1), 16)
        return chr(c) if c >= 0x20 and not 0xD800 <= c <= 0xDFFF else m.group(0)   # no control characters

    def xesc(m: re.Match) -> str:
        raw = bytes(int(h, 16) for h in re.findall(r"x([0-9a-fA-F]{2})", m.group(0)))
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            text = raw.decode("latin-1")   # "J\\xfcrgen"
        return "".join(c if ord(c) >= 0x20 and ord(c) != 0x7F else "\\x%02x" % ord(c) for c in text)
    s = UESCAPE.sub(esc, s)
    s = XESCAPE.sub(xesc, s)
    return unicodedata.normalize("NFKC", s).translate(APOSTROPHES)


def variants(v: str) -> list:
    """V as it may be written in a log: as is, URL-encoded ("Zorro%20Home",
    "Zorro+Home"), with _ or - for spaces."""
    import urllib.parse as up
    out = [v]
    for w in (up.quote(v, safe=""), up.quote_plus(v, safe=""), v.replace(" ", "_"), v.replace(" ", "-")):
        if w not in out:
            out.append(w)
    return out


def one_plain_word(v: str) -> bool:
    """One word of letters, no digit and no capital inside ("Light",
    "garden", "FRITZ"; not "ZorroNet", "Zorro5", "Zorro Net")."""
    return re.fullmatch(r"[^\W\d_]+", v) is not None and \
        not any(a.islower() and b.isupper() for a, b in zip(v, v[1:]))


def edges(kind: str, v: str) -> tuple:
    """Values matched as whole words only: short ones ("pi" must not eat
    "pipewire") and plain words. A Wi-Fi name that is one plain word also
    needs no hyphen next to it: a Wi-Fi called "Light" must not turn
    "backlight" or "keyboard-light" into "back<wifi>". Other Wi-Fi names
    ("ZorroNet", "Zorro Home") go also inside a neighbour's ("ZorroNet-5G",
    "ZorroNets"). ("", "") for the rest: matched anywhere."""
    if kind == "wifi" and one_plain_word(v):
        return r"(?<![^\W_])(?<!-)", r"(?![^\W_])(?!-)"
    if len(v) < 4 or common_only(v):
        return r"(?<![^\W_])", r"(?![^\W_])"   # no letter or digit next to it
    return "", ""


def plain_user(kind: str, v: str) -> bool:
    """A user or first name that is a plain word too ("max", "Marshall",
    "pro"): taken out only where it stands as a name (name_like_re)."""
    return kind == "user" and re.fullmatch(r"[^\W\d_]+", v) is not None and \
        (v.casefold() in COMMON or v.casefold() in NAME_LIKE)


# Where a plain word is a user name: after a word that says so ("user max",
# "User: max", "login=max", "-u max", "su max", "chown max:...", OmacVM's own
# "installed for max", "home of max", "user       max" in build's summary,
# JSON's "user": "max", "user 'max'"), before @ (max@host), in id's
# "1000(max)" and pam's "by max(uid=1000)", at the start of a passwd line,
# with 's, in sudo's "max : TTY=...". "for max" is taken even where it is a
# plain word: the user name never stays in OmacVM's own lines.
USER_KEYS = ("user", "users", "username", "login", "logname", "owner", "account", "-u", "--user", "su", "chown",
             "for user", "as user", "as", "hi", "hello", "dear", "for", "home of", "name")
USER_SEPS = ("=", ": ", ":", " ", '="', "='", ': "', "=\\\"", '": "', '":"', "': '", "':'", " '", ' "', ": '",
             '=\\\'') + tuple(" " * n for n in range(2, 13))


def name_like_re(v: str) -> re.Pattern:
    """V as a name: capitalised ("Max", "Hi Max", "Max's"), or any case in
    the places above. Not "max size", "set to max", "max_connections"."""
    w = re.escape(v)
    cap = re.escape(v[:1].upper() + v[1:].lower())
    after = "|".join("(?<=(?i:%s)%s)" % (re.escape(k), re.escape(sep)) for k in USER_KEYS for sep in USER_SEPS)
    edge_l, edge_r = r"(?<![\w<'-])", r"(?![\w-])"
    return re.compile(
        edge_l + cap + edge_r +                                  # "Max", "Max's", "Hi Max"
        "|" + edge_l + "(?i:" + w + r")(?=@[\w.-]|'s\b)" +      # max@host, max's
        "|(?=(?i:" + w + "))(?:" + after + ")(?i:" + w + ")" + edge_r +   # user max, -u max, login=max
        r"|(?<=\d\()(?i:" + w + r")(?=\))" +                    # uid=1000(max)
        "|" + edge_l + "(?i:" + w + r")(?=\(uid=\d)" +           # by max(uid=1000)
        "|" + edge_l + "(?i:" + w + r")(?= : (?:[^\n;]*; )?TTY=)" +  # sudo: max : TTY=pts/0 ; ...
        "|" + edge_l + "(?i:" + w + r")(?= is not user\b)" +    # max is not user 1000
        "|(?<=(?i:" + w + "):)(?i:" + w + ")" + edge_r +         # chown max:max
        "|" + edge_l + "(?i:" + w + ")(?=:(?i:" + w + ")" + edge_r + ")" +
        "|(?m:^)(?i:" + w + r")(?=:[^:\n]*:\d)")                 # max:x:1000:... (passwd)


def _value_re(v: str, kind: str = "user") -> re.Pattern:
    if plain_user(kind, v):
        return name_like_re(v)
    left, right = edges(kind, v)
    return re.compile(left + re.escape(v) + right, re.IGNORECASE)


# The labels redact() puts in: never matched by a known value ("User" in
# "<user>"), and the gate looks past them. Anything else in angle brackets
# ("<dana>") is text like any other.
LABEL = re.compile(r"<(?:user|host|vm|wifi|bt-device|audio-device|camera|secret|key|ssh-key|email|serial|uuid|hw-addr"
                   r"|ip-\d+|ip6-\d+|mac-parallels|mac-utm|mac-app)>")


def outside_labels(text: str, fn) -> str:
    """FN applied to the text between the labels put in."""
    parts = LABEL.split(text)
    marks = LABEL.findall(text)
    out = [fn(parts[0])]
    for mark, part in zip(marks, parts[1:]):
        out += [mark, fn(part)]
    return "".join(out)


# Product names with a plain word that may also be someone's name ("Apple M4
# Max", "AirPods Max"): kept apart while the known values go, so a user called
# Max does not turn the chip into "M4 <user>".
PRODUCT_NAMES = re.compile(r"\b(?:Apple )?M[1-9]\d?(?: (?:Pro|Max|Ultra))\b|\bAirPods Max\b"
                           r"|\biPhone(?: \d{1,2})? Pro Max\b|\bMarshall (?:Major|Minor|Motif|Monitor|Acton|Stanmore"
                           r"|Woburn|Emberton|Middleton|Willen|Tufton)\b")


# "key: none", "token: (null)", "Using key: /path/to/key": no secret in them.
NO_VALUE = {"", "none", "null", "(null)", "nil", "<null>", "true", "false", "yes", "no", "unset", "missing", "set",
            "n/a", "-", "empty", "absent", "present", "ok", "on", "off", "default", "required", "not"}


def not_a_secret(name: str, v: str) -> bool:
    if v.casefold() in NO_VALUE:
        return True
    # The shell's working folder in sudo's and the journal's lines
    # ("PWD=/home/x ; USER=root"): a path, no password (homes go apart).
    if name == "PWD" and re.fullmatch(r"(?:~|/)[\w./~-]*", v):
        return True
    # A key's file, not the key ("key: /home/x/.ssh/id_ed25519"; homes go apart).
    return name.casefold().endswith("key") and re.fullmatch(r"(?:~|\.{0,2})/[\w./~-]*", v) is not None


def sub_changed(rx: re.Pattern, repl, text: str) -> tuple:
    """rx.subn, counting only the matches the replacement changed: a match
    left as it is ("PWD=/", "key: none") is not something taken out."""
    n = 0

    def one(m: re.Match) -> str:
        nonlocal n
        r = repl(m) if callable(repl) else m.expand(repl)
        if r != m.group(0):
            n += 1
        return r
    return rx.sub(one, text), n


PATTERNS = [
    ("key", re.compile(r"-----BEGIN [A-Z0-9 ]+-----.*?-----END [A-Z0-9 ]+-----", re.S), "<key>"),
    ("key", re.compile(r"\b(?:ssh-(?:ed25519|rsa|dss)|ecdsa-sha2-[a-z0-9-]+|sk-[a-z0-9@.-]+)\s+[A-Za-z0-9+/=]{16,}(?:\s+\S+)?"), "<ssh-key>"),
    # A login in a URL (https://user:password@host, ssh://user@host): both go.
    ("secret", re.compile(r"(?i)\b([a-z][a-z0-9+.-]*://)[^\s/@:]+:[^\s/@]+@"), r"\1<user>:<secret>@"),
    ("user", re.compile(r"(?i)\b([a-z][a-z0-9+.-]*://)(?!<)[^\s/@:]+@"), r"\1<user>@"),
    ("email", re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"), "<email>"),
    ("secret", re.compile(r"(?i)\b(Bearer)\s+[^\s\"']+"), r"\1 <secret>"),
    # GitHub tokens (ghp_, gho_, ghu_, ghs_, ghr_, github_pat_).
    ("secret", re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b"), "<secret>"),
    # Anthropic, Slack, AWS and GitLab tokens.
    ("secret", re.compile(r"\b(?:sk-ant-[A-Za-z0-9_-]{20,}|xox[abeoprs]-[A-Za-z0-9-]{10,}|(?:AKIA|ASIA)[0-9A-Z]{16}"
                          r"|glpat-[A-Za-z0-9_-]{20,})"), "<secret>"),
    # JSON web tokens (three base64url parts, the first starts with {"): a
    # login in itself, and its middle part may carry the user's name.
    ("secret", re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"), "<secret>"),
    # name = value, name: value, "name": "value", 'name': 'value' (YAML, INI,
    # JSON, Python), also with escaped quotes (\"value\" in a logged command
    # line): the value goes, quoted (also with spaces) or not.
    ("secret", re.compile(r"""(?i)\b(?P<name>(?:[a-z0-9]*[_-])*(?:token|password|passwd|pass|pwd|passphrase|secret|psk|api_?key|key|credentials?))"""
                          r"""(?P<sep>\\*["']?\s*[=:]\s*)(?:(?P<q>\\*["'])(?P<v>[^\n]*?)(?P=q)|(?P<bare>(?!<)(?!\\*["'])[^\s"',;}\\]+))"""),
     lambda m: m.group(0) if m.group("v") == "<secret>" or not_a_secret(m.group("name"), m.group("v") if m.group("v") is not None else m.group("bare") or "")
     else m.group("name") + m.group("sep") + (m.group("q") or "") + "<secret>" + (m.group("q") or "")),
    # Basic auth: base64 that does not look like a word ("Basic setup" stays).
    ("secret", re.compile(r"\b((?i:Basic))\s+((?=[A-Za-z0-9+/]*(?:[0-9+/=]|[A-Z][a-z]*[A-Z]))[A-Za-z0-9+/]{6,}={0,2})"),
     r"\1 <secret>"),
    # The value as the next argument: --passphrase X, -password X, a
    # settings key ("wifi-sec.psk X"); "password X" alone only when X is no
    # plain lower-case word ("password incorrect" stays).
    ("secret", re.compile(r"(?<![\w-])((?i:--?(?:[a-z0-9]+-)*(?:password|passwd|passphrase|psk|secret|token)"
                          r"|(?:[a-z0-9]+[.-])*[a-z0-9]+\.(?:psk|password|passphrase)))(\s+)(?![<=:])"
                          r"(?:\"[^\"\n]*\"|'[^'\n]*'|[^\s\"'<]+)"), r"\1\2<secret>"),
    ("secret", re.compile(r"(?<![\w.-])((?i:password|passphrase|psk))(\s+)(?![<=:])(?=[^\s]*[^a-z\s])"
                          r"(?:\"[^\"\n]*\"|'[^'\n]*'|[^\s\"'<]+)"), r"\1\2<secret>"),
    ("serial", re.compile(r"(?i)(IOPlatformSerialNumber\"?\s*=?\s*\"?|Serial Number(?: \(system\))?:\s*)([A-Z0-9]{6,})"), r"\1<serial>"),
    ("uuid", re.compile(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"), "<uuid>"),
    ("hw", re.compile(r"\b(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b"), "<hw-addr>"),
    # BlueZ writes them with _ (dev_30_7A_D2_32_1E_AE).
    ("hw", re.compile(r"(?<![0-9A-Fa-f])(?:[0-9A-Fa-f]{2}_){5}[0-9A-Fa-f]{2}(?![0-9A-Fa-f])"), "<hw-addr>"),
    ("hw", re.compile(r"\b[0-9A-Fa-f]{4}\.[0-9A-Fa-f]{4}\.[0-9A-Fa-f]{4}\b"), "<hw-addr>"),
    # Without separators (Parallels writes MACs so: 001C42EE41A6): with the
    # VM apps' own prefixes, or right after a word that says it is one. Not any
    # 12 hex digits: a short commit hash looks the same.
    ("hw", re.compile(r"(?i)\b(?:001c42|525400|000c29|005056|000569|00163e)[0-9a-f]{6}\b"), "<hw-addr>"),
    ("hw", re.compile(r"(?i)\b((?:mac|hw|hardware|ether|ethernet|bssid|lladdr)(?:[ _-]?(?:address|addr))?\"?\s*[=:]?\s*\"?)[0-9a-f]{12}\b"),
     r"\1<hw-addr>"),
    ("secret", re.compile(r"\b[0-9a-fA-F]{32,}\b"), "<secret>"),
]
# The owner in a device name nobody told us about ("Anna's AirPods" when the
# Bridge is down, or a guest's device): "<user>'s AirPods". Also macOS's host
# name form ("Annas-MacBook-Pro").
# Apple's and others' (headphones, phones, game pads ...).
DEVICE_WORDS = (r"(?:AirPods|iPhone|iPad|MacBook|iMac|Mac|Magic|Keyboard|Mouse|Trackpad|Watch|Beats|HomePod|AirTag|Pencil"
                r"|Galaxy|Buds|Pixel|Phone|Tablet|Laptop|PC|Computer|Headphones|Headset|Earbuds|Earphones|Speaker"
                r"|Soundbar|Controller|Gamepad|Pen|Band|Fitbit|Garmin|Surface|ThinkPad|Xbox|DualSense|DualShock"
                r"|Joy-Con|Bose|Sony|Jabra|JBL|Sennheiser|Logitech|Keychron|Kindle|Echo|OnePlus|Xiaomi|Huawei"
                r"|Marshall|Soundcore|TV|Car)")
DEVICE_OWNER = re.compile(r"(?<![\w<'])([^\W\d_][\w.-]*?)'s?(?=[\s_-]+" + DEVICE_WORDS + r"\b)", re.IGNORECASE)
# Any "<Name>'s <Word>" with a capital name and a capital (or number) word
# after it ("Dana's Galaxy Buds"): a name is likely. Our own words stay (COMMON).
POSSESSIVE_ANY = re.compile(r"(?<![\w<'])([^\W\d_][\w.-]*?)'s?(?=[ \t]+(?:[^\W\d_a-z]|\d))")
# The same without the apostrophe ("Annas iPhone", Nordic and German style):
# only before a personal device.
GENITIVE_S = re.compile(r"(?<![\w<'])([^\W\d_][^\W\d_]+?)s(?=[ \t]+(?:AirPods|iPhone|iPad|MacBook|iMac|Apple Watch"
                        r"|Watch|HomePod|AirTag|Galaxy|Pixel|Buds|Headphones|Omarchy)\b)")
HOST_OWNER = re.compile(r"(?<![\w<-])([A-Z][^\W\d_]+?)s?(?=-(?:MacBook|iMac|Mac-mini|Mac-Studio|Mac-Pro|iPhone|iPad)\b)")
# The same in lower case, where a tool wrote the host name so ("maxs-macbook-pro"):
# only with the s, which says it is someone's.
HOST_OWNER_LOWER = re.compile(r"(?<![\w<-])([a-z][a-z]+?)s(?=-(?:macbook|imac|mac-mini|mac-studio|mac-pro|iphone|ipad)\b)")
# A known host name's owner (Known.add): "Maxs-MacBook-Pro" and
# "annas-macbook-pro" give Max and anna, Finnish "Annan-MacBook-Pro" Annan.
HOST_FORM = re.compile(r"^([^\W\d_]+?)s?-(?:macbook|imac|mac-mini|mac-studio|mac-pro|iphone|ipad)\b", re.IGNORECASE)
# Finnish names a device with the owner's genitive in -n ("Annan AirPods",
# "Mikon iPhone", "Jussin MacBook Pro"): a capitalised word ending in a vowel
# and n before an Apple device, but not the words that look the same
# ("Open iPhone Mirroring", German "Meinen AirPods").
GENITIVE_N = re.compile(r"(?<![\w<'])([A-Z\u00c4\u00d6\u00c5][a-z\u00e4\u00f6\u00e5]+[aeiouy\u00e4\u00f6]n)"
                        r"(?=[ \t]+(?:AirPods|iPhone|iPad|MacBook|iMac|Apple Watch|HomePod|AirTag)\b)")
NOT_GENITIVE = {"open", "golden", "green", "garden", "kitchen", "main", "plain", "hidden", "broken", "chosen", "given",
                "seven", "eleven", "even", "often", "again", "then", "when", "screen", "modern", "wooden", "silicon",
                "cotton", "common", "certain", "domain", "join", "rejoin", "scan", "plan", "clean", "mean", "lean",
                "between", "within", "begin", "login", "plugin", "admin", "origin", "margin", "button", "season",
                "reason", "person", "lesson", "iron", "neon", "satin", "token", "taken", "spoken", "written",
                "forgotten", "frozen", "proven", "listen", "fallen", "seen", "been", "keen", "teen", "queen",
                "geen", "mein", "dein", "sein", "kein", "nein", "einen", "meinen", "deinen", "seinen", "ihren",
                "unseren", "euren", "keinen", "neuen", "alten", "anderen", "beiden", "diesen", "jeden", "welchen",
                "allen", "verbinden", "trennen", "suchen", "finden", "entfernen", "laden", "aufladen", "zeigen",
                "vergessen", "ignorieren", "aktivieren", "deaktivieren", "your", "lion", "union"}
# macOS in other languages names a device after its owner the other way round:
# "AirPods von Dana", "iPhone de Jean-Luc", "AirPods di Marco", "iPad van Jan",
# and its host name "MacBook-Pro-von-Dana"; French also "iPhone d'Anne".
PREPS = r"(?:von|vom|van|de|di|du|da|do|del|della|des|af|av|fra)"
# Words that also come up in English after a device ("AirPods do not ..."):
# there the name must start with a capital.
PREPS_CAPITAL = {"de", "da", "do"}
NAME = r"[^\W\d_][\w'-]*"
# A VM is named the same way ("Omarchy von Dana").
OWNED = r"(?:" + DEVICE_WORDS + r"|Omarchy|OmacVM)"
OWNER_SPACED = re.compile(r"\b(" + OWNED + r"(?:[ \t]+(?!" + PREPS + r"[ \t])[\w().+]+){0,3}?)[ \t]+(" + PREPS +
                          r")[ \t]+(" + NAME + r")(?:[ \t]+(" + NAME + r"))?(?:[ \t]+(" + NAME + r"))?", re.IGNORECASE)
# The owner in brackets after a device ("iPhone (Dana)", "AirPods Pro (Dana Keller)").
CAP_NAME = r"[A-Z][^\W\d_A-Z]+(?:['-][^\W\d_]+)*"   # "Dana", "Jean-Luc"; not "USB"
OWNER_BRACKETS = re.compile(r"\b(" + DEVICE_WORDS + r"(?:[ \t]+[\w.+-]+){0,3}?[ \t]*\()(" + CAP_NAME + r"(?:[ \t]+" + CAP_NAME +
                            r"){0,2})(\))")
OWNER_HYPHEN = re.compile(r"\b(" + DEVICE_WORDS + r"(?:-(?!" + PREPS + r"-)[A-Za-z0-9]+){0,3}?)-(" + PREPS +
                          r")-([^\W\d_][\w-]*)", re.IGNORECASE)
OWNER_ELIDED = re.compile(r"\b(" + DEVICE_WORDS + r"(?:[ \t]+[\w().+]+){0,3}?)[ \t]+d'(" + NAME + r")", re.IGNORECASE)
# The owner in a Mac or device name we know ("Mac mini von Gilles"): for Known.add.
OWNER_AFTER = re.compile(r"(?:^|[\s_-])" + PREPS + r"[\s_-]+([^\W\d_][\w'-]*)|(?:^|\s)d'([^\W\d_][\w-]*)", re.IGNORECASE)


def device_owners(text: str) -> tuple[str, int]:
    n = 0

    def plain(w: str) -> bool:
        if w.casefold() in NAME_LIKE and w[:1].isupper():
            return False   # "AirPods von Max", "Max's iPhone"
        return (w.casefold() in COMMON or (w + "s").casefold() in COMMON or w.casefold() in NOT_OWNERS
                or product_only(w) or product_only(w + "s"))

    def owner(m: re.Match) -> str:
        nonlocal n
        w = m.group(1)
        if plain(w):
            return m.group(0)
        n += 1
        return "<user>" + m.group(0)[len(w):]

    def capital_owner(m: re.Match) -> str:
        return owner(m) if m.group(1)[0].isupper() else m.group(0)

    def after(m: re.Match) -> str:
        nonlocal n
        prep, name = m.group(2), m.group(3)
        # In a host name the owner may be in lower case: "mac-mini-von-max".
        hyphen_name = m.re is OWNER_HYPHEN and name.casefold() in NAME_LIKE
        if not hyphen_name and (plain(name) or (prep.casefold() in PREPS_CAPITAL and not name[0].isupper())):
            return m.group(0)
        n += 1
        end = 3
        # A second and third name ("von Anna Maria", "von Hans Peter Müller"), when they are names.
        for g in range(4, (m.re.groups or 3) + 1):
            more = m.group(g)
            if not more or not more[0].isupper() or plain(more) or re.fullmatch(DEVICE_WORDS, more, re.I):
                break
            end = g
        return m.group(0)[:m.start(3) - m.start(0)] + "<user>" + m.group(0)[m.end(end) - m.start(0):]

    def brackets(m: re.Match) -> str:
        nonlocal n
        if any(plain(w) for w in m.group(2).split()) or re.search(DEVICE_WORDS, m.group(2), re.I):
            return m.group(0)
        n += 1
        return m.group(1) + "<user>" + m.group(3)

    def elided(m: re.Match) -> str:
        nonlocal n
        if plain(m.group(2)):
            return m.group(0)
        n += 1
        return m.group(0)[:m.start(2) - m.start(0)] + "<user>"
    text = OWNER_HYPHEN.sub(after, text)
    text = OWNER_SPACED.sub(after, text)
    text = OWNER_ELIDED.sub(elided, text)
    text = OWNER_BRACKETS.sub(brackets, text)
    text = DEVICE_OWNER.sub(owner, text)
    text = POSSESSIVE_ANY.sub(capital_owner, text)
    text = GENITIVE_S.sub(capital_owner, text)

    def genitive_n(m: re.Match) -> str:
        return m.group(0) if m.group(1).casefold() in NOT_GENITIVE else owner(m)

    def lower_host(m: re.Match) -> str:
        nonlocal n
        if m.group(1) in NAME_LIKE or not plain(m.group(1)):
            n += 1
            return "<user>s"
        return m.group(0)
    text = GENITIVE_N.sub(genitive_n, text)
    text = HOST_OWNER.sub(owner, text)
    text = HOST_OWNER_LOWER.sub(lower_host, text)
    return text, n


# The Bridge's own log lines (bridge/mac): their names go whole, whatever
# language or form they have.
QUOTED = re.compile(r'"(?:[^"\\\n]|\\.)*"')
BRIDGE_CONNECTED = re.compile(r"(\bconnected=)\[([^\n]*\]|[^\n]*$)", re.M)     # bluetooth: connected=["...", "..."]
BRIDGE_SSID = re.compile(r"(\bssid=)(?!<[a-z][a-z0-9-]*>(?:[ \t]|$))(?!null\b)([^\n]+?)(?=[ \t]+ch=|$)", re.M)
BRIDGE_PASSWORD = re.compile(r"(Wi-Fi password for )(?!<wifi>)(.+?)( requested by )")
BRIDGE_BT_ACTION = re.compile(r"(/bluetooth/(?:connect|disconnect|forget) from \S+(?: failed)?: )([^\n]+)")
BRIDGE_BT_SAID = (("connected ", ""), ("disconnected ", ""), ("forgot ", ""), ("", " already connected"),
                  ("", " not connected"), ("", " did not connect (is it on and in range?)"), ("", " did not disconnect"))
BRIDGE_VM = re.compile(r"(\bcontrol: \S+ \S+ from \S+ \()(?!-\))(?!<vm>\))([^\n]+?)(\): \d{3}\b)")
# audio: output=<name> (<transport>) vol=0.5 muted=0 input=<name> (...) ...
BRIDGE_AUDIO = re.compile(r"(\b(?:output|input)=)(?!-(?:[ \t]|$))(?!<audio-device> \()([^\n]+?)( \([\w -]+\) vol=)")
# camera: on (<name>), camera: back: <name>
BRIDGE_CAMERA = re.compile(r"(\bcamera: (?:on \(|back: ))(?!<camera>)([^\n]+?)(\)?[ \t]*$)", re.M)
# Omanotch: guest 3 is VM "<name>", strip serves guest 3 ("<name>")
OMANOTCH_VM = re.compile(r'(\bguest \d+ is VM "|\bstrip serves guest \d+ \(")((?:[^"\\\n]|\\.)+)(")')
# The names macOS gives a Mac's own audio devices and cameras: kept.
BUILT_IN = re.compile(r"(?:MacBook (?:Pro|Air) |Mac mini |iMac |Mac Studio |Studio Display |External |LG UltraFine Display )?"
                      r"(?:Speakers|Microphone|Headphones|FaceTime HD Camera|Camera)(?: \(Built-in\))?|FaceTime HD Camera"
                      r"|BlackHole \d+ch|Microsoft Teams Audio|ZoomAudioDevice|Multi-Output Device|Aggregate Device"
                      r"|OmacVM test picture")


def bridge_lines(text: str) -> tuple[str, dict]:
    counts: dict = {}

    def bump(kind: str) -> None:
        counts[kind] = counts.get(kind, 0) + 1

    def connected(m: re.Match) -> str:
        inner = m.group(2)
        if inner.strip() in ("]", ""):
            return m.group(0)
        items = QUOTED.findall(inner)
        if items and QUOTED.sub("", inner).strip(" ,]") == "":
            for _ in items:
                bump("bt")
            return m.group(1) + "[" + ", ".join("<bt-device>" for _ in items) + "]"
        bump("bt")
        return m.group(1) + "[<bt-device>]"

    def ssid(m: re.Match) -> str:
        bump("wifi")
        return m.group(1) + "<wifi>"

    def action(m: re.Match) -> str:
        said = m.group(2)
        for head, tail in BRIDGE_BT_SAID:
            if said.startswith(head) and said.endswith(tail) and len(said) > len(head) + len(tail):
                name = said[len(head):len(said) - len(tail)]
                if name in ("?", "<bt-device>", "the device"):
                    return m.group(0)
                bump("bt")
                return m.group(1) + head + "<bt-device>" + tail
        return m.group(0)

    def vm(m: re.Match) -> str:
        bump("vm")
        return m.group(1) + "<vm>" + m.group(3)

    def password(m: re.Match) -> str:
        bump("wifi")
        return m.group(1) + "<wifi>" + m.group(3)

    def device(kind: str, label: str):
        def sub(m: re.Match) -> str:
            if BUILT_IN.fullmatch(m.group(2).strip()):
                return m.group(0)
            bump(kind)
            return m.group(1) + label + m.group(3)
        return sub

    def omanotch(m: re.Match) -> str:
        bump("vm")
        return m.group(1) + "<vm>" + m.group(3)
    text = BRIDGE_CONNECTED.sub(connected, text)
    text = BRIDGE_SSID.sub(ssid, text)
    text = BRIDGE_PASSWORD.sub(password, text)
    text = BRIDGE_BT_ACTION.sub(action, text)
    text = BRIDGE_VM.sub(vm, text)
    text = BRIDGE_AUDIO.sub(device("audio", "<audio-device>"), text)
    text = BRIDGE_CAMERA.sub(device("camera", "<camera>"), text)
    text = OMANOTCH_VM.sub(omanotch, text)
    return text, counts


# Base64 runs of 40 or more: only with digits and both cases, so a long path
# (letters and slashes) stays.
B64 = re.compile(r"(?<![A-Za-z0-9+/])[A-Za-z0-9+/]{40,}={0,2}")
# An address may end a sentence ("connect to 192.168.1.20."): only a digit, or
# a dot and a digit (a longer dotted number), ends the match early.
# Octets with leading zeros too (010.211.055.032).
IPV4 = re.compile(r"(?<!\d)(?<!\d\.)((?:25[0-5]|2[0-4]\d|[01]?\d?\d)(?:\.(?:25[0-5]|2[0-4]\d|[01]?\d?\d)){3})(?!\d)(?!\.\d)")
IPV6 = re.compile(r"(?<![0-9A-Fa-f:])((?:[0-9A-Fa-f]{1,4}:){2,7}[0-9A-Fa-f]{1,4}|(?:[0-9A-Fa-f]{1,4}:){1,7}:|::(?:[0-9A-Fa-f]{1,4}:){0,6}[0-9A-Fa-f]{1,4}|(?:[0-9A-Fa-f]{1,4}:){1,6}(?::[0-9A-Fa-f]{1,4}){1,6})(?![0-9A-Fa-f:])")
HOMES = re.compile(r"(/Users|/home)/(?!<)[^/\s:'\"]+")
TIME_LIKE = re.compile(r"^\d{1,2}(?::\d{2}){1,2}$")
PCI = re.compile(r"[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}")


def redact(text: str, known: Known, mac_addrs: dict | None = None) -> tuple[str, dict]:
    """Returns the text without personal data, and how many of each kind went."""
    counts: dict = {}

    def bump(kind: str, n: int = 1) -> None:
        if n:
            counts[kind] = counts.get(kind, 0) + n

    text = norm(text)
    # Home folders first, so "/home/zorro/x" becomes "~/x", not "/home/<user>/x".
    for h in sorted(known.home, key=len, reverse=True):
        text, n = re.subn(re.escape(h.rstrip("/")) + r"(?=/|\b|$)", "~", text)
        bump("home", n)
    text, n = HOMES.subn("~", text)
    bump("home", n)
    # Keys, URL logins and e-mail addresses whole, before their parts match a name.
    for kind, rx, repl in PATTERNS[:5]:
        text, n = sub_changed(rx, repl, text)
        bump(kind, n)
    # The names in the Bridge's own log lines, known or not.
    text, c = bridge_lines(text)
    for kind, n in c.items():
        bump(kind, n)
    # 1. Known values, longest first over all kinds (a VM named after its user).
    kept = PRODUCT_NAMES.findall(text)
    text = PRODUCT_NAMES.sub(lambda m: "\ue000" + str(kept.index(m.group(0))) + "\ue001", text)
    for kind, v in sorted(known.items(), key=lambda kv: len(kv[1]), reverse=True):
        for w in variants(v):
            rx = _value_re(w, kind)

            def sub(t: str, rx=rx, kind=kind) -> str:
                t, n = rx.subn(LABELS[kind], t)
                bump(kind, n)
                return t
            text = outside_labels(text, sub)
    text = re.sub("\ue000(\\d+)\ue001", lambda m: kept[int(m.group(1))], text)
    # 2. Patterns: device owners first, then the rest. (A known value that is
    # a device word alone, a phone's hotspot "iPhone", is not taken: it would
    # break up "iPhone-de-Jean-Luc" before this.)
    text, n = device_owners(text)
    bump("user", n)
    for kind, rx, repl in PATTERNS[5:]:
        text, n = sub_changed(rx, repl, text)
        bump(kind, n)

    def b64(m: re.Match) -> str:
        v = m.group(0)
        if re.search(r"\d", v) and re.search(r"[a-z]", v) and re.search(r"[A-Z]", v):
            bump("secret")
            return "<secret>"
        return v
    text = B64.sub(b64, text)
    labels = dict(MAC_ADDRS, **(mac_addrs or {}))
    seen: dict = {}

    def ip(m: re.Match) -> str:
        a = m.group(1)
        if a in KEEP_ADDRS:
            return a
        if a in labels:
            return labels[a]
        if a not in seen:
            seen[a] = f"<ip-{len(seen) + 1}>"
        bump("ip")
        return seen[a]
    text = IPV4.sub(ip, text)

    def ip6(m: re.Match) -> str:
        a = m.group(1)
        if a in ("::1", "::") or TIME_LIKE.match(a) or a.count(":") < 2:
            return a
        if PCI.fullmatch(a) and re.match(r"\.[0-7]\b", m.string[m.end():m.end() + 3]):
            return a   # a PCI address, 0000:00:02.0
        if a not in seen:
            seen[a] = f"<ip6-{sum(1 for k in seen if ':' in k) + 1}>"
        bump("ip")
        return seen[a]
    text = IPV6.sub(ip6, text)
    return text, counts


def gate(text: str, known: Known) -> None:
    """Refuse when any known value survived (normalised as norm(), case
    folded, also URL-encoded)."""
    import urllib.parse as up
    def clean(t: str) -> str:   # the labels put in and product names are no survivors
        return PRODUCT_NAMES.sub(" ", LABEL.sub(" ", norm(t))).casefold()
    t, t2 = clean(text), clean(up.unquote_plus(text))
    # Plain-word user names count only as names, which needs the case kept.
    c, c2 = (PRODUCT_NAMES.sub(" ", LABEL.sub(" ", norm(x))) for x in (text, up.unquote_plus(text)))
    for kind, v in known.items():
        if plain_user(kind, v):
            rx = name_like_re(norm(v))
            if rx.search(c) or rx.search(c2):
                raise RedactionFailed(kind)
            continue
        w = norm(v).casefold()
        for x in (t, t2):
            left, right = edges(kind, v)
            if re.search(left + re.escape(w) + right, x):
                raise RedactionFailed(kind)


def taken_out(counts: dict) -> str:
    """'3 user names, 1 address': never the values."""
    parts = []
    for kind, n in sorted(counts.items(), key=lambda kv: -kv[1]):
        noun = NOUNS.get(kind, kind)
        if n != 1:
            noun = noun + "es" if noun.endswith("address") else noun + "s"
        parts.append(f"{n} {noun}")
    return ", ".join(parts) if parts else "nothing personal found"


@dataclass
class Report:
    text: str
    counts: dict
    title: str


def build(sections: list, known: Known, title: str, mac_addrs: dict | None = None) -> Report:
    """sections: (heading, body) pairs. Redacts, gates, returns the report."""
    md = []
    for heading, body in sections:
        body = body.rstrip()
        if body:
            md.append(f"### {heading}\n{body}" if heading == "What happened" else f"### {heading}\n```\n{body}\n```")
    text, counts = redact("\n\n".join(md) + "\n", known, mac_addrs)
    t, c2 = redact(title, known, mac_addrs)
    gate(text + t, known)
    for k, v in c2.items():
        counts[k] = counts.get(k, 0) + v
    return Report(text=text, counts=counts, title=t)


def issue_url(report: Report) -> tuple[str, bool]:
    """The pre-filled issue URL; True when the text had to be cut (the rest
    goes to the clipboard and the issue says so)."""
    def url(body: str) -> str:
        return ISSUES + "?" + urllib.parse.urlencode({"title": report.title, "body": body, "labels": "bug"})
    full = url(report.text)
    if len(full) <= URL_MAX:
        return full, False
    note = "\n\n_The full report did not fit in the link: it is on the clipboard, pasted below._\n"
    lines = report.text.splitlines()
    logs = next((i for i, l in enumerate(lines) if l.startswith("### Logs")), None)
    # The logs' oldest lines go first; checks and versions stay.
    while lines and len(url("\n".join(lines) + note)) > URL_MAX:
        if logs is not None and logs + 2 < len(lines) and lines[logs + 2] != "```":
            del lines[logs + 2]
        else:
            lines.pop()
    return url("\n".join(lines) + note), True
