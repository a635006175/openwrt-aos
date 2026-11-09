-- SPDX-License-Identifier: GPL-2.0-only
-- The upstream common ubus method contains both queries and configuration changes.
local M = {}
function M.check()
    local util = require "luci.util"
    local dispatcher = require "luci.dispatcher"
    local result = util.ubus("session", "access", {
        ubus_rpc_session = dispatcher.context.authsession,
        scope = "uci", object = "fwx", ["function"] = "write"
    })
    if type(result) == "table" and result.access == true then return true end
    require("luci.http").status(403, "Forbidden")
    return false
end
return M
