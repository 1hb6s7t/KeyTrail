/* Read-only labels/geometry of the demo main window and its Quit button.
 * No SendMessage, WM_COMMAND, clipboard, edit-control or process-memory access. */
#define UNICODE
#define _UNICODE
#include <windows.h>
#include <stdio.h>
#include <wchar.h>
static void utf8(const WCHAR *source,char *target,int size) {
    if (!WideCharToMultiByte(CP_UTF8,0,source,-1,target,size,NULL,NULL)) target[0]=0;
}
int main(void) {
    HWND window=FindWindowW(L"KeyTrailResident12",NULL);
    if (!window) {puts("{\"windowFound\":false}");return 2;}
    WCHAR title[256]={0},label[128]={0},className[128]={0};
    char title8[1024]={0},label8[512]={0},class8[512]={0};
    RECT mainRect={0},quitRect={0};DWORD owner=0;
    GetWindowTextW(window,title,256);GetWindowRect(window,&mainRect);
    GetWindowThreadProcessId(window,&owner);
    HWND quit=GetDlgItem(window,107);
    if (quit) {GetWindowTextW(quit,label,128);GetClassNameW(quit,className,128);GetWindowRect(quit,&quitRect);}
    utf8(title,title8,sizeof title8);utf8(label,label8,sizeof label8);utf8(className,class8,sizeof class8);
    printf("{\"windowFound\":true,\"windowHandle\":%llu,\"ownerWindowsPid\":%lu,\"mainTitle\":\"%s\",\"windowVisible\":%s,\"mainRect\":[%ld,%ld,%ld,%ld],\"quitFound\":%s,\"quitHandle\":%llu,\"quitVisible\":%s,\"quitTitle\":\"%s\",\"quitClass\":\"%s\",\"quitRect\":[%ld,%ld,%ld,%ld]}\n",
        (unsigned long long)(ULONG_PTR)window,(unsigned long)owner,title8,IsWindowVisible(window)?"true":"false",mainRect.left,mainRect.top,mainRect.right,mainRect.bottom,quit?"true":"false",(unsigned long long)(ULONG_PTR)quit,quit&&IsWindowVisible(quit)?"true":"false",label8,class8,quitRect.left,quitRect.top,quitRect.right,quitRect.bottom);
    return window&&quit&&IsWindowVisible(window)&&IsWindowVisible(quit)&&wcsstr(title,L"DEMO")&&wcscmp(label,L"Quit KeyTrail")==0&&_wcsicmp(className,L"Button")==0?0:3;
}
