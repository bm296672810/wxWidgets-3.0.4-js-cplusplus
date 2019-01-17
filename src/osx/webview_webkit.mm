/////////////////////////////////////////////////////////////////////////////
// Name:        src/osx/webview_webkit.mm
// Purpose:     wxWebViewWebKit - embeddable web kit control,
//                             OS X implementation of web view component
// Author:      Jethro Grassie / Kevin Ollivier / Marianne Gagnon
// Modified by:
// Created:     2004-4-16
// Copyright:   (c) Jethro Grassie / Kevin Ollivier / Marianne Gagnon
// Licence:     wxWindows licence
/////////////////////////////////////////////////////////////////////////////

// http://developer.apple.com/mac/library/documentation/Cocoa/Reference/WebKit/Classes/WebView_Class/Reference/Reference.html

#include "wx/osx/webview_webkit.h"

#if wxUSE_WEBVIEW && wxUSE_WEBVIEW_WEBKIT && (defined(__WXOSX_COCOA__) \
                                          ||  defined(__WXOSX_CARBON__))

// For compilers that support precompilation, includes "wx.h".
#include "wx/wxprec.h"

#ifndef WX_PRECOMP
    #include "wx/wx.h"
#endif

#include "wx/osx/private.h"
#include "wx/cocoa/string.h"
#include "wx/hashmap.h"
#include "wx/filesys.h"

#include <WebKit/WebKit.h>
#include <WebKit/HIWebView.h>
#include <WebKit/CarbonUtils.h>
#include <JavaScriptCore/JavaScriptCore.h>

#include <Foundation/NSURLError.h>

#include <string>
#include <vector>
using namespace std;

#define DEBUG_WEBKIT_SIZING 0

    /*
     **                         0.快捷回复,            1.回复,    2.回复全部,    3.转发
     */
const char * CEFFuncName[] = { "FastReply:mailNum:" , "Reply:" ,"ReplyAll:" ,"Foward:" ,
    /*
     **          4.作为附件转发,        5.查看附件,        6.双击查看附件
     */
    "AsAttachmentForward:"  ,"AccessoryView:mailNum:" ,"AccessoryViewDBclick:",
    /*
     **          7.下载附件              8.保存所有附件                9.复制附件
     */
    "AccessoryDownload:mailNum:" ,"AccessorySaveall:mailNum:" ,"AccessoryCopy:mailNum:" ,
    /*
     **          10.转发附件         11.复制             12.全选
     */
    "AccessoryRelay:mailNum:" ,"CopyText:mailNum:" ,"SelectAll:mailNum:" ,
    /*
     **          13.获取应用的url,    14.应用详情             15.安装应用
     */
    "GetApplicationUrl:" ,"ApplicationDetail:" ,"InstallApplication:" ,
    /*
     **          16.邮件内容改变  17.打开应用连接   18.点击邮箱账号
     */
    "EditOnInput" ,"OpenWindowUrl" ,"JumpWriteMail:" };

enum {
    CEFFastReply = 5300,    //快捷回复
    CEFReply,                //回复
    CEFReplyAll,            //回复全部
    CEFFoward,                //转发
    CEFAsAttachFoward,        //作为附件转发
    CEFAttachmentView,      //查看附件
    CEFAttachmentViewDBclick,//双击查看附件
    CEFAttachmentDownload,  //下载附件
    CEFAttachmentSaveall,   //保存所有附件
    CEFAttachmentCopy,      //复制附件
    CEFAttachmentRelay,     //转发附件
    CEFCopyText,            //复制
    CEFSelectALL,           //全选
    CEFGetApplicationUrl,   //应用的url
    CEFApplicationDetail,   // 应用详情
    CEFInstallApplication,  // 安装应用
    CEFEditOnInput,         // 邮件编辑
    CEFOpenWindowUrl,       // 处理应用内跳链接
    CEFJumpWriteMail,       // 处理跳转到写邮件界面
    DownloadFileSuccess,    // 下载文件完成
    DownloadFileFailed,     // 下载文件失败
};
//std::map<std::string,void*> g_javascriptCallbackFuncs;
// ----------------------------------------------------------------------------
// macros
// ----------------------------------------------------------------------------

wxIMPLEMENT_DYNAMIC_CLASS(wxWebViewWebKit, wxWebView);

BEGIN_EVENT_TABLE(wxWebViewWebKit, wxControl)
#if defined(__WXMAC__) && wxOSX_USE_CARBON
    EVT_SIZE(wxWebViewWebKit::OnSize)
#endif
END_EVENT_TABLE()

#if defined(__WXOSX__) && wxOSX_USE_CARBON

// ----------------------------------------------------------------------------
// Carbon Events handlers
// ----------------------------------------------------------------------------

// prototype for function in src/osx/carbon/nonownedwnd.cpp
void SetupMouseEvent( wxMouseEvent &wxevent , wxMacCarbonEvent &cEvent );

static const EventTypeSpec eventList[] =
{
    //{ kEventClassControl, kEventControlTrack } ,
    { kEventClassMouse, kEventMouseUp },
    { kEventClassMouse, kEventMouseDown },
    { kEventClassMouse, kEventMouseMoved },
    { kEventClassMouse, kEventMouseDragged },

    { kEventClassKeyboard, kEventRawKeyDown } ,
    { kEventClassKeyboard, kEventRawKeyRepeat } ,
    { kEventClassKeyboard, kEventRawKeyUp } ,
    { kEventClassKeyboard, kEventRawKeyModifiersChanged } ,

    { kEventClassTextInput, kEventTextInputUnicodeForKeyEvent } ,
    { kEventClassTextInput, kEventTextInputUpdateActiveInputArea } ,

#if DEBUG_WEBKIT_SIZING == 1
    { kEventClassControl, kEventControlBoundsChanged } ,
#endif
};

// mix this in from window.cpp
pascal OSStatus wxMacUnicodeTextEventHandler(EventHandlerCallRef handler,
                                             EventRef event, void *data) ;

