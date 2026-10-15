#!/usr/bin/env python3
"""Reuse Flutter's hub_rounded glyph for Narad. Requires fontTools, rsvg-convert, Pillow."""
import argparse
from pathlib import Path
import subprocess
from fontTools.ttLib import TTFont
from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.svgPathPen import SVGPathPen
from PIL import Image

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--font',required=True,type=Path)
args=parser.parse_args()
root=Path(__file__).resolve().parents[1]
font=TTFont(args.font)
glyphs=font.getGlyphSet()
glyph=glyphs[font.getBestCmap()[0xF0335]]
pen=SVGPathPen(glyphs);glyph.draw(pen);path=pen.getCommands()
bounds=BoundsPen(glyphs);glyph.draw(bounds);x0,y0,x1,y1=bounds.bounds
scale=760/max(x1-x0,y1-y0)
x=(1024-(x1-x0)*scale)/2-x0*scale
y=(1024-(y1-y0)*scale)/2+y1*scale
assets=root/'clients/flutter/assets/branding';assets.mkdir(parents=True,exist_ok=True)
svg=f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024"><rect width="1024" height="1024" rx="200" fill="#f3faf7"/><path transform="translate({x} {y}) scale({scale} {-scale})" d="{path}" fill="#006b5b"/></svg>\n'
(assets/'narad.svg').write_text(svg)
subprocess.run(['rsvg-convert','-w','1024','-h','1024',str(assets/'narad.svg'),'-o',str(assets/'narad.png')],check=True)
android=root/'clients/flutter/android/app/src/main/res'
for qualifier,size in [('mdpi',48),('hdpi',72),('xhdpi',96),('xxhdpi',144),('xxxhdpi',192)]:
    destination=android/f'mipmap-{qualifier}'/'ic_launcher.png';destination.parent.mkdir(parents=True,exist_ok=True)
    Image.open(assets/'narad.png').resize((size,size),Image.Resampling.LANCZOS).save(destination)
def vector(name,extent,span,color):
    s=span/max(x1-x0,y1-y0);tx=(extent-(x1-x0)*s)/2-x0*s;ty=(extent-(y1-y0)*s)/2+y1*s
    out=android/'drawable'/name;out.parent.mkdir(exist_ok=True)
    out.write_text(f'<vector xmlns:android="http://schemas.android.com/apk/res/android" android:width="{extent}dp" android:height="{extent}dp" android:viewportWidth="{extent}" android:viewportHeight="{extent}"><group android:scaleX="{s}" android:scaleY="{-s}" android:translateX="{tx}" android:translateY="{ty}"><path android:fillColor="{color}" android:pathData="{path}"/></group></vector>\n')
vector('ic_narad_foreground.xml',108,60,'#006B5B')
vector('ic_narad_notification.xml',24,22,'#FFFFFFFF')
vector('ic_narad_monochrome.xml',108,60,'#FFFFFFFF')
for version in ['v26','v33']:
    out=android/f'mipmap-anydpi-{version}'/'ic_launcher.xml';out.parent.mkdir(exist_ok=True)
    monochrome='<monochrome android:drawable="@drawable/ic_narad_monochrome"/>' if version=='v33' else ''
    out.write_text(f'<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android"><background android:drawable="@color/narad_icon_background"/><foreground android:drawable="@drawable/ic_narad_foreground"/>{monochrome}</adaptive-icon>\n')
(android/'values'/'narad_colors.xml').write_text('<resources><color name="narad_icon_background">#F3FAF7</color></resources>\n')
Image.open(assets/'narad.png').save(root/'clients/flutter/windows/runner/resources/app_icon.ico',sizes=[(16,16),(32,32),(48,48),(64,64),(128,128),(256,256)])
print('Generated native launcher and notification icons from the existing hub_rounded symbol')
