// SPDX-License-Identifier: Apache-2.0
'use strict';
'require baseclass';
'require ui';

const icons = {
	security: 'M12 2l8 4v6c0 5-8 10-8 10S4 17 4 12V6zM8 12l3 3 5-6',
	behavior: 'M4 5h16M4 12h16M4 19h16M8 3v4M16 10v4M10 17v4',
	console: 'M3 13a9 9 0 0 1 18 0M12 13l4-5M5 18h14',
	status: 'M3 4h18v16H3zM4 13h4l3-6 3 10 3-4h3',
	system: 'M12 3l3 2 3-1 2 3-1 3 2 2-2 3 1 3-3 2-3-1-2 2-3-2-3 1-2-3 1-3-2-2 2-3-1-3 3-2 3 1zM15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0',
	network: 'M9 3h6v5H9zM2 16h6v5H2zM9 16h6v5H9zM16 16h6v5h-6zM12 8v8M5 16v-4h14v4',
	flow: 'M3 12h5M8 12l5-6h5M8 12l5 6h5M16 4l2 2-2 2M16 16l2 2-2 2',
	other: 'M3 3h7v7H3zM14 3h7v7h-7zM3 14h7v7H3zM14 14h7v7h-7z'
};

function icon(name) {
	const node = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
	node.setAttribute('viewBox', '0 0 24 24');
	node.setAttribute('aria-hidden', 'true');
	node.setAttribute('class', 'console-nav-icon');
	const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
	path.setAttribute('d', icons[name] || icons.other);
	node.appendChild(path);
	return node;
}

