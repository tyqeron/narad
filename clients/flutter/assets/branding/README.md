# Narad app mark

The mark reuses the same Google Material Icons `hub_rounded` glyph already shown
inside Narad. Material Icons is licensed under Apache 2.0; its license is included.

Regenerate the committed Android adaptive/legacy/monochrome icons, Windows ICO,
and Linux PNG with `scripts/create-app-icons.py --font /path/to/MaterialIcons-Regular.otf`.
The script requires Python fontTools and Pillow plus rsvg-convert. These are asset
maintenance tools, not application build dependencies. The Flutter SDK is pinned;
its `hub_rounded` codepoint is `0xF0335`.
