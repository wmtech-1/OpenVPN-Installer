#!/bin/bash

# Secure OpenVPN server installer for CentOS or RedHat
# https://github.com/wmtech-1/OpenVPN-install/


# Verify root
if [[ "$EUID" -ne 0 ]]; then
	echo "Sorry, you need to run this as root"
	exit
fi

# Verify tun
if [[ ! -e /dev/net/tun ]]; then
	echo "TUN is not available"
	exit
fi

if [[ -e /etc/os-release && $(cat /etc/os-release | grep "^NAME") == *"Raspbian"* ]]; then
    OS=raspberrypios
    PTABLES='/etc/iptables/rules.v4'
    IP6TABLES='/etc/ip6tables/rules.v6'
    SYSCTL='/etc/sysctl.d/30-openvpn-forward.conf'
else
    echo "Looks like you aren't running this installer on a Raspberry Pi"
    exit
fi

newclient () {
	# Where to write the custom client.ovpn?
	if [ -e "/home/$1" ]; then  # if $1 is a user name
		homeDir="/home/$1"
	elif [ "${SUDO_USER}" ]; then   # if not, use SUDO_USER
		homeDir="/home/${SUDO_USER}"
	else  # if not SUDO_USER, use /root
		homeDir="/root"
	fi
	# Generates the custom client.ovpn
	cp /etc/openvpn/client-template.txt "$homeDir/$1.ovpn"
	{
 		echo "<ca>"
 		cat "/etc/openvpn/easy-rsa/pki/ca.crt"
 		echo "</ca>"

 		echo "<cert>"
 		cat "/etc/openvpn/easy-rsa/pki/issued/$1.crt"
 		echo "</cert>"

 		echo "<key>"
 		cat "/etc/openvpn/easy-rsa/pki/private/$1.key"
 		echo "</key>"
 		echo "key-direction 1"

 		echo "<tls-auth>"
 		cat "/etc/openvpn/tls-auth.key"
 		echo "</tls-auth>"
 	} >> "$homeDir/$1.ovpn"
}

# Get Internet network interface with default route
NIC=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
# Get Internet network interface with default ipv6 route
NIC6=$(ip -6 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)

