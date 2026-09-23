#!/bin/bash

:<<EOF
 脚本调用命令：
 ingress.sh  \
         --ingress-ip "172.16.13.90"  \
         --ingress-interface "macvlan0" \
         --egress-interface "veth-ns" \
         --via-ip "172.16.13.11" \
         --total-bandwidth "300Mbit"  \
         --tc-default "10Mbit" \
         --tc-rule "web-server:80:10Mbit"  \
         --tc-rule "secure-app:443,900:20Mbit"

 ./ingress.sh show  

需求：
 1. 启用 sysctl -w net.ipv4.ip_forward=1
 2. 开启 ingress-interface 接口上的 arp 代理，sysctl -w net.ipv4.conf.<ingress-interface>.proxy_arp=1 
 3. 设置路由转发  ip r add <ingress-ip> via <via-ip> dev <egress-interface> onlink  和邻居表 ip n add <via-ip> lladdr <via-mac> dev <egress-interface> nud permanent
 4. 在 egress-interface 上配置 TC 规则，对 ingress-ip 的不同 端口 的流量 进行限流：
     - 一级父类：设置总网卡带宽 <total-bandwidth>
     - 二级子类A：缺省类，未显式声明端口的流量处理方式由 <tc-default> 指定
     - 二级子类B+：基于 tc-rule 参数创建，格式 "name:port[,port]...:bandwidth"


qdisc htb 1: root (总带宽)
├── class 1:1 (一级父类) 
    ├── class 1:10 (缺省，根据tc-default配置)
    ├── class 1:11 (端口组1限流 - web-server)
    ├── class 1:12 (端口组2限流 - secure-app)
    └── ......
EOF


set -e

# --- Global Variables ---
INGRESS_IP=""              # Target ingress IP with CIDR mask
INGRESS_INTERFACE=""       # Ingress network interface for ARP proxy
EGRESS_INTERFACE=""        # Egress network interface for TC rules
VIA_IP=""                  # Next hop IP address
VIA_MAC=""                 # Next hop MAC address (auto-detected)
TOTAL_BANDWIDTH=""         # Total bandwidth limit
TC_DEFAULT=""              # Default handling for unconfigured ports: "drop", "shared", or "bandwidth"
TC_DEFAULT_MODE=""         # Parsed default mode: "drop", "shared", or "custom"
TC_DEFAULT_BANDWIDTH=""    # Parsed default bandwidth for shared/custom mode
TC_RULES=()                # Array of TC rules in format "name:port[,port]...:bandwidth"
TARGET_IP=""               # Extracted target IP without CIDR mask
SHOW_MODE=false            # Flag for show mode operation
DETECTED_INGRESS_IP=""     # Auto-detected ingress IP for show mode
DETECTED_VIA_IP=""        # Auto-detected via IP for show mode
DETECTED_INGRESS_INTERFACE="" # Auto-detected ingress interface for show mode
DETECTED_VIA_MAC=""        # Auto-detected via MAC for show mode

# --- Help Information Function ---
show_help() {
    echo "Usage: $0 [options|command]"
    echo ""
    echo "Commands:"
    echo "  show --egress-interface IFACE  Display TC configuration and reverse parsing results for specified interface"
    echo ""
    echo "Options:"
    echo "  --ingress-ip IP/MASK       Target ingress IP with CIDR mask (required)"
    echo "  --ingress-interface IFACE  Ingress network interface for ARP proxy (required)"
    echo "  --egress-interface IFACE   Egress network interface for TC rules (required)"
    echo "  --via-ip IP                Next hop IP address (required)"
    echo "  --total-bandwidth BW       Total bandwidth limit (required)"
    echo "  --tc-default MODE          Default handling for unconfigured ports (required)"
    echo "                             'drop' - drop unconfigured traffic"
    echo "                             'shared' - share total bandwidth for unconfigured traffic"
    echo "                             'bandwidth' - share specified bandwidth (e.g., '10Mbit', '100kbit')"
    echo "  --tc-rule RULE             TC rule in format: 'name:port[,port]...:bandwidth' (repeatable)"
    echo "  --help                     Show this help information"
    echo ""
    echo "Examples:"
    echo "  Configure ingress forwarding and traffic shaping (drop unconfigured traffic):"
    echo "  $0 --ingress-ip '192.168.0.10/24' --ingress-interface 'macvlan0' --egress-interface 'veth0' --via-ip '192.168.0.20' --total-bandwidth '300Mbit' --tc-default 'drop' --tc-rule 'web:80:10Mbit' --tc-rule 'secure:443,900:20Mbit'"
    echo ""
    echo "  Configure ingress forwarding and traffic shaping (shared total bandwidth for unconfigured traffic):"
    echo "  $0 --ingress-ip '192.168.0.10/24' --ingress-interface 'macvlan0' --egress-interface 'veth0' --via-ip '192.168.0.20' --total-bandwidth '300Mbit' --tc-default 'shared' --tc-rule 'web:80:10Mbit' --tc-rule 'secure:443,900:20Mbit'"
    echo ""
    echo "  Configure ingress forwarding and traffic shaping (shared custom bandwidth for unconfigured traffic):"
    echo "  $0 --ingress-ip '192.168.0.10/24' --ingress-interface 'macvlan0' --egress-interface 'veth0' --via-ip '192.168.0.20' --total-bandwidth '300Mbit' --tc-default '10Mbit' --tc-rule 'web:80:10Mbit' --tc-rule 'secure:443,900:20Mbit'"
    echo ""
    echo "  Display current configuration:"
    echo "  $0 show --egress-interface eth0           # View configuration for specified interface"
}

