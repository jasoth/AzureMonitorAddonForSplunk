[azure_diagnostic_logs://<name>]
*Azure Monitor Diagnostic Logs Add-on For Splunk

SPNTenantID = <string> # Not required when using MSI Authentication
SPNApplicationId = <string> # Not required when using MSI Authentication
SPNApplicationKey = <string> # Not required when using MSI Authentication
eventHubNamespace = <string>
eventHubConsumerGroup = <string> # Not required. Default Value: $Default
vaultName = <string>
secretName = <string>
secretVersion = <string>

[azure_activity_log://<name>]
*Azure Monitor Activity Log Add-on For Splunk

SPNTenantID = <string> # Not required when using MSI Authentication
SPNApplicationId = <string> # Not required when using MSI Authentication
SPNApplicationKey = <string> # Not required when using MSI Authentication
eventHubNamespace = <string>
eventHubConsumerGroup = <string> # Not required. Default Value: $Default
vaultName = <string>
secretName = <string>
secretVersion = <string>

[azure_monitor_metrics://<name>]
*Azure Monitor Metrics Add-on For Splunk

SPNTenantID = <string> # Not required when using MSI Authentication
SPNApplicationId = <string> # Not required when using MSI Authentication
SPNApplicationKey = <string> # Not required when using MSI Authentication
SubscriptionId = <string>
vaultName = <string> # Not required when using MSI Authentication
secretName = <string> # Not required when using MSI Authentication
secretVersion = <string> # Not required when using MSI Authentication
