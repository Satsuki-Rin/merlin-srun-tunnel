#!/bin/sh
# Net Stack 2：一个控制循环；事件只请求重新检查，真实状态决定下一步。
# 运行依赖：Merlin BusyBox、curl、openssl、flock、iptables-restore、Xray。
umask 077
ROOT=${NETSTACK_ROOT:-$(CDPATH= cd "$(dirname "$0")" && pwd)}
RUN=${NETSTACK_RUN:-/tmp/net-stack}
CONF=${NETSTACK_CONF:-$ROOT/net-stack.conf}
MODEFILE=$ROOT/mode
mkdir -p "$RUN"
[ -r "$CONF" ] || { echo "缺少配置：$CONF" >&2; exit 1; }
. "$CONF"
PORTAL="http://$PORTAL_IP:$PORTAL_PORT"
SELF=$ROOT/netctl.sh

# ---- 通用工具：不根据文件 mtime 判断锁；不在 JFFS 记录运行状态。 ----
now() { cut -d. -f1 /proc/uptime; }
mode() { cat "$MODEFILE" 2>/dev/null || echo off; }
put() { printf '%s\n' "$2" > "$1.new.$$" && mv -f "$1.new.$$" "$1"; }
log() { printf '[%s +%ss] %s\n' "$(date '+%F %T')" "$(now)" "$*" >> "$RUN/control.log"; }
state() {
    [ "$(cat "$RUN/state" 2>/dev/null)" = "$1" ] || { put "$RUN/state" "$1"; log "$1"; }
}
rotate() {
    [ -f "$1" ] || return 0
    [ "$(wc -c < "$1")" -lt 524288 ] && return 0
    tail -n 300 "$1" > "$1.tail" && cat "$1.tail" > "$1"
    rm -f "$1.tail"
}
# PID + 内核启动时刻 + 命令行，避免 PID 复用，也不误杀其他 Xray。
pid_alive() {
    [ -r "$1" ] || return 1
    read p born < "$1"
    case "$p:$born" in *[!0-9:]*|:*) return 1;; esac
    [ -r "/proc/$p/stat" ] || return 1
    [ "$(awk '{print $22}' "/proc/$p/stat")" = "$born" ] || return 1
    [ "$(awk '{print $3}' "/proc/$p/stat")" != Z ] || return 1
    # 冷启动从 JFFS 装载 30MB ELF 可能数秒才完成 exec；此时 argv 仍是 shell。
    # 本进程亲自创建、PID/启动时刻均匹配的子进程无需等 argv 就绪，避免误判后重复启动。
    if [ "$2" = "$ROOT/bin/xray run -c $RUN/client.json" ] &&
       [ "$(awk '{print $4}' "/proc/$p/stat")" = "$$" ]; then return 0; fi
    tr '\000' ' ' < "/proc/$p/cmdline" | grep -q -F "$2"
}
remember_pid() { put "$1" "$2 $(awk '{print $22}' "/proc/$2/stat")"; }
validate() {
    for n in LAN_IF WAN_IF TUN ENDPOINT TLS_NAME XHTTP_HOST; do
        eval 'v=${'"$n"'}'
        case "$v" in ''|*[!a-zA-Z0-9_.:-]*) echo "无效配置 $n" >&2; return 1;; esac
    done
    for n in PORTAL_IP DNS1 DNS2 HOME_DNS LAN_CIDR LAN6_CIDR LAN6_ADDR TUN4 TUN6; do
        eval 'v=${'"$n"'}'
        case "$v" in ''|*[!0-9a-fA-F:./]*) echo "无效地址 $n" >&2; return 1;; esac
    done
    for n in WAN_UNIT TABLE RULE_PRIORITY MTU PORTAL_PORT AC_ID ENDPOINT_PORT SOCKS_PORT DNS_PORT AUTH_INTERVAL LOGIN_INTERVAL HEALTH_INTERVAL DNS_INTERVAL HTTP_TIMEOUT BOOT_DELAY; do
        eval 'v=${'"$n"'}'
        case "$v" in ''|*[!0-9]*) echo "无效整数 $n" >&2; return 1;; esac
    done
    [ "$TABLE" -ge 300 ] && [ "$RULE_PRIORITY" -ge 1000 ] && [ "$RULE_PRIORITY" -lt 32766 ] && [ "$LOGIN_INTERVAL" -ge 20 ] &&
        [ "$HTTP_TIMEOUT" -gt 0 ] && [ "$HTTP_TIMEOUT" -le 30 ] &&
        [ "$AUTH_INTERVAL" -ge 15 ] && [ "$HEALTH_INTERVAL" -ge 5 ] || return 1
    [ "${LAN6_CIDR#*/}" = 64 ] && [ "${LAN6_ADDR#*/}" = 64 ] || { echo 'LAN IPv6 SLAAC 需要 /64' >&2; return 1; }
    [ -n "$USERNAME" ] && [ -n "$PASSWORD" ] || { echo '请填写校园网账号密码' >&2; return 1; }
    case "$UUID" in ''|00000000-0000-0000-0000-000000000000|*[!0-9a-fA-F-]*) echo '请填写 UUID' >&2; return 1;; esac
}

