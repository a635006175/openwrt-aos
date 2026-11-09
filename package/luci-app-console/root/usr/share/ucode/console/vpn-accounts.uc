// SPDX-License-Identifier: Apache-2.0
import { open, mkdir, chmod, lsdir, readfile, rename, unlink } from 'fs';
import { crypt } from 'luci.core';

const directory = '/etc/console-vpn/accounts';
function validName(name) { return type(name) == 'string' && !!match(name, /^[A-Za-z0-9_-]{1,48}$/); }
function path(name) { if (!validName(name)) die('账号名称无效\n'); return `${directory}/${name}.json`; }
function load(name) {
	const data = readfile(path(name));
	if (data == null) return null;
	try { return json(data); } catch (e) { die('账号数据损坏\n'); }
}
function publicAccount(name, account) { return { username: name, enabled: account.enabled, address: account.address || '', remoteSubnet: account.remoteSubnet || '', description: account.description || '' }; }
function listAccounts() {
	let list = [];
	for (let filename in lsdir(directory) || []) {
		const m = match(filename, /^([A-Za-z0-9_-]{1,48})\.json$/);
		if (!m) continue;
		const account = load(m[1]);
		if (type(account) == 'object') push(list, publicAccount(m[1], account));
	}
	return list;
}
function validIPv4(value) {
	const matchIP = type(value) == 'string' && match(value, /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
	if (!matchIP) return false;
	for (let i = 1; i <= 4; i++) if (+matchIP[i] > 255 || (length(matchIP[i]) > 1 && substr(matchIP[i], 0, 1) == '0')) return false;
	return true;
}
function validPassword(value) {
	if (type(value) != 'string' || !length(value)) return false;
	return index(value, '\n') < 0 && index(value, '\r') < 0 && index(value, chr(0)) < 0;
}
// crypt() 的输入缓冲区有固定上限：实测 256 字节可正常出哈希，257 字节起返回空结果。
// 密码本身已不限制长度与字符集，但落盘必须能算出哈希，所以这里按 crypt 的真实能力兜底。
function cryptPassword(value, salt) {
	const hash = crypt(value, '$6$rounds=50000$' + hexenc(salt) + '$');
	return type(hash) == 'string' && length(hash) > 20 && substr(hash, 0, 3) == '$6$' ? hash : null;
}
function salt16() {
	const random = open('/dev/urandom', 'r');
	const salt = random?.read(8);
	random?.close();
	return salt && length(salt) == 8 ? salt : null;
}
function saveAccount(input) {
	const name = input.username;
	path(name);
	const existing = load(name);
	const password = input.password || '';
	// 密码不再限制长度；仍拒绝换行/CR/NUL，因为账号密码要以 root 独享文件保存，
	// 含换行的内容会破坏文件结构与后续读取。
	if ((!existing && !length(password)) || (length(password) && !validPassword(password))) die('密码不能为空，且不能包含换行或空字符\n');
	const address = input.address || '', remote = input.remoteSubnet || '', description = input.description || '';
	if (address && !validIPv4(address)) die('固定 IP 地址无效\n');
	if (remote) {
		const parts = split(remote, '/');
		if (length(parts) != 2 || !validIPv4(parts[0]) || !match(parts[1], /^\d{1,2}$/) || +parts[1] < 1 || +parts[1] > 30) die('远端网段无效\n');
	}
	if (type(description) != 'string' || length(description) > 120 || index(description, '\n') >= 0 || index(description, '\r') >= 0 || index(description, chr(0)) >= 0) die('备注无效\n');
	for (let item in listAccounts()) if (address && item.username != name && item.address == address) die('固定 IP 已被其他账号使用\n');
	let hash = existing?.hash;
	if (length(password)) {
		const salt = salt16();
		if (!salt) die('无法生成密码盐\n');
		hash = cryptPassword(password, salt);
		if (!hash) die('密码过长，无法安全保存（本机 crypt 上限 256 字节）\n');
	}
	mkdir('/etc/console-vpn', 0700); chmod('/etc/console-vpn', 0700);
	mkdir(directory, 0700); chmod(directory, 0700);
	const temporary = path(name) + '.new';
	const fd = open(temporary, 'w');
	if (!fd) die('无法写入账号\n');
	chmod(temporary, 0600);
	fd.write(sprintf('%J\n', { hash, enabled: input.enabled == true, address, remoteSubnet: remote, description }));
	fd.close();
	if (!rename(temporary, path(name))) die('无法保存账号\n');
	return publicAccount(name, { enabled: input.enabled == true, address, remoteSubnet: remote, description });
}
function deleteAccount(name) { if (!load(name)) die('账号不存在\n'); if (!unlink(path(name))) die('无法删除账号\n'); return true; }
function verify(name, password) {
	if (!validName(name) || !validPassword(password)) return false;
	const account = load(name);
	if (!account?.enabled || type(account.hash) != 'string' || substr(account.hash, 0, 3) != '$6$') return false;
	return crypt(password, account.hash) == account.hash;
}
export { listAccounts, saveAccount, deleteAccount, verify };
