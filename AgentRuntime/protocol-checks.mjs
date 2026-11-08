import http from 'node:http';
import {spawn} from 'node:child_process';
import {mkdtemp,rm,realpath} from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import readline from 'node:readline';
const runtime=process.argv[2] ?? path.dirname(new URL(import.meta.url).pathname), node=process.argv[3] ?? process.execPath;
const event=(name,value)=>`event: ${name}\ndata: ${JSON.stringify(value)}\n\n`;
for(const kind of ['compatible','anthropic','anthropic-optional','gemini','responses','deepseek','openai']) {
 const task=await realpath(await mkdtemp(path.join(os.tmpdir(),'KeyDock-Agent-')));
 let requestCount=0, sawImage=false, sawTool=false;
 const server=http.createServer((req,res)=>{let body='';req.on('data',chunk=>body+=chunk);req.on('end',()=>{sawImage=body.includes('image_url')||body.includes('inlineData')||body.includes('\"type\":\"image\"');
  requestCount++;res.writeHead(200,{'Content-Type':'text/event-stream'});
  const payload=JSON.parse(body), required=kind==='anthropic';
  if((required ? typeof payload.max_tokens!=='number' : payload.max_tokens!==undefined) || payload.max_completion_tokens!==undefined || payload.max_output_tokens!==undefined || payload.generationConfig?.maxOutputTokens!==undefined) { res.end('data: {"error":{"message":"unexpected output limit"}}\n\n'); return; }
  if(kind.startsWith('anthropic')) {
   res.end(event('message_start',{type:'message_start',message:{id:'fixture',type:'message',role:'assistant',model:'fixture-model',content:[],stop_reason:null,usage:{input_tokens:1,output_tokens:0}}})+
    event('content_block_start',{type:'content_block_start',index:0,content_block:{type:'text',text:''}})+event('content_block_delta',{type:'content_block_delta',index:0,delta:{type:'text_delta',text:'Hi'}})+event('content_block_stop',{type:'content_block_stop',index:0})+event('message_delta',{type:'message_delta',delta:{stop_reason:'end_turn',stop_sequence:null},usage:{output_tokens:1}})+event('message_stop',{type:'message_stop'}));
  } else if(kind==='responses') {
   const tool=requestCount===1;
   const item=tool?{type:'function_call',id:'fc_fixture',call_id:'call_fixture',name:'lookup_provider',arguments:JSON.stringify({query:'deepseek'}),status:'completed'}:{type:'message',id:'msg_fixture',role:'assistant',status:'completed',content:[{type:'output_text',text:'Hi',annotations:[]}]};
   const response={id:'resp_fixture_'+requestCount,object:'response',created_at:1,status:'completed',model:'fixture-model',output:[item],usage:{input_tokens:2,output_tokens:1,total_tokens:3}};
   res.end(event('response.created',{type:'response.created',response:{...response,status:'in_progress',output:[]}})+
    event('response.output_item.added',{type:'response.output_item.added',output_index:0,item:tool?{...item,arguments:'',status:'in_progress'}:{...item,content:[],status:'in_progress'}})+
    (tool?event('response.function_call_arguments.delta',{type:'response.function_call_arguments.delta',output_index:0,delta:item.arguments}):event('response.content_part.added',{type:'response.content_part.added',output_index:0,content_index:0,part:{type:'output_text',text:'',annotations:[]}})+event('response.output_text.delta',{type:'response.output_text.delta',output_index:0,content_index:0,delta:'Hi'}))+
    event('response.output_item.done',{type:'response.output_item.done',output_index:0,item})+event('response.completed',{type:'response.completed',response}));
  } else if(kind==='gemini') res.end('data: '+JSON.stringify({candidates:[{content:{role:'model',parts:[{text:'Hi'}]},finishReason:'STOP'}],usageMetadata:{promptTokenCount:1,candidatesTokenCount:1,totalTokenCount:2}})+'\n\n');
  else res.end('data: '+JSON.stringify({id:'fixture',object:'chat.completion.chunk',created:1,model:'fixture-model',choices:[{index:0,delta:{role:'assistant',content:'Hi'},finish_reason:null}]})+'\n\ndata: '+JSON.stringify({id:'fixture',object:'chat.completion.chunk',created:1,model:'fixture-model',choices:[{index:0,delta:{},finish_reason:'stop'}]})+'\n\ndata: [DONE]\n\n');
 });});
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 const child=spawn('/usr/bin/sandbox-exec',['-D','KEYDOCK_TASK_DIR='+task,'-D','KEYDOCK_RUNTIME_DIR='+await realpath(runtime),'-D','KEYDOCK_NODE_DIR='+path.dirname(node),'-f',path.join(runtime,'sandbox.sb'),node,path.join(runtime,'bridge.mjs')],{cwd:task,env:{KEYDOCK_AGENT_CHECKS:'1',PATH:path.dirname(node)+':/usr/bin:/bin:/usr/sbin:/sbin',TMPDIR:task,LANG:'en_US.UTF-8'},stdio:['pipe','pipe','pipe']});
 let stderr='',settled=false;child.stderr.on('data',d=>stderr+=d);const lines=readline.createInterface({input:child.stdout});
 lines.on('line',line=>{const message=JSON.parse(line);if(message.type==='host_tool'){sawTool=message.name==='lookup_provider';child.stdin.write(JSON.stringify({type:'tool_result',id:message.id,result:{ok:true,references:[]}})+'\n');}if(message.type==='settled'){settled=message.text==='Hi'&&!message.error&&!message.budgetExceeded;child.stdin.end();}});
 child.stdin.write(JSON.stringify({type:'start',task:'Say hello without tools.',text:'No secrets.',images:[{type:'image',mimeType:'image/png',data:'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAAXNSR0IArs4c6QAAADhlWElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAAqACAAQAAAABAAAACKADAAQAAAABAAAACAAAAAC2TFloAAAAH0lEQVQIHWNkYGRixgZYFBQUsIkzD6gE44OHj7C6CgAF0gb5Po5OdgAAAABJRU5ErkJggg=='}],service:{kind:kind==='anthropic-optional'?'anthropic':(['deepseek','openai'].includes(kind)?'compatible':kind),requiresOutputLimit:kind==='anthropic',providerHint:kind,baseURL:`http://127.0.0.1:${server.address().port}`,alias:'fixture-only',model:'fixture-model'}})+'\n');
 const timeout=setTimeout(()=>child.kill(),18000);const code=await new Promise(resolve=>child.on('exit',resolve));clearTimeout(timeout);server.close();await rm(task,{recursive:true,force:true});
 if(!settled || requestCount!==(kind==='responses'?2:1) || !sawImage || (kind==='responses'&&!sawTool)){console.error('FAIL',kind,code,requestCount,stderr.slice(-2500));process.exitCode=1;}else console.log('PASS official SDK protocol:',kind);
}
