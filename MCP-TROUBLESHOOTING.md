# MCP (Model Context Protocol) Troubleshooting Guide

## Overview
This document captures the troubleshooting journey for enabling MCP tools with the GenAI Playground on OpenShift AI 3.0.

---

## Environment
- **Model**: Qwen3-0.6B
- **Deployment**: LLMInferenceService with LLM-D (disaggregated inference)
- **Platform**: OpenShift AI 3.0 on ROSA
- **GPU**: Tesla T4

---

## Issue 1: MCP Tools Not Appearing in Playground

### Symptom
- MCP servers listed in Playground but "View tools" button is **disabled**
- Lock icon showing in "Auth" column

### Root Cause
MCP servers require authentication to list tools.

### Solution
1. Click "Configure" button (gear icon) next to the MCP server
2. Enter the API token in the "Access token" field
3. Click "Authorize"

### Verification
After authorization, the "View tools" button becomes **enabled** and shows available tools.

---

## Issue 2: Model Returns 400 Bad Request When MCP Enabled

### Symptom
- Model works fine without MCP
- When MCP tools are enabled, vLLM returns `400 Bad Request`

### Root Cause
vLLM doesn't have tool calling enabled by default. When LlamaStack sends a request with `tools` parameter, vLLM rejects it.

### Solution
Add tool calling flags to vLLM:

```bash
# Patch the LLMInferenceService
oc patch llminferenceservice qwen3-0-6b -n my-first-model --type='json' -p='[
  {
    "op": "replace",
    "path": "/spec/template/containers/0/env/2/value",
    "value": "--dtype=half --max-model-len=4096 --gpu-memory-utilization=0.85 --enforce-eager --enable-auto-tool-choice --tool-call-parser hermes"
  }
]'
```

### Key Flags
| Flag | Description |
|------|-------------|
| `--enable-auto-tool-choice` | Enables tool/function calling support |
| `--tool-call-parser` | Parser for tool call format (options: `hermes`, `qwen3_xml`, `llama3_json`, etc.) |

### Parser Options for Different Models
| Model | Recommended Parser |
|-------|-------------------|
| Qwen3 | `hermes` or `qwen3_xml` |
| Llama3 | `llama3_json` |
| Mistral | `mistral` |
| Generic | `hermes` |

---

## Issue 3: Invalid Tool Call Parser

### Symptom
vLLM pod crashes with error:
```
KeyError: 'invalid tool call parser: qwen (chose from { deepseek_v3, hermes, llama3_json, ... })'
```

### Root Cause
Using incorrect parser name. `qwen` is not valid; use `qwen3_xml` or `hermes`.

### Solution
Use a valid parser name from the supported list.

---

## Issue 4: Model Recognizes Tool But Doesn't Execute It

### Symptom
Model's thinking shows it understands the tool:
```
<think>
Let me check the tools available. There's a function called get_current_weather...
I need to call that function with the city parameter set to "Paris".
</think>
```

But then it doesn't output the actual tool call.

### Investigation

**Direct API Test:**
```bash
curl -k -s "https://qwen3-0-6b-kserve-workload-svc:8000/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen3-0.6B",
    "messages": [{"role": "user", "content": "What is weather in Paris?"}],
    "tools": [{
      "type": "function",
      "function": {
        "name": "get_weather",
        "description": "Get weather",
        "parameters": {
          "type": "object",
          "properties": {"city": {"type": "string"}},
          "required": ["city"]
        }
      }
    }],
    "max_tokens": 300
  }'
```

**Actual Response:**
```json
{
  "content": "<think>...</think>\n\n<tool_call>\n{\"name\": \"get_weather\", \"arguments\": {\"city\": \"Paris\"}}\n</tool_call>",
  "tool_calls": []  // <-- EMPTY!
}
```

### Root Cause
The model IS generating correct tool call XML:
```xml
<tool_call>
{"name": "get_weather", "arguments": {"city": "Paris"}}
</tool_call>
```

But vLLM's parser returns `tool_calls: []` - the parser isn't extracting the tool call from the response!

### Possible Causes
1. **Parser mismatch**: `qwen3_xml` parser may not handle `<think>` tags before `<tool_call>`
2. **vLLM version issue**: Parser implementation may have bugs
3. **Model output format**: Model may not be generating the exact format the parser expects

### Solution: Use `hermes` Parser Instead of `qwen3_xml`

**The `hermes` parser correctly extracts tool calls!**

```bash
oc patch llminferenceservice qwen3-0-6b -n my-first-model --type='json' -p='[
  {
    "op": "replace",
    "path": "/spec/template/containers/0/env/2/value",
    "value": "--dtype=half --max-model-len=4096 --gpu-memory-utilization=0.85 --enforce-eager --enable-auto-tool-choice --tool-call-parser hermes"
  }
]'
```

