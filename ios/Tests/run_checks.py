#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
# SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

"""Compile standalone checks against production sources; never build or launch Tincall."""
import argparse
import json
from pathlib import Path
import platform
import plistlib
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "ios/Tincall"
MODELS = ["Core/CallModels.swift"]
LOGS = MODELS + [f"Core/{name}.swift" for name in (
    "ModelMessage", "RequestLogModels", "RequestLogStore", "RequestLogSpan", "RequestLogText")]
MODEL = LOGS + [f"Core/{name}.swift" for name in (
    "CredentialStore", "DataSharingConsent", "ChatCompletionClient", "ModelRequestCodec", "ModelResponseCodec", "CallContextBuilder")]
MODEL += ["Voice/OriginalAudioEncoder.swift", "Voice/PCM16Wave.swift"]
EXTERNAL = MODEL + [f"Core/{name}.swift" for name in (
    "CallAccessStore", "DataSharingConsent", "ExternalCallClient", "MCPSummaryUploads")]
COORDINATOR = EXTERNAL + [f"Core/{name}.swift" for name in (
    "CallSummaryTasks", "CallCoordinator", "CallCoordinator+External", "CallCoordinator+Incoming",
    "CallCoordinator+Records", "CallCoordinator+Configuration", "CallCoordinator+Voice", "CallCoordinator+Turns")]
RECORDS = MODELS + ["Storage/CallRecordStore.swift"]
CONFIG = MODELS + ["Core/CredentialStore.swift", "Core/SystemCallContact.swift", "Core/SystemCallIntentHandler.swift",
                   "Core/SystemContactReader.swift", "Storage/LocalConfigurationStore.swift"]
CLOUD = EXTERNAL + ["Storage/CloudSyncModels.swift", "Storage/CloudSyncClient.swift"]
SPEECH = LOGS + [f"Voice/{name}.swift" for name in (
    "SpeechHTTP", "SpeechPlayback", "SpeechPlaybackState", "SpeechSynthesisConfiguration",
    "SpeechSegmenter", "FishAudioStream", "MiniMaxAudioStream", "PCM16Wave")]