// NOTE: This is mostly taken from KeyboardEventHandler in toplevel.cpp, but
// that expects the data pointer is a top-level window, so I needed to change
// that in this case. However, once 2.8 is out, we should factor out the common
// logic among the two functions and merge them.
static pascal OSStatus wxWebKitKeyEventHandler(EventHandlerCallRef handler,
                                               EventRef event, void *data)
{
    OSStatus result = eventNotHandledErr ;
    wxMacCarbonEvent cEvent( event ) ;

    wxWebViewWebKit* thisWindow = (wxWebViewWebKit*) data ;
    wxWindow* focus = thisWindow ;

    unsigned char charCode ;
    wxChar uniChar[2] ;
    uniChar[0] = 0;
    uniChar[1] = 0;

    UInt32 keyCode ;
    UInt32 modifiers ;
    UInt32 when = EventTimeToTicks( GetEventTime( event ) ) ;

#if wxUSE_UNICODE
    ByteCount dataSize = 0 ;
    if ( GetEventParameter(event, kEventParamKeyUnicodes, typeUnicodeText,
                           NULL, 0 , &dataSize, NULL ) == noErr)
    {
        UniChar buf[2] ;
        int numChars = dataSize / sizeof( UniChar) + 1;

        UniChar* charBuf = buf ;

        if ( numChars * 2 > 4 )
            charBuf = new UniChar[ numChars ] ;
        GetEventParameter(event, kEventParamKeyUnicodes, typeUnicodeText, NULL,
                          dataSize , NULL , charBuf) ;
        charBuf[ numChars - 1 ] = 0;

#if SIZEOF_WCHAR_T == 2
        uniChar = charBuf[0] ;
#else
        wxMBConvUTF16 converter ;
        converter.MB2WC( uniChar , (const char*)charBuf , 2 ) ;
#endif

        if ( numChars * 2 > 4 )
            delete[] charBuf ;
    }
#endif

    GetEventParameter(event, kEventParamKeyMacCharCodes, typeChar, NULL,
                      1, NULL, &charCode );
    GetEventParameter(event, kEventParamKeyCode, typeUInt32, NULL,
                      sizeof(UInt32), NULL, &keyCode );
    GetEventParameter(event, kEventParamKeyModifiers, typeUInt32, NULL,
                      sizeof(UInt32), NULL, &modifiers );

    UInt32 message = (keyCode << 8) + charCode;
    switch ( GetEventKind( event ) )
    {
        case kEventRawKeyRepeat :
        case kEventRawKeyDown :
        {
            WXEVENTREF formerEvent = wxTheApp->MacGetCurrentEvent() ;
            WXEVENTHANDLERCALLREF formerHandler =
                wxTheApp->MacGetCurrentEventHandlerCallRef() ;

            wxTheApp->MacSetCurrentEvent( event , handler ) ;
            if ( /* focus && */ wxTheApp->MacSendKeyDownEvent(
                focus, message, modifiers, when, uniChar[0]))
            {
                result = noErr ;
            }
            wxTheApp->MacSetCurrentEvent( formerEvent , formerHandler ) ;
        }
        break ;

        case kEventRawKeyUp :
            if ( /* focus && */ wxTheApp->MacSendKeyUpEvent(
                focus , message , modifiers , when , uniChar[0] ) )
            {
                result = noErr ;
            }
            break ;

        case kEventRawKeyModifiersChanged :
            {
                wxKeyEvent event(wxEVT_KEY_DOWN);

                event.m_shiftDown = modifiers & shiftKey;
                event.m_controlDown = modifiers & controlKey;
                event.m_altDown = modifiers & optionKey;
                event.m_metaDown = modifiers & cmdKey;

#if wxUSE_UNICODE
                event.m_uniChar = uniChar[0] ;
#endif

                event.SetTimestamp(when);
                event.SetEventObject(focus);

                if ( /* focus && */ (modifiers ^ wxApp::s_lastModifiers ) & controlKey )
                {
                    event.m_keyCode = WXK_CONTROL ;
                    event.SetEventType( ( modifiers & controlKey ) ? wxEVT_KEY_DOWN : wxEVT_KEY_UP ) ;
                    focus->GetEventHandler()->ProcessEvent( event ) ;
                }
                if ( /* focus && */ (modifiers ^ wxApp::s_lastModifiers ) & shiftKey )
                {
                    event.m_keyCode = WXK_SHIFT ;
                    event.SetEventType( ( modifiers & shiftKey ) ? wxEVT_KEY_DOWN : wxEVT_KEY_UP ) ;
                    focus->GetEventHandler()->ProcessEvent( event ) ;
                }
                if ( /* focus && */ (modifiers ^ wxApp::s_lastModifiers ) & optionKey )
                {
                    event.m_keyCode = WXK_ALT ;
                    event.SetEventType( ( modifiers & optionKey ) ? wxEVT_KEY_DOWN : wxEVT_KEY_UP ) ;
                    focus->GetEventHandler()->ProcessEvent( event ) ;
                }
                if ( /* focus && */ (modifiers ^ wxApp::s_lastModifiers ) & cmdKey )
                {
                    event.m_keyCode = WXK_COMMAND ;
                    event.SetEventType( ( modifiers & cmdKey ) ? wxEVT_KEY_DOWN : wxEVT_KEY_UP ) ;
                    focus->GetEventHandler()->ProcessEvent( event ) ;
                }

                wxApp::s_lastModifiers = modifiers ;
            }
            break ;

        default:
            break;
    }

    return result ;
}

static pascal OSStatus wxWebViewWebKitEventHandler( EventHandlerCallRef handler , EventRef event , void *data )
{
    OSStatus result = eventNotHandledErr ;

    wxMacCarbonEvent cEvent( event ) ;

    ControlRef controlRef ;
    wxWebViewWebKit* thisWindow = (wxWebViewWebKit*) data ;
    wxNonOwnedWindow* tlw = NULL;
    if (thisWindow)
        tlw = thisWindow->MacGetTopLevelWindow();

    cEvent.GetParameter( kEventParamDirectObject , &controlRef ) ;

    wxWindow* currentMouseWindow = thisWindow ;

    if ( wxApp::s_captureWindow )
        currentMouseWindow = wxApp::s_captureWindow;

    switch ( GetEventClass( event ) )
    {
        case kEventClassKeyboard:
        {
            result = wxWebKitKeyEventHandler(handler, event, data);
            break;
        }

        case kEventClassTextInput:
        {
            result = wxMacUnicodeTextEventHandler(handler, event, data);
            break;
        }

        case kEventClassMouse:
        {
            switch ( GetEventKind( event ) )
            {
                case kEventMouseDragged :
                case kEventMouseMoved :
                case kEventMouseDown :
                case kEventMouseUp :
                {
                    wxMouseEvent wxevent(wxEVT_LEFT_DOWN);
                    SetupMouseEvent( wxevent , cEvent ) ;

                    currentMouseWindow->ScreenToClient( &wxevent.m_x , &wxevent.m_y ) ;
                    wxevent.SetEventObject( currentMouseWindow ) ;
                    wxevent.SetId( currentMouseWindow->GetId() ) ;

                    if ( currentMouseWindow->GetEventHandler()->ProcessEvent(wxevent) )
                    {
                        result = noErr;
                    }

                    break; // this should enable WebKit to fire mouse dragged and mouse up events...
                }
                default :
                    break ;
            }
        }
        default:
            break;
    }
    ;

    result = CallNextEventHandler(handler, event);
    return result ;
}

DEFINE_ONE_SHOT_HANDLER_GETTER( wxWebViewWebKitEventHandler )

#endif

#if wxOSX_USE_COCOA

// NOTE: The standard WebView behavior is to clear the selection when the view loses focus.
// This causes various problems when the WebView is editable, though, and it is still possible
// to clear the selection when the view loses focus, so for now, just have it always retain
// selection regardless of focus state.
@interface WebView (Utilities)
- (BOOL) maintainsInactiveSelection;
@end

@implementation WebView (Utilities)

- (BOOL) maintainsInactiveSelection
{
    return true;
}

@end
#endif

@interface WebViewLoadDelegate : NSObject<WebFrameLoadDelegate>
{
    wxWebViewWebKit* webKitWindow;
}

- (id)initWithWxWindow: (wxWebViewWebKit*)inWindow;

@end

@interface WebViewPolicyDelegate : NSObject<WebPolicyDelegate>
{
    wxWebViewWebKit* webKitWindow;
}

- (id)initWithWxWindow: (wxWebViewWebKit*)inWindow;

@end

@interface WebViewUIDelegate : NSObject<WebUIDelegate>
{
    wxWebViewWebKit* webKitWindow;
}

- (id)initWithWxWindow: (wxWebViewWebKit*)inWindow;

@end

@interface WebResourceLoadDelegate : NSObject<WebResourceLoadDelegate>
{
    int resourceCount;
    int resourceFailedCount;
    int resourceCompletedCount;
    
    wxWebViewWebKit* webKitWindow;
}

- (id)initWithWxWindow: (wxWebViewWebKit*)inWindow;
@end
//We use a hash to map scheme names to wxWebViewHandler
WX_DECLARE_STRING_HASH_MAP(wxSharedPtr<wxWebViewHandler>, wxStringToWebHandlerMap);

static wxStringToWebHandlerMap g_stringHandlerMap;

@interface WebViewCustomProtocol : NSURLProtocol
{
}
@end


// ----------------------------------------------------------------------------
// creation/destruction
// ----------------------------------------------------------------------------

