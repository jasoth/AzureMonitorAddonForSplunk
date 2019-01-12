<#
.SYNOPSIS
    Configure Azure Monitor to send monitor data to storage account, event hub, and/or log analytics.
.EXAMPLE
    PS C:\> azure-setup-monitors.ps1 -Subscription 00000000-0000-0000-0000-000000000000 -TenantId 00000000-0000-0000-0000-000000000000 -ResourceGroupName "AzureMonitorData" -StorageAcctName "MyData" -StorageAcctRetentionInDays 90 -EventHubNamespaceName "MyData" -LogAnalyticsWorkspaceName "MyData"
    Configures Azure Monitor to send monitor data to storage account, event hub, and log analytics.
#>
param(
    # Azure SubscriptionId or Name.
    [Parameter(Mandatory=$true)]
    [string] $Subscription,
    # TenantId or Name backing Azure Subscription.
    [Parameter(Mandatory=$true)]
    [string] $TenantId,
    # Specifies the name of the Azure Monitor profiles.
    [Parameter(Mandatory=$false)]
    [string] $MonitorProfileName = 'default',
    # Azure Providers to Monitor.
    [Parameter(Mandatory=$false)]
    [string[]] $MonitorProviders = @('microsoft.insights','microsoft.aadiam','Microsoft.SecurityGraph'),
    # Resource Group to contain Azure storage, event hub, and/or log analytics. This is overridden by StorageAcctResourceId, EventHubAuthorizationRuleResourceId, and LogAnalyticsWorkspaceResourceId parameters. If it does not exist, it will be created.
    [Parameter(Mandatory=$false)]
    [string] $ResourceGroupName,
    # Azure storage account name to archive data. This is overridden by StorageAcctResourceId parameters.
    [Parameter(Mandatory=$false)]
    [string] $StorageAcctName,
    # Retention policy in days for monitor data in storage account.
    [Parameter(Mandatory=$false)]
    [int] $StorageAcctRetentionInDays,
    # Azure Storage account resourceId to archive data. This overrides ResourceGroupName and StorageAcctName parameters.
    [Parameter(Mandatory=$false)]
    [string] $StorageAcctResourceId,
    # Azure event hub namespace. This is overridden by EventHubAuthorizationRuleResourceId parameters.
    [Parameter(Mandatory=$false)]
    [string] $EventHubNamespaceName,
    # Authorization Rule use by Azure Monitor to push data to event hub. Must contain Manage permission.
    [Parameter(Mandatory=$false)]
    [string] $EventHubAuthorizationRuleName = "RootManageSharedAccessKey",
    # Azure event hub authorization rule resourceId to stream data. This overrides ResourceGroupName, EventHubNamespaceName, and EventHubAuthorizationRuleName parameters.
    [Parameter(Mandatory=$false)]
    [string] $EventHubAuthorizationRuleResourceId,
    # Azure log analytics workspace name. This is overridden by LogAnalyticsWorkspaceResourceId parameters.
    [Parameter(Mandatory=$false)]
    [string] $LogAnalyticsWorkspaceName,
    # Azure log analytics workspace resourceId to send data. This overrides ResourceGroupName and LogAnalyticsWorkspaceName parameters.
    [Parameter(Mandatory=$false)]
    [string] $LogAnalyticsWorkspaceResourceId
)

if (!$StorageAcctResourceId -and $ResourceGroupName -and $StorageAcctName) { $StorageAcctResourceId = "/subscriptions/$Subscription/resourceGroups/$ResourceGroupName/providers/Microsoft.Storage/storageAccounts/$StorageAcctName" }
if (!$EventHubAuthorizationRuleResourceId -and $ResourceGroupName -and $EventHubNamespaceName) { $EventHubAuthorizationRuleResourceId = "/subscriptions/$Subscription/resourceGroups/$ResourceGroupName/providers/Microsoft.EventHub/namespaces/$EventHubNamespaceName/authorizationrules/$EventHubAuthorizationRuleName" }
if (!$LogAnalyticsWorkspaceResourceId -and $ResourceGroupName -and $LogAnalyticsWorkspaceName) { $LogAnalyticsWorkspaceResourceId = "/subscriptions/$Subscription/resourceGroups/$ResourceGroupName/providers/Microsoft.OperationalInsights/workspaces/$LogAnalyticsWorkspaceName" }

## Authenticate and Set Azure Context
try {
    $AzureRmContext = Get-AzureRmContext  # Check for existing context
    if ($AzureRmContext) {
        if ($AzureRmContext.Subscription.Id -ne $Subscription) {
            [void](Select-AzureRmSubscription -Subscription $Subscription -Tenant $TenantId)
        }
        [void](Get-AzureRmDefault -ErrorAction Stop)
    }
    else { throw "No default context" }
}
catch {
    Write-Host 'Please complete authentication in popup window.'
    Connect-AzureRmAccount -Subscription $Subscription -TenantId $TenantId -ErrorAction Stop
}
$AzureRmContext = Get-AzureRmContext

