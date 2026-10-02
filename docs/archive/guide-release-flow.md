# iVox 发布流程

每次发版前按以下步骤执行：

## 1. 确认改动已 commit

```bash
git status
```

## 2. 打包二进制

```bash
cd .build/release
tar czf ivox-vX.X.X-macos-arm64.tar.gz ivox
```

注意：`install-binary.sh` 期望 `.tar.gz` 格式，不是 `.zip`。

## 3. 打版本 tag

```bash
make version V=vX.X.X
```

这会自动：
- 更新 `Version.swift` 中的版本号
- 提交更改
- 创建 git tag

## 4. 更新 CHANGELOG

编辑 `docs/CHANGELOG.md`，在顶部添加新版本：

```markdown
## vX.X.X — YYYY-MM-DD

### 修复 / 改进 / 新功能

- 描述
```

## 5. 提交并推送

```bash
git add -A && git commit -m "docs: 更新 CHANGELOG vX.X.X" && git push origin main --tags
```

## 6. 创建 GitHub Release

```bash
gh release create vX.X.X --title "iVox vX.X.X" --notes "..."
```

## 7. 上传二进制包

```bash
gh release upload vX.X.X .build/release/ivox-vX.X.X-macos-arm64.tar.gz --clobber
```

## 8. 检查 Release

确认以下内容：
- [ ] GitHub Release 已创建
- [ ] 二进制包已上传
- [ ] CHANGELOG 已更新
- [ ] 安装脚本能正常下载（可选）

## 注意

- push 后 CI 不做任何事，二进制需手动上传
- 每次发布前检查项目文档（README、CHANGELOG）是否已反映本次变更
