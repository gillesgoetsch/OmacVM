"""The control centre in Textual's headless driver (Pilot), against a fake
Mac: first frame time, keys, jobs, offline and older-Mac banners, updates,
report. Skipped where Textual is not installed."""
import asyncio
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(__file__))

import pytest  # noqa: E402

textual = pytest.importorskip("textual")

from fakes import FakeChecks, FakeMac, vm_env  # noqa: E402


@pytest.fixture
def world(tmp_path, monkeypatch):
    mac, checks = FakeMac(), FakeChecks()
    for k, v in vm_env(str(tmp_path), mac.port, checks.path).items():
        monkeypatch.setenv(k, v)
    yield mac
    mac.stop()
    checks.stop()


def app():
    from omacvm_cc.controller import Controller
    from omacvm_cc.tui import ControlCentre
    return ControlCentre(Controller())


async def settle(pilot, until, seconds=8.0):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        await pilot.pause(0.05)
        if until():
            return True
    a = pilot.app
    print("settle timed out:", a.c.hello, a.c.mac_error, a.c.vm_checks is not None, [w.name for w in a.workers])
    return False


def rows(a):
    return {r.feature.name: r for r in a.rows}


def test_first_frame_fast(world):
    """The budget is 0.5 s (measured in a real pty by vm_e2e.py). Here the
    process's CPU time is checked against it, and the wall time only loosely:
    a loaded machine or CI runner must not fail it."""
    async def go():
        t0, c0 = time.monotonic(), time.process_time()
        a = app()
        async with a.run_test(size=(110, 30)) as pilot:
            await pilot.pause()
            first, cpu = time.monotonic() - t0, time.process_time() - c0
            assert cpu < 0.5, f"first frame took {cpu:.2f} s of CPU"
            assert first < 3.0, f"first frame after {first:.2f} s"
            from textual.widgets import DataTable
            assert a.screen.query_one(DataTable).row_count == len(a.rows) >= 12
    asyncio.run(go())


def test_statuses_fill_in(world):
    async def go():
        a = app()
        async with a.run_test(size=(110, 30)) as pilot:
            assert await settle(pilot, lambda: a.c.linked and a.c.vm_checks is not None)
            await pilot.pause(0.2)
            r = rows(a)
            from omacvm_cc.state import Status
            assert r["bridge"].status is Status.WORKS
            assert r["camera"].status is Status.FAILING
            assert r["omanotch"].status is Status.UNAVAILABLE and "notch" in r["omanotch"].note
            assert r["gestures"].status is Status.OFF
            assert "Mac linked" in a.subtitle()
    asyncio.run(go())


def test_space_switches_through_the_mac(world):
    async def go():
        a = app()
        async with a.run_test(size=(110, 30)) as pilot:
            assert await settle(pilot, lambda: a.c.linked)
            names = [r.feature.name for r in a.rows]
            from textual.widgets import DataTable
            t = a.screen.query_one(DataTable)
            t.move_cursor(row=names.index("autologin"))
            await pilot.press("space")
            assert await settle(pilot, lambda: any(p == "/omacvm/jobs" for _, p, _ in world.requests))
            posts = [b for m, p, b in world.requests if p == "/omacvm/jobs"]
            assert posts[-1] == {"action": "enable", "features": ["autologin"]}
            assert await settle(pilot, lambda: all(not j.active for j in a.c.jobs.values()) and a.c.jobs)
    asyncio.run(go())


def test_title_follows_the_vm_version(world):
    """After an update the open window says the new version (the e2e saw 2.9.1 after 2.9.2 went in)."""
    async def go():
        a = app()
        async with a.run_test(size=(110, 30)) as pilot:
            assert await settle(pilot, lambda: a.c.linked)
            a.c.local.version = "9.9.9"
            a.refresh_all()
            await pilot.pause(0.1)
            assert a.screen.query_one(".box").border_title == "OmacVM 9.9.9"
    asyncio.run(go())


def test_failed_job_with_brackets_in_its_text(world):
    world.job_end = ("rolled-back", "omacvm apply: rolled back [/] [bold]x[/bold")

    async def go():
        a = app()
        async with a.run_test(size=(110, 30)) as pilot:
            assert await settle(pilot, lambda: a.c.linked)
            names = [r.feature.name for r in a.rows]
            from textual.widgets import DataTable
            a.screen.query_one(DataTable).move_cursor(row=names.index("autologin"))
            await pilot.press("space")
            assert await settle(pilot, lambda: a.c.jobs and not any(j.active for j in a.c.jobs.values()))
            await pilot.pause(0.5)
            assert list(a.c.jobs.values())[-1].state == "rolled-back"
    asyncio.run(go())


def test_dependency_asks_first(world):
    async def go():
        a = app()
        async with a.run_test(size=(110, 30)) as pilot:
            assert await settle(pilot, lambda: a.c.linked)
            names = [r.feature.name for r in a.rows]
            from textual.widgets import DataTable
            a.screen.query_one(DataTable).move_cursor(row=names.index("scroll-momentum"))
            await pilot.press("space")
            await pilot.pause(0.2)
            from omacvm_cc.tui import ConfirmScreen
            assert isinstance(a.screen, ConfirmScreen)
            await pilot.press("y")
            assert await settle(pilot, lambda: any(p == "/omacvm/jobs" for _, p, _ in world.requests))
            body = [b for _, p, b in world.requests if p == "/omacvm/jobs"][-1]
            assert body["action"] == "enable" and set(body["features"]) == {"scroll-momentum", "gestures"}
    asyncio.run(go())


