"""Native Android update verification. Only the separate QA app on an isolated emulator is touched."""
import json
import os
import re
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET

serial, agent, proof_arg, production_apk = sys.argv[1:]
if not serial.startswith('emulator-'):
    raise SystemExit('Requires an isolated emulator with host clipboard sharing disabled.')
proof = Path(proof_arg).resolve(); proof.mkdir(parents=True, exist_ok=True)
sdk = Path(os.environ['ANDROID_HOME'])
adb = str(sdk / 'platform-tools/adb')
signer = str(sdk / 'build-tools/35.0.0/apksigner')
aapt = str(sdk / 'build-tools/35.0.0/aapt')
package = 'io.github.c0mm0n.fxclip.updatetest'
activity = package + '/io.github.c0mm0n.fxclip.MainActivity'
session = 'fxclip-update-' + serial
work = Path(tempfile.mkdtemp(prefix='fxclip-android-update-'))
log = (proof / 'driver.log').open('w')
server = None
results = []
strings = {item.attrib['name']: (item.text or '').replace("\\'", "'") for item in ET.parse('android/app/src/main/res/values/strings.xml').findall('string')}

def command(args, *, text=None, cwd=None, timeout=180, allow_settings=False, check=True):
    log.write('$ ' + shlex.join(map(str, args)) + '\n'); log.flush()
    result = subprocess.run(list(map(str, args)), input=text, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, cwd=cwd, timeout=timeout)
    log.write(result.stdout); log.flush()
    # The driver reports an app escape while interacting with native Settings.
    # Assertions still verify the expected screen and the QA package's app-op.
    expected_switch = allow_settings and 'foregrounded com.android.settings' in result.stdout
    if check and result.returncode and not expected_switch:
        raise RuntimeError(result.stdout)
    return result.stdout

def device(*args, **kwargs):
    return command([adb, '-s', serial, *args], **kwargs)

def drive(*args, **kwargs):
    return command([agent, *args, '--session', session, '--platform', 'android', '--serial', serial], **kwargs)

def press(identifier, settle=True, **kwargs):
    return drive('press', 'id="' + identifier + '"', *(['--settle'] if settle else []), **kwargs)

def wait(message):
    drive('wait', 'text', message, '20000')

def requests():
    return [json.loads(line) for line in (proof / 'requests.jsonl').read_text().splitlines()]

def hashes():
    return device('shell', 'run-as', package, 'sha256sum', 'files/settings.json', 'shared_prefs/fxclip.xml').strip()

def version():
    data = device('shell', 'dumpsys', 'package', package)
    code = re.search(r'versionCode=(\d+)', data)
    name = re.search(r'versionName=([^\s]+)', data)
    assert code and name, 'Installed QA package missing'
    return int(code[1]), name[1]

def launch():
    device('shell', 'am', 'start', '-W', '-a', 'android.intent.action.MAIN', '-c', 'android.intent.category.LAUNCHER', '-f', '0x10200000', '-n', activity)
    drive('open', package, '--foreground', '--no-test-ime')
    wait('42')
    press('fxclip-updates-nav')

def reset(mode):
    global before, expected_hash
    device('shell', 'am', 'force-stop', package)
    device('install', '-r', '-d', str(work / '1.0.0.apk'))
    device('shell', 'pm', 'clear', package)
    device('shell', 'appops', 'set', package, 'REQUEST_INSTALL_PACKAGES', 'default')
    device('shell', 'run-as', package, 'mkdir', '-p', 'files', 'shared_prefs')
    prefs = '<?xml version="1.0" encoding="utf-8"?><map><boolean name="autoCleanOnOpen" value="false"/><boolean name="tutorialSeen" value="true"/><long name="trackersRemoved" value="42"/><boolean name="historyEnabled" value="true"/><string name="historyEntries">[&quot;https://example.com/qa-preserved&quot;]</string></map>'
    settings = '{"trackersEverywhere":false,"qaPreserve":"unchanged","addedTrackers":{"params":["qa_param"],"prefixes":[]}}'
    for target, value in [('shared_prefs/fxclip.xml', prefs), ('files/settings.json', settings)]:
        device('shell', '-T', 'run-as ' + package + ' sh -c ' + shlex.quote('cat > ' + target), text=value)
    expected_hash = hashes()
    (proof / 'mode').write_text(mode)
    before = len(requests())
    launch()
    wait(strings['update_version'] % '1.0.0')
    assert len(requests()) == before, 'Network request without consent'

def check_available():
    press('fxclip-update-check')
    wait(strings['update_available'] % '1.0.1')

def download(settle=True):
    press('fxclip-update-download')
    press('fxclip-update-download-confirm', settle=settle)

def clean_download():
    device('shell', 'run-as', package, 'sh', '-c', shlex.quote('test ! -e files/updates/update.apk.part && test ! -e files/updates/update.apk'))

