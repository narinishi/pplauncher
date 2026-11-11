param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = $PSScriptRoot
$cacheDirectory = Join-Path $root '_cache'
$patchDirectory = Join-Path $root 'patches'
$pinsPath = Join-Path $root 'pins.txt'

$expectedRepositories = @('chrlauncher', 'routine', 'cjson')

$patchCommand = Get-Command 'patch' -ErrorAction SilentlyContinue
if (-not $patchCommand) {
    $patchCommand = Get-Command 'patch.exe' -ErrorAction SilentlyContinue
}

if (-not $patchCommand) {
    Write-Error 'The patch program was not found on PATH. Install Git for Windows and add its usr\bin directory to PATH.'
    exit 1
}

$curlCommand = Get-Command 'curl.exe' -ErrorAction SilentlyContinue

$existingRepositories = @($expectedRepositories | Where-Object {
    Test-Path -LiteralPath (Join-Path $root $_)
})

if ($existingRepositories.Count -eq $expectedRepositories.Count -and -not $Force) {
    Write-Host 'All source repositories are already present; setup is assumed to be complete.'
    exit 0
}

if (-not (Test-Path -LiteralPath $pinsPath)) {
    throw "Missing pins file: $pinsPath"
}

New-Item -ItemType Directory -Force -Path $cacheDirectory, $patchDirectory | Out-Null

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Test-ZipEndOfCentralDirectory {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    $stream = [IO.File]::OpenRead($Path)
    try {
        $length = $stream.Length
        if ($length -lt 22) {
            return $false
        }

        $readLength = [Math]::Min(65557, $length)
        $stream.Seek($length - $readLength, [IO.SeekOrigin]::Begin) | Out-Null

        $buffer = New-Object byte[] $readLength
        $bytesRead = $stream.Read($buffer, 0, $readLength)

        for ($i = $bytesRead - 22; $i -ge 0; $i--) {
            if ($buffer[$i] -eq 0x50 -and
                $buffer[$i + 1] -eq 0x4B -and
                $buffer[$i + 2] -eq 0x05 -and
                $buffer[$i + 3] -eq 0x06) {

                $commentLength = $buffer[$i + 20] -bor ($buffer[$i + 21] -shl 8)

                if (($i + 22 + $commentLength) -eq $bytesRead) {
                    return $true
                }
            }
        }

        return $false
    }
    finally {
        $stream.Dispose()
    }
}

function Get-PinRecords {
    $records = @()

    foreach ($line in Get-Content -LiteralPath $pinsPath) {
        $line = $line.Trim()

        if (-not $line -or $line.StartsWith('#')) {
            continue
        }

        $parts = $line.Split(':')

        if ($parts.Count -ne 3) {
            throw "Invalid pin entry: $line"
        }

        $repository = $parts[0].Trim()
        $kind = $parts[1].Trim().ToLowerInvariant()
        $reference = $parts[2].Trim()

        if ($kind -ne 'commit' -and $kind -ne 'branch') {
            throw "Unsupported pin kind '$kind' in: $line"
        }

        $records += [PSCustomObject]@{
            Repository = $repository
            Kind = $kind
            Reference = $reference
            Name = $repository.Split('/')[-1].ToLowerInvariant()
        }
    }

    return $records
}

function Get-CachePath {
    param([PSCustomObject]$Pin)

    $safeReference = $Pin.Reference -replace '[^A-Za-z0-9._-]', '_'

    return (Join-Path $cacheDirectory ($Pin.Name + '-' + $safeReference + '.zip'))
}

function Get-ArchiveUrl {
    param([PSCustomObject]$Pin)

    if ($Pin.Kind -eq 'commit') {
        return ('https://codeload.github.com/' + $Pin.Repository + '/zip/' + $Pin.Reference)
    }

    return ('https://codeload.github.com/' + $Pin.Repository + '/zip/refs/heads/' + $Pin.Reference)
}