# Every top-level Swift check must be registered. Missing registrations fail before execution.
CHECKS = {
    "ActivityPushRecoveryChecks": EXTERNAL,
    "AutomaticCloudSyncChecks": ["Storage/AutomaticCloudSyncController.swift"],
    "AutomaticCloudSyncStoreChecks": RECORDS + ["Storage/CloudSyncModels.swift", "Storage/CloudSyncStore.swift", "Storage/CloudRecordTransfer.swift"],
    "BackendConnectionChecks": COORDINATOR,
    "BackupImportChecks": CONFIG + ["Storage/CallRecordStore.swift", "Storage/GlobalBackup.swift"],
    "CallAccessStoreChecks": MODELS + ["Core/CallAccessStore.swift"],
    "CallActivityPayloadChecks": ["Features/Call/CallActivityAttributes.swift"],
    "CallAudioControlChecks": COORDINATOR + ["Storage/CallRecordStore.swift"],
    "CallAudioRoutingChecks": MODELS + ["Voice/CallAudioRouting.swift"],
    "CallSummaryTasksChecks": COORDINATOR,
    "CloudSTTLifecycleChecks": MODELS + [f"Voice/{name}.swift" for name in ("SpeechRecognizer", "XunfeiSpeechRecognizer", "XunfeiTranscript", "BailianSpeechRecognizer", "BailianTranscript")],
    "CloudSyncPaginationChecks": CLOUD,
    "CloudServiceVersionChecks": EXTERNAL + ["Core/SupabaseDeploymentService.swift", "Core/SupabaseManagementClient.swift", "Core/CloudServiceVersionCheck.swift"],
    "ConfigurationSettingsChecks": CONFIG,
    "CredentialMetadataChecks": MODELS + ["Core/CredentialStore.swift"],
    "DataSharingConsentChecks": EXTERNAL,
    "ExternalContactDirectoryChecks": EXTERNAL,
    "IncomingForegroundChecks": MODELS + ["Core/IncomingCallController.swift", "Core/SystemCallContact.swift", "Core/SystemCallIntentHandler.swift", "Core/CallAccessStore.swift", "Core/DataSharingConsent.swift"],
    "MCPOpeningChecks": COORDINATOR,
    "MCPRoleBindingChecks": EXTERNAL,
    "MCPSummaryUploadChecks": EXTERNAL,
    "MessageImageChecks": CLOUD + ["Storage/CallRecordStore.swift"],
    "ModelHangUpChecks": COORDINATOR,
    "ModelProtocolChecks": MODEL,
    "OriginalAudioEncodingChecks": MODELS + ["Voice/PCM16Wave.swift", "Voice/OriginalAudioEncoder.swift"],
    "OriginalAudioInputChecks": COORDINATOR + CONFIG,
    "RecordStoreChecks": RECORDS,
    "RequestLogChecks": LOGS + ["Core/ModelRequestCodec.swift"],
    "RequestLogNoiseChecks": CLOUD,
    "RequestLogResponsivenessChecks": LOGS,
    "RoleMCPSetupChecks": EXTERNAL + CONFIG + ["Features/Settings/RoleMCPSetup.swift"],
    "ScheduleClientChecks": EXTERNAL + ["Core/CallScheduleClient.swift"],
    "ShortcutMessageChecks": COORDINATOR + CONFIG + ["Core/TincallShortcutMessages.swift", "Storage/CallRecordStore.swift"],
    "SpeechEmptyInputChecks": SPEECH,
    "SpeechPlaybackChecks": MODELS + ["Voice/SpeechSegmenter.swift", "Voice/SpeechPlaybackState.swift"],
    "SpeechStitchingChecks": SPEECH,
    "SupabaseDeploymentChecks": EXTERNAL + ["Core/SupabaseDeploymentService.swift", "Core/SupabaseManagementClient.swift"],
    "SystemCallContactChecks": CONFIG + ["Core/SystemCallIntentHandler.swift"],
    "VoiceProtocolChecks": MODELS + [f"Voice/{name}.swift" for name in ("WhisperTranscription", "PCM16Wave", "FishAudioStream", "SpeechSegmenter")],
}
SKIPPED = {}
MACOS = {"SpeechPlaybackChecks", "CloudSTTLifecycleChecks", "CallAccessStoreChecks", "RequestLogResponsivenessChecks"}
PARTIAL = {"SpeechPlaybackChecks", "CallAccessStoreChecks", "SystemCallContactChecks", "SupabaseDeploymentChecks"}
VARIANTS = {
    "MCPOpeningChecks": ["--unanswered-inputs-only", "--time-awareness-only", "--mcp-reentrant-failure-only",
        "--stt-switch-only", "--mcp-queue-only", "--missed-call", "--mcp-message-only", "--mcp-end-only",
        "--connection-timing-only", "--redial-recovery-only", "--network-recovery-only"],
    "IncomingForegroundChecks": ["--caller-handle", "--connection-removal", "--bindings", "--foreground-handoff",
        "--activity-after-answer", "--missed-call", "--ring-recovery", "--answer", "--outgoing", "--consent", "--failure-guidance"],
    "MCPSummaryUploadChecks": ["--verify-restart"],
    "SpeechEmptyInputChecks": ["--redirects-only"],
}


