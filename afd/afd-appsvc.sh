rg=afd-appsvc
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

spoke1_app_svc_name=waddahApp-$RANDOM

# Resource Groups
echo -e "\e[1;36mCreating $rg Resource Group...\e[0m"
az group create -l $location -n $rg -o none

# hub1 vnet
echo -e "\e[1;36mCreating $hub_vnet_name VNet...\e[0m"
az network vnet create -g $rg -n $hub_vnet_name -l $location --address-prefixes $hub_vnet_address --subnet-name AzureFirewallSubnet --subnet-prefixes $hub_fw_subnet_address -o none

# spoke1 vnet
echo -e "\e[1;36mCreating $spoke1_vnet_name VNet...\e[0m"
az network vnet create -g $rg -n $spoke1_vnet_name -l $location --address-prefixes $spoke1_vnet_address --subnet-name $spoke1_appgw_subnet_name --subnet-prefixes $spoke1_appgw_subnet_address -o none
az network vnet subnet create -g $rg -n $spoke1_pe_subnet_name --address-prefixes $spoke1_pe_subnet_address --vnet-name $spoke1_vnet_name --private-endpoint-network-policies Enabled -o none
az network vnet subnet create -g $rg -n $spoke1_appsvc_subnet_name --address-prefixes $spoke1_appsvc_subnet_address --vnet-name $spoke1_vnet_name -o none

# VNet Peering between hub1 and spoke1
echo -e "\e[1;36mCreating VNet peering between $hub_vnet_name and $spoke1_vnet_name...\e[0m"
az network vnet peering create -g $rg -n $hub_vnet_name-to-$spoke1_vnet_name-peering --remote-vnet $spoke1_vnet_name --vnet-name $hub_vnet_name --allow-vnet-access true --allow-forwarded-traffic true -o none
az network vnet peering create -g $rg -n $spoke1_vnet_name-to-$hub_vnet_name-peering --remote-vnet $hub_vnet_name --vnet-name $spoke1_vnet_name --allow-vnet-access true --allow-forwarded-traffic true -o none

# app service
echo -e "\e[1;36mCreating $spoke1_app_svc_name App Service...\e[0m"
az appservice plan create -g $rg -n $spoke1_app_svc_name-Plan --sku P1V3 --location $location --is-linux -o none
az webapp create -g $rg -n $spoke1_app_svc_name --plan $spoke1_app_svc_name-Plan --container-image-name jelledruyts/inspectorgadget:latest -o none
appid=$(az webapp show -g $rg -n $spoke1_app_svc_name --query id -o tsv)
appfqdn=$(az webapp show -g $rg -n $spoke1_app_svc_name --query hostNames[] -o tsv)

# front door
echo -e "\e[1;36mDeploying Azure Front Door..\e[0m"
az afd profile create -g $rg -n wadafd --sku Premium_AzureFrontDoor -o none
az afd endpoint create -g $rg -n wadafdfe --profile-name wadafd --enabled-state Enabled -o none
afdhostname=$(az afd endpoint show -g $rg -n wadafdfe --profile-name wadafd --query hostName -o tsv)
az afd origin-group create -g $rg -n og --profile-name wadafd --probe-request-type GET --probe-protocol Http --probe-interval-in-seconds 60 --probe-path / --sample-size 4 --successful-samples-required 3 --additional-latency-in-milliseconds 50 -o none
az afd origin create -g $rg --host-name $appfqdn --origin-host-header $appfqdn --origin-group-name og --profile-name wadafd --origin-name vm1 --priority 1 --enabled-state Enabled --enable-private-link true  --private-link-location $location --private-link-resource $appid --private-link-request-message "Please approve Private Endpoint for AFD" --private-link-sub-resource-type sites --http-port 80 --https-port 443 --weight 1000 -o none
az afd route create --resource-group $rg --profile-name wadafd --endpoint-name wadafdfe --forwarding-protocol MatchRequest --route-name route --https-redirect Enabled --origin-group og --supported-protocols Http Https --link-to-default-domain Enabled -o none
peid=$(az network private-endpoint-connection list --name $spoke1_app_svc_name -g $rg --type Microsoft.Web/sites --query [].id -o tsv)
az network private-endpoint-connection approve --id $peid --query properties.privateLinkServiceConnectionState.status
echo "Access the website through AFD: http://$afdhostname"




