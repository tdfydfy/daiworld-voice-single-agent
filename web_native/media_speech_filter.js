(function(root,factory){
  const api=factory();
  if(typeof module==='object'&&module.exports)module.exports=api;
  if(root)root.MediaSpeechFilter=api;
})(typeof globalThis!=='undefined'?globalThis:this,function(){
  const DIRECTIVE='MEDIA:';

  function createMediaSpeechFilter(){
    let atLineStart=true,probe='',suppressLine=false;

    function push(chunk){
      let output='';
      for(const char of String(chunk||'')){
        if(suppressLine){
          if(char==='\n'){suppressLine=false;atLineStart=true;probe=''}
          continue;
        }
        if(!atLineStart){
          output+=char;
          if(char==='\n')atLineStart=true;
          continue;
        }
        if(char==='\n'){
          output+=char;probe='';
          continue;
        }
        probe+=char;
        const candidate=probe.trimStart().toUpperCase();
        if(DIRECTIVE.startsWith(candidate)){
          if(candidate===DIRECTIVE){suppressLine=true;probe=''}
          continue;
        }
        output+=probe;probe='';atLineStart=false;
      }
      return output;
    }

    function flush(){
      if(suppressLine){probe='';return ''}
      const output=probe;probe='';return output;
    }

    return {push,flush};
  }

  function cleanSpeechText(text){
    let value=String(text||'').replace(/```[\s\S]*?```/g,' ');
    value=value.replace(/^\s*MEDIA:\s*.*$/gim,' ');
    value=value.replace(/\[([^\]]+)\]\([^)]*\)/g,'$1');
    value=value.replace(/https?:\/\/[^\s]+/gi,' ');
    value=value.replace(/[\\/~][^\s]+\.[A-Za-z0-9]{1,8}/g,' ');
    value=value.replace(/[*_#>`~]/g,'');
    return value.replace(/\s+/g,' ').trim();
  }

  function createSpeechTextFilter(){
    let pending='';
    function push(chunk){
      pending+=String(chunk||'');
      let output='',index=pending.search(/[。！？!?；;\n]/);
      while(index>=0){
        output+=cleanSpeechText(pending.slice(0,index+1));
        pending=pending.slice(index+1);index=pending.search(/[。！？!?；;\n]/);
      }
      if(pending.length>=160){
        output+=cleanSpeechText(pending.slice(0,160));pending=pending.slice(160);
      }
      return output;
    }
    function flush(){const output=cleanSpeechText(pending);pending='';return output}
    return {push,flush};
  }

  return {createMediaSpeechFilter,createSpeechTextFilter,cleanSpeechText};
});
