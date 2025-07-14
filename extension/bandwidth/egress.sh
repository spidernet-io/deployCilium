#!/bin/bash

:<<EOF
 脚本调用命令：
 ./egress.sh \
     --egress-interface eth1 \
     --egress-total-bandwidth "1Gbit" \
     --egress-ip-bandwidth "172.16.1.49:200Mbit" \
     --egress-ip-bandwidth "172.16.1.50,172.16.1.51:300Mbit"

 ./egress.sh show --egress-interface eth1

 要实现 可重复调用 egress.sh 脚本，实现如下出口限流效果：
 
 在一个 linux 节点上，它实施 ip forward，并对相关流量限流
 在该节点上使用 egress tc 在 egress-interface 实现出口的限流，
 他需要 一个 一级别 父类 class 设置了 总的网卡带宽 egress-total-bandwidth 

     egress-ip-bandwidth 格式是 "ip1[,ip2,...]:bandwidth"
     一级别 父类 class 下有 根据 egress-ip-bandwidth 不同的 二级别 子类 
     每个 二级子类 基于 egress-ip-bandwidth 中的 ip 进行 filter，并设置 带宽 来 设置 限流 
      有一个 缺省的 二级子类，对没有 命中的 其它 ip 进行 共享  父类 class 的 带宽

 qdisc htb 1: root (总带宽)
 ├── class 1:1 (一级父类) 
     ├── class 1:10 (缺省，其他IP共享)
#     ├── class 1:11 (IP组1限流)
EOF

set -e

# --- 全局变量 ---
EGRESS_INTERFACE=""
EGRESS_TOTAL_BANDWIDTH=""
EGRESS_IP_RULES=()
SHOW_MODE=false
AUTO_ASSIGN_IPS=false

# --- 帮助信息函数 ---
show_help() {
    echo "用法: $0 [选项|命令]"
    echo ""
    echo "命令:"
    echo "  show --egress-interface IFACE  显示指定接口的TC配置和反解析结果"
    echo ""
    echo "选项:"
    echo "  --egress-interface IFACE       出口网络接口 (必需)"
    echo "  --egress-total-bandwidth BW    总出口带宽限制 (必需)"
    echo "  --egress-ip-bandwidth RULE     IP限流规则，格式: 'ip1[,ip2,...]：bandwidth' (可重复)"
    echo "  --auto-assign-ips              自动将限流IP地址配置到出口接口上 (可选)"
    echo "  --help                         显示此帮助信息"
    echo ""
    echo "示例:"
    echo "  配置限流:"
    echo "  $0 --egress-interface 'eth0' --egress-total-bandwidth '100Mbit' --egress-ip-bandwidth '192.168.1.10:10Mbit' --egress-ip-bandwidth '192.168.1.11,192.168.1.12:20Mbit'"
    echo ""
    echo "  配置限流并自动分配IP地址:"
    echo "  $0 --egress-interface 'eth0' --egress-total-bandwidth '100Mbit' --egress-ip-bandwidth '192.168.1.10:10Mbit' --auto-assign-ips"
    echo ""
    echo "  显示当前配置:"
    echo "  $0 show --egress-interface eth0           # 指定接口"
}

# --- 参数解析函数 ---
parse_arguments() {
    # 检查第一个参数是否是 show 命令
    if [[ $# -ge 1 && "$1" == "show" ]]; then
        SHOW_MODE=true
        shift
        # 继续处理 show 后面可能的参数（如 --egress-interface）
    fi
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            show)
                SHOW_MODE=true
                shift
                ;;
            --egress-interface)
                EGRESS_INTERFACE="$2"
                shift 2
                ;;
            --egress-total-bandwidth)
                EGRESS_TOTAL_BANDWIDTH="$2"
                shift 2
                ;;
            --egress-ip-bandwidth)
                EGRESS_IP_RULES+=("$2")
                shift 2
                ;;
            --auto-assign-ips)
                AUTO_ASSIGN_IPS=true
                shift
                ;;
            --help)
                show_help
                exit 0
                ;;
            *)
                echo "错误: 未知参数 $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# --- 参数验证函数 ---
