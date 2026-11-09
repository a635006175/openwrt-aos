// SPDX-License-Identifier: Apache-2.0
const targets = [
	{ id: 'github', name: 'GitHub', url: 'https://github.com/' },
	{ id: 'google', name: 'Google', url: 'https://www.google.com/' },
	{ id: 'chatgpt', name: 'ChatGPT', url: 'https://chatgpt.com/' },
	{ id: 'youtube', name: 'YouTube', url: 'https://www.youtube.com/' }
];
function classify(code, exitCode) {
	if (exitCode == 28 || exitCode == 124) return 'timeout';
	if (exitCode != 0 || !code) return 'failed';
	if (code >= 200 && code < 400) return 'success';
	if (index([401, 403, 429], code) >= 0) return 'restricted';
	return 'http-error';
}
export { targets, classify };
