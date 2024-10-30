rg=appgw-fw-appsvc
location=centralindia

hub_vnet_name=hub
hub_vnet_address=10.1.0.0/16
hub_fw_subnet_address=10.1.0.0/24

spoke1_vnet_name=spoke1
spoke1_vnet_address=10.11.0.0/16
spoke1_appgw_subnet_name=appgw
spoke1_appgw_subnet_address=10.11.0.0/24
spoke1_pe_subnet_name=pe
spoke1_pe_subnet_address=10.11.1.0/24
spoke1_appsvc_subnet_name=appsvc
spoke1_appsvc_subnet_address=10.11.2.0/24

spoke1_appgw_name=appgw-$RANDOM
spoke1_app_svc_name=waddahApp-$RANDOM

admin_username=$(whoami)

# Resource Groups
echo -e "\e[1;36mCreating $rg Resource Group...\e[0m"
az group create -l $location -n $rg -o none

# hub1 vnet
echo -e "\e[1;36mCreating $hub_vnet_name VNet...\e[0m"
az network vnet create -g $rg -n $hub_vnet_name -l $location --address-prefixes $hub_vnet_address --subnet-name AzureFirewallSubnet --subnet-prefixes $hub_fw_subnet_address -o none

# spoke1 vnet
echo -e "\e[1;36mCreating $spoke1_vnet_name VNet...\e[0m"
az network vnet create -g $rg -n $spoke1_vnet_name -l $location --address-prefixes $spoke1_vnet_address --subnet-name $spoke1_appgw_subnet_name --subnet-prefixes $spoke1_appgw_subnet_address -o none
az network vnet subnet create -g $rg -n $spoke1_pe_subnet_name --address-prefixes $spoke1_pe_subnet_address --vnet-name $spoke1_vnet_name -o none
az network vnet subnet create -g $rg -n $spoke1_appsvc_subnet_name --address-prefixes $spoke1_appsvc_subnet_address --vnet-name $spoke1_vnet_name -o none

# VNet Peering between hub1 and spoke1
echo -e "\e[1;36mCreating VNet peering between $hub_vnet_name and $spoke1_vnet_name...\e[0m"
az network vnet peering create -g $rg -n $hub_vnet_name-to-$spoke1_vnet_name-peering --remote-vnet $spoke1_vnet_name --vnet-name $hub_vnet_name --allow-vnet-access true --allow-forwarded-traffic true -o none
az network vnet peering create -g $rg -n $spoke1_vnet_name-to-$hub_vnet_name-peering --remote-vnet $hub_vnet_name --vnet-name $spoke1_vnet_name --allow-vnet-access true --allow-forwarded-traffic true -o none

# app service
echo -e "\e[1;36mCreating $spoke1_app_svc_name App Service...\e[0m"
az appservice plan create -g $rg -n $spoke1_app_svc_name-Plan --sku P1V3 --location $location --is-linux -o none
az webapp create -g $rg -n $spoke1_app_svc_name --plan $spoke1_app_svc_name-Plan --container-image-name jelledruyts/inspectorgadget:latest -o none
appid=$(az webapp show -g $rg -n $spoke1_app_svc_name --query id -o tsv) && echo $appid
appfqdn=$(az webapp show -g $rg -n $spoke1_app_svc_name --query hostNames[] -o tsv) && echo app service fqdn: $appfqdn

# app service private endpoint
echo -e "\e[1;36mCreating Service Endpoint for $spoke1_app_svc_name App Service...\e[0m"
az network private-endpoint create -g $rg -n $spoke1_app_svc_name-pe --nic-name $spoke1_app_svc_name-pe-nic --vnet-name $spoke1_vnet_name --subnet $spoke1_pe_subnet_name --private-connection-resource-id $appid --group-id sites --connection-name $spoke1_app_svc_name-connection -l $location -o none
az network private-endpoint show -g $rg -n $spoke1_app_svc_name-pe --query customDnsConfigs[0].fqdn -o tsv
az network private-endpoint show -g $rg -n $spoke1_app_svc_name-pe --query customDnsConfigs[0].ipAddresses -o tsv

