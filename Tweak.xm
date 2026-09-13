// Weibo system integration fix for iOS 6.
// The old OAuth1/API requests are intercepted in accountsd/weibod and translated
// directly to api.weibo.cn. No LAN bridge is required after credentials are stored.

#import <Foundation/Foundation.h>
#import <substrate.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <CommonCrypto/CommonCryptor.h>
#include <stdarg.h>
#include <stdio.h>

#define WBURL             objc_getClass("NSURL")
#define WBRequest         objc_getClass("NSURLRequest")
#define WBMutableRequest  objc_getClass("NSMutableURLRequest")
#define WBHTTPResponse    objc_getClass("NSHTTPURLResponse")
#define WBDictionary      objc_getClass("NSDictionary")
#define WBJSON            objc_getClass("NSJSONSerialization")

static NSString *const WBPrefs = @"/var/mobile/Library/Preferences/com.shima.weibointegrationfix.plist";
static NSString *const WBHandled = @"WeiboIntegrationFixHandled";
static NSString *const WBCNBase = @"https://api.weibo.cn/2/";

static NSString *WBEncode(NSString *s);
static NSData *WBJSONData(id obj);

static void WBLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *line = [[[NSString alloc] initWithFormat:fmt arguments:ap] autorelease];
    va_end(ap);
    FILE *f = fopen("/var/tmp/weibointegrationfix.log", "a");
    if (f) { fprintf(f, "%s\n", [line UTF8String]); fclose(f); }
}

static NSMutableDictionary *WBLoad(void) {
    NSDictionary *d = [WBDictionary dictionaryWithContentsOfFile:WBPrefs];
    return d ? [[d mutableCopy] autorelease] : [NSMutableDictionary dictionary];
}

static void WBSave(NSDictionary *d) { [d writeToFile:WBPrefs atomically:YES]; }

static NSString *WBToken(void) {
    return [[[NSProcessInfo processInfo] globallyUniqueString] stringByReplacingOccurrencesOfString:@"-" withString:@""];
}

static NSString *WBBase64(NSData *data) {
    static const char t[]="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const unsigned char *p=(const unsigned char *)[data bytes]; NSUInteger n=[data length];
    NSMutableString *s=[NSMutableString stringWithCapacity:((n+2)/3)*4];
    for (NSUInteger i=0;i<n;i+=3) {
        unsigned v=p[i]<<16; if(i+1<n)v|=p[i+1]<<8; if(i+2<n)v|=p[i+2];
        [s appendFormat:@"%c%c%c%c",t[(v>>18)&63],t[(v>>12)&63],i+1<n?t[(v>>6)&63]:'=',i+2<n?t[v&63]:'='];
    }
    NSMutableString *wrapped=[NSMutableString string];
    for(NSUInteger i=0;i<[s length];i+=72){NSUInteger z=MIN((NSUInteger)72,[s length]-i);[wrapped appendString:[s substringWithRange:NSMakeRange(i,z)]];[wrapped appendString:@"\n"];}
    return wrapped;
}

static NSString *WBEncryptedMFP(NSString **uaOut) {
    NSString *ua=@"Xiaomi-M2011K2C__weibo__2.0__android__android12";
    NSString *oaid=WBToken();
    NSDictionary *sys=[WBDictionary dictionaryWithObjectsAndKeys:@"venus",@"ro.product.name",@"Xiaomi",@"ro.product.manufacturer",@"31",@"ro.build.version.sdk",@"venus",@"ro.product.device",nil];
    NSDictionary *mfp=[WBDictionary dictionaryWithObjectsAndKeys:
        [WBDictionary dictionaryWithObjectsAndKeys:@"2",@"version",@"",@"aid",nil],@"meta",
        [WBDictionary dictionaryWithObjectsAndKeys:[NSArray array],@"nlif",sys,@"sysprop",nil],@"ninfo",
        [WBDictionary dictionaryWithObjectsAndKeys:@"Android 12",@"os",ua,@"ua",@"M2011K2C",@"model",oaid,@"ext_oaid",@"80",@"battery",nil],@"ainfo",nil];
    NSDictionary *cfg=[WBDictionary dictionaryWithObjectsAndKeys:
        ua,@"ua",[WBDictionary dictionaryWithObjectsAndKeys:@"902784192",@"appkey",@"com.sina.weibolite",@"package",@"2.5",@"sdk_version",nil],@"meta",
        [WBDictionary dictionaryWithObjectsAndKeys:mfp,@"mfp",@"1478195010",@"from",@"1000_0001",@"wm",@"visitor_login",@"act",nil],@"data",nil];
    NSData *raw=WBJSONData(cfg); size_t outLen=[raw length]+kCCBlockSizeAES128; void *out=malloc(outLen); size_t moved=0;
    CCCrypt(kCCEncrypt,kCCAlgorithmAES128,kCCOptionPKCS7Padding,"7ad95a5ba3fc7464",16,"0501842de160030c",[raw bytes],[raw length],out,outLen,&moved);
    NSData *enc=[NSData dataWithBytesNoCopy:out length:moved freeWhenDone:YES]; if(uaOut)*uaOut=ua;
    return [NSString stringWithFormat:@"%@&version=01&extra=",WBEncode(WBBase64(enc))];
}

