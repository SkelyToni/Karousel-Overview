# Scroll Overview

A Karousel-aware KWin effect for Plasma **6.6.6** and Karousel **0.17**. Desktops form a vertical strip; each desktop retains Karousel's horizontal column order and the stored order of windows within each column. Live previews include windows scrolled off-screen.

The effect uses Plasma's `SceneEffect`, `WindowThumbnail`, and `SwipeGestureHandler` types. A shared QML JavaScript library connects it to Karousel's internal layout. KWin 6.6.6 loads declarative effects and scripts through the same QML engine, so no native plugin or compositor rebuild is required.

## Install

You need an installed **user-local** Karousel 0.17 package at `~/.local/share/kwin/scripts/karousel` (or the corresponding directory under `XDG_DATA_HOME`). A system or Nix store installation must first be copied to that user-local location. The package must contain its compiled `contents/code/main.js`.

```sh
python3 tools/install.py install
```

The installer patches two Karousel files and saves their originals with checksums. Re-running it updates the effect; it refuses to overwrite independently modified Karousel files. It does not alter your live desktop configuration by default.

For a Nix profile installation, use this to create the writable local copy and install the bridge:

```sh
python3 tools/install.py install --copy-karousel-from ~/.nix-profile/share/kwin/scripts/karousel
```

1. Restart Karousel by disabling and re-enabling it in **System Settings → Window Management → KWin Scripts**.
2. In **Desktop Effects**, disable Plasma's **Overview** and enable **Scroll Overview**. Both effects would otherwise register the same gesture.
3. Press **Meta+Ctrl+O**, or swipe **up with four fingers**.

Alternatively, `python3 tools/install.py install --activate` enables the effect, disables the built-in Overview, and reloads Karousel to attach the bridge. Reloading Karousel rebuilds its layout. `--data-home PATH` supports staging an installation away from your desktop.

The backdrop uses the current wallpaper with Plasma’s overview blur. Closing uses one coordinated zoom and camera movement, keeping live windows opaque until the effect hands back to the desktop.

## Controls

- Four-finger swipe up opens; four-finger swipe down closes. The transition follows your fingers and completes in half of KWin's full swipe distance. Releasing past halfway, or flicking, finishes the transition; releasing earlier or flicking back reverts it. Tune this with `gestureGain`, `gestureCommit` and `gestureFlick` in `effect/contents/ui/Style.js`.
- Two-finger scroll vertically to browse desktops, with gentle settling on a desktop row; scroll horizontally to browse the columns under the pointer, with release momentum. Scrolling works over previews and empty space and follows Plasma's scroll direction. A mouse wheel also works.
- Right-click and drag to pan a desktop horizontally. Window dragging near the screen edges scrolls the overview automatically.
- Click a window to switch desktop, focus it, and close the overview. Click a desktop background to switch desktop.
- Left/right arrows select windows; up/down selects the closest window on the adjacent desktop. Enter activates; Escape closes. Global shortcuts are temporarily paused while the overview is open, preventing snapping or moving the real windows; they resume on close or effect unload. Meta+Ctrl+O also closes through the overview’s key handler.
- A translucent destination preview follows your drag and shows the projected size and position before release.
- Drag a window onto another preview to join its column. Drop on a desktop background to insert a column at that horizontal position, including on another desktop.

## Restore

Disable Scroll Overview and enable Plasma Overview in Desktop Effects, then run:

```sh
python3 tools/install.py uninstall
```

Restart Karousel. The originals are restored only if the patched files still match their recorded checksums. Effect files and backups remain on disk for review.

## Scope and validation

This is an initial implementation, not a claim of full Niri parity. Plasma keeps its configured desktops rather than Niri's automatically created and removed workspaces. The overview includes all desktops in the current KDE activity. Karousel 0.17 manages a single tiling screen; other outputs show their own floating windows. Stacked Karousel columns reveal all their windows vertically in their stored order.

Remaining parity work includes drag-to-create desktops and Niri's exact spring animation. The effect has been tested in an isolated virtual KWin 6.6.6 session with Karousel 0.17, three desktops, and four live windows, including both scrolling axes, stacking, splitting columns, moving windows between desktops, and focusing them. Wheel delivery, momentum, snapping, and animation interruption have Qt input tests. Physical touchpad feel and global tiling shortcuts during the overview still need checking on your desktop.

Run the regression checks with:

```sh
python3 -m unittest discover -s tests -p 'test_*.py'
node tests/bridge.test.cjs
node tests/drop-preview.test.cjs
node tests/gesture.test.cjs
```

On NixOS, `nix-shell` provides Python, Node, and Qt tools. The installer needs no build dependencies beyond Python. The shared bridge relies on Karousel 0.17's implementation details; reinstall an updated compatible bridge after any Karousel upgrade.

To update an already installed effect without rebuilding Karousel's layout:

```sh
python3 tools/install.py install --reload-effect
```

Each changed version installs to a fresh package path because KWin caches QML after unloading an effect. The shared Karousel bridge keeps its original path. The installer disables the previous package and keeps its files for rollback; only the current package appears in Desktop Effects.

Qt input and motion tests can be run with `QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software qmltestrunner -input tests/qml`. They check wheel routing over clickable content, horizontal momentum, vertical snapping, bounds, and interrupting animations. The virtual KWin smoke also checks both scrolling axes and retention of live preview objects.

Sources checked: [KWin 6.6.6 declarative effect loader](https://github.com/KDE/kwin/blob/v6.6.6/src/effect/effectloader.cpp), [KWin QML effect example](https://github.com/KDE/kwin/tree/v6.6.6/examples/quick-effect), [Karousel 0.17](https://github.com/peterfajdiga/karousel/tree/v0.17), and [Niri overview](https://github.com/niri-wm/niri/blob/main/docs/wiki/Overview.md).
