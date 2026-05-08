$skipCommit = $env:SKIP_COMMIT -eq "true"
$changedExtensionsFile = $env:CHANGED_EXTENSIONS_FILE
$fullGenerate = $env:FULL_GENERATE -eq "true"

if ($changedExtensionsFile -and (-not $fullGenerate) -and (Test-Path -Path $changedExtensionsFile -PathType Leaf)) {
    $changedExtensionsJson = Get-Content -raw -Path $changedExtensionsFile
    if ([string]::IsNullOrWhiteSpace($changedExtensionsJson)) {
        $extensions = @()
    }
    else {
        $extensions = @($changedExtensionsJson | ConvertFrom-Json)
    }
}
else {
    $extensions = @(Get-Content -raw -Path ".cache/extensions.json" | ConvertFrom-Json)
    $fullGenerate = $true
}

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

function add-extension-version
{
    param (
        $PublisherId,
        $ExtensionId,
        $TaskContributionId,
        $TaskName,
        $TaskId,
        $Version
    )

    add-version -name "$TaskName" -version $Version
    add-version -name "$PublisherId.$ExtensionId.$TaskContributionId.$TaskName" -version $Version
    add-version -name "$TaskId" -version $Version
    add-version -name "$PublisherId.$ExtensionId.$TaskContributionId.$TaskId" -version $Version
}

function get-extension-reference-keys
{
    param (
        $PublisherId,
        $ExtensionId
    )

    $prefix = "$PublisherId.$ExtensionId.".ToLowerInvariant()
    return @($renovateData.Keys | Where-Object { $_.ToLowerInvariant().StartsWith($prefix) })
}

if ($fullGenerate -or (-not (Test-Path -Path "azure-pipelines-marketplace-tasks.json" -PathType Leaf))) {
    $renovateData = @{}
    # Add the data needed for the unit tests.
    add-version -name "automatedanalysis-marketplace" -version "0.198.0"
    add-version -name "automatedanalysis-marketplace" -version "0.171.0"
}
else {
    $renovateData = Get-Content -raw -Path "azure-pipelines-marketplace-tasks.json" | ConvertFrom-Json -AsHashtable
}

$extensionsProcessed = 0

foreach ($extension in $extensions) {
    $publisherId = $extension.publisher.publisherName
    $extensionId = $extension.extensionName

    write-progress -activity "Processing Extension" -status "$extensionsProcessed - $($extensions.count) | $publisherId/$extensionId" -percentComplete (($extensionsProcessed / $extensions.count) * 100)
    $extensionsProcessed += 1


    write-output "::group::$publisherId/$extensionId"

    if (-not $fullGenerate) {
        foreach ($key in (get-extension-reference-keys -PublisherId $publisherId -ExtensionId $extensionId)) {
            $renovateData.Remove($key)
        }
    }

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

            $taskManifestFiles = Get-ChildItem -Path "$localpath/*" -Filter task.json -Recurse -ErrorAction SilentlyContinue

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

                try {
                    $versionString = ([System.Version]"0$majorVersion.0$minorVersion.0$patchVersion").ToString()

                    add-extension-version -PublisherId $publisherId -ExtensionId $extensionId -TaskContributionId $taskContribution.id -TaskName $taskManifest.name -TaskId $taskManifest.id -Version $versionString
                }
                catch {
                    write-output "Could not parse version for task $($taskManifest.name) in $publisherId/$extensionId version $extensionVersion"
                }
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
    }
}
