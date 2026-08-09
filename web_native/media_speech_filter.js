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

  return {createMediaSpeechFilter};
});