def test_unavailable_does_not_ask_the_mac(world):
    async def go():
        a = app()
        async with a.run_test(size=(110, 30)) as pilot:
            assert await settle(pilot, lambda: a.c.mac_status is not None)
            names = [r.feature.name for r in a.rows]
            from textual.widgets import DataTable
            a.screen.query_one(DataTable).move_cursor(row=names.index("omanotch"))
            await pilot.press("space")
            await pilot.pause(0.3)
            assert not any(p == "/omacvm/jobs" for _, p, _ in world.requests)
    asyncio.run(go())


def test_offline_banner_and_read_only(tmp_path, monkeypatch):
    checks = FakeChecks()
    for k, v in vm_env(str(tmp_path), 9, checks.path).items():   # nothing listens on port 9
        monkeypatch.setenv(k, v)

    async def go():
        a = app()
        async with a.run_test(size=(110, 30)) as pilot:
            assert await settle(pilot, lambda: a.c.mac_error is not None)
            await pilot.pause(0.1)
            assert "does not answer" in a.banner()
            assert "Mac not reachable" in a.subtitle()
            await pilot.press("space")
            await pilot.pause(0.2)
            assert a.c.jobs == {}
    asyncio.run(go())
    checks.stop()


def test_older_mac_is_read_only(tmp_path, monkeypatch):
    mac, checks = FakeMac(old=True), FakeChecks()
    for k, v in vm_env(str(tmp_path), mac.port, checks.path).items():
        monkeypatch.setenv(k, v)

    async def go():
        a = app()
        async with a.run_test(size=(110, 30)) as pilot:
            assert await settle(pilot, lambda: a.c.mac_error is not None)
            assert a.c.mac_error.kind == "old"
            assert "omacvm update on the Mac" in a.banner()
    asyncio.run(go())
    mac.stop()
    checks.stop()


def test_updates_screen_and_silence(world):
    world.manifest = {"version": "2.9.1", "notes_url": "https://github.com/gillesgoetsch/omacvm/releases/tag/v2.9.1",
                      "parts": {"gestures": {"digest": "sha256:" + "c" * 64, "release": "2.9.1", "note": "fewer missed swipes"},
                                "bridge": {"digest": "sha256:" + "b" * 64, "release": "2.7.0"}}}

    async def go():
        a = app()
        async with a.run_test(size=(110, 30)) as pilot:
            assert await settle(pilot, lambda: a.c.updates is not None and a.c.updates.get("manifest"))
            await pilot.pause(0.1)
            r = rows(a)
            assert r["gestures"].update and not r["bridge"].update
            await pilot.press("U")
            await pilot.pause(0.2)
            from omacvm_cc.tui import UpdatesScreen
            assert isinstance(a.screen, UpdatesScreen)
            await pilot.press("s")
            assert await settle(pilot, lambda: not world.checks_enabled and not a.c.checks_enabled)
            # Checks off: no marks, no count on the features screen; the Updates screen still shows it.
            assert not any(r.update for r in a.rows) and "update" not in a.subtitle()
            assert rows_with_updates(a)["gestures"].update
            # ... and the last result is old: i installs nothing until c checked again.
            await pilot.press("i")
            await pilot.pause(0.3)
            from omacvm_cc.tui import ConfirmScreen
            assert not isinstance(a.screen, ConfirmScreen)
            assert not any(p == "/omacvm/jobs" for _, p, _ in world.requests)
            await pilot.press("c")
            assert await settle(pilot, lambda: a.c.manifest_fresh())
            await pilot.press("i")
            await pilot.pause(0.2)
            assert isinstance(a.screen, ConfirmScreen)
            await pilot.press("y")
            assert await settle(pilot, lambda: any(b == {"action": "update"} for _, p, b in world.requests if p == "/omacvm/jobs"))
    asyncio.run(go())


def rows_with_updates(a):
    return {r.feature.name: r for r in a.c.rows(with_updates=True)}


def test_checks_off_hides_marks_and_u_waits(world):
    world.manifest = {"version": "2.9.1", "parts": {"gestures": {"digest": "sha256:" + "c" * 64, "release": "2.9.1"}}}
    world.checks_enabled = False

    async def go():
        a = app()
        async with a.run_test(size=(110, 30)) as pilot:
            assert await settle(pilot, lambda: a.c.updates is not None and a.c.updates.get("manifest"))
            await pilot.pause(0.1)
            assert not any(r.update for r in a.rows)
            assert "update" not in a.subtitle()
            await pilot.press("u")
            await pilot.pause(0.3)
            from omacvm_cc.tui import ConfirmScreen
            assert not isinstance(a.screen, ConfirmScreen)
            assert not any(p == "/omacvm/jobs" for _, p, _ in world.requests)
    asyncio.run(go())


def test_lost_job_ends_failed_and_offers_a_retry(world, monkeypatch):
    from omacvm_cc import tui
    monkeypatch.setattr(tui, "LOST_AFTER", 2)
    world.job_polls_fail = True

    async def go():
        a = app()
        async with a.run_test(size=(110, 30)) as pilot:
            assert await settle(pilot, lambda: a.c.linked)
            names = [r.feature.name for r in a.rows]
            from textual.widgets import DataTable
            a.screen.query_one(DataTable).move_cursor(row=names.index("autologin"))
            await pilot.press("space")
            assert await settle(pilot, lambda: isinstance(a.screen, tui.ConfirmScreen), 12)
            j = list(a.c.jobs.values())[-1]
            assert j.state == "failed" and not j.active and a.c.active_job() is None
            assert "stopped answering" in a.last_result
            # Retry: the same job again.
            world.job_polls_fail = False
            await pilot.press("y")
            assert await settle(pilot, lambda: len([1 for _, p, _ in world.requests if p == "/omacvm/jobs"]) == 2)
            assert await settle(pilot, lambda: a.c.jobs and list(a.c.jobs.values())[-1].state == "done")
    asyncio.run(go())