if [[ -e /etc/openvpn/server.conf ]]; then
	while :
	do
	clear
		echo "OpenVPN-install (github.com/wmtech-1/OpenVPN-install)"
		echo ""
		echo "Looks like OpenVPN is already installed"
		echo ""

		echo "What do you want to do?"
		echo "   1) Add a cert for a new user"
		echo "   2) Revoke existing user cert"
		echo "   3) Remove OpenVPN"
		echo "   4) Exit"
		read -rp "Select an option [1-4]: " option

		case $option in
			1)
			echo ""
			echo "Do you want to protect the configuration file with a password?"
 			echo "(e.g. encrypt the private key with a password)"
 			echo "   1) Add a passwordless client"
 			echo "   2) Use a password for the client"
 			until [[ "$pass" =~ ^[1-2]$ ]]; do
 				read -rp "Select an option [1-2]: " -e -i 1 pass
 			done
 			echo ""
			echo "Tell me a name for the client cert"
			echo "Use one word only, no special characters"
 			until [[ "$CLIENT" =~ ^[a-zA-Z0-9_]+$ ]]; do
 				read -rp "Client name: " -e CLIENT
 			done

			cd /etc/openvpn/easy-rsa/ || return
			case $pass in
 				1)
 				./easyrsa build-client-full $CLIENT nopass
 				;;
 				2)
 				echo "⚠️ You will be asked for the client password below ⚠️"
 				./easyrsa build-client-full $CLIENT
 				;;
 			esac

			# Generates the custom client.ovpn
			newclient "$CLIENT"

			echo ""
			echo "Client $CLIENT added, certs available at $homeDir/$CLIENT.ovpn"
			exit
			;;
			2)
			NUMBEROFCLIENTS=$(tail -n +2 /etc/openvpn/easy-rsa/pki/index.txt | grep -c "^V")
			if [[ "$NUMBEROFCLIENTS" = '0' ]]; then
				echo ""
				echo "You have no existing clients!"
				exit
			fi

			echo ""
			echo "Select the existing client certificate you want to revoke"
			tail -n +2 /etc/openvpn/easy-rsa/pki/index.txt | grep "^V" | cut -d '=' -f 2 | nl -s ') '
			if [[ "$NUMBEROFCLIENTS" = '1' ]]; then
				read -rp "Select one client [1]: " CLIENTNUMBER
			else
				read -rp "Select one client [1-$NUMBEROFCLIENTS]: " CLIENTNUMBER
			fi

			CLIENT=$(tail -n +2 /etc/openvpn/easy-rsa/pki/index.txt | grep "^V" | cut -d '=' -f 2 | sed -n "$CLIENTNUMBER"p)
			echo
			read -p "Do you really want to revoke access for client $CLIENT? [y/N]: " -e REVOKE
 			if [[ "$REVOKE" = 'y' || "$REVOKE" = 'Y' ]]; then
 				cd /etc/openvpn/easy-rsa/ || return
 				./easyrsa --batch revoke $CLIENT
 				EASYRSA_CRL_DAYS=3650 ./easyrsa gen-crl
 				rm -f pki/reqs/$CLIENT.req
 				rm -f pki/private/$CLIENT.key
 				rm -f pki/issued/$CLIENT.crt
 				rm -f /etc/openvpn/crl.pem
 				cp /etc/openvpn/easy-rsa/pki/crl.pem /etc/openvpn/crl.pem
 				chmod 644 /etc/openvpn/crl.pem
 				rm -f $(find /home -maxdepth 2 | grep $CLIENT.ovpn) 2>/dev/null
 				rm -f /root/$CLIENT.ovpn 2>/dev/null

 				echo ""
 				echo "Certificate for client $CLIENT revoked!"
 				echo "Exiting..."
 			else
 				echo ""
 				echo "Certificate revocation for client $CLIENT aborted!"
 				echo "Exiting..."
 			fi
 			exit
 			;;
			3)
			echo ""
			read -rp "Do you really want to remove OpenVPN? [y/n]: " -e REMOVE
			if [[ "$REMOVE" = 'y' || "$REMOVE" = 'Y' ]]; then
				PORT=$(grep '^port ' /etc/openvpn/server.conf | cut -d " " -f 2)
				PROTOCOL=$(grep '^proto ' /etc/openvpn/server.conf | cut -d " " -f 2 | tail -n 1)
				IPV6E = "0"
				if grep -qs "#IPv6 config start" "/etc/openvpn/server.conf"; then
					IPV6E = "1"
				fi
				if pgrep firewalld; then
					# Using both permanent and not permanent rules to avoid a firewalld reload.
					firewall-cmd --zone=public --remove-port=$PORT/udp
					firewall-cmd --zone=trusted --remove-source=10.8.0.0/24
					firewall-cmd --permanent --zone=public --remove-port=$PORT/udp
					firewall-cmd --permanent --zone=trusted --remove-source=10.8.0.0/24
				fi
				if iptables -L -n | grep -qE 'REJECT|DROP'; then
					if [[ "$PROTOCOL" = 'udp' ]]; then
						iptables -D INPUT -p udp --dport $PORT -j ACCEPT
					else
						iptables -D INPUT -p tcp --dport $PORT -j ACCEPT
					fi
					iptables -D FORWARD -s 10.8.0.0/24 -j ACCEPT
					iptables -D INPUT -i tun+ -j ACCEPT
					iptables-save > $IPTABLES
				fi
				iptables -t nat -D POSTROUTING -o $NIC -s 10.8.0.0/24 -j MASQUERADE
				iptables-save > $IPTABLES
				if [[ "$IPV6E" = '1' ]]; then
					if ip6tables -L -n | grep -qE 'REJECT|DROP'; then
						if [[ "$PROTOCOL" = 'udp' ]]; then
							ip6tables -D INPUT -p udp --dport $PORT -j ACCEPT
						else
							ip6tables -D INPUT -p tcp --dport $PORT -j ACCEPT
						fi
						ip6tables -D FORWARD -s fd6c:62d9:eb8c::/112 -j ACCEPT
						ip6tables -D INPUT -i tun+ -j ACCEPT
						ip6tables-save > $IP6TABLES
					fi
					ip6tables -t nat -D POSTROUTING -o $NIC6 -s fd6c:62d9:eb8c::/112 -j MASQUERADE
					ip6tables-save > $IP6TABLES
				fi
				if hash sestatus 2>/dev/null; then
					if sestatus | grep "Current mode" | grep -qs "enforcing"; then
						if [[ "$PORT" != '1194' ]]; then
							semanage port -d -t openvpn_port_t -p udp $PORT
						fi
					fi
				fi
				apt remove openvpn -y
				OVPNS=$(ls /etc/openvpn/easy-rsa/pki/issued | awk -F "." {'print $1'})
 				for i in $OVPNS
 				do
 				rm $(find /home -maxdepth 2 | grep $i.ovpn) 2>/dev/null
 				rm /root/$i.ovpn 2>/dev/null
 				done
				rm -rf /etc/openvpn
				rm -f /etc/sysctl.d/30-openvpn-forward.conf
				rm -rf /usr/share/doc/openvpn*
				rm -rf /var/log/openvpn
				rm -rf /etc/logrotate.d/openvpn
				echo ""
				echo "OpenVPN removed!"
			else
				echo ""
				echo "Removal aborted!"
			fi
			exit
			;;
			4) exit;;
		esac
	done
