<#
.SYNOPSIS
    Builds TDLib for Windows 10 (UWP) ARM / x86 / x64 and packages it as the
    "Telegram.Td.UWP" Extension SDK VSIX consumed by UnigramMobile.

.DESCRIPTION
    UnigramMobile consumes TDLib as a prebuilt SDK Extension referenced in
    Unigram.Native and the main project as:

        <SDKReference Include="Telegram.Td.UWP, Version=1.0" />

    The compiled SDK is distributed via the repository's "tdlib" git branch as a
    single file, "tdlib.vsix", which azure-pipelines.yml installs with
    VSIXInstaller before building the app.

    This script reproduces that artifact from source so the TDLib version can be
    upgraded. It:
      1. Verifies prerequisites (Git, CMake, Visual Studio 2017/v141, gperf).
      2. Bootstraps vcpkg and installs OpenSSL + zlib for the UWP triplets.
      3. Clones TDLib at the requested ref.
      4. Builds TDLib's WinRT component (Telegram.Td) for ARM, x86 and x64 UWP
         using TDLib's official td/example/uwp/build_native.ps1.
      5. Assembles an Extension SDK layout under "Telegram.Td.UWP\1.0\" with a
         generated SDKManifest.xml (identity kept at Version 1.0 on purpose so the
         existing <SDKReference .../> in the app does not need to change).
      6. Optionally packages that layout into "tdlib.vsix".

    IMPORTANT: this script targets a Windows build host with Visual Studio 2017
    (toolset v141) and the 10.0.18362.0 Windows SDK installed, matching
    azure-pipelines.yml. It cannot run on macOS/Linux.

.PARAMETER TdlibRef
    Git ref (branch, tag or commit) of https://github.com/tdlib/td to build.
    Pin this to a known-good commit for reproducible builds. Default: master.

.PARAMETER VcpkgRoot
    Path to an existing vcpkg checkout. If it does not exist it will be cloned
    and bootstrapped here.

.PARAMETER WorkRoot
    Working directory for the TDLib checkout and build output.

.PARAMETER Architectures
    UWP architectures to build. Default: ARM, x86, x64.

.PARAMETER PackageVsix
    When set, packages the assembled Extension SDK into tdlib.vsix.

.EXAMPLE
    .\Build-TdLib.ps1 -TdlibRef v1.8.0 -VcpkgRoot C:\src\vcpkg -PackageVsix

.NOTES
    After producing tdlib.vsix, publish it on the "tdlib" branch (replacing the
    existing file) so azure-pipelines.yml picks it up, OR install it locally with
    VSIXInstaller before opening the solution.

    Newer TDLib (>= 1.8.6) removed the `tdlibParameters` object and
    `checkDatabaseEncryptionKey`. If you build such a version you MUST also apply
    the Phase 3 source migration (see ProtoService.Initialize) or the app will
    fail to authenticate. See build/tdlib/PHASE3-MIGRATION.notes for details.
#>

[CmdletBinding()]
param(
    [string] $TdlibRef = "master",
    [string] $VcpkgRoot = "$PSScriptRoot\vcpkg",
    [string] $WorkRoot = "$PSScriptRoot\work",
    [ValidateSet("ARM", "x86", "x64")]
    [string[]] $Architectures = @("ARM", "x86", "x64"),
    # vcpkg release tag to pin. IMPORTANT: the latest vcpkg ships OpenSSL 3.x,
    # which does NOT build for *-uwp with the VS2017 (v141) toolset. This tag is
    # the last vcpkg release whose baseline still uses OpenSSL 1.1.1n, which is
    # what TDLib 1.6.x/1.7.x expects and which builds for UWP. If OpenSSL still
    # fails, drop to an even older tag (e.g. 2021.05.12).
    [string] $VcpkgRef = "2022.06.16.1",
    # Build dependencies release-only: halves vcpkg time and skips the debug
    # build (the UWP debug build is the one that was failing). The app's Release
    # configuration only needs the release libraries anyway.
    [switch] $ReleaseOnlyDeps = $true,
    [switch] $PackageVsix
)

