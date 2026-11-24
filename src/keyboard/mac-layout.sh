#!/bin/bash
# The Linux (XKB) keyboard layout for this Mac's current one, as
# "<layout> [<variant>]" (e.g. "ch de_mac" for macOS Swiss German).
#   mac-layout.sh               for a new VM: XKB's Mac variant where the
#                               Mac's layout has one ("de mac": Option-L = @,
#                               Option-5/6 = [ ], as on the Mac)
#   mac-layout.sh --pc          the PC layout ("de": AltGr-Q = @), what VMs
#                               before 3.6 got and keep (omacvm apply)
#   mac-layout.sh --mac-of KB   the Mac variant of KB ("de" -> "de mac");
#                               exit 1 and nothing: it has none
#   mac-layout.sh --pc-of KB    the PC layout of a Mac variant ("de mac" -> "de");
#                               exit 1 and nothing: KB is no Mac variant
# Unknown layouts fall back to "us" with a note on stderr.
# Every Mac variant here types level 3 (the Option characters) with the right
# Option key only (XKB level3(ralt_switch)); the left Option stays Alt for
# Omarchy's bindings. Spanish has no Mac variant in XKB, and Norwegian's
# (no mac) has no level 3 key at all: both keep the PC layout.
# PC layout | its Mac variant
pairs='de|de mac
ch de|ch de_mac
ch fr|ch fr_mac
fr|fr mac
gb|gb mac
it|it mac
nl|nl mac
pt|pt mac
se|se mac
dk|dk mac
fi|fi mac
is|is mac'

counterpart() {   # FIELD-IN FIELD-OUT KB
  [[ -n $3 ]] || return 1
  local out
  out=$(awk -F'|' -v i="$1" -v o="$2" -v k="$3" '$i == k { print $o; exit }' <<< "$pairs")
  [[ -n $out ]] && echo "$out"
}

case ${1:-} in
  --mac-of) counterpart 1 2 "${2:-}"; exit ;;
  --pc-of) counterpart 2 1 "${2:-}"; exit ;;
  --pc|"") ;;
  *) echo "usage: mac-layout.sh [--pc | --mac-of KB | --pc-of KB]" >&2; exit 2 ;;
esac

id=$(defaults read com.apple.HIToolbox AppleCurrentKeyboardLayoutInputSourceID 2>/dev/null)
id=${id#com.apple.keylayout.}
case $id in
  US|ABC|USExtended|ABC-India|Australian) kb="us" ;;
  USInternational-PC|ABC-Extended) kb="us intl" ;;
  Dvorak|DVORAK-QWERTYCMD) kb="us dvorak" ;;
  Colemak) kb="us colemak" ;;
  British|British-PC|ABC-QWERTZ) kb="gb" ;;
  Irish|IrishExtended) kb="ie" ;;
  Canadian) kb="ca eng" ;;
  Canadian-CSA|CanadianFrench-PC) kb="ca" ;;
  German) kb="de" ;;
  Austrian) kb="at" ;;
  SwissGerman) kb="ch de" ;;
  SwissFrench) kb="ch fr" ;;
  French|French-PC|French-numerical) kb="fr" ;;
  Belgian) kb="be" ;;
  Dutch) kb="nl" ;;
  Italian|Italian-Pro) kb="it" ;;
  Spanish|Spanish-ISO) kb="es" ;;
  Portuguese) kb="pt" ;;
  Brazilian|Brazilian-ABNT2|Brazilian-Pro) kb="br" ;;
  Danish) kb="dk" ;;
  Swedish|Swedish-Pro) kb="se" ;;
  Norwegian|NorwegianExtended) kb="no" ;;
  Finnish|FinnishExtended|FinnishSami-PC) kb="fi" ;;
  Icelandic) kb="is" ;;
  Polish|PolishPro) kb="pl" ;;
  Czech) kb="cz" ;;
  Czech-QWERTY) kb="cz qwerty" ;;
  Slovak|Slovak-QWERTY) kb="sk" ;;
  Hungarian|Hungarian-QWERTY) kb="hu" ;;
  Slovenian) kb="si" ;;
  Croatian|Croatian-PC) kb="hr" ;;
  Romanian|Romanian-Standard) kb="ro" ;;
  Estonian) kb="ee" ;;
  Latvian) kb="lv" ;;
  Lithuanian) kb="lt" ;;
  Turkish|Turkish-QWERTY|Turkish-QWERTY-PC|Turkish-Standard) kb="tr" ;;
  Greek|GreekPolytonic) kb="gr" ;;
  Russian|RussianWin|Russian-Phonetic) kb="ru" ;;
  Ukrainian|Ukrainian-PC) kb="ua" ;;
  Hebrew|Hebrew-QWERTY|Hebrew-PC) kb="il" ;;
  *) echo "keyboard: no Linux match for macOS layout '${id:-?}', using us" >&2; kb="us" ;;
esac
# Only the Mac's own layouts get the Mac variant; a "-PC" layout (or
# ABC-QWERTZ, FinnishSami-PC, French-numerical) is the PC one on purpose.
case $id in
  German|SwissGerman|SwissFrench|French|British|Italian|Italian-Pro|Dutch|Portuguese|Swedish|Swedish-Pro|Danish|Finnish|FinnishExtended|Icelandic)
    [[ ${1:-} == --pc ]] || kb=$(counterpart 1 2 "$kb" || echo "$kb") ;;
esac
echo "$kb"
