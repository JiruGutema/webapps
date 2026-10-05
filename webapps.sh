#!/usr/bin/env bash
# Install websites as Firefox web apps ("Taskbar Tabs"). Apps open in their own
# window with their own icon, but run inside your normal Firefox profile, so
# logins are shared and no extra Firefox is started.
#
#   ./webapps.sh https://youtube.com [-n "YouTube"]   install
#   ./webapps.sh -r <url|name>                       remove
#   ./webapps.sh list                                list installed apps
#   ./webapps.sh check                               check profiles, enable the feature
#   ./webapps.sh frameless on|off                    app windows without toolbar (default: on)
#
# Options: -p <profile>  use a specific Firefox profile (name or path)
#          -y            answer yes to every prompt
#
# Installing an app that already exists refreshes its icon. Requires a Firefox
# with Taskbar Tabs on Linux (157+). Problems are logged to
# ~/.local/state/webapps/install.log.

set -euo pipefail

PREF="browser.taskbarTabs.enabled"
STYLE_PREF="toolkit.legacyUserProfileCustomizations.stylesheets"
APPS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
LEGACY_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/webapps"
LOG_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/webapps/install.log"
CSS_BEGIN="/* >>> webapps frameless >>> */"
CSS_END="/* <<< webapps frameless <<< */"

ASSUME_YES=0
PROFILE_ARG=""
NAME_ARG=""

# ---------------------------------------------------------------- output ----

log() {
    local level="$1"; shift
    mkdir -p "$(dirname "$LOG_FILE")"
    printf '%s [%s] %s\n' "$(date '+%F %T')" "$level" "$*" >>"$LOG_FILE"
}
info() { echo "$*"; log INFO "$*"; }
warn() { echo "warning: $*" >&2; log WARN "$*"; }
die()  { echo "error: $*" >&2; log ERROR "$*"; exit 1; }

ask() {
    (( ASSUME_YES )) && return 0
    if [[ ! -t 0 ]]; then
        warn "not asking in non-interactive mode (use -y): $1"
        return 1
    fi
    local answer
    read -r -p "$1 [Y/n] " answer
    [[ -z "$answer" || "$answer" =~ ^[Yy] ]]
}