bool wxWebViewWebKit::Create(wxWindow *parent,
                                 wxWindowID winID,
                                 const wxString& strURL,
                                 const wxPoint& pos,
                                 const wxSize& size, long style,
                                 const wxString& name)
{
    m_busy = false;
    m_nextNavigationIsNewWindow = false;

    DontCreatePeer();
    wxControl::Create(parent, winID, pos, size, style, wxDefaultValidator, name);

#if wxOSX_USE_CARBON
    wxMacControl* peer = new wxMacControl(this);
    WebInitForCarbon();
    HIWebViewCreate( peer->GetControlRefAddr() );

    m_webView = (WebView*) HIWebViewGetWebView( peer->GetControlRef() );

    HIViewChangeFeatures( peer->GetControlRef() , kHIViewIsOpaque , 0 ) ;
    InstallControlEventHandler(peer->GetControlRef(),
                               GetwxWebViewWebKitEventHandlerUPP(),
                               GetEventTypeCount(eventList), eventList, this,
                              (EventHandlerRef *)&m_webKitCtrlEventHandler);
    SetPeer(peer);
#else
    NSRect r = wxOSXGetFrameForControl( this, pos , size ) ;
    m_webView = [[WebView alloc] initWithFrame:r
                                     frameName:@"webkitFrame"
                                     groupName:@"webkitGroup"];
    SetPeer(new wxWidgetCocoaImpl( this, m_webView ));
#endif

    MacPostControlCreate(pos, size);

#if wxOSX_USE_CARBON
    HIViewSetVisible( GetPeer()->GetControlRef(), true );
#endif
    [m_webView setHidden:false];

    [[m_webView preferences] setPlugInsEnabled:YES];

    // Register event listener interfaces
    WebViewLoadDelegate* loadDelegate =
            [[WebViewLoadDelegate alloc] initWithWxWindow: this];

    [m_webView setFrameLoadDelegate:loadDelegate];

    // this is used to veto page loads, etc.
    WebViewPolicyDelegate* policyDelegate =
            [[WebViewPolicyDelegate alloc] initWithWxWindow: this];

    [m_webView setPolicyDelegate:policyDelegate];

    WebViewUIDelegate* uiDelegate =
            [[WebViewUIDelegate alloc] initWithWxWindow: this];

    [m_webView setUIDelegate:uiDelegate];

    WebResourceLoadDelegate* resourceDelegate = [[WebResourceLoadDelegate alloc] initWithWxWindow: this];
    
    [m_webView setResourceLoadDelegate:resourceDelegate];
    
    //Register our own class for custom scheme handling
    [NSURLProtocol registerClass:[WebViewCustomProtocol class]];

    LoadURL(strURL);
    return true;
}

wxWebViewWebKit::~wxWebViewWebKit()
{
    WebViewLoadDelegate* loadDelegate = [m_webView frameLoadDelegate];
    WebViewPolicyDelegate* policyDelegate = [m_webView policyDelegate];
    WebViewUIDelegate* uiDelegate = [m_webView UIDelegate];
    WebResourceLoadDelegate* resourceDelegate = [m_webView resourceLoadDelegate];

    [m_webView setFrameLoadDelegate: nil];
    [m_webView setPolicyDelegate: nil];
    [m_webView setUIDelegate: nil];
    [m_webView setResourceLoadDelegate: nil];

    
    if (loadDelegate)
        [loadDelegate release];

    if (policyDelegate)
        [policyDelegate release];

    if (uiDelegate)
        [uiDelegate release];
    
    if(resourceDelegate)
        [resourceDelegate release];

}

// ----------------------------------------------------------------------------
// public methods
// ----------------------------------------------------------------------------

bool wxWebViewWebKit::CanGoBack() const
{
    if ( !m_webView )
        return false;

    return [m_webView canGoBack];
}

bool wxWebViewWebKit::CanGoForward() const
{
    if ( !m_webView )
        return false;

    return [m_webView canGoForward];
}

void wxWebViewWebKit::GoBack()
{
    if ( !m_webView )
        return;

    [m_webView goBack];
}

void wxWebViewWebKit::GoForward()
{
    if ( !m_webView )
        return;

    [m_webView goForward];
}

void wxWebViewWebKit::Reload(wxWebViewReloadFlags flags)
{
    if ( !m_webView )
        return;

    if (flags & wxWEBVIEW_RELOAD_NO_CACHE)
    {
        // TODO: test this indeed bypasses the cache
        [[m_webView preferences] setUsesPageCache:NO];
        [[m_webView mainFrame] reload];
        [[m_webView preferences] setUsesPageCache:YES];
    }
    else
    {
        [[m_webView mainFrame] reload];
    }
}

void wxWebViewWebKit::Stop()
{
    if ( !m_webView )
        return;

    [[m_webView mainFrame] stopLoading];
}

bool wxWebViewWebKit::CanGetPageSource() const
{
    if ( !m_webView )
        return false;

    WebDataSource* dataSource = [[m_webView mainFrame] dataSource];
    return ( [[dataSource representation] canProvideDocumentSource] );
}

wxString wxWebViewWebKit::GetPageSource() const
{

    if (CanGetPageSource())
    {
        NSString *result = [m_webView stringByEvaluatingJavaScriptFromString:
                            @"document.documentElement.outerHTML"];
        
        if(result != nil)
            return wxStringWithNSString(result);
//        WebDataSource* dataSource = [[m_webView mainFrame] dataSource];
//        wxASSERT (dataSource != nil);
//
//        id<WebDocumentRepresentation> representation = [dataSource representation];
//        wxASSERT (representation != nil);
//
//        NSString* source = [representation documentSource];
//        if (source == nil)
//        {
//            return wxEmptyString;
//        }
//        NSLog(@"wxWebViewWebKit::GetPageSource%@",source);
//        return wxStringWithNSString( source );
    }

    return wxEmptyString;
}

bool wxWebViewWebKit::CanIncreaseTextSize() const
{
    if ( !m_webView )
        return false;

    if ([m_webView canMakeTextLarger])
        return true;
    else
        return false;
}

void wxWebViewWebKit::IncreaseTextSize()
{
    if ( !m_webView )
        return;

    if (CanIncreaseTextSize())
        [m_webView makeTextLarger:(WebView*)m_webView];
}

bool wxWebViewWebKit::CanDecreaseTextSize() const
{
    if ( !m_webView )
        return false;

    if ([m_webView canMakeTextSmaller])
        return true;
    else
        return false;
}

void wxWebViewWebKit::DecreaseTextSize()
{
    if ( !m_webView )
        return;

    if (CanDecreaseTextSize())
        [m_webView makeTextSmaller:(WebView*)m_webView];
}

void wxWebViewWebKit::Print()
{

    // TODO: allow specifying the "show prompt" parameter in Print() ?
    bool showPrompt = true;

    if ( !m_webView )
        return;

    id view = [[[m_webView mainFrame] frameView] documentView];
    NSPrintOperation *op = [NSPrintOperation printOperationWithView:view
                                 printInfo: [NSPrintInfo sharedPrintInfo]];
    if (showPrompt)
    {
        [op setShowsPrintPanel: showPrompt];
        // in my tests, the progress bar always freezes and it stops the whole
        // print operation. do not turn this to true unless there is a
        // workaround for the bug.
        [op setShowsProgressPanel: false];
    }
    // Print it.
    [op runOperation];
}

void wxWebViewWebKit::SetEditable(bool enable)
{
    if ( !m_webView )
        return;

    [m_webView setEditable:enable ];
}

bool wxWebViewWebKit::IsEditable() const
{
    if ( !m_webView )
        return false;

    return [m_webView isEditable];
}

void wxWebViewWebKit::SetZoomType(wxWebViewZoomType zoomType)
{
    // there is only one supported zoom type at the moment so this setter
    // does nothing beyond checking sanity
    wxASSERT(zoomType == wxWEBVIEW_ZOOM_TYPE_TEXT);
}

wxWebViewZoomType wxWebViewWebKit::GetZoomType() const
{
    // for now that's the only one that is supported
    // FIXME: does the default zoom type change depending on webkit versions? :S
    //        Then this will be wrong
    return wxWEBVIEW_ZOOM_TYPE_TEXT;
}

