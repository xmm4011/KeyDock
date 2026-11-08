# 国内厂商接入参考与核验

核对日期：2026-11-08。手动预设、请求构造、代理路由及导入 Agent 共用 `ProviderPresets.swift`。不预置猜测的模型 ID，不把模型目录等同于当前 Key 的调用权限。国外直连厂商已从预设菜单移除；中转站仍可选择所需协议。

## 接口资料

下表中的 Messages 指 Anthropic 兼容格式，Responses 指 Responses 格式。厂商地址可能使用专用前缀，界面选择协议后生成实际地址；不能把所有厂商都机械拼为同一路径。

| 预设 | Chat / Responses 基础地址 | Messages 基础地址 | 模型目录 | 余额 |
| --- | --- | --- | --- | --- |
| DeepSeek | `https://api.deepseek.com` | `https://api.deepseek.com/anthropic/v1` | GET `/models` | GET `/user/balance`，同一 API Key，保留返回币种 |
| 通义千问 / 百炼 | `https://dashscope.aliyuncs.com/compatible-mode/v1` | `https://dashscope.aliyuncs.com/apps/anthropic/v1` | 业务空间专属域名 GET `/api/v1/models`，按文档分页读取 | 云账户 QueryAccountBalance 需要独立 AK / 签名；提供控制台入口 |
| 豆包 / 火山方舟 | `https://ark.cn-beijing.volces.com/api/v3` | `https://ark.cn-beijing.volces.com/api/compatible/v1` | 未确认可复用模型 Key 的通用目录；可主动探测或添加实际 Model / Endpoint ID | 费用中心 QueryBalanceAcct 需独立账户权限 |
| Kimi / Moonshot | `https://api.moonshot.cn/v1` | `https://api.moonshot.cn/anthropic/v1` | GET `/v1/models` | GET `/v1/users/me/balance`，`data.available_balance`，CNY |
| 百川 | `https://api.baichuan-ai.com/v1`，仅确认 Chat | 未确认 | 公开文档未确认；可主动探测 | 未确认同 Key 查询接口，前往控制台 |
| 百度千帆 | `https://qianfan.baidubce.com/v2` | `https://qianfan.baidubce.com/anthropic/v1` | GET `/v2/models`，不同模型支持的协议可能不同 | 云账户 Finance 接口需要 AK/SK 签名 |
| 百度 EOS AIGC · 新加坡 | `https://eos-sg.aigc.exp.bcevod.com/v1` | 同左 | 接入指南未提供通用目录；保留已知模型并允许主动探测 | 接入指南未提供同 Key 余额接口 |
| 百度 EOS AIGC · 加州 | `https://eos-ca.aigc.exp.bcevod.com/v1` | 同左 | 同上 | 同上 |
| 百度 EOS AIGC · 德国 | `https://eos-de.aigc.exp.bcevod.com/v1` | 同左 | 同上 | 同上 |
| 百度 EOS AIGC · 广州 | `https://vod.gz.baidubce.com/v1` | 同左 | 同上 | 同上 |

各预设默认使用 Chat Completions。EOS 另外支持 Gemini 原生 `/v1beta/models/{model}:{action}`，所有协议均使用 Bearer。千帆 Messages 使用 `x-api-key`；其余表中已确认的接口使用 Bearer。原生 Messages 请求附加 `anthropic-version`。协议能力不表示每个模型都支持该协议。

