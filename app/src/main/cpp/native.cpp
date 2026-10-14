// VDExtra — Virtual Desktop enhancement (LSPosed native hook), forked from VDPlus (ghitori/vdplus)
// Note: the real ABI of mono_ldstr_checked is (ptr,u32,ptr,...); the hook must forward x0-x3 as void*, or a truncated pointer will crash.

#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdarg.h>
#include <time.h>
#include <string>
#include <vector>
#include <map>
#include <unordered_map>
#include <mutex>
#include <atomic>
#include <thread>
#include <chrono>
#include <dlfcn.h>
#include <android/log.h>
#include <jni.h>
#include <math.h>
#include <dobby.h>

#define TAG "VDExtra"
static void vlog(int prio,const char* fmt,...){
  va_list ap; va_start(ap,fmt);
  __android_log_vprint(prio,TAG,fmt,ap);
  va_end(ap);
}
#define LOGI(...) vlog(ANDROID_LOG_INFO,__VA_ARGS__)
#define LOGE(...) vlog(ANDROID_LOG_ERROR,__VA_ARGS__)

// Hooks go straight through our own vendored Dobby (see CMakeLists.txt), not the host
// framework's hook_func - see the comment above pollForMono() for why.
static int hook(void* target, void* replace, void** orig){
  return DobbyHook(target, replace, orig);
}

// Mono types (used as opaque pointers only)
struct _MonoObject; struct _MonoImage; struct _MonoClass; struct _MonoMethod;
struct _MonoString; struct _MonoType; struct _MonoDomain;
typedef struct _MonoObject MonoObject; typedef struct _MonoImage MonoImage;
typedef struct _MonoClass MonoClass; typedef struct _MonoMethod MonoMethod;
typedef struct _MonoString MonoString; typedef struct _MonoType MonoType;
typedef struct _MonoDomain MonoDomain;
typedef struct _MonoClassField* MonoField;
typedef uint32_t MonoGCHandle;

// Mono exported symbols
static MonoImage*  (*pGetCorlib)(void)=nullptr;
static MonoClass*  (*pClassFromName)(MonoImage*,const char*,const char*)=nullptr;
static MonoMethod* (*pClassGetMethod)(MonoClass*,const char*,int)=nullptr;
static MonoObject* (*pRuntimeInvoke)(MonoMethod*,void*,void**,MonoObject**)=nullptr;
static MonoClass*  (*pTypeGetClass)(MonoType*)=nullptr;
static void*       (*pCompileMethod)(MonoMethod*)=nullptr;
static MonoClass*  (*pObjGetClass)(MonoObject*)=nullptr;
static void*       (*pObjUnbox)(MonoObject*)=nullptr;
static MonoClass*  (*pClassGetParent)(MonoClass*)=nullptr;
static MonoField   (*pClassGetField)(MonoClass*,const char*)=nullptr;
static void        (*pFieldGetValue)(void*,void*,void*)=nullptr;
static void        (*pFieldSetValue)(void*,MonoField,void*)=nullptr;
static MonoString* (*pLdstrChecked)(void*,void*,uint32_t,void*)=nullptr;
static MonoString* (*pStringNewUtf16)(MonoDomain*,const uint16_t*,int32_t)=nullptr;
static MonoGCHandle (*pGchandleNew)(MonoObject*,int)=nullptr;
static MonoObject* (*pGchandleGet)(MonoGCHandle)=nullptr;
static void        (*pGchandleFree)(MonoGCHandle)=nullptr;
static MonoDomain* (*pGetRootDomain)(void)=nullptr;
static MonoDomain* (*pDomainGet)(void)=nullptr;
static MonoDomain* (*pJitThreadAttach)(MonoDomain*)=nullptr;
static void        (*pAttachToolsThread)(void)=nullptr;
static void*       (*pProfilerCreate)(void*)=nullptr;
static void        (*pProfilerSetRuntimeInitCb)(void*,void(*)(void*))=nullptr;
static void        (*pProfilerSetThreadStartedCb)(void*,void(*)(void*,uintptr_t))=nullptr;
static void        (*pProfilerSetGcEventCb)(void*,void(*)(void*,int,uint32_t,int))=nullptr;

// Global state
static MonoDomain* gDomain=nullptr;
static void* gCorlib=nullptr;
static MonoClass* gClsOff=nullptr;
static MonoField gDictField=nullptr;

static std::atomic<bool> gSetup{false};
static std::atomic<bool> gTextHooked{false};
static std::atomic<bool> gSerHooked{false};
static std::atomic<bool> gCmHooked{false};
static std::atomic<bool> gInSetup{false};

static MonoGCHandle gGoodHandle=0;
static std::map<int, MonoGCHandle> gGoodMap;
static std::mutex gMapMutex;
static std::unordered_map<std::string,std::string> gDict;

#define FULL 1000
static const int SER_CAP = 40;
static int serCount=0; static bool serDone=false;

// Resolved managed method pointers
typedef MonoString* (*fnGetText)(void*);
typedef float      (*fnGetSize)(MonoObject*);
typedef void       (*fnSetText)(void*,MonoString*);
typedef void       (*fnSetFont)(void*,MonoObject*);
typedef void       (*fnMusicPlay)(void*);
typedef MonoString*(*fnLdstr)(void*,void*,void*,void*);
typedef void       (*fnSerialize)(void*,void*,void*,void*);
typedef MonoObject*(*fnLoad3)(void*,void*,void*,void*);
typedef MonoObject*(*fnLoad2)(void*,void*,void*);
typedef int        (*fnJitExec)(MonoDomain*,void*,int,char**);
typedef MonoDomain*(*fnJitInit)(const char*);
typedef int        (*fnRunMain)(void*,int,char**);
typedef MonoObject*(*fnObjNew)(MonoDomain*,MonoClass*);

static fnGetText   getTextFn=nullptr;
static fnGetSize   getSizeFn=nullptr;
static fnSetText   origSetText=nullptr;
static fnSetFont   origSetFont=nullptr;
static fnLdstr     origLdstr=nullptr;
static fnSerialize origSerialize=nullptr;
static fnLoad3     origLoad3=nullptr;
static fnLoad2     origLoad2=nullptr;
static fnJitExec   origJitExec=nullptr;
static fnJitInit   origJitInit=nullptr;
static fnRunMain   origRunMain=nullptr;
static fnMusicPlay origMusicPlay=nullptr;
static fnObjNew    origObjNew=nullptr;

