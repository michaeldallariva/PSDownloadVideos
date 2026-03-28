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

    COOKIE HANDLING: Uses a browser's cookies for authentication. If cookie extraction
    fails for any reason, automatically retries without cookies so the download proceeds.
    Firefox is recommended as it does not lock its cookie database while running.

    Author : Michael DALLA RIVA, with the help of some AI.
    Version : 5.0
    Date : 28-MAr-2026
    Blog : https://lafrenchaieti.com
#>

# ============================================
# CONFIGURATION
# ============================================

$VideoQuality  = "1440"    # Options: "360", "480", "720", "1080", "1440", "2160", "best"
$CookieBrowser = "firefox" # Options: "firefox", "edge", "brave", "opera", "vivaldi", or "" to disable
$ConvertToH264 = $false    # $true = re-encode to H.264/AAC after download; $false = keep original codecs

# ============================================
# Script Start
# ============================================

$DownloadFolder = [System.IO.Path]::Combine($env:USERPROFILE, "Downloads")

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
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
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
                $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
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

if ($VideoQuality -eq "best") {
    $formatString = "bestvideo+bestaudio/best"
} else {
    $formatString = "bestvideo[height<=${VideoQuality}]+bestaudio/best[height<=${VideoQuality}]"
}

$outputTemplate = "$DownloadFolder\%(title)s.%(ext)s"

$baseArguments = @(
    "--format", $formatString
    "--merge-output-format", "mp4"
    "--output", $outputTemplate
    "--no-playlist"
    "--progress"
    $VideoUrl
)

Write-Host ""
Write-Host "Starting download..." -ForegroundColor Yellow
Write-Host "(Faststart will be applied during merge - no extra pass needed)" -ForegroundColor Gray
Write-Host ""

$downloadExitCode = -1

if (-not [string]::IsNullOrWhiteSpace($CookieBrowser)) {
    Write-Host "Trying with $CookieBrowser cookies..." -ForegroundColor Gray

    $argumentsWithCookies = @(
        "--format", $formatString
        "--merge-output-format", "mp4"
        "--postprocessor-args", "ffmpeg:-movflags +faststart"
        "--cookies-from-browser", $CookieBrowser
        "--output", $outputTemplate
        "--no-playlist"
        "--progress"
        $VideoUrl
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "yt-dlp"
    $psi.Arguments = ($argumentsWithCookies | ForEach-Object {
        if ($_ -match '\s') { "`"$_`"" } else { $_ }
    }) -join " "
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $false

    $process = [System.Diagnostics.Process]::Start($psi)

    $stderrLines = [System.Collections.Generic.List[string]]::new()
    while (-not $process.StandardError.EndOfStream) {
        $line = $process.StandardError.ReadLine()
        $stderrLines.Add($line)
        Write-Host $line -ForegroundColor Yellow
    }

    $process.WaitForExit()
    $downloadExitCode = $process.ExitCode
    $stderrText = $stderrLines -join "`n"

    $cookieFailed = $stderrText -match "Could not copy .+ cookie database" `
                 -or $stderrText -match "cookies-from-browser" `
                 -or $stderrText -match "Failed to extract cookies" `
                 -or $stderrText -match "no such file or directory" `
                 -or $stderrText -match "unable to load cookies"

    if ($downloadExitCode -ne 0 -and $cookieFailed) {
        Write-Host ""
        Write-Host "Cookie extraction failed - falling back to download without cookies..." -ForegroundColor Yellow
        Write-Host "(Tip: Make sure Firefox has been opened at least once so its profile exists)" -ForegroundColor Gray
        Write-Host ""
        $downloadExitCode = -1
    }
}

if ($downloadExitCode -ne 0) {
    if (-not [string]::IsNullOrWhiteSpace($CookieBrowser)) {
        Write-Host "Downloading without browser cookies..." -ForegroundColor Gray
        Write-Host ""
    }

    try {
        & yt-dlp @baseArguments
        $downloadExitCode = $LASTEXITCODE
    } catch {
        Write-Host ""
        Write-Host "ERROR: Failed to execute yt-dlp" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
}

if ($downloadExitCode -eq 0) {
    $latestFile = Get-ChildItem -Path $DownloadFolder -Filter "*.mp4" |
                  Sort-Object LastWriteTime -Descending |
                  Select-Object -First 1

    if ($latestFile) {
        Write-Host ""
        Write-Host "Verifying codec compatibility..." -ForegroundColor Yellow

        $ffprobeOutput = & ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 $latestFile.FullName 2>&1
        $videoCodec = $ffprobeOutput.Trim()

        $ffprobeOutput = & ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 $latestFile.FullName 2>&1
        $audioCodec = $ffprobeOutput.Trim()

        Write-Host "Current codecs: Video=$videoCodec, Audio=$audioCodec" -ForegroundColor Gray

        $videoNeedsReencode = $videoCodec -notmatch "^h264|^avc"
        $audioNeedsReencode = $audioCodec -notmatch "^aac"

        if ($ConvertToH264 -and ($videoNeedsReencode -or $audioNeedsReencode)) {
            Write-Host ""
            Write-Host "Converting to H.264/AAC for streaming compatibility..." -ForegroundColor Yellow

            $tempFile = "$DownloadFolder\temp_$($latestFile.Name)"
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

            $ffmpegArgs += @("-movflags", "+faststart")
            $ffmpegArgs += $tempFile

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
    Write-Host "If the issue persists, yt-dlp may need a newer update." -ForegroundColor Yellow
    Write-Host "Try running manually:  yt-dlp -U" -ForegroundColor Yellow
}

Write-Host ""
Read-Host "Press Enter to exit"
