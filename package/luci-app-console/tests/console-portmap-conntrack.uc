// SPDX-License-Identifier: Apache-2.0
// Unit tests for the binding-key derivation used by conntrack flushing.
// Run with: ucode tests/console-portmap-conntrack.uc
import * as m from 'console.portmap';

const top = {
	wans: [ { name: 'wan', zone: 'wan', up: true, addresses: ['172.16.10.81'], subnets: ['172.16.10.81/23'] } ],
	lans: [ { name: 'lan', zone: 'lan', up: true, addresses: ['192.168.1.1'], subnets: ['192.168.1.0/24'] } ]
};

function rule(over) {
	return {
		id: 'r1', internalIP: '192.168.1.8', internalPorts: '3555', externalPorts: '3555',
		protocol: 'tcp', type: 'interface', external: 'any',
		allowIPs: [], groups: [], comment: '', enabled: true, ...over
	};
}

let failures = 0;
function check(name, got, want) {
	const ok = sprintf('%J', got) === sprintf('%J', want);
	if (!ok) {
		failures++;
		printf('FAIL %s\n  got  %s\n  want %s\n', name, sprintf('%J', got), sprintf('%J', want));
	} else {
		printf('ok   %s\n', name);
	}
}

// A single enabled rule binds exactly one external tuple on the WAN address.
check('enabled tcp binding',
	map(m.exposed({ rules: [rule({})] }, top), t => t.key),
	['tcp|172.16.10.81|3555|192.168.1.8|3555']);

// A disabled rule exposes nothing, so its flows are eligible for flushing.
check('disabled exposes nothing',
	m.exposed({ rules: [rule({ enabled: false })] }, top), []);

// tcp+udp creates one binding per protocol.
check('tcp+udp count',
	length(m.exposed({ rules: [rule({ protocol: 'tcp+udp' })] }, top)), 2);

// Changing the external port must produce a different key, otherwise the stale
// connection would be kept alive after an edit.
const a = map(m.exposed({ rules: [rule({})] }, top), t => t.key);
const b = map(m.exposed({ rules: [rule({ externalPorts: '3556', internalPorts: '3556' })] }, top), t => t.key);
check('port change differs', a[0] !== b[0], true);

// Repointing the backend must also invalidate the old flow.
const c = map(m.exposed({ rules: [rule({ internalIP: '192.168.1.9' })] }, top), t => t.key);
check('backend change differs', a[0] !== c[0], true);

// An unchanged rule keeps its key, so unrelated saves do not cut traffic.
const d = map(m.exposed({ rules: [rule({})] }, top), t => t.key);
check('identical rule stable', a[0], d[0]);

// type=ip binds only the configured external address.
check('type=ip binding',
	map(m.exposed({ rules: [rule({ type: 'ip', external: '203.0.113.7' })] }, top), t => t.key),
	['tcp|203.0.113.7|3555|192.168.1.8|3555']);

// Many-to-one port ranges expand into one binding per port.
check('range expansion',
	length(m.exposed({ rules: [rule({ internalPorts: '8000-8002', externalPorts: '8000-8002' })] }, top)), 3);

if (failures) {
	printf('\nFAILURES=%d\n', failures);
	exit(1);
}
print('\nALL_PASS\n');
