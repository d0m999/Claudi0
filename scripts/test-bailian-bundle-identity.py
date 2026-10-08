#!/usr/bin/env python3
"""Run the real bundle orchestration with fake build tools and controlled source drift."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


REPO = Path(__file__).resolve().parents[1]


def write(path, text, executable=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    if executable:
        path.chmod(0o755)


def run_case(phase):
    with tempfile.TemporaryDirectory(prefix="claudio-bailian-identity-") as directory:
        root = Path(directory)
        for name in ["dev-bundle.sh", "pinned-output-directory.sh", "bailian-acceptance-source.py"]:
            source = REPO / "scripts" / name
            if source.exists():
                destination = root / "scripts" / name
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, destination)
        asset = root / "gui/Sources/ClaudioGUICore/BailianAssetContract.swift"
        write(asset, 'static let hostname = "fixture.example"\nacceptedMediaTypes: ["audio/x-wav"]\n')
        original_asset = asset.read_bytes()
        for path in ["gui/Package.swift", "helper/Package.swift", "helper/Sources/Version/version.c",
                     "gui/Sources/ClaudioLocalization/Resources/Localizable.xcstrings"]:
            write(root / path, "{}\n")
        for path in ["gui/AppResources/en.lproj", "gui/AppResources/zh-Hans.lproj", "packs"]:
            (root / path).mkdir(parents=True)
        for path in ["LICENSE", "PRIVACY.md", "integrations/opencode/claudio.js", "assets/branding/claudi0.icns"]:
            write(root / path, "fixture\n")
        write(root / "scripts/embed-opencode-plugin.py", "pass\n")
        write(root / "scripts/copy-bundled-packs.sh", "#!/bin/bash\nexit 0\n")
        write(root / "scripts/assemble-login-item.sh",
              '#!/bin/bash\nmkdir -p "$2/Contents/Library/LoginItems/claudi0 LoginItem.app/Contents/MacOS"\n'
              'cp "$1" "$2/Contents/Library/LoginItems/claudi0 LoginItem.app/Contents/MacOS/claudi0-login-item"\n')
        write(root / "scripts/check-release-size.sh", "#!/bin/bash\nexit 0\n")
        write(root / "scripts/verify-dev-bundle-signature.sh",
              '#!/bin/bash\nif [[ "$MUTATION_PHASE" == assembly ]]; then python3 "$FIXTURE_ROOT/mutate.py"; fi\n')
        write(root / "mutate.py",
              'import os\nfrom pathlib import Path\n'
              'root = Path(os.environ["FIXTURE_ROOT"])\n'
              'asset = root / "gui/Sources/ClaudioGUICore/BailianAssetContract.swift"\n'
              'phase = os.environ["MUTATION_PHASE"]\n'
              'if phase.endswith("-add"):\n'
              '    (root / "gui/Sources/Added.swift").write_text("struct Added {}\\n")\n'
              'elif phase.endswith("-delete"):\n'
              '    (root / "helper/Sources/Version/version.c").unlink()\n'
              'elif phase.endswith("-restore"):\n'
              '    original = asset.read_text()\n'
              '    asset.write_text(original.replace("audio/x-wav", "audio/wav"))\n'
              '    asset.write_text(original)\n'
              'else:\n'
              '    asset.write_text(asset.read_text().replace("audio/x-wav", "audio/wav"))\n')
        write(root / "tools/swift", '''#!/usr/bin/env python3
import os
from pathlib import Path
import subprocess
import sys
args = sys.argv[1:]
root = Path(os.environ["FIXTURE_ROOT"])
product = args[args.index("--product") + 1]
directory = root / "bin" / ("helper" if product == "claudio" else "gui")
directory.mkdir(parents=True, exist_ok=True)
if "--show-bin-path" in args:
    print(directory)
    sys.exit(0)
(root / "build-order").open("a").write(product + "\\n")
if product == "ClaudioGUI":
    (directory / "test_ClaudioGUI.bundle").mkdir(exist_ok=True)
    (directory / "test_ClaudioLocalization.bundle").mkdir(exist_ok=True)
binary = directory / product
binary.write_text("#!/bin/bash\\nprintf '0.0.0-dev'\\n")
binary.chmod(0o755)
phase = {"ClaudioGUI": "gui", "ClaudioLoginItem": "login", "claudio": "helper"}[product]
if os.environ["MUTATION_PHASE"].split("-")[0] == phase:
    subprocess.run([sys.executable, str(root / "mutate.py")], check=True)
''', executable=True)
        write(root / "tools/strip", "#!/bin/bash\nexit 0\n", executable=True)
        write(root / "tools/codesign",
              '#!/bin/bash\n[[ "${1:-}" != --display ]]\n', executable=True)
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        subprocess.run(["git", "-C", str(root), "add", "."], check=True)
        subprocess.run(["git", "-C", str(root), "-c", "user.name=Fixture", "-c",
                        "user.email=fixture@example.invalid", "commit", "-qm", "fixture"], check=True)
        env = os.environ.copy()
        env.update(PATH=str(root / "tools") + os.pathsep + env["PATH"],
                   FIXTURE_ROOT=str(root), MUTATION_PHASE=phase)
        for variable in ["CLAUDIO_VERSION", "CLAUDIO_BUILD_SDK", "CLAUDIO_PINNED_OUTPUT_DIRECTORY_IDENTITY"]:
            env.pop(variable, None)
        result = subprocess.run(["bash", str(root / "scripts/dev-bundle.sh"), "--bailian-acceptance"],
                                env=env, text=True, capture_output=True)
        app = root / "dist/claudi0.app"
        if phase:
            assert result.returncode != 0, f"{phase}: source drift must reject the bundle"
            assert "source changed" in result.stderr, f"{phase}: must report the source identity failure"
            assert not app.exists(), f"{phase}: rejected app must not remain launchable"
        else:
            assert result.returncode == 0, result.stderr
            identity = json.loads((app / "Contents/Resources/bailian-acceptance-source.json").read_text())
            assert identity["source_files"][str(asset.relative_to(root))] == hashlib.sha256(original_asset).hexdigest()
            assert identity["bailian_asset_policy"]["accepted_media_types"] == ["audio/x-wav"]
            assert identity["distribution_eligible"] is False
            assert "helper/Sources/Version/version.c" in identity["source_files"], "C input must be frozen too"


failures = []
for phase in ["", "gui", "login", "helper", "assembly", "gui-add", "helper-delete", "gui-restore"]:
    try:
        run_case(phase)
        print(f"PASS: {phase or 'stable source'}")
    except AssertionError as error:
        failures.append(str(error))
        print(f"FAIL: {error}")
if failures:
    raise SystemExit(1)
