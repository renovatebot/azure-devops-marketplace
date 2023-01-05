# create a function in powershell that takes 2 parameters called page and pagesize
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
        -Body "{`"assetTypes`":[`"Microsoft.VisualStudio.Services.Icons.Default`",`"Microsoft.VisualStudio.Services.Icons.Branding`",`"Microsoft.VisualStudio.Services.Icons.Small`"],`"filters`":[{`"criteria`":[{`"filterType`":8,`"value`":`"Microsoft.VisualStudio.Services`"},{`"filterType`":8,`"value`":`"Microsoft.VisualStudio.Services.Integration`"},{`"filterType`":8,`"value`":`"Microsoft.VisualStudio.Services.Cloud`"},{`"filterType`":8,`"value`":`"Microsoft.TeamFoundation.Server`"},{`"filterType`":8,`"value`":`"Microsoft.TeamFoundation.Server.Integration`"},{`"filterType`":8,`"value`":`"Microsoft.VisualStudio.Services.Cloud.Integration`"},{`"filterType`":8,`"value`":`"Microsoft.VisualStudio.Services.Resource.Cloud`"},{`"filterType`":10,`"value`":`"target:\`"Microsoft.VisualStudio.Services\`" target:\`"Microsoft.VisualStudio.Services.Integration\`" target:\`"Microsoft.VisualStudio.Services.Cloud\`" target:\`"Microsoft.TeamFoundation.Server\`" target:\`"Microsoft.TeamFoundation.Server.Integration\`" target:\`"Microsoft.VisualStudio.Services.Cloud.Integration\`" target:\`"Microsoft.VisualStudio.Services.Resource.Cloud\`" `"},{`"filterType`":12,`"value`":`"37888`"},{`"filterType`":5,`"value`":`"Azure Pipelines`"}],`"direction`":2,`"pageSize`":$PageSize,`"pageNumber`":$Page,`"sortBy`":4,`"sortOrder`":0,`"pagingToken`":null}],`"flags`":870}"

    return ($result.Content | ConvertFrom-Json).results[0];
}

& npm install tfx-cli@^0 -g --no-fund

$pageSize= 100;
$page = 1
$totalFetched = 0
$max = 0
$extensions = @()
$cacheFile = "Extensions.json"
if (-not (Test-Path -path $cacheFile -PathType Leaf))
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

    Set-Content -path $cacheFile -Value ($extensions | ConvertTo-Json -Depth 100)
}
else {
    $extensions = Get-Content -raw -Path $cacheFile | ConvertFrom-Json
}

if ($max -eq 0)
{
    $max = $extensions.Count
}

$token = $env:AZURE_DEVOPS_PAT
$marketplace = "https://marketplace.visualstudio.com"
& tfx login --auth-type pat --token $token --service-url $marketplace --no-color --no-prompt

$count = 1
foreach ($extension in $extensions)
{
    $publisherId = $extension.publisher.publisherName
    $extensionId = $extension.extensionName
    
    mkdir -path "$publisherId/$extensionId/" -Force | out-null

    $extensionData = (& tfx extension show --auth-type pat --token $token --service-url $marketplace --publisher $publisherId --extension-id $extensionId --json --no-color --no-prompt) | ConvertFrom-Json
    $extensionData | ConvertTo-Json -Depth 100 | Set-Content -Path "$publisherId/$extensionId/extension.json"
    
    foreach ($version in $extensionData.versions | ?{ $_.flags -eq 1 } )
    {
        $savePath = "$publisherId/$extensionId/$($version.version).vsix"
        $extractedPath = "$publisherId/$extensionId/$($version.version)/"
        $vsixUrl = $version.files | ?{ $_.assetType -eq "Microsoft.VisualStudio.Services.VSIXPackage" } | select -ExpandProperty source

        if (-not (Test-Path -Path $extractedPath -PathType Container))
        {
            try{
                $ProgressPreference = "SilentlyContinue"
                Invoke-WebRequest -Uri $vsixUrl -OutFile $savePath
                (& 7z x $savePath "-o$extractedPath" "task.json" "extension.vsixmanifest" "extension.vsomanifest" -y -r -bd -aoa -spd -bb0) | out-null
            }finally{
                Remove-Item $savepath
            }
        }
    }

    & git config --local user.email "jesse.houwing@gmail.com"
    & git config --local user.name "Jesse Houwing"
    
    & git add .
    (& git diff HEAD --exit-code) | Out-null
    if ($LASTEXITCODE -ne 0)
    {
        & git commit -m "Update $publisherId/$extensionId"
        & git push
    }
    write-host "##### COUNT: $count / $max "
    $count += 1
}
