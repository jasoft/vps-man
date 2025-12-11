## 使用说明：

  - 先将域名解析到服务器，再运行脚本。
  - 如需部署新静态站点：rsync -av --delete /path/to/out/ root@<server>:/
    opt/wp2/html/，容器会直接读取最新文件。
  - 脚本会打印 Hysteria2 订阅链接；客户端保持 UDP 443、SNI/证书校验开启。
