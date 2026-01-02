$skipCache = $env:USE_CACHE -eq "false"
$skipCommit = $env:SKIP_COMMIT -eq "true"

& git config --local user.email "jesse.houwing@gmail.com"
& git config --local user.name "Jesse Houwing"

$ErrorActionPreference = "Stop"

function Import-Extensions {
    [cmdletbinding()]
    Param (
        [int]$Page,
        [int]$PageSize
    )

    $maxRetries = 4
    $retryDelay = 15
    $attempt = 1
    
    do {
        try {
            if ($attempt -gt 1) {
                Write-Output "Retrying web request (attempt $attempt of $maxRetries) for page $Page..."
                Start-Sleep -Seconds $retryDelay
            }
            
            $result = Invoke-WebRequest -UseBasicParsing -Uri "https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery" `
                -Method "POST" `
                -Headers @{
                "authority"                    = "marketplace.visualstudio.com"
                "method"                       = "POST"
                "path"                         = "/_apis/public/gallery/extensionquery"
                "scheme"                       = "https"
                "accept"                       = "application/json;api-version=7.1-preview.1;excludeUrls=true"
                "accept-encoding"              = "gzip, deflate, br"
                "accept-language"              = "en-US,en;q=0.9"
                "cache-control"                = "no-cache"
                "origin"                       = "https://marketplace.visualstudio.com"
                "x-vss-reauthenticationaction" = "Suppress"
            } `
                -ContentType "application/json" `
                -Body "{`"assetTypes`":[],`"filters`":[{`"criteria`":[{`"filterType`":8,`"value`":`"Microsoft.VisualStudio.Services`"},{`"filterType`":8,`"value`":`"Microsoft.VisualStudio.Services.Integration`"},{`"filterType`":8,`"value`":`"Microsoft.VisualStudio.Services.Cloud`"},{`"filterType`":8,`"value`":`"Microsoft.TeamFoundation.Server`"},{`"filterType`":8,`"value`":`"Microsoft.TeamFoundation.Server.Integration`"},{`"filterType`":8,`"value`":`"Microsoft.VisualStudio.Services.Cloud.Integration`"},{`"filterType`":8,`"value`":`"Microsoft.VisualStudio.Services.Resource.Cloud`"},{`"filterType`":10,`"value`":`"target:\`"Microsoft.VisualStudio.Services\`" target:\`"Microsoft.VisualStudio.Services.Integration\`" target:\`"Microsoft.VisualStudio.Services.Cloud\`" target:\`"Microsoft.TeamFoundation.Server\`" target:\`"Microsoft.TeamFoundation.Server.Integration\`" target:\`"Microsoft.VisualStudio.Services.Cloud.Integration\`" target:\`"Microsoft.VisualStudio.Services.Resource.Cloud\`" `"},{`"filterType`":12,`"value`":`"37888`"}],`"direction`":2,`"pageSize`":$PageSize,`"pageNumber`":$Page,`"sortBy`":2,`"sortOrder`":0,`"pagingToken`":null}],`"flags`":870}" `
                -MaximumRetryCount 5 -RetryIntervalSec 10

            # If we get here, the request succeeded
            return ($result.Content | ConvertFrom-Json).results[0];
        }
        catch {
            Write-Output "Web request failed on attempt $attempt for page $Page`: $($_.Exception.Message)"
            
            if ($attempt -eq $maxRetries) {
                Write-Error "Failed to retrieve data after $maxRetries attempts for page $Page. Last error: $($_.Exception.Message)"
                throw
            }
            
            $attempt++
        }
    } while ($attempt -le $maxRetries)
}

function format-taskmanifests {
    [CmdletBinding()]
    param (
        $path
    )

    (Get-ChildItem -Path $path -Recurse -Filter "task.json" -File) | foreach-object {
        $taskJsonFile = $_
        try {
            $taskJson = Get-Content -Path $taskJsonFile.FullName -Raw | ConvertFrom-Json -AsHashtable
            $result = [ordered]@{
                id           = $taskJson.id
                name         = $taskJson.name
                version      = [ordered]@{
                    Major = ($taskJson.version.Major ?? $taskJson.version.major ?? 0)
                    Minor = ($taskJson.version.Minor ?? $taskJson.version.minor ?? 0)
                    Patch = ($taskJson.version.Patch ?? $taskJson.version.patch ?? 0)
                }
                friendlyName = $taskJson.friendlyName
                description  = $taskJson.description
                preview      = $taskJson.preview ?? $false
                deprecated   = $taskJson.deprecated ?? $false
                author       = $taskJson.author
            }

            write-output "Normalizing task manifest: $($taskJson.name) $($taskJson.version.Major).$($taskJson.version.Minor).$($taskJson.version.Patch)"

            ConvertTo-Json -Depth 100 $result | Set-Content -Path $taskJsonFile.FullName
        }
        catch {
            write-output "Deleting corrupt task manifest: $($taskJsonFile.FullName)"
            remove-item $taskJsonFile.FullName -Force
        }
    }
}

function write-commit {
    [cmdletbinding()]
    Param (
        [string]$message
    )

    write-output "::group::Git commit: $message"

    & git add . | Out-Null
    (& git diff HEAD --exit-code) | Out-null
    if ($LASTEXITCODE -ne 0) {
        if ($skipCommit) {
            return
        }

        & git commit -m $message
    }

    write-output "::endgroup::"
}

write-output "::group::Installing tfx"

npm install tfx-cli@0.22.6 -g --no-fund

$token = $env:AZURE_DEVOPS_PAT
$marketplace = "https://marketplace.visualstudio.com"
& tfx login --auth-type pat --token $token --service-url $marketplace --no-color --no-prompt
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to login to marketplace"
    exit 1
}

write-output "::endgroup::"

write-output "::group::Fetching Extension Metadata"
$pageSize = 100;
$page = 1
$totalFetched = 0
$max = 0
$extensions = @()
$cacheFile = ".cache/extensions.json"
mkdir -path ".cache" -Force | out-null

if ((-not (Test-Path -path $cacheFile -PathType Leaf)) -or (-not $skipCache)) {
    do {
        $ProgressPreference = "silentlycontinue"
        $result = Import-Extensions -PageSize $pageSize -Page $page
        $totalFetched += $result.extensions.Count
        $max = $result.resultMetaData[0].metadataItems[0].count

        $ProgressPreference = "continue"
        write-progress -activity "Fetching extension metadata" -status "Fetched $totalFetched of $max" -percentComplete (($totalFetched / $max) * 100)
        write-output "Fetching extension metadata | Fetched $totalFetched of $max"

        $extensions += $result.extensions
        $page += 1
    }
    while ($totalFetched -lt $max)

    # Remove properties that we don't need to prevent unwanted cache commits
    foreach ($extension in $extensions) {
        if ($extension.versions) { $extension.versions = @() }
        if ($extension.statistics) { $extension.statistics = @() }
        if ($extension.installationTargets) { $extension.installationTargets = @() }
        if ($extension.categories) { $extension.categories = @() }
        if ($extension.tags) { $extension.tags = @() }
    }

    # Sort the extensions to prevent unwanted cache commits
    $extensions = $extensions | Sort-Object -Property extensionId
    Set-Content -path $cacheFile -Value ($extensions | ConvertTo-Json -Depth 100)
    write-commit -message "Update extensions cache"
}
else {
    write-output "Using cached extension list"
    $extensions = Get-Content -raw -Path $cacheFile | ConvertFrom-Json
}
write-output "::endgroup::"

$extensionsProcessed = 0
foreach ($extension in $extensions) {
    $ProgressPreference = "continue"
    $publisherId = $extension.publisher.publisherName
    $extensionId = $extension.extensionName

    write-progress -activity "Processing extensions" -status "$extensionsProcessed - $($extensions.count) | $publisherId/$extensionId" -percentComplete (($extensionsProcessed / $($extensions.count)) * 100)
    write-output "Processing extensions | $extensionsProcessed - $($extensions.count) | $publisherId/$extensionId"
    $ProgressPreference = "silentlycontinue"
    $extensionsProcessed += 1

    write-output "::group::$publisherId/$extensionId"
    mkdir -path ".cache/$publisherId/$extensionId/" -Force | out-null

    $extensionDataFile = ".cache/$publisherId/$extensionId/extension.json"
    $fetchExtensionData = $true
    if (Test-Path -Path $extensionDataFile -PathType Leaf) {
        $extensionData = get-content -raw -Path $extensionDataFile | ConvertFrom-Json -Depth 100
        if ($extensionData.lastUpdated -ge $extension.lastUpdated) {
            $fetchExtensionData = $false
        }
    }

    if ($fetchExtensionData) {
        $extensionData = (& tfx extension show --auth-type pat --token $token --service-url $marketplace --publisher $publisherId --extension-id $extensionId --json --no-color --no-prompt) | ConvertFrom-Json
        ($extensionData.versions ?? @()) | foreach-object { $_.files = $_.files | where-object { $_.assetType -in @("Microsoft.VisualStudio.Services.VSIXPackage", "Microsoft.VisualStudio.Services.VsixManifest") } }
        $extensionData | ConvertTo-Json -Depth 100 | Set-Content -Path $extensionDataFile
    }

    foreach ($version in $extensionData.versions | where-object { $_.flags -eq 1 }) {
        $publisherId = $publisherId
        $extensionId = $extensionId

        $savePath = ".cache/$publisherId/$extensionId/$($version.version).vsix"
        $extractedPath = ".cache/$publisherId/$extensionId/$($version.version)/"
        $vsixUrl = ($version.files ?? @()) | where-object { $_.assetType -eq "Microsoft.VisualStudio.Services.VSIXPackage" } | select-object -ExpandProperty source
        $vsixManifestUrl = ($version.files ?? @()) | where-object { $_.assetType -eq "Microsoft.VisualStudio.Services.VsixManifest" } | select-object -ExpandProperty source

        if (
            -not (Test-Path -Path $extractedPath -PathType Container) -or
            (-not $vsixManifestUrl -and -not (test-path -path "$extractedPath/extension.vsixmanifest" -PathType Leaf))
        ) {
            write-output "Downloading VSIX: $($version.version)"
            try {
                Invoke-WebRequest -Uri $vsixUrl -OutFile $savePath -TimeoutSec 300
                (& 7z x $savePath "-o$extractedPath" "task.json" "extension.vsixmanifest" "extension.vsomanifest" -y -r -bd -aoa -spd -bb0) | out-null

                format-taskmanifests -path $extractedPath

                # For extensions that contain no tasks, make sure we commit the folder for caching
                if (-not (Test-Path -Path "$extractedPath/extension.vsomanifest" -PathType Leaf)) {
                    mkdir $extractedPath -Force | out-null
                    Set-Content -path "$extractedPath/.completed" -value "true" -Force
                }
            }
            finally {
                Remove-Item $savepath
            }
        }

        if ($vsixManifestUrl -and (-not(test-path -path "$extractedPath/extension.vsixmanifest" -PathType Leaf))) {
            write-output "Downloading VSIX Manifest: $($version.version)"
            mkdir $extractedPath -Force | out-null
            Invoke-WebRequest -Uri $vsixManifestUrl -OutFile "$extractedPath/extension.vsixmanifest"
            Set-Content -path "$extractedPath/.completed" -value "true" -Force
        }
    }

    write-output "::endgroup::"
}

write-commit -message "Update .cache"
if (-not $skipCommit) {
    & git push
}