# configure private dns
echo -e "\e[1;36mCreating Private DNS Zone for $spoke1_app_svc_name App Service...\e[0m"
az network private-dns zone create -g $rg -n "privatelink.azurewebsites.net" -o none
az network private-dns link vnet create -g $rg --zone-name "privatelink.azurewebsites.net" --name dns-link --virtual-network $spoke1_vnet_name --registration-enabled false -o none
az network private-endpoint dns-zone-group create -g $rg --endpoint-name $spoke1_app_svc_name-pe --name zone-group --private-dns-zone "privatelink.azurewebsites.net" --zone-name webapp -o none

# app service vnet integration:
echo -e "\e[1;36mEnable VNet integration on $spoke1_app_svc_name App Service...\e[0m"
az webapp vnet-integration add -g $rg -n $spoke1_app_svc_name --vnet $spoke1_vnet_name --subnet $spoke1_appsvc_subnet_name -o none
# Disable Outbound internet traffic settings:
az resource update -g $rg -n $spoke1_app_svc_name --resource-type "Microsoft.Web/sites" --set properties.vnetRouteAllEnabled=false -o none

# application gateway
echo -e "\e[1;36mCreating $spoke1_appgw_name Application Gateway...\e[0m"
az network public-ip create -g $rg -n $spoke1_appgw_name-ip --allocation-method Static --sku Standard -o none
appgwpip=$(az network public-ip show -g $rg -n $spoke1_appgw_name-ip --query ipAddress -o tsv) && echo AppGW public IP: $appgwpip
az network application-gateway create -g $rg -n $spoke1_appgw_name --capacity 1 --sku Standard_v2 --vnet-name $spoke1_vnet_name --public-ip-address $spoke1_appgw_name-ip --subnet $spoke1_appgw_subnet_name --servers $appfqdn --priority 100 -o none
appgwhttpsettings=$(az network application-gateway http-settings list -g $rg --gateway-name $spoke1_appgw_name --query [].name -o tsv)
az network application-gateway http-settings update -g $rg --name $appgwhttpsettings --gateway-name $spoke1_appgw_name --host-name-from-backend-pool true --protocol Https --port 443 --host-name $appfqdn -o none

echo "Try now to access the website through application gateway before routing the traffic to azure firewall: http://$appgwpip"

# hub1 azure firewall policy
fw_name=$hub_vnet_name-fw-$RANDOM
echo -e "\e[1;36mCreating $fw_name-policy Azure Firewall Policy....\e[0m"
az extension add -n azure-firewall
az extension update -n azure-firewall
az network firewall policy create -g $rg -n $fw_name-policy -l $location -o none
az network firewall policy rule-collection-group create -g $rg -n $hub_vnet_name-RuleCollectionGroup --policy-name $fw_name-policy --priority 100 -o none
az network firewall policy rule-collection-group collection add-filter-collection -g $rg -n $hub_vnet_name-NetworkRuleCollection --policy-name $fw_name-policy --rcg-name $hub_vnet_name-RuleCollectionGroup --action Allow --rule-name appgw-to-pe-traffic --collection-priority 500 --rule-type NetworkRule --source-addresses $spoke1_appgw_subnet_address --ip-protocols any --destination-addresses $spoke1_pe_subnet_address --destination-ports '*' -o none
az network firewall policy rule-collection-group collection rule add -g $rg -n appsvc-to-appgw-traffic --policy-name $fw_name-policy --rule-collection-group-name $hub_vnet_name-RuleCollectionGroup  --collection-name $hub_vnet_name-NetworkRuleCollection --rule-type NetworkRule --source-addresses $spoke1_appsvc_subnet_address --ip-protocols any --dest-addr $spoke1_appgw_subnet_address --destination-ports '*' -o none