// Bitrate: scale the internal max-lookup tables (GetMax*Bitrate) locally; the sender normalizes tiers via k=(max*s-min)/(max-min)
typedef int32_t (*fnMinMax1)(int32_t);
typedef int32_t (*fnMinMax3)(int32_t,int32_t,int32_t);
static fnMinMax1 fnMinDesk=nullptr, fnMinVR=nullptr;          // original min (used only to compute k)
static fnMinMax1 origMaxDesk=nullptr;                         // original max (desktop isn't hooked, value is read as-is)
static fnMinMax3 origMaxVR=nullptr;                           // original max (VR hook backup)
typedef int32_t (*fnCalcBitrate2)(int32_t,float);
typedef MonoString* (*fnBitrateStr2)(int32_t,float);
static fnCalcBitrate2 origDesktopBitrate=nullptr;
static fnBitrateStr2  origDesktopBitrateString=nullptr;
static std::atomic<int> gDeskMode{0};   // 0=unknown 1=table 2=outer (desktop only has a fallback)
static thread_local bool tProbeHit=false;
static thread_local bool tInStrDesktop=false;
// Display soft-limit correction (desktop outer mode)
static void (*origSettingsMeasured)(void*)=nullptr;
static void (*origLimitSliderSetLimit)(void*,float)=nullptr;
static thread_local bool tDeskLimitCtx=false;
typedef void (*fnSetInt1)(void*,int32_t);
static fnSetInt1 origSetHmdType=nullptr, origSetActiveCodec=nullptr, origSetFoveated=nullptr;
static fnSetInt1 origSetMeasuredBandwidth=nullptr;
static void (*origSendReload)(void*)=nullptr;
static std::atomic<bool> gSpeedtestDone{false};
static std::atomic<int32_t> gHmd{-1}, gCodec{-1}, gFov{-1};
static void* gMobileSettings=nullptr;                         // SharedMobileSettings instance (used for full-packet resends)
// Full-packet serialization
typedef void (*fnSerializerObject)(void*,void*);
static fnSerializerObject origSerializerObject=nullptr;
static MonoClass* gClsUserSettings=nullptr;
static void* gUserSettingsPin=nullptr;
static void (*origUserSendReload)(void*)=nullptr;
static MonoField gFieldDesktopLimit=nullptr, gFieldVRLimit=nullptr;
// Incremental setter
typedef void (*fnSetLimit1)(void*,float);
static fnSetLimit1 origSetDesktopLimit=nullptr, origSetVRLimit=nullptr;
// Force LAN discovery: merge in locally (UDP broadcast) discovered PCs even when the server is unavailable
static std::atomic<bool> gForceLan{true};
static bool (*origGetHasValidIdentity)(void*)=nullptr;
static void (*origSetHasValidIdentity)(void*,bool)=nullptr;
static void (*origUserSettingsCtor)(void*)=nullptr;
static MonoField  gFieldUserHasValidIdentity=nullptr;
static void* gUserSettingsDefault=nullptr;            // UserSettings singleton (pinned)
static std::atomic<bool> gForceLanTried{false};

static std::atomic<bool> gNoMusic{false};
static std::atomic<bool> gMusicHooked{false};
static std::atomic<bool> gMusicTried{false};

static std::atomic<bool> gQualitySound{false};   // master switch for performance cue sounds
static std::atomic<int>  gQualityMask{0x7F};     // per-cue-sound bit, 7 sounds total
static std::atomic<bool> gQualitySoundTried{false};

static std::atomic<float> gBitrateScale{2.0f};        // bitrate multiplier
static std::atomic<bool>  gBitrateExtend{false};      // extend the bitrate range
static std::atomic<bool>  gBitrateUnlock{false};      // remove the auto speed-test bitrate cap
static std::atomic<bool>  gBitrateHooked{false};
static std::atomic<bool>  gBitrateTried{false};

// UTF-8/UTF-16 conversion helpers
static void utf8ToUtf16(const std::string& u8, std::vector<uint16_t>& out){
  out.clear(); out.reserve(u8.size());
  size_t i=0, n=u8.size();
  while(i<n){
    unsigned char c=(unsigned char)u8[i];
    uint32_t cp=0; int extra=0;
    if(c<0x80){ cp=c; extra=0; }
    else if((c&0xE0)==0xC0){ cp=c&0x1F; extra=1; }
    else if((c&0xF0)==0xE0){ cp=c&0x0F; extra=2; }
    else if((c&0xF8)==0xF0){ cp=c&0x07; extra=3; }
    else { i++; continue; }
    if(i+(size_t)extra>=n) break;
    for(int k=0;k<extra;k++) cp=(cp<<6)|(u8[i+1+k]&0x3F);
    i+=1+extra;
    if(cp<=0xFFFF) out.push_back((uint16_t)cp);
    else { cp-=0x10000; out.push_back((uint16_t)(0xD800|(cp>>10))); out.push_back((uint16_t)(0xDC00|(cp&0x3FF))); }
  }
}
static std::string utf16ToUtf8(const uint16_t* s,int len){
  std::string o; o.reserve((size_t)len*3);
  for(int i=0;i<len;i++){
    uint32_t cp=s[i];
    if(cp>=0xD800 && cp<=0xDBFF && i+1<len && s[i+1]>=0xDC00 && s[i+1]<=0xDFFF){
      cp=0x10000+((cp-0xD800)<<10)+(s[i+1]-0xDC00); i++;
    }
    if(cp<0x80) o+=(char)cp;
    else if(cp<0x800){ o+=(char)(0xC0|(cp>>6)); o+=(char)(0x80|(cp&0x3F)); }
    else if(cp<0x10000){ o+=(char)(0xE0|(cp>>12)); o+=(char)(0x80|((cp>>6)&0x3F)); o+=(char)(0x80|(cp&0x3F)); }
    else { o+=(char)(0xF0|(cp>>18)); o+=(char)(0x80|((cp>>12)&0x3F)); o+=(char)(0x80|((cp>>6)&0x3F)); o+=(char)(0x80|(cp&0x3F)); }
  }
  return o;
}
static bool hasCjk(const uint16_t* s,int len){ for(int i=0;i<len;i++) if(s[i]>0x2E7F) return true; return false; }
static int  monoStrLen(MonoString* s){ return s?*(int32_t*)((char*)s+16):0; }
static const uint16_t* monoStrChars(MonoString* s){ return (const uint16_t*)((char*)s+20); }
static int rnd(float f){ return (int)(f>=0.0f?f+0.5f:f-0.5f); }

static MonoDomain* getDomain(){
  if(pDomainGet){ MonoDomain* d=pDomainGet(); if(d) return d; }
  if(gDomain) return gDomain;
  if(pGetRootDomain) return pGetRootDomain();
  return nullptr;
}

static MonoString* makeMono(const std::string& u8){
  if(!pStringNewUtf16) return nullptr;
  static thread_local std::vector<uint16_t> w;
  utf8ToUtf16(u8,w);
  if(w.empty()) return nullptr;
  return pStringNewUtf16(getDomain(), w.data(), (int32_t)w.size());
}

// Class/method resolution
static MonoClass* getClass(const char* qname){
  if(!pClassFromName||!pClassGetMethod||!pRuntimeInvoke||!pTypeGetClass||!gCorlib) return nullptr;
  MonoClass* ct=pClassFromName((MonoImage*)gCorlib,"System","Type");
  if(!ct) return nullptr;
  MonoMethod* mGT=pClassGetMethod(ct,"GetType",1);
  if(!mGT) return nullptr;
  MonoString* nm=makeMono(qname);
  if(!nm) return nullptr;
  void* a[1]; a[0]=nm;
  MonoObject* exc=nullptr;
  MonoObject* t=pRuntimeInvoke(mGT,nullptr,a,&exc);
  if(!t||exc) return nullptr;
  void* typePtr=*(void**)((char*)t+16);
  if(!typePtr) return nullptr;
  return pTypeGetClass((MonoType*)typePtr);
}
static void* methodAddr(MonoClass* c,const char* n,int np){
  if(!c||!pClassGetMethod||!pCompileMethod) return nullptr;
  MonoMethod* m=pClassGetMethod(c,n,np);
  if(!m) return nullptr;
  return pCompileMethod(m);
}

// Font capability probing
static int glyphCount(MonoObject* font){
  if(!font||!gDictField||!pFieldGetValue||!pObjGetClass||!pClassGetMethod||!pRuntimeInvoke||!pObjUnbox) return -1;
  void* dict=nullptr;
  pFieldGetValue(font,gDictField,&dict);
  MonoObject* d=(MonoObject*)dict;
  if(!d) return 0;
  MonoClass* dc=pObjGetClass(d);
  if(!dc) return -1;
  MonoMethod* cm=pClassGetMethod(dc,"get_Count",0);
  if(!cm) return -1;
  MonoObject* exc=nullptr;
  MonoObject* r=pRuntimeInvoke(cm,d,nullptr,&exc);
  if(exc||!r) return -1;
  int* pi=(int*)pObjUnbox(r);
  return pi?*pi:-1;
}
static float fsize(MonoObject* f){ return (f&&getSizeFn)?getSizeFn(f):0.0f; }
static bool isFontClass(MonoObject* o){
  if(!o||!pObjGetClass||!pClassGetParent||!gClsOff) return false;
  MonoClass* c=pObjGetClass(o);
  MonoClass* cur=c;
  for(int i=0;i<8 && cur;i++){
    if(cur==gClsOff) return true;
    cur=pClassGetParent(cur);
  }
  return false;
}

