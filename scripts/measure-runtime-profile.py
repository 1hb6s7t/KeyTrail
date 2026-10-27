#!/usr/bin/env python3
"""Bounded macOS release-binary profile using only an isolated synthetic demo DB.

The dashboard close uses the normal UI: close this new fixture dashboard's
window when progress.json says awaiting-dashboard-close. With --shutdown-mode ui,
quit its menu agent when progress.json says awaiting-agent-menu-quit. No existing process,
Application Support profile, Keychain service, or authorized bundle is modified.
--lifecycle-only skips resource sampling and identifies its new fixture as
KeyTrail Lifecycle Dashboard / Agent for manual-user UI actions.
"""
import argparse
import datetime as dt
import ctypes
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import socket
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('process_measure', ROOT / 'scripts/measure-process.py')
measure = importlib.util.module_from_spec(spec)
spec.loader.exec_module(measure)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def manifests(paths):
    return {str(path.relative_to(ROOT)): digest(path) for path in sorted(paths) if path.is_file()}


def protected_manifest():
    bundles = [ROOT / 'artifacts' / name for name in ('KeyTrail-Cat-validation.app', 'KeyTrail-Dashboard-fixed.app', 'KeyTrail-Float-validation.app') if (ROOT / 'artifacts' / name).exists()]
    for bundle in bundles:
        if not (bundle / 'Contents/Info.plist').is_file():
            raise RuntimeError('missing protected app bundle: ' + bundle.name)
    return manifests(path for bundle in bundles for path in bundle.rglob('*'))


def children(pid):
    result = subprocess.run(['pgrep', '-P', str(pid)], capture_output=True, text=True)
    if result.returncode not in (0, 1) or result.stderr.strip():
        raise RuntimeError('child discovery failed: ' + result.stderr.strip())
    return [int(value) for value in result.stdout.split()]


def rpc(directory, request):
    with socket.socket(socket.AF_UNIX) as client:
        client.settimeout(3)
        client.connect(str(directory / 'engine.sock'))
        client.sendall(json.dumps(request).encode() + b'\n')
        data = b''
        while b'\n' not in data:
            chunk = client.recv(65536)
            if not chunk:
                raise RuntimeError('fixture IPC closed')
            data += chunk
    response = json.loads(data.split(b'\n', 1)[0])
    if response.get('ok') is not True:
        raise RuntimeError(response.get('error', 'fixture IPC failed'))
    return response.get('result')


def wait_for(call, timeout=15):
    deadline = time.monotonic() + timeout
    while True:
        try:
            value = call()
            if value:
                return value
        except (OSError, ValueError):
            pass
        if time.monotonic() >= deadline:
            raise RuntimeError('timed out waiting for fixture state')
        time.sleep(0.2)


def notify_open(pid):
    # Use the app's existing local distributed-notification IPC directly. This
    # does not use Apple Events, script a UI, or request automation permission.
    foundation = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
    foundation.CFNotificationCenterGetDistributedCenter.restype = ctypes.c_void_p
    foundation.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
    foundation.CFStringCreateWithCString.restype = ctypes.c_void_p
    foundation.CFNotificationCenterPostNotification.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_bool]
    foundation.CFRelease.argtypes = [ctypes.c_void_p]
    name = foundation.CFStringCreateWithCString(None, f'com.auriel.keytrail.open-dashboard.{pid}'.encode(), 0x08000100)
    try:
        foundation.CFNotificationCenterPostNotification(foundation.CFNotificationCenterGetDistributedCenter(), name, None, None, True)
    finally:
        foundation.CFRelease(name)


