#!/bin/bash

set -ouex pipefail

# Copy the contents of system_files/ of the git repo to /
cp -avf "/ctx/system_files"/. /

### [IM]MUTABLE /opt
## bootc 里 /opt 指向 /var/opt，而构建阶段 /var 是 tmpfs：换成真实目录，避免第三方包
## 把内容写进会被丢弃的路径（google-chrome、docker-desktop 等）。
mkdir -p /var/roothome
if [ -L /opt ]; then
    rm /opt
    mkdir -p /opt
fi

### Base

systemctl enable podman.socket

# ---------------------------------------------------------------------------
# 1. 中文环境
# ---------------------------------------------------------------------------
# bootc 上没法用 PackageKit 事后补语言包，glibc 的 zh_CN locale 和中文本地化
# 必须在构建期装进 /usr。
dnf5 install -y \
    langpacks-zh_CN \
    fcitx5 \
    fcitx5-autostart \
    fcitx5-chinese-addons \
    fcitx5-configtool \
    fcitx5-gtk \
    fcitx5-qt

if ! dnf5 install -y glibc-langpack-zh; then
    echo "glibc-langpack-zh 不存在，回退到 glibc-all-langpacks"
    dnf5 install -y glibc-all-langpacks
fi
dnf5 clean all
locale -a | grep -qx 'zh_CN.utf8'

# system_files 的复制发生在装包之前，而 fcitx5-autostart 自带同名 desktop 文件，
# rpm 会把它覆盖回 Hidden=false，所以装完包再落一次。
install -Dm644 /ctx/system_files/etc/xdg/autostart/org.fcitx.Fcitx5.desktop \
    /etc/xdg/autostart/org.fcitx.Fcitx5.desktop

# fcitx5-autostart 的 XDG 自启动（Hidden=true，见 system_files）会和 kwinrc 的
# [Wayland] InputMethod 重复拉起 fcitx5：后启动的实例抢不到 D-Bus 名字会卸载全部
# addon，表现为「输入法在但打不出字」。所以只留 KWin 这条路。
# InputMethod 也是 Plasma 6 启用 text-input-v3 的条件，否则原生 Wayland 应用
# （Plasma 本体、KRunner）打不出中文。
kwriteconfig6 --file /etc/xdg/kwinrc --group Wayland --key InputMethod \
    /usr/share/applications/org.fcitx.Fcitx5.desktop

# 中文 locale 下固定 $HOME 目录为英文名（user-dirs.conf / user-dirs.dirs 由
# system_files 提供），这里只补出目录本身。
install -d -m 0755 \
    /etc/skel/Desktop /etc/skel/Downloads /etc/skel/Templates \
    /etc/skel/Public /etc/skel/Documents /etc/skel/Music \
    /etc/skel/Pictures /etc/skel/Videos /etc/skel/Projects

# ---------------------------------------------------------------------------
# 2. 代理
# ---------------------------------------------------------------------------
# Clash Verge Rev：Tauri GUI + clash-verge-service（TUN 模式的特权 helper）。
# 上游只发 GitHub Release 的 rpm；CI 传入 URL，本地构建回退到 GitHub API。
#
# 注意：2.5.x 起 rpm **不再自带 systemd 单元**，只带 clash-verge-service-install。
# 该安装器会把服务二进制复制到 /var/lib/clash-verge-service/ 并把单元写进
# /etc/systemd/system/，两者在构建阶段（/var 是 tmpfs）都必须避免，所以这里
# 只安装、不 enable：首次在 GUI 里开 TUN 时它会提示安装服务，点一次即可，
# 装出来的东西落在可写层，bootc 升级不会丢。
dnf5 install -y curl jq