return baseclass.extend({
	__init__() {
		// Acknowledge navigation immediately while the next document is loading.
		const navigationNotice = E('div', { role: 'status', class: 'console-navigation-status', hidden: true }, '正在打开页面…');
		document.body.append(navigationNotice);
		let navigationTimer;
		const clearNavigation = () => { navigationNotice.hidden = true; window.clearTimeout(navigationTimer); };
		window.addEventListener('pageshow', clearNavigation);
		document.addEventListener('click', event => {
			const link = event.target.closest('a');
			if (!link || !link.closest('.console-sidebar, #tabmenu') || event.defaultPrevented || event.button !== 0 || event.ctrlKey || event.metaKey || event.shiftKey || event.altKey || link.target || link.hasAttribute('download')) return;
			const url = new URL(link.href, location.href);
			if (url.origin !== location.origin || url.href === location.href || url.hash) return;
			navigationNotice.hidden = false;
			window.clearTimeout(navigationTimer);
			navigationTimer = window.setTimeout(clearNavigation, 12000);
		});
		const path = L.env.requestpath.slice(0, 3).join('/');
		// 增强模块尽早启动：cbi 内容一就绪就重排，减少原生界面的可见时间。
		if (path === 'admin/network/network') this.runEnhancer('console.interfaces', '.cn-interfaces');
		if (path === 'admin/network/dhcp') this.runEnhancer('console.dhcp', '.cn-dhcp');
		const toggle = document.querySelector('.console-toggle');
		if (toggle) toggle.addEventListener('click', () => {
			const open = document.body.classList.toggle('console-menu-open');
			toggle.setAttribute('aria-expanded', String(open));
		});
		document.addEventListener('keydown', event => {
			if (event.key === 'Escape' && document.body.classList.contains('console-menu-open')) {
				document.body.classList.remove('console-menu-open');
				toggle.setAttribute('aria-expanded', 'false');
				toggle.focus();
			}
		});
		ui.menu.load().then(tree => this.render(tree)).catch(() => {
			const menu = document.querySelector('#topmenu');
			if (menu) menu.appendChild(E('p', { class: 'console-menu-error' }, '菜单加载失败，请刷新页面。'));
		});
	},

	// 加载增强模块并在原生内容就绪后尽快接管。
	// 增强渲染完成（或失败）后撤掉 CSS 遮罩，失败时退回原生界面而不是一直空白。
	runEnhancer(moduleName, readySelector) {
		const reveal = () => document.body.classList.add('cn-enhanced');
		const fail = error => {
			if (window.console) console.error(moduleName + ' 增强失败：', error && error.message);
			reveal();
		};
		L.require(moduleName).then(module => {
			let attempts = 0;
			const attempt = () => {
				if (document.querySelector(readySelector)) return reveal();
				if (++attempts > 100) return reveal(); // 约 10 秒后放弃，交还原生界面
				window.setTimeout(attempt, 100);
			};
			try { module.start(); } catch (error) { return fail(error); }
			attempt();
		}).catch(fail);
	},

	render(tree) {
		const container = document.querySelector('#topmenu');
		const admin = tree.children && tree.children.admin;
		if (!container || !admin) return;
		const request = L.env.requestpath || [];
		const oafNames = { dashboard: 'dashboard', users: 'devices', app_filter: 'rules', mac_filter: 'access', whitelist: 'whitelist', app_record: 'records', feature: 'features', advanced: 'settings', about: 'about' };
		const current = request[1] === 'services' && request[2] === 'oaf' ? [ 'admin', 'behavior', oafNames[request[3]] || 'dashboard' ] : request;
		const behaviorAvailable = !!admin.children?.behavior?.satisfied;
		for (const group of ui.menu.getChildren(admin).filter(node => !!node.title)) {
			if (group.name === 'logout') continue;
			const active = current[1] === group.name;
			const children = ui.menu.getChildren(group).filter(node => !!node.title && !(behaviorAvailable && group.name === 'services' && node.name === 'oaf'));
			if (group.name === 'services' && behaviorAvailable && !children.length) continue;
			const title = group.name === 'console' ? '系统概况' : _(group.title);
			if (!children.length) {
				container.appendChild(E('a', { href: L.url('admin', group.name), class: 'console-nav-heading' + (active ? ' active' : ''), 'aria-current': active ? 'page' : null }, [ icon(group.name), title ]));
				continue;
			}
			const details = E('details', { class: 'console-nav-group', open: active || null }, [
				E('summary', { class: 'console-nav-heading' }, [ icon(group.name), E('span', {}, title), E('span', { class: 'console-chevron', 'aria-hidden': 'true' }, '›') ]),
				E('div', { class: 'console-nav-list' }, children.flatMap(child => {
					const grandchildren = ui.menu.getChildren(child).filter(node => !!node.title);
					const childActive = active && current[2] === child.name;
					// 只高亮最具体的一层：有三级被选中时父级不再高亮，避免两条高亮条并排。
					const grandchildActive = grandchildren.filter(node => current[3] === node.name)[0];
					const link = E('a', {
						href: L.url('admin', group.name, child.name),
						class: 'console-nav-link' + (childActive && !grandchildActive ? ' active' : ''),
						'aria-current': childActive && !grandchildActive ? 'page' : null
					}, _(child.title));
					if (!grandchildren.length) return [ link ];
					// 三级页面（例如「分流设置」下的多线负载等）直接展开在侧栏里，
					// 与一级/二级链接同处一个可折叠组，避免用户必须先点二级才知道有哪些页面。
					return [ link ].concat(grandchildren.map(grandchild => E('a', {
						href: L.url('admin', group.name, child.name, grandchild.name),
						class: 'console-nav-link console-nav-sublink' + (childActive && current[3] === grandchild.name ? ' active' : ''),
						'aria-current': childActive && current[3] === grandchild.name ? 'page' : null,
						style: 'margin-left:30px;padding-left:22px;font-size:13px;min-height:34px'
					}, _(grandchild.title))));
				}))
			]);
			container.appendChild(details);
		}
		let node = tree, url = '';
		for (let i = 0; i < 3 && node; i++) {
			node = node.children && node.children[L.env.dispatchpath[i]];
			url += (url ? '/' : '') + L.env.dispatchpath[i];
		}
		if (node) this.renderTabs(node, url, 0);
	},

	renderTabs(node, url, level) {
		const container = document.querySelector('#tabmenu');
		const children = ui.menu.getChildren(node).filter(node => !!node.title);
		if (!container || !children.length) return;
		const list = E('ul', { class: 'tabs' });
		let selected = null;
		children.forEach(child => {
			const active = L.env.dispatchpath[3 + level] === child.name;
			if (active) selected = child;
			list.appendChild(E('li', { class: active ? 'active' : '' }, E('a', { href: L.url(url, child.name) }, _(child.title))));
		});
		container.appendChild(list);
		container.style.display = '';
		if (selected) this.renderTabs(selected, url + '/' + selected.name, level + 1);
	}
});