$ErrorActionPreference = "Stop"

function Assert-Command {
    param([string] $Name, [string] $Hint)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required tool '$Name' was not found on PATH. $Hint"
    }
}

Write-Host "== Checking prerequisites ==" -ForegroundColor Cyan
Assert-Command git    "Install Git for Windows."
Assert-Command cmake  "Install CMake (>= 3.10) and add it to PATH."
# gperf and a host OpenSSL are pulled in via vcpkg below.

# vcpkg UWP triplet names.
$tripletMap = @{
    "ARM" = "arm-uwp"
    "x86" = "x86-uwp"
    "x64" = "x64-uwp"
}

# ---------------------------------------------------------------------------
# 1. vcpkg + dependencies (OpenSSL, zlib) for each UWP triplet
# ---------------------------------------------------------------------------
Write-Host "== Preparing vcpkg ($VcpkgRef) ==" -ForegroundColor Cyan
if (-not (Test-Path "$VcpkgRoot\.git")) {
    git clone https://github.com/microsoft/vcpkg "$VcpkgRoot"
}

# Pin vcpkg to a tag that still ships OpenSSL 1.1.1 (see -VcpkgRef note above).
Push-Location $VcpkgRoot
try {
    git fetch --all --tags
    $currentRef = (git rev-parse --abbrev-ref HEAD 2>$null)
    git checkout $VcpkgRef
    if ($LASTEXITCODE -ne 0) { throw "Could not check out vcpkg ref '$VcpkgRef'." }
}
finally {
    Pop-Location
}

# (Re)bootstrap so vcpkg.exe matches the pinned tree.
$vcpkgExe = Join-Path $VcpkgRoot "vcpkg.exe"
& "$VcpkgRoot\bootstrap-vcpkg.bat" -disableMetrics
if (-not (Test-Path $vcpkgExe)) { throw "vcpkg bootstrap failed." }

# ---------------------------------------------------------------------------
# Repair rotted tool download URLs.
# Old vcpkg tags reference build tools (7zip, nasm, ...) from vendor sites that
# only keep the LATEST version, so the pinned-version URLs now 404. We repoint
# the dead URLs to the Wayback Machine's raw capture (the "id_" form returns the
# original bytes unchanged, so vcpkg's SHA512 verification still passes).
$vcpkgToolsXml = Join-Path $VcpkgRoot "scripts\vcpkgTools.xml"
if (Test-Path $vcpkgToolsXml) {
    $toolsContent = Get-Content $vcpkgToolsXml -Raw
    $original = $toolsContent

    # Hosts known to drop old releases. Wayback serves the exact archived bytes.
    $deadHostPatterns = @(
        'https://www\.7-zip\.org/a/[^<"\s]+',
        'https://www\.nasm\.us/[^<"\s]+'
    )
    foreach ($pattern in $deadHostPatterns) {
        $toolsContent = [System.Text.RegularExpressions.Regex]::Replace(
            $toolsContent,
            $pattern,
            {
                param($m)
                $url = $m.Value
                if ($url -like 'https://web.archive.org/*') { return $url }
                return "https://web.archive.org/web/2022id_/$url"
            })
    }

    if ($toolsContent -ne $original) {
        Set-Content -Path $vcpkgToolsXml -Value $toolsContent -Encoding UTF8
        Write-Host "Repaired rotted tool download URLs in vcpkgTools.xml (via Wayback Machine)." -ForegroundColor Yellow
    }
}