async def yes_to_repair_a_working_row(pilot):
    """r on a row that works asks first (test_repair_a_working_row_asks_first)."""
    from omacvm_cc.tui import ConfirmScreen
    assert await settle(pilot, lambda: isinstance(pilot.app.screen, ConfirmScreen))
    await pilot.press("y")


def test_repair_a_working_row_asks_first(world):
    """The e2e: r on a row that works did nothing visible for a while (a
    reinstall started without a word). Now it says so and asks; on a failing
    row r still starts at once."""
    async def go():
        a = app()
        async with a.run_test(size=(110, 30)) as pilot:
            world.version = a.c.local.version
            assert await settle(pilot, lambda: a.c.linked and a.c.vm_checks is not None)
            from omacvm_cc.state import Status
            from omacvm_cc.tui import ConfirmScreen
            assert rows(a)["bridge"].status is Status.WORKS
            _move_to(a, "bridge")
            await pilot.press("r")
            assert await settle(pilot, lambda: isinstance(a.screen, ConfirmScreen))
            assert a.screen.title_text == "Repair OmacVM Bridge"
            assert "OmacVM Bridge works: nothing to repair. Install it again anyway?" in a.screen.text
            await pilot.press("n")
            await pilot.pause(0.3)
            assert not [p for _, p, _ in world.requests if p == "/omacvm/jobs"], "nothing ran after n"
            await pilot.press("r")
            await yes_to_repair_a_working_row(pilot)
            assert await settle(pilot, lambda: any(p == "/omacvm/jobs" for _, p, _ in world.requests))
            assert [b for _, p, b in world.requests if p == "/omacvm/jobs"][-1] == {"action": "reinstall", "features": ["bridge"]}
            assert await settle(pilot, lambda: not a.c.active_job())
            # A failing row: no question.
            assert rows(a)["camera"].status is Status.FAILING
            _move_to(a, "camera")
            await pilot.press("r")
            assert await settle(pilot, lambda: [b for _, p, b in world.requests if p == "/omacvm/jobs"][-1]
                                == {"action": "reinstall", "features": ["camera"]})
            assert not isinstance(a.screen, ConfirmScreen)
    asyncio.run(go())


def test_rolled_back_says_what_next(world):
    world.job_end = ("rolled-back", "omacvm apply: rolled back")

    async def go():
        a = app()
        async with a.run_test(size=(110, 30)) as pilot:
            assert await settle(pilot, lambda: a.c.linked)
            names = [r.feature.name for r in a.rows]
            from textual.widgets import DataTable
            a.screen.query_one(DataTable).move_cursor(row=names.index("mac-clock"))
            await pilot.press("r")
            await yes_to_repair_a_working_row(pilot)
            assert await settle(pilot, lambda: bool(a.last_result))
            assert a.last_result == ("Repair The Mac's clock: failed. This VM went back to its features from before "
                                     "(r tries again; ! reports the problem).")
            assert a.banner() == a.last_result
            body = [b for _, p, b in world.requests if p == "/omacvm/jobs"][-1]
            assert body == {"action": "reinstall", "features": ["mac-clock"]}
    asyncio.run(go())


def test_step_n_of_m_while_running(world):
    async def go():
        a = app()
        async with a.run_test(size=(110, 30)) as pilot:
            assert await settle(pilot, lambda: a.c.linked)
            names = [r.feature.name for r in a.rows]
            from textual.widgets import DataTable
            a.screen.query_one(DataTable).move_cursor(row=names.index("autologin"))
            await pilot.press("space")
            assert await settle(pilot, lambda: rows(a)["autologin"].status.value == "busy")
            assert await settle(pilot, lambda: "(2/4)" in rows(a)["autologin"].note or "(1/4)" in rows(a)["autologin"].note)
    asyncio.run(go())


@pytest.mark.parametrize("release,want", [("2.9.1", "u updates this VM"),
                                           (None, "on the Mac, omacvm apply --vm NAME --vm-type parallels brings this VM up to it")])
def test_update_first_offers_u(world, release, want):
    world.refuse_jobs = (409, "update-first", "the Mac has OmacVM 2.9.1, this VM 2.7.0: update first")
    if release:
        world.manifest = {"version": release, "parts": {}}
    seen = []

    async def go():
        a = app()
        orig = a.notify
        a.notify = lambda m, **kw: (seen.append(str(m)), orig(m, **kw))
        async with a.run_test(size=(110, 30)) as pilot:
            assert await settle(pilot, lambda: a.c.linked)
            names = [r.feature.name for r in a.rows]
            from textual.widgets import DataTable
            a.screen.query_one(DataTable).move_cursor(row=names.index("autologin"))
            await pilot.press("space")
            assert await settle(pilot, lambda: any(want in m for m in seen)), seen
    asyncio.run(go())


def test_still_asking_the_mac(world):
    world.hello_delay = 2.0
    seen = []

    async def go():
        a = app()
        orig = a.notify
        a.notify = lambda m, **kw: (seen.append(str(m)), orig(m, **kw))
        async with a.run_test(size=(110, 30)) as pilot:
            await pilot.pause(0.2)
            assert a.c.hello is None
            await pilot.press("space")
            await pilot.pause(0.1)
            assert any(m == "still asking the Mac: a moment" for m in seen), seen
            assert not any(p == "/omacvm/jobs" for _, p, _ in world.requests)
    asyncio.run(go())


