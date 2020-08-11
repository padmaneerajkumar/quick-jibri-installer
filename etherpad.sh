#!/bin/bash
# Etherpad Installer for Jitsi Meet
# SwITNet Ltd  Â© - 2020, https://switnet.net/
#
# GPLv3 or later.

while getopts m: option
do
	case "${option}"
	in
		m) MODE=${OPTARG};;
		\?) echo "Usage: sudo ./etherpad.sh [-m debug]" && exit;;
	esac
done

#DEBUG
if [ "$MODE" = "debug" ]; then
set -x
fi

if ! [ $(id -u) = 0 ]; then
   echo "You need to be root or have sudo privileges!"
   exit 0
fi

clear
echo '
########################################################################
                         Etherpad Docker addon
########################################################################
                    by Software, IT & Networks Ltd
'

check_apt_policy() {
apt-cache policy 2>/dev/null| \
grep http | \
grep $1 | \
awk '{print $3}' | \
head -n 1 | \
cut -d "/" -f2
}
install_ifnot() {
if [ "$(dpkg-query -W -f='${Status}' $1 2>/dev/null | grep -c "ok installed")" == "1" ]; then
	echo " $1 is installed, skipping..."
    else
    	echo -e "\n---- Installing $1 ----"
		apt-get -yq2 install $1
fi
}
DOMAIN=$(ls /etc/prosody/conf.d/ | grep -v localhost | awk -F'.cfg' '{print $1}' | awk '!NF || !seen[$0]++')
MEET_CONF="/etc/jitsi/meet/$DOMAIN-config.js"
WS_CONF="/etc/nginx/sites-enabled/$DOMAIN.conf"
PSGVER="$(apt-cache madison postgresql | head -n1 | awk '{print $3}' | cut -d "+" -f1)"
ETHERPAD_DB_USER="dockerpad"
ETHERPAD_DB_NAME="etherpad"
ETHERPAD_DB_PASS="$(tr -dc "a-zA-Z0-9#*=" < /dev/urandom | fold -w 10 | head -n1)"
DOCKER_CE_REPO="$(check_apt_policy docker)"

echo "Add Docker repo"
if [ "$DOCKER_CE_REPO" = "stable" ]; then
	echo "Docker repository already installed"
else
	echo "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker-ce.list
	wget -qO - https://download.docker.com/linux/ubuntu/gpg | apt-key add -
	apt -q2 update
fi

read -p "Set your etherpad docker admin password: " -r ETHERPAD_ADMIN_PASS

# Install required packages
install_ifnot docker-ce
install_ifnot postgresql-$PSGVER

# Create DB
sudo -u postgres psql <<DB
CREATE DATABASE ${ETHERPAD_DB_NAME};
CREATE USER ${ETHERPAD_DB_USER} WITH ENCRYPTED PASSWORD '${ETHERPAD_DB_PASS}';
GRANT ALL PRIVILEGES ON DATABASE ${ETHERPAD_DB_NAME} TO ${ETHERPAD_DB_USER};
DB
echo "Done!
"

# Check fot docker if not running then execute
if [ ! "$(docker ps -q -f name=etherpad)" ]; then
    if [ "$(docker ps -aq -f status=exited -f name=etherpad)" ]; then
        # cleanup
        docker rm etherpad
    fi
    # run your container
    docker run -d \
	--name etherpad         \
	-p 9001:9001            \
	-e 'IP=127.0.0.1'            \
	-e 'ADMIN_PASSWORD=$ETHERPAD_ADMIN_PASS' \
	-e 'DB_TYPE=postgres'   \
	-e 'DB_HOST=localhost'   \
	-e 'DB_PORT=5432'       \
	-e 'DB_NAME=$ETHERPAD_DB_NAME'   \
	-e 'DB_USER=$ETHERPAD_DB_USER' \
	-e 'DB_PASS=$ETHERPAD_DB_PASS' \
	etherpad/etherpad
fi

# Tune webserver for Jitsi App control

if [ $(grep -c "etherpad" $WS_CONF) != 0 ]; then
    echo "Webserver seems configured, skipping..."
elif [ -f $WS_CONF ]; then
    echo "Configuring webserver file..."
	sed -i "/Anything that didn't match above/i \ \ \ \ location \^\~\ \/etherpad\/ {" $WS_CONF
	sed -i "/Anything that didn't match above/i \ \ \ \ \ \ \ \ proxy_pass http:\/\/localhost:9001\/;" $WS_CONF
	sed -i "/Anything that didn't match above/i \ \ \ \ \ \ \ \ proxy_set_header X-Forwarded-For \$remote_addr;" $WS_CONF
	sed -i "/Anything that didn't match above/i \ \ \ \ \ \ \ \ proxy_buffering off;" $WS_CONF
    sed -i "/Anything that didn't match above/i \ \ \ \ \ \ \ \ proxy_set_header       Host \$host;" $WS_CONF
	sed -i "/Anything that didn't match above/i \ \ \ \ }" $WS_CONF
	sed -i "/Anything that didn't match above/i \\\n" $WS_CONF
else
	echo "No etherpad config done to server file, please report to:
    -> https://github.com/switnet-ltd/quick-jibri-installer/issues"
fi
    
# Configure config.js
if [ $(grep -c "etherpad_base" $WS_CONF) != 0 ]; then
    echo "$MEET_CONF seems configured, skipping..."
else
    echo "Setting etherpad domain at $MEET_CONF..."
    sed -i "/ domain: '$DOMAIN'/a\ \ \ \ \ \ \ \ etherpad_base: \'https://$DOMAIN/etherpad/p/\'," $MEET_CONF
fi

echo "Checking nginx configuration..."
nginx -t 2>/dev/null

if [ $? = 0 ]; then
	echo "Docker configuration seems fine, enabling it..."
	systemctl reload nginx
else
	echo "Please check your configuration, something may be wrong."
	echo "Will not try to enable etherpad nginx configuration, please report to:
    -> https://github.com/switnet-ltd/quick-jibri-installer/issues"
fi