# Optionally generate release-only overlay triplets to halve build time and to
# skip the debug UWP build that fails for OpenSSL.
$overlayArgs = @()
if ($ReleaseOnlyDeps) {
    $overlayDir = Join-Path $WorkRoot "triplets"
    New-Item -ItemType Directory -Force -Path $overlayDir | Out-Null
    foreach ($arch in $Architectures) {
        $triplet = $tripletMap[$arch]
        $src = Join-Path $VcpkgRoot "triplets\community\$triplet.cmake"
        if (-not (Test-Path $src)) {
            $src = Join-Path $VcpkgRoot "triplets\$triplet.cmake"
        }
        if (-not (Test-Path $src)) {
            throw "Could not find base triplet file for '$triplet' in the vcpkg checkout."
        }
        $dst = Join-Path $overlayDir "$triplet.cmake"
        $content = Get-Content $src -Raw
        if ($content -notmatch "VCPKG_BUILD_TYPE") {
            $content += "`nset(VCPKG_BUILD_TYPE release)`n"
        }
        Set-Content -Path $dst -Value $content -Encoding ASCII
    }
    $overlayArgs = @("--overlay-triplets=$overlayDir")
}

# gperf is a host build tool TDLib needs during generation.
$packages = @("gperf:x64-windows")
foreach ($arch in $Architectures) {
    $triplet = $tripletMap[$arch]
    $packages += "openssl:$triplet"
    $packages += "zlib:$triplet"
}

Write-Host "Installing: $($packages -join ', ')"
& $vcpkgExe install @packages @overlayArgs
if ($LASTEXITCODE -ne 0) { throw "vcpkg install failed." }

# Make gperf discoverable for TDLib's CMake generation.
$gperfDir = Join-Path $VcpkgRoot "installed\x64-windows\tools\gperf"
if (Test-Path $gperfDir) {
    $env:PATH = "$gperfDir;$env:PATH"
}

# ---------------------------------------------------------------------------
# 2. Clone TDLib at the requested ref
# ---------------------------------------------------------------------------
Write-Host "== Fetching TDLib ($TdlibRef) ==" -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $WorkRoot | Out-Null
$tdDir = Join-Path $WorkRoot "td"

if (-not (Test-Path "$tdDir\.git")) {
    git clone https://github.com/tdlib/td "$tdDir"
}
Push-Location $tdDir
try {
    git fetch --all --tags
    git checkout $TdlibRef
    git pull --ff-only 2>$null  # ignored for detached tags/commits
}
finally {
    Pop-Location
}

# ---------------------------------------------------------------------------
# 3. Build the UWP WinRT component for each architecture
#    TDLib ships an official driver script for exactly this.
# ---------------------------------------------------------------------------
$buildNative = Join-Path $tdDir "example\uwp\build_native.ps1"
if (-not (Test-Path $buildNative)) {
    throw "Expected TDLib UWP build script not found at $buildNative. The TDLib layout may have changed for ref '$TdlibRef'."
}

foreach ($arch in $Architectures) {
    Write-Host "== Building TDLib (UWP $arch) ==" -ForegroundColor Cyan
    & $buildNative -vcpkg_root $VcpkgRoot -arch $arch -mode Release
    if ($LASTEXITCODE -ne 0) { throw "TDLib UWP build failed for $arch." }
}

# TDLib's build_native.ps1 stages the SDK under example\uwp\build-native-uwp.
$nativeOut = Join-Path $tdDir "example\uwp\build-native-uwp"
if (-not (Test-Path $nativeOut)) {
    throw "TDLib UWP build did not produce expected output at $nativeOut."
}

# ---------------------------------------------------------------------------
# 4. Assemble the Extension SDK layout: Telegram.Td.UWP\1.0\
#    Identity is intentionally kept at version 1.0 so the consuming projects'
#    <SDKReference Include="Telegram.Td.UWP, Version=1.0" /> resolves unchanged.
# ---------------------------------------------------------------------------
Write-Host "== Assembling Telegram.Td.UWP Extension SDK ==" -ForegroundColor Cyan
$sdkRoot = Join-Path $WorkRoot "Telegram.Td.UWP\1.0"
if (Test-Path $sdkRoot) { Remove-Item -Recurse -Force $sdkRoot }
New-Item -ItemType Directory -Force -Path $sdkRoot | Out-Null

# Copy TDLib's staged SDK payload (References + Redist + DesignTime) verbatim.
Copy-Item -Recurse -Force "$nativeOut\*" $sdkRoot

