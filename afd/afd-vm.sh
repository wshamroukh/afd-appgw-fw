rg=afd-vm
location=centralindia

hub_vnet_name=hub
hub_vnet_address=10.1.0.0/16
hub_fw_subnet_address=10.1.0.0/24

spoke1_vnet_name=spoke1
spoke1_vnet_address=10.11.0.0/16
spoke1_appgw_subnet_name=appgw
spoke1_appgw_subnet_address=10.11.0.0/24
spoke1_vm_subnet_name=vm
spoke1_vm_subnet_address=10.11.1.0/24

admin_username=$(whoami)
admin_password=Test#123#123
vm_size=Standard_B2ats_v2
vm_image=$(az vm image list -l $location -p Canonical -s 22_04-lts --all --query "[?offer=='0001-com-ubuntu-server-jammy'].urn" -o tsv | sort -u | tail -n 1) && echo $vm_image

cloudinit_file=~/cloudinit.txt
cat <<EOF > $cloudinit_file
#cloud-config
runcmd:
  - sudo apt update && sudo apt install -y nginx
EOF

# Resource Groups
echo -e "\e[1;36mCreating $rg Resource Group...\e[0m"
az group create -l $location -n $rg -o none

# hub1 vnet
echo -e "\e[1;36mCreating $hub_vnet_name VNet...\e[0m"
az network vnet create -g $rg -n $hub_vnet_name -l $location --address-prefixes $hub_vnet_address --subnet-name AzureFirewallSubnet --subnet-prefixes $hub_fw_subnet_address -o none

# spoke1 vnet
echo -e "\e[1;36mCreating $spoke1_vnet_name VNet...\e[0m"
az network vnet create -g $rg -n $spoke1_vnet_name -l $location --address-prefixes $spoke1_vnet_address --subnet-name $spoke1_appgw_subnet_name --subnet-prefixes $spoke1_appgw_subnet_address -o none
az network vnet subnet create -g $rg -n $spoke1_vm_subnet_name --address-prefixes $spoke1_vm_subnet_address --vnet-name $spoke1_vnet_name -o none

# VNet Peering between hub1 and spoke1
echo -e "\e[1;36mCreating VNet peering between $hub_vnet_name and $spoke1_vnet_name...\e[0m"
az network vnet peering create -g $rg -n $hub_vnet_name-to-$spoke1_vnet_name-peering --remote-vnet $spoke1_vnet_name --vnet-name $hub_vnet_name --allow-vnet-access true --allow-forwarded-traffic true -o none
az network vnet peering create -g $rg -n $spoke1_vnet_name-to-$hub_vnet_name-peering --remote-vnet $hub_vnet_name --vnet-name $spoke1_vnet_name --allow-vnet-access true --allow-forwarded-traffic true -o none

# spoke1 vm
echo -e "\e[1;36mDeploying $spoke1_vnet_name VM...\e[0m"
az network public-ip create -g $rg -n $spoke1_vnet_name --allocation-method Static --sku Basic -o none
vmip=$(az network public-ip show  -g $rg -n $spoke1_vnet_name --query ipAddress -o tsv)
az network nic create -g $rg -n $spoke1_vnet_name -l $location --public-ip-address $spoke1_vnet_name --vnet-name $spoke1_vnet_name --subnet $spoke1_vm_subnet_name -o none
az vm create -g $rg -n $spoke1_vnet_name -l $location --image $vm_image --nics $spoke1_vnet_name --os-disk-name $spoke1_vnet_name --size $vm_size --admin-username $admin_username --admin-password $admin_password --custom-data $cloudinit_file --no-wait
spoke1_vm_ip=$(az network nic show -g $rg -n $spoke1_vnet_name --query ipConfigurations[0].privateIPAddress -o tsv) && echo $spoke1_vnet_name vm private ip: $spoke1_vm_ip
# clean up cloudinit file
rm $cloudinit_file

# front door
echo -e "\e[1;36mDeploying Azure Front Door..\e[0m"
az afd profile create -g $rg -n wadafd --sku Premium_AzureFrontDoor -o none
az afd endpoint create -g $rg -n wadafdfe --profile-name wadafd --enabled-state Enabled -o none
afdhostname=$(az afd endpoint show -g $rg -n wadafdfe --profile-name wadafd --query hostName -o tsv)
az afd origin-group create -g $rg -n og --profile-name wadafd --probe-request-type GET --probe-protocol Http --probe-interval-in-seconds 60 --probe-path / --sample-size 4 --successful-samples-required 3 --additional-latency-in-milliseconds 50 -o none
az afd origin create -g $rg --host-name $vmip --origin-host-header $vmip --origin-group-name og --profile-name wadafd --origin-name vm1 --priority 1 --enabled-state Enabled --http-port 80 --https-port 443 --weight 1000 -o none
az afd route create --resource-group $rg --profile-name wadafd --endpoint-name wadafdfe --forwarding-protocol HttpOnly --route-name route --https-redirect Enabled --origin-group og --supported-protocols Http Https --link-to-default-domain Enabled -o none
echo "Access the website through AFD: http://$afdhostname"
