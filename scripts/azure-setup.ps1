param(
    # Parameter help description
    [Parameter(Mandatory=$false)]
    [string] $Subscription = '3818195e-8660-4d47-b256-99f49c384cc7',
    # Parameter help description
    [Parameter(Mandatory=$false)]
    [string] $TenantId = 'cc7d0b33-84c6-4368-a879-2e47139b7b1f',
	# Parameter help description
    [Parameter(Mandatory=$false)]
    [string] $AzureADApplicationName = 'AzureMonitorSplunkAddOn',
    # Parameter help description
    [Parameter(Mandatory=$false)]
    [string] $DefaultResourceGroupName = $AzureADApplicationName,
    # Parameter help description
    [Parameter(Mandatory=$false)]
    [string] $DefaultResourceGroupLocation = 'North Central US',
    # Parameter help description
    [Parameter(Mandatory=$false)]
    [string] $EventHubResourceGroupName = $DefaultResourceGroupName,
    # Parameter help description
    [Parameter(Mandatory=$false)]
    [string] $EventHubNamespaceName = 'spleh2',
    # Parameter help description
    [Parameter(Mandatory=$false)]
    [string] $KeyVaultResourceGroupName = $DefaultResourceGroupName,
    # Parameter help description
    [Parameter(Mandatory=$false)]
    [string] $KeyVaultName = 'splkv2'
)

# Variables used below
#$subscriptionId = "<Your Azure Subscription Id>"
#$tenantId = "<Your Azure AD Tenant Id>"
#$splunkResourceGroupName = "AzureMonitorSplunkAddOn"
#$splunkResourceGroupLocation = "North Central US"
# Note: The resource group name can be a new or existing resource group.

#################################################################
# Don't modify anything below unless you know what you're doing.
#################################################################
$ErrorActionPreference = "Stop"
$WarningPreference = "SilentlyContinue"

$azureSession = Login-AzureRmAccount -Subscription $Subscription -TenantId $TenantId

# Lookup AAD Application
Write-Host "Looking up Azure AD Application '$AzureADApplicationName'." -ForegroundColor Yellow
$azureAdApp = Get-AzureRmADApplication -DisplayNameStartWith $AzureADApplicationName -ErrorAction SilentlyContinue | Where-Object DisplayName -EQ $AzureADApplicationName

# Lookup AAD Service Principal
Write-Host "Looking up service principal for Azure AD application '$AzureADApplicationName'." -ForegroundColor Yellow
$azureAdSp = Get-AzureRmADServicePrincipal -SearchString $AzureADApplicationName -ErrorAction SilentlyContinue | Where-Object DisplayName -EQ $AzureADApplicationName

## Ensure Event Hub Namespace Exists
# Lookup Event Hub Namespace
Write-Host "Looking up event hub namespace '$EventHubNamespaceName' in resource group '$EventHubResourceGroupName'." -ForegroundColor Yellow
$eventHubNamespace = Get-AzureRmEventHubNamespace -ResourceGroupName $EventHubResourceGroupName -Name $EventHubNamespaceName -ErrorAction SilentlyContinue

