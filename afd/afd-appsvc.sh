rg=afd-appsvc
location=centralindia

spoke1_app_svc_name=waddahApp-$RANDOM

# Resource Groups
echo -e "\e[1;36mCreating $rg Resource Group...\e[0m"
az group create -l $location -n $rg -o none

# app service
echo -e "\e[1;36mCreating $spoke1_app_svc_name App Service...\e[0m"
az appservice plan create -g $rg -n $spoke1_app_svc_name-Plan --sku P1V3 --location $location --is-linux -o none
az webapp create -g $rg -n $spoke1_app_svc_name --plan $spoke1_app_svc_name-Plan --container-image-name jelledruyts/inspectorgadget:latest -o none
appid=$(az webapp show -g $rg -n $spoke1_app_svc_name --query id -o tsv | tr -d '\r')
appfqdn=$(az webapp show -g $rg -n $spoke1_app_svc_name --query hostNames[] -o tsv | tr -d '\r')

# front door
echo -e "\e[1;36mDeploying Azure Front Door..\e[0m"
az afd profile create -g $rg -n wadafd --sku Premium_AzureFrontDoor -o none

echo -e "\e[1;36mCreating AFD Endpoint..\e[0m"
az afd endpoint create -g $rg -n wadafdfe --profile-name wadafd --enabled-state Enabled -o none
afdhostname=$(az afd endpoint show -g $rg -n wadafdfe --profile-name wadafd --query hostName -o tsv | tr -d '\r')

echo -e "\e[1;36mCreating AFD origin group..\e[0m"
az afd origin-group create -g $rg -n og --profile-name wadafd --probe-request-type GET --probe-protocol Http --probe-interval-in-seconds 60 --probe-path / --sample-size 4 --successful-samples-required 3 --additional-latency-in-milliseconds 50 -o none

echo -e "\e[1;36mCreating AFD orgin to the app service..\e[0m"
az afd origin create -g $rg --host-name $appfqdn --origin-host-header $appfqdn --origin-group-name og --profile-name wadafd --origin-name vm1 --priority 1 --enabled-state Enabled --enable-private-link true  --private-link-location $location --private-link-resource $appid --private-link-request-message "Please approve Private Endpoint for AFD" --private-link-sub-resource-type sites --http-port 80 --https-port 443 --weight 1000 -o none

peid=$(az network private-endpoint-connection list --name $spoke1_app_svc_name -g $rg --type Microsoft.Web/sites --query [].id -o tsv | tr -d '\r')
echo -e "\e[1;36mApproving the Private Link connection on the app service..\e[0m"
az network private-endpoint-connection approve --id $peid --query properties.privateLinkServiceConnectionState.status

echo -e "\e[1;36mCreating AFD routing rule..\e[0m"
az afd route create --resource-group $rg --profile-name wadafd --endpoint-name wadafdfe --forwarding-protocol MatchRequest --route-name route --https-redirect Enabled --origin-group og --supported-protocols Http Https --link-to-default-domain Enabled -o none

echo "Access the website through AFD: https://$afdhostname"

# Cleanup
# az group delete -g $rg --yes --no-wait -o none