# --- Parameter Parsing Function ---
parse_arguments() {
    # Debug: Log function entry
    echo "[DEBUG] Parsing command line arguments: $*" >&2
    
    if [[ $# -eq 0 ]]; then
        echo "[INFO] No arguments provided, showing help" >&2
        show_help
        exit 1
    fi
    
    # Check if first parameter is show command
    if [[ "$1" == "show" ]]; then
        echo "[DEBUG] Show mode detected" >&2
        SHOW_MODE=true
        shift
    fi
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --ingress-ip)
                INGRESS_IP="$2"
                echo "[DEBUG] Set ingress IP: $INGRESS_IP" >&2
                shift 2
                ;;
            --ingress-interface)
                INGRESS_INTERFACE="$2"
                echo "[DEBUG] Set ingress interface: $INGRESS_INTERFACE" >&2
                shift 2
                ;;
            --egress-interface)
                EGRESS_INTERFACE="$2"
                echo "[DEBUG] Set egress interface: $EGRESS_INTERFACE" >&2
                shift 2
                ;;
            --via-ip)
                VIA_IP="$2"
                echo "[DEBUG] Set via IP: $VIA_IP" >&2
                shift 2
                ;;
            --total-bandwidth)
                TOTAL_BANDWIDTH="$2"
                echo "[DEBUG] Set total bandwidth: $TOTAL_BANDWIDTH" >&2
                shift 2
                ;;
            --tc-default)
                TC_DEFAULT="$2"
                echo "[DEBUG] Set tc-default: $TC_DEFAULT" >&2
                shift 2
                ;;
            --tc-rule)
                TC_RULES+=("$2")
                echo "[DEBUG] Added TC rule: $2" >&2
                shift 2
                ;;
            --help)
                show_help
                exit 0
                ;;
            *)
                echo "[ERROR] Unknown parameter: $1" >&2
                show_help
                exit 1
                ;;
        esac
    done
    
    echo "[DEBUG] Parameter parsing completed" >&2
    
    # Validate required parameters immediately after parsing (except for show mode)
    if [[ "$SHOW_MODE" == false ]]; then
        validate_required_parameters
    fi
}

# --- Validate Required Parameters Function ---
validate_required_parameters() {
    echo "[DEBUG] Validating required parameters" >&2
    local errors=0

    if [[ -z "$INGRESS_IP" ]]; then
        echo "[ERROR] Missing required parameter: --ingress-ip" >&2
        errors=1
    fi

    if [[ -z "$INGRESS_INTERFACE" ]]; then
        echo "[ERROR] Missing required parameter: --ingress-interface" >&2
        errors=1
    fi

    if [[ -z "$EGRESS_INTERFACE" ]]; then
        echo "[ERROR] Missing required parameter: --egress-interface" >&2
        errors=1
    fi

    if [[ -z "$VIA_IP" ]]; then
        echo "[ERROR] Missing required parameter: --via-ip" >&2
        errors=1
    fi

    # Auto-detect VIA_MAC from neighbor table
    if [[ -z "$VIA_MAC" ]]; then
        VIA_MAC=$(ip neighbor show | grep "^$VIA_IP " | awk '{print $5}' 2>/dev/null || echo "")
        if [[ -z "$VIA_MAC" ]]; then
            echo "[INFO] via-mac not found in neighbor table, will be detected during configuration" >&2
        else
            echo "[INFO] Auto-detected via-mac: $VIA_MAC" >&2
        fi
    fi

    if [[ -z "$TOTAL_BANDWIDTH" ]]; then
        echo "[ERROR] Missing required parameter: --total-bandwidth" >&2
        errors=1
    fi

    if [[ -z "$TC_DEFAULT" ]]; then
        echo "[ERROR] Missing required parameter: --tc-default" >&2
        echo "请提供未声明端口的默认处理方式，例如:" >&2
        echo "  --tc-default 'drop' (丢弃未配置的流量)" >&2
        echo "  --tc-default 'shared' (共享总带宽给未配置的流量)" >&2
        echo "  --tc-default '10Mbit' (为未配置的流量共享10Mbit带宽)" >&2
        errors=1
    else
        # 解析 tc-default 参数
        if [[ "$TC_DEFAULT" == "drop" ]]; then
            TC_DEFAULT_MODE="drop"
            TC_DEFAULT_BANDWIDTH=""
            echo "[DEBUG] tc-default mode set to: drop" >&2
        elif [[ "$TC_DEFAULT" == "shared" ]]; then
            TC_DEFAULT_MODE="shared"
            TC_DEFAULT_BANDWIDTH="$TOTAL_BANDWIDTH"
            echo "[DEBUG] tc-default mode set to: shared, bandwidth: $TC_DEFAULT_BANDWIDTH" >&2
        elif [[ "$TC_DEFAULT" =~ ^[0-9]+[kKmMgG]?bit$ ]]; then
            TC_DEFAULT_MODE="custom"
            TC_DEFAULT_BANDWIDTH="$TC_DEFAULT"
            echo "[DEBUG] tc-default mode set to: custom, bandwidth: $TC_DEFAULT_BANDWIDTH" >&2
        else
            echo "[ERROR] Invalid --tc-default format: $TC_DEFAULT" >&2
            echo "支持的格式:" >&2
            echo "  'drop' - 丢弃未配置的流量" >&2
            echo "  'shared' - 共享总带宽给未配置的流量" >&2
            echo "  'bandwidth' - 为未配置的流量共享指定带宽 (例如: '10Mbit', '100kbit')" >&2
            errors=1
        fi
    fi

    if [[ $errors -eq 1 ]]; then
        echo "[ERROR] Parameter validation failed" >&2
        show_help
        exit 1
    fi
}

# --- 自动检测HTB接口函数 ---
auto_detect_htb_interface() {
    local htb_interfaces
    htb_interfaces=$(tc qdisc show | grep htb | awk '{print $5}' | sort -u)
    
    if [[ -z "$htb_interfaces" ]]; then
        echo "错误: 未发现任何配置了HTB的接口"
        exit 1
    fi
    
    local interface_count
    interface_count=$(echo "$htb_interfaces" | wc -l)
    
    if [[ $interface_count -eq 1 ]]; then
        EGRESS_INTERFACE="$htb_interfaces"
        echo "自动检测到HTB接口: $EGRESS_INTERFACE"
    else
        echo "发现多个HTB接口，请使用 --egress-interface 指定:"
        echo "$htb_interfaces" | sed 's/^/  /'
        echo "示例: $0 show --egress-interface <接口名>"
        exit 1
    fi
}

