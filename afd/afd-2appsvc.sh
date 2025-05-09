rg=afd-appsvc
location1=centralindia
location2=swedencentral
app1_svc_name=wadApp1-$RANDOM
app2_svc_name=wadApp2-$RANDOM

# Resource Groups
echo -e "\e[1;36mCreating $rg Resource Group...\e[0m"
az group create -l $location1 -n $rg -o none

# app1 service
echo -e "\e[1;36mCreating $app1_svc_name App Service...\e[0m"
az appservice plan create -g $rg -n $app1_svc_name-Plan --sku P1V3 --location $location1 --is-linux -o none
az webapp create -g $rg -n $app1_svc_name --plan $app1_svc_name-Plan --container-image-name jelledruyts/inspectorgadget:latest -o none
app1id=$(az webapp show -g $rg -n $app1_svc_name --query id -o tsv | tr -d '\r')
app1fqdn=$(az webapp show -g $rg -n $app1_svc_name --query hostNames[] -o tsv | tr -d '\r')

# app2 service
echo -e "\e[1;36mCreating $app2_svc_name App Service...\e[0m"
az appservice plan create -g $rg -n $app2_svc_name-Plan --sku P1V3 --location $location2 --is-linux -o none
az webapp create -g $rg -n $app2_svc_name --plan $app2_svc_name-Plan --container-image-name jelledruyts/inspectorgadget:latest -o none
app2id=$(az webapp show -g $rg -n $app2_svc_name --query id -o tsv | tr -d '\r')
app2fqdn=$(az webapp show -g $rg -n $app2_svc_name --query hostNames[] -o tsv | tr -d '\r')

# front door
afdname=wadafd-$RANDOM
echo -e "\e[1;36mDeploying Azure Front Door Profile ($afdname-profile)..\e[0m"
az afd profile create -g $rg -n $afdname-profile --sku Premium_AzureFrontDoor -o none
echo -e "\e[1;36mCreating AFD Endpoint ($afdname-pe)..\e[0m"
az afd endpoint create -g $rg -n $afdname-pe --profile-name $afdname-profile --enabled-state Enabled -o none
afdhostname=$(az afd endpoint show -g $rg -n $afdname-pe --profile-name $afdname-profile --query hostName -o tsv | tr -d '\r')
echo -e "\e[1;36mCreating AFD origin group ($afdname-og)..\e[0m"
az afd origin-group create -g $rg -n $afdname-og --profile-name $afdname-profile --probe-request-type GET --probe-protocol Http --probe-interval-in-seconds 60 --probe-path / --sample-size 4 --successful-samples-required 3 --additional-latency-in-milliseconds 50 -o none

echo -e "\e[1;36mAdding AFD orgin to the $app1_svc_name app service..\e[0m"
az afd origin create -g $rg --host-name $app1fqdn --origin-host-header $app1fqdn --origin-group-name $afdname-og --profile-name $afdname-profile --origin-name app1 --priority 1 --enabled-state Enabled --http-port 80 --https-port 443 --weight 2 --enable-private-link true --private-link-location $location1 --private-link-resource $app1id --private-link-request-message "Please approve Private Endpoint for AFD" --private-link-sub-resource-type sites -o none
pe1id=$(az network private-endpoint-connection list --name $app1_svc_name -g $rg --type Microsoft.Web/sites --query [].id -o tsv | tr -d '\r')
echo -e "\e[1;36mApproving the Private Link connection on the $app1_svc_name..\e[0m"
az network private-endpoint-connection approve --id $pe1id --query properties.privateLinkServiceConnectionState.status

echo -e "\e[1;36mAdding AFD orgin to the $app2_svc_name app service..\e[0m"
az afd origin create -g $rg --host-name $app2fqdn --origin-host-header $app2fqdn --origin-group-name $afdname-og --profile-name $afdname-profile --origin-name app2 --priority 1 --enabled-state Enabled --http-port 80 --https-port 443 --weight 2 --enable-private-link true --private-link-location $location2 --private-link-resource $app2id --private-link-request-message "Please approve Private Endpoint for AFD" --private-link-sub-resource-type sites -o none
pe2id=$(az network private-endpoint-connection list --name $app2_svc_name -g $rg --type Microsoft.Web/sites --query [].id -o tsv | tr -d '\r')
echo -e "\e[1;36mApproving the Private Link connection on the $app2_svc_name..\e[0m"
az network private-endpoint-connection approve --id $pe2id --query properties.privateLinkServiceConnectionState.status

echo -e "\e[1;36mListing AFD orgins..\e[0m"
az afd origin list -g $rg --origin-group-name $afdname-og --profile-name $afdname-profile -o table

echo -e "\e[1;36mCreating AFD routing rule..\e[0m"
az afd route create -g $rg --profile-name $afdname-profile --endpoint-name $afdname-pe --forwarding-protocol MatchRequest --route-name route --https-redirect Enabled --origin-group $afdname-og --supported-protocols Http Https --link-to-default-domain Enabled -o none

echo "Access the website through AFD: https://$afdhostname"

# Cleanup
# az group delete -g $rg --yes --no-wait -o none