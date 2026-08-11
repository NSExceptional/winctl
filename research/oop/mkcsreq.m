#import <Foundation/Foundation.h>
#import <Security/Security.h>
int main(int argc, char**argv){@autoreleasepool{
  if(argc<2){fprintf(stderr,"usage: mkcsreq 'req string'\n");return 2;}
  SecRequirementRef req=NULL;
  OSStatus s=SecRequirementCreateWithString((__bridge CFStringRef)@(argv[1]),kSecCSDefaultFlags,&req);
  if(s||!req){fprintf(stderr,"create failed %d\n",(int)s);return 3;}
  CFDataRef data=NULL; s=SecRequirementCopyData(req,kSecCSDefaultFlags,&data);
  if(s||!data){fprintf(stderr,"copydata failed %d\n",(int)s);return 4;}
  const unsigned char*b=CFDataGetBytePtr(data); CFIndex n=CFDataGetLength(data);
  for(CFIndex i=0;i<n;i++)printf("%02X",b[i]); printf("\n");
}return 0;}
