# OpenVPN-installer

OpenVPN installer for Raspberry Pi.

This script will let you setup your own secure VPN server.

Users with DS-Lite it's recommanded to first read the chapter [DS-Lite](/DS-Lite).

## Usage

First, make sure IPv6 is enabled

```bash
modprobe ipv6
```

Secondly, get the script and make it executable :

```bash
https://raw.githubusercontent.com/lordnik22/OpenVPN-Installer/master/openvpn-install.sh
chmod +x openvpn-install.sh
```

Thirdly, run it :

`./openvpn-install.sh`

The first time you run it, you'll have to follow the assistant and answer a few questions to setup your VPN server.

An example how to answer is provided in [Example](example.txt).

When OpenVPN is installed, you can run the script again, and you will get the choice to :
- Add a client
- Remove a client
- Uninstall OpenVPN

## DS-Lite

### Universale Port Mapper
I use a Universale Port-Mapper at feste-ip.net. This makes it possible
to access my home-network while I am connect from a IPv4-Network (e.g.
most mobilphone-networks are in IPv4). They only support TCP (never
tested with UDP).

If you use such a port-mapper you need to provide the DNS or IP of
that port-mapper instead of your device-ip.

I had to adjust the port in the client-file to the port they assigned to me.

For the IPv6 Target Port I could use the default OpenVPN port: 1194.

For the hostname I used my DDNS from no-ip.

### DDNS

I use a DDNS from no-ip.net. This makes it possible to access your
home-network even if your ISP changes the IPv6 (untested). In theory
the IPv6 should never change but I still use it because I already used
it with my old ISP with IPv4.

## The fork of the fork of the fork

This script is based on the great work of [Nyr and its contributors](https://github.com/Nyr/openvpn-install), [Angristan and its contributors](https://github.com/Angristan/OpenVPN-install) and [WMtech-1 and its contributors](https://github.com/wmtech-1/OpenVPN-Installer).

While I was at my old ISP with IPv4 I used the script from Nyr. Now I
am at a new ISP which uses DS-Lite. I therefore wanted to setup a
OpenVPN that is accessible over IPv6. I searched for similar projects
and found the script from WMtech-1 and adjusted it to my need until it
worked.

## Forward to VMtech-1 for more details

See [WMtech-1 and its contributors](https://github.com/wmtech-1/OpenVPN-Installer).

## Credits & Licence

Thanks to VMtech-1, the respective [contributors](https://github.com/wmtech-1/OpenVPN-Installer/graphs/contributors), Angristan and of course Nyr's orginal work.

[MIT Licence](https://raw.githubusercontent.com/wmtech-1/OpenVPN-Installer/master/LICENSE)
