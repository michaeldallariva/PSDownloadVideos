<#
.SYNOPSIS
    Downloads online videos to MP4 format using yt-dlp.

.DESCRIPTION
    Prompts for a video URL and downloads it as MP4, supporting YouTube, Facebook,
    Twitter, TikTok, and hundreds of other sites. Automatically installs yt-dlp and
    ffmpeg via winget if not found, and checks for the latest yt-dlp version on each run.

    CONVERSION MODE (ConvertToH264 = $true):
    Re-encodes to H.264/AAC if needed, then applies faststart for web streaming.
    Use this for universally compatible files for direct playback.

    DOWNLOAD ONLY MODE (ConvertToH264 = $false):
    Skips all re-encoding. Keeps original codecs (e.g. AV1/Opus) as downloaded.
    Best when a media server (Plex, NexusM, Jellyfin, etc.) will handle transcoding with
    hardware acceleration. Faststart is still applied via a fast stream copy.

    COOKIE HANDLING (3-tier automatic fallback):
      Tier 1 — cookies.txt file auto-exported from Firefox's SQLite database (most
               reliable; bypasses API endpoints that return 410 errors).
      Tier 2 — Live browser cookie extraction via --cookies-from-browser (works for
               most sites but can fail when the site's API is broken).
      Tier 3 — No cookies at all (public/unauthenticated content only).

    Firefox is recommended as its cookie database is readable even while the browser
    is running (no exclusive lock on Windows).

    Author : Michael DALLA RIVA, with the help of some AI.
    Version : 5.2
    
    Date : 14-Aug-2026
    Blog : https://lafrenchaieti.com
#>

# ============================================
# CONFIGURATION
# ============================================

$VideoQuality    = "1440"    # Options: "360", "480", "720", "1080", "1440", "2160", "best"
$CookieBrowser   = "firefox" # Options: "firefox", "edge", "brave", "opera", "vivaldi", or "" to disable
$ConvertToH264   = $false     # $true = re-encode to H.264/AAC after download; $false = keep original codecs / Useful to send videos to Whatsapp/Facebook etc
$UseNightlyBuild = $false     # $true = use nightly build (faster fixes for site breakage); $false = stable only

# ============================================
# Script Start
# ============================================

$DownloadFolder = [System.IO.Path]::Combine($env:USERPROFILE, "Downloads")
$CookiesFile    = [System.IO.Path]::Combine($env:TEMP, "yt-dlp-cookies.txt")

function Test-CommandExists {
    param([string]$Command)
    $null -ne (Get-Command $Command -ErrorAction SilentlyContinue)
}

function Install-ViaWinget {
    param(
        [string]$PackageName,
        [string]$DisplayName
    )

    Write-Host ""
    Write-Host "$DisplayName is not installed. Attempting to install via winget..." -ForegroundColor Yellow
    Write-Host ""

    if (-not (Test-CommandExists "winget")) {
        Write-Host "ERROR: winget is not available on this system." -ForegroundColor Red
        Write-Host "Please install 'App Installer' from the Microsoft Store." -ForegroundColor Yellow
        return $false
    }

    try {
        Write-Host "Running: winget install $PackageName" -ForegroundColor Cyan
        Write-Host ""
        winget install $PackageName --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -eq 0) {
            Write-Host ""
            Write-Host "$DisplayName installed successfully!" -ForegroundColor Green
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                        [System.Environment]::GetEnvironmentVariable("Path", "User")
            Start-Sleep -Seconds 2
            return $true
        } else {
            Write-Host ""
            Write-Host "ERROR: winget installation of $DisplayName failed." -ForegroundColor Red
            return $false
        }
    } catch {
        Write-Host ""
        Write-Host "ERROR: Failed to run winget." -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        return $false
    }
}