# hub1 azure firewall
echo -e "\e[1;36mCreating $fw_name Azure Firewall....\e[0m"
az network public-ip create -g $rg -n $fw_name -l $location --allocation-method Static --sku Standard -o none
az network firewall create -g $rg -n $fw_name -l $location --sku AZFW_VNet --firewall-policy $fw_name-policy -o none
az network firewall ip-config create -g $rg -n $fw_name-config --firewall-name $fw_name --public-ip-address $fw_name --vnet-name $hub_vnet_name -o none
az network firewall update -g $rg -n $fw_name -o none
hub1_fw_private_ip=$(az network firewall show -g $rg -n $fw_name --query ipConfigurations[0].privateIPAddress --output tsv) && echo "$fw_name private IP address: $hub1_fw_private_ip"
azfwid=$(az network firewall show -g $rg -n $fw_name --query id -o tsv)

# Log analytics Workspace
echo -e "\e[1;36mCreating Log Analytics Workspace....\e[0m"
law_name=$hub_vnet_name-fw-law-$RANDOM
az monitor log-analytics workspace create -g $rg -n $law_name -o none
lawid=$(az monitor log-analytics workspace show -g $rg -n $law_name --query id -o tsv)
# reference https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/azfwapplicationrule
az monitor diagnostic-settings create -n azfwlogs -g $rg --resource $azfwid --workspace $lawid --export-to-resource-specific true --logs '[{"category":"AZFWApplicationRule","Enabled":true}, {"category":"AZFWNetworkRule","Enabled":true}, {"category":"AZFWApplicationRuleAggregation","Enabled":true}, {"category":"AZFWDnsQuery","Enabled":true}, {"category":"AZFWFlowTrace","Enabled":true} , {"category":"AZFWIdpsSignature","Enabled":true}, {"category":"AZFWNatRule","Enabled":true}, {"category":"AZFWFatFlow","Enabled":true}, {"category":"AZFWNatRuleAggregation","Enabled":true}, {"category":"AZFWNetworkRuleAggregation","Enabled":true}, {"category":"AZFWThreatIntel","Enabled":true}]' -o none

# AppGW UDR
echo -e "\e[1;36mCreating $spoke1_appgw_name UDR....\e[0m"
az network route-table create -g $rg -n $spoke1_appgw_name -l $location --disable-bgp-route-propagation false -o none
az network route-table route create -g $rg -n to-$spoke1_pe_subnet_name --address-prefix $spoke1_pe_subnet_address --next-hop-type VirtualAppliance --route-table-name $spoke1_appgw_name --next-hop-ip-address $hub1_fw_private_ip -o none
az network vnet subnet update -g $rg -n $spoke1_appgw_subnet_name --vnet-name $spoke1_vnet_name --route-table $spoke1_appgw_name -o none

# AppSvc VNet Integration Subnet UDR
echo -e "\e[1;36mCreating $spoke1_appsvc_subnet_name UDR....\e[0m"
az network route-table create -g $rg -n $spoke1_appsvc_subnet_name -l $location --disable-bgp-route-propagation false -o none
az network route-table route create -g $rg -n default --address-prefix "0.0.0.0/0" --next-hop-type VirtualAppliance --route-table-name $spoke1_appsvc_subnet_name --next-hop-ip-address $hub1_fw_private_ip -o none
az network route-table route create -g $rg -n to-$spoke1_appgw_name --address-prefix $spoke1_appgw_subnet_address --next-hop-type VirtualAppliance --route-table-name $spoke1_appsvc_subnet_name --next-hop-ip-address $hub1_fw_private_ip -o none
az network vnet subnet update -g $rg -n $spoke1_appsvc_subnet_name --vnet-name $spoke1_vnet_name --route-table $spoke1_appsvc_subnet_name -o none

echo "Try now to access the website through application gateway after routing the traffic to azure firewall: http://$appgwpip"
