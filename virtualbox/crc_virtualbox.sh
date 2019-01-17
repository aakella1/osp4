#!/bin/bash

set +x

prerequisites()
{
    # Check if VirtualBox is installed
    if [[ $(vboxmanage --version | head -c1 | wc -c) -eq 0 ]]; then
       echo "Virtualbox is not installed on this system"
       exit 1
    fi
    
    # Check if port 53 is in use already
    if [[ $(lsof -i :53 | head -c1 | wc -c) -ne 0 ]]; then
       echo "Following Process is running on the port 53 check with 'lsof -i :53'"
       exit 1
    fi

    # Check if minishift running
    if pgrep -x "minishift" > /dev/null
    then
        echo "Minishift is running which create issue with coredns"
        echo "Stop or delete the minishift instance"
        exit 1
    fi

    # Check if minikube running
    if pgrep -x "minikube" > /dev/null
    then
        echo "Minikube is running which create issue with coredns"
        echo "Stop the minikube or delete"
        exit 1
    fi
    
    # Backup original Corefile and test1-api file.
    cp Corefile Corefile_bak
    cp test1-api test1-api_bak
    
    # Copy the disk image in the Virtualbox Folder
    mkdir -p  ~/VirtualBox\ VMs/master
    mkdir -p  ~/VirtualBox\ VMs/worker
    rm ~/VirtualBox\ VMs/master/test1-master-0.vmdk
    rm ~/VirtualBox\ VMs/worker/test1-worker-0-98nsr.vmdk
    echo "Copying the vmdk files to ~/VirtualBox\ VMs/ location ..."
    cp test1-master-0.vmdk ~/VirtualBox\ VMs/master
    cp test1-worker-0-98nsr.vmdk ~/VirtualBox\ VMs/worker
}

cluster_create()
{    
    # Create the hostonly address if not exit
    if [[ $(VBoxManage list hostonlyifs | head -c1 | wc -c) -eq 0 ]]; then
       VBoxManage hostonlyif create
    fi
    
    # Master configuration
    VBoxManage createvm --name master --ostype Fedora_64 --register 
    VBoxManage modifyvm master --cpus 2 --memory 8590 --vram 16
    VBoxManage modifyvm master --nic1 hostonly
    VBoxManage modifyvm master --nictype1 virtio
    VBoxManage modifyvm master --hostonlyadapter1 vboxnet0
    VBoxManage modifyvm master --nic2 nat
    VBoxManage modifyvm master --nictype2 virtio
    VBoxManage modifyvm master --macaddress1 3aceb1219fb2
    VBoxManage storagectl master --name "SATA Controller" --add sata --bootable on --portcount 1 
    VBoxManage storageattach master  --storagectl "SATA Controller" --port 0 --device 0 --type hdd --medium ~/VirtualBox\ VMs/master/test1-master-0.vmdk
    
    # Worker configuration
    VBoxManage createvm --name worker --ostype Fedora_64 --register
    VBoxManage modifyvm worker --cpus 2 --memory 3096 --vram 16
    VBoxManage modifyvm worker --nic1 hostonly
    VBoxManage modifyvm worker --nictype1 virtio
    VBoxManage modifyvm worker --hostonlyadapter1 vboxnet0
    VBoxManage modifyvm worker --nic2 nat
    VBoxManage modifyvm worker --nictype1 virtio
    VBoxManage modifyvm worker --macaddress1 080027c72a33
    VBoxManage storagectl worker --name "SATA Controller" --add sata --bootable on --portcount 1
    VBoxManage storageattach worker  --storagectl "SATA Controller" --port 0 --device 0 --type hdd --medium ~/VirtualBox\ VMs/worker/test1-worker-0-98nsr.vmdk
    
    hostonlyip=$(VBoxManage list hostonlyifs | grep IPAddress | head -1 | awk '{print $2}')
   
    update_nameserver
 
    echo "Adding tt.testing to /etc/resolver, It will ask for sudo password"
    # Add nameserver to resolv.conf which VM actually take
    echo "search tt.testing" | sudo tee /etc/resolv.conf
    echo "nameserver $hostonlyip" | sudo tee -a /etc/resolv.conf
    
    # Coredns ip add to resolver (tt.testing)
    sudo mkdir -p /etc/resolver
    echo "nameserver $hostonlyip" | sudo tee /etc/resolver/tt.testing
}

