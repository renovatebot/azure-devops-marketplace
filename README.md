# renovate-azure-devops-marketplace

To allow Renovate to update Azure DevOps Marketplace extensions for Azure Pipelines, this repo generates a file with all versions of all tasks currently published to the Azure DevOps marketplace.

## Contents

### `01-update-extension-cache.ps1`

Refreshes the data in the `.cache` folder with the latest data from the Visual Studio Azure DevOps Marketplace.

### `.cache`

The `extensions.json` file contains a list of all public  extensions published in the Azure Pipelines category on the Visual Studio Azure DevOps Marketplace.

And a subfolder per publisher/extension for the manifest data for each extension. 

 * `extension.json` - the list of all versions of the extension ever published to the Azure DevOps Marketplace.

And then per version the data for that sepcific extension version.

 * `extension.vsomanifest` - the manifest data that contains the contribution-id for each task.
 * `task.json` - the manifest data for that specific task version.

### `02-generate-renovate-data.ps1`

Uses the data in the `.cache` folder to generate the datafile used by [renovatebot](https://github.com/renovatebot/renovate).

### `azure-pipelines-marketplace-tasks.json`

 The latest data file used by [renovatebot](https://github.com/renovatebot/renovate) to propose updates to your Azure Pipelines workflows.

## How is it used

The data in this repository is updated daily through a github action and the updated datafile is commited to this repository.

Renovatebot [downloads the datafile from this repository on a regular basis and updates the main reporitory](https://github.com/renovatebot/renovate/blob/main/tools/static-data/generate-azure-pipelines-marketplace-tasks.mjs). The [file used by the current version of renovatebot can be found here](https://github.com/renovatebot/renovate/blob/main/data/azure-pipelines-marketplace-tasks.json).