# Create Event Hub (if needed)
if (!$eventHubNamespace) {
    Write-Host "Creating resource group '$EventHubResourceGroupName' in region '$DefaultResourceGroupLocation'." -ForegroundColor Yellow
    $eventHubResourceGroup = New-AzureRmResourceGroup -Name $EventHubResourceGroupName -Location $DefaultResourceGroupLocation -Force

    Write-Host "Creating event hub namespace '$EventHubNamespaceName' in resource group '$eventHubResourceGroupName'." -ForegroundColor Yellow
    $eventHubNamespace = New-AzureRmEventHubNamespace -ResourceGroupName $eventHubResourceGroup.ResourceGroupName `
                            -Location $eventHubResourceGroup.Location -Name $EventHubNamespaceName
}

# Event Hub Key
$eventHubRootKey = Get-AzureRmEventHubKey -ResourceGroupName $eventHubNamespace.ResourceGroup `
                        -Namespace $eventHubNamespace.Name -Name "RootManageSharedAccessKey"

## Ensure Key Vault Exists
# Lookup Key Vault
Write-Host "Looking up Key Vault '$KeyVaultName' in resource group '$KeyVaultResourceGroupName'." -ForegroundColor Yellow
$keyVault = Get-AzureRmKeyVault -ResourceGroupName $KeyVaultResourceGroupName -Name $KeyVaultName -ErrorAction SilentlyContinue

# Create Key Vault (if needed)
if (!$keyVault) {
    Write-Host "Creating resource group '$KeyVaultResourceGroupName' in region '$DefaultResourceGroupLocation'." -ForegroundColor Yellow
    $keyVaultResourceGroup = New-AzureRmResourceGroup -Name $KeyVaultResourceGroupName -Location $DefaultResourceGroupLocation -Force

    Write-Host "Creating Key Vault '$KeyVaultName' in resource group '$KeyVaultResourceGroupName'." -ForegroundColor Yellow
    $keyVault = New-AzureRmKeyVault -ResourceGroupName $keyVaultResourceGroup.ResourceGroupName `
                    -Location $keyVaultResourceGroup.Location -VaultName $KeyVaultName
}

# Key Vault Secret
Write-Host "- Setting default access policy for '$($azureSession.Context.Account.Id)'" -ForegroundColor Yellow
Set-AzureRmKeyVaultAccessPolicy -ResourceGroupName $keyVault.ResourceGroupName -VaultName $keyVault.VaultName `
    -UserPrincipalName $azureSession.Context.Account.Id `
    -PermissionsToSecrets get,list,set,delete,recover,backup,restore `
    -PermissionsToKey get,list,update,create,import,delete,recover,backup,restore


## Ensure Azure AD Application
if (!$azureADApp) {
    # Create an Azure AD App registration
    #$ticks = [DateTime]::UtcNow.Ticks
    #$AzureADApplicationName = "spladapp" + $ticks
    $splunkAzureADAppHomePage = "https://" + $AzureADApplicationName
    Write-Host "Creating a new Azure AD application registration named '$AzureADApplicationName'." -ForegroundColor Yellow
    $azureADApp = New-AzureRmADApplication -DisplayName $AzureADApplicationName -HomePage $splunkAzureADAppHomePage `
                -IdentifierUris $splunkAzureADAppHomePage
}

# Create a new client secret / credential for the Azure AD App registration
$bytes = New-Object Byte[] 32
$rand = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$rand.GetBytes($bytes)
$clientSecret = [System.Convert]::ToBase64String($bytes)
$clientSecretSecured = ConvertTo-SecureString -String $clientSecret -AsPlainText -Force
$endDate = [System.DateTime]::Now.AddYears(1)
Write-Host "- Adding a client secret to Azure AD application '$($azureADApp.DisplayName)'." -ForegroundColor Yellow
New-AzureRmADAppCredential -ApplicationId $azureADApp.ApplicationId -Password $clientSecretSecured -EndDate $endDate

## Ensure Azure AD Service Principal
if (!$azureAdSp) {
    # Create an Azure AD Service Principal associated with the Azure AD App
    Write-Host "Creating service principal for Azure AD application '$($azureADApp.DisplayName)'" -ForegroundColor Yellow
    $azureADSP = New-AzureRmADServicePrincipal -ApplicationId $azureADApp.ApplicationId
}

# Assign the service principal to the Reader role for the Azure subscription
Write-Host "Adding service principal '$($azureADSP.DisplayName)' to the Reader role for the subscription." -ForegroundColor Yellow
$count = 0
do {
    # Allow some time for the service principal to propogate throughout Azure AD
    Start-Sleep ($count++ * 10)
    $roleAssignment = New-AzureRmRoleAssignment -RoleDefinitionName "Reader" -Scope "/subscriptions/$Subscription" `
                        -ObjectId $azureADSP.Id -ErrorAction SilentlyContinue
} while (($roleAssignment -eq $null) -and ($count -le 5))

if ($roleAssignment -eq $null) {
    Write-Error "Unable to assign service principal '$($azureADSP.DisplayName) to Reader role for the subscription.  Stopping script execution."
}

# Give the service principal permissions to retrieve secrets from the key vault
Write-Host "Assigning key vault 'read' permissions to secrets for service principal '$($azureADSP.DisplayName)'" -ForegroundColor Yellow 
Set-AzureRmKeyVaultAccessPolicy -ResourceGroupName $keyVault.ResourceGroupName -VaultName $keyVault.VaultName `
    -PermissionsToSecrets "get" -ObjectId $azureADSP.Id

# Add secrets to keyvault for event hub and REST API credentials
Write-Host "Adding secrets to event hub namespace" -ForegroundColor Yellow
$eventHubPrimaryKeySecured = ConvertTo-SecureString -String $eventHubRootKey.PrimaryKey -AsPlainText -Force
$eventHubCredentialsSecret = Set-AzureKeyVaultSecret -VaultName $keyVault.VaultName -Name "myEventHubCredentials" `
    -ContentType $eventHubRootKey.KeyName -SecretValue $eventHubPrimaryKeySecured
$restAPICredentialsSecret = Set-AzureKeyVaultSecret -VaultName $keyVault.VaultName -Name "myRESTAPICredentials" `
    -ContentType $azureADSP.ApplicationId -SecretValue $clientSecretSecured

return

## Export Azure Monitor Data
# Create a new log profile to export activity log to event hub
Write-Host "Configuring Azure Monitor Activity Log to export to event hub '$eventHubNamespaceName'" -ForegroundColor Yellow
$logProfileName = "default"
$locations = (Get-AzureRmLocation).Location
$locations += "global"
$serviceBusRuleId = "/subscriptions/$subscriptionId/resourceGroups/$splunkResourceGroupName" + ` 
                    "/providers/Microsoft.EventHub/namespaces/$eventHubNamespaceName" + `
                    "/authorizationrules/RootManageSharedAccessKey"
Remove-AzureRmLogProfile -Name $logProfileName -ErrorAction SilentlyContinue
Add-AzureRmLogProfile -Name $logProfileName -Location $locations -ServiceBusRuleId $serviceBusRuleId 

Write-Host "Azure configuration completed successfully!" -ForegroundColor Green

# Configure Splunk
# Settings needed to configure Splunk
$transcriptPath = "$PSScriptRoot\$splunkResourceGroupName" + ".azureconfig" 
Start-Transcript -Path $transcriptPath -Append -Force

Write-Host ""
Write-Host "****************************"
Write-Host "*** SPLUNK CONFIGURATION ***"
Write-Host "****************************"
Write-Host ""
Write-Host "Data Input Settings for configuration as explained at https://github.com/Microsoft/AzureMonitorAddonForSplunk/wiki/Configuration-of-Splunk."
Write-Host ""
Write-Host "  AZURE MONITOR ACTIVITY LOG"
Write-Host "  ----------------------------"
Write-Host "  Name:               Azure Monitor Activity Log"
Write-Host "  SPNTenantID:       " $azureSession.Context.Tenant.Id
Write-Host "  SPNApplicationId:  " $azureADSP.ApplicationId
Write-Host "  SPNApplicationKey: " $clientSecret
Write-Host "  eventHubNamespace: " $eventHubNamespace.Name
Write-Host "  vaultName:         " $keyVault.VaultName
Write-Host "  secretName:        " $eventHubCredentialsSecret.Name
Write-Host "  secretVersion:     " $eventHubCredentialsSecret.Version
Write-Host ""
Write-Host "  AZURE MONITOR DIAGNOSTIC LOG"
Write-Host "  ----------------------------"
Write-Host "  Name:               Azure Monitor Diagnostic Log"
Write-Host "  SPNTenantID:       " $azureSession.Context.Tenant.Id
Write-Host "  SPNApplicationId:  " $azureADSP.ApplicationId
Write-Host "  SPNApplicationKey: " $clientSecret
Write-Host "  eventHubNamespace: " $eventHubNamespace.Name
Write-Host "  vaultName:         " $keyVault.VaultName
Write-Host "  secretName:        " $eventHubCredentialsSecret.Name
Write-Host "  secretVersion:     " $eventHubCredentialsSecret.Version
Write-Host ""
Write-Host "  AZURE MONITOR METRICS"
Write-Host "  ----------------------------"
Write-Host "  Name:               Azure Monitor Metrics"
Write-Host "  SPNTenantID:       " $azureSession.Context.Tenant
Write-Host "  SPNApplicationId:  " $azureADSP.ApplicationId
Write-Host "  SPNApplicationKey: " $clientSecret
Write-Host "  SubscriptionId:    " $azureSession.Context.Subscription
Write-Host "  vaultName:         " $keyVault.VaultName
Write-Host "  secretName:        " $restAPICredentialsSecret.Name
Write-Host "  secretVersion      " $restAPICredentialsSecret.Version
Write-Host ""

Stop-Transcript


