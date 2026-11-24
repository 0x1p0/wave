# The installer window (dmgbuild settings): Wave on the left, an arrow, Applications on the right, on Wave's
# background. scripts/release.sh builds it, from the repository root:
#   dmgbuild -s App/Support/dmg/settings.py -D app=path/to/Wave.app -D background=background.tiff Wave Wave.dmg
# The background (640 × 428, and @2x) is pre-rendered art; release.sh joins the two into one TIFF.
# The window is the background plus Finder's title bar.
import os.path

app = defines.get('app', 'build/ReleaseDerivedData/Build/Products/Release/Wave.app')  # noqa: F821 (dmgbuild provides `defines`)
appname = os.path.basename(app)

format = 'ULFO'
filesystem = 'HFS+'
files = [app]
symlinks = {'Applications': '/Applications'}
icon = os.path.join(app, 'Contents', 'Resources', 'AppIcon.icns')
background = defines.get('background', 'App/Support/dmg/background.tiff')  # noqa: F821

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
window_rect = ((240, 160), (640, 460))
default_view = 'icon-view'
show_icon_preview = False
arrange_by = None
label_pos = 'bottom'
text_size = 13
icon_size = 104
icon_locations = {
    appname: (170, 196),
    'Applications': (470, 196),
}
hide_extensions = [appname]
