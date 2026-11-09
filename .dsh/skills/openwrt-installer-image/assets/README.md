# Installer fonts

- `installer-console.psf`: 16×24 Linux-console font with the installer prompt repertoire, generated from Noto Sans CJK SC Regular. The source font URL is https://raw.githubusercontent.com/notofonts/noto-cjk/main/Sans/OTF/SimplifiedChinese/NotoSansCJKsc-Regular.otf . Its SIL OFL license is `installer-font-LICENSE.txt`; source hash, glyph coverage and generated hash are recorded in `installer-font-coverage.json`.
- `installer-grub.pf2`: unmodified GNU Unifont PF2 from the compiler's `/usr/share/grub/unicode.pf2`. Its native name is `Unifont Regular 16`. It supplies monospaced menu glyphs, CJK and navigation symbols. See https://unifoundry.com/unifont.html and `installer-grub-LICENSE.txt`.
- `installer-translations.json`: Chinese/English installer message catalogue used during localization.

To regenerate the console font, run `make-installer-font.py --font /path/to/NotoSansCJKsc-Regular.otf` with Pillow available. Copy the compiler's unchanged `/usr/share/grub/unicode.pf2` to `installer-grub.pf2`. The generated `installer-font-ranges.txt` is a diagnostic repertoire, not a replacement for the full GRUB font. Rebuild ISO, run the static glyph checks, and visually inspect BIOS and UEFI menus plus installer prompts before publishing.
