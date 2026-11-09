# OpenAppFilter 特征库扩充与安装说明

## 1. 问题结论

内置 `feature.bin` 只有 **48 个应用特征**（version `26.01.01`），确实是精简的占位库。

**这不是软件限制，而是随包发布的免费样例库太小。** 上游 OAF 本身支持 1024 个应用、16 个分类，只是默认没带全。

## 2. 可安装的特征库来源

OAF 的特征库在线服务 `https://api.openappfilter.com` 是开放的，无需注册即可列出与下载**免费版**：

| 包 ID | 版本 | 类型 | 应用数 | 大小 | 是否免费 |
|---|---|---|---|---|---|
| 2610081 | 26.10.08 | Lite | 560 | 12 KB | ❌ 需订阅 |
| 2609071 | 26.09.07 | Lite | 559 | 12 KB | ❌ 需订阅 |
| 2608031 | 26.08.03 | Lite | 553 | 12 KB | ❌ 需订阅 |
| 2608032 | 26.08.03 | Lite | 427 | 12 KB | ❌ 需订阅 |
| **2609101** | **26.09.10** | **Lite** | **358** | **1.2 MB** | ✅ **免费** |
| 2606101 | 26.06.10 | Lite | 311 | 1.2 MB | ✅ 免费 |

官方公告原文：*「注意 Lite 为精简版本，支持最热门的应用，Plus 版本支持的应用更多。」*

**免费版与付费版的差别**：免费 Lite 为 **358 项**（中文分类，含 507 个应用图标）；付费 Plus（需订阅 key）可达 **560 项**。相对内置的 48 项，免费版已经是 **7.5 倍**。

## 3. 已完成的安装（实机 192.168.1.1）

已安装 id `2609101`（version `26.09.10`，免费 Lite）：

| 项目 | 安装前 | 安装后 |
|---|---|---|
| feature.bin 大小 | 2385 B | 18499 B |
| md5 | `457babb1…` | `01602a7c…` |
| 特征库版本 | 26.01.01 | **26.09.10** |
| 应用数 | **48** | **358** |
| 分类数 | 7 | **12** |
| 应用图标 | 1（仅 default） | **507** |

分类分布：聊天 11、游戏 64、视频 57、购物 41、音乐 12、招聘 13、下载 30、常用网站 67、教育 5、生活 28、工具 3、金融 27。

**验证结果**（`ubus call fwx common '{"api":"get_feature_info"}'`）：

```json
{"loaded":1,"version":"26.09.10","type":0,"free":1,"format":"v4.0","app_count":358}
```

服务 `running`，`oafd` + `rule_manager` 双进程正常，内核模块 `oaf` 已加载。

## 4. 安装方法（两种）

### 方法 A：网页直接安装（推荐，无需命令行）

登录 LuCI → **行为管理 → 特征库 → 在线升级** 标签页：

1. 点「更新列表」获取最新可用版本
2. 在列表中点击免费版（标 `Free`）那一行的「切换」
3. 等待下载→校验→应用完成

设备本身能直连 `api.openappfilter.com`（已实测 HTTP 200），**不需要**在路由器上配置代理。免费版不需要填订阅 key。

> ⚠️ 注意：付费版（Plus）需要订阅 key，无 key 时接口返回 `50003 subscription feature manifest unavailable`。

### 方法 B：命令行离线安装

已在实机验证通过的完整流程：

```sh
# 1. 备份现有特征库（务必先做，设备上原本没有 .bak）
cp -p /etc/fwxd/feature.bin /etc/fwxd/feature.bin.bak

# 2. 下载免费特征库包（device_id 由 br-lan MAC 决定，可留空）
cd /tmp && rm -rf oaf-dl && mkdir oaf-dl && cd oaf-dl
wget -O pkg.tar.gz \
  'https://api.openappfilter.com/api/download_feature?token=&device_id=&model=&version=v4.0&lang=cn&id=2609101'

# 3. 校验（官方值 3d6eade2d53c15b232433d052e07e6f6）
md5sum pkg.tar.gz

# 4. 解包并安装
tar xzf pkg.tar.gz
cp feature.bin /etc/fwxd/feature.bin && chmod 644 /etc/fwxd/feature.bin
cp -f app_icons/*.png /www/luci-static/resources/oaf/app_icons/

# 5. 重启服务使新库生效
/etc/init.d/appfilter restart

# 6. 验证
ubus call fwx common '{"api":"get_feature_info"}'
```