百炼推荐使用控制台里的真实 WorkspaceId 专属域名，不生成虚构业务空间；旧域名继续保留为可直接填写的北京预设。Responses 使用 `/compatible-mode/v1/responses`，避免已停止维护的旧路径。Coding Plan、地域、项目空间的地址和 Key 不能混用。EOS 各地域 Key、海外美元账户和国内人民币账户分开；[海外登录](https://login.bce.baidu.com/overseas-login) 是控制台入口，不能作为 API Base URL。

余额接口只自动配置已确认能复用模型 Key 的 DeepSeek、Kimi。云账户级余额的地址、鉴权、返回字段及文档保留在 Agent 参考资料中，不能将模型 Key 发过去冒充账户鉴权；EOS 海外账户对 BCE Finance 的适用性仍需账户侧确认。

## 核验范围

匿名检查了 **58 个公开 URL**：30 次文档 / GET 查询与 28 次空正文路由探测。[公开状态记录](Tests/Fixtures/preset-endpoints-2026-11-08.json)中，结果为 200 × 19、302 × 6、401 × 29、403 × 2、400 × 1、422 × 1；没有网络异常。401 / 403 只表明到达了鉴权或访问控制，400 / 422 只表明收到参数校验响应，均不证明真实账号可调用。302 记录跳转位置，不将重定向本身算作正文已读。

检查不携带密钥、Cookie 或真实模型输入，不产生真实推理。Gemini 含模型名的动态路径通过文档和本地请求回归核对，没有使用猜测模型执行公网调用。飞书接入指南可匿名读取正文，但另一个嵌入模型表尚未完整读取，不能据此声称获取了 EOS 全部模型。

实际账号的模型权限、余额、图片 / 工具能力仍需应用内真实验证。已知资料不限制 Agent 的主动探测：没有文档目录不等于永远不支持目录；显式获取模型仍可观察实际结果，自定义 GET 地址也可提供新的目录。批量连接检查继续避免自动发送模型请求。

复查脚本：`KeyDockChecks --preset-reference-json` 导出公开参考资料，再运行 `python3 scripts/check-preset-endpoints.py references.json results.json`。脚本不读取保险库，也不携带鉴权。

## 一手资料

- DeepSeek：[Chat 接入](https://api-docs.deepseek.com/)、[Messages](https://api-docs.deepseek.com/guides/anthropic_api/)、[Responses](https://api-docs.deepseek.com/guides/responses_api/)、[模型目录](https://api-docs.deepseek.com/api/list-models/)、[余额](https://api-docs.deepseek.com/api/get-user-balance/)。Messages HTTP 的 `max_tokens` 可选，示例移除该限制。
- 百炼：[Base URL](https://help.aliyun.com/zh/model-studio/base-url)、[Messages](https://help.aliyun.com/zh/model-studio/anthropic-api-messages)、[Responses](https://help.aliyun.com/zh/model-studio/qwen-api-via-openai-responses)、[模型目录与分页结构](https://help.aliyun.com/zh/model-studio/list-models)、[云账户余额](https://help.aliyun.com/zh/user-center/developer-reference/api-bssopenapi-2017-12-14-queryaccountbalance)。Messages 的 `max_tokens` 必填，示例保留协议必填项。
- 火山方舟：[Chat](https://docs.volcengine.com/docs/82379/1494384)、[Messages](https://docs.volcengine.com/docs/ark/messages-api)、[多协议对照](https://docs.volcengine.com/docs/ark/agent-model-invocation-practice)、[API Key 权限](https://docs.volcengine.com/docs/ark/api-key)、[费用中心余额](https://docs.volcengine.com/docs/billing-center/query-balance-acct-query-user-account-balance-information)。Messages 的输出限制未标为必选，示例不添加。
- Kimi：[Chat](https://platform.kimi.com/docs/api/chat)、[Messages](https://platform.kimi.com/docs/api/messages)、[Responses](https://platform.kimi.com/docs/api/responses)、[模型目录](https://platform.kimi.com/docs/api/list-models)、[余额](https://platform.kimi.com/docs/api/balance)。Messages 的 `max_tokens` 必填，国内与国际 Key 独立。
- 百川：[官方 API 文档](https://platform.baichuan-ai.com/docs-v2/api)。
- 百度千帆：[Chat 接入](https://cloud.baidu.com/doc/qianfan-docs/s/Fm9l6ocai)、[模型目录及支持的协议路径](https://cloud.baidu.com/doc/qianfan-api/s/Dmba8k71y)、[BCE 财务余额与 AK/SK 权限](https://intl.cloud.baidu.com/zh/doc/Finance/s/Skhtyytwu-intl)。
- 百度 EOS：[用户提供的模型服务 V2 接入指南](https://tcnxnzs113h4.feishu.cn/wiki/JpXbwpfC3iyrkhkFQYVcoYyknRe)、[模型资料入口](https://tcnxnzs113h4.feishu.cn/wiki/I9NJw6lPmiqbNFkQF0TcavXln7b)。
