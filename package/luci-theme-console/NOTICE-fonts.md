# 字体说明

## 思源黑体 / Source Han Sans SC

控制台的正文和数字统一使用 Adobe 官方思源黑体简体中文可变字体，字重范围 250–900；字体在本机提供，不依赖外部字体服务。加载期间保留系统字体回退。

- 文件：`htdocs/luci-static/console/fonts/SourceHanSansSC-VF.otf.woff2`
- 上游：<https://github.com/adobe-fonts/source-han-sans>
- 固定版本：`a4f7cf94edfb9d7ffbdfc4841de276358bd7e0f2`，`Variable/WOFF2/OTF/SourceHanSansSC-VF.otf.woff2`
- 许可：SIL Open Font License 1.1，原文随字体保存在 `fonts/LICENSE.txt`。
- SHA-256：`085cc88c530b9c434165ab926f81608a55b24e60e05719f3d41340ac45d9c62f`。
- 字体文件直接来自上游，未裁剪、改名或修改内部字体数据。原 DINPro 三份字体已移除。

## 安装器字体

安装器的 Linux console PSF 和 GRUB PF2 为不同格式，继续使用现有字库，不受网页字体替换影响。
`installer-console.psf` 来自 Noto Sans CJK SC，`installer-grub.pf2` 来自 GNU Unifont；实际来源、校验值和许可见 `.dsh/skills/openwrt-installer-image/assets/README.md` 及随附的 `*-LICENSE.txt`。
