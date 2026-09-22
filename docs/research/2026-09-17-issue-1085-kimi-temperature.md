# Issue #1085: Kimi temperature, and China-lab Chat Completions support

Date: 2026-09-17, America/Los_Angeles.

**Issue:** [#1085](https://github.com/moona3k/macparakeet/issues/1085).

## Verdict

MacParakeet was sending the app baseline `temperature: 0.7` (and `0.1` for
knowledge cards) to Kimi. Official Moonshot docs fix Kimi K2.5+ / K3
temperature; any other value 400s. The same model-ID policy now covers native
Moonshot plus OpenRouter and custom OpenAI-compatible endpoints. First-class
providers were added for the other large China labs that already appear in the
OpenRouter fallback catalog and ship international OpenAI-compatible APIs.

## Official contracts (fetched 2026-09-17)

| Lab | Default endpoint | Sampling | Thinking wire |
|-----|------------------|----------|---------------|
| Moonshot / Kimi | `https://api.moonshot.ai/v1` | K2.5/K2.6: `1.0` thinking / `0.6` instant; K2.7-code and K3: `1.0`. Other values error. Omit the field. [`K2.6 quickstart`](https://platform.kimi.ai/docs/guide/kimi-k2-6-quickstart), [`model parameter reference`](https://platform.kimi.ai/docs/api/models-overview) | K2.5/K2.6: `thinking: {type: enabled\|disabled}`. K2.7-code and K3 always think; omit the field (`disabled` 400s on K2.7). |
| DeepSeek | `https://api.deepseek.com/v1` | Thinking (default) ignores temperature; omit it so receipts stay honest. [`Thinking mode`](https://api-docs.deepseek.com/guides/thinking_mode/) | `thinking: {type}` |
| Qwen / DashScope | `https://dashscope-intl.aliyuncs.com/compatible-mode/v1` | `0.7` is legal (`[0, 2)`) | `enable_thinking` bool |
| Z.AI / GLM | `https://api.z.ai/api/paas/v4` | `0.7` is legal; docs recommend `1.0` | `thinking: {type}` |
| MiniMax | `https://api.minimax.io/v1` | `[0, 2]`, default `1`, so `0.7` is legal | `thinking: {type: adaptive\|disabled}` |

Vercel AI SDK (`@ai-sdk/moonshotai`, `@ai-sdk/deepseek`, `@ai-sdk/minimax`,
`@ai-sdk/alibaba`, `@ai-sdk/zai`) uses the same idea: detect family from model
ID, omit illegal sampling, map thinking to the native field. MacParakeet keeps
one adapter and one `ChatCompletionsModelPolicy` instead of five packages.

## Out of first-class scope

ByteDance Doubao (Volcengine Ark) and Tencent Hunyuan use account-specific
endpoint IDs. Point **OpenAI-Compatible** at their `/v1` URL. Regional China
hosts (`api.moonshot.cn`, `dashscope.aliyuncs.com`, `open.bigmodel.cn`,
`api.minimaxi.com`) are base-URL overrides; keys are region-specific.