url="${CLASH_VERGE_RPM_URL:-}"
if [ -z "$url" ]; then
    url="$(curl -fsSL --retry 3 --retry-all-errors \
        -H 'Accept: application/vnd.github+json' \
        https://api.github.com/repos/clash-verge-rev/clash-verge-rev/releases/latest |
        jq -er '[.assets[] | select(.name | test("\\.(x86_64|amd64|x64)\\.rpm$"; "i"))][0].browser_download_url')"
fi
if [ -z "$url" ]; then
    echo "无法解析 Clash Verge rpm 地址（匿名 GitHub API 可能被限流？可通过 CLASH_VERGE_RPM_URL 传入）" >&2
    exit 1
fi
curl -fsSL --retry 3 --retry-all-errors -o /tmp/clash-verge.rpm "$url"
dnf5 install -y /tmp/clash-verge.rpm
rm -f /tmp/clash-verge.rpm
dnf5 clean all
test -x /usr/bin/clash-verge-service
test -x /usr/bin/clash-verge-service-install
test -n "$(find /usr/share/applications -maxdepth 1 -iname '*clash*' -print -quit)"

# v2rayA：Web UI + 系统服务，支持 vmess/vless/trojan/ss，订阅可直接导入。
# 2.5.x 起核心私有化为 v2raya_core（xray fork），版本必须与主程序完全一致，
# 否则启动即报 CORE_VERSION_MISMATCH。官方 redhat rpm 里主程序、配套核心、
# systemd 单元和 /usr/share/v2raya/{geoip,geosite}.dat 齐全，且依赖只有
# rpmlib(...)，不需要 Fedora 仓库里没有的 v2ray/xray 包，所以直接装它。
# CI 传入经认证 API 解析出的 rpm 地址；本地构建回退到公开 API（可能撞限流）。
dnf5 install -y nftables iproute

arch="${TARGETARCH:-}"
if [ -z "$arch" ]; then
    case "$(uname -m)" in
        x86_64) arch=amd64 ;;
        aarch64) arch=arm64 ;;
        *) arch="$(uname -m)" ;;
    esac
fi
case "$arch" in
    amd64) rpmarch=x64 ;;
    arm64) rpmarch=arm64 ;;
    *)
        echo "v2rayA rpm 不支持的架构：$arch" >&2
        exit 1
        ;;
esac

url="${V2RAYA_RPM_URL:-}"
if [ -z "$url" ]; then
    tag="$(curl -fsSL --retry 3 --retry-all-errors \
        -H 'Accept: application/vnd.github+json' \
        https://api.github.com/repos/v2rayA/v2rayA/releases/latest | jq -er .tag_name)"
    ver="${tag#v}"
    url="https://github.com/v2rayA/v2rayA/releases/download/${tag}/installer_redhat_${rpmarch}_${ver}.rpm"
fi
if [ -z "$url" ]; then
    echo "无法解析 v2rayA rpm 地址（匿名 GitHub API 可能被限流？可通过 V2RAYA_RPM_URL 传入）" >&2
    exit 1
fi
curl -fsSL --retry 3 --retry-all-errors -o /tmp/v2raya.rpm "$url"
dnf5 install -y /tmp/v2raya.rpm
rm -f /tmp/v2raya.rpm
test -x /usr/bin/v2raya
test -x /usr/bin/v2raya_core
test -f /usr/share/v2raya/geoip.dat
test -f /usr/lib/systemd/system/v2raya.service
dnf5 clean all
# 不 enable：代理服务默认不自启（用户按需 `systemctl start v2raya`）。
# 这里显式 disable 一次，保证即使上游 rpm 以后开始 enable 也不会带起来。
systemctl disable v2raya.service

