# Third-party software

Flipdial's own source code is MIT-licensed (see `LICENSE`). Release builds also ship the
following separate program, which Flipdial runs as an external process:

## FFmpeg

- Bundled in `Flipdial.app/Contents/Resources/bin/ffmpeg` together with the libraries it links
  against (`Contents/Resources/lib`), copied from the Homebrew `ffmpeg` formula.
- FFmpeg in this configuration (`--enable-gpl --enable-version3`, with libx264, libx265 and others)
  is licensed under the **GNU General Public License v3.0 or later**: https://www.gnu.org/licenses/gpl-3.0.html
- Source code: https://ffmpeg.org/download.html (exact release: run
  `Flipdial.app/Contents/Resources/bin/ffmpeg -version`). Build recipe:
  https://github.com/Homebrew/homebrew-core/blob/master/Formula/f/ffmpeg.rb
- Each bundled library keeps its own license (GPL, LGPL, BSD or similar); see the projects listed
  by `ffmpeg -version` and their Homebrew formulae.

## Optional, not bundled

- **LibreOffice** (MPL 2.0) — used if you install it, for PowerPoint and legacy Office files.
- **Pandoc** (GPL 2.0+) — used if you install it, for higher-fidelity Markdown/EPUB conversion.
