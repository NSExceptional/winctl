#import <Cocoa/Cocoa.h>
int main(int c, char**v){@autoreleasepool{
  if(c<2){fprintf(stderr,"usage: pixstats file.png\n");return 2;}
  NSBitmapImageRep*r=[NSBitmapImageRep imageRepWithContentsOfFile:@(v[1])];
  if(!r){fprintf(stderr,"cannot load\n");return 2;}
  NSInteger w=r.pixelsWide,h=r.pixelsHigh; long long sr=0,sg=0,sb=0,cnt=0,nb=0;int mx=0;
  for(NSInteger y=0;y<h;y+=4)for(NSInteger x=0;x<w;x+=4){
    NSColor*col=[r colorAtX:x y:y];CGFloat rr,gg,bb,aa;
    [[col colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace] getRed:&rr green:&gg blue:&bb alpha:&aa];
    int R=rr*255,G=gg*255,B=bb*255; sr+=R;sg+=G;sb+=B;cnt++; if(R>mx)mx=R;if(G>mx)mx=G;if(B>mx)mx=B; if(R+G+B>30)nb++;
  }
  printf("size=%ldx%ld avg_rgb=(%lld,%lld,%lld) max_channel=%d nonblack_frac=%.3f\n",(long)w,(long)h,sr/cnt,sg/cnt,sb/cnt,mx,(double)nb/cnt);
}return 0;}