bool wxWebViewWebKit::CanSetZoomType(wxWebViewZoomType type) const
{
    switch (type)
    {
        // for now that's the only one that is supported
        // TODO: I know recent versions of webkit support layout zoom too,
        //       check if we can support it
        case wxWEBVIEW_ZOOM_TYPE_TEXT:
            return true;

        default:
            return false;
    }
}

int wxWebViewWebKit::GetScrollPos()
{
    id result = [[m_webView windowScriptObject]
                    evaluateWebScript:@"document.body.scrollTop"];
    return [result intValue];
}

void wxWebViewWebKit::SetScrollPos(int pos)
{
    if ( !m_webView )
        return;

    wxString javascript;
    javascript.Printf(wxT("document.body.scrollTop = %d;"), pos);
    [[m_webView windowScriptObject] evaluateWebScript:
            (NSString*)wxNSStringWithWxString( javascript )];
}

wxString wxWebViewWebKit::GetSelectedText() const
{
    DOMRange* dr = [m_webView selectedDOMRange];
    if ( !dr )
        return wxString();

    return wxStringWithNSString([dr toString]);
}

void wxWebViewWebKit::RunScript(const wxString& javascript)
{
    if ( !m_webView )
        return;

    [[m_webView windowScriptObject] evaluateWebScript:
                    (NSString*)wxNSStringWithWxString( javascript )];
}

void wxWebViewWebKit::OnSize(wxSizeEvent &event)
{
#if defined(__WXMAC__) && wxOSX_USE_CARBON
    // This is a nasty hack because WebKit seems to lose its position when it is
    // embedded in a control that is not itself the content view for a TLW.
    // I put it in OnSize because these calcs are not perfect, and in fact are
    // basically guesses based on reverse engineering, so it's best to give
    // people the option of overriding OnSize with their own calcs if need be.
    // I also left some test debugging print statements as a convenience if
    // a(nother) problem crops up.

    wxWindow* tlw = MacGetTopLevelWindow();

    NSRect frame = [(WebView*)m_webView frame];
    NSRect bounds = [(WebView*)m_webView bounds];

#if DEBUG_WEBKIT_SIZING
    fprintf(stderr,"Carbon window x=%d, y=%d, width=%d, height=%d\n",
            GetPosition().x, GetPosition().y, GetSize().x, GetSize().y);
    fprintf(stderr, "Cocoa window frame x=%G, y=%G, width=%G, height=%G\n",
            frame.origin.x, frame.origin.y,
            frame.size.width, frame.size.height);
    fprintf(stderr, "Cocoa window bounds x=%G, y=%G, width=%G, height=%G\n",
            bounds.origin.x, bounds.origin.y,
            bounds.size.width, bounds.size.height);
#endif

    // This must be the case that Apple tested with, because well, in this one case
    // we don't need to do anything! It just works. ;)
    if (GetParent() == tlw) return;

    // since we no longer use parent coordinates, we always want 0,0.
    int x = 0;
    int y = 0;

    HIRect rect;
    rect.origin.x = x;
    rect.origin.y = y;

#if DEBUG_WEBKIT_SIZING
    printf("Before conversion, origin is: x = %d, y = %d\n", x, y);
#endif

    // NB: In most cases, when calling HIViewConvertRect, what people want is to
    // use GetRootControl(), and this tripped me up at first. But in fact, what
    // we want is the root view, because we need to make the y origin relative
    // to the very top of the window, not its contents, since we later flip
    // the y coordinate for Cocoa.
    HIViewConvertRect (&rect, GetPeer()->GetControlRef(),
                                HIViewGetRoot(
                                    (WindowRef) MacGetTopLevelWindowRef()
                                 ));

    x = (int)rect.origin.x;
    y = (int)rect.origin.y;

#if DEBUG_WEBKIT_SIZING
    printf("Moving Cocoa frame origin to: x = %d, y = %d\n", x, y);
#endif

    if (tlw){
        //flip the y coordinate to convert to Cocoa coordinates
        y = tlw->GetSize().y - ((GetSize().y) + y);
    }

#if DEBUG_WEBKIT_SIZING
    printf("y = %d after flipping value\n", y);
#endif

    frame.origin.x = x;
    frame.origin.y = y;
    [(WebView*)m_webView setFrame:frame];

    if (IsShown())
        [(WebView*)m_webView display];
    event.Skip();
#endif
}

void wxWebViewWebKit::MacVisibilityChanged(){
#if defined(__WXMAC__) && wxOSX_USE_CARBON
    bool isHidden = !IsControlVisible( GetPeer()->GetControlRef());
    if (!isHidden)
        [(WebView*)m_webView display];

    [m_webView setHidden:isHidden];
#endif
}

void wxWebViewWebKit::LoadURL(const wxString& url)
{
    [[m_webView mainFrame] loadRequest:[NSURLRequest requestWithURL:
            [NSURL URLWithString:wxNSStringWithWxString(url)]]];
}

wxString wxWebViewWebKit::GetCurrentURL() const
{
    return wxStringWithNSString([m_webView mainFrameURL]);
}

wxString wxWebViewWebKit::GetCurrentTitle() const
{
    return wxStringWithNSString([m_webView mainFrameTitle]);
}

float wxWebViewWebKit::GetWebkitZoom() const
{
    return [m_webView textSizeMultiplier];
}

void wxWebViewWebKit::SetWebkitZoom(float zoom)
{
    [m_webView setTextSizeMultiplier:zoom];
}

wxWebViewZoom wxWebViewWebKit::GetZoom() const
{
    float zoom = GetWebkitZoom();

    // arbitrary way to map float zoom to our common zoom enum
    if (zoom <= 0.55)
    {
        return wxWEBVIEW_ZOOM_TINY;
    }
    else if (zoom > 0.55 && zoom <= 0.85)
    {
        return wxWEBVIEW_ZOOM_SMALL;
    }
    else if (zoom > 0.85 && zoom <= 1.15)
    {
        return wxWEBVIEW_ZOOM_MEDIUM;
    }
    else if (zoom > 1.15 && zoom <= 1.45)
    {
        return wxWEBVIEW_ZOOM_LARGE;
    }
    else if (zoom > 1.45)
    {
        return wxWEBVIEW_ZOOM_LARGEST;
    }

    // to shut up compilers, this can never be reached logically
    wxASSERT(false);
    return wxWEBVIEW_ZOOM_MEDIUM;
}

void wxWebViewWebKit::SetZoom(wxWebViewZoom zoom)
{
    // arbitrary way to map our common zoom enum to float zoom
    switch (zoom)
    {
        case wxWEBVIEW_ZOOM_TINY:
            SetWebkitZoom(0.4f);
            break;

        case wxWEBVIEW_ZOOM_SMALL:
            SetWebkitZoom(0.7f);
            break;

        case wxWEBVIEW_ZOOM_MEDIUM:
            SetWebkitZoom(1.0f);
            break;

        case wxWEBVIEW_ZOOM_LARGE:
            SetWebkitZoom(1.3);
            break;

        case wxWEBVIEW_ZOOM_LARGEST:
            SetWebkitZoom(1.6);
            break;

        default:
            wxASSERT(false);
    }

}

void wxWebViewWebKit::DoSetPage(const wxString& src, const wxString& baseUrl)
{
   if ( !m_webView )
        return;

    [[m_webView mainFrame] loadHTMLString:(NSString*)wxNSStringWithWxString(src)
                                  baseURL:[NSURL URLWithString:
                                    wxNSStringWithWxString( baseUrl )]];
}

void wxWebViewWebKit::Cut()
{
    if ( !m_webView )
        return;

    [m_webView cut:m_webView];
}

void wxWebViewWebKit::Copy()
{
    if ( !m_webView )
        return;

    [m_webView copy:m_webView];
}

void wxWebViewWebKit::Paste()
{
    if ( !m_webView )
        return;

    [m_webView paste:m_webView];
}

void wxWebViewWebKit::DeleteSelection()
{
    if ( !m_webView )
        return;

    [m_webView deleteSelection];
}