else
	clear
	echo "Welcome to the secure OpenVPN installer (github.com/wmtech-1/OpenVPN-Installer)"
	echo ""

	# OpenVPN setup and first user creation
	echo "I need to ask you a few questions before starting the setup"
	echo "You can leave the default options and just press enter if you are ok with them"
	echo ""
	echo "I need to know the IPv4 address of the network interface you want OpenVPN listening to."
	echo "If your server is running behind a NAT, (e.g. LowEndSpirit, Scaleway) leave the IP address as it is. (local/private IP)"
	echo "Otherwise, it should be your public IPv4 address."

	# Autodetect IP address and pre-fill for the user
	IP=$(ip addr | grep 'inet' | grep -v inet6 | grep -vE '127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | head -1)
	read -rp "IP address: " -e -i $IP IP
	echo ""
	echo "What port do you want for OpenVPN?"
	echo "   1) Default: 1194"
 	echo "   2) Custom"
 	echo "   3) Random [49152-65535]"
 	until [[ "$PORT_CHOICE" =~ ^[1-3]$ ]]; do
 		read -rp "Port choice [1-3]: " -e -i 1 PORT_CHOICE
 	done
 	case $PORT_CHOICE in
 		1)
 			PORT="1194"
 		;;
 		2)
 			until [[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 -a "$PORT" -le 65535 ]; do
 				read -rp "Custom port [1-65535]: " -e -i 1194 PORT
 			done
 		;;
 		3)
 			# Generate random number within private ports range
 			PORT=$(shuf -i49152-65535 -n1)
 			echo "Random Port: $PORT"
 		;;
 	esac
	echo ""
	echo "Enable IPv6? (ensure that your machine has IPv6 support):"
	echo "   1) Yes (default)"
	echo "   2) No"
	until [[ "$IPV6E" =~ ^[0-9]+$ ]] && [ "$IPV6E" -ge 1 -a "$IPV6E" -le 2 ]; do
		read -rp "Enable IPv6 [1-2]: " -e -i 1 IPV6E
	done
	case $IPV6E in
		1)
		IPV6E="1"
		;;
		2)
		IPV6E="0"
		;;
	esac
	# If $IP is a private IP address, the server must be behind NAT
	if echo "$IP" | grep -qE '^(10\.|172\.1[6789]\.|172\.2[0-9]\.|172\.3[01]\.|192\.168)'; then
		echo ""
		echo "This server is behind NAT. What is the public IPv4 address or hostname?"
		read -rp "Public IP address / hostname: " -e PUBLICIP
	fi
	echo ""
	echo "What protocol do you want for OpenVPN?"
	echo "Unless UDP is blocked, you should not use TCP (unnecessarily slower)"
	until [[ "$PROTOCOL" == "UDP" || "$PROTOCOL" == "TCP" ]]; do
	    read -rp "Protocol [UDP/TCP]: " -e -i UDP PROTOCOL
	done
	echo ""
	echo "What DNS do you want to use with the VPN?"
	echo "   1) Current system resolvers (from /etc/resolv.conf)"
	echo "   2) Cloudflare (Anycast: worldwide)"
	echo "   3) Quad9 (Anycast: worldwide)"
	echo "   4) FDN (France)"
	echo "   5) DNS.WATCH (Germany)"
	echo "   6) OpenDNS (Anycast: worldwide)"
	echo "   7) Google (Anycast: worldwide)"
	echo "   8) Yandex Basic (Russia)"
	echo "   9) AdGuard DNS (Russia)"
	until [[ "$DNS" =~ ^[0-9]+$ ]] && [ "$DNS" -ge 1 -a "$DNS" -le 9 ]; do
		read -rp "DNS [1-9]: " -e -i 1 DNS
	done
	echo ""
	echo "See https://github.com/wmtech-1/OpenVPN-Installer#encryption to learn more about "
	echo "the encryption in OpenVPN and the choices I made in this script."
	echo "Please note that all the choices proposed are secure (to a different degree)"
	echo "and are still viable to date, unlike some default OpenVPN options"
	echo ''
	echo "Choose which cipher you want to use for the data channel:"
	echo "   1) AES-128-CBC (fastest and sufficiently secure for everyone, recommended)"
	echo "   2) AES-192-CBC"
	echo "   3) AES-256-CBC"
	echo "Alternatives to AES, use them only if you know what you're doing."
	echo "They are relatively slower but as secure as AES."
	echo "   4) CAMELLIA-128-CBC"
	echo "   5) CAMELLIA-192-CBC"
	echo "   6) CAMELLIA-256-CBC"
	echo "   7) SEED-CBC"
	until [[ "$CIPHER" =~ ^[0-9]+$ ]] && [ "$CIPHER" -ge 1 -a "$CIPHER" -le 7 ]; do
		read -rp "Cipher [1-7]: " -e -i 1 CIPHER
	done
	case $CIPHER in
		1)
		CIPHER="cipher AES-128-CBC"
		;;
		2)
		CIPHER="cipher AES-192-CBC"
		;;
		3)
		CIPHER="cipher AES-256-CBC"
		;;
		4)
		CIPHER="cipher CAMELLIA-128-CBC"
		;;
		5)
		CIPHER="cipher CAMELLIA-192-CBC"
		;;
		6)
		CIPHER="cipher CAMELLIA-256-CBC"
		;;
		7)
		CIPHER="cipher SEED-CBC"
		;;
	esac
	echo ""
	echo "Choose what size of Diffie-Hellman key you want to use:"
	echo "   1) 2048 bits (fastest)"
	echo "   2) 3072 bits (recommended, best compromise)"
	echo "   3) 4096 bits (most secure)"
	until [[ "$DH_KEY_SIZE" =~ ^[0-9]+$ ]] && [ "$DH_KEY_SIZE" -ge 1 -a "$DH_KEY_SIZE" -le 3 ]; do
		read -rp "DH key size [1-3]: " -e -i 2 DH_KEY_SIZE
	done
	case $DH_KEY_SIZE in
		1)
		DH_KEY_SIZE="2048"
		;;
		2)
		DH_KEY_SIZE="3072"
		;;
		3)
		DH_KEY_SIZE="4096"
		;;
	esac
	echo ""
	echo "Choose what size of RSA key you want to use:"
	echo "   1) 2048 bits (fastest)"
	echo "   2) 3072 bits (recommended, best compromise)"
	echo "   3) 4096 bits (most secure)"
	until [[ "$RSA_KEY_SIZE" =~ ^[0-9]+$ ]] && [ "$RSA_KEY_SIZE" -ge 1 -a "$RSA_KEY_SIZE" -le 3 ]; do
		read -rp "RSA key size [1-3]: " -e -i 2 RSA_KEY_SIZE
	done
	case $RSA_KEY_SIZE in
		1)
		RSA_KEY_SIZE="2048"
		;;
		2)
		RSA_KEY_SIZE="3072"
		;;
		3)
		RSA_KEY_SIZE="4096"
		;;
	esac
	echo ""
	echo "Do you want to protect the configuration file with a password?"
 	echo "(e.g. encrypt the private key with a password)"
 	echo "   1) Add a passwordless client"
 	echo "   2) Use a password for the client"
 	until [[ "$pass" =~ ^[1-2]$ ]]; do
 		read -rp "Select an option [1-2]: " -e -i 1 pass
 	done
 	echo ""
	echo "Finally, tell me a name for the client certificate and configuration"
	echo "Use one word only, no special characters"
	until [[ "$CLIENT" =~ ^[a-zA-Z0-9_]+$ ]]; do
		read -rp "Client name: " -e -i firstclient CLIENT
	done
	echo ""
	echo "Okay, that was all I needed. We are ready to setup your OpenVPN server now"
	read -n1 -r -p "Press any key to continue..."

	if [[ "$OS" = 'raspberrypios' ]]; then
		apt install epel-release -y
		apt install openvpn iptables openssl wget ca-certificates curl -y
		# Install iptables service
		if [[ ! -e /usr/lib/systemd/system/iptables.service  && ! -e /etc/systemd/system/iptables.service ]]; then
			mkdir /etc/iptables
			iptables-save > $IPTABLES
			echo "#!/bin/sh
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT" > /etc/iptables/flush-iptables.sh
			chmod +x /etc/iptables/flush-iptables.sh
			echo "[Unit]
