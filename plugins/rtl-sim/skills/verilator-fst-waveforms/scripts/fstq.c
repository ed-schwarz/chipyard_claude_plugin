#include "fstapi.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
/* fstq <file> info
   fstq <file> list <substr> [substr2...]   (all substrings must match full path)
   fstq <file> dump <t0> <t1> <handle>...   */
static void cb(void *u, uint64_t t, fstHandle h, const unsigned char *v){ printf("%llu %u %s\n",(unsigned long long)t,h,v); }
int main(int argc,char**argv){
  void*ctx=fstReaderOpen(argv[1]); if(!ctx){fprintf(stderr,"open fail\n");return 1;}
  if(!strcmp(argv[2],"info")){
    printf("start %llu end %llu timescale 1e%d vars %llu\n",(unsigned long long)fstReaderGetStartTime(ctx),(unsigned long long)fstReaderGetEndTime(ctx),fstReaderGetTimescale(ctx),(unsigned long long)fstReaderGetVarCount(ctx));
  } else if(!strcmp(argv[2],"list")){
    char path[65536]; int lens[4096]; int depth=0; path[0]=0;
    struct fstHier*h;
    while((h=fstReaderIterateHier(ctx))){
      if(h->htyp==FST_HT_SCOPE){ lens[depth++]=strlen(path); strcat(path,h->u.scope.name); strcat(path,"."); }
      else if(h->htyp==FST_HT_UPSCOPE){ if(depth) path[lens[--depth]]=0; }
      else if(h->htyp==FST_HT_VAR){
        char full[70000]; snprintf(full,sizeof full,"%s%s",path,h->u.var.name);
        int ok=1; for(int i=3;i<argc;i++) if(!strstr(full,argv[i])){ok=0;break;}
        if(ok) printf("%u %u %s%s\n",h->u.var.handle,h->u.var.length,full,h->u.var.is_alias?" (alias)":"");
      }
    }
  } else if(!strcmp(argv[2],"dump")){
    uint64_t t0=strtoull(argv[3],0,10),t1=strtoull(argv[4],0,10);
    fstReaderClrFacProcessMaskAll(ctx);
    for(int i=5;i<argc;i++) fstReaderSetFacProcessMask(ctx,(fstHandle)strtoul(argv[i],0,10));
    fstReaderSetLimitTimeRange(ctx,t0,t1);
    fstReaderIterBlocks(ctx,cb,NULL,NULL);
  }
  fstReaderClose(ctx); return 0;
}
