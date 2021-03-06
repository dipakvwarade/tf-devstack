#!/bin/bash

function is_registry_insecure() {
    echo "DEBUG: is_registry_insecure: $@"
    local registry=`echo $1 | sed 's|^.*://||' | cut -d '/' -f 1`
    if  curl -s -I --connect-timeout 60 http://$registry/v2/ ; then
        echo "DEBUG: is_registry_insecure: $registry is insecure"
        return 0
    fi
    echo "DEBUG: is_registry_insecure: $registry is secure"
    return 1
}

function collect_stack_details() {
    local log_dir=$1
    [ -n "$log_dir" ] || {
        echo "WARNING: empty log_dir provided.. logs collection skipped"
        return
    }
    source ~/stackrc
    # collect stack details
    echo "INFO: collect stack outputs"
    openstack stack output show -f json --all overcloud | sed 's/\\n/\n/g' > ${log_dir}/stack_outputs.log
    echo "INFO: collect stack environment"
    openstack stack environment show -f json overcloud | sed 's/\\n/\n/g' > ${log_dir}/stack_environment.log

    # ensure stack is not failed
    status=$(openstack stack show -f json overcloud | jq ".stack_status")
    if [[ ! "$status" =~ 'COMPLETE' ]] ; then
        echo "ERROR: stack status $status"
        echo "ERROR: openstack stack failures list"
        openstack stack failures list --long overcloud | sed 's/\\n/\n/g' | tee ${log_dir}/stack_failures.log

        echo "INFO: collect failed resources"
        rm -f ${log_dir}/stack_failed_resources.log
        local name
        openstack stack resource list --filter status=FAILED -n 10 -f json overcloud | jq -r -c ".[].resource_name" | while read name ; do
            echo "ERROR: $name" >> ./stack_failed_resources.log
            openstack stack resource show -f shell overcloud $name | sed 's/\\n/\n/g' >> ${log_dir}/stack_failed_resources.log
            echo -e "\n\n" >> ./stack_failed_resources.log
        done

        echo "INFO: collect failed deployments"
        rm -f ${log_dir}/stack_failed_deployments.log
        local id
        openstack software deployment list --format json | jq -r -c ".[] | select(.status != \"COMPLETE\") | .id" | while read id ; do
            openstack software deployment show --format shell $id | sed 's/\\n/\n/g' >> ${log_dir}/stack_failed_deployments.log
            echo -e "\n\n" >> ./stack_failed_deployments.log
        done
    fi
}

function get_servers_ips() {
    if [[ -n "$overcloud_cont_prov_ip" ]]; then
        echo "$overcloud_cont_prov_ip $overcloud_compute_prov_ip $overcloud_ctrlcont_prov_ip"
        return
    fi
    [[ -z "$OS_AUTH_URL" ]] && source ~/stackrc
    openstack server list -c Networks -f value | awk -F '=' '{print $NF}' | xargs
}

function get_servers_ips_by_name() {
    local name=$1
    [[ -n "$overcloud_cont_prov_ip" && "$name" == 'controller' ]] && echo $overcloud_cont_prov_ip && return
    [[ -n "$overcloud_ctrlcont_prov_ip" && "$name" == 'contrailcontroller' ]] && echo $overcloud_ctrlcont_prov_ip && return
    [[ -n "$overcloud_compute_prov_ip" && "$name" == 'novacompute' ]] && echo $overcloud_compute_prov_ip && return

    [[ -z "$OS_AUTH_URL" ]] && source ~/stackrc
    openstack server list -c Name -c Networks -f value | grep "overcloud-${name}-" | awk -F '=' '{print $NF}' | xargs
}

function get_vip() {
    local vip_name=$1
    local openstack_node=$(get_servers_ips_by_name controller | awk '{print $1}')
    ssh $ssh_opts $SSH_USER@$openstack_node sudo hiera -c /etc/puppet/hiera.yaml $vip_name
}

function get_openstack_node_ips() {
    local name=$1
    local subdomain=$2
    local openstack_node=$(get_servers_ips_by_name controller | awk '{print $1}')
    ssh $ssh_opts $SSH_USER@$openstack_node \
         cat /etc/hosts | grep overcloud-${name}-[0-9]\.${subdomain} | awk '{print $1}'| xargs
}