// goodFont/goodMap: pinned via gchandle so the moving GC can't relocate them
static MonoGCHandle pin(MonoObject* o){ return (o&&pGchandleNew)?pGchandleNew(o,1):0; }
static MonoObject* mov(MonoGCHandle h){ return (h&&pGchandleGet)?pGchandleGet(h):nullptr; }
static void markGood(MonoObject* f,const char* tag){
  if(!f) return;
  int g=glyphCount(f);
  if(g<FULL) return;
  float sz=fsize(f);
  int k=rnd(sz);
  if(!gGoodHandle){ gGoodHandle=pin(f); LOGI("[F] goodFont(%s) size=%.1f glyphs=%d",tag,sz,g); }
  std::lock_guard<std::mutex> lk(gMapMutex);
  if(gGoodMap.find(k)==gGoodMap.end()) gGoodMap[k]=pin(f);
}
static bool goodMapHas(int k){ std::lock_guard<std::mutex> lk(gMapMutex); return gGoodMap.find(k)!=gGoodMap.end(); }
// Pick a replacement font: sizes 30/32 match to the nearest cached size; other sizes prefer the largest non-32 entry, falling back to 32
static MonoObject* pickReplacement(float size){
  MonoGCHandle h=0;
  {
    std::lock_guard<std::mutex> lk(gMapMutex);
    if(!gGoodHandle) return nullptr;
    int r=rnd(size);
    if(r==30 || r==32){
      auto it=gGoodMap.find(r);
      if(it!=gGoodMap.end()){ h=it->second; }
      else {
        MonoGCHandle best=gGoodHandle; int bd=1<<30;
        for(auto& kv:gGoodMap){ int d=abs(kv.first-r); if(d<bd){ bd=d; best=kv.second; } }
        h=best;
      }
    } else {
      int mk=-1000000;
      for(auto& kv:gGoodMap){ if(kv.first!=32 && kv.first>mk){ mk=kv.first; h=kv.second; } }
      if(!h){
        auto it2=gGoodMap.find(32);
        h=(it2!=gGoodMap.end())?it2->second:gGoodHandle;
      }
    }
  }
  return h?mov(h):nullptr;
}

// set_Text hook: translation only; font handling is left entirely to set_Font to avoid re-entrant writes to Font from this setter
static void hookSetText(void* tb,MonoString* text){
  int len=monoStrLen(text);
  if(len<=0 || len>2048){ if(origSetText) origSetText(tb,text); return; }
  std::string key=utf16ToUtf8(monoStrChars(text),len);
  auto it=gDict.find(key);
  if(it!=gDict.end()){
    MonoString* zh=makeMono(it->second);
    if(zh){
      text=zh;
    }
  }
  if(origSetText) origSetText(tb,text);
}

// set_Font hook: for text containing CJK, approximate-match the nearest-size full-coverage font
static void hookSetFont(void* tb,MonoObject* newFont){
  MonoObject* cur=newFont;
  MonoObject* gf=mov(gGoodHandle);
  if(gf && cur && cur!=gf){
    bool cjk=false;
    if(getTextFn){ MonoString* p=getTextFn(tb); cjk=hasCjk(monoStrChars(p),monoStrLen(p)); }
    if(cjk){
      int gc=glyphCount(cur);
      if(gc<FULL){
        float oS=fsize(cur);
        MonoObject* chN=pickReplacement(oS);
        if(chN && chN!=cur) cur=chN;
      }
    }
  }
  if(origSetFont) origSetFont(tb,cur);
}

// MusicSystem::Play hook: disables background auto-play music (the only play entry point)
static void hookMusicPlay(void* self){
  if(gNoMusic.load()) return;
  if(origMusicPlay) origMusicPlay(self);
}

// Performance cue sounds: muted individually via the gQualityMask bitmask
static void* gOrigSound[7]={nullptr};
template<int B> static void hookMuteSound(void* self){
  if(gQualitySound.load() && (gQualityMask.load()&(1<<B))) return;
  if(gOrigSound[B]) ((void(*)(void*))gOrigSound[B])(self);
}
static bool installQualitySoundHooks(){
  MonoClass* ss=getClass("VirtualDesktop.Mobile.SoundSystem, VirtualDesktop.Mobile");
  if(!ss){ LOGE("SoundSystem class not found"); return false; }
  static const char* names[7]={
    "PlayPotato","PlayUltra","PlayGodlike","PlayMonster",
    "PlayRampage","PlayUnstoppable","PlayHolyShit"
  };
  int ok=0;
  void* a0=methodAddr(ss,names[0],0); if(a0&&hook(a0,(void*)hookMuteSound<0>,&gOrigSound[0])==0) ok++;
  void* a1=methodAddr(ss,names[1],0); if(a1&&hook(a1,(void*)hookMuteSound<1>,&gOrigSound[1])==0) ok++;
  void* a2=methodAddr(ss,names[2],0); if(a2&&hook(a2,(void*)hookMuteSound<2>,&gOrigSound[2])==0) ok++;
  void* a3=methodAddr(ss,names[3],0); if(a3&&hook(a3,(void*)hookMuteSound<3>,&gOrigSound[3])==0) ok++;
  void* a4=methodAddr(ss,names[4],0); if(a4&&hook(a4,(void*)hookMuteSound<4>,&gOrigSound[4])==0) ok++;
  void* a5=methodAddr(ss,names[5],0); if(a5&&hook(a5,(void*)hookMuteSound<5>,&gOrigSound[5])==0) ok++;
  void* a6=methodAddr(ss,names[6],0); if(a6&&hook(a6,(void*)hookMuteSound<6>,&gOrigSound[6])==0) ok++;
  LOGI("hooked quality sounds: %d/7 mask=%d",ok,gQualityMask.load());
  return true;
}

