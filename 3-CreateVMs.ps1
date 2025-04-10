<#
.SYNOPSIS 
  This sample script is designed to start e deployment of lab environment VMs in Azure

.DESCRIPTION
  This script deploy:
  - 1 Virtual Network
  - 1 Network Security Group
  - 2 Public Ip Addresses
  - 2 Virtual Machines
  - Virtual Machine extensions
  - Data Collection Rule Associations

.REQUIREMENTS
  The following PowerShell modules are required:
    - AZ.RESOURCES

.NOTES
  AUTHOR:   Bruno Gabrielli
  LASTEDIT: January 9th, 2025

  - VERSION: 2.4 // January 9th, 2025
    - Removed unnecessary params and moved to fixed VM names

  - VERSION: 2.3 // August 29th, 2022
    - Added required PowerShell modules

  - VERSION: 2.2 // October 28th, 2021
    - Added working dir parameter to allow for start-job to run inside the current folder
#>

param(
  [Alias("rg", "RgName")]
  [Parameter(Mandatory = $True,
    ValueFromPipeline = $false,
    HelpMessage = 'Insert the ResourceGroupName')]
    [string]$ResourceGroupName,

  [Alias("wd", "WorkingDirectory")]
  [Parameter(Mandatory = $True,
    ValueFromPipeline = $false,
    HelpMessage = 'Insert the path of the working directory')]
    [string]$workingDir
)

# Deploying Azure VMs through template
New-AzResourceGroupDeployment -ResourceGroupName "$ResourceGroupName" -TemplateFile "$workingDir\deployVM.json" -TemplateParameterFile "$workingDir\deployVM.parameters.json"