def run(command, log, timeout=180, env=None):
    log.write("$ " + " ".join(map(str, command)) + "\n")
    log.flush()
    subprocess.run(list(map(str, command)), cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                   check=True, timeout=timeout, env=env)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checks", nargs="*", help="Check names, without .swift; default: all")
    parser.add_argument("--output", type=Path, help="Logs and build directory; default: a new temporary directory")
    parser.add_argument("--list", action="store_true")
    args = parser.parse_args()
    actual = {p.stem for p in (ROOT / "ios/Tests").glob("*.swift")}
    if actual != CHECKS.keys():
        parser.error(f"Unregistered checks: {sorted(actual - CHECKS.keys())}; missing files: {sorted(CHECKS.keys() - actual)}")
    selected = args.checks or sorted(CHECKS)
    if set(selected) - CHECKS.keys():
        parser.error(f"Unknown checks: {sorted(set(selected) - CHECKS.keys())}")
    if args.list:
        for name in selected:
            host = "macOS" if name in MACOS else "iOS simulator"
            print(f"{name}: {SKIPPED.get(name, host + (' (partial coverage)' if name in PARTIAL else ''))}")
        return
    out = (args.output or Path(tempfile.mkdtemp(prefix="tincall-checks-"))).resolve()
    out.mkdir(parents=True, exist_ok=True)
    print(f"Check output: {out}", flush=True)
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
    architecture = "arm64" if platform.machine() == "arm64" else "x86_64"
    triple = f"{architecture}-apple-ios26.0-simulator"
    device = None
    results = []
    try:
        if any(name not in MACOS and name not in SKIPPED for name in selected):
            inventory = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "-j"], text=True))
            runtimes = [r for r in inventory["runtimes"] if r["isAvailable"] and r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-") and int(r["version"].split(".")[0]) >= 26]
            runtime = max(runtimes, key=lambda r: tuple(map(int, r["version"].split("."))))
            device_type = next(d["identifier"] for d in runtime["supportedDeviceTypes"] if d["name"].startswith("iPhone "))
            device = subprocess.check_output(["xcrun", "simctl", "create", "Tincall isolated checks", device_type, runtime["identifier"]], text=True).strip()
            with (out / "setup.log").open("w") as log:
                run(["xcrun", "simctl", "boot", device], log)
                # A fresh CI simulator may spend several minutes migrating system data.
                run(["xcrun", "simctl", "bootstatus", device, "-b"], log, timeout=600)
                if any("Voice/OriginalAudioEncoder.swift" in CHECKS[name] for name in selected):
                    run(["xcrun", "swift", "build", "--build-system", "native", "--package-path", ROOT / "ios/LocalPackages/LAME", "--scratch-path", out / "lame", "--sdk", sdk, "--triple", triple], log)
        libraries = out / "lame/debug"
        for name in selected:
            if name in SKIPPED:
                print(f"SKIP {name}: {SKIPPED[name]}", flush=True)
                results.append({"check": name, "status": "skipped", "reason": SKIPPED[name]})
                continue
            log_path = out / f"{name}.log"
            try:
                with log_path.open("w") as log:
                    sources = list(dict.fromkeys(APP / path for path in CHECKS[name]))
                    binary = out / name
                    optimization = "-O" if name == "RequestLogResponsivenessChecks" else "-Onone"
                    command = ["xcrun"] + ([] if name in MACOS else ["--sdk", "iphonesimulator"]) + ["swiftc", "-swift-version", "6", "-parse-as-library", "-whole-module-optimization", optimization]
                    if name not in MACOS:
                        entitlement = out / f"{name}.plist"
                        entitlement.write_bytes(plistlib.dumps({"application-identifier": f"TincallChecks.{name}"}))
                        command += ["-sdk", sdk, "-target", triple, "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__entitlements", "-Xlinker", str(entitlement)]
                    if "Voice/OriginalAudioEncoder.swift" in CHECKS[name]:
                        command += ["-L", str(libraries), "-lLAME", "-Xcc", "-I" + str(ROOT / "ios/LocalPackages/LAME/Sources/include"), "-Xcc", "-fmodule-map-file=" + str(libraries / "LAME.build/module.modulemap"), "-Xlinker", "-rpath", "-Xlinker", str(libraries)]
                    if name == "CallAccessStoreChecks":
                        sources.append(ROOT / "ios/Tests/CI/CallAccessMain.swift")
                        developer = Path(subprocess.check_output(["xcode-select", "-p"], text=True).strip())
                        storekit = developer / "Platforms/MacOSX.platform/Developer/Library/Frameworks"
                        command += ["-F", str(storekit), "-Xlinker", "-rpath", "-Xlinker", str(storekit)]
                    run(command + sources + [ROOT / f"ios/Tests/{name}.swift", "-o", binary], log)
                    run(["codesign", "--force", "--sign", "-", binary], log)
                    arguments = []
                    if name in {"SupabaseDeploymentChecks", "CloudServiceVersionChecks"}:
                        arguments = [str(ROOT)]
                    if name == "SupabaseDeploymentChecks":
                        arguments.append(str(out / "sql-transactions"))
                    if name == "CallActivityPayloadChecks":
                        payload = out / "activity-payload.json"
                        script = "import {activityStartPayload} from './connector/live-activity-push.mjs'; console.log(JSON.stringify(activityStartPayload('11111111-1111-4111-8111-111111111111',1800000000,'11111111-1111-4111-8111-111111111111','Synthetic caller')));"
                        payload.write_bytes(subprocess.check_output(["node", "--input-type=module", "-e", script], cwd=ROOT))
                        arguments = [str(payload)]
                    execution = [binary] if name in MACOS else ["xcrun", "simctl", "spawn", device, binary]
                    for variant in [None] + VARIANTS.get(name, []):
                        run(execution + arguments + ([variant] if variant else []), log, timeout=120)
                status = "partial" if name in PARTIAL else "passed"
                results.append({"check": name, "status": status})
                print(f"{status.upper()} {name}", flush=True)
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
                results.append({"check": name, "status": "failed", "error": str(error)})
                print(f"FAIL {name}: {log_path}", flush=True)
            (out / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    finally:
        (out / "results.json").write_text(json.dumps(results, indent=2) + "\n")
        if device:
            subprocess.run(["xcrun", "simctl", "shutdown", device], capture_output=True)
            subprocess.run(["xcrun", "simctl", "delete", device], capture_output=True)
    print(json.dumps({status: sum(item["status"] == status for item in results) for status in ("passed", "partial", "failed", "skipped")}))
    return int(any(item["status"] == "failed" for item in results))


if __name__ == "__main__":
    sys.exit(main())
