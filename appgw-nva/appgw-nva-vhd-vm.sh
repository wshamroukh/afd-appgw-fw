rg=appgw-nva-vm
location=centralindia

hub_vnet_name=hub
hub_vnet_address=10.1.0.0/16
hub_nva_subnet_name=hub-nva
hub_nva_subnet_address=10.1.0.0/24
vhdUri=https://wadvhds.blob.core.windows.net/vhds/opnsense.vhd
storageType=Premium_LRS

spoke1_vnet_name=spoke1
spoke1_vnet_address=10.11.0.0/16
spoke1_appgw_subnet_name=appgw
spoke1_appgw_subnet_address=10.11.0.0/24
spoke1_vm_subnet_name=vm
spoke1_vm_subnet_address=10.11.1.0/24

spoke1_appgw_name=appgw-$RANDOM

admin_username=$(whoami)
admin_password=Test#123#123
vm_size=Standard_B2als_v2


cloudinit_file=cloudinit.txt
cat <<EOF > $cloudinit_file
#cloud-config
runcmd:
  - apt update && apt-get install -y dotnet-sdk-8.0 nginx git
  - mv /etc/nginx/sites-available/default /etc/nginx/sites-available/default.bak
  - cd /etc/nginx/sites-available/ && curl -O https://raw.githubusercontent.com/wshamroukh/nginx-aspdotnet/refs/heads/main/default
  - git clone https://github.com/jelledruyts/InspectorGadget /var/www/InspectorGadget
  - mv /var/www/InspectorGadget/WebApp /var/www/ && rm -rf /var/www/InspectorGadget
  - cd /etc/systemd/system/ && curl -O https://raw.githubusercontent.com/wshamroukh/nginx-aspdotnet/refs/heads/main/inspectorg.service
  - systemctl enable inspectorg && systemctl start inspectorg
  - nginx -t && nginx -s reload
  - reboot
EOF

# Resource Groups
echo -e "\e[1;36mCreating $rg Resource Group...\e[0m"
az group create -l $location -n $rg -o none

# hub vnet
echo -e "\e[1;36mCreating $hub_vnet_name VNet...\e[0m"
az network vnet create -g $rg -n $hub_vnet_name -l $location --address-prefixes $hub_vnet_address --subnet-name $hub_nva_subnet_name --subnet-prefixes $hub_nva_subnet_address -o none

# spoke1 vnet
echo -e "\e[1;36mCreating $spoke1_vnet_name VNet...\e[0m"
az network vnet create -g $rg -n $spoke1_vnet_name -l $location --address-prefixes $spoke1_vnet_address --subnet-name $spoke1_appgw_subnet_name --subnet-prefixes $spoke1_appgw_subnet_address -o none
az network vnet subnet create -g $rg -n $spoke1_vm_subnet_name --address-prefixes $spoke1_vm_subnet_address --vnet-name $spoke1_vnet_name -o none

# VNet Peering between hub and spoke1
echo -e "\e[1;36mCreating VNet peering between $hub_vnet_name and $spoke1_vnet_name...\e[0m"
az network vnet peering create -g $rg -n $hub_vnet_name-to-$spoke1_vnet_name-peering --remote-vnet $spoke1_vnet_name --vnet-name $hub_vnet_name --allow-vnet-access true --allow-forwarded-traffic true -o none
az network vnet peering create -g $rg -n $spoke1_vnet_name-to-$hub_vnet_name-peering --remote-vnet $hub_vnet_name --vnet-name $spoke1_vnet_name --allow-vnet-access true --allow-forwarded-traffic true -o none

