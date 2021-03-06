## set cloudstack as data source in cloud-init with the modifications from exoscale.ch - thanks
cat << EOF > /etc/cloud/cloud.cfg.d/99_cloudstack.cfg
datasource:
  CloudStack: {}
  None: {}
datasource_list:
  - CloudStack
EOF
#fix userdata url issue with ending slash
#sed -i '385i \ \ \ \ #cloudstack fix remove ending slash' /usr/lib/python2.7/site-packages/boto/utils.py
#sed -i '386i \ \ \ \ ud_url = ud_url[:-1]' /usr/lib/python2.7/site-packages/boto/utils.py

#sed -i 's,disable_root: 1,disable_root: 0,' /etc/cloud/cloud.cfg
#sed -i 's,ssh_pwauth:   0,ssh_pwauth:   1,' /etc/cloud/cloud.cfg
#sed -i 's,name: cloud-user,name: root,' /etc/cloud/cloud.cfg
# non-blocking resize fs, should be done in the background
#sed -i '/resize_rootfs_tmp/aresize_rootfs: noblock' /etc/cloud/cloud.cfg

# cloudstack friendly cloud.cfg

cat > /etc/cloud/cloud.cfg << "EOF"
users:
 - default

disable_root: 0
ssh_pwauth:   1

locale_configfile: /etc/sysconfig/i18n
mount_default_fields: [~, ~, 'auto', 'defaults,nofail', '0', '2']
resize_rootfs_tmp: /dev
resize_rootfs: noblock
ssh_deletekeys:   0
ssh_genkeytypes:  ~
syslog_fix_perms: ~

cloud_init_modules:
 - migrator
 - bootcmd
 - write-files
 - growpart
 - resizefs
 - set_hostname
 - update_hostname
 - update_etc_hosts
 - rsyslog
 - users-groups
 - ssh

cloud_config_modules:
 - mounts
 - locale
 - set-passwords
 - yum-add-repo
 - package-update-upgrade-install
 - timezone
 - puppet
 - chef
 - salt-minion
 - mcollective
 - disable-ec2-metadata
 - runcmd

cloud_final_modules:
 - rightscale_userdata
 - scripts-per-once
 - scripts-per-boot
 - scripts-per-instance
 - scripts-user
 - ssh-authkey-fingerprints
 - keys-to-console
 - phone-home
 - final-message

system_info:
  default_user:
    name: root
  distro: rhel
  paths:
    cloud_dir: /var/lib/cloud
    templates_dir: /etc/cloud/templates
  ssh_svcname: sshd

# vim:syntax=yaml
EOF


mkdir -p /var/lib/cloud/scripts/per-boot
cat > /var/lib/cloud/scripts/per-boot/10_cloud-set-guest-password << "EOF"
#!/bin/bash
#
# Init file for Password Download Client
#
# chkconfig: 345 98 02
# description: Password Download Client

# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
# 
#   http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.


# Modify this line to specify the user (default is root)
user=root

# Add your DHCP lease folders here
DHCP_FOLDERS="/var/lib/dhclient/* /var/lib/dhcp3/* /var/lib/dhcp/* /var/lib/NetworkManager/*"
password_received=0
file_count=0
error_count=0

for DHCP_FILE in $DHCP_FOLDERS
do
	if [ -f $DHCP_FILE ]
	then
		file_count=$((file_count+1))
		PASSWORD_SERVER_IP=$(grep dhcp-server-identifier $DHCP_FILE | tail -1 | awk '{print $NF}' | tr -d '\;')

		if [ -n "$PASSWORD_SERVER_IP" ]
		then
			logger -t "cloud" "Found password server IP $PASSWORD_SERVER_IP in $DHCP_FILE"
			logger -t "cloud" "Sending request to password server at $PASSWORD_SERVER_IP"
			password=$(wget -q -t 3 -T 20 -O - --header "DomU_Request: send_my_password" $PASSWORD_SERVER_IP:8080)
			password=$(echo $password | tr -d '\r')

			if [ $? -eq 0 ]
			then
				logger -t "cloud" "Got response from server at $PASSWORD_SERVER_IP"

				case $password in
				
				"")					logger -t "cloud" "Password server at $PASSWORD_SERVER_IP did not have any password for the VM"
									continue
									;;
				
				"bad_request")		logger -t "cloud" "VM sent an invalid request to password server at $PASSWORD_SERVER_IP"
									error_count=$((error_count+1))
									continue
									;;
									
				"saved_password") 	logger -t "cloud" "VM has already saved a password from the password server at $PASSWORD_SERVER_IP"
									continue
									;;
									
				*)					logger -t "cloud" "VM got a valid password from server at $PASSWORD_SERVER_IP"
									password_received=1
									break
									;;
									
				esac
			else
				logger -t "cloud" "Failed to send request to password server at $PASSWORD_SERVER_IP"
				error_count=$((error_count+1))
			fi
		else
			logger -t "cloud" "Could not find password server IP in $DHCP_FILE"
			error_count=$((error_count+1))
		fi
	fi
done

if [ "$password_received" == "0" ]
then
	if [ "$error_count" == "$file_count" ]
	then
		logger -t "cloud" "Failed to get password from any server"
		exit 1
	else
		logger -t "cloud" "Did not need to change password."
		exit 0
	fi
fi

logger -t "cloud" "Changing password ..."
echo $user:$password | chpasswd
						
if [ $? -gt 0 ]
then
	usermod -p `mkpasswd -m SHA-512 $password` $user
		
	if [ $? -gt 0 ]
	then
		logger -t "cloud" "Failed to change password for user $user"
		exit 1
	else
		logger -t "cloud" "Successfully changed password for user $user"
	fi
fi
						
logger -t "cloud" "Sending acknowledgment to password server at $PASSWORD_SERVER_IP"
wget -t 3 -T 20 -O - --header "DomU_Request: saved_password" $PASSWORD_SERVER_IP:8080
exit 0
EOF

chmod +x /var/lib/cloud/scripts/per-boot/10_cloud-set-guest-password
