$ErrorActionPreference = "Stop"

$skipCommit = $env:SKIP_COMMIT -eq "true"
$count = 0
$extensions = Get-Content -raw -Path ".cache/extensions.json" | ConvertFrom-Json

function add-version
{
    param (
        [array]$names,
        [version]$version,
        $isdeprecated = $false,
        $isstable = $true,
        $homepage,
        $releaseTimeStamp,
        $downloadUrl
    )

    foreach ($name in $names)
    {
    $name = $name.ToLowerInvariant()

        $releaseResult = $renovateData."$name" ?? [ordered] @{
            releases = @()
        }

        $release = [ordered] @{
            version = $version.ToString()
        }

        if ($releaseTimeStamp)
        {
            $release.releaseTimeStamp = $releaseTimeStamp
        }

        if ($downloadUrl)
        {
            $release.downloadUrl = $downloadUrl
        }

        if ($isdeprecated)
        {
            $release.isDeprecated = $true
        }

        if (-not $isStable)
        {
            $release.isStable = $false
        }

        if ($repository)
        {
            if (-not $releaseResult.sourceUrl)
            {
                $releaseResult.sourceUrl = $repository
            }
            elseif ($releaseResult.sourceUrl -ne $repository)
            {
                $override = $true
                foreach ($knownVersion in $releaseResult.releases | %{ [version]$_.version } )
                {
                    if ($version -lt $knownVersion)
                    {
                        $override = $false
                        break
                    }
                }
                if ($override)
                {
                    $releaseResult.sourceUrl = $repositorys
                    foreach ($release in $releaseResult.releases)
                    {
                        if (($version -gt [version]$release.version) -and (-not $release.sourceUrl))
                        {
                            $release.sourceUrl = $repository
                        }
                    }
                }
                else
                {
                    if ($releaseResult.sourceUrl -ne $repository)
                    {
                        $release.sourceUrl = $repository
                    }
                }
            }
        }

        if ($homepage)
        {
            if (-not $releaseResult.homepage)
            {
                $releaseResult.homepage = $homepage
            }
            elseif ($releaseResult.homepage -ne $homepage)
            {
                $override = $true
                foreach ($knownVersion in $releaseResult.releases | %{ [version]$_.version } )
                {
                    if ($version -lt $knownVersion)
                    {
                        $override = $false
                        break
                    }
                }
                if ($override)
                {
                    $releaseResult.homepage = $homepage
                }
            }
        }

        [array]$releaseResult.releases += $release
        $releaseResult.releases = $releaseResult.releases

        $renovateData."$name" = $releaseResult
    }
}

$renovateData = @{}
# Add the data needed for the unit tests.
add-version -names @("automatedanalysis-marketplace") -version "0.198.0" -isstable $true
add-version -names @("automatedanalysis-marketplace") -version "0.171.0" -isstable $true

