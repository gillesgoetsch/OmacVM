"""`omacvm sound` in the VM (the audio panel runs it): the Mac's outputs as
macOS lists them and the balance, over this VM's control port, answered by
OmacVM.app itself. A pty stands in for the port and a thread for the app
(test_port.py)."""
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(__file__))

import pytest  # noqa: E402

from test_port import FakeApp  # noqa: E402

ENTRY = os.path.join(os.path.dirname(__file__), "..", "omacvm")
PATH = "/omacvm/app/sound"


@pytest.fixture
def vm(tmp_path):
    share = tmp_path / "share"
    share.mkdir()
    (share / "VERSION").write_text("3.4.7\n")
    env_file = tmp_path / "env"
    apps = []

    def run(answer, *args, vm_type="app", port=True):
        env_file.write_text(f"OMACVM_VM_TYPE={vm_type}\nOMACVM_HOST=10.0.2.2\n")
        env = {k: v for k, v in os.environ.items() if k != "OMACVM_BRIDGE_URL"}
        env.update(OMACVM_SHARE=str(share), OMACVM_ENV=str(env_file), HOME=str(tmp_path))
        app = None
        if port:
            app = FakeApp(answer)
            apps.append(app)
            env["OMACVM_CONTROL_PORT"] = app.path
        else:
            env["OMACVM_CONTROL_PORT"] = str(tmp_path / "no-port")
        p = subprocess.run([sys.executable, ENTRY, "sound", *args], env=env, capture_output=True, text=True, timeout=20)
        return p, (app.requests if app else [])
    yield run
    for a in apps:
        a.close()


STATE = {"accessibility": True, "output": "display-speakers-uid", "balance": None}
# What a Mac with a Studio Display and a HomePod answered (placeholder names).
DEVICES = [{"name": "MacBook Pro Speakers", "selected": False}, {"name": "Studio Display Speakers", "selected": True},
           {"name": "Kitchen", "selected": False}]
LIST = dict(STATE, devices=DEVICES, ms=973)


def test_reads_the_state(vm):
    p, reqs = vm(lambda r: (200, STATE), "--json")
    assert p.returncode == 0, p.stderr
    assert json.loads(p.stdout) == STATE
    assert reqs[-1]["method"] == "GET" and reqs[-1]["path"] == PATH and reqs[-1]["body"] is None


def test_reads_the_list(vm):
    p, reqs = vm(lambda r: (200, LIST), "read", "--json")
    assert p.returncode == 0, p.stderr
    assert json.loads(p.stdout) == dict(STATE, devices=DEVICES)
    assert reqs[-1]["method"] == "POST" and reqs[-1]["body"] == {"read": True}
    p, _ = vm(lambda r: (200, LIST), "read")
    assert p.stdout.splitlines() == ["  MacBook Pro Speakers", "* Studio Display Speakers", "  Kitchen",
                                     "Balance: this output has none"]


def test_presses_a_device(vm):
    def app(r):
        name = r["body"]["press"]
        return 200, dict(STATE, devices=[dict(d, selected=d["name"] == name) for d in DEVICES])
    p, reqs = vm(app, "press", "Kitchen", "--json")
    assert p.returncode == 0, p.stderr
    assert reqs[-1]["body"] == {"press": "Kitchen"}
    assert [d["name"] for d in json.loads(p.stdout)["devices"] if d["selected"]] == ["Kitchen"]


# AirPods Pro as the Mac's output, as Control Center listed them.
LISTENING = {"title": "Listening Mode", "options": [{"title": "Transparency", "selected": True, "enabled": True},
                                                    {"title": "Adaptive", "selected": False, "enabled": True},
                                                    {"title": "Noise Cancellation", "selected": False, "enabled": True}]}
SPATIAL = {"title": "Spatial Audio", "options": [{"title": "Not Available", "selected": False, "enabled": False}]}
CONVERSATION = {"title": "Conversation Awareness", "options": [{"title": "Off", "selected": True, "enabled": True},
                                                               {"title": "On", "selected": False, "enabled": True}]}
PODS = "AirPods Pro"
WITH_PODS = [{"name": "MacBook Pro Speakers", "selected": False}, {"name": PODS, "selected": True, "modes": [LISTENING, SPATIAL, CONVERSATION]},
             {"name": "Kitchen", "selected": False}]


def test_reads_the_modes_of_the_airpods(vm):
    p, _ = vm(lambda r: (200, dict(STATE, devices=WITH_PODS, ms=1012)), "read", "--json")
    assert p.returncode == 0, p.stderr
    assert json.loads(p.stdout)["devices"] == WITH_PODS
    p, _ = vm(lambda r: (200, dict(STATE, devices=WITH_PODS)), "read")
    assert p.stdout.splitlines()[1:6] == [f"* {PODS}", "    Listening Mode: *Transparency  Adaptive  Noise Cancellation",
                                          "    Spatial Audio: Not Available (not offered)", "    Conversation Awareness: *Off  On",
                                          "  Kitchen"]


