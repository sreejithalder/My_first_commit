<#
.SYNOPSIS
  This sample script is designed to build the lab environment for the Azure Monitor Advanced Analysis (AMAA) workshop

.DESCRIPTION
  This script builds-up an anvironment made of the following components:
    - Resource Group
    - Log Analytics workspace
    - Solutions: "Security"
    - Performance counters as defined in the accompaining PerfCounter.csv file
    - Windows Event log collection as defined in the accompaining EventLogs.csv file
    - Azure Automation Account
    - Diagnostic Settings for the Azure Automation Account (enabled)

.REQUIREMENTS
  The following PowerShell modules are required:
    - AZ.ACCOUNTS
    - AZ.RESOURCES
    - AZ.AUTOMATION
    - AZ.COMPUTE
    - AZ.MONITOR

.NOTES
  AUTHOR:   Bruno Gabrielli
  LASTEDIT: January 9th, 2025

  - VERSION: 3.7 // January 9th, 2025
    - Removed unnecessary params and moved to fixed VM names

  - VERSION: 3.6 // November 6th, 2024
    - Removed App Registration creation and role assignment to the DCR since we will upload the
      sample training data using the Azure user provided by LOD

  - VERSION: 3.5 // September 10th, 2024
    - Changed tag value for "WorkshopPLUS Name" to correctly show the new workshop name WorkshopPLUS - Azure Monitor Advanced Analysis
  
  - VERSION: 3.4 // January 18th, 2024
    - Changed parameter request to show Microsoft Entra ID instead of Azure Active Directory
      
  - VERSION: 3.3 // August 30th, 2022
    - Added required PowerShell modules
    - Forced the use of TLS1.2

  - VERSION: 3.2 // June 16th, 2022
    - Added creation custom table, DCE and DCR for custom data upload using DCR

  - VERSION: 3.1 // May 13th, 2022
    - Managed to create VM for available size in available region to prevent capacity issue during lab creation

  - VERSION: 3.0 // May 2nd, 2022
    - Removed creation of RunAs Accounts in favour of Managed Identity.
  
  - VERSION: 2.9 // January 10th, 2022
    - Added non-mandatory location parameter with the default value of westus2. If deployment fails in that region, students
    can re-run the script using the additional -Location parameter to specify a different location
    - Fixed the parameter value passed to the AddRunAsAccountfunction to correctly pass the SubscriptionId instead of the entire object

  - VERSION: 2.8 // November 05th, 2021
    - Made tenantId request for authentication the default behavior
  
  - VERSION: 2.7 // October 28th, 2021
    - Added parallelism by using start-job to run data ingestion and VM creation in parallel
#>


# Checking if PowerShell has been started with elevation (RunAs Admin)
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator"))
{ Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs; exit }  

# Preventing warning from breaking-changes
Set-Item Env:\SuppressAzurePowerShellBreakingChangeWarnings "true"

# Forcing PowerShell to use TLS1.2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Declaring and initializing constant & variables
[string]$nameFixPart = "AmaaLab"
[string]$resourceGroup = "rg-$nameFixPart"
[string]$workspaceName = "la-$nameFixPart"
[string]$role = "Monitoring Metrics Publisher"

# Clear all existing context
Clear-AzContext -force

# Requesting the Azure AD Tenant Id to authenticate against
$azTenantId = Read-Host -Prompt "Enter the Microsoft Entra ID tenant Id"

# Logging-in
Connect-AzAccount -WarningAction Ignore -TenantId $azTenantId | Out-Null
$Subscription = Get-AzSubscription -WarningAction Ignore | Where-Object { $_.State -eq "Enabled" } | Out-GridView -OutputMode Single -Title "Select your subscription"

# Selecting the subscription on which operate
Set-AzContext -WarningAction Ignore -Subscription $Subscription | Out-Null

# Silently registering the resource provider for Microsoft.Insights
Register-AzResourceProvider -ProviderNamespace "Microsoft.Insights" | Out-Null
Register-AzResourceProvider -ProviderNamespace "Microsoft.AlertsManagement" | Out-Null
Register-AzResourceProvider -ProviderNamespace "Microsoft.Automation" | Out-Null

#region CreatingAzureEnvironment

