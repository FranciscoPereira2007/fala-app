# Constrói FalaSetup.exe: venv limpo (sem Whisper), PyInstaller, ffmpeg LGPL (BtbN) e Inno Setup.
# Uso (no PC): powershell -ExecutionPolicy Bypass -File build.ps1 1.0.0
param([string]$Version = "1.0.0")
$ErrorActionPreference = "Stop"
$B = $PSScriptRoot; $Src = Split-Path $B
Set-Location $B
if (-not (Test-Path .venv)) { py -3.12 -m venv .venv }
.venv\Scripts\python.exe -m pip install -q --upgrade pip pyinstaller cryptography websockets segno
if (-not (Test-Path ffmpeg.exe)) {
  $zip = "$env:TEMP\ffmpeg-lgpl.zip"
  Invoke-WebRequest "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-n8.1-latest-win64-lgpl-8.1.zip" -OutFile $zip
  Expand-Archive $zip "$env:TEMP\ffmpeg-lgpl" -Force
  Copy-Item (Get-ChildItem "$env:TEMP\ffmpeg-lgpl" -Recurse -Filter ffmpeg.exe | Select-Object -First 1).FullName ffmpeg.exe
}
.venv\Scripts\pyinstaller.exe --noconfirm --clean --windowed --name Fala --icon "$Src\fala.ico" `
  --add-binary "ffmpeg.exe;." --add-data "$Src\fala.ico;." --paths $Src `
  --hidden-import server --hidden-import screen --hidden-import relay_link --hidden-import sessions --hidden-import accounts --hidden-import jarvis `
  --exclude-module numpy --exclude-module faster_whisper --exclude-module piper `
  "$Src\fala_app.py"
$iscc = @("$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe", "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { winget install -e --id JRSoftware.InnoSetup --scope user --accept-source-agreements --accept-package-agreements | Out-Null
  $iscc = @("$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe", "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1 }
$env:FALA_VERSION = $Version
& $iscc /Q installer.iss
Get-Item out\FalaSetup.exe | Select-Object Name, Length
