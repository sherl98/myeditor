"""Build a minimal drag-to-Applications window without automating Finder."""
import sys
from pathlib import Path

from dmgbuild import build_dmg
from ds_store import DSStore
from PIL import Image, ImageDraw

source, output = map(Path, sys.argv[1:])
background = source.parent / 'background.png'
# Render at 2x, then downsample for a smooth, restrained blue arrow.
image = Image.new('RGB', (1320, 840), 'white')
draw = ImageDraw.Draw(image)
for x, radius, color in [(600, 4, '#cfe5ff'), (618, 5, '#abd0ff'), (638, 6, '#80b7ff')]:
    draw.ellipse((x-radius, 380-radius, x+radius, 380+radius), fill=color)
draw.line([(656, 380), (698, 380)], fill='#579af5', width=10)
draw.line([(677, 356), (701, 380), (677, 404)], fill='#579af5', width=10, joint='curve')
image.resize((660, 420), Image.Resampling.LANCZOS).save(background)

# Backport the upstream Tahoe background fix while retaining Python 3.9 support.
# https://github.com/dmgbuild/dmgbuild/pull/275
mounted = None

def remember_mount(mount, options):
    global mounted
    mounted = Path(mount)

def finish_layout(event):
    if event.get('type') == 'operation::finished' and event.get('operation') == 'dsstore::create':
        with DSStore.open(str(mounted / '.DS_Store'), 'r+') as store:
            del store['.'][b'pBBk']

build_dmg(str(output), 'MyEditor', callback=finish_layout, settings={
    'create_hook': remember_mount,
    'format': 'UDZO',
    'filesystem': 'HFS+',
    'files': [str(source / 'MyEditor.app')],
    'symlinks': {'Applications': '/Applications'},
    'background': str(background),
    'window_rect': ((160, 140), (660, 420)),
    'default_view': 'icon-view',
    'icon_size': 128,
    'text_size': 13,
    'icon_locations': {'MyEditor.app': (175, 190), 'Applications': (490, 190)},
    'show_toolbar': False,
    'show_status_bar': False,
    'show_pathbar': False,
    'show_sidebar': False,
    'show_tab_view': False,
    'include_icon_view_settings': True,
    'include_list_view_settings': False,
})