$extensionsProcessed = 1
$totalExtensions = $extensions.count
foreach ($extension in $extensions) {
    $publisherId = $extension.publisher.publisherName
    $extensionId = $extension.extensionName

    $ProgressPreference = "continue"
    $progress = @{
        Id               = 1
        Activity         = 'Processing Extensions    '
        Status           = "$extensionsProcessed - $totalExtensions | $publisherId/$extensionId"
        PercentComplete  = ($extensionsProcessed / $totalExtensions) * 100
        CurrentOperation = 'Extensions'
    }
    Write-Progress @progress
    $ProgressPreference = "silentlycontinue"
    $extensionsProcessed += 1

    Write-host "::group::$publisherId/$extensionId"

    $extensionDataFile = ".cache/$publisherId/$extensionId/extension.json"
    if (-not (Test-Path -Path $extensionDataFile -PathType Leaf)) { continue }
    $extensionData = gc -raw $extensionDataFile | ConvertFrom-Json

    $homepage = "https://marketplace.visualstudio.com/items?itemName=$publisherId.$extensionid"
    $extensionIsDeprecated = ($extension.displayName -like "*deprecated*") `
        -or ($extension.shortDescription -like "*deprecated*")

    $versionsProcessed = 1
    $versions = $extensionData.versions | ?{ $_.flags -eq 1 }
    $totalVersions = $versions.Count
    foreach ($version in $versions)
    {
        $extensionVersion = $version.version

        $ProgressPreference = "continue"
        $progress = @{
            Id               = 2
            Activity         = 'Processing Versions      '
            Status           = "$versionsProcessed - $totalVersions | $extensionVersion"
            PercentComplete  = ($versionsProcessed / $totalVersions) * 100
            CurrentOperation = 'Versions'
        }
        Write-Progress @progress
        $ProgressPreference = "silentlycontinue"
        $versionsProcessed += 1

        $extensionManifestFile = ".cache/$publisherId/$extensionId/$extensionVersion/extension.vsomanifest"
        if (-not (Test-Path -Path $extensionManifestFile -PathType Leaf)) { continue }
        $extensionVsixManifestFile = ".cache/$publisherId/$extensionId/$extensionVersion/extension.vsixmanifest"
        $extensionManifest = gc -raw $extensionManifestFile | ConvertFrom-Json -AsHashtable

        $taskContributions = $extensionManifest.contributions | ?{ $_.type -eq "ms.vss-distributed-task.task" }
        if ($taskContributions.Count -gt 0) {
            $extensionVsixManifest = [xml](gc -raw $extensionVsixManifestFile)
            $downloadUrl = $version.files | ?{ $_.assetType -eq "Microsoft.VisualStudio.Services.VSIXPackage" } | select -ExpandProperty source
            $repository = $extensionManifest.repository.uri
            $extensionIsPreview = ($extensionVsixManifest.PackageManifest.Metadata.GalleryFlags -like "*preview*")
            $releaseTimeStamp = $version.lastUpdated
        }

        $contributionsProcessed = 1
        $totalContributions = $taskContributions.Count

        foreach ($taskContribution in $taskContributions)
        {
            $ProgressPreference = "continue"
            $progress = @{
                Id               = 3
                Activity         = 'Processing Contributions'
                Status           = "$contributionsProcessed - $totalContributions | $($taskContribution.properties.name)"
                PercentComplete  = ($contributionsProcessed / $totalContributions) * 100
                CurrentOperation = 'Contributions'
            }
            Write-Progress @progress
            $ProgressPreference = "silentlycontinue"
            $contributionsProcessed += 1

            $localpath = ".cache/$publisherId/$extensionId/$extensionVersion/$($taskContribution.properties.name)"
            $taskManifestFiles = Get-ChildItem -Path "$localpath/*" -Filter task.json -Recurse

            foreach ($taskManifestFile in $taskManifestFiles)
            {
                $taskManifestString = get-content -raw $taskManifestFile.FullName
                $taskManifest = $taskManifestString | ConvertFrom-Json

                $majorVersion = $taskManifest.version.Major
                $minorVersion = $taskManifest.version.Minor
                $patchVersion = $taskManifest.version.Patch

                $versionString = ([System.Version]"$majorVersion.$minorVersion.$patchVersion").ToString()
                $isDeprecated = $extensionIsDeprecated -or ($taskManifest.deprecated) -or ($taskManifest.description -like "*\[deprecated\]*") -or ($taskManifest.friendlyName -like "*\[deprecated\]*")
                $isStable = -not (($taskManifest.preview) -or ($extensionIsPreview))

                $names = @(
                    "$($taskManifest.name)", 
                    "$publisherId.$extensionId.$($taskContribution.id).$($taskManifest.name)",
                    "$($taskManifest.id)",
                    "$publisherId.$extensionId.$($taskContribution.id).$($taskManifest.id)"
                )

                add-version -names $names `
                    -version $versionString `
                    -isDeprecated $isDeprecated `
                    -isStable $isStable `
                    -repository $repository `
                    -homepage $homepage `
                    -releaseTimestamp $releaseTimeStamp `
                    -downloadUrl $downloadUrl
            }
        }
    }
    write-output "::endgroup::"
}

# Sort the data to prevent unnecessary commits
$renovateDataSorted = [ordered]@{}

$renovateData.Keys | Sort-Object | foreach-object { 
    $renovateDataSorted."$_" = $renovateData."$_"
    $renovateDataSorted."$_".releases = $renovateDataSorted."$_".releases | Sort-Object -Unique -Property @{ Exp = { [System.Version]($_.version) } }
}

ConvertTo-Json $renovateDataSorted -Depth 5 | Set-Content -Path "azure-pipelines-marketplace-tasks.json" 

if (-not $skipCommit)
{
    & git config --local user.email "jesse.houwing@gmail.com"
    & git config --local user.name "Jesse Houwing"
    & git add azure-pipelines-marketplace-tasks.json
    & git diff HEAD --exit-code | Out-Null
    if ($LASTEXITCODE -ne 0)
    {
        & git commit -m "azure-pipelines-marketplace-tasks.json"
        & git push
    }
}