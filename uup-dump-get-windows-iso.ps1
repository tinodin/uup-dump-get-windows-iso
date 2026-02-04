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
        ring = "Retail"
        preview = $false
    }
    "24H2" = @{
        search = "windows 11 26100 amd64"
        edition = "Professional"
        virtualEdition = $null
        ring = "Retail"
        preview = $false
        build = "26100.7628" 
    }
    "25H2" = @{
        search = "windows 11 26200 amd64"
        edition = "Professional"
        virtualEdition = $null
        ring = "Retail"
        preview = $false
    }
}

function New-QueryString([hashtable]$parameters) {
    @($parameters.GetEnumerator() | ForEach-Object {
        "$($_.Key)=$([System.Web.HttpUtility]::UrlEncode($_.Value))"
    }) -join '&'
}

function Invoke-UupDumpApi([string]$name, [hashtable]$body) {
    # see https://git.uupdump.net/uup-dump/json-api
    for ($n = 0; $n -lt 15; ++$n) {
        if ($n) {
            Write-Host "Waiting a bit before retrying the uup-dump api ${name} request #$n"
            Start-Sleep -Seconds 10
            Write-Host "Retrying the uup-dump api ${name} request #$n"
        }
        try {
            return Invoke-RestMethod `
                -Method Get `
                -Uri "https://api.uupdump.net/$name.php" `
                -Body $body
        } catch {
            Write-Host "WARN: failed the uup-dump api $name request: $_"
        }
    }
    throw "timeout making the uup-dump api $name request"
}

function Get-UupDumpIso($name, $target) {
    Write-Host "Getting the $name metadata"

    $query = if ($target.PSObject.Properties.Name -contains 'build') {
        @{ search = $target.build }
    } elseif ($target.PSObject.Properties.Name -contains 'uuid') {
        @{ id = $target.uuid }
    } else {
        @{ search = $target.search }
    }

    $result = Invoke-UupDumpApi listid $query

    # pick only the exact build/UUID if specified
    $resultBuild = if ($target.PSObject.Properties.Name -contains 'build') {
        $result.response.builds.PSObject.Properties | Where-Object { $_.Value.build -eq $target.build } | Select-Object -First 1
    } elseif ($target.PSObject.Properties.Name -contains 'uuid') {
        $result.response.builds.PSObject.Properties | Where-Object { $_.Value.uuid -eq $target.uuid } | Select-Object -First 1
    } else {
        $result.response.builds.PSObject.Properties | Select-Object -First 1
    }

    if (-not $resultBuild) {
        throw "Could not find the requested build/UUID for $name"
    }

    $id = $resultBuild.Value.uuid
    $uupDumpUrl = 'https://uupdump.net/selectlang.php?' + (New-QueryString @{ id = $id })
    Write-Host "Processing $name $id ($uupDumpUrl)"

    # get more information about the build. eg:
    #   "langs": {
    #     "en-us": "English (United States)",
    #     "pt-pt": "Portuguese (Portugal)",
    #     ...
    #   },
    #   "info": {
    #     "title": "Feature update to Microsoft server operating system, version 21H2 (20348.643)",
    #     "ring": "RETAIL",
    #     "flight": "Active",
    #     "arch": "amd64",
    #     "build": "20348.643",
    #     "checkBuild": "10.0.20348.1",
    #     "sku": 8,
    #     "created": 1649783041,
    #     "sha256ready": true
    #   }
    Write-Host "Getting the $name $id langs metadata"
    $langsResult = Invoke-UupDumpApi listlangs @{ id = $id }

    if ($langsResult.response.updateInfo.build -ne $resultBuild.Value.build) {
        throw 'for some reason listlangs returned an unexpected build'
    }

    $resultBuild.Value | Add-Member -NotePropertyMembers @{
        langs = $langsResult.response.langFancyNames
        info  = $langsResult.response.updateInfo
    }

    $langs = $resultBuild.Value.langs.PSObject.Properties.Name

    $editions = if ($langs -contains 'en-us') {
        Write-Host "Getting the $name $id editions metadata"
        $editionsResult = Invoke-UupDumpApi listeditions @{ id = $id; lang = 'en-us' }
        $editionsResult.response.editionFancyNames
    } else {
        Write-Host "Skipping. Expected langs=en-us. Got langs=$($langs -join ',')."
        [PSCustomObject]@{}
    }

    $resultBuild.Value | Add-Member -NotePropertyMembers @{ editions = $editions }

    # only return builds that:
    #   1. are from the expected ring/channel (default retail)
    #   2. have the english language
    #   3. match the requested edition
    $ring = $resultBuild.Value.info.ring
    $editionsNames = $resultBuild.Value.editions.PSObject.Properties.Name
    if ($ring -ne $target.ring -or $langs -notcontains 'en-us' -or $editionsNames -notcontains $target.edition) {
        Write-Host "Skipping. Expected ring=$($target.ring), langs=en-us, editions=$($target.edition). Got ring=$ring, langs=$($langs -join ','), editions=$($editionsNames -join ',')."
        throw "Build $id does not match target ring/lang/edition requirements"
    }

    # return the final object
    [PSCustomObject]@{
        name               = $name
        title              = $resultBuild.Value.title
        build              = $resultBuild.Value.build
        id                 = $id
        edition            = $target.edition
        virtualEdition     = $target.virtualEdition
        apiUrl             = 'https://api.uupdump.net/get.php?' + (New-QueryString @{ id = $id; lang = 'en-us'; edition = $target.edition })
        downloadUrl        = 'https://uupdump.net/download.php?' + (New-QueryString @{ id = $id; pack = 'en-us'; edition = $target.edition })
        # NB you must use the HTTP POST method to invoke this packageUrl
        #    AND in the body you must include:
        #           autodl=2 updates=1 cleanup=1
        #           OR
        #           autodl=3 updates=1 cleanup=1 virtualEditions[]=Enterprise
        downloadPackageUrl = 'https://uupdump.net/get.php?' + (New-QueryString @{ id = $id; pack = 'en-us'; edition = $target.edition })
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
        Get-WindowsImage -ImagePath $installPath `
            | ForEach-Object {
                $image = Get-WindowsImage `
                    -ImagePath $installPath `
                    -Index $_.ImageIndex
                $imageVersion = $image.Version
                [PSCustomObject]@{
                    index = $image.ImageIndex
                    name = $image.ImageName
                    version = $imageVersion
                }
            }
    } finally {
        Write-Host "Dismounting $isoPath"
        Dismount-DiskImage $isoPath | Out-Null
    }
}

function Get-WindowsIso($name, $destinationDirectory) {
    $iso = Get-UupDumpIso $name $TARGETS.$name

    # ensure the build is a version number.
    if ($iso.build -notmatch '^\d+\.\d+$') {
        throw "unexpected $name build: $($iso.build)"
    }

    $buildDirectory = "$destinationDirectory/$name"
    $destinationIsoPath = "$buildDirectory.iso"
    $destinationIsoMetadataPath = "$destinationIsoPath.json"
    $destinationIsoChecksumPath = "$destinationIsoPath.sha256.txt"

    # create the build directory.
    if (Test-Path $buildDirectory) {
        Remove-Item -Force -Recurse $buildDirectory | Out-Null
    }
    New-Item -ItemType Directory -Force $buildDirectory | Out-Null

    # define the iso title.
    $edition = if ($iso.virtualEdition) {
        $iso.virtualEdition
    } else {
        $iso.edition
    }
    $title = "$name $edition $($iso.build)"

    Write-Host "Downloading the UUP dump download package for $title from $($iso.downloadPackageUrl)"
    $downloadPackageBody = if ($iso.virtualEdition) {
        @{
            autodl = 3
            updates = 1
            cleanup = 1
            'virtualEditions[]' = $iso.virtualEdition
        }
    } else {
        @{
            autodl = 2
            updates = 1
            cleanup = 1
        }
    }
    Invoke-WebRequest `
        -Method Post `
        -Uri $iso.downloadPackageUrl `
        -Body $downloadPackageBody `
        -OutFile "$buildDirectory.zip" `
        | Out-Null
    Expand-Archive "$buildDirectory.zip" $buildDirectory

    # patch the uup-converter configuration.
    # see the ConvertConfig $buildDirectory/ReadMe.html documentation.
    # see https://github.com/abbodi1406/BatUtil/tree/master/uup-converter-wimlib
    $convertConfig = (Get-Content $buildDirectory/ConvertConfig.ini) `
        -replace '^(AutoExit\s*)=.*','$1=1' `
        -replace '^(Cleanup\s*)=.*','$1=1' `
        -replace '^(NetFx3\s*)=.*','$1=1' `
        -replace '^(ResetBase\s*)=.*','$1=1'
    if ($iso.virtualEdition) {
        $convertConfig = $convertConfig `
            -replace '^(StartVirtual\s*)=.*','$1=1' `
            -replace '^(vDeleteSource\s*)=.*','$1=1' `
            -replace '^(vAutoEditions\s*)=.*',"`$1=$($iso.virtualEdition)"
    }
    Set-Content `
        -Encoding ascii `
        -Path $buildDirectory/ConvertConfig.ini `
        -Value $convertConfig

    Write-Host "Creating the $title iso file inside the $buildDirectory directory"
    Push-Location $buildDirectory
    # NB we have to use powershell cmd to workaround:
    #       https://github.com/PowerShell/PowerShell/issues/6850
    #       https://github.com/PowerShell/PowerShell/pull/11057
    # NB we have to use | Out-String to ensure that this powershell instance
    #    waits until all the processes that are started by the .cmd are
    #    finished.
    powershell cmd /c uup_download_windows.cmd | Out-String -Stream
    if ($LASTEXITCODE) {
        throw "uup_download_windows.cmd failed with exit code $LASTEXITCODE"
    }
    Pop-Location

    $sourceIsoPath = Resolve-Path $buildDirectory/*.iso

    Write-Host "Getting the $sourceIsoPath checksum"
    $isoChecksum = (Get-FileHash -Algorithm SHA256 $sourceIsoPath).Hash.ToLowerInvariant()
    Set-Content -Encoding ascii -NoNewline `
        -Path $destinationIsoChecksumPath `
        -Value $isoChecksum

    $windowsImages = Get-IsoWindowsImages $sourceIsoPath

    # create the iso metadata file.
    Set-Content `
        -Path $destinationIsoMetadataPath `
        -Value (
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

    Write-Host "Moving the created $sourceIsoPath to $destinationIsoPath"
    Move-Item -Force $sourceIsoPath $destinationIsoPath

    Write-Host 'All Done.'
}

Get-WindowsIso $windowsTargetName $destinationDirectory