# Generate the SDKManifest.xml describing the extension.
$sdkManifest = @'
<?xml version="1.0" encoding="utf-8"?>
<FileList
    DisplayName="Telegram.Td"
    ProductFamilyName="Telegram.Td.UWP"
    FrameworkIdentity-Telegram.Td.UWP="Telegram.Td.UWP"
    TargetFramework="UAP, version=v10.0.15063.0"
    MinVSVersion="15.0"
    AppliesTo="WindowsAppContainer"
    SDKType="External"
    SupportsMultipleVersions="Error"
    SupportPrefer32Bit="True">
  <File Reference="Telegram.Td.winmd" Implementation="Telegram.Td.dll" />
</FileList>
'@
Set-Content -Path (Join-Path $sdkRoot "SDKManifest.xml") -Value $sdkManifest -Encoding UTF8

Write-Host "Extension SDK staged at: $sdkRoot" -ForegroundColor Green

# ---------------------------------------------------------------------------
# 5. (Optional) package into tdlib.vsix
# ---------------------------------------------------------------------------
if ($PackageVsix) {
    Write-Host "== Packaging tdlib.vsix ==" -ForegroundColor Cyan
    # A VSIX is a ZIP containing the SDK payload plus extension.vsixmanifest and
    # a [Content_Types].xml. We generate a minimal Extension-SDK VSIX here.
    $vsixStage = Join-Path $WorkRoot "vsix"
    if (Test-Path $vsixStage) { Remove-Item -Recurse -Force $vsixStage }
    New-Item -ItemType Directory -Force -Path $vsixStage | Out-Null

    # Place the SDK under the well-known Extension SDK install path inside the VSIX.
    $vsixSdkDir = Join-Path $vsixStage "Telegram.Td.UWP\1.0"
    New-Item -ItemType Directory -Force -Path $vsixSdkDir | Out-Null
    Copy-Item -Recurse -Force "$sdkRoot\*" $vsixSdkDir

    $vsixManifest = @'
<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011">
  <Metadata>
    <Identity Id="Telegram.Td.UWP" Version="1.0" Language="en-US" Publisher="Unigram" />
    <DisplayName>Telegram.Td.UWP</DisplayName>
    <Description>TDLib Universal Windows Platform Extension SDK.</Description>
  </Metadata>
  <Installation Scope="Global" AllUsers="true">
    <InstallationTarget Id="Microsoft.ExtensionSDK" TargetPlatformIdentifier="UAP" TargetPlatformVersion="v10.0" SdkName="Telegram.Td.UWP" SdkVersion="1.0" />
  </Installation>
  <Assets>
    <Asset Type="Microsoft.ExtensionSDK" Path="Telegram.Td.UWP" TargetPlatformIdentifier="UAP" TargetPlatformVersion="v10.0" SdkName="Telegram.Td.UWP" SdkVersion="1.0" />
  </Assets>
</PackageManifest>
'@
    Set-Content -Path (Join-Path $vsixStage "extension.vsixmanifest") -Value $vsixManifest -Encoding UTF8

    $contentTypes = @'
<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="vsixmanifest" ContentType="text/xml" />
  <Default Extension="dll" ContentType="application/octet-stream" />
  <Default Extension="winmd" ContentType="application/octet-stream" />
  <Default Extension="xml" ContentType="text/xml" />
  <Default Extension="pri" ContentType="application/octet-stream" />
</Types>
'@
    Set-Content -Path (Join-Path $vsixStage "[Content_Types].xml") -Value $contentTypes -Encoding UTF8

    $vsixPath = Join-Path $WorkRoot "tdlib.vsix"
    if (Test-Path $vsixPath) { Remove-Item -Force $vsixPath }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory($vsixStage, $vsixPath)

    Write-Host "VSIX created: $vsixPath" -ForegroundColor Green
    Write-Host "Publish it on the 'tdlib' branch (overwrite tdlib.vsix) to update CI." -ForegroundColor Yellow
}

Write-Host "== Done ==" -ForegroundColor Cyan