// Bitrate: prefer hooking the lookup table directly; falls back to the outer call if the probe misses
// The table hook can be bypassed by JIT inlining; the first call probes to detect this: hit -> table, miss -> multiply the outer call's input by k
// Sending: SerializerObject multiplies the tier by k when serializing the full packet; the setter stores the baseline and (after the speed test) resends the full packet
static float rateMul(){
  float s=gBitrateScale.load();
  return (gBitrateExtend.load() && s>0.0f) ? s : 1.0f;
}
static int32_t scaleMax(int32_t v){ return (int32_t)((double)v*(double)rateMul()); }
static float kCalc(float mn,float mx){
  float s=rateMul(); if(s<=1.0f) return 1.0f;
  if(mx<=mn) return s;
  return (float)((mx*s-mn)/(mx-mn));
}
static float kDesktopFor(int32_t hmd){
  if(hmd<0 || !fnMinDesk || !origMaxDesk) return rateMul();
  return kCalc((float)fnMinDesk(hmd),(float)origMaxDesk(hmd));
}
static float kVRFor(int32_t hmd,int32_t codec,int32_t fov){
  if(hmd<0 || codec<0 || !fnMinVR || !origMaxVR) return rateMul();
  return kCalc((float)fnMinVR(hmd),(float)origMaxVR(hmd,codec,fov));
}
static float kDesktop(){ return kDesktopFor(gHmd.load()); }
static float kVR(){ return kVRFor(gHmd.load(),gCodec.load(),gFov.load()); }
// Table hook: no scaling in outer mode; otherwise scale and set the probe flag
static int32_t hookMaxDesk(int32_t hmd){
  if(gDeskMode.load()==2) return origMaxDesk?origMaxDesk(hmd):0;
  tProbeHit=true;
  return scaleMax(origMaxDesk?origMaxDesk(hmd):0);
}
static int32_t hookMaxVR(int32_t hmd,int32_t codec,int32_t fov){
  return scaleMax(origMaxVR?origMaxVR(hmd,codec,fov):0);
}
// Outer Get*Bitrate: probes on first call; passes through if the table is active, otherwise multiplies the input by k
static int32_t hookDesktopBitrate(int32_t hmd,float t){
  if(!origDesktopBitrate) return 0;
  if(tInStrDesktop) return origDesktopBitrate(hmd,t);
  int m=gDeskMode.load();
  if(m==1) return origDesktopBitrate(hmd,t);
  if(m==2) return origDesktopBitrate(hmd,t*kDesktopFor(hmd));
  tProbeHit=false;
  int32_t r=origDesktopBitrate(hmd,t);
  if(tProbeHit){ gDeskMode.store(1); LOGI("bitrate desktop: table hook ACTIVE (direct)"); return r; }
  gDeskMode.store(2); LOGI("bitrate desktop: table inlined -> outer hook");
  return origDesktopBitrate(hmd,t*kDesktopFor(hmd));
}
static MonoString* hookDesktopBitrateString(int32_t hmd,float t){
  if(!origDesktopBitrateString) return nullptr;
  if(gDeskMode.load()!=2) return origDesktopBitrateString(hmd,t);
  tInStrDesktop=true; MonoString* r=origDesktopBitrateString(hmd,t*kDesktopFor(hmd)); tInStrDesktop=false;
  return r;
}
// Desktop fallback mode: the UI multiplies the tier by k, so this divides by k first while computing the speed-test soft limit, then restores it
static void hookSettingsMeasured(void* self){ tDeskLimitCtx=true; if(origSettingsMeasured) origSettingsMeasured(self); tDeskLimitCtx=false; }
static void hookLimitSliderSetLimit(void* self,float v){
  if(gDeskMode.load()==2 && tDeskLimitCtx){
    float k=kDesktop(); if(k>1.0f) v=v/k;
  }
  if(origLimitSliderSetLimit) origLimitSliderSetLimit(self,v);
}

// Context capture + pin the SharedMobileSettings instance
static void captureMobile(void* self){ if(self && !gMobileSettings){ if(pGchandleNew) pGchandleNew((MonoObject*)self,1); gMobileSettings=self; } }
static void hookCaptureHmd(void* self,int32_t v){ gHmd.store(v); captureMobile(self); if(origSetHmdType) origSetHmdType(self,v); }
static void hookCaptureCodec(void* self,int32_t v){ gCodec.store(v); captureMobile(self); if(origSetActiveCodec) origSetActiveCodec(self,v); }
static void hookCaptureFov(void* self,int32_t v){ gFov.store(v); captureMobile(self); if(origSetFoveated) origSetFoveated(self,v); }

// Incremental update: only write the baseline value (scaled locally via the lookup table), then resend the full packet (the sender multiplies by k)
static void hookSetDesktopLimit(void* self,float v){
  if(!origSetDesktopLimit) return;
  if(!gUserSettingsPin && pGchandleNew && pGchandleGet){ MonoGCHandle gh=pGchandleNew((MonoObject*)self,1); if(gh) gUserSettingsPin=pGchandleGet(gh); }
  if(v!=v) v=0.0f;
  if(v<0.0f) v=0.0f;
  MonoGCHandle h=0; void* pin=self;
  if(pGchandleNew){ h=pGchandleNew((MonoObject*)self,1); if(pGchandleGet) pin=pGchandleGet(h); }
  origSetDesktopLimit(pin,v);
  if(rateMul()>1.0f && gSpeedtestDone.load()){   // Don't resend the full packet before the speed test (avoids a bad packet with meas=0)
    if(origUserSendReload) origUserSendReload(pin);
    if(gMobileSettings && origSendReload) origSendReload(gMobileSettings);
  }
  if(h && pGchandleFree) pGchandleFree(h);
}
static void hookSetVRLimit(void* self,float v){
  if(!origSetVRLimit) return;
  if(!gUserSettingsPin && pGchandleNew && pGchandleGet){ MonoGCHandle gh=pGchandleNew((MonoObject*)self,1); if(gh) gUserSettingsPin=pGchandleGet(gh); }
  if(v!=v) v=0.0f;
  if(v<0.0f) v=0.0f;
  MonoGCHandle h=0; void* pin=self;
  if(pGchandleNew){ h=pGchandleNew((MonoObject*)self,1); if(pGchandleGet) pin=pGchandleGet(h); }
  origSetVRLimit(pin,v);
  if(rateMul()>1.0f && gSpeedtestDone.load()){   // Don't resend the full packet before the speed test (avoids a bad packet with meas=0)
    if(origUserSendReload) origUserSendReload(pin);
    if(gMobileSettings && origSendReload) origSendReload(gMobileSettings);
  }
  if(h && pGchandleFree) pGchandleFree(h);
}

// Full packet: multiply the tier by k before serializing, restore it after (without triggering a local recalculation)
static void hookSerializerObject(void* obj,void* writer){
  if(!origSerializerObject){ return; }
  if(!gUserSettingsPin && obj && pObjGetClass && gClsUserSettings && pGchandleNew
     && pObjGetClass((MonoObject*)obj)==gClsUserSettings){
    MonoGCHandle gh=pGchandleNew((MonoObject*)obj,1);
    if(gh && pGchandleGet) gUserSettingsPin=pGchandleGet(gh);
  }
  if(rateMul()<=1.0f || !obj || !gClsUserSettings || !gFieldDesktopLimit || !gFieldVRLimit
     || !pFieldGetValue || !pFieldSetValue || !pObjGetClass
     || pObjGetClass((MonoObject*)obj)!=gClsUserSettings){
    origSerializerObject(obj,writer); return;
  }
  MonoGCHandle h=0; void* pin=obj;
  if(pGchandleNew){ h=pGchandleNew((MonoObject*)obj,1); if(pGchandleGet) pin=pGchandleGet(h); }
  float d0=0,v0=0;
  pFieldGetValue(pin,gFieldDesktopLimit,&d0);
  pFieldGetValue(pin,gFieldVRLimit,&v0);
  float d1=d0*kDesktop(), v1=v0*kVR();
  pFieldSetValue(pin,gFieldDesktopLimit,&d1);
  pFieldSetValue(pin,gFieldVRLimit,&v1);
  origSerializerObject(pin,writer);
  pFieldSetValue(pin,gFieldDesktopLimit,&d0);
  pFieldSetValue(pin,gFieldVRLimit,&v0);
  if(h && pGchandleFree) pGchandleFree(h);
}
// Unlock: pin to the int32 max (10G overflows int32)
static void hookSetMeasuredBandwidth(void* self,int32_t v){
  captureMobile(self);
  bool firstReal=(v>0 && !gSpeedtestDone.load());
  int32_t out=v;
  if(gBitrateUnlock.load() && (gSpeedtestDone.load() || firstReal)) out=2147483647;
  if(firstReal) gSpeedtestDone.store(true);
  if(origSetMeasuredBandwidth) origSetMeasuredBandwidth(self,out);
  if(firstReal){
    if(origSendReload) origSendReload(self);
    if(origUserSendReload && gUserSettingsPin) origUserSendReload(gUserSettingsPin);
  }
}