def test_every_mac_request_is_signed_and_the_key_never_sent(world):
    async def go():
        a = app()
        async with a.run_test(size=(110, 30)) as pilot:
            assert await settle(pilot, lambda: a.c.linked and a.c.mac_status is not None)
    asyncio.run(go())
    from fakes import VM_KEY
    assert world.signed and all(ok for _, ok in world.signed)
    for headers, body in world.headers_seen:
        assert VM_KEY not in " ".join(headers.values()) and VM_KEY.encode() not in body


def test_report_has_no_personal_data(world, monkeypatch):
    async def go():
        a = app()
        async with a.run_test(size=(110, 30)) as pilot:
            assert await settle(pilot, lambda: a.c.linked and a.c.vm_checks is not None)
            await pilot.press("exclamation_mark")
            from omacvm_cc.tui import ReportScreen
            assert await settle(pilot, lambda: isinstance(a.screen, ReportScreen) and a.screen.rep is not None, 15)
            text = a.screen.rep.text
            for bad in ("ZorroNet", "a4:2b:b0", "Zorro's AirPods", "11:22:33:44:55:66", "Zorro Guest"):
                assert bad.lower() not in text.lower(), bad
            assert "### Versions" in text and "Apple M4 Max" in text
    asyncio.run(go())


def test_details_and_back(world):
    async def go():
        a = app()
        async with a.run_test(size=(110, 30)) as pilot:
            assert await settle(pilot, lambda: a.c.vm_checks is not None)
            await pilot.press("enter")
            await pilot.pause(0.2)
            from omacvm_cc.tui import DetailsScreen, FeaturesScreen
            assert isinstance(a.screen, DetailsScreen)
            await pilot.press("escape")
            await pilot.pause(0.1)
            assert isinstance(a.screen, FeaturesScreen)
            await pilot.press("q")
    asyncio.run(go())


def test_escape_closes_it(world):
    """A floating window like a quick-access one: Escape closes it (q too)."""
    async def go():
        a = app()
        async with a.run_test(size=(110, 30)) as pilot:
            assert await settle(pilot, lambda: a.c.vm_checks is not None)
            await pilot.press("escape")
            await pilot.pause(0.2)
            assert a.return_code is not None
    asyncio.run(go())

def test_rollback_says_which_part_failed(world):
    world.job_end = ("rolled-back", "the Mac's clock was not set up")
    world.job_extra = {"failed_part": "mac-clock"}

    async def go():
        a = app()
        async with a.run_test(size=(110, 30)) as pilot:
            assert await settle(pilot, lambda: a.c.linked)
            names = [r.feature.name for r in a.rows]
            from textual.widgets import DataTable
            a.screen.query_one(DataTable).move_cursor(row=names.index("mac-clock"))
            await pilot.press("r")
            await yes_to_repair_a_working_row(pilot)
            assert await settle(pilot, lambda: bool(a.last_result))
            assert a.last_result.startswith("Repair The Mac's clock: the Mac's clock was not set up. This VM went back")
    asyncio.run(go())


def test_failed_update_says_the_mac_kept_it_and_the_way_out(world, monkeypatch, tmp_path):
    """The update's camera part failed: the Mac keeps 2.9.1, the VM went back;
    turning the part off or repairing it is the way on (the Mac allows both)."""
    import base64
    with open(os.environ["OMACVM_ENV"], "a") as f:
        f.write("OMACVM_VM_NAME_B64=" + base64.b64encode(b"My Omarchy").decode() + "\n")
    world.manifest = {"version": "2.9.1", "parts": {"camera": {"digest": "sha256:" + "c" * 64, "release": "2.9.1"}}}
    world.job_end = ("rolled-back", "camera was not set up")
    world.job_extra = {"failed_part": "camera", "mac_omacvm": "2.9.1"}

    async def go():
        a = app()
        async with a.run_test(size=(110, 30)) as pilot:
            assert await settle(pilot, lambda: a.c.linked and a.c.update_offered())
            await pilot.press("u")
            await pilot.pause(0.2)
            await pilot.press("y")
            assert await settle(pilot, lambda: bool(a.last_result), 10)
            r = a.last_result
            assert r.startswith("Update: camera was not set up. The Mac keeps OmacVM 2.9.1; "
                                f"this VM went back to OmacVM {a.c.local.version} and its features."), r
            assert "Turn the Mac's camera off (space) or repair it (r)" in r
            assert "omacvm apply --vm 'My Omarchy' --vm-type parallels" in r
    asyncio.run(go())


def test_update_of_core_only_shows_progress_in_the_banner(world):
    world.manifest = {"version": "2.9.1", "parts": {"core": {"digest": "sha256:" + "e" * 64, "release": "2.9.1"}}}
    world.job_polls_to_end = 6

    async def go():
        a = app()
        async with a.run_test(size=(110, 30)) as pilot:
            assert await settle(pilot, lambda: a.c.linked and a.c.update_offered())
            assert not any(r.update for r in a.rows)      # no feature row changes
            await pilot.press("u")
            await pilot.pause(0.2)
            await pilot.press("y")
            assert await settle(pilot, lambda: "(2/4)" in a.banner())
            assert a.banner() == "Update: the VM side (2/4)"
            assert not any(r.status.value == "busy" for r in a.rows)
    asyncio.run(go())