# ---------------------------------------------------------------------------
# 3. NVIDIA 锁频
# ---------------------------------------------------------------------------
# udev 规则在电源状态变化时拉起这个 oneshot：插电时把核心频率锁定在显卡最大
# 频率的 40% 到最大值之间（nvidia-smi -lgc），切到电池时恢复默认（nvidia-smi -rgc）。
# 台式机没有 Mains 设备，开机即生效。
# nvidia-powerd 由基座的 nvidia 变体提供；脚本/单元/规则由 system_files 提供。
chmod 0755 /usr/libexec/nvidia-clock-ac
systemctl enable nvidia-clock-ac.service
udevadm verify /usr/lib/udev/rules.d/90-nvidia-ac-clock.rules
test -x /usr/libexec/nvidia-clock-ac
test -L /etc/systemd/system/multi-user.target.wants/nvidia-clock-ac.service

# ---------------------------------------------------------------------------
# 4. 字体与主题（系统级，装进 /usr/share，所有用户共享，无需手动执行）
# ---------------------------------------------------------------------------
# Maple Mono Normal NF CN：等宽 + 中文字形（OFL）。
dnf5 install -y unzip gtk-update-icon-cache
curl -fsSL --retry 3 --retry-all-errors -o /tmp/maple.zip \
    https://github.com/subframe7536/maple-font/releases/download/v7.9/MapleMonoNormal-NF-CN.zip
printf '%s  %s\n' \
    24aeb14ed756d78b112e6692ea02c669e16afaa0f01e7bfdbb37d2e63fa45fa7 \
    /tmp/maple.zip | sha256sum -c -
install -d /usr/share/fonts/maple-mono /usr/share/licenses/maple-font
unzip -q -j /tmp/maple.zip \
    MapleMonoNormal-NF-CN-Regular.ttf \
    MapleMonoNormal-NF-CN-Bold.ttf \
    MapleMonoNormal-NF-CN-Italic.ttf \
    MapleMonoNormal-NF-CN-BoldItalic.ttf \
    -d /usr/share/fonts/maple-mono
unzip -p /tmp/maple.zip LICENSE.txt > /usr/share/licenses/maple-font/LICENSE.txt
rm -f /tmp/maple.zip

# JetBrains Mono Nerd Font：全部变体。
install -d /usr/share/fonts/nerd-fonts/JetBrainsMono
curl -fsSL --retry 3 --retry-all-errors -o /tmp/jbmono.zip \
    https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.zip
unzip -q -j -o /tmp/jbmono.zip '*.ttf' -d /usr/share/fonts/nerd-fonts/JetBrainsMono
rm -f /tmp/jbmono.zip
fc-cache -f /usr/share/fonts

# Fluent Light Plasma 主题 + Fluent11 图标。
# install.sh 检测到 root 时会自动装进 /usr/share/{aurorae,plasma,color-schemes}，
# 正是我们要的系统级位置，不需要额外的 --dest。
install -d /tmp/fluent-kde
curl -fsSL --retry 3 --retry-all-errors \
    https://github.com/vinceliuice/Fluent-kde/archive/44794f29c89de994b0179aebabd2f5776c90d236.tar.gz |
    tar -xz --strip-components=1 -C /tmp/fluent-kde
(cd /tmp/fluent-kde && bash ./install.sh --theme default --color light)
install -D -m 0644 /tmp/fluent-kde/LICENSE /usr/share/licenses/fluent-kde/LICENSE
rm -rf /tmp/fluent-kde /root/.config/Kvantum
rm -f /root/.Xresources
install -d /tmp/fluent11
curl -fsSL --retry 3 --retry-all-errors \
    https://github.com/luisrguerra/fluent11-icon-theme/archive/11c74905bc51be17f1e5b65fc46c02d6c6280577.tar.gz |
    tar -xz --strip-components=1 -C /tmp/fluent11
cp -a /tmp/fluent11/fluent11 /usr/share/icons/
install -D -m 0644 /tmp/fluent11/LICENSE /usr/share/licenses/fluent11-icon-theme/LICENSE
rm -rf /tmp/fluent11
gtk-update-icon-cache -q -f /usr/share/icons/fluent11

