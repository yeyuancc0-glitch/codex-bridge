# DeepSeek Harness 接入指南

## Profile 与 `.env`

Codex Bridge 只登记 DeepSeek Harness 可执行文件和外部 `cordis.yml`，不读取、保存或摘要 API Key。将 `.env` 放在所登记的 `cordis.yml` 同一目录；Bridge 以该目录启动 Harness，由 Harness 自行加载配置。

从仓库示例开始：

```bash
cp Examples/DeepSeekHarnessProfile/.env.example /path/to/profile/.env
```

仅在本机编辑生成的 `.env`，不要提交或分享它。

## 模型与 Web Search 使用不同端点

```env
DEEPSEEK_API_KEY=
DEEPSEEK_BASE_URL=https://api.deepseek.com
DEEPSEEK_SEARCH_BASE_URL=https://api.deepseek.com/anthropic/v1
```

- `DEEPSEEK_BASE_URL` 是主模型的 DeepSeek-compatible chat-completions 基址。
- `DEEPSEEK_SEARCH_BASE_URL` 是独立的 Anthropic-compatible Web Search 基址。DSH 会自动追加 `/messages`，不要在变量中包含 `/messages`。
- 当前 Bridge Profile 的主模型与搜索插件默认共用 `DEEPSEEK_API_KEY`。若两个端点属于不同服务，必须确认同一凭据对两者都有效；否则搜索会收到远端认证失败，而主模型仍可能正常工作。

一个网关支持 `/messages` 不代表它支持 Web Search。搜索端点还必须接受 Anthropic Messages 请求中的原生 `web_search_20250305` server tool。配置前应核对网关文档；认证成功也不等于该工具可用。

## 常见错误

### `Authentication Fails ... api key ... is invalid`

这表示 DSH 已解析到凭据并到达搜索端点，但远端拒绝了该凭据。重点核对：

1. `DEEPSEEK_SEARCH_BASE_URL` 是否指向预期的搜索服务，而不是遗漏后回退到 DeepSeek 官方端点；
2. `DEEPSEEK_API_KEY` 是否对该搜索端点有效；
3. 搜索端点是否接受 `POST <baseURL>/messages`。

### 没有 `web_search_tool_result`

认证和 Messages 请求可能已经成功，但端点没有执行原生 Web Search。确认它明确支持 `web_search_20250305`，不能只根据 Anthropic-compatible 标识推断。

修改外部 `cordis.yml`、Harness 可执行文件或锁文件会触发 Codex Bridge 的安装身份复核；仅更新未登记的本机 `.env` 不会改变已冻结的安装工件。
