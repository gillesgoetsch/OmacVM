// omacvm-awake.qml (OmacVM.app; run by omacvm-displays as its child, ADR 0072): holds Omarchy's own idle
// (its screensaver and lock) while a Firefox video plays where it can be seen. Firefox tells its wake lock
// only to org.freedesktop.ScreenSaver (the agent serves it), never to Wayland, and Omarchy's shell waits only
// for Wayland's idle inhibitors. A 1x1 transparent surface that takes no input and reserves no space, with an
// IdleInhibitor that is on only while the agent's lease is fresh ($XDG_RUNTIME_DIR/omacvm/guest-awake,
// {"until": unix seconds}, renewed every 10 s): a hung agent lets go within 25 s.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
  id: root
  property bool fresh: false

  function look() {
    let until = 0
    try {
      until = Number(JSON.parse(lease.text()).until) || 0
    } catch (e) {
      until = 0
    }
    root.fresh = until > Date.now() / 1000
  }

  FileView {
    id: lease
    path: Quickshell.env("XDG_RUNTIME_DIR") + "/omacvm/guest-awake"
    onLoaded: root.look()
    onLoadFailed: root.fresh = false
  }

  Timer {
    interval: 5000
    running: true
    repeat: true
    onTriggered: {
      lease.reload()
      root.look()
    }
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
      enabled: root.fresh
    }
  }
}