static bool installBitrateHooks(){
  int ok=0;
  MonoClass* hx=getClass("Xenko.VR.HmdResolutionTypeExtensions, VirtualDesktop.Mobile.Shared");
  if(hx){
    fnMinDesk=(fnMinMax1)methodAddr(hx,"GetMinDesktopBitrate",1);
    fnMinVR =(fnMinMax1)methodAddr(hx,"GetMinVRBitrate",1);
    void* a;
    a=methodAddr(hx,"GetMaxDesktopBitrate",1);    if(a && hook(a,(void*)hookMaxDesk,(void**)&origMaxDesk)==0) ok++;
    a=methodAddr(hx,"GetMaxVRBitrate",3);         if(a && hook(a,(void*)hookMaxVR,(void**)&origMaxVR)==0) ok++;
    a=methodAddr(hx,"GetDesktopBitrate",2);       if(a && hook(a,(void*)hookDesktopBitrate,(void**)&origDesktopBitrate)==0) ok++;
    a=methodAddr(hx,"GetDesktopBitrateString",2); if(a && hook(a,(void*)hookDesktopBitrateString,(void**)&origDesktopBitrateString)==0) ok++;
  } else LOGE("HmdResolutionTypeExtensions class not found");
  MonoClass* us=getClass("VirtualDesktop.Mobile.SharedUserSettings, VirtualDesktop.Mobile.Shared");
  if(us){
    if(pClassGetField){ gFieldDesktopLimit=pClassGetField(us,"_desktopBitrateLimit"); gFieldVRLimit=pClassGetField(us,"_vrBitrateLimit"); }
    void* a;
    a=methodAddr(us,"set_DesktopBitrateLimit",1); if(a && hook(a,(void*)hookSetDesktopLimit,(void**)&origSetDesktopLimit)==0) ok++;
    a=methodAddr(us,"set_VRBitrateLimit",1);      if(a && hook(a,(void*)hookSetVRLimit,(void**)&origSetVRLimit)==0) ok++;
  } else LOGE("SharedUserSettings class not found");
  gClsUserSettings=us;
  if(us && pClassGetParent){
    MonoClass* c=pClassGetParent(us);
    for(int i=0;i<4 && c && !origUserSendReload;i++){ origUserSendReload=(void(*)(void*))methodAddr(c,"SendSettingsReload",0); if(!origUserSendReload) c=pClassGetParent(c); }
  }
  MonoClass* ms=getClass("VirtualDesktop.Mobile.SharedMobileSettings, VirtualDesktop.Mobile.Shared");
  if(ms){
    void* a;
    a=methodAddr(ms,"set_HmdType",1);           if(a && hook(a,(void*)hookCaptureHmd,(void**)&origSetHmdType)==0) ok++;
    a=methodAddr(ms,"set_FoveatedStreaming",1);  if(a && hook(a,(void*)hookCaptureFov,(void**)&origSetFoveated)==0) ok++;
    a=methodAddr(ms,"set_MeasuredBandwidth",1);  if(a && hook(a,(void*)hookSetMeasuredBandwidth,(void**)&origSetMeasuredBandwidth)==0) ok++;
    origSendReload=(void(*)(void*))methodAddr(ms,"SendSettingsReload",0);
    if(!origSendReload && pClassGetParent){ MonoClass* c=pClassGetParent(ms); for(int i=0;i<4 && c && !origSendReload;i++){ origSendReload=(void(*)(void*))methodAddr(c,"SendSettingsReload",0); if(!origSendReload) c=pClassGetParent(c); } }
  } else LOGE("SharedMobileSettings class not found");
  MonoClass* ss=getClass("VirtualDesktop.Mobile.SharedStreamerSettings, VirtualDesktop.Mobile.Shared");
  if(ss){ void* a=methodAddr(ss,"set_ActiveCodec",1); if(a && hook(a,(void*)hookCaptureCodec,(void**)&origSetActiveCodec)==0) ok++; } else LOGE("SharedStreamerSettings class not found");
  MonoClass* jh=getClass("VirtualDesktop.Core.JsonHelper, VirtualDesktop.Core");
  if(jh){ void* a=methodAddr(jh,"SerializerObject",2); if(a && hook(a,(void*)hookSerializerObject,(void**)&origSerializerObject)==0) ok++; } else LOGE("JsonHelper class not found");
  MonoClass* st=getClass("VirtualDesktop.Mobile.SettingsTab, VirtualDesktop.Mobile");
  if(st){ void* a=methodAddr(st,"OnMeasuredBandwidthChanged",0); if(a && hook(a,(void*)hookSettingsMeasured,(void**)&origSettingsMeasured)==0) ok++; } else LOGE("SettingsTab class not found");
  MonoClass* ls=getClass("Xenko.UI.Controls.LimitSlider, Xenko.UI");
  if(ls){ void* a=methodAddr(ls,"set_Limit",1); if(a && hook(a,(void*)hookLimitSliderSetLimit,(void**)&origLimitSliderSetLimit)==0) ok++; } else LOGE("LimitSlider class not found");
  gBitrateHooked.store(ok>0);
  LOGI("bitrate hooks=%d scale=%.2f",ok,rateMul());
  return hx && us && ms;
}
// Force LAN discovery
// Forces HasValidIdentity=true so locally discovered PCs are still merged in when the server is unreachable
static void captureUserSettings(void* self){
  if(!self) return;
  if(!gUserSettingsDefault){ gUserSettingsDefault=self; if(pGchandleNew) pGchandleNew((MonoObject*)self,1); }
  if(gFieldUserHasValidIdentity && pFieldSetValue){ bool t=true; pFieldSetValue(self,gFieldUserHasValidIdentity,&t); }
}
static void hookUserSettingsCtor(void* self){
  captureUserSettings(self);
  if(origUserSettingsCtor) origUserSettingsCtor(self);
}
static bool hookGetHasValidIdentity(void* self){
  if(!gForceLan.load()) return origGetHasValidIdentity ? origGetHasValidIdentity(self) : false;
  captureUserSettings(self);
  return true;
}
static void hookSetHasValidIdentity(void* self,bool v){
  if(gForceLan.load()){ captureUserSettings(self); v=true; }
  if(origSetHasValidIdentity) origSetHasValidIdentity(self,v);
}
static bool installForceLanHooks(){
  if(!gForceLan.load()){ LOGI("forceLan off: hooks skipped"); return true; }
  MonoClass* mus=getClass("VirtualDesktop.Mobile.UserSettings, VirtualDesktop.Mobile");
  if(!mus){ LOGE("UserSettings class not found"); return false; }
  if(pClassGetField) gFieldUserHasValidIdentity=pClassGetField(mus,"_hasValidIdentity");
  void* a;
  a=methodAddr(mus,"get_HasValidIdentity",0);
  if(a && hook(a,(void*)hookGetHasValidIdentity,(void**)&origGetHasValidIdentity)==0) LOGI("hooked UserSettings::get_HasValidIdentity");
  a=methodAddr(mus,"set_HasValidIdentity",1);
  if(a && hook(a,(void*)hookSetHasValidIdentity,(void**)&origSetHasValidIdentity)==0) LOGI("hooked UserSettings::set_HasValidIdentity");
  a=methodAddr(mus,".ctor",0);
  if(a && hook(a,(void*)hookUserSettingsCtor,(void**)&origUserSettingsCtor)==0) LOGI("hooked UserSettings::.ctor");
  LOGI("forceLan: identity field=%p",(void*)gFieldUserHasValidIdentity);
  return true;
}

// Serialize hook: load-monitoring capture for goodFont/goodMap
static void hookSerialize(void* x0,void* x1,void* x2,void* x3){
  void* slot=x1;
  if(origSerialize) origSerialize(x0,x1,x2,x3);
  if(serDone) return;
  if(serCount>=SER_CAP){ serDone=true; return; }
  serCount++;
  if(!slot) return;
  MonoObject* o=*(MonoObject**)slot;
  if(!o || !isFontClass(o)) return;
  int g=glyphCount(o);
  if(g>=FULL){
    markGood(o,"ser");
    if(goodMapHas(14)&&goodMapHas(16)&&goodMapHas(20)&&goodMapHas(24)) serDone=true;
  }
}

