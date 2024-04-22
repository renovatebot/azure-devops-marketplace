# Azure DevOps Access

In order to generate the Azure DevOps cache files, this repo needs access to 2 things:

 1. The Azure DevOps Marketplace - to download all the published vsix files from which it can extract the available versions of each task.
 2. An Azure DevOps Organization - to query all the task versions that were published by Microsoft and ship as part of the Azure DevOps product. 

 And thus, the tasks need an access token to Azure DevOps with the following scopes:

  - `marketplace: read` - to download the published vsix files from the marketplace.
  - `agent pool: read` - to download the tasks from the Azure DevOps Organization.

  The token must be generated for the Azure DevOps organization which's agent pool will be queried.

  This information is stored in GitHub using Action secrets and variables:

   - Repository variable `AZURE_DEVOPS_ORG` contains the name of the Azure DevOps organization, e.g. `renovatebot-download`.
   - Repository secret `AZURE_DEVOPS_PAT` contains the Personal Access Token for a user with the above mentioned scopes and access to the organization.

   This token must be regenerated or renewed at least once a year.