def visible_dashboard_windows(pid):
    """Read window metadata, retaining only this fixture's visible main window.

    A process in AppKit's run loop can still have no dashboard. Menu bars and
    invisible windows are not evidence that SwiftUI created the main scene.
    No screenshots or other applications' metadata are persisted.
    """
    cg = ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
    cf = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
    cg.CGWindowListCopyWindowInfo.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
    cg.CGWindowListCopyWindowInfo.restype = ctypes.c_void_p
    cf.CFPropertyListCreateData.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_long, ctypes.c_ulong, ctypes.c_void_p]
    cf.CFPropertyListCreateData.restype = ctypes.c_void_p
    cf.CFDataGetLength.argtypes = [ctypes.c_void_p]
    cf.CFDataGetLength.restype = ctypes.c_long
    cf.CFDataGetBytePtr.argtypes = [ctypes.c_void_p]
    cf.CFDataGetBytePtr.restype = ctypes.POINTER(ctypes.c_ubyte)
    cf.CFRelease.argtypes = [ctypes.c_void_p]
    windows = cg.CGWindowListCopyWindowInfo(0, 0)
    if not windows:
        raise RuntimeError('window metadata query failed')
    data = None
    try:
        data = cf.CFPropertyListCreateData(None, windows, 100, 0, None)
        if not data:
            raise RuntimeError('window metadata serialization failed')
        values = plistlib.loads(ctypes.string_at(cf.CFDataGetBytePtr(data), cf.CFDataGetLength(data)))
        return [value for value in values if value.get('kCGWindowOwnerPID') == pid
                and value.get('kCGWindowIsOnscreen') is True
                and value.get('kCGWindowLayer') == 0 and value.get('kCGWindowAlpha', 0) > 0
                and value.get('kCGWindowBounds', {}).get('Width', 0) >= 900
                and value.get('kCGWindowBounds', {}).get('Height', 0) >= 600
                and 'KeyTrail' in value.get('kCGWindowName', '')]
    finally:
        if data:
            cf.CFRelease(data)
        cf.CFRelease(windows)