// ContentManager::Load hook: load-monitoring capture of the returned font
static void tryCaptLoad(MonoObject* o){
  if(!o || !isFontClass(o)) return;
  if(glyphCount(o)>=FULL) markGood(o,"load");
}
static MonoObject* hookLoad3(void* x0,void* x1,void* x2,void* x3){
  MonoObject* r=origLoad3?origLoad3(x0,x1,x2,x3):nullptr;
  tryCaptLoad(r);
  return r;
}
static MonoObject* hookLoad2(void* x0,void* x1,void* x2){
  MonoObject* r=origLoad2?origLoad2(x0,x1,x2):nullptr;
  tryCaptLoad(r);
  return r;
}

// doSetup (must run on the managed thread only)
static void doSetupImpl(){
  if(!gCorlib && pGetCorlib) gCorlib=pGetCorlib();
  if(!gCorlib) return;

  // Install font-unrelated hooks as early as possible so they aren't blocked by the font block's early return; retry next time if class resolution fails
  if(!gQualitySoundTried.load() && installQualitySoundHooks()) gQualitySoundTried.store(true);
  if(!gBitrateTried.load() && installBitrateHooks()) gBitrateTried.store(true);
  if(!gForceLanTried.load() && installForceLanHooks()) gForceLanTried.store(true);
  if(!gMusicHooked.load() && !gMusicTried.load()){
    gMusicTried.store(true);
    MonoClass* ms=getClass("VirtualDesktop.Mobile.MusicSystem, VirtualDesktop.Mobile");
    if(ms){
      void* aPlay=methodAddr(ms,"Play",0);
      if(aPlay && hook(aPlay,(void*)hookMusicPlay,(void**)&origMusicPlay)==0){
        gMusicHooked.store(true);
        LOGI("hooked MusicSystem::Play");
      } else LOGE("MusicSystem::Play hook failed");
    } else LOGE("MusicSystem class not found");
  }

  if(!gTextHooked.load()){
    MonoClass* tb=getClass("Xenko.UI.Controls.TextBlock, Xenko.UI");
    if(!tb) return;
    void* aSet =methodAddr(tb,"set_Text",1);
    void* aSetF=methodAddr(tb,"set_Font",1);
    void* aGetT=methodAddr(tb,"get_Text",0);
    if(!aSet||!aSetF) return;
    getTextFn=(fnGetText)aGetT;
    if(hook(aSet,(void*)hookSetText,(void**)&origSetText)!=0) LOGE("set_Text hook failed");
    if(hook(aSetF,(void*)hookSetFont,(void**)&origSetFont)!=0) LOGE("set_Font hook failed");
    MonoClass* sf=getClass("Xenko.Graphics.SpriteFont, Xenko.Graphics");
    if(sf){ getSizeFn=(fnGetSize)methodAddr(sf,"get_Size",0); }
    MonoClass* off=getClass("Xenko.Graphics.Font.OfflineRasterizedSpriteFont, Xenko.Graphics");
    if(off&&pClassGetField){ gClsOff=off; gDictField=pClassGetField(off,"CharacterToGlyph"); }
    gTextHooked.store(true);
    LOGI("hooked set_Text + set_Font");
  }

  if(!gSerHooked.load()){
    MonoClass* ser=getClass("Xenko.Graphics.Font.OfflineRasterizedSpriteFontSerializer, Xenko.Graphics");
    if(ser){
      void* aSer=methodAddr(ser,"Serialize",3);
      if(aSer && hook(aSer,(void*)hookSerialize,(void**)&origSerialize)==0){
        gSerHooked.store(true);
        LOGI("hooked OfflineRasterizedSpriteFontSerializer::Serialize");
      }
    }
  }

  if(!gCmHooked.load()){
    MonoClass* cm=getClass("Xenko.Core.Serialization.Contents.ContentManager, Xenko.Core.Serialization");
    if(cm){
      void* aLoad3=methodAddr(cm,"Load",3);
      void* aLoad2=methodAddr(cm,"Load",2);
      if(aLoad3&&aLoad2 &&
         hook(aLoad3,(void*)hookLoad3,(void**)&origLoad3)==0 &&
         hook(aLoad2,(void*)hookLoad2,(void**)&origLoad2)==0){
        gCmHooked.store(true);
        LOGI("hooked ContentManager::Load");
      }
    }
  }

  if(gTextHooked.load()&&gSerHooked.load()&&gCmHooked.load()){ gSetup.store(true); LOGI("setup done"); }
}
static void doSetup(){
  if(gSetup.load()) return;
  bool expected=false;
  if(!gInSetup.compare_exchange_strong(expected,true)) return;  // re-entrancy guard (GetType triggers ldstr again internally)
  doSetupImpl();
  gInSetup.store(false);
}

// Trigger / domain-capture hooks (all run on the managed thread)
static int gLd=0;
static MonoString* hookLdstr(void* a0,void* a1,void* a2,void* a3){
  if(!gDomain && a0) gDomain=(MonoDomain*)a0;
  gLd++;
  if(gLd<=5 || gLd%500==0) LOGI("ldstr call #%d",gLd);
  if(!gSetup.load() && gLd%20==2) doSetup();
  return origLdstr?origLdstr(a0,a1,a2,a3):nullptr;
}
// Every `new X()` in managed code allocates through this - unlike ldstr (interned, so a
// literal is only ever loaded once) this should fire continuously in any actively-running
// app, making it a much more reliable tick for a module that attaches after startup.
static int gObjNew=0;
static MonoObject* hookObjNew(MonoDomain* d,MonoClass* k){
  if(!gDomain && d) gDomain=d;
  gObjNew++;
  if(gObjNew<=5 || gObjNew%2000==0) LOGI("object_new call #%d",gObjNew);
  if(!gSetup.load() && gObjNew%50==7) doSetup();
  return origObjNew?origObjNew(d,k):nullptr;
}
static MonoDomain* hookJitInit(const char* name){
  LOGI("jit_init('%s') called",name?name:"?");
  MonoDomain* d=origJitInit?origJitInit(name):nullptr;
  if(!gDomain && d) gDomain=d;
  if(!gSetup.load()) doSetup();
  return d;
}
static int hookJitExec(MonoDomain* domain,void* asm_,int argc,char** argv){
  LOGI("jit_exec called");
  if(!gDomain && domain) gDomain=domain;
  if(!gSetup.load()) doSetup();
  return origJitExec?origJitExec(domain,asm_,argc,argv):-1;
}
static int hookRunMain(void* asm_,int argc,char** argv){
  LOGI("run_main called");
  if(!gDomain && pGetRootDomain) gDomain=pGetRootDomain();
  if(!gSetup.load()) doSetup();
  return origRunMain?origRunMain(asm_,argc,argv):-1;
}

// Resolve Mono symbols (from the handle passed to on_library_loaded)
static void resolveMono(void* mh){
  *(void**)&pGetCorlib       =dlsym(mh,"mono_get_corlib");
  *(void**)&pClassFromName   =dlsym(mh,"mono_class_from_name");
  *(void**)&pClassGetMethod  =dlsym(mh,"mono_class_get_method_from_name");
  *(void**)&pRuntimeInvoke   =dlsym(mh,"mono_runtime_invoke");
  *(void**)&pTypeGetClass    =dlsym(mh,"mono_type_get_class");
  *(void**)&pCompileMethod   =dlsym(mh,"mono_compile_method");
  *(void**)&pObjGetClass     =dlsym(mh,"mono_object_get_class");
  *(void**)&pObjUnbox        =dlsym(mh,"mono_object_unbox");
  *(void**)&pClassGetParent  =dlsym(mh,"mono_class_get_parent");
  *(void**)&pClassGetField   =dlsym(mh,"mono_class_get_field_from_name");
  *(void**)&pFieldGetValue   =dlsym(mh,"mono_field_get_value");
  *(void**)&pFieldSetValue   =dlsym(mh,"mono_field_set_value");
    *(void**)&pLdstrChecked    =dlsym(mh,"mono_ldstr_checked");
  *(void**)&pStringNewUtf16  =dlsym(mh,"mono_string_new_utf16");
  *(void**)&pGchandleNew     =dlsym(mh,"mono_gchandle_new");
  *(void**)&pGchandleGet     =dlsym(mh,"mono_gchandle_get_target");
  *(void**)&pGchandleFree    =dlsym(mh,"mono_gchandle_free");
  *(void**)&pGetRootDomain   =dlsym(mh,"mono_get_root_domain");
  *(void**)&pDomainGet       =dlsym(mh,"mono_domain_get");
  *(void**)&pJitThreadAttach =dlsym(mh,"mono_jit_thread_attach");
  *(void**)&pAttachToolsThread=dlsym(mh,"mono_threads_attach_tools_thread");
  *(void**)&pProfilerCreate   =dlsym(mh,"mono_profiler_create");
  *(void**)&pProfilerSetRuntimeInitCb=dlsym(mh,"mono_profiler_set_runtime_initialized_callback");
  *(void**)&pProfilerSetThreadStartedCb=dlsym(mh,"mono_profiler_set_thread_started_callback");
  *(void**)&pProfilerSetGcEventCb=dlsym(mh,"mono_profiler_set_gc_event_callback");
}

