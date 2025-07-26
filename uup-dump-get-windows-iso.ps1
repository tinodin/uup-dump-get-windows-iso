#!/usr/bin/pwsh
param(
    [string]$windowsTargetName,
    [string]$destinationDirectory='output'
)

Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'
trap {
    Write-Host "ERROR: $_"
    @(($_.ScriptStackTrace -split '\r?\n') -replace '^(.*)$','ERROR: $1') | Write-Host
    @(($_.Exception.ToString() -split '\r?\n') -replace '^(.*)$','ERROR EXCEPTION: $1') | Write-Host
    Exit 1
}

$TARGETS = @{
    "23H2" = @{
        search = "windows 11 22631 amd64"
        edition = "Professional"
        virtualEdition = $null
        ring = "RETAIL"
        preview = $false
    }
    "24H2" = @{
        search = "windows 11 26100 amd64"
        edition = "Professional"
        virtualEdition = $null
        ring = "RETAIL"
        preview = $false
    }
    "25H2" = @{
        search = "windows 11 26200 amd64"
        edition = "Professional"
        virtualEdition = $null
        ring = "WIF"
        preview = $true
    }
}

function New-QueryString([hashtable]$parameters) {
    @($parameters.GetEnumerator() | ForEach-Object {
        "$($_.Key)=$([System.Web.HttpUtility]::UrlEncode($_.Value))"
    }) -join '&'
}

function Invoke-UupDumpApi([string]$name, [hashtable]$body) {
    for ($n = 0; $n -lt 15; ++$n) {
        if ($n) {
            Write-Host "Waiting a bit before retrying the uup-dump api ${name} request #$n"
            Start-Sleep -Seconds 10
            Write-Host "Retrying the uup-dump api ${name} request #$n"
        }
        try {
            return Invoke-RestMethod -Method Get -Uri "https://api.uupdump.net/$name.php" -Body $body
        } catch {
            Write-Host "WARN: failed the uup-dump api $name request: $_"
        }
    }
    throw "timeout making the uup-dump api $name request"
}

function Get-UupDumpIso($name, $target) {
    Write-Host "Getting the $name metadata"
    $result = Invoke-UupDumpApi listid @{ search = $target.search }

    $result.response.builds.PSObject.Properties `
        | ForEach-Object {
            $id = $_.Value.uuid
            Write-Host "Processing $name $id"
            $_
        } `
        | Where-Object {
            $isPreview = $_.Value.title -like '*preview*'
            $expectedPreview = $target.preview
            $result = ($expectedPreview -eq $isPreview)
            if (-not $result) {
                Write-Host "Skipping. Expected preview=$expectedPreview. Got preview=$isPreview."
            }
            $result
        } `
        | ForEach-Object {
            $id = $_.Value.uuid
            Write-Host "Getting the $name $id langs metadata"
            $result = Invoke-UupDumpApi listlangs @{ id = $id }

            if ($result.response.updateInfo.build -ne $_.Value.build) {
                throw 'Unexpected build mismatch in listlangs'
            }

            $_.Value | Add-Member -NotePropertyMembers @{
                langs = $result.response.langFancyNames
                info = $result.response.updateInfo
            }

            $langs = $_.Value.langs.PSObject.Properties.Name
            $editions = if ($langs -contains 'en-us') {
                Write-Host "Getting the $name $id editions metadata"
                $result = Invoke-UupDumpApi listeditions @{ id = $id; lang = 'en-us' }
                $result.response.editionFancyNames
            } else {
                Write-Host "Skipping. Missing en-us language."
                [PSCustomObject]@{}
            }

            $_.Value | Add-Member -NotePropertyMembers @{ editions = $editions }
            $_
        } `
        | Where-Object {
            $ring = $_.Value.info.ring
            $langs = $_.Value.langs.PSObject.Properties.Name
            $editions = $_.Value.editions.PSObject.Properties.Name
            $expectedRing = $target.ring

            ($ring -eq $expectedRing) -and
            ($langs -contains 'en-us') -and
            ($editions -contains $target.edition)
        } `
        | Select-Object -First 1 `
        | ForEach-Object {
            $id = $_.Value.uuid
            [PSCustomObject]@{
                name = $name
                title = $_.Value.title
                build = $_.Value.build
                id = $id
                edition = $target.edition
                virtualEdition = $null
                apiUrl = 'https://api.uupdump.net/get.php?' + (New-QueryString @{
                    id = $id; lang = 'en-us'; edition = $target.edition
                })
                downloadUrl = 'https://uupdump.net/download.php?' + (New-QueryString @{
                    id = $id; pack = 'en-us'; edition = $target.edition
                })
                downloadPackageUrl = 'https://uupdump.net/get.php?' + (New-QueryString @{
                    id = $id; pack = 'en-us'; edition = $target.edition
                })
            }
        }
}