# --- Parameter Validation Function ---
validate_parameters() {
    echo "[DEBUG] Starting parameter validation" >&2
    
    if [[ "$SHOW_MODE" == true ]]; then
        echo "[DEBUG] Show mode validation" >&2
        if [[ -z "$EGRESS_INTERFACE" ]]; then
            echo "[INFO] Auto-detecting HTB interface for show mode" >&2
            auto_detect_htb_interface
        fi
        return 0
    fi
    
    # Extract target IP (remove CIDR mask)
    TARGET_IP=$(echo "$INGRESS_IP" | cut -d'/' -f1)
    echo "[DEBUG] Extracted target IP: $TARGET_IP from $INGRESS_IP" >&2
    echo "[INFO] Parameter validation completed successfully" >&2
}

# --- 显示配置参数函数 ---
show_configuration() {
    echo "=== 配置参数 ==="
    echo "入口IP: $INGRESS_IP"
    echo "目标IP: $TARGET_IP"
    echo "出口接口: $EGRESS_INTERFACE"
    echo "下一跳IP: $VIA_IP"
    echo "下一跳MAC: $VIA_MAC"
    echo "总带宽: $TOTAL_BANDWIDTH"
    echo "默认处理方式: $TC_DEFAULT"
    if [[ "$TC_DEFAULT_MODE" == "drop" ]]; then
        echo "  模式: 丢弃流量"
    elif [[ "$TC_DEFAULT_MODE" == "shared" ]]; then
        echo "  模式: 共享总带宽"
        echo "  带宽: $TC_DEFAULT_BANDWIDTH"
    else
        echo "  模式: 共享自定义带宽"
        echo "  带宽: $TC_DEFAULT_BANDWIDTH"
    fi
    echo "TC规则数量: ${#TC_RULES[@]}"
    for rule in "${TC_RULES[@]}"; do
        echo "  TC规则: $rule"
    done
    echo ""
}

# --- Cleanup Existing Configuration Function ---
cleanup_existing_configuration() {
    echo "=== Cleaning Up Existing Configuration ==="
    echo "[DEBUG] Starting cleanup for target IP: $TARGET_IP, via IP: $VIA_IP" >&2

    # Temporarily disable error exit to avoid script termination when deleting non-existent entries
    set +e

    # Clean up existing routes
    echo "Removing existing routes..."
    local route_count=0
    
    # Remove specific /32 routes
    while  ip route del "$TARGET_IP/32" 2>/dev/null; do
        ((route_count++))
        echo "  Removed route #$route_count: $TARGET_IP/32"
        echo "[DEBUG] Removed /32 route for $TARGET_IP" >&2
    done
    
    # Remove CIDR routes
    while  ip route del "$INGRESS_IP" 2>/dev/null; do
        ((route_count++))
        echo "  Removed route #$route_count: $INGRESS_IP"
        echo "[DEBUG] Removed CIDR route for $INGRESS_IP" >&2
    done
    
    # Remove target IP route via via-ip
    while  ip route del "$TARGET_IP" via "$VIA_IP" dev "$EGRESS_INTERFACE" 2>/dev/null; do
        ((route_count++))
        echo "  Removed route #$route_count: $TARGET_IP via $VIA_IP dev $EGRESS_INTERFACE"
        echo "[DEBUG] Removed forwarding route for $TARGET_IP via $VIA_IP" >&2
    done
    
    if [ "$route_count" -gt 0 ]; then
        echo "  Successfully removed $route_count routes"
        echo "[INFO] Cleaned up $route_count existing routes" >&2
    else
        echo "  No routes to remove"
        echo "[DEBUG] No existing routes found" >&2
    fi

    # Clean up neighbor table entries for re-entrancy
    echo "Removing existing neighbor table entries..."
    local neighbor_count=0
    
    # Remove neighbor entry for via-ip
    if  ip neighbor del "$VIA_IP" dev "$EGRESS_INTERFACE" 2>/dev/null; then
        ((neighbor_count++))
        echo "  Removed neighbor entry: $VIA_IP on $EGRESS_INTERFACE"
        echo "[DEBUG] Removed neighbor entry for $VIA_IP on $EGRESS_INTERFACE" >&2
    fi
    
    if [ "$neighbor_count" -gt 0 ]; then
        echo "  Successfully removed $neighbor_count neighbor entries"
        echo "[INFO] Cleaned up $neighbor_count existing neighbor entries" >&2
    else
        echo "  No neighbor entries to remove"
        echo "[DEBUG] No existing neighbor entries found" >&2
    fi

    # Clean up existing TC rules
    echo "Checking existing TC rules..."
    if  tc qdisc show dev "$EGRESS_INTERFACE" | grep -q "htb"; then
        echo "  Found existing HTB qdisc, removing..."
        echo "[DEBUG] Removing HTB qdisc from $EGRESS_INTERFACE" >&2
         tc qdisc del dev "$EGRESS_INTERFACE" root 2>/dev/null || true
        echo "  TC rules cleanup completed"
        echo "[INFO] HTB qdisc removed from $EGRESS_INTERFACE" >&2
    else
        echo "  No HTB qdisc found"
        echo "[DEBUG] No HTB qdisc found on $EGRESS_INTERFACE" >&2
    fi

    # Re-enable error exit
    set -e
    echo "[INFO] Configuration cleanup completed" >&2
    echo ""
}

