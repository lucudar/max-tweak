# MAX Messenger IPA Builder with MAXMods Tweak (Windows)
# Downloads latest dylib from GitHub releases, injects into IPA

param(
    [string]$IpaPath = "",
    [string]$OutputName = "MAX_Modded.ipa"
)

$ErrorActionPreference = "Stop"
$REPO = "lucudar/max-tweak"
$DYLIB_NAME = "MAXMods.dylib"

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  MAX Messenger IPA Builder with MAXMods Tweak" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# Function: Download latest dylib from GitHub
function Download-LatestDylib {
    Write-Host "`n📥 Downloading latest MAXMods.dylib from GitHub..." -ForegroundColor Yellow

    try {
        $apiUrl = "https://api.github.com/repos/$REPO/releases/latest"
        $release = Invoke-RestMethod -Uri $apiUrl

        $asset = $release.assets | Where-Object { $_.name -eq $DYLIB_NAME } | Select-Object -First 1

        if (-not $asset) {
            Write-Host "❌ $DYLIB_NAME not found in latest release" -ForegroundColor Red
            return $false
        }

        Write-Host "   Release: $($release.tag_name)" -ForegroundColor Gray
        Write-Host "   URL: $($asset.browser_download_url)" -ForegroundColor Gray

        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $DYLIB_NAME
        Write-Host "✅ Downloaded to $DYLIB_NAME" -ForegroundColor Green
        return $true

    } catch {
        Write-Host "❌ Failed to download: $_" -ForegroundColor Red
        return $false
    }
}

# Function: Find MAX IPA in common locations
function Find-MaxIpa {
    $locations = @(
        (Get-Location).Path,
        "$env:USERPROFILE\Desktop",
        "$env:USERPROFILE\Downloads"
    )

    foreach ($loc in $locations) {
        $ipas = Get-ChildItem -Path $loc -Filter "*.ipa" -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match "MAX|oneme" }

        if ($ipas) {
            return $ipas[0].FullName
        }
    }

    return $null
}

# Function: Inject dylib into IPA
function Inject-Dylib {
    param(
        [string]$IpaPath,
        [string]$DylibPath,
        [string]$OutputIpa
    )

    Write-Host "`n🔧 Injecting $DylibPath into $IpaPath..." -ForegroundColor Yellow

    $tempDir = "temp_ipa_build"

    # Cleanup old temp
    if (Test-Path $tempDir) {
        Remove-Item -Path $tempDir -Recurse -Force
    }

    try {
        # 1. Extract IPA (it's just a ZIP)
        Write-Host "   Extracting IPA..." -ForegroundColor Gray
        Expand-Archive -Path $IpaPath -DestinationPath $tempDir -Force

        # 2. Find .app bundle
        $payloadDir = Join-Path $tempDir "Payload"
        $appBundle = Get-ChildItem -Path $payloadDir -Directory -Filter "*.app" | Select-Object -First 1

        if (-not $appBundle) {
            Write-Host "❌ No .app bundle found in IPA" -ForegroundColor Red
            return $false
        }

        Write-Host "   Found app: $($appBundle.Name)" -ForegroundColor Gray

        # 3. Create Frameworks directory
        $frameworksDir = Join-Path $appBundle.FullName "Frameworks"
        if (-not (Test-Path $frameworksDir)) {
            New-Item -Path $frameworksDir -ItemType Directory | Out-Null
        }

        # 4. Copy dylib
        $targetDylib = Join-Path $frameworksDir (Split-Path $DylibPath -Leaf)
        Copy-Item -Path $DylibPath -Destination $targetDylib -Force
        Write-Host "   ✅ Copied dylib to Frameworks/" -ForegroundColor Green

        # 5. Note about LC_LOAD_DYLIB
        $dylibLoadPath = "@executable_path/Frameworks/$DYLIB_NAME"
        Write-Host "   ⚠️  Manual step required:" -ForegroundColor Yellow
        Write-Host "      Add LC_LOAD_DYLIB to Mach-O executable" -ForegroundColor Yellow
        Write-Host "      Path: $dylibLoadPath" -ForegroundColor Gray
        Write-Host "      Use: insert_dylib or optool on macOS/Linux" -ForegroundColor Gray

        # 6. Repackage IPA
        Write-Host "   Repackaging to $OutputIpa..." -ForegroundColor Gray

        if (Test-Path $OutputIpa) {
            Remove-Item $OutputIpa -Force
        }

        Compress-Archive -Path "$tempDir\*" -DestinationPath $OutputIpa -CompressionLevel Optimal

        Write-Host "✅ Created: $OutputIpa" -ForegroundColor Green
        return $true

    } catch {
        Write-Host "❌ Error: $_" -ForegroundColor Red
        return $false
    } finally {
        # Cleanup
        if (Test-Path $tempDir) {
            Remove-Item -Path $tempDir -Recurse -Force
        }
    }
}

# Main execution
try {
    # Step 1: Download dylib if not present
    if (-not (Test-Path $DYLIB_NAME)) {
        if (-not (Download-LatestDylib)) {
            exit 1
        }
    } else {
        Write-Host "`n✅ Found existing $DYLIB_NAME" -ForegroundColor Green
    }

    # Step 2: Find or validate IPA path
    if ([string]::IsNullOrEmpty($IpaPath)) {
        $IpaPath = Find-MaxIpa
    }

    if ([string]::IsNullOrEmpty($IpaPath) -or -not (Test-Path $IpaPath)) {
        Write-Host "`n❌ MAX IPA not found!" -ForegroundColor Red
        Write-Host "   Usage: .\build_ipa.ps1 -IpaPath <path_to_max.ipa>" -ForegroundColor Yellow
        Write-Host "   Or place MAX IPA in current directory/Desktop/Downloads" -ForegroundColor Yellow
        exit 1
    }

    Write-Host "`n📦 Using IPA: $IpaPath" -ForegroundColor Cyan

    # Step 3: Inject and build
    if (Inject-Dylib -IpaPath $IpaPath -DylibPath $DYLIB_NAME -OutputIpa $OutputName) {
        Write-Host "`n============================================================" -ForegroundColor Cyan
        Write-Host "✅ SUCCESS! Modded IPA ready: $OutputName" -ForegroundColor Green
        Write-Host "============================================================" -ForegroundColor Cyan
        Write-Host "`n📝 Next steps:" -ForegroundColor Yellow
        Write-Host "   1. Use insert_dylib or optool to add LC_LOAD_DYLIB" -ForegroundColor White
        Write-Host "      insert_dylib '@executable_path/Frameworks/$DYLIB_NAME' Payload/MAX.app/MAX" -ForegroundColor Gray
        Write-Host "   2. Sign with your certificate (Sideloadly/AltStore)" -ForegroundColor White
        Write-Host "   3. Install via AltStore/SideStore" -ForegroundColor White
        Write-Host "   4. Check logs: Settings → MaxMods → View Logs" -ForegroundColor White
    } else {
        Write-Host "`n❌ Build failed" -ForegroundColor Red
        exit 1
    }

} catch {
    Write-Host "`n❌ Unexpected error: $_" -ForegroundColor Red
    exit 1
}