def passed(name, request_count, new=False):
    assert hashes() == expected_hash, name + ': settings/counter/history changed'
    assert version() == ((101, '1.0.1') if new else (100, '1.0.0')), name + ': wrong installed version'
    seen = requests()[before:]
    assert len(seen) == request_count, (name, seen)
    assert all(row['path'] in ('/latest', '/fxclip-android.apk') and row['user_agent'].startswith('fxclip/') for row in seen)
    drive('screenshot', str(proof / (name + '.png')))
    results.append({'name': name, 'passed': True, 'requests': len(seen), 'dataHashes': expected_hash})
    (proof / 'results.json').write_text(json.dumps(results, indent=2))
    print(name + ': passed', flush=True)

try:
    # Build only unpublished fixtures. The production APK supplied by CI is never overwritten.
    for name, code in [('1.0.0', 100), ('1.0.1', 101), ('old-code', 100)]:
        release = '1.0.1' if name == 'old-code' else name
        command(['./gradlew', ':app:assembleUpdateTest', '-PfxclipVersion=' + release, '-PfxclipVersionCode=' + str(code), '--console=plain'], cwd='android', timeout=300)
        shutil.copyfile('android/app/build/outputs/apk/updateTest/app-updateTest.apk', work / (name + '.apk'))
    badging = command([aapt, 'dump', 'badging', work / '1.0.0.apk']).splitlines()[0]
    assert "name='" + package + "'" in badging and "versionCode='100'" in badging, 'Refusing to install a non-QA fixture'
    shutil.copyfile(production_apk, work / 'wrong-package.apk')
    command([Path(os.environ['JAVA_HOME']) / 'bin/keytool', '-genkeypair', '-keystore', work / 'other.p12', '-storepass', 'fixture-only', '-alias', 'qa', '-keyalg', 'RSA', '-keysize', '2048', '-validity', '30', '-dname', 'CN=fxclip Update QA'])
    command([signer, 'sign', '--ks', work / 'other.p12', '--ks-key-alias', 'qa', '--ks-pass', 'pass:fixture-only', '--out', work / 'other-certificate.apk', work / '1.0.1.apk'])
    (proof / 'mode').write_text('normal')
    (proof / 'requests.jsonl').write_text('')
    (proof / 'server-ready').unlink(missing_ok=True)
    server = subprocess.Popen([sys.executable, 'android/tools/update-server.py', str(work), str(proof)], stdout=log, stderr=log)
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if server.poll() is not None: raise RuntimeError('Loopback fixture server failed to start')
        if (proof / 'server-ready').exists() and (proof / 'server-ready').read_text() == str(server.pid): break
        time.sleep(.05)
    else: raise RuntimeError('Loopback fixture server did not become ready')
    device('reverse', 'tcp:48637', 'tcp:48637')
    reset('normal'); wait(strings['update_idle']); passed('default-off', 0)
    for mode in ['older', 'equal', 'draft', 'prerelease', 'network']:
        reset(mode); press('fxclip-update-check')
        wait(strings['update_check_failed' if mode == 'network' else 'update_current'])
        clean_download(); passed(mode, 1)
    reset('normal'); check_available(); press('fxclip-update-download'); press('fxclip-update-download-decline')
    wait(strings['update_available'] % '1.0.1'); clean_download(); passed('decline-download', 1)
    reset('slow'); check_available(); download(settle=False)
    drive('wait', 'id="fxclip-update-cancel"', '20000'); press('fxclip-update-cancel')
    wait(strings['update_cancelled']); clean_download()
    drive('screenshot', str(proof / 'cancel-download.png'))
    (proof / 'mode').write_text('normal')
    download(); wait(strings['update_ready'] % '1.0.1'); passed('cancel-and-retry', 3)
    for mode, message in [('corrupt', 'update_invalid_apk'), ('digest', 'update_invalid_apk'), ('size', 'update_invalid_apk'), ('interrupted', 'update_download_failed'), ('old-code', 'update_old_code'), ('certificate', 'update_wrong_signature'), ('package', 'update_wrong_package')]:
        reset(mode); check_available(); download(); wait(strings[message]); clean_download(); passed(mode, 2)
    reset('slow'); check_available(); download(settle=False)
    drive('wait', 'id="fxclip-update-cancel"', '20000')
    # Wait for actual private partial bytes, then model Android stopping the process.
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        partial = device('shell', 'run-as', package, 'sh', '-c', shlex.quote('test -s files/updates/update.apk.part && echo written'), check=False)
        if 'written' in partial: break
        time.sleep(.1)
    else: raise AssertionError('No partial download to interrupt')
    device('shell', 'am', 'force-stop', package); launch(); wait(strings['update_idle'])
    clean_download(); passed('stopped-during-download', 2)
    reset('normal'); press('fxclip-update-auto'); wait(strings['update_available'] % '1.0.1')
    device('shell', 'am', 'force-stop', package); launch(); wait(strings['update_idle'])
    assert 'value="true"' in device('shell', 'run-as', package, 'cat', 'shared_prefs/updates.xml')
    assert len(requests()[before:]) == 1, 'Repeated automatic check within a day'
    device('shell', 'am', 'force-stop', package)
    expired = ET.fromstring(device('shell', 'run-as', package, 'cat', 'shared_prefs/updates.xml'))
    expired.find("long[@name='lastCheck']").set('value', '1')
    device('shell', '-T', 'run-as ' + package + ' sh -c ' + shlex.quote('cat > shared_prefs/updates.xml'), text=ET.tostring(expired, encoding='unicode'))
    launch(); wait(strings['update_available'] % '1.0.1')
    press('fxclip-update-auto')
    device('shell', 'am', 'force-stop', package); launch(); wait(strings['update_idle'])
    passed('automatic-consent-daily-expiry-and-reopen', 2)
    reset('normal'); check_available(); download(); wait(strings['update_ready'] % '1.0.1')
    device('shell', 'appops', 'set', package, 'REQUEST_INSTALL_PACKAGES', 'allow')
    device('shell', 'run-as ' + package + ' sh -c ' + shlex.quote('printf X | dd of=files/updates/update.apk bs=1 count=1 conv=notrunc'))
    press('fxclip-update-install'); press('fxclip-update-install-confirm')
    wait(strings['update_invalid_apk']); clean_download(); passed('reverify-before-install', 2)
    reset('normal'); check_available(); download(); wait(strings['update_ready'] % '1.0.1')
    # Keep an enabled automatic preference through the real package replacement.
    press('fxclip-update-auto')
    device('shell', 'am', 'force-stop', package); launch(); wait(strings['update_ready'] % '1.0.1')
    press('fxclip-update-install'); press('fxclip-update-permission-decline')
    wait(strings['update_ready'] % '1.0.1'); assert version() == (100, '1.0.0')
    press('fxclip-update-install'); press('fxclip-update-permission-open', settle=False, allow_settings=True)
    wait('Allow from this source')
    drive('press', 'label="Allow from this source"', '--settle', allow_settings=True)
    assert 'allow' in device('shell', 'appops', 'get', package, 'REQUEST_INSTALL_PACKAGES')
    drive('screenshot', str(proof / 'source-permission.png'))
    drive('back', '--system', '--settle')
    press('fxclip-update-install'); press('fxclip-update-install-decline')
    assert version() == (100, '1.0.0')
    press('fxclip-update-install'); press('fxclip-update-install-confirm')
    drive('alert', 'get'); drive('screenshot', str(proof / 'native-installer.png'))
    drive('alert', 'dismiss'); wait(strings['update_installer_closed'])
    assert version() == (100, '1.0.0') and hashes() == expected_hash
    press('fxclip-update-install'); press('fxclip-update-install-confirm'); drive('alert', 'accept')
    deadline = time.monotonic() + 40
    while time.monotonic() < deadline:
        if version() == (101, '1.0.1'): break
        time.sleep(.2)
    else: raise AssertionError('Android did not install version 1.0.1')
    assert not device('shell', 'pidof', package, check=False).strip(), 'Unexpected automatic relaunch'
    launch(); wait(strings['update_version'] % '1.0.1'); wait(strings['update_idle'])
    assert len(device('shell', 'pidof', package).split()) == 1
    prefs = device('shell', 'run-as', package, 'cat', 'shared_prefs/updates.xml')
    assert 'name="automaticChecks" value="true"' in prefs
    passed('native-install-preserves-data-and-consent', 2, new=True)
except Exception as error:
    (proof / 'failure.txt').write_text(str(error))
    # Preserve the Android cause as well as the UI-driver symptom (for example an ANR).
    for name, args in [('logcat.txt', ['logcat', '-d', '-v', 'threadtime']),
                       ('last-anr.txt', ['shell', 'dumpsys', 'activity', 'lastanr']),
                       ('activity.txt', ['shell', 'dumpsys', 'activity', 'activities'])]:
        try:
            (proof / name).write_text(device(*args, timeout=30, check=False))
        except Exception as diagnostic_error:
            (proof / (name + '.error')).write_text(str(diagnostic_error))
    try:
        drive('screenshot', str(proof / 'failure.png'), timeout=30)
    except Exception as diagnostic_error:
        (proof / 'screenshot.error').write_text(str(diagnostic_error))
    raise
finally:
    if server is not None:
        server.terminate()
        server.wait(timeout=5)
    shutil.rmtree(work)
    log.close()
