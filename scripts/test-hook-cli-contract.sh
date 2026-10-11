#!/usr/bin/env bash
# 真实 CLI 子进程契约：受支持的宿主 hook 无论结果如何，都必须 exit 0 且零输出。
set -euo pipefail

cd "$(dirname "$0")/.."

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/claudio-hook-contract.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

DEBUG_BIN="${CLAUDIO_CONTRACT_DEBUG_BIN:-}"
if [[ -z "$DEBUG_BIN" ]]; then
  swift build --package-path helper --product claudio >/dev/null
  DEBUG_BIN_DIR="$(swift build --package-path helper --product claudio --show-bin-path)"
  DEBUG_BIN="$DEBUG_BIN_DIR/claudio"
fi

RELEASE_BIN="${CLAUDIO_CONTRACT_RELEASE_BIN:-}"
if [[ -z "$RELEASE_BIN" ]]; then
  swift build -c release --package-path helper --product claudio >/dev/null
  RELEASE_BIN_DIR="$(swift build -c release --package-path helper --product claudio --show-bin-path)"
  RELEASE_BIN="$RELEASE_BIN_DIR/claudio"
fi

if ! LC_ALL=C strings "$DEBUG_BIN" | grep -F "CLAUDIO_TEST_ROOT" >/dev/null; then
  echo "FAIL: Debug helper 未包含 CLAUDIO_TEST_ROOT 测试入口" >&2
  exit 1
fi
if LC_ALL=C strings "$RELEASE_BIN" | grep -F "CLAUDIO_TEST_ROOT" >/dev/null; then
  echo "FAIL: Release helper 不得包含 CLAUDIO_TEST_ROOT" >&2
  exit 1
fi

CONTRACT_TOOLS="$TEST_ROOT/tools"
mkdir -p "$CONTRACT_TOOLS"
for tool in claude codex; do
  printf '#!/bin/sh\nprintf "contract-version\\n"\n' > "$CONTRACT_TOOLS/$tool"
  chmod 700 "$CONTRACT_TOOLS/$tool"
done
export PATH="$CONTRACT_TOOLS:$PATH"
CLAUDIO_CONTRACT_VERSION="$("$DEBUG_BIN" --version)"

INSTALLATION_ID="11111111-2222-4333-8444-555555555555"
STALE_ID="aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

prepare_root() {
  local root="$1"
  local host="$2"
  local mode="$3"

  mkdir -p "$root/integrations/installations"
  cat > "$root/integrations/installations/$host.json" <<JSON
{
  "schema": 2,
  "host": "$host",
  "installation_id": "$INSTALLATION_ID",
  "scope_fingerprint": "test-hook-cli-contract:$host"
}
JSON

  case "$mode" in
    ready|muted)
      mkdir -p "$root/packs"
      cp -R packs/minimal-chime "$root/packs/minimal-chime"
      if [[ "$mode" == "muted" ]]; then
        cat > "$root/config.json" <<'JSON'
{"selected_pack":"minimal-chime","master_volume":0,"events":{"task_start":false}}
JSON
      else
        cat > "$root/config.json" <<'JSON'
{"selected_pack":"minimal-chime","master_volume":0,"events":{}}
JSON
      fi
      ;;
    not-ready)
      cat > "$root/config.json" <<'JSON'
{"selected_pack":"missing-pack","master_volume":0,"events":{}}
JSON
      ;;
    *)
      echo "FAIL: unknown fixture mode $mode" >&2
      exit 1
      ;;
  esac
  python3 - "$root" "$host" "$$" "$CLAUDIO_CONTRACT_VERSION" <<'PYFIXTURE'
import sys, json
from pathlib import Path
sys.path.insert(0, "scripts")
from hook_cli_fixture import register_fixture_lifetime
root, host, pid, helper_version = Path(sys.argv[1]), sys.argv[2], int(sys.argv[3]), sys.argv[4]
register_fixture_lifetime(root, pid)
config = json.loads((root / "config.json").read_text())
config["host_integrations"] = {"policy_version": 1, "surfaces": {
    host: {"enabled": True, "revision": "22222222-2222-4222-8222-222222222222"}}}