# --- Configure System Settings Function ---
# Consolidated function handling requirements 1, 2, and 3
configure_system_settings() {
    echo "=== Configuring System Settings ==="
    echo "[DEBUG] Starting system configuration for requirements 1, 2, and 3" >&2
    
    # Requirement 1: Enable IP forwarding
    echo "Step 1: Enabling IP forwarding..."
    echo "[DEBUG] Executing: sysctl -w net.ipv4.ip_forward=1" >&2
    if  sysctl -w net.ipv4.ip_forward=1; then
        echo "[INFO] IP forwarding enabled successfully" >&2
        echo "✓ IP forwarding enabled"
    else
        echo "[ERROR] Failed to enable IP forwarding" >&2
        exit 1
    fi
    
    # New Requirement 1: Ensure ingress-ip is not assigned to ingress-interface
    echo "Step 1a: Ensuring ingress IP is not assigned to ingress interface..."
    echo "[DEBUG] Checking if $TARGET_IP is assigned to $INGRESS_INTERFACE" >&2
    
    # Check if the IP is assigned to the interface
    if ip addr show dev "$INGRESS_INTERFACE" | grep -q "inet $TARGET_IP\/"; then
        echo "[WARNING] IP address $TARGET_IP is assigned to interface $INGRESS_INTERFACE, removing it..." >&2
        echo "[DEBUG] Executing: sudo ip addr del $TARGET_IP dev $INGRESS_INTERFACE" >&2
        if sudo ip addr del "$TARGET_IP" dev "$INGRESS_INTERFACE" >&2; then
            echo "[INFO] Successfully removed $TARGET_IP from $INGRESS_INTERFACE" >&2
            echo "✓ Removed $TARGET_IP from $INGRESS_INTERFACE"
        else
            echo "[ERROR] Failed to remove $TARGET_IP from $INGRESS_INTERFACE" >&2
            exit 1
        fi
    else
        echo "[INFO] IP address $TARGET_IP is not assigned to $INGRESS_INTERFACE" >&2
        echo "✓ IP address check passed"
    fi
    
    # New Requirement 2: Set rp_filter=0 for both interfaces
    echo "Step 1b: Setting rp_filter=0 for ingress and egress interfaces..."
    
    # Set rp_filter=0 for ingress interface
    echo "[DEBUG] Setting rp_filter=0 for ingress interface $INGRESS_INTERFACE" >&2
    if  sysctl -w "net.ipv4.conf.$INGRESS_INTERFACE.rp_filter=0"; then
        echo "[INFO] rp_filter set to 0 for $INGRESS_INTERFACE" >&2
        echo "✓ rp_filter=0 for $INGRESS_INTERFACE"
    else
        echo "[ERROR] Failed to set rp_filter=0 for $INGRESS_INTERFACE" >&2
        exit 1
    fi
    
    # Set rp_filter=0 for egress interface
    echo "[DEBUG] Setting rp_filter=0 for egress interface $EGRESS_INTERFACE" >&2
    if  sysctl -w "net.ipv4.conf.$EGRESS_INTERFACE.rp_filter=0"; then
        echo "[INFO] rp_filter set to 0 for $EGRESS_INTERFACE" >&2
        echo "✓ rp_filter=0 for $EGRESS_INTERFACE"
    else
        echo "[ERROR] Failed to set rp_filter=0 for $EGRESS_INTERFACE" >&2
        exit 1
    fi
    
    echo "[DEBUG] Setting rp_filter=0 for all interfaces" >&2
    if  sysctl -w "net.ipv4.conf.all.rp_filter=0"; then
        echo "[INFO] rp_filter set to 0 for all interfaces" >&2
        echo "✓ rp_filter=0 for all interfaces"
    else
        echo "[ERROR] Failed to set rp_filter=0 for all interfaces" >&2
        exit 1
    fi
  
    # Requirement 2: Enable ARP proxy on ingress interface
    echo "Step 2: Enabling ARP proxy on ingress interface..."
    echo "[DEBUG] Executing: sysctl -w net.ipv4.conf.$INGRESS_INTERFACE.proxy_arp=1" >&2
    if  sysctl -w "net.ipv4.conf.$INGRESS_INTERFACE.proxy_arp=1"; then
        echo "[INFO] ARP proxy enabled successfully on interface $INGRESS_INTERFACE" >&2
        echo "✓ ARP proxy enabled on $INGRESS_INTERFACE"
    else
        echo "[ERROR] Failed to enable ARP proxy on interface $INGRESS_INTERFACE" >&2
        exit 1
    fi
    
    # Requirement 3: Configure forwarding route and neighbor table
    echo "Step 3: Configuring forwarding route and neighbor table..."
    echo "[DEBUG] Configuring route for $TARGET_IP via $VIA_IP on $EGRESS_INTERFACE" >&2
    echo "[DEBUG] Setting neighbor entry for $VIA_IP with MAC $VIA_MAC" >&2

    # Auto-detect VIA_MAC if not already detected
    if [[ -z "$VIA_MAC" ]]; then
        echo "Auto-detecting via-mac from neighbor table..."
        VIA_MAC=$(ip neighbor show | grep "^$VIA_IP " | awk '{print $5}' 2>/dev/null || echo "")
        if [[ -z "$VIA_MAC" ]]; then
            echo "[WARNING] via-mac not found in neighbor table, you may need to ping the via-ip first" >&2
        else
            echo "[INFO] Auto-detected via-mac: $VIA_MAC" >&2
        fi
    fi

    # Configure forwarding route
    echo "Adding forwarding route: $TARGET_IP via $VIA_IP dev $EGRESS_INTERFACE onlink"
    if  ip route add "$TARGET_IP" via "$VIA_IP" dev "$EGRESS_INTERFACE" onlink; then
        echo "[INFO] Forwarding route added successfully" >&2
        echo "✓ Route: $TARGET_IP via $VIA_IP dev $EGRESS_INTERFACE"
    else
        echo "[WARNING] Route may already exist or failed to add" >&2
    fi

    # Configure neighbor table entry (only if VIA_MAC is available)
    if [[ -n "$VIA_MAC" ]]; then
        echo "Adding neighbor table entry: $VIA_IP lladdr $VIA_MAC dev $EGRESS_INTERFACE"
        if  ip neighbor add "$VIA_IP" lladdr "$VIA_MAC" dev "$EGRESS_INTERFACE" nud permanent; then
            echo "[INFO] Neighbor table entry added successfully" >&2
            echo "✓ Neighbor: $VIA_IP -> $VIA_MAC on $EGRESS_INTERFACE"
        else
            echo "[WARNING] Neighbor entry may already exist or failed to add" >&2
        fi
    else
        echo "[WARNING] via-mac not available, skipping neighbor table entry" >&2
        echo "[INFO] You may need to manually add the neighbor entry or ensure the via-ip is reachable" >&2
    fi
    
    echo "[INFO] System configuration completed for all requirements" >&2
    echo ""
}


