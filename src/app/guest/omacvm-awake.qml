// omacvm-awake.qml (OmacVM.app; run by omacvm-displays as its child, ADR 0072): holds Omarchy's own idle
// (its screensaver and lock) while a Firefox video plays where it can be seen. Firefox tells its wake lock
// only to org.freedesktop.ScreenSaver (the agent serves it), never to Wayland, and Omarchy's shell waits only
// for Wayland's idle inhibitors. A 1x1 transparent surface that takes no input and reserves no space, with an
// IdleInhibitor. It quits when the agent's lease ($XDG_RUNTIME_DIR/omacvm/guest-awake, {"until": unix
// seconds}, renewed every 10 s) is missing or stale: a hung agent lets go within about 30 s.
//
// Hyprland 0.56 looks at a layer surface's inhibitor only when the inhibitor is made or goes (and when a
// window maps or unmaps): one made before the surface is mapped never counts, and one switched off and on
// lets the idle timers start again. So it is made once, 2 s after the surface is shown (not after the start:
// on a slow guest the surface could map late), and never switched off.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
  id: root
  property bool armed: false

  function look() {
    let until = 0
    try {
      until = Number(JSON.parse(lease.text()).until) || 0
    } catch (e) {
      until = 0
    }
    if (until <= Date.now() / 1000)
      Qt.quit()
  }

  FileView {
    id: lease
    path: Quickshell.env("XDG_RUNTIME_DIR") + "/omacvm/guest-awake"
    onLoaded: root.look()
    onLoadFailed: Qt.quit()
  }

  Timer {
    interval: 2000
    running: surface.backingWindowVisible
    onTriggered: root.armed = true
  }

  Timer {
    interval: 5000
    running: true
    repeat: true
    onTriggered: lease.reload()
  }

  PanelWindow {
    id: surface
    implicitWidth: 1
    implicitHeight: 1
    color: "transparent"
    anchors.top: true
    anchors.left: true
    exclusionMode: ExclusionMode.Ignore
    mask: Region {}
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "omacvm-awake"

    IdleInhibitor {
      window: surface
      enabled: root.armed
    }
  }
}
