#!/usr/bin/python3
"""Bounded, read-only power comparison; never changes power settings or AI tasks."""
import argparse
import datetime
import json
import os
from pathlib import Path
import re
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output-dir', required=True)
parser.add_argument('--seconds', type=int, default=180)
parser.add_argument('--post-open-seconds', type=int, default=30)
args = parser.parse_args()
if os.geteuid() != 0 or not 10 <= args.seconds <= 1500:
    parser.error('Requires administrator execution; duration must be 10–1500 seconds.')
if not 30 <= args.post_open_seconds <= 300:
    parser.error('Post-open observations must be 30–300 seconds.')
out = Path(args.output_dir)
if not out.is_absolute() or out.is_symlink() or not out.is_dir() or out.stat().st_mode & 0o077:
    parser.error('Output must be an existing private directory, not a symlink.')

def read(command):
    result = subprocess.run(command, text=True, capture_output=True, timeout=4,
                            env={**os.environ, 'LC_ALL': 'C'})
    if result.returncode:
        raise RuntimeError(result.stderr.strip()[:200])
    return result.stdout

power = None
started = time.monotonic()
reason = 'duration reached'
last_resources = -30.0
with (out / 'power.txt').open('x') as power_file, (out / 'context.jsonl').open('x') as context_file, (out / 'resources.jsonl').open('x') as resources_file:
    try:
        power = subprocess.Popen(['/usr/bin/powermetrics', '--samplers',
            'cpu_power,gpu_power,thermal', '--sample-rate', '5000',
            '--sample-count', str(args.seconds // 5), '--buffer-size', '1'],
            stdout=power_file, stderr=subprocess.STDOUT, env={**os.environ, 'LC_ALL': 'C'})
        seen_closed = False
        opened_at = None
        while time.monotonic() - started < args.seconds:
            row = {'time': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                   'elapsed': time.monotonic() - started}
            try:
                domain = read(['/usr/sbin/ioreg', '-r', '-d', '1', '-c', 'IOPMrootDomain', '-l'])
                match = re.search(r'^\s*"AppleClamshellState" = (Yes|No)', domain, re.M)
                row['lidClosed'] = None if match is None else match[1] == 'Yes'
                battery = read(['/usr/sbin/ioreg', '-r', '-c', 'AppleSmartBattery', '-l'])
                for key in ['ExternalConnected', 'IsCharging', 'CurrentCapacity', 'Voltage', 'Amperage']:
                    match = re.search(r'^\s*"' + key + r'" = (Yes|No|-?\d+)\s*$', battery, re.M)
                    row[key] = None if match is None else match[1]
                settings = read(['/usr/bin/pmset', '-g'])
                match = re.search(r'^\s*SleepDisabled\s+([01])\s*$', settings, re.M)
                row['sleepDisabled'] = None if match is None else match[1] == '1'
                if row['lidClosed'] is True:
                    seen_closed = True
                    opened_at = None
                elif seen_closed and row['lidClosed'] is False and opened_at is None:
                    opened_at = time.monotonic()
            except Exception as error:
                row['error'] = str(error)
            context_file.write(json.dumps(row) + '\n')
            context_file.flush()
            if time.monotonic() - started - last_resources >= 30:
                resources = {'time': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                             'elapsed': time.monotonic() - started}
                last_resources = resources['elapsed']
                try:
                    listing = read(['/bin/ps', '-axo', 'pid=,lstart=,time=,rss=,comm='])
                    processes = []
                    malformed = 0
                    lines = listing.splitlines()
                    for line in lines[:4096]:
                        fields = line.split(None, 8)
                        try:
                            processes.append({'pid': int(fields[0]), 'start': ' '.join(fields[1:6]),
                                'cpuTime': fields[6], 'rssKiB': int(fields[7]),
                                'name': Path(fields[8]).name})
                        except (ValueError, IndexError):
                            malformed += 1
                    resources.update(processes=processes, malformedRows=malformed,
                                     processListTruncated=len(lines) > 4096)
                    resources['vm'] = read(['/usr/bin/vm_stat'])
                    resources['memory'] = read(['/usr/sbin/sysctl',
                        'kern.memorystatus_vm_pressure_level', 'vm.swapusage'])
                except Exception as error:
                    resources['error'] = str(error)
                resources['collectionSeconds'] = time.monotonic() - started - resources['elapsed']
                resources_file.write(json.dumps(resources) + '\n')
                resources_file.flush()
            if opened_at is not None and time.monotonic() - opened_at >= args.post_open_seconds:
                reason = 'closed then reopened; collected post-open observations'
                break
            if power.poll() is not None:
                reason = 'powermetrics exited: ' + str(power.returncode)
                break
            if sum((out / name).stat().st_size for name in
                   ['power.txt', 'context.jsonl', 'resources.jsonl']) > 10 * 1024 * 1024:
                reason = '10 MiB limit reached'
                break
            time.sleep(min(5, max(0, args.seconds - (time.monotonic() - started))))
    finally:
        if power is not None and power.poll() is None:
            power.terminate()
            try:
                power.wait(timeout=3)
            except subprocess.TimeoutExpired:
                power.kill()
                power.wait(timeout=3)
print(json.dumps({'output': str(out), 'duration': time.monotonic() - started, 'reason': reason}))