update_nameserver()
{ 
    saveIFS="$IFS"
    IFS=$'\n'
    nameservers=$(scutil --dns | sed -n '/^resolver #1/,/^resolver #2/p;/^resolver #2/q' | grep nameserver | awk '{print $3}')
    IFS="$saveIFS"
    for i in "${nameservers[@]}"; do
       nslookup google.com $i
       if [ $? -eq 0 ]
       then
           i=$(echo $i | tr -d '\r')
           sed -i '' "s/mynameserver/$i/g" Corefile
           break
       fi
    done
}

cluster_start()
{
    check_cluster
    VBoxManage startvm master --type headless
    VBoxManage startvm worker --type headless
    if ! pgrep -x "coredns" > /dev/null 
    then
        modify_corefile
        coredns_start
    fi
}

modify_corefile()
{
    # Get the IP of the master node using arp
    while true; do
        IFS=$'\n'; for line in $(arp -i vboxnet0 -a); do 
          echo $line
          IFS=' ' read -a array <<< $line
          masterIp=$(echo "${array[1]}"|tr "(" " "|tr ")" " ")
          if [ "3a:ce:b1:21:9f:b2" = "${array[3]}" ]; then
            echo "Master IP address is $masterIp"
            break 2
          fi
        done
    done

    # Get the IP of the master node
    while true; do
        IFS=$'\n'; for line in $(arp -i vboxnet0 -a); do 
          echo $line
          IFS=' ' read -a array <<< $line
          workerIp=$(echo "${array[1]}"|tr "(" " "|tr ")" " ")
          if [ "8:0:27:c7:2a:33" = "${array[3]}" ]; then
            echo "Worker IP address is $workerIp"
            break 2
          fi
        done
    done
  
 
    # Run Coredns after editing tt.testing file.
    echo "test1-api     IN      A       $masterIp" | tee -a test1-api
    echo "test1-etcd-0     IN      A    $masterIp" | tee -a test1-api
    echo "test1-master-0     IN      A    $masterIp" | tee -a test1-api
    echo "test1-worker-0-98nsr     IN      A    $workerIp" | tee -a test1-api
}

cluster_stop()
{
    check_cluster
    VBoxManage controlvm master poweroff
    VBoxManage controlvm worker poweroff
}

check_cluster()
{
    VBoxManage list vms | grep -q  master
    if [ $? -ne 0 ]; then
         echo "Cluster is not present"
         usage
         exit 1
    fi
}

cluster_delete()
{
    check_cluster
    cluster_stop
    VBoxManage unregistervm master --delete
    VBoxManage unregistervm worker --delete
    coredns_stop
    if [ -f Corefile_bak ]; then
	rm Corefile && mv Corefile_bak Corefile
    fi
    if [ -f test1-api_bak ]; then
	rm test1-api && mv test1-api_bak test1-api
    fi
}

coredns_start()
{
    echo "Starting Coredns as backgroud process"
    echo "Coredns logs are in /tmp/coredns.log file"
    ./coredns > /tmp/coredns.log 2>&1 &
}

coredns_stop()
{
    echo "Stopping Coredns process"
    pkill coredns
}

usage()
{
    usage="$(basename "$0") [[create | start | stop | delete] | [-h]]
where:
    create - Create the cluster resources
    start  - Start the cluster
    stop   - Stop the cluster
    delete - Delete the cluster
    -h     - Usage message
    "

    echo "$usage"

}

main()
{
    if [ "$#" -ne 1 ]; then
        usage
        exit 0
    fi
    
    while [ "$1" != "" ]; do
        case $1 in
            create )           prerequisites
                               cluster_create
                               ;;
            start )            cluster_start
                               ;;
            stop )             cluster_stop
                               ;;
            delete )           cluster_delete
                               ;;
            -h | --help )      usage
                               exit
                               ;;
            * )                usage
                               exit 1
        esac
        shift
    done
}

main "$@"; exit