function Update-YtDlp {
    Write-Host "Checking yt-dlp version..." -ForegroundColor Cyan

    $currentVersion = $null
    try {
        $verOutput = & yt-dlp --version 2>&1
        $currentVersion = $verOutput.Trim()
    } catch {
        Write-Host "Could not determine current yt-dlp version." -ForegroundColor Yellow
    }

    # --- Nightly build path ---
    if ($UseNightlyBuild) {
        Write-Host "Nightly build mode enabled - updating to latest nightly..." -ForegroundColor Cyan
        try {
            & yt-dlp --update-to nightly 2>&1 | ForEach-Object { Write-Host $_ -ForegroundColor Gray }
            if ($LASTEXITCODE -eq 0) {
                $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                            [System.Environment]::GetEnvironmentVariable("Path", "User")
                Write-Host "yt-dlp nightly updated successfully!" -ForegroundColor Green
                return
            } else {
                Write-Host "Nightly update returned a non-zero exit code. Falling back to stable update..." -ForegroundColor Yellow
            }
        } catch {
            Write-Host "Nightly update failed: $($_.Exception.Message). Falling back to stable update..." -ForegroundColor Yellow
        }
    }

    # --- Stable build path ---
    $latestVersion = $null
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest" `
                                     -Headers @{ "User-Agent" = "PowerShell" } `
                                     -TimeoutSec 10
        $latestVersion = $release.tag_name.TrimStart("v")
    } catch {
        Write-Host "Could not reach GitHub to check for yt-dlp updates. Skipping update check." -ForegroundColor Yellow
        Write-Host "  (Current version: $currentVersion)" -ForegroundColor Gray
        return
    }

    if ($currentVersion -eq $latestVersion) {
        Write-Host "yt-dlp is up to date ($currentVersion)" -ForegroundColor Green
        return
    }

    Write-Host "Update available: $currentVersion -> $latestVersion" -ForegroundColor Yellow
    Write-Host "Updating yt-dlp now..." -ForegroundColor Yellow

    $updated = $false
    try {
        & yt-dlp -U 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "yt-dlp updated successfully via built-in updater!" -ForegroundColor Green
            $updated = $true
        }
    } catch { }

    if (-not $updated) {
        Write-Host "Built-in updater failed, trying winget upgrade..." -ForegroundColor Yellow
        try {
            winget upgrade yt-dlp --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                            [System.Environment]::GetEnvironmentVariable("Path", "User")
                Write-Host "yt-dlp updated successfully via winget!" -ForegroundColor Green
                $updated = $true
            }
        } catch { }
    }

    if (-not $updated) {
        Write-Host "winget upgrade failed, attempting direct download from GitHub..." -ForegroundColor Yellow
        try {
            $asset = $release.assets | Where-Object { $_.name -eq "yt-dlp.exe" } | Select-Object -First 1
            if ($asset) {
                $ytdlpPath = (Get-Command "yt-dlp" -ErrorAction SilentlyContinue).Source
                if (-not $ytdlpPath) {
                    $ytdlpPath = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\yt-dlp.yt-dlp_Microsoft.Winget.Source_8wekyb3d8bbwe\yt-dlp.exe"
                }
                if ($ytdlpPath -and (Test-Path $ytdlpPath)) {
                    $tempPath = "$env:TEMP\yt-dlp-new.exe"
                    Write-Host "Downloading $($asset.name) from GitHub..." -ForegroundColor Cyan
                    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tempPath -TimeoutSec 120
                    Copy-Item $tempPath $ytdlpPath -Force
                    Remove-Item $tempPath -ErrorAction SilentlyContinue
                    Write-Host "yt-dlp updated successfully via direct download!" -ForegroundColor Green
                    $updated = $true
                } else {
                    $newPath = "$env:LOCALAPPDATA\yt-dlp\yt-dlp.exe"
                    $newDir  = Split-Path $newPath
                    if (-not (Test-Path $newDir)) { New-Item -ItemType Directory $newDir | Out-Null }
                    Write-Host "Downloading $($asset.name) from GitHub..." -ForegroundColor Cyan
                    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $newPath -TimeoutSec 120
                    $userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
                    if ($userPath -notlike "*$newDir*") {
                        [System.Environment]::SetEnvironmentVariable("Path", "$userPath;$newDir", "User")
                        $env:Path += ";$newDir"
                    }
                    Write-Host "yt-dlp updated successfully via direct download!" -ForegroundColor Green
                    $updated = $true
                }
            } else {
                Write-Host "Could not find yt-dlp.exe asset in latest GitHub release." -ForegroundColor Red
            }
        } catch {
            Write-Host "Direct download update failed: $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    if (-not $updated) {
        Write-Host "WARNING: Could not update yt-dlp automatically. Downloads may fail." -ForegroundColor Red
        Write-Host "  To update manually, run:  yt-dlp -U  (as administrator if needed)" -ForegroundColor Yellow
        Write-Host "  Or download from: https://github.com/yt-dlp/yt-dlp/releases/latest" -ForegroundColor Yellow
    }
}

# ============================================
# Export Firefox cookies.sqlite → cookies.txt
# Returns $true on success, $false on failure
# ============================================
function Export-FirefoxCookies {
    param([string]$OutputPath)

    if ([string]::IsNullOrWhiteSpace($CookieBrowser) -or $CookieBrowser -ne "firefox") {
        return $false
    }

    Write-Host "Exporting Firefox cookies automatically..." -ForegroundColor Cyan

    # Locate the default Firefox profile
    $firefoxProfileRoot = [System.IO.Path]::Combine($env:APPDATA, "Mozilla", "Firefox", "Profiles")
    if (-not (Test-Path $firefoxProfileRoot)) {
        Write-Host "  Firefox profile folder not found. Skipping cookie export." -ForegroundColor Yellow
        return $false
    }

    # Prefer the profile flagged as Default in profiles.ini, fall back to most-recently-written
    $profilesIni = [System.IO.Path]::Combine($env:APPDATA, "Mozilla", "Firefox", "profiles.ini")
    $sqlitePath  = $null

    if (Test-Path $profilesIni) {
        $iniContent  = Get-Content $profilesIni -Raw
        # Find the path of the section that contains Default=1
        $defaultMatch = [regex]::Match($iniContent, '(?s)\[Profile[^\]]*\][^\[]*Default=1[^\[]*Path=([^\r\n]+)')
        if ($defaultMatch.Success) {
            $relPath = $defaultMatch.Groups[1].Value.Trim()
            # Path can be relative or absolute
            $candidate = if ([System.IO.Path]::IsPathRooted($relPath)) {
                $relPath
            } else {
                [System.IO.Path]::Combine($env:APPDATA, "Mozilla", "Firefox", $relPath)
            }
            $candidate = [System.IO.Path]::Combine($candidate, "cookies.sqlite")
            if (Test-Path $candidate) { $sqlitePath = $candidate }
        }
    }

    if (-not $sqlitePath) {
        # Fall back: pick profile folder that has the newest cookies.sqlite
        $sqlitePath = Get-ChildItem -Path $firefoxProfileRoot -Recurse -Filter "cookies.sqlite" -ErrorAction SilentlyContinue |
                      Sort-Object LastWriteTime -Descending |
                      Select-Object -First 1 -ExpandProperty FullName
    }

    if (-not $sqlitePath -or -not (Test-Path $sqlitePath)) {
        Write-Host "  cookies.sqlite not found in any Firefox profile. Skipping cookie export." -ForegroundColor Yellow
        return $false
    }

    Write-Host "  Found: $sqlitePath" -ForegroundColor Gray

    # We must work on a copy because Firefox may have a shared-memory WAL lock
    $sqliteCopy = [System.IO.Path]::Combine($env:TEMP, "yt-dlp-cookies-src.sqlite")
    try {
        Copy-Item $sqlitePath $sqliteCopy -Force

        # Also copy WAL/SHM files if they exist (needed for an up-to-date consistent read)
        foreach ($ext in @("-wal", "-shm")) {
            $extra = "$sqlitePath$ext"
            if (Test-Path $extra) { Copy-Item $extra "$sqliteCopy$ext" -Force }
        }
    } catch {
        Write-Host "  Could not copy cookies.sqlite: $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }

    # Use Python (built-in sqlite3 module) to convert to Netscape cookies.txt
    # Python is available on all modern Windows machines; install silently via winget if missing
    $pythonCmd = $null
    foreach ($cmd in @("python", "python3", "py")) {
        if (Test-CommandExists $cmd) { $pythonCmd = $cmd; break }
    }

    if (-not $pythonCmd) {
        Write-Host "  Python not found — installing silently via winget..." -ForegroundColor Yellow
        $installed = Install-ViaWinget -PackageName "Python.Python.3.12" -DisplayName "Python 3.12"
        if ($installed) {
            foreach ($cmd in @("python", "python3", "py")) {
                if (Test-CommandExists $cmd) { $pythonCmd = $cmd; break }
            }
        }
    }

    if (-not $pythonCmd) {
        Write-Host "  Python unavailable — cannot auto-export cookies." -ForegroundColor Yellow
        return $false
    }

    # Inline Python: read copied SQLite, write Netscape cookies.txt
    $pyScript = @'
import sqlite3, sys, os, time

src  = sys.argv[1]
dest = sys.argv[2]

try:
    con = sqlite3.connect(f"file:{src}?mode=ro&immutable=1", uri=True)
except Exception:
    con = sqlite3.connect(src)   # fallback: open normally

cur = con.cursor()
cur.execute("""
    SELECT host, path, isSecure, expiry, name, value
    FROM   moz_cookies
""")
rows = cur.fetchall()
con.close()

now = int(time.time())
with open(dest, "w", encoding="utf-8") as f:
    f.write("# Netscape HTTP Cookie File\n")
    f.write("# Auto-exported by Download-Video.ps1\n\n")
    for host, path, secure, expiry, name, value in rows:
        if expiry and expiry < now:
            continue            # skip expired cookies
        domain_flag = "TRUE" if host.startswith(".") else "FALSE"
        secure_flag = "TRUE"   if secure else "FALSE"
        expiry_str  = str(expiry) if expiry else "0"
        f.write(f"{host}\t{domain_flag}\t{path}\t{secure_flag}\t{expiry_str}\t{name}\t{value}\n")

print(f"Exported {len(rows)} cookies.")
'@

    $pyFile = [System.IO.Path]::Combine($env:TEMP, "yt-dlp-cookie-export.py")
    Set-Content -Path $pyFile -Value $pyScript -Encoding UTF8

    try {
        $result = & $pythonCmd $pyFile $sqliteCopy $OutputPath 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  $result" -ForegroundColor Green
            return $true
        } else {
            Write-Host "  Python cookie export failed: $result" -ForegroundColor Yellow
            return $false
        }
    } catch {
        Write-Host "  Exception during cookie export: $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    } finally {
        Remove-Item $sqliteCopy       -ErrorAction SilentlyContinue
        Remove-Item "$sqliteCopy-wal" -ErrorAction SilentlyContinue
        Remove-Item "$sqliteCopy-shm" -ErrorAction SilentlyContinue
        Remove-Item $pyFile           -ErrorAction SilentlyContinue
    }
}

# ============================================
# Helper: run yt-dlp and return exit code
# ============================================
function Invoke-YtDlp {
    param([string[]]$Arguments)
    try {
        & yt-dlp @Arguments
        return $LASTEXITCODE
    } catch {
        Write-Host "ERROR: Failed to execute yt-dlp: $($_.Exception.Message)" -ForegroundColor Red
        return -1
    }
}

# ============================================
# Helper: run yt-dlp capturing stderr to detect cookie-specific failures
# ============================================
function Invoke-YtDlpCaptured {
    param([string[]]$Arguments)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName  = "yt-dlp"
    $psi.Arguments = ($Arguments | ForEach-Object {
        if ($_ -match '\s') { "`"$_`"" } else { $_ }
    }) -join " "
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute       = $false
    $psi.CreateNoWindow        = $false

    $process = [System.Diagnostics.Process]::Start($psi)

    $stderrLines = [System.Collections.Generic.List[string]]::new()
    while (-not $process.StandardError.EndOfStream) {
        $line = $process.StandardError.ReadLine()
        $stderrLines.Add($line)
        Write-Host $line -ForegroundColor Yellow
    }
    $process.WaitForExit()

    $stderr = $stderrLines -join "`n"
    $cookieFailed = $stderr -match "Could not copy .+ cookie database"  `
                 -or $stderr -match "cookies-from-browser"              `
                 -or $stderr -match "Failed to extract cookies"         `
                 -or $stderr -match "no such file or directory"         `
                 -or $stderr -match "unable to load cookies"

    return [PSCustomObject]@{
        ExitCode     = $process.ExitCode
        CookieFailed = $cookieFailed
    }
}