# ---- 数据平面：短 flock 只包住本地规则/路由操作，不包含任何网络探测。 ----
# iptables-restore --noflush 在每个表内一次提交，绝不先撤 OUTPUT 再重建。
# IPv4/IPv6 各自原子提交；只操作 NS2_* 自有链，保留固件与插件规则。
filter_rules() {
    fam=$1; gate=$2
    if [ "$fam" = 4 ]; then xt=iptables; else xt=ip6tables; fi
    echo '*filter'
    echo ':NS2_FWD - [0:0]'; echo ':NS2_OUT - [0:0]'
    echo '-F NS2_FWD'; echo '-F NS2_OUT'
    "$xt" -S FORWARD | sed -n 's/^-A FORWARD -j NS2_FWD$/-D FORWARD -j NS2_FWD/p'
    "$xt" -S OUTPUT | sed -n 's/^-A OUTPUT -j NS2_OUT$/-D OUTPUT -j NS2_OUT/p'
    if [ "$gate" != off ]; then
        echo "-A NS2_FWD -i $LAN_IF -o $LAN_IF -j ACCEPT"
        if [ "$gate" = allow ]; then
            echo "-A NS2_FWD -i $LAN_IF -o $TUN -j ACCEPT"
            echo "-A NS2_FWD -i $TUN -o $LAN_IF -j ACCEPT"
        fi
        echo "-A NS2_FWD -i $LAN_IF -j DROP"
        echo "-A NS2_OUT ! -o $WAN_IF -j RETURN"
        if [ "$fam" = 4 ]; then
            echo "-A NS2_OUT -d $PORTAL_IP -p tcp --dport $PORTAL_PORT -j ACCEPT"
            for dns in "$DNS1" "$DNS2"; do
                echo "-A NS2_OUT -d $dns -p udp --dport 53 -j ACCEPT"
                echo "-A NS2_OUT -d $dns -p tcp --dport 53 -j ACCEPT"
            done
            echo '-A NS2_OUT -p udp --sport 68 --dport 67 -j ACCEPT'
            # 认证预访问也是本渲染器的状态；并发 firewall hook 不会覆盖它。
            if [ -r "$RUN/bootstrap" ]; then
                read bootstrap_ip bootstrap_until < "$RUN/bootstrap"
                [ "$(now)" -gt "$bootstrap_until" ] || echo "-A NS2_OUT -d $bootstrap_ip -p tcp --dport 80 -j ACCEPT"
            fi
        else
            # 保留邻居发现、路径 MTU、MLD 和 DHCPv6；不开放普通 IPv6 出站。
            for type in 1 2 3 4 130 131 132 133 135 136 143; do
                echo "-A NS2_OUT -p ipv6-icmp --icmpv6-type $type -j ACCEPT"
            done
            echo '-A NS2_OUT -p udp --sport 546 --dport 547 -j ACCEPT'
        fi
        if [ -f "$RUN/endpoint$fam" ]; then
            while read addr; do
                [ -z "$addr" ] || echo "-A NS2_OUT -d $addr -p tcp --dport $ENDPOINT_PORT -j ACCEPT"
            done < "$RUN/endpoint$fam"
        fi
        echo '-A NS2_OUT -j DROP'
        echo '-I FORWARD 1 -j NS2_FWD'; echo '-I OUTPUT 1 -j NS2_OUT'
    fi
    echo COMMIT
}
nat_rules() {
    echo '*nat'; echo ':NS2_DNS - [0:0]'; echo '-F NS2_DNS'
    iptables -t nat -S PREROUTING | sed -n 's/^-A PREROUTING -j NS2_DNS$/-D PREROUTING -j NS2_DNS/p'
    if [ "$1" != off ]; then
        echo "-A NS2_DNS -i $LAN_IF -p udp --dport 53 -j REDIRECT --to-ports 53"
        echo "-A NS2_DNS -i $LAN_IF -p tcp --dport 53 -j REDIRECT --to-ports 53"
        echo '-I PREROUTING 1 -j NS2_DNS'
    fi
    echo COMMIT
}
routes() {
    if [ "$1" = off ]; then
        while ip rule del iif "$LAN_IF" lookup "$TABLE" 2>/dev/null; do :; done
        while ip -6 rule del iif "$LAN_IF" lookup "$TABLE" 2>/dev/null; do :; done
        ip route flush table "$TABLE" 2>/dev/null
        ip -6 route flush table "$TABLE" 2>/dev/null
        ip -6 addr del "$LAN6_ADDR" dev "$LAN_IF" 2>/dev/null || :
        return 0
    fi
    # 黑洞后备路由常驻：TUN 消失时，查表不能继续落到校园 WAN。
    # 2.6.36 的 IPv6 replace 对已存在路由会报 EEXIST，先检查再 add。
    routes4=$(ip route show table "$TABLE" 2>/dev/null)
    routes6=$(ip -6 route show table "$TABLE" 2>/dev/null)
    echo "$routes4" | grep -q '^blackhole default.*metric 32767' || ip route add blackhole default metric 32767 table "$TABLE" || return 1
    echo "$routes6" | grep -q '^unreachable default dev lo.*metric 32767' || ip -6 route add unreachable default dev lo metric 32767 table "$TABLE" || return 1
    echo "$routes4" | grep -q -F "$LAN_CIDR dev $LAN_IF" || ip route add "$LAN_CIDR" dev "$LAN_IF" table "$TABLE" || return 1
    echo "$routes6" | grep -q -F "$LAN6_CIDR dev $LAN_IF" || ip -6 route add "$LAN6_CIDR" dev "$LAN_IF" table "$TABLE" || return 1
    ip rule show | grep -q "iif $LAN_IF.*lookup $TABLE" || ip rule add iif "$LAN_IF" lookup "$TABLE" priority "$RULE_PRIORITY" || return 1
    ip -6 rule show | grep -q "iif $LAN_IF.*lookup $TABLE" || ip -6 rule add iif "$LAN_IF" lookup "$TABLE" priority "$RULE_PRIORITY" || return 1
    if [ "$1" = allow ]; then
        ip -6 addr show dev "$LAN_IF" | grep -q -F " $LAN6_ADDR " || ip -6 addr add "$LAN6_ADDR" dev "$LAN_IF" || return 1
        ip link set "$TUN" up || return 1
        echo "$routes4" | grep -q "^default dev $TUN .*metric 10" || ip route add default dev "$TUN" metric 10 table "$TABLE" || return 1
        echo "$routes6" | grep -q "^default dev $TUN .*metric 10" || ip -6 route add default dev "$TUN" metric 10 table "$TABLE" || return 1
    fi
}
# 调用者已持有 fd 8；所有调用都重新读取模式，拒绝过期的放行结果。
firewall_locked() {
    gate=$1
    [ "$(mode)" = tunnel ] || gate=off
    [ "$gate" != allow ] || [ ! -f "$RUN/event" ] || gate=block
    # 放行前先确保路由；封锁时先提交 DROP，再修复路由。
    if [ "$gate" = allow ]; then routes allow || gate=block; fi
    filter_rules 4 "$gate" > "$RUN/filter4"
    iptables-restore --noflush < "$RUN/filter4" || return 1
    filter_rules 6 "$gate" > "$RUN/filter6"
    ip6tables-restore --noflush < "$RUN/filter6" || return 1
    nat_rules "$gate" > "$RUN/nat4"
    iptables-restore --noflush < "$RUN/nat4" || return 1
    [ "$gate" = allow ] || routes "$gate" || return 1
    put "$RUN/gate" "$gate"
}
firewall() ( exec 8>"$RUN/firewall.lock"; flock -x 8 || exit 1; firewall_locked "$1"; )