function Get-CachedArchive {
    param([PSCustomObject]$Pin)

    $cachePath = Get-CachePath $Pin

    if (Test-ZipEndOfCentralDirectory $cachePath) {
        Write-Host "CACHE $($Pin.Name)"
        return $cachePath
    }

    if (Test-Path -LiteralPath $cachePath) {
        Remove-Item -LiteralPath $cachePath -Force
    }

    $url = Get-ArchiveUrl $Pin

    Write-Host "GET   $($Pin.Repository) ($($Pin.Kind) $($Pin.Reference))"

    if ($curlCommand) {
        & $curlCommand.Source '--location' '--fail' '--silent' '--show-error' '--retry' '3' '--retry-delay' '2' '--output' $cachePath $url

        if ($LASTEXITCODE -ne 0) {
            throw "Download failed for $($Pin.Repository) (curl exit code $LASTEXITCODE)"
        }
    }
    else {
        Invoke-WebRequest -Uri $url -OutFile $cachePath -UseBasicParsing
    }

    if (-not (Test-ZipEndOfCentralDirectory $cachePath)) {
        throw "Downloaded archive is not a valid zip file: $cachePath"
    }

    return $cachePath
}

function Expand-RepositoryArchive {
    param(
        [PSCustomObject]$Pin,
        [string]$ArchivePath
    )

    $extractDirectory = Join-Path $cacheDirectory ('_extract_' + $Pin.Name)
    $targetDirectory = Join-Path $root $Pin.Name

    if (Test-Path -LiteralPath $extractDirectory) {
        Remove-Item -LiteralPath $extractDirectory -Recurse -Force
    }

    New-Item -ItemType Directory -Force -Path $extractDirectory | Out-Null
    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $extractDirectory -Force

    $topLevelDirectory = Get-ChildItem -LiteralPath $extractDirectory -Directory | Select-Object -First 1

    if (-not $topLevelDirectory) {
        throw "Archive has no top-level directory: $ArchivePath"
    }

    if (Test-Path -LiteralPath $targetDirectory) {
        Remove-Item -LiteralPath $targetDirectory -Recurse -Force
    }

    New-Item -ItemType Directory -Force -Path $targetDirectory | Out-Null

    if ($Pin.Name -eq 'cjson') {
        Get-ChildItem -LiteralPath $topLevelDirectory.FullName -File | Copy-Item -Destination $targetDirectory -Force
    }
    else {
        $sourceDirectory = Join-Path $topLevelDirectory.FullName 'src'

        if (-not (Test-Path -LiteralPath $sourceDirectory)) {
            throw "Archive does not contain a src directory: $ArchivePath"
        }

        Copy-Item -LiteralPath $sourceDirectory -Destination (Join-Path $targetDirectory 'src') -Recurse -Force

        $licensePath = Join-Path $topLevelDirectory.FullName 'LICENSE'

        if (Test-Path -LiteralPath $licensePath) {
            Copy-Item -LiteralPath $licensePath -Destination (Join-Path $targetDirectory 'LICENSE') -Force
        }
    }

    Remove-Item -LiteralPath $extractDirectory -Recurse -Force
}

function Invoke-RepositoryPatch {
    param(
        [string]$Repository,
        [string]$PatchFile
    )

    if (-not (Test-Path -LiteralPath $PatchFile)) {
        throw "Missing patch file: $PatchFile"
    }

    Write-Host "PATCH $Repository"

    & $patchCommand.Source '--binary' '-p1' '-d' (Join-Path $root $Repository) '-i' $PatchFile

    if ($LASTEXITCODE -ne 0) {
        throw "Patch failed for $Repository (exit code $LASTEXITCODE)"
    }
}

$pins = Get-PinRecords

foreach ($pin in $pins) {
    if ($expectedRepositories -notcontains $pin.Name) {
        throw "Unexpected repository in pins.txt: $($pin.Repository)"
    }

    $archivePath = Get-CachedArchive $pin
    Expand-RepositoryArchive -Pin $pin -ArchivePath $archivePath
}

Invoke-RepositoryPatch -Repository 'chrlauncher' -PatchFile (Join-Path $patchDirectory 'chrlauncher.patch')
Invoke-RepositoryPatch -Repository 'routine' -PatchFile (Join-Path $patchDirectory 'routine.patch')

Write-Host 'Setup complete.'
