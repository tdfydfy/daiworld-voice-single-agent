(function(root,factory){
  const api=factory();
  if(typeof module==='object'&&module.exports)module.exports=api;
  if(root)root.VoiceFilters=api;
})(typeof globalThis!=='undefined'?globalThis:this,function(){
  function normalize(text){
    return String(text||'').toLowerCase().replace(/[\s\p{P}\p{S}]/gu,'');
  }

  function echoScore(transcript,spoken){
    const a=normalize(transcript),b=normalize(spoken);
    if(a.length<4||b.length<4)return 0;
    const spokenPairs=new Set();
    for(let i=0;i<b.length-1;i++)spokenPairs.add(b.slice(i,i+2));
    let hit=0;
    for(let i=0;i<a.length-1;i++)if(spokenPairs.has(a.slice(i,i+2)))hit++;
    return hit/Math.max(1,a.length-1);
  }

  function isLikelyEcho(transcript,spoken){
    const a=normalize(transcript),b=normalize(spoken);
    if(a.length<4||b.length<4)return false;
    if(b.includes(a))return true;
    return echoScore(a,b)>=0.78;
  }

  function shouldPauseForTranscript(transcript,spoken,playbackActive){
    const text=normalize(transcript);
    return Boolean(playbackActive&&text.length>=2&&!isLikelyEcho(text,spoken));
  }

  return {normalize,echoScore,isLikelyEcho,shouldPauseForTranscript};
});
