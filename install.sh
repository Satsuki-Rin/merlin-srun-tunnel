#!/bin/sh
# 在路由器运行：先验证、再备份、封锁、替换；失败时保留备份和保护。
set -e
umask 077
SRC=$(CDPATH= cd "$(dirname "$0")" && pwd)
DEST=/jffs/scripts/net-stack
BACK=/jffs/net-stack-backup-$(date '+%Y%m%d-%H%M%S')-$$
STAGE=/jffs/scripts/.net-stack-next-$$
HOOKS='init-start services-start wan-event firewall-start dnsmasq.postconf'
[ "$(nvram get jffs2_scripts)" = 1 ] || { echo '请先启用 JFFS 自定义脚本'; exit 1; }
[ -f "$SRC/net-stack.conf" ] && [ -x "$SRC/bin/xray" ] || { echo '缺少 net-stack.conf 或 bin/xray'; exit 1; }
mkdir -p "$STAGE/bin"
cp "$SRC/netctl.sh" "$SRC/xencode.awk" "$SRC/net-stack.conf" "$SRC/README.md" "$SRC/LICENSE" "$STAGE/"
[ ! -d "$SRC/docs" ] || cp -R "$SRC/docs" "$STAGE/"
cp "$SRC/bin/xray" "$STAGE/bin/xray"
chmod 700 "$STAGE"; chmod 755 "$STAGE/netctl.sh" "$STAGE/bin/xray"; chmod 600 "$STAGE/net-stack.conf"
. "$SRC/net-stack.conf"
OLD_WAN=$WAN_IF
OLD_LAN=$LAN_IF
if [ -f "$DEST/settings.conf" ]; then
    OLD_WAN=$( . "$DEST/settings.conf"; echo "$WAN_IF")
    OLD_LAN=$( . "$DEST/settings.conf"; echo "$LAN_IF")
fi
initial=$(cat "$DEST/mode" 2>/dev/null || echo tunnel)
case "$initial" in off|auth|tunnel) ;; *) initial=tunnel;; esac
printf '%s\n' "$initial" > "$STAGE/mode"
if [ "$(cat /proc/sys/vm/overcommit_memory)" = 2 ]; then
    [ "$(cat /proc/sys/vm/overcommit_ratio)" -ge 400 ] || echo 400 > /proc/sys/vm/overcommit_ratio
fi
NETSTACK_RUN=/tmp/net-stack-validate-$$ "$STAGE/netctl.sh" check
rm -rf /tmp/net-stack-validate-$$
mkdir -p "$BACK/hooks"
for name in $HOOKS; do
    [ ! -f "/jffs/scripts/$name" ] || cp -p "/jffs/scripts/$name" "$BACK/hooks/$name"
done
cru l > "$BACK/cron.txt"
# CTF 会让已加速连接绕过软件转发规则；保存原值，禁用后必须重启生效。
nvram get ctf_disable > "$BACK/ctf_disable"
nvram get ctf_disable_force > "$BACK/ctf_disable_force"
# 回滚脚本与旧程序保存在 JFFS；重启后仍可使用。
cat > "$BACK/rollback.sh" <<'ROLLBACK'
#!/bin/sh
set -e
B=$(CDPATH= cd "$(dirname "$0")" && pwd)
D=/jffs/scripts/net-stack
[ -d "$B/previous" ] || { echo '这是全新安装的备份；没有上一版本'; exit 1; }
cru d net-stack-v2 2>/dev/null || :
for key in ctf_disable ctf_disable_force; do
    [ ! -f "$B/$key" ] || nvram set "$key=$(cat "$B/$key")"
done
nvram commit
"$D/netctl.sh" stop || :
mv "$D" "$B/replaced-v2-$(date +%s)"
mv "$B/previous" "$D"
for name in init-start services-start wan-event firewall-start dnsmasq.postconf; do
    if [ -f "$B/hooks/$name" ]; then cp -p "$B/hooks/$name" "/jffs/scripts/$name"; else rm -f "/jffs/scripts/$name"; fi
done
if ! grep -q '^# Net Stack 2' "$D/netctl.sh"; then
    rm -rf /tmp/net-stack-control.lock
fi
"$D/netctl.sh" early
if ! grep -q '^# Net Stack 2' "$D/netctl.sh"; then
for tool in iptables ip6tables; do
    while "$tool" -D FORWARD -j NS2_FWD 2>/dev/null; do :; done
    while "$tool" -D OUTPUT -j NS2_OUT 2>/dev/null; do :; done
    "$tool" -F NS2_FWD 2>/dev/null || :; "$tool" -X NS2_FWD 2>/dev/null || :
    "$tool" -F NS2_OUT 2>/dev/null || :; "$tool" -X NS2_OUT 2>/dev/null || :
done
while iptables -t nat -D PREROUTING -j NS2_DNS 2>/dev/null; do :; done
iptables -t nat -F NS2_DNS 2>/dev/null || :; iptables -t nat -X NS2_DNS 2>/dev/null || :
rm -rf /tmp/net-stack
fi
service restart_dnsmasq
"$D/netctl.sh" boot >/tmp/net-stack-rollback.log 2>&1 &
echo '已恢复上一版本；查看 /tmp/net-stack-rollback.log'
ROLLBACK
chmod 700 "$BACK/rollback.sh"
echo "备份与回滚：$BACK/rollback.sh"
trap 'echo "安装中断；备份位置：$BACK。保护规则可能仍在，请检查后回滚。" >&2' EXIT

