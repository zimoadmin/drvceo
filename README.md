# 驱动总裁官方安装包自动同步

定期检查系统总裁官网的**驱动总裁在线版本**，有变化时下载原版安装包，验证官网 MD5 与 Windows Authenticode 发布者签名，再上传 GitHub Releases。不会运行安装包、安装驱动或修改 Windows 配置。

这是第三方镜像自动化项目，不是驱动总裁官方项目。安装包版权属于原作者；本仓库不修改安装包。

## 下载

- [最新版原版安装包](https://github.com/zimoadmin/drvceo/releases/latest/download/DrvCeo.exe)
- [版本及校验清单](https://github.com/zimoadmin/drvceo/releases/latest/download/manifest.json)
- [SHA256SUMS](https://github.com/zimoadmin/drvceo/releases/latest/download/SHA256SUMS.txt)
- [运行记录](https://github.com/zimoadmin/drvceo/actions)
- [官方来源](https://www.sysceo.com/software-softwarei-id-258.html)

## 同步规则

- 每 6 小时检查一次，北京时间约 02:37、08:37、14:37、20:37。GitHub 调度可能延迟，不承诺实时更新。
- 可以在 Actions → Sync official DrvCeo installer → Run workflow 手动检查。
- 官网版本和 MD5 未变化、已发布附件的 SHA-256 与清单一致时跳过。
- 只使用官网的“普通下载”地址；不下载“安全下载”包装器。
- 全程 HTTPS，官网 MD5 与签名任一不通过则失败，保留旧的可用版本。
- 签名发布者必须是 `Jiangmen Eyun Network Co., Ltd.`；发布者变化需要人工复核，不自动放宽。
- 新文件先上传到草稿，完整上传后发布为最新版本；旧版本保留。
- `manifest.json` 包含官网版本、文件版本、大小、MD5、SHA-256、来源与签名信息。
- 工作流只使用仓库自带 `GITHUB_TOKEN`，无需额外保存个人访问令牌。

公共仓库长时间没有活动时，GitHub 可能禁用定时工作流；可在 Actions 页面重新启用。检查失败也应到 Actions 查看原因。

## 本地检查

在 Windows PowerShell 或 PowerShell 中运行：

```powershell
# 只读取官网版本与链接
./scripts/sync.ps1 -CheckOnly

# 下载并校验，但不发布、更不会安装
./scripts/sync.ps1 -DownloadOnly
```

自动同步使用 GitHub 的 Windows runner 校验数字签名。工具箱尚未自动切换到本仓库，接入下载来源是单独的修改。
