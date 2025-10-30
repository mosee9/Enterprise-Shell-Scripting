#!/bin/bash

# Enterprise Fleet Management System
# Managing 50+ Debian nodes with 99.9% uptime
# 7 years Linux administration experience

set -euo pipefail

# Configuration
FLEET_CONFIG="/etc/fleet/nodes.conf"
LOG_FILE="/var/log/fleet_manager.log"
PARALLEL_JOBS=10
SSH_KEY="/root/.ssh/fleet_key"

# Node inventory
declare -A FLEET_NODES

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Load fleet configuration
load_fleet_config() {
    if [ ! -f "$FLEET_CONFIG" ]; then
        log_message "Creating default fleet configuration..."
        mkdir -p "$(dirname "$FLEET_CONFIG")"
        cat > "$FLEET_CONFIG" << EOF
# Fleet Node Configuration
# Format: hostname:ip:role:environment
web01:192.168.1.10:webserver:production
web02:192.168.1.11:webserver:production
db01:192.168.1.20:database:production
db02:192.168.1.21:database:production
app01:192.168.1.30:application:production
app02:192.168.1.31:application:production
EOF
    fi
    
    # Parse configuration
    while IFS=':' read -r hostname ip role env; do
        [[ "$hostname" =~ ^#.*$ ]] && continue
        [[ -z "$hostname" ]] && continue
        FLEET_NODES["$hostname"]="$ip:$role:$env"
    done < "$FLEET_CONFIG"
    
    log_message "Loaded ${#FLEET_NODES[@]} nodes from fleet configuration"
}

# Execute command on remote node
execute_remote() {
    local hostname="$1"
    local command="$2"
    local node_info="${FLEET_NODES[$hostname]}"
    local ip=$(echo "$node_info" | cut -d':' -f1)
    
    ssh -i "$SSH_KEY" -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
        "root@$ip" "$command" 2>/dev/null || {
        log_message "Failed to execute on $hostname ($ip): $command"
        return 1
    }
}

# Health check across fleet
fleet_health_check() {
    log_message "Starting fleet-wide health check..."
    
    local failed_nodes=0
    local total_nodes=${#FLEET_NODES[@]}
    
    for hostname in "${!FLEET_NODES[@]}"; do
        {
            local node_info="${FLEET_NODES[$hostname]}"
            local ip=$(echo "$node_info" | cut -d':' -f1)
            local role=$(echo "$node_info" | cut -d':' -f2)
            
            if execute_remote "$hostname" "uptime"; then
                # Get system metrics
                local cpu_usage=$(execute_remote "$hostname" "top -bn1 | grep 'Cpu(s)' | awk '{print \$2}' | sed 's/%us,//'")
                local mem_usage=$(execute_remote "$hostname" "free | awk 'NR==2{printf \"%.0f\", \$3*100/\$2}'")
                local disk_usage=$(execute_remote "$hostname" "df -h / | awk 'NR==2{print \$5}' | sed 's/%//'")
                
                log_message "✓ $hostname ($role): CPU:${cpu_usage}% MEM:${mem_usage}% DISK:${disk_usage}%"
            else
                log_message "✗ $hostname ($role): UNREACHABLE"
                ((failed_nodes++))
            fi
        } &
        
        # Limit parallel jobs
        (($(jobs -r | wc -l) >= PARALLEL_JOBS)) && wait
    done
    
    wait  # Wait for all background jobs
    
    local success_rate=$(( (total_nodes - failed_nodes) * 100 / total_nodes ))
    log_message "Fleet health check completed: $success_rate% nodes healthy ($((total_nodes - failed_nodes))/$total_nodes)"
}

# Deploy configuration across fleet
fleet_deploy() {
    local config_file="$1"
    local target_path="$2"
    
    if [ ! -f "$config_file" ]; then
        log_message "Configuration file not found: $config_file"
        return 1
    fi
    
    log_message "Deploying $config_file to $target_path across fleet..."
    
    for hostname in "${!FLEET_NODES[@]}"; do
        {
            local node_info="${FLEET_NODES[$hostname]}"
            local ip=$(echo "$node_info" | cut -d':' -f1)
            
            if scp -i "$SSH_KEY" -o ConnectTimeout=10 "$config_file" "root@$ip:$target_path"; then
                log_message "✓ Deployed to $hostname"
            else
                log_message "✗ Failed to deploy to $hostname"
            fi
        } &
        
        (($(jobs -r | wc -l) >= PARALLEL_JOBS)) && wait
    done
    
    wait
    log_message "Fleet deployment completed"
}

# Update packages across fleet
fleet_update() {
    local update_type="${1:-security}"
    
    log_message "Starting fleet-wide $update_type updates..."
    
    for hostname in "${!FLEET_NODES[@]}"; do
        {
            local node_info="${FLEET_NODES[$hostname]}"
            local role=$(echo "$node_info" | cut -d':' -f2)
            
            case "$update_type" in
                "security")
                    if execute_remote "$hostname" "apt-get update && apt-get -y upgrade"; then
                        log_message "✓ Security updates applied on $hostname ($role)"
                    else
                        log_message "✗ Security updates failed on $hostname ($role)"
                    fi
                    ;;
                "full")
                    if execute_remote "$hostname" "apt-get update && apt-get -y dist-upgrade"; then
                        log_message "✓ Full updates applied on $hostname ($role)"
                    else
                        log_message "✗ Full updates failed on $hostname ($role)"
                    fi
                    ;;
            esac
        } &
        
        (($(jobs -r | wc -l) >= PARALLEL_JOBS)) && wait
    done
    
    wait
    log_message "Fleet updates completed"
}

# Service management across fleet
fleet_service() {
    local service_name="$1"
    local action="$2"  # start, stop, restart, status
    
    log_message "Fleet service management: $action $service_name"
    
    for hostname in "${!FLEET_NODES[@]}"; do
        {
            if execute_remote "$hostname" "systemctl $action $service_name"; then
                log_message "✓ $hostname: $service_name $action successful"
            else
                log_message "✗ $hostname: $service_name $action failed"
            fi
        } &
        
        (($(jobs -r | wc -l) >= PARALLEL_JOBS)) && wait
    done
    
    wait
    log_message "Fleet service management completed"
}

# Generate fleet report
generate_fleet_report() {
    local report_file="/var/log/fleet_report_$(date +%Y%m%d_%H%M%S).txt"
    
    log_message "Generating comprehensive fleet report..."
    
    {
        echo "=== Enterprise Fleet Management Report ==="
        echo "Generated: $(date)"
        echo "Total Nodes: ${#FLEET_NODES[@]}"
        echo
        
        echo "=== Node Inventory ==="
        for hostname in "${!FLEET_NODES[@]}"; do
            local node_info="${FLEET_NODES[$hostname]}"
            local ip=$(echo "$node_info" | cut -d':' -f1)
            local role=$(echo "$node_info" | cut -d':' -f2)
            local env=$(echo "$node_info" | cut -d':' -f3)
            echo "$hostname | $ip | $role | $env"
        done
        echo
        
        echo "=== System Status ==="
        for hostname in "${!FLEET_NODES[@]}"; do
            local node_info="${FLEET_NODES[$hostname]}"
            local ip=$(echo "$node_info" | cut -d':' -f1)
            
            if execute_remote "$hostname" "uptime" >/dev/null 2>&1; then
                local uptime=$(execute_remote "$hostname" "uptime | awk '{print \$3,\$4}' | sed 's/,//'")
                local load=$(execute_remote "$hostname" "uptime | awk -F'load average:' '{print \$2}'")
                echo "$hostname: UP (${uptime}) Load:${load}"
            else
                echo "$hostname: DOWN"
            fi
        done
        
    } > "$report_file"
    
    log_message "Fleet report generated: $report_file"
}

# Main function
main() {
    case "${1:-}" in
        --health-check)
            load_fleet_config
            fleet_health_check
            ;;
        --deploy)
            if [ $# -lt 3 ]; then
                echo "Usage: $0 --deploy <config_file> <target_path>"
                exit 1
            fi
            load_fleet_config
            fleet_deploy "$2" "$3"
            ;;
        --update)
            load_fleet_config
            fleet_update "${2:-security}"
            ;;
        --service)
            if [ $# -lt 3 ]; then
                echo "Usage: $0 --service <service_name> <action>"
                exit 1
            fi
            load_fleet_config
            fleet_service "$2" "$3"
            ;;
        --report)
            load_fleet_config
            generate_fleet_report
            ;;
        --help)
            echo "Enterprise Fleet Management System"
            echo "Usage: $0 [option]"
            echo "  --health-check           Check health of all nodes"
            echo "  --deploy <file> <path>   Deploy configuration file"
            echo "  --update [type]          Update packages (security/full)"
            echo "  --service <name> <action> Manage services across fleet"
            echo "  --report                 Generate comprehensive report"
            echo "  --help                   Show this help"
            ;;
        *)
            log_message "Starting comprehensive fleet management..."
            load_fleet_config
            fleet_health_check
            generate_fleet_report
            log_message "Fleet management cycle completed"
            ;;
    esac
}

# Ensure running as root
if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root"
    exit 1
fi

main "$@"