function New-DiagnosticSettingsConfig {
    param (
        # Specifies the name of the Azure Monitor profiles
        [Parameter(Mandatory=$true, Position=1)]
        [string] $Provider,
        # Names of Azure Monitor categories to enable.
        [Parameter(Mandatory=$false)]
        [string[]] $Categories,
        # Azure Storage account resourceId to archive data.
        [Parameter(Mandatory=$false)]
        [string] $StorageAcctResourceId,
        # Retention policy in days for monitor data in storage account.
        [Parameter(Mandatory=$false)]
        [int] $StorageAcctRetentionInDays,
        # Azure event hub authorization rule resourceId to stream data.
        [Parameter(Mandatory=$false)]
        [string] $EventHubAuthorizationRuleResourceId,
        # Azure log analytics workspace resourceId to send data.
        [Parameter(Mandatory=$false)]
        [string] $LogAnalyticsWorkspaceResourceId
    )

    [psobject[]] $allCategories = Get-AzureRmResource -ApiVersion '2017-04-01-preview' -ResourceId "providers/$Provider/diagnosticSettingsCategories"
    if ($Categories) { $allCategories = $allCategories | Where-Object Name -In $Categories }
    [string[]] $logCategories = $allCategories | Where-Object { $_.Properties.categoryType -eq "Logs" } | Select-Object -ExpandProperty Name
    [string[]] $metricCategories = $allCategories | Where-Object { $_.Properties.categoryType -eq "Metrics" } | Select-Object -ExpandProperty Name

    [hashtable] $DiagnosticSettings = @{}
    if ($StorageAcctResourceId) { $DiagnosticSettings['storageAccountId'] = $StorageAcctResourceId }
    if ($LogAnalyticsWorkspaceResourceId) { $DiagnosticSettings['workspaceId'] = $LogAnalyticsWorkspaceResourceId }
    if ($EventHubAuthorizationRuleResourceId) { $DiagnosticSettings['eventHubAuthorizationRuleId'] = $EventHubAuthorizationRuleResourceId }

    # Add Log Catagories
    $listLogCatagories = New-Object System.Collections.Generic.List[psobject]
    foreach ($CategoryName in $logCategories) {
        $Catagory = @{
            category = $CategoryName
            enabled = $true
        }
        if ($StorageAcctResourceId) {
            $Catagory['retentionPolicy'] = @{
                enabled = ([bool]$StorageAcctRetentionInDays)
                days = $StorageAcctRetentionInDays
            }
        }
        $listLogCatagories.Add($Catagory)
    }
    if ($listLogCatagories) { $DiagnosticSettings['logs'] = $listLogCatagories.ToArray() }

    ## Add Metric Catagories
    $listMetricCatagories = New-Object System.Collections.Generic.List[psobject]
    foreach ($CategoryName in $metricCategories) {
        $Catagory = @{
            timeGrain = "PT1M"
            enabled = $true
        }
        if ($StorageAcctResourceId) {
            $Catagory['retentionPolicy'] = @{
                enabled = ([bool]$StorageAcctRetentionInDays)
                days = $StorageAcctRetentionInDays
            }
        }
        $listMetricCatagories.Add($Catagory)
    }
    if ($listMetricCatagories) { $DiagnosticSettings['metrics'] = $listMetricCatagories.ToArray() }

    return $DiagnosticSettings
}

## Export Azure Monitor Activity & Diagnostic Data
foreach ($MonitorProvider in $MonitorProviders) {
    if ($MonitorProvider -eq 'microsoft.insights') {
        ## Export Azure Monitor Activity Data
        Write-Host "Configuring Azure Monitor Activity Log profile '$MonitorProfileName'." -ForegroundColor Yellow
        #Remove-AzureRmLogProfile -Name $MonitorProfileName -ErrorAction SilentlyContinue
        Add-AzureRmLogProfile -Name $MonitorProfileName -Location ((Get-AzureRmLocation).Location + "global") -StorageAccountId $StorageAcctResourceId -RetentionInDays $StorageAcctRetentionInDays -ServiceBusRuleId $EventHubAuthorizationRuleResourceId        
    }
    else {
        ## Export Azure Monitor Diagnostic Data
        Write-Host "Configuring Azure Monitor Diagnostic Setting '$MonitorProfileName' for provider '$MonitorProvider'." -ForegroundColor Yellow
        #Remove-AzureRmResource -ApiVersion '2017-04-01-preview' -ResourceId "providers/$MonitorProvider/diagnosticSettings/$MonitorProfileName" -Force -ErrorAction SilentlyContinue
        New-AzureRmResource -ApiVersion '2017-04-01-preview' -ResourceId "providers/$MonitorProvider/diagnosticSettings/$MonitorProfileName" -Force -Properties (New-DiagnosticSettingsConfig -Provider $MonitorProvider -StorageAcctResourceId $StorageAcctResourceId -StorageAcctRetentionInDays $StorageAcctRetentionInDays -EventHubAuthorizationRuleResourceId $EventHubAuthorizationRuleResourceId -LogAnalyticsWorkspaceResourceId $LogAnalyticsWorkspaceResourceId)    
    }
}

Write-Host "Azure Monitor data routing configuration completed successfully!" -ForegroundColor Green