# ---- DNS 与 Xray 配置由同一份配置生成，没有对 JSON 排版的依赖。 ----
jsonesc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
render_xray() {
    cat > "$RUN/client.json.new" <<JSON
{"log":{"loglevel":"warning"},"inbounds":[
 {"tag":"tun-in","protocol":"tun","settings":{"name":"$TUN","mtu":$MTU,"inet4_address":"$TUN4","inet6_address":"$TUN6","stack":"gvisor","auto_route":false,"strict_route":false,"sniffing":true,"sniffing_dest_override":["http","tls","quic"]}},
 {"tag":"socks-local","listen":"127.0.0.1","port":$SOCKS_PORT,"protocol":"socks","settings":{"udp":true}},
 {"tag":"dns-in","listen":"127.0.0.1","port":$DNS_PORT,"protocol":"dokodemo-door","settings":{"address":"$HOME_DNS","port":53,"network":"tcp,udp"}}
],"outbounds":[{"tag":"proxy","protocol":"vless","settings":{"vnext":[{"address":"$ENDPOINT","port":$ENDPOINT_PORT,"users":[{"id":"$UUID","encryption":"none"}]}]},"streamSettings":{"security":"tls","tlsSettings":{"serverName":"$TLS_NAME","alpn":["h2"],"fingerprint":"chrome"},"network":"xhttp","xhttpSettings":{"host":"$XHTTP_HOST","path":"$(jsonesc "$XHTTP_PATH")","mode":"stream-one","xPaddingObfsMode":true,"xPaddingMethod":"tokenish","xPaddingPlacement":"cookie","xPaddingKey":"ck_sess","xPaddingBytes":"200-1200"}}}],"routing":{"rules":[{"type":"field","inboundTag":["dns-in","tun-in"],"outboundTag":"proxy"}]}}
JSON
    mv -f "$RUN/client.json.new" "$RUN/client.json"
}
dns_config() {
    [ "$(mode)" = tunnel ] && [ -f "$1" ] || return 0
    # no-resolv 不会禁用 servers-file；必须删除固件生成的所有上游。
    awk '
      /# >>> net-stack dns >>>/ {skip=1; next}
      /# <<< net-stack dns <<</ {skip=0; next}
      skip {next}
      /^(servers-file|resolv-file|server)=/ || /^no-resolv$/ || /^enable-ra$/ {next}
      /^dhcp-range=.*ra-only/ || /^dhcp-option=option6:dns-server,/ {next}
      {print}
    ' "$1" > "$RUN/dnsmasq.$$" || return 1
    {
        cat "$RUN/dnsmasq.$$"
        echo '# >>> net-stack dns >>>'
        echo no-resolv
        echo "server=127.0.0.1#$DNS_PORT"
        echo "server=/$ENDPOINT/$DNS1"
        echo "server=/$ENDPOINT/$DNS2"
        echo enable-ra
        echo "dhcp-range=${LAN6_CIDR%/*},ra-only,${LAN6_CIDR#*/},12h"
        echo "dhcp-option=option6:dns-server,[${LAN6_ADDR%/*}]"
        echo '# <<< net-stack dns <<<'
    } > "$1"
    rm -f "$RUN/dnsmasq.$$"
}
resolve_endpoint() (
    # DNS 请求在锁外，有超时；失败时保留上次成功地址，避免抖动导致全量重启。
    f="$RUN/resolve.$$"; : > "$f"
    for dns in "$DNS1" "$DNS2"; do
        timeout -t "$HTTP_TIMEOUT" nslookup "$ENDPOINT" "$dns" 9>&- 2>/dev/null | awk '
          /^Name:/ {found=1; next}
          found && /^Address/ {for(i=2;i<=NF;i++) if (($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ || ($i ~ /^[0-9a-fA-F:]+$/ && $i ~ /:.*:/))) print $i}
        ' >> "$f"
    done
    [ -s "$f" ] || { rm -f "$f"; return 1; }
    sort -u "$f" > "$f.sorted"
    grep -v ':' "$f.sorted" > "$f.4"; grep ':' "$f.sorted" > "$f.6"
    exec 8>"$RUN/firewall.lock"; flock -x 8 || exit 1
    changed=0
    cmp -s "$f.4" "$RUN/endpoint4" && cmp -s "$f.6" "$RUN/endpoint6" || changed=1
    mv -f "$f.4" "$RUN/endpoint4"; mv -f "$f.6" "$RUN/endpoint6"
    rm -f "$f" "$f.sorted"
    [ "$changed" = 1 ] || return 0
    firewall_locked block || return 1
    return 10
)

