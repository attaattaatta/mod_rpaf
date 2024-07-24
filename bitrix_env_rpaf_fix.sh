#!/bin/bash
# enable debug
#set -x -v

# exit 1 if any error
set -e -o verbose

#set -o verbose
#pipefail | verbose

# set colors
GCV="\033[0;92m"
LRV="\033[1;91m"
YCV="\033[01;33m"
NCV="\033[0m"

check_free_space_func() {

printf "\n${GCV}Checking free space${NCV}"
current_free_space=$(df -Pm --sync / | awk '{print $4}' | tail -n 1)
space_need_megabytes="1000"
if [[ $current_free_space -le $space_need_megabytes ]]
then
        printf " - ${LRV}FAIL${NCV}";
	exit 1
else
	printf " - ${GCV}OK${NCV}\n"
fi
}

# check privileges
if [[ $EUID -ne 0 ]]
then
        printf "\n${LRV}ERROR - This script must be run as root.${NCV}\n"
        exit 1
fi

# check bitrix env
if [ ! -f /opt/webdir/bin/bx-sites ]; then
	printf "${LRV}NOT BITRIX ENV${NCV}";
	exit 1
fi

# check free space
check_free_space_func

# fixing paths
export PATH=$PATH:/usr/sbin:/usr/sbin:/usr/local/sbin

# GET IPs
printf "${GCV}GETTING IPs${NCV}\n"
CURRENT_IPs=$(ip a s | grep -E "^\\s*inet" | grep -v inet6| grep -m2 global | grep -vE '192\.168|172\.16\.|^/(?!peer)([[:space:]]|\.)10\.' | awk "{ print \$2 }" | sed ':a;N;$!ba;s@\n@ @gi' | sed "s|/.*\s| |" |  sed "s|/.*$||");

printf "${GCV}${CURRENT_IPs}${NCV}\n"

# apache2
printf "${GCV}APACHE2 FIX${NCV}\n"

{
REL=$(cat /etc/*release* | head -n 1)
if echo $REL | grep -i centos | grep -i 7
then
	sed -i "s/^mirrorlist=/#mirrorlist=/g" /etc/yum.repos.d/CentOS-*
	sed -i "s|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g" /etc/yum.repos.d/CentOS-*
	yum --enablerepo=updates clean metadata
fi
} > /dev/null 2>&1

yum -y groupinstall "Development Tools"
yum -y install wget httpd-devel
wget -O /tmp/mod_rpaf.c https://raw.githubusercontent.com/attaattaatta/mod_rpaf/stable/mod_rpaf.c
apxs -c -i /tmp/mod_rpaf.c

mv /etc/httpd/bx/conf/mod_rpaf.conf /etc/httpd/bx/conf/mod_rpaf.disabled_conf || true
mv /etc/httpd/bx-scale/conf/mod_rpaf.conf /etc/httpd/bx-scale/conf/mod_rpaf.disabled_conf || true

> /etc/httpd/bx/custom/rpaf.conf || true

cat <<EOT >> /etc/httpd/bx/custom/rpaf.conf
LoadModule              rpaf_module modules/mod_rpaf.so
RPAF_Enable             On
RPAF_ProxyIPs           127.0.0.1 ::1 ${CURRENT_IPs}
RPAF_SetHostName        On
RPAF_SetHTTPS           On
RPAF_SetPort            On
RPAF_ForbidIfNotProxy   Off
EOT

sed -i 's@^LoadModule remoteip_module@#LoadModule remoteip_module@gi' /etc/httpd/conf.modules.d/00-base.conf || true
sed -i 's@^LogFormat "%h@LogFormat "%a@gi' /etc/httpd/conf/httpd.conf || true
sed -i 's@^LogFormat "%h@LogFormat "%a@gi' /etc/httpd/conf/httpd-scale.conf || true

/usr/sbin/apachectl configtest
systemctl restart httpd*

# nginx
printf "${GCV}NGINX FIX${NCV}\n"
grep -RiIl "\$host:443;" /etc/nginx/bx/ | xargs sed -i 's@\$host:443;@\$host;\n    proxy_set_header \tX-Forwarded-Proto \$scheme;\n@gi' || true
grep -RiIl "\$host:80;" /etc/nginx/bx/ | xargs sed -i 's@\$host:80;@\$host;\n\t\tproxy_set_header \tX-Forwarded-Proto \$scheme;\n@gi' || true
/usr/sbin/nginx -t && /usr/sbin/nginx -s reload

# done
printf "${GCV}DONE WELL${NCV}\n"
exit 0