### 回滚

```sh
cp -p /etc/fwxd/feature.bin.bak /etc/fwxd/feature.bin
/etc/init.d/appfilter restart
```

## 5. 已同步到源码树

`package/OpenAppFilter/open-app-filter/files/feature.bin` 已替换为增强版（18499 B，md5 `01602a7c…`）。

该路径被 `open-app-filter/Makefile:52` 打包：

```makefile
$(INSTALL_DATA) ./files/feature.bin $(1)/etc/fwxd/feature.bin
```

因此**下次编译固件时新特征库会自动打进包里**，无需额外操作。

> 注：图标（507 个 PNG，约 2 MB）未放进源码树。若希望固件自带图标，需在 Makefile 中增加 `app_icons/` 的安装规则。

## 6. 容量上限（自行验证于源码）

| 限制项 | 值 | 出处 |
|---|---|---|
| 应用总数 | 1024 | `open-app-filter/src/fwx_config.h:10` |
| 分类数 | 16 | `open-app-filter/src/fwx_user.h:18` |
| 每应用特征数 | 16 | `oaf/src/fwx.h:29` |
| 单条特征串长度 | 128 | `oaf/src/fwx.h:31` |
| 单行特征长度 | 800 | `oaf/src/fwx.h:36` |
| host/request URL | 128 | `oaf/src/fwx.h:32-33` |
| 特征库文件上限 | 20 MB | `open-app-filter/src/fwx_feature.h:14` |
| 自定义应用 id 后缀 | 900–999 | `open-app-filter/src/fwx_custom_feature.c:18-19` |

免费 Lite 库实测：最长行 346 字符、最长特征串 54 字符，**远低于上限**。

## 7. 特征库文件格式（供自行扩充）

文件为加密二进制（magic `FWXB`，v1，XTEA-CTR），解密后是文本：

```
#version 26.09.10
#format v4.0
#type 0
#free 1
#class chat 1 聊天
1002~微信:[tcp;;;weixin.qq;;,tcp;;443;;;05:2f|06:6d]
1005~支付宝:[tcp;;;alipay.com;;,udp;;1100-1200;;;00:00|01:01|02:00]
```

- `#class <名称> <ID> <显示名>` — 分类声明
- `<appid>~<应用名>:[特征1,特征2,...]` — 应用行
- 特征格式：`proto;sport;dport;host url;request;dict;search str;ignore`
- `appid/1000` = 分类号，`appid%1000` = 应用在分类内的编号
- 应用名最多 63 字节，不能含 `:~[];,`

**辅助脚本**（已在本工作区 `tmp/` 下）：

- `oaf_feature_tool.py` — 解密 / 打包 `feature.bin`（`dump` / `info` / `pack`）
- `validate_feature.py` — 按上述所有上限校验明文特征库

## 8. 已知限制与注意事项

1. **`/` 是 ext4 裸盘**，没有 overlay 保护，无法用 firstboot 回滚 —— 改动前必须手动备份。
2. **图标会随内核/服务重装被清空**：`install_icons()` 依赖 `statvfs("/overlay")`，本机 `/overlay` 是空目录不在独立分区上，但实测服务重启后图标可保留；若重装 appfilter 包需重新拷贝图标。
3. **`device_id` 是实时算的**：`md5(小写 br-lan MAC 去掉冒号)`。换网卡或改 MAC 会导致付费订阅授权失效。
4. **仅识别一个接口**：当前 `fwx.global.lan_ifname='br-lan'`，其他 LAN 口与 VPN 客户端不受保护。
5. **日志里有活跃异常**：`oafd` 每约 3 分钟报 `Command failed: Not found`，疑似调用不存在的 shell 命令，与本特征库无关，尚未定位。
6. 免费 Lite **无「教育」以外的部分英文库**，`lang=en` 列表为空属正常。

## 9. 下一步可选增强

- **订阅 Plus**：付费可达 560 项，是免费用量的 1.5 倍，也是官方最新数据（`26.10.08`）。
- **自建自定义特征**：LuCI「特征库 → 自定义应用」可直接加应用，会追加到 `/etc/fwxd/custom_feature.cfg`，与内置库并行生效，无需重新打包。
- **固件内置图标**：在 `open-app-filter/Makefile` 增加 `app_icons` 安装规则。
