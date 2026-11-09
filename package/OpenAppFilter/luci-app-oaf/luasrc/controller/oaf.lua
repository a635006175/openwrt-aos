module("luci.controller.oaf", package.seeall)

function index()
    local page = entry({"admin", "services", "oaf"}, firstchild(), _("Parental Control"), 20)
    page.dependent = true
    page.acl_depends = { "oaf" }
end