validate_parameters() {
    # 在 show 模式下不需要验证参数
    if [[ "$SHOW_MODE" == "true" ]]; then
        return
    fi
    
    local errors=0

    if [[ -z "$EGRESS_INTERFACE" ]]; then
        echo "错误: 缺少 --egress-interface 参数"
        errors=1
    fi

    if [[ -z "$EGRESS_TOTAL_BANDWIDTH" ]]; then
        echo "错误: 缺少 --egress-total-bandwidth 参数"
        errors=1
    fi

    if [[ $errors -eq 1 ]]; then
        show_help
        exit 1
    fi
}

# --- 显示配置参数函数 ---
show_configuration() {
    echo "=== 配置参数 ==="
    echo "出口接口: $EGRESS_INTERFACE"
    echo "总出口带宽: $EGRESS_TOTAL_BANDWIDTH"
    echo "IP限流规则数量: ${#EGRESS_IP_RULES[@]}"
    for rule in "${EGRESS_IP_RULES[@]}"; do
        echo "  IP限流规则: $rule"
    done
    echo "自动分配IP地址: $(if [[ "$AUTO_ASSIGN_IPS" == "true" ]]; then echo "启用"; else echo "禁用"; fi)"
    echo ""
}

# --- 清理现有配置函数 ---
cleanup_existing_configuration() {
    echo "=== 清理现有配置 ==="

    # Check and remove any existing TC rules on the interface
    echo "检查现有TC规则..."
    
    # Get current qdisc information for the interface
    local current_qdisc=$(sudo tc qdisc show dev "$EGRESS_INTERFACE" 2>/dev/null | head -n1)
    
    if [[ -n "$current_qdisc" && "$current_qdisc" != *"noqueue"* && "$current_qdisc" != *"noop"* ]]; then
        echo "  发现现有队列规程: $current_qdisc"
        echo "  正在删除现有配置..."
        
        # Try to remove existing root qdisc
        local cleanup_success=false
        if sudo tc qdisc del dev "$EGRESS_INTERFACE" root 2>/dev/null; then
            echo "  TC规则删除完成"
            cleanup_success=true
        else
            # Check if it's a handle 0: qdisc that cannot be deleted normally
            if [[ "$current_qdisc" == *" 0: "* ]]; then
                echo "  检测到handle 0:的队列规程，无法直接删除"
                echo "  使用replace方式清理为默认状态..."
                
                # Use replace with pfifo_fast to clear the handle 0: qdisc
                # 如果 cilium 开启了 bandwidth，那么 handle 0: qdisc 无法删除，必须采用这个方式来生效删除
                if sudo tc qdisc replace dev "$EGRESS_INTERFACE" root pfifo_fast 2>/dev/null; then
                    echo "  handle 0:队列规程已成功替换为pfifo_fast"
                    cleanup_success=true
                else
                    echo "  警告: 替换handle 0:队列规程失败，但将继续执行"
                    cleanup_success=true  # Continue anyway
                fi
            else
                echo "  警告: 删除TC规则时出现问题，但将继续执行"
            fi
        fi
        
        # Wait a moment for the system to clean up
        if [[ "$cleanup_success" == "true" ]]; then
            sleep 0.5
        fi
        
        # Verify cleanup - now we can check all cases
        local after_cleanup=$(sudo tc qdisc show dev "$EGRESS_INTERFACE" 2>/dev/null | head -n1)
        echo "  清理后状态: ${after_cleanup:-'无队列规程'}"
        
        # Additional verification for successful cleanup
        if [[ -n "$after_cleanup" && "$after_cleanup" == *"pfifo_fast"* ]]; then
            echo "  ✓ 接口已恢复为默认pfifo_fast状态，可以正常创建HTB"
        elif [[ -z "$after_cleanup" ]]; then
            echo "  ✓ 接口已清理干净，可以正常创建HTB"
        fi
    else
        echo "  未发现需要清理的队列规程"
    fi

    echo ""
}

