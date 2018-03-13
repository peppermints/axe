//
//  AXEWebViewBridge.m
//  Axe
//
//  Created by 罗贤明 on 2018/3/10.
//  Copyright © 2018年 罗贤明. All rights reserved.
//

#import "AXEWebViewBridge.h"
#import "WebViewJavascriptBridge.h"
#import "WKWebViewJavascriptBridge.h"
#import "AXEDefines.h"
#import "AXEBasicTypeData.h"
#import "AXEJavaScriptModelData.h"
#import "AXEData+JavaScriptSupport.h"
#import "AXEEvent.h"


@interface AXEWebViewBridge()

/**
  当前注册的事件。
 */
@property (nonatomic,strong) NSMutableDictionary *registeredEvents;

@end

@implementation AXEWebViewBridge

+ (instancetype)bridgeWithUIWebView:(UIWebView *)webView {
    NSParameterAssert([webView isKindOfClass:[UIWebView class]]);
    
    return [[self alloc] initWithWebView:webView];
}

+ (instancetype)bridgeWithWKWebView:(WKWebView *)webView {
    NSParameterAssert([webView isKindOfClass:[WKWebView class]]);
    
    return [[self alloc] initWithWebView:webView];
}

- (instancetype)initWithWebView:(UIView *)webView {
    if (self = [super init]) {
        _AXEContainerState = [AXEEventUserInterfaceState state];
        _registeredEvents = [[NSMutableDictionary alloc] init];
        if ([webView isKindOfClass:[UIWebView class]]) {
            _javascriptBridge = (id<AXEWebViewJavaScriptBridge>) [WebViewJavascriptBridge bridgeForWebView:webView];
        }else if ([webView isKindOfClass:[WKWebView class]]) {
            _javascriptBridge = (id<AXEWebViewJavaScriptBridge>) [WKWebViewJavascriptBridge bridgeForWebView:(WKWebView *)webView];
        }
        [self setupBrige];
    }
    return self;
}

- (void)setupBrige {
    @weakify(self);
    // 初始化 jsbridge ,注入相关方法。
    // 设置共享数据数据
    [_javascriptBridge registerHandler:@"axe_data_set" handler:^(id data, WVJBResponseCallback responseCallback) {
        [[AXEData sharedData] setJavascriptData:data forKey:[data objectForKey:@"key"]];
    }];
    [_javascriptBridge registerHandler:@"axe_data_remove" handler:^(id data, WVJBResponseCallback responseCallback) {
        if ([data isKindOfClass:[NSString class]]) {
            [[AXEData sharedData] removeDataForKey:data];
        }
    }];
    [_javascriptBridge registerHandler:@"axe_data_get" handler:^(id data, WVJBResponseCallback responseCallback) {
        NSDictionary *value = [[AXEData sharedData] javascriptDataForKey:data];
        if (value) {
            responseCallback(value);
        }else {
            responseCallback([NSNull null]);
        }
    }];
    // 事件通知
    [_javascriptBridge registerHandler:@"axe_event_register" handler:^(id data, WVJBResponseCallback responseCallback) {
        NSString *eventName = data;
        if ([eventName isKindOfClass:[NSString class]]) {
            @strongify(self);
            if (![self->_registeredEvents objectForKey:eventName]) {
                // 当不存在该监听时，进行注册。
                id disposable = [AXEEvent registerUIListenerForEventName:eventName handler:^(AXEData *payload) {
                    NSMutableDictionary *post = [[NSMutableDictionary alloc] init];
                    [post setObject:eventName forKey:@"name"];
                    if (payload) {
                        // 如果有附带数据，则进行转换。
                        NSDictionary *javascriptData = [AXEData javascriptDataFromAXEData:payload];
                        if ([javascriptData isKindOfClass:[NSDictionary class]]) {
                            [post setObject:javascriptData forKey:@"payload"];
                        }
                    }
                    NSLog(@"post event !!!");
                    [self->_javascriptBridge callHandler:@"axe_event_callback" data:post];
                } inUIContainer:self];
                [self->_registeredEvents setObject:disposable forKey:eventName];
            }
        }
    }];
    [_javascriptBridge registerHandler:@"axe_event_remove" handler:^(id data, WVJBResponseCallback responseCallback) {
        @strongify(self);
        NSCParameterAssert([data isKindOfClass:[NSString class]]);
        // 取消监听
        id<AXEListenerDisposable> disposable = self->_registeredEvents[data];
        if (disposable) {
            [self->_registeredEvents removeObjectForKey:data];
            [disposable dispose];
        }
    }];
    [_javascriptBridge registerHandler:@"axe_event_post" handler:^(id data, WVJBResponseCallback responseCallback) {
        NSCParameterAssert([data isKindOfClass:[NSDictionary class]]);
        NSDictionary *payload = [data objectForKey:@"data"];
        AXEData *payloadData;
        if (payload) {
            payloadData = [AXEData axeDataFromJavascriptData:payload];
        }
        [AXEEvent postEventName:[data objectForKey:@"name"] withPayload:payloadData];
    }];
    
    // 路由跳转
    [_javascriptBridge registerHandler:@"axe_router_route" handler:^(id data, WVJBResponseCallback responseCallback) {
        @strongify(self);
        NSCParameterAssert([data isKindOfClass:[NSDictionary class]]);
        
        NSString *url = [data objectForKey:@"url"];
        NSDictionary *param = [data objectForKey:@"param"];
        AXEData *payload;
        if (param) {
            payload = [AXEData axeDataFromJavascriptData:param];
        }
        // 是否有回调。
        AXERouterCallbackBlock callback;
        BOOL needCallback = [data objectForKey:@"callback"];
        if (needCallback) {
            callback = ^(AXEData *returnData) {
                NSDictionary *returnPayload;
                if (returnData) {
                    returnPayload = [AXEData javascriptDataFromAXEData:returnData];
                }
                responseCallback(returnPayload);
            };
        }
        [[AXERouter sharedRouter] routeURL:url fromViewController:self.webviewController withParams:payload finishBlock:callback];
    }];
    // 路由回调。
    [_javascriptBridge registerHandler:@"axe_router_callback" handler:^(id data, WVJBResponseCallback responseCallback) {
        @strongify(self);
        if (!self.routeCallback) {
            // 如果当前没有设置回调，则表示 这里不能进行回调， 业务模块间的交互定义存在问题。
            AXELogWarn(@"H5模块调用路由回调， 但是当前模块调起时，并没有设置回调。 请检测业务逻辑！！！");
            return;
        }
        AXEData *payload;
        if ([data isKindOfClass:[NSDictionary class]]) {
            payload = [AXEData axeDataFromJavascriptData:data];
        }
        self.routeCallback(payload);
    }];
    // 获取路由信息，即参数以及来源。
    [_javascriptBridge registerHandler:@"axe_router_source" handler:^(id data, WVJBResponseCallback responseCallback) {
        @strongify(self);
        NSMutableDictionary *ret = [[NSMutableDictionary alloc] initWithCapacity:2];
        if (self.routeParams) {
            NSDictionary *javascriptData = [AXEData javascriptDataFromAXEData:self.routeParams];
            [ret setObject:javascriptData forKey:@"payload"];
        }
        if (self.routeCallback) {
            [ret setObject:@"true" forKey:@"needCallback"];
        }else {
            [ret setObject:@"false" forKey:@"needCallback"];
        }
        responseCallback(ret);
    }];
}


@end