function collect_overcloud_env() {
    if [[ "${DEPLOY_COMPACT_AIO,,}" == 'true' ]] ; then
        CONTROLLER_NODES=$(get_servers_ips_by_name controller)
        AGENT_NODES="$CONTROLLER_NODES"
    elif [[ "${ENABLE_NETWORK_ISOLATION,,}" = true ]] ; then
        CONTROLLER_NODES="$(get_openstack_node_ips contrailcontroller internalapi)"
        AGENT_NODES="$(get_servers_ips_by_name novacompute) $(get_servers_ips_by_name contraildpdk) $(get_servers_ips_by_name contrailsriov)"
        DEPLOYMENT_ENV['OPENSTACK_CONTROLLER_NODES']=$(get_openstack_node_ips controller internalapi)
        DEPLOYMENT_ENV['CONTROL_NODES']="$(get_openstack_node_ips contrailcontroller tenant | tr ' ' ',')"
    else
        CONTROLLER_NODES=$(get_servers_ips_by_name contrailcontroller)
        AGENT_NODES=$(get_servers_ips_by_name novacompute)
    fi
        DEPLOYMENT_ENV['DPDK_AGENT_NODES']=$(get_servers_ips_by_name contraildpdk)
    if [[ -f ~/overcloudrc ]] ; then
        source ~/overcloudrc
        DEPLOYMENT_ENV['AUTH_URL']=$(echo ${OS_AUTH_URL} | sed "s/overcloud/overcloud.internalapi/")
        DEPLOYMENT_ENV['AUTH_PASSWORD']="${OS_PASSWORD}"
        DEPLOYMENT_ENV['AUTH_REGION']="${OS_REGION_NAME}"
        DEPLOYMENT_ENV['AUTH_PORT']="35357"
    fi
}

function collect_deployment_log() {
    #Collecting undercloud logs
    local host_name=$(hostname -s)
    create_log_dir
    mkdir ${TF_LOG_DIR}/${host_name}
    collect_system_stats $host_name
    collect_stack_details ${TF_LOG_DIR}/${host_name}
    if [[ -e /var/lib/mistral/overcloud/ansible.log ]] ; then
        cp /var/lib/mistral/overcloud/ansible.log ${TF_LOG_DIR}/${host_name}/
    fi

    #Collecting overcloud logs
    local ip=''
    for ip in $(get_servers_ips); do
        scp $ssh_opts $my_dir/../common/collect_logs.sh $SSH_USER@$ip:
        cat <<EOF | ssh $ssh_opts $SSH_USER@$ip
            export TF_LOG_DIR="/home/$SSH_USER/logs"
            cd /home/$SSH_USER
            ./collect_logs.sh create_log_dir
            ./collect_logs.sh collect_docker_logs
            ./collect_logs.sh collect_system_stats
            ./collect_logs.sh collect_contrail_logs
EOF
        source_name=$(ssh $ssh_opts $SSH_USER@$ip hostname -s)
        mkdir ${TF_LOG_DIR}/${source_name}
        scp -r $ssh_opts $SSH_USER@$ip:logs/* ${TF_LOG_DIR}/${source_name}/
    done

    # Save to archive all yaml files and tripleo templates
    tar -czf ${TF_LOG_DIR}/tht.tgz -C ~ *.yaml tripleo-heat-templates

    tar -czf ${WORKSPACE}/logs.tgz -C ${TF_LOG_DIR}/.. logs

    set -e
}

function set_rhosp_version() {
    case "$OPENSTACK_VERSION" in
    "queens" )
        export RHEL_VERSION='rhel7'
        export RHOSP_VERSION='rhosp13'
        ;;
    "train" )
        export RHEL_VERSION='rhel8'
        export RHOSP_VERSION='rhosp16'
        ;;
    *)
        echo "Variable OPENSTACK_VERSION is unset or incorrect"
        exit 1
        ;;
esac
}

function add_vlan_interface() {
    local vlan_id=$1
    local phys_dev=$2
    local ip_addr=$3
    local net_mask=$4
sudo tee /etc/sysconfig/network-scripts/ifcfg-${vlan_id} > /dev/null <<EOF
# This file is autogenerated by tf-devstack
ONBOOT=yes
BOOTPROTO=static
HOTPLUG=no
NM_CONTROLLED=no
PEERDNS=no
USERCTL=yes
VLAN=yes
DEVICE=$vlan_id
PHYSDEV=$phys_dev
IPADDR=$ip_addr
NETMASK=$net_mask
EOF
    ifdown ${vlan_id}
    ifup ${vlan_id}
}
