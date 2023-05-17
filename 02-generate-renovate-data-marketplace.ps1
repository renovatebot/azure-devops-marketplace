$skipCommit = $env:SKIP_COMMIT -eq "true"

$extensions = Get-Content -raw -Path ".cache/extensions.json" | ConvertFrom-Json

function add-version
{
    param (
        $name,
        $version
    )
    $name = $name.ToLowerInvariant()

    [string[]]$currentversions = $renovateData."$name"
    $currentversions += $version
    $renovateData."$name" = $currentversions
}

$renovateData = @{}
# Add the data needed for the unit tests.
add-version -name "automatedanalysis-marketplace" -version "0.198.0"
add-version -name "automatedanalysis-marketplace" -version "0.171.0"

$extensionsProcessed = 0

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
        $extensionManifest = get-content -raw $extensionManifestFile | ConvertFrom-Json -AsHashtable

        $taskContributions = $extensionManifest.contributions | where-object { $_.type -eq "ms.vss-distributed-task.task" }
        foreach ($taskContribution in $taskContributions)
        {
            $localpath = ".cache/$publisherId/$extensionId/$extensionVersion/$($taskContribution.properties.name)"

            $taskManifestFiles = Get-ChildItem -Path "$localpath/*" -Filter task.json -Recurse

            foreach ($taskManifestFile in $taskManifestFiles)
            {
                $taskManifestString = get-content -raw $taskManifestFile.FullName
                $taskManifest = $taskManifestString | ConvertFrom-Json -AsHashtable

                try {
                    $majorVersion = $taskManifest.version.Major
                }
                catch{
                    try {
                        $majorVersion = $taskManifest.version.major
                    }
                    catch {
                        $majorVersion = 0
                    }
                }
                try {
                    $minorVersion = $taskManifest.version.Minor
                }
                catch{
                    try {
                        $minorVersion = $taskManifest.version.minor
                    }
                    catch {
                        $minorVersion = 0
                    }
                }
                try {
                    $patchVersion = $taskManifest.version.Patch
                }
                catch{
                    try {
                        $patchVersion = $taskManifest.version.patch
                    }
                    catch {
                        $patchVersion = 0
                    }
                }

                $versionString = ([System.Version]"0$majorVersion.0$minorVersion.0$patchVersion").ToString()

                add-version -name "$($taskManifest.name)" -version $versionString
                add-version -name "$publisherId.$extensionId.$($taskContribution.id).$($taskManifest.name)" -version $versionString
                add-version -name "$($taskManifest.id)" -version $versionString
                add-version -name "$publisherId.$extensionId.$($taskContribution.id).$($taskManifest.id)" -version $versionString
            }
        }
    }
    write-output "::endgroup::"
}
write-progress -activity "Processing Extension" -Completed

# Sort the data to prevent unnecessary commits
$renovateDataSorted = [ordered]@{}
$renovateData.Keys | Sort-Object | foreach-object {
    $renovateDataSorted."$_" = [string[]]($renovateData."$_" | Sort-Object -Unique -Property @{ Exp = { [System.Version]$_ } })
  }

ConvertTo-Json $renovateDataSorted | Set-Content -Path "azure-pipelines-marketplace-tasks.json"

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