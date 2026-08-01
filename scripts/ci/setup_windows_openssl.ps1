$ErrorActionPreference = "Stop"

choco install openssl -y --no-progress

$opensslCandidates = @(
  (Join-Path $env:ProgramFiles "OpenSSL-Win64"),
  (Join-Path $env:ProgramFiles "OpenSSL")
)
$opensslDir = $opensslCandidates | Where-Object {
  Test-Path (Join-Path $_ "include\openssl\ssl.h")
} | Select-Object -First 1
if (-not $opensslDir) {
  throw "OpenSSL installation was not found. Checked: $($opensslCandidates -join ', ')"
}

$opensslLibCandidates = @(
  (Join-Path $opensslDir "lib"),
  (Join-Path $opensslDir "lib\VC\x64\MD")
)
$opensslLibDir = $opensslLibCandidates | Where-Object {
  Test-Path (Join-Path $_ "libcrypto.lib")
} | Select-Object -First 1
if (-not $opensslLibDir) {
  throw "OpenSSL import library libcrypto.lib was not found. Checked: $($opensslLibCandidates -join ', ')"
}

if (-not $env:GITHUB_ENV) {
  throw "GITHUB_ENV is unavailable."
}

Write-Host "Using OpenSSL headers from $opensslDir and libraries from $opensslLibDir"
Add-Content -Path $env:GITHUB_ENV -Value "OPENSSL_DIR=$opensslDir"
Add-Content -Path $env:GITHUB_ENV -Value "OPENSSL_INCLUDE_DIR=$(Join-Path $opensslDir 'include')"
Add-Content -Path $env:GITHUB_ENV -Value "OPENSSL_LIB_DIR=$opensslLibDir"
Add-Content -Path $env:GITHUB_ENV -Value "LIB=$opensslLibDir;$env:LIB"
