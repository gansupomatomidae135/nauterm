$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

$Arch = "x86_64"
$AppName = "Nauterm"
$BinaryName = "nauterm"
$DistDir = if ($env:DIST_DIR) { $env:DIST_DIR } else { "dist" }
$CleanDist = if ($env:CLEAN_DIST) { $env:CLEAN_DIST } else { "1" }
$ReleaseDir = "build\windows\x64\runner\Release"
$MoshLibDir = if ($env:NAUTERM_MOSH_LIB_DIR) { $env:NAUTERM_MOSH_LIB_DIR } else { $null }
$DefaultMoshRepo = Join-Path (Resolve-Path ".").Path "..\nauterm-mosh"
$MoshRepoDir = if ($env:NAUTERM_MOSH_REPO_DIR) { $env:NAUTERM_MOSH_REPO_DIR } else { $DefaultMoshRepo }
$MoshFfiManifest = Join-Path $MoshRepoDir "nauterm_mosh_ffi\Cargo.toml"
$PubspecVersionLine = Get-Content "pubspec.yaml" | Where-Object { $_ -match '^version:\s+' } | Select-Object -First 1
$PubspecVersion = $PubspecVersionLine -replace '^version:\s+', ''
$VersionParts = $PubspecVersion -split '\+', 2
$Version = $VersionParts[0]
$NumericVersion = ($Version -split '-', 2)[0]
$PubspecBuildNumber = if ($VersionParts.Count -gt 1) { $VersionParts[1] } else { "1" }
$BuildNumber = if ($env:NAUTERM_BUILD_NUMBER) { $env:NAUTERM_BUILD_NUMBER } else { $PubspecBuildNumber }

if ($env:PROCESSOR_ARCHITECTURE -notin @("AMD64", "x86_64")) {
  throw "Windows x86_64 packaging requires an x86_64 host; current host is $env:PROCESSOR_ARCHITECTURE."
}

if ($BuildNumber -notmatch '^[0-9]+$' -or [int64]$BuildNumber -lt 1 -or [int64]$BuildNumber -gt 65535) {
  throw "Build number must be an integer from 1 through 65535: $BuildNumber"
}

