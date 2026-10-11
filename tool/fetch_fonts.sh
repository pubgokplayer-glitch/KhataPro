#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  tool/fetch_fonts.sh — download the OFL fonts into assets/fonts/.
#  Kept out of version control: 1.4 MB of binary in every clone for no reason.
#  After running this, uncomment the `fonts:` block in pubspec.yaml — a declared
#  but missing font asset is a hard build failure, which is why it ships
#  commented out.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/assets/fonts"
mkdir -p "$DEST"

fetch () {  # url, outfile
  if [ -f "$DEST/$2" ]; then echo "   · $2 already present"; return; fi
  echo "   ↓ $2"
  curl -fsSL --retry 3 -o "$DEST/$2" "$1"
}

# Inter — Latin UI face (variable, weights 100–900 in one 700 KB file)
fetch "https://github.com/rsms/inter/raw/master/docs/font-files/InterVariable.ttf" \
      "Inter-VariableFont_opsz,wght.ttf"

# Noto Nastaliq Urdu — the Urdu face. Nastaliq is NOT Naskh: shaping, line
# height and ligature behaviour all differ, and a Naskh font renders Urdu as
# visibly "wrong" to the target user. This is the correct one.
fetch "https://github.com/notofonts/notofonts.github.io/raw/main/fonts/NotoNastaliqUrdu/hinted/ttf/NotoNastaliqUrdu-Regular.ttf" \
      "NotoNastaliqUrdu-Regular.ttf"
fetch "https://github.com/notofonts/notofonts.github.io/raw/main/fonts/NotoNastaliqUrdu/hinted/ttf/NotoNastaliqUrdu-Bold.ttf" \
      "NotoNastaliqUrdu-Bold.ttf"

# Arabic-script fallback for Arabic numerals/diacritics in mixed strings
fetch "https://github.com/notofonts/notofonts.github.io/raw/main/fonts/NotoNaskhArabic/hinted/ttf/NotoNaskhArabic-Regular.ttf" \
      "NotoNaskhArabic-Regular.ttf"

cat <<'NOTE'

✔ fonts downloaded.

Now uncomment this block in pubspec.yaml:

  fonts:
    - family: Inter
      fonts:
        - asset: assets/fonts/Inter-VariableFont_opsz,wght.ttf
    - family: NotoNastaliqUrdu
      fonts:
        - asset: assets/fonts/NotoNastaliqUrdu-Regular.ttf
        - asset: assets/fonts/NotoNastaliqUrdu-Bold.ttf
          weight: 700
    - family: NotoNaskhArabic
      fonts:
        - asset: assets/fonts/NotoNaskhArabic-Regular.ttf

…then set the Urdu text style in lib/app/theme/typography.dart:
  height: 2.2 (Nastaliq needs far more leading than Latin; 1.4 clips it)

Licence: all four faces are SIL OFL 1.1 — free for commercial use, including
in a closed-source APK. Attribution belongs in docs/THIRD_PARTY.md.
NOTE