static NSString *WBEncode(NSString *s) {
    if (!s) return @"";
    return [(NSString *)CFURLCreateStringByAddingPercentEscapes(NULL, (CFStringRef)s, NULL,
             CFSTR("!*'();:@&=+$,/?%#[]"), kCFStringEncodingUTF8) autorelease];
}

static NSMutableDictionary *WBForm(NSString *s) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSString *part in [s componentsSeparatedByString:@"&"]) {
        NSRange r = [part rangeOfString:@"="];
        if (r.location == NSNotFound) continue;
        NSString *k = [[part substringToIndex:r.location] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        NSString *v = [[part substringFromIndex:r.location + 1] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        if (k) [out setObject:(v ?: @"") forKey:k];
    }
    return out;
}

static void WBAddOAuthHeader(NSMutableDictionary *out, NSString *header) {
    if (![header hasPrefix:@"OAuth "]) return;
    NSString *rest=[header substringFromIndex:6];
    for(NSString *piece in [rest componentsSeparatedByString:@","]){
        NSString *part=[piece stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSRange r=[part rangeOfString:@"="]; if(r.location==NSNotFound)continue;
        NSString *k=[part substringToIndex:r.location]; NSString *v=[part substringFromIndex:r.location+1];
        if([v hasPrefix:@"\""]&&[v hasSuffix:@"\""]&&[v length]>=2)v=[v substringWithRange:NSMakeRange(1,[v length]-2)];
        v=[v stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding]; if(k&&v)[out setObject:v forKey:k];
    }
}

static NSData *WBRequestBody(NSURLRequest *r) {
    NSData *d=[r HTTPBody]; if(d)return d;
    NSInputStream *s=[r HTTPBodyStream]; if(!s)return nil;
    NSMutableData *out=[NSMutableData data]; uint8_t buf[16384]; [s open];
    while([s hasBytesAvailable]){NSInteger n=[s read:buf maxLength:sizeof(buf)];if(n<=0)break;[out appendBytes:buf length:n];}
    [s close]; return out;
}

static NSString *WBFormString(NSDictionary *d) {
    NSMutableArray *a = [NSMutableArray array];
    for (NSString *k in d) [a addObject:[NSString stringWithFormat:@"%@=%@", WBEncode(k), WBEncode([d objectForKey:k])]];
    return [a componentsJoinedByString:@"&"];
}

static NSDictionary *WBCredentials(void) { return WBLoad(); }

// The stock authentication plug-in stores screen_name only as accountDescription.
// Keep all three Settings fields consistent at save time.
static void (*WBOrigSetDescription)(id,SEL,NSString *);
static void WBSetDescription(id account, SEL cmd, NSString *name) {
    WBOrigSetDescription(account,cmd,name);
    if (![name length]) return;
    id type=[account respondsToSelector:@selector(accountType)]?[account performSelector:@selector(accountType)]:nil;
    NSString *identifier=[type respondsToSelector:@selector(identifier)]?[type performSelector:@selector(identifier)]:nil;
    if ([identifier isEqualToString:@"com.apple.sinaweibo"]) {
        if ([account respondsToSelector:@selector(setUsername:)]) [account performSelector:@selector(setUsername:) withObject:name];
        if ([account respondsToSelector:@selector(setAccountProperty:forKey:)]) {
            ((void(*)(id,SEL,id,id))objc_msgSend)(account,@selector(setAccountProperty:forKey:),name,@"screen_name");
        }
    }
}

static NSString *WBMobileQuery(NSDictionary *p, NSString *gsid) {
    NSMutableDictionary *q = [NSMutableDictionary dictionaryWithObjectsAndKeys:
        @"iphone", @"c", @"1053093010", @"from", @"9939040f", @"s",
        @"3333_2001", @"wm", @"edff677", @"i", @"0", @"b",
        @"default", @"skin", @"21", @"v_p", @"1", @"v_f", @"zh_CN", @"lang",
        @"iPhone5,2__weibo__5.3.0__iphone__os6.1.3", @"ua", nil];
    if (gsid) [q setObject:gsid forKey:@"gsid"];
    NSSet *drop = [NSSet setWithObjects:@"oauth_token",@"oauth_consumer_key",@"oauth_signature",
                   @"oauth_signature_method",@"oauth_timestamp",@"oauth_nonce",@"oauth_version",@"source",nil];
    for (NSString *k in p) if (![drop containsObject:k]) [q setObject:[p objectForKey:k] forKey:k];
    return WBFormString(q);
}

static NSData *WBJSONData(id obj) {
    return [WBJSON dataWithJSONObject:obj options:0 error:NULL];
}

static NSData *WBRequestSync(NSString *url, NSString *method, NSString *body, NSString *ua, NSInteger *status) {
    NSMutableURLRequest *r=[WBMutableRequest requestWithURL:[WBURL URLWithString:url]];
    [r setHTTPMethod:method]; [r setTimeoutInterval:30];
    [r setValue:(ua ?: @"okhttp/3.12.1") forHTTPHeaderField:@"User-Agent"];
    if(body){
        NSData *bd=[body dataUsingEncoding:NSUTF8StringEncoding]; [r setHTTPBody:bd];
        [r setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
        [r setValue:[NSString stringWithFormat:@"%u",[bd length]] forHTTPHeaderField:@"Content-Length"];
        [r setValue:@"close" forHTTPHeaderField:@"Connection"];
    }
    [NSURLProtocol setProperty:@YES forKey:WBHandled inRequest:r];
    NSURLResponse *resp=nil; NSError *err=nil;
    NSData *d=[NSURLConnection sendSynchronousRequest:r returningResponse:&resp error:&err];
    if(status)*status=[resp respondsToSelector:@selector(statusCode)]?[(id)resp statusCode]:0;
    if(err) WBLog(@"sync error %@",err);
    return d;
}

static NSDictionary *WBJSONObject(NSData *d) {
    if(!d)return nil; id o=[WBJSON JSONObjectWithData:d options:0 error:NULL]; return [o isKindOfClass:WBDictionary]?o:nil;
}

static void WBFinish(NSURLProtocol *proto, NSData *data, NSInteger status, NSString *type) {
    NSURLResponse *resp = [[[WBHTTPResponse alloc] initWithURL:[[proto request] URL]
        statusCode:status HTTPVersion:@"HTTP/1.1"
        headerFields:[WBDictionary dictionaryWithObject:(type ?: @"application/json") forKey:@"Content-Type"]] autorelease];
    [[proto client] URLProtocol:proto didReceiveResponse:resp cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    if (data) [[proto client] URLProtocol:proto didLoadData:data];
    [[proto client] URLProtocolDidFinishLoading:proto];
}

static void WBFailJSON(NSURLProtocol *p, NSInteger code, NSString *msg) {
    NSData *d = WBJSONData([WBDictionary dictionaryWithObjectsAndKeys:msg,@"error",
                            [NSNumber numberWithInteger:code],@"error_code",nil]);
    WBFinish(p,d,400,@"application/json");
}

@interface WBIntegrationFixProtocol : NSURLProtocol <NSURLConnectionDelegate> {
    NSURLConnection *_connection;
    NSMutableData *_data;
    NSURLResponse *_response;
}
@end

@implementation WBIntegrationFixProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)r {
    if ([NSURLProtocol propertyForKey:WBHandled inRequest:r]) return NO;
    NSString *h = [[r URL] host];
    return [h isEqualToString:@"api.weibo.com"] || [h isEqualToString:@"api.t.sina.com.cn"];
}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)r { return r; }

- (void)startLoading {
    NSURLRequest *old = [self request];
    NSURL *u = [old URL];
    NSString *path = [u path] ?: @"";
    NSMutableDictionary *p = WBForm([u query] ?: @"");
    WBAddOAuthHeader(p,[old valueForHTTPHeaderField:@"Authorization"]);
    NSString *ctype = [old valueForHTTPHeaderField:@"Content-Type"] ?: @"";
    if (!([ctype hasPrefix:@"multipart/"])) {
        NSString *body = [[[NSString alloc] initWithData:WBRequestBody(old) encoding:NSUTF8StringEncoding] autorelease];
        [p addEntriesFromDictionary:WBForm(body ?: @"")];
    }

    // Existing and newly generated OAuth credentials are local aliases for the gsid.
    if ([path hasSuffix:@"/oauth/access_token"]) {
        [self retain];
        NSOperationQueue *queue=[[[NSOperationQueue alloc] init] autorelease];
        [queue addOperationWithBlock:^{
            @autoreleasepool { [self handleAuth:p]; [self release]; }
        }];
        return;
    }
    NSDictionary *cred = WBCredentials();
    NSString *requestToken=[p objectForKey:@"oauth_token"];
    if (![requestToken hasPrefix:@"_2A"]) {
        WBFailJSON(self,21332,@"token_rejected!"); return;
    }

    if ([path hasSuffix:@"/common/configuration.json"]) {
        NSDictionary *cfg = [WBDictionary dictionaryWithObjectsAndKeys:@20,@"short_url_length",@1024,@"long_url_length",
                             @5242880,@"image_size_limit",nil];
        WBFinish(self,WBJSONData(cfg),200,@"application/json"); return;
    }
    if ([path hasSuffix:@"/place/nearby/pois.json"]) {
        WBFinish(self,WBJSONData([WBDictionary dictionaryWithObjectsAndKeys:[NSArray array],@"pois",@0,@"total_number",nil]),200,@"application/json"); return;
    }

    NSString *target = path;
    if ([target hasPrefix:@"/2/"]) target = [target substringFromIndex:3];
    else if ([target hasPrefix:@"/"]) target = [target substringFromIndex:1];
    if ([target hasSuffix:@".json"]) target = [target substringToIndex:[target length]-5];
    if ([target isEqualToString:@"account/verify_credentials"]) {
        target = @"users/show"; [p setObject:[cred objectForKey:@"UID"] forKey:@"uid"];
    } else if ([target isEqualToString:@"statuses/friends"]) {
        target = @"friendships/friends"; [p setObject:[cred objectForKey:@"UID"] forKey:@"uid"];
        if ([[p objectForKey:@"cursor"] isEqualToString:@"-1"]) [p setObject:@"0" forKey:@"cursor"];
    } else if ([target isEqualToString:@"statuses/update"]) {
        target = @"statuses/send";
    } else if ([target isEqualToString:@"querymid"]) {
        target = @"statuses/querymid";
    }

    NSString *url = [NSString stringWithFormat:@"%@%@?%@",WBCNBase,target,WBMobileQuery(p,requestToken)];
    NSMutableURLRequest *nr = [WBMutableRequest requestWithURL:[WBURL URLWithString:url]];
    [nr setHTTPMethod:[old HTTPMethod]];
    [nr setTimeoutInterval:60];
    [nr setValue:@"Weibo/5.3.0 (iPhone; iOS 6.1.3; Scale/2.00)" forHTTPHeaderField:@"User-Agent"];
    if ([[old HTTPMethod] isEqualToString:@"POST"]) {
        NSData *body = WBRequestBody(old);
        if ([target isEqualToString:@"statuses/send"] && ![ctype hasPrefix:@"multipart/"]) {
            NSMutableDictionary *f = WBForm([[[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] autorelease]);
            NSString *text = [f objectForKey:@"status"] ?: [f objectForKey:@"content"] ?: @"";
            body = [WBFormString([WBDictionary dictionaryWithObject:text forKey:@"content"]) dataUsingEncoding:NSUTF8StringEncoding];
            ctype = @"application/x-www-form-urlencoded";
        }
        [nr setHTTPBody:body];
        if ([ctype length]) [nr setValue:ctype forHTTPHeaderField:@"Content-Type"];
    }
    [NSURLProtocol setProperty:@YES forKey:WBHandled inRequest:nr];
    WBLog(@"%@ %@ -> %@",[old HTTPMethod],path,target);
    _data = [[NSMutableData alloc] init];
    _connection = [[NSURLConnection alloc] initWithRequest:nr delegate:self startImmediately:YES];
}

- (void)handleAuth:(NSDictionary *)p {
    NSMutableDictionary *c = WBLoad();
    NSString *mode = [p objectForKey:@"x_auth_mode"];
    NSString *token = [p objectForKey:@"x_auth_access_token"];
    if ([mode isEqualToString:@"exchange_auth"] && [token hasPrefix:@"_2A"]) {
        [self authReply:c token:token]; return;
    }
    if(![mode isEqualToString:@"client_auth"]){WBFinish(self,[@"error=unsupported_mode" dataUsingEncoding:NSUTF8StringEncoding],400,@"text/plain");return;}
    NSString *entered=[p objectForKey:@"x_auth_username"] ?: @"";
    NSString *phone=entered;
    if([entered isEqualToString:[c objectForKey:@"ScreenName"]] && [c objectForKey:@"Phone"]) phone=[c objectForKey:@"Phone"];
    NSString *secret=[p objectForKey:@"x_auth_password"] ?: @"";
    NSCharacterSet *nonDigits=[[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    BOOL isCode=([secret length]>=4 && [secret length]<=8 && [secret rangeOfCharacterFromSet:nonDigits].location==NSNotFound);
    NSInteger st=0;
    if(isCode && [c objectForKey:@"PendingAid"] && [c objectForKey:@"PendingPhone"]) {
        NSDictionary *f=[WBDictionary dictionaryWithObjectsAndKeys:@"weibofastios",@"c",@"1234567",@"i",[c objectForKey:@"PendingAid"],@"aid",@"1",@"getuser",phone,@"phone",secret,@"smscode",@"zh_CN",@"lang",nil];
        NSData *d=WBRequestSync(@"https://api.weibo.cn/2/account/login",@"POST",WBFormString(f),@"okhttp/3.12.1",&st);
        NSDictionary *j=WBJSONObject(d); NSString *gsid=[j objectForKey:@"gsid"];
        if(gsid){
            NSDictionary *user=[j objectForKey:@"user"]; NSString *uid=[[j objectForKey:@"uid"] description] ?: [[user objectForKey:@"id"] description];
            NSString *name=[j objectForKey:@"screen_name"] ?: [user objectForKey:@"screen_name"] ?: entered;
            [c setObject:(uid ?: @"") forKey:@"UID"]; [c setObject:name forKey:@"ScreenName"];
            [c setObject:phone forKey:@"Phone"]; [c removeObjectForKey:@"PendingAid"]; [c removeObjectForKey:@"PendingPhone"]; WBSave(c);
            [self authReply:c token:gsid]; return;
        }
        NSString *msg=[j objectForKey:@"errmsg"] ?: @"sms_login_failed"; WBFinish(self,[[NSString stringWithFormat:@"error=%@",WBEncode(msg)] dataUsingEncoding:NSUTF8StringEncoding],401,@"text/plain");return;
    }
    NSString *ua=nil; NSString *encrypted=WBEncryptedMFP(&ua);
    NSData *vd=WBRequestSync(@"https://login.sina.com.cn/visitor/signin",@"POST",[NSString stringWithFormat:@"data=%@",encrypted],ua,&st);
    NSDictionary *vj=WBJSONObject(vd); NSString *aid=[[vj objectForKey:@"data"] objectForKey:@"aid"];
    if(!aid){WBFinish(self,[@"error=visitor_aid_failed" dataUsingEncoding:NSUTF8StringEncoding],401,@"text/plain");return;}
    NSDictionary *sf=[WBDictionary dictionaryWithObjectsAndKeys:aid,@"aid",phone,@"phone",@"zh_CN",@"lang",@"weibofastios",@"c",@"1234567",@"i",@"1478195010",@"from",nil];
    NSData *sd=WBRequestSync(@"https://api.weibo.cn/2/account/login_sendcode",@"POST",WBFormString(sf),@"okhttp/3.12.1",&st);
    NSDictionary *sj=WBJSONObject(sd);
    if([[sj objectForKey:@"sendsms"] boolValue]){[c setObject:aid forKey:@"PendingAid"];[c setObject:phone forKey:@"PendingPhone"];WBSave(c);WBFinish(self,[@"error=sms_code_sent" dataUsingEncoding:NSUTF8StringEncoding],401,@"text/plain");return;}
    NSString *msg=[sj objectForKey:@"errmsg"] ?: @"sms_send_failed"; WBFinish(self,[[NSString stringWithFormat:@"error=%@",WBEncode(msg)] dataUsingEncoding:NSUTF8StringEncoding],401,@"text/plain");
}

- (void)authReply:(NSDictionary *)c token:(NSString *)token {
    NSDictionary *r = [WBDictionary dictionaryWithObjectsAndKeys:
        token,@"oauth_token", @"integrationfix",@"oauth_token_secret",
        [c objectForKey:@"UID"],@"user_id", [c objectForKey:@"ScreenName"],@"screen_name",nil];
    WBFinish(self,[WBFormString(r) dataUsingEncoding:NSUTF8StringEncoding],200,@"text/plain");
}

- (void)stopLoading { [_connection cancel]; [_connection release]; _connection=nil; }
- (void)connection:(NSURLConnection *)c didReceiveResponse:(NSURLResponse *)r { [_response release]; _response=[r retain]; [_data setLength:0]; }
- (void)connection:(NSURLConnection *)c didReceiveData:(NSData *)d { [_data appendData:d]; }
- (void)connectionDidFinishLoading:(NSURLConnection *)c {
    NSInteger status = [_response respondsToSelector:@selector(statusCode)] ? [(id)_response statusCode] : 200;
    NSData *sendData=_data;
    NSDictionary *json=WBJSONObject(_data);
    if ([json objectForKey:@"errno"]) {
        status=400;
        sendData=WBJSONData([WBDictionary dictionaryWithObjectsAndKeys:
            ([json objectForKey:@"errmsg"] ?: @"Weibo error"),@"error",
            [json objectForKey:@"errno"],@"error_code",nil]);
        NSURLResponse *mapped=[[[WBHTTPResponse alloc] initWithURL:[[self request] URL] statusCode:400
            HTTPVersion:@"HTTP/1.1" headerFields:[WBDictionary dictionaryWithObject:@"application/json" forKey:@"Content-Type"]] autorelease];
        [_response release]; _response=[mapped retain];
    }
    WBLog(@"response %d bytes=%d",status,[_data length]);
    [[self client] URLProtocol:self didReceiveResponse:_response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [[self client] URLProtocol:self didLoadData:sendData]; [[self client] URLProtocolDidFinishLoading:self];
}
- (void)connection:(NSURLConnection *)c didFailWithError:(NSError *)e { WBLog(@"error %@",e); [[self client] URLProtocol:self didFailWithError:e]; }
- (void)dealloc { [_connection cancel]; [_connection release]; [_data release]; [_response release]; [super dealloc]; }
@end

%ctor {
    @autoreleasepool {
        Class ac=objc_getClass("ACAccount");
        if(ac) MSHookMessageEx(ac,@selector(setAccountDescription:),(IMP)WBSetDescription,(IMP *)&WBOrigSetDescription);
        [NSURLProtocol registerClass:[WBIntegrationFixProtocol class]];
        WBLog(@"loaded in %@",[[NSProcessInfo processInfo] processName]);
    }
}