$ProjectRoot = (Resolve-Path ".").Path
$ResolvedDistCandidate = if ([System.IO.Path]::IsPathRooted($DistDir)) {
  [System.IO.Path]::GetFullPath($DistDir)
} else {
  [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot $DistDir))
}
$ProjectPrefix = $ProjectRoot.TrimEnd('\') + '\'
if (
  $ResolvedDistCandidate -eq $ProjectRoot -or
  -not $ResolvedDistCandidate.StartsWith($ProjectPrefix, [System.StringComparison]::OrdinalIgnoreCase)
) {
  throw "DIST_DIR must be a child of the project directory: $DistDir"
}

bash scripts/prepare_app_icons.sh

function Get-CargoTargetDir {
  try {
    $metadata = cargo metadata --manifest-path native\nauterm_ffi\Cargo.toml --format-version 1 --no-deps | ConvertFrom-Json
    return $metadata.target_directory
  } catch {
    Write-Host "Unable to read cargo target directory from metadata: $_"
    return $null
  }
}

function Find-NativeDll {
  param(
    [string]$CargoTargetDir,
    [string]$DllName,
    [string]$CrateDir,
    [string]$ExtraRoot
  )

  $candidates = @(
    (Join-Path $ReleaseDir $DllName),
    "native\$CrateDir\target\release\$DllName",
    "native\$CrateDir\target\x86_64-pc-windows-msvc\release\$DllName",
    "target\release\$DllName",
    "target\x86_64-pc-windows-msvc\release\$DllName",
    "build\windows\x64\native_assets\windows\$DllName"
  )
  if ($CargoTargetDir) {
    $candidates += (Join-Path $CargoTargetDir "release\$DllName")
    $candidates += (Join-Path $CargoTargetDir "x86_64-pc-windows-msvc\release\$DllName")
  }
  if ($env:CARGO_TARGET_DIR) {
    $candidates += (Join-Path $env:CARGO_TARGET_DIR "release\$DllName")
    $candidates += (Join-Path $env:CARGO_TARGET_DIR "x86_64-pc-windows-msvc\release\$DllName")
  }
  if ($ExtraRoot) {
    $candidates += (Join-Path $ExtraRoot $DllName)
    $candidates += (Join-Path $ExtraRoot "target\release\$DllName")
    $candidates += (Join-Path $ExtraRoot "target\x86_64-pc-windows-msvc\release\$DllName")
  }

  foreach ($candidate in $candidates) {
    if (Test-Path $candidate) {
      return $candidate
    }
  }

  $searchRoots = @("native\$CrateDir\target", "target", "build\windows\x64")
  if ($CargoTargetDir) {
    $searchRoots += $CargoTargetDir
  }
  if ($env:CARGO_TARGET_DIR) {
    $searchRoots += $env:CARGO_TARGET_DIR
  }
  if ($ExtraRoot) {
    $searchRoots += $ExtraRoot
  }
  foreach ($root in $searchRoots) {
    if (-not (Test-Path $root)) {
      continue
    }
    $match = Get-ChildItem -Path $root -Filter $DllName -Recurse -File |
      Select-Object -First 1
    if ($null -ne $match) {
      return $match.FullName
    }
  }

  return $null
}

function Write-NativeDllDiagnostics {
  param(
    [string]$CargoTargetDir,
    [string]$DllName,
    [string]$CrateDir,
    [string]$ExtraRoot
  )

  $roots = @("native\$CrateDir\target", "target", "build\windows\x64")
  if ($CargoTargetDir) {
    $roots += $CargoTargetDir
  }
  if ($env:CARGO_TARGET_DIR) {
    $roots += $env:CARGO_TARGET_DIR
  }
  if ($ExtraRoot) {
    $roots += $ExtraRoot
  }
  $roots = $roots | Select-Object -Unique

  Write-Host "Searched for $DllName under:"
  foreach ($root in $roots) {
    Write-Host "  $root"
  }

  Write-Host "DLL files found in searched roots:"
  foreach ($root in $roots) {
    if (Test-Path $root) {
      Get-ChildItem -Path $root -Filter "*.dll" -Recurse -File -ErrorAction SilentlyContinue |
        ForEach-Object { Write-Host "  $($_.FullName)" }
    }
  }
}

if ($CleanDist -ne "0" -and (Test-Path $DistDir)) {
  Remove-Item $DistDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $DistDir | Out-Null

flutter config --enable-windows-desktop

if ($env:NAUTERM_SKIP_PUB_GET -ne "1") {
  flutter pub get
}
$CargoTargetDir = Get-CargoTargetDir
cargo build --manifest-path native\nauterm_ffi\Cargo.toml --release
if (-not $MoshLibDir -and -not (Test-Path $MoshFfiManifest)) {
  throw "Missing nauterm-mosh workspace. Set NAUTERM_MOSH_REPO_DIR to a checkout containing nauterm_mosh_ffi."
}
if (-not $MoshLibDir) {
  cargo build --manifest-path $MoshFfiManifest --release
} elseif (-not (Test-Path (Join-Path $MoshLibDir "nauterm_mosh_ffi.dll"))) {
  throw "Missing prebuilt nauterm_mosh_ffi.dll in NAUTERM_MOSH_LIB_DIR=$MoshLibDir"
}
$DartDefineArgs = @()
foreach ($Name in @(
  "NAUTERM_UPDATE_REPOSITORY",
  "NAUTERM_POSTHOG_API_KEY",
  "NAUTERM_POSTHOG_HOST",
  "NAUTERM_GITHUB_CLIENT_ID",
  "NAUTERM_GOOGLE_CLIENT_ID",
  "NAUTERM_GOOGLE_CLIENT_SECRET",
  "NAUTERM_ONEDRIVE_CLIENT_ID",
  "NAUTERM_DROPBOX_CLIENT_ID"
)) {
  $Value = [Environment]::GetEnvironmentVariable($Name)
  if (-not [string]::IsNullOrWhiteSpace($Value)) {
    $DartDefineArgs += "--dart-define=$Name=$Value"
  }
}
$FlutterBuildArgs = @(
  "windows",
  "--release",
  "--no-pub",
  "--build-name=$Version",
  "--build-number=$BuildNumber"
) + $DartDefineArgs
flutter build @FlutterBuildArgs

if (-not (Test-Path $ReleaseDir)) {
  throw "Expected Windows release bundle not found: $ReleaseDir"
}

if ($env:OPENSSL_DIR) {
  $OpenSslBinDir = Join-Path $env:OPENSSL_DIR "bin"
  if (-not (Test-Path $OpenSslBinDir)) {
    throw "OpenSSL binaries were not found: $OpenSslBinDir"
  }
  Get-ChildItem -Path $OpenSslBinDir -Filter "lib*.dll" -File |
    ForEach-Object {
      Copy-Item $_.FullName (Join-Path $ReleaseDir $_.Name) -Force
    }
}

$NativeDll = Find-NativeDll -CargoTargetDir $CargoTargetDir -DllName "nauterm_ffi.dll" -CrateDir "nauterm_ffi" -ExtraRoot ""
if ($null -eq $NativeDll) {
  Write-NativeDllDiagnostics -CargoTargetDir $CargoTargetDir -DllName "nauterm_ffi.dll" -CrateDir "nauterm_ffi" -ExtraRoot ""
  throw "Expected native DLL not found: nauterm_ffi.dll"
}

$BundledDll = Join-Path $ReleaseDir "nauterm_ffi.dll"
if ((Resolve-Path $NativeDll).Path -ne (Resolve-Path $BundledDll -ErrorAction SilentlyContinue).Path) {
  Copy-Item $NativeDll $BundledDll -Force
}

$MoshDllRoot = if ($MoshLibDir) { $MoshLibDir } else { $MoshRepoDir }
$MoshDll = Find-NativeDll -CargoTargetDir $CargoTargetDir -DllName "nauterm_mosh_ffi.dll" -CrateDir "nauterm_mosh_ffi" -ExtraRoot $MoshDllRoot
if ($null -eq $MoshDll) {
  Write-NativeDllDiagnostics -CargoTargetDir $CargoTargetDir -DllName "nauterm_mosh_ffi.dll" -CrateDir "nauterm_mosh_ffi" -ExtraRoot $MoshDllRoot
  throw "Expected native DLL not found: nauterm_mosh_ffi.dll"
}

$BundledMoshDll = Join-Path $ReleaseDir "nauterm_mosh_ffi.dll"
if ((Resolve-Path $MoshDll).Path -ne (Resolve-Path $BundledMoshDll -ErrorAction SilentlyContinue).Path) {
  Copy-Item $MoshDll $BundledMoshDll -Force
}

$ArchivePath = Join-Path $DistDir "$AppName-$Version-windows-$Arch.zip"
Compress-Archive -Path (Join-Path $ReleaseDir "*") -DestinationPath $ArchivePath -Force

$InnoScript = Join-Path $env:TEMP "nauterm-installer.iss"
$ResolvedReleaseDir = (Resolve-Path $ReleaseDir).Path
$ResolvedDistDir = (Resolve-Path $DistDir).Path
$ResolvedIconPath = (Resolve-Path "windows\runner\resources\app_icon.ico").Path
@"
[Setup]
AppId={{7A63A445-7F28-4336-B582-A10697D4CA53}
AppName=$AppName
AppVersion=$Version
VersionInfoVersion=$NumericVersion.$BuildNumber
AppPublisher=Nauterm
DefaultDirName={autopf}\$AppName
DefaultGroupName=$AppName
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
Compression=lzma2
SolidCompression=yes
CloseApplications=yes
RestartApplications=no
OutputDir=$ResolvedDistDir
OutputBaseFilename=$AppName-$Version-windows-$Arch-setup
SetupIconFile=$ResolvedIconPath
UninstallDisplayIcon={app}\$BinaryName.exe

[Files]
Source: "$ResolvedReleaseDir\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\$AppName"; Filename: "{app}\$BinaryName.exe"
Name: "{autodesktop}\$AppName"; Filename: "{app}\$BinaryName.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional icons:"

[Run]
Filename: "{app}\$BinaryName.exe"; Description: "Launch $AppName"; Flags: nowait postinstall skipifsilent
"@ | Set-Content -Path $InnoScript -Encoding UTF8

$Iscc = Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6\ISCC.exe"
if (-not (Test-Path $Iscc)) {
  throw "Inno Setup compiler not found: $Iscc"
}
& $Iscc $InnoScript