def test_lost_job_names_the_right_mac_command(world, monkeypatch):
    from omacvm_cc import tui
    monkeypatch.setattr(tui, "LOST_AFTER", 2)
    world.job_polls_fail = True

    async def go():
        a = app()
        async with a.run_test(size=(110, 30)) as pilot:
            assert await settle(pilot, lambda: a.c.linked)
            names = [r.feature.name for r in a.rows]
            from textual.widgets import DataTable
            a.screen.query_one(DataTable).move_cursor(row=names.index("autologin"))
            await pilot.press("space")
            assert await settle(pilot, lambda: isinstance(a.screen, tui.ConfirmScreen), 12)
            assert "omacvm features --vm NAME" in a.last_result and "omacvm status" not in a.last_result
    asyncio.run(go())


@pytest.mark.parametrize("vm,mac,release,offered", [
    ("2.7.0", "2.7.0", "2.9.1", True),
    ("2.9.1", "2.9.1", "2.9.0", False),   # a dev checkout ahead of the release
    ("2.9.0", "2.9.1", "2.9.0", False),   # the Mac ahead of the release
    ("2.9.0", "2.9.2", "2.9.1", False),   # it would take the Mac back
    ("2.9.0", "2.9.1", "2.9.1", True),    # after an update that went back in the VM
    ("1.x", "2.9.1", "2.9.1", True),
])
def test_never_a_downgrade(world, vm, mac, release, offered):
    from omacvm_cc import state as S
    assert S.update_offered(release, vm, mac) is offered


def test_a_release_older_than_the_vm_shows_nothing(world):
    world.manifest = {"version": "2.6.0", "parts": {"gestures": {"digest": "sha256:" + "c" * 64, "release": "2.6.0"}}}
    world.version = "2.6.0"

    async def go():
        a = app()
        async with a.run_test(size=(110, 30)) as pilot:
            assert await settle(pilot, lambda: a.c.updates is not None and a.c.updates.get("manifest"))
            await pilot.pause(0.1)
            assert not a.c.update_offered() and not any(r.update for r in a.rows)
            assert "update" not in a.subtitle()
            assert not any(r.update for r in a.c.rows(with_updates=True))
            await pilot.press("u")
            await pilot.pause(0.3)
            from omacvm_cc.tui import ConfirmScreen
            assert not isinstance(a.screen, ConfirmScreen)
            assert not any(p == "/omacvm/jobs" for _, p, _ in world.requests)
            await pilot.press("U")
            await pilot.pause(0.2)
            from textual.widgets import Static
            body = str(a.screen.query_one("#body", Static).render())
            assert "Up to date" in body and "→" not in body
    asyncio.run(go())


def test_repair_that_went_back_on_an_older_vm(world):
    """A repair while the Mac is newer installs all of the Mac's OmacVM; when
    it goes back, the text says the Mac keeps its version."""
    world.job_end = ("rolled-back", "The Mac's camera was not set up")
    world.job_extra = {"failed_part": "camera", "mac_omacvm": "2.9.1"}

    async def go():
        a = app()
        async with a.run_test(size=(110, 30)) as pilot:
            assert await settle(pilot, lambda: a.c.linked)
            names = [r.feature.name for r in a.rows]
            from textual.widgets import DataTable
            a.screen.query_one(DataTable).move_cursor(row=names.index("camera"))
            await pilot.press("r")
            assert await settle(pilot, lambda: bool(a.last_result))
            assert a.last_result == ("Repair The Mac's camera: The Mac's camera was not set up. The Mac keeps OmacVM 2.9.1; "
                                     f"this VM went back to OmacVM {a.c.local.version} and its features. Turn the Mac's camera off (space) "
                                     "to go on without it, or r tries again; on the Mac: omacvm apply --vm NAME --vm-type parallels. "
                                     "! reports the problem."), a.last_result
    asyncio.run(go())


def _move_to(a, name):
    from textual.widgets import DataTable
    a.screen.query_one(DataTable).move_cursor(row=[r.feature.name for r in a.rows].index(name))


@pytest.mark.parametrize("key", ["space", "r"])
def test_off_or_repair_on_an_older_vm_asks_first(world, key):
    """The Mac has a newer OmacVM: switching off or repairing brings all of it
    into this VM, so the control centre says so and waits for y."""
    world.version = "2.99.0"

    async def go():
        a = app()
        async with a.run_test(size=(110, 30)) as pilot:
            assert await settle(pilot, lambda: a.c.linked)
            _move_to(a, "camera")
            await pilot.press(key)
            await pilot.pause(0.3)
            from omacvm_cc.tui import ConfirmScreen
            assert isinstance(a.screen, ConfirmScreen), a.screen
            assert f"from OmacVM {a.c.local.version} to OmacVM 2.99.0" in a.screen.text
            await pilot.press("n")
            await pilot.pause(0.3)
            assert not [p for _, p, _ in world.requests if p == "/omacvm/jobs"], "nothing ran after n"
            await pilot.press(key)
            await pilot.pause(0.3)
            await pilot.press("y")
            assert await settle(pilot, lambda: any(p == "/omacvm/jobs" for _, p, _ in world.requests))
            posts = [b for m, p, b in world.requests if p == "/omacvm/jobs"]
            assert posts[-1] == {"action": "disable" if key == "space" else "reinstall", "features": ["camera"]}
    asyncio.run(go())


def test_same_version_switch_off_does_not_ask(world):
    async def go():
        a = app()
        async with a.run_test(size=(110, 30)) as pilot:
            world.version = a.c.local.version
            assert await settle(pilot, lambda: a.c.linked)
            _move_to(a, "camera")
            await pilot.press("space")
            assert await settle(pilot, lambda: any(p == "/omacvm/jobs" for _, p, _ in world.requests))
            assert await settle(pilot, lambda: a.c.jobs and all(not j.active for j in a.c.jobs.values()))
    asyncio.run(go())