# 先安装新保护，再停止旧进程。新链名称独立于旧版。
"$STAGE/netctl.sh" early
for job in net-stack-wd srun-watch xray-wd net-stack-v2; do cru d "$job" 2>/dev/null || :; done
# 按进程命令行精确匹配；不使用 killall，也不误伤 SSH/其他代理。
for proc in /proc/[0-9]*/cmdline; do
    cmd=$(tr '\000' ' ' < "$proc" 2>/dev/null || :)
    case "$cmd" in
        "/bin/sh $DEST/netctl.sh "*|"/bin/sh $DEST/srun.sh "*|"/bin/sh $DEST/xray-super.sh "*)
            pid=${proc#/proc/}; pid=${pid%/cmdline}; kill "$pid" 2>/dev/null || :;;
    esac
done
[ ! -x "$DEST/srun.sh" ] || "$DEST/srun.sh" stop >/dev/null 2>&1 || :
[ ! -x "$DEST/xray-super.sh" ] || "$DEST/xray-super.sh" stop >/dev/null 2>&1 || :
[ ! -f /tmp/net-stack/daemon.pid ] || "$DEST/netctl.sh" stop || :
sleep 2
# 老控制器的 TERM trap 不一定退出；最后只清除仍匹配旧控制入口的进程。
for proc in /proc/[0-9]*/cmdline; do
    cmd=$(tr '\000' ' ' < "$proc" 2>/dev/null || :)
    case "$cmd" in "/bin/sh $DEST/netctl.sh "*) pid=${proc#/proc/}; pid=${pid%/cmdline}; kill -9 "$pid" 2>/dev/null || :;; esac
done
[ ! -d "$DEST" ] || mv "$DEST" "$BACK/previous"
mv "$STAGE" "$DEST"

# 保留其他插件的 hook；清掉已知历史标记块，再追加一次新入口。
hook() {
    path=/jffs/scripts/$1; action=$2
    if [ "$1" = dnsmasq.postconf ] && grep -q 'ROOT=/jffs/scripts/net-stack' "$path" 2>/dev/null; then
        printf '#!/bin/sh\n' > "$path"  # 旧版整份文件属于本项目，原件已备份。
    fi
    [ -f "$path" ] || printf '#!/bin/sh\n' > "$path"
    awk '
      /# >>> (net-stack|net-stack-project|net-stack-v2|srun-auto-auth|xray-tunnel)/ {skip=1; next}
      /# <<< (net-stack|net-stack-project|net-stack-v2|srun-auto-auth|xray-tunnel)/ {skip=0; next}
      !skip {print}
    ' "$path" > "$path.new"
    printf '\n# >>> net-stack-v2 >>>\n%s\n# <<< net-stack-v2 <<<\n' "$DEST/netctl.sh $action" >> "$path.new"
    chmod 755 "$path.new"; mv -f "$path.new" "$path"
}
hook init-start 'early >>/tmp/net-stack-hooks.log 2>&1'
hook services-start 'boot >>/tmp/net-stack-hooks.log 2>&1'
hook wan-event 'wan "$@" >>/tmp/net-stack-hooks.log 2>&1'
hook firewall-start 'firewall >>/tmp/net-stack-hooks.log 2>&1'
hook dnsmasq.postconf 'dns "$@"'

# 新保护已接管后才移除旧链；不删除备份或无关插件规则。
for tool in iptables ip6tables; do
    for chain in NETSTACK_FWD NETSTACK_FWD6 NETSTACK_TRANS NETSTACK_TRANS6; do
        while "$tool" -D FORWARD -j "$chain" 2>/dev/null; do :; done
        "$tool" -F "$chain" 2>/dev/null || :; "$tool" -X "$chain" 2>/dev/null || :
    done
    for chain in NETSTACK_OUT NETSTACK_OUT6; do
        while "$tool" -D OUTPUT -o "$OLD_WAN" -j "$chain" 2>/dev/null; do :; done
        "$tool" -F "$chain" 2>/dev/null || :; "$tool" -X "$chain" 2>/dev/null || :
    done
done
. "$DEST/net-stack.conf"
for proto in udp tcp; do
    while iptables -t nat -D PREROUTING -i "$OLD_LAN" -p "$proto" --dport 53 -j REDIRECT --to-ports 53 2>/dev/null; do :; done
done
# 清理旧表内容一次；之后先检查再 add，拒绝后备路由不会被周期 flush。
ip route flush table "$TABLE"; ip -6 route flush table "$TABLE"
"$DEST/netctl.sh" early
service restart_dnsmasq
"$DEST/netctl.sh" boot
nvram set ctf_disable=1
nvram set ctf_disable_force=1
nvram commit
trap - EXIT
echo "安装完成；请重启以禁用 CTF，确保转发规则不被硬件加速绕过。状态：$DEST/netctl.sh status；回滚：$BACK/rollback.sh"
