<p align="center">
  <img src="assets/readme/hero.svg" width="100%"
       alt="wfadnf-git-guard：提交前按路径、体积、内容、指纹四层检查，拦截运行时数据与密钥">
</p>

<p align="center">
  用户级 <code>pre-commit</code> / <code>pre-push</code> 防泄漏闸。<br>
  <b>路径 · 体积 · 内容 · 指纹</b> 四层检查，在 git 写入之前完成拦截。
</p>

<p align="center"><a href="README.en.md">English</a></p>

## 拦截输出示例

```text
$ git commit -m "sync runtime"

============ git-guard 已拦截提交 ============
  x data/config.json
      -> 路径命中禁止规则: (^|/)data/
  x key.js
      -> 内容命中高置信度密钥特征
  x notes.txt
      -> 内容命中密钥赋值特征
---------------------------------------------------------
通常是运行时数据/密钥/配置被 add 进来了。处理办法：
  git restore --staged <file>        # 取消暂存
  git rm --cached <file>             # 已入库的移出索引
  echo '<pattern>' >> .gitignore     # 长期忽略
规则: ~/.config/git/guard/{deny-paths,deny-content,deny-content-soft}.txt
误伤可加到 allow-paths.txt；确认无害才: GUARD_OVERRIDE=1 git ...
=========================================================
```

`.gitignore` 仅按路径匹配、仅在单个仓库内生效，且无法阻止 `git add -f`。git-guard 将规则置于用户级并按内容检查：运行时文件预先计算指纹，任何仓库中出现逐字节相同的副本均会被拦截，即使重命名或更改扩展名亦然。

## 安装

依赖 `bash`、`git` 及 GNU `find`/`awk`/`sed`/`grep`；macOS 需执行 `brew install coreutils findutils gnu-sed`，并将 `gnubin` 加入 PATH。

```bash
git clone https://github.com/AndyerNotFound/wfadnf-git-guard.git
cd wfadnf-git-guard && ./install.sh
```

钩子模板写入 `~/.config/git/template`，此后克隆的仓库自动继承；已有仓库可通过 `git-guard install` 补装。卸载方式：`./uninstall.sh`。

补充以下两项个人配置后完成初始化：

```bash
echo 'github.com/yourname/' >> ~/.config/git/guard/owners.txt         # 自有远端
echo "$HOME/app-runtime"   >> ~/.config/git/guard/protected-roots.txt # 运行时目录
git-guard snapshot && wsnap init && wsnap hook on
```

## 用法

| 命令 | 功能 |
|---|---|
| `git-guard status` | 显示配置、受保护目录与已挂钩仓库 |
| `git-guard audit <目录>` | 审计已入库内容（仅列出文件名） |
| `git-guard snapshot` | 重新计算运行时指纹 |
| `git-guard check <文件>` | 预检：判断该文件是否会被拦截 |
| `wsnap verify` | 报告工作区相对基线的变更（存在告警时返回码为 3） |
| `wsnap verify --accept` | 接受当前状态为新基线 |
| `wsnap watch 5` | 常驻轮询 |
| `wsnap hook off` | 卸载提示符钩子 |

若已安装 `termux-api` 或 `notify-send`，拦截发生时将推送通知，可一键取消暂存，或签发一次性放行令牌（默认有效期 10 分钟，仅对下一次提交有效，`pre-push` 不予认可；有效期可经 `allow-ttl` 调整）。`GUARD_NOTIFY=0` 使本次操作不发送通知，`GUARD_OVERRIDE=1` 放行本次操作，误报可写入 `allow-paths.txt` 获得永久放行。

## 规则

`~/.config/git/guard/` 下均为纯文本文件，每行一条 ERE，修改后立即生效。

| 文件 | 用途 |
|---|---|
| `deny-paths.txt` | 路径规则：`data/`、`.env`、`*.pem`、日志、压缩包等 |
| `deny-content.txt` | 高置信度特征：私钥头、`sk-`、`ghp_`、`AKIA`、JWT |
| `deny-content-soft.txt` | 密钥赋值 `key = "…"`；跳过 `lang`/`test`/`docs` |
| `allow-paths.txt` | 永久放行 |
| `protected-roots.txt` | 禁止目录内仓库提交与推送 |
| `owners.txt` | 自有远端前缀 |
| `exclude-dirs.txt` | 扫描时跳过的目录 |
| `private.blobs` | 指纹清单（由 `snapshot` 生成） |
| `allowed-repos.txt` | 受保护目录内的例外仓库 |

体积上限为 5 MB；内容检查仅读取前 1 MB，并跳过 `mock`/`example` 等占位值；指纹仅匹配逐字节相同的文件。

## 限制

- 并非沙箱：钩子可被同一用户删除或修改，`--no-verify` 亦可跳过；最终防线依赖服务端 push protection 或 `pre-receive`。
- 指纹无法识别经编码、压缩或加密处理后的变体。
- 新克隆的仓库（含第三方仓库）将继承模板钩子；如不希望继承，可调整 `init.templateDir`。
- 未使用 inotify；新建文件将于下一次 `wsnap verify` 时纳入基线。
- `audit` 仅列出文件名；清理历史记录需使用 `git filter-repo` 或 BFG。

## 自测

```bash
bash test/run-tests.sh   # 32 个用例，全部在临时目录中执行
```

## License

AGPL-3.0