(root / "config.json").write_text(json.dumps(config))
if host in ("claude-code", "codex"):
    bindings = [f"{host}:UserPromptSubmit:task_start:none:v1", f"{host}:Stop:stop:none:v1",
                f"{host}:SubagentStop:subagent_stop:none:v1"]
    if host == "claude-code":
        bindings += [f"{host}:StopFailure:stop_failure:none:v1", f"{host}:Notification:notification:none:v1",
                     f"{host}:PreToolUse:notification:question_intent_only:v1"]
    else:
        bindings += [f"{host}:PermissionRequest:notification:permission_request_only:v1"]
    marker = root / "integrations/installations" / (host + ".json")
    value = json.loads(marker.read_text())
    version = "contract-version" if host == "claude-code" else "cli=contract-version"
    value["scope_fingerprint"] = f"surface={host};host={version};claudio={helper_version};bindings=" + ",".join(sorted(bindings))
    marker.write_text(json.dumps(value))
PYFIXTURE
}

run_silent_hook() {
  local label="$1"
  local root="$2"
  shift 2
  local stdout_file="$TEST_ROOT/$label.stdout"
  local stderr_file="$TEST_ROOT/$label.stderr"
  local status

  set +e
  CLAUDIO_TEST_ROOT="$root" "$DEBUG_BIN" hook "$@" >"$stdout_file" 2>"$stderr_file"
  status=$?
  set -e

  if [[ $status -ne 0 ]]; then
    echo "FAIL: $label exit=$status" >&2
    exit 1
  fi
  if [[ -s "$stdout_file" ]]; then
    echo "FAIL: $label stdout 非零字节" >&2
    exit 1
  fi
  if [[ -s "$stderr_file" ]]; then
    echo "FAIL: $label stderr 非零字节" >&2
    exit 1
  fi
}

fixture_digest() {
  python3 - "$1" <<'PYDIGEST'
import hashlib, sys
from pathlib import Path
root = Path(sys.argv[1])
digest = hashlib.sha256()
for file in sorted(root.rglob('*')):
    if file.is_file():
        digest.update(str(file.relative_to(root)).encode())
        digest.update(file.read_bytes())
print(digest.hexdigest())
PYDIGEST
}

receipt_result() {
  /usr/bin/plutil -extract playback_result raw -o - "$1"
}

READY_ROOT="$TEST_ROOT/ready"
prepare_root "$READY_ROOT" claude-code ready
run_silent_hook played "$READY_ROOT" \
  claude-code UserPromptSubmit --installation-id "$INSTALLATION_ID"
READY_RECEIPT="$READY_ROOT/integrations/receipts/claude-code/UserPromptSubmit.json"
if [[ "$(receipt_result "$READY_RECEIPT")" != "played" ]]; then
  echo "FAIL: 首次 UserPromptSubmit 未写 played 回执" >&2
  exit 1
fi
run_silent_hook debounced "$READY_ROOT" \
  claude-code UserPromptSubmit --installation-id "$INSTALLATION_ID"
if [[ "$(receipt_result "$READY_RECEIPT")" != "debounced" ]]; then
  echo "FAIL: 250ms 内重复 UserPromptSubmit 未写 debounced 回执" >&2
  exit 1
fi

MUTED_ROOT="$TEST_ROOT/muted"
prepare_root "$MUTED_ROOT" codex muted
run_silent_hook muted "$MUTED_ROOT" \
  codex UserPromptSubmit --installation-id "$INSTALLATION_ID"
MUTED_RECEIPT="$MUTED_ROOT/integrations/receipts/codex/UserPromptSubmit.json"
if [[ "$(receipt_result "$MUTED_RECEIPT")" != "muted" ]]; then
  echo "FAIL: 任务开始单事件静音未写 muted 回执" >&2
  exit 1
fi

MISSING_ROOT="$TEST_ROOT/not-ready"
prepare_root "$MISSING_ROOT" claude-code not-ready
run_silent_hook not-ready "$MISSING_ROOT" \
  claude-code UserPromptSubmit --installation-id "$INSTALLATION_ID"
