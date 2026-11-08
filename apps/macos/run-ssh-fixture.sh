#!/bin/bash
set -euo pipefail

# Loopback disposable fixture runner for NativeSSHTransport & NativeSSHHostTrust (Swift/macOS)
# Runs strict host-key verification, unknown key approval, mismatch rejection, interactive PTY, resize, and cleanup.

if [[ "$(/usr/bin/id -u)" == "0" ]]; then
    printf '%s\n' 'Run this fixture as an unprivileged user; sudo is not supported.' >&2
    exit 2
fi

task_tmp_root="${TMPDIR%/}"
if [[ -z "$task_tmp_root" || ! -d "$task_tmp_root" || -L "$task_tmp_root" || ! -O "$task_tmp_root" ]]; then
    task_tmp_root="/tmp"
fi

for tool in ssh-keygen ssh-agent ssh-add nc /usr/sbin/sshd swift; do
    command -v "$tool" >/dev/null || {
        printf 'Missing fixture prerequisite: %s\n' "$tool" >&2
        exit 2
    }
done

script_dir="$(cd "$(dirname "$0")" && pwd)"
fixture_dir="$(mktemp -d "$task_tmp_root/mrw-native-ssh-fixture.XXXXXX")"
sshd_pid=''
agent_pid=''
echo_server_pid=''
askpass_service=''
askpass_account=''

