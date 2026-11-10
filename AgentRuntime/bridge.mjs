// Official Pi SDK owns planning, tool dispatch, conversation and recovery.
// This adapter only maps the native host's credential capabilities onto SDK tools.
import readline from 'node:readline';
import path from 'node:path';
import { mkdir, readFile } from 'node:fs/promises';
import { Type } from 'typebox';
import { createAgentSession, DefaultResourceLoader, ModelRuntime, SessionManager, SettingsManager } from '@earendil-works/pi-coding-agent';
import { streamSimple as sdkStreamSimple } from '@earendil-works/pi-ai/compat';

const send = value => process.stdout.write(JSON.stringify(value) + '\n');
const waiting = new Map();
let session, started = false, stopping = false, running = false, turns = 0, toolCalls = 0, budgetExceeded = false;
function host(name, args, signal) {
  const id = crypto.randomUUID();
  return new Promise((resolve, reject) => {
    const abort = () => { waiting.delete(id); reject(new Error('Operation aborted')); };
    if (signal?.aborted) return abort();
    signal?.addEventListener('abort', abort, { once: true });
    waiting.set(id, { resolve(value) { signal?.removeEventListener('abort', abort); resolve(value); }, reject });
    send({ type: 'host_tool', id, name, args });
  });
}
const str = description => Type.String({ description });
const optional = description => Type.Optional(str(description));
function withoutOptionalOutputLimits(payload, requiredMessagesLimit) {
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) return payload;
  const result = {...payload};
  for (const name of ['max_tokens','max_completion_tokens','max_output_tokens']) {
    if (name !== 'max_tokens' || !requiredMessagesLimit) delete result[name];
  }
  for (const name of ['generationConfig','config']) {
    if (result[name] && typeof result[name] === 'object') {
      result[name] = {...result[name]}; delete result[name].maxOutputTokens;
    }
  }
  return result;
}
const definitions = [
  ['lookup_provider', '查阅厂商接入资料', 'Look up researched provider references: documented protocols, exact base URLs, authentication, model discovery, balance capability and regional restrictions. These are references, not proof of account access. Use only the user-matched provider, region and workspace. Read linked docs when details are missing or conflict.', Type.Object({query:optional('Provider ID or name; omit to return references matching the supplied user material')})],
  ['ask_user', '等待补充资料', 'Ask the user a specific question only when the supplied materials, documentation and safe probes cannot resolve it. The user can reply with text and images here; the same task continues with its existing context. State exactly what is missing and why, combine related questions and give an example when useful. Never use this for a service outage or a tool error that you can repair.', Type.Object({question:str('Specific user-facing question in Chinese'),reason:optional('What you tried and why this input is necessary'),items:Type.Optional(Type.Array(str('A concrete item to provide'))),example:optional('Example input, without invented credentials')})],
  ['list_models', '获取支持的模型', 'Fetch the actual model list for a draft using its native authentication. Use when the model is unknown or to inspect supported IDs; the list alone does not prove inference access. Preserve actual deployment IDs. An unavailable catalog is not proof of an invalid key.', Type.Object({id:str('Draft ID')})],
  ['fetch_document', '读取接口文档', 'Download a document into the task workspace without credentials or cookies. Returns its local path and observed access status. Read the relevant contents, follow links and write extraction scripts as needed. Login pages are not readable documentation.', Type.Object({ url: str('Document URL provided by the user or linked from previously retrieved documentation') })],
  ['propose_credential', '整理候选配置', 'Create or revise a local draft. Keys must use original KEYDOCK_SECRET identifiers or exact visible image values. This does not save to the vault. Returns draft ID, issues, retained model count and verified status. Editing descriptions preserves verification; changing connection, authentication, protocol or model clears it.', Type.Object({ id: optional('Existing draft ID when revising'), name: optional('Name'), provider: optional('Provider'), base_url: str('Exact API base URL found in supplied materials or documentation'), api_key: str('Original secret identifier, never invent a key'), model: optional('Actual model or deployment ID'), models: Type.Optional(Type.Array(str('Model ID returned by list_models for this same draft configuration, or found verbatim in user material or fetched document body; not proof of inference permissions'))), docs_url: optional('Documentation URL'), purpose: optional('Purpose'), notes: optional('Optional polished notes: usually 1-3 short factual lines of special requirements only. Leave empty when dedicated fields suffice; never repeat address, authentication, model list, verification status or generic caveats'), notes_sections: Type.Optional(Type.Object({access:Type.Optional(Type.Array(str('Useful connection detail, not already in a dedicated field'))),limits:Type.Optional(Type.Array(str('Documented restriction or regional/account caveat'))),pending:Type.Optional(Type.Array(str('Unresolved item and concrete next step')))})), tags: optional('Comma separated labels'), kind: Type.Union(['compatible','anthropic','responses','gemini','custom'].map(v => Type.Literal(v))), auth: Type.Optional(Type.Union(['bearer','xAPIKey','apiKey','googleKey','none'].map(v => Type.Literal(v)))), extra_headers: optional('Documented non-authentication headers, one per line, preserve original secret identifiers') })],
  ['verify_credential', '验证候选配置', 'Execute a real low-volume probe through the native host. The host injects the actual credential. Optional relative request path, JSON body and headers let you adapt to documented protocols instead of a fixed template. Inspect observed errors and correct the draft or request, then retry. HTTP 200 alone does not prove model inference.', Type.Object({ id: str('Draft ID'), method: Type.Optional(Type.Union([Type.Literal('GET'),Type.Literal('POST')])), path: optional('Endpoint relative to Base URL, e.g. chat/completions or /chat/completions, without repeating /v1; omit for the default probe'), body: optional('JSON object encoded as a string, minimal input and small output budget'), headers: optional('Additional documented non-authentication headers, one per line') })],
  ['finish_import', '提交核验结果', 'Return checked drafts for user review. Only real host verification can mark a draft successful. Report unread documentation and unresolved failures honestly. Do not silently drop credentials from the original materials.', Type.Object({ ids: Type.Array(str('Draft ID')), summary: str('Concise user-facing result, including remaining issues and unread documents') })],
];
const customTools = definitions.map(([name,label,description,parameters]) => ({ name,label,description,parameters,
  executionMode:'sequential',
  async execute(_callId,args,signal) {
    const result = await host(name,args,signal);
    if(name==='ask_user') {
      const {images=[],...reply}=result;
      return {content:[{type:'text',text:JSON.stringify(reply)},...images],details:{}};
    }
    return { content: [{type:'text',text:JSON.stringify(result)}], details: {} };
  }
}));
async function start(config) {
  const cwd = process.cwd(), agentDir = path.join(cwd,'.pi-task');
  await mkdir(agentDir,{recursive:true});
  const settingsManager = SettingsManager.inMemory({ compaction: { enabled: true }, retry: { enabled: false }, shellPath: '/bin/bash' });
  const modelRuntime = await ModelRuntime.create({ authPath:path.join(agentDir,'unused-auth.json'), modelsPath:null, modelsStorePath:path.join(agentDir,'model-cache.json'), allowModelNetwork:false, refreshOnCreate:false });
  const api = { compatible:'openai-completions', anthropic:'anthropic-messages', responses:'openai-responses', gemini:'google-generative-ai' }[config.service.kind];
  if (!api) throw new Error('Unsupported organizer protocol');
  const providerID = ['deepseek','moonshot','openai'].includes(config.service.providerHint) ? config.service.providerHint : 'keydock';
  const streamWithOutputPolicy = (model, context, options = {}) => sdkStreamSimple(model, context, {...options,
    onPayload: async (payload, currentModel) => withoutOptionalOutputLimits((await options.onPayload?.(payload,currentModel)) ?? payload, api === 'anthropic-messages' && (config.service.requiresOutputLimit ?? true))
  });
  modelRuntime.registerProvider(providerID, { api, streamSimple:streamWithOutputPolicy, baseUrl:config.service.baseURL, apiKey:config.service.alias, models:[{ id:config.service.model, name:config.service.model, api, reasoning:false, input:['text','image'], contextWindow:128000, maxTokens:8192, cost:{input:0,output:0,cacheRead:0,cacheWrite:0}, compat:{supportsDeveloperRole:false,supportsStore:false} }] });
  await modelRuntime.setRuntimeApiKey(providerID,config.service.alias);
  const instructions = config.systemPrompt === undefined
    ? await readFile(new URL('./prompts/credential-import.md', import.meta.url), 'utf8')
    : config.systemPrompt;
  if (typeof instructions !== 'string' || !instructions.trim()) throw new Error('Agent 提示词不能为空，请在系统设置中编辑。');
  const loader = new DefaultResourceLoader({ cwd,agentDir,settingsManager,noExtensions:true,noSkills:true,noPromptTemplates:true,noThemes:true,noContextFiles:true,systemPromptOverride:() => instructions,appendSystemPromptOverride:() => [] });
  await loader.reload();
  ({session} = await createAgentSession({ cwd,agentDir,settingsManager,modelRuntime,model:modelRuntime.getModel(providerID,config.service.model),thinkingLevel:'off',resourceLoader:loader,sessionManager:SessionManager.inMemory(cwd),tools:['read','write','edit','bash',...definitions.map(d=>d[0])],customTools }));
  const toolLabels = {read:'读取资料',write:'编写临时代码',edit:'调整临时代码',bash:'运行临时命令',fetch_document:'获取接口文档',lookup_provider:'查阅厂商资料',list_models:'获取模型列表',ask_user:'等待你的回复',propose_credential:'整理候选配置',verify_credential:'发起实际验证',finish_import:'汇总结果'};
  let assistantText = '', assistantSequence = 0;
  const textOf = result => (result?.content ?? []).filter(item => item.type === 'text').map(item => item.text).join('\n').slice(-12000);
  // The host applies the user's display preference and redacts persisted logs.
  const logArgs = args => JSON.stringify(args, null, 2).slice(0,12000);
  session.subscribe(event => {
    if(event.type==='message_start' && event.message?.role==='assistant') { assistantText=''; assistantSequence++; }
    if(event.type==='message_update' && event.assistantMessageEvent?.type==='text_delta') {
      assistantText=(assistantText+event.assistantMessageEvent.delta).slice(-12000);
    }
    if(event.type==='message_end' && event.message?.role==='assistant' && assistantText.trim()) send({type:'narration',id:String(assistantSequence),text:assistantText});
    if(event.type==='tool_execution_start') send({type:'activity',id:event.toolCallId,tool:event.toolName,label:toolLabels[event.toolName]??event.toolName,state:'running',detail:logArgs(event.args)});
    if(event.type==='tool_execution_update') send({type:'activity',id:event.toolCallId,tool:event.toolName,label:toolLabels[event.toolName]??event.toolName,state:'running',output:textOf(event.partialResult)});
    if(event.type==='tool_execution_end') send({type:'activity',id:event.toolCallId,tool:event.toolName,label:toolLabels[event.toolName]??event.toolName,state:event.isError?'failed':'completed',output:textOf(event.result)});

    if (event.type==='turn_start') {
      turns++; send({type:'progress',label:'正在等待整理模型回复',turn:turns});
      if(turns>32) { budgetExceeded=true; void session.abort(); }
    }
    if (event.type==='tool_execution_start') {
      toolCalls++; send({type:'progress',label:toolLabels[event.toolName] ?? '正在处理',tool:event.toolName});
      if(toolCalls>96) { budgetExceeded=true; void session.abort(); }
    }
  });
  await prompt((config.task ? config.task+'\n\n' : '')+'已核对的厂商参考资料（不是账户验证结果）：\n'+JSON.stringify(config.providerReferences??[])+'\n\n以下是用户资料与整理要求（敏感片段已编号）：\n'+config.text,config.images);
}
async function prompt(text,images=[]) {
  await session.prompt(text,{images});
  if(stopping) throw new Error('Operation aborted');
  const last=session.messages.findLast(m=>m.role==='assistant');
  running=false;
  send({type:'settled',turns,toolCalls,text:session.getLastAssistantText() ?? '',error:budgetExceeded?'本次任务已达到运行上限，请核对已有结果后重试。':last?.errorMessage ?? '',budgetExceeded});
}
function failed(error) {
  running=false;
  send({type:'activity',id:'runtime-error-'+crypto.randomUUID(),tool:'runtime',label:'运行时错误',state:'failed',output:String(error.stack ?? error.message ?? error).slice(0,12000)});
  if(process.env.KEYDOCK_AGENT_CHECKS==='1') console.error(error.stack);
  send({type:'failed',message:String(error.message ?? 'Agent 未完成，资料已保留。').slice(0,2000)});
}
const lines = readline.createInterface({input:process.stdin,crlfDelay:Infinity});
lines.on('line', line => {
  try {
    const message = JSON.parse(line);
    if(message.type==='tool_result') { waiting.get(message.id)?.resolve(message.result); waiting.delete(message.id); }
    else if(message.type==='start' && !started) { started=true; running=true; void start(message).catch(failed); }
    else if(message.type==='continue' && session && !running && !stopping) { running=true; void prompt('用户补充：\n'+message.text,message.images).catch(failed); }
    else if(message.type==='supplement' && session && !stopping) { void (async()=>{ if(running) await session.steer('用户补充：\n'+message.text,message.images??[]); else { running=true; await prompt('用户补充：\n'+message.text,message.images??[]); } })().catch(failed); }
    else if(message.type==='cancel') { stopping=true; void session?.abort(); }
  } catch { send({type:'failed',message:'Agent 通信格式错误。'}); }
});
lines.on('close',()=>{ stopping=true; void session?.abort().finally(()=>session?.dispose()); });
process.on('SIGTERM',()=>{ stopping=true; void session?.abort(); setTimeout(()=>process.exit(0),1500).unref(); });