MISSING_RECEIPT="$MISSING_ROOT/integrations/receipts/claude-code/UserPromptSubmit.json"
if [[ "$(receipt_result "$MISSING_RECEIPT")" != "not_ready" ]]; then
  echo "FAIL: 缺少 task_start 映射时未写 not_ready 回执" >&2
  exit 1
fi

PLAYBACK_FAILED_ROOT="$TEST_ROOT/playback-failed"
prepare_root "$PLAYBACK_FAILED_ROOT" claude-code ready
# 让宿主播放锁路径成为目录，稳定触发真实文件系统 lock failure；回执目录仍可写，
# 因而这条能同时证明 playback_failed 结果和零输出 CLI 契约。
mkdir -p "$PLAYBACK_FAILED_ROOT/integrations/claude-code-play.lock"
run_silent_hook playback-failed "$PLAYBACK_FAILED_ROOT" \
  claude-code UserPromptSubmit --installation-id "$INSTALLATION_ID"
PLAYBACK_FAILED_RECEIPT="$PLAYBACK_FAILED_ROOT/integrations/receipts/claude-code/UserPromptSubmit.json"
if [[ "$(receipt_result "$PLAYBACK_FAILED_RECEIPT")" != "playback_failed" ]]; then
  echo "FAIL: 播放锁文件系统失败未写 playback_failed 回执" >&2
  exit 1
fi

BEFORE_REJECT="$(fixture_digest "$MUTED_ROOT")"
run_silent_hook unsupported "$MUTED_ROOT" \
  codex StopFailure --installation-id "$INSTALLATION_ID"
[[ "$(fixture_digest "$MUTED_ROOT")" == "$BEFORE_REJECT" ]] || { echo "FAIL: unsupported event mutated fixture" >&2; exit 1; }
BEFORE_REJECT="$(fixture_digest "$MISSING_ROOT")"
run_silent_hook stale-installation "$MISSING_ROOT" \
  claude-code UserPromptSubmit --installation-id "$STALE_ID"

[[ "$(fixture_digest "$MISSING_ROOT")" == "$BEFORE_REJECT" ]] || { echo "FAIL: stale installation mutated fixture" >&2; exit 1; }

# Authorized fixture must also lose eligibility when its source is OFF or GUI identity disappears.
for rejection in off gui-exited; do
  REJECT_ROOT="$TEST_ROOT/$rejection"
  prepare_root "$REJECT_ROOT" claude-code ready
  if [[ "$rejection" == "off" ]]; then
    jq '.host_integrations.surfaces["claude-code"].enabled = false' "$REJECT_ROOT/config.json" > "$REJECT_ROOT/config.next"
    mv "$REJECT_ROOT/config.next" "$REJECT_ROOT/config.json"
  else
    rm "$REJECT_ROOT/gui-run.json"
  fi
  BEFORE_REJECT="$(fixture_digest "$REJECT_ROOT")"
  run_silent_hook "$rejection" "$REJECT_ROOT" claude-code UserPromptSubmit --installation-id "$INSTALLATION_ID"
  [[ "$(fixture_digest "$REJECT_ROOT")" == "$BEFORE_REJECT" ]] || { echo "FAIL: rejected event mutated fixture" >&2; exit 1; }
  if [[ -e "$REJECT_ROOT/integrations/receipts" || -e "$REJECT_ROOT/integrations/receipt-history" ]]; then
    echo "FAIL: rejected fixture published a receipt" >&2
    exit 1
  fi
done

# Fixture-only verification does not inspect an installed WorkBuddy application.
if [[ "${CLAUDIO_CONTRACT_FIXTURE_ONLY:-0}" != 1 ]]; then
WORKBUDDY_ROOT="$TEST_ROOT/workbuddy"
prepare_root "$WORKBUDDY_ROOT" workbuddy muted
# Scope 来自生产只读 collector；没有 Desktop 的机器仍验证旧 scope 零输出拒绝，
# 正向 subtype/播放由可注入的 executable harness 覆盖。
WORKBUDDY_SCOPE="$(CLAUDIO_TEST_ROOT="$WORKBUDDY_ROOT" "$DEBUG_BIN" acceptance workbuddy-preflight --json | jq -r '.scope.fingerprint // empty')"
jq '.events = {"subagent_stop":false,"notification":false}' "$WORKBUDDY_ROOT/config.json" > "$WORKBUDDY_ROOT/config.next"
mv "$WORKBUDDY_ROOT/config.next" "$WORKBUDDY_ROOT/config.json"
WORKBUDDY_RECEIPT="$WORKBUDDY_ROOT/integrations/receipts/workbuddy/SubagentStop.json"
printf '%s' '{"hook_event_name":"SubagentStop"}' | run_silent_hook workbuddy-stale-scope \
  "$WORKBUDDY_ROOT" workbuddy SubagentStop --installation-id "$INSTALLATION_ID"
