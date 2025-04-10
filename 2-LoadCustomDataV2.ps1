<#
.SYNOPSIS
  This sample script is designed to load dummy data from a csv file as custom log for the Azure Monitor Advanced Analysis (AMAA) workshop

.DESCRIPTION
  This script loads dummy data from a csv into a customLog called AmaaLab_CL. The csv file containing the data must use the comma (",") as delimiter.
  The csv file containing the data must be ordered based on the datevalue field either ascending or descending.
  The script will detect the order and will act as required (re-sorting desc if the file was sorted asc).

.REQUIREMENTS
  NONE

.NOTES
  AUTHOR:   Bruno Gabrielli
  LASTEDIT: January 9th, 2025

  - VERSION: 2.8 // January 9th, 2025
    - Removed unnecessary params and moved to fixed VM names

  - VERSION: 2.7 // November 6th, 2024
    - Removed App Registration creation and role assignment to the DCR since we will upload the
      sample training data using the Azure user provided by LOD
    - VERSION: 2.6 // August 30th, 2022
    - Forced use of TLS1.2
    - Managed the record count to be done only once instead of in the foreach loop
    - Removed the FQDN from the computer name and added the initials with no switch block

  - VERSION: 2.5 // June 16th, 2022
    - Added creation of AD Service Principal 
    - Modified script to upload using DCR.
    - Removed unnecessary code and parameters
  
  - VERSION: 2.4 // October 28th, 2021
    - Added working dir parameter to allow for start-job to run inside the current folder
#>

param(
  [Alias("cr", "ImmutableId")]
  [Parameter(Mandatory = $True,
    ValueFromPipeline = $false,
    HelpMessage = 'Enter the DCR Immutable Id.')]
    [string]$dcrImmutableId,

  [Alias("ce", "Endpoint")]
  [Parameter(Mandatory = $True,
    ValueFromPipeline = $false,
    HelpMessage = 'Enter the Data Collection Endpoint resource id.')]
    [string]$dceEndpoint,

  [Alias("df", "DummyFileName")]
  [Parameter(Mandatory = $True,
    ValueFromPipeline = $false,
    HelpMessage = 'Insert the dummy data file name (i.e. dummyPerfData.csv).')]
    [string]$dummyFile,

  [Alias("lt", "TableName")]
  [Parameter(Mandatory = $True,
    ValueFromPipeline = $false,
    HelpMessage = 'Insert the table name that will host the data (i.e. AmaaLab_Perf_CL).')]
    [string]$logType,

  [Alias("wd", "WorkingDirectory")]
  [Parameter(Mandatory = $True,
    ValueFromPipeline = $false,
    HelpMessage = 'Insert the path of the working directory.')]
    [string]$workingDir,

  [Alias("bs", "Size")]
  [Parameter(Mandatory = $True,
    ValueFromPipeline = $false,
    HelpMessage = 'Insert the number of record to be loaded every iteraction.')]
    [int]$batchSize

)

#region Functions

# Function to upload data
Function Upload-CustomData ($fDceEndpoint, $fDcrImmutableId, $fStreamName, $fDataBody) {
  # Adding required assembly
  Add-Type -AssemblyName System.Web

  # Retrieving bearer token for authentication for the Azure account provided by LOD
  $bearerToken = (Get-AzAccessToken -ResourceUrl 'https://monitor.azure.com/').Token

  # Send custom data to Log Analytics via DCE.
  $uploadHeaders = @{"Authorization" = "Bearer $bearerToken"; "Content-Type" = "application/json" }
  $uploadUri = "$fDceEndpoint/dataCollectionRules/$fDcrImmutableId/streams/$($fStreamName)?api-version=2021-11-01-preview"
  $uploadResponse = Invoke-RestMethod -Uri $uploadUri -Method "Post" -Body $fDataBody -Headers $uploadHeaders

  # Returning response code
  return $uploadResponse.StatusCode
}

#endregion

# Forcing PowerShell to use TLS1.2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Setting variables
[int]$round = 0
[int]$total = 0
[int]$i = 0
[int]$recTotal = 0

# Parsing table name to define the stram
Switch ($logType) {
  "AmaaLab_Perf_CL" {
    $streamName = "Custom-AmaaPerfRawData"
  }
    
  "AmaaLab_Security_CL" {
    $streamName = "Custom-AmaaSecurityRawData"
  }
}

# Loading data from CSV source
$dummyData = Import-Csv "$workingDir\$dummyFile" # -Delimiter ";"

#Sorting descending if necessary
if ($dummyData[0].DateValue -lt $dummyData[$($dummyData.Count - 1)].DateValue) {
  $dummyData = $dummyData | Sort-Object -Descending -Property DateValue
}

# Storing the total number of record from the input file
$recTotal = $dummyData.Count

# Creating empty array of records
$newDummyDataArray = [System.Collections.ArrayList]::new()

# Calculating the time difference since the first record.
# We also subtract 1 and then we add the difference so we will have always the last collection from yesterday back
$today = (Get-date -Format O).Split('T')[0]
$datePart = $dummyData[0].DateValue.split('T')[0]
[int]$diff = (([datetime]$today - [datetime]$datePart).Days) - 1

# Manipulating datetime and VM name
foreach ($rec in $dummyData) {
  # Assigning the new value to record field
  $rec.DateValue = Get-date(([datetime]$rec.DateValue).AddDays($diff).ToUniversalTime()) -Format O

  # Assigning the new VM name value accordingly, removing the domain part
  $rec.Computer = $rec.Computer.split(".")[0]

  # Adding the record to a new temporary array for posting in batches
  [void]$newDummyDataArray.Add($rec)
  $i++

  # Checking if we reached the batch size or the last record
  if (($i -eq $batchSize) -or (($total + $i) -eq $recTotal)) {
    [int]$round ++

    #Converting PSObject to JSON
    $dataBody = ConvertTo-Json -InputObject @($newDummyDataArray)

    # Submit the data to the API endpoint
    Write-Host "`n`tPosting batch round $round with $i records for a total of $($total + $i) out of $recTotal records" -ForegroundColor Cyan
    Write-Host "`t=================================================" -ForegroundColor Cyan

    $results = (Upload-CustomData -fDceEndpoint $dceEndpoint -fDcrImmutableId $dcrImmutableId -fStreamName $streamName -fDataBody $dataBody)

    # Exiting the loop since the upload was fine and preparing for another batch
    [int]$total = $total + $i
    [int]$i = 0
    $newDummyDataArray = [System.Collections.ArrayList]::new()
  }
}
            
# Logging the end of posting
Write-Host "`n`tLoading custom data to Azure Monitor completed." -ForegroundColor Green

# End of script