// This build is MonoVM-hosted (modern .NET-for-Android, confirmed via exported monovm_*
// symbols) and fully AOT-compiled (every assembly ships as its own libaot-*.dll.so) - live
// testing showed ldstr/jit_init/jit_exec/run_main/object_new never fire even once after
// attach, despite minutes of real UI use: AOT-compiled methods branch directly to each
// other's native code, so hot application logic essentially never calls back into any of
// Mono's generic/slow-path exported runtime functions. There is no reliable "tick" here -
// doSetup() has to run immediately once we attach.
//
// Three different "attach our own foreign thread" APIs have each hit a different internal
// assertion, all live-confirmed: mono_domain_foreach() aborts via
// mono_threads_enter_gc_unsafe_region_internal when called pre-attachment (crash-looped VD
// 3x); mono_jit_thread_attach(NULL) aborts with "condition `domain' not met" - it needs a
// real domain we don't have; mono_threads_attach_tools_thread() aborts with "condition
// `mono_threads_inited' not met", even after a 5s wait - this build's runtime bootstrap
// (thread subsystem, domain, GC) apparently never reaches a state any of these three
// classic embedding APIs expect, at least not within any delay we can safely guess.
//
// mono_profiler_set_*_callback() sidesteps the whole problem: it just stores a function
// pointer (no thread/GC state touched, so a too-late registration should fail silently
// rather than crash - confirmed live: registering runtime_initialized did not crash, it
// just never fired, meaning that one-shot boot event had already passed by attach time).
// Mono calls these back on its own already-correctly-initialized thread, no foreign-thread
// attach needed. runtime_initialized is one-shot at boot (too late for us); thread_started
// and gc_event both recur throughout a live app's whole lifetime, so either should still be
// reachable well after our late attach.
static void onRuntimeInitialized(void* prof){
  LOGI("mono_profiler runtime_initialized callback fired");
  doSetup();
}
static void onThreadStarted(void* prof,uintptr_t tid){
  LOGI("mono_profiler thread_started callback fired (tid=%zu)",(size_t)tid);
  doSetup();
}
static void onGcEvent(void* prof,int event,uint32_t generation,int isSerial){
  LOGI("mono_profiler gc_event callback fired (event=%d gen=%u)",event,generation);
  doSetup();
}

// Attach is now driven synchronously from the Java-level Runtime.initInternal hook (see
// MainModule.hookRuntimeInit -> nativeCheckMono), which calls this on the exact OS thread
// that just executed Xamarin's own initInternal() - a thread Mono's own bootstrap genuinely
// ran on, not a foreign pthread we spawned ourselves. Every foreign-thread-attach API we
// tried earlier (mono_domain_foreach, mono_jit_thread_attach, mono_threads_attach_tools_thread)
// asserted/aborted on a background pthread Mono never registered; calling doSetup() directly
// here should behave completely differently, since this isn't a foreign thread at all.
// setupMonoHooks() can still be reached from the 20s-delayed poll-thread fallback though
// (if the Java hook never fires) - gCalledFromJavaHook tracks which case we're in, since
// doSetup() is only safe to call directly from the former.
static thread_local bool tInSetupFromJavaHook=false;
static void setupMonoHooks(void* handle){
  resolveMono(handle);
  if(!pLdstrChecked){ LOGE("mono_ldstr_checked not found"); return; }
  if(hook((void*)pLdstrChecked,(void*)hookLdstr,(void**)&origLdstr)!=0) LOGE("ldstr hook failed");
  void* je=dlsym(handle,"mono_jit_exec");
  if(je) hook(je,(void*)hookJitExec,(void**)&origJitExec);
  void* ji=dlsym(handle,"mono_jit_init");
  if(ji) hook(ji,(void*)hookJitInit,(void**)&origJitInit);
  void* rm=dlsym(handle,"mono_runtime_run_main");
  if(rm) hook(rm,(void*)hookRunMain,(void**)&origRunMain);
  void* on=dlsym(handle,"mono_object_new");
  if(on && hook(on,(void*)hookObjNew,(void**)&origObjNew)!=0) LOGE("object_new hook failed");
  LOGI("mono hooked");
  void* h=pProfilerCreate?pProfilerCreate(nullptr):nullptr;
  if(h){
    if(pProfilerSetRuntimeInitCb){ pProfilerSetRuntimeInitCb(h,onRuntimeInitialized); LOGI("registered runtime_initialized callback"); }
    if(pProfilerSetThreadStartedCb){ pProfilerSetThreadStartedCb(h,onThreadStarted); LOGI("registered thread_started callback"); }
    if(pProfilerSetGcEventCb){ pProfilerSetGcEventCb(h,onGcEvent); LOGI("registered gc_event callback"); }
  } else LOGE("mono_profiler_create failed/unresolved");
  if(tInSetupFromJavaHook){
    LOGI("calling doSetup() directly - this is Xamarin's own bootstrap thread, not a foreign one");
    doSetup();
  }
}