# --- 创建基础TC结构函数 ---
create_basic_tc_structure() {
    echo "1. 创建HTB根队列规程和一级父类..."
    # 使用r2q=100来避免quantum警告（默认是10，对于高带宽会产生警告）
     tc qdisc add dev "$EGRESS_INTERFACE" root handle 1: htb default 10 r2q 100
     tc class add dev "$EGRESS_INTERFACE" parent 1: classid 1:1 htb rate "$TOTAL_BANDWIDTH" ceil "$TOTAL_BANDWIDTH"

    echo "2. 创建缺省二级子类..."
    if [[ "$TC_DEFAULT_MODE" == "drop" ]]; then
        # 对于drop模式，创建一个极小带宽的class来实现丢包效果
        echo "  配置为丢弃未声明端口的流量"
         tc class add dev "$EGRESS_INTERFACE" parent 1:1 classid 1:10 htb rate 1kbit ceil 1kbit
    else
        # 对于shared/custom模式，使用指定的带宽
        echo "  配置为共享带宽: $TC_DEFAULT_BANDWIDTH"
         tc class add dev "$EGRESS_INTERFACE" parent 1:1 classid 1:10 htb rate "$TC_DEFAULT_BANDWIDTH" ceil "$TC_DEFAULT_BANDWIDTH"
    fi
}

# --- 解析并创建TC规则函数 ---
create_tc_rules_from_config() {
    echo "3. 根据TC规则创建端口限流二级子类..."
    local classid_counter=11
    
    # 创建一个关联数组来存储端口到规则的映射，用于处理重复端口
    declare -A port_rules_map
    
    # 首先解析所有规则，处理重复端口（保留最新的）
    for rule in "${TC_RULES[@]}"; do
        # 解析规则格式: "name:port[,port]...:bandwidth"
        if [[ "$rule" =~ ^([^:]+):([0-9,]+):(.+)$ ]]; then
            local name="${BASH_REMATCH[1]}"
            local ports="${BASH_REMATCH[2]}"
            local bandwidth="${BASH_REMATCH[3]}"
            
            # 分割端口并存储规则
            IFS=',' read -ra PORT_ARRAY <<< "$ports"
            for port in "${PORT_ARRAY[@]}"; do
                # 存储最新的规则（后面的覆盖前面的）
                port_rules_map["$port"]="$name:$bandwidth"
                echo "[DEBUG] Port $port mapped to rule: $name:$bandwidth" >&2
            done
        else
            echo "  警告: TC规则格式错误: $rule (应为 'name:port[,port]...:bandwidth')"
        fi
    done
    
    # 按规则名称分组端口
    declare -A rule_groups
    for port in "${!port_rules_map[@]}"; do
        local rule_info="${port_rules_map[$port]}"
        rule_groups["$rule_info"]+="$port,"
    done
    
    # 为每个规则组创建TC类和过滤器
    for rule_info in "${!rule_groups[@]}"; do
        if [[ "$rule_info" =~ ^([^:]+):(.+)$ ]]; then
            local name="${BASH_REMATCH[1]}"
            local bandwidth="${BASH_REMATCH[2]}"
            local ports="${rule_groups[$rule_info]}"
            # 移除末尾的逗号
            ports="${ports%,}"
            
            # Calculate appropriate burst size (at least 10KB or 1/10 of rate)
            local burst_size
            local rate_num=$(echo "$bandwidth" | sed 's/[^0-9]//g')
            local rate_unit=$(echo "$bandwidth" | sed 's/[0-9]//g')
            
            case "$rate_unit" in
                "Mbit"|"mbit")
                    # For Mbit rates, use rate/8 KB as burst (1/8 second worth of data)
                    burst_size="$((rate_num * 128))kb"
                    ;;
                "Gbit"|"gbit")
                    # For Gbit rates, use rate/8 MB as burst
                    burst_size="$((rate_num * 128))mb"
                    ;;
                *)
                    # Default burst size
                    burst_size="15kb"
                    ;;
            esac
            
            echo "  创建二级子类 1:$classid_counter，名称: $name，端口: $ports，带宽: $bandwidth，突发: $burst_size"
            echo "[DEBUG] Creating class 1:$classid_counter with name=$name, rate=$bandwidth, burst=$burst_size" >&2
            
            # Create class with calculated burst size
             tc class add dev "$EGRESS_INTERFACE" parent 1:1 classid 1:$classid_counter htb \
                rate "$bandwidth" ceil "$bandwidth" burst "$burst_size" cburst "$burst_size"
            
            # 为每个端口创建过滤器
            create_port_filters "$ports" "$classid_counter"
            
            ((classid_counter++))
        fi
    done
}

# --- 创建端口过滤器函数 ---
create_port_filters() {
    local ports="$1"
    local classid="$2"
    local prio_counter=1
    
    # Split port string and create filters for TCP ports
    IFS=',' read -ra PORT_ARRAY <<< "$ports"
    for port in "${PORT_ARRAY[@]}"; do
        echo "    添加端口 $port 的TCP过滤器(flower方法)"
        echo "[DEBUG] Using flower filter for TCP port $port to class 1:$classid" >&2
        
        # Use flower filter for more reliable TCP port matching
        # Flower filter has better support for protocol-specific matching
        # Try both destination port and source port matching
        echo "[DEBUG] Adding flower filter for destination port $port" >&2
         tc filter add dev "$EGRESS_INTERFACE" protocol ip parent 1: prio $prio_counter flower \
            ip_proto tcp dst_port "$port" \
            action flowid 1:$classid
        
        # Also try source port matching as backup
        echo "[DEBUG] Adding flower filter for source port $port" >&2
         tc filter add dev "$EGRESS_INTERFACE" protocol ip parent 1: prio $((prio_counter + 10)) flower \
            ip_proto tcp src_port "$port" \
            action flowid 1:$classid
        
        echo "[DEBUG] Created TCP dport filter for port $port with prio $prio_counter" >&2
        ((prio_counter++))
    done
}

