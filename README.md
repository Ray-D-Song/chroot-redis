# chroot-redis

离线 Redis 8 发行包，使用 Debian 12 AMD64 chroot 运行环境，供没有外网或宿主发行版不固定的 Linux 服务器使用。

## 构建与发布

`versions.env` 锁定 Redis 官方 APT 仓库的精确包版本。推送分支或 Pull Request 时 GitHub Actions 构建并验证；推送 `v*` tag 后，只有 Ubuntu 24 Hosted Runner 与自建 CentOS 7 / Linux 3.10 Runner 都通过验证，才会创建 GitHub Release。

自建 Runner 必须包含标签：`self-hosted`、`linux`、`x64`、`centos7-kernel310-redis`，并且允许无交互 `sudo`。它会真实安装、启动 systemd 服务、用密码连接 Redis、重启并验证数据持久化。

非 Release 的工作流和失败工作流都会在结束时删除本次构建 Artifact，避免持续占用仓库空间。

Redis 8 采用 AGPLv3 / RSALv2 双许可，与 7.2 之前的 BSD 许可不同；如果不能接受，把 `versions.env` 里的 `REDIS_PACKAGE_VERSION` 改回 `6:7.4.x-1rl1~bookworm1` 系列重新构建即可。

## 安装发行包

```bash
tar -xzf chroot-redis-<version>-linux-amd64.tar.gz
cd chroot-redis-<version>-linux-amd64
sudo ./install.sh
sudo systemctl status chroot-redis
sudo cat /etc/chroot-redis/credentials
```

默认路径为 `/opt/chroot-redis`（rootfs）、`/var/lib/chroot-redis/data`（数据）、`/etc/chroot-redis/conf`（配置）和 `/etc/chroot-redis/credentials`（凭据）；数据和配置目录不会随普通卸载或升级删除。

默认监听 `0.0.0.0:6379`，安装时生成随机 `requirepass` 密码，或通过 `--password` / `CHROOT_REDIS_PASSWORD` 指定，同时开启 AOF（`appendfsync everysec`）与 RDB 快照；生产使用前必须通过防火墙限制来源地址。

密码来源（仅全新实例）：`--password` > `CHROOT_REDIS_PASSWORD` > 随机生成。已有数据目录时传入密码会被忽略并警告，密码以 credentials 文件为准。自动化场景优先使用环境变量：

```bash
sudo CHROOT_REDIS_PASSWORD='your-secret-here' ./install.sh
```

连接示例：

```bash
sudo chroot /opt/chroot-redis/rootfs /usr/bin/redis-cli -h 127.0.0.1 -p 6379 \
  -a "$(sudo awk -F= '$1=="REDIS_PASSWORD"{print $2}' /etc/chroot-redis/credentials)"
```

## 修改配置

配置文件是 `/etc/chroot-redis/conf/redis.conf`，运行时被 bind mount 到 rootfs 的 `/etc/redis`。文件开头是 `# BEGIN chroot-redis managed settings` 到 `# END chroot-redis managed settings` 的托管区块，每次安装都会重写它。

Redis 以**最后出现的指令**为准，所以自定义配置要写在托管区块**之后**才能覆盖默认值。改完执行 `sudo systemctl restart chroot-redis` 生效。带注释的上游完整配置样例在 rootfs 里的 `/usr/share/redis/redis.conf.reference`。

可覆盖默认值：

```bash
sudo ./install.sh --prefix /opt/chroot-redis --data-dir /var/lib/chroot-redis/data \
  --conf-dir /etc/chroot-redis/conf --port 6379 --bind '127.0.0.1' --password 'your-secret-here'
```

`sudo ./uninstall.sh` 删除服务和 rootfs、保留数据与配置；仅在确认不再需要这份数据时使用 `sudo ./uninstall.sh --purge-data`（同时删除数据、配置和凭据）。
