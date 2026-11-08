#!/bin/bash
set -euo pipefail

# Disposable two-hop loopback fixture for native ProxyJump host-trust ordering.
if [[ "$(/usr/bin/id -u)" == "0" ]]; then
  printf '%s\n' 'Run this fixture as an unprivileged user; sudo is not supported.' >&2
  exit 2
fi

for tool in ssh-keygen ssh-keyscan ssh-agent ssh-add nc swift python3; do
  command -v "$tool" >/dev/null || {
    printf 'Missing fixture prerequisite: %s\n' "$tool" >&2
    exit 2
  }
done
[[ -x /usr/sbin/sshd ]] || {
  printf '%s\n' 'Missing fixture prerequisite: /usr/sbin/sshd' >&2
  exit 2
}

task_tmp_root="${TMPDIR%/}"
if [[ -z "$task_tmp_root" || ! -d "$task_tmp_root" || -L "$task_tmp_root" || ! -O "$task_tmp_root" ]]; then
  task_tmp_root="/tmp"
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
fixture_dir="$(mktemp -d "$task_tmp_root/mrw-native-proxyjump-fixture.XXXXXX")"
chmod 700 "$fixture_dir"
jump_sshd_pid=''
target_sshd_pid=''
agent_pid=''

cleanup() {
  for pid in "$agent_pid" "$target_sshd_pid" "$jump_sshd_pid"; do
    if [[ -n "$pid" ]]; then
      kill "$pid" >/dev/null 2>&1 || true
      wait "$pid" >/dev/null 2>&1 || true
    fi
  done
  if [[ -d "$fixture_dir" && ! -L "$fixture_dir" && -O "$fixture_dir" ]]; then
    rm -rf -- "$fixture_dir"
  fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

fixture_user="$(/usr/bin/id -un)"
ssh-keygen -q -t ed25519 -N '' -C mrw-proxyjump-jump -f "$fixture_dir/jump_host_key" >/dev/null 2>&1
ssh-keygen -q -t ed25519 -N '' -C mrw-proxyjump-target -f "$fixture_dir/target_host_key" >/dev/null 2>&1
ssh-keygen -q -t ed25519 -N '' -C mrw-proxyjump-wrong -f "$fixture_dir/wrong_host_key" >/dev/null 2>&1
ssh-keygen -q -t ed25519 -N '' -C mrw-proxyjump-agent -f "$fixture_dir/agent_key" >/dev/null 2>&1
cp "$fixture_dir/agent_key.pub" "$fixture_dir/authorized_keys"
chmod 600 "$fixture_dir/authorized_keys"

jump_port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
target_port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"

write_sshd_config() {
  local name="$1"
  local port="$2"
  cat >"$fixture_dir/${name}_sshd_config" <<EOF
Port $port
ListenAddress 127.0.0.1
HostKey $fixture_dir/${name}_host_key
PidFile $fixture_dir/${name}.pid
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
AllowTcpForwarding yes
X11Forwarding no
PrintMotd no
UseDNS no
PerSourcePenaltyExemptList 127.0.0.1
LogLevel DEBUG3
EOF
  chmod 600 "$fixture_dir/${name}_sshd_config"
  /usr/sbin/sshd -t -f "$fixture_dir/${name}_sshd_config"
  /usr/sbin/sshd -D -e -f "$fixture_dir/${name}_sshd_config" >"$fixture_dir/${name}.log" 2>&1 &
  if [[ "$name" == 'jump' ]]; then jump_sshd_pid=$!; else target_sshd_pid=$!; fi
}

write_sshd_config jump "$jump_port"
write_sshd_config target "$target_port"

ready=0
for _ in {1..60}; do
  if nc -z 127.0.0.1 "$jump_port" >/dev/null 2>&1 && nc -z 127.0.0.1 "$target_port" >/dev/null 2>&1; then
    ready=1
    break
  fi
  if ! kill -0 "$jump_sshd_pid" >/dev/null 2>&1 || ! kill -0 "$target_sshd_pid" >/dev/null 2>&1; then
    printf '%s\n' 'A loopback sshd exited before becoming ready.' >&2
    exit 1
  fi
  sleep 0.1
done
if [[ "$ready" != '1' ]]; then
  printf '%s\n' 'The loopback sshd fixtures did not become ready.' >&2
  exit 1
fi

ssh-keyscan -t ed25519 -p "$jump_port" 127.0.0.1 >"$fixture_dir/jump_known_line" 2>/dev/null
ssh-keyscan -t ed25519 -p "$target_port" 127.0.0.1 >"$fixture_dir/target_known_line" 2>/dev/null
cat "$fixture_dir/jump_known_line" "$fixture_dir/target_known_line" >"$fixture_dir/known_hosts"
cp "$fixture_dir/jump_known_line" "$fixture_dir/jump_only_known_hosts"
touch "$fixture_dir/empty_known_hosts"

wrong_pub="$(cat "$fixture_dir/wrong_host_key.pub")"
wrong_type="$(awk '{print $1}' <<<"$wrong_pub")"
wrong_base64="$(awk '{print $2}' <<<"$wrong_pub")"
printf '[127.0.0.1]:%s %s %s\n' "$target_port" "$wrong_type" "$wrong_base64" >"$fixture_dir/wrong_target_known_hosts"
cat "$fixture_dir/jump_known_line" "$fixture_dir/wrong_target_known_hosts" >"$fixture_dir/wrong_target_combined"
mv "$fixture_dir/wrong_target_combined" "$fixture_dir/wrong_target_known_hosts"
printf '[127.0.0.1]:%s %s %s\n' "$jump_port" "$wrong_type" "$wrong_base64" >"$fixture_dir/wrong_jump_known_hosts"
cat "$fixture_dir/wrong_jump_known_hosts" "$fixture_dir/target_known_line" >"$fixture_dir/wrong_jump_combined"
mv "$fixture_dir/wrong_jump_combined" "$fixture_dir/wrong_jump_known_hosts"
chmod 600 "$fixture_dir"/*known_hosts

agent_socket="$fixture_dir/agent.sock"
ssh-agent -D -a "$agent_socket" >/dev/null 2>&1 &
agent_pid=$!
for _ in {1..40}; do
  [[ -S "$agent_socket" ]] && break
  sleep 0.05
done
if [[ ! -S "$agent_socket" ]]; then
  printf '%s\n' 'The disposable ssh-agent did not become ready.' >&2
  exit 1
fi
SSH_AUTH_SOCK="$agent_socket" ssh-add "$fixture_dir/agent_key" >/dev/null 2>&1

printf '%s\n' 'Running native ProxyJump trust and session tests against two disposable loopback sshd servers...'
MRW_PROXYJUMP_FIXTURE_ROOT="$fixture_dir" \
MRW_PROXYJUMP_JUMP_PORT="$jump_port" \
MRW_PROXYJUMP_TARGET_PORT="$target_port" \
MRW_PROXYJUMP_USER="$fixture_user" \
MRW_PROXYJUMP_AGENT_SOCK="$agent_socket" \
swift test --package-path "$script_dir" --filter NativeSSHProxyJumpTests
