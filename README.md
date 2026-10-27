<p align="center">
  <img src="assets/readme/hero.svg" width="100%"
       alt="wfadnf-git-guard：提交前按路径、体积、内容特征和运行时文件指纹检查，拦下运行时数据与密钥">
</p>

<p align="center">
  给个人仓库加一道提交闸：<b>路径、体积、内容特征、运行时文件指纹</b>四层检查。<br>
  <code>pre-commit</code> 拦一次，<code>pre-push</code> 对即将发布的每个提交再拦一次。
</p>

## 先看拦下来的样子

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

三个文件分别被路径、宽松密钥特征、高置信度密钥特征拦下；它们都没有进入历史。

## 它解决什么问题

运行时数据、密钥和配置常常就在同一个 home 里，与仓库只隔一个目录。一次 `git add -A`、一次 AI 助手的“顺手提交”，就可能把 `data/`、`config.json`、`.env` 或私钥带进历史。

`.gitignore` 只能按路径挡，只在单个仓库里生效，也挡不住 `git add -f`。git-guard 把规则放到用户级，在 git 真正写入前检查文件内容：

- **改名的副本也能认**：先给运行时文件算指纹，仓库里出现逐字节相同的文件就拦，不管后缀是 `.dat` 还是 `.txt`。
- **推送前还能补刀**：`git commit --no-verify` 跳过的提交，`pre-push` 会连同 merge 带入、加了又删的内容一起重扫。
- **纯 bash，无 Node/Python 依赖**：Linux、macOS、Android 上的 POSIX shell 都能直接跑。

## 四层检查

| 层 | 拦什么 | 在哪里生效 |
|---|---|---|
| 路径 | `data/`、`logs/`、`storage/`、`.env`、`config.*.json`、`*.pem`、`*.db`、日志、压缩包 | 提交、推送、审计 |
| 体积 | 超过 5 MB 的文件，通常是数据库、备份或构建产物 | 提交、推送、审计 |
| 内容 | 私钥头、`sk-`、`ghp_`、`AKIA`、`AIza`、JWT，以及 `key/password/token = "…"` 赋值 | 提交、推送、审计 |
| 指纹 | 与 `protected-roots.txt` 下运行时文件逐字节相同的副本 | 提交、推送、工作区核验 |
| 受保护目录 | 位于 `protected-roots.txt` 内的仓库，默认禁止提交和推送 | 提交、推送 |

内容检查只读前 1 MB；`mock`、`dummy`、`example`、`your_api_key` 这类占位值会跳过。宽松规则不检查 `lang/`、`test/`、`docs/`，高置信度规则任何目录都查。

## 安装

需要 `bash`、`git` 和 GNU `find`/`awk`/`sed`/`grep`（主流 Linux 发行版自带）。

```bash
git clone https://github.com/AndyerNotFound/wfadnf-git-guard.git
cd wfadnf-git-guard && ./install.sh
```

`install.sh` 幂等，已存在的规则文件不会被覆盖。它会把钩子模板装进 `~/.config/git/template`，所以**之后新 clone 的仓库会自动继承钩子**；`git-guard install` 用来补装已有仓库。

装完后补两条自己的规则：

```bash
# 只给自己的远端装钩子；第三方开源仓库不动
echo 'github.com/yourname/' >> ~/.config/git/guard/owners.txt

# 运行时数据放在哪里
echo "$HOME/app-runtime" >> ~/.config/git/guard/protected-roots.txt

git-guard install ~/work      # 给已有仓库装钩子 + 索引级忽略
git-guard snapshot            # 生成运行时文件指纹
wsnap init && wsnap hook on   # 工作区基线 + 提示符核验
```

卸载：`./uninstall.sh`。

## 日常用法

```bash
git-guard status              # 全局配置、受保护目录、已挂钩子的仓库
git-guard audit ~/work        # 审计已入库内容（只列文件名，不打印内容）
git-guard snapshot            # 运行时配置变了之后重算指纹

wsnap verify                  # 工作区比基线多了/改了什么
wsnap verify --accept         # 确认无误，接受为新基线
wsnap watch 5                 # 常驻轮询，只在告警时打印
wsnap hook off                # 卸载提示符钩子
```

`wsnap` 默认核验 `~/work`，用 `WSN_ROOT` 指定别的目录；返回码 `3` 表示有告警。

**误报怎么放行：**

```bash
# 永久放行：写 ERE，以 ^/ 开头，匹配 /仓库内相对路径
echo '^/fixtures/sample-config\.json$' >> ~/.config/git/guard/allow-paths.txt

# 单次放行
GUARD_OVERRIDE=1 git commit -m "..."
```

源码里的 `data`、`runtime` 包名已经在 `allow-paths.txt` 里放行；受保护目录内确实需要提交的仓库，可以写进可选的 `allowed-repos.txt`。

## 规则

全部是纯文本，一行一条 ERE，`#` 开头为注释，改完立即生效：

| 文件（`~/.config/git/guard/`） | 用途 |
|---|---|
| `deny-paths.txt` | 路径规则，匹配 `/仓库内相对路径` |
| `deny-content.txt` | 高置信度特征，大小写敏感，含二进制文件 |
| `deny-content-soft.txt` | 宽松的密钥赋值特征，`lang`/`test`/`docs` 跳过 |
| `allow-paths.txt` | 永久放行，也用于源码里的 `data` 包名 |
| `protected-roots.txt` | 这些目录内的仓库禁止提交/推送 |
| `owners.txt` | 自有远端前缀，决定 `git-guard install` 给谁装钩子 |
| `exclude-dirs.txt` | 扫描仓库时跳过的目录名 |
| `private.blobs` | 运行时文件指纹清单，由 `git-guard snapshot` 生成 |
| `allowed-repos.txt` | 可选；受保护目录内仍允许提交的仓库绝对路径 |

## 边界

- **不是沙箱。** 钩子、规则、指纹都在 `~/.config/git/`，同一用户可删改；`git push --no-verify` 也能直接跳过客户端钩子。真正的兜底在服务端：GitHub push protection，或裸库的 `pre-receive`。
- **只认逐字节相同。** 编码、压缩、加密后的变体认不出。
- **新 clone 会继承模板钩子。** 包括第三方仓库；`owners.txt` 只影响 `git-guard install` 的扫描范围，不会阻止新 clone 继承钩子，介意的话单独调整 `init.templateDir`。
- **没有 inotify。** 工作区里“刚创建”的文件，要等下一次 `wsnap verify` 才按 mtime + 哈希补上。
- **审计只看文件名。** `git-guard audit` 不会打印命中内容，避免二次泄漏；清理历史仍需 `git filter-repo` 或 BFG。

## 自测

```bash
bash test/run-tests.sh    # 12 个用例，全部在临时目录
```

覆盖普通代码放行、`data/` 拦截、改名副本、手写密钥、`key` 字段、源码 `data` 包名放行、6 MB 文件、`--no-verify` 后推送、merge 带入、受保护目录。

## License

AGPL-3.0
