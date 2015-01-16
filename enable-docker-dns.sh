#!/bin/sh

#Change these to change the configuration of the private host network
# IP address of the host on the private VM network
B2D_HOST='172.16.0.1'
# IP address of the boot2docker VM on the private host network
B2D_IP='172.16.0.11'

# The below ranges are the defaults of Docker and Kubernetes.
# This script does not change the configuration of either program so don't change these.
# CIDR range of the Docker containers
DOCKER_RANGE='172.17.0.0/16'
# CIDR range of the Kubernetes services
KUBE_RANGE='172.30.17.0/24'

# Bootup script added to boot2docker VM.
bootlocal_script=$(cat <<-SCRIPTEND
	#!/bin/sh
	ifconfig eth1 $B2D_IP netmask 255.255.255.0

	/etc/init.d/docker restart

	docker pull skynetservices/skydns:latest
	docker pull openshift/origin:latest

	# get current nameservers as a comma seperated list
	NAMESERVERS=\`grep ^nameserver /etc/resolv.conf | awk '{ print \$2":53" }' | sed 's/,$/\n/'\`

	docker stop openshift skydns
	docker rm openshift skydns

	docker run -d --name openshift -v /var/run/docker.sock:/var/run/docker.sock \\
	--net=host --privileged openshift/origin start

	docker run -d --name skydns --net=host skynetservices/skydns -kubernetes \\
	-master=http://localhost:8080 -addr=$B2D_IP:53 -nameservers=\$NAMESERVERS -domain=docker
SCRIPTEND
)
# boot2docker profile script used to configure docker daemon
profile_script=$(cat <<-SCRIPTEND
	DOCKER_TLS=no
	EXTRA_ARGS="--dns=$B2D_IP --insecure-registry docker.intranet.qualys.com:5000"
SCRIPTEND
)

function printOK {
  if [ $? == 0 ];
  then
    echo "$(tput setaf 2)[OK]$(tput sgr0)"
  else
    echo "$(tput setaf 1)[FAIL]$(tput sgr0)"
  fi
}

# check if root or sudo
#[ $(id -u) = 0 ] || { echo "You must be root (or use 'sudo')" ; exit 1; }

# check if the necissary commands are installed
command -v boot2docker > /dev/null 2>&1 || { echo >&2 "boot2docker command not found." ; exit 1; }
command -v VBoxManage > /dev/null 2>&1 || { echo >&2 "VBoxManage command not found." ; exit 1; }

# check if boot2docker-vm exists
VBoxManage list vms | grep boot2docker-vm > /dev/null 2>&1
if [ $? == 1 ]; # VM does not exist
then
  printf "*** boot2docker-vm not found. Creating ... "
  boot2docker init --dhcp=false --hostip=$B2D_HOST > /dev/null 2>&1
  printOK
else
  echo "*** Found existing boot2docker-vm. Remove it (boot2docker destroy) and rerun this script if docker is acting odd."
fi

printf "*** Booting boot2docker-vm ... "
boot2docker up > /dev/null 2>&1
printOK

printf "*** Configuring eth1 to $B2D_IP ... "
boot2docker ssh "sudo ifconfig eth1 $B2D_IP netmask 255.255.255.0"
printOK

printf "*** Writing startup script ... "
boot2docker ssh sudo tee /var/lib/boot2docker/bootlocal.sh > /dev/null 2>&1 <<SCRIPTEND
$bootlocal_script
SCRIPTEND
[ $? = 0 ] && boot2docker ssh sudo chmod a+x /var/lib/boot2docker/bootlocal.sh
printOK

printf "*** Configuring Docker daemon ... "
boot2docker ssh sudo tee /var/lib/boot2docker/profile > /dev/null 2>&1 <<SCRIPTEND
$profile_script
SCRIPTEND
printOK

printf "*** Setting up route from this host to containers ... "
sudo route -n add $DOCKER_RANGE $B2D_IP > /dev/null 2>&1
[ $? = 0 ] && sudo route -n add $KUBE_RANGE $B2D_IP > /dev/null 2>&1
printOK

printf "*** Configuring DNS client to resolve .docker hostnames ... "
sudo echo "nameserver $B2D_IP" > /etc/resolver/docker
printOK

printf "*** Restarting VM ... "
boot2docker restart > /dev/null 2>&1
printOK

echo ""
echo "--- boot2docker configured and started ---"
echo ""
echo "Please add the following to .bash_profile:"
boot2docker shellinit
echo "    export KUBERNETES_MASTER=$B2D_IP:8080"
echo "    alias dockup='boot2docker up && sudo route -n add $DOCKER_RANGE $B2D_IP && sudo route -n add $KUBE_RANGE $B2D_IP'"
echo ""
echo "After rebooting, use the 'dockup' command to start the boot2docker VM.  This will re-initialize the required routes."