def test_switches_a_mode(vm):
    def app(r):
        m = r["body"]["mode"]
        modes = [dict(g, options=[dict(o, selected=o["title"] == m["option"]) for o in g["options"]]) if g["title"] == m["group"] else g
                 for g in WITH_PODS[1]["modes"]]
        return 200, dict(STATE, devices=[WITH_PODS[0], dict(WITH_PODS[1], modes=modes), WITH_PODS[2]])
    p, reqs = vm(app, "mode", PODS, "Listening Mode", "Noise Cancellation", "--json")
    assert p.returncode == 0, p.stderr
    assert reqs[-1]["method"] == "POST" and reqs[-1]["body"] == {"mode": {"device": PODS, "group": "Listening Mode", "option": "Noise Cancellation"}}
    listening = json.loads(p.stdout)["devices"][1]["modes"][0]
    assert [o["title"] for o in listening["options"] if o["selected"]] == ["Noise Cancellation"]
    p, _ = vm(lambda r: (409, {"code": "no-option", "error": "no"}), "mode", PODS, "Spatial Audio", "Not Available", "--json")
    assert p.returncode == 4 and json.loads(p.stdout)["code"] == "no-option"


def test_sets_the_balance(vm):
    def app(r):
        value = r["body"]["balance"]["value"] if r["body"] else 0.5
        return 200, dict(STATE, balance={"value": value, "settable": True})
    p, reqs = vm(app, "balance", "25", "display-speakers-uid", "--json")
    assert p.returncode == 0, p.stderr
    assert [r["body"] for r in reqs] == [{"balance": {"value": 0.25, "output": "display-speakers-uid"}}]
    assert json.loads(p.stdout)["balance"] == {"value": 0.25, "settable": True}
    # Without OUTPUT, the balance of the output that plays now, as the app names it.
    p, reqs = vm(app, "balance", "25", "--json")
    assert p.returncode == 0, p.stderr
    assert [r["body"] for r in reqs] == [None, {"balance": {"value": 0.25, "output": "display-speakers-uid"}}]
    p, _ = vm(lambda r: (200, dict(STATE, balance={"value": 0.5, "settable": True})))
    assert p.stdout.strip() == "Balance: 50"


def test_opens_the_macs_settings(vm):
    p, reqs = vm(lambda r: (200, dict(STATE, accessibility=False)), "allow", "--json")
    assert p.returncode == 0, p.stderr
    assert reqs[-1]["method"] == "POST" and reqs[-1]["body"] == {"allow": True}
    assert json.loads(p.stdout)["accessibility"] is False


def test_the_app_says_no(vm):
    for status, code in [(403, "accessibility"), (409, "busy"), (409, "not-front"), (409, "no-device"), (409, "no-option"),
                         (409, "interrupted"), (409, "no-balance"), (501, "unsupported")]:
        p, _ = vm(lambda r, s=status, c=code: (s, {"code": c, "error": "no"}), "read", "--json")
        assert p.returncode == 4, (status, code, p.stderr)
        assert json.loads(p.stdout)["code"] == code


def test_older_app(vm):
    # An app without the request passes it to the Bridge, which knows no such one.
    p, _ = vm(lambda r: (404, {"code": "not-found", "error": "not found"}), "--json")
    assert p.returncode == 1 and p.stdout == ""
    p, _ = vm(lambda r: (0, {"error": "OmacVM Bridge does not answer on this Mac"}), "read", "--json")
    assert p.returncode == 1 and p.stdout == ""


def test_not_an_app_vm(vm):
    p, reqs = vm(lambda r: (200, STATE), "--json", vm_type="other")
    assert p.returncode == 3 and reqs == []
    p, _ = vm(None, "--json", port=False)
    assert p.returncode == 3


def test_usage(vm):
    for args in (["press"], ["press", ""], ["balance", "left"], ["balance", "101"], ["balance", "50", ""], ["volume", "5"], ["read", "now"],
                 ["mode", PODS, "Listening Mode"], ["mode", PODS, "", "Adaptive"], ["mode", PODS, "Listening Mode", "Adaptive", "now"]):
        p, reqs = vm(lambda r: (200, STATE), *args)
        assert p.returncode == 2 and reqs == [], args


def test_the_panel_gets_its_types(vm):
    p, _ = vm(lambda r: (200, {"accessibility": 1, "output": 7, "balance": {"value": "0.5"},
                               "devices": [{"name": "Kitchen", "selected": 1}, {"name": 5}, "Office", {"name": ""}]}),
              "read", "--json")
    assert json.loads(p.stdout) == {"accessibility": False, "output": None, "balance": None,
                                    "devices": [{"name": "Kitchen", "selected": False}]}
    p, _ = vm(lambda r: (200, {"accessibility": True, "output": None, "balance": None, "devices": [
        {"name": PODS, "selected": True, "modes": [
            {"title": "Listening Mode", "options": [{"title": "Adaptive", "selected": 1}, {"title": ""}, "Off", {"title": "On", "enabled": True}]},
            {"title": "Spatial Audio", "options": []}, {"title": 3, "options": [{"title": "On"}]}, {"options": [{"title": "On"}]}]},
        {"name": "Kitchen", "selected": False, "modes": "none"}]}), "read", "--json")
    assert json.loads(p.stdout)["devices"] == [
        {"name": PODS, "selected": True, "modes": [{"title": "Listening Mode", "options": [
            {"title": "Adaptive", "selected": False, "enabled": False}, {"title": "On", "selected": False, "enabled": True}]}]},
        {"name": "Kitchen", "selected": False}]
    p, _ = vm(lambda r: (200, {"accessibility": True, "balance": {"value": 7, "settable": True}}), "--json")
    assert json.loads(p.stdout)["balance"] == {"value": 1.0, "settable": True}
