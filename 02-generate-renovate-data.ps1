$extensions = Get-Content -raw -Path extensions.json | ConvertFrom-Json 
$max = $extensions.Count
$count = 0

function add-version
{
    param (
        $name,
        $version
    )

    if (-not $renovateData."$name")
    {
        $renovateData."$name" = [string[]]@()
    }
    
    [string[]]$currentversions = $renovateData."$name"
    $currentversions += $version
    $renovateData."$name" = $currentversions | Sort-Object -Unique
}

$renovateData = @{}

foreach ($extension in $extensions) {
    $publisherId = $extension.publisher.publisherName
    $extensionId = $extension.extensionName

    $extensionDataFile = "$publisherId/$extensionId/extension.json"
    if (-not (Test-Path -Path $extensionDataFile -PathType Leaf)) { continue }
    $extensionData = gc -raw "$publisherId/$extensionId/extension.json" | ConvertFrom-Json -AsHashtable

    foreach ($version in $extensionData.versions | ?{ $_.flags -eq 1 })
    {
        $extensionVersion = $version.version

        $extensionManifestFile = "$publisherId/$extensionId/$extensionVersion/extension.vsomanifest"
        if (-not (Test-Path -Path $extensionManifestFile -PathType Leaf)) { continue }
        $extensionManifest = gc -raw $extensionManifestFile | ConvertFrom-Json

        $taskContributions = $extensionManifest.contributions | ?{ $_.type -eq "ms.vss-distributed-task.task" }
        foreach ($taskContribution in $taskContributions)
        {
            $localpath = "$publisherId/$extensionId/$extensionVersion/$($taskContribution.properties.name)"
            
            $taskManifestFiles = Get-ChildItem -Path "$localpath/*" -Filter task.json

            foreach ($taskManifestFile in $taskManifestFiles)
            {
                $taskManifestString = gc -raw $taskManifestFile.FullName
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

                add-version -name "$publisherId.$extensionId.$($taskContribution.id).$($taskManifest.id)" -version $versionString
                add-version -name "$publisherId.$extensionId.$($taskContribution.id).$($taskManifest.name)" -version $versionString
                add-version -name "$($taskManifest.id)" -version $versionString
                add-version -name "$($taskManifest.name)" -version $versionString
            }
        } 
    }  
    
    
}

$renovateData | ConvertTo-Json -Depth 10 | Set-Content -Path "renovate-data.json"

& git config --local user.email "jesse.houwing@gmail.com"
& git config --local user.name "Jesse Houwing"
& git add .
& git diff HEAD --exit-code
if ($LASTEXITCODE -ne 0)
{    
    & git commit -m "Regenerating renovate-data.json"
    & git push
}