dns_flush() {
    # DDNS 变化后清掉 dnsmasq 的旧缓存，避免 Xray 继续得到旧地址。
    dns_pid=$(cat /var/run/dnsmasq.pid 2>/dev/null)
    case "$dns_pid" in ''|*[!0-9]*) return 0;; esac
    if [ -r "/proc/$dns_pid/cmdline" ] && tr '\000' ' ' < "/proc/$dns_pid/cmdline" | grep -q dnsmasq; then
        kill -HUP "$dns_pid" 2>/dev/null || :
    fi
}

# ---- 深澜协议：无独立守护、回调或快速重试。只有下面的控制循环能登录。 ----
httpget() { curl -A 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124.0.0.0 Safari/537.36' --noproxy '*' -fs -m "$HTTP_TIMEOUT" "$1" 9>&- 2>/dev/null; }
jget() {
    printf '%s' "$1" | awk -v key="$2" '{s=s $0} END {
      p="\""key"\"[ \t]*:[ \t]*"; if(!match(s,p)) exit
      r=substr(s,RSTART+RLENGTH)
      if(substr(r,1,1)=="\"") {r=substr(r,2); print substr(r,1,index(r,"\"")-1)}
      else {match(r,/^[^,}]*/); print substr(r,1,RLENGTH)}
    }'
}
urlenc() {
    printf '%s' "$1" | hexdump -v -e '1/1 "%u "' | awk '{for(i=1;i<=NF;i++) {
      b=$i+0; if((b>=48&&b<=57)||(b>=65&&b<=90)||(b>=97&&b<=122)||b==45||b==46||b==95||b==126) printf "%c",b
      else printf "%%%02X",b
    }}'
}
sha1() { printf '%s' "$1" | openssl dgst -sha1 | sed 's/^.*[= ]//'; }
hmac() { printf '%s' "$PASSWORD" | openssl dgst -md5 -hmac "$1" | sed 's/^.*[= ]//'; }
xencode() { printf '%s' "$1" | hexdump -v -e '1/1 "%u "' | LC_ALL=C awk -v TOKEN="$2" -f "$ROOT/xencode.awk"; }
auth_status() {
    reply=$(httpget "$PORTAL/cgi-bin/rad_user_info?callback=cb&ip=$WAN_IP") || return 2
    case "$(jget "$reply" error)" in
        ok) [ "$(jget "$reply" online_ip)" = "$WAN_IP" ] && return 0;;
        not_online_error) return 1;;
    esac
    return 2                          # 未知不等于离线，不能据此发 login。
}
bootstrap() (
    target=$(head -n 1 "$RUN/endpoint4" 2>/dev/null)
    [ -n "$target" ] || { log 'bootstrap: endpoint IPv4 unavailable'; return 1; }
    # 规则的创建、刷新和删除都经过同一锁和渲染器，退出/超时后必清理。
    cleanup() (
        exec 8>"$RUN/firewall.lock"; flock -x 8 || exit 1
        rm -f "$RUN/bootstrap"; firewall_locked block
    )
    trap cleanup EXIT
    trap 'exit 130' INT; trap 'exit 143' TERM
    (
        exec 8>"$RUN/firewall.lock"; flock -x 8 || exit 1
        put "$RUN/bootstrap" "$target $(( $(now) + HTTP_TIMEOUT + 5 ))"
        firewall_locked block
    ) || return 1
    code=$(curl --noproxy '*' --interface "$WAN_IF" -s --connect-timeout 3 -m "$HTTP_TIMEOUT" -o /dev/null -w '%{http_code}' "http://$target/" 9>&-)
    log "bootstrap HTTP=$code"
    case "$code" in 200|30[12378]) return 0;; *) return 1;; esac
)
auth_login() {
    last=$(cat "$RUN/last-login" 2>/dev/null || echo 0)
    [ "$(( $(now) - last ))" -ge "$LOGIN_INTERVAL" ] || return 3
    [ "$(mode)" != off ] || return 3
    put "$RUN/last-login" "$(now)"  # 守护崩溃/重启也不能绕过全局限频。
    bootstrap || return 1
    token=$(jget "$(httpget "$PORTAL/cgi-bin/get_challenge?callback=cb&username=$(urlenc "$USERNAME")&ip=$WAN_IP&_=$(date +%s)000")" challenge)
    [ -n "$token" ] || { log 'authentication: missing challenge'; return 1; }
    md5=$(hmac "$token"); [ "${#md5}" = 32 ] || return 1
    info_json="{\"username\":\"$(jsonesc "$USERNAME")\",\"password\":\"$(jsonesc "$PASSWORD")\",\"ip\":\"$WAN_IP\",\"acid\":\"$AC_ID\",\"enc_ver\":\"srun_bx1\"}"
    encoded=$(xencode "$info_json" "$token"); [ -n "$encoded" ] || return 1
    info="{SRBX1}$encoded"
    checksum=$(sha1 "$token$USERNAME$token$md5$token$AC_ID$token$WAN_IP${token}200${token}1$token$info")
    [ "${#checksum}" = 40 ] || return 1
    [ "$(mode)" != off ] || return 3
    put "$RUN/last-login" "$(now)"
    log 'authentication: submit login'
    reply=$(httpget "$PORTAL/cgi-bin/srun_portal?callback=cb&action=login&username=$(urlenc "$USERNAME")&password=$(urlenc "{MD5}$md5")&ac_id=$AC_ID&ip=$WAN_IP&info=$(urlenc "$info")&chksum=$checksum&n=200&type=1&double_stack=$DOUBLE_STACK")
    err=$(jget "$reply" error); suc=$(jget "$reply" suc_msg)
    [ "$err" = ok ] || [ "$suc" = ip_already_online_error ] || { log "authentication rejected: $err $(jget "$reply" error_msg)"; return 1; }
    for attempt in 1 2 3; do
        auth_status && { log 'authentication: confirmed online'; return 0; }
        [ "$attempt" = 3 ] || sleep 2
    done
    log 'authentication accepted but online status not confirmed'
    return 1
}
fix_clock() {
    [ "$(date +%Y)" -ge 2025 ] && return 0
    header=$(curl --noproxy '*' -sSI -m "$HTTP_TIMEOUT" "$PORTAL/" 9>&- | awk -F': ' 'tolower($1)=="date" {print $2}' | tr -d '\r')
    set -- $header
    [ "$#" = 6 ] || return 1
    case "$3" in Jan)m=01;; Feb)m=02;; Mar)m=03;; Apr)m=04;; May)m=05;; Jun)m=06;; Jul)m=07;; Aug)m=08;; Sep)m=09;; Oct)m=10;; Nov)m=11;; Dec)m=12;; *)return 1;; esac
    TZ=UTC0 date -s "$4-$m-$2 $5" >/dev/null || return 1
    log 'clock corrected from portal HTTP Date'
}
wan_ready() {
    WAN_IP=$(nvram get "wan${WAN_UNIT}_ipaddr")
    case "$WAN_IP" in ''|0.0.0.0) return 1;; esac
    ip route get "$PORTAL_IP" 2>/dev/null | grep -q "dev $WAN_IF"
}

