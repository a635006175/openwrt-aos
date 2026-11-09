// SPDX-License-Identifier: Apache-2.0
'use strict';
'require baseclass';

function decorate(definition) {
	for (const name of ['submit', 'save', 'apply', 'disconnect', 'reconnect']) {
		const original = definition[name];
		if (typeof original !== 'function') continue;
		definition[name] = function(...args) {
			if (this.actionPending) return this.actionPending;
			const buttons = Array.from(document.querySelectorAll('button.cbi-button'));
			const states = buttons.map(button => button.disabled);
			const trigger = document.activeElement;
			const notice = document.createElement('span');
			notice.textContent = ' · 处理中…';
			notice.setAttribute('role', 'status');
			if (buttons.includes(trigger)) { trigger.append(notice); trigger.setAttribute('aria-busy', 'true'); }
			buttons.forEach(button => { button.disabled = true; });
			this.actionPending = Promise.resolve().then(() => original.apply(this, args)).finally(() => {
				notice.remove();
				if (trigger && buttons.includes(trigger)) trigger.removeAttribute('aria-busy');
				buttons.forEach((button, index) => { if (button.isConnected) button.disabled = states[index]; });
				this.actionPending = null;
			});
			return this.actionPending;
		};
	}
	return definition;
}

return baseclass.extend({ decorate });