if [[ -e "$WORKBUDDY_RECEIPT" ]]; then
  echo "FAIL: WorkBuddy 旧 scope 不得写回执" >&2
  exit 1
fi
if [[ -n "$WORKBUDDY_SCOPE" ]]; then
  jq --arg scope "$WORKBUDDY_SCOPE" '.scope_fingerprint = $scope' \
    "$WORKBUDDY_ROOT/integrations/installations/workbuddy.json" > "$WORKBUDDY_ROOT/current.json"
  mv "$WORKBUDDY_ROOT/current.json" "$WORKBUDDY_ROOT/integrations/installations/workbuddy.json"
  printf '%s' '{"hook_event_name":"Stop"}' | run_silent_hook workbuddy-wrong-event \
    "$WORKBUDDY_ROOT" workbuddy SubagentStop --installation-id "$INSTALLATION_ID"
  if [[ -e "$WORKBUDDY_RECEIPT" ]]; then
    echo "FAIL: WorkBuddy 错位 stdin 不得写 SubagentStop 回执" >&2
    exit 1
  fi

  NOTIFICATION_RECEIPT="$WORKBUDDY_ROOT/integrations/receipts/workbuddy/Notification.json"
  for payload in \
    '{}' \
    '{"hook_event_name":"Stop","notification_type":"idle_prompt"}' \
    '{"hook_event_name":"Notification","notification_type":"auth_success"}' \
    '{"hook_event_name":"Notification","notification_type":null}' \
    '{"hook_event_name":"Notification","hook_event_name":"Notification","notification_type":"idle_prompt"}' \
    '{"hook_event_name":"Notification","notification_type":"idle_prompt","notification_type":"idle_prompt"}' \
    '{broken'; do
    printf '%s' "$payload" | run_silent_hook workbuddy-invalid-notification \
      "$WORKBUDDY_ROOT" workbuddy Notification --installation-id "$INSTALLATION_ID"
    if [[ -e "$NOTIFICATION_RECEIPT" ]]; then
      echo "FAIL: WorkBuddy 非法 Notification 不得产生回执" >&2
      exit 1
    fi
  done
  for subtype in permission_prompt idle_prompt; do
    printf '{"hook_event_name":"Notification","notification_type":"%s"}' "$subtype" | \
      run_silent_hook "workbuddy-$subtype" "$WORKBUDDY_ROOT" workbuddy Notification --installation-id "$INSTALLATION_ID"
    if [[ "$(receipt_result "$NOTIFICATION_RECEIPT")" != "muted" ]]; then
      echo "FAIL: WorkBuddy $subtype 未形成当前 muted 回执" >&2
      exit 1
    fi
  done
  printf '%s' '{"hook_event_name":"SubagentStop"}' | run_silent_hook workbuddy-subagent \
    "$WORKBUDDY_ROOT" workbuddy SubagentStop --installation-id "$INSTALLATION_ID"
  if [[ "$(receipt_result "$WORKBUDDY_RECEIPT")" != "muted" ]]; then
    echo "FAIL: WorkBuddy 有效 stdin 未形成 SubagentStop muted 回执" >&2
    exit 1
  fi

else
  echo "SKIP: WorkBuddy Desktop absent; valid-subtype receipt covered by injectable harness"
fi

# Question-intent entry contracts use only isolated machine state and a deterministic version
# executable. This is CLI evidence, never a Claude Code callback or human audibility claim.
fi

