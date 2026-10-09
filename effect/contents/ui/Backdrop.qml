import QtQuick
import Qt5Compat.GraphicalEffects
import org.kde.kwin as KWin
import "Style.js" as Style

// Blurred wallpaper behind the overview, with the same source and blur radius
// as Plasma's built-in overview. It stays opaque so edges uncovered by the
// zoom never flash dark; only the dimming follows the transition.
Item {
    id: backdrop
    // Desktop whose wallpaper to show; the current desktop when null.
    property var desktop: null
    required property string outputName
    // Transition progress, 0 closed to 1 open.
    property real progress: 0

    Rectangle { anchors.fill: parent; color: Style.backdropColor }
    KWin.DesktopBackground {
        id: wallpaper
        anchors.fill: parent
        activity: KWin.Workspace.currentActivity
        desktop: backdrop.desktop || KWin.Workspace.currentDesktop
        outputName: backdrop.outputName
        visible: false
    }
    FastBlur { anchors.fill: parent; source: wallpaper; radius: Style.backdropBlur }
    Rectangle { anchors.fill: parent; color: Style.backdropColor; opacity: Style.backdropDim * backdrop.progress }
}