bool wxWebViewWebKit::HasSelection() const
{
    DOMRange* range = [m_webView selectedDOMRange];
    if(!range)
    {
        return false;
    }
    else
    {
        return true;
    }
}

void wxWebViewWebKit::ClearSelection()
{
    //We use javascript as selection isn't exposed at the moment in webkit
    RunScript("window.getSelection().removeAllRanges();");
}

void wxWebViewWebKit::SelectAll()
{
    RunScript("window.getSelection().selectAllChildren(document.body);");
}

wxString wxWebViewWebKit::GetSelectedSource() const
{
    DOMRange* dr = [m_webView selectedDOMRange];
    if ( !dr )
        return wxString();

    return wxStringWithNSString([dr markupString]);
}

wxString wxWebViewWebKit::GetPageText() const
{
    NSString *result = [m_webView stringByEvaluatingJavaScriptFromString:
                                  @"document.body.textContent"];
    return wxStringWithNSString(result);
}

void wxWebViewWebKit::EnableHistory(bool enable)
{
    if ( !m_webView )
        return;

    [m_webView setMaintainsBackForwardList:enable];
}

void wxWebViewWebKit::ClearHistory()
{
    [m_webView setMaintainsBackForwardList:NO];
    [m_webView setMaintainsBackForwardList:YES];
}

wxVector<wxSharedPtr<wxWebViewHistoryItem> > wxWebViewWebKit::GetBackwardHistory()
{
    wxVector<wxSharedPtr<wxWebViewHistoryItem> > backhist;
    WebBackForwardList* history = [m_webView backForwardList];
    int count = [history backListCount];
    for(int i = -count; i < 0; i++)
    {
        WebHistoryItem* item = [history itemAtIndex:i];
        wxString url = wxStringWithNSString([item URLString]);
        wxString title = wxStringWithNSString([item title]);
        wxWebViewHistoryItem* wxitem = new wxWebViewHistoryItem(url, title);
        wxitem->m_histItem = item;
        wxSharedPtr<wxWebViewHistoryItem> itemptr(wxitem);
        backhist.push_back(itemptr);
    }
    return backhist;
}

wxVector<wxSharedPtr<wxWebViewHistoryItem> > wxWebViewWebKit::GetForwardHistory()
{
    wxVector<wxSharedPtr<wxWebViewHistoryItem> > forwardhist;
    WebBackForwardList* history = [m_webView backForwardList];
    int count = [history forwardListCount];
    for(int i = 1; i <= count; i++)
    {
        WebHistoryItem* item = [history itemAtIndex:i];
        wxString url = wxStringWithNSString([item URLString]);
        wxString title = wxStringWithNSString([item title]);
        wxWebViewHistoryItem* wxitem = new wxWebViewHistoryItem(url, title);
        wxitem->m_histItem = item;
        wxSharedPtr<wxWebViewHistoryItem> itemptr(wxitem);
        forwardhist.push_back(itemptr);
    }
    return forwardhist;
}

void wxWebViewWebKit::LoadHistoryItem(wxSharedPtr<wxWebViewHistoryItem> item)
{
    [m_webView goToBackForwardItem:item->m_histItem];
}

bool wxWebViewWebKit::CanUndo() const
{
    return [[m_webView undoManager] canUndo];
}

bool wxWebViewWebKit::CanRedo() const
{
    return [[m_webView undoManager] canRedo];
}

void wxWebViewWebKit::Undo()
{
    [[m_webView undoManager] undo];
}

void wxWebViewWebKit::Redo()
{
    [[m_webView undoManager] redo];
}

void wxWebViewWebKit::RegisterHandler(wxSharedPtr<wxWebViewHandler> handler)
{
    g_stringHandlerMap[handler->GetName()] = handler;
}

//------------------------------------------------------------
// Listener interfaces
//------------------------------------------------------------

// NB: I'm still tracking this down, but it appears the Cocoa window
// still has these events fired on it while the Carbon control is being
// destroyed. Therefore, we must be careful to check both the existence
// of the Carbon control and the event handler before firing events.


@implementation WebViewLoadDelegate

- (id)initWithWxWindow: (wxWebViewWebKit*)inWindow
{
    [super init];
    webKitWindow = inWindow;    // non retained
    return self;
}

- (void)webView:(WebView *)sender
    didStartProvisionalLoadForFrame:(WebFrame *)frame
{
    webKitWindow->m_busy = true;
}

- (void)webView:(WebView *)sender didCommitLoadForFrame:(WebFrame *)frame
{
    webKitWindow->m_busy = true;
    NSLog(@"WebViewLoadDelegate");
    
    if (webKitWindow && frame == [sender mainFrame]){
        NSString *url = [[[[frame dataSource] request] URL] absoluteString];
        wxString target = wxStringWithNSString([frame name]);
        wxWebViewEvent event(wxEVT_WEBVIEW_NAVIGATED,
                             webKitWindow->GetId(),
                             wxStringWithNSString( url ),
                             target);

        if (webKitWindow && webKitWindow->GetEventHandler())
            webKitWindow->GetEventHandler()->ProcessEvent(event);
    }
}

- (void)webView:(WebView *)sender didFinishLoadForFrame:(WebFrame *)frame
{
    webKitWindow->m_busy = false;

    if (webKitWindow && frame == [sender mainFrame]){
        NSString *url = [[[[frame dataSource] request] URL] absoluteString];

        wxString target = wxStringWithNSString([frame name]);
        wxWebViewEvent event(wxEVT_WEBVIEW_LOADED,
                             webKitWindow->GetId(),
                             wxStringWithNSString( url ),
                             target);

        if (webKitWindow && webKitWindow->GetEventHandler())
            webKitWindow->GetEventHandler()->ProcessEvent(event);
    }
}

wxString nsErrorToWxHtmlError(NSError* error, wxWebViewNavigationError* out)
{
    *out = wxWEBVIEW_NAV_ERR_OTHER;

    if ([[error domain] isEqualToString:NSURLErrorDomain])
    {
        switch ([error code])
        {
            case NSURLErrorCannotFindHost:
            case NSURLErrorFileDoesNotExist:
            case NSURLErrorRedirectToNonExistentLocation:
                *out = wxWEBVIEW_NAV_ERR_NOT_FOUND;
                break;

            case NSURLErrorResourceUnavailable:
            case NSURLErrorHTTPTooManyRedirects:
            case NSURLErrorDataLengthExceedsMaximum:
            case NSURLErrorBadURL:
            case NSURLErrorFileIsDirectory:
                *out = wxWEBVIEW_NAV_ERR_REQUEST;
                break;

            case NSURLErrorTimedOut:
            case NSURLErrorDNSLookupFailed:
            case NSURLErrorNetworkConnectionLost:
            case NSURLErrorCannotConnectToHost:
            case NSURLErrorNotConnectedToInternet:
            //case NSURLErrorInternationalRoamingOff:
            //case NSURLErrorCallIsActive:
            //case NSURLErrorDataNotAllowed:
                *out = wxWEBVIEW_NAV_ERR_CONNECTION;
                break;

            case NSURLErrorCancelled:
            case NSURLErrorUserCancelledAuthentication:
                *out = wxWEBVIEW_NAV_ERR_USER_CANCELLED;
                break;

            case NSURLErrorCannotDecodeRawData:
            case NSURLErrorCannotDecodeContentData:
            case NSURLErrorCannotParseResponse:
            case NSURLErrorBadServerResponse:
                *out = wxWEBVIEW_NAV_ERR_REQUEST;
                break;

            case NSURLErrorUserAuthenticationRequired:
            case NSURLErrorSecureConnectionFailed:
#if MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_6
            case NSURLErrorClientCertificateRequired:
#endif
                *out = wxWEBVIEW_NAV_ERR_AUTH;
                break;

            case NSURLErrorNoPermissionsToReadFile:
                *out = wxWEBVIEW_NAV_ERR_SECURITY;
                break;

            case NSURLErrorServerCertificateHasBadDate:
            case NSURLErrorServerCertificateUntrusted:
            case NSURLErrorServerCertificateHasUnknownRoot:
            case NSURLErrorServerCertificateNotYetValid:
            case NSURLErrorClientCertificateRejected:
                *out = wxWEBVIEW_NAV_ERR_CERTIFICATE;
                break;
        }
    }

    wxString message = wxStringWithNSString([error localizedDescription]);
    NSString* detail = [error localizedFailureReason];
    if (detail != NULL)
    {
        message = message + " (" + wxStringWithNSString(detail) + ")";
    }
    return message;
}