# --- 自动分配IP地址到接口函数 ---
assign_ips_to_interface() {
    if [[ "$AUTO_ASSIGN_IPS" != "true" ]]; then
        echo "自动分配IP地址功能未启用，跳过IP地址配置"
        return
    fi
    
    echo "=== 自动分配IP地址到接口 ==="
    echo "正在解析egress-ip-bandwidth规则中的IP地址..."
    
    # 收集所有需要分配的IP地址
    local all_ips=()
    
    for rule in "${EGRESS_IP_RULES[@]}"; do
        # 解析规则格式: "ip1[,ip2,...]:bandwidth"
        local ips_part="${rule%:*}"  # 获取冒号前的IP部分
        local bandwidth_part="${rule#*:}"  # 获取冒号后的带宽部分
        
        echo "  处理规则: $rule"
        echo "    IP部分: $ips_part"
        echo "    带宽部分: $bandwidth_part"
        
        # 分割多个IP地址（用逗号分隔）
        IFS=',' read -ra ip_array <<< "$ips_part"
        for ip in "${ip_array[@]}"; do
            # 去除空格
            ip=$(echo "$ip" | xargs)
            if [[ -n "$ip" ]]; then
                all_ips+=("$ip")
                echo "    发现IP: $ip"
            fi
        done
    done
    
    if [[ ${#all_ips[@]} -eq 0 ]]; then
        echo "  未发现需要分配的IP地址"
        echo ""
        return
    fi
    
    echo "  总共发现 ${#all_ips[@]} 个IP地址需要分配"
    echo ""
    
    # 检查接口是否存在
    if ! ip link show "$EGRESS_INTERFACE" >/dev/null 2>&1; then
        echo "  错误: 接口 $EGRESS_INTERFACE 不存在"
        return 1
    fi
    
    # 为每个IP地址配置到接口上
    local success_count=0
    local skip_count=0
    local error_count=0
    
    for ip in "${all_ips[@]}"; do
        echo "  正在处理IP: $ip"
        
        # 检查IP地址是否已经以任何掩码存在于接口上
        local existing_ip_info=$(ip addr show dev "$EGRESS_INTERFACE" | grep -E "inet[[:space:]]+$ip/" | head -n1)
        
        if [[ -n "$existing_ip_info" ]]; then
            # 提取现有的掩码长度
            local existing_mask=$(echo "$existing_ip_info" | grep -oE "$ip/[0-9]+" | cut -d'/' -f2)
            
            if [[ "$existing_mask" == "32" ]]; then
                echo "    ✓ IP $ip/32 已存在于接口 $EGRESS_INTERFACE 上，跳过"
            else
                echo "    ✓ IP $ip/$existing_mask 已存在于接口 $EGRESS_INTERFACE 上（非/32掩码），尊重现有配置，跳过"
            fi
            ((skip_count++))
            continue
        fi
        
        # 添加IP地址到接口
        if sudo ip addr add "$ip/32" dev "$EGRESS_INTERFACE" 2>/dev/null; then
            echo "    ✓ 成功添加 IP $ip/32 到接口 $EGRESS_INTERFACE"
            ((success_count++))
        else
            echo "    ✗ 添加 IP $ip/32 到接口 $EGRESS_INTERFACE 失败"
            ((error_count++))
        fi
    done
    
    echo ""
    echo "  📊 IP地址分配结果:"
    echo "    成功添加: $success_count 个"
    echo "    已存在跳过: $skip_count 个"
    echo "    添加失败: $error_count 个"
    echo "    总计处理: ${#all_ips[@]} 个"
    
    # 验证配置结果
    echo ""
    echo "  🔍 验证接口 $EGRESS_INTERFACE 上的IP地址配置:"
    for ip in "${all_ips[@]}"; do
        if ip addr show dev "$EGRESS_INTERFACE" | grep -q "$ip/32"; then
            echo "    ✓ $ip/32 已正确配置"
        else
            echo "    ✗ $ip/32 配置失败或不存在"
        fi
    done
    
    echo ""
    echo "=== IP地址自动分配完成 ==="
    echo ""
}

# --- 启用IP转发函数 ---
enable_ip_forwarding() {
    echo "=== 启用IP转发 ==="
    
    # 检查当前IP转发状态
    local current_forward=$(cat /proc/sys/net/ipv4/ip_forward)
    echo "当前IP转发状态: $current_forward"
    
    if [ "$current_forward" != "1" ]; then
        echo "启用IP转发..."
        echo 1 | sudo tee /proc/sys/net/ipv4/ip_forward > /dev/null
        echo "IP转发已启用"
    else
        echo "IP转发已经启用"
    fi
    echo ""
}

# --- 创建基础TC结构函数 ---
create_basic_tc_structure() {
    echo "1. 创建HTB根队列规程和一级父类..."
    
    # Create HTB root qdisc - cleanup function has already handled any existing qdiscs
    # Use r2q=100 to avoid quantum warnings
    sudo tc qdisc add dev "$EGRESS_INTERFACE" root handle 1: htb default 10 r2q 100
    
    # Create parent class
    sudo tc class add dev "$EGRESS_INTERFACE" parent 1: classid 1:1 htb rate "$EGRESS_TOTAL_BANDWIDTH" ceil "$EGRESS_TOTAL_BANDWIDTH"

    echo "2. 创建缺省二级子类（其他IP共享带宽）..."
    # Default child class for other IP traffic (1:10) - default class
    sudo tc class add dev "$EGRESS_INTERFACE" parent 1:1 classid 1:10 htb rate 1mbit ceil "$EGRESS_TOTAL_BANDWIDTH"
}

# --- 解析并创建IP限流规则函数 ---
create_ip_rules_from_config() {
    echo "3. 根据IP限流规则创建二级子类..."
    local classid_counter=11
    
    for rule in "${EGRESS_IP_RULES[@]}"; do
        # 解析规则格式: "ip1[,ip2,...]：bandwidth"
        if [[ "$rule" =~ ^([0-9.,]+):(.+)$ ]]; then
            local ips="${BASH_REMATCH[1]}"
            local bandwidth="${BASH_REMATCH[2]}"
            
            echo "  创建二级子类 1:$classid_counter，IP: $ips，带宽: $bandwidth"
            sudo tc class add dev "$EGRESS_INTERFACE" parent 1:1 classid 1:$classid_counter htb rate "$bandwidth" ceil "$bandwidth"
            
            # 为每个IP创建过滤器
            create_ip_filters "$ips" "$classid_counter"
            
            ((classid_counter++))
        else
            echo "  警告: IP限流规则格式错误: $rule (应为 'ip1[,ip2,...]：bandwidth')"
        fi
    done
}

# --- 创建IP过滤器函数 ---
create_ip_filters() {
    local ips="$1"
    local classid="$2"
    local prio_counter=1
    
    # 分割IP字符串
    IFS=',' read -ra IP_ARRAY <<< "$ips"
    for ip in "${IP_ARRAY[@]}"; do
        echo "    添加源IP $ip 的过滤器"
        sudo tc filter add dev "$EGRESS_INTERFACE" protocol ip parent 1: prio $prio_counter u32 \
            match ip src "$ip"/32 \
            flowid 1:$classid
        ((prio_counter++))
    done
}

# --- 创建主过滤器函数（简化设计中不需要） ---
create_main_filter() {
    echo "4. 主过滤器配置完成（简化设计中直接通过IP过滤器分类）"
}

# --- 配置TC限流规则主函数 ---
configure_tc_rules() {
    echo "=== 配置TC出口限流规则 ==="
    
    create_basic_tc_structure
    
    if [ ${#EGRESS_IP_RULES[@]} -gt 0 ]; then
        create_ip_rules_from_config
        create_main_filter
    else
        echo "未配置IP限流规则，所有流量将使用默认类别"
    fi
    
    echo ""
    echo "=== TC配置完成 ==="
}



# --- 验证配置结果函数 ---
verify_configuration() {
    echo "=== 验证配置 ==="
    
    echo "1. IP转发状态:"
    echo "  $(cat /proc/sys/net/ipv4/ip_forward)"
    
    echo ""
    echo "2. 接口状态:"
    ip link show "$EGRESS_INTERFACE" | head -1 || echo "  接口 $EGRESS_INTERFACE 不存在"

    echo ""
    echo "3. TC队列规程:"
    sudo tc -s qdisc show dev "$EGRESS_INTERFACE"

    echo ""
    echo "4. TC类别:"
    sudo tc -s class show dev "$EGRESS_INTERFACE"

    echo ""
    echo "5. TC过滤器:"
    echo "  IP过滤器 (parent 1:):"
    local ip_filters=$(sudo tc filter show dev "$EGRESS_INTERFACE" parent 1: | wc -l)
    if [ "$ip_filters" -gt 0 ]; then
        sudo tc -s filter show dev "$EGRESS_INTERFACE" parent 1: | sed 's/^/    /'
    else
        echo "    未发现IP过滤器"
    fi

    echo ""
    echo "=== 反解析当前TC配置 ==="
    
    # 检查是否存在HTB配置
    if ! sudo tc qdisc show dev "$EGRESS_INTERFACE" | grep -q "htb"; then
        echo "  未发现HTB配置，无法反解析"
    else
        echo "  解析配置中..."
        
        # 解析总带宽
        local total_bandwidth=""
        local class_output=$(sudo tc class show dev "$EGRESS_INTERFACE" | grep "class htb 1:1.*root")
        if [[ $class_output =~ rate[[:space:]]+([^[:space:]]+) ]]; then
            total_bandwidth="${BASH_REMATCH[1]}"
        fi
        
        # 创建临时关联数组来存储 classid -> bandwidth 映射
        declare -A class_bandwidth_map
        declare -A class_ip_map
        
        # 解析二级子类的带宽配置
        while IFS= read -r line; do
            if [[ $line =~ class[[:space:]]+htb[[:space:]]+1:([0-9]+)[[:space:]].*rate[[:space:]]+([^[:space:]]+) ]]; then
                local classid="${BASH_REMATCH[1]}"
                local bandwidth="${BASH_REMATCH[2]}"
                if [[ $classid != "10" && $classid != "1" ]]; then  # 排除默认类别1:10和根类别1:1
                    class_bandwidth_map["$classid"]="$bandwidth"
                fi
            fi
        done < <(sudo tc class show dev "$EGRESS_INTERFACE" 2>/dev/null)
        
        # 解析过滤器中的IP映射
        local current_classid=""
        while IFS= read -r line; do
            # 先查找flowid行，记录当前的classid
            if [[ $line =~ \*flowid[[:space:]]+1:([0-9]+) ]] || [[ $line =~ flowid[[:space:]]+1:([0-9]+) ]]; then
                current_classid="${BASH_REMATCH[1]}"
            fi
            
            # 然后查找match行，结合之前记录的classid
            if [[ $line =~ match[[:space:]]+([0-9a-f]+)/ffffffff[[:space:]]+at[[:space:]]+12 ]]; then
                local ip_hex="${BASH_REMATCH[1]}"
                
                # 将十六进制IP转换为点分十进制
                if [[ ${#ip_hex} -eq 8 && -n "$current_classid" ]]; then
                    local a=$((0x${ip_hex:0:2}))
                    local b=$((0x${ip_hex:2:2}))
                    local c=$((0x${ip_hex:4:2}))
                    local d=$((0x${ip_hex:6:2}))
                    local ip_decimal="$a.$b.$c.$d"
                    
                    # 添加到对应类别的IP列表
                    if [[ -n "${class_ip_map[$current_classid]}" ]]; then
                        class_ip_map["$current_classid"]="${class_ip_map[$current_classid]},$ip_decimal"
                    else
                        class_ip_map["$current_classid"]="$ip_decimal"
                    fi
                fi
            fi
        done < <(sudo tc filter show dev "$EGRESS_INTERFACE" parent 1: 2>/dev/null)
        
        # 构建等价命令行
        echo ""
        echo "  📋 等价的命令行配置:"
        echo ""
        
        local cmd_line="./egress.sh \\"
        cmd_line="$cmd_line"$'\n'"    --egress-interface $EGRESS_INTERFACE \\"
        
        if [[ -n "$total_bandwidth" ]]; then
            cmd_line="$cmd_line"$'\n'"    --egress-total-bandwidth $total_bandwidth \\"
        fi
        
        # 按类别输出IP限流规则（保持原有分组）
        for classid in "${!class_bandwidth_map[@]}"; do
            local bandwidth="${class_bandwidth_map[$classid]}"
            local ips="${class_ip_map[$classid]}"
            
            if [[ -n "$ips" && -n "$bandwidth" ]]; then
                cmd_line="$cmd_line"$'\n'"    --egress-ip-bandwidth \"$ips:$bandwidth\" \\"
            fi
        done
        
        # 移除最后的反斜杠
        cmd_line="${cmd_line%\\*}"
        
        echo "$cmd_line"
        
        if [[ ${#class_bandwidth_map[@]} -eq 0 ]]; then
            echo "  📝 注意: 未发现IP限流规则"
        fi
        
        echo ""
        echo "  📊 配置总结:"
        if [[ -n "$total_bandwidth" ]]; then
            echo "    总带宽: $total_bandwidth"
        fi
        echo "    限流规则数: ${#class_bandwidth_map[@]}"
        # 计算受限IP总数
        local total_ips=0
        for classid in "${!class_ip_map[@]}"; do
            local ips="${class_ip_map[$classid]}"
            if [[ -n "$ips" ]]; then
                local ip_count=$(echo "$ips" | tr ',' '\n' | wc -l)
                ((total_ips += ip_count))
            fi
        done
        echo "    受限IP总数: $total_ips"
        
        # 显示限流规则分布
        if [[ ${#class_bandwidth_map[@]} -gt 0 ]]; then
            echo "    限流规则分布:"
            for classid in "${!class_bandwidth_map[@]}"; do
                local bandwidth="${class_bandwidth_map[$classid]}"
                local ips="${class_ip_map[$classid]}"
                if [[ -n "$ips" && -n "$bandwidth" ]]; then
                    local ip_count=$(echo "$ips" | tr ',' '\n' | wc -l)
                    echo "      规则$classid: $ip_count 个IP 限制 $bandwidth"
                fi
            done
        fi
    fi

    echo ""
    echo "=== 配置验证完成 ==="
    echo ""
    echo "📝 使用说明:"
    echo "  - 出口接口 $EGRESS_INTERFACE 总带宽限制: $EGRESS_TOTAL_BANDWIDTH"
    echo "  - 配置了 ${#EGRESS_IP_RULES[@]} 条IP限流规则"
    echo "  - 指定IP的出口流量将根据配置进行限流"
    echo "  - 其他IP的出口流量共享总带宽"
    echo ""
    echo "=== 脚本执行成功 ==="
}

# --- 主执行函数 ---
main() {
    parse_arguments "$@"
    validate_parameters
    
    if [[ "$SHOW_MODE" == "true" ]]; then
        # show 模式：只显示当前配置
        echo "=== 显示当前TC配置 ==="
        
        # 自动检测配置了HTB的接口
        if [[ -z "$EGRESS_INTERFACE" ]]; then
            EGRESS_INTERFACE=$(detect_htb_interface)
            echo "自动检测到HTB接口: $EGRESS_INTERFACE"
            echo ""
        fi
        
        verify_configuration
    else
        # 配置模式：执行配置但不显示详细验证
        show_configuration
        cleanup_existing_configuration
        assign_ips_to_interface
        enable_ip_forwarding
        configure_tc_rules
        echo ""
        echo "=== 配置完成 ==="
        echo "💡 提示: 使用 '$0 show --egress-interface $EGRESS_INTERFACE' 查看详细配置信息"
        echo ""
        echo "=== 脚本执行成功 ==="
    fi
}

# --- 脚本入口点 ---
main "$@"

