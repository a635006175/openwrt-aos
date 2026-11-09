// SPDX-License-Identifier: Apache-2.0
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const previewRoot = __dirname;
const resourcesRoot = path.resolve(__dirname, '../../package/luci-app-console/htdocs/luci-static/resources');
const port = Number(process.env.CONSOLE_PREVIEW_PORT || 8788);
const types = { '.html': 'text/html; charset=utf-8', '.js': 'application/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.png': 'image/png' };
http.createServer((request, response) => {
	let pathname;
	try { pathname = decodeURIComponent(new URL(request.url, 'http://localhost').pathname); }
	catch { response.writeHead(400).end(); return; }
	if (pathname === '/favicon.ico') { response.writeHead(204).end(); return; }
	const root = pathname.startsWith('/resources/') ? resourcesRoot : previewRoot;
	const relative = pathname.startsWith('/resources/') ? pathname.slice(11) : pathname === '/' ? 'index.html' : pathname.slice(1);
	const file = path.resolve(root, relative);
	if (!file.startsWith(root + path.sep) || !types[path.extname(file)]) { response.writeHead(404).end(); return; }
	fs.readFile(file, (error, data) => {
		if (error) { response.writeHead(404).end(); return; }
		response.writeHead(200, { 'Content-Type': types[path.extname(file)], 'Cache-Control': 'no-store' }).end(data);
	});
}).listen(port, '127.0.0.1', () => console.log('OpenWrt console preview: http://127.0.0.1:' + port));
