$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $projectRoot
cargo test --locked --manifest-path rust/Cargo.toml -p keytrail-core -p keytrail-server -p keytrail-windows
if ($LASTEXITCODE -ne 0) { throw 'Windows tests failed' }
cargo build --release --locked --manifest-path rust/Cargo.toml -p keytrail-windows
if ($LASTEXITCODE -ne 0) { throw 'Windows release build failed' }
$destination = Join-Path $projectRoot 'artifacts/KeyTrail-Windows-v1.2'
New-Item -ItemType Directory -Force -Path $destination | Out-Null
Copy-Item 'rust/target/release/keytrail-windows.exe' $destination
Copy-Item 'rust/keytrail-windows/README.md' $destination
$checksum = (Get-FileHash (Join-Path $destination 'keytrail-windows.exe') -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -Path (Join-Path $destination 'SHA256.txt') -Value ($checksum + '  keytrail-windows.exe')
Compress-Archive -Path "$destination/*" -DestinationPath 'artifacts/KeyTrail-Windows-v1.2.zip' -Force
Write-Output 'Packaged Windows executable; collection was not launched and login settings were not changed.'
