#!/usr/bin/env bash
# 
# download-videos.sh
# -----------------------------------------------------------------------------
# Downloads online videos to MP4 using yt-dlp (YouTube, Facebook, Twitter,
# TikTok, and 1000+ sites). Installs yt-dlp / ffmpeg if missing and checks for a
# newer yt-dlp on each run.
#
# CONVERSION MODE  (CONVERT_TO_H264=true)
#     Re-encodes to H.264/AAC if needed, then applies faststart for web
#     streaming. Use for universally compatible, direct-playback files.
#
# DOWNLOAD-ONLY MODE  (CONVERT_TO_H264=false)
#     Keeps original codecs (e.g. AV1/Opus). Best when a media server
#     (Plex, Jellyfin, etc.) handles transcoding. Faststart is still applied
#     via a fast stream copy during the merge.
#
# COOKIE HANDLING (3-tier automatic fallback):
#     Tier 1 — cookies.txt auto-exported from Firefox's SQLite database using
#              the native `sqlite3` CLI (bypasses API endpoints returning 410).
#     Tier 2 — Live browser extraction via --cookies-from-browser.
#     Tier 3 — No cookies (public/unauthenticated content only).
#
# Bash conversion of the original PowerShell script (v5.2) by
# Michael DALLA RIVA. Native Linux tooling — no PowerShell shim.
# -----------------------------------------------------------------------------

# ============================================
# CONFIGURATION
# ============================================
VIDEO_QUALITY="1440"      # 360 | 480 | 720 | 1080 | 1440 | 2160 | best
COOKIE_BROWSER="firefox"  # firefox | chrome | chromium | brave | opera | vivaldi | edge | "" to disable
CONVERT_TO_H264=false     # true = re-encode to H.264/AAC after download; false = keep original codecs
USE_NIGHTLY_BUILD=false   # true = track yt-dlp nightly; false = stable only

# ============================================
# Paths & colors
# ============================================
set -o pipefail

if command -v xdg-user-dir >/dev/null 2>&1; then
    DOWNLOAD_FOLDER="$(xdg-user-dir DOWNLOAD 2>/dev/null)"
fi
DOWNLOAD_FOLDER="${DOWNLOAD_FOLDER:-$HOME/Downloads}"
mkdir -p "$DOWNLOAD_FOLDER"

TMPDIR_BASE="${TMPDIR:-/tmp}"
COOKIES_FILE="$TMPDIR_BASE/yt-dlp-cookies.txt"

LOCAL_BIN="$HOME/.local/bin"
export PATH="$LOCAL_BIN:$PATH"

if [[ -t 1 ]]; then
    C_RESET=$'\e[0m'; C_RED=$'\e[31m'; C_GREEN=$'\e[32m'
    C_YELLOW=$'\e[33m'; C_CYAN=$'\e[36m'; C_GRAY=$'\e[90m'
else
    C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""; C_GRAY=""
fi
info()  { printf '%s%s%s\n' "$C_CYAN"   "$1" "$C_RESET"; }
ok()    { printf '%s%s%s\n' "$C_GREEN"  "$1" "$C_RESET"; }
warn()  { printf '%s%s%s\n' "$C_YELLOW" "$1" "$C_RESET"; }
err()   { printf '%s%s%s\n' "$C_RED"    "$1" "$C_RESET"; }
gray()  { printf '%s%s%s\n' "$C_GRAY"   "$1" "$C_RESET"; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

# ============================================
# Package-manager helpers (for ffmpeg / sqlite3)
# ============================================
detect_pm() {
    for pm in apt-get dnf pacman zypper apk; do
        command_exists "$pm" && { echo "$pm"; return 0; }
    done
    return 1
}
PM="$(detect_pm || true)"

install_pkg() {
    # $1 = package name (same across ffmpeg / sqlite3 on all these distros)
    local pkg="$1" sudo=""
    [[ $EUID -ne 0 ]] && command_exists sudo && sudo="sudo"
    case "$PM" in
        apt-get) $sudo apt-get update -qq && $sudo apt-get install -y "$pkg" ;;
        dnf)     $sudo dnf install -y "$pkg" ;;
        pacman)  $sudo pacman -S --needed --noconfirm "$pkg" ;;
        zypper)  $sudo zypper --non-interactive install "$pkg" ;;
        apk)     $sudo apk add "$pkg" ;;
        *)       return 1 ;;
    esac
}

