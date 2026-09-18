# Feather MLX 后端

这个目录包含 Feather Input 的本机 MLX 服务。服务只监听 `127.0.0.1:1235`，不记录或
持久化输入文字，并拒绝带浏览器 `Origin` 的请求。

推荐使用生命周期管理器部署到稳定目录：

```sh
python3 scripts/manage-macos-mlx-backend.py install \
  --model "$HOME/Library/Application Support/FeatherInput/models/Qwen3-1.7B-Base-MLX-8bit"
```

安装命令使用 `uv` 在
`~/Library/Application Support/FeatherInput/MLXBackend` 创建虚拟环境，复制当前目录，
安装锁定依赖，并替换同名的 `im.feather.mlx-worker` LaunchAgent。新服务无法加载时会恢复
旧 LaunchAgent 和旧后端目录，不会创建第二个监听相同端口的服务。

管理命令：

```sh
python3 scripts/manage-macos-mlx-backend.py status
python3 scripts/manage-macos-mlx-backend.py restart
python3 scripts/manage-macos-mlx-backend.py stop
python3 scripts/manage-macos-mlx-backend.py start
python3 scripts/manage-macos-mlx-backend.py uninstall
```

接口包括 `GET /health`、`POST /generate`、`POST /score` 和 `POST /continuations`。客户端
必须把模型调用放在按键主线程之外，并在输入 revision 变化后丢弃迟到结果。

`pinyin_generation.py` 使用 `pypinyin` 的单字读音数据；许可证见
`licenses/pypinyin-MIT.txt`。
