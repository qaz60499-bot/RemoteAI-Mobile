"""Disposable simulator only: safe negative executor oracle, fixed normal + TSan.

The old nested-type isolation boundary is restored only in this CI checkout.
An executor assertion stops the negative case before shared-array mutation.
This does not claim to reproduce the historic allocator abort.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/web-tab-race'
OUT.mkdir(parents=True, exist_ok=True)
SOURCE = ROOT / 'RemoteAIMobileTests/WebTabTests.swift'
fixed = SOURCE.read_bytes()
newline = b'\r\n' if b'\r\n' in fixed else b'\n'
needle = b'    @MainActor' + newline + b'    private final class TabTransport: Transport {'
assert fixed.count(needle) == 1
udid = subprocess.check_output(['xcrun', 'simctl', 'create', 'RemoteAI-WebTab-Race',
    'com.apple.CoreSimulator.SimDeviceType.iPhone-13-Pro',
    'com.apple.CoreSimulator.SimRuntime.iOS-18-5'], text=True, timeout=45).strip()
report = {'commit': os.environ['GITHUB_SHA'], 'fixedSourceSHA256': hashlib.sha256(fixed).hexdigest(),
          'scope': 'test-double executor regression; historic allocator crash attribution remains separate', 'stages': []}

def save():
    (OUT / 'summary.json').write_text(json.dumps(report, indent=2))

def test(label, selector, sanitizer=False):
    result_path = OUT / (label + '.xcresult')
    command = ['xcodebuild', 'test', '-project', 'RemoteAIMobile.xcodeproj', '-scheme', 'RemoteAIMobile',
        '-configuration', 'Debug', '-destination', 'platform=iOS Simulator,id=' + udid,
        '-parallel-testing-enabled', 'NO', '-resultBundlePath', str(result_path), '-only-testing:' + selector]
    if sanitizer:
        command += ['-enableThreadSanitizer', 'YES']
    with (OUT / (label + '.log')).open('w') as log:
        result = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, timeout=600)
    text = (OUT / (label + '.log')).read_text(errors='replace')
    stage = {'label': label, 'exitCode': result.returncode,
             'executorAssertion': 'TAB_TRANSPORT_EXECUTOR' in text,
             'threadSanitizerWarning': 'WARNING: ThreadSanitizer' in text}
    report['stages'].append(stage)
    save()
    if result_path.exists():
        summary = subprocess.run(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(result_path), '--format', 'json'],
                                 capture_output=True, text=True, timeout=45)
        (OUT / (label + '-summary.json')).write_text(summary.stdout or summary.stderr)
    print(json.dumps(stage), flush=True)
    return stage, text

try:
    # Preserve every other byte; only remove the pre-existing fix for the oracle.
    SOURCE.write_bytes(fixed.replace(needle, b'    private final class TabTransport: Transport {'))
    negative, _ = test('old-boundary-negative', 'RemoteAIMobileTests/WebTabTests/testTransportConcurrentCallsAndCancellationStayOnMainActor')
    assert negative['exitCode'] != 0 and negative['executorAssertion'], negative
finally:
    SOURCE.write_bytes(fixed)
    assert hashlib.sha256(SOURCE.read_bytes()).hexdigest() == report['fixedSourceSHA256']

for label, sanitizer in [('normal-fixed', False), ('tsan-fixed', True)]:
    stage, log = test(label, 'RemoteAIMobileTests/WebTabTests', sanitizer)
    assert stage['exitCode'] == 0 and not stage['executorAssertion'] and not stage['threadSanitizerWarning'], stage
    assert "Test Suite 'WebTabTests' passed" in log and '** TEST SUCCEEDED **' in log
    assert 'Restarting after unexpected exit' not in log
report['result'] = 'negative oracle + fixed normal + fixed TSan passed'
save()
print(json.dumps(report), flush=True)