@pytest.mark.parametrize("action,key,state,where", [
    ("enable", "space", "failed", "This VM was not changed."),
    ("update", "u", "failed", "now, as the Mac"),
])
def test_mac_helper_that_did_not_build(world, action, key, state, where):
    """A Mac helper failed: the job names it, says where the VM is, and the
    next step is on the Mac (not "apply", which would stop on it again)."""
    world.version = "2.99.0" if action == "update" else "2.7.0"
    world.manifest = {"version": "2.99.0", "parts": {"gestures": {"digest": "sha256:" + "a" * 64, "release": "2.99.0"}}}
    world.job_end = (state, "OmacVM Gestures did not build on the Mac")
    world.job_extra = {"failed_part": "gestures", "failed_side": "mac", "mac_omacvm": world.version}

    async def go():
        a = app()
        async with a.run_test(size=(110, 30)) as pilot:
            if action == "enable":
                world.version = a.c.local.version
                world.job_extra["mac_omacvm"] = a.c.local.version
            assert await settle(pilot, lambda: a.c.linked and (action != "update" or a.c.update_offered()))
            if action == "enable":
                _move_to(a, "gestures")
            await pilot.press(key)
            await pilot.pause(0.3)
            from omacvm_cc.tui import ConfirmScreen
            if isinstance(a.screen, ConfirmScreen):
                await pilot.press("y")
            assert await settle(pilot, lambda: bool(a.last_result), 10)
            r = a.last_result
            assert "OmacVM Gestures did not build on the Mac." in r and where in r, r
            assert "On the Mac, omacvm update tries it again and shows why" in r, r
            assert "omacvm apply" not in r and "space" not in r, r
    asyncio.run(go())


def test_control_centre_part_failed_never_says_turn_it_off(world):
    """An update whose control-centre part failed (Textual from pacman while
    offline): turning the control centre off from inside it is no way on."""
    world.manifest = {"version": "2.99.0", "parts": {"control-centre": {"digest": "sha256:" + "c" * 64, "release": "2.99.0"}}}
    world.version = "2.99.0"
    world.job_end = ("rolled-back", "The OmacVM control centre was not set up")
    world.job_extra = {"failed_part": "control-centre", "mac_omacvm": "2.99.0"}

    async def go():
        a = app()
        async with a.run_test(size=(110, 30)) as pilot:
            assert await settle(pilot, lambda: a.c.linked and a.c.update_offered())
            await pilot.press("u")
            await pilot.pause(0.2)
            await pilot.press("y")
            assert await settle(pilot, lambda: bool(a.last_result), 10)
            r = a.last_result
            assert "off (space)" not in r and "Later, u tries again" in r, r
    asyncio.run(go())


def test_vm_the_mac_does_not_list_yet_asks_again(world, monkeypatch):
    """The Mac does not list this VM yet (it just started, or the Bridge
    restarted): it answers unknown-vm at once and looks in the background;
    the control centre asks again until it is linked."""
    from omacvm_cc import tui
    monkeypatch.setattr(tui, "UNKNOWN_WAIT", 0.2)
    world.unknown_for = 2

    async def go():
        a = app()
        async with a.run_test(size=(110, 30)) as pilot:
            assert await settle(pilot, lambda: a.c.linked and a.c.mac_status is not None, 10)
            assert sum(1 for m, p, _ in world.requests if p == "/omacvm/status") == 3
    asyncio.run(go())


def test_old_vm_list_on_the_mac_asks_again(world, monkeypatch):
    """Final review point 3: the Mac's list still has a stopped VM at this
    VM's address, so the key does not match; the Mac looks again ("looking")
    and the control centre asks again with that message, not "omacvm apply"."""
    from omacvm_cc import tui
    monkeypatch.setattr(tui, "UNKNOWN_WAIT", 0.2)
    world.stale_for = 2
    seen = []

    async def go():
        a = app()
        orig = a.c.refresh_mac

        def spy():
            orig()
            if a.c.mac_error is not None:
                seen.append((a.c.mac_error.code, str(a.c.mac_error), a.c.mac_looking()))
        a.c.refresh_mac = spy
        async with a.run_test(size=(110, 30)) as pilot:
            assert await settle(pilot, lambda: a.c.linked and a.c.mac_status is not None, 10)
            assert sum(1 for m, p, _ in world.requests if p == "/omacvm/status") == 1
    asyncio.run(go())
    assert len(seen) == 2 and all(code == "vm-key" and looking and "looking at its VMs again" in msg
                                  for code, msg, looking in seen), seen


def test_wrong_key_without_looking_is_not_asked_again(world, monkeypatch):
    from omacvm_cc import tui
    monkeypatch.setattr(tui, "UNKNOWN_WAIT", 0.2)
    world.stale_for, world.stale_looking = 50, False

    async def go():
        a = app()
        async with a.run_test(size=(110, 30)) as pilot:
            assert await settle(pilot, lambda: a.c.mac_error is not None, 10)
            await pilot.pause(1.0)
            assert a.c.mac_error.code == "vm-key" and not a.c.mac_looking()
            assert "omacvm apply" in a.c.mac_problem()
            assert sum(1 for p, ok in world.signed if p == "/omacvm/status") == 1
    asyncio.run(go())