# hub fw opnsense nsg
echo -e "\e[1;36mCreating $hub_nva_subnet_name-nsg NSG...\e[0m"
myip=$(curl -s4 https://ifconfig.co/)
az network nsg create -g $rg -n $hub_nva_subnet_name-nsg -l $location -o none
az network nsg rule create -g $rg -n AllowSSH --nsg-name $hub_nva_subnet_name-nsg --priority 1000 --access Allow --description AllowSSH --protocol Tcp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges 22 --source-address-prefixes $myip --source-port-ranges '*' -o none
az network nsg rule create -g $rg -n AllowHTTP --nsg-name $hub_nva_subnet_name-nsg --priority 1010 --access Allow --description AllowHTTP --protocol Tcp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges 80 --source-address-prefixes $myip --source-port-ranges '*' -o none
az network nsg rule create -g $rg -n AllowHTTPS --nsg-name $hub_nva_subnet_name-nsg --priority 1020 --access Allow --description AllowHTTPS --protocol Tcp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges 443 --source-address-prefixes $myip --source-port-ranges '*' -o none
az network vnet subnet update -g $rg -n $hub_nva_subnet_name --vnet-name $hub_vnet_name --nsg $hub_nva_subnet_name-nsg -o none

# hub fw opnsense vm
# create a managed disk from a vhd
echo -e "\e[1;36mCreating $hub_nva_subnet_name managed disk from a vhd...\e[0m"
az disk create -g $rg -n "$hub_nva_subnet_name" --sku $storageType --location $location --size-gb 30 --source $vhdUri --os-type Linux -o none

#Get the resource Id of the managed disk
diskId=$(az disk show -n $hub_nva_subnet_name -g $rg --query [id] -o tsv | tr -d '\r')

echo -e "\e[1;36mCreating $hub_nva_subnet_name VM...\e[0m"
az network public-ip create -g $rg -n "$hub_nva_subnet_name" -l $location --allocation-method Static --sku Basic -o none
az network nic create -g $rg -n "$hub_nva_subnet_name-wan" --subnet $hub_nva_subnet_name --vnet-name $hub_vnet_name --ip-forwarding true --private-ip-address 10.1.0.250 --public-ip-address "$hub_nva_subnet_name" -o none
az vm create -g $rg -n $hub_nva_subnet_name --nics "$hub_nva_subnet_name-wan" --size Standard_B2als_v2 --attach-os-disk $diskId --os-type linux -o none
# hub fw opnsense vm details:
hub_nva_public_ip=$(az network public-ip show -g $rg -n "$hub_nva_subnet_name" --query 'ipAddress' -o tsv | tr -d '\r') && echo $hub_nva_subnet_name public ip: $hub_nva_public_ip
hub_nva_private_ip=$(az network nic show -g $rg -n $hub_nva_subnet_name-wan --query ipConfigurations[].privateIPAddress -o tsv | tr -d '\r') && echo $hub_nva_subnet_name wan private IP: $hub_nva_private_ip

# opnsense vm boot diagnostics
echo -e "\e[1;36mEnabling VM boot diagnostics for $hub_nva_subnet_name...\e[0m"
az vm boot-diagnostics enable -g $rg -n $hub_nva_subnet_name -o none

# spoke1 vm
echo -e "\e[1;36mDeploying $spoke1_vnet_name VM...\e[0m"
az network nic create -g $rg -n $spoke1_vnet_name -l $location --vnet-name $spoke1_vnet_name --subnet $spoke1_vm_subnet_name -o none
az vm create -g $rg -n $spoke1_vnet_name -l $location --image Ubuntu2404 --nics $spoke1_vnet_name --os-disk-name $spoke1_vnet_name --size $vm_size --admin-username $admin_username --admin-password $admin_password --custom-data $cloudinit_file --no-wait
spoke1_vm_ip=$(az network nic show -g $rg -n $spoke1_vnet_name --query ipConfigurations[0].privateIPAddress -o tsv | tr -d '\r') && echo $spoke1_vnet_name vm private ip: $spoke1_vm_ip

# application gateway
echo -e "\e[1;36mCreating $spoke1_appgw_name Application Gateway...\e[0m"
az network public-ip create -g $rg -n $spoke1_appgw_name-ip --allocation-method Static --sku Standard -o none
appgwpip=$(az network public-ip show -g $rg -n $spoke1_appgw_name-ip --query ipAddress -o tsv | tr -d '\r') && echo AppGW public IP: $appgwpip
az network application-gateway create -g $rg -n $spoke1_appgw_name --capacity 1 --sku Standard_v2 --vnet-name $spoke1_vnet_name --public-ip-address $spoke1_appgw_name-ip --subnet $spoke1_appgw_subnet_name --servers $spoke1_vm_ip --priority 100 -o none

echo "Try now to access the website through application gateway before routing the traffic to nva: http://$appgwpip"
# clean up cloudinit file
rm $cloudinit_file

echo "Access nva management portal via https://$hub_nva_public_ip username: root, passwd: opnsense - it is highly recommended to change the password as soon as you login"

# AppGW UDR
echo -e "\e[1;36mCreating $spoke1_appgw_name UDR....\e[0m"
az network route-table create -g $rg -n $spoke1_appgw_name -l $location --disable-bgp-route-propagation false -o none
az network route-table route create -g $rg -n to-$spoke1_vm_subnet_name --address-prefix $spoke1_vm_subnet_address --next-hop-type VirtualAppliance --route-table-name $spoke1_appgw_name --next-hop-ip-address $hub_nva_private_ip -o none
az network vnet subnet update -g $rg -n $spoke1_appgw_subnet_name --vnet-name $spoke1_vnet_name --route-table $spoke1_appgw_name -o none

# VM UDR
echo -e "\e[1;36mCreating $spoke1_vm_subnet_name UDR....\e[0m"
az network route-table create -g $rg -n $spoke1_vm_subnet_name -l $location --disable-bgp-route-propagation false -o none
az network route-table route create -g $rg -n default --address-prefix "0.0.0.0/0" --next-hop-type VirtualAppliance --route-table-name $spoke1_vm_subnet_name --next-hop-ip-address $hub_nva_private_ip -o none
az network route-table route create -g $rg -n to-$spoke1_appgw_name --address-prefix $spoke1_appgw_subnet_address --next-hop-type VirtualAppliance --route-table-name $spoke1_vm_subnet_name --next-hop-ip-address $hub_nva_private_ip -o none
az network vnet subnet update -g $rg -n $spoke1_vm_subnet_name --vnet-name $spoke1_vnet_name --route-table $spoke1_vm_subnet_name -o none

# create a LAN rule in opnsense to route traffic from appgw subnet to vm subnet
echo "Try now to access the website through application gateway after routing the traffic to nva: http://$appgwpip"

# Cleanup
# az group delete -g $rg --yes --no-wait -o none