param(
    # Azure SubscriptionId or Name
    [Parameter(Mandatory=$true)]
    [string] $Subscription,
    # TenantId or Name backing Azure Subscription
    [Parameter(Mandatory=$true)]
    [string] $TenantId,
	# Specifies the display name of the application
    [Parameter(Mandatory=$false)]
    [string] $AzureADApplicationName = 'AzureMonitorSplunkAddOn',
    # Name of Default Resource Group to contain Azure resources if not specified by EventHubResourceGroupName or KeyVaultResourceGroupName
    [Parameter(Mandatory=$false)]
    [string] $DefaultResourceGroupName = $AzureADApplicationName,
    # Location to create resources when not already present
    [Parameter(Mandatory=$true)]
    [string] $DefaultResourceLocation,
    # Name of Resource Group to contain Event Hub Namespace
    [Parameter(Mandatory=$false)]
    [string] $EventHubResourceGroupName = $DefaultResourceGroupName,
    # Name of EventHub Namespace
    [Parameter(Mandatory=$true)]
    [ValidatePattern("^[a-zA-Z][a-zA-Z0-9-]{4,48}[a-zA-Z0-9]$")]
    [string] $EventHubNamespaceName,
    # Name of Resource Group to contain Key Vault
    [Parameter(Mandatory=$false)]
    [string] $KeyVaultResourceGroupName = $DefaultResourceGroupName,
    # Name of Key Vault
    [Parameter(Mandatory=$true)]
    [ValidatePattern("^[a-zA-Z][a-zA-Z0-9-]{1,22}[a-zA-Z0-9]$")]
    [string] $KeyVaultName
)

# Note: The resource group name can be a new or existing resource group.

#################################################################
# Don't modify anything below unless you know what you're doing.
#################################################################
$ErrorActionPreference = "Stop"
$WarningPreference = "SilentlyContinue"

## Authenticate and Set Azure Context
$AzureRmContext = Get-AzureRmContext
if (!$AzureRmContext.Subscription -or $AzureRmContext.Subscription.Id -ne $Subscription) {
	Write-Host 'Please complete authentication in popup window.'
    Add-AzureRmAccount -Subscription $Subscription -TenantId $TenantId
    $AzureRmContext = Get-AzureRmContext
}

## Ensure Event Hub Namespace Exists
# Lookup Event Hub Namespace
Write-Host "Looking up event hub namespace '$EventHubNamespaceName' in resource group '$EventHubResourceGroupName'." -ForegroundColor Yellow
$eventHubNamespace = Get-AzureRmEventHubNamespace -ResourceGroupName $EventHubResourceGroupName -Name $EventHubNamespaceName -ErrorAction SilentlyContinue

