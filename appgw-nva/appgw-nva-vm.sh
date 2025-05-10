rg=appgw-nva-vm
location=centralindia

hub_vnet_name=hub
hub_vnet_address=10.1.0.0/16
hub_nva_subnet_name=hub-nva
hub_nva_subnet_address=10.1.0.0/24
hub_nva_vm_image=$(az vm image list -l $location -p thefreebsdfoundation --sku 14_1-release-zfs --all --query "[?offer=='freebsd-14_1'].urn" -o tsv | sort -u | tail -n 1) && echo $hub_nva_vm_image
az vm image terms accept --urn $hub_nva_vm_image -o none

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

opnsense_init_file=opnsense_init.sh
cat <<EOF > $opnsense_init_file
#!/usr/local/bin/bash
echo $admin_password | sudo -S pkg update
sudo pkg upgrade -y
sed 's/#PermitRootLogin no/PermitRootLogin yes/g' /etc/ssh/sshd_config > /tmp/sshd_config
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config_tmp
sudo mv /tmp/sshd_config /etc/ssh/sshd_config
sudo /etc/rc.d/sshd restart
fetch https://raw.githubusercontent.com/opnsense/update/master/src/bootstrap/opnsense-bootstrap.sh.in
sed 's/reboot/#reboot/' opnsense-bootstrap.sh.in >opnsense-bootstrap.sh.in.tmp
mv opnsense-bootstrap.sh.in.tmp opnsense-bootstrap.sh.in
sed 's/set -e/#set -e/' opnsense-bootstrap.sh.in >opnsense-bootstrap.sh.in.tmp
mv opnsense-bootstrap.sh.in.tmp opnsense-bootstrap.sh.in
sudo chmod +x opnsense-bootstrap.sh.in
sudo sh ~/opnsense-bootstrap.sh.in -y -r 25.1
sudo cp ~/config.xml /usr/local/etc/config.xml
sudo pkg upgrade
sudo pkg install -y bash git py311-setuptools-63.1.0_3
sudo ln -s /usr/local/bin/python3.11 /usr/local/bin/python
git -c http.sslVerify=false clone https://github.com/Azure/WALinuxAgent.git
cd ~/WALinuxAgent/
git checkout v2.13.1.1
sudo python setup.py install --register-service --force
sudo reboot
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
echo -e "\e[1;36mCreating $hub_nva_subnet_name VM...\e[0m"
az network public-ip create -g $rg -n "$hub_nva_subnet_name" -l $location --allocation-method Static --sku Basic -o none
az network nic create -g $rg -n "$hub_nva_subnet_name" --subnet $hub_nva_subnet_name --vnet-name $hub_vnet_name --ip-forwarding true --private-ip-address 10.1.0.4 --public-ip-address "$hub_nva_subnet_name" -o none
az vm create -g $rg -n $hub_nva_subnet_name --image $hub_nva_vm_image --nics "$hub_nva_subnet_name" --os-disk-name $hub_nva_subnet_name --size Standard_B2als_v2 --admin-username $admin_username --generate-ssh-keys -o none
# hub fw opnsense vm details:
hub_nva_public_ip=$(az network public-ip show -g $rg -n "$hub_nva_subnet_name" --query 'ipAddress' -o tsv | tr -d '\r') && echo $hub_nva_subnet_name public ip: $hub_nva_public_ip
hub_nva_private_ip=$(az network nic show -g $rg -n $hub_nva_subnet_name --query ipConfigurations[].privateIPAddress -o tsv | tr -d '\r') && echo $hub_nva_subnet_name private IP: $hub_nva_private_ip

# opnsense vm boot diagnostics
echo -e "\e[1;36mEnabling VM boot diagnostics for $hub_nva_subnet_name...\e[0m"
az vm boot-diagnostics enable -g $rg -n $hub_nva_subnet_name -o none

# configuring opnsense
echo -e "\e[1;36mConfiguring $hub_nva_subnet_name...\e[0m"
config_file=~/config.xml
curl -o $config_file  https://raw.githubusercontent.com/wshamroukh/afd-appgw-fw/refs/heads/main/appgw-nva/config-vm.xml
echo -e "\e[1;36mCopying configuration files to $vm_name and installing opnsense firewall...\e[0m"
scp -o StrictHostKeyChecking=no $opnsense_init_file $config_file $admin_username@$hub_nva_public_ip:/home/$admin_username
ssh -o StrictHostKeyChecking=no $admin_username@$hub_nva_public_ip "chmod +x /home/$admin_username/opnsense_init.sh && sh /home/$admin_username/opnsense_init.sh"
rm $opnsense_init_file $config_file

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

echo "Try now to access the website through application gateway after routing the traffic to nva: http://$appgwpip"

# Cleanup
# az group delete -g $rg --yes --no-wait -o none