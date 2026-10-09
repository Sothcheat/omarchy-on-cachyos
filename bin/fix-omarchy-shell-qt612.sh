#!/bin/bash

set -euo pipefail

# Make the Omarchy shell work on Qt 6.12.
#
# Qt 6.12 adds a built-in QML type named `Color`. It shadows the `Color`
# palette singleton the Omarchy shell imports from qs.Commons, so every
# `Color.bar.background`, `Color.tooltip.text`, ... resolves to Qt's type and
# evaluates to undefined. The shell still starts, but nothing it draws has a
# color: no bar, no launcher, no menus, and the journal fills with
#   TypeError: Cannot read property 'background' of undefined
#   Unable to assign [undefined] to QColor
#
# CachyOS ships Qt 6.12 before Omarchy's stable channel does. Upstream fixed
# it in b83d3df0 ("Qualify shell palette references for Qt 6.12") by importing
# qs.Commons under an alias and writing `Commons.Color` everywhere. This
# applies that same rewrite to an installed shell tree.
#
# Idempotent: already-qualified references are left alone, so on an Omarchy
# release that includes the upstream fix this changes nothing. It is also run
# from a pacman hook after every omarchy upgrade, because the package restores
# the unpatched files until that release lands.

HOOK_SCRIPT="/usr/local/lib/omarchy-on-cachyos/fix-omarchy-shell-qt612.sh"
HOOK_FILE="/etc/pacman.d/hooks/zz-omarchy-on-cachyos-qt612.hook"

# --install-hook: keep a copy of this script outside the repo checkout and
# re-run it after every omarchy package install or upgrade, then fix now.
if [ "${1:-}" = "--install-hook" ]; then
    (( EUID == 0 )) || exec sudo "$0" "$@"
    install -Dm755 "$(readlink -f "$0")" "$HOOK_SCRIPT"
    install -d -m 0755 "$(dirname "$HOOK_FILE")"
    cat > "$HOOK_FILE" <<EOF
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = omarchy

[Action]
Description = Qualifying Omarchy shell palette references for Qt 6.12...
When = PostTransaction
Exec = $HOOK_SCRIPT
EOF
    echo "Installed pacman hook $HOOK_FILE"
    shift
fi

SHELL_DIR="${1:-/usr/share/omarchy/shell}"

[ -d "$SHELL_DIR" ] || { echo "Omarchy shell not found at $SHELL_DIR" >&2; exit 1; }

if [ ! -w "$SHELL_DIR" ] && (( EUID != 0 )); then
    exec sudo "$0" "$SHELL_DIR"
fi

# A bare reference is `Color.` not preceded by a word character or a dot, so
# `Commons.Color.`, `textColor.` and `Qt.Color` are never touched.
mapfile -t FILES < <(grep -rlP '(?<![\w.])Color\.' --include='*.qml' "$SHELL_DIR" || true)

if (( ${#FILES[@]} == 0 )); then
    echo "Omarchy shell palette references are already qualified. Nothing to do."
    exit 0
fi

for file in "${FILES[@]}"; do
    perl -0pi -e '
        # Add the alias once: right after `import qs.Commons`, or, for files
        # inside the Commons module itself, after the last leading import.
        unless (/^import qs\.Commons as Commons$/m) {
            s/^(import qs\.Commons)$/$1\nimport qs.Commons as Commons/m
                or s/\A((?:(?:pragma|import)[^\n]*\n|[ \t]*\n)*(?:pragma|import)[^\n]*\n)/$1import qs.Commons as Commons\n/;
        }
        s/(?<![\w.])Color\./Commons.Color./g;
    ' "$file"
done

# Every file must now carry the alias and no bare references. Anything else
# means the tree has a shape this rewrite does not understand.
LEFT="$(grep -rlP '(?<![\w.])Color\.' --include='*.qml' "$SHELL_DIR" || true)"
MISSING=""
for file in "${FILES[@]}"; do
    grep -q '^import qs\.Commons as Commons$' "$file" || MISSING+="$file"$'\n'
done
if [ -n "$LEFT" ] || [ -n "$MISSING" ]; then
    echo "Error: the Qt 6.12 shell fix did not apply cleanly." >&2
    [ -n "$LEFT" ] && echo "Still unqualified:"$'\n'"$LEFT" >&2
    [ -n "$MISSING" ] && echo "Missing the Commons import:"$'\n'"$MISSING" >&2
    exit 1
fi

echo "Qualified the Color palette references in ${#FILES[@]} Omarchy shell files for Qt 6.12."