# Retrieving all existing locations excluding those where Automation Account to Workspace link is not supported
$allLocations = (Get-AzLocation).Location | Where-object { $_ -notin ("brazilsoutheast", "WestUS3", "canadaeast", "southindia", "westindia", "japanwest", "australiacentral", "australiacentral2", "koreasouth", "francesouth", "ukwest", "switzerlandwest", "uaecentral", "germanynorth", "germanywestcentral", "norwaywest", "swedencentral", "southafricanorth", "southafricawest") }

# Retrieving all existing VM Size based on 2 cores and 4Gb memory
Write-Host ("`nRetrieving the list of VM Size with 2 cores and 4Gb of memory")
$selectedSkuSize = Get-AZVMSize -Location "eastus" | Where-Object { $_.Name -match "Standard_[B2]" } | Where-Object { $_.NumberOfCores -eq 2 } | Where-Object { $_.MemoryInMB -in (4096) } | Select-Object -ExpandProperty Name | Sort-Object Name | Out-GridView -OutputMode Single -Title "Select one of the recommended the VM size"
Write-Host ("`tVM Size '$selectedSkuSize' has been selected.") -ForegroundColor Cyan

# Retrieving the regions where the selected VM Size is available
Write-Host ("`nRetrieving the regions where the selected VM size is available")
$selectedRegion = Get-AzComputeResourceSku | Where-Object { $_.ResourceType -eq "virtualmachines" } | Where-Object { $_.Locations -in $allLocations } | Where-Object { $_.Name -eq $selectedSkuSize } | Where-Object { [string]::IsNullOrEmpty($_.Restrictions) } | Select-Object -ExpandProperty Locations | Out-GridView -OutputMode Single -Title "Select the region with capacity for the selected VM Size"
Write-Host ("`tRegion '$selectedRegion' has been selected.") -ForegroundColor Cyan

# Updating parameter file accordingly
Write-Host ("`nUpdating parameter file with the selected VM Size")
$paramFile = Get-Content '.\deployVM.parameters.json' -raw | ConvertFrom-Json
$paramFile.parameters.vmSize.value = $selectedSkuSize
$paramFile | ConvertTo-Json -Depth 100 | Set-Content '.\deployVM.parameters.json' -Encoding UTF8

# Logging the script starting time
Write-Host ("=== BuildLabEnvironment_V2 script Started - '$(Get-Date -Format s)' ===") -ForegroundColor Green

# Create the resource group if needed
Write-Host "`nLooking for resource group '$resourceGroup'  in the '$selectedRegion' region ..."
try {
  # Checking if the RG already exists
  $newRg = (Get-AzResourceGroup -Name $resourceGroup -Location $selectedRegion -ErrorAction Stop)
  Write-Host "`tResource Group '$resourceGroup' is already existing in the '$selectedRegion' region. No need to create it." -ForegroundColor Yellow
}
catch {
  # If not, let's create the resource group
  Write-Host "`tCreating Resource Group '$resourceGroup'  in the '$selectedRegion' region ..." -ForegroundColor Cyan
  $newRg = New-AzResourceGroup -Name $resourceGroup -Location $selectedRegion -Tag @{"WorkshopPLUS Name" = "WorkshopPLUS - Azure Monitor Advanced Analysis"; "Scope" = "WorkshopPLUS" }
  if ($newRg.ProvisioningState -eq "Succeeded") {
    Write-Host "`t`tResource Group '$resourceGroup' in the '$selectedRegion' region was created successfully." -ForegroundColor Green
  }
  else {
    Write-Host "`t`tErrors encountered during resource group '$resourceGroup' creation." -ForegroundColor Red
  }
}

# Deploying workspace with solution, Data Sources and AutomationAccount
Write-Host "`nDeploying ARM template for workspace '$workspaceName' with solutions, Data Sources and Automation Account ..."