# ---- Xray 是唯一子服务，由控制循环直接管理；没有第二个 supervisor。 ----
xray_stop() {
    if pid_alive "$RUN/xray.pid" "$ROOT/bin/xray run -c $RUN/client.json"; then
        kill "$p" 2>/dev/null
        for second in 1 2 3; do
            pid_alive "$RUN/xray.pid" "$ROOT/bin/xray run -c $RUN/client.json" || break
            sleep 1
        done
        pid_alive "$RUN/xray.pid" "$ROOT/bin/xray run -c $RUN/client.json" && kill -9 "$p" 2>/dev/null
        wait "$p" 2>/dev/null || :
    fi
    rm -f "$RUN/xray.pid"
}
xray_start() {
    [ "$(mode)" = tunnel ] || return 1
    pid_alive "$RUN/xray.pid" "$ROOT/bin/xray run -c $RUN/client.json" && return 0
    if ! lsmod | grep -q '^tun '; then
        modprobe tun 2>/dev/null || {
            for module in /lib/modules/*/kernel/drivers/net/tun.ko /rom/lib/modules/*/kernel/drivers/net/tun.ko; do
                [ -f "$module" ] && insmod "$module" && break
            done
        }
    fi
    [ -e /dev/net/tun ] || { mkdir -p /dev/net; mknod /dev/net/tun c 10 200; }
    [ -c /dev/net/tun ] || return 1
    chmod 600 /dev/net/tun
    if [ "$(cat /proc/sys/vm/overcommit_memory)" = 2 ]; then
        [ "$(cat /proc/sys/vm/overcommit_ratio)" -ge 400 ] || echo 400 > /proc/sys/vm/overcommit_ratio
    fi
    render_xray
    "$ROOT/bin/xray" run -c "$RUN/client.json" </dev/null >> "$RUN/xray.log" 2>&1 9>&- 8>&- &
    remember_pid "$RUN/xray.pid" "$!"
    log "xray started pid=$!"
}
healthy() {
    pid_alive "$RUN/xray.pid" "$ROOT/bin/xray run -c $RUN/client.json" || return 1
    [ -d "/sys/class/net/$TUN" ] || return 1
    netstat -lnt | grep -q ":$DNS_PORT " || return 1
    [ "$(curl --noproxy '' -s -m "$HTTP_TIMEOUT" -o /dev/null -w '%{http_code}' --socks5-hostname "127.0.0.1:$SOCKS_PORT" "$HEALTH_URL" 9>&-)" = 204 ]
}