**Before (qwen3_xml parser):**
```json
{
  "content": "<tool_call>{\"name\": \"get_weather\", \"arguments\": {\"city\": \"Tokyo\"}}</tool_call>",
  "tool_calls": []  // EMPTY - parser failed
}
```

**After (hermes parser):**
```json
{
  "content": "<think>...</think>",
  "tool_calls": [
    {
      "id": "chatcmpl-tool-xxx",
      "type": "function",
      "function": {
        "name": "get_weather",
        "arguments": "{\"city\": \"Tokyo\"}"
      }
    }
  ],
  "finish_reason": "tool_calls"  // Properly detected!
}
```

---

## Issue 5: Weather MCP Server Authentication

### Symptom
Weather MCP server requires API token but storing in ConfigMap is insecure.

### Bad Practice (Don't Do This)
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: gen-ai-aa-mcp-servers
data:
  Weather: |
    {
      "url": "https://weather-server.example.com/mcp?token=SECRET_TOKEN",  # BAD!
      "description": "Weather API"
    }
```

### Best Practice
1. Store URL without token in ConfigMap:
```yaml
Weather: |
  {
    "url": "https://weather-server.example.com/mcp",
    "description": "Get real-time weather data. Requires Apify API token."
  }
```

2. Enter token via Playground UI:
   - Click "Configure" button
   - Enter token in "Access token" field
   - Token is stored securely (likely in Kubernetes Secret)

---

## Useful Commands

### Check vLLM Logs
```bash
oc logs <vllm-pod> -n <namespace> --tail=50
```

### Check LlamaStack Logs
```bash
oc logs <llamastack-pod> -n <namespace> --tail=50
```

### Test Tool Calling Directly
```bash
oc run curl-test --rm -i --restart=Never --image=curlimages/curl -n <namespace> -- \
  curl -k -s "https://<vllm-service>:8000/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"<model-name>","messages":[{"role":"user","content":"test"}],"tools":[...]}'
```

### View MCP Session Connections
```bash
oc logs <llamastack-pod> -n <namespace> | grep -i "mcp\|session"
```

---

## Components Status Checklist

| Component | How to Verify | Expected |
|-----------|--------------|----------|
| vLLM Model | `oc get pods` | 1/1 Running |
| vLLM Tool Parser | Check logs for "Successfully import tool parser" | Parser loaded |
| LlamaStack | `oc get pods` | 1/1 Running |
| MCP Connection | Check logs for "Received session ID" | Session established |
| MCP Tools | Click "View tools" in Playground | Tools listed |
| Tool Execution | Check `tool_calls` array in API response | Contains tool calls |

---

## Key Learnings

1. **MCP requires proper vLLM configuration** - Tool calling must be explicitly enabled
2. **Parser choice matters** - Different models need different parsers
3. **Authentication is per-session** - Tokens entered in GUI are session-specific
4. **Model size affects capability** - Smaller models (0.6B) may struggle with tool calling
5. **Always test with direct API calls** - Helps isolate issues between layers

---

## Status: ✅ FULLY RESOLVED

### Solution Summary
Use `--tool-call-parser hermes` instead of `qwen3_xml` for Qwen3 models.

### All Tests Passed:
- [x] `hermes` parser instead of `qwen3_xml` - **WORKS!**
- [x] `tool_calls` array gets populated correctly
- [x] **End-to-end MCP tool execution in Playground - SUCCESS!**

### Verified Working Example
**User Query:** "What is the weather of Kuala Lumpur?"

**Model Response:**
```
<think> 
Okay, the user is asking about the weather in Kuala Lumpur. 
Let me check the tools available. There's a function called get_current_weather...
</think>

The weather in Kuala Lumpur is Overcast with a temperature of 25.4°C 
and a relative humidity of 87%. The dew point temperature at 2 meters is 23.1°C.
```

**Tool Call Made:**
```json
{
  "name": "get_current_weather",
  "arguments": {"city": "Kuala Lumpur"}
}
```

**Weather API Response:**
```
Overcast, 25.4°C, Humidity: 87%, Dew point: 23.1°C
```

### Key Finding
The `qwen3_xml` parser doesn't properly handle the `<think>` tags that Qwen3 outputs before `<tool_call>` tags. The `hermes` parser correctly extracts tool calls regardless of thinking tags.

### Final Configuration
```yaml
VLLM_ADDITIONAL_ARGS: "--dtype=half --max-model-len=4096 --gpu-memory-utilization=0.85 --enforce-eager --enable-auto-tool-choice --tool-call-parser hermes"
```

*Last updated: January 11, 2026*
