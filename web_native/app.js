(()=>{
  const $=id=>document.getElementById(id);
  const convo=$('conversation'),profileEl=$('profile'),runtime=$('runtime'),connection=$('connection');
  const historyBackdrop=$('historyBackdrop'),historyList=$('historyList');
  const composerBar=document.querySelector('.composer-bar'),textToggle=$('textToggle');
  const token=()=>{let v=localStorage.getItem('native_voice_token');if(!v){v=prompt('请输入内部访问口令')||'';if(v)localStorage.setItem('native_voice_token',v)}return v};
  const base=location.pathname.endsWith('/')?location.pathname:location.pathname.replace(/[^/]*$/,'');
  const voiceFilters=globalThis.VoiceFilters;
  const mediaSpeech=globalThis.MediaSpeechFilter;

  const HISTORY_PAGE_SIZE=20;
  let ws=null,sessionId=null,storedSessionId=null,reqId=0,pending=new Map(),busy=false,currentAgent=null;
  let historyItems=[],historyLimit=HISTORY_PAGE_SIZE,historyLoading=false,historyHasMore=true;
  let voiceEnabled=false,voiceState='idle',listenHandle=null,bargeStop=null,bargeCapturing=false,turnInterrupted=false;
  let speechWs=null,speechCtx=null,speechNext=0,speechEndTimer=null,speechEndPending=false,speechPausedForUser=false,speechFallback=false,speechComplete=false,speechFullText='',speechAudio=null,playing=false;
  let asrWs=null,asrCtx=null,asrProcessor=null,asrStream=null,asrPcmPending=new Uint8Array(0),asrPreview=null,asrFinalizing=false,asrInterrupted=false,asrStopping=false,asrLastVoiceAt=0,speechStartedAt=0,asrReady=false;
  let turnStartedAt=0,turnFirstTokenAt=0,turnModelLabel='',activity=null;
  let currentSpeechJob=null,activeSpeechJob=null,speechQueue=[];
  let pendingApproval=null,approvalAudio=null;

  function nearBottom(){return convo.scrollHeight-convo.scrollTop-convo.clientHeight<100}
  function scrollIfFollowing(wasNear=true){if(wasNear)requestAnimationFrame(()=>convo.scrollTop=convo.scrollHeight)}
  function clearEmpty(){convo.querySelector('.empty')?.remove()}
  function clock(){return new Date().toLocaleTimeString('zh-CN',{hour12:false})}
  function compactAgentIdentity(label=''){
    const parts=String(label).split('·').map(x=>x.trim()).filter(Boolean),name=profileEl.options[profileEl.selectedIndex]?.text||'Agent';
    const modelIndex=parts.findIndex(x=>/(gpt|deepseek|claude|gemini|qwen|glm|kimi|doubao|llama|mistral)/i.test(x));
    const model=modelIndex>=0?parts[modelIndex]:(parts[1]||'');
    const provider=modelIndex>=0?(parts[modelIndex+1]||''):'';
    return model?`${name} · ${model}${provider?' · '+provider:''}`:name;
  }
  function setAgentMeta(el,identity,timing){
    if(!el)return;let m=el.querySelector('.meta');if(!m){m=document.createElement('span');m.className='meta';el.append(m)}
    const who=document.createElement('span');who.className='meta-identity';who.textContent=compactAgentIdentity(identity);
    const perf=document.createElement('span');perf.className='meta-timing';perf.textContent=timing;m.replaceChildren(who,perf);
  }
  function message(role,text,meta='',stamp=true){const follow=nearBottom();clearEmpty();const el=document.createElement('div');el.className='msg '+role;const body=document.createElement('div');body.className='body';body.textContent=text;el.append(body);const shownMeta=meta?`${meta}${stamp?' · '+clock():''}`:(stamp&&(role==='user'||role==='agent')?clock():'');if(shownMeta){const m=document.createElement('span');m.className='meta';m.textContent=shownMeta;el.append(m)}convo.append(el);scrollIfFollowing(follow);return el}
  function setUserMessageState(el,state){if(!el)return;let m=el.querySelector('.meta');if(!m){m=document.createElement('span');m.className='meta';el.append(m)}m.textContent=`豆包流式ASR · ${state} · ${clock()}`}
  function formatBytes(value){const n=Number(value)||0;if(n<1024)return `${n} B`;if(n<1048576)return `${(n/1024).toFixed(1)} KB`;return `${(n/1048576).toFixed(1)} MB`}
  function renderArtifacts(el,artifacts){
    if(!el||!Array.isArray(artifacts)||!artifacts.length)return;const follow=nearBottom();el.querySelector('.artifacts')?.remove();
    const wrap=document.createElement('div');wrap.className='artifacts';
    for(const artifact of artifacts){
      if(!artifact?.token)continue;const url=base+'api/artifacts/'+encodeURIComponent(artifact.token),name=artifact.name||'附件';
      if(artifact.is_image){
        const card=document.createElement('a');card.className='artifact-image';card.href=url;card.target='_blank';card.rel='noopener';
        const image=document.createElement('img');image.src=url;image.alt=name;image.loading='lazy';image.addEventListener('load',()=>scrollIfFollowing(follow),{once:true});
        const caption=document.createElement('span');caption.textContent=`${name} · ${formatBytes(artifact.size)}`;card.append(image,caption);wrap.append(card);
      }else{
        const card=document.createElement('a');card.className='artifact-file';card.href=url+'?download=1';card.download=name;
        const icon=document.createElement('span');icon.className='artifact-icon';icon.textContent='↓';
        const info=document.createElement('span');info.className='artifact-info';const title=document.createElement('b');title.textContent=name;const detail=document.createElement('small');detail.textContent=`${artifact.mime_type||'文件'} · ${formatBytes(artifact.size)}`;info.append(title,detail);
        const action=document.createElement('span');action.className='artifact-action';action.textContent='下载';card.append(icon,info,action);wrap.append(card);
      }
    }
    if(!wrap.children.length)return;const meta=el.querySelector('.meta');meta?el.insertBefore(wrap,meta):el.append(wrap);scrollIfFollowing(follow);
  }
  function setConnected(ok,text){
    const state=ok?'online':text.includes('连接中')?'connecting':'offline';
    connection.className='conn '+state;connection.textContent=text;
  }
  function wsUrl(path,params={}){const u=new URL(base+path,location.href);u.protocol=location.protocol==='https:'?'wss:':'ws:';Object.entries(params).forEach(([k,v])=>u.searchParams.set(k,v));return u.toString()}
  function rpc(method,params={}){return new Promise((resolve,reject)=>{if(!ws||ws.readyState!==1)return reject(new Error('Hermes未连接'));const id=String(++reqId);pending.set(id,{resolve,reject});ws.send(JSON.stringify({jsonrpc:'2.0',id,method,params}));setTimeout(()=>{if(pending.has(id)){pending.delete(id);reject(new Error(method+'超时'))}},30000)})}
  function ensureActivity(){
    if(activity)return activity;
    const details=document.createElement('details');details.className='activity';
    const summary=document.createElement('summary');
    const sTitle=document.createElement('span');sTitle.textContent='执行过程';
    const sCount=document.createElement('span');sCount.className='activity-count';sCount.textContent='';
    const sStatus=document.createElement('span');sStatus.className='activity-status pending';sStatus.textContent='进行中';
    const chev=document.createElement('span');chev.className='chev';chev.textContent='›';
    summary.append(sTitle,sCount,sStatus,chev);
    const list=document.createElement('div');list.className='activity-list';details.append(summary,list);if(currentAgent&&currentAgent.parentNode===convo)convo.insertBefore(details,currentAgent);else convo.append(details);
    activity={details,summary,list,rows:new Map(),count:0,sTitle,sCount,sStatus};return activity;
  }
  function refreshActivityHeader(){
    if(!activity)return;
    activity.sCount.textContent=activity.count?` · ${activity.count}项`:'';
  }
  function finishActivity(){if(!activity)return;activity.details.open=false;activity.sStatus.textContent='已完成';activity.sStatus.className='activity-status done';activity=null}
  function activityRow(id,title,detail=''){
    const a=ensureActivity();let row=a.rows.get(id);
    if(!row){row=document.createElement('div');row.className='activity-row';const icon=document.createElement('span');icon.className='activity-icon';const label=document.createElement('span');label.className='activity-label';const extra=document.createElement('span');extra.className='activity-detail';row.append(icon,label,extra);a.list.append(row);a.rows.set(id,row);a.count++;refreshActivityHeader()}
    row.querySelector('.activity-label').textContent=title;row.querySelector('.activity-detail').textContent=detail;return row;
  }
  function shortApprovalText(p){
    let text=String(p.description||'').trim()||String(p.command||'').trim()||'执行一项高风险操作';
    text=text.replace(/\s+/g,' ');const chars=Array.from(text);return chars.length>50?chars.slice(0,50).join('')+'…':text;
  }
  function stopApprovalAudio(){if(approvalAudio){approvalAudio.pause();approvalAudio.src='';approvalAudio=null}}
  async function speakApprovalRequest(p){
    if(!voiceEnabled)return;
    stopApprovalAudio();
    try{
      const r=await fetch(base+'api/audio/speak?profile='+encodeURIComponent(profileEl.value),{method:'POST',headers:{'Content-Type':'application/json','X-Voice-Token':token()},body:JSON.stringify({text:`高风险操作需要确认：${shortApprovalText(p)}。请说同意或拒绝。`})});const d=await r.json();if(!r.ok)throw new Error(d.detail||'审批提示播报失败');
      approvalAudio=new Audio(d.data_url);approvalAudio.onended=()=>{approvalAudio=null};approvalAudio.onerror=()=>{approvalAudio=null};await approvalAudio.play();
    }catch(e){message('system','审批语音提示失败：'+e.message)}
  }
  function normalizeVoiceWord(text){return String(text||'').trim().toLowerCase().replace(/^[\s"'“”‘’.,!?;:，。！？；：、]+|[\s"'“”‘’.,!?;:，。！？；：、]+$/g,'')}
  function isApprovalYes(text){return ['同意','允许','可以','执行','允许执行','同意执行'].includes(normalizeVoiceWord(text))}
  function isApprovalNo(text){return ['拒绝','阻止','取消','不要','拒绝执行','阻止执行'].includes(normalizeVoiceWord(text))}
  function renderApproval(p){
    pendingApproval=p;const el=message('approval','');const body=el.querySelector('.body');
    const head=document.createElement('div');head.className='approval-head';
    const badge=document.createElement('span');badge.className='approval-badge';badge.textContent='高风险';
    const title=document.createElement('b');title.textContent='操作需要确认';
    head.append(badge,title);
    const desc=document.createElement('div');desc.className='approval-desc';desc.textContent=shortApprovalText(p);
    const code=document.createElement('pre');code.textContent=p.command||'';
    const status=document.createElement('div');status.className='approval-status';status.textContent='执行已暂停，等待你的决定';
    const actions=document.createElement('div');actions.className='approval-actions';
    const choiceCfg=[['session','允许执行','allow'],['deny','阻止执行','danger']];
    choiceCfg.forEach(([choice,label,cls])=>{const b=document.createElement('button');b.type='button';b.textContent=label;b.className=cls;b.onclick=async()=>{actions.querySelectorAll('button').forEach(x=>x.disabled=true);pendingApproval=null;stopApprovalAudio();status.textContent=choice==='session'?'已允许，正在继续执行':'已阻止，操作未执行';try{await rpc('approval.respond',{session_id:sessionId,choice})}catch(e){status.textContent='审批响应失败：'+e.message}};actions.append(b)});
    body.replaceChildren(head,desc,code,status,actions);if(activity&&activity.sStatus){activity.sStatus.textContent='等待审批';activity.sStatus.className='activity-status pending'}if(voiceEnabled){setVoiceState('approval');void speakApprovalRequest(p)}return el;
  }
  function renderClarify(p){
    const el=message('approval','');const body=el.querySelector('.body');const title=document.createElement('b');title.textContent='需要你的回答';const desc=document.createElement('div');desc.textContent=p.question||'Hermes需要补充信息';const actions=document.createElement('div');actions.className='approval-actions';
    (p.choices||[]).forEach(choice=>{const b=document.createElement('button');b.type='button';b.textContent=choice;b.onclick=async()=>{actions.querySelectorAll('button').forEach(x=>x.disabled=true);try{await rpc('clarify.respond',{session_id:sessionId,request_id:p.request_id,answer:choice})}catch(e){message('system','回答发送失败：'+e.message)}};actions.append(b)});
    body.replaceChildren(title,desc,actions);return el;
  }
  function setVoiceState(state){
    voiceState=state;
    const mic=$('mic');
    mic.querySelector('.mic-label').textContent=voiceEnabled?'关闭实时对话':'开启实时对话';
    mic.setAttribute('aria-pressed',String(voiceEnabled));
    mic.classList.toggle('recording',voiceEnabled&&(state==='listening'||state==='transcribing'));
    mic.classList.toggle('live',voiceEnabled&&(state==='thinking'||state==='speaking'||state==='approval'));
    mic.classList.toggle('listening',voiceEnabled&&state==='listening');
  }

  async function establishSession(){const response=await fetch(base+'api/auth/session',{method:'POST',headers:{'X-Voice-Token':token()},cache:'no-store'});if(!response.ok){let detail='访问口令错误';try{detail=(await response.json()).detail||detail}catch{}throw new Error(detail)}}
  async function connect(){
    closeGateway();setConnected(false,'连接中…');
    try{await establishSession()}catch(e){setConnected(false,'鉴权失败');message('system',e.message);return}
    ws=new WebSocket(wsUrl('api/hermes/ws',{profile:profileEl.value}));
    ws.onopen=()=>setConnected(true,'Hermes已连接');
    ws.onclose=()=>{setConnected(false,'连接断开');busy=false;$('stop').disabled=true;stopVoiceConversation(false)};
    ws.onerror=()=>setConnected(false,'连接失败');
    ws.onmessage=event=>{try{handleFrame(JSON.parse(event.data))}catch(e){console.error(e)}};
  }
  function closeGateway(){if(ws){try{ws.close()}catch{}ws=null}pending.forEach(p=>p.reject(new Error('连接关闭')));pending.clear();sessionId=null;storedSessionId=null;stopVoiceConversation(false);stopSpeech(true)}
  function profileName(){return profileEl.options[profileEl.selectedIndex]?.text||'Agent'}
  function applyRuntimeInfo(info={}){runtime.textContent=`${profileName()} · ${info.model||'模型加载中'}${info.provider?' · '+info.provider:''}`}
  async function createSession(){const r=await rpc('session.create',{cols:100});sessionId=r.session_id;storedSessionId=r.stored_session_id||r.session_key||null;applyRuntimeInfo(r.info||{});if(matchMedia('(min-width:761px)').matches)void openHistory();else void refreshHistoryCount()}
  function historyDate(value){if(!value)return '';return new Date(Number(value)*1000).toLocaleString('zh-CN',{month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',hour12:false})}
  function closeHistory(){if(matchMedia('(min-width:761px)').matches)return;historyBackdrop.hidden=true}
  function renderHistoryRows(sessions){
    const priorScroll=historyList.scrollTop;historyList.replaceChildren();$('historyCount').textContent=sessions.length?(historyHasMore?`${sessions.length}+`:String(sessions.length)):'';
    if(!sessions.length){const empty=document.createElement('p');empty.className='history-empty';empty.textContent='这个Agent还没有历史对话。';historyList.append(empty);return}
    for(const item of sessions){
      const row=document.createElement('div');row.className='history-row';
      const button=document.createElement('button');button.type='button';button.dataset.id=item.id;button.className='history-item'+(item.id===storedSessionId?' active':'');
      const title=document.createElement('span');title.className='history-item-title';title.textContent=item.title||item.preview||'未命名对话';
      const preview=document.createElement('span');preview.className='history-item-preview';preview.textContent=item.preview||'暂无内容预览';
      const meta=document.createElement('span');meta.className='history-item-meta';
      const date=document.createElement('span');date.textContent=historyDate(item.started_at);const count=document.createElement('span');count.textContent=`${item.message_count||0}条`;const source=document.createElement('span');source.textContent=item.source||'Hermes';meta.append(date,count,source);
      button.append(title,preview,meta);button.onclick=()=>void resumeStoredSession(item.id,button);
      const remove=document.createElement('button');remove.type='button';remove.className='history-delete';remove.textContent='删除';remove.title=item.id===storedSessionId?'当前会话不能删除':'删除对话';remove.disabled=item.id===storedSessionId;remove.onclick=e=>{e.stopPropagation();void deleteStoredSession(item.id,item.title||'未命名对话')};
      row.append(button,remove);historyList.append(row);
    }
    if(historyHasMore){const more=document.createElement('p');more.className='history-more';more.textContent=historyLoading?'正在加载更多…':'继续下滑加载更多';historyList.append(more)}
    historyList.scrollTop=priorScroll;
  }
  async function deleteStoredSession(storedId,title){
    if(!confirm(`删除“${title}”及其全部记录？此操作不可撤销。`))return;
    try{await rpc('session.delete',{session_id:storedId});historyItems=await requestHistory(historyLimit);historyHasMore=historyItems.length===historyLimit;renderHistoryRows(historyItems)}catch(e){const empty=document.createElement('p');empty.className='history-empty';empty.textContent='删除失败：'+e.message;historyList.prepend(empty)}
  }
  async function requestHistory(limit){const result=await rpc('session.list',{limit});return Array.isArray(result.sessions)?result.sessions:[]}
  async function requestStoredDetail(storedId){
    const response=await fetch(base+'api/hermes/sessions/'+encodeURIComponent(storedId)+'?profile='+encodeURIComponent(profileEl.value),{headers:{'X-Voice-Token':token()}});const data=await response.json();if(!response.ok)throw new Error(data.detail||'历史详情读取失败');return data;
  }
  async function loadHistory(reset=false){
    if(historyLoading||(!reset&&!historyHasMore))return;const requested=reset?HISTORY_PAGE_SIZE:historyLimit+HISTORY_PAGE_SIZE;historyLoading=true;
    if(reset){historyList.scrollTop=0;historyItems=[];historyHasMore=true}else renderHistoryRows(historyItems);
    try{const sessions=await requestHistory(requested);historyLimit=requested;historyItems=sessions;historyHasMore=sessions.length===requested;renderHistoryRows(historyItems)}catch(e){if(reset){historyList.replaceChildren();const empty=document.createElement('p');empty.className='history-empty';empty.textContent='历史加载失败：'+e.message;historyList.append(empty)}}finally{historyLoading=false;if(historyItems.length)renderHistoryRows(historyItems)}
  }
  async function refreshHistoryCount(){try{const sessions=await requestHistory(HISTORY_PAGE_SIZE);$('historyCount').textContent=sessions.length===HISTORY_PAGE_SIZE?`${HISTORY_PAGE_SIZE}+`:String(sessions.length)}catch{}}
  async function openHistory(){
    historyBackdrop.hidden=false;$('historyProfile').textContent=`${profileName()} · 完整Hermes记录`;historyList.innerHTML='<p class="history-empty">正在加载…</p>';await loadHistory(true)
  }
  function storedMessageTime(value){if(!value)return '';return new Date(Number(value)*1000).toLocaleString('zh-CN',{year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',second:'2-digit',hour12:false})}
  function renderStoredConversation(messages,sessionInfo={},runtimeInfo={}){
    convo.replaceChildren();activity=null;currentAgent=null;pendingApproval=null;
    const fragment=document.createDocumentFragment();let currentModel=sessionInfo.model||runtimeInfo.model||'未知模型',lastUserAt=0;
    for(const item of messages||[]){
      if(item?.display_kind==='model_switch'){let metadata=item.display_metadata;try{if(typeof metadata==='string')metadata=JSON.parse(metadata)}catch{}if(metadata?.model)currentModel=metadata.model;continue}
      const role=item?.role==='assistant'?'agent':item?.role==='user'?'user':null;if(!role)continue;
      const text=typeof item.text==='string'?item.text:(typeof item.content==='string'?item.content:''),timestamp=Number(item.timestamp)||0;if(role==='agent'&&!text&&!item.artifacts?.length)continue;if(role==='user')lastUserAt=timestamp;
      const el=document.createElement('div');el.className='msg '+role;const body=document.createElement('div');body.className='body';body.textContent=text;el.append(body);renderArtifacts(el,item.artifacts);
      if(role==='agent'){const total=timestamp&&lastUserAt&&timestamp>=lastUserAt?timestamp-lastUserAt:null,timing=[total!=null?`总计 ${total.toFixed(1)}s`:'',storedMessageTime(timestamp)].filter(Boolean).join(' · ');setAgentMeta(el,`${profileName()} · ${currentModel}`,timing)}
      else{const meta=document.createElement('span');meta.className='meta';meta.textContent=storedMessageTime(timestamp)||'时间未知';el.append(meta)}
      fragment.append(el);
    }
    if(!fragment.childNodes.length){const empty=document.createElement('p');empty.className='empty';empty.textContent='这个会话还没有消息。';fragment.append(empty)}
    convo.append(fragment);requestAnimationFrame(()=>convo.scrollTop=convo.scrollHeight);
  }
  function setActiveHistory(storedId){historyList.querySelectorAll('.history-row').forEach(row=>{const item=row.querySelector('.history-item'),remove=row.querySelector('.history-delete'),active=item?.dataset.id===storedId;item?.classList.toggle('active',active);if(remove){remove.disabled=active;remove.title=active?'当前会话不能删除':'删除对话'}})}
  async function resumeStoredSession(storedId,button){
    if(busy){message('system','当前任务仍在执行，请先停止后再切换历史对话。');closeHistory();return}
    historyList.querySelectorAll('button').forEach(item=>item.disabled=true);button?.classList.add('active');
    stopVoiceConversation(false);stopSpeech(true);cancelSpeechQueue();
    try{
      const [result,detail]=await Promise.all([rpc('session.resume',{session_id:storedId,cols:100}),requestStoredDetail(storedId).catch(()=>null)]);sessionId=result.session_id;storedSessionId=result.session_key||storedId;const runtimeInfo={...(result.info||{}),...(detail?.session?.model?{model:detail.session.model}:{})};applyRuntimeInfo(runtimeInfo);renderStoredConversation(detail?.messages?.length?detail.messages:(result.messages||[]),detail?.session||{},runtimeInfo);busy=Boolean(result.running);$('stop').disabled=!busy;historyList.querySelectorAll('.history-item').forEach(item=>item.disabled=false);setActiveHistory(storedSessionId);closeHistory();
    }catch(e){historyList.querySelectorAll('button').forEach(item=>item.disabled=false);button?.classList.remove('active');setActiveHistory(storedSessionId);const empty=document.createElement('p');empty.className='history-empty';empty.textContent='恢复失败：'+e.message;historyList.prepend(empty)}
  }

  function cleanMediaText(text){const filter=mediaSpeech?.createMediaSpeechFilter();return filter?filter.push(String(text||''))+filter.flush():String(text||'')}
  function createSpeechJob(){return {text:'',ttsText:'',complete:false,ttsFilter:mediaSpeech?.createMediaSpeechFilter()||null,displayFilter:mediaSpeech?.createMediaSpeechFilter()||null}}
  function handleFrame(frame){
    if(frame.id&&pending.has(String(frame.id))){const p=pending.get(String(frame.id));pending.delete(String(frame.id));frame.error?p.reject(new Error(frame.error.message||'请求失败')):p.resolve(frame.result);return}
    if(frame.method!=='event')return;const ev=frame.params||{},p=ev.payload||{};
    if(ev.type==='gateway.ready'){createSession().catch(e=>message('system',e.message));return}
    if(sessionId&&ev.session_id&&ev.session_id!==sessionId)return;
    if(ev.type==='session.info')applyRuntimeInfo(p);
    else if(ev.type==='message.start'){
      busy=true;$('stop').disabled=false;turnStartedAt=Date.now();turnFirstTokenAt=0;turnModelLabel=runtime.textContent;activity=null;currentAgent=message('agent','',compactAgentIdentity(turnModelLabel));currentSpeechJob=createSpeechJob();if(activeSpeechJob){speechQueue.push(currentSpeechJob)}else activateSpeechJob(currentSpeechJob);asrInterrupted=false;
      if(voiceEnabled){setVoiceState(activeSpeechJob===currentSpeechJob?'thinking':'speaking')}
    }
    else if(ev.type==='message.delta'){
      if(!turnFirstTokenAt)turnFirstTokenAt=Date.now();
      if(!currentAgent)currentAgent=message('agent','',compactAgentIdentity(turnModelLabel||runtime.textContent));
      const text=p.text||p.rendered||'',follow=nearBottom(),displayDelta=currentSpeechJob?.displayFilter?currentSpeechJob.displayFilter.push(text):text;currentAgent.querySelector('.body').textContent+=displayDelta;if(currentSpeechJob){currentSpeechJob.text+=text;const ttsDelta=currentSpeechJob.ttsFilter?currentSpeechJob.ttsFilter.push(text):text;currentSpeechJob.ttsText+=ttsDelta;if(activeSpeechJob===currentSpeechJob)feedSpeech(ttsDelta)}scrollIfFollowing(follow);
    }
    else if(ev.type==='message.complete'){
      const follow=nearBottom(),ended=Date.now(),thinkMs=turnStartedAt?Math.max(0,(turnFirstTokenAt||ended)-turnStartedAt):0,genMs=turnFirstTokenAt?Math.max(0,ended-turnFirstTokenAt):0,totalMs=turnStartedAt?Math.max(0,ended-turnStartedAt):0;
      busy=false;$('stop').disabled=true;const hasFinalText=typeof p.text==='string'||typeof p.rendered==='string',text=typeof p.text==='string'?p.text:(p.rendered||'');
      if(currentAgent&&hasFinalText)currentAgent.querySelector('.body').textContent=cleanMediaText(text);
      if(currentAgent)renderArtifacts(currentAgent,p.artifacts);
      if(currentAgent)setAgentMeta(currentAgent,turnModelLabel||'Agent',`思考 ${(thinkMs/1000).toFixed(1)}s · 生成 ${(genMs/1000).toFixed(1)}s · 总计 ${(totalMs/1000).toFixed(1)}s · ${clock()}`);
      if(currentSpeechJob){
        const tail=currentSpeechJob.ttsFilter?.flush()||'';currentSpeechJob.ttsText+=tail;if(activeSpeechJob===currentSpeechJob)feedSpeech(tail);
        if(hasFinalText){currentSpeechJob.text=text;currentSpeechJob.ttsText=cleanMediaText(text)}
        }
        if(turnInterrupted){stopSpeech(true);turnInterrupted=false}else if(currentSpeechJob){currentSpeechJob.complete=true;if(activeSpeechJob===currentSpeechJob)finishSpeech(currentSpeechJob.ttsText)}
      finishActivity();currentAgent=null;turnStartedAt=0;turnFirstTokenAt=0;scrollIfFollowing(follow);
    }
    else if(ev.type==='tool.start'){
      const id=p.tool_id||`tool-${Date.now()}`,row=activityRow(id,`⏳ ${p.name||'unknown'}`,p.context||p.args_text||'');row.classList.add('tool-step');row.querySelector('.activity-icon').textContent='⏳';if(activity)activity.details.open=true;
    }
    else if(ev.type==='tool.progress'){
      const a=ensureActivity(),row=[...a.rows.values()].find(x=>x.querySelector('.activity-label').textContent.includes(p.name||''));if(row)row.querySelector('.activity-detail').textContent=p.preview||'';
    }
    else if(ev.type==='tool.complete'){
      const id=p.tool_id||`tool-${Date.now()}`,row=activityRow(id,`${p.name||'unknown'}${p.summary?` · ${p.summary}`:''}`,p.duration_s!=null?`耗时 ${Number(p.duration_s).toFixed(2)}s`:'');row.classList.add('tool-step','completed');row.querySelector('.activity-icon').textContent=p.error?'✕':'✓';
    }
    else if(ev.type==='thinking.delta'||ev.type==='reasoning.delta'){
      const a=ensureActivity(),row=activityRow('thinking','思考过程','');a.thinkingText=(a.thinkingText||'')+(p.text||'');row.classList.add('thinking-full');row.querySelector('.activity-icon').textContent='…';row.querySelector('.activity-detail').textContent=a.thinkingText;if(activity)activity.details.open=true;
    }
    else if(ev.type==='approval.request')renderApproval({...p});
    else if(ev.type==='clarify.request')renderClarify({...p});
    else if(ev.type==='status.update'){
      const text=p.text||p.kind||'处理中';
      if(currentAgent||busy){const row=activityRow('status','当前状态',text);row.querySelector('.activity-icon').textContent='•';}
    }
    else if(ev.type==='error'){
      busy=false;$('stop').disabled=true;stopSpeech(true);message('system',p.message||'Hermes执行失败');
      if(voiceEnabled&&!bargeCapturing){stopBargeMonitor();setVoiceState('idle');scheduleListening()}
    }
  }

  async function submit(text,source='文字',options={},existingMessage=null){
    text=(text||'').trim();if(!text||!sessionId)return;
    turnInterrupted=false;const userMessage=existingMessage||message('user',text,source);if(existingMessage)setUserMessageState(userMessage,'提交中');
    try{
      const result=await rpc('prompt.submit',{session_id:sessionId,text,...(options.queued?{queued:true}:{})});
      if(existingMessage)setUserMessageState(userMessage,options.queued?'已排队':'已提交');
      if(voiceEnabled&&options.queued)message('system','已收到补充，当前播报继续；新问题后台排队处理中');
      if(voiceEnabled){setVoiceState(options.queued&&activeSpeechJob?'speaking':'thinking')}
      return result;
    }catch(error){if(existingMessage)setUserMessageState(userMessage,'提交失败');throw error}
  }

  async function interrupt(fromBarge=false){
    if(!sessionId)return;
    if(!fromBarge){turnInterrupted=true;cancelSpeechQueue();stopSpeech(true);stopBargeMonitor()}
    await rpc('session.interrupt',{session_id:sessionId});
    busy=false;$('stop').disabled=true;
    if(voiceEnabled&&!fromBarge){setVoiceState('idle');scheduleListening()}
  }

  async function toggleVoice(){voiceEnabled?stopVoiceConversation(true):await startVoiceConversation()}
  async function startVoiceConversation(){
    for(let i=0;i<50&&!sessionId;i++)await new Promise(r=>setTimeout(r,200));
    if(!sessionId){message('system','Hermes会话尚未就绪');return}
    voiceEnabled=true;asrStopping=false;setVoiceState('connecting');
    try{await startStreamingASR();if(pendingApproval)void speakApprovalRequest(pendingApproval)}catch(e){message('system','无法开启实时ASR：'+e.message);stopVoiceConversation(false)}
  }
  function stopVoiceConversation(show=true){
    voiceEnabled=false;cancelSpeechQueue();listenHandle?.cancel();listenHandle=null;stopBargeMonitor();stopSpeech(true);stopStreamingASR();bargeCapturing=false;setVoiceState('off');
    if(show)message('system','实时语音对话已结束');
  }
  async function stopCurrentVoiceTask(){
    turnInterrupted=true;pendingApproval=null;stopApprovalAudio();stopVoiceConversation(false);
    try{if(sessionId)await rpc('session.interrupt')}catch(e){message('system','停止请求失败：'+e.message)}
    busy=false;$('stop').disabled=true;message('system','已停止当前任务');
  }
  function scheduleListening(){if(voiceEnabled&&!asrWs&&!asrStopping)setTimeout(()=>void startStreamingASR().catch(e=>message('system',e.message)),300)}
  async function startStreamingASR(){
    if(asrWs)return;
    asrStopping=false;asrReady=false;asrPcmPending=new Uint8Array(0);asrInterrupted=false;
    const socket=new WebSocket(wsUrl('api/audio/transcribe-stream',{profile:profileEl.value}));asrWs=socket;
    const ready=new Promise((resolve,reject)=>{
      const timeout=setTimeout(()=>reject(new Error('豆包流式ASR连接超时')),15000);
      socket.onmessage=e=>{
        let m;try{m=JSON.parse(e.data)}catch{return}
        if(m.type==='ready'){asrReady=true;clearTimeout(timeout);resolve();return}
        if(!asrReady)return;
        if(m.type==='transcript')void handleAsrTranscript(m);
        else if(m.type==='error')message('system',m.message||'流式ASR失败');
      };
      socket.onerror=()=>{clearTimeout(timeout);reject(new Error('豆包流式ASR连接失败'))};
      socket.onclose=()=>{clearTimeout(timeout);if(!asrReady)reject(new Error('流式ASR连接断开'));if(asrWs===socket)asrWs=null;stopAsrCapture();if(voiceEnabled&&!asrStopping){message('system','流式ASR已断开，正在重连');scheduleListening()}};
    });
    const capturePromise=startAsrCapture();
    await Promise.all([ready,capturePromise]);
    if(!voiceEnabled){stopStreamingASR();return}
    flushAsrPcm();setVoiceState('listening');
  }
  async function startAsrCapture(){
    if(asrStream)return;
    asrStream=await navigator.mediaDevices.getUserMedia({audio:{channelCount:1,echoCancellation:true,noiseSuppression:true,autoGainControl:true}});
    asrCtx=new AudioContext();await asrCtx.resume();const source=asrCtx.createMediaStreamSource(asrStream),gain=asrCtx.createGain();gain.gain.value=0;
    asrProcessor=asrCtx.createScriptProcessor(4096,1,1);asrProcessor.onaudioprocess=e=>{if(!voiceEnabled||!asrWs||asrWs.readyState!==1)return;const data=e.inputBuffer.getChannelData(0);let sum=0;for(let i=0;i<data.length;i++)sum+=data[i]*data[i];if(Math.sqrt(sum/data.length)>=.025)asrLastVoiceAt=Date.now();queueAsrPcm(floatTo16(downsample(data,asrCtx.sampleRate,16000)))};
    source.connect(asrProcessor);asrProcessor.connect(gain);gain.connect(asrCtx.destination);
  }
  function downsample(data,from,to){if(from===to)return data;const ratio=from/to,len=Math.round(data.length/ratio),out=new Float32Array(len);for(let i=0;i<len;i++){const start=Math.floor(i*ratio),end=Math.min(Math.floor((i+1)*ratio),data.length);let sum=0;for(let j=start;j<end;j++)sum+=data[j];out[i]=sum/Math.max(1,end-start)}return out}
  function floatTo16(data){const out=new Uint8Array(data.length*2),view=new DataView(out.buffer);for(let i=0;i<data.length;i++){const s=Math.max(-1,Math.min(1,data[i]));view.setInt16(i*2,s<0?s*32768:s*32767,true)}return out}
  function flushAsrPcm(){while(asrPcmPending.length>=6400&&asrWs?.readyState===1){asrWs.send(asrPcmPending.slice(0,6400));asrPcmPending=asrPcmPending.slice(6400)}}
  function queueAsrPcm(chunk){
    const merged=new Uint8Array(asrPcmPending.length+chunk.length);merged.set(asrPcmPending);merged.set(chunk,asrPcmPending.length);asrPcmPending=merged;flushAsrPcm();
  }
  function stopAsrCapture(){if(asrProcessor){asrProcessor.disconnect();asrProcessor.onaudioprocess=null;asrProcessor=null}if(asrCtx){asrCtx.close().catch(()=>{});asrCtx=null}if(asrStream){asrStream.getTracks().forEach(t=>t.stop());asrStream=null}asrPcmPending=new Uint8Array(0)}
  function stopStreamingASR(){
    asrStopping=true;stopAsrCapture();clearAsrPreview();const socket=asrWs;asrWs=null;
    if(socket){try{if(socket.readyState===1)socket.send(JSON.stringify({stop:true}));setTimeout(()=>{try{socket.close()}catch{}},300)}catch{}}
  }
  function clearAsrPreview(){if(asrPreview){asrPreview.remove();asrPreview=null}}
  async function handleAsrTranscript(event){
    if(!voiceEnabled)return;const text=(event.text||'').trim();
    if(text){if(!asrPreview)asrPreview=message('user',text,'豆包实时识别');else asrPreview.querySelector('.body').textContent=text}
    if(event.interim&&!event.final){
      if(voiceFilters?.shouldPauseForTranscript(text,speechFullText,playing))void pauseSpeechForUser();
      return;
    }
    if(!event.final||!text||asrFinalizing)return;
    asrFinalizing=true;const preview=asrPreview;asrPreview=null;const discardPreview=()=>preview?.remove();
    try{
      if(voiceFilters?.shouldPauseForTranscript(text,speechFullText,playing))await pauseSpeechForUser();
      if(pendingApproval){
        const approval=pendingApproval;discardPreview();
        if(isStopCommand(text)){await stopCurrentVoiceTask();return}
        if(isApprovalYes(text)||isApprovalNo(text)){
          const choice=isApprovalYes(text)?'session':'deny';pendingApproval=null;stopApprovalAudio();await rpc('approval.respond',{session_id:sessionId,choice});message('system',choice==='session'?'已同意当前会话执行。':'已拒绝当前操作。');await resumeSpeechForUser();return;
        }
        message('system','审批中，请只说“同意”或“拒绝”。');void speakApprovalRequest(approval);await resumeSpeechForUser();return;
      }
      if(isStopCommand(text)){discardPreview();await stopCurrentVoiceTask();return}
      const echo=Boolean((busy||activeSpeechJob)&&voiceFilters?.isLikelyEcho(text,speechFullText));
      if(echo){discardPreview();console.info('[voice-asr] final-filtered-as-echo',{length:text.length,score:voiceFilters.echoScore(text,speechFullText)});await resumeSpeechForUser();return}
      const append=Boolean(busy||activeSpeechJob||speechQueue.length);asrInterrupted=false;
      const submitted=submit(text,'豆包流式ASR',append?{queued:true}:{},preview);await resumeSpeechForUser();await submitted;
      console.info('[voice-asr] final-submitted',{length:text.length,queued:append});
    }catch(e){await resumeSpeechForUser();message('system',e.message)}finally{asrFinalizing=false}
  }
  function isStopCommand(text){const x=String(text||'').trim().toLowerCase().replace(/^[\s"'“”‘’.,!?;:，。！？；：、]+|[\s"'“”‘’.,!?;:，。！？；：、]+$/g,'');return x==='停止'||x==='stop'}

  async function createVadRecorder(options){
    const stream=await navigator.mediaDevices.getUserMedia({audio:{echoCancellation:true,noiseSuppression:true,autoGainControl:true}});
    const type=['audio/webm;codecs=opus','audio/webm','audio/mp4','audio/ogg;codecs=opus','audio/ogg'].find(t=>MediaRecorder.isTypeSupported(t))||'';
    const recorder=new MediaRecorder(stream,type?{mimeType:type}:undefined),chunks=[];
    const context=new AudioContext(),analyser=context.createAnalyser(),data=new Uint8Array(256);analyser.fftSize=256;context.createMediaStreamSource(stream).connect(analyser);
    let frame=null,started=Date.now(),heard=false,silenceSince=null,triggered=false,resolveStop=null;
    const cleanup=()=>{if(frame)cancelAnimationFrame(frame);frame=null;stream.getTracks().forEach(t=>t.stop());context.close().catch(()=>{})};
    const resultPromise=new Promise(r=>resolveStop=r);
    recorder.ondataavailable=e=>{if(e.data.size)chunks.push(e.data)};
    recorder.onstop=()=>{cleanup();resolveStop({audio:new Blob(chunks,{type:recorder.mimeType||type||'audio/webm'}),heardSpeech:heard})};
    recorder.start();
    const tick=()=>{
      analyser.getByteTimeDomainData(data);let sum=0;for(const v of data){const c=v-128;sum+=c*c}const level=Math.min(1,Math.sqrt(sum/data.length)/42),now=Date.now();
      if(level>=options.silenceLevel){heard=true;silenceSince=null}else if(heard){silenceSince??=now;if(!triggered&&now-silenceSince>=options.silenceMs){triggered=true;options.onEndpoint()}}else if(!triggered&&now-started>=options.idleSilenceMs){triggered=true;options.onEndpoint()}
      if(!triggered)frame=requestAnimationFrame(tick);
    };tick();
    return{stop:()=>{if(recorder.state!=='inactive')recorder.stop();return resultPromise},cancel:()=>{recorder.ondataavailable=null;recorder.onstop=null;if(recorder.state!=='inactive')recorder.stop();cleanup();resolveStop(null)}};
  }

  function ensureBargeMonitor(){
    if(!voiceEnabled||bargeStop||listenHandle)return;
    bargeStop=monitorBargeIn({
      isPlaying:()=>playing,
      onSpeech:()=>{
        bargeCapturing=true;turnInterrupted=true;stopSpeech(true);
        if(busy)void interrupt(true).catch(e=>message('system',e.message));
      },
      onUtterance:audio=>{bargeStop=null;void submitBargeUtterance(audio)}
    });
  }
  function stopBargeMonitor(){if(bargeStop){bargeStop();bargeStop=null}}
  async function submitBargeUtterance(audio){
    if(!voiceEnabled){bargeCapturing=false;return}
    if(!audio){bargeCapturing=false;setVoiceState('idle');scheduleListening();return}
    setVoiceState('transcribing');
    try{
      const text=await transcribeBlob(audio);
      if(!text){bargeCapturing=false;setVoiceState('idle');scheduleListening();return}
      if(isStopCommand(text)){bargeCapturing=false;stopVoiceConversation(true);return}
      const deadline=Date.now()+5000;while(busy&&Date.now()<deadline)await new Promise(r=>setTimeout(r,100));
      bargeCapturing=false;await submit(text,'Hermes全双工打断');
    }catch(e){bargeCapturing=false;message('system',e.message);setVoiceState('idle');scheduleListening()}
  }

  function monitorBargeIn({isPlaying,onSpeech,onUtterance}){
    let disposed=false,stream=null,context=null,frame=null,recorder=null,chunks=[],mime='',tripped=false,quietSince=null,trippedAt=0,segmentAt=Date.now();
    const floor=[],recent=[];let floorLocked=false,calibratedSince=null,quietFloor=0,wasPlaying=false,playbackSeen=false,lastPlayingAt=0,graceUntil=0;
    const cleanup=()=>{disposed=true;if(frame)cancelAnimationFrame(frame);frame=null;if(recorder&&recorder.state!=='inactive'){recorder.ondataavailable=null;recorder.onstop=null;try{recorder.stop()}catch{}}recorder=null;context?.close().catch(()=>{});stream?.getTracks().forEach(t=>t.stop())};
    const startSegment=()=>{if(!stream)return;mime=['audio/webm;codecs=opus','audio/webm','audio/mp4','audio/ogg;codecs=opus'].find(t=>MediaRecorder.isTypeSupported(t))||'';recorder=new MediaRecorder(stream,mime?{mimeType:mime}:undefined);chunks=[];recorder.ondataavailable=e=>{if(e.data.size)chunks.push(e.data)};recorder.start(250);segmentAt=Date.now()};
    const rotate=()=>{if(!recorder||recorder.state==='inactive')return;recorder.ondataavailable=null;recorder.onstop=null;recorder.stop();startSegment()};
    const finish=()=>{const active=recorder,type=active?.mimeType||mime||'audio/webm';if(!active||active.state==='inactive'){const audio=chunks.length?new Blob(chunks,{type}):null;cleanup();onUtterance(audio);return}active.onstop=()=>{const audio=chunks.length?new Blob(chunks,{type}):null;cleanup();onUtterance(audio)};active.stop()};
    (async()=>{
      try{
        stream=await navigator.mediaDevices.getUserMedia({audio:{echoCancellation:true,noiseSuppression:true}});if(disposed){cleanup();return}startSegment();
        context=new AudioContext();const analyser=context.createAnalyser(),data=new Uint8Array(256);analyser.fftSize=256;context.createMediaStreamSource(stream).connect(analyser);
        const pushFloor=x=>{floor.push(x);if(floor.length>200)floor.shift();quietFloor=[...floor].sort((a,b)=>a-b)[floor.length>>1]||0};
        const tick=()=>{
          if(disposed)return;analyser.getByteTimeDomainData(data);let sum=0;for(const v of data){const c=v-128;sum+=c*c}const level=Math.min(1,Math.sqrt(sum/data.length)/42),now=Date.now(),playingNow=isPlaying();
          if(!tripped){
            if(!floorLocked){if(!playingNow){calibratedSince??=now;pushFloor(level)}if(playingNow||(calibratedSince!==null&&now-calibratedSince>=400))floorLocked=true}
            if(playingNow&&!wasPlaying){if(!playbackSeen||now-lastPlayingAt>=1000)graceUntil=now+500;playbackSeen=true}wasPlaying=playingNow;if(playingNow)lastPlayingAt=now;
            let trigger=Math.max(.075,quietFloor*3.5);if(playingNow)trigger=Math.min(Math.max(trigger,.14),.37);if(floorLocked&&!playingNow&&level<trigger)pushFloor(level);
            const above=floorLocked&&level>=trigger&&now>=graceUntil;recent.push({above,at:now});while(recent.length&&now-recent[0].at>300)recent.shift();const count=recent.reduce((n,x)=>n+(x.above?1:0),0),span=recent.length?now-recent[0].at:0;
            if(above&&span>=240&&count>=recent.length*.8){tripped=true;trippedAt=now;quietSince=null;onSpeech()}else if(!above&&now-segmentAt>=5000)rotate();
          }else{
            if(level>=.075)quietSince=null;else quietSince??=now;
            if((quietSince&&now-quietSince>=1250)||now-trippedAt>=30000){finish();return}
          }
          frame=requestAnimationFrame(tick);
        };tick();
      }catch{cleanup();onUtterance(null)}
    })();
    return cleanup;
  }

  function cancelSpeechQueue(){currentSpeechJob=null;activeSpeechJob=null;speechQueue=[]}
  async function pauseSpeechForUser(){
    if(speechPausedForUser||!playing)return false;speechPausedForUser=true;
    if(speechEndTimer){clearTimeout(speechEndTimer);speechEndTimer=null;speechEndPending=true}
    try{if(speechCtx?.state==='running')await speechCtx.suspend();if(speechAudio&&!speechAudio.paused)speechAudio.pause()}catch{}
    if(voiceEnabled)setVoiceState('listening');console.info('[voice-asr] playback-paused-for-user');return true;
  }
  async function resumeSpeechForUser(){
    if(!speechPausedForUser)return false;speechPausedForUser=false;
    try{if(speechCtx?.state==='suspended')await speechCtx.resume();if(speechAudio?.paused)await speechAudio.play()}catch{}
    if(speechEndPending){speechEndPending=false;scheduleSpeechEnd()}else if(voiceEnabled&&playing)setVoiceState('speaking');console.info('[voice-asr] playback-resumed');return true;
  }
  function activateSpeechJob(job){activeSpeechJob=job;startSpeech();const prepared=job.complete?job.text:job.ttsText;if(prepared)feedSpeech(prepared);if(job.complete)finishSpeech(job.text)}
  function startNextSpeechJob(){if(!activeSpeechJob&&speechQueue.length)activateSpeechJob(speechQueue.shift())}
  function startSpeech(){
    stopSpeech(true);speechFallback=false;speechComplete=false;speechFullText='';
    speechWs=new WebSocket(wsUrl('api/audio/speak-stream',{profile:profileEl.value}));speechWs.binaryType='arraybuffer';
    speechWs.onopen=()=>{if(speechFullText&&!speechFallback)speechWs.send(JSON.stringify({text:speechFullText}));if(speechComplete&&!speechFallback)speechWs.send(JSON.stringify({done:true}))};
    speechWs.onmessage=e=>{
      if(typeof e.data==='string'){
        const m=JSON.parse(e.data);
        if(m.type==='start'){playing=true;speechStartedAt=Date.now();if(voiceEnabled)setVoiceState('speaking');speechCtx=new AudioContext({sampleRate:m.sample_rate||24000});speechNext=speechCtx.currentTime+.03}
        else if(m.type==='end')scheduleSpeechEnd()
        else if(m.type==='fallback'){speechFallback=true;if(speechComplete)void speakFallback(speechFullText)}
      }else if(speechCtx)playPcm(e.data);
    };
  }
  function feedSpeech(text){if(!text)return;speechFullText+=text;if(!speechFallback&&speechWs?.readyState===1)speechWs.send(JSON.stringify({text}))}
  function finishSpeech(text=''){
    speechComplete=true;if(text!==speechFullText)speechFullText=text;
    if(!speechFullText.trim()){speechEnded();return}
    if(speechFallback){void speakFallback(speechFullText);return}
    if(speechWs?.readyState===1)speechWs.send(JSON.stringify({done:true}));
  }
  async function speakFallback(text){
    if(!text)return;
    try{
      const r=await fetch(base+'api/audio/speak?profile='+encodeURIComponent(profileEl.value),{method:'POST',headers:{'Content-Type':'application/json','X-Voice-Token':token()},body:JSON.stringify({text})});const d=await r.json();if(!r.ok)throw new Error(d.detail||'TTS失败');
      speechAudio=new Audio(d.data_url);playing=true;if(voiceEnabled)setVoiceState('speaking');speechAudio.onended=speechEnded;speechAudio.onerror=speechEnded;await speechAudio.play();
    }catch(e){message('system','Hermes TTS失败：'+e.message);speechEnded()}
  }
  function scheduleSpeechEnd(){
    if(speechEndTimer){clearTimeout(speechEndTimer);speechEndTimer=null}
    if(speechPausedForUser){speechEndPending=true;return}
    if(!speechCtx){speechEnded();return}
    const remaining=Math.max(0,speechNext-speechCtx.currentTime);
    speechEndTimer=setTimeout(()=>{speechEndTimer=null;speechEnded()},Math.max(40,remaining*1000+40));
  }
  function stopSpeech(preserveBarge=false){
    if(speechEndTimer){clearTimeout(speechEndTimer);speechEndTimer=null}
    if(speechWs){try{if(speechWs.readyState===1)speechWs.send(JSON.stringify({stop:true}));speechWs.close()}catch{}speechWs=null}
    if(speechAudio){speechAudio.pause();speechAudio.src='';speechAudio=null}
    if(speechCtx){speechCtx.close().catch(()=>{});speechCtx=null}speechNext=0;playing=false;speechPausedForUser=false;speechEndPending=false;
    if(!preserveBarge)stopBargeMonitor();
  }
  function speechEnded(){const ended=activeSpeechJob;stopSpeech(true);if(ended&&activeSpeechJob===ended)activeSpeechJob=null;if(speechQueue.length){startNextSpeechJob();return}if(voiceEnabled&&!bargeCapturing){stopBargeMonitor();setVoiceState('idle');scheduleListening()}}
  function playPcm(buffer){const view=new DataView(buffer),samples=new Float32Array(buffer.byteLength/2);for(let i=0;i<samples.length;i++)samples[i]=view.getInt16(i*2,true)/32768;const rate=speechCtx.sampleRate||24000,audio=speechCtx.createBuffer(1,samples.length,24000);audio.copyToChannel(samples,0);const src=speechCtx.createBufferSource();src.buffer=audio;src.connect(speechCtx.destination);speechNext=Math.max(speechNext,speechCtx.currentTime+.02);src.start(speechNext);speechNext+=audio.duration}

  function syncComposer(){const t=$('text'),v=t.value.trim(),s=document.querySelector('.send');if(s)s.disabled=!v;t.style.height='auto';t.style.height=Math.min(t.scrollHeight,200)+'px'}
  function setTextComposer(open){
    composerBar.classList.toggle('text-open',open);textToggle.setAttribute('aria-expanded',String(open));
    if(open)setTimeout(()=>$('text').focus(),0);
  }
  $('composer').onsubmit=e=>{e.preventDefault();const text=$('text').value;if(!text.trim())return;$('text').value='';syncComposer();if(matchMedia('(max-width:640px)').matches)setTextComposer(false);submit(text).catch(err=>message('system',err.message))};
  $('text').addEventListener('input',syncComposer);syncComposer();
  textToggle.onclick=()=>setTextComposer(textToggle.getAttribute('aria-expanded')!=='true');
  $('mic').onclick=()=>void toggleVoice();
  $('stop').onclick=()=>interrupt(false).catch(e=>message('system',e.message));
  $('historyButton').onclick=()=>void openHistory();
  historyList.addEventListener('scroll',()=>{if(historyList.scrollHeight-historyList.scrollTop-historyList.clientHeight<100)void loadHistory(false)});
  $('historyClose').onclick=closeHistory;
  historyBackdrop.onclick=e=>{if(e.target===historyBackdrop)closeHistory()};
  window.addEventListener('keydown',e=>{if(e.key==='Escape'&&!historyBackdrop.hidden)closeHistory()});
  $('newSession').onclick=()=>{closeHistory();convo.innerHTML='<p class="empty">新对话已创建。</p>';connect()};
  profileEl.onchange=()=>{closeHistory();$('historyCount').textContent='';convo.innerHTML='<p class="empty">已切换Agent，正在创建独立Hermes会话。</p>';connect()};
  window.addEventListener('beforeunload',closeGateway);setVoiceState('off');connect();
})();