def sample_state(name, pids, duration, period):
    start = time.monotonic()
    samples = []
    while True:
        values = [measure.read_process(pid) for pid in pids]
        if any(value is None for value in values):
            raise RuntimeError(f'owned process exited during {name}')
        samples.append({'elapsedSeconds': time.monotonic() - start,
                        'timestamp': dt.datetime.now(dt.timezone.utc).isoformat(),
                        'processes': values, 'totalRssMiB': sum(value['rssKiB'] for value in values) / 1024})
        elapsed = time.monotonic() - start
        if elapsed >= duration:
            break
        time.sleep(min(period, duration - elapsed))
    wall = samples[-1]['elapsedSeconds'] - samples[0]['elapsedSeconds']
    per_process = []
    for index, pid in enumerate(pids):
        rss = [sample['processes'][index]['rssKiB'] / 1024 for sample in samples]
        cpu = samples[-1]['processes'][index]['cpuTimeSeconds'] - samples[0]['processes'][index]['cpuTimeSeconds']
        per_process.append({'pid': pid, 'rssMiB': {'min': min(rss), 'median': statistics.median(rss), 'max': max(rss)},
                            'cpuTimeDeltaSeconds': cpu, 'intervalCpuPercentOneCore': cpu / wall * 100})
    totals = [sample['totalRssMiB'] for sample in samples]
    return {'name': name, 'wallSeconds': wall, 'sampleCount': len(samples), 'processes': per_process,
            'totalRssMiB': {'min': min(totals), 'median': statistics.median(totals), 'max': max(totals)},
            'intervalCpuPercentOneCore': sum(value['intervalCpuPercentOneCore'] for value in per_process), 'samples': samples}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--agent', type=Path, required=True)
    parser.add_argument('--duration', type=float, default=60)
    parser.add_argument('--period', type=float, default=2)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--shutdown-mode', choices=('ipc', 'ui'), default='ipc',
                        help='ui waits for the normal agent menu quit; ipc uses its existing shutdown operation')
    parser.add_argument('--lifecycle-only', action='store_true',
                        help='skip RSS/CPU sampling and verify normal lifecycle using manual-user UI actions')
    parser.add_argument('--ui-timeout', type=float, default=240,
                        help='maximum seconds to wait for each normal UI action (15–600)')
    args = parser.parse_args()
    if platform.system() != 'Darwin' or not (60 <= args.duration <= 120) or not (0 < args.period <= args.duration):
        parser.error('macOS and 60–120 second states with a positive sampling period are required')
    if not 15 <= args.ui_timeout <= 600:
        parser.error('UI action timeout must be between 15 and 600 seconds')
    if args.lifecycle_only and args.shutdown_mode != 'ui':
        parser.error('--lifecycle-only requires --shutdown-mode ui')
    agent_path = args.agent.resolve()
    dashboard_path = agent_path.with_name('KeyTrailDashboard')
    if not agent_path.is_file() or not dashboard_path.is_file():
        parser.error('sibling current-build Agent and Dashboard executables are required')
    args.output.mkdir(parents=True, exist_ok=True)
    progress_path = args.output / 'progress.json'
    report_path = args.output / 'runtime-profile.json'
    def checkpoint():
        temporary_report = report_path.with_suffix('.json.tmp')
        temporary_report.write_text(json.dumps(report, indent=2) + '\n')
        temporary_report.replace(report_path)
    def progress(state, **extra):
        event = {'state': state, 'timestamp': dt.datetime.now(dt.timezone.utc).isoformat(), **extra}
        progress_path.write_text(json.dumps(event, indent=2) + '\n')
        report['events'].append(event)
        checkpoint()
        print(state, flush=True)
    protected_before = protected_manifest()
    report = {'scope': 'Synthetic demo DB, normal AppKit menu agent; no real input monitor or network sync.',
              'method': 'RSS from ps, not physical footprint. Interval CPU from cumulative ps time delta; 100% is one core. ps %cpu is rolling only.',
              'durationPerStateSeconds': None if args.lifecycle_only else args.duration,
              'periodSeconds': None if args.lifecycle_only else args.period,
              'resourceSampling': 'not measured' if args.lifecycle_only else 'three bounded states',
              'uiActionSource': 'manual-user' if args.lifecycle_only else 'normal-ui-operator',
              'host': {'platform': platform.platform(), 'architecture': platform.machine()},
              'binaryHashes': {str(agent_path): digest(agent_path), str(dashboard_path): digest(dashboard_path)},
              'sourceHashes': manifests([*ROOT.glob('Sources/**/*.swift'), *ROOT.glob('rust/**/*.rs'), ROOT / 'Package.swift', ROOT / 'rust/Cargo.lock', ROOT / 'scripts/measure-process.py', Path(__file__)]),
              'protectedBundleCount': len({Path(path).parts[1] for path in protected_before}),
              'protectedBundleHashesBefore': protected_before, 'states': [], 'checks': {},
              'result': 'running', 'events': [], 'shutdownMode': args.shutdown_mode,
              'lifecycleEvidenceScope': 'Normal dashboard window close; ' + ('normal menu-agent UI quit.' if args.shutdown_mode == 'ui' else 'existing local IPC shutdown, not menu-click evidence.')}
    owned_agent = None
    directory = None
    try:
        with tempfile.TemporaryDirectory(prefix='kt-profile-', dir='/private/tmp') as temporary:
            directory = Path(temporary)
            # Register distinct development bundles so native inspection can
            # identify this fixture without selecting the user's current app.
            fixture_kind = 'Lifecycle' if args.lifecycle_only else 'Resource'
            identifier_suffix = fixture_kind.lower() if args.lifecycle_only else 'resources'
            agent_title = f'KeyTrail {fixture_kind} Agent' if args.lifecycle_only else 'KeyTrail Resource Fixture'
            dashboard_title = f'KeyTrail {fixture_kind} Dashboard'
            agent_bundle = directory / f'{agent_title}.app'
            dashboard_bundle = agent_bundle / f'Contents/Helpers/{dashboard_title}.app'
            bundle_identifiers = [f'com.auriel.keytrail.fixture.{identifier_suffix}.agent',
                                  f'com.auriel.keytrail.fixture.{identifier_suffix}.dashboard']
            for bundle, executable, bundle_id, title in (
                (agent_bundle, agent_path, bundle_identifiers[0], agent_title),
                (dashboard_bundle, dashboard_path, bundle_identifiers[1], dashboard_title)):
                macos = bundle / 'Contents/MacOS'
                macos.mkdir(parents=True)
                shutil.copy2(executable, macos / executable.name)
                with (bundle / 'Contents/Info.plist').open('wb') as stream:
                    plistlib.dump({'CFBundleIdentifier': bundle_id, 'CFBundleExecutable': executable.name,
                                   'CFBundleName': title, 'CFBundleDisplayName': title,
                                   'CFBundlePackageType': 'APPL', 'LSMinimumSystemVersion': '14.0',
                                   'CFBundleShortVersionString': '1.2.0', 'CFBundleVersion': '1',
                                   'NSPrincipalClass': 'NSApplication',
                                   'NSHighResolutionCapable': True, 'LSUIElement': executable == agent_path}, stream)
            # The existing agent locates this fixed helper directory name.
            helper_bundle = dashboard_bundle.with_name('KeyTrailDashboard.app')
            dashboard_bundle.rename(helper_bundle)
            resource_bundle = dashboard_path.parent / 'KeyTrail_KeyTrailApp.bundle'
            if resource_bundle.exists():
                shutil.copytree(resource_bundle, helper_bundle / resource_bundle.name)
            fixture_agent_path = agent_bundle / 'Contents/MacOS/KeyTrailAgent'
            fixture_dashboard_path = helper_bundle / 'Contents/MacOS/KeyTrailDashboard'
            report['fixtureBundleIdentifiers'] = bundle_identifiers
            report['checks']['packagedBinaryHashesMatchRelease'] = digest(fixture_agent_path) == digest(agent_path) and digest(fixture_dashboard_path) == digest(dashboard_path)
            # An absent DB lets the demo runtime seed only synthetic minute aggregates.
            invalid_arguments = (['--test-directory', str(directory)],
                                 ['--test-directory=' + str(directory)],
                                 ['--demo', '--test-directory'],
                                 ['--demo', '--test-directory', 'relative-fixture'],
                                 ['--demo', '--test-directory=relative-fixture'],
                                 ['--demo', '--test-directory='],
                                 ['--demo', '--test-directory-unknown=' + str(directory)],
                                 ['--demo', '--test-directory', str(directory), '--test-directory', str(directory)],
                                 ['--demo', '--test-directory', str(directory), '--test-directory=' + str(directory)],
                                 ['--demo', '--test-directory=' + str(directory), '--test-directory=' + str(directory)])
            for executable in (fixture_agent_path, fixture_dashboard_path):
                for arguments in invalid_arguments:
                    rejected = subprocess.run([str(executable), *arguments], capture_output=True, text=True, timeout=10)
                    if rejected.returncode != 64 or directory.joinpath('activity.sqlite').exists():
                        raise RuntimeError(executable.name + ' fixture CLI guard failed')
                    report['checks'][executable.name + ':reject:' + ' '.join(arguments)] = {'exitCode': rejected.returncode, 'message': rejected.stderr.strip()}
            log = args.output / 'agent.log'
            with log.open('w') as stream:
                owned_agent = subprocess.Popen([str(fixture_agent_path), '--demo', '--background', '--test-directory=' + temporary], stdout=stream, stderr=stream)
                status = wait_for(lambda: rpc(directory, {'op': 'status'}))
                if status.get('isDemo') is not True or status.get('monitoring') is not False or status.get('pid') != owned_agent.pid:
                    raise RuntimeError('fixture runtime safety status mismatch')
                report['initialStatus'] = status
                if children(owned_agent.pid):
                    raise RuntimeError('background fixture unexpectedly launched child UI')
                progress('background-agent-only', agentPID=owned_agent.pid, fixtureDirectory=temporary,
                         fixtureAgentBundle=str(agent_bundle), fixtureDashboardBundle=str(helper_bundle))
                if not args.lifecycle_only:
                    report['states'].append(sample_state('background-agent-only', [owned_agent.pid], args.duration, args.period))
                notify_open(owned_agent.pid)
                dashboard_pid = wait_for(lambda: next((pid for pid in children(owned_agent.pid) if (value := measure.read_process(pid)) and value['command'].endswith('/KeyTrailDashboard')), None))
                report['initialDashboardWindows'] = wait_for(lambda: visible_dashboard_windows(dashboard_pid), timeout=20)
                report['checks']['initialDashboardHasVisibleMainWindow'] = True
                progress('dashboard-open', agentPID=owned_agent.pid, dashboardPID=dashboard_pid, fixtureDirectory=temporary,
                         fixtureAgentBundle=str(agent_bundle), fixtureDashboardBundle=str(helper_bundle))
                if not args.lifecycle_only:
                    report['states'].append(sample_state('dashboard-open', [owned_agent.pid, dashboard_pid], args.duration, args.period))
                progress('awaiting-dashboard-close', agentPID=owned_agent.pid, dashboardPID=dashboard_pid, instructions='Close only the newly launched fixture dashboard window using its normal close button or Command-W.')
                wait_for(lambda: measure.read_process(dashboard_pid) is None, timeout=args.ui_timeout)
                if rpc(directory, {'op': 'status'}).get('pid') != owned_agent.pid:
                    raise RuntimeError('closing fixture dashboard stopped agent')
                report['checks']['normalWindowCloseExitsDashboardAndPreservesAgent'] = True
                progress('dashboard-closed-agent-continues', agentPID=owned_agent.pid)
                if not args.lifecycle_only:
                    report['states'].append(sample_state('dashboard-closed-agent-continues', [owned_agent.pid], args.duration, args.period))
                notify_open(owned_agent.pid)
                reopened_pid = wait_for(lambda: next((pid for pid in children(owned_agent.pid) if (value := measure.read_process(pid)) and value['command'].endswith('/KeyTrailDashboard')), None))
                report['reopenedDashboardWindows'] = wait_for(lambda: visible_dashboard_windows(reopened_pid), timeout=20)
                report['checks']['reopenedDashboardHasVisibleMainWindow'] = True
                report['checks']['dashboardReopenedWithNewPID'] = reopened_pid != dashboard_pid
                if args.shutdown_mode == 'ui':
                    progress('awaiting-agent-menu-quit', agentPID=owned_agent.pid, dashboardPID=reopened_pid,
                             instructions='Use only this fixture agent menu: 退出键迹（停止全部进程）.')
                    wait_for(lambda: owned_agent.poll() is not None, timeout=args.ui_timeout)
                else:
                    rpc(directory, {'op': 'shutdown'})
                owned_agent.wait(timeout=15)
                wait_for(lambda: measure.read_process(reopened_pid) is None)
                report['checks']['agentShutdownExitsOwnedDashboard'] = True
                report['checks']['agentExitCode'] = owned_agent.returncode
                report['checks']['fixtureSocketRemovedOnShutdown'] = not (directory / 'engine.sock').exists()
            report['fixtureFileNames'] = sorted(path.name for path in directory.iterdir())
        report['checks']['temporaryFixtureRemoved'] = not directory.exists()
        report['protectedBundleHashesAfter'] = protected_manifest()
        report['checks']['protectedBundlesUnchanged'] = report['protectedBundleHashesAfter'] == protected_before
        if not report['checks']['protectedBundlesUnchanged']:
            raise RuntimeError('protected bundle files changed during measurement')
        report['result'] = 'completed'
        progress('completed')
    except Exception as error:
        report['result'] = 'failed'
        report['error'] = str(error)
        progress('failed', error=str(error))
        raise
    finally:
        if owned_agent is not None and owned_agent.poll() is None:
            owned_agent.terminate()
            try:
                owned_agent.wait(timeout=10)
            except subprocess.TimeoutExpired:
                owned_agent.kill()
                owned_agent.wait(timeout=5)
        if directory is not None:
            report['checks']['temporaryFixtureRemoved'] = not directory.exists()
        try:
            report['protectedBundleHashesAfter'] = protected_manifest()
            report['checks']['protectedBundlesUnchanged'] = report['protectedBundleHashesAfter'] == protected_before
        except Exception as error:
            report['checks']['protectedBundlesUnchanged'] = False
            report['protectedBundleVerificationError'] = str(error)
        if not report['checks']['protectedBundlesUnchanged']:
            report['result'] = 'failed'
            report.setdefault('error', 'protected app bundle verification failed')
        checkpoint()


if __name__ == '__main__':
    main()
