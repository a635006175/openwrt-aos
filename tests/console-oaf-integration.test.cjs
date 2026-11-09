// SPDX-License-Identifier: Apache-2.0
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const read = name => fs.readFileSync(path.join(root, name), 'utf8');
test('behavior menu remains hidden without the OAF service and routes to upstream management pages', () => {
  const menu = JSON.parse(read('package/luci-app-console/root/usr/share/luci/menu.d/luci-app-console-oaf.json'));
  assert.equal(menu['admin/behavior'].title, '行为管理');
  for (const [name, entry] of Object.entries(menu)) {
    assert.equal(entry.depends.fs['/usr/bin/oafd'], 'executable', name);
    assert.equal(entry.depends.fs['/etc/config/fwx'], 'file', name);
    assert.deepEqual(entry.depends.acl, ['oaf'], name);
    if (name !== 'admin/behavior') assert.match(entry.action.path, /^admin\/services\/oaf\//);
  }
});
test('first generated OAF configuration does not enable filtering', () => {
  const init = read('package/OpenAppFilter/open-app-filter/files/appfilter.init');
  for (const section of ['appfilter appfilter', 'macfilter macfilter'])
    assert.match(init, new RegExp('config ' + section + '\\s+option enable 0'));
  assert.match(init, /config global 'global'\s+option enable '0'/);
});
test('OAF mixed read/write ubus method is not granted as read-only', () => {
  const acl = JSON.parse(read('package/OpenAppFilter/open-app-filter/files/luci-app-oaf.json')).oaf;
  assert.equal(acl.read.ubus?.fwx?.includes('common') || false, false);
  assert.ok(acl.write.ubus.fwx.includes('common'));
});
test('OAF mutation routes require POST and explicit write authorization', () => {
  const dir = path.join(root, 'package/OpenAppFilter/luci-app-oaf/luasrc/controller');
  let count = 0;
  for (const file of fs.readdirSync(dir).filter(name => name.endsWith('.lua'))) {
    const text = fs.readFileSync(path.join(dir, file), 'utf8');
    assert.doesNotMatch(text, /call\("(?:add_|del_|delete_|update_|set_|start_|record_action)[A-Za-z0-9_]*"\)/, file);
    for (const match of text.matchAll(/post\("((?:add_|del_|delete_|update_|set_|start_|record_action)[A-Za-z0-9_]*)"\)/g)) {
      assert.match(text, new RegExp('function ' + match[1] + '\\(\\)\\s+if not require\\("luci\\.oaf_guard"\\)\\.check\\(\\) then return end'), file + ':' + match[1]);
      count++;
    }
  }
  assert.ok(count > 25);
});
test('jQuery mutation requests add the LuCI CSRF token without replacing feature keys', () => {
  const vm = require('node:vm');
  let filter;
  const context = {window:{jQuery:{ajaxPrefilter: fn => {filter = fn;}}, L:{}}, L:{env:{token:'session-token'}}, FormData: class FormData {}};
  vm.runInNewContext(read('package/OpenAppFilter/luci-app-oaf/htdocs/luci-static/resources/oaf/console-security.js'), context);
  const request = {type:'POST',url:'/cgi-bin/luci/admin/services/oaf/feature/online_save',data:'feature_token=example'};
  filter(request);
  assert.equal(request.data, 'feature_token=example&token=session-token');
  const unrelated = {type:'POST',url:'/cgi-bin/luci/admin/network/elsewhere',data:'data=1'};
  filter(unrelated);
  assert.equal(unrelated.data, 'data=1');
});