Description=Packet Filtering Framework
DefaultDependencies=no
Before=network-pre.target
Wants=network-pre.target
[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore /etc/iptables/iptables.rules
ExecReload=/sbin/iptables-restore /etc/iptables/iptables.rules
ExecStop=/etc/iptables/flush-iptables.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target" > /etc/systemd/system/iptables.service
			systemctl daemon-reload
			systemctl enable iptables.service
			# Disable firewalld to allow iptables to start upon reboot
			systemctl disable firewalld
			systemctl mask firewalld
		fi
		if [[ "$IPV6E" = '1' ]]; then
			# Install ip6tables service
			if [[ ! -e /usr/lib/systemd/system/ip6tables.service && ! -e /etc/systemd/system/ip6tables.service ]]; then
				mkdir /etc/ip6tables
				ip6tables-save > $IP6TABLES
				echo "#!/bin/sh
ip6tables -F
ip6tables -X
ip6tables -t nat -F
ip6tables -t nat -X
ip6tables -t mangle -F
ip6tables -t mangle -X
ip6tables -P INPUT ACCEPT
ip6tables -P FORWARD ACCEPT
ip6tables -P OUTPUT ACCEPT" > /etc/ip6tables/flush-ip6tables.sh
			chmod +x /etc/ip6tables/flush-ip6tables.sh
			echo "[Unit]
Description=IPv6 Packet Filtering Framework
DefaultDependencies=no
After=syslog.target iptables.service
Wants=network-pre.target
[Service]
Type=oneshot
ExecStart=/sbin/ip6tables-restore /etc/ip6tables/ip6tables.rules
ExecReload=/sbin/ip6tables-restore /etc/ip6tables/ip6tables.rules
ExecStop=/etc/ip6tables/flush-ip6tables.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target" > /etc/systemd/system/ip6tables.service
				systemctl daemon-reload
				systemctl enable ip6tables.service
			fi
		fi
	fi
	# Find out if the machine uses nogroup or nobody for the permissionless group
	if grep -qs "^nogroup:" /etc/group; then
		NOGROUP=nogroup
	else
		NOGROUP=nobody
	fi

	# Setup logging and logrotate
	mkdir /var/log/openvpn
	echo -e "/var/log/openvpn/openvpn.log {
 missingok
 notifempty
 copytruncate
 compress
 delaycompress
 daily
 rotate 7
 create 0600 root root
}" > /etc/logrotate.d/openvpn

	# An old version of easy-rsa was available by default in some openvpn packages
	if [[ -d /etc/openvpn/easy-rsa/ ]]; then
		rm -rf /etc/openvpn/easy-rsa/
	fi
	# Get easy-rsa
	wget -O ~/EasyRSA-3.0.4.tgz https://github.com/OpenVPN/easy-rsa/releases/download/v3.0.4/EasyRSA-3.0.4.tgz
	tar xzf ~/EasyRSA-3.0.4.tgz -C ~/
	mv ~/EasyRSA-3.0.4/ /etc/openvpn/
	mv /etc/openvpn/EasyRSA-3.0.4/ /etc/openvpn/easy-rsa/
	chown -R root:root /etc/openvpn/easy-rsa/
	rm -f ~/EasyRSA-3.0.4.tgz
	cd /etc/openvpn/easy-rsa/ || return
	# Generate a random, alphanumeric identifier of 16 characters for CN and one for server name
	SERVER_CN="cn_$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 16 | head -n 1)"
	SERVER_NAME="server_$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 16 | head -n 1)"
	echo "set_var EASYRSA_KEY_SIZE $RSA_KEY_SIZE" > vars
	echo "set_var EASYRSA_REQ_CN $SERVER_CN" >> vars
	# Create the PKI, set up the CA, the DH params and the server + client certificates
	./easyrsa init-pki
	./easyrsa --batch build-ca nopass
	openssl dhparam -out dh.pem $DH_KEY_SIZE
	./easyrsa build-server-full $SERVER_NAME nopass
	case $pass in
 		1)
 			./easyrsa build-client-full $CLIENT nopass
 		;;
 		2)
 			echo "⚠️ You will be asked for the client password below ⚠️"
 			./easyrsa build-client-full $CLIENT
 		;;
 	esac
	EASYRSA_CRL_DAYS=3650 ./easyrsa gen-crl
	# generate tls-auth key
	openvpn --genkey --secret /etc/openvpn/tls-auth.key
	# Move all the generated files
	cp pki/ca.crt pki/private/ca.key dh.pem pki/issued/$SERVER_NAME.crt pki/private/$SERVER_NAME.key /etc/openvpn/easy-rsa/pki/crl.pem /etc/openvpn
	# Make cert revocation list readable for non-root
	chmod 644 /etc/openvpn/crl.pem

	# Generate ipv6 server.conf
	if [[ "$IPV6E" = '1' ]]; then
		echo -e "#IPv6 config start