# ============================================
# Install / update tools
# ============================================

if (-not (Test-CommandExists "yt-dlp")) {
    $installed = Install-ViaWinget -PackageName "yt-dlp" -DisplayName "yt-dlp"
    if (-not $installed -or -not (Test-CommandExists "yt-dlp")) {
        Write-Host ""
        Write-Host "yt-dlp installation requires a new PowerShell window." -ForegroundColor Yellow
        Write-Host "Please close this window and run the script again." -ForegroundColor Yellow
        Read-Host "Press Enter to exit"
        exit 1
    }
} else {
    Update-YtDlp
}

if (-not (Test-CommandExists "ffmpeg")) {
    Write-Host ""
    Write-Host "ffmpeg is required for video processing." -ForegroundColor Yellow
    $installed = Install-ViaWinget -PackageName "Gyan.FFmpeg" -DisplayName "ffmpeg"
    if (-not $installed -or -not (Test-CommandExists "ffmpeg")) {
        Write-Host ""
        Write-Host "ffmpeg installation requires a new PowerShell window." -ForegroundColor Yellow
        Write-Host "Please close this window and run the script again." -ForegroundColor Yellow
        Read-Host "Press Enter to exit"
        exit 1
    }
}

# ============================================
# Banner
# ============================================

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "     Online Video Downloader" -ForegroundColor Cyan
Write-Host "     MP4 (H.264/AAC) Format" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Supports: YouTube, Facebook, Twitter, TikTok, and 1000+ sites" -ForegroundColor Gray
Write-Host ""
Write-Host "Quality setting: ${VideoQuality}p" -ForegroundColor Green
Write-Host "Output format:   MP4 (H.264 video / AAC audio)" -ForegroundColor Green
Write-Host "Download folder: $DownloadFolder" -ForegroundColor Green
Write-Host ""

