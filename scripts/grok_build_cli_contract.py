"""Grok subprocess cases shared by the existing additional-host CLI contract driver."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import uuid

from hook_cli_fixture import register_fixture_lifetime


def run_grok_build_cli_contract(debug, base, tools, check):
    repo = Path(__file__).resolve().parents[1]
    home = base / "grok-build" / "home"
    root = home / ".claudio"
    root.mkdir(parents=True)
    shutil.copytree(repo / "packs/minimal-chime", root / "packs/minimal-chime")
    (root / "config.json").write_text('{"selected_pack":"minimal-chime","master_volume":0,"events":{}}')
    config_root = base / "grok-build" / "configuration"
    config_root.mkdir()
    protected = config_root / "config.toml"
    protected.write_bytes(b'# Preserve Claude compatibility and all user settings\n[compat.claude]\nhooks = true\n')
    third_party = config_root / "hooks/third-party.json"
    third_party.parent.mkdir()
    third_party.write_bytes(b'{"hooks":{"Stop":[]},"future":"retain"}\n')
    for command, body in (
        ("grok", '#!/bin/sh\nprintf "%s\\n" "${CLAUDIO_TEST_GROK_VERSION:-grok 1.0.62 (fixture)}"\n'),
        ("claude", "#!/bin/sh\nprintf '2.1.112 (Claude Code)\\n'\n"),
    ):
        path = tools / command
        path.write_text(body)
        path.chmod(0o700)
    env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ.get("PATH", ""),
               CLAUDIO_TEST_HOME=str(home), CLAUDIO_TEST_ROOT=str(root), GROK_HOME=str(config_root))
    for key in ("GROK_HOOK_EVENT", "GROK_HOOK_NAME", "GROK_SESSION_ID", "GROK_WORKSPACE_ROOT"):
        env.pop(key, None)
    marker = root / "integrations/installations/grok-build.json"
    file = config_root / "hooks/claudio.json"

    def invoke(arguments, data=b"", environment=env):
        result = subprocess.run([str(debug), *arguments], input=data, capture_output=True,
                                env=environment, timeout=12)
        return result

    def connect():
        result = invoke(["integrations", "connect", "grok-build"])
        check(result.returncode == 0, "grok-build: connect: " + result.stdout.decode())
        return json.loads(marker.read_text())["installation_id"]

    def payload(native, request="request-1"):
        prompt_id = "11111111-1111-4111-8111-111111111111" if native == "UserPromptSubmit" else request
        value = dict(hookEventName={"StopFailure": "stop_failure", "Notification": "notification",
                                    "PreToolUse": "pre_tool_use", "UserPromptSubmit": "user_prompt_submit",
                                    "Stop": "stop"}.get(native, "notification"),
                     hook_event_name=native, sessionId="fixture-grok-session",
                     session_id="fixture-grok-session", cwd="/fixture/project", workspaceRoot="/fixture/project",
                     promptId=prompt_id, timestamp="2026-10-21T00:00:00Z", permissionMode="default")
        if native == "StopFailure":
            value.update(error="server_error", errorDetails="PRIVATE_BODY")
        elif native == "PreToolUse":
            value.update(toolName="ask_user_question", toolUseId=request,
                         toolInput={"question": "PRIVATE_BODY"}, toolInputTruncated=False)
        elif native == "UserPromptSubmit":
            value.update(prompt="fixture prompt")
        elif native == "Stop":
            value.update(reason="end_turn", stopHookActive=False, stop_hook_active=False,
                         lastAssistantMessage="OK", last_assistant_message="OK",
                         backgroundTasks=[], sessionCrons=[])
        else:
            value.update(notificationType="permission_prompt", message="PRIVATE_BODY")
        return value

    def runner(native):
        return dict(env, GROK_HOOK_EVENT={"StopFailure": "stop_failure", "PreToolUse": "pre_tool_use",
                                          "UserPromptSubmit": "user_prompt_submit", "Stop": "stop"}.get(native, "notification"),
                    GROK_HOOK_NAME="claudio", GROK_SESSION_ID="fixture-grok-session", GROK_WORKSPACE_ROOT="/fixture/project")

    def hook(native, installation, data=None, environment=None, host="grok-build"):
        data = payload(native) if data is None else data
        if not isinstance(data, bytes):
            data = json.dumps(data).encode()
        result = invoke(["hook", host, native, "--installation-id", installation], data,
                        environment=runner(native) if environment is None else environment)
        check(result.returncode == 0 and not result.stdout and not result.stderr,
              f"{host}/{native}: exit 0 with no stdout/stderr")

    def disk():
        # Fixtures own regular files only; do not follow an accidental link outside this root.
        return {str(path.relative_to(root)): path.read_bytes() for path in root.rglob("*")
                if not path.is_symlink() and path.is_file()}

    installation = connect()
    installed = file.read_bytes()
    check(connect() == installation and file.read_bytes() == installed, "Grok install bytes and identity are idempotent")
    hooks = json.loads(installed)["hooks"]
    check(set(hooks) == {"StopFailure", "Notification", "PreToolUse", "UserPromptSubmit", "Stop"},
          "exactly five native Grok bindings")
    check(hooks["Notification"][0]["matcher"] == "^permission_prompt$"
          and hooks["PreToolUse"][0]["matcher"] == "^(ask_user_question)$"
          and "matcher" not in hooks["Stop"][0] and "matcher" not in hooks["UserPromptSubmit"][0]
          and all(group[0]["hooks"][0]["timeout"] == 2 for group in hooks.values()), "exact matchers and timeout=2")
    before = disk()
    hook("StopFailure", installation)
    check(disk() == before, "without GUI lifetime, no Grok callback effects")
    register_fixture_lifetime(root)
    for native in hooks:
        hook(native, installation)
        receipt = root / "integrations/receipts/grok-build" / (native + ".json")
        check(receipt.is_file(), "current Grok receipt: " + native)
    doctor = invoke(["doctor"]).stdout.decode()
    check("Grok Build 已收到事件；支持 4/5" in doctor,
          "doctor reports real Grok binding receipts separately from capability coverage: " + doctor)
    for native in ("StopFailure", "PreToolUse"):
        hook(native, installation)
        receipt = root / "integrations/receipts/grok-build" / (native + ".json")
        check(json.loads(receipt.read_text())["playback_result"] == "debounced", "Grok identity deduplication: " + native)
    before = disk()
    for data in (b"", b"[]", b"{", b" " * 65_537,
                 dict(payload("StopFailure"), subagentType="explore"),
                 dict(payload("StopFailure"), session_id="other"),
                 dict(payload("StopFailure"), error="permission_cancelled")):
        hook("StopFailure", installation, data=data)
    for native in ("SubagentStop", "StopCancelled", "PermissionDenied", "PostToolUseFailure"):
        hook(native, installation)
    hook("UserPromptSubmit", installation,
         data=dict(payload("UserPromptSubmit"), promptId="task-completed-11111111-1111-4111-8111-111111111111"))
    hook("Stop", installation, data=dict(payload("Stop"), reason="shutdown"))
    hook("Stop", installation, data=dict(payload("Stop"), stopHookActive=True, stop_hook_active=True))
    hook("Notification", installation, data=dict(payload("Notification"), notificationType="idle_prompt"))
    hook("Notification", installation, data=dict(payload("Notification"), permissionMode="bypassPermissions"))
    hook("PreToolUse", installation, environment=env)
    hook("StopFailure", str(uuid.uuid4()))
    hook("PreToolUse", installation, environment=dict(runner("PreToolUse"), GROK_HOME=str(base / "other-grok")))
    check(disk() == before, "invalid, child, idle, missing runner, stale and wrong-root Grok callbacks have zero writes")

    # Both the current Claude command and historical play may be loaded by Grok. Protect the
    # same shared helper without touching the user's compatibility settings or third-party hooks.
    claude = invoke(["integrations", "connect", "claude-code"])
    check(claude.returncode == 0, "isolated Claude compatibility installation")
    claude_id = json.loads((root / "integrations/installations/claude-code.json").read_text())["installation_id"]
    before = disk()
    for environment in (runner("StopFailure"), env):
        hook("StopFailure", claude_id, environment=environment, host="claude-code")
        result = invoke(["play", "stop_failure"], json.dumps(payload("StopFailure")).encode(), environment)
        check(result.returncode == 0 and not result.stdout and not result.stderr, "legacy play stays silent for Grok")
    check(disk() == before, "compatibility callbacks never create Claude state")
    normal = dict(hook_event_name="StopFailure", session_id="claude-session", cwd="/fixture/project")
    hook("StopFailure", claude_id, data=normal, environment=env, host="claude-code")
    check((root / "integrations/receipts/claude-code/StopFailure.json").is_file(), "genuine Claude callback keeps its original behavior")

    # An edited subset is a conflict, not a repair authorization.
    edited = json.loads(installed)
    edited["hooks"].pop("PreToolUse")
    file.write_text(json.dumps(edited))
    retained = file.read_bytes()
    check(invoke(["integrations", "repair", "grok-build"]).returncode != 0 and file.read_bytes() == retained,
          "edited Grok file is never overwritten")
    file.write_bytes(installed)
    env["CLAUDIO_TEST_GROK_VERSION"] = "grok 1.0.63 (fixture)"
    replacement = connect()
    check(replacement != installation, "Grok version change rotates installation")
    check((file.parent.parent / "claudio-hooks.backup.json").read_bytes() == installed,
          "one-shot Grok configuration backup stays outside the scanned hooks directory")
    before = disk()
    hook("PreToolUse", installation, data=payload("PreToolUse", "late"))
    check(disk() == before, "late old installation cannot consume identity")
    check(invoke(["integrations", "disconnect", "grok-build"]).returncode == 0, "Grok disconnect succeeds")
    check(not marker.exists() and not file.exists(), "disconnect revokes and removes only owned Grok file")
    check("Grok Build 已关闭" in invoke(["doctor"]).stdout.decode(), "doctor honors saved Grok OFF")
    before = disk()
    hook("PreToolUse", replacement, data=payload("PreToolUse", "off"))
    check(disk() == before, "OFF rejects late native callbacks")
    check(invoke(["integrations", "disconnect", "grok-build"]).returncode == 0, "repeated Grok disconnect is idempotent")
    check(protected.read_bytes().endswith(b"hooks = true\n") and third_party.read_bytes() == b'{"hooks":{"Stop":[]},"future":"retain"}\n',
          "Claude compatibility and third-party Grok hooks retain original bytes")
    for path, data in disk().items():
        check(b"PRIVATE_BODY" not in data and b"fixture-grok-session" not in data,
              "Grok private payload is never stored: " + path)
