# PSDownloadVideos

A PowerShell script that downloads videos from YouTube and hundreds of other sites as MP4 files. It handles tool installation, automatic updates, browser cookie authentication, codec verification, and optional re-encoding - all from a single script with no manual setup required.

---

## Requirements

- Windows 10 or Windows 11
- PowerShell 5.1 or later
- winget (App Installer) - available by default on Windows 11, and from the Microsoft Store on Windows 10

yt-dlp and ffmpeg are installed automatically via winget if not already present.

---

## Usage

1. Download `PSDownloadVideos.ps1`
2. Open it in a text editor and set your preferred configuration values (see [Configuration](#configuration))
3. Right-click the file and choose **Run with PowerShell**, or run it from a terminal:

```powershell
.\PSDownloadVideos.ps1
```

4. Paste a video URL when prompted
5. The file is saved to your `Downloads` folder, named after the video title

---

## Configuration

Three variables at the top of the script control its behaviour:

```powershell
$VideoQuality  = "1440"    # "360", "480", "720", "1080", "1440", "2160", or "best"
$CookieBrowser = "firefox" # "firefox", "edge", "brave", "opera", "vivaldi", or "" to disable
$ConvertToH264 = $false    # $true = re-encode to H.264/AAC;  $false = keep original codecs
```

---

## How It Works

### Startup sequence

Each time the script runs it checks for yt-dlp and ffmpeg before doing anything else.

If either tool is missing, winget installs it automatically. If yt-dlp is already installed, the script queries the GitHub API and updates it before proceeding, trying three strategies in order: the built-in `yt-dlp -U` self-updater, `winget upgrade`, and finally a direct binary download from the GitHub releases page.

---

### Download sequence

After the URL is entered, the script attempts the download in up to two passes.

**Attempt 1** runs yt-dlp with cookies from the configured browser. stderr is captured separately while stdout (the progress bar) streams directly to the console. If the exit code is non-zero and stderr contains cookie-related error patterns, the failure is treated as a cookie problem and Attempt 2 runs automatically.

**Attempt 2** runs yt-dlp without any cookies. This is also the only attempt made when `$CookieBrowser` is set to an empty string.

---

### Post-download processing

After a successful download, ffprobe inspects the video and audio codec of the output file.


What happens next depends on the `$ConvertToH264` setting and what codecs were found:

| Condition | Result |
|---|---|
| `ConvertToH264 = $true` and video/audio needs re-encoding | ffmpeg re-encodes to H.264/AAC with faststart applied |
| `ConvertToH264 = $true` and codecs are already H.264/AAC | Streams are copied as-is, faststart applied |
| `ConvertToH264 = $false` | No ffmpeg pass; faststart was already applied by yt-dlp at merge time |

Faststart moves the MP4 metadata (moov atom) to the front of the file, which is required for proper HTTP streaming and browser playback without needing to download the entire file first.

---

## Download Modes

### Conversion mode (`ConvertToH264 = $true`)

Use this when the file will be played directly on a device or browser without a media server in the middle. The script re-encodes any non-H.264 video stream using `libx264` at CRF 23 (good quality, reasonable size) and any non-AAC audio stream at 192k. Streams that are already the correct codec are copied without re-encoding.

This is slower on long videos because re-encoding is CPU-bound.

### Download-only mode (`ConvertToH264 = $false`)

Use this when a media server such as Plex, NexusM, Jellyfin, or Emby will handle the file. The original codecs (commonly AV1 video and Opus audio from YouTube) are kept exactly as downloaded. The media server can transcode using GPU hardware acceleration, which is far faster than CPU re-encoding in PowerShell.

Faststart is still applied via a lossless stream copy during the yt-dlp merge step, so the file is ready for HTTP streaming regardless.

---

## Cookie Handling

Some videos require authentication to download at full quality, or at all. Setting `$CookieBrowser` tells yt-dlp to read the login session from your browser's cookie store.

Firefox is the recommended browser because it does not lock its SQLite cookie database while running. Chromium-based browsers (Chrome, Edge) hold an exclusive lock on the database while open, which causes extraction to fail.

If cookie extraction fails for any reason - the profile does not exist yet, the browser locked the database, or the extraction tool encountered an error - the script detects this from stderr output and automatically retries the download without cookies. The download proceeds either way.

To disable cookie extraction entirely, set `$CookieBrowser = ""`.

---

## yt-dlp Update Strategy

On every run, the script compares the installed yt-dlp version against the latest GitHub release. If an update is available, it tries three methods in order, stopping as soon as one succeeds:

1. `yt-dlp -U` - the built-in self-updater (fastest, works if yt-dlp has write access to itself)
2. `winget upgrade yt-dlp` - Windows Package Manager upgrade
3. Direct download of `yt-dlp.exe` from the GitHub releases API, replacing the existing binary in-place

If none of the three methods succeed, a warning is printed and the script continues with the currently installed version.

---

## Output

Files are saved to `%USERPROFILE%\Downloads` and named after the video title, sanitized for the filesystem by yt-dlp. The container is always MP4.