$VideoUrl = Read-Host "Enter the video URL"

if ([string]::IsNullOrWhiteSpace($VideoUrl)) {
    Write-Host ""
    Write-Host "ERROR: No URL provided. Exiting." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

# ============================================
# Build format / output args (shared)
# ============================================

if ($VideoQuality -eq "best") {
    $formatString = "bestvideo+bestaudio/best"
} else {
    $formatString = "bestvideo[height<=${VideoQuality}]+bestaudio/best[height<=${VideoQuality}]"
}

$outputTemplate = "$DownloadFolder\%(title)s.%(ext)s"

$commonArgs = @(
    "--format",               $formatString
    "--merge-output-format",  "mp4"
    "--postprocessor-args",   "ffmpeg:-movflags +faststart"
    "--output",               $outputTemplate
    "--no-playlist"
    "--progress"
    $VideoUrl
)

Write-Host ""
Write-Host "Starting download..." -ForegroundColor Yellow
Write-Host ""

$downloadExitCode = -1

# ============================================
# TIER 1 — cookies.txt auto-exported from Firefox SQLite
# ============================================
$cookiesExported = Export-FirefoxCookies -OutputPath $CookiesFile

if ($cookiesExported -and (Test-Path $CookiesFile)) {
    Write-Host "Trying with auto-exported cookies file (Tier 1)..." -ForegroundColor Cyan

    $tier1Args = @("--cookies", $CookiesFile) + $commonArgs
    $downloadExitCode = Invoke-YtDlp -Arguments $tier1Args

    if ($downloadExitCode -ne 0) {
        Write-Host ""
        Write-Host "Tier 1 (cookies file) failed — falling back to Tier 2..." -ForegroundColor Yellow
        $downloadExitCode = -1
    }
}

# ============================================
# TIER 2 — live --cookies-from-browser
# ============================================
if ($downloadExitCode -ne 0 -and -not [string]::IsNullOrWhiteSpace($CookieBrowser)) {
    Write-Host "Trying with live $CookieBrowser cookies (Tier 2)..." -ForegroundColor Cyan

    $tier2Args = @("--cookies-from-browser", $CookieBrowser) + $commonArgs
    $result    = Invoke-YtDlpCaptured -Arguments $tier2Args
    $downloadExitCode = $result.ExitCode

    if ($downloadExitCode -ne 0 -and $result.CookieFailed) {
        Write-Host ""
        Write-Host "Cookie extraction failed — falling back to Tier 3 (no cookies)..." -ForegroundColor Yellow
        Write-Host "(Tip: open Firefox at least once so its profile exists)" -ForegroundColor Gray
        $downloadExitCode = -1
    } elseif ($downloadExitCode -ne 0) {
        Write-Host ""
        Write-Host "Tier 2 failed — falling back to Tier 3 (no cookies)..." -ForegroundColor Yellow
        $downloadExitCode = -1
    }
}

# ============================================
# TIER 3 — no cookies
# ============================================
if ($downloadExitCode -ne 0) {
    Write-Host "Trying without cookies (Tier 3)..." -ForegroundColor Cyan

    $tier3Args = $commonArgs
    $downloadExitCode = Invoke-YtDlp -Arguments $tier3Args
}

# ============================================
# Post-download: codec check / H.264 conversion
# ============================================
if ($downloadExitCode -eq 0) {
    $latestFile = Get-ChildItem -Path $DownloadFolder -Filter "*.mp4" |
                  Sort-Object LastWriteTime -Descending |
                  Select-Object -First 1

    if ($latestFile) {
        Write-Host ""
        Write-Host "Verifying codec compatibility..." -ForegroundColor Yellow

        $videoCodec = (& ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 $latestFile.FullName 2>&1).Trim()
        $audioCodec = (& ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 $latestFile.FullName 2>&1).Trim()

        Write-Host "Current codecs: Video=$videoCodec, Audio=$audioCodec" -ForegroundColor Gray

        $videoNeedsReencode = $videoCodec -notmatch "^h264|^avc"
        $audioNeedsReencode = $audioCodec -notmatch "^aac"

        if ($ConvertToH264 -and ($videoNeedsReencode -or $audioNeedsReencode)) {
            Write-Host ""
            Write-Host "Converting to H.264/AAC for streaming compatibility..." -ForegroundColor Yellow

            $tempFile  = "$DownloadFolder\temp_$($latestFile.Name)"
            $ffmpegArgs = @("-i", $latestFile.FullName, "-y")

            if ($videoNeedsReencode) {
                $ffmpegArgs += @("-c:v", "libx264", "-preset", "fast", "-crf", "23")
            } else {
                $ffmpegArgs += @("-c:v", "copy")
            }

            if ($audioNeedsReencode) {
                $ffmpegArgs += @("-c:a", "aac", "-b:a", "192k")
            } else {
                $ffmpegArgs += @("-c:a", "copy")
            }

            $ffmpegArgs += @("-movflags", "+faststart", $tempFile)
            & ffmpeg @ffmpegArgs

            if ($LASTEXITCODE -eq 0) {
                Remove-Item $latestFile.FullName -Force
                Rename-Item $tempFile $latestFile.Name
                Write-Host "Conversion complete!" -ForegroundColor Green
            } else {
                Write-Host "Conversion failed, keeping original file." -ForegroundColor Yellow
                if (Test-Path $tempFile) { Remove-Item $tempFile -Force }
            }
        } else {
            if (-not $ConvertToH264 -and ($videoNeedsReencode -or $audioNeedsReencode)) {
                Write-Host "Conversion skipped (ConvertToH264 = false) - your media server will transcode." -ForegroundColor Cyan
            }
            Write-Host "Faststart already applied during download merge - file ready!" -ForegroundColor Green
        }
    }

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "   Download completed successfully!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "File saved to: $DownloadFolder" -ForegroundColor Cyan
    if ($ConvertToH264) {
        Write-Host "Format: MP4 (H.264/AAC) - Ready for direct playback!" -ForegroundColor Cyan
    } else {
        Write-Host "Format: MP4 (original codecs) - Ready for media server transcoding!" -ForegroundColor Cyan
    }
} else {
    Write-Host ""
    Write-Host "Download failed. Check the output above for details." -ForegroundColor Red
    Write-Host ""
    Write-Host "If the issue persists, the site extractor may not be fixed in yt-dlp yet." -ForegroundColor Yellow
    Write-Host "Monitor: https://github.com/yt-dlp/yt-dlp/issues/16729" -ForegroundColor Yellow
}

# Clean up temp cookies file
Remove-Item $CookiesFile -ErrorAction SilentlyContinue

Write-Host ""
Read-Host "Press Enter to exit"