# --- Show模式: 反解析TC配置函数 ---
parse_existing_tc_config() {
    echo "=== 当前TC配置 ==="
    
    # 检查是否存在HTB配置
    if ! tc qdisc show dev "$EGRESS_INTERFACE" | grep -q "htb"; then
        echo "接口 $EGRESS_INTERFACE 上未发现HTB配置"
        return 1
    fi
    
    # 显示当前配置状态
    echo "1. 队列规程 (qdisc):"
    tc -s qdisc show dev "$EGRESS_INTERFACE" | sed 's/^/  /'
    
    echo ""
    echo "2. 类别 (class):"
    tc -s class show dev "$EGRESS_INTERFACE" | sed 's/^/  /'
    
    echo ""
    echo "3. 过滤器 (filter):"
    tc -s filter show dev "$EGRESS_INTERFACE" | sed 's/^/  /'
    
    echo ""
    return 0
}

# --- Detect IP Configuration from Route Table Function ---
detect_ip_configuration() {
    local ingress_ip=""
    local via_ip=""
    
    echo "Attempting to infer IP configuration from route table..."
    echo "[DEBUG] Searching for forwarding routes on interface $EGRESS_INTERFACE" >&2
    
    # Look for previously configured forwarding routes in format: <ingress-ip> via <via-ip> dev <egress-interface> onlink
    # This matches the route format created by our configure_system_settings function
    echo "Searching for forwarding routes with 'onlink' flag..."
    local forwarding_route
    forwarding_route=$(ip route | grep "dev $EGRESS_INTERFACE" | grep "via " | grep "onlink" | head -1)
    
    if [[ -n "$forwarding_route" ]]; then
        # Extract ingress IP and via IP from the route
        # Format: <ingress-ip> via <via-ip> dev <interface> onlink
        ingress_ip=$(echo "$forwarding_route" | awk '{print $1}')
        via_ip=$(echo "$forwarding_route" | awk '{print $3}')
        
        echo "  ✓ Detected forwarding route: $forwarding_route"
        echo "[DEBUG] Extracted ingress IP: $ingress_ip, via IP: $via_ip" >&2
    else
        echo "  No forwarding routes with 'onlink' flag found"
        echo "[DEBUG] Falling back to general route detection" >&2
        
        # Fallback: Look for any routes through the interface
        local general_route
        general_route=$(ip route | grep "dev $EGRESS_INTERFACE" | grep "via " | head -1)
        
        if [[ -n "$general_route" ]]; then
            # Try to extract IPs from general route format
            local route_dest=$(echo "$general_route" | awk '{print $1}')
            local route_via=$(echo "$general_route" | awk '{print $3}')
            
            # Check if destination looks like a single IP (not a network)
            if [[ "$route_dest" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                ingress_ip="$route_dest"
                via_ip="$route_via"
                echo "  ✓ Detected general route: $general_route"
                echo "[DEBUG] Extracted from general route - ingress IP: $ingress_ip, via IP: $via_ip" >&2
            fi
        fi
    fi
    
    # If still no ingress IP found, try interface IP as last resort
    if [[ -z "$ingress_ip" ]]; then
        echo "Checking interface IP as fallback..."
        local interface_ip
        interface_ip=$(ip addr show dev "$EGRESS_INTERFACE" | grep "inet " | awk '{print $2}' | head -1)
        
        if [[ -n "$interface_ip" ]]; then
            ingress_ip="$interface_ip"
            echo "  ✓ Using interface IP: $ingress_ip"
            echo "[DEBUG] Using interface IP as fallback: $ingress_ip" >&2
        fi
    fi
    
    # Detect ingress interface by checking which interfaces have ARP proxy enabled
    local detected_ingress_interface=""
    echo "Detecting ingress interface with ARP proxy enabled..."
    echo "[DEBUG] Checking sysctl settings for proxy_arp" >&2
    
    # Get all network interfaces
    local interfaces
    interfaces=$(ip link show | grep '^[0-9]' | awk -F': ' '{print $2}' | cut -d'@' -f1)
    
    while IFS= read -r interface; do
        if [[ -n "$interface" ]]; then
            # Check if proxy_arp is enabled on this interface
            local proxy_arp_value
            proxy_arp_value=$(sysctl -n "net.ipv4.conf.$interface.proxy_arp" 2>/dev/null || echo "0")
            
            if [[ "$proxy_arp_value" == "1" ]]; then
                detected_ingress_interface="$interface"
                echo "  ✓ Found ARP proxy enabled on interface: $interface"
                echo "[DEBUG] Detected ingress interface: $interface (proxy_arp=1)" >&2
                break
            fi
        fi
    done <<< "$interfaces"
    
    # Detect via MAC from neighbor table
    local detected_via_mac=""
    if [[ -n "$via_ip" ]]; then
        echo "Detecting via MAC from neighbor table..."
        echo "[DEBUG] Looking up MAC address for via IP: $via_ip" >&2
        
        # Look for the via IP in the neighbor table
        local neighbor_entry
        neighbor_entry=$(ip neighbor show | grep "$via_ip" | head -1)
        
        if [[ -n "$neighbor_entry" ]]; then
            # Extract MAC address from neighbor entry
            # Format: <ip> dev <interface> lladdr <mac> <state>
            detected_via_mac=$(echo "$neighbor_entry" | awk '{for(i=1;i<=NF;i++) if($i=="lladdr") print $(i+1)}')
            
            if [[ -n "$detected_via_mac" ]]; then
                echo "  ✓ Found neighbor entry: $neighbor_entry"
                echo "[DEBUG] Detected via MAC: $detected_via_mac" >&2
            fi
        else
            echo "  No neighbor entry found for via IP: $via_ip"
            echo "[DEBUG] No neighbor entry found for $via_ip" >&2
        fi
    fi
    
    # Set global variables for detected values
    if [[ -n "$ingress_ip" ]]; then
        DETECTED_INGRESS_IP="$ingress_ip"
        echo "[INFO] Successfully detected ingress IP: $ingress_ip" >&2
    else
        DETECTED_INGRESS_IP="[Unable to auto-detect]"
        echo "[WARNING] Could not detect ingress IP" >&2
    fi
    
    if [[ -n "$via_ip" ]]; then
        DETECTED_VIA_IP="$via_ip"
        echo "[INFO] Successfully detected via IP: $via_ip" >&2
    else
        DETECTED_VIA_IP="[Unable to auto-detect]"
        echo "[WARNING] Could not detect via IP" >&2
    fi
    
    if [[ -n "$detected_ingress_interface" ]]; then
        DETECTED_INGRESS_INTERFACE="$detected_ingress_interface"
        echo "[INFO] Successfully detected ingress interface: $detected_ingress_interface" >&2
    else
        DETECTED_INGRESS_INTERFACE="[Unable to auto-detect]"
        echo "[WARNING] Could not detect ingress interface" >&2
    fi
    
    if [[ -n "$detected_via_mac" ]]; then
        DETECTED_VIA_MAC="$detected_via_mac"
        echo "[INFO] Successfully detected via MAC: $detected_via_mac" >&2
    else
        DETECTED_VIA_MAC="[Unable to auto-detect]"
        echo "[WARNING] Could not detect via MAC" >&2
    fi
}

# --- Show模式: 生成等效命令函数 ---
generate_equivalent_command() {
    echo "=== 等效命令生成 ==="
    
    # 获取总带宽
    local total_bandwidth
    total_bandwidth=$(tc class show dev "$EGRESS_INTERFACE" | grep "^class htb 1:1 root" | head -1 | grep -o "rate [^ ]*" | cut -d' ' -f2)
    
    if [[ -z "$total_bandwidth" ]]; then
        echo "无法解析总带宽配置"
        return 1
    fi
    
    # 获取默认class配置
    local default_class_info
    default_class_info=$(tc class show dev "$EGRESS_INTERFACE" | grep "^class htb 1:10 parent")
    
    if [[ -z "$default_class_info" ]]; then
        echo "无法解析默认class配置"
        return 1
    fi
    
    # 判断默认模式
    local tc_default_config
    local default_rate
    default_rate=$(echo "$default_class_info" | grep -o "rate [^ ]*" | cut -d' ' -f2)
    
    if [[ "$default_rate" == "1kbit" ]]; then
        tc_default_config="drop"
        echo "检测到默认处理方式: drop (丢弃未配置的流量)"
    elif [[ "$default_rate" == "$total_bandwidth" ]]; then
        tc_default_config="shared"
        echo "检测到默认处理方式: shared (共享总带宽)"
    else
        tc_default_config="$default_rate"
        echo "检测到默认处理方式: $default_rate (共享自定义带宽)"
    fi
    
    echo "检测到总带宽: $total_bandwidth"
    
    # 尝试推断IP配置
    detect_ip_configuration
    
    # 构建基础命令
    local base_cmd="$0"
    base_cmd+=" --egress-interface $EGRESS_INTERFACE"
    base_cmd+=" --ingress-ip $DETECTED_INGRESS_IP"
    base_cmd+=" --ingress-interface $DETECTED_INGRESS_INTERFACE"
    base_cmd+=" --via-ip $DETECTED_VIA_IP"
    base_cmd+=" --total-bandwidth $total_bandwidth"
    base_cmd+=" --tc-default \"$tc_default_config\""
    
    # 解析端口限流规则
    echo ""
    echo "解析端口限流规则..."
    
    # 获取所有非缺省的class (排除根类1:1和默认类1:10)
    local classes
    classes=$(tc class show dev "$EGRESS_INTERFACE" | grep "^class htb 1:" | grep -v "1:1 root" | grep -v "1:10 parent")
    
    if [[ -z "$classes" ]]; then
        echo "未发现端口限流规则"
        echo ""
        echo "等效命令:"
        echo "$base_cmd"
        return 0
    fi
    
    # 按class ID分组处理端口规则
    declare -A class_bandwidth_map
    declare -A class_ports_map
    declare -A class_names_map
    
    # 解析每个class的带宽和class ID
    while IFS= read -r class_line; do
        if [[ "$class_line" =~ class\ htb\ 1:([0-9]+).*rate\ ([^ ]*) ]]; then
            local class_id="${BASH_REMATCH[1]}"
            local bandwidth="${BASH_REMATCH[2]}"
            class_bandwidth_map["$class_id"]="$bandwidth"
            class_ports_map["$class_id"]=""
            # 使用通用名称，因为show模式无法获取原始名称
            class_names_map["$class_id"]="class-$class_id"
        fi
    done <<< "$classes"
    
    # 解析过滤器，提取端口和对应的class ID (支持flower过滤器)
    local filters
    filters=$(tc filter show dev "$EGRESS_INTERFACE" parent 1: 2>/dev/null)
    
    local current_class_id=""
    while IFS= read -r filter_line; do
        # 检查是否包含classid，记录当前的class_id (flower格式)
        if [[ "$filter_line" =~ classid\ 1:([0-9]+) ]]; then
            current_class_id="${BASH_REMATCH[1]}"
        fi
        
        # 检查flower过滤器的dst_port行
        if [[ "$filter_line" =~ dst_port\ ([0-9]+) ]]; then
            local port_dec="${BASH_REMATCH[1]}"
            
            # 将端口添加到对应的class (只处理dst_port，忽略src_port避免重复)
            if [[ -n "$current_class_id" && $port_dec -gt 0 ]]; then
                if [[ -n "${class_ports_map[$current_class_id]}" ]]; then
                    # 检查端口是否已存在，避免重复添加
                    if [[ ",${class_ports_map[$current_class_id]}," != *",$port_dec,"* ]]; then
                        class_ports_map["$current_class_id"]="${class_ports_map[$current_class_id]},$port_dec"
                    fi
                else
                    class_ports_map["$current_class_id"]="$port_dec"
                fi
                echo "  解析到端口规则: Class 1:$current_class_id -> 端口 $port_dec (flower dst_port)"
            fi
        fi
        
        # 兼容旧的u32过滤器格式 (向后兼容)
        if [[ "$filter_line" =~ flowid\ 1:([0-9]+) ]]; then
            current_class_id="${BASH_REMATCH[1]}"
        fi
        if [[ "$filter_line" =~ match\ ([0-9a-f]+)/0000ffff\ at\ 20 ]]; then
            local port_hex="${BASH_REMATCH[1]}"
            local port_dec
            if [[ ${#port_hex} -eq 8 ]]; then
                local port_hex_short="${port_hex: -4}"
                port_dec=$((0x$port_hex_short))
            elif [[ ${#port_hex} -eq 4 ]]; then
                port_dec=$((0x$port_hex))
            else
                continue
            fi
            
            if [[ -n "$current_class_id" && $port_dec -gt 0 ]]; then
                if [[ -n "${class_ports_map[$current_class_id]}" ]]; then
                    if [[ ",${class_ports_map[$current_class_id]}," != *",$port_dec,"* ]]; then
                        class_ports_map["$current_class_id"]="${class_ports_map[$current_class_id]},$port_dec"
                    fi
                else
                    class_ports_map["$current_class_id"]="$port_dec"
                fi
                echo "  解析到端口规则: Class 1:$current_class_id -> 端口 $port_dec (u32 legacy)"
            fi
        fi
    done <<< "$filters"
    
    # 生成tc-rule参数 - 使用实际的端口和带宽信息
    local tc_rules=()
    # 按class ID顺序处理
    local sorted_class_ids=($(printf '%s\n' "${!class_bandwidth_map[@]}" | sort -n))
    
    for class_id in "${sorted_class_ids[@]}"; do
        local bandwidth="${class_bandwidth_map[$class_id]}"
        local ports="${class_ports_map[$class_id]}"
        local name="${class_names_map[$class_id]}"
        
        if [[ -n "$ports" ]]; then
            # 由于show模式无法获取原始名称，使用通用格式
            tc_rules+=("--tc-rule \"$name:$ports:$bandwidth\"")
            echo "  Class 1:$class_id: 名称 $name, 端口 $ports -> 带宽 $bandwidth"
        fi
    done

    echo "ip rule"
    ip rule 

    echo "ip route"
    ip route 

    echo "ip neighbor"
    ip neighbor
    
    # 输出完整命令
    echo ""
    echo "等效命令:"
    for rule in "${tc_rules[@]}"; do
        base_cmd+=" $rule"
    done
    echo "$base_cmd"
    
    echo ""
    echo "📊 配置总结:"
    echo "  出口接口: $EGRESS_INTERFACE"
    echo "  入口接口: $DETECTED_INGRESS_INTERFACE"
    echo "  总带宽: $total_bandwidth"
    echo "  默认处理方式: $tc_default_config"
    echo "  入口IP: $DETECTED_INGRESS_IP"
    echo "  下一跳IP: $DETECTED_VIA_IP"
    echo "  下一跳MAC: $DETECTED_VIA_MAC"
    echo "  端口限流规则数: ${#tc_rules[@]}"
    
    if [[ ${#tc_rules[@]} -gt 0 ]]; then
        echo "  端口限流详情:"
        # 按class ID顺序显示
        for class_id in "${sorted_class_ids[@]}"; do
            local bandwidth="${class_bandwidth_map[$class_id]}"
            local ports="${class_ports_map[$class_id]}"
            local name="${class_names_map[$class_id]}"
            if [[ -n "$ports" && -n "$bandwidth" ]]; then
                local port_count=$(echo "$ports" | tr ',' '\n' | wc -l)
                echo "    Class 1:$class_id: 名称 $name, $port_count 个端口($ports) 限制 $bandwidth"
            fi
        done
    fi
    
    echo ""
    echo "💡 提示:"
    echo "  ⚠️  Show模式无法获取原始规则名称，显示为通用名称"
    echo "  📋 可直接复制上述等效命令重新配置"
    if [[ "$DETECTED_INGRESS_IP" == "[无法自动检测]" || "$DETECTED_VIA_IP" == "[无法自动检测]" ]]; then
        echo "  ⚠️  部分IP参数无法自动检测，请手动补充"
    fi
}

# --- Show模式: 主函数 ---
show_tc_configuration() {
    parse_existing_tc_config || return 1
    generate_equivalent_command
}

# --- 配置TC限流规则主函数 ---
configure_tc_rules() {
    echo "=== 配置TC限流规则 ==="
    
    create_basic_tc_structure
    create_tc_rules_from_config
    
    echo ""
}



# --- Main Execution Function ---
main() {
    echo "[DEBUG] Starting main execution" >&2
    
    parse_arguments "$@"
    validate_parameters
    
    if [[ "$SHOW_MODE" == true ]]; then
        echo "[DEBUG] Executing show mode" >&2
        show_tc_configuration
        return 0
    fi
    
    echo "[DEBUG] Executing configuration mode" >&2
    show_configuration
    cleanup_existing_configuration
    
    # Execute requirements 1, 2, and 3 using consolidated function
    configure_system_settings    # Requirements 1, 2, and 3: IP forwarding, ARP proxy, route & neighbor table
    
    # Requirement 4: Configure TC rules (unchanged)
    configure_tc_rules
    
    echo ""
    echo "=== Configuration Completed ==="
    echo "[INFO] All configuration steps completed successfully" >&2
    echo "💡 Tip: Use '$0 show --egress-interface $EGRESS_INTERFACE' to view detailed configuration and reverse parsing results"
}

# --- 脚本入口点 ---
main "$@"