- (void)webView:(WebView *)sender didFailLoadWithError:(NSError*) error
        forFrame:(WebFrame *)frame
{
    webKitWindow->m_busy = false;

    if (webKitWindow && frame == [sender mainFrame]){
        NSString *url = [[[[frame dataSource] request] URL] absoluteString];

        wxWebViewNavigationError type;
        wxString description = nsErrorToWxHtmlError(error, &type);
        wxWebViewEvent event(wxEVT_WEBVIEW_ERROR,
                             webKitWindow->GetId(),
                             wxStringWithNSString( url ),
                             wxEmptyString);
        event.SetString(description);
        event.SetInt(type);

        if (webKitWindow && webKitWindow->GetEventHandler())
        {
            webKitWindow->GetEventHandler()->ProcessEvent(event);
        }
    }
}

- (void)webView:(WebView *)sender
        didFailProvisionalLoadWithError:(NSError*)error
                               forFrame:(WebFrame *)frame
{
    webKitWindow->m_busy = false;

    if (webKitWindow && frame == [sender mainFrame]){
        NSString *url = [[[[frame provisionalDataSource] request] URL]
                            absoluteString];

        wxWebViewNavigationError type;
        wxString description = nsErrorToWxHtmlError(error, &type);
        wxWebViewEvent event(wxEVT_WEBVIEW_ERROR,
                             webKitWindow->GetId(),
                             wxStringWithNSString( url ),
                             wxEmptyString);
        event.SetString(description);
        event.SetInt(type);

        if (webKitWindow && webKitWindow->GetEventHandler())
            webKitWindow->GetEventHandler()->ProcessEvent(event);
    }
}

- (void)webView:(WebView *)sender didReceiveTitle:(NSString *)title
                                         forFrame:(WebFrame *)frame
{
    wxString target = wxStringWithNSString([frame name]);
    wxWebViewEvent event(wxEVT_WEBVIEW_TITLE_CHANGED,
                         webKitWindow->GetId(),
                         webKitWindow->GetCurrentURL(),
                         target);

    event.SetString(wxStringWithNSString(title));

    if (webKitWindow && webKitWindow->GetEventHandler())
        webKitWindow->GetEventHandler()->ProcessEvent(event);
}

- (void)webView:(WebView *)sender didClearWindowObject:(WebScriptObject *)windowScriptObject forFrame:(WebFrame *)frame //网页加载完成后发生的动作
{
    NSLog(@"WebViewLoadDelegate window.external");
    [windowScriptObject setValue:self forKeyPath:@"window.external"]; // 注册一个 window.external 的 Javascript 类
}

+ (NSString*)webScriptNameForSelector:(SEL)sel
{
    NSString* funcName = NSStringFromSelector(sel);
    NSLog(@"funcName----->:%@",funcName);
    // selector 返回的方法名多: 需要把:去掉
    if([funcName containsString:@":"])
    {
        NSUInteger pos = [funcName rangeOfString:@":"].location;
        funcName = [funcName substringToIndex:pos];
    }
    
    return funcName;
}


+ (BOOL)isSelectorExcludedFromWebScript:(SEL)sel
{
    NSString* funcName = NSStringFromSelector(sel);
    
    NSLog(@"isSelectorExcludedFromWebScript funcName:%@",funcName);
    
    for (size_t i = 0; i < sizeof(CEFFuncName)/sizeof(char*); i++) {
        NSString* name = [[NSString alloc] initWithUTF8String:CEFFuncName[i]];
        //NSLog(@"for name:%@",name);
        if([funcName isEqualToString:name])
            return NO;
    }
    
    return YES; //返回 YES 表示函数被排除，不会在网页上注册
}

//产生一个右键菜单事件
-(void) GenerateCefRightEvent:(vector<string>) value eventId:(int)EventId
{
    NSLog(@"GenerateCefRightEvent: eventId:%d, value.size:%ld",EventId,value.size());
    wxThreadEvent threadEvent(wxEVT_THREAD, EventId);
    threadEvent.SetPayload(value);
    if (webKitWindow && webKitWindow->GetEventHandler())
        wxQueueEvent(webKitWindow, threadEvent.Clone());
    
}
- (vector<string>)constructPars:(NSString*) arg1 second:(NSString*) arg2
{
    vector<string> r;
    if (arg1 == nil)
    {
        r.push_back("");
    }
    else
    {
        const char* t = [arg1 UTF8String];
        r.push_back(t);
    }
    
    if (arg2 == nil)
    {
        r.push_back("");
    }
    else
    {
        const char* t = [arg2 UTF8String];
        r.push_back(t);
    }
    
    return r;
}
// 快速回复
- (void)FastReply:(NSString*)replayContent mailNum:(NSString*)num
{
    vector<string> values = [self constructPars:replayContent second:num];

    [self GenerateCefRightEvent:values eventId:CEFFastReply];
    NSLog(@"replayContent:%@,%@",replayContent,num);
}
// 回复
- (void) Reply:(NSString*)num
{
    vector<string> values = [self constructPars:nil second:num];
    
    [self GenerateCefRightEvent:values eventId:CEFReply];
    NSLog(@"Reply:%@",num);
}
// 回复全部
- (void) ReplyAll:(NSString*)num
{
    vector<string> values = [self constructPars:nil second:num];
    
    [self GenerateCefRightEvent:values eventId:CEFReplyAll];
    NSLog(@"ReplyAll:%@",num);
}
// 转发
- (void) Foward:(NSString*)num
{
    vector<string> values = [self constructPars:nil second:num];
    
    [self GenerateCefRightEvent:values eventId:CEFFoward];
    NSLog(@"Foward:%@",num);
}
// 作为附件转发
- (void)AsAttachmentForward:(NSString*)num
{
    vector<string> values = [self constructPars:nil second:num];
    
    [self GenerateCefRightEvent:values eventId:CEFAsAttachFoward];
    NSLog(@"AsAttachmentForward:%@",num);
}
// 附件预览
- (void) AccessoryView:(NSString*)index mailNum:(NSString*)num
{
    vector<string> values = [self constructPars:index second:num];
    
    [self GenerateCefRightEvent:values eventId:CEFAttachmentView];
    NSLog(@"Accessory_view index:%@ mailNum:%@", index,num);
}
// 双击查看附件
//Accessory_view_DBclick:
// 下载附件
- (void)AccessoryDownload:(NSString*)index mailNum:(NSString*)num
{
    vector<string> values = [self constructPars:index second:num];
    
    [self GenerateCefRightEvent:values eventId:CEFAttachmentDownload];
    NSLog(@"Accessory_Download index:%@ mailNum:%@", index,num);
}
// 保存所有附件
- (void)AccessorySaveall:(NSString*)index mailNum:(NSString*)num
{
    vector<string> values = [self constructPars:index second:num];
    
    [self GenerateCefRightEvent:values eventId:CEFAttachmentSaveall];
    NSLog(@"Accessory_Saveall index:%@ mailNum:%@", index,num);
}
// 拷贝附件
- (void)AccessoryCopy:(NSString*)index mailNum:(NSString*)num
{
    vector<string> values = [self constructPars:index second:num];
    
    [self GenerateCefRightEvent:values eventId:CEFAttachmentCopy];
    NSLog(@"Accessory_Copy index:%@ mailNum:%@", index,num);
}
// 转发附件
- (void)AccessoryRelay:(NSString*)index mailNum:(NSString*)num
{
    vector<string> values = [self constructPars:index second:num];
    
    [self GenerateCefRightEvent:values eventId:CEFAttachmentRelay];
    NSLog(@"Accessory_Relay index:%@ mailNum:%@", index,num);
}
// 拷贝
- (void)CopyText:(NSString*)index mailNum:(NSString*)num
{
    vector<string> values = [self constructPars:index second:num];
    
    [self GenerateCefRightEvent:values eventId:CEFCopyText];
    NSLog(@"CopyText index:%@ mailNum:%@", index,num);
}
// 全选
- (void)SelectAll:(NSString*)index mailNum:(NSString*)num
{
    vector<string> values = [self constructPars:index second:num];
    
    [self GenerateCefRightEvent:values eventId:CEFSelectALL];
    NSLog(@"SelectAll index:%@ num:%@",index,num);
}
// 应用url
- (void)GetApplicationUrl:(NSString*)ids
{
    vector<string> values = [self constructPars:nil second:ids];
    
    [self GenerateCefRightEvent:values eventId:CEFGetApplicationUrl];
    NSLog(@"Get_Application_Url:%@",ids);
}
// 应用详情
- (void)ApplicationDetail:(NSString*)ids
{
    vector<string> values = [self constructPars:nil second:ids];
    
    [self GenerateCefRightEvent:values eventId:CEFApplicationDetail];
    NSLog(@"Application_Detail:%@",ids);
}
// 安装应用
- (void)InstallApplication:(NSString*)aid
{
    vector<string> values = [self constructPars:nil second:aid];
    
    [self GenerateCefRightEvent:values eventId:CEFInstallApplication];
    NSLog(@"Install_Application:%@",aid);
}
///edit_on_input
//OpenWindowUrl
// 跳到写邮件
- (void)JumpWriteMail:(NSString*)account
{
    vector<string> values = [self constructPars:nil second:account];
    
    [self GenerateCefRightEvent:values eventId:CEFJumpWriteMail];
    NSLog(@"jump_write_mail:%@",account);
}

