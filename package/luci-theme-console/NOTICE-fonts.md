# 字体说明

## DINPro-*.otf

`htdocs/luci-static/console/fonts/` 下的 `DINPro-Regular.otf` / `DINPro-Medium.otf` /
`DINPro-Bold.otf` 是 Monotype 的 DIN Pro 字面，属**商业字体**，不是自由许可字体。

它们由本项目作者在开发环境自行取得并使用。本仓库公开分发时携带这三个文件，
**不代表**授予任何再分发或商用许可。若你 fork 或再分发本仓库，请自行确认字体授权，
或用以下任一方式替换：

1. 删除这三个文件与 `console-system.css` 顶部的三段 `@font-face`，回退到
   `--console-font-sans` 的字体栈（该栈本身已包含系统字体，缺字体不影响功能与版式）；
2. 换成 OFL 许可的等效数字字体（如 Archivo、Barlow、Roboto Condensed）。

## 安装器字体

`.dsh/skills/openwrt-installer-image/assets/` 下的 `installer-console.psf` 与
`installer-grub.pf2` 分别由 Unifont 与 GNU Unifont 子集生成，许可文本见同目录
`installer-font-LICENSE.txt`、`installer-grub-LICENSE.txt`。