# ============================================
# Ensure yt-dlp (installed as self-updating binary in ~/.local/bin)
# ============================================
install_ytdlp_binary() {
    info "Installing yt-dlp binary to $LOCAL_BIN ..."
    mkdir -p "$LOCAL_BIN"
    local url="https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp"
    if command_exists curl; then
        curl -fL "$url" -o "$LOCAL_BIN/yt-dlp" || return 1
    elif command_exists wget; then
        wget -q "$url" -O "$LOCAL_BIN/yt-dlp" || return 1
    else
        err "Neither curl nor wget is available to download yt-dlp."
        return 1
    fi
    chmod +x "$LOCAL_BIN/yt-dlp"
    ok "yt-dlp installed."
}

update_ytdlp() {
    info "Checking yt-dlp version..."
    local current latest
    current="$(yt-dlp --version 2>/dev/null | tr -d '[:space:]')"

    # --- Nightly path ---
    if [[ "$USE_NIGHTLY_BUILD" == "true" ]]; then
        info "Nightly build mode enabled - updating to latest nightly..."
        if yt-dlp --update-to nightly 2>&1 | sed "s/^/  /"; then
            ok "yt-dlp nightly updated successfully!"
            return
        fi
        warn "Nightly update failed. Falling back to stable update check..."
    fi

    # --- Stable path: compare against GitHub latest tag ---
    if command_exists curl; then
        latest="$(curl -fsSL -H 'User-Agent: bash' \
            https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest 2>/dev/null \
            | grep -m1 '"tag_name"' | sed -E 's/.*"v?([^"]+)".*/\1/')"
    fi

    if [[ -z "$latest" ]]; then
        warn "Could not reach GitHub to check for yt-dlp updates. Skipping."
        gray "  (Current version: ${current:-unknown})"
        return
    fi

    if [[ "$current" == "$latest" ]]; then
        ok "yt-dlp is up to date ($current)"
        return
    fi

    warn "Update available: ${current:-unknown} -> $latest"
    warn "Updating yt-dlp now..."

    if yt-dlp -U >/dev/null 2>&1 && [[ "$(yt-dlp --version 2>/dev/null | tr -d '[:space:]')" == "$latest" ]]; then
        ok "yt-dlp updated successfully via built-in updater!"
    else
        warn "Built-in updater unavailable (distro/pip install?) - re-downloading binary..."
        if install_ytdlp_binary; then
            ok "yt-dlp updated via direct download!"
        else
            warn "WARNING: Could not update yt-dlp automatically. Downloads may still work."
            warn "  Manual update:  yt-dlp -U   or   https://github.com/yt-dlp/yt-dlp/releases/latest"
        fi
    fi
}

# ============================================
# Export Firefox cookies.sqlite -> Netscape cookies.txt (native sqlite3 + awk)
# echoes nothing; returns 0 on success
# ============================================
export_firefox_cookies() {
    local output="$1"

    [[ "$COOKIE_BROWSER" != "firefox" ]] && return 1

    info "Exporting Firefox cookies automatically..."

    local ff_root="$HOME/.mozilla/firefox"
    if [[ ! -d "$ff_root" ]]; then
        warn "  Firefox profile folder not found. Skipping cookie export."
        return 1
    fi

    if ! command_exists sqlite3; then
        warn "  sqlite3 not found — installing via package manager..."
        install_pkg sqlite3 || install_pkg sqlite || true
    fi
    if ! command_exists sqlite3; then
        warn "  sqlite3 unavailable — cannot auto-export cookies (Tier 2 will still try)."
        return 1
    fi

    # Resolve the default profile.
    local profiles_ini="$ff_root/profiles.ini" sqlite_path="" rel=""
    if [[ -f "$profiles_ini" ]]; then
        # Modern Firefox: [Install*] Default=<relative path to default-release>
        rel="$(awk -F= '
            /^\[Install/ {ins=1; next}
            /^\[/        {ins=0}
            ins && $1=="Default" {print $2; exit}
        ' "$profiles_ini")"
        [[ -n "$rel" && -f "$ff_root/$rel/cookies.sqlite" ]] && sqlite_path="$ff_root/$rel/cookies.sqlite"
    fi
    # Fallback: newest cookies.sqlite anywhere under the profiles root.
    if [[ -z "$sqlite_path" ]]; then
        sqlite_path="$(find "$ff_root" -name cookies.sqlite -printf '%T@ %p\n' 2>/dev/null \
                       | sort -rn | head -1 | cut -d' ' -f2-)"
    fi
    if [[ -z "$sqlite_path" || ! -f "$sqlite_path" ]]; then
        warn "  cookies.sqlite not found in any Firefox profile. Skipping cookie export."
        return 1
    fi
    gray "  Found: $sqlite_path"

    # Work on a copy (Firefox may hold a WAL lock).
    local copy="$TMPDIR_BASE/yt-dlp-cookies-src.sqlite"
    cp -f "$sqlite_path" "$copy" 2>/dev/null || { warn "  Could not copy cookies.sqlite."; return 1; }
    for ext in -wal -shm; do
        [[ -f "$sqlite_path$ext" ]] && cp -f "$sqlite_path$ext" "$copy$ext" 2>/dev/null
    done

    local count status=0
    {
        printf '# Netscape HTTP Cookie File\n'
        printf '# Auto-exported by download-videos.sh\n\n'
        sqlite3 -readonly -separator $'\t' "$copy" \
            "SELECT host, path, isSecure, expiry, name, value FROM moz_cookies;" \
            2>/dev/null \
        | awk -F'\t' -v now="$(date +%s)" '
            {
                if ($4+0 > 0 && $4+0 < now) next            # skip expired
                df = (substr($1,1,1)=="." ? "TRUE" : "FALSE")
                sf = ($3==1 ? "TRUE" : "FALSE")
                ex = ($4=="" ? "0" : $4)
                print $1"\t"df"\t"$2"\t"sf"\t"ex"\t"$5"\t"$6
            }'
    } > "$output" || status=1

    rm -f "$copy" "$copy-wal" "$copy-shm"

    if [[ $status -eq 0 && -s "$output" ]]; then
        count="$(grep -vc '^#' "$output" 2>/dev/null)"
        ok "  Exported ${count:-0} cookies."
        return 0
    fi
    warn "  Cookie export produced no data."
    return 1
}

# ============================================
# Run yt-dlp; return its exit code
# ============================================
run_ytdlp() {
    yt-dlp "$@"
}

# ============================================
# Run yt-dlp capturing stderr to detect cookie-specific failures.
# Sets globals: DL_EXIT and COOKIE_FAILED
# ============================================
run_ytdlp_captured() {
    local errlog="$TMPDIR_BASE/yt-dlp-stderr.$$"
    yt-dlp "$@" 2> >(tee "$errlog" >&2)
    DL_EXIT=$?
    COOKIE_FAILED=0
    if grep -Eiq 'Could not copy .+ cookie database|cookies-from-browser|Failed to extract cookies|no such file or directory|unable to load cookies' "$errlog"; then
        COOKIE_FAILED=1
    fi
    rm -f "$errlog"
}

# ============================================
# Install / update tools
# ============================================
if ! command_exists yt-dlp; then
    warn ""
    warn "yt-dlp is not installed. Installing..."
    install_ytdlp_binary || { err "yt-dlp installation failed."; exit 1; }
    command_exists yt-dlp || { err "yt-dlp still not on PATH. Add $LOCAL_BIN to your PATH."; exit 1; }
else
    update_ytdlp
fi

if ! command_exists ffmpeg; then
    warn ""
    warn "ffmpeg is required for video processing. Installing..."
    install_pkg ffmpeg || true
    if ! command_exists ffmpeg; then
        err "Could not install ffmpeg automatically. Please install it with your package manager and re-run."
        exit 1
    fi
fi

# ============================================
# Banner
# ============================================
echo ""
info "========================================"
info "     Online Video Downloader"
info "     MP4 Format"
info "========================================"
echo ""
gray "Supports: YouTube, Facebook, Twitter, TikTok, and 1000+ sites"
echo ""
ok  "Quality setting: ${VIDEO_QUALITY}p"
ok  "Download folder: $DOWNLOAD_FOLDER"
echo ""

read -r -p "Enter the video URL: " VIDEO_URL
if [[ -z "${VIDEO_URL// }" ]]; then
    echo ""
    err "ERROR: No URL provided. Exiting."
    exit 1
fi

# ============================================
# Build shared format / output args
# ============================================
if [[ "$VIDEO_QUALITY" == "best" ]]; then
    FORMAT_STRING="bestvideo+bestaudio/best"
else
    FORMAT_STRING="bestvideo[height<=${VIDEO_QUALITY}]+bestaudio/best[height<=${VIDEO_QUALITY}]"
fi

OUTPUT_TEMPLATE="$DOWNLOAD_FOLDER/%(title)s.%(ext)s"

COMMON_ARGS=(
    --format               "$FORMAT_STRING"
    --merge-output-format  mp4
    --postprocessor-args   "ffmpeg:-movflags +faststart"
    --output               "$OUTPUT_TEMPLATE"
    --no-playlist
    --progress
    "$VIDEO_URL"
)

echo ""
warn "Starting download..."
echo ""

DOWNLOAD_EXIT=-1

# ============================================
# TIER 1 — auto-exported cookies.txt
# ============================================
if export_firefox_cookies "$COOKIES_FILE" && [[ -s "$COOKIES_FILE" ]]; then
    info "Trying with auto-exported cookies file (Tier 1)..."
    run_ytdlp --cookies "$COOKIES_FILE" "${COMMON_ARGS[@]}"
    DOWNLOAD_EXIT=$?
    if [[ $DOWNLOAD_EXIT -ne 0 ]]; then
        echo ""; warn "Tier 1 (cookies file) failed — falling back to Tier 2..."
        DOWNLOAD_EXIT=-1
    fi
fi

# ============================================
# TIER 2 — live --cookies-from-browser
# ============================================
if [[ $DOWNLOAD_EXIT -ne 0 && -n "${COOKIE_BROWSER// }" ]]; then
    info "Trying with live $COOKIE_BROWSER cookies (Tier 2)..."
    run_ytdlp_captured --cookies-from-browser "$COOKIE_BROWSER" "${COMMON_ARGS[@]}"
    DOWNLOAD_EXIT=$DL_EXIT
    if [[ $DOWNLOAD_EXIT -ne 0 && $COOKIE_FAILED -eq 1 ]]; then
        echo ""; warn "Cookie extraction failed — falling back to Tier 3 (no cookies)..."
        gray "(Tip: open Firefox at least once so its profile exists)"
        DOWNLOAD_EXIT=-1
    elif [[ $DOWNLOAD_EXIT -ne 0 ]]; then
        echo ""; warn "Tier 2 failed — falling back to Tier 3 (no cookies)..."
        DOWNLOAD_EXIT=-1
    fi
fi

# ============================================
# TIER 3 — no cookies
# ============================================
if [[ $DOWNLOAD_EXIT -ne 0 ]]; then
    info "Trying without cookies (Tier 3)..."
    run_ytdlp "${COMMON_ARGS[@]}"
    DOWNLOAD_EXIT=$?
fi

# ============================================
# Post-download: codec check / optional H.264 conversion
# ============================================
if [[ $DOWNLOAD_EXIT -eq 0 ]]; then
    LATEST_FILE="$(find "$DOWNLOAD_FOLDER" -maxdepth 1 -name '*.mp4' -printf '%T@ %p\n' 2>/dev/null \
                   | sort -rn | head -1 | cut -d' ' -f2-)"

    if [[ -n "$LATEST_FILE" && -f "$LATEST_FILE" ]]; then
        echo ""
        warn "Verifying codec compatibility..."

        VIDEO_CODEC="$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$LATEST_FILE" 2>/dev/null | tr -d '[:space:]')"
        AUDIO_CODEC="$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 "$LATEST_FILE" 2>/dev/null | tr -d '[:space:]')"
        gray "Current codecs: Video=$VIDEO_CODEC, Audio=$AUDIO_CODEC"

        VIDEO_REENCODE=false; AUDIO_REENCODE=false
        [[ "$VIDEO_CODEC" =~ ^(h264|avc) ]] || VIDEO_REENCODE=true
        [[ "$AUDIO_CODEC" =~ ^aac        ]] || AUDIO_REENCODE=true

        if [[ "$CONVERT_TO_H264" == "true" && ( "$VIDEO_REENCODE" == "true" || "$AUDIO_REENCODE" == "true" ) ]]; then
            echo ""
            warn "Converting to H.264/AAC for streaming compatibility..."

            TEMP_FILE="$(dirname "$LATEST_FILE")/temp_$(basename "$LATEST_FILE")"
            FFMPEG_ARGS=(-i "$LATEST_FILE" -y)

            if [[ "$VIDEO_REENCODE" == "true" ]]; then
                FFMPEG_ARGS+=(-c:v libx264 -preset fast -crf 23)
            else
                FFMPEG_ARGS+=(-c:v copy)
            fi
            if [[ "$AUDIO_REENCODE" == "true" ]]; then
                FFMPEG_ARGS+=(-c:a aac -b:a 192k)
            else
                FFMPEG_ARGS+=(-c:a copy)
            fi
            FFMPEG_ARGS+=(-movflags +faststart "$TEMP_FILE")

            if ffmpeg "${FFMPEG_ARGS[@]}"; then
                rm -f "$LATEST_FILE"
                mv -f "$TEMP_FILE" "$LATEST_FILE"
                ok "Conversion complete!"
            else
                warn "Conversion failed, keeping original file."
                [[ -f "$TEMP_FILE" ]] && rm -f "$TEMP_FILE"
            fi
        else
            if [[ "$CONVERT_TO_H264" != "true" && ( "$VIDEO_REENCODE" == "true" || "$AUDIO_REENCODE" == "true" ) ]]; then
                info "Conversion skipped (CONVERT_TO_H264=false) - your media server will transcode."
            fi
            ok "Faststart already applied during download merge - file ready!"
        fi
    fi

    echo ""
    ok "========================================"
    ok "   Download completed successfully!"
    ok "========================================"
    echo ""
    info "File saved to: $DOWNLOAD_FOLDER"
    if [[ "$CONVERT_TO_H264" == "true" ]]; then
        info "Format: MP4 (H.264/AAC) - Ready for direct playback!"
    else
        info "Format: MP4 (original codecs) - Ready for media server transcoding!"
    fi
else
    echo ""
    err "Download failed. Check the output above for details."
    echo ""
    warn "If the issue persists, the site extractor may not be fixed in yt-dlp yet."
    warn "Monitor: https://github.com/yt-dlp/yt-dlp/issues"
fi

# Clean up temp cookies file
rm -f "$COOKIES_FILE"

echo ""
read -r -p "Press Enter to exit "
