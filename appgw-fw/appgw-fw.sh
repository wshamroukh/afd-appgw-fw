rg=appg-fw
location=centralindia

hub1_vnet_name=hub1
hub1_vnet_address=10.1.0.0/16
hub1_fw_subnet_address=10.1.0.0/24

spoke1_vnet_name=spoke1
spoke1_vnet_address=10.11.0.0/16
spoke1_appgw_subnet_name=appgw
spoke1_appgw_subnet_address=10.11.0.0/24
spoke1_pe_subnet_name=pe
spoke1_pe_subnet_address=10.11.1.0/24

myip=$(curl -s4 https://ifconfig.co/)

# Resource Groups
echo -e "\e[1;36mCreating $rg Resource Group...\e[0m"
az group create -l $location -n $rg -o none

# hub1 vnet
echo -e "\e[1;36mCreating $hub1_vnet_name VNet...\e[0m"
az network vnet create -g $rg -n $hub1_vnet_name -l $location --address-prefixes $hub1_vnet_address --subnet-name AzureFirewallSubnet --subnet-prefixes $hub1_fw_subnet_address -o none

# spoke1 vnet
echo -e "\e[1;36mCreating $spoke1_vnet_name VNet...\e[0m"
az network vnet create -g $rg -n $spoke1_vnet_name -l $location --address-prefixes $spoke1_vnet_address --subnet-name $spoke1_appgw_subnet_name --subnet-prefixes $spoke1_appgw_subnet_address -o none
az network vnet subnet create -g $rg -n $spoke1_pe_subnet_name --address-prefixes $spoke1_pe_subnet_address --vnet-name $spoke1_vnet_name -o none

# VNet Peering between hub1 and spoke1
echo -e "\e[1;36mCreating VNet peerring between $hub1_vnet_name and $spoke1_vnet_name...\e[0m"
az network vnet peering create -g $rg -n $hub1_vnet_name-to-$spoke1_vnet_name-peering --remote-vnet $spoke1_vnet_name --vnet-name $hub1_vnet_name --allow-vnet-access -o none
az network vnet peering create -g $rg -n $spoke1_vnet_name-to-$hub1_vnet_name-peering --remote-vnet $hub1_vnet_name --vnet-name $spoke1_vnet_name --allow-vnet-access -o none

# app service
az appservice plan create -g $rg -n waddahapp1Plan --sku P1V3 --location $location
az webapp create -g $rg -n waddahapp1 --plan waddahapp1Plan
appid=$(az webapp show -g $rg -n waddahapp1 --query id -o tsv)
appfqdb=$(az webapp show -g $rg -n waddahapp1 --query hostNames[] -o tsv)

# app service private endpoint
az network private-endpoint create -g $rg -n waddahapp1-pe --nic-name waddahapp1-pe-nic --vnet-name $spoke1_vnet_name --subnet $spoke1_pe_subnet_name --private-connection-resource-id $appid --group-id sites --connection-name waddahapp1-connection -l $location
az network private-endpoint create --nic-name

# configure private dns
az network private-dns zone create -g $rg -n "privatelink.azurewebsites.net"
az network private-dns link vnet create -g $rg --zone-name "privatelink.azurewebsites.net" --name dns-link --virtual-network $spoke1_vnet_name --registration-enabled false
az network private-endpoint dns-zone-group create -g $rg --endpoint-name waddahapp1-pe --name zone-group --private-dns-zone "privatelink.azurewebsites.net" --zone-name webapp

# application gateway
az network public-ip create -g $rg -n appgwip --allocation-method Static --sku Standard
az network application-gateway create -g $rg -n appgw --capacity 1 --sku Standard_v2 --vnet-name $spoke1_vnet_name --public-ip-address appgwip --subnet $spoke1_appgw_subnet_name --servers $appfqdb --priority 100

# hub1 azure firewall policy
echo -e "\e[1;36mCreating $hub1_vnet_name-fw-policy Azure Firewall Policy....\e[0m"
az extension add -n azure-firewall
az extension update -n azure-firewall
az network firewall policy create -g $rg -n $hub1_vnet_name-fw-policy -l $location -o none
az network firewall policy rule-collection-group create -g $rg -n $hub1_vnet_name-RuleCollectionGroup --policy-name $hub1_vnet_name-fw-policy --priority 100 -o none
az network firewall policy rule-collection-group collection add-filter-collection -g $rg -n $hub1_vnet_name-NetworkRuleCollection --policy-name $hub1_vnet_name-fw-policy --rcg-name $hub1_vnet_name-RuleCollectionGroup --action Allow --rule-name appgw-to-appsv-pe-traffic --collection-priority 100 --rule-type NetworkRule --source-addresses $spoke1_appgw_subnet_address --ip-protocols any --destination-addresses $spoke1_pe_subnet_address --destination-ports '*' -o none
az network firewall policy rule-collection-group collection rule add -g $rg -n appsvc-pe-to-appgw-traffic --policy-name $hub1_vnet_name-fw-policy --rule-collection-group-name $hub1_vnet_name-RuleCollectionGroup  --collection-name $hub1_vnet_name-NetworkRuleCollection --rule-type NetworkRule --dest-addr $spoke1_appgw_subnet_address --destination-ports '*' --ip-protocols any --source-addresses $spoke1_pe_subnet_address -o none

# hub1 azure firewall
echo -e "\e[1;36mCreating $hub1_vnet_name-fw Azure Firewall....\e[0m"
az network public-ip create -g $rg -n $hub1_vnet_name-fw -l $location --allocation-method Static --sku Standard -o none
az network firewall create -g $rg -n $hub1_vnet_name-fw -l $location --sku AZFW_VNet --firewall-policy $hub1_vnet_name-fw-policy -o none
az network firewall ip-config create -g $rg -n $hub1_vnet_name-fw-config --firewall-name $hub1_vnet_name-fw --public-ip-address $hub1_vnet_name-fw --vnet-name $hub1_vnet_name -o none
az network firewall update -g $rg -n $hub1_vnet_name-fw -o none
hub1_fw_private_ip=$(az network firewall show -g $rg -n $hub1_vnet_name-fw --query ipConfigurations[0].privateIPAddress --output tsv) && echo "$hub1_vnet_name-fw private IP address: $hub1_fw_private_ip"

# AppGW UDR
az network route-table create -g $rg -n appgw -l $location --disable-bgp-route-propagation false -o none
az network route-table route create -g $rg -n to-appsvc-pe --address-prefix $spoke1_pe_subnet_address --next-hop-type VirtualAppliance --route-table-name appgw --next-hop-ip-address $hub1_fw_private_ip -o none
az network vnet subnet update -g $rg -n $spoke1_appgw_subnet_name --vnet-name $spoke1_vnet_name --route-table appgw -o none

# App Service Private Endpoint UDR
az network route-table create -g $rg -n appsvc -l $location --disable-bgp-route-propagation false -o none
az network route-table route create -g $rg -n default --address-prefix "0.0.0.0/0" --next-hop-type VirtualAppliance --route-table-name appsvc --next-hop-ip-address $hub1_fw_private_ip -o none
az network route-table route create -g $rg -n to-appgw --address-prefix $spoke1_appgw_subnet_address --next-hop-type VirtualAppliance --route-table-name appsvc --next-hop-ip-address $hub1_fw_private_ip -o none
az network vnet subnet update -g $rg -n $spoke1_pe_subnet_name --vnet-name $spoke1_vnet_name --route-table appsvc -o none

