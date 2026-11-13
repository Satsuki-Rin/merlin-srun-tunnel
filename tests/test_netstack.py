"""Regression scenarios with isolated state and fake network I/O; never contacts a router."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

PROJECT = Path(__file__).resolve().parents[1]

AUTH = r'''
WAN_IP=192.0.2.10
now() { echo "${TEST_NOW:-1000}"; }
bootstrap() { echo bootstrap >> "$RUN/calls"; }
hmac() { printf '%032d' 0; }
sha1() { printf '%040d' 0; }
xencode() { echo test-encoded; }
sleep() { :; }
httpget() {
    case "$1" in
        *rad_user_info*)
            echo status >> "$RUN/calls"
            case "$(cat "$RUN/portal")" in
                online) echo '{"error":"ok","online_ip":"192.0.2.10"}';;
                offline) echo '{"error":"not_online_error"}';;
                unknown) return 7;;
                mismatch) echo '{"error":"ok","online_ip":"10.0.0.2"}';;
                *) echo '<html>bad gateway</html>';;
            esac;;
        *get_challenge*) echo challenge >> "$RUN/calls"; echo '{"challenge":"abc"}';;
        *action=login*)
            echo login >> "$RUN/calls"
            [ "${LOGIN_SUCCEEDS:-0}" = 0 ] || echo online > "$RUN/portal"
            echo '{"error":"ok"}';;
    esac
}
'''
STEP = AUTH + r'''
previous_mode=tunnel; previous_ip=$WAN_IP; online=0
next_auth=0; next_dns=0; next_health=0; settle_until=0
restart_at=0; restart_delay=2; failures=0
firewall() { echo "firewall $1" >> "$RUN/calls"; put "$RUN/gate" "$1"; }
xray_stop() { echo stop >> "$RUN/calls"; rm -f "$RUN/xray.pid"; }
xray_start() { echo start >> "$RUN/calls"; }
wan_ready() { WAN_IP=192.0.2.10; [ "${WAN_READY:-1}" = 1 ]; }
fix_clock() { [ "${CLOCK_OK:-1}" = 1 ]; }
resolve_endpoint() { echo 203.0.113.10 > "$RUN/endpoint4"; return 0; }
service() { echo service >> "$RUN/calls"; }
pid_alive() { [ "${XRAY_ALIVE:-1}" = 1 ]; }
healthy() { [ "${HEALTH_OK:-1}" = 1 ]; }
'''


class NetStackTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.run = self.root / 'run'
        self.run.mkdir()
        config = (PROJECT / 'net-stack.conf.example').read_text()
        config = config.replace("USERNAME=''", "USERNAME='test-user'")
        config = config.replace("PASSWORD=''", "PASSWORD='test-password'")
        config = config.replace('00000000-0000-0000-0000-000000000000', '11111111-1111-1111-1111-111111111111')
        (self.root / 'net-stack.conf').write_text(config)
        (self.root / 'mode').write_text('tunnel\n')
        (self.root / 'netctl.sh').symlink_to(PROJECT / 'netctl.sh')
        (self.run / 'portal').write_text('offline\n')
        self.env = dict(os.environ, NETSTACK_ROOT=str(self.root), NETSTACK_RUN=str(self.run), NETSTACK_LIBRARY='1')
        self.prefix = f'. "{PROJECT}/netctl.sh"\n'

    def tearDown(self):
        self.tmp.cleanup()

    def shell(self, code, **env):
        return subprocess.run(['sh', '-c', self.prefix + code], env=dict(self.env, **env), capture_output=True, text=True, timeout=15)

    def ok(self, code, **env):
        result = self.shell(code, **env)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        return result.stdout

    def calls(self, name=None):
        path = self.run / 'calls'
        lines = path.read_text().splitlines() if path.exists() else []
        return lines.count(name) if name else lines

    def test_status_online_offline_unknown(self):
        for value, expected in [('online', 0), ('offline', 1), ('unknown', 2), ('mismatch', 2), ('html', 2)]:
            (self.run / 'portal').write_text(value)
            self.assertEqual(self.shell(AUTH + '\nauth_status').returncode, expected, value)

    def test_accepted_login_requires_online_confirmation(self):
        self.assertEqual(self.shell(AUTH + '\nauth_login').returncode, 1)
        self.assertEqual(self.calls('login'), 1)
        self.assertEqual(self.calls('status'), 3)
        self.assertNotIn('confirmed online', (self.run / 'control.log').read_text())

    def test_bootstrap_precedes_challenge_and_success_is_verified(self):
        self.ok(AUTH + '\nauth_login', LOGIN_SUCCEEDS='1')
        self.assertEqual(self.calls()[:4], ['bootstrap', 'challenge', 'login', 'status'])
        self.assertIn('confirmed online', (self.run / 'control.log').read_text())

    def test_global_login_interval_survives_new_process(self):
        self.shell(AUTH + '\nauth_login')
        self.assertEqual(self.shell(AUTH + '\nauth_login', TEST_NOW='1020').returncode, 3)
        self.assertEqual(self.calls('login'), 1)
        self.shell(AUTH + '\nauth_login', TEST_NOW='1060')
        self.assertEqual(self.calls('login'), 2)

    def test_unknown_status_never_authenticates(self):
        (self.run / 'portal').write_text('unknown')
        self.ok(STEP + '\nstep')
        self.assertEqual(self.calls('login'), 0)
        self.assertEqual((self.run / 'state').read_text().strip(), 'auth-unknown')

    def test_wan_readiness_recovers_without_another_event(self):
        self.ok(STEP + '\nWAN_READY=0; step\nWAN_READY=1; LOGIN_SUCCEEDS=1; step')
        self.assertEqual(self.calls('login'), 1)
        self.assertEqual((self.run / 'state').read_text().strip(), 'tunnel-online')

    def test_boot_delay_then_authentication_without_marker(self):
        self.ok(STEP + '\nsettle_until=1020; step\nTEST_NOW=1020; LOGIN_SUCCEEDS=1; step')
        self.assertEqual(self.calls('login'), 1)

    def test_clock_failure_retries_later(self):
        self.ok(STEP + '\nCLOCK_OK=0; step\nCLOCK_OK=1; TEST_NOW=1030; LOGIN_SUCCEEDS=1; step')
        self.assertEqual(self.calls('login'), 1)

    def test_event_burst_cannot_bypass_login_interval(self):
        self.ok(STEP + '\nfor i in 1 2 3 4 5; do next_auth=0; step; done')
        self.assertEqual(self.calls('login'), 1)

    def test_false_down_event_does_not_latch_authentication_pause(self):
        (self.run / 'portal').write_text('online')
        self.ok(STEP + '\nfirewall block; next_auth=0; next_health=0; step')
        self.assertEqual((self.run / 'gate').read_text().strip(), 'allow')
        self.assertEqual(self.calls('login'), 0)

    def test_unhealthy_live_process_is_restarted(self):
        (self.run / 'portal').write_text('online')
        self.ok(STEP + '\nHEALTH_OK=0; step\nTEST_NOW=1015; step')
        self.assertEqual(self.calls('stop'), 1)
        self.assertEqual((self.run / 'gate').read_text().strip(), 'block')

    def test_dns_failure_preserves_working_cached_tunnel(self):
        (self.run / 'portal').write_text('online')
        self.ok(STEP + '\necho 203.0.113.10 > "$RUN/endpoint4"\nresolve_endpoint() { return 1; }\nstep')
        self.assertEqual((self.run / 'gate').read_text().strip(), 'allow')
        self.assertEqual(self.calls('stop'), 0)

    def test_no_endpoint_cache_means_no_xray_start(self):
        (self.run / 'portal').write_text('online')
        self.ok(STEP + '\nresolve_endpoint() { return 1; }\nstep')
        self.assertEqual(self.calls('start'), 0)
        self.assertEqual((self.run / 'state').read_text().strip(), 'waiting-endpoint')

    def test_same_cron_is_installed_in_all_modes(self):
        self.ok(r'''
cru() { echo "$*" >> "$RUN/cron"; }
pid_alive() { return 0; }
firewall_locked() { echo "$(mode)" >> "$RUN/policies"; }
for m in auth tunnel off tunnel; do set_mode "$m"; start; done
''')
        self.assertEqual((self.run / 'cron').read_text().count('a net-stack-v2 '), 4)
        self.assertEqual((self.run / 'policies').read_text().splitlines(), ['auth', 'tunnel', 'off', 'tunnel'])

    def test_single_daemon_even_if_wall_clock_jumps(self):
        body = self.prefix + r'''
validate() { :; }
log() { :; }
step() { echo entered >> "$RUN/entered"; sleep 0.6; exit 0; }
run
'''
        a = subprocess.Popen(['sh', '-c', body], env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        deadline = time.monotonic() + 3
        while not (self.run / 'entered').exists() and time.monotonic() < deadline:
            time.sleep(.01)
        b = subprocess.run(['sh', '-c', body], env=self.env, capture_output=True, timeout=3)
        a.communicate(timeout=3)
        self.assertEqual(b.returncode, 0)
        self.assertEqual((self.run / 'entered').read_text().splitlines(), ['entered'])

    def test_busybox_dns_address_numbers_are_not_ipv6(self):
        self.ok(r'''
timeout() { printf 'Server: 192.0.2.53\nAddress 1: 192.0.2.53\nName: home.example.com\nAddress 1: 203.0.113.10\nAddress 2: 2001:db8::10\n'; }
firewall_locked() { :; }
resolve_endpoint; [ "$?" = 10 ]
''')
        self.assertEqual((self.run / 'endpoint4').read_text().strip(), '203.0.113.10')
        self.assertEqual((self.run / 'endpoint6').read_text().strip(), '2001:db8::10')

    def test_resolver_merges_both_upstreams(self):
        self.ok(r'''
timeout() {
    echo 'Name: home.example.com'
    case "$5" in 119.*) echo 'Address 1: 203.0.113.10';; *) echo 'Address 1: 203.0.113.11';; esac
}
firewall_locked() { :; }
resolve_endpoint; [ "$?" = 10 ]
''')
        self.assertEqual((self.run / 'endpoint4').read_text().splitlines(), ['203.0.113.10','203.0.113.11'])

    def test_owned_child_is_alive_before_exec_finishes(self):
        self.ok(r'''
sleep 5 &
child=$!
remember_pid "$RUN/xray.pid" "$child"
pid_alive "$RUN/xray.pid" "$ROOT/bin/xray run -c $RUN/client.json"
result=$?
kill "$child"; wait "$child" 2>/dev/null
exit "$result"
''')

    def test_wrong_process_start_time_is_not_alive(self):
        (self.run / 'pid').write_text(f'{os.getpid()} 1\n')
        self.assertEqual(self.shell('pid_alive "$RUN/pid" python').returncode, 1)

    def render(self, family=4, gate='block', extra=''):
        return self.ok('iptables() { :; }; ip6tables() { :; }\n' + extra + f'\nfilter_rules {family} {gate}')

    def test_filter_replacement_stays_in_one_transaction(self):
        text = self.render()
        self.assertTrue(text.startswith('*filter\n'))
        self.assertTrue(text.endswith('COMMIT\n'))
        self.assertIn('-A NS2_OUT -j DROP\n-I FORWARD', text)
        self.assertIn('-I OUTPUT 1 -j NS2_OUT', text)
        self.assertNotIn('-F OUTPUT', text)
        self.assertNotIn('-F FORWARD', text)

    def test_block_vs_allow_only_permits_lan_to_tun(self):
        blocked = self.render()
        allowed = self.render(gate='allow')
        self.assertNotIn('-i br0 -o xray0 -j ACCEPT', blocked)
        self.assertIn('-i br0 -j DROP', blocked)
        self.assertIn('-i br0 -o xray0 -j ACCEPT', allowed)
        self.assertIn('-i br0 -j DROP', allowed)
        self.assertNotIn('-i br0 -o eth0 -j ACCEPT', allowed)

    def test_bootstrap_rule_survives_rebuild_and_expires(self):
        (self.run / 'bootstrap').write_text('203.0.113.10 1010\n')
        for _ in range(2):
            self.assertIn('-d 203.0.113.10 -p tcp --dport 80 -j ACCEPT', self.render(extra='now() { echo 1000; }'))
        self.assertNotIn('-d 203.0.113.10 -p tcp --dport 80 -j ACCEPT', self.render(extra='now() { echo 1011; }'))

    def test_ipv6_keeps_ndp_and_dhcp_but_blocks_general_egress(self):
        rules = self.render(6)
        for typ in [1, 2, 3, 4, 133, 135, 136]:
            self.assertIn(f'--icmpv6-type {typ} -j ACCEPT', rules)
        self.assertIn('--sport 546 --dport 547 -j ACCEPT', rules)
        self.assertIn('-A NS2_OUT -j DROP', rules)
        self.assertNotIn('-p tcp --dport 80 -j ACCEPT', rules)

    def test_stale_allow_cannot_override_off_or_pending_event(self):
        for name in ['iptables-restore', 'ip6tables-restore']:
            script = self.root / name
            script.write_text('#!/bin/sh\ncat >/dev/null\n')
            script.chmod(0o700)
        self.env['PATH'] = str(self.root) + os.pathsep + self.env['PATH']
        self.ok(r'''
filter_rules() { echo "gate=$2" >> "$RUN/rendered"; }
nat_rules() { :; }
routes() { :; }
iptables_restore() { cat >/dev/null; }
echo off > "$MODEFILE"; firewall allow
echo tunnel > "$MODEFILE"; touch "$RUN/event"; firewall allow
'''.replace('iptables_restore() { cat >/dev/null; }\n', ''))
        self.assertEqual((self.run / 'rendered').read_text().splitlines(), ['gate=off', 'gate=off', 'gate=block', 'gate=block'])

    def test_dns_rewrites_all_upstreams_and_uses_configured_ula(self):
        config = self.run / 'dns.conf'
        config.write_text('interface=br0\nservers-file=/tmp/resolv.dnsmasq\nresolv-file=/tmp/resolv.conf\nserver=8.8.8.8\nno-resolv\n')
        self.ok('LAN6_CIDR=fd77:88::/64; LAN6_ADDR=fd77:88::1/64; dns_config "$RUN/dns.conf"; dns_config "$RUN/dns.conf"')
        value = config.read_text()
        self.assertNotIn('servers-file', value)
        self.assertNotIn('resolv-file', value)
        self.assertNotIn('8.8.8.8', value)
        self.assertEqual(value.count('server=127.0.0.1#15353'), 1)
        self.assertIn('dhcp-range=fd77:88::,ra-only,64,12h', value)
        self.assertIn('dhcp-option=option6:dns-server,[fd77:88::1]', value)

    def test_generated_json_uses_shared_configuration(self):
        self.ok('validate && render_xray')
        config = json.loads((self.run / 'client.json').read_text())
        self.assertEqual(config['outbounds'][0]['settings']['vnext'][0]['address'], 'home.example.com')
        self.assertEqual(config['inbounds'][0]['settings']['inet6_address'], 'fd00:19::1/126')
        self.assertEqual(config['inbounds'][2]['settings']['address'], '192.168.5.1')
        self.assertNotIn('dns', config)

    def test_unsafe_config_and_too_fast_login_are_rejected(self):
        for override in ['LAN_IF="br0;reboot"', 'TABLE=200', 'LOGIN_INTERVAL=10', 'HTTP_TIMEOUT=0']:
            self.assertNotEqual(self.shell(override + '\nvalidate').returncode, 0)


if __name__ == '__main__':
    unittest.main(verbosity=2)
