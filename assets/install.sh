#!/bin/sh
# Install Zit for this user: the binary, its menu entry and its icon, so the
# launcher, the taskbar and the file manager all show it as Zit.
#
#   ./install.sh            install into ~/.local
#   ./install.sh --remove   take it out again
#
# A Linux executable carries no icon of its own; the desktop finds it through
# the .desktop entry and the icon theme, which is what this puts in place.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
prefix=${XDG_DATA_HOME:-$HOME/.local/share}
bin=$HOME/.local/bin

# Refresh the caches where the tools exist; harmless where they do not.
refresh() {
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$prefix/applications" || true
    command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q -t "$prefix/icons/hicolor" || true
    command -v kbuildsycoca6 >/dev/null 2>&1 && kbuildsycoca6 >/dev/null 2>&1 || true
}

if [ "${1:-}" = "--remove" ]; then
    rm -f "$bin/zit" "$prefix/applications/zit.desktop"
    for size in 16 32 48 64 128 256 512; do
        rm -f "$prefix/icons/hicolor/${size}x${size}/apps/zit.png"
    done
    refresh
    echo "Zit removed. Your settings in ~/.config/zit are left as they are."
    exit 0
fi

mkdir -p "$bin" "$prefix/applications"
install -m 755 "$here/zit" "$bin/zit"

for size in 16 32 48 64 128 256 512; do
    mkdir -p "$prefix/icons/hicolor/${size}x${size}/apps"
    install -m 644 "$here/icons/${size}x${size}/zit.png" "$prefix/icons/hicolor/${size}x${size}/apps/zit.png"
done

# The absolute path, so the menu entry works even where ~/.local/bin is not
# on the PATH the desktop session started with. Quoted the way the desktop
# entry spec asks — `"`, `` ` ``, `$` and `\` escaped, then every backslash
# doubled again for the string value, `%` as `%%` — so a home folder with a
# space or an `&` in it still launches. Written line by line rather than
# through sed, whose replacement would read `&` and `|` in the path.
exec_path=$(printf '%s\n' "$bin/zit" | sed -e 's/\\/\\\\\\\\/g' -e 's/["`$]/\\\\&/g' -e 's/%/%%/g')
while IFS= read -r line; do
    case $line in
        Exec=zit*) printf 'Exec="%s"%s\n' "$exec_path" "${line#Exec=zit}" ;;
        *) printf '%s\n' "$line" ;;
    esac
done < "$here/zit.desktop" > "$prefix/applications/zit.desktop"

refresh

echo "Zit installed: $bin/zit"
echo "It is in your application menu; run it from there or with: zit /path/to/repo"