# ---- 唯一状态机：每次检查有限步骤，失败回到下轮；不存在永久 WAN_DOWN。 ----
step() {
    desired=$(mode)
    if [ "$desired" != "$previous_mode" ]; then
        firewall block || return 1
        xray_stop
        service restart_dnsmasq 9>&- 8>&- >/dev/null 2>&1
        previous_mode=$desired; online=0; next_auth=0; next_dns=0; next_health=0
        state "mode=$desired"
    fi
    if [ "$desired" = off ]; then state off; return 0; fi
    if ! wan_ready; then
        [ "$online" = 0 ] && [ "$(cat "$RUN/gate" 2>/dev/null)" != allow ] || firewall block
        xray_stop; online=0; next_auth=0
        state waiting-wan; return 0
    fi
    if [ "$WAN_IP" != "$previous_ip" ]; then
        firewall block; xray_stop
        previous_ip=$WAN_IP; online=0; next_auth=0; next_dns=0
    fi
    tick=$(now)
    [ "$tick" -ge "$settle_until" ] || { state settling-wan; return 0; }
    if [ "$tick" -ge "$next_auth" ]; then
        next_auth=$((tick + AUTH_INTERVAL))
        if ! fix_clock; then firewall block; state waiting-clock; return 0; fi
        auth_status; status=$?
        case "$status" in
            0) online=1;;
            1)
                online=0; firewall block; xray_stop
                resolve_endpoint; resolved=$?
                if [ "$resolved" = 0 ] || [ "$resolved" = 10 ]; then
                    auth_login && online=1
                fi
                ;;
            *) online=0; firewall block; xray_stop; state auth-unknown; return 0;;
        esac
    fi
    [ "$(mode)" = "$desired" ] || return 0
    [ "$online" = 1 ] || { state waiting-auth; return 0; }
    [ "$desired" = tunnel ] || { state auth-online; return 0; }
    if [ "$tick" -ge "$next_dns" ]; then
        next_dns=$((tick + DNS_INTERVAL))
        resolve_endpoint; resolved=$?
        [ "$resolved" != 10 ] || { xray_stop; dns_flush; next_health=0; log 'endpoint addresses changed'; }
        # 无缓存且 DNS 失败时不能启动；有缓存时保留已工作的连接，继续周期重试。
        [ -s "$RUN/endpoint4" ] || [ -s "$RUN/endpoint6" ] || { firewall block; state waiting-endpoint; return 0; }
    fi
    if ! pid_alive "$RUN/xray.pid" "$ROOT/bin/xray run -c $RUN/client.json"; then
        firewall block
        if [ -f "$RUN/xray.pid" ]; then
            rm -f "$RUN/xray.pid"
            restart_at=$((tick + restart_delay))
            log "xray exited unexpectedly; retry in ${restart_delay}s"
            restart_delay=$((restart_delay * 2)); [ "$restart_delay" -le 300 ] || restart_delay=300
        fi
        [ "$tick" -ge "$restart_at" ] || { state xray-backoff; return 0; }
        xray_start || { restart_at=$((tick + 30)); return 1; }
        restart_at=$((tick + 10)); next_health=$((tick + 2))
    fi
    if [ "$tick" -ge "$next_health" ]; then
        next_health=$((tick + HEALTH_INTERVAL))
        if healthy; then
            failures=0; restart_delay=2
            firewall allow || { state firewall-error; return 1; }
            [ "$(cat "$RUN/gate")" != allow ] || state tunnel-online
        else
            firewall block; failures=$((failures + 1)); state tunnel-unhealthy
            if [ "$failures" -ge 2 ]; then
                [ "$restart_delay" -ge 20 ] || restart_delay=20
                xray_stop; failures=0; restart_at=$(( $(now) + restart_delay ))
                restart_delay=$((restart_delay * 2)); [ "$restart_delay" -le 300 ] || restart_delay=300
                log "xray health restart; next start at uptime=$restart_at"
            fi
        fi
    fi
}
run() {
    exec 9>"$RUN/daemon.lock"
    flock -n 9 || return 0             # 内核锁，校时/进程崩溃不会产生陈旧锁。
    validate || return 1
    remember_pid "$RUN/daemon.pid" "$$"
    trap 'firewall block; xray_stop; rm -f "$RUN/daemon.pid"; exit 0' INT TERM
    previous_mode=''; previous_ip=''; online=0
    next_auth=0; next_dns=0; next_health=0; failures=0; restart_at=0; restart_delay=2
    settle_until=0
    if [ ! -f "$RUN/boot-seen" ]; then
        touch "$RUN/boot-seen"; settle_until=$(( $(now) + BOOT_DELAY ))
    fi
    log "controller started pid=$$"
    while :; do
        if mv "$RUN/event" "$RUN/event.handled" 2>/dev/null; then
            rm -f "$RUN/event.handled"
            next_auth=0; next_health=0
        fi
        step || log 'step failed; retrying on next pass'
        rotate "$RUN/control.log"; rotate "$RUN/xray.log"; rotate "$RUN/daemon.log"
        sleep 2 9>&-
    done
}
start() {
    # 唯一 cron 只负责拉起控制器，所有模式均保留，避免切换后漏装。
    cru a net-stack-v2 "* * * * * $SELF start >/dev/null 2>&1"
    pid_alive "$RUN/daemon.pid" "$SELF run" && return 0
    nohup "$SELF" run </dev/null >> "$RUN/daemon.log" 2>&1 9>&- 8>&- &
}
set_mode() (
    case "$1" in off|auth|tunnel) ;; *) echo 'mode 必须是 off/auth/tunnel' >&2; return 2;; esac
    exec 8>"$RUN/firewall.lock"; flock -x 8 || exit 1
    put "$MODEFILE" "$1"
    touch "$RUN/event"
    firewall_locked block
)
stop_controller() {
    if pid_alive "$RUN/daemon.pid" "$SELF run"; then
        kill "$p" 2>/dev/null
        waited=0
        while pid_alive "$RUN/daemon.pid" "$SELF run"; do
            [ "$waited" -lt 20 ] || { kill -9 "$p" 2>/dev/null; firewall block; xray_stop; break; }
            sleep 1; waited=$((waited + 1))
        done
    fi
}
selftest() {
    token=aa0edd0fff7dd9f1f0ae4e981ec0114c7b0bf6f67c4895bed4f4ac634e97ecf2
    [ "$(sha1 abc)" = a9993e364706816aba3e25717850c26c9cd0d89d ] || return 1
    PASSWORD=pass
    [ "$(hmac 3c6d08d667d0ee0ccad77c55b19d3e4ab2552f7163ec40a9389095a18f86c398)" = fae5d0cfe12af021cb47a53ad9fe0a41 ] || return 1
    [ "$(xencode 1 "$token")" = NmsaR0fCm5H= ] || return 1
    [ "$(xencode agfawegwq12834eqrge "$token")" = DAxHygvRUjlDyJjmvChIzuavMsjy7B9L ] || return 1
    [ "$(xencode agfawegwq12834eqrge 0000000000000000000000000000000000000000000000000000000000000000)" = TOdQ9ggF2y/mskS6Orkg+eUZIok9vqJr ] || return 1
    [ "$(xencode '9$02%8r89)(&22{}we[f]|s' "$token")" = kCG+xmvGAhCV717Y80Fk0o1YJ8SYvBdnUmQoqS== ] || return 1
    [ "$(urlenc '{SRBX1}a+b/c=')" = %7BSRBX1%7Da%2Bb%2Fc%3D ] || return 1
    echo '7 crypto/encoding vectors passed'
}
password() (
    printf '新校园网密码：'; trap 'stty echo 2>/dev/null' EXIT INT TERM
    stty -echo; IFS= read -r secret; stty echo; echo
    [ -n "$secret" ] || return 1
    escaped=$(printf '%s' "$secret" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\$/\\$/g; s/`/\\`/g')
    grep -v '^PASSWORD=' "$CONF" > "$CONF.new"
    printf 'PASSWORD="%s"\n' "$escaped" >> "$CONF.new"
    chmod 600 "$CONF.new"; mv -f "$CONF.new" "$CONF"
    "$SELF" restart
)

# 测试只载入函数，不执行生产入口；测试环境提供独立 RUN/CONF。
[ "${NETSTACK_LIBRARY:-0}" = 1 ] && return 0
case "${1:-status}" in
    run) run;;
    start|boot) start;;
    mode) validate && set_mode "$2" && start;;
    early)
        [ "$(mode)" = tunnel ] || exit 0
        for attempt in 1 2 3 4 5 6 7 8 9 10; do firewall block && exit 0; sleep 1; done
        exit 1;;
    firewall|wan)
        # 乱序事件不是事实；立即保护，下一轮用 WAN 路由及门户状态重新判定。
        touch "$RUN/event"; firewall block;;
    dns) dns_config "$2";;
    login|wake) touch "$RUN/event"; start; echo '已请求检查认证；仍遵守全局登录间隔';;
    restart) stop_controller; start;;
    stop) stop_controller;;
    logout)
        [ "$(mode)" = off ] || { echo '先 mode off，避免自动认证与注销竞争' >&2; exit 1; }
        wan_ready || exit 1
        httpget "$PORTAL/cgi-bin/srun_portal?callback=cb&action=logout&username=$(urlenc "$USERNAME")&ac_id=$AC_ID&ip=$WAN_IP&n=200&type=1";;
    auth-status) wan_ready && auth_status; rc=$?; echo "auth_status=$rc (0=online 1=offline 2=unknown)"; exit "$rc";;
    status)
        echo "mode=$(mode) state=$(cat "$RUN/state" 2>/dev/null) gate=$(cat "$RUN/gate" 2>/dev/null)"
        pid_alive "$RUN/daemon.pid" "$SELF run" && echo "controller=$p" || echo controller=stopped
        pid_alive "$RUN/xray.pid" "$ROOT/bin/xray run -c $RUN/client.json" && echo "xray=$p" || echo xray=stopped
        ip route show table "$TABLE"; ip -6 route show table "$TABLE";;
    check) validate && render_xray && "$ROOT/bin/xray" run -test -c "$RUN/client.json" && selftest;;
    selftest) selftest;;
    password) password;;
    *) echo "usage: $0 {mode off|auth|tunnel|status|auth-status|login|logout|start|stop|restart|check|selftest|password}"; exit 2;;
esac
