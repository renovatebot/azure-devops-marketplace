$ErrorActionPreference = "Stop"

$skipCommit = $env:SKIP_COMMIT -eq "true"

$org = $env:AZURE_DEVOPS_ORG
$pat = $env:AZURE_DEVOPS_PAT

$url = "https://dev.azure.com/$org"
$header = @{authorization = "Basic $([Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(".:$pat")))"}

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

if (Test-Path -Path "azure-pipelines-builtin-tasks-base.json")
{
    $renovateData = get-content -raw "azure-pipelines-builtin-tasks-base.json" | ConvertFrom-Json -AsHashtable
}
else 
{
    $renovateData = @{}
}
# Add the data needed for the unit tests.
add-version -name "automatedanalysis" -version "0.198.0"
add-version -name "automatedanalysis" -version "0.171.0"

$tasksResponse = Invoke-RestMethod -Uri "$url/_apis/distributedtask/tasks?allversions=true" -Method Get -ContentType "application/json" -Headers $header | ConvertFrom-Json -AsHashtable
$tasks = $tasksResponse.value

foreach ($task in $tasks)
{
    $majorVersion = $task.version.major
    $minorVersion = $task.version.minor
    $patchVersion = $task.version.patch
    $versionString = ([System.Version]"0$majorVersion.0$minorVersion.0$patchVersion").ToString()
    add-version -name "$($task.name)" -version $versionString
    add-version -name "$($task.id)" -version $versionString
}

# Sort the data to prevent unnecessary commits
$renovateDataSorted = [ordered]@{}
$renovateData.Keys | Sort-Object | foreach-object {
    $renovateDataSorted."$_" = [string[]]($renovateData."$_" | Sort-Object -Unique -Property @{ Exp = { [System.Version]$_ } })
  }

ConvertTo-Json $renovateDataSorted | Set-Content -Path "azure-pipelines-builtin-tasks.json"

if (-not $skipCommit)
{
    & git config --local user.email "jesse.houwing@gmail.com"
    & git config --local user.name "Jesse Houwing"
    & git add azure-pipelines-builtin-tasks.json
    & git diff HEAD --exit-code | Out-Null
    if ($LASTEXITCODE -ne 0)
    {
        & git commit -m "azure-pipelines-builtin-tasks.json"
        & git push
    }
}