server-ipv6 fd6c:62d9:eb8c::/112" > /etc/openvpn/server.conf
		echo "proto $(echo $PROTOCOL | tr '[:upper:]' '[:lower:]')6" >> /etc/openvpn/server.conf
		echo -e 'tun-ipv6
push tun-ipv6
push "route-ipv6 2000::/3"
push "redirect-gateway ipv6"
#IPv6 config end
' >> /etc/openvpn/server.conf
	fi

	# Generate ipv4 server.conf
	echo "port $PORT" >> /etc/openvpn/server.conf
	echo "proto $(echo $PROTOCOL | tr '[:upper:]' '[:lower:]')6" >> /etc/openvpn/server.conf
	echo "dev tun
user nobody
group $NOGROUP
persist-key
persist-tun
keepalive 10 120
topology subnet
server 10.8.0.0 255.255.255.0
ifconfig-pool-persist ipp.txt" >> /etc/openvpn/server.conf
	# DNS resolvers
	case $DNS in
		1)
		# Locate the proper resolv.conf
 		# Needed for systems running systemd-resolved
 		if grep -q "127.0.0.53" "/etc/resolv.conf"; then
 			RESOLVCONF='/run/systemd/resolve/resolv.conf'
 		else
 			RESOLVCONF='/etc/resolv.conf'
 		fi
		# Obtain the resolvers from resolv.conf and use them for OpenVPN
		grep -v '#' $RESOLVCONF | grep 'nameserver' | grep -E -o '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | while read -r line; do
			echo "push \"dhcp-option DNS $line\"" >> /etc/openvpn/server.conf
		done
		;;
		2) # Cloudflare
 		echo 'push "dhcp-option DNS 1.0.0.1"' >> /etc/openvpn/server.conf
 		echo 'push "dhcp-option DNS 1.1.1.1"' >> /etc/openvpn/server.conf
 		;;
		3) #Quad9
		echo 'push "dhcp-option DNS 9.9.9.9"' >> /etc/openvpn/server.conf
		echo 'push "dhcp-option DNS 149.112.112.112"' >> /etc/openvpn/server.conf
		;;
		4) #FDN
		echo 'push "dhcp-option DNS 80.67.169.40"' >> /etc/openvpn/server.conf
		echo 'push "dhcp-option DNS 80.67.169.12"' >> /etc/openvpn/server.conf
		;;
		5) #DNS.WATCH
		echo 'push "dhcp-option DNS 84.200.69.80"' >> /etc/openvpn/server.conf
		echo 'push "dhcp-option DNS 84.200.70.40"' >> /etc/openvpn/server.conf
		;;
		6) #OpenDNS
		echo 'push "dhcp-option DNS 208.67.222.222"' >> /etc/openvpn/server.conf
		echo 'push "dhcp-option DNS 208.67.220.220"' >> /etc/openvpn/server.conf
		;;
		7) #Google
		echo 'push "dhcp-option DNS 8.8.8.8"' >> /etc/openvpn/server.conf
		echo 'push "dhcp-option DNS 8.8.4.4"' >> /etc/openvpn/server.conf
		;;
		8) #Yandex Basic
		echo 'push "dhcp-option DNS 77.88.8.8"' >> /etc/openvpn/server.conf
		echo 'push "dhcp-option DNS 77.88.8.1"' >> /etc/openvpn/server.conf
		;;
		9) #AdGuard DNS
		echo 'push "dhcp-option DNS 176.103.130.130"' >> /etc/openvpn/server.conf
		echo 'push "dhcp-option DNS 176.103.130.131"' >> /etc/openvpn/server.conf
		;;
	esac
