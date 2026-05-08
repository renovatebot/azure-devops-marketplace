$skipCache = $env:USE_CACHE -eq "false"
$skipCommit = $env:SKIP_COMMIT -eq "true"
$extensionListOnly = $env:EXTENSIONS_LIST_ONLY -eq "true"
$changedExtensionsFile = $env:CHANGED_EXTENSIONS_FILE

& git config --local user.email "jesse.houwing@gmail.com"
& git config --local user.name "Jesse Houwing"

$ErrorActionPreference = "Stop"

function Import-Extensions {
    [cmdletbinding()]
    Param (
        [int]$Page,
        [int]$PageSize,
        [AllowNull()][Nullable[DateTimeOffset]]$HighWatermark
    )

    function Get-ExtensionQueryErrorText {
        param (
            $ErrorRecord
        )

        $message = $ErrorRecord.Exception.Message

        if ($ErrorRecord.ErrorDetails.Message) {
            $message = $ErrorRecord.ErrorDetails.Message
        }
        elseif ($ErrorRecord.Exception.Response.Content) {
            $message = $ErrorRecord.Exception.Response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        }

        return $message
    }

    function Get-ExtensionQueryErrorMessage {
        param (
            $ErrorRecord
        )

        $message = Get-ExtensionQueryErrorText -ErrorRecord $ErrorRecord

        try {
            $errorResponse = $message | ConvertFrom-Json
            if ($errorResponse.message) {
                return $errorResponse.message
            }
        }
        catch {
            # Return the raw error message when the response is not JSON.
            Write-Verbose "Marketplace error response was not JSON."
        }

        return $message
    }

    function Test-IsNullReferenceException {
        param (
            $ErrorRecord
        )

        return (Get-ExtensionQueryErrorText -ErrorRecord $ErrorRecord) -match "NullReferenceException"
    }

    function Get-ExtensionQueryResult {
        param (
            $Extensions,
            $ResultMetaData,
            $SkippedExtensions
        )

        return [PSCustomObject]@{
            extensions        = @($Extensions)
            resultMetaData    = $ResultMetaData
            skippedExtensions = @($SkippedExtensions)
        }
    }

    function Invoke-ExtensionQuery {
        param (
            [int]$Page,
            [int]$PageSize
        )

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
            -Body "{`"assetTypes`":[],`"filters`":[{`"criteria`":[{`"filterType`":8,`"value`":`"Microsoft.VisualStudio.Services`"},{`"filterType`":8,`"value`":`"Microsoft.VisualStudio.Services.Integration`"},{`"filterType`":8,`"value`":`"Microsoft.VisualStudio.Services.Cloud`"},{`"filterType`":8,`"value`":`"Microsoft.TeamFoundation.Server`"},{`"filterType`":8,`"value`":`"Microsoft.TeamFoundation.Server.Integration`"},{`"filterType`":8,`"value`":`"Microsoft.VisualStudio.Services.Cloud.Integration`"},{`"filterType`":8,`"value`":`"Microsoft.VisualStudio.Services.Resource.Cloud`"},{`"filterType`":10,`"value`":`"target:\`"Microsoft.VisualStudio.Services\`" target:\`"Microsoft.VisualStudio.Services.Integration\`" target:\`"Microsoft.VisualStudio.Services.Cloud\`" target:\`"Microsoft.TeamFoundation.Server\`" target:\`"Microsoft.TeamFoundation.Server.Integration\`" target:\`"Microsoft.VisualStudio.Services.Cloud.Integration\`" target:\`"Microsoft.VisualStudio.Services.Resource.Cloud\`" `"},{`"filterType`":12,`"value`":`"37888`"}],`"direction`":2,`"pageSize`":$PageSize,`"pageNumber`":$Page,`"sortBy`":1,`"sortOrder`":0,`"pagingToken`":null}],`"flags`":870}" `
            -MaximumRetryCount 5 -RetryIntervalSec 10

        return ($result.Content | ConvertFrom-Json).results[0]
    }

    function Get-SplitPageSize {
        param (
            [int]$Page,
            [int]$PageSize
        )

        $offset = ($Page - 1) * $PageSize
        for ($candidate = [Math]::Floor($PageSize / 2); $candidate -ge 1; $candidate--) {
            if (($PageSize % $candidate -eq 0) -and ($offset % $candidate -eq 0)) {
                return $candidate
            }
        }

        return 1
    }

    function Test-ExtensionBelowHighWatermark {
        param (
            [object[]]$Extensions,
            [AllowNull()][Nullable[DateTimeOffset]]$HighWatermark
        )

        if (-not $HighWatermark) {
            return $false
        }

        foreach ($extension in $Extensions) {
            if ((Get-ExtensionLastUpdated -Extension $extension) -lt $HighWatermark) {
                return $true
            }
        }

        return $false
    }

    $maxRetries = 4
    $retryDelay = 15
    $attempt = 1
    $lastError = $null

    do {
        try {
            if ($attempt -gt 1) {
                Write-Output "Retrying web request (attempt $attempt of $maxRetries) for page $Page..."
                Start-Sleep -Seconds $retryDelay
            }

            $result = Invoke-ExtensionQuery -PageSize $PageSize -Page $Page

            # If we get here, the request succeeded
            return Get-ExtensionQueryResult -Extensions $result.extensions -ResultMetaData $result.resultMetaData -SkippedExtensions @()
        }
        catch {
            $lastError = $_
            Write-Output "Web request failed on attempt $attempt for page $Page`: $($_.Exception.Message)"

            if (Test-IsNullReferenceException -ErrorRecord $lastError) {
                Write-Output "NullReferenceException encountered for page $Page. Splitting the batch without further retries."
                break
            }

            $attempt++
        }
    } while ($attempt -le $maxRetries)

    if (-not (Test-IsNullReferenceException -ErrorRecord $lastError)) {
        Write-Error "Failed to retrieve data after $maxRetries attempts for page $Page. Last error: $(Get-ExtensionQueryErrorMessage -ErrorRecord $lastError)"
        throw $lastError
    }

    if ($PageSize -eq 1) {
        $position = (($Page - 1) * $PageSize) + 1
        return Get-ExtensionQueryResult -Extensions @() -ResultMetaData $null -SkippedExtensions @(
            [PSCustomObject]@{
                position = $position
                message  = Get-ExtensionQueryErrorMessage -ErrorRecord $lastError
            }
        )
    }

    $splitPageSize = Get-SplitPageSize -Page $Page -PageSize $PageSize
    $offset = ($Page - 1) * $PageSize
    $endOffset = $offset + $PageSize
    $extensions = @()
    $resultMetaData = $null
    $skippedExtensions = @()

    Write-Warning "NullReferenceException encountered for page $Page with page size $PageSize. Splitting the batch into smaller batches."
    for ($childOffset = $offset; $childOffset -lt $endOffset; $childOffset += $splitPageSize) {
        $childPage = [int](($childOffset / $splitPageSize) + 1)
        $childResult = Import-Extensions -PageSize $splitPageSize -Page $childPage -HighWatermark $HighWatermark
        $extensions += $childResult.extensions
        if (-not $resultMetaData -and $childResult.resultMetaData) {
            $resultMetaData = $childResult.resultMetaData
        }
        $skippedExtensions += $childResult.skippedExtensions

        if (Test-ExtensionBelowHighWatermark -Extensions $childResult.extensions -HighWatermark $HighWatermark) {
            break
        }
    }

    return Get-ExtensionQueryResult -Extensions $extensions -ResultMetaData $resultMetaData -SkippedExtensions $skippedExtensions
}

function Get-ExtensionCacheKey {
    [cmdletbinding()]
    [OutputType([string])]
    Param (
        $Extension
    )

    if ($Extension.extensionId) {
        return $Extension.extensionId
    }

    return "$($Extension.publisher.publisherName)/$($Extension.extensionName)"
}

function Get-ExtensionLastUpdated {
    [cmdletbinding()]
    [OutputType([DateTimeOffset])]
    Param (
        $Extension
    )

    if (-not $Extension.lastUpdated) {
        return [DateTimeOffset]::MinValue
    }

    return [DateTimeOffset]::Parse(
        $Extension.lastUpdated,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal
    )
}

function ConvertTo-ExtensionCacheEntry {
    [cmdletbinding()]
    [OutputType([object])]
    Param (
        $Extension
    )

    $cacheEntry = $Extension | Select-Object -Property * -ExcludeProperty versions, statistics, installationTargets, categories, tags
    $cacheEntry | Add-Member -MemberType NoteProperty -Name versions -Value @()
    $cacheEntry | Add-Member -MemberType NoteProperty -Name statistics -Value @()
    $cacheEntry | Add-Member -MemberType NoteProperty -Name installationTargets -Value @()
    $cacheEntry | Add-Member -MemberType NoteProperty -Name categories -Value @()
    $cacheEntry | Add-Member -MemberType NoteProperty -Name tags -Value @()

    return $cacheEntry
}

function Merge-ExtensionCache {
    [cmdletbinding()]
    [OutputType([object[]])]
    Param (
        $CachedExtension,
        $UpdatedExtension
    )

    $extensionByKey = @{}

    foreach ($extension in (@($CachedExtension) + @($UpdatedExtension))) {
        $extensionByKey[(Get-ExtensionCacheKey -Extension $extension)] = $extension
    }

    return @($extensionByKey.Values | Sort-Object -Property extensionId)
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

write-output "::group::Fetching Extension Metadata"
$pageSize = 100;
$page = 1
$totalFetched = 0
$max = 0
$extensions = @()
$extensionsToProcess = @()
$updatedExtensions = @()
$cacheFile = ".cache/extensions.json"
$changedExtensions = @()
mkdir -path ".cache" -Force | out-null
$cachedExtensions = @()
$highWatermark = $null

if (Test-Path -path $cacheFile -PathType Leaf) {
    $cachedExtensions = @(Get-Content -raw -Path $cacheFile | ConvertFrom-Json)
    $highWatermark = @($cachedExtensions | ForEach-Object { Get-ExtensionLastUpdated -Extension $_ } | Where-Object { $_ } | Sort-Object -Descending | Select-Object -First 1)[0]
}

if ((-not (Test-Path -path $cacheFile -PathType Leaf)) -or (-not $skipCache)) {
    if ($highWatermark) {
        write-output "Fetching extensions updated since $($highWatermark.ToString("o"))"
    }

    $stopPaging = $false
    do {
        $ProgressPreference = "silentlycontinue"
        $result = Import-Extensions -PageSize $pageSize -Page $page -HighWatermark $highWatermark
        $pageExtensions = @($result.extensions)
        $totalFetched += $pageExtensions.Count + $result.skippedExtensions.Count
        if ($result.resultMetaData) {
            $max = $result.resultMetaData[0].metadataItems[0].count
        }
        elseif ($max -eq 0) {
            Write-Error "Failed to retrieve extension metadata and could not determine the total extension count."
        }

        foreach ($skippedExtension in $result.skippedExtensions) {
            Write-Warning "Skipping extension at position $($skippedExtension.position)/$max. Marketplace error message: $($skippedExtension.message)"
        }

        $ProgressPreference = "continue"
        write-progress -activity "Fetching extension metadata" -status "Fetched $totalFetched of $max" -percentComplete (($totalFetched / $max) * 100)
        write-output "Fetching extension metadata | Fetched $totalFetched of $max"

        if ($highWatermark) {
            $pageExtensionsToProcess = @($pageExtensions | Where-Object { (Get-ExtensionLastUpdated -Extension $_) -ge $highWatermark })
            $updatedExtensions += $pageExtensionsToProcess
            if ($pageExtensionsToProcess.Count -lt $pageExtensions.Count) {
                $stopPaging = $true
            }
        }
        else {
            $updatedExtensions += $pageExtensions
        }

        $page += 1
    }
    while (($totalFetched -lt $max) -and (-not $stopPaging))

    # Remove properties that we don't need to prevent unwanted cache commits
    for ($index = 0; $index -lt $updatedExtensions.Count; $index++) {
        $updatedExtensions[$index] = ConvertTo-ExtensionCacheEntry -Extension $updatedExtensions[$index]
    }

    # Merge and sort the extensions to prevent unwanted cache commits
    $extensions = Merge-ExtensionCache -CachedExtension $cachedExtensions -UpdatedExtension $updatedExtensions
    $extensionsToProcess = @($updatedExtensions | Sort-Object -Property extensionId)
    $changedExtensions = $extensionsToProcess
    Set-Content -path $cacheFile -Value ($extensions | ConvertTo-Json -Depth 100)
    write-commit -message "Update extensions cache"
}
else {
    write-output "Using cached extension list"
    $extensions = $cachedExtensions
    if ($changedExtensionsFile -and (Test-Path -Path $changedExtensionsFile -PathType Leaf)) {
        $changedExtensionsJson = Get-Content -raw -Path $changedExtensionsFile
        if ([string]::IsNullOrWhiteSpace($changedExtensionsJson)) {
            $extensionsToProcess = @()
        }
        else {
            $extensionsToProcess = @($changedExtensionsJson | ConvertFrom-Json)
        }
        $changedExtensions = $extensionsToProcess
    }
    else {
        $extensionsToProcess = $extensions
    }
}
write-output "::endgroup::"

if ($changedExtensionsFile) {
    $changedExtensions | ConvertTo-Json -Depth 100 | Set-Content -Path $changedExtensionsFile
}

if ($extensionListOnly) {
    write-output "Skipping extension detail cache because EXTENSIONS_LIST_ONLY is true."
    return
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

$extensionsProcessed = 0
foreach ($extension in $extensionsToProcess) {
    $ProgressPreference = "continue"
    $publisherId = $extension.publisher.publisherName
    $extensionId = $extension.extensionName

    write-progress -activity "Processing extensions" -status "$extensionsProcessed - $($extensionsToProcess.count) | $publisherId/$extensionId" -percentComplete (($extensionsProcessed / $($extensionsToProcess.count)) * 100)
    write-output "Processing extensions | $extensionsProcessed - $($extensionsToProcess.count) | $publisherId/$extensionId"
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



