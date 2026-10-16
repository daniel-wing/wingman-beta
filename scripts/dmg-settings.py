# Layout of the installer disk image, read by dmgbuild (scripts/make-dmg.sh):
# Wingman on the left, an Applications shortcut on the right, and the
# background with the arrow between them (scripts/make-dmg-background.swift
# draws it for these positions).
import os

app = defines["app"]
volume_name = "Wingman"
format = "UDZO"
filesystem = "HFS+"
icon = defines["icon"]
files = [app]
symlinks = {"Applications": "/Applications"}
background = defines["background"]

window_rect = ((200, 140), (600, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
icon_locations = {
    os.path.basename(app): (160, 160),
    "Applications": (440, 160),
}