echo 'push "redirect-gateway def1 bypass-dhcp" ' >> /etc/openvpn/server.conf
echo "crl-verify crl.pem
ca ca.crt
cert $SERVER_NAME.crt
key $SERVER_NAME.key
tls-auth tls-auth.key 0
dh dh.pem
auth SHA256
$CIPHER
tls-server
tls-version-min 1.2
tls-cipher TLS-DHE-RSA-WITH-AES-128-GCM-SHA256
status /var/log/openvpn/status.log
log-append /var/log/openvpn/server.log
verb 3
mute 3
sndbuf 393216
rcvbuf 393216" >> /etc/openvpn/server.conf
	echo 'push "sndbuf 393216"' >> /etc/openvpn/server.conf
	echo 'push "rcvbuf 393216"' >> /etc/openvpn/server.conf

	# Create log dir
	mkdir -p /var/log/openvpn

	# Create the sysctl configuration file if needed
	if [[ ! -e $SYSCTL ]]; then
		touch $SYSCTL
	fi

	# Enable net.ipv4.ip_forward for the system
	echo 'net.ipv4.ip_forward=1' >> $SYSCTL
	# Avoid an unneeded reboot
	echo 1 > /proc/sys/net/ipv4/ip_forward

	# Enable net.ipv6.ip_forward for the system
	if [[ "$IPV6E" = '1' ]]; then
		echo 'net.ipv6.conf.all.forwarding=1' >> $SYSCTL
		# Avoid an unneeded reboot
		echo 1 > /proc/sys/net/ipv6/conf/all/forwarding
	fi

	# Set NAT for the VPN subnet
	iptables -t nat -A POSTROUTING -o $NIC -s 10.8.0.0/24 -j MASQUERADE

	# Save persitent iptables rules
	iptables-save > $IPTABLES

	if pgrep firewalld; then
		# We don't use --add-service=openvpn because that would only work with
		# the default port. Using both permanent and not permanent rules to
		# avoid a firewalld reload.
		if [[ "$PROTOCOL" = 'UDP' ]]; then
			firewall-cmd --zone=public --add-port=$PORT/udp
			firewall-cmd --permanent --zone=public --add-port=$PORT/udp
		elif [[ "$PROTOCOL" = 'TCP' ]]; then
			firewall-cmd --zone=public --add-port=$PORT/tcp
			firewall-cmd --permanent --zone=public --add-port=$PORT/tcp
		fi
		firewall-cmd --zone=trusted --add-source=10.8.0.0/24
		firewall-cmd --permanent --zone=trusted --add-source=10.8.0.0/24
	fi

	if iptables -L -n | grep -qE 'REJECT|DROP'; then
		# If iptables has at least one REJECT rule, we asume this is needed.
		# Not the best approach but I can't think of other and this shouldn't
		# cause problems.
		if [[ "$PROTOCOL" = 'UDP' ]]; then
			iptables -I INPUT -p udp --dport $PORT -j ACCEPT
		elif [[ "$PROTOCOL" = 'TCP' ]]; then
			iptables -I INPUT -p tcp --dport $PORT -j ACCEPT
		fi
		iptables -I FORWARD -s 10.8.0.0/24 -j ACCEPT
		iptables -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
		iptables -I INPUT -i tun+ -j ACCEPT
		# Save persitent OpenVPN rules
        iptables-save > $IPTABLES
	fi

	if [[ "$IPV6E" = '1' ]]; then
		# Set NAT for the VPN subnet
		ip6tables -t nat -A POSTROUTING -o $NIC6 -s fd6c:62d9:eb8c::/112 -j MASQUERADE
		# Save persitent iptables rules
		ip6tables-save > $IP6TABLES

		if ip6tables -L -n | grep -qE 'REJECT|DROP'; then
			# If ip6tables has at least one REJECT rule, we asume this is needed.
			# Not the best approach but I can't think of other and this shouldn't
			# cause problems.
			if [[ "$PROTOCOL" = 'UDP' ]]; then
				ip6tables -I INPUT -p udp --dport $PORT -j ACCEPT
			elif [[ "$PROTOCOL" = 'TCP' ]]; then
				ip6tables -I INPUT -p tcp --dport $PORT -j ACCEPT
			fi
			ip6tables -I FORWARD -s fd6c:62d9:eb8c::/112 -j ACCEPT
			ip6tables -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
			ip6tables -I INPUT -i tun+ -j ACCEPT
			# Save persitent OpenVPN rules
			ip6tables-save > $IP6TABLES
		fi
	fi

	# If SELinux is enabled and a custom port was selected, we need this
	if hash sestatus 2>/dev/null; then
		if sestatus | grep "Current mode" | grep -qs "enforcing"; then
			if [[ "$PORT" != '1194' ]]; then
				# semanage isn't available in CentOS 6 by default
				if ! hash semanage 2>/dev/null; then
					apt install policycoreutils-python-utils -y
				fi
				if [[ "$PROTOCOL" = 'UDP' ]]; then
					semanage port -a -t openvpn_port_t -p udp $PORT
				elif [[ "$PROTOCOL" = 'TCP' ]]; then
					semanage port -a -t openvpn_port_t -p tcp $PORT
				fi
			fi
		fi
	fi

	# And finally, restart OpenVPN
	if pgrep systemd-journal; then
		systemctl restart openvpn@server.service
		systemctl enable openvpn@server.service
	else
		service openvpn restart
		chkconfig openvpn on
	fi

	# If the server is behind a NAT, use the correct IP address
	if [[ "$PUBLICIP" != "" ]]; then
		IP=$PUBLICIP
	fi

	# client-template.txt is created so we have a template to add further users later
	echo "client" > /etc/openvpn/client-template.txt
	if [[ "$PROTOCOL" = 'UDP' ]]; then
		echo "proto udp" >> /etc/openvpn/client-template.txt
	elif [[ "$PROTOCOL" = 'TCP' ]]; then
		echo "proto tcp-client" >> /etc/openvpn/client-template.txt
	fi
	echo "remote $IP
port $PORT
dev tun
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
verify-x509-name $SERVER_NAME name
auth SHA256
auth-nocache
$CIPHER
tls-client
tls-version-min 1.2
tls-cipher TLS-DHE-RSA-WITH-AES-128-GCM-SHA256
setenv opt block-outside-dns
verb 3
ping 10
float" >> /etc/openvpn/client-template.txt

	# Generate the custom client.ovpn
	newclient "$CLIENT"
	echo ""
	echo "Finished!"
	echo ""
	echo "Your client config is available at $homeDir/$CLIENT.ovpn"
	echo "If you want to add more clients, you simply need to run this script another time!"
fi
exit 0;
