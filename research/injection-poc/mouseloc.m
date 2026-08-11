#import <Cocoa/Cocoa.h>
int main(){NSPoint p=[NSEvent mouseLocation];printf("%.1f %.1f\n",p.x,p.y);return 0;}