cleanup() {
    if [[ -n "$askpass_service" ]]; then
        cleanup_askpass_canary || true
    fi
    if [[ -n "$echo_server_pid" ]]; then
        kill "$echo_server_pid" >/dev/null 2>&1 || true
        wait "$echo_server_pid" >/dev/null 2>&1 || true
    fi
    if [[ -n "$agent_pid" ]]; then
        kill "$agent_pid" >/dev/null 2>&1 || true
        wait "$agent_pid" >/dev/null 2>&1 || true
    fi
    if [[ -n "$sshd_pid" ]]; then
        kill "$sshd_pid" >/dev/null 2>&1 || true
        wait "$sshd_pid" >/dev/null 2>&1 || true
    fi
    if [[ -d "$fixture_dir" && ! -L "$fixture_dir" && -O "$fixture_dir" ]]; then
        rm -rf -- "$fixture_dir"
    fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

chmod 700 "$fixture_dir"

# Generate host keys: valid server host key, plus an unrelated mismatched key
ssh-keygen -q -t ed25519 -N '' -C mrw-fixture-host -f "$fixture_dir/host_key" >/dev/null 2>&1
ssh-keygen -q -t ed25519 -N '' -C mrw-wrong-host -f "$fixture_dir/wrong_host_key" >/dev/null 2>&1

# Generate client auth key
ssh-keygen -q -t ed25519 -N '' -C mrw-fixture-agent -f "$fixture_dir/agent_key" >/dev/null 2>&1
cp "$fixture_dir/agent_key.pub" "$fixture_dir/authorized_keys"
chmod 600 "$fixture_dir/authorized_keys"

# TC-006: passphrase-protected client key + Keychain canary for askpass auth.
# This passphrase and Keychain item are disposable fixture artifacts owned by
# this run only; they are removed by the cleanup trap. They are not user secrets.
enc_key_passphrase="mrw-fixture-$(python3 -c 'import secrets; print(secrets.token_urlsafe(18))')"
ssh-keygen -q -t ed25519 -N "$enc_key_passphrase" -C mrw-fixture-enc-agent -f "$fixture_dir/enc_agent_key" >/dev/null 2>&1
cat "$fixture_dir/enc_agent_key.pub" >>"$fixture_dir/authorized_keys"

askpass_service="com.macremoteworkspace.tests.credentials"
askpass_account="$(python3 -c 'import uuid; print(str(uuid.uuid4()).lower())')"
/usr/bin/security add-generic-password -s "$askpass_service" -a "$askpass_account" -w "$enc_key_passphrase" -U >/dev/null 2>&1

cleanup_askpass_canary() {
    /usr/bin/security delete-generic-password -s "$askpass_service" -a "$askpass_account" >/dev/null 2>&1 || true
}

# Set up ephemeral ssh-agent
agent_sock="$fixture_dir/agent.sock"
ssh-agent -D -a "$agent_sock" >/dev/null 2>&1 &
agent_pid=$!

for _ in {1..30}; do
    [[ -S "$agent_sock" ]] && break
    sleep 0.05
done
SSH_AUTH_SOCK="$agent_sock" ssh-add "$fixture_dir/agent_key" >/dev/null 2>&1

# Pick random available loopback port
fixture_port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
target_port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
fixture_user="$(/usr/bin/id -un)"

python3 -c '
import socketserver, sys

class EchoHandler(socketserver.BaseRequestHandler):
    def handle(self):
        while True:
            data = self.request.recv(4096)
            if not data:
                return
            self.request.sendall(data)

class EchoServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

EchoServer(("127.0.0.1", int(sys.argv[1])), EchoHandler).serve_forever()
' "$target_port" >/dev/null 2>&1 &
echo_server_pid=$!

cat >"$fixture_dir/sshd_config" <<EOF
Port $fixture_port
ListenAddress 127.0.0.1
HostKey $fixture_dir/host_key
PidFile $fixture_dir/sshd.pid
AuthorizedKeysFile $fixture_dir/authorized_keys
AllowUsers $fixture_user
StrictModes yes
PubkeyAuthentication yes
AuthenticationMethods publickey
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
PermitRootLogin no
PermitTTY yes
AllowTcpForwarding local
X11Forwarding no
Subsystem sftp /usr/libexec/sftp-server
PrintMotd no
UseDNS no
PerSourcePenaltyExemptList 127.0.0.1
LogLevel DEBUG3
EOF
chmod 600 "$fixture_dir/sshd_config"

/usr/sbin/sshd -t -f "$fixture_dir/sshd_config"
/usr/sbin/sshd -D -e -f "$fixture_dir/sshd_config" >"$fixture_dir/sshd.log" 2>&1 &
sshd_pid=$!

ready=0
for _ in {1..50}; do
    if nc -z 127.0.0.1 "$fixture_port" >/dev/null 2>&1; then
        ready=1
        break
    fi
    if ! kill -0 "$sshd_pid" >/dev/null 2>&1; then
        printf '%s\n' 'Loopback sshd exited before becoming ready; fixture stopped.' >&2
        exit 1
    fi
    sleep 0.1
done

if [[ "$ready" != "1" ]]; then
    printf '%s\n' 'Loopback sshd did not become ready.' >&2
    exit 1
fi

echo_ready=0
for _ in {1..50}; do
    if nc -z 127.0.0.1 "$target_port" >/dev/null 2>&1; then
        echo_ready=1
        break
    fi
    if ! kill -0 "$echo_server_pid" >/dev/null 2>&1; then
        printf '%s\n' 'Loopback echo server exited before becoming ready; fixture stopped.' >&2
        exit 1
    fi
    sleep 0.1
done

if [[ "$echo_ready" != "1" ]]; then
    printf '%s\n' 'Loopback echo server did not become ready.' >&2
    exit 1
fi

# Prepare known_hosts files
# 1. Trusted known_hosts: correct host key from server
ssh-keyscan -p "$fixture_port" 127.0.0.1 >"$fixture_dir/known_hosts" 2>/dev/null
# 2. Wrong known_hosts: mismatched host key
wrong_pub="$(cat "$fixture_dir/wrong_host_key.pub")"
wrong_key_type="${wrong_pub%% *}"
wrong_key_b64="$(echo "$wrong_pub" | awk '{print $2}')"
echo "[127.0.0.1]:$fixture_port $wrong_key_type $wrong_key_b64" >"$fixture_dir/wrong_known_hosts"
# 3. Empty known_hosts
touch "$fixture_dir/empty_known_hosts"

echo "Running native SSH transport, SFTP large-transfer, host trust, connection diagnostics, and Keychain askpass suites against disposable loopback fixture..."
MRW_NATIVE_SSH_HOST="127.0.0.1" \
MRW_NATIVE_SSH_PORT="$fixture_port" \
MRW_NATIVE_SSH_USER="$fixture_user" \
MRW_NATIVE_TUNNEL_TARGET_PORT="$target_port" \
MRW_NATIVE_AGENT_SOCK="$agent_sock" \
MRW_NATIVE_FIXTURE_ROOT="$fixture_dir" \
MRW_NATIVE_ENC_KEY="$fixture_dir/enc_agent_key" \
MRW_NATIVE_ASKPASS_ACCOUNT="$askpass_account" \
swift test --package-path "$script_dir" --filter '(NativeSSH(Transport|HostTrust|KeychainAskpass)Tests|ConnectionDiagnosticsTests|NativeSFTPTests|SSHPasswordAuthenticationTests|SFTPLargeTransferTests|SSHPTYParallelSessionTests)'