def test_graphics_row_on_an_app_vm(tmp_path, monkeypatch):
    from omacvm_cc.tui import ConfirmScreen
    """OmacVM.app VMs get a Graphics row; space asks, then sends the next choice."""
    mac, checks = FakeMac(version="2.9.0"), FakeChecks()
    mac.graphics = {"graphics": "auto", "next_start": "opengl", "this_start": "auto -> opengl (macOS 15)",
                    "driver_ready": False}
    for k, v in vm_env(str(tmp_path), mac.port, checks.path, "OMACVM_VM_TYPE=app\n").items():
        monkeypatch.setenv(k, v)

    async def go():
        a = app()
        async with a.run_test(size=(110, 30)) as pilot:
            assert await settle(pilot, lambda: a.c.linked and "graphics" in rows(a)
                                and rows(a)["graphics"].note.startswith("Automatic"))
            assert rows(a)["graphics"].note == "Automatic: OpenGL"
            from textual.widgets import DataTable
            t = a.screen.query_one(DataTable)
            t.move_cursor(row=[r.feature.name for r in a.rows].index("graphics"))
            await pilot.press("space")
            assert await settle(pilot, lambda: isinstance(a.screen, ConfirmScreen))
            assert "OpenGL" in a.screen.text and "next start" in a.screen.text
            await pilot.press("y")
            assert await settle(pilot, lambda: any(p == "/omacvm/jobs" for _, p, _ in mac.requests))
            posts = [b for m, p, b in mac.requests if p == "/omacvm/jobs"]
            assert posts[-1] == {"action": "graphics", "graphics": "opengl"}
    try:
        asyncio.run(go())
    finally:
        mac.stop()
        checks.stop()


def test_graphics_repair_with_vulkan_asks_first(tmp_path, monkeypatch):
    from omacvm_cc.tui import ConfirmScreen
    """Repair on Graphics Vulkan builds the driver again, which can update the
    VM's whole system first (omarchy update): asked, nothing sent on no."""
    mac, checks = FakeMac(version="2.9.0"), FakeChecks()
    mac.graphics = {"graphics": "vulkan", "next_start": "opengl", "this_start": "", "driver_ready": False,
                    "waiting_for_driver": True}
    for k, v in vm_env(str(tmp_path), mac.port, checks.path, "OMACVM_VM_TYPE=app\n").items():
        monkeypatch.setenv(k, v)

    async def go():
        a = app()
        async with a.run_test(size=(110, 30)) as pilot:
            assert await settle(pilot, lambda: a.c.linked and "graphics" in rows(a) and a.c.graphics() == "vulkan")
            from textual.widgets import DataTable
            t = a.screen.query_one(DataTable)
            t.move_cursor(row=[r.feature.name for r in a.rows].index("graphics"))
            await pilot.press("r")
            assert await settle(pilot, lambda: isinstance(a.screen, ConfirmScreen))
            assert "omarchy update" in a.screen.text
            await pilot.press("n")
            await pilot.pause(0.5)
            assert not any(p == "/omacvm/jobs" for _, p, _ in mac.requests)
            await pilot.press("r")
            assert await settle(pilot, lambda: isinstance(a.screen, ConfirmScreen))
            await pilot.press("y")
            assert await settle(pilot, lambda: any(p == "/omacvm/jobs" for _, p, _ in mac.requests))
            posts = [b for m, p, b in mac.requests if p == "/omacvm/jobs"]
            assert posts[-1] == {"action": "graphics", "graphics": "vulkan"}
    try:
        asyncio.run(go())
    finally:
        mac.stop()
        checks.stop()


def test_no_graphics_row_on_other_routes(world):
    async def go():
        a = app()
        async with a.run_test(size=(110, 30)) as pilot:
            assert await settle(pilot, lambda: a.c.linked)
            assert "graphics" not in rows(a)
    asyncio.run(go())


def test_live_refresh_while_open(world, monkeypatch):
    """An open control centre re-reads the VM's env when another window or
    the Mac changed it, and asks the Mac again (also after it failed)."""
    from omacvm_cc import tui
    monkeypatch.setattr(tui, "LIVE_EVERY", 0.3)

    async def go():
        a = app()
        asks = []
        real = a.c.refresh_mac
        monkeypatch.setattr(a.c, "refresh_mac", lambda: (asks.append(1), real())[1])
        async with a.run_test(size=(110, 30)) as pilot:
            assert await settle(pilot, lambda: a.c.linked and a.c.vm_checks is not None)
            before, n = a.c.local, len(asks)
            assert await settle(pilot, lambda: len(asks) >= n + 2, 5)
            assert a.c.local is before                   # nothing changed: not re-read
            path = os.environ["OMACVM_ENV"]
            with open(path, "a", encoding="utf-8") as f:
                f.write("\n# changed from another window\n")
            os.utime(path, (time.time() + 5, time.time() + 5))
            assert await settle(pilot, lambda: a.c.local is not before, 5)
    asyncio.run(go())


def gpu_world(tmp_path, monkeypatch, vm_type="app", gpu=True):
    mac, checks = FakeMac(version="3.0.0"), FakeChecks()
    if gpu:
        mac.gpu_memory = {"measured": True, "in_use_mb": 1126, "peak_mb": 1638, "budget_mb": 49152,
                          "pressure": "normal", "refused": 0, "lost": 0}
    for k, v in vm_env(str(tmp_path), mac.port, checks.path, f"OMACVM_VM_TYPE={vm_type}\n").items():
        monkeypatch.setenv(k, v)
    return mac, checks


