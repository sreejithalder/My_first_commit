<#
.SYNOPSIS
  This sample script is designed to remove the lab environment for the Azure Monitor Advanced Analysis (AMAA) workshop

.DESCRIPTION
  This script removes an anvironment made of the following components:
  - Log Analytics workspace
  - Resource Group and contained resources

.REQUIREMENTS
  The following PowerShell modules are required:
  - AZ.ACCOUNTS
  - AZ.RESOURCES
  - AZ.OPERATIONALINSIGHTS

.NOTES
  AUTHOR:   Bruno Gabrielli
  LASTEDIT: January 9th, 2025

  - VERSION: 2.0 // January 9th, 2025
    - Removed unnecessary params and moved to fixed VM names

  - VERSION: 1.5 // November 6th, 2024
    - Removed App Registration removal since we're not using it anymore

  - VERSION: 1.4 // January 18th, 2024
    - Changed parameter request to show Microsoft Entra ID instead of Azure Active Directory             

  - VERSION: 1.3 // August 29th, 2022
    - Added required PowerShell modules

  - VERSION: 1.2 // June 16th, 2022
    - Added removal of AD Service Principal
        
  - VERSION: 1.1 // March 18th, 2022
    - Fixed typo and script name in the output
        
  - VERSION: 1.0 // January 10th, 2022
    - First version
#>

# Preventing warning from breaking-changes
Set-Item Env:\SuppressAzurePowerShellBreakingChangeWarnings "true"

# Declaring and initializing constant & variables
[string]$nameFixPart = "AmaaLab"
[string]$resourceGroup = "rg-$nameFixPart"
[string]$workspaceName = "la-$nameFixPart"

# Clear all existing context
Clear-AzContext -force

# Requesting the Azure AD Tenant Id to authenticate against
$azTenantId = Read-Host -Prompt "Enter the Microsoft Entra ID tenant Id"

# Logging-in
Connect-AzAccount -WarningAction Ignore -TenantId $azTenantId | Out-Null
$Subscription = Get-AzSubscription -WarningAction Ignore | Where-Object { $_.State -eq "Enabled" } | Out-GridView -OutputMode Single -Title "Select your subscription"

# Selecting the subscription on which operate
Set-AzContext -WarningAction Ignore -Subscription $Subscription | Out-Null

Write-Host ("`n=== DestroyLabEnvironment_V2 script Started - '$(Get-Date -Format s)' ===") -ForegroundColor Green
try {
  $existingRg = (Get-AzResourceGroup -Name $resourceGroup -ErrorAction SilentlyContinue)
  if ($existingRg) {
        
    # Permanently deleting the workspace
    Write-Host "`n`tRemoving the workspace '$workspaceName' ..."
    Remove-AzOperationalInsightsWorkspace -ResourceGroupName "$resourceGroup" -Name "$workspaceName"-ForceDelete -Force -ErrorAction Stop
    Write-Host "`t`tWorkspace '$workspaceName' was permanently removed." -ForegroundColor Green
        
    # Deleting the resource group and all contained resources
    Write-Host "`n`tRemoving the resource group '$resourceGroup' and all contained resources ..."
    Remove-AzResourceGroup -Name $resourceGroup -Force -ErrorAction Stop
    Write-Host "`t`tResource Group '$resourceGroup' and all contained resources were removed successfully." -ForegroundColor Green
  }
  else {
    Write-Host "`t`tResource Group '$resourceGroup' is not existing in the selected subscription." -ForegroundColor Yellow
  }
}
catch {
  Write-Host "`t`tAn error occurred while removing resource Group '$resourceGroup' and all contained resources. Some of the resources were NOT removed successfully." -ForegroundColor Red
}

# Logging the end of the script
Write-Host ("`n=== DestroyLabEnvironment_V2 script completed - '$(Get-Date -Format s)' ===`n") -ForegroundColor Green

# End Of script