# Create Event Hub (if needed)
if (!$eventHubNamespace) {
    Write-Host "Creating resource group '$EventHubResourceGroupName' in region '$DefaultResourceLocation'." -ForegroundColor Yellow
    $eventHubResourceGroup = New-AzureRmResourceGroup -Name $EventHubResourceGroupName -Location $DefaultResourceLocation -Force

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
    Write-Host "Creating resource group '$KeyVaultResourceGroupName' in region '$DefaultResourceLocation'." -ForegroundColor Yellow
    $keyVaultResourceGroup = New-AzureRmResourceGroup -Name $KeyVaultResourceGroupName -Location $DefaultResourceLocation -Force

    Write-Host "Creating Key Vault '$KeyVaultName' in resource group '$KeyVaultResourceGroupName'." -ForegroundColor Yellow
    $keyVault = New-AzureRmKeyVault -ResourceGroupName $keyVaultResourceGroup.ResourceGroupName `
                    -Location $keyVaultResourceGroup.Location -VaultName $KeyVaultName
}

# Key Vault Secret
Write-Host "- Setting default access policy for '$($AzureRmContext.Account.Id)'" -ForegroundColor Yellow
Set-AzureRmKeyVaultAccessPolicy -ResourceGroupName $keyVault.ResourceGroupName -VaultName $keyVault.VaultName `
    -UserPrincipalName $AzureRmContext.Account.Id `
    -PermissionsToSecrets get,list,set,delete,recover,backup,restore `
    -PermissionsToKey get,list,update,create,import,delete,recover,backup,restore


## Ensure Azure AD Application Registration
# Lookup Azure AD Application Registration
Write-Host "Looking up Azure AD Application '$AzureADApplicationName'." -ForegroundColor Yellow
$azureAdApp = Get-AzureRmADApplication -DisplayNameStartWith $AzureADApplicationName -ErrorAction SilentlyContinue | Where-Object DisplayName -EQ $AzureADApplicationName

# Create Azure AD Application Registration (if needed)
if (!$azureAdApp) {
    $splunkAzureADAppHomePage = "https://" + $AzureADApplicationName
    Write-Host "Creating a new Azure AD application registration named '$AzureADApplicationName'." -ForegroundColor Yellow
    $azureAdApp = New-AzureRmADApplication -DisplayName $AzureADApplicationName -HomePage $splunkAzureADAppHomePage `
                -IdentifierUris $splunkAzureADAppHomePage
}

# Create a new client secret / credential for the Azure AD App registration
$bytes = New-Object Byte[] 32
$rand = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$rand.GetBytes($bytes)
$clientSecret = [System.Convert]::ToBase64String($bytes)
$clientSecretSecured = ConvertTo-SecureString -String $clientSecret -AsPlainText -Force
$endDate = [System.DateTime]::Now.AddYears(1)
Write-Host "- Adding a client secret to Azure AD application '$($azureAdApp.DisplayName)'." -ForegroundColor Yellow
New-AzureRmADAppCredential -ApplicationId $azureAdApp.ApplicationId -Password $clientSecretSecured -EndDate $endDate | Out-Null

## Ensure Azure AD Service Principal associated with the Azure AD App
# Lookup Azure AD Service Principal
Write-Host "Looking up service principal for Azure AD application '$AzureADApplicationName'." -ForegroundColor Yellow
$azureAdSp = Get-AzureRmADServicePrincipal -SearchString $AzureADApplicationName -ErrorAction SilentlyContinue | Where-Object DisplayName -EQ $AzureADApplicationName

# Create Azure AD Service Principal (if needed)
if (!$azureAdSp) {
    Write-Host "Creating service principal for Azure AD application '$($azureAdApp.DisplayName)'" -ForegroundColor Yellow
    $azureAdSp = New-AzureRmADServicePrincipal -ApplicationId $azureAdApp.ApplicationId
}

## Ensure Azure Role Assignment for Azure AD Service Principal
# Lookup Azure Role Assignment
Write-Host "Adding service principal '$($azureAdSp.DisplayName)' to the Reader role for the subscription." -ForegroundColor Yellow
$roleAssignment = Get-AzureRmRoleAssignment -RoleDefinitionName "Reader" -Scope "/subscriptions/$Subscription" -ObjectId $azureAdSp.Id

# Create Azure Role Assignment (if needed)
if (!$roleAssignment) {
    $count = 0
    do {
        # Allow some time for the service principal to propogate throughout Azure AD
        Start-Sleep ($count++ * 10)
        $roleAssignment = New-AzureRmRoleAssignment -RoleDefinitionName "Reader" -Scope "/subscriptions/$Subscription" -ObjectId $azureAdSp.Id -ErrorAction SilentlyContinue
    } while (($roleAssignment -eq $null) -and ($count -le 5))
    
    if ($roleAssignment -eq $null) {
        Write-Error "Unable to assign service principal '$($azureAdSp.DisplayName) to Reader role for the subscription.  Stopping script execution."
    }
}

# Ensure the service principal permissions to retrieve secrets from the key vault
Write-Host "Assigning key vault 'read' permissions to secrets for service principal '$($azureAdSp.DisplayName)'" -ForegroundColor Yellow 
Set-AzureRmKeyVaultAccessPolicy -ResourceGroupName $keyVault.ResourceGroupName -VaultName $keyVault.VaultName `
    -PermissionsToSecrets "get" -ObjectId $azureAdSp.Id

# Add secrets to keyvault for event hub and REST API credentials
Write-Host "Adding secrets to event hub namespace" -ForegroundColor Yellow
$eventHubPrimaryKeySecured = ConvertTo-SecureString -String $eventHubRootKey.PrimaryKey -AsPlainText -Force
$eventHubCredentialsSecret = Set-AzureKeyVaultSecret -VaultName $keyVault.VaultName -Name "myEventHubCredentials" `
    -ContentType $eventHubRootKey.KeyName -SecretValue $eventHubPrimaryKeySecured
$restAPICredentialsSecret = Set-AzureKeyVaultSecret -VaultName $keyVault.VaultName -Name "myRESTAPICredentials" `
    -ContentType $azureAdSp.ApplicationId -SecretValue $clientSecretSecured

Write-Host "Azure configuration completed successfully!" -ForegroundColor Green

# Configure Splunk
# Settings needed to configure Splunk
$SplunkConfigPath = "$PSScriptRoot\$AzureADApplicationName" + ".splunkconfig" 

$SplunkConfig = @"
****************************"
*** SPLUNK CONFIGURATION ***"
****************************"

Data Input Settings for configuration as explained at https://github.com/Microsoft/AzureMonitorAddonForSplunk/wiki/Configuration-of-Splunk.

  AZURE MONITOR ACTIVITY LOG
  ----------------------------
  Name:               Azure Monitor Activity Log
  SPNTenantID:        $($AzureRmContext.Tenant.Id)
  SPNApplicationId:   $($azureADSP.ApplicationId)
  SPNApplicationKey:  $($clientSecret)
  eventHubNamespace:  $($eventHubNamespace.Name)
  vaultName:          $($keyVault.VaultName)
  secretName:         $($eventHubCredentialsSecret.Name)
  secretVersion:      $($eventHubCredentialsSecret.Version)

  AZURE MONITOR DIAGNOSTIC LOG
  ----------------------------
  Name:               Azure Monitor Diagnostic Log
  SPNTenantID:        $($AzureRmContext.Tenant.Id)
  SPNApplicationId:   $($azureADSP.ApplicationId)
  SPNApplicationKey:  $($clientSecret)
  eventHubNamespace:  $($eventHubNamespace.Name)
  vaultName:          $($keyVault.VaultName)
  secretName:         $($eventHubCredentialsSecret.Name)
  secretVersion:      $($eventHubCredentialsSecret.Version)

  AZURE MONITOR METRICS
  ----------------------------
  Name:               Azure Monitor Metrics
  SPNTenantID:        $($AzureRmContext.Tenant)
  SPNApplicationId:   $($azureADSP.ApplicationId)
  SPNApplicationKey:  $($clientSecret)
  SubscriptionId:     $($AzureRmContext.Subscription.Id)
  vaultName:          $($keyVault.VaultName)
  secretName:         $($restAPICredentialsSecret.Name)
  secretVersion       $($restAPICredentialsSecret.Version)
"@
Write-Host $SplunkConfig
Set-Content $SplunkConfigPath -Value $SplunkConfig -Encoding Unicode
