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

    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $result = Invoke-WebRequest -UseBasicParsing -Uri "https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery" `
        -Method "POST" `
        -WebSession $session `
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
        -Body "{`"assetTypes`":[`"Microsoft.VisualStudio.Services.Icons.Default`",`"Microsoft.VisualStudio.Services.Icons.Branding`",`"Microsoft.VisualStudio.Services.Icons.Small`"],`"filters`":[{`"criteria`":[{`"filterType`":8,`"value`":`"Microsoft.VisualStudio.Services`"},{`"filterType`":8,`"value`":`"Microsoft.VisualStudio.Services.Integration`"},{`"filterType`":8,`"value`":`"Microsoft.VisualStudio.Services.Cloud`"},{`"filterType`":8,`"value`":`"Microsoft.TeamFoundation.Server`"},{`"filterType`":8,`"value`":`"Microsoft.TeamFoundation.Server.Integration`"},{`"filterType`":8,`"value`":`"Microsoft.VisualStudio.Services.Cloud.Integration`"},{`"filterType`":8,`"value`":`"Microsoft.VisualStudio.Services.Resource.Cloud`"},{`"filterType`":10,`"value`":`"target:\`"Microsoft.VisualStudio.Services\`" target:\`"Microsoft.VisualStudio.Services.Integration\`" target:\`"Microsoft.VisualStudio.Services.Cloud\`" target:\`"Microsoft.TeamFoundation.Server\`" target:\`"Microsoft.TeamFoundation.Server.Integration\`" target:\`"Microsoft.VisualStudio.Services.Cloud.Integration\`" target:\`"Microsoft.VisualStudio.Services.Resource.Cloud\`" `"},{`"filterType`":12,`"value`":`"37888`"},{`"filterType`":5,`"value`":`"Azure Pipelines`"}],`"direction`":2,`"pageSize`":$PageSize,`"pageNumber`":$Page,`"sortBy`":2,`"sortOrder`":0,`"pagingToken`":null}],`"flags`":870}"

    return ($result.Content | ConvertFrom-Json).results[0];
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

if (-not (get-command -all "tfx"))
{
    & npm install tfx-cli@^0 -g --no-fund
}
$token = $env:AZURE_DEVOPS_PAT
$marketplace = "https://marketplace.visualstudio.com"
& tfx login --auth-type pat --token $token --service-url $marketplace --no-color --no-prompt

Write-host "::endgroup::"

Write-host "::group::Fetching Extension Metadata"
$skipCache = $env:USE_CACHE -ne "true"
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
        $result = Get-Extensions -PageSize $pageSize -Page $page
        $totalFetched += $result.extensions.Count
        
        $max = $result.resultMetaData[0].metadataItems[0].count
        $extensions += $result.extensions
        $page += 1
    }
    while ($totalFetched -lt $max)

    foreach ($extension in $extensions)
    {
        $extension.versions = $null
        $extension.statistics = $null
    }

    Set-Content -path $cacheFile -Value ($extensions | ConvertTo-Json -Depth 100)
    commit-changes -message "Update extensions cache"
}
else {
    $extensions = Get-Content -raw -Path $cacheFile | ConvertFrom-Json
}
Write-host "::endgroup::"

foreach ($extension in $extensions)
{
    $publisherId = $extension.publisher.publisherName
    $extensionId = $extension.extensionName
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
        $extensionData | ConvertTo-Json -Depth 100 | Set-Content -Path $extensionDataFile
        $shouldCommit = $true
    }
    
    foreach ($version in $extensionData.versions | ?{ $_.flags -eq 1 } )
    {
        $savePath = ".cache/$publisherId/$extensionId/$($version.version).vsix"
        $extractedPath = ".cache/$publisherId/$extensionId/$($version.version)/"
        $vsixUrl = $version.files | ?{ $_.assetType -eq "Microsoft.VisualStudio.Services.VSIXPackage" } | select -ExpandProperty source

        if (-not (Test-Path -Path $extractedPath -PathType Container))
        {
            write-host "$($version.version)"
            try{
                $ProgressPreference = "SilentlyContinue"
                Invoke-WebRequest -Uri $vsixUrl -OutFile $savePath
                (& 7z x $savePath "-o$extractedPath" "task.json" "extension.vsomanifest" -y -r -bd -aoa -spd -bb0) | out-null
                $shouldCommit = $true
            }finally{
                Remove-Item $savepath
            }
        }
    }

    if ($shouldCommit)
    {
        commit-changes -message "Update $publisherId/$extensionId"
    }
    write-host "::endgroup::"
}

if (-not $skipCommit)
{
    & git push
}