@end


@implementation WebViewPolicyDelegate

- (id)initWithWxWindow: (wxWebViewWebKit*)inWindow
{
    [super init];
    webKitWindow = inWindow;    // non retained
    return self;
}

- (void)webView:(WebView *)sender
        decidePolicyForNavigationAction:(NSDictionary *)actionInformation
                                request:(NSURLRequest *)request
                                  frame:(WebFrame *)frame
                       decisionListener:(id<WebPolicyDecisionListener>)listener
{
    wxUnusedVar(frame);
    NSString *url = [[request URL] absoluteString];
    NSLog(@"WebViewPolicyDelegate: %d, url:%@",[[actionInformation objectForKey:WebActionNavigationTypeKey] intValue], url);
    NSLog(@"WebNavigationTypeLinkClicked:%d",WebNavigationTypeLinkClicked);

    if (webKitWindow->m_nextNavigationIsNewWindow)
    {
        // This navigation has been marked as a new window
        // cancel the request here and send an apropriate event
        // to the application code
        webKitWindow->m_nextNavigationIsNewWindow = false;

        wxWebViewEvent event(wxEVT_WEBVIEW_NEWWINDOW,
                             webKitWindow->GetId(),
                             wxStringWithNSString( url ), "");

        if (webKitWindow && webKitWindow->GetEventHandler())
            webKitWindow->GetEventHandler()->ProcessEvent(event);

        [listener ignore];
        return;
    }

    webKitWindow->m_busy = true;
    wxString target = wxStringWithNSString([frame name]);
    wxWebViewEvent event(wxEVT_WEBVIEW_NAVIGATING,
                         webKitWindow->GetId(),
                         wxStringWithNSString( url ), target);

    if (webKitWindow && webKitWindow->GetEventHandler())
        webKitWindow->GetEventHandler()->ProcessEvent(event);

    if (!event.IsAllowed())
    {
        webKitWindow->m_busy = false;
        [listener ignore];
    }
    else
    {
        [listener use];
    }
}

- (void)webView:(WebView *)sender
      decidePolicyForNewWindowAction:(NSDictionary *)actionInformation
                             request:(NSURLRequest *)request
                        newFrameName:(NSString *)frameName
                    decisionListener:(id < WebPolicyDecisionListener >)listener
{
    wxUnusedVar(actionInformation);
    
    NSString *url = [[request URL] absoluteString];
    wxWebViewEvent event(wxEVT_WEBVIEW_NEWWINDOW,
                         webKitWindow->GetId(),
                         wxStringWithNSString( url ), "");

    if (webKitWindow && webKitWindow->GetEventHandler())
        webKitWindow->GetEventHandler()->ProcessEvent(event);

    [listener ignore];
}

@end

@implementation WebViewCustomProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request
{
    NSString *scheme = [[request URL] scheme];

    wxStringToWebHandlerMap::const_iterator it;
    for( it = g_stringHandlerMap.begin(); it != g_stringHandlerMap.end(); ++it )
    {
        if(it->first.IsSameAs(wxStringWithNSString(scheme)))
        {
            return YES;
        }
    }

    return NO;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request
{
    //We don't do any processing here as the wxWebViewHandler classes do it
    return request;
}

- (void)startLoading
{
    NSURLRequest *request = [self request];
    NSString* path = [[request URL] absoluteString];

    id<NSURLProtocolClient> client = [self client];

    wxString wxpath = wxStringWithNSString(path);
    wxString scheme = wxStringWithNSString([[request URL] scheme]);
    wxFSFile* file = g_stringHandlerMap[scheme]->GetFile(wxpath);

    if (!file)
    {
        NSError *error = [[NSError alloc] initWithDomain:NSURLErrorDomain
                            code:NSURLErrorFileDoesNotExist
                            userInfo:nil];

        [client URLProtocol:self didFailWithError:error];

        return;
    }

    size_t length = file->GetStream()->GetLength();


    NSURLResponse *response =  [[NSURLResponse alloc] initWithURL:[request URL]
                               MIMEType:wxNSStringWithWxString(file->GetMimeType())
                               expectedContentLength:length
                               textEncodingName:nil];

    //Load the data, we malloc it so it is tidied up properly
    void* buffer = malloc(length);
    file->GetStream()->Read(buffer, length);
    NSData *data = [[NSData alloc] initWithBytesNoCopy:buffer length:length];

    //We do not support caching anything yet
    [client URLProtocol:self didReceiveResponse:response
            cacheStoragePolicy:NSURLCacheStorageNotAllowed];

    //Set the data
    [client URLProtocol:self didLoadData:data];

    //Notify that we have finished
    [client URLProtocolDidFinishLoading:self];

    [response release];
}

- (void)stopLoading
{

}

@end

@implementation WebViewUIDelegate

- (id)initWithWxWindow: (wxWebViewWebKit*)inWindow
{
    [super init];
    webKitWindow = inWindow;    // non retained
    return self;
}

- (WebView *)webView:(WebView *)sender createWebViewWithRequest:(NSURLRequest *)request
{
    // This method is called when window.open() is used in javascript with a target != _self
    // request is always nil, so it can't be used for event generation
    // Mark the next navigation as "new window"
    webKitWindow->m_nextNavigationIsNewWindow = true;
    NSLog(@"WebViewUIDelegate");
    return sender;
}

- (void)webView:(WebView *)sender printFrameView:(WebFrameView *)frameView
{
    wxUnusedVar(sender);
    wxUnusedVar(frameView);

    webKitWindow->Print();
}

- (NSArray *)webView:(WebView *)sender contextMenuItemsForElement:(NSDictionary *)element
                                                 defaultMenuItems:(NSArray *) defaultMenuItems
{
    if(webKitWindow->IsContextMenuEnabled())
        return defaultMenuItems;
    else
        return nil;
}
- (void)webView:(WebView *)sender runOpenPanelForFileButtonWithResultListener:(id<WebOpenPanelResultListener>)resultListener
{
    NSLog(@"runOpenPanelForFileButtonWithResultListener 1");
}

- (void)webView:(WebView *)sender runOpenPanelForFileButtonWithResultListener:(id<WebOpenPanelResultListener>)resultListener allowMultipleFiles:(BOOL)allowMultipleFiles
{
    NSLog(@"unOpenPanelForFileButtonWithResultListener 2");
    NSOpenPanel* openDlg = [NSOpenPanel openPanel];
    
    [openDlg setCanChooseFiles:YES];
    
    [openDlg setCanChooseDirectories:NO];
    
    [openDlg setAllowsOtherFileTypes:YES];
    
    [openDlg setAllowsMultipleSelection:allowMultipleFiles];

    if ( [openDlg runModal] == NSOKButton )
    {
        if (allowMultipleFiles)
        {
            NSArray* names = [openDlg URLs];
            NSMutableArray *paths = [[NSMutableArray alloc]init];
            for(NSURL* url in names)
            {
                NSString* path = [NSString stringWithString:[url path]];
                [paths addObject:path];
            }

            [resultListener chooseFilenames:paths];
        }
        else
        {
            NSURL* url = [openDlg URL];
            NSString* fileString = [NSString stringWithString:[url path]];
            [resultListener chooseFilename:fileString];
        }
    }
}

- (void)webView:(WebView *)sender runJavaScriptAlertPanelWithMessage:(NSString *)message
{
    NSAlert *alert = [[NSAlert alloc] init];
    [alert addButtonWithTitle:@"确定"];
    [alert setMessageText:message];
    [alert runModal];
    [alert release];
}
- (BOOL)webView:(WebView *)sender runJavaScriptConfirmPanelWithMessage:(NSString *)message
{
    NSAlert* alert = [[NSAlert alloc] init];
    [alert addButtonWithTitle:NSLocalizedString(@"确定", @"")];
    [alert addButtonWithTitle:NSLocalizedString(@"取消", @"")];
    [alert setMessageText:message];

    BOOL r = ([alert runModal] == NSAlertFirstButtonReturn);
    [alert release];
    
    return r;
}

- (NSString *)webView:(WebView *)sender runJavaScriptTextInputPanelWithPrompt:(NSString *)prompt defaultText:(NSString *)defaultText
{
    NSAlert* alert = [[NSAlert alloc] init];
    [alert addButtonWithTitle:NSLocalizedString(@"确定", @"")];
    [alert addButtonWithTitle:NSLocalizedString(@"取消", @"")];
    [alert setMessageText:prompt];
    
    NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 200, 24)];
    [input setPlaceholderString:defaultText];
    [alert setAccessoryView:input];
    NSInteger button = [alert runModal];
    if (button == NSAlertFirstButtonReturn) {
        [input validateEditing];
        return [input stringValue];
    } else if (button == NSAlertSecondButtonReturn) {
        return nil;
    } else {
        return nil;
    }
}