def test_gpu_memory_row_live(tmp_path, monkeypatch):
    """An OmacVM.app VM shows its graphics memory, asked at most every 2 s
    while open (a warning when macOS is short of memory), and nothing once
    the control centre is closed."""
    from omacvm_cc.state import Status
    mac, checks = gpu_world(tmp_path, monkeypatch)

    async def go():
        a = app()
        async with a.run_test(size=(110, 30)) as pilot:
            assert await settle(pilot, lambda: a.c.linked and "gpu-memory" in rows(a)
                                and rows(a)["gpu-memory"].status is Status.WORKS)
            r = rows(a)["gpu-memory"]
            assert r.feature.title == "Graphics memory" and r.note == "1.1 GB (peak 1.6 GB)"
            from textual.widgets import DataTable
            t = a.screen.query_one(DataTable)
            t.move_cursor(row=[x.feature.name for x in a.rows].index("gpu-memory"))
            await pilot.pause(0.1)
            hint = str(a.screen.query_one("#hint").render())
            assert "VM memory is the Mac memory you gave the VM" in hint
            # macOS gets short of memory: the row warns at the next look.
            mac.gpu_memory = dict(mac.gpu_memory, pressure="critical", in_use_mb=3000, peak_mb=3100)
            assert await settle(pilot, lambda: rows(a)["gpu-memory"].status is Status.NEEDS_PERSON, seconds=5)
            assert rows(a)["gpu-memory"].note.startswith("2.9 GB (peak 3.0 GB); macOS is short of memory")
            # At most one look every 2 s (and no more than one at a time).
            n0, t0 = len(mac.gpu_memory_at), time.monotonic()
            await pilot.pause(4.5)
            n = len(mac.gpu_memory_at) - n0
            assert 1 <= n <= 3, f"{n} looks in {time.monotonic() - t0:.1f} s"
            gaps = [b - a_ for a_, b in zip(mac.gpu_memory_at, mac.gpu_memory_at[1:])]
            assert min(gaps[1:] or [2.0]) > 1.5, gaps   # the first two: ask_mac's look, then the timer's
            # Space explains instead of switching.
            await pilot.press("space")
            await pilot.pause(0.1)
            assert not any(p == "/omacvm/jobs" for _, p, _ in mac.requests)
        closed = len(mac.gpu_memory_at)
        await asyncio.sleep(2.5)
        assert len(mac.gpu_memory_at) == closed, "asked after the control centre closed"
    try:
        asyncio.run(go())
    finally:
        mac.stop()
        checks.stop()


def test_gpu_memory_not_asked_on_other_routes(tmp_path, monkeypatch):
    mac, checks = gpu_world(tmp_path, monkeypatch, vm_type="parallels")

    async def go():
        a = app()
        async with a.run_test(size=(110, 30)) as pilot:
            assert await settle(pilot, lambda: a.c.linked)
            await pilot.pause(2.5)
            assert "gpu-memory" not in rows(a)
            assert mac.gpu_memory_at == []
    try:
        asyncio.run(go())
    finally:
        mac.stop()
        checks.stop()


def test_gpu_memory_on_an_older_mac(tmp_path, monkeypatch):
    """A Mac whose hello does not list gpu-memory: the row says so, nothing is asked."""
    from omacvm_cc.state import Status
    mac, checks = gpu_world(tmp_path, monkeypatch, gpu=False)

    async def go():
        a = app()
        async with a.run_test(size=(110, 30)) as pilot:
            assert await settle(pilot, lambda: a.c.linked and "gpu-memory" in rows(a)
                                and "older" in rows(a)["gpu-memory"].note)
            assert rows(a)["gpu-memory"].status is Status.UNKNOWN
            await pilot.pause(2.5)
            assert not any(p == "/omacvm/gpu-memory" for _, p, _ in mac.requests)
    try:
        asyncio.run(go())
    finally:
        mac.stop()
        checks.stop()


def test_updates_screen_updates_omarchy_too(world, tmp_path, monkeypatch):
    """o: Omarchy's own update in its own window, apart from OmacVM's; the
    count of waiting packages comes from checkupdates."""
    b, calls = tmp_path / "bin", tmp_path / "calls"
    b.mkdir()
    for name, body in (("checkupdates", 'printf "mesa 1 -> 2\\nllvm-libs 22 -> 23\\n"'),
                       ("omarchy-launch-tui", f'echo "$*" >> {calls}')):
        (b / name).write_text(f"#!/bin/sh\n{body}\n")
        (b / name).chmod(0o755)
    monkeypatch.setenv("PATH", f"{b}{os.pathsep}{os.environ['PATH']}")
    monkeypatch.setenv("WAYLAND_DISPLAY", "wayland-1")
    monkeypatch.setenv("HYPRLAND_INSTANCE_SIGNATURE", "sig")

    async def go():
        a = app()
        async with a.run_test(size=(110, 40)) as pilot:
            await pilot.press("U")
            from omacvm_cc.tui import ConfirmScreen, UpdatesScreen
            assert await settle(pilot, lambda: a.omarchy_waiting == 2)
            body = str(a.screen.query_one("#body").render())
            assert isinstance(a.screen, UpdatesScreen)
            assert "Omarchy: 2 updates waiting" in body and "not OmacVM" in body
            await pilot.press("o")
            await pilot.pause(0.2)
            assert isinstance(a.screen, ConfirmScreen)
            await pilot.press("n")
            await pilot.pause(0.2)
            assert not calls.exists()
            await pilot.press("o")
            await pilot.pause(0.2)
            await pilot.press("y")
            end = time.monotonic() + 3
            while time.monotonic() < end and not calls.exists():
                await pilot.pause(0.05)
            assert calls.read_text().strip() == "omacvm --window update-system --yes"
            # Nothing went to the Mac: this is not the OmacVM update.
            assert not any(p == "/omacvm/jobs" for _, p, _ in world.requests)
    asyncio.run(go())