usage() {
    sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

# --------------------------------------------------------------- helpers ----

normalize_url() {
    local url="$1"
    [[ "$url" =~ ^https?:// ]] || url="https://$url"
    echo "$url"
}

# https://www.youtube.com/feed -> youtube.com
host_of() {
    local host="${1#*://}"
    host="${host%%/*}"
    host="${host%%:*}"
    host="${host#www.}"
    echo "${host,,}"
}

ini_get() { grep -m1 "^$2=" "$1" 2>/dev/null | cut -d= -f2- || true; }

desktop_name() { ini_get "$1" Name; }

refresh_menu() {
    command -v update-desktop-database >/dev/null && update-desktop-database "$APPS_DIR" 2>/dev/null || true
}

firefox_bin() { command -v firefox || die "firefox is not installed"; }

# -------------------------------------------------------------- profiles ----

firefox_roots() {
    local r
    for r in "${XDG_CONFIG_HOME:-$HOME/.config}/mozilla/firefox" "$HOME/.mozilla/firefox"; do
        [[ -d "$r" ]] && echo "$r"
    done
    return 0
}

# Every profile folder, including ones made by Firefox's newer profile
# manager that are not listed in profiles.ini.
all_profiles() {
    local root dir
    while read -r root; do
        for dir in "$root"/*/; do
            dir="${dir%/}"
            [[ -f "$dir/prefs.js" || -f "$dir/compatibility.ini" ]] && echo "$dir"
        done
    done < <(firefox_roots)
    return 0
}

profile_name() {
    local dir="$1" base name
    base="$(basename "$dir")"
    name="$(awk -F= -v p="$base" '
        /^\[/ { n = ""; path = "" }
        /^Name=/ { n = $2 }
        /^Path=/ { path = $2 }
        n != "" && path == p { print n; exit }' "$(dirname "$dir")/profiles.ini" 2>/dev/null || true)"
    echo "${name:-${base#*.}}"
}

# Firefox install folder that last used this profile
profile_platform() { ini_get "$1/compatibility.ini" LastPlatformDir; }

is_running() {
    local pid
    pid="$(readlink "$1/lock" 2>/dev/null || true)"
    pid="${pid##*+}"
    [[ "$pid" =~ ^[0-9]+$ && -r "/proc/$pid/cmdline" ]] && tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | grep -q firefox
}

declare -A SUPPORT_CACHE=()
supports_taskbar_tabs() {
    local platform="$1" src
    if [[ -z "${SUPPORT_CACHE[$platform]+x}" ]]; then
        src="$(unzip -p "$platform/browser/omni.ja" modules/taskbartabs/TaskbarTabsPin.sys.mjs 2>/dev/null || true)"
        if grep -q 'platform === "linux"' <<<"$src"; then
            SUPPORT_CACHE[$platform]=1
        else
            SUPPORT_CACHE[$platform]=0
        fi
    fi
    [[ "${SUPPORT_CACHE[$platform]}" == 1 ]]
}

pref_set() { grep -qF "user_pref(\"$2\", true)" "$1" 2>/dev/null; }

# Enabled if Firefox will have it on at its next start
pref_enabled() { pref_set "$1/user.js" "$2" || pref_set "$1/prefs.js" "$2"; }

# Enabled in user.js, but the running Firefox has not picked it up yet
pref_needs_restart() { is_running "$1" && ! pref_set "$1/prefs.js" "$2"; }

enable_pref() {
    local file="$1/user.js"
    [[ -f "$file" ]] && sed -i "/\"${2//./\\.}\"/d" "$file"
    echo "user_pref(\"$2\", true); // added by webapps.sh" >>"$file"
    log INFO "enabled $2 in $file"
}

# Prints why a profile can't use web apps, or nothing if it can
incompatible_reason() {
    local platform
    platform="$(profile_platform "$1")"
    if [[ -z "$platform" ]]; then
        echo "never opened in Firefox"
    elif [[ ! -d "$platform" ]]; then
        echo "its Firefox install ($platform) no longer exists"
    elif ! supports_taskbar_tabs "$platform"; then
        echo "Firefox $(ini_get "$platform/application.ini" Version) ($platform) has no web app support on Linux; update to Firefox 157+"
    fi
    return 0
}

usable_profiles() {
    local p
    while read -r p; do
        [[ -z "$(incompatible_reason "$p")" ]] && echo "$p"
    done < <(all_profiles)
    return 0
}

# The profile apps are installed into: -p, or the default profile of the
# `firefox` command's install.
target_profile() {
    local p
    if [[ -n "$PROFILE_ARG" ]]; then
        while read -r p; do
            if [[ "$p" == "$PROFILE_ARG" || "$(basename "$p")" == "$PROFILE_ARG" \
                || "$(profile_name "$p")" == "$PROFILE_ARG" ]]; then
                echo "$p"
                return
            fi
        done < <(all_profiles)
        die "no Firefox profile named '$PROFILE_ARG' (see: $0 check)"
    fi

    local platform root def best="" best_time=0 t
    platform="$(dirname "$(readlink -f "$(firefox_bin)")")"

    while read -r root; do
        while read -r def; do
            p="$root/$def"
            [[ "$(profile_platform "$p")" == "$platform" ]] && { echo "$p"; return; }
        done < <(grep -h '^Default=' "$root/installs.ini" "$root/profiles.ini" 2>/dev/null \
                 | cut -d= -f2- | grep -v '^1$' || true)
    done < <(firefox_roots)

    # No install default: use the most recently used profile of this install
    while read -r p; do
        [[ "$(profile_platform "$p")" == "$platform" ]] || continue
        t="$(stat -c %Y "$p/prefs.js" 2>/dev/null || echo 0)"
        (( t > best_time )) && { best="$p"; best_time="$t"; }
    done < <(all_profiles)
    [[ -n "$best" ]] || die "no Firefox profile found for $platform; open Firefox once first"
    echo "$best"
}

# ----------------------------------------------------------------- check ----

# Reports every profile, logs incompatible ones and offers to enable the pref
check_profiles() {
    command -v unzip >/dev/null || die "unzip is required (sudo apt install unzip)"
    command -v jq >/dev/null || die "jq is required (sudo apt install jq)"

    local p name reason disabled=() restart=()
    echo "Firefox profiles:"
    while read -r p; do
        name="$(profile_name "$p")"
        reason="$(incompatible_reason "$p")"
        if [[ -n "$reason" ]]; then
            printf '  %-20s incompatible: %s\n' "$name" "$reason"
            log WARN "incompatible profile '$name' ($p): $reason"
        elif ! pref_enabled "$p" "$PREF"; then
            printf '  %-20s disabled\n' "$name"
            disabled+=("$p")
        elif pref_needs_restart "$p" "$PREF"; then
            printf '  %-20s enabled (restart Firefox to apply)\n' "$name"
            restart+=("$p")
        else
            printf '  %-20s enabled\n' "$name"
        fi
    done < <(all_profiles)

    if (( ${#disabled[@]} )); then
        echo
        if ask "Web apps (Taskbar Tabs) are disabled in ${#disabled[@]} profile(s). Enable them?"; then
            for p in "${disabled[@]}"; do
                enable_pref "$p" "$PREF"
                info "Enabled in '$(profile_name "$p")'"
                if pref_needs_restart "$p" "$PREF"; then restart+=("$p"); fi
            done
        else
            log INFO "left $PREF disabled"
        fi
    fi

    for p in "${restart[@]}"; do
        warn "Firefox is running with profile '$(profile_name "$p")': restart Firefox to apply the change"
    done
    return 0
}

# Prints why apps can't be installed into $1 right now, or nothing if they can
ready_problem() {
    local p="$1" name reason
    name="$(profile_name "$p")"
    reason="$(incompatible_reason "$p")"
    if [[ -n "$reason" ]]; then
        echo "profile '$name' can't use web apps: $reason"
    elif ! pref_enabled "$p" "$PREF"; then
        echo "web apps are disabled in profile '$name' (run: $0 check)"
    elif pref_needs_restart "$p" "$PREF"; then
        echo "restart Firefox (profile '$name') to finish enabling web apps, then run this again"
    fi
    return 0
}

require_ready() {
    local problem
    problem="$(ready_problem "$1")"
    [[ -z "$problem" ]] || die "$problem"
}

is_ready() { [[ -z "$(ready_problem "$1")" ]]; }

# -------------------------------------------------------------- registry ----

registry_file() { echo "$1/taskbartabs/taskbartabs.json"; }

# Prints id<TAB>name<TAB>startUrl<TAB>host for every app in a profile
registry_entries() {
    local reg
    reg="$(registry_file "$1")"
    [[ -f "$reg" ]] || return 0
    jq -r '.taskbarTabs[] | select(.userContextId == 0)
        | [.id, (.name // ""), .startUrl, (.scopes[0].hostname | sub("^www\\."; ""))] | @tsv' "$reg"
}

registry_find() {
    local id name url host
    while IFS=$'\t' read -r id name url host; do
        [[ "$host" == "$2" ]] && { echo "$id"; return; }
    done < <(registry_entries "$1")
    return 0
}

registry_name() {
    jq -r --arg id "$2" '.taskbarTabs[] | select(.id == $id) | .name // empty' "$(registry_file "$1")"
}

registry_remove() {
    local reg tmp
    reg="$(registry_file "$1")"
    [[ -f "$reg" ]] || return 0
    tmp="$(mktemp)"
    jq --arg id "$2" '.taskbarTabs |= map(select(.id != $id))' "$reg" >"$tmp" && mv "$tmp" "$reg"
}

desktop_for() {
    local f
    for f in "$APPS_DIR"/*.webapp-"$1".desktop; do
        [[ -e "$f" ]] && { echo "$f"; return; }
    done
    return 0
}

# Recreates a launcher Firefox made earlier, in the same format it uses
write_desktop() {
    local profile="$1" id="$2" name="$3" url="$4" icon file
    icon="$(ls "$profile/taskbartabs/icons/$id".* 2>/dev/null | head -1 || true)"
    file="$APPS_DIR/firefox.webapp-$id.desktop"
    mkdir -p "$APPS_DIR"
    cat >"$file" <<EOF
[Desktop Entry]
Type=Application
Version=1.5
Name=$name
Icon=${icon:-firefox}
Exec="$(firefox_bin)" "-taskbar-tab" "$id" "-new-window" "$url" "-profile" "$profile" "-container" "0"
EOF
    echo "$file"
}

# Downloads the sharpest icon a site offers (web app manifest, apple-touch-icon,
# favicons, then Google's favicon service) as a PNG. Firefox only uses
# favicons it already has cached, which are often missing or tiny.
fetch_icon_full() {
    python3 - "$1" "$2" <<'PY'
import html.parser, json, os, re, shutil, struct, subprocess, sys, tempfile, urllib.parse, urllib.request

url, out = sys.argv[1:3]
UA = "Mozilla/5.0 (X11; Linux x86_64; rv:157.0) Gecko/20100101 Firefox/157.0"
WANT = 192


def get(u, limit=5_000_000):
    req = urllib.request.Request(u, headers={"User-Agent": UA, "Accept-Language": "en"})
    with urllib.request.urlopen(req, timeout=15) as r:
        return r.geturl(), r.read(limit)


class Links(html.parser.HTMLParser):
    def __init__(self):
        super().__init__()
        self.links = []

    def handle_starttag(self, tag, attrs):
        if tag == "link":
            a = dict(attrs)
            if a.get("href"):
                self.links.append(a)


def size_of(s):
    m = re.findall(r"(\d+)x\d+", s or "")
    return max(map(int, m), default=0)


def candidates():
    found = []
    try:
        base, page = get(url)
        p = Links()
        p.feed(page.decode("utf-8", "replace"))
        rels = lambda a: (a.get("rel") or "").lower().split()

        for a in p.links:
            if "manifest" in rels(a):
                try:
                    murl, data = get(urllib.parse.urljoin(base, a["href"]))
                    icons = json.loads(data).get("icons", [])
                    icons = [i for i in icons if "any" in (i.get("purpose") or "any").split()] or icons
                    icons.sort(key=lambda i: size_of(i.get("sizes")), reverse=True)
                    found += [urllib.parse.urljoin(murl, i["src"]) for i in icons if i.get("src")]
                except Exception:
                    pass

        touch = [a for a in p.links if "apple-touch-icon" in rels(a) or "apple-touch-icon-precomposed" in rels(a)]
        found += [urllib.parse.urljoin(base, a["href"]) for a in sorted(touch, key=lambda a: size_of(a.get("sizes")), reverse=True)]
        found.append(urllib.parse.urljoin(base, "/apple-touch-icon.png"))

        icons = [a for a in p.links if "icon" in rels(a)]
        found += [urllib.parse.urljoin(base, a["href"]) for a in sorted(icons, key=lambda a: size_of(a.get("sizes")), reverse=True)]
    except Exception:
        pass
    host = urllib.parse.urlsplit(url).hostname
    found.append(f"https://www.google.com/s2/favicons?domain={host}&sz=256")
    return list(dict.fromkeys(found))


def png_width(data):
    if data[:8] == b"\x89PNG\r\n\x1a\n" and data[12:16] == b"IHDR":
        return struct.unpack(">I", data[16:20])[0]
    return 0


def as_png(data):
    """Returns (png bytes, width); converts other formats with gdk-pixbuf."""
    w = png_width(data)
    if w or not shutil.which("gdk-pixbuf-thumbnailer"):
        return data, w
    with tempfile.TemporaryDirectory() as tmp:
        src, dst = os.path.join(tmp, "in"), os.path.join(tmp, "out.png")
        open(src, "wb").write(data)
        r = subprocess.run(["gdk-pixbuf-thumbnailer", "-s", "256", src, dst], capture_output=True)
        if r.returncode or not os.path.exists(dst):
            return data, 0
        data = open(dst, "rb").read()
        return data, png_width(data)


best, best_w = None, 0
for c in candidates():
    try:
        _, data = get(c)
    except Exception:
        continue
    data, w = as_png(data)
    if w > best_w:
        best, best_w, best_src = data, w, c
    if best_w >= WANT:
        break

if not best:
    sys.exit(1)
open(out, "wb").write(best)
print(f"{best_w}px from {best_src}")
PY
}

# Without python3: just Google's favicon service, via curl
fetch_icon_basic() {
    local host src="" width
    command -v curl >/dev/null || return 1
    host="$(host_of "$1")"
    src="https://www.google.com/s2/favicons?domain=$host&sz=256"
    curl -fsSL --max-time 15 -o "$2" "$src" 2>/dev/null || return 1
    [[ "$(head -c 8 "$2" | od -An -tx1 | tr -d ' \n')" == 89504e470d0a1a0a ]] || return 1
    width="$(od -An -tu1 -j16 -N4 "$2" | awk '{ print $1 * 16777216 + $2 * 65536 + $3 * 256 + $4 }')"
    echo "${width}px from $src"
}

fetch_icon() {
    if command -v python3 >/dev/null; then
        fetch_icon_full "$@" && return
    fi
    fetch_icon_basic "$@"
}

# Replaces the icon Firefox picked with a downloaded one, if that works
update_icon() {
    local profile="$1" id="$2" url="$3" icon tmp result
    icon="$profile/taskbartabs/icons/$id.png"
    tmp="$(mktemp)"
    if result="$(fetch_icon "$url" "$tmp" 2>/dev/null)"; then
        mkdir -p "$(dirname "$icon")"
        mv "$tmp" "$icon"
        info "  icon: $result"
        local desktop
        desktop="$(desktop_for "$id")"
        if [[ -n "$desktop" ]]; then
            sed -i "s|^Icon=.*|Icon=$icon|" "$desktop"
        fi
    else
        rm -f "$tmp"
        warn "couldn't download an icon for $url; keeping the one Firefox picked"
    fi
}

# ------------------------------------------------------------- commands ----

install_app() {
    local url host profile id desktop=""
    url="$(normalize_url "$1")"
    host="$(host_of "$url")"
    [[ -n "$host" ]] || die "invalid URL: $1"

    profile="$(target_profile)"
    require_ready "$profile"

    id="$(registry_find "$profile" "$host")"
    if [[ -n "$id" ]]; then
        desktop="$(desktop_for "$id")"
        if [[ -n "$desktop" && -z "$NAME_ARG" ]]; then
            info "'$(desktop_name "$desktop")' is already installed"
            update_icon "$profile" "$id" "$url"
            refresh_menu
            frameless_default "$profile"
            return
        elif [[ -z "$desktop" ]]; then
            desktop="$(write_desktop "$profile" "$id" "${NAME_ARG:-$(registry_name "$profile" "$id")}" "$url")"
            info "Restored the launcher for $host"
        fi
    else
        info "Asking Firefox to create the app for $url..."
        log INFO "launching taskbar tab for $url in $profile"
        # Firefox registers an unknown id as a new app and writes its launcher
        setsid "$(firefox_bin)" -taskbar-tab "$(cat /proc/sys/kernel/random/uuid)" \
            -new-window "$url" -profile "$profile" -container 0 >/dev/null 2>&1 &

        local i
        for (( i = 0; i < 60; i++ )); do
            id="$(registry_find "$profile" "$host")"
            [[ -n "$id" ]] && desktop="$(desktop_for "$id")"
            [[ -n "$desktop" ]] && break
            sleep 0.5
        done
        if [[ -z "$desktop" && -n "$id" ]]; then
            desktop="$(write_desktop "$profile" "$id" "${NAME_ARG:-$(registry_name "$profile" "$id")}" "$url")"
        fi
        [[ -n "$desktop" ]] || die "Firefox didn't create the app within 30s. Check that web apps are enabled (run: $0 check)"
    fi

    if [[ -n "$NAME_ARG" ]]; then
        sed -i "s/^Name=.*/Name=${NAME_ARG//\//\\/}/" "$desktop"
    fi
    info "Installed '$(desktop_name "$desktop")' ($url) in profile '$(profile_name "$profile")'"
    update_icon "$profile" "$id" "$url"
    refresh_menu
    info "  launcher: $desktop"
    frameless_default "$profile"
}

# Apps made by the earlier version of this script (one Firefox profile per app)
legacy_apps() {
    local f
    for f in "$APPS_DIR"/webapp-*.desktop; do
        [[ -e "$f" ]] && grep -q '^X-WebApp-URL=' "$f" && echo "$f"
    done
    return 0
}

remove_legacy() {
    local f="$1" slug
    slug="$(basename "$f" .desktop)"
    slug="${slug#webapp-}"
    rm -f "$f"
    rm -rf "${LEGACY_DIR:?}/$slug"
    if [[ -z "$(legacy_apps)" ]]; then
        rm -rf "${LEGACY_DIR:?}"
    fi
    log INFO "removed legacy app $slug"
}

remove_app() {
    local target="$1" by_url=0 host="" p id name url h desktop found=0 f
    if [[ "$target" == *.* || "$target" == *://* ]]; then
        by_url=1
        host="$(host_of "$(normalize_url "$target")")"
    fi

    while read -r p; do
        while IFS=$'\t' read -r id name url h; do
            desktop="$(desktop_for "$id")"
            [[ -n "$desktop" ]] && name="$(desktop_name "$desktop")"
            [[ -n "$desktop" ]] || continue
            if (( by_url )); then
                [[ "$h" == "$host" ]] || continue
            else
                [[ "${name,,}" == "${target,,}" ]] || continue
            fi

            [[ -n "$desktop" ]] && rm -f "$desktop"
            # A running Firefox keeps its registry in memory and would write the
            # entry back, so only drop it while Firefox is closed. A leftover
            # entry is harmless: without a launcher the app counts as removed.
            if is_running "$p"; then
                log INFO "Firefox is running for $p; kept registry entry $id"
            else
                rm -f "$p/taskbartabs/icons/$id".*
                registry_remove "$p" "$id"
            fi
            found=1
            info "Removed '$name' from profile '$(profile_name "$p")'"
        done < <(registry_entries "$p")
    done < <(usable_profiles)

    while read -r f; do
        [[ -n "$f" ]] || continue
        if (( by_url )); then
            [[ "$(host_of "$(ini_get "$f" X-WebApp-URL)")" == "$host" ]] || continue
        else
            name="$(desktop_name "$f")"
            [[ "${name,,}" == "${target,,}" ]] || continue
        fi
        name="$(desktop_name "$f")"
        remove_legacy "$f"
        found=1
        info "Removed '$name' (old version)"
    done < <(legacy_apps)

    (( found )) || die "no web app found for '$target' (see: $0 list)"
    refresh_menu
}

list_apps() {
    local p id name url host desktop rows=() f
    while read -r p; do
        while IFS=$'\t' read -r id name url host; do
            desktop="$(desktop_for "$id")"
            [[ -n "$desktop" ]] || continue
            name="$(desktop_name "$desktop")"
            rows+=("$(printf '%-24s %-32s %s' "$name" "$url" "$(profile_name "$p")")")
        done < <(registry_entries "$p")
    done < <(usable_profiles)

    while read -r f; do
        [[ -n "$f" ]] || continue
        rows+=("$(printf '%-24s %-32s %s' "$(desktop_name "$f")" "$(ini_get "$f" X-WebApp-URL)" "(old version)")")
    done < <(legacy_apps)

    if (( ${#rows[@]} )); then
        printf '%-24s %-32s %s\n' NAME URL PROFILE
        printf '%s\n' "${rows[@]}"
    else
        echo "No web apps installed."
    fi
}

# Offers to convert apps made by the earlier version of this script
migrate_legacy() {
    local apps=() f names=""
    while read -r f; do [[ -n "$f" ]] && apps+=("$f"); done < <(legacy_apps)
    (( ${#apps[@]} )) || return 0

    for f in "${apps[@]}"; do names+="${names:+, }$(desktop_name "$f")"; done
    echo
    ask "Found ${#apps[@]} app(s) from the old version of this script ($names). Convert them to Firefox web apps?" || return 0

    local url name
    for f in "${apps[@]}"; do
        url="$(ini_get "$f" X-WebApp-URL)"
        name="$(desktop_name "$f")"
        remove_legacy "$f"
        NAME_ARG="$name" install_app "$url"
    done
}

# Replaces the marked block in userChrome.css. "off" leaves an empty block so
# installs remember the choice and don't turn frameless back on.
write_frameless() {
    local profile="$1" mode="$2" css="$1/chrome/userChrome.css"
    if [[ -f "$css" ]]; then
        sed -i "\|^${CSS_BEGIN//\*/\\*}\$|,\|^${CSS_END//\*/\\*}\$|d" "$css"
    fi
    mkdir -p "$profile/chrome"
    if [[ "$mode" == on ]]; then
        cat >>"$css" <<EOF
$CSS_BEGIN
/* Hide the toolbar in web app windows only; normal windows are unaffected */
:root[taskbartab] #nav-bar,
:root[taskbartab] #TabsToolbar,
:root[taskbartab] #PersonalToolbar { visibility: collapse !important; }
$CSS_END
EOF
        pref_enabled "$profile" "$STYLE_PREF" || enable_pref "$profile" "$STYLE_PREF"
    else
        printf '%s\n/* turned off with: webapps.sh frameless off */\n%s\n' "$CSS_BEGIN" "$CSS_END" >>"$css"
    fi
    log INFO "frameless $mode for $profile"
}

frameless_hint() {
    info "  frameless windows: move with Super+drag, maximize with Super+Up, close with Ctrl+W"
    info "  (turn off with: $0 frameless off)"
}

# Frameless is the default: turn it on unless the user turned it off before
frameless_default() {
    local profile="$1"
    grep -qF "$CSS_BEGIN" "$profile/chrome/userChrome.css" 2>/dev/null && return 0
    write_frameless "$profile" on
    info "Turned on frameless app windows for profile '$(profile_name "$profile")'"
    frameless_hint
    if is_running "$profile"; then warn "restart Firefox to make app windows frameless"; fi
    return 0
}

set_frameless() {
    local mode="$1" profile
    [[ "$mode" == on || "$mode" == off ]] || die "usage: $0 frameless on|off"
    profile="$(target_profile)"
    write_frameless "$profile" "$mode"
    info "Frameless app windows turned $mode for profile '$(profile_name "$profile")'"
    if [[ "$mode" == on ]]; then frameless_hint; fi
    if is_running "$profile"; then warn "restart Firefox to apply"; fi
    return 0
}

# ------------------------------------------------------------------ main ----

main() {
    local mode="" args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage ;;
            -y|--yes) ASSUME_YES=1 ;;
            -p|--profile) [[ $# -ge 2 ]] || die "$1 needs a value"; PROFILE_ARG="$2"; shift ;;
            -n|--name) [[ $# -ge 2 ]] || die "$1 needs a value"; NAME_ARG="$2"; shift ;;
            -r|--remove) mode=remove ;;
            -l|--list) mode=list ;;
            -*) die "unknown option: $1" ;;
            *) args+=("$1") ;;
        esac
        shift
    done

    if [[ -z "$mode" ]]; then
        case "${args[0]:-}" in
            "") usage 1 ;;
            list|check|frameless) mode="${args[0]}"; args=("${args[@]:1}") ;;
            *) mode=install ;;
        esac
    fi

    case "$mode" in
        list) list_apps ;;
        check)
            check_profiles
            if is_ready "$(target_profile)"; then migrate_legacy; fi
            ;;
        frameless) set_frameless "${args[0]:-}" ;;
        remove)
            (( ${#args[@]} )) || die "usage: $0 -r <url|name>"
            local t
            for t in "${args[@]}"; do remove_app "$t"; done
            ;;
        install)
            (( ${#args[@]} == 1 )) || die "install takes one URL (got: ${args[*]})"
            check_profiles
            echo
            install_app "${args[0]}"
            ;;
    esac
}

main "$@"