// We find libmonosgen ourselves (polling for it, which never triggers a real load) instead
// of registering as a native_init.list module for a load-notification callback. The latter
// makes the host framework (Vector) install a global inline hook on the linker's own
// do_dlopen - on some framework/OS combinations that hook corrupts unrelated register state
// inside the linker's genuinely unmodified code, crashing the whole process on its very next
// (unrelated) dlopen call. Never hooking do_dlopen at all - ours or the framework's -
// sidesteps that entirely.
//
// Our own .so is injected (memfd-style) outside of VD's own per-APK ClassLoader, so it does
// not share VD's linker namespace. libmonosgen-2.0.so is one of VD's private native libs,
// loaded through that app-local namespace - RTLD_NOLOAD only searches namespaces visible to
// the caller, so it can never see it, no matter how long we wait (confirmed live: the lib
// was resident in /proc/self/maps while RTLD_NOLOAD kept missing it indefinitely). Instead
// we read the resident library's own absolute path out of /proc/self/maps and dlopen() that
// full path - bionic dedupes already-loaded libraries by realpath across namespaces before
// consulting namespace search-path rules, so this attaches to the real, already-running
// instance rather than mapping a second independent copy.
// Devices can have more than one resident copy of the same soname mapped at once (e.g. a
// Quest-customized zygote preloading common VR-runtime libs alongside VD's own private
// instance) - a single [min-base, max-end) spanning *all* matching maps lines would wrongly
// treat the gap between two unrelated instances as "valid" too. So each instance is tracked
// as its own tight range, grouped by its file-offset-0 segment (the start of a fresh load).
struct LibInstance { uintptr_t base=0, end=0; };
struct LoadedLib { std::string path; std::vector<LibInstance> instances; };
static LoadedLib findLoadedLib(const char* soname){
  LoadedLib r;
  FILE* f=fopen("/proc/self/maps","r");
  if(!f) return r;
  char line[1024];
  size_t sl=strlen(soname);
  while(fgets(line,sizeof(line),f)){
    size_t len=strlen(line);
    while(len>0 && (line[len-1]=='\n'||line[len-1]=='\r')) line[--len]=0;
    if(len<sl || strcmp(line+len-sl,soname)!=0) continue;
    char* slash=strchr(line,'/');
    if(!slash) continue;
    r.path=slash;
    unsigned long b=0,e=0,off=0;
    char perm[8]={0};
    if(sscanf(line,"%lx-%lx %7s %lx",&b,&e,perm,&off)<4) continue;
    if(off==0){
      r.instances.push_back({(uintptr_t)b,(uintptr_t)e});
    } else if(!r.instances.empty() && (uintptr_t)e>r.instances.back().end){
      r.instances.back().end=(uintptr_t)e;   // later segment of the same load (rodata/data)
    }
  }
  fclose(f);
  return r;
}
// Single attach attempt: finds the resident instance, dlopens it by path, and verifies the
// handle actually resolves into that instance's own address range before trusting it (see
// LibInstance comment above). Idempotent and safe to call from multiple places/threads -
// whichever call wins the race installs the hooks, every other call becomes a no-op.
static std::atomic<bool> gAttached{false};
static bool tryAttachMono(){
  if(gAttached.load()) return true;
  LoadedLib lib=findLoadedLib("libmonosgen-2.0.so");
  if(lib.path.empty()) return false;
  void* h=dlopen(lib.path.c_str(), RTLD_NOW);
  if(!h){ LOGE("dlopen('%s') failed: %s",lib.path.c_str(),dlerror()); return false; }
  void* probe=dlsym(h,"mono_get_root_domain");
  const LibInstance* match=nullptr;
  if(probe) for(auto& inst:lib.instances) if((uintptr_t)probe>=inst.base && (uintptr_t)probe<inst.end){ match=&inst; break; }
  if(!match){
    LOGE("dlopen('%s') returned a handle (probe=%p) matching none of the %zu resident instance(s) - refusing to hook a decoy copy",lib.path.c_str(),probe,lib.instances.size());
    return false;
  }
  bool expected=false;
  if(!gAttached.compare_exchange_strong(expected,true)) return true;  // another caller already won the race
  LOGI("libmonosgen attached (base=%p, %zu resident instance(s))",(void*)match->base,lib.instances.size());
  setupMonoHooks(h);
  return true;
}
// Give the Java-level Runtime.initInternal hook (MainModule.hookRuntimeInit ->
// nativeCheckMono) first crack at the attach race: it fires right after Mono's own bootstrap
// genuinely completes, while this loop's very first check can otherwise land within ~200ms
// of "native loaded" - right when System.loadLibrary("monosgen-2.0") returns inside
// LoadApplication but *before* initInternal() has even been called yet, let alone finished
// (confirmed live: this thread kept winning the race at that point, well before Mono was
// actually ready, same timing problem as before the Java hook existed). This stays purely a
// fallback for whenever that hook doesn't fire at all (e.g. a future app version renaming/
// resignaturing initInternal, caught safely by hookRuntimeInit's own try/catch).
static std::atomic<bool> gPollStarted{false};
static void pollForMono(){
  std::this_thread::sleep_for(std::chrono::seconds(20));
  for(int i=0;; i++){
    if(tryAttachMono()) return;
    if(i>0 && i%300==0) LOGI("still waiting for libmonosgen-2.0.so (%ds elapsed)",i/5+20);
    std::this_thread::sleep_for(std::chrono::milliseconds(200));
  }
}

// JNI exports
extern "C" JNIEXPORT void JNICALL Java_com_gitmorin_vdextra_MainModule_nativeInit(JNIEnv* env, jobject thiz){
  bool expected=false;
  if(!gPollStarted.compare_exchange_strong(expected,true)) return;
  std::thread(pollForMono).detach();
}
// Called synchronously from the Java-level Runtime.initInternal hook (MainModule.
// hookRuntimeInit), right after the real initInternal() call returns - catches libmonosgen
// on the exact thread that just finished Mono's own bootstrap, instead of racing it from our
// own background poll thread (see setupMonoHooks' comment).
extern "C" JNIEXPORT jboolean JNICALL Java_com_gitmorin_vdextra_MainModule_nativeCheckMono(JNIEnv* env, jobject thiz){
  LOGI("nativeCheckMono called from the Java initInternal hook");
  // initInternal() returns almost immediately (confirmed live: this fires ~70ms after launch),
  // but the very first attach attempt right then can still get rejected as a decoy - bionic's
  // realpath dedup apparently doesn't always kick in yet for a mapping this fresh (relocations
  // possibly still settling). We're clearly at the right moment timing-wise, just slightly
  // ahead of the linker - a brief bounded retry here (blocking this one JNI call, not spawning
  // anything) is a better fit than falling all the way back to the 20s poll-thread safety net.
  tInSetupFromJavaHook=true;
  for(int i=0;i<20;i++){
    if(tryAttachMono()) { tInSetupFromJavaHook=false; return JNI_TRUE; }
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
  }
  tInSetupFromJavaHook=false;
  return JNI_FALSE;
}
extern "C" JNIEXPORT void JNICALL Java_com_gitmorin_vdextra_MainModule_nativeSetNoMusic(JNIEnv* env, jobject thiz, jboolean disable){
  gNoMusic.store(disable==JNI_TRUE);
  LOGI("noMusic=%d",(int)gNoMusic.load());
}
extern "C" JNIEXPORT void JNICALL Java_com_gitmorin_vdextra_MainModule_nativeSetQuality(JNIEnv* env, jobject thiz, jboolean enable, jint mask){
  gQualitySound.store(enable==JNI_TRUE);
  gQualityMask.store((int)mask & 0x7F);
  LOGI("quality enable=%d mask=%d",(int)gQualitySound.load(),gQualityMask.load());
}
extern "C" JNIEXPORT void JNICALL Java_com_gitmorin_vdextra_MainModule_nativeSetBitrate(JNIEnv* env, jobject thiz, jboolean extend, jboolean unlock, jfloat scale){
  float s=scale;
  if(!(s>=1.0f)) s=1.0f;   // also handles NaN
  if(s>3.0f) s=3.0f;
  gBitrateExtend.store(extend==JNI_TRUE);
  gBitrateUnlock.store(unlock==JNI_TRUE);
  gBitrateScale.store(s);
  LOGI("bitrate extend=%d unlock=%d scale=%.2f",(int)gBitrateExtend.load(),(int)gBitrateUnlock.load(),s);
}
extern "C" JNIEXPORT void JNICALL Java_com_gitmorin_vdextra_MainModule_nativeSetForceLan(JNIEnv* env, jobject thiz, jboolean on){
  gForceLan.store(on==JNI_TRUE);
  LOGI("forceLan=%d",(int)gForceLan.load());
}
extern "C" JNIEXPORT void JNICALL Java_com_gitmorin_vdextra_MainModule_nativeSetDict(JNIEnv* env, jobject thiz, jobjectArray keys, jobjectArray vals){
  jint n=env->GetArrayLength(keys);
  jint m=env->GetArrayLength(vals);
  for(jint i=0;i<n && i<m;i++){
    jstring k=(jstring)env->GetObjectArrayElement(keys,i);
    jstring v=(jstring)env->GetObjectArrayElement(vals,i);
    const char* ck=k?env->GetStringUTFChars(k,nullptr):nullptr;
    const char* cv=v?env->GetStringUTFChars(v,nullptr):nullptr;
    if(ck&&cv) gDict[ck]=cv;
    if(ck) env->ReleaseStringUTFChars(k,ck);
    if(cv) env->ReleaseStringUTFChars(v,cv);
    if(k) env->DeleteLocalRef(k);
    if(v) env->DeleteLocalRef(v);
  }
  LOGI("dict=%d",(int)gDict.size());
}
