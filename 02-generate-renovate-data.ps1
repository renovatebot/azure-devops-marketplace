$skipCommit = $env:SKIP_COMMIT -eq "true"

$extensions = Get-Content -raw -Path ".cache/extensions.json" | ConvertFrom-Json

function add-version
{
    param (
        $names,
        $version,
        $isdeprecated = $false,
        $isstable = $true,
        $homepage
    )
    foreach ($name in $names)
    {
    $name = $name.ToLowerInvariant()

        $v = [ordered]@{
            version = $version
        }

        if ($isdeprecated)
        {
            $v.isDeprecated = $true
        }

        if (-not $isStable)
        {
            $v.isStable = $false
        }

        if ($repository)
        {
            $v.sourceUrl = $repository
        }

        if ($homepage)
        {
            $v.homepage = $homepage
        }

        [array]$currentversions = $renovateData."$name"
        $currentversions += $v
    $renovateData."$name" = $currentversions
    }
}

$renovateData = @{}
# Add the data needed for the unit tests.
add-version -names @("automatedanalysis-marketplace") -version "0.198.0" -isstable $true
add-version -names @("automatedanalysis-marketplace") -version "0.171.0" -isstable $true

foreach ($extension in $extensions) {
    $publisherId = $extension.publisher.publisherName
    $extensionId = $extension.extensionName
    write-progress -activity "Processing Extension" -status "$extensionsProcessed - $($extensions.count) | $publisherId/$extensionId" -percentComplete (($extensionsProcessed / $extensions.count) * 100)
    $extensionsProcessed += 1
    write-output "::group::$publisherId/$extensionId"

    $extensionDataFile = ".cache/$publisherId/$extensionId/extension.json"
    if (-not (Test-Path -Path $extensionDataFile -PathType Leaf)) { continue }
    $extensionData = get-content -raw $extensionDataFile | ConvertFrom-Json -AsHashtable

    $versions = $extensionData.versions | where-object { $_.flags -eq 1 }
    foreach ($version in $versions)
    {
        $extensionVersion = $version.version
        write-output "Processing version $extensionVersion"

        $extensionManifestFile = ".cache/$publisherId/$extensionId/$extensionVersion/extension.vsomanifest"
        if (-not (Test-Path -Path $extensionManifestFile -PathType Leaf)) { continue }
        $extensionVsixManifestFile = ".cache/$publisherId/$extensionId/$extensionVersion/extension.vsixmanifest"
        $extensionManifest = gc -raw $extensionManifestFile | ConvertFrom-Json -AsHashtable
        $extensionVsixManifest = [xml](gc -raw $extensionVsixManifestFile)

        $taskContributions = $extensionManifest.contributions | where-object { $_.type -eq "ms.vss-distributed-task.task" }
        foreach ($taskContribution in $taskContributions)
        {
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

                $isDeprecated = ($taskManifest.deprecated) -or ($taskManifest.description -like "*deprecated*")
                $isStable = -not ($taskManifest.preview -or ($extensionVsixManifest.PackageManifest.Metadata.GalleryFlags -like "*preview*"))
                $repository = $extensionManifest.repository.uri
                $homepage = "https://marketplace.visualstudio.com/items?itemName=$publisherId.$extensionid"

                $names = @(
                    "$($taskManifest.name)", 
                    "$publisherId.$extensionId.$($taskContribution.id).$($taskManifest.name)",
                    "$($taskManifest.id)",
                    "$publisherId.$extensionId.$($taskContribution.id).$($taskManifest.id)"
                )

                add-version -names $names -version $versionString -isDeprecated $isDeprecated -isStable $isStable -repository $repository -homepage $homepage
            }
        }
    }
    write-output "::endgroup::"
}

# Sort the data to prevent unnecessary commits
$renovateDataSorted = [ordered]@{}
$renovateData.Keys | Sort-Object | ForEach-Object { 
    $renovateDataSorted."$_" = ($renovateData."$_" | Sort-Object -Unique -Property @{ Exp = { [System.Version]($_.version) } })
}

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