# 系统级 KDE 默认值（用户仍可在自己 ~/.config 里覆盖）。
# 这里只追加 kwinrc 的装饰相关键，不会覆盖上面写入的 [Wayland] InputMethod。
kwriteconfig6 --file /etc/xdg/kdeglobals --group General --key ColorScheme FluentLight
kwriteconfig6 --file /etc/xdg/kdeglobals --group General --key fixed \
    'Maple Mono Normal NF CN,10,-1,5,400,0,0,0,0,0,0,0,0,0,0,1,,0,0'
kwriteconfig6 --file /etc/xdg/kdeglobals --group Icons --key Theme fluent11
kwriteconfig6 --file /etc/xdg/plasmarc --group Theme --key name Fluent-light
kwriteconfig6 --file /etc/xdg/kwinrc --group org.kde.kdecoration2 --key library \
    org.kde.kwin.aurorae.v2
kwriteconfig6 --file /etc/xdg/kwinrc --group org.kde.kdecoration2 --key theme \
    __aurorae__svg__Fluent-light

# ---------------------------------------------------------------------------
# 5. GRUB 主题（Vimix，4K 资源，随仓库分发）
# ---------------------------------------------------------------------------
# 主题资源由 system_files 提供（system_files/usr/share/grub/...），构建时不访问
# GitHub：不走 api.github.com 的匿名配额，也不用把 token 塞进镜像 history。
# bootc 的 /boot 在运行时是独立分区，镜像里 /boot 的内容会被 mask
# （bootc lint 的 nonempty-boot），所以主题装进 /usr/share，由
# grub-theme-sync.service 在每次启动时同步到 /boot。
theme=/usr/share/grub/themes/vimix
lib=/usr/share/grub/grub2-themes

# 未拉取 LFS 时 system_files 里是指针文本而不是图片，早点炸掉别悄悄烧进镜像
if grep -rls 'git-lfs.github.com/spec' /usr/share/grub >/dev/null; then
    echo "GRUB 资源是 Git LFS 指针，先跑 'git lfs pull' 再构建" >&2
    exit 1
fi

chmod 0755 /usr/libexec/grub-theme-sync
bash -n /usr/libexec/grub-theme-sync
test -s "$theme/theme.txt"
test -s "$theme/background.jpg"
test "$(head -c 3 "$theme/background.jpg" | od -An -tx1 | tr -d ' \n')" = ffd8ff
test "$(head -c 4 "$theme/icons/fedora.png" | od -An -tx1 | tr -d ' \n')" = 89504e47
test -s "$theme/dejavu_sans_32.pf2"
test -s "$theme/terminus-18.pf2"
test -s "$theme/icons/fedora.png"
test -s "$theme/icons/windows.png"
test -s "$theme/icons/macosx.png"
test -s "$theme/icons/macos.png"
test -s "$theme/icons/chromeos.png"
test -s "$theme/icons/chrome.png"
test "$(find "$lib/icons" -name '*.png' | wc -l)" -eq 684
test "$(find "$lib/backgrounds" -name '*.jpg' | wc -l)" -eq 20
test "$(find "$lib/fonts" -name '*.pf2' | wc -l)" -eq 13
test "$(find "$lib/config" -name 'theme-*.txt' | wc -l)" -eq 5
test "$(find "$lib/select" -name 'select_*.png' | wc -l)" -eq 9
test -s "$lib/info/info-4k.png"
systemctl enable grub-theme-sync.service
test -L /etc/systemd/system/multi-user.target.wants/grub-theme-sync.service