try {
  Write-Host "`tCreating Workspace '$workspaceName' in the '$selectedRegion' region ..." -ForegroundColor Cyan
  $newDeployment = (New-AzResourceGroupDeployment -ResourceGroupName $resourceGroup -TemplateFile ".\EnvDeploy.json" -TemplateParameterFile ".\EnvDeploy.parameters.json" -ErrorAction Stop)
  if ($newDeployment.ProvisioningState -eq "Succeeded") {
    $automationAccount = $newDeployment.Outputs.automationAccountName.Value
    Write-Host "`t`tWorkspace '$workspaceName' was created successfully." -ForegroundColor Green
    Write-Host "`t`tAutomation Account '$automationAccount' and the corresponding Managed Identity were created successfully. The Managed Identity was also granted Contributor role at the resource group level." -ForegroundColor Green

    #Getting current location
    $workingDir = (get-location).Path

    # Configuring the Diagnostic Setting for Automation Account with Log Analytics
    Write-Host "`n`tChecking Diagnostic Setting configuration for Automation Account '$automationAccount'in the '$selectedRegion' region ..." -ForegroundColor Cyan
    if (Get-AzDiagnosticSetting -ResourceId $($newDeployment.Outputs.automationAccountId.Value)) {
      Write-Host "`t`tDiagnostic Setting for Automation Account '$automationAccount' are already enabled. No need to enable them." -ForegroundColor Yellow
    }
    else {
      Write-Host "`t`tEnabling Diagnostic Settings for Automation Account '$automationAccount' in the '$selectedRegion' region ..." -ForegroundColor Cyan
            
      #Enabling DiagnosticSettings for Automation Account
      Set-AzDiagnosticSetting -ResourceId $($newDeployment.Outputs.automationAccountId.Value) -WorkspaceId $($newDeployment.Outputs.logAnalyticsWorkspaceResourceId.Value) -Enabled $true | Out-Null
      Write-Host "`t`tDiagnostic Settings for Automation Account '$automationAccount' were successfully enabled ." -ForegroundColor Green
    }

    Write-Host "`n`tCreating custom tables for both Perf and Security data ..." -ForegroundColor Cyan

    # Creating Performance table schema according to the data to be uploaded for custom log ingestion using DCR
    $perfTableParams = '{"properties":{"schema":{"name":"AmaaLab_Perf_CL","columns":[{"name":"TimeGenerated","type":"datetime","description":"TimeGenerated"},{"name":"DateValue","type":"datetime","description":"DateValue"},{"name":"Computer","type":"string","description":"Computer"},{"name":"ObjectName","type":"string","description":"ObjectName"},{"name":"CounterName","type":"string","description":"CounterName"},{"name":"InstanceName","type":"string","description":"InstanceName"},{"name":"CounterValue","type":"real","description":"CounterValue"}]}}}'
    Invoke-AzRestMethod -Path "$($newDeployment.Outputs.logAnalyticsWorkspaceResourceId.Value)/tables/AmaaLab_Perf_CL?api-version=2021-12-01-preview" -Method PUT -payload $perfTableParams | Out-Null

    # Creating Security table schema according to the data to be uploaded for custom log ingestion using DCR
    $secTableParams = '{"properties":{"schema":{"name":"AmaaLab_Security_CL","columns":[{"name":"TimeGenerated","type":"datetime","description":"TimeGenerated"},{"name":"DateValue","type":"datetime","description":"DateValue"},{"name":"Account","type":"string","description":"Account"},{"name":"AccountType","type":"string","description":"AccountType"},{"name":"Computer","type":"string","description":"Computer"},{"name":"EventSourceName","type":"string","description":"EventSourceName"},{"name":"Channel","type":"string","description":"Channel"},{"name":"Task","type":"int","description":"Task"},{"name":"Level","type":"string","description":"Level"},{"name":"EventData","type":"string","description":"EventData"},{"name":"EventID","type":"int","description":"EventID"},{"name":"Activity","type":"string","description":"Activity"},{"name":"AccessList","type":"string","description":"AccessList"},{"name":"AccessMask","type":"string","description":"AccessMask"},{"name":"AccountExpires","type":"string","description":"AccountExpires"},{"name":"AllowedToDelegateTo","type":"string","description":"AllowedToDelegateTo"},{"name":"AuthenticationPackageName","type":"string","description":"AuthenticationPackageName"},{"name":"CallerProcessId","type":"string","description":"CallerProcessId"},{"name":"CallerProcessName","type":"string","description":"CallerProcessName"},{"name":"DisplayName","type":"string","description":"DisplayName"},{"name":"ElevatedToken","type":"string","description":"ElevatedToken"}]}}}'
    Invoke-AzRestMethod -Path "$($newDeployment.Outputs.logAnalyticsWorkspaceResourceId.Value)/tables/AmaaLab_Security_CL?api-version=2021-12-01-preview" -Method PUT -payload $secTableParams | Out-Null

    Write-Host "`t`tCustom tables for both Perf and Security data created successfully" -ForegroundColor Green
      
    # Creating DCE and DCR and assigning permissions
    Write-Host "`n`tCreating Azure Monitor DCE and DCR for data ingestion ..." -ForegroundColor Cyan
    $CustomLogDeployment = (New-AzResourceGroupDeployment -ResourceGroupName $resourceGroup -TemplateFile ".\CustomLog.json" -TemplateParameterFile ".\CustomLog.parameters.json" -ErrorAction Stop)
    if ($CustomLogDeployment.ProvisioningState -eq "Succeeded") {
      Write-Host "`t`tAzure Monitor DCE and DCR created successfully" -ForegroundColor Green

      # Retrieving the logged user
      $loggedInUser = (Get-AzContext).Account.Id

      # Assigning Monitoring Metrics Publisher role to the logged user
      Write-Host "`n`tAssigning '$role' role to user '$loggedInUser' ..." -ForegroundColor Cyan
      New-AzRoleAssignment -SignInName $loggedInUser -RoleDefinitionName $role -Scope $($CustomLogDeployment.Outputs.resourceGroupId.Value) | Out-Null
      Write-Host "`t`tRole '$role' has been successfully assigned to user '$loggedInUser'." -ForegroundColor Green
      
      # Loading dummy Perf data into custom log
      Write-Host "`nInvoking LoadCustomData_V2 script with Perf data as background job - '$(Get-Date -Format s)' ..."
      Start-Job -Name "LoadCustomData_Perf" -FilePath ".\2-LoadCustomDataV2.ps1" -ArgumentList $($CustomLogDeployment.Outputs.amaaPerfDataDCRImmutableId.Value), $($CustomLogDeployment.Outputs.azMonDCE.value), 'dummyPerfData.csv', 'AmaaLab_Perf_CL', $workingDir, 3500 | Tee-Object -Variable out | Out-Null

      # Loading dummy Security data into custom log
      Write-Host "`nInvoking LoadCustomData_V2 script with Security data as background job - '$(Get-Date -Format s)' ..."
      Start-Job -Name "LoadCustomData_Security" -FilePath ".\2-LoadCustomDataV2.ps1" -ArgumentList $($CustomLogDeployment.Outputs.amaaSecDataDCRImmutableId.Value), $($CustomLogDeployment.Outputs.azMonDCE.value), 'dummySecData.csv', 'AmaaLab_Security_CL', $workingDir, 500 | Tee-Object -Variable out | Out-Null
    }
    else {
      Write-Host "`t`tAzure Monitor DCE and DCR were NOT created successfully" -ForegroundColor Red
    }

    # Creating VMs
    Write-Host "`nCreating Virtual Machines of size '$selectedSkuSize' in the '$selectedRegion' region as background job - '$(Get-Date -Format s)' ..."
    Start-Job -Name "Create_VMs" -FilePath ".\3-CreateVMs.ps1" -ArgumentList $resourceGroup, $workingDir | Tee-Object -Variable out | Out-Null

    # Waiting for jobs to complete
    Get-Job | Wait-Job
    if ($CustomLogDeployment.ProvisioningState -eq "Succeeded") {
      # Writing job output
      Receive-Job -Name LoadCustomData_Perf -Keep
      Write-Host "`n`nLoadCustomData_V2 script execution with Perf data completed - '$(Get-Date -Format s)'." -ForegroundColor Green
            
      Receive-Job -Name LoadCustomData_Security -Keep
      Write-Host "`n`nLoadCustomData_V2 script execution with Security data completed - '$(Get-Date -Format s)'." -ForegroundColor Green
    }

    Receive-Job -Name Create_VMs -Keep
    Write-Host "`n`nCreate_VMs script execution completed - '$(Get-Date -Format s)'." -ForegroundColor Green
        
    # Removing Jobs
    Get-Job | Remove-Job
  }
}
Catch {
  Write-Host "Exception occurred. Exception is: $_.Exception" -ForegroundColor Red
}

#endregion

# Logging the end of the script
Write-Host ("`n=== BuildLabEnvironment_V2 script completed - '$(Get-Date -Format s)' ===") -ForegroundColor Green

# End Of script