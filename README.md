# shells

常用脚本子项目列表。

后续可以继续在这里追加新的命令。

## ss

Shadowsocks 安装脚本。

```bash
curl -sSL https://raw.githubusercontent.com/zhnkc9/shells/refs/heads/master/shadowsocks.sh -o shadowsocks.sh && chmod +x shadowsocks.sh && ./shadowsocks.sh
```


## bbr

```bash
curl -sSL https://raw.githubusercontent.com/zhnkc9/shells/refs/heads/master/bbr.sh -o bbr.sh && chmod +x bbr.sh && ./bbr.sh
```

## dante-server

Debian SOCKS5 服务端安装脚本，基于 `dante-server`，监听 `0.0.0.0:1080`，允许任意客户端来源连接，并使用用户名/密码认证。

```bash
curl -sSL https://raw.githubusercontent.com/zhnkc9/shells/refs/heads/master/dante-server.sh -o dante-server.sh && chmod +x dante-server.sh && sudo ./dante-server.sh --user socksuser --password 'your-password'
```

自定义端口：

```bash
curl -sSL https://raw.githubusercontent.com/zhnkc9/shells/refs/heads/master/dante-server.sh -o dante-server.sh && chmod +x dante-server.sh && sudo ./dante-server.sh --user socksuser --password 'your-password' --port 1080
```

客户端测试：

```bash
curl --socks5 socksuser:your-password@服务器IP:1080 https://ifconfig.me
```

注意：该脚本允许任意来源客户端访问 SOCKS5 端口，请使用强密码，并确认云厂商规则允许代理服务。
