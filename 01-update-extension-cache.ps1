$skipCache = $env:USE_CACHE -ne "true"
$skipCommit = $env:SKIP_COMMIT -eq "true"

& git config --local user.email "jesse.houwing@gmail.com"
& git config --local user.name "Jesse Houwing"

function Get-Extensions
{
    [cmdletbinding()]
    Param (
        [int]$Page,
        [int]$PageSize
    )

    $result = Invoke-WebRequest -UseBasicParsing -Uri "https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery" `
        -Method "POST" `
        -Headers @{
        "authority"="marketplace.visualstudio.com"
        "method"="POST"
        "path"="/_apis/public/gallery/extensionquery"
        "scheme"="https"
        "accept"="application/json;api-version=7.1-preview.1;excludeUrls=true"
        "accept-encoding"="gzip, deflate, br"
        "accept-language"="en-US,en;q=0.9"
        "cache-control"="no-cache"
        "origin"="https://marketplace.visualstudio.com"
        "x-vss-reauthenticationaction"="Suppress"
        } `
        -ContentType "application/json" `
        -Body "{`"assetTypes`":[],`"filters`":[{`"criteria`":[{`"filterType`":8,`"value`":`"Microsoft.VisualStudio.Services`"},{`"filterType`":8,`"value`":`"Microsoft.VisualStudio.Services.Integration`"},{`"filterType`":8,`"value`":`"Microsoft.VisualStudio.Services.Cloud`"},{`"filterType`":8,`"value`":`"Microsoft.TeamFoundation.Server`"},{`"filterType`":8,`"value`":`"Microsoft.TeamFoundation.Server.Integration`"},{`"filterType`":8,`"value`":`"Microsoft.VisualStudio.Services.Cloud.Integration`"},{`"filterType`":8,`"value`":`"Microsoft.VisualStudio.Services.Resource.Cloud`"},{`"filterType`":10,`"value`":`"target:\`"Microsoft.VisualStudio.Services\`" target:\`"Microsoft.VisualStudio.Services.Integration\`" target:\`"Microsoft.VisualStudio.Services.Cloud\`" target:\`"Microsoft.TeamFoundation.Server\`" target:\`"Microsoft.TeamFoundation.Server.Integration\`" target:\`"Microsoft.VisualStudio.Services.Cloud.Integration\`" target:\`"Microsoft.VisualStudio.Services.Resource.Cloud\`" `"},{`"filterType`":12,`"value`":`"37888`"}],`"direction`":2,`"pageSize`":$PageSize,`"pageNumber`":$Page,`"sortBy`":2,`"sortOrder`":0,`"pagingToken`":null}],`"flags`":870}"

    return ($result.Content | ConvertFrom-Json).results[0];
}

function normalize-taskmanifests
{
    [CmdletBinding()]
    param (
        $path
    )

    (Get-ChildItem -Path $path -Recurse -Filter "task.json" -File) | %{
        write-host $taskJsonFile.FullName
        $taskJsonFile = $_
        $taskJson = Get-Content -Path $taskJsonFile.FullName -Raw | ConvertFrom-Json -AsHashtable
        $result = [ordered]@{
            id = $taskJson.id
            name = $taskJson.name
            version = [ordered]@{
                Major = ($taskJson.version.Major ?? $taskJson.version.major ?? 0)
                Minor = ($taskJson.version.Minor ?? $taskJson.version.minor ?? 0)
                Patch = ($taskJson.version.Patch ?? $taskJson.version.patch ?? 0)
            }
            friendlyName = $taskJson.friendlyName
            description = $taskJson.description
            preview = $taskJson.preview ?? $false
            deprecated = $taskJson.deprecated ?? $false
            author = $taskJson.author
        }
        
        ConvertTo-Json -Depth 100 $result | Set-Content -Path $taskJsonFile.FullName
    }
}

function commit-changes
{
    [cmdletbinding()]
    Param (
        [string]$message
    )

    write-host "::group::Git commit: $message"

    & git add . | Out-Null
    (& git diff HEAD --exit-code) | Out-null
    if ($LASTEXITCODE -ne 0)
    {
        if ($skipCommit)
        {
            return
        }

        & git commit -m $message
    }

    write-host "::endgroup::"
}

Write-host "::group::Installing tfx"

if (-not (get-command -all "tfx" -ErrorAction SilentlyContinue))
{
    & npm install tfx-cli@^0 -g --no-fund
}
$token = $env:AZURE_DEVOPS_PAT
$marketplace = "https://marketplace.visualstudio.com"
& tfx login --auth-type pat --token $token --service-url $marketplace --no-color --no-prompt

Write-host "::endgroup::"

Write-host "::group::Fetching Extension Metadata"
$pageSize= 100;
$page = 1
$totalFetched = 0
$max = 0
$extensions = @()
$cacheFile = ".cache/extensions.json"
mkdir -path ".cache" -Force | out-null

if ((-not (Test-Path -path $cacheFile -PathType Leaf)) -or $skipCache)
{
    do
    {
        $ProgressPreference = "silentlycontinue"
        $result = Get-Extensions -PageSize $pageSize -Page $page
        $totalFetched += $result.extensions.Count
        $max = $result.resultMetaData[0].metadataItems[0].count

        $ProgressPreference = "continue"
        write-progress -activity "Fetching extension metadata" -status "Fetched $totalFetched of $max" -percentComplete (($totalFetched / $max) * 100)
        

        $extensions += $result.extensions
        $page += 1
    }
    while ($totalFetched -lt $max)

    # Remove properties that we don't need to prevent unwanted cache commits
    foreach ($extension in $extensions)
    {
        $extension.versions = @()
        $extension.statistics = @()
        $extension.installationTargets = @()
        $extension.categories = @()
        $extension.tags = @()
    }

    # Sort the extensions to prevent unwanted cache commits
    $extensions = $extensions | Sort-Object -Property extensionId
    Set-Content -path $cacheFile -Value ($extensions | ConvertTo-Json -Depth 100)
    commit-changes -message "Update extensions cache"
}
else {
    $extensions = Get-Content -raw -Path $cacheFile | ConvertFrom-Json
}
Write-host "::endgroup::"

$extensionsProcessed = 0
foreach ($extension in $extensions)
{
    $ProgressPreference = "continue"
    $publisherId = $extension.publisher.publisherName
    $extensionId = $extension.extensionName

    write-progress -activity "Processing extensions" -status "$extensionsProcessed - $max | $publisherId/$extensionId" -percentComplete (($extensionsProcessed / $max) * 100)
    $ProgressPreference = "silentlycontinue"
    $extensionsProcessed += 1
        
    $shouldCommit = $false

    Write-host "::group::$publisherId/$extensionId"
    mkdir -path ".cache/$publisherId/$extensionId/" -Force | out-null

    $extensionDataFile = ".cache/$publisherId/$extensionId/extension.json"
    $fetchExtensionData = $true
    if (Test-Path -Path $extensionDataFile -PathType Leaf)
    {
        $extensionData = gc -raw -Path $extensionDataFile | ConvertFrom-Json -Depth 100
        if ($extensionData.lastUpdated -le $extension.lastUpdated)
        {
            $fetchExtensionData = $false
        }
    }

    if ($fetchExtensionData)
    {
        $extensionData = (& tfx extension show --auth-type pat --token $token --service-url $marketplace --publisher $publisherId --extension-id $extensionId --json --no-color --no-prompt) | ConvertFrom-Json
        $extensionData.versions | %{ $_.files = $_.files | ?{ $_.assetType -in @("Microsoft.VisualStudio.Services.VSIXPackage", "Microsoft.VisualStudio.Services.VsixManifest") } }
        $extensionData | ConvertTo-Json -Depth 100 | Set-Content -Path $extensionDataFile
        $shouldCommit = $true
    }
    
    $extensionData.versions | ?{ $_.flags -eq 1 } | foreach-object -parallel {
        $version = $_
        $publisherId = $using:publisherId
        $extensionId = $using:extensionId
        
        $savePath = ".cache/$publisherId/$extensionId/$($version.version).vsix"
        $extractedPath = ".cache/$publisherId/$extensionId/$($version.version)/"
        $vsixUrl = ($version.files ?? @()) | ?{ $_.assetType -eq "Microsoft.VisualStudio.Services.VSIXPackage" } | select -ExpandProperty source
        $vsixManifestUrl = $version.files | ?{ $_.assetType -eq "Microsoft.VisualStudio.Services.VsixManifest" } | select -ExpandProperty source

        if (
            -not (Test-Path -Path $extractedPath -PathType Container) -or
            (-not $vsixManifestUrl -and -not (test-path -path "$extractedPath/extension.vsixmanifest" -PathType Leaf))
            )
        {
            write-host "Downloading VSIX: $($version.version)"
            try{
                Invoke-WebRequest -Uri $vsixUrl -OutFile $savePath
                (& 7z x $savePath "-o$extractedPath" "task.json" "extension.vsixmanifest" "extension.vsomanifest" -y -r -bd -aoa -spd -bb0) | out-null

                normalize-taskmanifests -path $extractedPath

                # For extensions that contain no tasks, make sure we commit the folder for caching
                if (-not (Test-Path -Path "$extractedPath/extension.vsomanifest" -PathType Leaf))
                {
                    mkdir $extractedPath -Force | out-null
                    Set-Content -path "$extractedPath/.completed" -value "true" -Force
                }
            }finally{
                Remove-Item $savepath
            }
        }

        if ($vsixManifestUrl -and (-not(test-path -path "$extractedPath/extension.vsixmanifest" -PathType Leaf)))
        {
            write-host "Downloading VSIX Manifest: $($version.version)"
            mkdir $extractedPath -Force | out-null
            Invoke-WebRequest -Uri $vsixManifestUrl -OutFile "$extractedPath/extension.vsixmanifest"
            Set-Content -path "$extractedPath/.completed" -value "true" -Force
        }
    }

    write-host "::endgroup::"
}

commit-changes -message "Update .cache"
if (-not $skipCommit)
{
    & git push
}