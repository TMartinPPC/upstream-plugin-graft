import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar badge for plugins that carry local commits. Hidden when everything is
// in sync, shows the diverged count otherwise; a click opens the graft flow
// in a held-open terminal so rebase conflicts stay visible.
BarWidget {
  id: root
  moduleName: "io.github.tmartinppc.plugin-graft"

  property int diverged: 0

  function refresh() {
    if (!scanRunning) scanProc.running = true
  }

  property bool scanRunning: scanProc.running

  function runGraft() {
    // -f keeps the terminal open until a keypress, so rebase conflict
    // instructions survive to be read. Refresh first so the badge reflects
    // reality before the prompt is shown.
    refresh()
    root.bar.run("omarchy-launch-floating-terminal-with-presentation omarchy-plugin-graft")
  }

  visible: diverged > 0
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: scanProc
    // --fetch makes "nothing waiting" trustworthy: it refreshes each
    // candidate's upstream tip (same bookkeeping graft uses). A failed
    // fetch (offline) keeps the last known tip instead of erroring.
    command: ["omarchy-plugin-diverged", "--fetch", "--json"]
    stdout: StdioCollector {
      id: scanOut
      waitForEnd: true
    }
    onExited: function(exitCode, exitCodeText) {
      let parsed = []
      try {
        parsed = JSON.parse(scanOut.text || "[]")
      } catch (e) {
        console.warn("plugin-graft: diverged scan output was not JSON:", e)
      }
      root.diverged = Array.isArray(parsed) ? parsed.length : 0
      if (exitCode !== 0 && exitCode !== 1)
        console.warn("plugin-graft: omarchy-plugin-diverged exited", exitCode)
    }
  }

  Component.onCompleted: refresh()

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uf126 " + root.diverged
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    tooltipText: root.diverged === 1
      ? "1 plugin needs upstream sync — click to graft"
      : root.diverged + " plugins need upstream sync — click to graft"
    onPressed: root.runGraft()
  }
}