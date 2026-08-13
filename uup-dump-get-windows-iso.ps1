#!/usr/bin/pwsh
param(
    [string]$windowsTargetName,
    [string]$destinationDirectory='output',
    [string]$rcloneRemote='gdrive',
    [string]$rcloneProdRemote=$null,
    [switch]$copyOnly
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
    "25H2" = @{
        search = "windows 11 26200 amd64"
        id = $null
        edition = "Professional"
        virtualEdition = $null
        ring = "RETAIL"
        preview = $true
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

    if ($target.id) {
        $id = $target.id
        $uupDumpUrl = 'https://uupdump.net/selectlang.php?' + (New-QueryString @{
            id = $id
        })
        Write-Host "Using override id $id ($uupDumpUrl)"

        Write-Host "Getting the $name $id langs metadata"
        $result = Invoke-UupDumpApi listlangs @{
            id = $id
        }
        $info = $result.response.updateInfo
        $langs = if ($result.response.langFancyNames -is [System.Management.Automation.PSCustomObject]) {
            @($result.response.langFancyNames.PSObject.Properties | ForEach-Object { $_.Name })
        } else {
            @()
        }

        if ($langs -notcontains 'en-us') {
            throw "Override build $id does not have the en-us language."
        }

        Write-Host "Getting the $name $id editions metadata"
        $editionsResult = Invoke-UupDumpApi listeditions @{
            id = $id
            lang = 'en-us'
        }
        $editions = if ($editionsResult.response.editionFancyNames -is [System.Management.Automation.PSCustomObject]) {
            @($editionsResult.response.editionFancyNames.PSObject.Properties | ForEach-Object { $_.Name })
        } else {
            @()
        }

        if ($editions -notcontains $target.edition) {
            throw "Override build $id does not have the $($target.edition) edition."
        }

        return [PSCustomObject]@{
            name = $name
            title = $info.title
            build = $info.build
            id = $id
            edition = $target.edition
            virtualEdition = $target.virtualEdition
            apiUrl = 'https://api.uupdump.net/get.php?' + (New-QueryString @{
                id = $id
                lang = 'en-us'
                edition = $target.edition
            })
            downloadUrl = 'https://uupdump.net/download.php?' + (New-QueryString @{
                id = $id
                pack = 'en-us'
                edition = $target.edition
            })
            downloadPackageUrl = 'https://uupdump.net/get.php?' + (New-QueryString @{
                id = $id
                pack = 'en-us'
                edition = $target.edition
            })
        }
    }

    $result = Invoke-UupDumpApi listid @{
        search = $target.search
    }
    $builds = if ($result.response.builds -is [System.Management.Automation.PSCustomObject]) {
        $result.response.builds.PSObject.Properties
    } else {
        @()
    }
    $builds `
        | ForEach-Object {
            $id = $_.Value.uuid
            $uupDumpUrl = 'https://uupdump.net/selectlang.php?' + (New-QueryString @{
                id = $id
            })
            Write-Host "Processing $name $id ($uupDumpUrl)"
            $_
        } `
        | Where-Object {
            # ignore previews when they are not explicitly requested.
            $preview = if ($target.Contains('preview') -and $target.preview) { $true } elseif ($target.search -like '*preview*') { $true } else { $false }
            $result = $preview -or $_.Value.title -notlike '*preview*'
            if (!$result) {
                Write-Host "Skipping. Expected preview=false. Got preview=true."
            }
            if ($_.Value.title -like '*Update for*' -and $_.Value.title -notlike '*Feature update*') {
                Write-Host "Skipping. Build seems to be an update, not a full OS: $($_.Value.title)"
                $result = $false
            }
            $result
        } `
        | ForEach-Object {
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
            $id = $_.Value.uuid
            Write-Host "Getting the $name $id langs metadata"
            $result = Invoke-UupDumpApi listlangs @{
                id = $id
            }
            if ($result.response.updateInfo.build -ne $_.Value.build) {
                throw 'for some reason listlangs returned an unexpected build'
            }
            $_.Value | Add-Member -NotePropertyMembers @{
                langs = $result.response.langFancyNames
                info = $result.response.updateInfo
            }
            $langs = if ($_.Value.langs -is [System.Management.Automation.PSCustomObject]) {
                @($_.Value.langs.PSObject.Properties | ForEach-Object { $_.Name })
            } else {
                @()
            }
            $editions = if ($langs -contains 'en-us') {
                Write-Host "Getting the $name $id editions metadata"
                $result = Invoke-UupDumpApi listeditions @{
                    id = $id
                    lang = 'en-us'
                }
                $result.response.editionFancyNames
            } else {
                if ($langs) {
                    Write-Host "Skipping. Expected langs=en-us. Got langs=$($langs -join ',')."
                } else {
                    Write-Host "Skipping. No languages found."
                }
                [PSCustomObject]@{}
            }
            $_.Value | Add-Member -NotePropertyMembers @{
                editions = $editions
            }
            $_
        } `
        | Where-Object {
            # only return builds that:
            #   1. are from the expected ring/channel (default retail)
            #   2. have the english language
            #   3. match the requested edition
            $ring = $_.Value.info.ring
            $langs = if ($_.Value.langs -is [System.Management.Automation.PSCustomObject]) {
                @($_.Value.langs.PSObject.Properties | ForEach-Object { $_.Name })
            } else {
                @()
            }
            $editions = if ($_.Value.editions -is [System.Management.Automation.PSCustomObject]) {
                @($_.Value.editions.PSObject.Properties | ForEach-Object { $_.Name })
            } else {
                @()
            }
            $result = $true
            $expectedRing = if ($target.Contains('ring')) {
                $target.ring
            } else {
                'RETAIL'
            }
            if ($ring -ne $expectedRing) {
                Write-Host "Skipping. Expected ring=$expectedRing. Got ring=$ring."
                $result = $false
            }
            if ($langs -notcontains 'en-us') {
                if ($langs) {
                    Write-Host "Skipping. Expected langs=en-us. Got langs=$($langs -join ',')."
                } else {
                    Write-Host "Skipping. No languages found."
                }
                $result = $false
            }
            if ($editions -notcontains $target.edition) {
                if ($editions) {
                    Write-Host "Skipping. Expected editions=$($target.edition). Got editions=$($editions -join ',')."
                } else {
                    Write-Host "Skipping. No editions found."
                }
                $result = $false
            }
            $result
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
                virtualEdition = $target.virtualEdition
                apiUrl = 'https://api.uupdump.net/get.php?' + (New-QueryString @{
                    id = $id
                    lang = 'en-us'
                    edition = $target.edition
                    #noLinks = '1' # do not return the files download urls.
                })
                downloadUrl = 'https://uupdump.net/download.php?' + (New-QueryString @{
                    id = $id
                    pack = 'en-us'
                    edition = $target.edition
                })
                # NB you must use the HTTP POST method to invoke this packageUrl
                #    AND in the body you must include:
                #           autodl=2 updates=1 cleanup=1
                #           OR
                #           autodl=3 updates=1 cleanup=1 virtualEditions[]=Enterprise
                downloadPackageUrl = 'https://uupdump.net/get.php?' + (New-QueryString @{
                    id = $id
                    pack = 'en-us'
                    edition = $target.edition
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

function Invoke-RcloneCopy([string]$source, [string]$destination, [string]$label) {
    if (!$env:RCLONE_PATH) {
        throw "RCLONE_PATH not set."
    }
    Write-Host $label
    & $env:RCLONE_PATH copy $source $destination --progress --stats 5s --stats-one-line
    if ($LASTEXITCODE -ne 0) {
        throw "rclone copy failed ($label): $source -> $destination"
    }
    Write-Host "Done: $label"
}

function Upload-ToRclone($localPath, $remotePath, [string]$label = $null) {
    if (!$env:RCLONE_PATH) {
        Write-Host "RCLONE_PATH not set. Skipping upload of $localPath"
        return
    }
    if (!$label) {
        $label = "Uploading $localPath to $remotePath"
    }
    Invoke-RcloneCopy $localPath $remotePath $label
}

function Copy-FromTestToProduction($name, $testRemote, $prodRemote) {
    Invoke-RcloneCopy "$testRemote`:$name/$name.iso" "$prodRemote`:$name/" "Copying (1/3) $name.iso from $testRemote to $prodRemote"
    Invoke-RcloneCopy "$testRemote`:$name/$name.iso.json" "$prodRemote`:$name/" "Copying (2/3) $name.iso.json from $testRemote to $prodRemote"
    Invoke-RcloneCopy "$testRemote`:$name/$name.iso.sha256.txt" "$prodRemote`:$name/" "Copying (3/3) $name.iso.sha256.txt from $testRemote to $prodRemote"
    Write-Host "Copy from test to production complete."
}

function Copy-OnlyMode($name, $testRemote, $prodRemote, $destinationDirectory) {
    if (!$env:RCLONE_PATH) {
        throw "RCLONE_PATH not set. Copy-only mode requires rclone."
    }
    if (!$prodRemote) {
        throw "Production remote not specified. Copy-only mode requires both test and production remotes."
    }

    Write-Host "Copy-only mode: Checking if build exists on test account ($testRemote)..."
    $testJsonPath = "$testRemote`:$name/$name.iso.json"
    try {
        $testJsonContent = & $env:RCLONE_PATH cat $testJsonPath 2>$null
        if ($LASTEXITCODE -ne 0 -or !$testJsonContent) {
            throw "Build not found on test account. Cannot proceed with copy-only mode."
        }
        $testJson = $testJsonContent | ConvertFrom-Json
        Write-Host "Build $($testJson.build) found on test account."

        # Check if it already exists on production
        Write-Host "Checking if build exists on production account ($prodRemote)..."
        $prodJsonPath = "$prodRemote`:$name/$name.iso.json"
        try {
            $prodJsonContent = & $env:RCLONE_PATH cat $prodJsonPath 2>$null
            if ($LASTEXITCODE -eq 0 -and $prodJsonContent) {
                $prodJson = $prodJsonContent | ConvertFrom-Json
                if ($prodJson.build -eq $testJson.build) {
                    Write-Host "Build $($testJson.build) already exists on production account. Skipping copy."
                    return
                }
                Write-Host "Production has build $($prodJson.build), test has build $($testJson.build). Proceeding with copy."
            } else {
                Write-Host "Build not found on production account. Proceeding with copy."
            }
        } catch {
            Write-Host "Failed to check production account. Proceeding with copy."
        }

        # Download from test to local
        $buildDirectory = "$destinationDirectory/$name"
        if (Test-Path $buildDirectory) {
            Remove-Item -Force -Recurse $buildDirectory | Out-Null
        }
        New-Item -ItemType Directory -Force $buildDirectory | Out-Null

        Invoke-RcloneCopy "$testRemote`:$name/$name.iso" "$buildDirectory/" "Downloading (1/3) $name.iso from $testRemote"
        Invoke-RcloneCopy "$testRemote`:$name/$name.iso.json" "$buildDirectory/" "Downloading (2/3) $name.iso.json from $testRemote"
        Invoke-RcloneCopy "$testRemote`:$name/$name.iso.sha256.txt" "$buildDirectory/" "Downloading (3/3) $name.iso.sha256.txt from $testRemote"

        Write-Host "Uploading to production account ($prodRemote)..."
        $localIsoPath = "$buildDirectory/$name.iso"
        $localJsonPath = "$buildDirectory/$name.iso.json"
        $localChecksumPath = "$buildDirectory/$name.iso.sha256.txt"

        Upload-ToRclone $localIsoPath "$prodRemote`:$name/" "Uploading (1/3) $name.iso to $prodRemote"
        Upload-ToRclone $localJsonPath "$prodRemote`:$name/" "Uploading (2/3) $name.iso.json to $prodRemote"
        Upload-ToRclone $localChecksumPath "$prodRemote`:$name/" "Uploading (3/3) $name.iso.sha256.txt to $prodRemote"

        Write-Host "Copy from test to production complete."

    } catch {
        throw "Copy-only mode failed: $_"
    }
}

function Get-WindowsIso($name, $destinationDirectory) {
    $iso = Get-UupDumpIso $name $TARGETS.$name

    # ensure the build is a version number.
    if ($iso.build -notmatch '^\d+\.\d+$') {
        throw "unexpected $name build: $($iso.build)"
    }

    if ($env:RCLONE_PATH) {
        Write-Host "Checking if build $($iso.build) is already on Google Drive ($rcloneRemote)..."
        $gdriveJsonPath = "$rcloneRemote`:$name/$name.iso.json"
        try {
            $existingJsonContent = & $env:RCLONE_PATH cat $gdriveJsonPath 2>$null
            if ($LASTEXITCODE -eq 0 -and $existingJsonContent) {
                $existingJson = $existingJsonContent | ConvertFrom-Json
                if ($existingJson.build -eq $iso.build) {
                    Write-Host "Build $($iso.build) already exists on Google Drive ($($existingJson.title)). Skipping build."
                    if ($env:GITHUB_OUTPUT) {
                        "skipped=true" | Add-Content -Path $env:GITHUB_OUTPUT
                    }
                    exit 0
                }
                Write-Host "Existing build on Google Drive is $($existingJson.build), but current build is $($iso.build). Proceeding with build."
            } else {
                Write-Host "No existing build metadata found on Google Drive. Proceeding with build."
            }
        } catch {
            Write-Host "Failed to check for existing build on Google Drive."
        }
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
    
    # Retry loop to handle HTTP 429 Rate Limits
    $cmdContent = Get-Content -Path $buildDirectory/uup_download_windows.cmd -Raw
    $cmdContent = [regex]::Replace($cmdContent, 
        '(?mi)^"\%aria2\%".*?-o"\%aria2Script\%".*?"(https://uupdump\.net/get\.php.*?)".*$',
        'powershell -Command "for ($i=0; $i -lt 15; $i++) { try { Invoke-WebRequest -Uri ''$1'' -OutFile ''%aria2Script%''; exit 0 } catch { Write-Host ''Retrying API due to rate limit...''; Start-Sleep 15 } }; exit 1"'
    )
    Set-Content -Encoding ascii -NoNewline -Path $buildDirectory/uup_download_windows.cmd -Value $cmdContent

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

    $version = '10.0.26100.1742'
    if ($windowsImages | Where-Object { $_.version -eq $version }) {
        Write-Host "Build $($iso.build) contains image with forbidden version $version. Skipping upload."
        if ($env:GITHUB_OUTPUT) {
            "skipped=true" | Add-Content -Path $env:GITHUB_OUTPUT
        }
        return
    }

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

    # Upload to the specified remote (test or prod)
    if ($env:RCLONE_PATH) {
        Write-Host "Uploading ISO and metadata to $rcloneRemote..."
        Upload-ToRclone $destinationIsoPath "$rcloneRemote`:$name/"
        Upload-ToRclone $destinationIsoMetadataPath "$rcloneRemote`:$name/"
        Upload-ToRclone $destinationIsoChecksumPath "$rcloneRemote`:$name/"
        Write-Host "Upload to $rcloneRemote complete."
    }

    # If production remote is specified, check test and copy to production
    if ($rcloneProdRemote -and $env:RCLONE_PATH) {
        Write-Host "Checking if build exists on test account ($rcloneRemote)..."
        $testJsonPath = "$rcloneRemote`:$name/$name.iso.json"
        try {
            $testJsonContent = & $env:RCLONE_PATH cat $testJsonPath 2>$null
            if ($LASTEXITCODE -eq 0 -and $testJsonContent) {
                $testJson = $testJsonContent | ConvertFrom-Json
                Write-Host "Build $($testJson.build) found on test account."

                # Check if it already exists on production
                Write-Host "Checking if build exists on production account ($rcloneProdRemote)..."
                $prodJsonPath = "$rcloneProdRemote`:$name/$name.iso.json"
                try {
                    $prodJsonContent = & $env:RCLONE_PATH cat $prodJsonPath 2>$null
                    if ($LASTEXITCODE -eq 0 -and $prodJsonContent) {
                        $prodJson = $prodJsonContent | ConvertFrom-Json
                        if ($prodJson.build -eq $testJson.build) {
                            Write-Host "Build $($testJson.build) already exists on production account. Skipping copy."
                        } else {
                            Write-Host "Production has build $($prodJson.build), test has build $($testJson.build). Copying from test to production..."
                            Copy-FromTestToProduction $name $rcloneRemote $rcloneProdRemote
                        }
                    } else {
                        Write-Host "Build not found on production account. Copying from test to production..."
                        Copy-FromTestToProduction $name $rcloneRemote $rcloneProdRemote
                    }
                } catch {
                    Write-Host "Failed to check production account. Copying from test to production..."
                    Copy-FromTestToProduction $name $rcloneRemote $rcloneProdRemote
                }
            } else {
                Write-Host "Build not found on test account. Skipping production copy."
            }
        } catch {
            Write-Host "Failed to check test account. Skipping production copy."
        }
    }

    Write-Host 'All Done.'
}

if ($copyOnly) {
    if (!$rcloneProdRemote) {
        throw "Copy-only mode requires -rcloneProdRemote parameter"
    }
    Copy-OnlyMode $windowsTargetName $rcloneRemote $rcloneProdRemote $destinationDirectory
} else {
    Get-WindowsIso $windowsTargetName $destinationDirectory
}
