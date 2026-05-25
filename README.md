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

## microsocks

Debian SOCKS5 服务端安装脚本，基于 `microsocks`，监听 `0.0.0.0:1080`，允许任意客户端来源连接，并使用用户名/密码认证。默认用户名为 `socksuser`。

```bash
curl -sSL https://raw.githubusercontent.com/zhnkc9/shells/refs/heads/master/microsocks.sh | sudo bash -s -- --password 'your-password'
```

自定义端口：

```bash
curl -sSL https://raw.githubusercontent.com/zhnkc9/shells/refs/heads/master/microsocks.sh | sudo bash -s -- --password 'your-password' --port 2080
```

自定义用户名：

```bash
curl -sSL https://raw.githubusercontent.com/zhnkc9/shells/refs/heads/master/microsocks.sh | sudo bash -s -- --user socksuser --password 'your-password'
```

客户端测试：

```bash
curl --socks5 socksuser:your-password@服务器IP:1080 https://ifconfig.me
```

注意：该脚本允许任意来源客户端访问 SOCKS5 端口，请使用强密码，并确认云厂商规则允许代理服务。

密码只允许字母、数字、点、下划线、`@`、`+`、`=` 和短横线，避免 systemd 参数解析问题。
