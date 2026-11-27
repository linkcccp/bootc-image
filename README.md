# bootc-image

基于 [Bazzite DX](https://github.com/ublue-os/bazzite)（KDE + NVIDIA open 内核模块）的个人
bootc 镜像，按 [ublue-os/image-template](https://github.com/ublue-os/image-template) 的官方结构维护。

仓库只做一层薄定制：桌面、内核、驱动、Flatpak、更新器全部跟随基座，出问题先怀疑基座还是这里
改的那几块。切换 / 回滚 / 升级都走 bootc，不重装系统。

```dockerfile
FROM ghcr.io/ublue-os/bazzite-dx-nvidia:latest
```

| 由基座提供 | 由本仓库提供 |
| --- | --- |
| KDE Plasma（Kinoite 基础）、NVIDIA open 驱动与 kargs | 中文语言包 + fcitx5 输入法 |
| flatpak / Flathub、podman、distrobox、brew | Clash Verge Rev（GUI + TUN） |
| VS Code、Docker CE、incus/libvirt、Cockpit（DX 变体） | v2rayA（Web UI + 内置核心） |
| uupd 自动更新、Secure Boot 签名链路 | NVIDIA 插电锁频、字体、KDE 主题、Vimix GRUB 主题 |

## 目录结构（官方约定）

| 路径 | 作用 |
| --- | --- |
| `Containerfile` | 只负责选基座、把 `build_files/` + `system_files/` 交给 `build.sh`、跑 `bootc container lint` |
| `build_files/build.sh` | 所有安装与生成逻辑（按编号分 6 节） |
| `build_files/VERSION` | **自己的**语义化版本，改功能/有破坏性变更时 bump |
| `system_files/` | 静态文件，构建时原样复制到 `/`（含 GRUB 主题与资产库） |
| `Justfile` | 本地与 CI 的统一入口（`just build` / `build-qcow2` / `run-vm-*` …） |
| `image-template.env` | 项目身份：`IMAGE_NAME` / `REPO_ORGANIZATION` / 描述 / `DEFAULT_TAG` |
| `disk_config/` | `disk.toml`（qcow2）、`iso.toml`（anaconda ISO，kickstart 指向本镜像） |
| `.github/workflows/` | `build.yml`（构建 + 推送 + 签名）、`build-disk.yml`（qcow2 / ISO） |

## 镜像里加了什么

### 1. 中文

- `langpacks-zh_CN` + `glibc-langpack-zh`（bootc 上无法事后用 PackageKit 补语言包）
- `fcitx5` 全套；**关掉它的 XDG 自启动**，改由 KWin 的 `[Wayland] InputMethod` 拉起
  （两个实例会抢 D-Bus 名字，后启动的抢不到会卸载全部 addon，表现为「输入法在但打不出字」）
- `$HOME` 目录固定英文名（`user-dirs.conf` + `skel/.config/user-dirs.dirs`）

### 2. 代理

- **Clash Verge Rev**：只装 rpm，不 enable 服务；首次在 GUI 开 TUN 时按提示装一次
  `clash-verge-service`，装进可写层，升级不丢
- **v2rayA**：官方 redhat rpm（主程序 + 配套 `v2raya_core` + geo 数据），Web UI 在
  `http://127.0.0.1:2017`。**服务默认不自启**，按需启动：

  ```sh
  sudo systemctl start v2raya     # 本次开机使用
  sudo systemctl enable --now v2raya   # 想让它开机自启
  ```

> 两个客户端不要同时开 TUN。

### 3. NVIDIA 插电锁频

`udev` 在电源状态变化时拉起 oneshot：插电把核心频率下限固定为当前最大值（`nvidia-smi -lgc`），
电池恢复默认（`-rgc`）。关闭：`sudo systemctl disable --now nvidia-clock-ac.service`。

### 4. 外观

字体 `Maple Mono Normal NF CN` / `JetBrains Mono Nerd Font`，主题 `Fluent Light` + `Fluent11` 图标，
均装进 `/usr/share`，系统级默认值写 `/etc/xdg/{kdeglobals,plasmarc,kwinrc}`，用户可在 `~/.config` 覆盖。

### 5. GRUB

Vimix 4K 主题。bootc 里 `/boot` 是独立分区、镜像内的 `/boot` 会被 mask，所以主题放
`/usr/share/grub/themes/vimix`，由 `grub-theme-sync.service` 在启动后同步进 `/boot` 并重生成
`grub.cfg`（第二次启动起可见）。`/usr/share/grub/grub2-themes` 是上游完整资产库（684 图标 /
20 背景 / 13 字体 / 5 布局），换配色见其中的 `README.md`。

## 版本号

```
45.20261125.0 . v0.1.0 . t3
└─ 上游管系统 ┘ └你管功能┘ └ 同版本内的重建 ┘
```

| 段 | 来源 | 什么时候变 |
| --- | --- | --- |
| `45.20261125.0` | 基座 `/usr/lib/os-release` 的 `OSTREE_VERSION`（bazzite 用它；aurora 用 `IMAGE_VERSION`，代码会自动回退） | 基座发新构建（基本每天） |
| `v0.1.0` | `build_files/VERSION`，手动维护 | 你改功能 / 有破坏性变更时 bump |
| `t3` | 查 registry 上同版本元组已有的 `.tN` tag，取 `max+1` | 每次构建 +1；前两段一变自动回到 `t1` |

写入位置（三处同源、互相校验）：

- OCI label `org.opencontainers.image.version` → `bootc status` 的 `Version`
- `/usr/lib/os-release` 的 `VERSION` / `PRETTY_NAME` / `OSTREE_VERSION` / `BUILD_ID` /
  `BOOTLOADER_NAME` → GRUB 标题、`hostnamectl`、fastfetch、KDE「关于」
- `/usr/share/ublue-os/image-info.json` 的 `version` / `version-pretty`
- 上游版本另存一份到 `/usr/share/bootc-image/upstream-version`

`build.sh` 会独立推导一遍再和 `just build` 传入的值对账，不一致直接构建失败——避免
`bootc status` 与 GRUB 标题显示的版本不是同一个。

切到某个具体构建：

```sh
sudo bootc switch ghcr.io/linkcccp/bootc-image:45.20261125.0.v0.1.0.t3
```

> 版本 tag 会累积（约每天一个）。要清理时可删掉旧的 `.tN`，不影响已部署机器（它们按 digest 走）。

## 构建

```sh
git lfs install && git lfs pull   # GRUB 资产在 Git LFS 里，缺这一步 build.sh 会直接报错
just build                        # 推荐：自动算版本、传 label、写 output.env
```

不用 `just` 时：

```sh
podman build -t ghcr.io/linkcccp/bootc-image:latest .
# 此时没有版本参数，os-release 用推导值，OCI label 为 dev
```

校验：`just check`（Justfile 语法）。镜像自检由 `build.sh` 末尾的断言 + `bootc container lint` 完成。

## 更新与回滚

| 操作 | 命令 |
| --- | --- |
| 自动更新 | 基座自带 `uupd.timer`，按当前 ref 自动 `bootc upgrade` |
| 手动更新 | `sudo bootc upgrade` |
| 立即生效 | `sudo systemctl reboot` |
| 回滚 | `sudo bootc rollback` |

构建期的升级策略是**跟随基座**：本仓库不跑 `dnf upgrade`，系统包版本由基座每天的新构建带来；
我们自己装的包（fcitx5、clash、v2rayA…）在每次构建时按当时仓库的最新版本安装。个别包需要提前修时，
在 `build.sh` 里精准升级即可（例如 `dnf5 upgrade -y --refresh openssl-libs`）。

## CI

| 工作流 | 触发 | 产物 |
| --- | --- | --- |
| `build.yml` | push 到 `main`、每天 10:05 UTC、手动、PR（仅验证） | 推送 `ghcr.io/linkcccp/bootc-image`（`latest` + 日期/sha 别名 + 版本 tag），并用 cosign 签名 |
| `build-disk.yml` | 手动（可选上传 S3） | qcow2 + anaconda ISO（kickstart 装完后 `bootc switch` 到本镜像） |

- 签名需要仓库 secret `SIGNING_SECRET`（cosign 私钥，**必须空密码**，workflow 不提供 `COSIGN_PASSWORD`）
- 验证签名（公钥 `cosign.pub` 随仓库分发）：

  ```sh
  cosign verify --key cosign.pub ghcr.io/linkcccp/bootc-image:latest
  ```

- `build.yml` 的 checkout 必须保留 `lfs: true`，否则 GRUB 资源会以 LFS 指针形式进入镜像
- rechunk（`rpm-ostree compose build-chunked-oci`）固定产出 gzip 层，推送时会用 `podman push --compression-format=zstd --force-compression` 重压成 zstd，与上游基座一致、体积更小
- ISO 构建用的是 registry 上的 `:latest`，所以先让 `build.yml` 成功推送过一次

## 开机后要做的三件事

1. **输入法**：系统设置 → 输入法 → 添加「拼音（Fcitx 5）」
2. **Clash**：打开 Clash Verge Rev → 导入订阅 → 开 TUN 时按提示装一次服务
3. **v2rayA**：`sudo systemctl start v2raya` → 浏览器打开 `http://127.0.0.1:2017` → 创建管理员 → 导入订阅

自检：

```sh
bootc status
systemctl status nvidia-clock-ac
systemctl is-enabled v2raya        # 应为 disabled（按需手动 start）
rpm -q fcitx5 fcitx5-chinese-addons langpacks-zh_CN
fc-match "Maple Mono Normal NF CN"
ls /usr/share/plasma/desktoptheme/Fluent-light
```

## 已知限制

- 本机构建若算出序号但没推送，下次 CI 可能复用同一个 `.tN`（版本号相同、内容不同）
- 版本 tag 目前不自动清理
- `system_files/etc/default/grub` 会整体覆盖基座同名文件（`GRUB_CMDLINE_LINUX="rhgb quiet"`）；
  内核参数实际由 bootc 的 kargs 机制管理，不受影响