@end

@implementation WebResourceLoadDelegate

- (id)initWithWxWindow: (wxWebViewWebKit*)inWindow
{
    [super init];
    webKitWindow = inWindow;    // non retained
    return self;
}

-(NSURLRequest *)webView:(WebView *)sender
                resource:(id)identifier
         willSendRequest:(NSURLRequest *)request
        redirectResponse:(NSURLResponse *)redirectResponse
          fromDataSource:(WebDataSource *)dataSource
{

    NSString* path = [[request URL] absoluteString];

    NSLog(@"willSendRequest:%@",path);

    //path = path.lowercaseString;
    //if(![path containsString:@"UploadHandler.ashx"] && ![path containsString:@"controller.ashx"] && ![path containsString:@"askforleave.aspx"])
    if([path containsString:@"Handler.ashx?"])
        [self downloadFile:request];

    // Update the status message
    [self updateResourceStatus];

    return request;
}
// 这里会发送一次网络请求
- (void) downloadFile:(NSURLRequest *)request
{
    NSURLSession *session = [NSURLSession sharedSession];
    
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request
                                            completionHandler:
                                  ^(NSData *data, NSURLResponse *response, NSError *error) {
                                      
                                      if (error==nil) {
                                          if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
                                              NSDictionary *dic = [(NSHTTPURLResponse *)response allHeaderFields];
                                              NSString *contentType = (NSString*)[dic objectForKey:@"Content-Type"];
                                              NSString *contentDisposition = [dic objectForKey:@"Content-Disposition"];
                                              //NSLog(@"=== content-type:%@ : disposition:%@  ,dic:%@", contentType, contentDisposition, dic);
                                              if ([contentType isEqualToString:@"application/octet-stream"]) {

                                                  NSArray *paths  = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
                                                  NSString *path = [paths objectAtIndex:0];
                                                  NSString *cpath = @"";
                                                  
                                                  NSString *prefix = @"attachment; filename=";
                                                  if (contentDisposition != nil) {
                                                      BOOL isContent = [contentDisposition hasPrefix:prefix];
                                                      if (isContent) {
                                                          NSRange range = [contentDisposition rangeOfString:prefix];
                                                          NSString *fileName = [[contentDisposition substringFromIndex:(range.location + range.length)] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];

                                                          NSLog(@"filePath:%@",path);
                                                          NSLog(@"fileName:%@",fileName);
                                                          NSString *fullPath = [path stringByAppendingString:[NSString stringWithFormat:@"/database/tmp/%@",fileName]];
                                                          NSLog(@"fullPath:%@",fullPath);
                                                          
                                                          [data writeToFile:fullPath atomically:YES];
                                                          vector<string> vec;
                                                          vec.push_back(wxStringWithNSString(fullPath).ToStdString());
                                                          vec.push_back("");
                                                          [self GenerateThreadEvent:vec eventId:DownloadFileSuccess];
                                                      }
                                                  }
                                              }
                                          }
                                      }
                                      
                                  }];
    
    [task resume];
}

//- (NSString *) choseSaveFilePath
//{
//    NSSavePanel* saveDlg = [NSSavePanel savePanel];
//    NSString* path = @"";
//    [saveDlg setCanCreateDirectories:YES];
//    [saveDlg setMessage:@"Choose the path to save the document"];
//    [saveDlg setAllowsOtherFileTypes:YES];
//    [saveDlg beginSheetModalForWindow:nil completionHandler:^(NSInteger result){
//        if (result == NSFileHandlingPanelOKButton)
//        {
//            NSString *tpath = [[saveDlg URL] path];
//            NSLog(@"saveDlg path:%@",path);
//            [path initWithString:tpath];
//        }
//    }];
//
//    return path;
//}

- (void) updateResourceStatus
{
    
}

-(void)webView:(WebView *)sender resource:(id)identifier
didFailLoadingWithError:(NSError *)error
fromDataSource:(WebDataSource *)dataSource
{
    NSLog(@"didFailLoadingWithError");
    resourceFailedCount++;
    // Update the status message
    [self updateResourceStatus];
}

- (void)webView:(WebView *)sender
      resource:(id)identifier
didFinishLoadingFromDataSource:(WebDataSource *)dataSource
{
    NSLog(@"didFinishLoadingFromDataSource");
    resourceCompletedCount++;
    // Update the status message
    [self updateResourceStatus];
}

//产生一个右键菜单事件
- (void) GenerateThreadEvent:(vector<string>) value eventId:(int)EventId
{
    NSLog(@"GenerateCefRightEvent: eventId:%d, value.size:%ld",EventId,value.size());
    wxThreadEvent threadEvent(wxEVT_THREAD, EventId);
    threadEvent.SetPayload(value);
    if (webKitWindow && webKitWindow->GetEventHandler())
        wxQueueEvent(webKitWindow, threadEvent.Clone());
    
}
@end

#endif //wxUSE_WEBVIEW && wxUSE_WEBVIEW_WEBKIT