# ---------------------------------------------------------------------------
# 6. 版本号：上游版本在前，自己的版本在后（如 45.20261125.0.v0.1.0）
# ---------------------------------------------------------------------------
# 版本号有两个独立来源，缺一不可：
#   - OCI label org.opencontainers.image.version → `bootc status` 的 Version
#     （bootc 只读 config label，不读 manifest annotation），由 Justfile 传入
#   - /usr/lib/os-release → GRUB 标题 / hostnamectl / fastfetch / KDE「关于」
# 两个值必须一致，所以这里用 build_files/VERSION + 基座版本自己推导一遍，
# 再和传入的 BUILD_VERSION 对账：不一致就报错，避免 label 与 os-release 漂移。
#
# 基座的写法各家不同（aurora 用 IMAGE_VERSION，bazzite 用 OSTREE_VERSION），
# 所以按优先级回退，取到第一个非空值。
upstream_version="$(grep -E '^(IMAGE_VERSION|OSTREE_VERSION)=' /usr/lib/os-release |
    head -n 1 | cut -d= -f2- | tr -d "\"'" | tr -d '[:space:]')"
if [ -z "$upstream_version" ]; then
    # 兜底：部分镜像只有 VERSION="45.20261125.0 (Kinoite)"
    upstream_version="$(grep -E '^VERSION=' /usr/lib/os-release |
        head -n 1 | cut -d= -f2- | tr -d "\"'" | sed 's/ *(.*//' | tr -d '[:space:]')"
fi
case "$upstream_version" in
    ''|*[!0-9.]*)
        echo "无法从 /usr/lib/os-release 解析上游版本：'$upstream_version'" >&2
        exit 1
        ;;
esac

own_version="$(tr -d '[:space:]' < /ctx/VERSION)"
if ! printf '%s' "$own_version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "build_files/VERSION 必须是 x.y.z 语义化版本，当前：'$own_version'" >&2
    exit 1
fi

build_version="${upstream_version}.v${own_version}"

# 显示名沿用基座品牌，不写死：bazzite → NAME="Bazzite" / VERSION_CODENAME="Kinoite"
base_name="$(grep -E '^NAME=' /usr/lib/os-release | head -n 1 | cut -d= -f2- | tr -d '"')"
codename="$(grep -E '^VERSION_CODENAME=' /usr/lib/os-release | head -n 1 | cut -d= -f2- | tr -d '"')"
[ -n "$base_name" ] || base_name=Bazzite
[ -n "$codename" ] || codename=Kinoite

if [ "${BUILD_VERSION:-dev}" = "dev" ]; then
    # 直接 podman build 没传版本：os-release 用推导值（不带构建序号），但 OCI label 仍是 dev。
    # 想要 `bootc status` 也显示版本、并且带 .tN 序号，就用 `just build`。
    echo "未传入 BUILD_VERSION，os-release 使用推导值 ${build_version}（不带 .tN，OCI label 仍为 dev）" >&2
else
    # just build 传进来的值必须恰好是 <推导值>.t<N>：既防止 label 与 os-release 漂移，
    # 也防止有人手填一个和 build_files/VERSION 无关的版本。
    base_pattern="$(printf '%s' "$build_version" | sed 's/\./\\./g')"
    if printf '%s' "${BUILD_VERSION}" | grep -qE "^${base_pattern}\.t[0-9]+$"; then
        build_version="${BUILD_VERSION}"
    else
        echo "BUILD_VERSION=${BUILD_VERSION} 不是 <上游>.v<自己>.t<N> 形式（推导值 ${build_version}.t<N>）；" >&2
        echo "请用 just build，或同步修改 build_files/VERSION / Containerfile 的基座" >&2
        exit 1
    fi
fi

install -d /usr/share/bootc-image
printf '%s\n' "$upstream_version" >/usr/share/bootc-image/upstream-version
printf '%s\n' "$build_version" >/usr/share/bootc-image/version

sed -i \
    -e "s|^VERSION=.*|VERSION=\"${build_version} (${codename})\"|" \
    -e "s|^PRETTY_NAME=.*|PRETTY_NAME=\"${base_name} (Version: ${build_version})\"|" \
    -e "s|^OSTREE_VERSION=.*|OSTREE_VERSION='${build_version}'|" \
    -e "s|^BUILD_ID=.*|BUILD_ID=\"${build_version}\"|" \
    /usr/lib/os-release