QUESTION_ROOT="$TEST_ROOT/question"
QUESTION_TOOLS="$TEST_ROOT/question-tools"
prepare_root "$QUESTION_ROOT" claude-code muted
mkdir -p "$QUESTION_TOOLS"
cat > "$QUESTION_TOOLS/claude" <<'SH'
#!/bin/sh
printf '%s\n' 'question-contract-version'
SH
chmod 700 "$QUESTION_TOOLS/claude"
CLAUDIO_CONTRACT_VERSION="$("$DEBUG_BIN" --version)"
QUESTION_BINDINGS="$(jq -nr '[
  "claude-code:UserPromptSubmit:task_start:none:v1",
  "claude-code:Stop:stop:none:v1",
  "claude-code:StopFailure:stop_failure:none:v1",
  "claude-code:Notification:notification:none:v1",
  "claude-code:PreToolUse:notification:question_intent_only:v1",
  "claude-code:SubagentStop:subagent_stop:none:v1"
] | sort | join(",")')"
QUESTION_SCOPE="surface=claude-code;host=question-contract-version;claudio=$CLAUDIO_CONTRACT_VERSION;bindings=$QUESTION_BINDINGS"
jq --arg scope "$QUESTION_SCOPE" '.scope_fingerprint = $scope' \
  "$QUESTION_ROOT/integrations/installations/claude-code.json" > "$QUESTION_ROOT/current.json"
mv "$QUESTION_ROOT/current.json" "$QUESTION_ROOT/integrations/installations/claude-code.json"
jq '.events = {"notification":false}' "$QUESTION_ROOT/config.json" > "$QUESTION_ROOT/config.next"
mv "$QUESTION_ROOT/config.next" "$QUESTION_ROOT/config.json"
QUESTION_RECEIPT="$QUESTION_ROOT/integrations/receipts/claude-code/PreToolUse.json"
for payload in \
  '{}' \
  '{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestionExtra","session_id":"s","tool_use_id":"r","tool_input":{}}' \
  '{"hook_event_name":"PreToolUse","tool_name":"askuserquestion","session_id":"s","tool_use_id":"r","tool_input":{}}' \
  '{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","session_id":"s","tool_input":{}}' \
  '{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","session_id":"s","tool_use_id":"r","tool_input":null}' \
  '{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","session_id":"s","session_id":"s","tool_use_id":"r","tool_input":{}}' \
  '{"hook_event_name":"Stop","tool_name":"AskUserQuestion","session_id":"s","tool_use_id":"r","tool_input":{}}' \
  '{broken'; do
  printf '%s' "$payload" | PATH="$QUESTION_TOOLS:$PATH" run_silent_hook question-invalid \
    "$QUESTION_ROOT" claude-code PreToolUse --installation-id "$INSTALLATION_ID"
  if [[ -e "$QUESTION_RECEIPT" || -e "$QUESTION_ROOT/integrations/claude-code-questions/consumed.json" ]]; then
    echo "FAIL: invalid question must have no receipt or consumption side effects" >&2
    exit 1
  fi
done
QUESTION_PAYLOAD='{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","session_id":"s","tool_use_id":"r","tool_input":{}}'
printf '%s' "$QUESTION_PAYLOAD" | PATH="$QUESTION_TOOLS:$PATH" run_silent_hook question-stale \
  "$QUESTION_ROOT" claude-code PreToolUse --installation-id "$STALE_ID"
if [[ -e "$QUESTION_RECEIPT" ]]; then
  echo "FAIL: stale question installation must not write a receipt" >&2
  exit 1
fi
for expected in muted debounced; do
  printf '%s' "$QUESTION_PAYLOAD" | PATH="$QUESTION_TOOLS:$PATH" run_silent_hook "question-$expected" \
    "$QUESTION_ROOT" claude-code PreToolUse --installation-id "$INSTALLATION_ID"
  if [[ "$(receipt_result "$QUESTION_RECEIPT")" != "$expected" ]]; then
    echo "FAIL: question expected $expected receipt" >&2
    exit 1
  fi
done

if [[ "${CLAUDIO_CONTRACT_FIXTURE_ONLY:-0}" == 1 ]]; then
  echo "PASS: isolated Claude/Codex Debug CLI fixtures; Release strings checked; WorkBuddy inspection skipped"
else
  echo "PASS: claudi0 hook 真实子进程 exit/stdout/stderr、提问入口与 Debug-only root 契约"
fi
