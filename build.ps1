param(
    [ValidateSet('Release', 'Debug')]
    [string]$Configuration = 'Release',
    [string]$OutputDirectory,
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = $PSScriptRoot
$repo = Join-Path $root 'chrlauncher'
$src = Join-Path $repo 'src'
$routines = Join-Path $root 'routine'
$routinesSrc = Join-Path $routines 'src'
$cjson = Join-Path $root 'cjson'

function Resolve-LlvmTool {
    param([string]$Name)

    $command = Get-Command $Name -ErrorAction SilentlyContinue

    if ($command) {
        return $command.Source
    }

    $parent = Split-Path $root -Parent
    $toolchain = Get-ChildItem -LiteralPath $parent -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'llvm-mingw' -or $_.Name -like 'llvm-mingw*' } |
        Sort-Object Name |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "bin\$Name") } |
        Select-Object -First 1

    if ($toolchain) {
        return (Join-Path $toolchain.FullName "bin\$Name")
    }

    return $null
}

$clang = Resolve-LlvmTool 'clang.exe'
$windres = Resolve-LlvmTool 'llvm-windres.exe'

if (-not $clang) {
    throw 'clang not found on PATH or in a parent llvm-mingw directory'
}

if (-not $windres) {
    throw 'llvm-windres not found on PATH or in a parent llvm-mingw directory'
}

$objDir = Join-Path $root ('build\' + $Configuration.ToLowerInvariant())

if (-not $OutputDirectory) {
    $OutputDirectory = $objDir
}

$exePath = Join-Path $OutputDirectory 'chrlauncher.exe'
$pdbPath = [IO.Path]::ChangeExtension($exePath, '.pdb')
$mapPath = Join-Path $objDir 'chrlauncher.map'

if ($Clean) {
    Remove-Item -LiteralPath $objDir -Recurse -Force -ErrorAction SilentlyContinue
}

New-Item -ItemType Directory -Force -Path $objDir, $OutputDirectory | Out-Null

$defines = @(
    '-DUNICODE',
    '-D_UNICODE',
    '-DWIN32_LEAN_AND_MEAN',
    '-D_WIN32_WINNT=0x0601',
    '-DMINIZ_NO_TIME',
    '-DMINIZ_NO_DEFLATE_APIS',
    '-DAPP_NO_APPDATA',
    '-DAPP_NO_MUTEX',
    '-DAPP_HAVE_TRAY',
    '-DNDEBUG'
)

$warnings = @(
    '-Wno-incompatible-pointer-types',
    '-Wno-int-conversion',
    '-Wno-pragma-pack',
    '-Wno-c23-extensions',
    '-Wno-parentheses-equality',
    '-Wno-unused-value',
    '-Wno-ignored-attributes',
    '-Wno-pointer-sign',
    '-Wno-pointer-to-int-cast'
)

$includes = @(
    "-I$routinesSrc",
    "-I$src",
    "-I$src\lzma",
    "-I$cjson"
)

$libs = @(
    '-lbcrypt', '-lcomctl32', '-ldwmapi', '-ldbghelp', '-lshlwapi',
    '-lpsapi', '-lrpcrt4', '-lshcore', '-ltaskschd', '-luxtheme',
    '-lversion', '-lwindowscodecs', '-lwinhttp', '-lwtsapi32',
    '-lxmllite', '-lole32', '-loleaut32', '-luuid', '-lshell32',
    '-luser32', '-lgdi32', '-ladvapi32', '-lntdll', '-lkernel32',
    '-lcomdlg32'
)

if ($Configuration -eq 'Release') {
    $common = @('-std=gnu11', '-Oz', '-flto', '-ffunction-sections', '-fdata-sections', '-fno-ident') + $defines + $warnings + $includes
}
else {
    $common = @('-std=gnu11', '-O1', '-g', '-gcodeview') + $defines + $warnings + $includes
}

$sources = @(
    (Join-Path $src 'main.c'),
    (Join-Path $routinesSrc 'routine.c'),
    (Join-Path $routinesSrc 'rapp.c'),
    (Join-Path $src 'miniz.c'),
    (Join-Path $cjson 'cJSON.c')
)

$sources += Get-ChildItem -LiteralPath (Join-Path $src 'lzma') -Filter '*.c' -File | Sort-Object Name | ForEach-Object FullName

function Invoke-Tool {
    param(
        [string]$Tool,
        [string[]]$Arguments
    )

    & $Tool @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Tool failed with exit code $LASTEXITCODE"
    }
}

$objects = @()

foreach ($source in $sources) {
    $name = [IO.Path]::GetFileNameWithoutExtension($source)
    $object = Join-Path $objDir ($name + '.o')
    $arguments = @('-c') + $common + @($source, '-o', $object)

    Write-Host "CC  $([IO.Path]::GetFileName($source))"
    Invoke-Tool $clang $arguments
    $objects += $object
}

$resourceSource = Join-Path $objDir 'resource.rc'
$resourceText = Get-Content -LiteralPath (Join-Path $src 'resource.rc') -Raw
$resourceText = $resourceText -replace '222 10,', '222, 10,'
Set-Content -LiteralPath $resourceSource -Value $resourceText -Encoding UTF8

$resourceObject = Join-Path $objDir 'resource.o'
Write-Host 'RC  resource.rc'
Push-Location $src
try {
    Invoke-Tool $windres @(
        '-I', $routinesSrc,
        '-I', $src,
        '-i', $resourceSource,
        '-o', $resourceObject,
        '-O', 'coff'
    )
}
finally {
    Pop-Location
}
$objects += $resourceObject

if ($Configuration -eq 'Release') {
    $linkFlags = @(
        '-municode', '-mwindows', '-Oz', '-flto',
        '-Wl,--gc-sections', '-Wl,--icf=all', '-Wl,--strip-all',
        '-Wl,--no-insert-timestamp'
    )
}
else {
    $linkFlags = @('-municode', '-mwindows', '-O1', "-Wl,--pdb=$pdbPath")
}

$link = $linkFlags + $objects + $libs + @("-Wl,-Map=$mapPath")

Write-Host "LD  $exePath"
Invoke-Tool $clang ($link + @('-o', $exePath))

if ($Configuration -eq 'Release') {
    Remove-Item -LiteralPath $pdbPath -Force -ErrorAction SilentlyContinue
}

Write-Host "Built $exePath"