# GRUB 菜单标题（blscfg 读它），基座 bazzite 有、别的基座可能没有
if grep -q '^BOOTLOADER_NAME=' /usr/lib/os-release; then
    sed -i "s|^BOOTLOADER_NAME=.*|BOOTLOADER_NAME=\"${base_name} ${build_version}\"|" \
        /usr/lib/os-release
fi

# ublue 的 image-info.json（ujust / uupd 等工具会读）里的版本也同步，
# image-name / image-ref 保持基座原样，避免打断基座自带的更新与回滚逻辑。
if [ -f /usr/share/ublue-os/image-info.json ]; then
    tmp="$(mktemp)"
    jq --arg v "$build_version" \
        '.version = $v | .["version-pretty"] = $v' \
        /usr/share/ublue-os/image-info.json >"$tmp"
    cat "$tmp" >/usr/share/ublue-os/image-info.json
    rm -f "$tmp"
fi

# ---------------------------------------------------------------------------
# 自检
# ---------------------------------------------------------------------------
rpm -q fcitx5 fcitx5-chinese-addons fcitx5-qt fcitx5-gtk langpacks-zh_CN
locale -a | grep -qx 'zh_CN.utf8'
test -f /usr/share/applications/org.fcitx.Fcitx5.desktop
grep -qx 'Hidden=true' /etc/xdg/autostart/org.fcitx.Fcitx5.desktop
grep -qx 'InputMethod=/usr/share/applications/org.fcitx.Fcitx5.desktop' /etc/xdg/kwinrc
test -f /etc/xdg/user-dirs.conf
test -f /etc/skel/.config/user-dirs.dirs
grep -qx 'enabled=False' /etc/xdg/user-dirs.conf
grep -qx 'XDG_DESKTOP_DIR="$HOME/Desktop"' /etc/skel/.config/user-dirs.dirs
rpm -q v2raya
test -x /usr/bin/v2raya
test -x /usr/bin/v2raya_core
test -f /usr/share/v2raya/geoip.dat
test ! -L /etc/systemd/system/multi-user.target.wants/v2raya.service
test -L /etc/systemd/system/multi-user.target.wants/nvidia-clock-ac.service
test -x /usr/bin/clash-verge-service-install
test -f /usr/share/fonts/maple-mono/MapleMonoNormal-NF-CN-Regular.ttf
test -n "$(find /usr/share/fonts/nerd-fonts/JetBrainsMono -name '*.ttf' -print -quit)"
test -f /usr/share/color-schemes/FluentLight.colors
test -d /usr/share/plasma/desktoptheme/Fluent-light
test -d /usr/share/aurorae/themes/Fluent-light
test -f /usr/share/icons/fluent11/index.theme
grep -qx 'ColorScheme=FluentLight' /etc/xdg/kdeglobals
grep -qx 'GRUB_THEME="/boot/grub2/themes/vimix/theme.txt"' /etc/default/grub
grep -qx 'GRUB_GRUBENV_UPDATE=no' /etc/default/grub
test -L /etc/systemd/system/multi-user.target.wants/grub-theme-sync.service
test ! -e /boot/grub2/themes
test -s /usr/share/bootc-image/upstream-version
test -s /usr/share/bootc-image/version
grep -qx "VERSION=\"${build_version} (${codename})\"" /usr/lib/os-release
grep -qx "PRETTY_NAME=\"${base_name} (Version: ${build_version})\"" /usr/lib/os-release
grep -qx "OSTREE_VERSION='${build_version}'" /usr/lib/os-release
grep -qx "BUILD_ID=\"${build_version}\"" /usr/lib/os-release
if [ -f /usr/share/ublue-os/image-info.json ]; then
    test "$(jq -r .version /usr/share/ublue-os/image-info.json)" = "$build_version"
fi
test "$(cat /usr/share/bootc-image/upstream-version)" != "$build_version"
