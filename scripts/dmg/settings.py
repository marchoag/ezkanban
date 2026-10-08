# dmgbuild settings for the EZKanban DMG window (used by scripts/release.sh).
# dmgbuild writes the Finder layout directly, so packaging needs no Finder
# automation permission. Paths are relative to the repo root.
import os.path

app = defines.get("app", "build/EZKanban.app")  # noqa: F821 (provided by dmgbuild)
app_name = os.path.basename(app)

format = "UDZO"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents/Resources/AppIcon.icns")  # volume icon

# 600x400 window to match background.tiff (1x + 2x); see background.html.
background = "scripts/dmg/background.tiff"
window_rect = ((200, 160), (600, 400))
icon_size = 112
text_size = 13
icon_locations = {
    app_name: (150, 190),
    "Applications": (450, 190),
}

default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
