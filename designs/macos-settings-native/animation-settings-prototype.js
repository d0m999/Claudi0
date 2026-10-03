/* PROTOTYPE: three layouts for Notifications > Event animation, ?variant=A|B|C.
 * Uses the existing eight-page settings shell and the original exported sprites.
 * All choices stay in this page's memory. No application preferences are written.
 */
(async () => {
  const themes = [
    { id:'original', name:['原版图标','Original icons'], detail:['原来的事件图标，无动画','Original event icons, no animation'] },
    { id:'E', name:['机械小鸭','Mechanical duck'], detail:['关节动作，活泼回应','Expressive, mechanical movements'] },
    { id:'G', name:['像素幽灵','Pixel ghost'], detail:['轻轻漂浮，安静陪伴','Gentle floating and quiet expressions'] },
    { id:'H', name:['比特币','Bitcoin'], detail:['旋转与跳动，节奏鲜明','Distinctive spins and bounces'] }
  ];
  const motionEvents = [
    { id:'task_start', name:['任务开始','Task started'], text:['Claude Code 开始执行','Claude Code started a task'], color:'#0877d7' },
    { id:'notification', name:['待响应','Needs input'], text:['Claude Code 等你授权','Claude Code needs permission'], color:'#b96036', attention:true },
    { id:'stop', name:['本轮结束','Turn ended'], text:['Claude Code 本轮已结束','Claude Code ended this turn'], color:'#288b43' },
    { id:'subagent_stop', name:['子任务结束','Subtask ended'], text:['Claude Code 子任务已结束','Claude Code ended a subtask'], color:'#6556c9' },
    { id:'stop_failure', name:['执行中断','Interrupted'], text:['Claude Code 执行中断','Claude Code was interrupted'], color:'#a56b00', attention:true }
  ];
  const variants = { A:['并排选择','Gallery'], B:['分组列表','Grouped list'], C:['大图预览','Large preview'] };
  const motionParams = new URLSearchParams(location.search);
  const state = {
    theme:themes.some(t=>t.id===motionParams.get('character'))?motionParams.get('character'):'original',
    event:'notification', enabled:true, reduced:false,
    variant:Object.hasOwn(variants,motionParams.get('variant'))?motionParams.get('variant'):'A'
  };
  const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
  const images = {};
  let frameRequest = 0, startedAt = 0, pausedAt = null, pausedMs = 0, hoverPaused = false;
  const resourceRoot = '../../gui/Sources/ClaudioGUI/Resources/EventAnimations/';
  const provenance = await fetch(resourceRoot+'provenance.json').then(response=>{
    if(!response.ok)throw new Error('Animation resource manifest unavailable');return response.json();
  });
  const manifests = Object.fromEntries(await Promise.all(Object.values(provenance.styles).map(async entry=>
    [entry.variant,await fetch(resourceRoot+entry.timing).then(response=>response.json())])));
  // Sample after asynchronous resource loading, then project change events into UI state.
  // Polling MQL.matches each RAF updates Blink's comparison value before change delivery.
  let systemReducedMotion = reducedMotion.matches;
  const currentTheme = () => themes.find(t=>t.id===state.theme);
  const currentEvent = () => motionEvents.find(e=>e.id===state.event);
  const active = () => S.page==='notifications' && S.detail==='animation' && !document.querySelector('.window-closed');
  const staticMotion = () => state.reduced || systemReducedMotion;
  // Original glyphs from the current Panel and Settings Prototype.html (G / EVENTS).
  const originalGlyphs = {
    task_start:'<svg viewBox="0 0 16 16" fill="currentColor"><path d="M14 2L1.8 6.7c-.5.2-.5.9 0 1.1l3.5 1.3 1.3 3.5c.2.5.9.5 1.1 0L12.4 3z"/></svg>',
    notification:'<svg viewBox="0 0 16 16" fill="none"><path d="M8 2.2a3.9 3.9 0 0 0-3.9 3.9v2.7L2.8 11h10.4l-1.3-2.2V6.1A3.9 3.9 0 0 0 8 2.2z"/><path d="M6.6 13.2a1.5 1.5 0 0 0 2.8 0"/></svg>',
    stop:'<svg viewBox="0 0 16 16" fill="currentColor"><path d="M8 1.5A6.5 6.5 0 1 0 8 14.5 6.5 6.5 0 0 0 8 1.5zm3 4.9l-3.9 4a.9.9 0 0 1-1.3 0L4.9 9.5a.9.9 0 0 1 1.3-1.3l1.5 1.6 3.3-3.4a.9.9 0 0 1 1.3 1.3z"/></svg>',
    subagent_stop:'<svg viewBox="0 0 16 16" fill="none"><circle cx="8" cy="8" r="6.2"/><path d="M5.3 8.2l1.9 2 3.5-3.7"/></svg>',
    stop_failure:'<svg viewBox="0 0 16 16" fill="currentColor"><rect x="4" y="3" width="2.6" height="10" rx="1.1"/><rect x="9.4" y="3" width="2.6" height="10" rx="1.1"/></svg>'
  };
  function originalGlyph(event='notification', size=64) {
    const entry=motionEvents.find(e=>e.id===event)||motionEvents.find(e=>e.id==='notification');
    return `<span class="motion-original" data-motion-original="${entry.id}" style="width:${size}px;height:${size}px;--original-size:${Math.max(25,size*.75)}px;--original-color:${entry.color}" aria-hidden="true"><span class="motion-original-icon">${originalGlyphs[entry.id]}</span></span>`;
  }
  const sprite = (theme, event='idle', live=false, size=64) => theme==='original'?originalGlyph(event,size):`<canvas class="motion-sprite" width="64" height="64" style="width:${size}px;height:${size}px" data-motion-theme="${theme}" data-motion-state="${event}" ${live?'data-motion-live="true"':''} aria-hidden="true"></canvas>`;
  const choice = theme => `<button id="motion-theme-${theme.id}" class="motion-choice" data-motion-theme-choice="${theme.id}" aria-pressed="${state.theme===theme.id}">${sprite(theme.id,'idle',false,state.variant==='B'?40:64)}<span><strong>${T(...theme.name)}</strong><small>${T(...theme.detail)}</small></span><span class="motion-check" aria-hidden="true">${state.theme===theme.id?icon('check'):''}</span></button>`;
  const eventButtons = () => `<div class="motion-events" role="group" aria-label="${T('预览事件','Preview event')}">${motionEvents.map(e=>`<button id="motion-event-${e.id}" class="motion-event" data-motion-event="${e.id}" aria-pressed="${state.event===e.id}">${T(...e.name)}</button>`).join('')}</div>`;
  function preview() {
    const event=currentEvent();
    const original=state.theme==='original'||!state.enabled;
    return `<section class="motion-section"><div class="motion-section-heading"><h2>${T('横幅预览','Banner preview')}</h2><span>${T('实际显示尺寸','Actual display size')}</span></div><div class="motion-preview"><div class="motion-banner-stage"><div class="motion-banner" id="motion-banner" style="--motion-event:${event.color}" role="img" aria-label="${esc(T(...event.text))}">${original?originalGlyph(state.event,32):sprite(state.theme,state.event,true,32)}<div class="motion-banner-text"><strong>${T(...event.text)}</strong><small>Claudio · ${T('刚刚','just now')}</small></div>${event.attention?`<span class="motion-banner-action">${T('打开来源','Open source')}</span>`:''}<span class="motion-banner-close" aria-hidden="true">×</span><div class="motion-track" aria-hidden="true"><div class="motion-track-fill" id="motion-track-fill"></div></div></div></div>${eventButtons()}<div class="motion-preview-footer"><span>${original?T('选择事件查看原版图标','Choose an event to see its original icon'):T('选择事件查看动作','Choose an event to see its motion')}</span><button class="motion-replay" id="motion-replay" data-motion-replay>${icon('refresh')}${original?T('预览横幅','Preview banner'):T('重播一次','Replay')}</button></div></div></section>`;
  }
  function options() {
    if(state.theme==='original')return `<p class="motion-status" id="motion-status" role="status">${T('当前使用：原版图标 · 无动画','Current theme: Original icons · No animation')}</p>`;
    return `<div class="motion-options group"><div class="row"><label class="motion-option-label" for="motion-enabled"><span class="label"><strong>${T('显示角色动画','Show character animations')}</strong><small>${T('用所选角色呈现事件横幅。','Use the selected character in event banners.')}</small></span><input id="motion-enabled" type="checkbox" ${state.enabled?'checked':''}></label></div><div class="row"><label class="motion-option-label" for="motion-reduced"><span class="label"><strong>${T('静态表情','Still expressions')}</strong><small>${systemReducedMotion?T('系统已开启“减少动态效果”。','Reduce Motion is enabled in system settings.'):T('保留角色表情，停止播放动作。','Keep character expressions without playing motion.')}</small></span><input id="motion-reduced" type="checkbox" ${staticMotion()?'checked':''} ${systemReducedMotion?'disabled':''}></label></div></div><p class="motion-status" id="motion-status" role="status">${state.enabled?T('当前使用：','Current theme: ')+T(...currentTheme().name)+(staticMotion()?T(' · 静态表情',' · Still expressions'):''):T('动画已关闭；已记住所选角色。','Animations are off; your character selection is kept.')}</p>`;
  }
  function page() {
    const intro=`<div class="motion-intro"><h2>${T('选择提醒的显示样式','Choose how notices look')}</h2><p>${T('原版图标或动画角色，切换后立即生效。','Choose original icons or an animated character. Changes take effect immediately.')}</p></div>`;
    if(state.variant==='B') return intro+`<div class="motion-list" role="group" aria-label="${T('动画主题','Animation theme')}">${themes.map(choice).join('')}</div>`+preview()+options();
    if(state.variant==='C') return intro+`<div class="motion-theater"><div class="motion-stage"><button id="motion-prev-character" data-motion-cycle="-1" aria-label="${T('上一个角色','Previous character')}">${icon('back')}</button>${sprite(state.theme,state.event,state.enabled,128)}<button id="motion-next-character" data-motion-cycle="1" aria-label="${T('下一个角色','Next character')}">${icon('next')}</button></div><h2>${T(...currentTheme().name)}</h2><p>${T(...currentTheme().detail)}</p><div class="motion-theme-tabs" role="group" aria-label="${T('动画主题','Animation theme')}">${themes.map(t=>`<button id="motion-theme-${t.id}" data-motion-theme-choice="${t.id}" aria-pressed="${state.theme===t.id}">${T(...t.name)}</button>`).join('')}</div></div>`+preview()+options();
    return intro+`<div class="motion-choices" role="group" aria-label="${T('动画主题','Animation theme')}">${themes.map(choice).join('')}</div>`+preview()+options();
  }
  function draw(canvas, frame) {
    const key=canvas.dataset.motionTheme, animation=manifests[key].animations[canvas.dataset.motionState];
    const appearance=document.documentElement.dataset.theme==='dark'?'dark':'light',image=images[key+'-'+appearance];
    if(!image?.complete || !image.naturalWidth) return;
    const ctx=canvas.getContext('2d');ctx.imageSmoothingEnabled=false;ctx.clearRect(0,0,64,64);
    ctx.drawImage(image,frame*64,animation.row*64,64,64,0,0,64,64);
  }
  function frameAt(animation, elapsed) {
    const duration=animation.durationsMs.reduce((a,b)=>a+b,0);
    if(elapsed>=duration && animation.playback==='loop') {
      const prefix=animation.durationsMs.slice(0,animation.loopStartFrame||0).reduce((a,b)=>a+b,0);
      elapsed=prefix+(elapsed-duration)%(duration-prefix);
    }
    let frame=0;
    while(frame<animation.frames-1 && elapsed>=animation.durationsMs[frame]) {elapsed-=animation.durationsMs[frame];frame++;}
    return frame;
  }
  function drawThumbnails() {
    document.querySelectorAll('canvas.motion-sprite:not([data-motion-live])').forEach(canvas=>draw(canvas,manifests[canvas.dataset.motionTheme].animations[canvas.dataset.motionState].reducedMotionFrame));
  }
  function stop() {cancelAnimationFrame(frameRequest);frameRequest=0;}
  function tick(now) {
    frameRequest=0;
    if(!active() || document.hidden) return;
    const elapsed=Math.max(0,(pausedAt??now)-startedAt-pausedMs), finished=elapsed>=4000;
    document.querySelectorAll('canvas[data-motion-live]').forEach(canvas=>{
      const animation=manifests[canvas.dataset.motionTheme].animations[canvas.dataset.motionState];
      const frame=staticMotion()?animation.reducedMotionFrame:frameAt(animation,Math.min(4000,elapsed));
      draw(canvas,frame);
    });
    const track=$('motion-track-fill');
    if(track){track.style.transform=`scaleX(${staticMotion()?1:Math.max(0,1-elapsed/4000)})`;track.style.opacity=staticMotion()?'.3':'1';}
    if(!finished && pausedAt===null && !staticMotion()) frameRequest=requestAnimationFrame(tick);
  }
  function replay() {
    stop();startedAt=performance.now();pausedMs=0;pausedAt=null;hoverPaused=false;
    drawThumbnails();tick(startedAt);
  }
  function setPaused() {
    const paused=hoverPaused;
    if(paused && pausedAt===null){pausedAt=performance.now();stop();}
    if(!paused && pausedAt!==null){pausedMs+=performance.now()-pausedAt;pausedAt=null;tick(performance.now());}
  }
  function switcher() {
    $('motion-layout-switcher')?.remove();
    if(!active())return;
    const nav=document.createElement('nav');nav.id='motion-layout-switcher';nav.className='motion-prototype-switcher';nav.setAttribute('aria-label',T('原型布局比较','Prototype layout comparison'));
    nav.innerHTML=`<span class="motion-caption">${T('布局提案','Layouts')}</span><button id="motion-layout-previous" class="motion-arrow" data-motion-layout-cycle="-1" aria-label="${T('上一方案','Previous layout')}">‹</button>${Object.entries(variants).map(([key,name])=>`<button id="motion-layout-${key}" data-motion-variant="${key}" aria-pressed="${key===state.variant}">${key} · ${T(...name)}</button>`).join('')}<button id="motion-layout-next" class="motion-arrow" data-motion-layout-cycle="1" aria-label="${T('下一方案','Next layout')}">›</button>`;
    document.body.append(nav);
  }
  const originalNotifications=renderNotifications;
  renderNotifications=()=>{
    if(S.detail==='animation')return page();
    const entry=`<button id="motion-open" class="row disclosure" style="width:100%;text-align:left" data-motion-open>${sprite(state.theme,'idle',false,32)}<span class="label"><strong>${T('事件动画','Event animation')}</strong><small>${T('选择原版图标或动画角色，预览五种事件。','Choose original icons or animated characters and preview five events.')}</small></span><span class="value">${state.enabled?T(...currentTheme().name):T('已关闭','Off')}</span>${icon('next')}</button>`;
    return section(T('动画效果','Animation'),entry)+originalNotifications();
  };
  const originalRender=render;
  render=()=>{
    const focused=document.activeElement?.id;stop();originalRender();
    document.title=T('claudi0 · 事件动画设置原型','claudi0 · Event animation settings prototype');
    $('review-title').textContent=T('claudi0 · 事件动画设置','claudi0 · Event animation settings');
    $('prototype-message').textContent=T('交互原型 · 选择仅保留在本页 · 下方切换三种布局提案','Interactive prototype · Choices stay in this page · Compare three layouts below');
    if(active()){
      $('page-title').textContent=T('事件动画','Event animation');
      const banner=$('motion-banner');
      banner.onpointerenter=()=>{hoverPaused=true;setPaused();};banner.onpointerleave=()=>{hoverPaused=false;setPaused();};
      replay();
    } else drawThumbnails();
    switcher();
    if(focused?.startsWith('motion-'))$(focused)?.focus({preventScroll:true});
  };
  function selectTheme(id) {state.theme=id;state.enabled=true;render();announce(`已选择${T(...currentTheme().name)}。`,`Selected ${T(...currentTheme().name)}.`);}
  function selectVariant(key) {
    state.variant=key;const url=new URL(location.href);url.searchParams.set('variant',key);history.replaceState(null,'',url);render();
  }
  function cycleLayout(step) {const keys=Object.keys(variants);selectVariant(keys[(keys.indexOf(state.variant)+step+keys.length)%keys.length]);}
  document.addEventListener('click',event=>{
    const target=event.target.closest('button');if(!target)return;
    if(target.hasAttribute('data-motion-open'))return navigate('notifications','animation');
    if(target.dataset.motionThemeChoice)return selectTheme(target.dataset.motionThemeChoice);
    if(target.dataset.motionEvent){state.event=target.dataset.motionEvent;return render();}
    if(target.hasAttribute('data-motion-replay'))return replay();
    if(target.dataset.motionVariant)return selectVariant(target.dataset.motionVariant);
    if(target.dataset.motionLayoutCycle)return cycleLayout(Number(target.dataset.motionLayoutCycle));
    if(target.dataset.motionCycle){const next=(themes.findIndex(t=>t.id===state.theme)+Number(target.dataset.motionCycle)+themes.length)%themes.length;return selectTheme(themes[next].id);}
  });
  document.addEventListener('change',event=>{
    if(event.target.id==='motion-enabled'){state.enabled=event.target.checked;render();}
    if(event.target.id==='motion-reduced'){state.reduced=event.target.checked;render();}
  });
  document.addEventListener('keydown',event=>{
    if(!active() || !['ArrowLeft','ArrowRight'].includes(event.key) || event.target.closest('input,textarea,select,button,[contenteditable="true"]'))return;
    event.preventDefault();cycleLayout(event.key==='ArrowLeft'?-1:1);
  });
  document.addEventListener('visibilitychange',()=>{if(document.hidden)stop();else if(active())replay();});
  for(const entry of Object.values(provenance.styles)) {
    for(const appearance of ['light','dark']) {
      const image=new Image();images[entry.variant+'-'+appearance]=image;
      image.onload=()=>{drawThumbnails();if(active()){stop();tick(performance.now());}};
      image.src=resourceRoot+entry.atlases[appearance];
    }
  }
  reducedMotion.addEventListener('change',event=>{systemReducedMotion=event.matches;render();});
  $('preview-theme').addEventListener('change',()=>{drawThumbnails();if(active()){stop();tick(performance.now());}});
  $('window-close').addEventListener('click',stop);$('window-minimize').addEventListener('click',stop);
  const originalBack=$('detail-back').onclick;
  $('detail-back').onclick=()=>{if(active()){navigate('notifications',null,{focus:false});$('motion-open').focus();}else originalBack();};
  $('reset-demo').addEventListener('click',()=>{Object.assign(state,{theme:'original',event:'notification',enabled:true,reduced:false});navigate('notifications','animation');});
  const sceneLabel=$('preview-scene').closest('label');sceneLabel.style.display='none';
  S.page='notifications';S.detail=motionParams.get('detail')==='overview'?null:'animation';render();
  window.animationSettingsReview={getState:()=>({...state,systemReducedMotion,playing:frameRequest!==0}),replay};
})();