function Get-IsoWindowsImages($isoPath) {
    $isoPath = Resolve-Path $isoPath
    Write-Host "Mounting $isoPath"
    $isoImage = Mount-DiskImage $isoPath -PassThru
    try {
        $isoVolume = $isoImage | Get-Volume
        $installPath = "$($isoVolume.DriveLetter):\sources\install.wim"
        Write-Host "Getting Windows images from $installPath"
        Get-WindowsImage -ImagePath $installPath | ForEach-Object {
            $image = Get-WindowsImage -ImagePath $installPath -Index $_.ImageIndex
            [PSCustomObject]@{
                index = $image.ImageIndex
                name = $image.ImageName
                version = $image.Version
            }
        }
    } finally {
        Write-Host "Dismounting $isoPath"
        Dismount-DiskImage $isoPath | Out-Null
    }
}

function Get-WindowsIso($name, $destinationDirectory) {
    $iso = Get-UupDumpIso $name $TARGETS.$name

    if ($iso.build -notmatch '^\d+\.\d+$') {
        throw "unexpected $name build: $($iso.build)"
    }

    $buildDirectory = "$destinationDirectory/$name"
    $destinationIsoPath = "$buildDirectory.iso"
    $destinationIsoMetadataPath = "$destinationIsoPath.json"
    $destinationIsoChecksumPath = "$destinationIsoPath.sha256.txt"

    if (Test-Path $buildDirectory) {
        Remove-Item -Force -Recurse $buildDirectory | Out-Null
    }
    New-Item -ItemType Directory -Force $buildDirectory | Out-Null

    $title = "$name $($iso.edition) $($iso.build)"
    Write-Host "Downloading UUP dump package for $title"

    $downloadPackageBody = @{
        autodl = 2
        updates = 1
        cleanup = 1
    }

    Invoke-WebRequest -Method Post -Uri $iso.downloadPackageUrl -Body $downloadPackageBody -OutFile "$buildDirectory.zip" | Out-Null
    Expand-Archive "$buildDirectory.zip" $buildDirectory

    $convertConfig = (Get-Content $buildDirectory/ConvertConfig.ini) `
        -replace '^(AutoExit\s*)=.*','$1=1' `
        -replace '^(Cleanup\s*)=.*','$1=1' `
        -replace '^(NetFx3\s*)=.*','$1=1' `
        -replace '^(ResetBase\s*)=.*','$1=1' `
        -replace '^(SkipWinRE\s*)=.*','$1=1'

    Set-Content -Encoding ascii -Path $buildDirectory/ConvertConfig.ini -Value $convertConfig

    Write-Host "Creating ISO for $title"
    Push-Location $buildDirectory
    powershell cmd /c uup_download_windows.cmd | Out-String -Stream
    if ($LASTEXITCODE) {
        throw "uup_download_windows.cmd failed with exit code $LASTEXITCODE"
    }
    Pop-Location

    $sourceIsoPath = Resolve-Path $buildDirectory/*.iso

    $isoChecksum = (Get-FileHash -Algorithm SHA256 $sourceIsoPath).Hash.ToLowerInvariant()
    Set-Content -Encoding ascii -NoNewline -Path $destinationIsoChecksumPath -Value $isoChecksum

    $windowsImages = Get-IsoWindowsImages $sourceIsoPath

    Set-Content -Path $destinationIsoMetadataPath -Value (
        ([PSCustomObject]@{
            name = $name
            title = $iso.title
            build = $iso.build
            checksum = $isoChecksum
            images = @($windowsImages)
            uupDump = @{
                id = $iso.id
                apiUrl = $iso.apiUrl
                downloadUrl = $iso.downloadUrl
                downloadPackageUrl = $iso.downloadPackageUrl
            }
        } | ConvertTo-Json -Depth 99) -replace '\\u0026','&'
    )

    Write-Host "Moving ISO to $destinationIsoPath"
    Move-Item -Force $sourceIsoPath $destinationIsoPath

    Write-Host 'All Done.'
}

Get-WindowsIso $windowsTargetName $destinationDirectory
