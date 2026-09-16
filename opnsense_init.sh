#!/usr/local/bin/bash
fetch https://raw.githubusercontent.com/opnsense/update/master/src/bootstrap/opnsense-bootstrap.sh.in
sed -i.bak 's/reboot/#reboot/' opnsense-bootstrap.sh.in
sed -i.bak "s#pkg delete -fa#pkg query -e '%R != \"FreeBSD-base\"' '%n' | xargs -r pkg delete -fy#" opnsense-bootstrap.sh.in
sudo chmod +x opnsense-bootstrap.sh.in
sudo sh ~/opnsense-bootstrap.sh.in -y -r 26.7
fetch https://raw.githubusercontent.com/wshamroukh/opnsense-azure-vm/refs/heads/main/config.xml
sudo cp ~/config.xml /usr/local/etc/config.xml
sudo cp ~/config.xml /conf/config.xml
sudo pkg install -y bash git py313-setuptools-63.1.0_3 os-frr
git -c http.sslVerify=false clone https://github.com/Azure/WALinuxAgent.git
cd ~/WALinuxAgent/
git checkout v2.15.0.1
sudo python setup.py install --register-service --force
waagent -register-service
waagent start
sudo reboot
